(define-library (schemacs progmodes scheme)
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
  ;;   * `scheme-mode-line-process', `run-scheme' and the inferior
  ;;     process half (`cmuscheme.el').
  ;;   * `scheme-imenu-generic-expression' and the imenu variables -
  ;;     imenu is not ported.

  (import
    (scheme base)
    (scheme char)
    (prefix (schemacs keymap) km:)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs buffer) current-buffer set-buffer-local-value!)
    (only (schemacs syntax) modify-syntax-entry set-syntax-table)
    (only (schemacs subr) make-syntax-table)
    (only (schemacs progmodes prog-mode) prog-mode)
    (only (schemacs files) *mode-require-final-newline*)
    (only (schemacs font-lock) set!font-lock-defaults!
          font-lock-register-keyword-variable!)
    (only (schemacs core regexp-opt) regexp-opt)
    (only (schemacs search)
          match-beginning match-end looking-at string-match
          re-search-forward syntax-propertize-rules)
    (only (schemacs core lisp-mode)
          lisp-indent-line lisp-indent-function lisp-indent-specform
          lisp-indent-defform *calculate-lisp-indent-last-sexp*)
    (only (schemacs syntax)
          parse-partial-sexp skip-chars-forward skip-chars-backward
          forward-comment backward-prefix-chars syntax-ppss string-to-syntax)
    (only (schemacs core lisp) forward-sexp)
    (only (schemacs syntax) scan-error?)
    (only (schemacs editfns)
          goto-char point point-max buffer-substring forward-line char-after
          save-excursion save-restriction narrow-to-region point-min)
    ;; `beginning-of-line' is the *command* (`cmds.c'), as it is in
    ;; lisp-mode's own import
    (only (schemacs cmds) beginning-of-line backward-char)
    (only (schemacs indentc) current-column)
    (only (schemacs intervals) get put)
    (only (schemacs textprop) put-text-property get-text-property)
    (only (schemacs custom) define-custom))

  (export scheme-mode scheme-mode-map scheme-mode-hook scheme-mode-hook
          scheme-mode-syntax-table scheme-mode-variables
          scheme-font-lock-keywords
          scheme-font-lock-keywords-1 scheme-font-lock-keywords-2
          scheme-indent-function scheme-let-indent *scheme-mit-dialect*
          scheme-syntax-propertize scheme-syntax-propertize-sexp-comment
          scheme-syntax-propertize-regexp)

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

    ;;----------------------------------------------------------------
    ;; The indentation (`scheme.el:562-760')
    ;;------------------------------------------------------------------
    ;; `scheme-indent-function' is "Scheme mode function for the value of
    ;; the variable `lisp-indent-function'", and the `put' table below is
    ;; what it consults: "for forms with no `scheme-indent-function'
    ;; property the 2nd and subsequent lines will be indented with one
    ;; space; if the value of the property is zero ... two spaces; if the
    ;; value is a positive integer N, the first N lines ... four spaces
    ;; and the rest two; if the value is `defun', like for `defun'; if a
    ;; function, it is called."

    ;;----------------------------------------------------------------
    ;; `scheme-syntax-propertize' (`scheme.el:684-760')
    ;;------------------------------------------------------------------
    ;; `#;' datum comments and `#|...|#' block comments are not syntax
    ;; the table can say, so the mode propertizes them: `#;' is given a
    ;; comment-open syntax and the end of the commented sexp a
    ;; comment-close one, and a `#/.../' regexp's closing `/` becomes a
    ;; string delimiter.
    ;;
    ;; **The C narrows to END around `forward-sexp`** so that a sexp
    ;; running past END is a `scan-error`; this is that narrowing, since
    ;; 2026-11-17 the primitive is here.
    (define (scheme-syntax-propertize-sexp-comment end)
      ;; The C's `while' has a recursion inside its body - a nested `#;'
      ;; restarts the whole scan after marking itself - so a continued
      ;; iteration is `iterate', and **every** exit from it writes the
      ;; closing marker for that iteration's FOUND, which is what the C's
      ;; `(when found ...)' after the `while' does.
      ;;--------------------------------------------------------------
      (let ((state (syntax-ppss))
            (checked (point)))
        (when (eqv? 2 (list-ref state 7))
          ;; "It's a sexp-comment. Tell parse-partial-sexp where it ends."
          (let loop ((startpos (+ 2 (list-ref state 8))))
            (define (iterate)
              (let ((found
                     ;; The C's
                     ;;
                     ;;   (condition-case nil
                     ;;       (save-restriction
                     ;;         (narrow-to-region (point-min) end)
                     ;;         (goto-char startpos)
                     ;;         (forward-sexp 1)
                     ;;         (setq found (point)))
                     ;;     (scan-error (goto-char end)))
                     ;;
                     ;; - the narrowing is what turns "the sexp runs past
                     ;; END" into the `scan-error` this catches, and it is
                     ;; the primitive's whole job here.
                     (guard (e ((scan-error? e) (goto-char end) #f))
                       (save-restriction
                         (narrow-to-region (point-min) end)
                         (goto-char startpos)
                         (forward-sexp 1)
                         (point)))))
                (let ((limit (min end (or found end))))
                  (if (< checked limit)
                      (begin
                        (goto-char checked)
                        ;; "Skip those #; inside comments and strings."
                        (let scan ()
                          (cond ((not (re-search-forward "\\\\(#\\\\);" limit #t))
                                 (goto-char limit))  ; the C's `'move'
                                ((list-ref (save-excursion
                                             (parse-partial-sexp
                                              startpos (match-beginning 0)))
                                           8)
                                 (scan))
                                (else #f)))
                        (set! checked (point))
                        (if (< (point) limit)
                            (begin
                              (put-text-property (match-beginning 1)
                                                 (match-end 1)
                                                 'syntax-table
                                                 (string-to-syntax "< cn"))
                              ;; "Try the `forward-sexp' with the new text
                              ;; state."
                              (loop (point))
                              (iterate))
                            (when found
                              (goto-char found)
                              (put-text-property (- found 1) found
                                                 'syntax-table
                                                 (string-to-syntax "> cn")))))
                      (when found
                        (goto-char found)
                        (put-text-property (- found 1) found
                                           'syntax-table
                                           (string-to-syntax "> cn")))))))
             (iterate)))))

    (define (scheme-syntax-propertize-regexp end)
      (let* ((state (syntax-ppss))
             (within-str (list-ref state 3))
             (start-delim-pos (list-ref state 8)))
        (when (and within-str
                   (char=? #\# (char-after start-delim-pos)))
          ;; The same `'move' as above: a failed search goes to END.
          (let scan ()
            (cond ((not (re-search-forward "/" end #t)) (goto-char end))
                  ((eqv? -1 (modulo (save-excursion
                                      (backward-char)
                                      (skip-chars-backward "\\\\"))
                                    2))
                   (scan))
                  (else #f)))
          (when (< (point) end)
            (put-text-property (match-beginning 0) (match-end 0)
                               'syntax-table (string-to-syntax "|"))))))

    (define (scheme-syntax-propertize beg end)
      ;; "Add syntax-table properties to Scheme code between BEG and END.
      ;; Used as the value of `syntax-propertize-function' in
      ;; `scheme-mode'."
      ;;--------------------------------------------------------------
      (goto-char beg)
      (scheme-syntax-propertize-sexp-comment end)
      (scheme-syntax-propertize-regexp end)
      ((syntax-propertize-rules
        (list
         (list "\\(#\\);"
               (list 1 (list 'prog1 "< cn"
                             (lambda () (scheme-syntax-propertize-sexp-comment end)))))
         (list "\\(#\\)/"
               (list 1 (lambda ()
                         (if (list-ref (save-excursion
                                         (syntax-ppss (match-beginning 0)))
                                       8)
                             #f
                             (begin
                               (put-text-property (match-beginning 1)
                                                  (match-end 1)
                                                  'syntax-table
                                                  (string-to-syntax "|"))
                               (scheme-syntax-propertize-regexp end)
                               #f)))))))
       (point) end)
      )

    (define *scheme-mit-dialect* (make-parameter #t))
    ;; ^ GNU Emacs's `scheme-mit-dialect' (`scheme.el:262'), "If non-nil,
    ;; scheme mode is specialized for MIT Scheme" - the default is `t',
    ;; and the table below is what that gates.

    (define (scheme-indent-function indent-point state)
      ;; "This behaves like the function `lisp-indent-function', except
      ;; that: i) it checks for a non-nil value of the property
      ;; `scheme-indent-function' (or the deprecated `scheme-indent-hook')
      ;; ... ii) if that property specifies a function, it is called with
      ;; three arguments (not two), the third argument being the default
      ;; (i.e., current) indentation."
      ;;--------------------------------------------------------------
      (let ((normal-indent (current-column)))
        (goto-char (+ 1 (list-ref state 1)))
        (parse-partial-sexp (point) *calculate-lisp-indent-last-sexp* 0 #t)
        (if (and (list-ref state 2)
                 (not (looking-at "\\sw\\|\\s_")))
            ;; "car of form doesn't seem to be a symbol"
            (begin
              (if (not (> (save-excursion (forward-line 1) (point))
                          *calculate-lisp-indent-last-sexp*))
                  (begin (goto-char *calculate-lisp-indent-last-sexp*)
                         (beginning-of-line)
                         (parse-partial-sexp (point)
                                             *calculate-lisp-indent-last-sexp*
                                             0 #t)))
              ;; "Indent under the list or under the first sexp on the
              ;; same line as calculate-lisp-indent-last-sexp."
              (backward-prefix-chars)
              (current-column))
            (let ((function (buffer-substring
                             (point) (begin (forward-sexp 1) (point)))))
              (let ((method (or (get (string->symbol function)
                                     'scheme-indent-function)
                                (get (string->symbol function)
                                     'scheme-indent-hook))))
                (cond ((or (eq? method 'defun)
                           (and (not method)
                                (> (string-length function) 3)
                                (string-match "\\`def" function)))
                       (lisp-indent-defform state indent-point))
                      ((integer? method)
                       (lisp-indent-specform method state
                                             indent-point normal-indent))
                      (else (if method
                                (method state indent-point normal-indent)
                                #f))))))))

    (define (scheme-let-indent state indent-point normal-indent)
      ;; "Let is different in Scheme" (`scheme.el:626').
      ;;--------------------------------------------------------------
      (skip-chars-forward " \t")
      (if (looking-at "[-a-zA-Z0-9+*/?!@$%^&_:~]")
          (lisp-indent-specform 2 state indent-point normal-indent)
          (lisp-indent-specform 1 state indent-point normal-indent)))

    (for-each
     (lambda (entry)
       (put (car entry) 'scheme-indent-function
            (if (pair? (cdr entry)) (cdr entry) (cdr entry))))
     ;; `(put 'begin 'scheme-indent-function 0)' and its siblings, in the
     ;; C's order. A procedure's value is the procedure itself, since a
     ;; symbol is not callable here.
     (list
      (cons 'element 1) (cons 'mode 1) (cons 'with-mode 1) (cons 'make 1)
      (cons 'style 1) (cons 'root 1) (cons 'λ 1)
      (cons 'begin 0)
      (cons 'case 1)
      (cons 'delay 0)
      (cons 'do 2)
      (cons 'lambda 1)
      (cons 'let scheme-let-indent)
      (cons 'let* 1)
      (cons 'letrec 1)
      (cons 'let-values 1)
      (cons 'let*-values 1)
      (cons 'and-let* 1)
      (cons 'sequence 0)
      (cons 'let-syntax 1)
      (cons 'letrec-syntax 1)
      (cons 'syntax-rules 'defun)
      (cons 'syntax-case 2)
      (cons 'with-syntax 1)
      (cons 'library 1)
      (cons 'eval-when 1)
      (cons 'call-with-input-file 1)
      (cons 'call-with-port 1)
      (cons 'with-input-from-file 1)
      (cons 'with-input-from-port 1)
      (cons 'call-with-output-file 1)
      (cons 'with-output-to-file 1)
      (cons 'with-output-to-port 1)
      (cons 'call-with-values 1)
      (cons 'dynamic-wind 3)
      (cons 'when 1)
      (cons 'unless 1)
      (cons 'letrec* 1)
      (cons 'parameterize 1)
      (cons 'define-values 1)
      (cons 'define-record-type 1)
      (cons 'define-library 1)
      (cons 'guard 1)
      (cons 'receive 2)
      (cons 'test-group 1)
      (cons 'test-group-with-cleanup 1)
      (cons 'match 1)
      (cons 'match-lambda 0)
      (cons 'match-lambda* 0)
      (cons 'match-let scheme-let-indent)
      (cons 'match-let* 1)
      (cons 'match-letrec 1)
      (cons 'opt-lambda 1)
      (cons 'opt*-lambda 1)
      (cons 'let-optionals 2)
      (cons 'let-optionals* 2)
      (cons 'check-case 1)
      (cons 'lambda-checked 1)))

    ;; "MIT Scheme specific indentation" (`scheme.el:715'), which the C
    ;; runs only when `scheme-mit-dialect' is non-nil - and it defaults
    ;; to t.
    (when (*scheme-mit-dialect*)
      (for-each
       (lambda (entry) (put (car entry) 'scheme-indent-function (cdr entry)))
       (list
        (cons 'fluid-let 1) (cons 'in-package 1) (cons 'local-declare 1)
        (cons 'macro 1) (cons 'make-environment 0) (cons 'named-lambda 1)
        (cons 'using-syntax 1)
        (cons 'with-input-from-string 1) (cons 'with-output-to-string 0)
        (cons 'with-values 1)
        (cons 'syntax-table-define 2)
        (cons 'list-transform-positive 1) (cons 'list-transform-negative 1)
        (cons 'list-search-positive 1) (cons 'list-search-negative 1)
        (cons 'access-components 1) (cons 'assignment-components 1)
        (cons 'combination-components 1) (cons 'comment-components 1)
        (cons 'conditional-components 1) (cons 'disjunction-components 1)
        (cons 'declaration-components 1) (cons 'definition-components 1)
        (cons 'delay-components 1) (cons 'in-package-components 1)
        (cons 'lambda-components 1) (cons 'lambda-components* 1)
        (cons 'lambda-components** 1) (cons 'open-block-components 1)
        (cons 'pathname-components 1) (cons 'procedure-components 1)
        (cons 'sequence-components 1) (cons 'unassigned?-components 1)
        (cons 'unbound?-components 1) (cons 'variable-components 1))))

    ;; "Docstring's pos in a `define' depends on whether it's a var or
    ;; fun def" (`scheme.el:399-411'): the `define' entry is a *function*
    ;; of point, so it is called the way `lisp-string-in-doc-position-p'
    ;; calls one.
    (define (scheme--define-doc-string-elt)
      (forward-comment (point-max))
      (if (char=? (char-after (point)) #\() 2 0))

    (for-each
     (lambda (entry) (put (car entry) 'scheme-doc-string-elt (cdr entry)))
     (list
      (cons 'lambda 2)
      (cons 'lambda* 2)
      (cons 'define scheme--define-doc-string-elt)
      (cons 'define* 2)
      (cons 'case-lambda 1)
      (cons 'case-lambda* 1)
      (cons 'define-syntax-rule 2)
      (cons 'syntax-rules 2)
      (cons 'case-lambda-checked 1)))

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
      ;; The C stores the *symbol*; a symbol is not callable here, so
      ;; the procedure goes in (lisp-mode-variables does the same).
      (setq-local 'indent-line-function lisp-indent-line)
      (setq-local 'parse-sexp-ignore-comments #t)
      (setq-local 'outline-regexp ";;; \\|(....")
      (setq-local 'add-log-current-defun-function 'lisp-current-defun-name)
      (setq-local 'comment-start ";")
      (setq-local 'comment-add 1)
      (setq-local 'comment-start-skip ";+[ \t]*")
      (setq-local 'comment-use-syntax #t)
      (setq-local 'comment-column 40)
      (setq-local 'lisp-indent-function scheme-indent-function)
      ;; "Docstring's pos in a `define' depends on whether it's a var or
      ;; fun def" - `scheme-doc-string-elt' is the property this mode's
      ;; doc strings are read from (`scheme.el:399-411').
      (setq-local 'lisp-doc-string-elt-property 'scheme-doc-string-elt)
      (setq-local 'syntax-propertize-function scheme-syntax-propertize)
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
