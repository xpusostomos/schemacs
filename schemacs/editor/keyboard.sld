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
    (only (ncurses curses)
          ERR KEY_BACKSPACE KEY_DC KEY_DOWN KEY_END KEY_HOME KEY_LEFT
          KEY_RESIZE KEY_RIGHT KEY_UP getch keyname stdscr timeout!)
    (only (schemacs editor command)
          command-interactive-spec command-type? run-command)
    (only (schemacs editor frame)
          *current-frame* ncurses-frame-esc-pending ncurses-frame-keymap-state
          ncurses-frame-message ncurses-frame-message-expired?
          ncurses-frame-message-expiry
          ncurses-frame-quit-cont set!ncurses-frame-esc-pending
          set!ncurses-frame-keymap-state set!ncurses-frame-message
          set!ncurses-frame-message-expiry
          set!ncurses-frame-quit-cont)
    ;; The global map the lookup falls back on, and the local map a
    ;; minibuffer or a mode binds to have its own keys.
    (only (schemacs editor keymap)
          *current-keymap*
          *default-keymap*)
    ;; The keys the current buffer has of its own - what gives a buffer
    ;; like `*Completions*' its own bindings - and which buffer is current.
    (only (schemacs editor buffer)
          buffer-local-keymap
          current-buffer)
    (only (schemacs editor simple)
          *last-change-was-undo* *last-command* clear-prefix!
          pending-uarg place-undo-boundary! prefix-echo-pending?
          rotate-kill-flag! show-prefix-echo!
          undo-command undo-redo-command update-prefix!)
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

    (define named-key-names
      ;; The key at the front of an ncurses extended keyname, as the name
      ;; this editor's keymaps use for it. The names are terminfo's:
      ;; `kUP3' is the up key, and the `3' is the modifier.
      ;;--------------------------------------------------------------
      '(("UP" . "up") ("DN" . "down") ("LFT" . "left") ("RGT" . "right")
        ("HOM" . "home") ("END" . "end") ("DC" . "delete")
        ("IC" . "insert") ("PP" . "prior") ("NP" . "next")))

    (define named-key-modifiers
      ;; The digit ncurses puts after the key name, as the modifiers it
      ;; stands for. The digits are xterm's `CSI 1 ; N A' numbering, which
      ;; is the numbering terminfo's `kUP3'-style names are built from,
      ;; and GNU Emacs reads the sequences the same way in
      ;; `term/xterm.el' (`\e[1;3A' is `[M-up]' there).
      ;;
      ;; 2, 4, 6 and 8 all carry Shift, and this editor's keymaps have no
      ;; shift modifier - `(schemacs keymap)''s modifier table has ctrl,
      ;; meta, super, hyper and alt and no more - so those answer #f and
      ;; the key is reported unhandled, which is where it was before.
      ;;--------------------------------------------------------------
      '(("3" (meta)) ("5" (ctrl)) ("7" (meta ctrl))))

    (define (extended-key->keymap-path ev)
      ;; The keymap path for an extended keycode, or #f when it is not one
      ;; this editor knows a name for. ncurses names them from terminfo -
      ;; `(keyname 532)' answers "kDN3" - so what is decoded is that name:
      ;; the key, and the modifier digit after it.
      ;;
      ;; `keyname' can only be asked once the terminal is open, which is
      ;; why this cannot be a table built at load time. It costs one call
      ;; per modified key press, and nothing at all for the keys the
      ;; constants above already cover.
      ;;--------------------------------------------------------------
      (let ((name (keyname ev)))
        (and (string? name)
             (< 2 (string-length name))
             (char=? (string-ref name 0) #\k)
             (let* ((base (substring name 1 (- (string-length name) 1)))
                    (digit (string (string-ref name
                                               (- (string-length name) 1))))
                    (key (assoc base named-key-names))
                    (modifiers (assoc digit named-key-modifiers)))
               (and key modifiers
                    (append (cadr modifiers) (list (cdr key))))))))

    (define (ncurses-key->keymap-path ev)
      ;; Convert an ncurses key event to a keymap path: a list of
      ;; modifier symbols and characters (or #f when the event cannot
      ;; be converted).
      ;;
      ;; A keypad key becomes a *named* key - `("up")', `("down")',
      ;; `("home")' and the rest - which is what GNU Emacs sees a
      ;; terminal arrow key as. They used to be folded onto the control
      ;; key that moves the same way (KEY_UP to `(ctrl #\p)' and so on),
      ;; which is what a terminal does when it has no arrow keys; the
      ;; cost is that `M-<up>' - a key of its own in Emacs's
      ;; `minibuffer-local-completion-map' - arrived as M-C-p and could
      ;; not be bound. The control keys are still bound to the same
      ;; commands, so folding them is no longer a behaviour anything
      ;; depends on.
      ;;--------------------------------------------------------------
      (cond
       ((char? ev)
        (let ((ci (char->integer ev)))
          (cond
           ((char=? ev #\return) (list 'ctrl #\m))
           ((char=? ev #\newline) (list 'ctrl #\j))
           ((char=? ev #\esc) (list 'ctrl #\[))
           ((or (= ci 127) (char=? ev #\backspace))
            (list 'ctrl #\h))
           ((and (< 0 ci) (< ci 27))
            (list 'ctrl (integer->char (+ 96 ci))))
           ((and (>= ci 28) (< ci 32))
            (list 'ctrl (integer->char ci)))
           ((and (>= ci 32) (not (= ci 127)))
            (list ev))
           (else #f))))
       ((integer? ev)
        (cond
         ((= ev KEY_LEFT)  (list "left"))
         ((= ev KEY_RIGHT) (list "right"))
         ((= ev KEY_UP)    (list "up"))
         ((= ev KEY_DOWN)  (list "down"))
         ((= ev KEY_HOME)  (list "home"))
         ((= ev KEY_END)   (list "end"))
         ((= ev KEY_DC)    (list "delete"))
         ;; DEL and BS are the same event in a terminal, and Emacs reads
         ;; that byte as `C-h' - which is why both spellings of the
         ;; backspace key land on the same binding here.
         ((= ev KEY_BACKSPACE) (list 'ctrl #\h))
         ((= ev KEY_RESIZE) (list 'resize))
         ;; Anything else: ncurses reports a key carrying a *modifier* as
         ;; an extended keycode - one above `KEY_MAX', named from
         ;; terminfo - and `M-<down>' arrives as the code ncurses calls
         ;; `kDN3' rather than as anything the constants above cover.
         (else (extended-key->keymap-path ev))))
       (else #f)))

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
      (let ((uarg (pending-uarg)))
        (rotate-kill-flag!)
        (place-undo-boundary! action)
        (unless (or (eq? action undo-command) (eq? action undo-redo-command))
          (*last-change-was-undo* #f))
        (clear-prefix!)
        (set!ncurses-frame-message frame "")
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
           ((procedure? action) (action))
           (else (error "not a command" action))))
        (*last-command* action)))

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
      (set!ncurses-frame-message
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
          ;; of consecutive kills.
          (begin
            (rotate-kill-flag!)
            (set!ncurses-frame-keymap-state frame #f))
          ;; any other key: continue (or start) the keymap lookup
          (begin
            (let ((state
                   (or (ncurses-frame-keymap-state frame)
                       (km:new-modal-lookup-state (lookup-keymaps)))))
              ;; NOTE: the state must be stored on the frame BEFORE the
              ;; lookup step, because commands dispatched by the step
              ;; (such as `self-insert-command`) read the key index of
              ;; the chord from the frame's state.
              (set!ncurses-frame-keymap-state frame state)
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
                        (set!ncurses-frame-message
                         frame
                         (string-append
                          "; undefined key: "
                          (call-with-port (open-output-string)
                            (lambda (port)
                              (write (km:keymap-index->list full-path) port)
                              (get-output-string port)))))))))
                (set!ncurses-frame-keymap-state
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
          (set!ncurses-frame-esc-pending frame #t))
         ((and path (ncurses-frame-esc-pending frame))
          (set!ncurses-frame-esc-pending frame #f)
          (dispatch-key-event frame (cons 'meta path))
          )
         ((and path (eq? 'resize (car path)))
          (set!ncurses-frame-message frame "")
          (set!ncurses-frame-esc-pending frame #f))
         (path
          (set!ncurses-frame-esc-pending frame #f)
          (dispatch-key-event frame path))
         (else
          (set!ncurses-frame-esc-pending frame #f)
          (set!ncurses-frame-message
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
      ;; Whether a read produced a key. guile-ncurses's `getch' answers
      ;; `#f' whenever there was nothing to read - a timed-out read, a
      ;; non-blocking read with no input, and the end of input alike -
      ;; so a key is a character or an integer that is not `ERR'.
      ;;
      ;; The distinction this loses is end of input against a timeout.
      ;; It is recovered by the caller from the *timeout*: a blocking
      ;; read only comes back with nothing at the end of input, so the
      ;; editor is left then and not otherwise.
      ;;--------------------------------------------------------------
      (or (char? ev) (and (integer? ev) (not (= ev ERR)))))

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
           (let ((armed #f))
             (let loop ()
               (let ((want (if (or (ncurses-frame-message-expiry frame)
                                   ;; a prefix argument owes the echo
                                   ;; area a description, and it is owed
                                   ;; once the keyboard has been quiet
                                   ;; for `echo-keystrokes' - so the read
                                   ;; cannot block while that is owed
                                   (prefix-echo-pending?))
                               message-read-timeout
                               -1)))
                 (unless (eqv? want armed)
                   (timeout! (stdscr) want)
                   (set! armed want)))
               (let ((ev (getch (stdscr))))
                 (cond
                  ;; Nothing to read, with a message pending that times
                  ;; out: take the message down once its time is up and
                  ;; draw again. Until then there is nothing to do - and
                  ;; nothing to read is also what the end of input looks
                  ;; like, which is why the editor is not left here.
                  ((and (not (key-event? ev))
                        (or (ncurses-frame-message-expiry frame)
                            (prefix-echo-pending?)))
                   (let ((drawn? #f))
                     (when (ncurses-frame-message-expired? frame)
                       (set!ncurses-frame-message frame "")
                       (set!ncurses-frame-message-expiry frame #f)
                       (set! drawn? #t))
                     ;; the prefix description, if its second has come
                     (let ((before (ncurses-frame-message frame)))
                       (show-prefix-echo!)
                       (when (not (eq? before (ncurses-frame-message frame)))
                         (set! drawn? #t)))
                     (when drawn? (render! frame))))
                  ;; Nothing to read on a *blocking* read is the end of
                  ;; input - guile-ncurses answers #f for that too - so
                  ;; leave the editor.
                  ((not (key-event? ev))
                   (let ((quit (ncurses-frame-quit-cont frame)))
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
      (let ((outer-state (ncurses-frame-keymap-state frame)))
        (set!ncurses-frame-keymap-state frame #f)
        (let ((result (command-loop frame)))
          (set!ncurses-frame-keymap-state frame outer-state)
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

    (define (abort-recursive-edit)
      ;; Leave the innermost recursive edit and signal quit, so the
      ;; command that asked the question is abandoned: GNU Emacs's
      ;; `abort-recursive-edit'. It is `exit-recursive-edit' with a thunk
      ;; whose call signals, exactly as Emacs's
      ;; `minibuffer-quit-recursive-edit' does.
      ;;--------------------------------------------------------------
      (exit-recursive-edit signal-quit))

    (define (event-loop frame)
      ;; The outermost command loop: it runs until the editor is quit.
      ;;--------------------------------------------------------------
      (parameterize ((*current-frame* frame)
                     (*current-keymap* *default-keymap*))
        (render! frame)
        (call/cc
         (lambda (k)
           (set!ncurses-frame-quit-cont frame k)
           (command-loop frame)))))

    ))
