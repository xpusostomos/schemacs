(define-library (schemacs editor lisp-mode)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/lisp-mode.el' -
  ;; the syntax tables, `lisp-mode-variables`, the font-lock keyword
  ;; tables, and the `lisp-data-mode' and `lisp-mode' that are built from
  ;; them. `emacs-lisp-mode' is `elisp-mode.scm''s, its own file in Emacs
  ;; 31.
  ;;
  ;; **The keyword regexps are transcribed, not rebuilt.** Emacs builds
  ;; them at load time with `regexp-opt' and `rx' over lists of names;
  ;; the strings here are what those calls produce, emitted from a
  ;; running Emacs 31.1. `rx' is not ported - it is a whole macro DSL -
  ;; and calling `regexp-opt' at load time would only move the same data
  ;; one step. The one place that still computes is
  ;; `lisp-mode-autoload-regexp', which is a plain literal.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `lisp-font-lock-syntactic-face-function', and with it the
  ;;     `font-lock-doc-face' on a docstring: it asks whether the string
  ;;     sits in doc position, which walks the list with `forward-sexp' -
  ;;     `scan_sexps_forward''s other half, not ported. Strings get
  ;;     `font-lock-string-face', which `font-lock-doc-face' inherits, so
  ;;     the difference is a face name rather than a colour.
  ;;   * the level-2 keyword *functions* - `lisp--el-match-keyword'
  ;;     (control structures, which needs the `lisp--el-keywords' list
  ;;     and `lisp-mode--search-key'), the `:'/`&' keyword matcher, the
  ;;     Elisp-regexp grouping matcher (which reads the `face' property),
  ;;     `lisp--match-hidden-arg' and `lisp--match-confusable-symbol-
  ;;     character'. The regexp entries they sit beside are all here.
  ;;   * `lisp-mode-syntax-propertize' and `elisp-mode-syntax-propertize':
  ;;     both are built on `syntax-propertize-rules', the macro, which is
  ;;     not ported. `|...|' symbols and `#(...)' vectors therefore parse
  ;;     as several expressions.
  ;;   * the `lisp-indent-line'/`indent-sexp' half - `lisp-indent.el''s
  ;;     `calculate-lisp-indent' - and `lisp-fill-paragraph'. The mode
  ;;     names them in `indent-line-function' and
  ;;     `fill-paragraph-function' in Emacs; here those names are stored
  ;;     with the rest of `lisp-mode-variables'' buffer-locals, but the
  ;;     functions do not exist, so TAB does whatever it did before.
  ;;   * `lisp-mode-abbrev-table', `lisp-imenu-generic-expression', the
  ;;     outline variables and `lisp-current-defun-name': abbrevs, imenu,
  ;;     outline and add-log are not ported.

  (import
    (scheme base)
    (scheme char)
    (only (guile) logand)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer)
          current-buffer major-mode set-buffer-local-value!)
    ;; the syntax-table writers, and `make-syntax-table', which is
    ;; subr.el's
    (only (schemacs editor syntax) modify-syntax-entry set-syntax-table)
    (only (schemacs editor subr) make-syntax-table)
    ;; the mode's parents, and the variables it copies
    (only (schemacs editor simple) fundamental-mode)
    (only (schemacs editor prog-mode) prog-mode)
    (only (schemacs editor files) *mode-require-final-newline*)
    ;; `font-lock-defaults' is buffer-local
    (only (schemacs editor font-lock) set!font-lock-defaults!
          font-lock-register-keyword-variable!)
    ;; the `lisp-define-type' property the definition keyword's face
    ;; function reads
    (only (schemacs editor intervals) get put)
    (only (schemacs editor search) match-string)
    (only (schemacs editor custom) define-custom))

  (export lisp-data-mode lisp-data-mode-syntax-table
          lisp-mode lisp-mode-syntax-table lisp-mode-map lisp-mode-hook
          lisp-mode-shared-map lisp-mode-variables
          lisp-mode-autoload-regexp lisp-mode-symbol-regexp
          lisp-el-font-lock-keywords lisp-el-font-lock-keywords-1
          lisp-el-font-lock-keywords-2
          lisp-cl-font-lock-keywords lisp-cl-font-lock-keywords-1
          lisp-cl-font-lock-keywords-2
          lisp--define-face)

  (begin

    ;;----------------------------------------------------------------
    ;; The syntax tables
    ;;------------------------------------------------------------------

    (define lisp-data-mode-syntax-table
      ;; GNU Emacs's `lisp-data-mode-syntax-table' (lisp-mode.el:37):
      ;; "Parent syntax table used in Lisp modes." The four `while' loops
      ;; are the C's: everything below `0', between `9' and `A', between
      ;; `Z' and `a', and between `z' and 128 is symbol syntax - the
      ;; digits and the letters keep the word syntax they inherit.
      ;;--------------------------------------------------------------
      (let ((table (make-syntax-table)))
        (let loop ((c 0))
          (when (< c 128)
            ;; "The digits and the letters keep the word syntax they
            ;; inherit from the standard table"; everything else below
            ;; 128 is symbol syntax.
            (unless (or (char<=? #\0 (integer->char c) #\9)
                        (char<=? #\A (integer->char c) #\Z)
                        (char<=? #\a (integer->char c) #\z))
              (modify-syntax-entry (integer->char c) "_   " table))
            (loop (+ c 1))))
        (modify-syntax-entry #\space "    " table)
        ;; "Non-break space acts as whitespace."
        (modify-syntax-entry (integer->char #xa0) "    " table)
        (modify-syntax-entry #\tab "    " table)
        (modify-syntax-entry #\page "    " table)
        (modify-syntax-entry #\newline ">   " table)
        (modify-syntax-entry #\; "<   " table)
        (modify-syntax-entry #\` "'   " table)
        (modify-syntax-entry #\' "'   " table)
        (modify-syntax-entry #\, "'   " table)
        (modify-syntax-entry #\@ "_ p" table)
        ;; "Used to be singlequote; changed for flonums."
        (modify-syntax-entry #\. "_   " table)
        (modify-syntax-entry #\# "'   " table)
        (modify-syntax-entry #\" "\"    " table)
        (modify-syntax-entry #\\ "\\   " table)
        (modify-syntax-entry #\( "()  " table)
        (modify-syntax-entry #\) ")(  " table)
        (modify-syntax-entry #\[ "(]" table)
        (modify-syntax-entry #\] ")[" table)
        table))

    (define lisp-mode-syntax-table
      ;; GNU Emacs's `lisp-mode-syntax-table' (lisp-mode.el:88).
      ;;--------------------------------------------------------------
      (let ((table (make-syntax-table lisp-data-mode-syntax-table)))
        (modify-syntax-entry #\[ "_   " table)
        (modify-syntax-entry #\] "_   " table)
        (modify-syntax-entry #\# "' 14" table)
        (modify-syntax-entry #\| "\" 23bn" table)
        table))

    ;;----------------------------------------------------------------
    ;; The two regexp literals the keyword tables use
    ;;------------------------------------------------------------------

    (define lisp-mode-autoload-regexp
      ;; GNU Emacs's `lisp-mode-autoload-regexp'.
      "^;;;###\\(\\([-[:alnum:]]+?\\)-\\)?\\(autoload\\)")

    (define lisp-mode-symbol-regexp
      ;; GNU Emacs's `lisp-mode-symbol-regexp', which is
      ;; `(rx lisp-mode-symbol)' - `\\(?:\\w\\|\\s_\\|\\\\.\\)+'.
      "\\(?:\\w\\|\\s_\\|\\\\.\\)+")

    ;;----------------------------------------------------------------
    ;; The definition face
    ;;------------------------------------------------------------------

    (define (lisp--define-face)
      ;; The face function in both definition keywords:
      ;;
      ;;   (3 (let ((type (get (intern-soft (match-string 1))
      ;;                       'lisp-define-type)))
      ;;        (cond ((eq type 'var) 'font-lock-variable-name-face)
      ;;              ((eq type 'type) 'font-lock-type-face)
      ;;              ((or (not (match-string 2))
      ;;                   (and (match-string 2) (match-string 4)))
      ;;               'font-lock-function-name-face)))
      ;;      nil t)
      ;;
      ;; `intern-soft' is Emacs's "the symbol if it exists"; a symbol's
      ;; `lisp-define-type' property is nil whether the symbol exists or
      ;; not, so the plain property read is the same answer.
      ;;--------------------------------------------------------------
      (let ((type (and (match-string 1)
                       (get (string->symbol (match-string 1))
                            'lisp-define-type))))
        (cond ((eq? type 'var) 'font-lock-variable-name-face)
              ((eq? type 'type) 'font-lock-type-face)
              ((or (not (match-string 2))
                   (and (match-string 2) (match-string 4)))
               'font-lock-function-name-face)
              (else #f))))

    (for-each (lambda (name) (put (string->symbol name) 'lisp-define-type 'var))
              '("defconst" "defconstant" "defcustom" "defface" "define-error"
                "define-symbol-macro" "defparameter" "defvar" "defvar-local"
                "defvaralias"))
    (for-each (lambda (name) (put (string->symbol name) 'lisp-define-type 'type))
              '("cl-defstruct" "cl-deftype" "defclass" "defgroup"
                "defpackage" "defstruct" "deftheme" "deftype"))

    ;;----------------------------------------------------------------
    ;; The keyword tables
    ;;------------------------------------------------------------------

    (define lisp-el-font-lock-keywords-1
      ;; GNU Emacs's `lisp-el-font-lock-keywords-1' (lisp-mode.el:457),
      ;; "Subdued level highlighting for Emacs Lisp mode."
      ;;--------------------------------------------------------------
      (list
       (list
        "(\\(cl-def\\(?:generic\\|m\\(?:acro\\|ethod\\)\\|s\\(?:\\(?:truc\\|ubs\\)t\\)\\|type\\|un\\)\\|def\\(?:a\\(?:dvice\\|lias\\)\\|c\\(?:lass\\|onst\\|ustom\\)\\|face\\|g\\(?:eneric\\|roup\\)\\|ine-\\(?:advice\\|derived-mode\\|error\\|g\\(?:\\(?:eneric\\|lobalized-minor\\)-mode\\)\\|inline\\|minor-mode\\|skeleton\\|widget\\)\\|m\\(?:acro\\|ethod\\)\\|subst\\|theme\\|un\\|var\\(?:-local\\|alias\\)?\\)\\|ert-deftest\\)\\_>[ \t']*\\(([ \t']*\\)?\\(\\(setf\\)[ \t]+\\(?:\\w\\|\\s_\\|\\\\.\\)+\\|\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)?"
        (list 1 'font-lock-keyword-face)
        (list 3 lisp--define-face #f #t))
       ;; "Emacs Lisp autoload cookies."
       (list lisp-mode-autoload-regexp
             (list 3 'font-lock-warning-face 'prepend)
             (list 2 'font-lock-function-name-face 'prepend #t))))

    (define lisp-cl-font-lock-keywords-1
      ;; GNU Emacs's `lisp-cl-font-lock-keywords-1' (lisp-mode.el:485),
      ;; "Subdued level highlighting for Lisp modes."
      ;;--------------------------------------------------------------
      (list
       (list
        "(\\(def\\(?:c\\(?:lass\\|onstant\\)\\|generic\\|ine-\\(?:co\\(?:mpiler-macro\\|ndition\\)\\|m\\(?:ethod-combination\\|odify-macro\\)\\|s\\(?:etf-expander\\|ymbol-macro\\)\\)\\|m\\(?:acro\\|ethod\\)\\|pa\\(?:ckage\\|rameter\\)\\|s\\(?:etf\\|\\(?:truc\\|ubs\\)t\\)\\|type\\|un\\|var\\)\\)\\_>[ \t']*\\(([ \t']*\\)?\\(\\(setf\\)[ \t]+\\(?:\\w\\|\\s_\\|\\\\.\\)+\\|\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)?"
        (list 1 'font-lock-keyword-face)
        (list 3 lisp--define-face #f #t))))

    (define lisp-el-font-lock-keywords-2
      ;; GNU Emacs's `lisp-el-font-lock-keywords-2' (lisp-mode.el:508),
      ;; "Gaudy level highlighting for Emacs Lisp mode." The entries the
      ;; library header names as not carried are simply absent.
      ;;--------------------------------------------------------------
      (append
       lisp-el-font-lock-keywords-1
       (list
        ;; "Regexp negated char group."
        (list "\\[\\(\\^\\)" (list 1 'font-lock-negation-char-face 'prepend))
        ;; "Erroneous structures."
        (list "(\\(cl-\\(?:assert\\|check-type\\)\\|error\\|signal\\|user-error\\|warn\\)\\_>"
              (list 1 'font-lock-warning-face))
        ;; "Exit/Feature symbols as constants."
        (list "(\\(catch\\|throw\\|featurep\\|provide\\|require\\)\\_>[ \t']*\\(\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)?"
              (list 1 'font-lock-keyword-face)
              (list 2 'font-lock-constant-face #f #t))
        ;; "Words inside \\[], \\<>, \\{} or \\`' tend to be for
        ;; `substitute-command-keys'."
        (list "\\\\\\\\\\(?:\\[\\(?1:\\(?:\\w\\|\\s_\\|\\\\.\\)+[^\\]\\)]\\|`\\(?1:\\(?:\\w\\|\\s_\\|\\\\.\\)+\\(?: \\(?:\\w\\|\\s_\\|\\\\.\\)+\\)*\\)'\\)"
              (list 1 'font-lock-constant-face 'prepend))
        (list "\\\\\\\\\\(?:<\\(?1:\\(?:\\w\\|\\s_\\|\\\\.\\)+[^\\]\\)>\\|{\\(?1:\\(?:\\w\\|\\s_\\|\\\\.\\)+[^\\]\\)}\\)"
              (list 1 'font-lock-variable-name-face 'prepend))
        ;; "Words inside ‘’ and `' tend to be symbol names."
        (list "[`‘']\\(\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)['’]"
              (list 1 'font-lock-constant-face 'prepend))
        ;; "\\\\= tends to be an escape in doc strings."
        (list "\\\\\\\\=" (list 0 'font-lock-builtin-face 'prepend)))))

    (define lisp-cl-font-lock-keywords-2
      ;; GNU Emacs's `lisp-cl-font-lock-keywords-2' (lisp-mode.el:578).
      ;;--------------------------------------------------------------
      (append
       lisp-cl-font-lock-keywords-1
       (list
        (list "\\[\\(\\^\\)" (list 1 'font-lock-negation-char-face 'prepend))
        (list "(\\(catch\\|throw\\|provide\\|require\\)\\_>[ \t']*\\(\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)?"
              (list 1 'font-lock-keyword-face)
              (list 2 'font-lock-constant-face #f #t))
        (list "(\\(cl-\\(?:assert\\|check-type\\)\\|error\\|signal\\|user-error\\|warn\\)\\_>"
              (list 1 'font-lock-warning-face))
        (list "[`‘]\\(\\(?:\\w\\|\\s_\\|\\\\.\\)+\\(?: \\(?:\\w\\|\\s_\\|\\\\.\\)+\\)*\\)['’]"
              (list 1 'font-lock-constant-face 'prepend))
        ;; "Uninterned symbols, e.g., (defpackage #:my-package ...)"
        (list "#:\\(?:\\w\\|\\s_\\|\\\\.\\)+"
              (list 0 'font-lock-builtin-face))
        ;; "CL (but not EL!) `with-' (context) and `do-' (iteration)"
        (list "(\\(\\(do-\\|with-\\)\\(?:\\w\\|\\s_\\|\\\\.\\)+\\)"
              (list 1 'font-lock-keyword-face)))))

    (define lisp-el-font-lock-keywords lisp-el-font-lock-keywords-1)

    (define lisp-cl-font-lock-keywords lisp-cl-font-lock-keywords-1)

    ;; "a symbol (a variable ... whose value is the keywords)": the
    ;; `font-lock-defaults' list names these six by symbol, and this is
    ;; the table that lookup reads.
    (for-each (lambda (pair)
                (font-lock-register-keyword-variable! (car pair) (cdr pair)))
              (list (cons 'lisp-el-font-lock-keywords lisp-el-font-lock-keywords)
                    (cons 'lisp-el-font-lock-keywords-1 lisp-el-font-lock-keywords-1)
                    (cons 'lisp-el-font-lock-keywords-2 lisp-el-font-lock-keywords-2)
                    (cons 'lisp-cl-font-lock-keywords lisp-cl-font-lock-keywords)
                    (cons 'lisp-cl-font-lock-keywords-1 lisp-cl-font-lock-keywords-1)
                    (cons 'lisp-cl-font-lock-keywords-2 lisp-cl-font-lock-keywords-2)))
    ;; ^ GNU Emacs's `lisp-el-font-lock-keywords' and
    ;; `lisp-cl-font-lock-keywords' (lisp-mode.el:624, :626): each is the
    ;; *subdued* list, and `font-lock-maximum-decoration' (t) chooses the
    ;; last of the three at fontification time.

    ;;----------------------------------------------------------------
    ;; `lisp-mode-variables'
    ;;------------------------------------------------------------------

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does: the buffer's own value.
      ;; It is not a macro here because the tree's buffer-local store is
      ;; keyed by a plain symbol, which a macro could not make either.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    (define (lisp-mode-variables . args)
      ;; GNU Emacs's `lisp-mode-variables' (lisp-mode.el:711): "Common
      ;; initialization routine for Lisp modes." LISP-SYNTAX,
      ;; KEYWORDS-CASE-INSENSITIVE and ELISP are Emacs's three arguments.
      ;;
      ;; The buffer-locals are all stored, as `setq-local' stores them;
      ;; the functions named in them (`lisp-fill-paragraph',
      ;; `lisp-indent-line', ...) are not ported, and the library header
      ;; says so.
      ;;--------------------------------------------------------------
      (let ((lisp-syntax (and (pair? args) (car args)))
            (keywords-case-insensitive (and (pair? args) (pair? (cdr args))
                                            (cadr args)))
            (elisp (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                        (car (cddr args)))))
        (when lisp-syntax
          (set-syntax-table lisp-mode-syntax-table))
        (setq-local 'paragraph-ignore-fill-prefix #t)
        (setq-local 'fill-paragraph-function 'lisp-fill-paragraph)
        (setq-local 'adaptive-fill-function 'lisp-adaptive-fill)
        (setq-local 'indent-line-function 'lisp-indent-line)
        (setq-local 'indent-region-function 'lisp-indent-region)
        (setq-local 'comment-indent-function 'lisp-comment-indent)
        (setq-local 'comment-start ";")
        (setq-local 'comment-start-skip ";+ *")
        ;; "default to `;;' in comment-region"
        (setq-local 'comment-add 1)
        (setq-local 'comment-column 40)
        (setq-local 'comment-use-syntax #t)
        (setq-local 'multibyte-syntax-as-symbol #t)
        (set!font-lock-defaults!
         (list
          (if elisp
              (list 'lisp-el-font-lock-keywords
                    'lisp-el-font-lock-keywords-1
                    'lisp-el-font-lock-keywords-2)
              (list 'lisp-cl-font-lock-keywords
                    'lisp-cl-font-lock-keywords-1
                    'lisp-cl-font-lock-keywords-2))
          #f keywords-case-insensitive #f #f
          (cons 'font-lock-mark-block-function 'mark-defun)
          (cons 'font-lock-extra-managed-props
                (if elisp
                    '(help-echo cursor-sensor-functions mouse-face)
                    '(help-echo)))))
        ;; "Adaptive fill mode gets in the way of auto-fill" and the
        ;; rest of the C's variables are stored above; the function
        ;; returns unspecified in Emacs and #t here.
        #t))

    ;;----------------------------------------------------------------
    ;; `lisp-data-mode' and `lisp-mode'
    ;;------------------------------------------------------------------

    (define lisp-data-mode-map (km:keymap '*lisp-data-mode-map*))
    (define lisp-data-mode-hook '())
    (define lisp-mode-shared-map (km:keymap '*lisp-mode-shared-map*))
    (define lisp-mode-map (km:keymap '*lisp-mode-map*))
    (define lisp-mode-hook '())

    (define-derived-mode (lisp-data-mode prog-mode "Lisp-Data"
                                         lisp-data-mode-map
                                         lisp-data-mode-hook
                                         lisp-data-mode-syntax-table)
      "Major mode for buffers holding data written in Lisp syntax."
      (lisp-mode-variables #f #t #f))

    (define-derived-mode (lisp-mode lisp-data-mode "Lisp" lisp-mode-map
                                    lisp-mode-hook lisp-mode-syntax-table)
      "Major mode for editing programs in Common Lisp and other similar
Lisps."
      (setq-local 'lisp-indent-function 'common-lisp-indent-function)
      (setq-local 'comment-start-skip
                  "\\(\\(^\\|[^\\\n]\\)\\(\\\\\\\\\\)*\\)\\(;+\\|#|\\) *")
      (setq-local 'comment-end-skip "[ \t]*\\(\\s>\\||#\\)")
      (setq-local 'font-lock-comment-end-skip "|#"))

    ))
