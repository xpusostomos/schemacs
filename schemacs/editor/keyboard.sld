(define-library (schemacs editor keyboard)
  ;; This library mirrors GNU Emacs's `keyboard.c': the command loop and
  ;; the reading of keys. It reads a key event, turns it into a key
  ;; sequence, looks that up in the keymap, runs the command it finds, and
  ;; reports what went wrong in the echo area - then does it again.
  ;;
  ;; The command loop can be *re-entered* rather than copied, which is what
  ;; makes a minibuffer possible: a minibuffer is this same loop called
  ;; again with a different keymap and a different current buffer, which is
  ;; GNU Emacs's `recursive-edit'. Everything the loop does for a command -
  ;; the undo boundary before it, the kill flag rotation, error reporting,
  ;; `last-command' - a prompt gets for free.
  ;;
  ;; Leaving a recursive edit is a `throw' in Emacs: `exit-minibuffer' does
  ;; `(throw \'exit nil)' (minibuffer.el:3048), and a *quit* is
  ;; `(throw \'exit <a function>)' (minibuffer.el:3060) - the function is
  ;; run when the recursive edit has been left, so the quit is raised in
  ;; the CALLER's context and travels out past the minibuffer to the command
  ;; loop, abandoning the command that asked the question. Continuations do
  ;; the same job here, and a quit is that same trick: the loop returns a
  ;; thunk, and the caller runs it.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    ;; The error the loop reports is formatted from the format string its
    ;; arguments arrive apart in.
    (only (scheme write) write)
    ;; `format' and `string-index' are Guile's and not R7RS's, and both are
    ;; on the error path: `report-command-error!' asks whether the message
    ;; has a `~' in it and fills it in if it has. Neither was imported, so
    ;; reporting an error failed - and only a test that makes a command
    ;; signal one could see it, because the error path is not otherwise
    ;; reached.
    (only (guile) format string-index)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor engine)
          new-text-editor
          text-editor-copy-string
          text-editor-deactivate-mark set!text-editor-deactivate-mark!)
    (only (schemacs editor command)
          *this-event*
          command-interactive-spec command-name command-record-of
          command-type? define-command
          run-command)
    ;; Reading a key, and asking the display what it means, is the
    ;; display's job - `getch', its timeout and the terminal's own key
    ;; table all belong to the driver, and this loop calls through the
    ;; interface.
    (only (schemacs editor dispnew)
          current-display key-event->keymap-path read-input-event)
    (only (schemacs editor frame)
          *current-frame* blink-cursor-check
          display-selections-p frame-keymap-state
          frame-message frame-message-expired?
          frame-message-expiry
          frame-quit-cont run-pre-command-hook!
          set!frame-keymap-state set!frame-message
          set!frame-message-expiry
          set!frame-quit-cont
          *echo-area-buffer* *echo-area-prompt*)
    ;; The global map the lookup falls back on, and the local map a
    ;; minibuffer or a mode binds to have its own keys.
    (only (schemacs editor keymap)
          *current-keymap*
          *default-keymap*
          *special-event-map* define-key)
    ;; The keys the current buffer has of its own - what gives a buffer
    ;; like `*Completions*' its own bindings - and which buffer is current.
    (only (schemacs editor buffer)
          buffer-local-keymap buffer-local-value current-buffer
          mark-active set!mark-active transient-mark-mode)
    (only (schemacs editor simple)
          *last-change-was-undo* *last-command* *this-command*
          *select-active-regions*
          deactivate-mark clear-prefix! pending-uarg place-undo-boundary!
          prefix-echo-pending? show-prefix-echo!
          undo undo-redo update-prefix!)
    (only (schemacs editor editfns)
          barf-if-buffer-read-only insert)
    ;; `uarg->integer' is `callint.c''s, in the command library the
    ;; commands' interactive specs come from.
    (only (schemacs editor command) uarg->integer current-prefix-arg)
    ;; The primary selection the command loop keeps updated while the
    ;; region stays active - the call `keyboard.c:1639' makes.
    (only (schemacs editor select) gui-set-selection
          *saved-region-selection*)
    ;; The region's text, which the update is of.
    (only (schemacs editor editfns) region-beginning region-end)
    ;; `render!' after every key: the loop is what drives the display.
    (only (schemacs editor xdisp) render!)
    ;; The development back door, which the command loop gives its turn
    ;; between keys. A no-op unless `SCHEMACS_REPL' opened it.
    (only (schemacs repl) poll-repl! repl-open?)
    ;; The clock. The read's timeout is shortened to the next timer
    ;; (`read-timeout-or'), and the timers are run when it expires - which
    ;; is how a cursor blink happens while the editor sits still.
    (only (schemacs editor timer)
          *timer-idle-list* *timer-list* cancel-timer current-idle-time
          set!timer-due-at timer-armed? timer-args timer-due-at
          timer-function timer-idle? timer-idle-start! timer-idle-stop!
          timer-mark-run! timer-repeat timer-ripe?)
    ;; `ceiling' and `inexact->exact' are Guile's; the delay is a
    ;; fractional number of seconds and the read wants whole milliseconds.
    (only (guile) ceiling inexact->exact)
    ;; the clock the next timer's delay is measured against
    (only (scheme time) current-second)
    ;; `ignore' is what the special-event-map binds a key that the loop
    ;; must receive but not act on to - the frame's resize.
    (only (schemacs editor subr) ignore)
    )

  (export
   ;; `*current-keymap*' and `*special-event-map*' are not re-exported:
   ;; they are `(schemacs editor keymap)''s, and a library that both
   ;; imports and exports a name gives its importers two of it.
   *recursive-edit-exit*
   *unread-command-events*
   abort-recursive-edit
   command-loop
   dispatch-key-event
   dispatch-input-event
   event-loop
   exit-recursive-edit
   key-event->char
   key-path->char-code
   quoted-insert
   read-quoted-char
   read-key-event
   read-wait-ms
   recursive-edit
   report-command-error!
   signal-quit
   ;; `timer_check' and the read's deadline are the command loop's, so
   ;; they are published the way the rest of the loop is.
   timer-check!
   timer-next-delay
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Key events

    ;; `*esc-pending*' is keyboard.c's own state (its meta-prefix
    ;; resolution), which is why it lives here and not on the frame.
    (define *esc-pending* (make-parameter #f))

    (define *selection-inhibit-update-commands*
      ;; GNU Emacs's `selection-inhibit-update-commands' (keyboard.c:14371):
      ;; "List of commands which should not update the selection.
      ;; Normally, if `select-active-regions' is non-nil and the mark
      ;; remains active after a command (i.e. the mark was not
      ;; deactivated), the Emacs command loop sets the selection to the
      ;; text in the region.  However, if the command is in this list,
      ;; the selection is not updated." The two are `handle-switch-frame'
      ;; and `handle-select-window', window-switching commands of which
      ;; there are none here yet - `memq' on them is harmless.
      ;;--------------------------------------------------------------
      (make-parameter '(handle-switch-frame handle-select-window)))

    (define *unread-command-events* (make-parameter '()))
    ;; ^ GNU Emacs's `unread-command-events': events put back on the
    ;; input, which the next read answers before it asks the display.
    ;; isearch pushes the key that ended a search onto it so the command
    ;; loop runs that key, which is what `isearch-other-control-char'
    ;; does in `isearch.el'. It is keyboard.c's variable - the read's
    ;; first step is `read_char''s - which is why it is here and not on
    ;; the display.

    (define (this-command-name)
      ;; The command's name, as `Vthis_command' is in the C: the symbol
      ;; `define-command' bound the procedure with. A command may have
      ;; renamed itself while it ran - `kill-region' to itself,
      ;; `yank-pop' to `yank' - so the question is asked of
      ;; `*this-command*' after the command, not of the key's action.
      ;;--------------------------------------------------------------
      (let ((cmd (*this-command*)))
        (if (symbol? cmd)
            cmd
            (let ((record (command-record-of cmd)))
              (and record (command-name record))))))

    (define (dispatch-action frame action)
      ;; Run an action reached by a key lookup. The pending prefix
      ;; argument is consumed here, not when the key event arrives, so
      ;; that it survives the intermediate keys of a chord. mg's
      ;; per-command flag rotation happens here too, which is what
      ;; breaks a run of consecutive kills at any command that is not
      ;; itself a kill.
      ;;
      ;; This is also the command loop's undo work: a boundary goes into
      ;; the buffer's undo list before the command runs, so that the
      ;; command's edits form one change group and one undo undoes one
      ;; command. The undo commands themselves are the exception to
      ;; `last-change-was-undo', which is how a redo knows there is
      ;; something to redo.
      ;;--------------------------------------------------------------
      (let* ((uarg (pending-uarg))
             (buffer (current-buffer)))
        ;; Emacs clears its buffer-local deferred flag before every command;
        ;; edits and region commands may set it again while they run.
        (set!text-editor-deactivate-mark! buffer #f)
        ;; `this_command' is what is running - and a command may *change*
        ;; it (`kill-region' renames itself to itself, `yank-pop' says
        ;; `yank'), which is why the promotion to `last-command' reads it
        ;; again after the command rather than using ACTION.
        (*this-command* action)
        (place-undo-boundary! action)
        (unless (or (eq? action undo) (eq? action undo-redo))
          (*last-change-was-undo* #f))
        (clear-prefix!)
        (set!frame-message frame "")
        ;; `pre-command-hook', run here because Emacs runs it here: after
        ;; `this-command' is set and before the command itself
        ;; (`keyboard.c': "Vthis_command = cmd; ... safe_run_hooks
        ;; (Qpre_command_hook)"). The blinking cursor is its one user -
        ;; the first key you press after a pause is what stops the blink
        ;; and gives you a solid cursor to type at.
        (run-pre-command-hook!)
        ;; A command that cannot do what it was asked - editing a
        ;; read-only buffer, say - signals an error, and the command
        ;; loop reports it in the echo area and carries on, as GNU Emacs
        ;; does. Letting it out would take the editor down with it.
        (guard (ex (else (report-command-error! frame ex)))
          (cond
           ((command-type? action)
            ;; A command declares with its interactive spec whether it
            ;; takes the universal argument; the default (#f) takes none.
            (if (command-interactive-spec action)
                (run-command action uarg)
                (run-command action)))
           ((procedure? action)
            ;; A procedure the keymap holds. It may be a
            ;; `define-command' - a bare procedure whose command record sits
            ;; in the obarray - in which case it is run like the record
            ;; it belongs to, so the interactive specification is
            ;; honoured; otherwise it is a plain procedure to call.
            (let ((record (command-record-of action)))
              (if record
                  (if (command-interactive-spec record)
                      (run-command record uarg)
                      (run-command record))
                  (action))))
           (else (error "not a command" action))))
        ;; Commands such as `kill-ring-save' set the buffer's deferred
        ;; `deactivate-mark' flag. Apply it after the command, as Emacs does,
        ;; so later motion does not extend the copied region. Not
        ;; deactivating - the mark still active - is keyboard.c:1615's
        ;; else-branch: with `select-active-regions' on, PRIMARY is set to
        ;; the region after every command, which is how a selection stays
        ;; current for other programs while the region is being adjusted.
        ;; The conditions are the C's: `window-system', or the tty's
        ;; `tty-select-active-regions' with `xterm--set-selection' - both
        ;; `display-selections-p' - with the mark really set
        ;; (Bug#7044's check; the mark is the buffer's own here), Transient
        ;; Mark mode on, and the command not on the inhibit list. The
        ;; region text is what `region-extract-function''s default makes,
        ;; which `deactivate-mark' makes too, and an empty selection is
        ;; not set. `post-select-region-hook' is not run - no user of it.
        (when (mark-active)
          (if (text-editor-deactivate-mark buffer)
              (begin
                (set!text-editor-deactivate-mark! buffer #f)
                (deactivate-mark))
              (when (and (display-selections-p)
                         (*select-active-regions*)
                         (transient-mark-mode)
                         (not (memq (this-command-name)
                                    (*selection-inhibit-update-commands*))))
                ;; `buffer' and not `(current-buffer)' or
                ;; `(current-editor)': this command loop bound it once at
                ;; the top, which is the C's `current_buffer' for the
                ;; whole command (keyboard.c:1615-1647), and
                ;; `region-beginning'/`region-end' answer against the
                ;; same buffer. Re-reading it here asks a *different*
                ;; question - a command may have moved the current
                ;; buffer, and the answer at this point is not
                ;; necessarily the one the positions were computed in.
                (let ((txt (text-editor-copy-string
                            buffer
                            (- (region-beginning) 1)
                            (- (region-end) 1))))
                  (unless (= 0 (string-length txt))
                    ;; Don't set empty selections.
                    (gui-set-selection 'PRIMARY txt)))))
          ;; `Vsaved_region_selection = Qnil' (keyboard.c:1647) - spent
          ;; after every command the mark was active through.
          (*saved-region-selection* #f))
        (*last-command* (*this-command*))))

    (define (report-command-error! frame ex)
      ;; ... including a quit, which Emacs's command loop reports as
      ;; "Quit" rather than as an error.
      ;;--------------------------------------------------------------
      ;; Show in the echo area what went wrong, the way GNU Emacs's
      ;; command loop does with the errors its commands signal. Many
      ;; errors arrive as a format string with its arguments kept apart
      ;; ("Wrong type argument in position ~A: ~S"), so the text is put
      ;; together here; Emacs shows the formatted message too.
      ;;--------------------------------------------------------------
      (set!frame-message
       frame
       (cond
        ((quit-condition? ex) "Quit")
        ((error-object? ex)
         (let ((message (error-object-message ex))
               (irritants (error-object-irritants ex)))
           (if (and (list? irritants)
                    (string-index message #\~))
               (apply format #f message irritants)
               message)))
        (else "error"))))

    ;; `special-event-map' is in `(schemacs editor keymap)', beside
    ;; `*default-keymap*' - which Emacs also creates in `keymap.c', and
    ;; which this tree put in the leaf for the same reason: the libraries
    ;; that own the commands bind into it, and they cannot import this
    ;; library.

    ;; The frame's resize: Emacs has no resize key - a frame resize is
    ;; handled by redisplay re-framing (`window-size-change-functions'),
    ;; and the event only has to be dispatched for this loop to redraw,
    ;; which is what `render!' does by re-tiling. Emacs binds keys that
    ;; must be received but not acted on to `ignore' (`bindings.el:1757',
    ;; `[sigusr1]' in `special-event-map'), which is what this is.
    (define-key *special-event-map* (list "resize") ignore)

    ;; `*default-keymap*' - which Emacs also creates in `keymap.c', and
    ;; which this tree put in the leaf for the same reason: the libraries
    ;; that own the commands bind into it, and they cannot import this
    ;; library.

    (define (lookup-keymaps)
      ;; What a key sequence is looked up in, in precedence order. GNU
      ;; Emacs's `read_key_sequence' searches, in order: the current
      ;; buffer's own map (`current-local-map', the keymap a buffer has of
      ;; its own) and then `global-map'. `NEW-MODAL-LOOKUP-STATE' takes the
      ;; list.
      ;;
      ;; The buffer's map comes first, which is what gives a `*Buffer
      ;; List*' or a `*Completions*' buffer its own keys - the reason the
      ;; buffer has a keymap slot at all. `*CURRENT-KEYMAP*' is the map a
      ;; *mode* binds around the buffer it is reading: the minibuffer binds
      ;; its own there while it reads, which in Emacs is the same thing as
      ;; the minibuffer's buffer having a local map, since the minibuffer
      ;; is the current buffer while it is read.
      ;;
      ;; The keymaps are *shared* with the list, so a binding made after
      ;; this is built is still found; what is fixed is the list itself.
      ;; That is why a buffer's map needs no copy of the global one - the
      ;; precedence is settled per lookup rather than once at load.
      ;;--------------------------------------------------------------
      (let ((buffer-keys (buffer-local-keymap (current-buffer)))
            (mode-keys (*current-keymap*)))
        ;; `special-event-map' first: `keyboard.c:3113' looks the window
        ;; system's events up in it before the ordinary maps, which is how
        ;; `(delete-frame (FRAME))' runs its handler rather than being read
        ;; as an ordinary key.
        (cond ((and buffer-keys mode-keys)
               (list *special-event-map* buffer-keys mode-keys *default-keymap*))
              (buffer-keys (list *special-event-map* buffer-keys *default-keymap*))
              (mode-keys (list *special-event-map* mode-keys *default-keymap*))
              (else (list *special-event-map* *default-keymap*)))))

    (define (dispatch-key-event frame path)
      ;; Dispatch one key event through the modal keymap lookup. The
      ;; modal lookup state persists across events while a chord
      ;; (such as C-x C-c) is being entered. C-u and digits are
      ;; consumed as prefix arguments before the keymap lookup; the
      ;; pending prefix is left alone for the rest of the chord and is
      ;; consumed by `dispatch-action' when a command finally runs.
      ;;--------------------------------------------------------------
      (if (update-prefix! path)
          ;; C-u or a prefix digit was consumed. It is a command in
          ;; its own right, so like any other command it breaks a run
          ;; of consecutive kills - by *being* the last command, which
          ;; is what `kill-region' asks about.
          (begin
            (*last-command* 'kill-region)
            (set!frame-keymap-state frame #f))
          ;; any other key: continue (or start) the keymap lookup
          (begin
            (let ((state
                   (or (frame-keymap-state frame)
                       (km:new-modal-lookup-state (lookup-keymaps)))))
              ;; NOTE: the state must be stored on the frame BEFORE the
              ;; lookup step, because commands dispatched by the step
              ;; (such as `self-insert-command`) read the key index of
              ;; the chord from the frame's state.
              (set!frame-keymap-state frame state)
              (let ((result
                     (km:modal-lookup-state-step!
                      state (km:keymap-index path)
                      (lambda (full-path action)
                        (dispatch-action frame action) #f)
                      (lambda (full-path action) #t)
                      (lambda (full-path)
                        ;; An undefined key ends the chord: the pending
                        ;; prefix is discarded with it, the way GNU
                        ;; Emacs drops a prefix argument when the key
                        ;; sequence it precedes is not a command.
                        (clear-prefix!)
                        (set!frame-message
                         frame
                         (string-append
                          "; undefined key: "
                          (call-with-port (open-output-string)
                            (lambda (port)
                              (write (km:keymap-index->list full-path) port)
                              (get-output-string port)))))))))
                (set!frame-keymap-state
                 frame (and result state)))))))

    (define (dispatch-input-event frame ev)
      ;; Handle one input event: ask the display what it is, and dispatch
      ;; the key it names, applying the Emacs ASCII protocol where ESC
      ;; prefixes the next key with the meta modifier. An event the
      ;; display has no name for is reported in the echo area.
      ;;--------------------------------------------------------------
      (let* ((path (key-event->keymap-path (current-display) ev))
             ;; The event the command is handed, which Emacs reads from
             ;; the key sequence the loop recorded (`callint.c:287') and
             ;; `(interactive "e")' takes from it (`callint.c:608'). A
             ;; window-system event is the list `make_lispy_event' built -
             ;; `(delete-frame (FRAME))' and `(focus-in (FRAME))' - with
             ;; the frame as its argument, and an ordinary key's event is
             ;; the key itself.
             (event (if (and (pair? path) (string? (car path)))
                        (list (string->symbol (car path)) (list frame))
                        path)))
        (cond
         ;; ESC prefixes the next key with the meta modifier
         ((and (char? ev) (char=? ev #\esc))
          (*esc-pending* #t))
         ((and path (*esc-pending*))
          (*esc-pending* #f)
          (dispatch-key-event frame (cons 'meta path))
          )
         (path
          (*esc-pending* #f)
          (parameterize ((*this-event* event))
            (dispatch-key-event frame path)))
         (else
          (*esc-pending* #f)
          (set!frame-message
           frame
           (string-append
            "; unhandled event: "
            (cond ((integer? ev) (number->string ev))
                  ((char? ev) (string ev))
                  (else "#f"))))))))

    ;;----------------------------------------------------------------
    ;; The command loop, and recursive edits
    ;;
    ;; GNU Emacs's command loop: read a key, run the command it names,
    ;; redraw, and repeat. The important thing is that it can be
    ;; *re-entered* rather than copied: a minibuffer is this same loop
    ;; called again with a different keymap and a different current
    ;; buffer, which is Emacs's `recursive-edit'. Everything the loop
    ;; does for a command - the undo boundary before it, the kill flag
    ;; rotation, error reporting, `last-command' - a prompt gets for
    ;; free, instead of each hand-rolled reader re-implementing RET, C-g
    ;; and end of input for itself.
    ;;
    ;; Leaving a recursive edit is a `throw' in Emacs: `exit-minibuffer'
    ;; does `(throw 'exit nil)' (minibuffer.el:3048), and a *quit* is
    ;; `(throw 'exit <a function>)' (minibuffer.el:3060) - the function
    ;; is run when the recursive edit has been left, so the quit signal
    ;; is raised in the CALLER's context and travels out past the
    ;; minibuffer to the command loop, abandoning the command that asked
    ;; the question. Continuations do the same job here, and a quit is
    ;; that same trick: the loop returns a thunk, and the caller runs it.
    ;;------------------------------------------------------------------

    (define-record-type <quit-condition>
      (make-quit-condition) quit-condition?)

    (define (signal-quit)
      ;; Signal that the user quit, the way C-g does: GNU Emacs's
      ;; `(signal 'quit nil)'.
      ;;--------------------------------------------------------------
      (raise (make-quit-condition)))

    (define *recursive-edit-exit* (make-parameter #f))

    (define message-read-timeout
      ;; How long the key read may wait when the echo area holds nothing
      ;; that changes on its own. Giving up keeps the read from blocking
      ;; forever on a message that has to be taken down.
      ;;--------------------------------------------------------------
      100)

    (define (key-event? ev)
      ;; Whether a read produced a key. The driver's `read-input-event'
      ;; already answers `#f' for a timed-out read, a non-blocking read
      ;; with no input, and the end of input alike, so a key is a
      ;; character or an integer (a keypad code) and nothing else.
      ;;
      ;; The distinction this loses is end of input against a timeout.
      ;; It is recovered by the caller from the *timeout*: a blocking
      ;; read only comes back with nothing at the end of input, so the
      ;; editor is left then and not otherwise.
      ;;--------------------------------------------------------------
      (or (char? ev) (integer? ev)))

    (define (read-key-event timeout)
      ;; Read one input event for the command loop, TIMEOUT milliseconds
      ;; allowed - a negative TIMEOUT blocks. An event put back on
      ;; `*unread-command-events*' is answered first, which is how the
      ;; loop runs a key a command gave back to it; otherwise the display
      ;; is asked for one. GNU Emacs's `read_char' takes the same first
      ;; step.
      ;;
      ;; This is the read every key comes through, whatever asked for it:
      ;; the command loop, isearch's own reading, and the minibuffer's
      ;; y-or-n question all call it, so a pushed-back key reaches
      ;; whichever of them reads next.
      ;;--------------------------------------------------------------
      (let ((unread (*unread-command-events*)))
        (if (null? unread)
            (let ((ev (read-input-event (current-display) timeout)))
              ev)
            (begin
              (*unread-command-events* (cdr unread))
              (car unread)))))

    ;;----------------------------------------------------------------
    ;; Timers
    ;;
    ;; `timer_check', which is GNU Emacs's `keyboard.c''s and not
    ;; `timer.el''s: the list of timers is `timer.el''s, but *running* the
    ;; ripe ones and putting the repeating ones back is the command
    ;; loop's, and it runs from `read_char''s wait - here from this loop,
    ;; which is what waits in this editor.
    ;;------------------------------------------------------------------

    (define (timer-next-delay)
      ;; GNU Emacs's `timer_check' as the wait uses it: how many seconds
      ;; the editor may sleep before the next timer is due, or #f when
      ;; none is. A timer that cannot wake the read can only run when a
      ;; key happens to arrive, which for a blinking cursor is never.
      ;;--------------------------------------------------------------
      (let ((idle (current-idle-time)))
        (let loop ((timers (append (*timer-list*)
                                   (if idle (*timer-idle-list*) '())))
                   (least #f))
          (cond
           ((null? timers) least)
           (else
            (let* ((timer (car timers))
                   (delay (if (timer-idle? timer)
                              (and (timer-armed? timer)
                                   (- (timer-due-at timer) idle))
                              (- (timer-due-at timer) (current-second)))))
              (loop (cdr timers)
                    (if (and delay (or (not least) (< delay least)))
                        delay least))))))))

    (define (timer-check!)
      ;; GNU Emacs's `timer_check': run every timer that is ripe. It
      ;; answers whether any ran rather than, as the C does, the time of
      ;; the next one - because this editor's redisplay is the command
      ;; loop's, so the caller has to be told to draw again when a timer
      ;; changed what should be on the screen. That is what makes a cursor
      ;; blink visible without a keypress.
      ;;
      ;; The lists are walked as *copies*, as Emacs copies them too, so
      ;; that a timer which adds another one (or itself) cannot make this
      ;; loop run for ever on a timer that is ripe the moment it is added.
      ;;--------------------------------------------------------------
      (let ((idle (current-idle-time))
            (ran? #f))
        (let loop ((timers (append (reverse (*timer-list*))
                                   (if idle
                                       (reverse (*timer-idle-list*))
                                       '()))))
          (when (pair? timers)
            (let ((timer (car timers)))
              (if (timer-ripe? timer idle)
                  (begin
                    (set! ran? #t)
                    (cond
                     ;; An idle timer stays on its list but is marked as
                     ;; having run, so it does not run again until the
                     ;; editor has been idle afresh; a one-shot one goes.
                     ((timer-idle? timer)
                      (if (timer-repeat timer)
                          (timer-mark-run! timer)
                          (cancel-timer timer)))
                     (else
                      ;; A repeating timer is taken off and put back at
                      ;; its new time; a one-shot one is simply gone.
                      ;; Either way it is cancelled first, so that a timer
                      ;; whose function cancels it does not end up on the
                      ;; list twice. The next time is measured from when
                      ;; it *should* have run, not from now, which is
                      ;; Emacs's `timer-inc-time' - so a repeating timer
                      ;; does not drift later and later.
                      (cancel-timer timer)
                      (when (timer-repeat timer)
                        (set!timer-due-at
                         timer (+ (timer-due-at timer) (timer-repeat timer)))
                        (*timer-list*
                         (append (*timer-list*) (list timer))))))
                    (apply (timer-function timer) (timer-args timer))))
              (loop (cdr timers)))))
        ran?))

    (define (read-timeout-or message-timeout timer-delay cap)
      ;; The timeout the command loop's read should be given: the one it
      ;; would have had, shortened to the next timer when one is due
      ;; sooner. A negative timeout blocks, so it is "no timeout at all"
      ;; rather than a number to compare.
      ;;
      ;; This is the whole reason a timer can fire at all: a read that
      ;; blocks for ever cannot be woken by a clock, so the loop has to
      ;; ask how long it may sleep. Emacs's `read_char' computes its wait
      ;; from `timer_check' the same way.
      ;;--------------------------------------------------------------
      (let ((timer-ms (and timer-delay
                           (inexact->exact
                            (max 0 (ceiling (* 1000 timer-delay)))))))
        (let ((want (cond ((not timer-ms) message-timeout)
                          ((< message-timeout 0) timer-ms)
                          (else (min message-timeout timer-ms)))))
          ;; a cap applies to a negative (blocking) timeout too: that is
          ;; the case it exists for
          (cond ((not cap) want)
                ((< want 0) cap)
                (else (min want cap))))))

    (define (read-wait-ms)
      ;; How long an interactive read may block for, in milliseconds, or a
      ;; negative number for "until an event arrives".
      ;;
      ;; It is the command loop's own computation, published because a
      ;; command that reads its *own* keys has to wait the same way and
      ;; must not drift from it. `isearch' is that command.
      ;;
      ;; The cap is the whole point: a read that blocks for ever gives
      ;; nothing else in the process a turn. On a terminal the read blocks
      ;; in `getch' with nothing to poll, so the development REPL never
      ;; answers between keys; on Gtk the *pump* that waits for a key is
      ;; the same code that polls, and a wait that never comes back is a
      ;; wait in which no key is ever seen - which is what made an
      ;; incremental search on Gtk look like it had hung the moment it
      ;; started, with every key doing nothing, `C-g' included.
      ;;--------------------------------------------------------------
      (read-timeout-or -1 #f (and (repl-open?) 100)))

    (define (command-loop frame)
      ;; Read key events and dispatch them, until something leaves this
      ;; level with `exit-recursive-edit' - or, at the outermost level,
      ;; until the editor is quit.
      ;;
      ;; The read is given a timeout while a message that times out is
      ;; on the screen, and none otherwise. That is this editor's stand
      ;; in for the timer GNU Emacs arms in `minibuffer-message': with
      ;; no timeout the read would block in `getch' and the message
      ;; would stay up until the user typed, which is how "No match"
      ;; used to sit in the echo area for as long as you looked at it.
      ;; The timeout costs nothing while nothing is pending, which is
      ;; why it is armed and disarmed rather than always on - and it is
      ;; why end of input is still noticed at once.
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (exit)
         (parameterize ((*recursive-edit-exit* exit))
           ;; draw before the first key is read: a prompt that appears only
           ;; after a key is typed looks like nothing happened
           (render! frame)
           (let loop ()
             ;; Give the development REPL a turn before waiting for a key.
             ;; A no-op unless `SCHEMACS_REPL' opened it. A terminal's read
             ;; blocks in `getch' with nothing to hang the poll on, so
             ;; between keys is the most a terminal can offer; the GTK
             ;; display polls in its own loop, where it is idle far more
             ;; often (`pgtk.sld''s `pgtk-read-event').
             (poll-repl!)
             ;; Arm the mode that blinks the cursor, if the frame can and
             ;; it is not armed already. Emacs does this from its
             ;; focus-change hook; there is no such hook here, and this
             ;; loop is the thing that always runs.
             (blink-cursor-check)
             ;; The editor is about to wait, which is what "idle" means;
             ;; an idle timer counts from here.
             (timer-idle-start!)
             (let ((want (read-timeout-or
                          (if (or (frame-message-expiry frame)
                                  ;; a prefix argument owes the echo
                                  ;; area a description, and it is owed
                                  ;; once the keyboard has been quiet
                                  ;; for `echo-keystrokes' - so the read
                                  ;; cannot block while that is owed
                                  (prefix-echo-pending?))
                              message-read-timeout
                              -1)
                          (timer-next-delay)
                          ;; With the development REPL open the wait is
                          ;; capped - see `read-wait-ms', which is the
                          ;; same computation `isearch' waits by.
                          (and (repl-open?) 100))))
             (let ((ev (read-key-event want)))
               ;; A *key* means the editor is not idle any more. A timeout
               ;; does not: nothing arrived, which is what idleness is.
               (when (key-event? ev) (timer-idle-stop!))
               ;; A timer that was due has now run. Redraw when one did,
               ;; which is what makes a cursor blink visible without a
               ;; keypress: Emacs's `internal-show-cursor' asks for a
               ;; redisplay and this is where that lands here.
               (when (timer-check!) (render! frame))
               (cond
                  ((key-event? ev)
                   (dispatch-input-event frame ev)
                   (render! frame))
                  ;; Nothing to read on a *blocking* read is the end of
                  ;; input - the read answers #f for that too - so leave
                  ;; the editor. "Blocking" is the test, and it has to be
                  ;; the test rather than "no message is pending": a read
                  ;; is also armed when a *timer* is due, and a timer that
                  ;; is due must not read as the end of the input.
                  ((< want 0)
                   (let ((quit (frame-quit-cont frame)))
                     (when quit (quit 'eof))))
                  ;; A timed read that found nothing: take down a message
                  ;; whose time is up, show the prefix description if its
                  ;; second has come, and draw again if either did. A
                  ;; timer that was due has already been run and drawn
                  ;; above.
                  (else
                   (let ((drawn? #f))
                     (when (frame-message-expired? frame)
                       (set!frame-message frame "")
                       (set!frame-message-expiry frame #f)
                       (set! drawn? #t))
                     ;; the prefix description, if its second has come
                     (let ((before (frame-message frame)))
                       (show-prefix-echo!)
                       (when (not (eq? before (frame-message frame)))
                         (set! drawn? #t)))
                     (when drawn? (render! frame))))))
               (loop)))))))

    (define (recursive-edit frame)
      ;; Enter a nested command loop and return what leaving it produced:
      ;; either the value `exit-recursive-edit' was given, or a thunk
      ;; that signals quit (which the caller runs, so that the signal is
      ;; raised outside this edit - see the note above). The caller is
      ;; expected to have bound `*current-keymap*' and `*minibuffer*'.
      ;;
      ;; A key chord cannot be half-entered when a recursive edit begins
      ;; (the command's own key finished the chord), but the pending
      ;; lookup state is saved and restored all the same, so that a
      ;; nested loop cannot inherit or clobber the outer one's.
      ;;--------------------------------------------------------------
      (let ((outer-state (frame-keymap-state frame)))
        (set!frame-keymap-state frame #f)
        (let ((result (command-loop frame)))
          (set!frame-keymap-state frame outer-state)
          result)))

    (define exit-recursive-edit
      ;; Leave the innermost recursive edit with a value. GNU Emacs's
      ;; `exit-recursive-edit'.
      ;;--------------------------------------------------------------
      (case-lambda
       (() (exit-recursive-edit #f))
       ((value)
        (let ((exit (*recursive-edit-exit*)))
          (if exit
              (exit value)
              (error "Not in a recursive edit"))))))

    ;;----------------------------------------------------------------
    ;; Quoted insertion
    ;;
    ;; GNU Emacs's `quoted-insert' (C-q) and the `read-quoted-char' it
    ;; reads with are simple.el's, but they are here and not there for
    ;; the import graph's sake: they read a KEY, and reading a key is
    ;; `read-key-event''s, which simple.sld cannot import - this
    ;; library imports simple, not the other way around. It is the
    ;; same wall `abort-recursive-edit' is the other side of.
    ;;------------------------------------------------------------------

    (define *read-quoted-char-radix*
      ;; GNU Emacs's `read-quoted-char-radix' (simple.el): "Radix for
      ;; `quoted-insert' and other uses of `read-quoted-char'.
      ;; Supported radix values are 8, 10 and 16."
      ;;--------------------------------------------------------------
      (make-parameter 8))

    (define (key-event->char ev)
      ;; EV, a key the driver's read has answered, as the CHARACTER it
      ;; stands for - or #f when it does not stand for one.
      ;;
      ;; The two drivers answer a key in different forms, and this is the
      ;; seam between them. A terminal folds the modifiers into the byte,
      ;; so `read-input-event' answers a printable key as the character
      ;; and a control key as its code - already the form a command that
      ;; reads its own keys wants. Gtk answers *every* key as the integer
      ;; `(modifiers . keysym)' (`pgtk-encode-event'), which stands for a
      ;; character only after the same decode the command loop does:
      ;; `key-event->keymap-path' names the path and `key-path->char-code'
      ;; reads the character out of it - the translation
      ;; `read-quoted-char' already uses.
      ;;
      ;; A command that reads its own keys must go through this or it will
      ;; work on a terminal and not on Gtk. `isearch' did not, and every
      ;; key on Gtk - `RET' and `C-g' included - matched none of its
      ;; tests and was thrown away.
      ;;--------------------------------------------------------------
      (cond
       ((char? ev) ev)
       ((not (integer? ev)) #f)
       (else
        (let ((path (guard (e (#t #f))
                      (key-event->keymap-path (current-display) ev))))
          ;; a special code - a resize, a focus change - has no key path
          ;; and a named key (an arrow, a function key) has one that is
          ;; not a character; both answer #f, and the caller ignores them
          ;; as it always did
          (let ((code (and path (key-path->char-code path))))
            (and code (< 0 code 256) (integer->char code)))))))

    (define (key-path->char-code path)
      ;; The key decode's inverse: the CHARACTER CODE a single-key path
      ;; stands for, or #f when the path is not one key - which is what
      ;; `read-quoted-char''s translation (`local-function-key-map''s,
      ;; which maps the TAB key to control-I and friends) comes to. A
      ;; control-modified letter is its ASCII control code; a plain
      ;; character is itself; a meta-modified one is the C's
      ;; 128-set form; a named key (an arrow, a function key) is not a
      ;; character at all.
      ;;--------------------------------------------------------------
      (cond
       ((and (= 1 (length path)) (char? (car path)))
        (char->integer (car path)))
       ((and (= 2 (length path)) (eq? 'ctrl (car path)) (char? (cadr path)))
        (let ((c (cadr path)))
          (cond
           ;; the lowercase letters the decoder spells a control with
           ;; - the terminal's byte 7 is `\(ctrl #\g)' - and the
           ;; uppercase spellings, which run @ through _
           ((and (char<=? #\a c #\z))
            (- (char->integer c) 96))
           ((and (char<=? #\@ c #\_))
            (- (char->integer c) 64))
           (else #f))))
       ((and (= 2 (length path)) (eq? 'meta (car path)) (char? (cadr path)))
        (+ 128 (char->integer (cadr path))))
       (else #f)))

    (define (read-quoted-char . args)
      ;; GNU Emacs's `read-quoted-char' (simple.el:986): "Like
      ;; `read-char', but do not allow quitting. Also, if the first
      ;; character read is an octal digit, we read any number of octal
      ;; digits and return the specified character code. Any nondigit
      ;; terminates the sequence. If the terminator is RET, it is
      ;; discarded; any other terminator is used itself as input."
      ;; The optional PROMPT is what the echo area shows with a `-'
      ;; after it. Quitting is inhibited for the FIRST character only -
      ;; which is why C-q C-g inserts a ^G - and a C-g later in the
      ;; digits quits, as the C's `inhibit-quit' binding says.
      ;;--------------------------------------------------------------
      (let* ((prompt (if (pair? args) (car args) #f))
             (frame (*current-frame*))
             (radix (*read-quoted-char-radix*))
             (done #f)
             (first #t)
             (code 0))
        (parameterize ((*echo-area-buffer* (new-text-editor))
                       (*echo-area-prompt*
                        (if prompt (string-append prompt "-") "")))
          (render! frame)
          (let loop ()
            (if done
                code
                (let* ((ev (read-key-event -1))
                       (path (key-event->keymap-path (current-display) ev))
                       (code-read (key-path->char-code path)))
                  (cond
                   ;; a C-g after the first character quits, as the
                   ;; C's quitting is enabled once `first' is past
                   ((and (not first)
                         (= 2 (length path))
                         (eq? 'ctrl (car path))
                         (char=? (cadr path) #\g))
                    (signal-quit))
                   ;; a digit of the radix: accumulate, and echo the
                   ;; digit after the prompt
                   ((and code-read
                         (or (char-numeric? (integer->char code-read))
                             (and (= 16 radix)
                                  (char<=? #\a (integer->char code-read) #\f))
                             (and (<= 10 radix)
                                  (char<=? #\a (integer->char code-read)
                                           (integer->char (+ 87 (- radix 10)))))))
                    ;; ^ Elisp's second branch is the letters a-F up
                    ;; to the radix, for 16: `(and (<= ?a (downcase
                    ;; translated)) (< (downcase translated) (+ ?a
                    ;; -10 (min 36 read-quoted-char-radix))))'
                    (set! code (+ (* code radix)
                                  (- code-read (char->integer #\0))))
                    (set! first #f)
                    (parameterize ((*echo-area-prompt*
                                    (string-append
                                     (if prompt prompt "")
                                     (if first "" " ")
                                     (string (integer->char code-read)))))
                      (render! frame))
                    (loop))
                   ;; RET after the first digit terminates and is
                   ;; discarded; before that it is the character
                   ((and (not first)
                         (= 2 (length path))
                         (eq? 'ctrl (car path))
                         (char=? (cadr path) #\m))
                    (set! done #t)
                    (loop))
                   ;; any other terminator after the first digit is
                   ;; used itself as input: pushed back for the
                   ;; caller, and its code read
                   ((not first)
                    (*unread-command-events* (cons ev (*unread-command-events*)))
                    (set! done #t)
                    (loop))
                   ;; the first character, not a digit: it is the
                   ;; answer - quitting inhibited, so a C-g is code 7
                   ((and code-read)
                    (set! code code-read)
                    (set! done #t)
                    (loop))
                   (else
                    ;; a key that is not a character at all (an
                    ;; arrow, a frame resize): ask again, as the C's
                    ;; `(cond ((null translated)))' does
                    (loop)))))))))

    (define-command (abort-recursive-edit)
      ;; Leave the innermost recursive edit and signal quit, so the
      ;; command that asked the question is abandoned: GNU Emacs's
      ;; `abort-recursive-edit', which is keyboard.c's own - a function
      ;; any Lisp can call, and a command at the same time, which is
      ;; why the minibuffer map can bind it directly. It is
      ;; `exit-recursive-edit' with a thunk whose call signals, exactly
      ;; as Emacs's `minibuffer-quit-recursive-edit' does.
      "Quit the innermost recursive edit and the command that asked the question."
      (interactive)
      (exit-recursive-edit signal-quit))

    (define-command (quoted-insert arg)
      ;; GNU Emacs's `quoted-insert' (simple.el:1047): "Read next input
      ;; character and insert it. This is useful for inserting control
      ;; characters. With argument, insert ARG copies of the
      ;; character." The `*' of its interactive spec is the read-only
      ;; check, made first; the overwrite-mode branches are not ported
      ;; (no overwrite mode here).
      "Read next input character and insert it.
This is useful for inserting control characters.
With argument, insert ARG copies of the character."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (barf-if-buffer-read-only)
      (let* ((code (read-quoted-char))
             (char (integer->char code)))
        (let loop ((left arg))
          (when (> left 0)
            (insert char)
            (loop (- left 1))))
        #f))

    (define (event-loop frame)
      ;; The outermost command loop: it runs until the editor is quit.
      ;;--------------------------------------------------------------
      (parameterize ((*current-frame* frame)
                     (*current-keymap* *default-keymap*))
        (render! frame)
        (call/cc
         (lambda (k)
           (set!frame-quit-cont frame k)
           (command-loop frame)))))

    (define-key *default-keymap* (list (list 'ctrl #\q)) quoted-insert)

    ))
