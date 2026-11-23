(define-library (schemacs core rmc)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/rmc.el': the
  ;; question whose answer is one of a list of *named* choices -
  ;; `read-multiple-choice'. Its sibling `read-answer' is
  ;; `(schemacs core map-ynp)''s, from `map-ynp.el', and this library is laid
  ;; out the way that one is - the same shape of prompt, the same
  ;; "named rather than faked" list below, the same reasons.
  ;;
  ;; The caller is `kill-buffer--possibly-save' (`simple.el:11568'),
  ;; which is what `kill-buffer' (buffer.c:1958, and `files.sld' here)
  ;; asks through when the buffer being killed has unsaved changes.
  ;; That is the `C-x k' prompt.
  ;;
  ;; **The path that caller takes is `--long-answers'**, and it is
  ;; Emacs's own here. LONG-FORM is `(and (not use-short-answers) (not
  ;; (use-dialog-box-p)))' - both nil for a keyboard command on a
  ;; terminal - so the answer is read as a *word*: "yes", "no", "save
  ;; and then kill", completed in the minibuffer. Measured against
  ;; Emacs 31.1 in a pty on a modified buffer, `C-x k' then RET gives
  ;;
  ;;   Buffer rmc-test.txt modified; kill anyway? (yes/no/save and then kill)
  ;;
  ;; and `n' then RET answers it - `completing-read' completes the one
  ;; letter to "no" - with the buffer left alone. That is this port's
  ;; test.
  ;;
  ;; Not ported, and named rather than faked:
  ;;
  ;;   * **`read-multiple-choice--short-answers'** - the modal path,
  ;;     taken when `read-char-choice-use-read-key' is non-nil or a GUI
  ;;     dialog is wanted. It reads with `read-key' and translates the
  ;;     answer through `query-replace-map' into `recenter',
  ;;     `scroll-up', `edit' and the rest, and it carries a touchscreen
  ;;     protocol besides. There is no `read-char-choice-use-read-key'
  ;;     here and no dialog boxes - the same two absences `map-ynp.sld'
  ;;     notes - so the branch cannot be taken and is not written.
  ;;
  ;;   * **`read-multiple-choice--from-minibuffer'** - **the branch this
  ;;     function's own default would take for a call that is not
  ;;     long-form**, so this is a real gap and not a theoretical one.
  ;;     It reads with a *sparse keymap* whose every choice character is
  ;;     bound to a command that records `last-command-event' and leaves
  ;;     the minibuffer, with `self-insert-command' remapped to a
  ;;     command that beeps and shows the help - so that a key which is
  ;;     not an answer never enters the minibuffer. `map-ynp.sld' left
  ;;     the same shape unported for the same reason (it wants
  ;;     `delete-minibuffer-contents', minibuf.c's); here it also wants
  ;;     an `[remap ...]' binding, which this tree's keymap has no
  ;;     spelling for. `read-from-minibuffer' does take a map, so the
  ;;     port is bounded - it is named rather than half-written. Until
  ;;     it is written, a call that is not long-form signals, which is
  ;;     better than answering a choice the user never made.
  ;;
  ;;   * **`rmc--add-key-description`'s graphical branch**, which
  ;;     propertizes the choice character with a face instead of
  ;;     bracketing it - `[Y]es` against a highlighted `yes`. That is
  ;;     what Emacs 31.1 draws on *this* terminal, whose
  ;;     `display-supports-face-attributes-p' answers t for underline;
  ;;     this tree has no faces on strings, so the bracketed form - the
  ;;     one Emacs draws where faces are unavailable - is the one
  ;;     written. Measured in batch, `(rmc--add-key-description '(?y
  ;;     "yes" "kill"))' is `(121 . "[Y]es")'.
  ;;
  ;;   * **`rmc--show-help`'s window** - the `*Multiple Choice Help*`
  ;;     buffer, its `with-help-window', its per-choice `fill-region`
  ;;     and its column arithmetic. `map-ynp.sld' puts its help in the
  ;;     echo area for the same reason. It is reached only by pressing
  ;;     `?' or `C-h' at the prompt, which needs `--from-minibuffer'
  ;;     above anyway.
  ;;
  ;;   * **the dialog path** (`x-popup-dialog') and the
  ;;     `read-multiple-choice--long-answers' GUI dialog: no popup menus
  ;;     exist here, as `map-ynp.sld' says of its own.

  (import
    (scheme base)
    ;; `string-join' is `mapconcat''s: the choice names written out
    ;; between "/" for the prompt.
    (only (guile) string-join)
    ;; the question itself, and the optional-argument reader the two
    ;; entry points share with the rest of the tree
    (only (schemacs minibuffer)
          completing-read list-ref-or read-from-minibuffer exit-minibuffer
          minibuffer-message minibuffer-local-bindings
          minibuffer-map-from-bindings)
    (only (guile) string-index string-upcase)
    (only (schemacs command) *last-command-event*)
    (only (schemacs keymap) key-description define-key)
    (only (schemacs buffer)
          get-buffer-create with-current-buffer erase-buffer)
    (only (schemacs editfns) insert goto-char point-min)
    (only (schemacs window) display-buffer))

  (export read-multiple-choice read-multiple-choice--long-answers
          read-multiple-choice--from-minibuffer
          rmc--add-key-description rmc--show-help)

  (begin

    (define (read-multiple-choice--long-answers prompt choices)
      ;; GNU Emacs's `read-multiple-choice--long-answers'
      ;; (`rmc.el:321'): complete over the NAMEs, and find the entry the
      ;; answer names.
      ;;
      ;; The prompt is Emacs's own `(concat prompt " (" ... ") ")' - a
      ;; space after the closing paren, not `": "', because the answer
      ;; is completed rather than typed out in full. Measured:
      ;; `Buffer X modified; kill anyway? ([Y]es, [N]o, ...) ' is *not*
      ;; this path - that is `--from-minibuffer''s prompt, which
      ;; brackets through `rmc--add-key-description'. This one lists the
      ;; names between "/" and does not bracket.
      ;;
      ;; CHOICES is Emacs's `(KEY NAME [DESCRIPTION])' list, with KEY a
      ;; *character* - Emacs writes it `?y', which is the integer 121
      ;; there and `#\y' here, Emacs having no character type.
      ;;--------------------------------------------------------------
      (let ((answer
             (completing-read
              (string-append prompt " ("
                             (string-join
                              (map (lambda (choice) (cadr choice)) choices)
                              "/")
                             ") ")
              ;; the NAMEs are the collection, and REQUIRE-MATCH is t:
              ;; the minibuffer will not be left holding something that
              ;; names no choice.
              (map (lambda (choice) (cadr choice)) choices)
              #f #t)))
        ;; Emacs's `(seq-find (lambda (elem) (equal (cadr elem) answer))
        ;; choices)' - the whole entry, whose NAME is the answer.
        (let loop ((rest choices))
          (cond ((null? rest) #f)
                ((equal? (cadr (car rest)) answer) (car rest))
                (else (loop (cdr rest)))))))

    (define (read-multiple-choice prompt choices . rest)
      ;; GNU Emacs's `read-multiple-choice' (`rmc.el:133'): "Ask user to
      ;; select an entry from CHOICES, prompting with PROMPT."
      ;;
      ;;   (read-multiple-choice PROMPT CHOICES &optional HELp-STRING
      ;;                         SHOW-HELP LONG-FORM)
      ;;
      ;; The answer is the matching *entry* from CHOICES, not the
      ;; character and not the name - which is why both callers of it
      ;; read it with `cadr' to get the name they asked about.
      ;;
      ;; Of Emacs's three arms only LONG-FORM is written, and the other
      ;; two are named in the header. Signaling rather than guessing
      ;; matters here: an unported arm that answered, say, `#f' would
      ;; read to `kill-buffer--possibly-save' as "do not kill", which is
      ;; a safe-looking answer to a question nobody was asked.
      ;;--------------------------------------------------------------
      ;; REST is `(HELP-STRING SHOW-HELP LONG-FORM)', so LONG-FORM is
      ;; index **2**. It was `3' - one past the end - so the answer was
      ;; always the default `#f' and **every** call took the branch this
      ;; library does not implement: `C-x k' on a modified buffer did not
      ;; ask its question, it raised. Emacs's own argument list is
      ;; `(PROMPT CHOICES &optional HELP-STRING SHOW-HELP LONG-FORM)'
      ;; (`rmc.el:133'), and its `cond' tests LONG-FORM first.
      (let ((long-form (list-ref-or rest 2 #f))
            (help-string (list-ref-or rest 0 #f))
            (show-help (list-ref-or rest 1 #f)))
        (if long-form
            (read-multiple-choice--long-answers prompt choices)
            ;; Emacs's cond then tests the modal/dialog arm, whose two
            ;; switches (`read-char-choice-use-read-key`,
            ;; `use-dialog-box-p`) have no counterpart here; on a
            ;; terminal with neither, Emacs takes this same arm.
            (read-multiple-choice--from-minibuffer
             prompt choices help-string show-help))))

    ;;----------------------------------------------------------------
    ;; `read-multiple-choice--from-minibuffer' (rmc.el:336)
    ;;
    ;; The arm Emacs takes for `novice.el`'s "Use this command?" - the
    ;; modal and dialog arms are not carried (`read-char-choice-use-
    ;; read-key` and `use-dialog-box-p` have no counterpart here, and
    ;; neither is wanted on a terminal), so this is the default.
    ;;----------------------------------------------------------------

    (define (rmc--add-key-description elem)
      ;; GNU Emacs's `rmc--add-key-description' (`rmc.el:26'): the
      ;; choice's key description and name - "Y (yes)" for a name that
      ;; contains the key, "[Y]es" on a terminal, and "SPC (space bar)
      ;; only once" for one that does not.
      ;;
      ;; **The graphical arm is not carried** (`read-multiple-choice-face`
      ;; and the underline probe are a window-system's); the terminal's
      ;; bracket form is what is drawn either way here.
      ;;--------------------------------------------------------------
      (let* ((char (car elem))
             (name (cadr elem))
             (pos (string-index name char))
             (desc (key-description (vector (char->integer char)))))
        (cons char
              (cond
               ;; "Not in the name string, or a special character."
               ((or (not pos)
                    (member desc '("ESC" "TAB" "RET" "DEL" "SPC")))
                (string-append desc " " name))
               ;; "And put it in [bracket] on non-graphical terminals."
               (else
                (string-append (substring name 0 pos)
                               "["
                               (string-upcase (substring name pos (+ pos 1)))
                               "]"
                               (substring name (+ pos 1))))))))

    (define (rmc--show-help prompt help-string show-help choices altered)
      ;; GNU Emacs's `rmc--show-help' (`rmc.el:56'): "Show the help
      ;; buffer" - the caller's HELP-STRING, or the choices written out,
      ;; in a buffer named by SHOW-HELP when it is a string.
      ;;
      ;; **The buffer is not killed on the way out**: that is
      ;; `read-multiple-choice--from-minibuffer`'s `unwind-protect`
      ;; (`rmc.el:384`), and `kill-buffer` would have to be reached
      ;; through the window library. The next prompt of the same name
      ;; empties and reuses it, so nothing accumulates.
      ;;--------------------------------------------------------------
      (let* ((buf-name (if (string? show-help) show-help
                           "*Multiple Choice Help*"))
             (buf (get-buffer-create buf-name)))
        (with-current-buffer buf
          (erase-buffer)
          (insert (if help-string
                      help-string
                      (string-append prompt "\n\n"
                                     (string-join (map cdr altered) "\n"))))
          (goto-char (point-min)))
        (display-buffer buf)
        buf))

    (define (read-multiple-choice--from-minibuffer prompt choices
                                                  help-string show-help)
      ;; GNU Emacs's `read-multiple-choice--from-minibuffer'
      ;; (`rmc.el:336'): "Read short answers from the minibuffer." Each
      ;; choice's key is bound to a command that records
      ;; `last-command-event` and exits; `?` and C-h show the help; any
      ;; other printing key is refused with "Invalid choice".
      ;;
      ;; Emacs sets `enable-recursive-minibuffers` and a text-conversion
      ;; style here; neither exists in this tree, and the help buffer's
      ;; kill (`rmc.el:384`) is named on `rmc--show-help`.
      ;;--------------------------------------------------------------
      (let* ((prompt-choices (if show-help choices
                                 (append choices (list (list #\? "?")))))
             (altered (map rmc--add-key-description prompt-choices))
             (full-prompt (string-append
                           prompt " ("
                           (string-join (map cdr altered) ", ")
                           "): "))
             (tchar #f)
             (buf #f)
             (map (minibuffer-map-from-bindings '*rmc--keymap*
                                                (minibuffer-local-bindings))))
        (define (cmd-char)
          ;; The choices hold *characters* (this tree's spelling of
          ;; Emacs's `?\s' integers) and `last-command-event' is the
          ;; event's code, so the answer is converted here - without
          ;; this, `(assq 32 '(#\space ...))' was false and every answer
          ;; looked like a refusal.
          (let ((e (*last-command-event*)))
            (set! tchar (if (integer? e) (integer->char e) e)))
          (exit-minibuffer))
        (define (cmd-help)
          (set! buf (rmc--show-help prompt help-string show-help
                                    choices altered)))
        (define (cmd-wrong)
          ;; `(ding)` is not ported: the message is the report.
          (set! buf (rmc--show-help prompt help-string show-help
                                    choices altered))
          (minibuffer-message "Invalid choice"))
        (for-each (lambda (c)
                    (define-key map (vector (char->integer (car c))) cmd-char))
                  choices)
        ;; `help-char` is C-h; the tree has not the variable.
        (define-key map (vector 8) cmd-help)
        (unless show-help
          (define-key map (vector (char->integer #\?)) cmd-help))
        (define-key map (vector 'remap 'self-insert-command) cmd-wrong)
        (read-from-minibuffer full-prompt #f map)
        (assq tchar choices)))

    ))
