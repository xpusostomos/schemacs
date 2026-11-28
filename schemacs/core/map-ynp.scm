(define-library (schemacs core map-ynp)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/map-ynp.el': the
  ;; question-askers that walk a list of objects - `map-y-or-n-p', which
  ;; `save-some-buffers` asks through (and `y-or-n-p` would, if this tree
  ;; had it in Emacs's shape) - and `read-answer', which Dired's
  ;; `dired-delete-file' asks before it deletes a directory that has
  ;; anything in it.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * **`map-y-or-n-p`'s echo-area arm** - `y-or-n-p-use-read-key`
  ;;     non-nil reads the answer with `read-key-sequence-vector` in the
  ;;     echo area. The variable is here and nil (Emacs's default), so
  ;;     the minibuffer arm is the one taken.
  ;;   * **the dialog-box path** - Emacs asks for an answer with
  ;;     `x-popup-dialog' when `use-dialog-box' and
  ;;     `display-popup-menus-p' both allow it. No dialog question is
  ;;     ported, so that arm cannot be taken and is not written.
  ;;   * **the short-answer keymap** - Emacs binds each one-character
  ;;     answer in a sparse keymap whose `self-insert-command' is
  ;;     remapped to say "Type ? for help", so that a key that is not an
  ;;     answer does not go into the minibuffer at all. That needs
  ;;     `delete-minibuffer-contents' (minibuf.c's), which is not
  ;;     ported; the answer is read with `read-char-from-minibuffer'
  ;;     instead - the same one-key question, with an unbound answer
  ;;     beeping the same message. The long-answer path, which is the
  ;;     one `read-answer-short''s default of `auto' resolves to, is
  ;;     Emacs's own.
  ;;   * **`read-answer-map--memoize'** - Emacs caches each answers list's
  ;;     keymap in a weak-keyed hash. The keymap is a function call here.

  (import
    ;; `define-custom' - the C variables `cus-start.el' makes
    ;; customizable (see the declaration below).
    (only (schemacs custom) define-custom)
    (scheme base)
    (scheme char)
    ;; `string-join' is `mapconcat''s: the answers written out between
    ;; ", " for the prompt.
    (only (guile) caddr string-join)
    ;; the question, and the one-key question the short path asks
    (only (schemacs minibuffer)
          read-from-minibuffer read-char-from-minibuffer
          minibuffer-local-map exit-minibuffer)
    ;; a message goes to the echo area, and the `message' that puts it
    ;; there is editfns.c's in Emacs 31
    (only (schemacs editfns) format message current-message)
    ;; `message-log-max' is a DEFVAR in xdisp.c and lives in `xdisp.scm'
    ;; here; the final "restore the previous message" binds it nil so it
    ;; is not logged.
    (only (schemacs xdisp) *message-log-max*)
    ;; `map-y-or-n-p`'s answers are `query-replace-map`'s, and the keys
    ;; are spelled with the keymap helpers.
    (prefix (schemacs keymap) km:)
    (only (schemacs keymap) key-description single-key-description)
    (only (schemacs replace) *query-replace-map*)
    ;; the help page, and the substitution its text is written with
    (only (schemacs help)
          substitute-command-keys with-help-window help-buffer help-key)
    ;; `call-interactively` for an answer bound to a command symbol, and
    ;; `sit-for` after an answer that means nothing
    (only (schemacs command) call-interactively command-record-named
          *quit-flag* maybe-quit)
    (only (schemacs keyboard) sit-for *unread-command-events*)
    ;; the two `subr.el` defvars the question reads
    (only (schemacs subr)
          y-or-n-p-use-read-key y-or-n-p-history-variable
          ;; `(nth 1 ELT)` reads an action-alist entry's function and
          ;; `(nth 2 ELT)` its help string.
          nth)
    (only (schemacs editfns) insert)
    )

  (export *read-answer-short* *use-short-answers* read-answer
          read-answer-short
          map-y-or-n-p)

  (begin

    ;; `y-or-n-p-use-read-key' and `y-or-n-p-history-variable' are
    ;; `subr.el`'s defvars (`:4039`, `:4102`) and live in `subr.scm',
    ;; where Emacs has them; this library reads them by name.

    (define (map-y-or-n-p prompter actor list help action-alist
                          no-cursor-in-echo-area)
      ;; GNU Emacs's `map-y-or-n-p' (`map-ynp.el:43'): "Ask a boolean
      ;; question per PROMPTER for each object in LIST, then call ACTOR."
      ;;
      ;; The question is Emacs 31's, character for character, because it
      ;; is Emacs's own format string:
      ;;
      ;;   Save file /tmp/x.txt? (`y', `n', `!', `.', `q', `C-r', `d' or `C-h')
      ;;
      ;; The answers are `query-replace-map`'s symbols, with each answer
      ;; key bound in the minibuffer to a command that leaves with that
      ;; key - the C's `cmd-char` remap - and any other printing key
      ;; saying how to ask for help instead of going into the minibuffer.
      ;; **This is the minibuffer arm**, which is Emacs's default
      ;; (`y-or-n-p-use-read-key' nil). The echo-area
      ;; `read-key-sequence-vector' arm and the dialog-box arm are not
      ;; carried; see the library header.
      ;;--------------------------------------------------------------
      (let* ((msg (current-message))
             (action-alist (or action-alist '()))
             (user-keys
              (if (pair? action-alist)
                  (string-append
                   (string-join
                    (map (lambda (elt)
                           (substitute-command-keys
                            (format "\\`%s'"
                                    (key-description (vector (car elt))))))
                         action-alist)
                    ", ")
                   " ")
                  ""))
             ;; "Make a map that defines each user key as a vector
             ;; containing its definition."
             (answers (let ((m (km:make-sparse-keymap)))
                        ;; `query-replace-map' is a plain variable here
                        ;; (`replace.scm` makes the keymap at load); the
                        ;; stars are the Emacs name's, not the parameter
                        ;; convention's, so it is read as a value.
                        (km:set-keymap-parent m *query-replace-map*)
                        (for-each
                         (lambda (elt)
                           (km:define-key m (vector (car elt))
                                          (vector (nth 1 elt))))
                         action-alist)
                        m))
             (prompter (if (string? prompter)
                           (lambda (object) (format prompter object))
                           prompter))
             ;; The C's `next' and `try-again' closures: `next!' takes
             ;; the next object, and a failed answer asks about the same
             ;; one again (`again' #t in the loop).
             (elt #f)
             (rest list)
             (delayed-switch-frame #f))
        (define (next!)
          (if (null? rest)
              #f
              (begin (set! elt (car rest))
                     (set! rest (cdr rest))
                     #t)))
        (define (restore-message!)
          ;; "Clear the last prompt from the minibuffer, and restore the
          ;; previous echo-area message, if any."
          (parameterize ((*message-log-max* #f))
            (if msg (message "%s" msg) (message ""))))
        (define (finish actions)
          ;; The C's unwind-protect tail: a switch-frame event seen while
          ;; asking is put back for the command loop, and the previous
          ;; message is restored. Answers ACTIONS.
          (if delayed-switch-frame
              ;; A parameter is set by calling it (the tree's rule);
              ;; `unread-command-events` is one in `keyboard.scm`.
              (*unread-command-events*
               (cons delayed-switch-frame (*unread-command-events*))))
          (restore-message!)
          actions)
        (define (ask prompt)
          ;; "Read from the minibuffer." Answers `(CHARS . DEF)', DEF
          ;; looked up in ANSWERS.
          (let ((chars #f))
            (let ((remap (km:make-sparse-keymap)))
              (km:set-keymap-parent remap minibuffer-local-map)
              (km:define-key remap (vector 'remap 'self-insert-command)
                             (lambda ()
                               (message "%s"
                                        (substitute-command-keys
                                         (format "Type \\`%s' for help"
                                                 (help-key))))))
              ;; Each key of ANSWERS exits the minibuffer with itself:
              ;; `cl--map-keymap-recursively' over the composed map,
              ;; binding every key to `cmd-char'.
              (km:map-keymap
               (lambda (key command)
                 (km:define-key remap (vector key)
                                (lambda ()
                                  (set! chars (vector key))
                                  (exit-minibuffer))))
               answers)
              (let ((full-prompt
                     (substitute-command-keys
                      (format "%s(\\`y', \\`n', \\`!', \\`.', \\`q', %sor \\`%s') "
                              prompt user-keys (help-key)))))
                (read-from-minibuffer full-prompt #f remap
                                      (or y-or-n-p-history-variable #t) #f)
                ;; "Show the answer to the question."
                (message "%s%s" full-prompt (key-description chars))
                (cons chars
                      (and chars (km:keymap-lookup answers chars)))))))
        (define (show-help)
          ;; `def` = help: Emacs's page, built from HELP and the action
          ;; alist. `(princ ...)` into the help window is `insert` here.
          (with-help-window (help-buffer)
            (let ((object (or (and (pair? help) (nth 0 help)) "object"))
                  (objects (or (and (pair? help) (nth 1 help)) "objects"))
                  (action (or (and (pair? help) (nth 2 help)) "act on")))
              (insert
               (substitute-command-keys
                (format
                        (string-append
                         "Type \\`SPC' or \\`y' to %s the current %s;\n"
                         "\\`DEL' or \\`n' to skip the current %s;\n"
                         "\\`RET' or \\`q' to skip the current and all remaining %s;\n"
                         "\\`C-g' to quit (cancel the whole command);\n"
                         "\\`!' to %s all remaining %s;\n")
                        action object object objects action objects)))
              (for-each
               (lambda (elt)
                 (insert (format "%s to %s;\n"
                                 (single-key-description (nth 0 elt))
                                 (nth 2 elt))))
               action-alist)
              (insert (format "or . (period) to %s the current %s and exit."
                              action object)))))
        ;; One object's question, and where the loop goes from it.
        (define (step actions)
          ;; **GNU Emacs's evaluator checks `quit_flag` at every function
          ;; call** (`maybe_quit` in `eval_sub`), and that is what makes
          ;; the `quit` answer work: the C sets `quit-flag` and calls
          ;; `try-again`, and the *next call* - before the prompt's own
          ;; `(setq quit-flag nil)` runs - signals. Scheme has no such
          ;; check, so the loop re-entry makes it by hand; without this
          ;; the flag was cleared by the re-ask and C-g asked again for
          ;; ever.
          (maybe-quit)
          (let ((prompt (prompter elt)))
            (cond
             ;; "Prompt the user about this object."
             ((string? prompt)
              (*quit-flag* #f)
              (let* ((answer (ask prompt))
                     (chars (car answer))
                     (def (cdr answer)))
                (cond
                 ((eq? def 'exit)
                  (finish actions))
                 ((eq? def 'act)
                  ;; Act on the object.
                  (actor elt)
                  (loop (+ actions 1) #f))
                 ((eq? def 'skip)
                  ;; Skip the object.
                  (loop actions #f))
                 ((eq? def 'act-and-exit)
                  ;; Act on the object and then exit.
                  (actor elt)
                  (finish (+ actions 1)))
                 ((memq def '(quit exit-prefix))
                  ;; "Set quit-flag and try again": the next read raises
                  ;; it, exactly as the C's `quit_flag' does.
                  (*quit-flag* #t)
                  (loop actions #t))
                 ((eq? def 'automatic)
                  ;; Act on this and all following objects.
                  (let ((actions (if prompt
                                     (begin (actor elt) (+ actions 1))
                                     actions)))
                    (let drain ((actions actions))
                      (if (next!)
                          (drain (if (prompter elt)
                                     (begin (actor elt) (+ actions 1))
                                     actions))
                          (finish actions)))))
                 ((eq? def 'help)
                  (show-help)
                  (loop actions #t))
                 ((and (symbol? def)
                       (command-record-named (symbol->string def)))
                  (call-interactively def)
                  ;; Regurgitated; try again.
                  (loop actions #t))
                 ((vector? def)
                  ;; A user-defined key: the function takes ELT, and a
                  ;; non-nil answer means the object was handled.
                  (if ((vector-ref def 0) elt)
                      (loop (+ actions 1) #f)
                      (loop actions #t)))
                 ((equal? chars (vector 'switch-frame))
                  ;; "Put it off until we're done."
                  (set! delayed-switch-frame chars)
                  (loop actions #t))
                 (else
                  ;; "Random char." `ding` is not ported: the message
                  ;; and the pause are here, the bell is not.
                  (message "%s"
                           (substitute-command-keys
                            (format "Type \\`%s' for help" (help-key))))
                  (sit-for 1)
                  (loop actions #t)))))
             ;; A non-string prompt: act without asking - the docstring's
             ;; "may be nil to ignore the object, or non-nil to act on it".
             (prompt
              (actor elt)
              (loop (+ actions 1) #f))
             (else
              (loop actions #f)))))
        (define (loop actions again)
          (cond
           ;; `try-again': the same object, without taking the next.
           (again (step actions))
           ((next!) (step actions))
           (else (finish actions))))
        (loop 0 #f)))

    (define-custom *read-answer-short* 'auto
      "If non-nil, the `read-answer' function accepts single-character answers.
If t, accept short (single key-press) answers to the question.
If nil, require long answers.  If `auto', accept short answers if
`use-short-answers' is non-nil, or the function cell of `yes-or-no-p'
is set to `y-or-n-p'.

Note that this variable does not affect calls to the more
commonly-used `yes-or-no-p' function; it only affects calls to
the `read-answer' function.  To control whether `yes-or-no-p'
requires a long or a short answer, see the `use-short-answers'
variable."
      :type '(choice (const :tag "Accept short answers" t) (const :tag "Require long answer" nil) (const :tag "Guess preference" auto)) :group 'minibuffer :version "26.2")
    ;; ^ GNU Emacs's `read-answer-short' (map-ynp.el:406), whose default
    ;; is `auto': "accept short answers if `use-short-answers' is
    ;; non-nil, or the function cell of `yes-or-no-p' is set to
    ;; `y-or-n-p'."

    (define-custom *use-short-answers* #f
      "Non-nil means ‘yes-or-no-p’ accepts single-key answers \"y\" or \"n\".\nWhen non-nil, ‘yes-or-no-p’ will use ‘y-or-n-p’ to read the answer.\nThis means the user will be able to press just one key to answer, whereas\nby default the user needs to type the full \"yes\" or \"no\" response\nand then press RET.\n\nWe recommend against setting this variable non-nil, because ‘yes-or-no-p’\nis intended to be used when users are expected not to respond too\nquickly, but to take their time and perhaps think about the answer.\nThe same variable also affects the function ‘read-answer’.  See also\n‘yes-or-no-prompt’."
      :type 'boolean
      :group 'menu
      :version "28.1")
    ;; ^ GNU Emacs's `use-short-answers', false by default.

    (define (read-answer-short)
      ;; The resolution `read-answer' makes of `read-answer-short'
      ;; (map-ynp.el:451). Emacs's second test is on `yes-or-no-p''s
      ;; *function cell*, which a user can set to `y-or-n-p'; a command
      ;; here is a procedure rather than a name with a cell, so that way
      ;; of asking for short answers has no equivalent, and the variable
      ;; is the one that answers.
      ;;--------------------------------------------------------------
      (if (eq? (*read-answer-short*) 'auto)
          (*use-short-answers*)
          (*read-answer-short*)))

    (define (read-answer question answers)
      ;; GNU Emacs's `read-answer' (map-ynp.el:415): "Read an answer
      ;; either as a complete word or its character abbreviation. Ask
      ;; user a question and accept an answer from the list of possible
      ;; answers. Return the long answer even when accepting short ones."
      ;;
      ;; ANSWERS is an alist of `(LONG-ANSWER SHORT-ANSWER HELP-MESSAGE)',
      ;; as it is in Emacs.
      ;;--------------------------------------------------------------
      (let* ((short (read-answer-short))
             (answers-with-help
              (if (assoc "help" answers)
                  answers
                  (append answers '(("help" ?? "show this help message")))))
             (answers-without-help
              (let loop ((rest answers-with-help) (acc '()))
                (cond ((null? rest) (reverse acc))
                      ((equal? (car (car rest)) "help") (loop (cdr rest) acc))
                      (else (loop (cdr rest) (cons (car rest) acc))))))
             (prompt
              (string-append question
                             "("
                             (string-join
                              (map (lambda (a)
                                     (if short
                                         (short-answer-text (cadr a))
                                         (car a)))
                                   answers-with-help)
                              ", ")
                             ") "))
             (the-message
              (string-append
               "Please answer "
               (string-join
                (map (lambda (a)
                       (string-append "`"
                                      (if short (short-answer-text (cadr a))
                                          (car a))
                                      "'"))
                     answers-with-help)
                " or ")
               "."))
             (answer #f))
        (let loop ()
          (set! answer
                (string-downcase
                 (if short
                     (string (read-char-from-minibuffer prompt))
                     (read-from-minibuffer prompt #f #f #f #f))))
          (if (assoc answer answers-without-help)
              answer
              (begin
                ;; "help" is the two-character answer `?', and the rest
                ;; of the answers are listed - Emacs shows them in the
                ;; `*Help*' window, which is not ported; the message
                ;; takes their place.
                (message "%s" (read-answer-help-text question answers-with-help
                                                     short))
                (loop))))
        ;; the long answer, which is the car of the entry the answer matched
        (car (assoc answer answers-without-help))))

    (define (short-answer-text short-answer)
      ;; A short answer written out: `map-ynp.el' does this with
      ;; `(if (characterp (nth 1 a)) (format "%c" (nth 1 a))
      ;; (key-description (nth 1 a)))' - a character, or a key like C-M-h
      ;; named by `key-description'.
      ;;--------------------------------------------------------------
      (if (char? short-answer)
          (string short-answer)
          (format "%s" short-answer)))

    (define (read-answer-help-text question answers-with-help short)
      ;; The text `read-answer''s `help' branch puts in `*Help*' - here
      ;; said in the echo area, since the help window is not ported.
      ;;--------------------------------------------------------------
      (string-append
       question
       (string-join
        (map (lambda (a)
               (string-append "`"
                              (if short (short-answer-text (cadr a)) (car a))
                              "'"
                              (if short
                                  (string-append " (" (car a) ")")
                                  "")
                              " to "
                              (caddr a)))
             answers-with-help)
        ", ")
       "."))

    ))
