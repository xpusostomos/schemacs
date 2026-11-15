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
    (only (schemacs editor command) define-command)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer)
          current-buffer major-mode set-buffer-local-value! buffer-local-value)
    ;; the syntax-table writers, and `make-syntax-table', which is
    ;; subr.el's; the scanner the indentation engine runs
    (only (schemacs editor syntax)
          modify-syntax-entry set-syntax-table parse-partial-sexp syntax-ppss
          skip-chars-forward skip-chars-backward skip-syntax-forward skip-syntax-backward
          backward-prefix-chars char-syntax *parse-sexp-ignore-comments*
          forward-comment scan-error? string-to-syntax
          ppss-comment-or-string-start)
    (only (schemacs editor indent) indent-line-to)
    (only (schemacs editor newcomment) indent-for-comment comment-indent-default)
    (only (schemacs editor lisp)
          beginning-of-defun backward-up-list forward-sexp backward-sexp
          *calculate-lisp-indent-function*)
    (only (schemacs editor keymap) define-key)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor cmds) beginning-of-line end-of-line forward-char)
    (only (schemacs editor editfns)
          bolp eobp eolp point point-max line-beginning-position
          line-end-position forward-line goto-char preceding-char
          char-after char-before buffer-substring save-excursion point-min)
    (only (schemacs editor marker) copy-marker markerp marker-position set-marker)
    (only (schemacs editor indentc) current-column)
    (only (schemacs editor search) looking-at re-search-forward
          match-beginning match-end save-match-data syntax-propertize-rules)
    (only (scheme read) read)
    (only (guile) module-ref open-input-string last-pair resolve-module)
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
    (only (schemacs editor textprop) get-text-property)
    (only (schemacs editor search) match-string)
    (only (schemacs editor custom) define-custom))

  (export lisp-data-mode lisp-data-mode-syntax-table
          lisp-mode lisp-mode-syntax-table lisp-mode-map lisp-mode-hook
          lisp-mode-shared-map lisp-mode-variables
          lisp-mode-autoload-regexp lisp-doc-string-elt-property
   lisp--el-funcall-position-p lisp--el-match-keyword
   %lisp-el-special-forms-and-macros
   lisp-string-in-doc-position-p lisp-string-after-doc-keyword-p
   lisp-font-lock-syntactic-face-function cl--defmethod-doc-pos lisp-mode-symbol-regexp
          lisp-el-font-lock-keywords lisp-el-font-lock-keywords-1
          lisp-el-font-lock-keywords-2
          lisp-cl-font-lock-keywords lisp-cl-font-lock-keywords-1
          lisp-cl-font-lock-keywords-2
          lisp--define-face
          ;; the indentation engine
          lisp-ppss lisp-indent-state? lisp-indent-initial-state
          lisp-indent-calc-next lisp-indent-region lisp-indent-line
          calculate-lisp-indent lisp-indent-function lisp-indent-specform
          lisp--local-defform-body-p
          lisp-indent-defform lisp-body-indent lisp-indent-offset
          ;; `lisp-indent-local-overrides' (`lisp-mode.el:1270'): "An
          ;; alist of file-local or directory-local indent
          ;; specifications." Read by `lisp-indent-function' and by
          ;; `cl-indent.scm''s `lisp-indent-find-method'; nothing here
          ;; fills it, and a file can.
          lisp-indent-local-overrides
          lisp-comment-indent indent-sexp
          ;; the state `calculate-lisp-indent' leaves for the
          ;; `lisp-indent-function' variable's value to read
          *calculate-lisp-indent-last-sexp*
          ;; `lisp-doc-string-elt-property' is a `defvar-local' here - a
          ;; mode says which property it uses (scheme-mode's is
          ;; `scheme-doc-string-elt')
          lisp-doc-string-elt-property)

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


    ;; ---------------------------------------------------------------
    ;; `lisp--el-match-keyword' (`lisp-mode.el:293'), the entry that
    ;; colours `if', `let', `when' and the rest of the special forms and
    ;; macros inside a call position. It asks `special-form-p' and
    ;; `macrop' - "is this symbol a special form or a macro in Emacs" -
    ;; which this tree cannot ask, having no Elisp obarray; the answer is
    ;; **transcribed** from a fresh Emacs 31.1 with `emacs-lisp-mode'
    ;; loaded, the same method as the `lisp-indent-function' table.
    ;;--------------------------------------------------------------
    (define %lisp-el-special-forms-and-macros
      (list
      '|1value| '|`| 'add-function 'allout-mode-p 'and 'and-let*
      'atomic-change-group 'backquote 'backquote-list* 'backquote-list*-macro
      'benchmark-progn 'benchmark-run 'benchmark-run-compiled 'bind*
      'bind-and* 'bind-key 'bind-key* 'bind-keys 'bind-keys*
      'bound-and-true-p 'buffer-local-set-state 'catch 'charset-long-name
      'charset-short-name 'check-ccl-program 'cl--define-built-in-type
      'cl--generic 'cl-assert 'cl-block 'cl-callf 'cl-callf2 'cl-case
      'cl-check-type 'cl-decf 'cl-declaim 'cl-declare 'cl-defgeneric
      'cl-define-compiler-macro 'cl-defmacro 'cl-defmethod 'cl-defstruct
      'cl-defsubst 'cl-deftype 'cl-defun 'cl-destructuring-bind 'cl-do
      'cl-do* 'cl-do-all-symbols 'cl-do-symbols 'cl-dolist 'cl-dotimes
      'cl-ecase 'cl-etypecase 'cl-eval-when 'cl-flet 'cl-flet* 'cl-function
      'cl-generic-current-method-specializers
      'cl-generic-define-context-rewriter 'cl-generic-define-generalizer
      'cl-incf 'cl-iter-defun 'cl-labels 'cl-letf 'cl-letf*
      'cl-load-time-value 'cl-locally 'cl-loop 'cl-macrolet
      'cl-multiple-value-bind 'cl-multiple-value-setq 'cl-once-only 'cl-prog
      'cl-prog* 'cl-progv 'cl-psetf 'cl-psetq 'cl-pushnew 'cl-remf 'cl-return
      'cl-return-from 'cl-rotatef 'cl-shiftf 'cl-symbol-macrolet 'cl-tagbody
      'cl-the 'cl-typecase 'cl-with-accessors 'cl-with-gensyms
      'combine-after-change-calls 'combine-change-calls
      'comment-with-narrowing 'cond 'cond* 'condition-case
      'condition-case-unless-debug 'connection-local-p
      'connection-local-value 'decf 'declare 'declare-ccl-program
      'declare-function 'def-edebug-spec 'defadvice 'defclass 'defconst
      'defcustom 'defface 'defgroup 'defimage 'define-advice
      'define-alternatives 'define-ccl-program 'define-derived-mode
      'define-generic-mode 'define-global-minor-mode
      'define-globalized-minor-mode 'define-ibuffer-column
      'define-ibuffer-filter 'define-ibuffer-op 'define-ibuffer-sorter
      'define-icon 'define-inline 'define-minor-mode
      'define-obsolete-face-alias 'define-obsolete-function-alias
      'define-obsolete-variable-alias 'define-short-documentation-group
      'define-skeleton 'define-treesit-generic-mode 'define-widget-keywords
      'defmacro 'defmath 'defsubst 'deftheme 'defun 'defvar 'defvar-keymap
      'defvar-local 'degrees-to-radians 'delay-mode-hooks 'dlet 'dolist
      'dolist-with-progress-reporter 'dont-compile 'dotimes
      'dotimes-with-progress-reporter 'easy-menu-define
      'easy-mmode-define-global-mode 'easy-mmode-define-minor-mode
      'easy-mmode-defmap 'easy-mmode-defsyntax
      'eldoc--documentation-strategy-defcustom 'ert-deftest
      'ert-font-lock-deftest 'ert-font-lock-deftest-file 'eval-and-compile
      'eval-when-compile 'face-attribute-specified-or 'faceup-defexplainer
      'flymake-log 'function 'gv-define-expander 'gv-define-setter
      'gv-define-simple-setter 'gv-letplace 'gv-ref 'handler-bind 'if 'if-let
      'if-let* 'ignore-error 'ignore-errors 'incf 'inhibit-auto-revert
      'inline 'interactive 'isearch-define-mode-toggle 'lambda
      'lazy-completion-table 'let 'let* 'let-alist 'let-when-compile 'letrec
      'macroexp--accumulate 'macroexp--with-extended-form-stack
      'macroexp-let2 'macroexp-let2* 'macroexp-preserve-posification 'match*
      'menu-bar-make-mm-toggle 'menu-bar-make-toggle
      'menu-bar-make-toggle-command 'minibuffer-with-setup-hook
      'mwheel--is-dir-p 'named-let 'noreturn 'oclosure--define-functions
      'oclosure--lambda 'oclosure-define 'oclosure-lambda 'or
      'org-batch-agenda 'org-batch-agenda-csv 'org-batch-store-agenda-views
      'pcase 'pcase* 'pcase-defmacro 'pcase-dolist 'pcase-exhaustive
      'pcase-lambda 'pcase-let 'pcase-let* 'pcase-setq 'pop 'prog1 'prog2
      'progn 'push 'quail-define-rules 'quote 'radians-to-degrees
      'remove-function 'replace--push-stack 'report-errors
      'robin-define-package 'rx 'rx-define 'rx-let 'rx-let-eval
      'save-current-buffer 'save-excursion 'save-mark-and-excursion
      'save-match-data 'save-restriction 'save-selected-window
      'save-window-excursion 'seq-doseq 'seq-let 'seq-setq 'setf 'setopt
      'setopt-local 'setq 'setq-connection-local 'setq-default 'setq-local
      'static-if 'static-unless 'static-when
      'subr--with-wrapper-hook-no-warnings
      'syntax-propertize-precompile-rules 'syntax-propertize-rules
      'track-mouse 'tramp-archive-autoload-file-name-regexp 'unbind-key
      'unless 'unwind-protect 'use-package 'vc-call 'vc-error-occurred 'when
      'when-let 'when-let* 'while 'while-let 'while-no-input
      'with-auto-compression-mode 'with-case-table 'with-category-table
      'with-coding-priority 'with-connection-local-application-variables
      'with-connection-local-variables 'with-current-buffer
      'with-current-buffer-window 'with-delayed-message 'with-demoted-errors
      'with-displayed-buffer-window 'with-environment-variables
      'with-eval-after-load 'with-existing-directory 'with-file-modes
      'with-help-window 'with-isearch-suspended 'with-local-quit
      'with-locale-environment 'with-memoization
      'with-minibuffer-completions-window 'with-minibuffer-selected-window
      'with-mutex 'with-output-to-string 'with-output-to-temp-buffer
      'with-restriction 'with-selected-frame 'with-selected-window
      'with-silent-modifications 'with-suppressed-warnings 'with-syntax-table
      'with-system-sleep-block 'with-temp-buffer 'with-temp-buffer-window
      'with-temp-file 'with-temp-message 'with-timeout 'with-undo-amalgamate
      'with-window-non-dedicated 'with-work-buffer 'with-wrapper-hook
      'without-remote-files 'without-restriction))

    (define (lisp--el-funcall-position-p pos)
      ;; "Heuristically determine whether POS is an evaluated position."
      ;; (`lisp-mode.el:244').
      ;;--------------------------------------------------------------
      (save-match-data
        (save-excursion
          (guard (e (#t #f))
            (goto-char pos)
            ;; "'(lambda ..) is not a funcall position, but #'(lambda
            ;; ...) is."
            (if (char=? (char-before) #\')
                (char=? (char-before (- (point) 1)) #\#)
                (let* ((ppss (syntax-ppss))
                       (paren-posns (list-ref ppss 9))
                       (parent
                        (when (pair? paren-posns)
                          (goto-char (car (last-pair paren-posns))) ;(up-list -1)
                          (cond
                           ((guard (e (#t #f))
                              (and (char=? (char-after (point)) #\()
                                   (begin
                                     ;; Elisp's `(car (last paren-posns 2))'
                                     ;; - the *second-to-last* opener, which
                                     ;; is the form the enclosing paren
                                     ;; belongs to. `(car (last (cdr ...)))'
                                     ;; takes the enclosing paren itself,
                                     ;; and the `let' test then never fires:
                                     ;; `(interactive t)' in a `let*'
                                     ;; binding list was coloured a keyword
                                     ;; where Emacs leaves it plain.
                                     (when (pair? (cdr paren-posns))
                                       (goto-char (car (list-tail
                                                        paren-posns
                                                        (- (length paren-posns) 2)))))
                                     (looking-at "(\\_<let\\*?\\_>"))))
                            (goto-char (match-end 0))
                            'let)
                           ((looking-at "(\\(?1:\\(?:\\w\\|\\s_\\)+\\)\\_>")
                            (let ((sym (string->symbol (match-string 1))))
                              (goto-char (match-end 1))
                              sym))))))
                  (cond ((eq? parent 'declare) #f)
                        ((eq? parent 'let)
                         (forward-sexp 1)
                         (>= pos (point)))
                        ((memq parent '(defun defmacro cl-defmethod cl-defun))
                         (forward-sexp 2)
                         (>= pos (point)))
                        ((eq? parent 'condition-case)
                         ;; "If (cdr paren-posns), then we're in the BODY
                         ;; of HANDLERS."
                         (or (pair? (cdr paren-posns))
                             (begin
                               (forward-sexp 1)
                               ;; "If we're in the second form, then
                               ;; we're in a funcall position."
                               (and (< (point) pos)
                                    (< pos (begin (forward-sexp 1) (point)))))))
                        (else #t))))))))

    (define help-uni-confusables-regexp "[‘’‛“”‟〞＂＇]")
    ;; ^ GNU Emacs's `help-uni-confusables-regexp' (subr.el), transcribed.

    (define (lisp--match-hidden-arg limit)
      ;; "Match a hidden argument: one that starts a line without
      ;; anything before it on that line, which reads as if it belonged
      ;; to the previous form." (`lisp-mode.el:219').
      ;;--------------------------------------------------------------
      (let ((res #f))
        (forward-line 0)
        ;; `(while (let ((ppss ...)) ...) BODY)' with an empty BODY: the
        ;; value of the `let' is the loop's test.
        (let loop ()
          (when (let ((ppss (parse-partial-sexp (point) (line-end-position) -1)))
                  (skip-syntax-forward " )")
                  (if (or (>= (car ppss) 0)
                          (eolp)
                          (looking-at ";")
                          (list-ref (syntax-ppss) 8)) ; "Within a string or comment."
                      (begin
                        (forward-line 1)
                        (< (point) limit))
                      (begin
                        (looking-at ".*")      ; "Set the match-data."
                        (forward-line 1)
                        (set! res (point))
                        #f)))
            (loop)))
        res))

    (define (lisp-mode--search-key char bound)
      ;; "Search for CHAR followed by a symbol constituent ... and check
      ;; that it is not escaped or preceded by whitespace."
      ;; (`lisp-mode.el:356').
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (found)
         (let loop ()
           (when (re-search-forward
                  (string-append "\\_<" char lisp-mode-symbol-regexp "\\_>")
                  bound #t)
             ;; The C's `while' body is the `when'; the test runs again
             ;; after it.
             (when (or (< (match-beginning 0) (+ (point-min) 2))
                       ;; "A quoted white space before the &/: means that
                       ;; this is not the start of a :keyword or an
                       ;; &option."
                       (not (char=? (char-after (- (match-beginning 0) 2))
                                    #\\))
                       (not (memv (char-after (- (match-beginning 0) 1))
                                  (list #\space #\newline #\tab))))
               (found #t))
             (loop)))
         #f)))

    (define (elisp--font-lock-backslash)
      ;; "Fontify a `\\' that has no effect (typically in need of
      ;; doubling)." (`lisp-mode.el:310').
      ;;--------------------------------------------------------------
      (let* ((beg0 (match-beginning 0))
             (end0 (match-end 0))
             (ppss (save-excursion (syntax-ppss beg0))))
        (and (list-ref ppss 3)                ; "Inside a string."
             (not (list-ref ppss 5))          ; "The \ is not itself \-escaped."
             ;; "Don't highlight the \( introduced because of
             ;; `open-paren-in-column-0-is-defun-start'."
             (not (char=? #\newline (char-before beg0)))
             (guard (e (#t #f))
               (equal? (let ((str (buffer-substring beg0 end0)))
                         (read (open-input-string (string-append "\"" str "\""))))
                       (buffer-substring (+ 1 beg0) end0)))
             '(face font-lock-warning-face
                    help-echo "This \\ has no effect"))))

    (define (lisp--match-confusable-symbol-character limit)
      ;; "Match a confusable character within a Lisp symbol."
      ;; (`lisp-mode.el:343').
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (matched)
         (let loop ()
           (if (re-search-forward help-uni-confusables-regexp limit #t)
               ;; "Skip confusables which are backslash escaped, or
               ;; inside strings or comments."
               (save-match-data
                 (unless (or (char=? (char-before (match-beginning 0)) #\\)
                             (list-ref (syntax-ppss) 8))
                   (matched #t)))
               (matched #f))
           (loop)))))

    (define (lisp--el-match-keyword limit)
      ;; (`lisp-mode.el:293'): font-lock's matcher for the Elisp
      ;; keywords. The C's `(catch 'found (while ... (throw 'found t)))'
      ;; is the `call/cc' escape.
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (found)
         (let loop ()
           (when (re-search-forward
                  (string-append "(\\(" lisp-mode-symbol-regexp "\\)\\_>")
                  limit #t)
             (let ((sym (string->symbol (match-string 1))))
               (when (and (or (memq sym %lisp-el-special-forms-and-macros)
                              (get sym 'font-lock-keyword))
                          (not (get sym 'no-font-lock-keyword))
                          (lisp--el-funcall-position-p (match-beginning 0)))
                 (found #t)))
             (loop)))
         #f)))

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
        ;; "Erroneous structures." **Before** the control structures, as
        ;; the C has them: a face already set is not overwritten unless
        ;; the highlight says so, so `(cl-assert ...)' keeps the warning
        ;; face and only its first face wins.
        (list "(\\(cl-\\(?:assert\\|check-type\\)\\|error\\|signal\\|user-error\\|warn\\)\\_>"
              (list 1 'font-lock-warning-face))
        ;; "Control structures. Common Lisp forms." - the function
        ;; matcher, `(lisp--el-match-keyword . 1)' in the C.
        (cons lisp--el-match-keyword 1)
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
        (list "\\\\\\\\=" (list 0 'font-lock-builtin-face 'prepend))
        ;; "Ineffective backslashes (typically in need of doubling)."
        (list "\\(\\\\\\)\\([^\"\\]\\)"
              ;; The C holds the *form* `(elisp--font-lock-backslash)';
              ;; here the procedure itself goes in the face slot, which
              ;; the highlighter calls (as level-1's `lisp--define-face'
              ;; already does).
              (list 1 elisp--font-lock-backslash 'prepend))
        ;; "Constant values."
        (cons (lambda (bound) (lisp-mode--search-key ":" bound))
              (list (list 0 'font-lock-builtin-face)))
        ;; "Elisp and Common Lisp `&' keywords as types."
        (cons (lambda (bound) (lisp-mode--search-key "&" bound))
              (list (list 0 'font-lock-type-face)))
        ;; "Elisp regexp grouping constructs" - the highlights are
        ;; `(1 font-lock-regexp-grouping-backslash prepend)' and
        ;; `(3 font-lock-regexp-grouping-construct prepend)'.
        (cons (lambda (bound)
                ;; "The following loop is needed to continue searching
                ;; after matches that do not occur in strings."
                (call/cc
                 (lambda (found)
                   (let loop ()
                     (when (re-search-forward
                            "\\(\\\\\\\\\\)\\(?:\\(\\\\\\\\\\)\\|\\((\\(?:\\?[0-9]*:\\)?\\|[|)]\\)\\)"
                            bound #t)
                       (unless (match-beginning 2)
                         (let ((face (get-text-property (- (point) 1) 'face)))
                           (when (or (and (pair? face)
                                          (memq 'font-lock-string-face face))
                                     (eq? 'font-lock-string-face face))
                             (found #t))))
                       (loop)))
                   #f)))
              (list (list 1 'font-lock-regexp-grouping-backslash 'prepend)
                    (list 3 'font-lock-regexp-grouping-construct 'prepend)))
        (cons lisp--match-hidden-arg
              (list (list 0 '(face font-lock-warning-face
                                   help-echo "Easy to misread; consider moving the element to the next line")
                          'prepend)))
        (cons lisp--match-confusable-symbol-character
              (list (list 0 '(face font-lock-warning-face
                                   help-echo "Confusable character")))))))

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

    ;; ---------------------------------------------------------------
    ;; Docstrings: `lisp-doc-string-elt-property' and its table
    ;; (`lisp-mode.el:203-216'), `lisp-string-in-doc-position-p'
    ;; (`:635'), `lisp-string-after-doc-keyword-p' (`:670') and
    ;; `lisp-font-lock-syntactic-face-function' (`:672') - the function
    ;; that gives a docstring `font-lock-doc-face' instead of the
    ;; string face.
    ;; ---------------------------------------------------------------
    (define lisp-doc-string-elt-property-variable 'doc-string-elt)
    ;; ^ GNU Emacs's `lisp-doc-string-elt-property' (`lisp-mode.el:610')
    ;; is a `defvar-local': "Property to use to determine the position of
    ;; docstrings." A mode may name its own, and `scheme-mode' does
    ;; (`scheme-doc-string-elt') - so the value is read per buffer.

    (define (lisp-doc-string-elt-property)
      (buffer-local-value (current-buffer) 'lisp-doc-string-elt-property
                          lisp-doc-string-elt-property-variable))

    (define (cl--defmethod-doc-pos)
      ;; "Return the index of the docstring for a `cl-defmethod'.
      ;; Presumes point is at the end of the `cl-defmethod' symbol."
      ;; (`cl-generic.el:533').
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((n 2))
          (let loop ()
            (when (and (guard (e (#t #f)) (forward-sexp 1) #t)
                       (not (char=? (char-before) #\))))
              (set! n (+ n 1))
              (loop)))
          n)))

    (for-each
     (lambda (e) (put (car e) (lisp-doc-string-elt-property) (cdr e)))
     (list
      (cons 'autoload 3)
      (cons 'cl--define-built-in-type 3)
      (cons 'cl-defgeneric 3)
      (cons 'cl-defmacro 3)
      ;; The C's value is the *symbol* `cl--defmethod-doc-pos', which
      ;; `functionp' recognises as callable; there is no obarray here, so
      ;; the procedure itself goes in the table - the same spelling the
      ;; font-lock keyword tables use for their matchers.
      (cons 'cl-defmethod cl--defmethod-doc-pos)
      (cons 'cl-defstruct 2)
      (cons 'cl-defsubst 3)
      (cons 'cl-deftype 3)
      (cons 'cl-defun 3)
      (cons 'cl-iter-defun 3)
      (cons 'defadvice 3)
      (cons 'defalias 3)
      (cons 'defclass 4)
      (cons 'defconst 3)
      (cons 'defconstant 3)
      (cons 'defcustom 3)
      (cons 'defface 3)
      (cons 'defgroup 3)
      (cons 'defimage 3)
      (cons 'define-abbrev-table 3)
      (cons 'define-advice 3)
      (cons 'define-category 2)
      (cons 'define-ccl-program 3)
      (cons 'define-compilation-mode 3)
      (cons 'define-compiler-macro 3)
      (cons 'define-completion-category 3)
      (cons 'define-derived-mode 4)
      (cons 'define-generic-mode 7)
      (cons 'define-globalized-minor-mode 2)
      (cons 'define-ibuffer-filter 2)
      (cons 'define-ibuffer-op 3)
      (cons 'define-ibuffer-sorter 2)
      (cons 'define-icon 4)
      (cons 'define-inline 3)
      (cons 'define-minor-mode 2)
      (cons 'define-obsolete-function-alias 4)
      (cons 'define-obsolete-variable-alias 4)
      (cons 'define-overloadable-function 3)
      (cons 'define-setf-expander 3)
      (cons 'define-skeleton 2)
      (cons 'define-treesit-generic-mode 2)
      (cons 'define-widget 3)
      (cons 'defmacro 3)
      (cons 'defmath 3)
      (cons 'defmethod 3)
      (cons 'defparameter 3)
      (cons 'defstruct 2)
      (cons 'defsubst 3)
      (cons 'deftheme 2)
      (cons 'deftype 3)
      (cons 'defun 3)
      (cons 'defvar 3)
      (cons 'defvar-local 3)
      (cons 'defvaralias 3)
      (cons 'easy-menu-define 3)
      (cons 'easy-mmode-defmap 3)
      (cons 'easy-mmode-defsyntax 3)
      (cons 'ert-deftest 3)
      (cons 'ert-font-lock-deftest 2)
      (cons 'ert-font-lock-deftest-file 2)
      (cons 'lambda 2)
      (cons 'oclosure-define 2)
      (cons 'pcase-defmacro 3)
      (cons 'pcase-lambda 2)))

    (define (lisp-string-in-doc-position-p listbeg startpos)
      ;; "Return non-nil if a doc string may occur at STARTPOS inside a
      ;; list. LISTBEG is the position of the start of the innermost
      ;; list containing STARTPOS." (`lisp-mode.el:635').
      ;;--------------------------------------------------------------
      (let* ((firstsym
              (and listbeg
                   (save-excursion
                     (goto-char listbeg)
                     (and (looking-at
                           (string-append "([ \t\n]*\\("
                                          lisp-mode-symbol-regexp "\\)"))
                          (match-string 1)))))
             (docelt (and firstsym
                          (get (string->symbol firstsym)
                               (lisp-doc-string-elt-property)))))
        (and docelt
             (save-excursion
               (when (procedure? docelt)
                 (goto-char (match-end 1))
                 (set! docelt (docelt)))
               (goto-char listbeg)
               (forward-char 1)
               (guard (e (#t #f))
                 (let loop ()
                   (when (and (> docelt 0) (< (point) startpos))
                     (forward-sexp 1)
                     (set! docelt (- docelt 1))
                     (loop))))
               (and (= docelt 0) (<= (point) startpos)
                    (begin (forward-comment (point-max)) #t)
                    (= (point) startpos))))))

    (define (lisp-string-after-doc-keyword-p listbeg startpos)
      ;; "Return non-nil if `:documentation' symbol ends at STARTPOS
      ;; inside a list. `:doc' can also be used." (`lisp-mode.el:670').
      ;;--------------------------------------------------------------
      (and listbeg
           (save-excursion
             (goto-char startpos)
             (guard (e (#t #f))
               (backward-sexp 1)
               (and (looking-at ":documentation\\_>\\|:doc\\_>") #t)))))

    (define (lisp-font-lock-syntactic-face-function state)
      ;; "Return syntactic face function for the position represented by
      ;; STATE." (`lisp-mode.el:672'): a docstring gets
      ;; `font-lock-doc-face', any other string `font-lock-string-face',
      ;; a comment `font-lock-comment-face'.
      ;;--------------------------------------------------------------
      (if (list-ref state 3)
          ;; "This might be a (doc)string or a |...| symbol."
          (let ((startpos (list-ref state 8)))
            (if (char=? (char-after startpos) #\|)
                ;; "This is not a string, but a |...| symbol."
                #f
                (let ((listbeg (list-ref state 1)))
                  (if (or (lisp-string-in-doc-position-p listbeg startpos)
                          (lisp-string-after-doc-keyword-p listbeg startpos))
                      'font-lock-doc-face
                      'font-lock-string-face))))
          'font-lock-comment-face))

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
        ;; The C stores *functions*; a symbol is not callable here, so
        ;; the procedures themselves go in (the same shape every other
        ;; function-valued buffer-local takes).
        (setq-local 'indent-line-function lisp-indent-line)
        (setq-local 'indent-region-function lisp-indent-region)
        (setq-local 'comment-indent-function lisp-comment-indent)
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
                    '(help-echo)))
          ;; "`font-lock-syntactic-face-function' . lisp-font-lock-
          ;; syntactic-face-function" - the docstring face. The C stores
          ;; the *symbol*; a symbol is not callable here, so the
          ;; procedure goes in.
          (cons 'font-lock-syntactic-face-function
                lisp-font-lock-syntactic-face-function)))
        ;; "Adaptive fill mode gets in the way of auto-fill" and the
        ;; rest of the C's variables are stored above; the function
        ;; returns unspecified in Emacs and #t here.
        #t))

    ;; ---------------------------------------------------------------
    ;; The indentation engine (`lisp-mode.el:880-1500'): `lisp-ppss',
    ;; the `lisp-indent-state' record, `lisp-indent-calc-next',
    ;; `lisp-indent-region', `lisp-indent-line', `calculate-lisp-indent',
    ;; `lisp-indent-function' and `indent-sexp'.
    ;;--------------------------------------------------------------

    (define (lisp-ppss . rest)
      ;; GNU Emacs's `lisp-ppss' (`lisp-mode.el:944'): "Return the
      ;; `syntax-ppss' of POS, or of point if POS is nil. ... complete
      ;; sexp in the innermost containing list at position 2 (counting
      ;; from 0).  This is important for Lisp indentation."
      ;;--------------------------------------------------------------
      (let* ((pos (if (and (pair? rest) (car rest)) (car rest) (point)))
             (pss (syntax-ppss pos)))
        (if (and (not (list-ref pss 2)) (pair? (list-ref pss 9)))
            (let ((sexp-start (car (last-pair (list-ref pss 9)))))
              (parse-partial-sexp sexp-start pos #f #f
                                  (syntax-ppss sexp-start)))
            pss)))

    ;; `(cl-defstruct (lisp-indent-state ...))' (`lisp-mode.el:950'):
    ;; STACK (cached indentation, per depth), PPSS and PPSS-POINT.
    (define-record-type <lisp-indent-state>
      (make-lisp-indent-state stack ppss ppss-point)
      lisp-indent-state?
      (stack lisp-indent-state-stack set!lisp-indent-state-stack!)
      (ppss lisp-indent-state-ppss set!lisp-indent-state-ppss!)
      (ppss-point lisp-indent-state-ppss-point set!lisp-indent-state-ppss-point!))

    (define (lisp-indent-initial-state)
      ;; The struct's `&aux' defaults, in the C's order: `ppss' is read
      ;; first, and the stack is as deep as `(car ppss)' plus one.
      ;;--------------------------------------------------------------
      (let ((ppss (lisp-ppss)))
        (make-lisp-indent-state (make-list (+ 1 (list-ref ppss 0)) #f)
                                ppss
                                (point))))

    (define (lisp-indent-calc-next state)
      ;; GNU Emacs's `lisp-indent-calc-next' (`lisp-mode.el:959'): "Move
      ;; to next line and return calculated indent for it. STATE is
      ;; updated by side effect, the first state should be created by
      ;; `lisp-indent-initial-state'. This function may move by more than
      ;; one line to cross a string literal."
      ;;--------------------------------------------------------------
      (let* ((indent-stack (lisp-indent-state-stack state))
             (ppss (lisp-indent-state-ppss state))
             (ppss-point (lisp-indent-state-ppss-point state))
             (indent-depth (list-ref ppss 0)) ; corresponding to indent-stack
             (depth indent-depth))
        ;; "Parse this line so we can learn the state to indent the next
        ;; line."
        (let loop ()
          (let ((last-sexp (list-ref ppss 2)))
            (set! ppss (parse-partial-sexp
                        ppss-point
                        (begin (end-of-line) (point))
                        #f #f ppss))
            ;; "Preserve last sexp of state (position 2) for
            ;; `calculate-lisp-indent', if we're at the same depth."
            (if (and (not (list-ref ppss 2)) (= depth (list-ref ppss 0)))
                (list-set! ppss 2 last-sexp)
                (set! last-sexp (list-ref ppss 2)))
            (set! depth (list-ref ppss 0))
            ;; "Skip over newlines within strings."
            (when (and (not (eobp)) (list-ref ppss 3))
              (let ((string-start (list-ref ppss 8)))
                (set! ppss (parse-partial-sexp (point) (point-max) #f #f
                                               ppss 'syntax-table))
                (list-set! ppss 2 string-start)  ; "Finished a complete string."
                (set! depth (list-ref ppss 0)))
              (set! ppss-point (point))
              (loop))))
        (set! ppss-point (point))
        (let ((depth-delta (- depth indent-depth)))
          (cond ((< depth-delta 0)
                 (set! indent-stack (list-tail indent-stack (- depth-delta))))
                ((> depth-delta 0)
                 (set! indent-stack (append (make-list depth-delta #f)
                                            indent-stack)))))
        (let ((result
               (let ((indent #f))
                 (cond ((= (forward-line 1) 1)
                        ;; "Can't move to the next line, apparently end of
                        ;; buffer."
                        #f)
                       ((null? indent-stack)
                        ;; "Negative depth, probably some kind of syntax
                        ;; error. Reset the state."
                        (set! ppss (parse-partial-sexp (point) (point-max)))
                        ppss)
                       ((car indent-stack))
                       ((integer? (begin (set! indent (calculate-lisp-indent ppss))
                                         indent))
                        (set-car! indent-stack indent)
                        indent)
                       ((pair? indent)       ; (COLUMN CONTAINING-SEXP-START)
                        (car indent))
                       (else
                        ;; "This only happens if we're in a string, but the
                        ;; loop should always skip over strings (unless we
                        ;; hit end of buffer, which is taken care of by the
                        ;; first clause)."
                        (error "This shouldn't happen"))))))
          (set!lisp-indent-state-stack! state indent-stack)
          (set!lisp-indent-state-ppss-point! state ppss-point)
          (set!lisp-indent-state-ppss! state ppss)
          result)))

    (define (lisp-indent-region start end)
      ;; GNU Emacs's `lisp-indent-region' (`lisp-mode.el:1005'): "Indent
      ;; region as Lisp code, efficiently."
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((end (copy-marker end)))
          (goto-char start)
          (beginning-of-line)
          ;; "The default `indent-region-line-by-line' doesn't hold a
          ;; running parse state, which forces each indent call to reparse
          ;; from the beginning. That has O(n^2) complexity."
          (let ((parse-state (lisp-indent-initial-state)))
            (let ((ppss (lisp-indent-state-ppss parse-state)))
              (unless (or (and (bolp) (eolp)) (list-ref ppss 3))
                (lisp-indent-line (calculate-lisp-indent ppss))))
            (let ((indent #f))
              (let loop ()
                (set! indent (lisp-indent-calc-next parse-state))
                (when (< (point) (marker-position end))
                  (unless (or (and (bolp) (eolp)) (not indent))
                    (lisp-indent-line indent))
                  (loop)))))
          (set-marker end #f))))

    (define (lisp-indent-line . rest)
      ;; GNU Emacs's `lisp-indent-line' (`lisp-mode.el:1043'): "Indent
      ;; current line as Lisp code."
      ;;--------------------------------------------------------------
      (let* ((indent (if (and (pair? rest) (car rest)) (car rest) #f))
             (pos (- (point-max) (point)))
             (indent (begin (beginning-of-line)
                            (or indent (calculate-lisp-indent (lisp-ppss))))))
        (skip-chars-forward " \t")
        (if (or (not indent) (looking-at "\\s<\\s<\\s<"))
            ;; "Don't alter indentation of a ;;; comment line or a line
            ;; that starts in a string."
            (goto-char (- (point-max) pos))
            (begin
              (if (and (looking-at "\\s<") (not (looking-at "\\s<\\s<")))
                  ;; "Single-semicolon comment lines should be indented as
                  ;; comment lines, not as code."
                  (begin (indent-for-comment) (forward-char -1))
                  (begin
                    (if (pair? indent) (set! indent (car indent)))
                    (indent-line-to indent)))
              ;; "If initial point was within line's indentation, position
              ;; after the indentation. Else stay at same point in text."
              (if (> (- (point-max) pos) (point))
                  (goto-char (- (point-max) pos)))))))

    (define *calculate-lisp-indent-last-sexp* #f)
    ;; ^ `calculate-lisp-indent-last-sexp' (`lisp-mode.el:1066'): an
    ;; unbound `defvar' in the C, `setq'-ed by `calculate-lisp-indent'
    ;; and read by `lisp-indent-function' and `lisp-indent-defform'. A
    ;; plain variable here for the same reason: it is a global the two
    ;; share, not a binding.

    (define (calculate-lisp-indent . rest)
      ;; GNU Emacs's `calculate-lisp-indent' (`lisp-mode.el:1068'):
      ;; "Return appropriate indentation for current line as Lisp code.
      ;; In usual case returns an integer: the column to indent to. If
      ;; the value is nil, that means don't change the indentation
      ;; because the line starts inside a string. ... The value can also
      ;; be a list of the form (COLUMN CONTAINING-SEXP-START)."
      ;;--------------------------------------------------------------
      (let ((parse-start (if (and (pair? rest) (car rest)) (car rest) #f)))
        (save-excursion
          (beginning-of-line)
          (let ((indent-point (point))
                (state #f)
                ;; "setting this to a number inhibits calling hook"
                (desired-indent #f)
                (retry #t)
                (whitespace-after-open-paren #f)
                (containing-sexp #f))
            (cond ((or (markerp parse-start) (integer? parse-start))
                   (goto-char (if (markerp parse-start)
                                  (marker-position parse-start)
                                  parse-start)))
                  ((not parse-start) (beginning-of-defun))
                  (else (set! state parse-start)))
            (unless state
              ;; "Find outermost containing sexp"
              (let loop ()
                (when (< (point) indent-point)
                  (set! state (parse-partial-sexp (point) indent-point 0))
                  (loop))))
            ;; "Find innermost containing sexp"
            (let loop ()
              (when (and retry state (> (list-ref state 0) 0))
                (set! retry #f)
                (set! *calculate-lisp-indent-last-sexp* (list-ref state 2))
                (set! containing-sexp (list-ref state 1))
                ;; "Position following last unclosed open."
                (goto-char (+ 1 containing-sexp))
                ;; "Is there a complete sexp since then?"
                (when (and *calculate-lisp-indent-last-sexp*
                           (> *calculate-lisp-indent-last-sexp* (point)))
                  ;; "Yes, but is there a containing sexp after that?"
                  (let* ((peek (parse-partial-sexp
                                *calculate-lisp-indent-last-sexp*
                                indent-point 0))
                         ;; **`set!' answers the OLD value in this
                         ;; Guile**, so the C's `(if (setq retry ...)
                         ;; (setq state peek))' cannot be a `when' around a
                         ;; `set!': the test would read the previous
                         ;; value and the peek's state would never be
                         ;; taken.
                         (next (list-ref peek 1)))
                    (set! retry next)
                    (when next
                      (set! state peek))))
                (loop)))
            (if retry
                #f
                ;; "Innermost containing sexp found"
                (begin
                  (goto-char (+ 1 containing-sexp))
                  (set! whitespace-after-open-paren (looking-at "\\s-"))
                  (if (not *calculate-lisp-indent-last-sexp*)
                      ;; "indent-point immediately follows open paren.
                      ;; Don't call hook."
                      (set! desired-indent (current-column))
                      ;; "Find the start of first element of containing
                      ;; sexp."
                      (begin
                        (parse-partial-sexp (point)
                                            *calculate-lisp-indent-last-sexp*
                                            0 #t)
                        (cond ((looking-at "\\s(")
                               ;; "First element of containing sexp is a
                               ;; list. Indent under that list."
                               #f)
                              ((> (save-excursion (forward-line 1) (point))
                                  *calculate-lisp-indent-last-sexp*)
                               ;; "This is the first line to start within
                               ;; the containing sexp. It's almost
                               ;; certainly a function call."
                               (if (or (= (point)
                                          *calculate-lisp-indent-last-sexp*)
                                       whitespace-after-open-paren)
                                   ;; "Containing sexp has nothing before
                                   ;; this line except the first element,
                                   ;; or the first element is preceded by
                                   ;; whitespace. Indent under that
                                   ;; element."
                                   #f
                                   ;; "Skip the first element, find start of
                                   ;; second (the first argument of the
                                   ;; function call) and indent under."
                                   (begin
                                     (forward-sexp 1)
                                     (parse-partial-sexp
                                      (point) *calculate-lisp-indent-last-sexp*
                                      0 #t)))
                               (backward-prefix-chars))
                              (else
                               ;; "Indent beneath first sexp on same line as
                               ;; `calculate-lisp-indent-last-sexp'. Again,
                               ;; it's almost certainly a function call."
                               (goto-char *calculate-lisp-indent-last-sexp*)
                               (beginning-of-line)
                               (parse-partial-sexp
                                (point) *calculate-lisp-indent-last-sexp*
                                0 #t)
                               (backward-prefix-chars)))))))
            ;; "Point is at the point to indent under unless we are
            ;; inside a string. Call indentation hook except when
            ;; overridden by lisp-indent-offset or if the desired
            ;; indentation has already been computed."
            ;;
            ;; **This `let' is NOT inside the `if' above** - the C's
            ;; `(if retry nil ...)' is a statement, and the `cond' below
            ;; runs either way. With it inside the else branch (as it
            ;; was until 2026-11-15) a line whose state had no
            ;; containing sexp answered #f where Emacs answers 0.
            (let ((normal-indent (current-column)))
              (cond ;; Emacs's `(elt state 3)' is nil for a nil state;
                    ;; `list-ref' would raise here.
                    ((and state (list-ref state 3))
                     ;; "Inside a string, don't change indentation."
                     #f)
                    ((and (integer? (lisp-indent-offset))
                          containing-sexp)
                     ;; "Indent by constant offset"
                     (goto-char containing-sexp)
                     (+ (current-column) (lisp-indent-offset)))
                    ;; "in this case calculate-lisp-indent-last-sexp
                    ;; is not nil"
                    (*calculate-lisp-indent-last-sexp*
                     (or
                      ;; "try to align the parameters of a known
                      ;; function"
                      (and (lisp-indent-function-variable) (not retry)
                           ((lisp-indent-function-variable)
                            indent-point state))
                      ;; "If the function has no special alignment or
                      ;; it does not apply to this argument, try to
                      ;; align a constant-symbol under the last
                      ;; preceding constant symbol, if there is such
                      ;; one of the last 2 preceding symbols, in the
                      ;; previous uncommented line."
                      (and (save-excursion
                             (goto-char indent-point)
                             (skip-chars-forward " \t")
                             (looking-at ":"))
                           (save-excursion
                             (goto-char *calculate-lisp-indent-last-sexp*)
                             ;; "Handle prefix characters and
                             ;; whitespace following an open paren.
                             ;; (Bug#1012)"
                             (backward-prefix-chars)
                             (let loop ()
                               (when (not (save-excursion
                                            (skip-chars-backward " \t")
                                            (or (= (point)
                                                   (line-beginning-position))
                                                (and containing-sexp
                                                     (= (point)
                                                        (+ 1 containing-sexp))))))
                                 (forward-sexp -1)
                                 (backward-prefix-chars)
                                 (loop)))
                             (set! *calculate-lisp-indent-last-sexp*
                                   (point)))
                           (> *calculate-lisp-indent-last-sexp*
                              (save-excursion
                                (goto-char (+ 1 containing-sexp))
                                (parse-partial-sexp
                                 (point) *calculate-lisp-indent-last-sexp*
                                 0 #t)
                                (point)))
                           (parameterize ((*parse-sexp-ignore-comments* #t))
                             (let ((indent #f))
                               (goto-char *calculate-lisp-indent-last-sexp*)
                               ;; The C is `(or (and (looking-at ":")
                               ;; (setq indent (current-column))) ...)'
                               ;; - the `and' answers the column. A
                               ;; Scheme `set!' answers the OLD value,
                               ;; so the `and' is written as an `if'.
                               (if (looking-at ":")
                                   (set! indent (current-column))
                                   (if (and (< (line-beginning-position)
                                               (begin (backward-sexp)
                                                      (point)))
                                            (looking-at ":"))
                                       (set! indent (current-column))))
                               indent)))
                      ;; "another symbols or constants not preceded by
                      ;; a constant as defined above."
                      normal-indent))
                    ;; "in this case calculate-lisp-indent-last-sexp
                    ;; is nil"
                    (desired-indent)
                    (else normal-indent)))))))


    (define (lisp-indent-offset)
      ;; `lisp-indent-offset' (`lisp-mode.el:898'): "If non-nil, indent
      ;; second line of expressions that many more columns." A
      ;; buffer-local variable.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'lisp-indent-offset #f))

    (define lisp-body-indent 2)
    ;; ^ `lisp-body-indent' (`lisp-mode.el:1360'): "Number of columns to
    ;; indent the second line of a `(def...)' form."

    (define (lisp-indent-function-variable)
      ;; The *variable* `lisp-indent-function' (`lisp-mode.el:904', a
      ;; `defcustom'): "A function to be called by
      ;; `calculate-lisp-indent'. ... One option for this function is
      ;; `common-lisp-indent-function'."
      ;;
      ;; **The default is the procedure**, which is the defcustom's own
      ;; initial value (`#'lisp-indent-function'); modes that want another
      ;; table `setq-local' one (scheme.el, and `lisp-mode-variables' for
      ;; Common Lisp). It was `#f' until 2026-11-15, so the hook was never
      ;; called and every form fell back to the "align under the first
      ;; element" column - a `(defun foo (a b)` body indented to 7
      ;; instead of 2.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'lisp-indent-function
                          lisp-indent-function))

    (define (lisp-indent-function indent-point state)
      ;; GNU Emacs's `lisp-indent-function' (`lisp-mode.el:1295'): "This
      ;; function is the normal value of the variable
      ;; `lisp-indent-function'. ... This function returns either the
      ;; indentation to use, or nil if the Lisp function does not specify
      ;; a special indentation."
      ;;--------------------------------------------------------------
      (let ((normal-indent (current-column)))
        (goto-char (+ 1 (list-ref state 1)))
        (parse-partial-sexp (point) *calculate-lisp-indent-last-sexp* 0 #t)
        (if (and (list-ref state 2)
                 (not (looking-at "\\sw\\|\\s_")))
            ;; "car of form doesn't seem to be a symbol"
            (if (lisp--local-defform-body-p state)
                ;; "We nevertheless check whether we are in flet-like
                ;; form as we presume local function names could be
                ;; non-symbols."
                (lisp-indent-defform state indent-point)
                (begin
                  (if (not (> (save-excursion (forward-line 1) (point))
                              *calculate-lisp-indent-last-sexp*))
                      (begin
                        (goto-char *calculate-lisp-indent-last-sexp*)
                        (beginning-of-line)
                        (parse-partial-sexp (point)
                                            *calculate-lisp-indent-last-sexp*
                                            0 #t)))
                  ;; "Indent under the list or under the first sexp on the
                  ;; same line as calculate-lisp-indent-last-sexp."
                  (backward-prefix-chars)
                  (current-column)))
            ;; "FIXME: Using `shorthands-intern-soft' is wrong for
            ;; non-Emacs Lisp." - there are no shorthands here.
            (let* ((function
                    (string->symbol
                     (buffer-substring (point)
                                       (begin (forward-sexp 1) (point)))))
                   (local (assq function lisp-indent-local-overrides))
                   (method (if local
                               (cdr local)
                               (get function 'lisp-indent-function))))
              (cond ((or (eq? method 'defun)
                         ;; "Check whether we are in flet-like form."
                         (lisp--local-defform-body-p state))
                     (lisp-indent-defform state indent-point))
                    ((integer? method)
                     (lisp-indent-specform method state
                                           indent-point normal-indent))
                    (else (if method ((method) indent-point state) #f)))))))

    (define lisp-indent-local-overrides '())
    ;; ^ `lisp-indent-local-overrides' (`lisp-mode.el:1288'): "An alist
    ;; of file-local or directory-local indent specifications." Read with
    ;; `assq' above; nothing here sets it.

    (define (lisp--local-defform-body-p state)
      ;; GNU Emacs's `lisp--local-defform-body-p' (`lisp-mode.el:1197'):
      ;; "Return non-nil when at local definition body according to
      ;; STATE." It is what recognises a `cl-flet'-style local function
      ;; definition, whose car *is* an ordinary symbol - so without it
      ;; the body indents as a function call and lines up under the
      ;; first argument (`cl-extra.el' was 3 lines out).
      ;;
      ;; The `read' is Emacs's `(read (current-buffer))' reading the head
      ;; symbol; the Scheme reader takes it from a string port. A read
      ;; error is `ignore-errors''#f.
      ;;--------------------------------------------------------------
      ;; **Every `when' here is an `if' with an explicit `#f'.** Elisp's
      ;; `when' answers nil when its test fails; Scheme's answers the
      ;; unspecified value, which is *true* - and the caller is
      ;; `(if (lisp--local-defform-body-p state) (lisp-indent-defform ...)
      ;; ...)', so a `when' made every form in the buffer a local def.
      (let ((start-of-innermost-containing-list (list-ref state 1)))
        (and start-of-innermost-containing-list
          (let ((parents (list-ref state 9))
                (first-cons-after '())
                (second-cons-after '())
                (first-order-parent #f)
                (second-order-parent #f))
            (set! first-cons-after (if (pair? parents) (cdr parents) '()))
            (set! second-cons-after
                  (if (pair? first-cons-after) (cdr first-cons-after) '()))
            ;; `(while second-cons-after (when (= start (car
            ;; second-cons-after)) (setq second-order-parent (pop parents)
            ;; first-order-parent (pop parents) second-cons-after nil))
            ;; (pop second-cons-after) (pop parents))'
            (let loop ()
              (when (pair? second-cons-after)
                (when (= start-of-innermost-containing-list
                         (car second-cons-after))
                  ;; `(pop parents)' twice - and `(car nil)' is nil in
                  ;; Elisp, an error here.
                  (set! second-order-parent
                        (if (pair? parents) (car parents) #f))
                  (set! parents (if (pair? parents) (cdr parents) '()))
                  (set! first-order-parent
                        (if (pair? parents) (car parents) #f))
                  (set! parents (if (pair? parents) (cdr parents) '()))
                  (set! second-cons-after '()))
                (when (pair? second-cons-after)
                  (set! second-cons-after (cdr second-cons-after)))
                (when (pair? parents) (set! parents (cdr parents)))
                (loop)))
            (and second-order-parent
              (let ((local-definitions-starting-point #f))
                (and
                 (save-excursion
                   (goto-char (+ 1 second-order-parent))
                   (let ((head (guard (e (#t #f))
                                 (let ((h (read (open-input-string
                                                 (buffer-substring
                                                  (point)
                                                  (line-end-position))))))
                                   ;; Emacs's `(read (current-buffer))'
                                   ;; leaves point **past the symbol**,
                                   ;; and the `parse-partial-sexp' below
                                   ;; starts from there. A string port
                                   ;; does not move the buffer's point,
                                   ;; so the move is made here.
                                   (forward-sexp 1)
                                   h))))
                     ;; The C's `(when-let* ... (when (memq ...) (setq ...)))'
                     ;; is the `and''s value - and a `when' answers the
                     ;; unspecified value here, which is true.
                     (and head
                          (if (memq head '(cl-flet cl-labels cl-macrolet
                                                   cl-flet* cl-symbol-macrolet))
                              (begin
                                (parse-partial-sexp (point) first-order-parent
                                                    #f #t)
                                (set! local-definitions-starting-point (point))
                                #t)
                              #f))))
                 (save-excursion
                   (let ((ok (guard (e (#t #f))
                               (backward-up-list 2)
                               #t)))
                     (and ok
                          (= local-definitions-starting-point (point))))))))))))

    (define (lisp-indent-specform count state indent-point normal-indent)
      ;; GNU Emacs's `lisp-indent-specform' (`lisp-mode.el:1369').
      ;;--------------------------------------------------------------
      (let ((containing-form-start (list-ref state 1))
            (i count)
            (body-indent #f)
            (containing-form-column #f))
        ;; "Move to the start of containing form, calculate indentation
        ;; to use for non-distinguished forms (> count), and move past the
        ;; function symbol."
        (goto-char containing-form-start)
        (set! containing-form-column (current-column))
        (set! body-indent (+ lisp-body-indent containing-form-column))
        (forward-char 1)
        (forward-sexp 1)
        ;; "Now find the start of the last form."
        (parse-partial-sexp (point) indent-point 1 #t)
        (let loop ()
          (when (and (< (point) indent-point)
                     (guard (e (#t #f))
                       (set! count (- count 1))
                       (forward-sexp 1)
                       (parse-partial-sexp (point) indent-point 1 #t)
                       #t))
            (loop)))
        ;; "Point is sitting on first character of last (or count) sexp."
        (if (> count 0)
            ;; "A distinguished form. If it is the first or second form
            ;; use double lisp-body-indent, else normal indent."
            (if (<= (- i count) 1)
                (list (+ containing-form-column (* 2 lisp-body-indent))
                      containing-form-start)
                (list normal-indent containing-form-start))
            ;; "A non-distinguished form. Use body-indent if there are no
            ;; distinguished forms and this is the first undistinguished
            ;; form, or if this is the first undistinguished form and the
            ;; preceding distinguished form has indentation at least as
            ;; great as body-indent."
            (if (or (and (= i 0) (= count 0))
                    (and (= count 0) (<= body-indent normal-indent)))
                body-indent
                normal-indent))))

    (define (lisp-indent-defform state indent-point)
      ;; GNU Emacs's `lisp-indent-defform' (`lisp-mode.el:1414').
      ;;--------------------------------------------------------------
      (goto-char (list-ref state 1))
      (forward-line 1)
      (if (> (point) (list-ref state 2))
          (begin
            (goto-char (list-ref state 1))
            (+ lisp-body-indent (current-column)))
          #f))

    (define (lisp-comment-indent)
      ;; GNU Emacs's `lisp-comment-indent' (`lisp-mode.el:887'): "Like
      ;; `comment-indent-default', but don't put space after open paren."
      ;;--------------------------------------------------------------
      (or (if (looking-at "\\s<\\s<")
              ;; Elisp's `when' answers nil when the test fails; Scheme's
              ;; answers the unspecified value, which an `or' takes as
              ;; true - so the fallback below would never run.
              (let ((pt (point)))
                (skip-syntax-backward " ")
                (if (= (preceding-char) 40)     ; ?\(
                    (cons (current-column) (current-column))
                    (begin (goto-char pt) #f)))
              #f)
          (comment-indent-default)))

    ;; ---------------------------------------------------------------
    ;; The `lisp-indent-function' properties (`lisp-mode.el:1423').
    ;;
    ;; "(put 'progn 'lisp-indent-function 0), say, causes progn to be
    ;; indented like defun if the first form is placed on the next line,
    ;; otherwise it is indented like any other form (i.e. forms line up
    ;; under first)."
    ;;
    ;; **The C's entries below are transcribed, not sampled**, and they
    ;; are the ones `lisp-mode.el` sets. `defun`, `defmacro`, `defsubst`
    ;; and `lambda` are here too: Emacs gets theirs from the `(declare
    ;; (indent 2))` in those macros' own definitions (`byte-run.el`'s
    ;; `function-put` for `defmacro`), which is machinery this tree has
    ;; not got. The properties a *library* sets for its own macros -
    ;; `with-temp-buffer`, the `cl-*` family and the rest of the
    ;; preloaded tree - are not here, so those forms indent as ordinary
    ;; function calls.
    ;;--------------------------------------------------------------
    (for-each
     (lambda (entry) (put (car entry) 'lisp-indent-function (cdr entry)))
     (list
      (cons 'defun 2)
      (cons 'defmacro 2)
      (cons 'defsubst 2)
      (cons 'lambda 'defun)
      (cons 'autoload 'defun)             ; Elisp
      (cons 'progn 0)
      (cons 'defvar 'defun)
      (cons 'defalias 'defun)
      (cons 'defvaralias 'defun)
      (cons 'defconst 'defun)
      (cons 'define-category 'defun)
      (cons 'define-charset-internal 'defun)
      (cons 'define-fringe-bitmap 'defun)
      (cons 'prog1 1)
      (cons 'save-excursion 0)            ; Elisp
      (cons 'save-restriction 0)          ; Elisp
      (cons 'save-current-buffer 0)       ; Elisp
      (cons 'let 1)
      (cons 'let* 1)
      (cons 'while 1)
      (cons 'if 2)
      (cons 'catch 1)
      (cons 'condition-case 2)
      (cons 'handler-case 1)              ; CL
      (cons 'unwind-protect 1)))

    ;; ---------------------------------------------------------------
    ;; The `lisp-indent-function' properties the rest of Emacs's tree
    ;; sets from each macro's own `(declare (indent N))'.
    ;;
    ;; Emacs has no table for these: `defmacro' walks the `declare' form
    ;; and `function-put's each key onto the macro's symbol
    ;; (`macroexp-parse-body' and `defmacro' in `byte-run.el'), and
    ;; `lisp-indent-function' reads them with `(function-get SYMBOL
    ;; 'lisp-indent-function 'macro)'. This tree has no `defmacro' - a
    ;; Scheme macro has no symbol to hang a property on - so what would
    ;; be `defmacro''s work is done here, once, as data.
    ;;
    ;; **Transcribed, not sampled**, the way `xterm.sld''s decode map
    ;; and the charset registry were: a script asked a running Emacs
    ;; 31.1 for `(get SYMBOL 'lisp-indent-function)' over every interned
    ;; symbol and this is the answer, minus the names `lisp-mode.el'
    ;; itself sets (above), whose values agree.
    ;;
    ;; **Only a property a fresh Emacs really has, or one that
    ;; `function-get''s autoload reaches, is here.** The dump snapshots
    ;; two things *before* it loads anything - the properties already
    ;; present, and which symbols are autoloaded - and then lets
    ;; `function-get' load an autoloaded symbol's own library. Asking
    ;; the question naively over every symbol gets both wrong: loading
    ;; one library sets properties on symbols visited later, so
    ;; `iter-defun' (a macro in `generator.el', which nothing in a fresh
    ;; `emacs -Q' autoloads) appeared in the table and indented
    ;; `avl-tree.el` to 12 where Emacs says 2; `inline--letlisteval'
    ;; (defined in the very file being indented) did the same.
    ;;
    ;; Not here: a macro from a *user's* library, which Emacs would
    ;; autoload and read and this table cannot see.
    ;;--------------------------------------------------------------
    (for-each
     (lambda (entry) (put (car entry) 'lisp-indent-function (cdr entry)))
     (list
      (cons 'and-let* 1)
      (cons 'atomic-change-group 0)
      (cons 'benchmark-progn 0)
      (cons 'benchmark-run 1)
      (cons 'benchmark-run-compiled 1)
      (cons 'cl--define-built-in-type 2)
      (cons 'cl-block 1)
      (cons 'cl-callf 2)
      (cons 'cl-callf2 3)
      (cons 'cl-case 1)
      (cons 'cl-defgeneric 2)
      (cons 'cl-define-compiler-macro 2)
      (cons 'cl-defmacro 2)
      (cons 'cl-defmethod 'defun)
      (cons 'cl-defstruct 1)
      (cons 'cl-defsubst 2)
      (cons 'cl-deftype 2)
      (cons 'cl-defun 2)
      (cons 'cl-destructuring-bind 2)
      (cons 'cl-do 2)
      (cons 'cl-do* 2)
      (cons 'cl-do-all-symbols 1)
      (cons 'cl-do-symbols 1)
      (cons 'cl-dolist 1)
      (cons 'cl-dotimes 1)
      (cons 'cl-ecase 1)
      (cons 'cl-etypecase 1)
      (cons 'cl-eval-when 1)
      (cons 'cl-flet 1)
      (cons 'cl-flet* 1)
      (cons 'cl-generic-define-context-rewriter 'defun)
      (cons 'cl-generic-define-generalizer 1)
      (cons 'cl-iter-defun 2)
      (cons 'cl-labels 1)
      (cons 'cl-letf 1)
      (cons 'cl-letf* 1)
      (cons 'cl-macrolet 1)
      (cons 'cl-multiple-value-bind 2)
      (cons 'cl-multiple-value-setq 1)
      (cons 'cl-once-only 1)
      (cons 'cl-progv 2)
      (cons 'cl-return-from 1)
      (cons 'cl-symbol-macrolet 1)
      (cons 'cl-the 1)
      (cons 'cl-typecase 1)
      (cons 'cl-with-accessors 2)
      (cons 'cl-with-gensyms 1)
      (cons 'combine-after-change-calls 0)
      (cons 'combine-change-calls 2)
      (cons 'comment-with-narrowing 2)
      (cons 'condition-case-unless-debug 2)
      (cons 'def-edebug-elem-spec 1)
      (cons 'def-edebug-spec 1)
      (cons 'defadvice 2)
      (cons 'defclass 'defun)
      (cons 'defcustom 'defun)
      (cons 'defface 'defun)
      (cons 'defgroup 'defun)
      (cons 'defimage 'defun)
      (cons 'define-abbrev 'defun)
      (cons 'define-abbrev-table 'defun)
      (cons 'define-advice 2)
      (cons 'define-alternatives 'defun)
      (cons 'define-auto-insert 'defun)
      (cons 'define-button-type 'defun)
      (cons 'define-ccl-program 'defun)
      (cons 'define-char-code-property 'defun)
      (cons 'define-charset 'defun)
      (cons 'define-coding-system 'defun)
      (cons 'define-completion-category 'defun)
      (cons 'define-derived-mode 'defun)
      (cons 'define-generic-mode 1)
      (cons 'define-globalized-minor-mode 'defun)
      (cons 'define-ibuffer-column 'defun)
      (cons 'define-ibuffer-filter 2)
      (cons 'define-ibuffer-op 2)
      (cons 'define-ibuffer-sorter 1)
      (cons 'define-icon 2)
      (cons 'define-inline 'defun)
      (cons 'define-iso-single-byte-charset 'defun)
      (cons 'define-key-after 'defun)
      (cons 'define-keymap 'defun)
      (cons 'define-mail-user-agent 'defun)
      (cons 'define-minor-mode 'defun)
      (cons 'define-obsolete-function-alias 'defun)
      (cons 'define-obsolete-variable-alias 'defun)
      (cons 'define-short-documentation-group 'defun)
      (cons 'define-skeleton 'defun)
      (cons 'define-translation-hash-table 'defun)
      (cons 'define-translation-table 'defun)
      (cons 'define-treesit-generic-mode 'defun)
      (cons 'define-widget 'defun)
      (cons 'define-widget-keywords 'defun)
      (cons 'defmath 'defun)
      (cons 'deftheme 1)
      (cons 'defvar-keymap 1)
      (cons 'defvar-local 'defun)
      (cons 'delay-mode-hooks 0)
      (cons 'dlet 1)
      (cons 'dolist 1)
      (cons 'dolist-with-progress-reporter 2)
      (cons 'dont-compile 0)
      (cons 'dotimes 1)
      (cons 'dotimes-with-progress-reporter 2)
      (cons 'easy-menu-define 'defun)
      (cons 'easy-mmode-defmap 1)
      (cons 'easy-mmode-defsyntax 1)
      (cons 'eldoc--documentation-strategy-defcustom 2)
      (cons 'ert-deftest 2)
      (cons 'ert-font-lock-deftest 1)
      (cons 'ert-font-lock-deftest-file 1)
      (cons 'eval-after-load 1)
      (cons 'eval-and-compile 0)
      (cons 'eval-when-compile 0)
      (cons 'gv-define-expander 1)
      (cons 'gv-define-setter 2)
      (cons 'gv-letplace 2)
      (cons 'handler-bind 1)
      (cons 'if-let 2)
      (cons 'if-let* 2)
      (cons 'ignore-error 1)
      (cons 'ignore-errors 0)
      (cons 'inhibit-auto-revert 0)
      (cons 'isearch-define-mode-toggle 'defun)
      (cons 'keymap-set-after 'defun)
      (cons 'let-alist 1)
      (cons 'let-when-compile 1)
      (cons 'letrec 1)
      (cons 'macroexp--accumulate 1)
      (cons 'macroexp--with-extended-form-stack 1)
      (cons 'macroexp-let2 3)
      (cons 'macroexp-let2* 2)
      (cons 'macroexp-preserve-posification 1)
      (cons 'minibuffer-with-setup-hook 1)
      (cons 'named-let 2)
      (cons 'oclosure--lambda 3)
      (cons 'oclosure-define 1)
      (cons 'oclosure-lambda 2)
      (cons 'pcase 1)
      (cons 'pcase-defmacro 2)
      (cons 'pcase-dolist 1)
      (cons 'pcase-exhaustive 1)
      (cons 'pcase-lambda 'defun)
      (cons 'pcase-let 1)
      (cons 'pcase-let* 1)
      (cons 'prog2 2)
      (cons 'replace--push-stack 0)
      (cons 'rx-define 'defun)
      (cons 'rx-let 1)
      (cons 'rx-let-eval 1)
      (cons 'save-mark-and-excursion 0)
      (cons 'save-match-data 0)
      (cons 'save-selected-window 0)
      (cons 'save-window-excursion 0)
      (cons 'seq-doseq 1)
      (cons 'seq-let 2)
      (cons 'static-if 2)
      (cons 'static-unless 1)
      (cons 'static-when 1)
      (cons 'track-mouse 0)
      (cons 'transient-append-suffix 'defun)
      (cons 'transient-inline-group 'defun)
      (cons 'transient-insert-suffix 'defun)
      (cons 'transient-remove-suffix 'defun)
      (cons 'transient-replace-suffix 'defun)
      (cons 'unless 1)
      (cons 'use-package 'defun)
      (cons 'wallpaper-setter-create 1)
      (cons 'when 1)
      (cons 'when-let 1)
      (cons 'when-let* 1)
      (cons 'which-key-add-keymap-based-replacements 'defun)
      (cons 'which-key-add-major-mode-key-based-replacements 'defun)
      (cons 'while-let 1)
      (cons 'while-no-input 0)
      (cons 'with-auto-compression-mode 0)
      (cons 'with-case-table 1)
      (cons 'with-category-table 1)
      (cons 'with-coding-priority 1)
      (cons 'with-connection-local-application-variables 1)
      (cons 'with-connection-local-variables 0)
      (cons 'with-current-buffer 1)
      (cons 'with-current-buffer-window 3)
      (cons 'with-delayed-message 1)
      (cons 'with-demoted-errors 1)
      (cons 'with-displayed-buffer-window 3)
      (cons 'with-environment-variables 1)
      (cons 'with-eval-after-load 1)
      (cons 'with-existing-directory 0)
      (cons 'with-file-modes 1)
      (cons 'with-help-window 1)
      (cons 'with-local-quit 0)
      (cons 'with-locale-environment 1)
      (cons 'with-memoization 1)
      (cons 'with-minibuffer-completions-window 0)
      (cons 'with-minibuffer-selected-window 0)
      (cons 'with-mutex 1)
      (cons 'with-no-warnings 0)
      (cons 'with-output-to-string 0)
      (cons 'with-output-to-temp-buffer 1)
      (cons 'with-restriction 2)
      (cons 'with-selected-frame 1)
      (cons 'with-selected-window 1)
      (cons 'with-silent-modifications 0)
      (cons 'with-suppressed-warnings 1)
      (cons 'with-syntax-table 1)
      (cons 'with-system-sleep-block 1)
      (cons 'with-temp-buffer 0)
      (cons 'with-temp-buffer-window 3)
      (cons 'with-temp-file 1)
      (cons 'with-temp-message 1)
      (cons 'with-timeout 1)
      (cons 'with-undo-amalgamate 0)
      (cons 'with-window-non-dedicated 1)
      (cons 'with-work-buffer 0)
      (cons 'with-wrapper-hook 2)
      (cons 'without-remote-files 0)
      (cons 'without-restriction 0)))
    (define-command (indent-sexp . rest)
      "Indent each line of the list starting just after point.
If optional arg ENDPOS is given, indent each line, stopping when
ENDPOS is encountered."
      (interactive '())
      (let* ((endpos (if (and (pair? rest) (car rest)) (car rest) #f))
             (parse-state (lisp-indent-initial-state))
             ;; "We need a marker because we modify the buffer text
             ;; preceding endpos."
             (endpos (copy-marker
                      (if endpos endpos
                          ;; "Get error now if we don't have a complete
                          ;; sexp after point."
                          (save-excursion
                            (forward-sexp 1)
                            (let ((eol (line-end-position)))
                              ;; "We actually look for a sexp which ends
                              ;; after the current line so that we properly
                              ;; indent things like #s(...)."
                              (when (and (< (point) eol)
                                         (> (list-ref
                                             (save-excursion
                                               (parse-partial-sexp (point) eol))
                                             0)
                                            0))
                                (guard (e ((scan-error? e) #f))
                                  (let loop ()
                                    (when (< (point) eol)
                                      (forward-sexp 1)
                                      (loop)))))
                              (point)))))))
        (save-excursion
          (let loop ()
            (let ((indent (lisp-indent-calc-next parse-state))
                  (ppss (lisp-indent-state-ppss parse-state)))
              ;; "If the line contains a comment indent it now with
              ;; `indent-for-comment'."
              (when (and (list-ref ppss 4)
                         (<= (list-ref ppss 8) (marker-position endpos)))
                (save-excursion
                  (goto-char (lisp-indent-state-ppss-point parse-state))
                  (indent-for-comment)
                  (set!lisp-indent-state-ppss-point!
                   parse-state (line-end-position))))
              (when (< (point) (marker-position endpos))
                ;; "Indent the next line, unless it's blank, or just a
                ;; comment (we will `indent-for-comment' the latter)."
                (skip-chars-forward " \t")
                (unless (or (eolp) (not indent)
                            (char=? (char-syntax (char-after (point))) #\<))
                  (indent-line-to indent))
                (loop)))))
        (set-marker endpos #f)))

    ;;----------------------------------------------------------------
    ;; `lisp-data-mode' and `lisp-mode'
    ;;------------------------------------------------------------------

    (define lisp-data-mode-map (km:keymap '*lisp-data-mode-map*))
    (define lisp-data-mode-hook '())
    (define lisp-mode-shared-map (km:keymap '*lisp-mode-shared-map*))
    ;; "C-M-q" #'indent-sexp (`lisp-mode.el:818'). Emacs's `emacs-lisp-mode'
    ;; rebinds it to `indent-pp-sexp', which is `indent-sexp' plus
    ;; `pp-buffer' - not ported, so that mode keeps this binding and the
    ;; prefix argument has nothing to say.
    (define-key lisp-mode-shared-map (kbd "C-M-q") indent-sexp)

    ;; `move-past-close-and-reindent' (`lisp.el:969') calls
    ;; `calculate-lisp-indent', which is this library's; `lisp.scm' is
    ;; below it, so the call comes through the seam it defines.
    (*calculate-lisp-indent-function* calculate-lisp-indent)
    (define lisp-mode-map (km:keymap '*lisp-mode-map*))
    (define lisp-mode-hook '())

    (define-derived-mode (lisp-data-mode prog-mode "Lisp-Data"
                                         lisp-data-mode-map
                                         lisp-data-mode-hook
                                         lisp-data-mode-syntax-table)
      "Major mode for buffers holding data written in Lisp syntax."
      (lisp-mode-variables #f #t #f))

    (define lisp-mode-syntax-propertize-rules
      ;; "`syntax-propertize' rules for Common Lisp code."
      ;; (`lisp-mode.el:88-104'), the C's `(syntax-propertize-precompile-
      ;; rules ...)' - which is the rules themselves here.
      ;;
      ;;   - "Give entire multiple escape sections symbol syntax. Without
      ;;     this, `forward-sexp' and co. treat `symbols| like |this' as
      ;;     three expressions."
      ;;   - "Give numeric args and the sub character in dispatch macros
      ;;     prefix syntax."
      ;;--------------------------------------------------------------
      (list
       (list "|\\(?:\\\\|\\|[^|]\\)+|"
             (list 0 (lambda ()
                       (if (ppss-comment-or-string-start (syntax-ppss))
                           #f
                           (string-to-syntax "_")))))
       (list "#\\(?1:[0-9]*[*+.:=ACPSacps-]\\)\\|#\\(?1:[0-9]+\\)(\\|,\\(?1:[.@]\\)"
             (list 1 (lambda ()
                       (if (ppss-comment-or-string-start (syntax-ppss))
                           #f
                           (string-to-syntax "'")))))))

    (define (lisp-mode-syntax-propertize start end)
      ;; "Add syntax-table properties to Common Lisp code between START
      ;; and END. Used as the value of `syntax-propertize-function' in
      ;; `lisp-mode'."
      ;;--------------------------------------------------------------
      ((syntax-propertize-rules lisp-mode-syntax-propertize-rules)
       start end))

    (define %common-lisp-indent-function #f)
    ;; ^ `(schemacs editor cl-indent)`'s `common-lisp-indent-function`,
    ;; once that library has loaded. Emacs's is `;;;###autoload`ed
    ;; (`cl-indent.el:208`), so the symbol is `fboundp` before the file
    ;; is; the name is fetched here on first use for the same reason.

    (define (%cl-indent-function)
      ;; Emacs's autoload, spelled the way `files.sld`'s `%autoload-mode`
      ;; is: `resolve-module` loads a library that is not loaded yet.
      ;;
      ;; **It is a resolve and not an import**, because `cl-indent.scm`
      ;; imports *this* library (it needs `lisp-body-indent` and
      ;; `lisp-indent-local-overrides`), so an import back would be a
      ;; cycle. By the time `lisp-mode` runs, cl-indent's own import of
      ;; this library resolves to the copy already loaded.
      ;;--------------------------------------------------------------
      (unless %common-lisp-indent-function
        (let ((module (resolve-module '(schemacs editor cl-indent) #t)))
          (set! %common-lisp-indent-function
                (module-ref module 'common-lisp-indent-function))))
      %common-lisp-indent-function)

    (define-derived-mode (lisp-mode lisp-data-mode "Lisp" lisp-mode-map
                                    lisp-mode-hook lisp-mode-syntax-table)
      "Major mode for editing programs in Common Lisp and other similar
Lisps."
      ;; `(setq-local lisp-indent-function #'common-lisp-indent-function)'
      ;; - Emacs sets the *symbol*, which its autoload machinery turns
      ;; into the loaded function; a Scheme symbol is not callable, so
      ;; the procedure is fetched first. See `%cl-indent-function`.
      (setq-local 'lisp-indent-function (%cl-indent-function))
      (setq-local 'comment-start-skip
                  "\\(\\(^\\|[^\\\n]\\)\\(\\\\\\\\\\)*\\)\\(;+\\|#|\\) *")
      (setq-local 'comment-end-skip "[ \t]*\\(\\s>\\||#\\)")
      (setq-local 'font-lock-comment-end-skip "|#")
      (setq-local 'syntax-propertize-function lisp-mode-syntax-propertize))

    ))
