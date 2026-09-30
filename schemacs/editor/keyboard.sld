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
    ;; Only the names used: guile-ncurses exports a `define-key\' of its
    ;; own, which would collide with the keymap library's.
    ;; Decoding a raw event into a keymap path is the terminal driver's
    ;; business now; this loop reads what it decoded.
    (only (schemacs editor term) ncurses-key->keymap-path)
    (only (schemacs editor engine)
          text-editor-deactivate-mark set!text-editor-deactivate-mark!)
    (only (schemacs editor command)
          command-interactive-spec command-record-of command-type? defcommand
          run-command)
    ;; Reading a key is the display's job - `getch' and its timeout
    ;; belong to the terminal driver, and this loop calls through the
    ;; interface.
    (only (schemacs editor dispnew) current-display read-input-event)
    (only (schemacs editor frame)
          *current-frame* frame-keymap-state
          frame-message frame-message-expired?
          frame-message-expiry
          frame-quit-cont
          set!frame-keymap-state set!frame-message
          set!frame-message-expiry
          set!frame-quit-cont)
    ;; The global map the lookup falls back on, and the local map a
    ;; minibuffer or a mode binds to have its own keys.
    (only (schemacs editor keymap)
          *current-keymap*
          *default-keymap*)
    ;; The keys the current buffer has of its own - what gives a buffer
    ;; like `*Completions*' its own bindings - and which buffer is current.
    (only (schemacs editor buffer)
          buffer-local-keymap buffer-local-value current-buffer
          mark-active set!mark-active)
    (only (schemacs editor simple)
          *last-change-was-undo* *last-command* *this-command*
          deactivate-mark clear-prefix! pending-uarg place-undo-boundary!
          prefix-echo-pending? show-prefix-echo!
          undo undo-redo update-prefix!)
    ;; `render!' after every key: the loop is what drives the display.
    (only (schemacs editor xdisp) render!)
    )

  (export
   ;; `*current-keymap*' is not re-exported: it is `(schemacs editor
   ;; keymap)''s, and a library that both imports and exports a name gives
   ;; its importers two of it.
   *recursive-edit-exit*
   abort-recursive-edit
   command-loop
   dispatch-key-event
   dispatch-ncurses-event
   event-loop
   exit-recursive-edit
   ncurses-key->keymap-path
   recursive-edit
   report-command-error!
   signal-quit
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Key events

    ;; `*esc-pending*' is keyboard.c's own state (its meta-prefix
    ;; resolution), which is why it lives here and not on the frame.
    (define *esc-pending* (make-parameter #f))

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
            ;; `defcommand' - a bare procedure whose command record sits
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
        ;; so later motion does not extend the copied region.
        (when (text-editor-deactivate-mark buffer)
          (set!text-editor-deactivate-mark! buffer #f)
          (deactivate-mark))
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
        (cond ((and buffer-keys mode-keys)
               (list buffer-keys mode-keys *default-keymap*))
              (buffer-keys (list buffer-keys *default-keymap*))
              (mode-keys (list mode-keys *default-keymap*))
              (else (list *default-keymap*)))))

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

    (define (dispatch-ncurses-event frame ev)
      ;; Handle one ncurses key event: translate it to a keymap path and
      ;; dispatch it, applying the Emacs ASCII protocol where ESC
      ;; prefixes the next key with the meta modifier. Events that
      ;; cannot be translated are reported in the echo area.
      ;;--------------------------------------------------------------
      (let ((path (ncurses-key->keymap-path ev)))
        (cond
         ;; ESC prefixes the next key with the meta modifier
         ((and (char? ev) (char=? ev #\esc))
          (*esc-pending* #t))
         ((and path (*esc-pending*))
          (*esc-pending* #f)
          (dispatch-key-event frame (cons 'meta path))
          )
         ((and path (eq? 'resize (car path)))
          (set!frame-message frame "")
          (*esc-pending* #f))
         (path
          (*esc-pending* #f)
          (dispatch-key-event frame path))
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
             (let ((want (if (or (frame-message-expiry frame)
                                 ;; a prefix argument owes the echo
                                 ;; area a description, and it is owed
                                 ;; once the keyboard has been quiet
                                 ;; for `echo-keystrokes' - so the read
                                 ;; cannot block while that is owed
                                 (prefix-echo-pending?))
                             message-read-timeout
                             -1)))
             (let ((ev (read-input-event (current-display) want)))
                 (cond
                  ;; Nothing to read, with a message pending that times
                  ;; out: take the message down once its time is up and
                  ;; draw again. Until then there is nothing to do - and
                  ;; nothing to read is also what the end of input looks
                  ;; like, which is why the editor is not left here.
                  ((and (not (key-event? ev))
                        (or (frame-message-expiry frame)
                            (prefix-echo-pending?)))
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
                     (when drawn? (render! frame))))
                  ;; Nothing to read on a *blocking* read is the end of
                  ;; input - guile-ncurses answers #f for that too - so
                  ;; leave the editor.
                  ((not (key-event? ev))
                   (let ((quit (frame-quit-cont frame)))
                     (when quit (quit 'eof))))
                  (else
                   (dispatch-ncurses-event frame ev)
                   (render! frame))))
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

    (defcommand (abort-recursive-edit)
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

    ))
