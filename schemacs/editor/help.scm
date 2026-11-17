(define-library (schemacs editor help)
  ;; This library mirrors GNU Emacs's `lisp/help.el' - the help system.
  ;; What is here is the string-substitution half, which the
  ;; disabled-command prompt and every `:help' string stand on:
  ;; `substitute-command-keys', `substitute-quotes', `key-valid-p' (with
  ;; a placement note - it is `keymap.el`'s) and the fontified key
  ;; description.
  ;;
  ;; **Not carried, and what each waits for**:
  ;;
  ;;   * `\{MAPVAR}' and `\<MAPVAR>' - the keymap summary and the
  ;;     "use this map" form. The summary is `help--describe-map-tree',
  ;;     the describe-bindings machinery (it is also what `C-h b' would
  ;;     need), which this tree has not. The forms are left standing in
  ;;     the text, as an unrecognised `\`...`` form is: the walk moves
  ;;     past them and the next character is processed normally.
  ;;   * `help-link-key-to-documentation' / `help-mode--add-function-link'
  ;;     - both are gated on `help-buffer-under-preparation`, which
  ;;     nothing here sets, so the fallback (the plain fontified key) is
  ;;     what Emacs takes too.
  ;;   * The *Help* buffer itself, `describe-*', `help-fns'.
  ;;
  ;; The walk runs over a temporary buffer as Emacs's does, because
  ;; every branch edits in place - a `\=` deletes two characters, a
  ;; failed `\`KEY'' substitution leaves the backtick for the quote
  ;; rule on the next pass - and a string accumulator would have to
  ;; re-implement that bookkeeping.

  (import
    (scheme base)
    (scheme char)
    ;; `key-valid-p` and the walk are string matchers.
    (only (schemacs editor search)
          string-match string-match-p match-end match-beginning save-match-data)
    ;; `split-string`, `kbd`-free - the strokes come as text.
    (only (schemacs editor subr) split-string)
    ;; the temporary buffer the walk edits in place
    (only (schemacs editor buffer) allocate-buffer *current-buffer* current-buffer)
    (only (schemacs editor editfns)
          buffer-string buffer-substring-no-properties insert goto-char point
          point-min point-max char-after propertize save-excursion
          text-quoting-style)
    ;; the movement and deletion the walk spells the Elisp way
    (only (schemacs editor cmds) forward-char)
    (only (schemacs editor editfns) delete-region)
    ;; `search-forward` is the tree's, from `search.c`.
    (only (schemacs editor search) search-forward)
    ;; `where-is-internal` is `keymap.c`'s, and `key-description` with it.
    (only (schemacs editor keyboard) where-is-internal)
    (only (schemacs editor keymap) key-description)
    ;; the face and the property store
    (only (schemacs editor textprop) add-text-properties))

  (export substitute-quotes substitute-command-keys key-valid-p
          help--key-description-fontified)

  (begin

    ;;----------------------------------------------------------------
    ;; `substitute-quotes' (help.el:1578)
    ;;----------------------------------------------------------------

    (define (substitute-quotes string)
      ;; GNU Emacs's `substitute-quotes' (`help.el:1578'):
      ;; "Substitute quote characters in STRING for display. Each grave
      ;; accent \\=` is replaced by left quote, and each apostrophe
      ;; \\=' is replaced by right quote. Which left and right quote
      ;; characters to use is determined by the variable
      ;; `text-quoting-style'."
      ;;--------------------------------------------------------------
      (case (text-quoting-style)
        ((curve)
         (list->string
          (map (lambda (c)
                 (case c ((#\`) #\‘) ((#\') #\’) (else c)))
               (string->list string))))
        ((straight)
         (list->string
          (map (lambda (c) (case c ((#\`) #\') (else c)))
               (string->list string))))
        (else string)))

    ;;----------------------------------------------------------------
    ;; `key-valid-p' (keymap.el:328)
    ;;
    ;; **A placement departure**: it is `keymap.el`'s, but it is a
    ;; string matcher (`string-match-p`, `split-string`), and both live
    ;; above `keymap.scm` - `search.scm` and `subr.scm` respectively.
    ;; This library is the first thing that wants it.
    ;;----------------------------------------------------------------

    (define (key-valid-p keys)
      ;; GNU Emacs's `key-valid-p' (`keymap.el:328'): "Return non-nil if
      ;; KEYS, a string, is a valid key sequence. ... Each key stroke is
      ;; either a single character, or the name of an event, surrounded
      ;; by angle brackets <like-this>. ... Modifiers have to be
      ;; specified in this order: A-C-H-M-S-s."
      ;;--------------------------------------------------------------
      (define prefixes
        ;; "\\(A-\\)?\\(C-\\)?\\(H-\\)?\\(M-\\)?\\(S-\\)?\\(s-\\)?"
        "\\(A-\\)?\\(C-\\)?\\(H-\\)?\\(M-\\)?\\(S-\\)?\\(s-\\)?")
      (and (string? keys)
           (string-match-p "\\`[^ ]+\\( [^ ]+\\)*\\'" keys)
           (save-match-data
            (let loop ((strokes (split-string keys " ")))
              (cond
               ((null? strokes) #t)
               (else
                (let* ((stroke (car strokes))
                       (key (if (string-match (string-append "\\`" prefixes)
                                              stroke)
                                (substring stroke (match-end 0))
                                stroke)))
                  (if (or
                       ;; a single character that is not a control
                       ;; character, and not a raw byte in [127,255] -
                       ;; every string here is multibyte, so the C's
                       ;; `multibyte-string-p` test is always true.
                       (and (= (string-length key) 1)
                            (not (< (char->integer (string-ref key 0)) 32)))
                       ;; a named event: <name> with the modifiers in
                       ;; front, and the name itself not starting a
                       ;; second modifier run ("Don't allow <M-C-down>").
                       (and (string-match-p "\\`<[-_A-Za-z0-9]+>\\'" key)
                            (= (if (string-match (string-append "\\`<" prefixes)
                                                 key)
                                   (match-end 0)
                                   0)
                               1))
                       ;; the seven shorthand names.
                       (string-match-p
                        "\\`\\(NUL\\|RET\\|TAB\\|LFD\\|ESC\\|SPC\\|DEL\\)\\'"
                        key))
                      (loop (cdr strokes))
                      #f))))))))

    ;;----------------------------------------------------------------
    ;; `help--key-description-fontified' (help.el:808)
    ;;----------------------------------------------------------------

    (define (help--key-description-fontified keys . rest)
      ;; GNU Emacs's `help--key-description-fontified' (`help.el:808'):
      ;; "Like `key-description' but add face for \"*Help*\" buffers. ...
      ;; Return nil if KEYS is nil." Both properties, as the C's comment
      ;; says - "the only way to get this to work reliably in any
      ;; buffer".
      ;;--------------------------------------------------------------
      (and keys
           (propertize (key-description keys (and (pair? rest) (car rest)))
                       'font-lock-face 'help-key-binding
                       'face 'help-key-binding)))

    ;;----------------------------------------------------------------
    ;; `substitute-command-keys' (help.el:1435)
    ;;----------------------------------------------------------------

    (define (substitute-command-keys string . rest)
      ;; GNU Emacs's `substitute-command-keys' (`help.el:1435'):
      ;; "Substitute key descriptions for command names in STRING. Each
      ;; substring of the form \\[COMMAND] is replaced by either a
      ;; keystroke sequence that invokes COMMAND, or \"M-x COMMAND\" if
      ;; COMMAND is not on any keys. ... Each grave accent \\=` is
      ;; replaced by left quote, and each apostrophe \\=' is replaced by
      ;; right quote. ... \\== quotes the following character and is
      ;; discarded."
      ;;
      ;; The C's cases, in its order: 1A `\=` at end, 1B `\=` quoting
      ;; the next character, 1C `\`KEY'', 1D `\[COMMAND]', 1E `\{MAP}'
      ;; and `\<MAP>' (not carried - see the header), then the two
      ;; quote rules and the ordinary step. The buffer the C edits is
      ;; made here, with the user's buffer remembered for
      ;; `where-is-internal`'s benefit.
      ;;--------------------------------------------------------------
      (let ((no-face (and (pair? rest) (car rest)))
            (include-menus (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (keymap #f))
        (if (not string)
            string
            (let ((orig-buf (current-buffer)))
              (parameterize ((*current-buffer* (allocate-buffer)))
                (insert string)
                (goto-char (point-min))
                (let loop ()
                  (when (< (point) (point-max))
                    (let ((orig-point (point))
                          (end-point #f))
                      (cond
                       ;; 1. A backslash: 1A-1E.
                       ((char=? (char-after (point)) #\\)
                        (forward-char 1)
                        (let ((c (char-after (point))))
                          (cond
                           ;; 1A. `\=` at end of string.
                           ((and c (char=? c #\=)
                                 (= (+ (point) 1) (point-max)))
                            (forward-char 1))
                           ;; 1B. `\=` quotes the next character.
                           ((and c (char=? c #\=))
                            (goto-char orig-point)
                            (delete-region (point) (+ (point) 2))
                            (forward-char 1))
                           ;; 1C. `\`KEY'' is replaced by the fontified
                           ;; KEY, when KEY names a key; otherwise the
                           ;; backtick is left for the quote rule.
                           ((and c (char=? c #\`)
                                 (save-match-data
                                   (let ((at (save-excursion
                                               (search-forward "'" #f #t))))
                                     (when at
                                       (set! end-point (- at 1))
                                       #t))))
                            (let ((k (buffer-substring-no-properties
                                      (+ orig-point 2) end-point)))
                              (when (or (key-valid-p k)
                                        (string-match-p "\\`mouse-[1-9]" k)
                                        (string-match-p "\\`M-x " k))
                                (goto-char orig-point)
                                (delete-region (point) (+ (point) 2))
                                (goto-char (- end-point 2))
                                (delete-region (point) (+ (point) 1))
                                (unless no-face
                                  (add-text-properties
                                   orig-point (point)
                                   (list 'face 'help-key-binding
                                         'font-lock-face 'help-key-binding))))))
                           ;; 1D. `\[COMMAND]' is replaced by its key
                           ;; description, or "M-x COMMAND".
                           ((and c (char=? c #\[)
                                 (save-match-data
                                   (let ((at (save-excursion
                                               (search-forward "]" #f #t))))
                                     (when at
                                       (set! end-point (- at 2))
                                       #t))))
                            (goto-char orig-point)
                            (delete-region (point) (+ (point) 2))
                            (let* ((fun (string->symbol
                                         (buffer-substring-no-properties
                                          (point) (- end-point 1))))
                                   (key (parameterize ((*current-buffer* orig-buf))
                                          (where-is-internal
                                           fun (and keymap (list keymap))
                                           #t #f #f))))
                              ;; "If we're looking in a particular keymap
                              ;; which has no binding, then we need to
                              ;; redo the lookup, with the global map as
                              ;; well this time."
                              (when (and (not key) keymap)
                                (set! key (parameterize ((*current-buffer* orig-buf))
                                            (where-is-internal fun keymap #t #f #f))))
                              (if (not key)
                                  ;; "Function is not on any key."
                                  (let ((op (point)))
                                    (insert "M-x ")
                                    (goto-char (+ end-point 3))
                                    (unless no-face
                                      (add-text-properties
                                       op (point)
                                       (list 'face 'help-key-binding
                                             'font-lock-face 'help-key-binding)))
                                    (delete-region (point) (+ (point) 1)))
                                  (begin
                                    (delete-region (point) end-point)
                                    (insert
                                     (if no-face
                                         (key-description key)
                                         (help--key-description-fontified key)))))))
                           ;; 1E is not carried (see the header): the
                           ;; forms are left as they stand, and the next
                           ;; pass treats the `{' or `<` as ordinary.
                           (else #f))))
                       ;; 2. Quotes, under `curve' and `straight'.
                       ((and (eq? (text-quoting-style) 'curve)
                             (or (and (char=? (char-after (point)) #\`)
                                      (begin (insert "‘") #t))
                                 (and (char=? (char-after (point)) #\')
                                      (begin (insert "’") #t))))
                        ;; `insert` leaves point after the quote; the
                        ;; backtick/apostrophe is now the character at
                        ;; point, and that is the `(delete-char 1)`.
                        (delete-region (point) (+ (point) 1)))
                       ((and (eq? (text-quoting-style) 'straight)
                             (char=? (char-after (point)) #\`))
                        (insert "'")
                        (delete-region (point) (+ (point) 1)))
                       ;; 3. Nothing to do - next character.
                       (else (forward-char 1))))
                    (loop)))
                (buffer-string))))))))
