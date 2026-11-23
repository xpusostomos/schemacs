(define-library (schemacs progmodes elisp-mode)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/elisp-mode.el' -
  ;; `emacs-lisp-mode' and `lisp-interaction-mode', their syntax table
  ;; and keymaps, and the syntax-propertize function the mode installs.
  ;;
  ;; Emacs 31 keeps `emacs-lisp-mode' in `elisp-mode.el' and the keyword
  ;; tables it uses in `lisp-mode.el'; both files have a library here,
  ;; and this one is the mode.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `syntax-propertize-rules', the macro, is not ported (see
  ;;     `syntax.scm`'s header); `elisp-mode-syntax-propertize' is here,
  ;;     written out as the four scans the macro would build.
  ;;   * the eldoc, xref, flymake, completion-at-point, electric-pair and
  ;;     context-menu entries the mode adds to their hooks: none of those
  ;;     subsystems exists here.
  ;;   * the `lexical-binding' mode-line construct
  ;;     (`elisp-enable-lexical-binding' and its mouse map): the mode line
  ;;     is a list of `mode-line-format' constructs here and this one is
  ;;     a `:propertize' form, which the renderer does not read.
  ;;   * `eval-defun', `elisp-eval-region-or-buffer' and the byte/native
  ;;     compilation commands - `eval-region' exists, `eval-defun' does
  ;;     not.

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr)
    (prefix (schemacs keymap) km:)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs buffer)
          current-buffer set-buffer-local-value! set-point buffer-pt)
    (only (schemacs syntax) modify-syntax-entry string-to-syntax
          syntax-ppss)
    (only (schemacs search)
          re-search-forward match-beginning match-end
          syntax-propertize-rules)
    (only (schemacs buffer) *case-fold-search*)
    (only (schemacs textprop) put-text-property)
    (only (schemacs subr) make-syntax-table)
    (only (schemacs core lisp-mode) lisp-data-mode lisp-data-mode-syntax-table
          lisp-mode-shared-map lisp-mode-variables)
    (only (schemacs custom) define-custom)
    (only (schemacs core lisp)
          forward-sexp beginning-of-defun end-of-defun)
    (only (schemacs editfns)
          point point-marker point-min point-max goto-char insert
          buffer-substring save-excursion message)
    (only (schemacs minibuffer)
          eval-expression-print-format eval-expression-get-print-arguments)
    (only (schemacs loadup) open-user-environment!)
    (only (schemacs command)
          define-command current-prefix-arg uarg->integer)
    (only (schemacs keymap) define-key)
    (only (schemacs subr) kbd)
    (only (scheme eval) eval)
    (only (scheme read) read)
    (only (scheme write) write))

  (export emacs-lisp-mode emacs-lisp-mode-map emacs-lisp-mode-hook
          emacs-lisp-mode-syntax-table elisp-mode-syntax-propertize
          eval-last-sexp eval-print-last-sexp eval-defun
          elisp--preceding-sexp
          lisp-interaction-mode lisp-interaction-mode-map
          lisp-interaction-mode-hook)

  (begin

    (define emacs-lisp-mode-syntax-table
      ;; GNU Emacs's `emacs-lisp-mode-syntax-table' (elisp-mode.el:41):
      ;; `lisp-data-mode-syntax-table' with the "p" flag taken off `@',
      ;; because `,@' is handled precisely by `syntax-propertize' there
      ;; (`elisp-mode-syntax-propertize', below).
      ;;--------------------------------------------------------------
      (let ((table (make-syntax-table lisp-data-mode-syntax-table)))
        (modify-syntax-entry #\@ "_" table)
        table))

    (define emacs-lisp-mode-map
      ;; GNU Emacs's `emacs-lisp-mode-map' (elisp-mode.el:50). The keys
      ;; whose commands exist here are bound; the rest are named in this
      ;; library's header.
      ;;--------------------------------------------------------------
      (km:keymap '*emacs-lisp-mode-map*))

    ;; ":parent lisp-mode-shared-map" (`elisp-mode.el:53`), which is
    ;; where `C-M-q' (`indent-sexp') lives.
    (km:set-keymap-parent emacs-lisp-mode-map lisp-mode-shared-map)

    (define (elisp-mode-syntax-propertize start end)
      ;; GNU Emacs's `elisp-mode-syntax-propertize' (`elisp-mode.el:259'):
      ;; "Add syntax-table properties to Emacs Lisp code between START
      ;; and END. Used as the value of `syntax-propertize-function' in
      ;; `emacs-lisp-mode'."
      ;;
      ;; The C is one call to `(syntax-propertize-rules ...)', whose
      ;; rules are the four below; the engine (`syntax.el') lives in
      ;; `(schemacs search)' - see its placement note - and gives
      ;; the **single scan** the rules need.
      ;;
      ;; Each action refuses to fire inside a string or comment, which
      ;; is what `(nth 8 (syntax-ppss))` answers - at point for the
      ;; first three (the C's `(unless (nth 8 (syntax-ppss)) ...)`,
      ;; where point is the match end) and at the match start for the
      ;; last (`(save-excursion (nth 8 (syntax-ppss (match-beginning
      ;; 0))))`).
      ;;--------------------------------------------------------------
      (set-point (current-buffer) start)
      (parameterize ((*case-fold-search* #f))
        ((syntax-propertize-rules
          (list
           ;; "Empty symbol."
           (list "##"
                 (list 0 (lambda ()
                           (if (list-ref (syntax-ppss) 8)
                               #f
                               (string-to-syntax "_")))))
           ;; "Prevent the @ from becoming part of a following symbol."
           (list ",@"
                 (list 0 (lambda ()
                           (if (list-ref (syntax-ppss) 8)
                               #f
                               (string-to-syntax "'")))))
           ;; "Unicode character names. (The longest name is 88
           ;; characters long.)"
           (list "\\?\\\\N{[-A-Za-z0-9 ]\\{,100\\}}"
                 (list 0 (lambda ()
                           (if (list-ref (syntax-ppss) 8)
                               #f
                               (string-to-syntax "_")))))
           ;; "Bool-vector (`#&N"'), record (`#s(') and char-table
           ;; (`#^^['): the part after the `#' gets quote syntax."
           (list "#\\(?:\\(?1:&[0-9]+\\)\"\\|\\(?1:s\\)(\\|\\(?1:\\^+\\)\\[\\)"
                 (list 1 (lambda ()
                           (if (save-excursion
                                 (list-ref (syntax-ppss (match-beginning 0)) 8))
                               #f
                               (string-to-syntax "'")))))))
         (buffer-pt (current-buffer))
         end))
      #f)

    (define emacs-lisp-mode-hook '())

    (define-custom *emacs-lisp-mode-hook* '()
      "Hook run when entering Emacs Lisp mode."
      :type 'hook
      :group 'lisp)

    (define-derived-mode (emacs-lisp-mode lisp-data-mode "Elisp"
                                          emacs-lisp-mode-map
                                          emacs-lisp-mode-hook
                                          emacs-lisp-mode-syntax-table)
      "Major mode for editing Lisp code to run in Emacs."
      ;; "(lisp-mode-variables nil nil t)" - LISP-SYNTAX nil keeps the
      ;; table the parent mode set, KEYWORDS-CASE-INSENSITIVE nil (Elisp
      ;; keywords are case sensitive), ELISP t.
      (lisp-mode-variables #f #f #t)
      ;; "(setq-local syntax-propertize-function
      ;;   #'elisp-mode-syntax-propertize)" (`elisp-mode.el:763').
      (set-buffer-local-value! (current-buffer) 'syntax-propertize-function
                               elisp-mode-syntax-propertize))

    (define lisp-interaction-mode-map
      ;; GNU Emacs's `lisp-interaction-mode-map' (elisp-mode.el:1756).
      ;;--------------------------------------------------------------
      (km:keymap '*lisp-interaction-mode-map*))
    ;; ":parent lisp-mode-shared-map" (`elisp-mode.el:1759').
    (km:set-keymap-parent lisp-interaction-mode-map lisp-mode-shared-map)

    (define lisp-interaction-mode-hook '())

    (define-derived-mode (lisp-interaction-mode emacs-lisp-mode
                                                "Lisp Interaction"
                                                lisp-interaction-mode-map
                                                lisp-interaction-mode-hook)
      "Major mode for typing and evaluating Lisp forms.
Like Lisp mode except that \\[eval-print-last-sexp] evals the Lisp
expression before point, inserting the value into the buffer as text."
      #t)

    ;; ---------------------------------------------------------------
    ;; `eval-last-sexp', `eval-print-last-sexp' and `eval-defun'
    ;; (elisp-mode.el:1859-2245).
    ;;
    ;; **The evaluator is Scheme's**, the departure `eval-expression' and
    ;; `eval-region' already carry: Emacs's `eval' runs Emacs Lisp, and
    ;; this editor has no Lisp evaluator under it. What is read is the
    ;; text the sexp motions land on, and what runs is that expression.
    ;;
    ;; Not carried, each named against what it waits for:
    ;;
    ;;   * `elisp--preceding-sexp''s Emacs-reader syntax - the `...'' and
    ;;     ‘...’ quote stripping, the `?\e' character literal, `#s' hash
    ;;     tables and `#N=' labels - because the reader is Scheme's.
    ;;   * `eval-sexp-add-defvars', `elisp--eval-defun-1' and
    ;;     `eval-defun-1': they exist to re-run a `defvar'/`defcustom'/
    ;;     `defface' initializer. Scheme has no `defvar'.
    ;;   * `lexical-binding' and the `macroexpand-all' the C does first.
    ;;   * `eval-expression-insert-value', `eval-expression-print-length'
    ;;     and `-print-level': this tree's printer has no truncation to
    ;;     bind.
    ;; ---------------------------------------------------------------
    (define (elisp--preceding-sexp)
      ;; GNU Emacs's `elisp--preceding-sexp' (`elisp-mode.el:1956'):
      ;; "Return sexp before the point."
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((opoint (point)))
          (forward-sexp -1)
          (read (open-input-string (buffer-substring (point) opoint))))))

    (define (%eval-last-sexp-value->string value)
      (call-with-port (open-output-string)
        (lambda (port) (write value port) (get-output-string port))))

    (define (elisp--eval-last-sexp-print-value value output no-truncate
                                               char-print-limit)
      ;; GNU Emacs's `elisp--eval-last-sexp-print-value'
      ;; (`elisp-mode.el:2042'): "print value in the echo area", or into
      ;; the buffer when OUTPUT is one. `last-sexp-setup-props' - the
      ;; text properties that make the echoed value clickable - is not
      ;; carried.
      ;;--------------------------------------------------------------
      (let ((str (%eval-last-sexp-value->string value))
            (suffix (and char-print-limit
                         (eval-expression-print-format value))))
        (if (eq? output #t)
            (message "%s" (if suffix (string-append str suffix) str))
            (begin
              (insert str)
              (if suffix (insert suffix))))))

    (define (elisp--eval-last-sexp eval-last-sexp-arg-internal)
      ;; GNU Emacs's `elisp--eval-last-sexp' (`elisp-mode.el:2021').
      ;;--------------------------------------------------------------
      (let ((args (eval-expression-get-print-arguments
                   eval-last-sexp-arg-internal)))
        (let ((insert-value (list-ref args 0))
              (no-truncate (list-ref args 1))
              (char-print-limit (list-ref args 2)))
          (let ((output (if insert-value (current-buffer) #t)))
          (elisp--eval-last-sexp-print-value
             (eval (elisp--preceding-sexp) (open-user-environment!))
             output no-truncate char-print-limit)))))

    (define-command (eval-last-sexp arg)
      "Evaluate sexp before point; print value in the echo area."
      (interactive (list (current-prefix-arg)))
      (elisp--eval-last-sexp arg))

    (define-command (eval-print-last-sexp . rest)
      "Evaluate sexp before point; print value into current buffer."
      (interactive (list (current-prefix-arg)))
      (let ((arg (if (pair? rest) (car rest) #f)))
        ;; `(let ((standard-output (current-buffer))) (terpri) ...)' -
        ;; this tree has no `standard-output', so the newlines are put
        ;; where that binding would have put them.
        (insert "\n")
        (eval-last-sexp arg)
        (insert "\n")))

    (define (elisp--eval-defun)
      ;; GNU Emacs's `elisp--eval-defun' (`elisp-mode.el:2159'):
      ;; "Evaluate defun that point is in or before. The value is
      ;; displayed in the echo area."
      ;;--------------------------------------------------------------
      (save-excursion
        ;; "Read the form from the buffer, and record where it ends."
        (end-of-defun)
        (let ((end (point)))
          (beginning-of-defun)
          (let* ((beg (point))
                 (form (read (open-input-string
                              (buffer-substring beg end)))))
            (let ((result (eval form (open-user-environment!))))
              (let ((str (eval-expression-print-format result)))
                (when str (message "%s" str)))
              result)))))

    (define-command (eval-defun . rest)
      "Evaluate top-level form around point and instrument it if EDEBUG-IT is non-nil."
      (interactive (list (current-prefix-arg)))
      ;; EDEBUG-IT - the prefix argument - would instrument the form
      ;; first; there is no Edebug here, so it is read and unused.
      (let ((edebug-it (if (pair? rest) (car rest) #f)))
        edebug-it
        (elisp--eval-defun)))

    (define-key km:*default-keymap* (kbd "C-x C-e") eval-last-sexp)
    (define-key km:*default-keymap* (kbd "C-M-x") eval-defun)

    ))
