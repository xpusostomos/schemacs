(define-library (schemacs editor scheme)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/scheme.el' - the
  ;; syntax table, `scheme-mode-variables', the two font-lock keyword
  ;; levels and the `scheme-mode' built from them.
  ;;
  ;; The keyword regexps are Emacs's own: the level-2 control-structure
  ;; pattern is built at load time with `regexp-opt', exactly as the C
  ;; builds it, and the rest are the C's literals.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `scheme-syntax-propertize' and its rules - `syntax-propertize-
  ;;     rules', the macro, is not ported. `#;' datum comments and
  ;;     `#|...|#' block comments therefore parse by the table alone.
  ;;   * `scheme-indent-function', `scheme-let-indent' and the
  ;;     `scheme-indent-function' properties - `lisp-indent-line' and
  ;;     `calculate-lisp-indent' are lisp-mode's, and are not ported.
  ;;   * `scheme-mode-line-process', `run-scheme' and the inferior
  ;;     process half (`cmuscheme.el').
  ;;   * `scheme-imenu-generic-expression' and the imenu variables, and
  ;;     `lisp-doc-string-elt-property' - imenu and the doc-string face
  ;;     are not ported.

  (import
    (scheme base)
    (scheme char)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer) current-buffer set-buffer-local-value!)
    (only (schemacs editor syntax) modify-syntax-entry set-syntax-table)
    (only (schemacs editor subr) make-syntax-table)
    (only (schemacs editor prog-mode) prog-mode)
    (only (schemacs editor files) *mode-require-final-newline*)
    (only (schemacs editor font-lock) set!font-lock-defaults!
          font-lock-register-keyword-variable!)
    (only (schemacs regexp-opt) regexp-opt)
    (only (schemacs editor search) match-beginning))

  (export scheme-mode scheme-mode-map scheme-mode-hook scheme-mode-hook
          scheme-mode-syntax-table scheme-mode-variables
          scheme-font-lock-keywords
          scheme-font-lock-keywords-1 scheme-font-lock-keywords-2)

  (begin

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does - see lisp-mode's copy.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    ;;----------------------------------------------------------------
    ;; The syntax table
    ;;------------------------------------------------------------------

    (define scheme-mode-syntax-table
      ;; GNU Emacs's `scheme-mode-syntax-table' (scheme.el:55). "We used
      ;; to treat chars 128-256 as symbol-constituent, but they should be
      ;; valid word constituents" - so the four loops stop at 128, and
      ;; what is above inherits word syntax from the standard table.
      ;;--------------------------------------------------------------
      (let ((st (make-syntax-table)))
        (let loop ((c 0))
          (when (< c 128)
            (unless (or (char<=? #\0 (integer->char c) #\9)
                        (char<=? #\A (integer->char c) #\Z)
                        (char<=? #\a (integer->char c) #\z))
              (modify-syntax-entry (integer->char c) "_   " st))
            (loop (+ c 1))))
        ;; Whitespace
        (modify-syntax-entry #\tab "    " st)
        (modify-syntax-entry #\newline ">   " st)
        (modify-syntax-entry #\page "    " st)
        (modify-syntax-entry #\return "    " st)
        (modify-syntax-entry #\space "    " st)
        ;; "These characters are delimiters but otherwise undefined.
        ;; Brackets and braces balance for editing convenience."
        (modify-syntax-entry #\[ "(]  " st)
        (modify-syntax-entry #\] ")[  " st)
        (modify-syntax-entry #\{ "(}  " st)
        (modify-syntax-entry #\} "){  " st)
        (modify-syntax-entry #\| "\" 23bn" st)
        ;; Other atom delimiters
        (modify-syntax-entry #\( "()  " st)
        (modify-syntax-entry #\) ")(  " st)
        ;; "It's used for single-line comments as well as for #;(...)
        ;; sexp-comments."
        (modify-syntax-entry #\; "<" st)
        (modify-syntax-entry #\" "\"   " st)
        (modify-syntax-entry #\' "'   " st)
        (modify-syntax-entry #\` "'   " st)
        ;; Special characters
        (modify-syntax-entry #\, "'   " st)
        (modify-syntax-entry #\@ "'   " st)
        (modify-syntax-entry #\# "' 14" st)
        (modify-syntax-entry #\\ "\\   " st)
        st))

    ;;----------------------------------------------------------------
    ;; The keyword tables
    ;;------------------------------------------------------------------

    (define scheme-font-lock-keywords-1
      ;; GNU Emacs's `scheme-font-lock-keywords-1' (scheme.el:309),
      ;; "Subdued expressions to highlight in Scheme modes."
      ;;
      ;; The last element is a *face function*: which face the name gets
      ;; depends on which group matched.
      ;;--------------------------------------------------------------
      (list
       (list
        (string-append "(\\(define\\*?\\("
                       "\\(\\|-public\\|-method\\|-generic\\(-procedure\\)?\\)\\|"
                       "\\(-syntax\\|-macro\\)\\|"
                       "-class"
                       "\\|-module"
                       "\\)\\)\\>"
                       "[ \t]*(*"
                       "\\(\\sw+\\)?")
        (list 1 'font-lock-keyword-face)
        (list 6 (lambda ()
                  (cond ((match-beginning 3) 'font-lock-function-name-face)
                        ((match-beginning 5) 'font-lock-variable-name-face)
                        (else 'font-lock-type-face)))
              #f #t))))

    (define scheme-font-lock-keywords-2
      ;; GNU Emacs's `scheme-font-lock-keywords-2' (scheme.el:338),
      ;; "Gaudy expressions to highlight in Scheme modes."
      ;;--------------------------------------------------------------
      (append
       scheme-font-lock-keywords-1
       (list
        ;; "Control structures."
        (cons (string-append
               "("
               (regexp-opt
                '("begin" "call-with-current-continuation" "call/cc"
                  "call-with-input-file" "call-with-output-file"
                  "call-with-port"
                  "case" "cond"
                  "do" "else" "for-each" "if" "lambda" "λ"
                  "let" "let*" "let-syntax" "letrec" "letrec-syntax"
                  ;; R6RS library subforms.
                  "export" "import"
                  ;; SRFI 11 usage comes up often enough.
                  "let-values" "let*-values"
                  ;; Hannes Haug wants these.
                  "and" "or" "delay" "force"
                  "map" "syntax" "syntax-rules"
                  ;; For R7RS
                  "when" "unless" "letrec*" "include" "include-ci"
                  "cond-expand"
                  "delay-force" "parameterize" "guard" "case-lambda"
                  "syntax-error" "only" "except" "prefix" "rename"
                  "define-values"
                  "define-record-type" "define-library"
                  "include-library-declarations"
                  ;; SRFI-8
                  "receive")
                #t)
               "\\>")
              1)
        ;; "It wouldn't be Scheme without named-let."
        (list "(let\\s-+\\(\\sw+\\)" (list 1 'font-lock-function-name-face))
        ;; "David Fox for SOS/STklos class specifiers."
        (cons "\\<<\\sw+>\\>" 'font-lock-type-face)
        ;; "Scheme `:' and `#:' keywords as builtins."
        (cons "\\<#?:\\sw+\\>" 'font-lock-builtin-face)
        ;; "R6RS library declarations."
        (list "(\\(\\<library\\>\\)\\s-*(?\\(\\sw+\\)?"
              (list 1 'font-lock-keyword-face)
              (list 2 'font-lock-type-face)))))

    (define scheme-font-lock-keywords scheme-font-lock-keywords-1)

    ;; the three names `font-lock-defaults' uses
    (for-each (lambda (pair)
                (font-lock-register-keyword-variable! (car pair) (cdr pair)))
              (list (cons 'scheme-font-lock-keywords scheme-font-lock-keywords)
                    (cons 'scheme-font-lock-keywords-1 scheme-font-lock-keywords-1)
                    (cons 'scheme-font-lock-keywords-2 scheme-font-lock-keywords-2)))

    ;; ^ GNU Emacs's `scheme-font-lock-keywords' (scheme.el:389): the
    ;; *subdued* list; `font-lock-maximum-decoration' picks the last of
    ;; the three.

    ;;----------------------------------------------------------------
    ;; `scheme-mode-variables'
    ;;------------------------------------------------------------------

    (define (scheme-mode-variables)
      ;; GNU Emacs's `scheme-mode-variables' (scheme.el:173).
      ;;--------------------------------------------------------------
      (set-syntax-table scheme-mode-syntax-table)
      (setq-local 'paragraph-start "$\\|\\f")
      (setq-local 'paragraph-separate "$\\|\\f")
      (setq-local 'paragraph-ignore-fill-prefix #t)
      (setq-local 'fill-paragraph-function 'lisp-fill-paragraph)
      ;; "Adaptive fill mode gets in the way of auto-fill"
      (setq-local 'adaptive-fill-mode #f)
      (setq-local 'indent-line-function 'lisp-indent-line)
      (setq-local 'parse-sexp-ignore-comments #t)
      (setq-local 'outline-regexp ";;; \\|(....")
      (setq-local 'add-log-current-defun-function 'lisp-current-defun-name)
      (setq-local 'comment-start ";")
      (setq-local 'comment-add 1)
      (setq-local 'comment-start-skip ";+[ \t]*")
      (setq-local 'comment-use-syntax #t)
      (setq-local 'comment-column 40)
      (setq-local 'lisp-indent-function 'scheme-indent-function)
      (setq-local 'imenu-case-fold-search #t)
      (set!font-lock-defaults!
       (list
        (list 'scheme-font-lock-keywords
              'scheme-font-lock-keywords-1
              'scheme-font-lock-keywords-2)
        #f #t
        ;; SYNTAX-ALIST: "the characters that make up identifiers but
        ;; have punctuation syntax in the table", given word syntax for
        ;; the fontification only - the buffer's own table is untouched.
        (list (cons "+-*/.<>=!?$%_&~^:" "w")
              (cons #\#
                    "w 14"))
        'beginning-of-defun
        (cons 'font-lock-mark-block-function 'mark-defun))))

    ;;----------------------------------------------------------------
    ;; `scheme-mode'
    ;;------------------------------------------------------------------

    (define scheme-mode-map
      ;; GNU Emacs's `scheme-mode-map', which `define-derived-mode' makes
      ;; for the mode below; its parent is `lisp-mode-shared-map', whose
      ;; keys come from `prog-mode-map' here.
      ;;--------------------------------------------------------------
      (km:keymap '*scheme-mode-map*))

    (define scheme-mode-hook '())

    (define-derived-mode (scheme-mode prog-mode "Scheme" scheme-mode-map
                                      scheme-mode-hook
                                      scheme-mode-syntax-table)
      "Major mode for editing Scheme code.
Editing commands are similar to those of `lisp-mode'."
      (scheme-mode-variables))

    ))
