(define-library (schemacs progmodes cc-langs)
  ;; `lisp/progmodes/cc-langs.el', the language-variable system only so
  ;; far: `c-lang-defvar', `c-lang-setvar',
  ;; `c-make-emacs-variables-local', `c-make-init-lang-vars-fun' and
  ;; `c-init-language-vars' (`cc-langs.el:130'-`:205', `:4608'-`:4715').
  ;; The language data itself - the `c-lang-defconst' tables - comes
  ;; next, and with it the syntax tables that make
  ;; `c-make-keywords-re''s symbol/non-symbol split exact.
  ;;
  ;; **The representation departure.** Emacs's language variables are
  ;; buffer-local variables (defvar + make-variable-buffer-local, set
  ;; per mode init by the function `c-init-language-vars' generates).
  ;; Here a language variable is a *buffer-local slot* keyed by the
  ;; Emacs symbol - the tree's buffer-local mechanism
  ;; (`set-buffer-local-value!') - and ported cc-mode code reads one
  ;; through `c-mode-var' or `buffer-local-value'. There is no symbol
  ;; value cell and no global value to copy, so
  ;; `c-make-emacs-variables-local' ensures the slot exists and sets
  ;; nothing else.
  ;;
  ;; `c-lang-defvar' and `c-lang-setvar' register their (var val doc)
  ;; in an ordered list at expand, load and eval time. The `defconst's
  ;; that bake the two lists into Emacs's compiled cc-langs have no
  ;; counterpart: the list is the registry.
  ;;
  ;; `c-init-language-vars' expands at the caller's compile time: each
  ;; VAL is evaluated *then* (with `*c-buffer-is-cc-mode*' bound to the
  ;; language), and a value that is literal data is baked into the
  ;; expansion as a quoted value - Emacs's compiled path. A value that
  ;; is not literal (a function, a record) becomes a runtime
  ;; `c-lang-var-value' call, which evaluates the source then; that is
  ;; Emacs's source-eval fallback, per variable.
  (import
    (scheme base)
    (only (guile) eval eval-when current-module module-name
                  syntax with-syntax syntax-case syntax->datum datum->syntax
                  make-hash-table hash-set!)
    (only (schemacs buffer) current-buffer set-buffer-local-value!
          buffer-local-value)
    (only (schemacs progmodes cc-defs)
          c-lang-const c-lang-defconst c-lang-defconst-eval-immediately
          c-get-lang-constant c-lang-defconst-eval-now c-mode-var-boundp
          c-lang-constant-documentation c-literal-datum?
          c-major-mode-is *c-buffer-is-cc-mode*
          c-mode-symbol c-mode-var c-concat-separated c-make-bare-char-alt
          c-make-keywords-re c--mapcan c--set-difference c--intersection
          c--delete-duplicates c-lang-constant-names c-emacs-features
          c-with-syntax-table c-int-to-char c-characterp
          %c-true %c-false
          c-alpha c-alnum c-digit c-upper c-lower)
    (only (schemacs subr) make-syntax-table remove
          string-suffix-p
          delq remq intern regexp-unmatchable)
    (only (schemacs syntax) modify-syntax-entry char-syntax
          copy-syntax-table)
    (only (schemacs fns) concat %substring %string %length mapcar
          elt identity string-equal delete)
    (only (schemacs eval) funcall)
    (only (schemacs data) aref)
    (only (schemacs search)
          string-match regexp-opt-depth regexp-quote
          match-beginning match-end)
    (only (schemacs core regexp-opt) regexp-opt))
  (export c-lang-defvar c-lang-setvar c-make-emacs-variables-local
          c-make-init-lang-vars-fun c-init-language-vars
          c-lang-set-local! c-lang-var-value c-filter-ops
          c-kwds-lang-consts)

  (begin

    ;; `eval-when (expand ...)': a `c-lang-defvar' in this very file
    ;; registers its variable while the file is being expanded, before
    ;; its ordinary definitions have run. Emacs's `c-lang-defvar' is
    ;; `eval-and-compile' for the same reason.
    (eval-when (expand load eval)
      (define-record-type <c-lang-var>
        (%make-c-lang-var var kind expr module doc)
        c-lang-var?
        (var c-lang-var-var)
        (kind c-lang-var-kind)        ; 'lang or 'emacs
        (expr c-lang-var-expr)        ; source data
        (module c-lang-var-module)    ; module object of the definition
        (doc c-lang-var-doc))

      (define %c-lang-vars '())

      (define (c-register-lang-var! var kind expr doc)
        ;; Replace an earlier registration of VAR in place, as Emacs's
        ;; `(if elem (setcdr elem (list val doc)) ...)' does, so the
        ;; order of the list is the order to set the variables in.
        (let ((record (%make-c-lang-var var kind expr (current-module) doc)))
          (let loop ((l %c-lang-vars) (acc '()))
            (cond ((null? l)
                   (set! %c-lang-vars (reverse (cons record acc))))
                  ((eq? (c-lang-var-var (car l)) var)
                   (set! %c-lang-vars
                         (append (reverse acc) (cons record (cdr l)))))
                  (else (loop (cdr l) (cons (car l) acc))))))))

    (define (%c-lang-vars-of-kind kind)
      (let loop ((l %c-lang-vars) (acc '()))
        (cond ((null? l) (reverse acc))
              ((eq? (c-lang-var-kind (car l)) kind)
               (loop (cdr l) (cons (car l) acc)))
              (else (loop (cdr l) acc)))))

    (define (%c-find-lang-var var)
      (let loop ((l %c-lang-vars))
        (cond ((null? l) #f)
              ((eq? (c-lang-var-var (car l)) var) (car l))
              (else (loop (cdr l))))))

    ;;------------------------------------------------------------------
    ;; `c-lang-set-local!' and `c-lang-var-value': what generated code
    ;; calls at run time.
    ;;------------------------------------------------------------------
    (define (c-lang-set-local! var value)
      ;; Set the buffer-local slot for VAR in the current buffer - the
      ;; tree's `make-local-variable' + `set'.
      (set-buffer-local-value! (current-buffer) var value))

    (define (c-lang-var-value var mode)
      ;; The source-eval path: evaluate VAR's definition with the
      ;; language bound, in the module that defined it.
      (let ((record (%c-find-lang-var var)))
        (or record (error "No `c-lang-defvar' for `~a'" var))
        (parameterize ((*c-buffer-is-cc-mode* mode))
          (eval (c-lang-var-expr record) (c-lang-var-module record)))))

    ;;------------------------------------------------------------------
    ;; `c-lang-defvar' (`cc-langs.el:153') and `c-lang-setvar' (`:180')
    ;;------------------------------------------------------------------
    (eval-when (expand load eval)
      ;; `eval-when (expand ...)': the transformer below calls this while
      ;; cc-langs.scm itself is being expanded, when the file's ordinary
      ;; definitions have not run yet. (cc-langs is the first library to
      ;; both define `c-lang-defvar' and use it.)
      (define (%c-lang-defvar-doc var val)
        ;; The docstring, or the constant's when VAL is a plain
        ;; `(c-lang-const var)' - Emacs's special case.
        (if (and (pair? val)
                 (eq? (car val) 'c-lang-const)
                 (eq? (cadr val) var)
                 (null? (cddr val)))
            (c-lang-constant-documentation var)
            #f)))

    (define-syntax c-lang-defvar
      (lambda (stx)
        (syntax-case stx ()
          ((_ var val)
           (let* ((v (syntax->datum (syntax var)))
                  (e (syntax->datum (syntax val)))
                  (doc (%c-lang-defvar-doc v e)))
             (with-syntax ((v* (datum->syntax (syntax var) v))
                           (e* (datum->syntax (syntax val) e))
                           (d* (datum->syntax (syntax var) doc)))
               #'(begin
                   (eval-when (expand load eval)
                     (c-register-lang-var! 'v* 'lang 'e* d*))
                   (quote v*)))))
          ((_ var val doc)
           (let ((v (syntax->datum (syntax var)))
                 (e (syntax->datum (syntax val)))
                 (d (syntax->datum (syntax doc))))
             (with-syntax ((v* (datum->syntax (syntax var) v))
                           (e* (datum->syntax (syntax val) e))
                           (d* (datum->syntax (syntax var) d)))
               #'(begin
                   (eval-when (expand load eval)
                     (c-register-lang-var! 'v* 'lang 'e* d*))
                   (quote v*))))))))

    (define-syntax c-lang-setvar
      (lambda (stx)
        (syntax-case stx ()
          ((_ var val)
           (let ((v (syntax->datum (syntax var)))
                 (e (syntax->datum (syntax val))))
             (with-syntax ((v* (datum->syntax (syntax var) v))
                           (e* (datum->syntax (syntax val) e)))
               #'(begin
                   (eval-when (expand load eval)
                     (c-register-lang-var! 'v* 'emacs 'e* #f))
                   (quote v*))))))))

    ;;------------------------------------------------------------------
    ;; `c-make-emacs-variables-local' (`cc-langs.el:4635')
    ;;------------------------------------------------------------------
    (define (c-lang-make-local-emacs-vars!)
      ;; Emacs's `make-local-variable' for each `c-lang-setvar'
      ;; variable: here it only ensures the buffer-local slot exists
      ;; (there is no global value to copy).
      (for-each (lambda (record)
                  (let ((var (c-lang-var-var record)))
                    (set-buffer-local-value!
                     (current-buffer) var
                     (buffer-local-value (current-buffer) var #f))))
                (%c-lang-vars-of-kind 'emacs)))

    (define-syntax c-make-emacs-variables-local
      (lambda (stx)
        (syntax-case stx ()
          ((_) #'(c-lang-make-local-emacs-vars!)))))

    ;;------------------------------------------------------------------
    ;; `c-make-init-lang-vars-fun' (`cc-langs.el:4616')
    ;;------------------------------------------------------------------
    (define (c-make-init-lang-vars-fun mode)
      ;; A *form*, for `c-init-language-vars' to splice: one
      ;; `c-lang-set-local!' call per variable, with the value baked
      ;; when it is literal data (evaluated now, in the defining
      ;; module, with the language bound) and a runtime
      ;; `c-lang-var-value' call otherwise.
      (cons 'begin
            (map (lambda (record)
                   (let* ((var (c-lang-var-var record))
                          (value (%c-lang-init-value record mode)))
                     ;; `%c-no-value` - what the guard answers when the
                     ;; VAL could not be evaluated - is a two-element
                     ;; list of symbols, which `c-literal-datum?` would
                     ;; otherwise take for literal data and bake into
                     ;; the initialisation. It must take the runtime
                     ;; path instead, where a buffer exists and the
                     ;; variable can be computed.
                     (if (and (c-literal-datum? value)
                              (not (equal? value (%c-no-value))))
                         (list 'c-lang-set-local! (list 'quote var)
                               (list 'quote value))
                         (list 'c-lang-set-local! (list 'quote var)
                               (list 'c-lang-var-value (list 'quote var)
                                     (list 'quote mode))))))
                 (append (%c-lang-vars-of-kind 'emacs)
                         (%c-lang-vars-of-kind 'lang)))))

    (define (%c-lang-init-value record mode)
      ;; Evaluate RECORD's definition now; on any error, answer a value
      ;; the caller cannot mistake for literal data so it takes the
      ;; runtime path.
      (guard (e (#t (%c-no-value)))
        (parameterize ((*c-buffer-is-cc-mode* mode))
          (eval (c-lang-var-expr record) (c-lang-var-module record)))))

    (define (%c-no-value) (list 'no-value))

    ;;------------------------------------------------------------------
    ;; `c-init-language-vars' (`cc-langs.el:4707')
    ;;------------------------------------------------------------------
    (define-syntax c-init-language-vars
      (lambda (stx)
        (syntax-case stx ()
          ((_ mode)
           (let ((m (syntax->datum (syntax mode))))
             (unless (symbol? m)
               (error "Not a symbol: ~s" m))
             (datum->syntax (syntax mode)
                            (c-make-init-lang-vars-fun m)))))))

    ;;------------------------------------------------------------------
    ;; The syntax tables (`cc-langs.el:331'-`:395')
    ;;------------------------------------------------------------------
    (define (c-populate-syntax-table table)
      ;; "Populate the given syntax table as necessary for a C-like
      ;; language." Emacs's `c-emacs-features' branch taken is its
      ;; 1-bit (Emacs) one; the XEmacs arm has no counterpart here.
      (modify-syntax-entry #\_ "_" table)
      (modify-syntax-entry #\\ "\\" table)
      (modify-syntax-entry #\+ "." table)
      (modify-syntax-entry #\- "." table)
      (modify-syntax-entry #\= "." table)
      (modify-syntax-entry #\% "." table)
      (modify-syntax-entry #\< "." table)
      (modify-syntax-entry #\> "." table)
      (modify-syntax-entry #\& "." table)
      (modify-syntax-entry #\| "." table)
      (modify-syntax-entry #\' "\"" table)
      (modify-syntax-entry #\x00A0 " " table)
      (modify-syntax-entry #\/ ". 124b" table)
      (modify-syntax-entry #\* ". 23" table)
      (modify-syntax-entry #\newline "> b" table)
      (modify-syntax-entry #\return "> b" table)
      table)

    (c-lang-defconst c-make-mode-syntax-table
      "Functions that generates the mode specific syntax tables."
      t (let ((at-entry (cond ((c-major-mode-is 'objc-mode) (cons #\@ "_"))
                              ((c-major-mode-is 'java-mode) (cons #\@ "_"))
                              ((c-major-mode-is 'pike-mode) (cons #\@ "."))
                              (else #f))))
          ;; Emacs splices the chosen `modify-syntax-entry' into the
          ;; lambda at constant-evaluation time; the choice is made
          ;; here, once, for the same reason: `c-major-mode-is' must
          ;; not be re-asked when the lambda is called in a buffer of
          ;; another language.
          (lambda ()
            (let ((table (make-syntax-table)))
              (c-populate-syntax-table table)
              (when at-entry
                (modify-syntax-entry (car at-entry) (cdr at-entry) table))
              table))))

    (c-lang-defconst c-mode-syntax-table
      ;; "The syntax tables in evaluated form."
      t ((c-lang-const c-make-mode-syntax-table)))

;;; ------------------------------------------------------------------
    ;;------------------------------------------------------------------
    ;; `c-filter-ops' (`cc-langs.el:214')
    ;;------------------------------------------------------------------
    ;; "Extract a subset of the operators in the list OPS in a DWIM:ey
    ;; way.  The return value is a plain list of operators". Emacs's
    ;; `setq' of a lambda is written as a second binding; the
    ;; `c-with-syntax-table' takes a thunk here.
    (define (c-filter-ops ops opgroup-filter op-filter . rest)
      (let ((xlate (and (pair? rest) (car rest))))
        ;; Emacs's nil is both spellings here; `c-filter-ops' is called
        ;; with a constant that a language does not set.
        (unless ops (set! ops '()))
        (unless (list? (if (pair? ops) (car ops) '()))
          (set! ops (list ops)))
        (cond ((eq? opgroup-filter #t)
               (set! opgroup-filter (lambda (opgroup) #t)))
              ((not (procedure? opgroup-filter))
               (let ((wanted opgroup-filter))
                 (set! opgroup-filter
                       (lambda (opgroup) (memq opgroup wanted))))))
        (cond ((eq? op-filter #t)
               (set! op-filter (lambda (op) #t)))
              ((string? op-filter)
               (let ((regexp op-filter))
                 (set! op-filter
                       (lambda (op) (string-match regexp op))))))
        (unless xlate
          (set! xlate identity))
        (c-with-syntax-table
         (c-lang-const c-mode-syntax-table)
         (lambda ()
           (c--delete-duplicates
            (c--mapcan
             (lambda (opgroup)
               ;; Emacs's `(symbolp (car opgroup))' is *true for nil* -
               ;; nil is a symbol there - so a group whose head is nil
               ;; (`(cons nil c-after-id-concat-ops)`) is a group like
               ;; any other. `#f` is this tree's nil.
               (if (if (or (symbol? (car opgroup)) (not (car opgroup)))
                       (if (funcall opgroup-filter (car opgroup))
                           (begin (set! opgroup (cdr opgroup)) #t)
                           #f)
                       #t)
                   (c--mapcan
                    (lambda (op)
                      (if (funcall op-filter op)
                          ;; Emacs's `(if (listp res) res (list res))':
                          ;; a nil result is spliced as nothing, which is
                          ;; `#f` here.
                          (let ((res (funcall xlate op)))
                            (cond ((list? res) res)
                                  ((not res) '())
                                  (else (list res))))
                          #f))
                    opgroup)
                   #f))
             ops)
            ':test equal?)))))

;;; The mode menu's items (`cc-langs.el:275'). **Less the items whose
;;; commands this tree does not have** - "Macro Expand Region"
;;; (`c-macro-expand' runs cpp as a subprocess), the Style submenu's
;;; two guess entries (`cc-guess.el') and the "Subword mode" toggle
;;; (`cc-subword.el'); a menu item naming a missing command signals
;;; when it is clicked. That is the same accounting `menu-bar.scm'
;;; keeps for the menu bar. **The `:selected' values are calls, not the
;;; variable symbols Emacs writes**, because this tree's variables are
;;; accessor procedures; a bare symbol would evaluate to the procedure
;;; and the toggle would always look selected.
(c-lang-defconst c-mode-menu
  "The definition for the mode menu.  The menu title is prepended to
this before it's fed to `easy-menu-define'."
  t
  (append
   (list
    (vector "Comment Out Region" 'comment-region
            '(c-fn-region-is-active-p))
    (vector "Uncomment Region"
            (list 'comment-region '(region-beginning) '(region-end)
                  '(list 4))
            '(c-fn-region-is-active-p))
    (vector "Indent Expression" 'c-indent-exp
            (list 'memq '(char-after) (list 'list #\( #\[ #\{)))
    (vector "Indent Line or Region" 'c-indent-line-or-region #t)
    (vector "Fill Comment Paragraph" 'c-fill-paragraph #t)
    "----"
    (vector "Backward Statement" 'c-beginning-of-statement #t)
    (vector "Forward Statement" 'c-end-of-statement #t))
   ;; "Only applicable if there's a cpp preprocessor."
   (if (%c-true (c-lang-const c-opt-cpp-prefix))
       (list
        (vector "Up Conditional" 'c-up-conditional #t)
        (vector "Backward Conditional" 'c-backward-conditional #t)
        (vector "Forward Conditional" 'c-forward-conditional #t)
        "----"
        (vector "Backslashify" 'c-backslash-region
                '(c-fn-region-is-active-p)))
       '())
   (list
    "----"
    (list "Style..."
          (vector "Set Style..." 'c-set-style #t)
          (vector "Show Current Style Name"
                  (list 'message
                        "Style Name: %s"
                        '(c-indentation-style))
                  #t))
    "----"
    (list "Toggle..."
          (vector "Syntactic indentation" 'c-toggle-syntactic-indentation
                  ':style 'toggle ':selected '(c-syntactic-indentation))
          (vector "Electric mode" 'c-toggle-electric-state
                  ':style 'toggle ':selected '(c-electric-flag))
          (vector "Auto newline" 'c-toggle-auto-newline
                  ':style 'toggle ':selected '(c-auto-newline))
          (vector "Hungry delete" 'c-toggle-hungry-state
                  ':style 'toggle ':selected '(c-hungry-delete-key))))))

(c-lang-defconst c-make-no-parens-syntax-table
  ;; "A variant of the standard syntax table which is used to find
  ;; matching \"<\"s and \">\"s which have been marked as parens using
  ;; syntax table properties. ... This variable is nil for languages
  ;; which don't have template stuff."
  ;;
  ;; Emacs's value is a quasiquoted lambda with the syntax-table maker
  ;; spliced in by `funcall' and `eval'; a procedure is a value here, so
  ;; the maker is simply closed over.
  t
  (if (c-lang-const c-recognize-<>-arglists)
         (let ((make (c-lang-const c-make-mode-syntax-table)))
           (lambda ()
             (let ((table (make)))
               (modify-syntax-entry #\( "." table)
               (modify-syntax-entry #\) "." table)
               (modify-syntax-entry #\[ "." table)
               (modify-syntax-entry #\] "." table)
               (modify-syntax-entry #\{ "." table)
               (modify-syntax-entry #\} "." table)
               table)))
         #f))
(c-lang-defvar c-no-parens-syntax-table
  ;; Emacs: "(and (c-lang-const c-make-no-parens-syntax-table)
  ;; (funcall (eval (c-lang-const ...))))" - the `eval' is for the
  ;; byte-compiled quasiquote's benefit and has no counterpart.
  (let ((make (c-lang-const c-make-no-parens-syntax-table)))
    (if make (make) #f)))

;; c-identifier-syntax-modifications
(c-lang-defconst c-identifier-syntax-modifications
  "A list that describes the modifications that should be done to the\nmode syntax table to get a syntax table that matches all identifiers\nand keywords as words.\n\nThe list is just like the one used in `font-lock-defaults': Each\nelement is a cons where the car is the character to modify and the cdr\nthe new syntax, as accepted by `modify-syntax-entry'."
  t
  '((#\_ . "w") (#\$ . "w"))
  (objc java)
  (append '((#\@ . "w")) (or (c-lang-const c-identifier-syntax-modifications) '()))
  awk
  '((#\_ . "w")))

;; c-identifier-syntax-modifications
(c-lang-defvar c-identifier-syntax-modifications (c-lang-const c-identifier-syntax-modifications))

;; c-identifier-syntax-table
(c-lang-defvar c-identifier-syntax-table (let ((table (copy-syntax-table (c-lang-const c-mode-syntax-table))) (mods (c-lang-const c-identifier-syntax-modifications)) (mod '())) (let %while2 () (if (%c-true mods) (begin (let ((%q0 (car mods))) (set! mod %q0) (let ((%q2 (cdr mods))) (set! mods %q2) %q2)) (modify-syntax-entry (car mod) (cdr mod) table) (%while2)) #f)) table))

;; c-get-state-before-change-functions
(c-lang-defconst c-get-state-before-change-functions
  t
  '(c-before-change-include-<> c-before-change-check-unbalanced-strings)
  c++
  '(c-extend-region-for-CPP c-depropertize-CPP c-before-change-check-ml-strings c-unmark-<>-around-region c-before-change-check-<>-operators c-before-after-change-check-c++-modules c-truncate-bs-cache c-before-change-check-unbalanced-strings c-parse-quotes-before-change c-before-change-fix-comment-escapes)
  c
  '(c-extend-region-for-CPP c-before-change-include-<> c-depropertize-CPP c-truncate-bs-cache c-before-change-check-unbalanced-strings c-parse-quotes-before-change c-before-change-fix-comment-escapes)
  objc
  '(c-extend-region-for-CPP c-depropertize-CPP c-truncate-bs-cache c-before-change-check-unbalanced-strings c-unmark-<>-around-region c-before-change-check-<>-operators c-parse-quotes-before-change c-before-change-fix-comment-escapes)
  java
  '(c-parse-quotes-before-change c-unmark-<>-around-region c-before-change-check-unbalanced-strings c-before-change-check-<>-operators)
  pike
  '(c-before-change-include-<> c-before-change-check-ml-strings c-before-change-check-unbalanced-strings)
  awk
  'c-awk-record-region-clear-NL)

;; c-get-state-before-change-functions
(c-lang-defvar c-get-state-before-change-functions (let ((fs (c-lang-const c-get-state-before-change-functions))) (if (%c-true (list? fs)) fs (list fs))))

;; c-before-font-lock-functions
(c-lang-defconst c-before-font-lock-functions
  t
  '(c-depropertize-new-text c-after-change-escape-NL-in-string c-after-change-mark-abnormal-strings c-after-change-include-<> c-change-expand-fl-region)
  c
  '(c-depropertize-new-text c-after-change-fix-comment-escapes c-after-change-escape-NL-in-string c-parse-quotes-after-change c-after-change-mark-abnormal-strings c-extend-font-lock-region-for-macros c-after-change-include-<> c-neutralize-syntax-in-CPP c-change-expand-fl-region)
  objc
  '(c-depropertize-new-text c-after-change-fix-comment-escapes c-after-change-escape-NL-in-string c-parse-quotes-after-change c-after-change-mark-abnormal-strings c-unmark-<>-around-region c-extend-font-lock-region-for-macros c-neutralize-syntax-in-CPP c-restore-<>-properties c-change-expand-fl-region)
  c++
  '(c-depropertize-new-text c-after-change-fix-comment-escapes c-after-change-escape-NL-in-string c-after-change-unmark-ml-strings c-parse-quotes-after-change c-after-change-mark-abnormal-strings c-unmark-<>-around-region c-extend-font-lock-region-for-macros c-before-after-change-check-c++-modules c-neutralize-syntax-in-CPP c-restore-<>-properties c-change-expand-fl-region)
  java
  '(c-depropertize-new-text c-after-change-escape-NL-in-string c-parse-quotes-after-change c-unmark-<>-around-region c-after-change-mark-abnormal-strings c-restore-<>-properties c-change-expand-fl-region)
  pike
  '(c-depropertize-new-text c-after-change-escape-NL-in-string c-after-change-unmark-ml-strings c-after-change-mark-abnormal-strings c-after-change-include-<> c-change-expand-fl-region)
  awk
  '(c-depropertize-new-text c-awk-extend-and-syntax-tablify-region))

;; c-before-font-lock-functions
(c-lang-defvar c-before-font-lock-functions (let ((fs (c-lang-const c-before-font-lock-functions))) (if (%c-true (list? fs)) fs (list fs))))

;; c-before-context-fontification-functions
(c-lang-defconst c-before-context-fontification-functions
  t
  'c-context-expand-fl-region
  awk
  'c-awk-context-expand-fl-region)

;; c-before-context-fontification-functions
(c-lang-defvar c-before-context-fontification-functions (let ((fs (c-lang-const c-before-context-fontification-functions))) (if (%c-true (list? fs)) fs (list fs))))

;; c-at-vsemi-p-fn
(c-lang-defconst c-at-vsemi-p-fn
  "Contains a function \"Is there a virtual semicolon at POS or point?\".\nSuch a function takes one optional parameter, a buffer position (defaults to\npoint), and returns nil or t.  This variable contains nil for languages which\ndon't have EOL terminated statements. "
  t
  #f
  (c objc)
  'c-at-macro-vsemi-p
  c++
  'c-c++-vsemi-p
  awk
  'c-awk-at-vsemi-p)

;; c-at-vsemi-p-fn
(c-lang-defvar c-at-vsemi-p-fn (c-lang-const c-at-vsemi-p-fn))

;; c-vsemi-status-unknown-p-fn
(c-lang-defconst c-vsemi-status-unknown-p-fn
  "A function \"are we unsure whether there is a virtual semicolon on this line?\".\nThe (admittedly kludgy) purpose of such a function is to prevent an infinite\nrecursion in c-beginning-of-statement-1 when point starts at a `while' token.\nThe function MUST NOT UNDER ANY CIRCUMSTANCES call `c-beginning-of-statement-1',\neven indirectly.  This variable contains nil for languages which don't have\nEOL terminated statements."
  t
  #f
  (c c++ objc)
  'c-macro-vsemi-status-unknown-p
  awk
  'c-awk-vsemi-status-unknown-p)

;; c-vsemi-status-unknown-p-fn
(c-lang-defvar c-vsemi-status-unknown-p-fn (c-lang-const c-vsemi-status-unknown-p-fn))

;; c-has-bitfields
(c-lang-defconst c-has-bitfields
  "Whether the language has bitfield declarations."
  t
  #f
  (c c++ objc)
  #t)

;; c-has-bitfields
(c-lang-defvar c-has-bitfields (c-lang-const c-has-bitfields))

;; c-single-quotes-quote-strings
(c-lang-defconst c-single-quotes-quote-strings
  "Whether the language uses single quotes for multi-char strings.\n\nNote that to set up a language to use this, additionally:\n(i) the syntax of \"'\" must be \"string quote\" (7);\n(ii) the language's value of `c-has-quoted-numbers' must be nil;\n(iii) the language's value of `c-get-state-before-change-functions' may not\n  contain `c-parse-quotes-before-change';\n(iv) the language's value of `c-before-font-lock-functions' may not contain\n  `c-parse-quotes-after-change'."
  t
  #f)

;; c-single-quotes-quote-strings
(c-lang-defvar c-single-quotes-quote-strings (c-lang-const c-single-quotes-quote-strings))

;; c-string-delims
(c-lang-defconst c-string-delims
  t
  (if (%c-true (c-lang-const c-single-quotes-quote-strings)) '(#\" #\') '(#\")))

;; c-string-delims
(c-lang-defvar c-string-delims (c-lang-const c-string-delims))

;; c-ml-string-backslash-escapes
(c-lang-defconst c-ml-string-backslash-escapes
  "If non-nil, a \\ character escapes the next character in a ml string.\nOtherwise such a \\ will be marked to be handled as any other character."
  t
  #f
  pike
  #t)

;; c-ml-string-non-punc-skip-chars
(c-lang-defconst c-ml-string-non-punc-skip-chars
  t
  (if (%c-true (c-lang-const c-ml-string-backslash-escapes)) "^\"" "^\"\\"))

;; c-ml-string-non-punc-skip-chars
(c-lang-defvar c-ml-string-non-punc-skip-chars (c-lang-const c-ml-string-non-punc-skip-chars))

;; c-ml-string-opener-re
(c-lang-defconst c-ml-string-opener-re
  "If non-nil, a regexp that matches a multi-line string opener.\nIt may also match context.\n\nSuch an opener must be at least 2 characters long, and must\ncontain a \" character.  (match-string 1) matches the actual\ndelimiter and (match-string 2) matches the actual \".  If a\ndelimiter contains several \"s, it is recommended to configure\nthe first of them as \"the\" \"."
  t
  #f
  pike
  "\\(#\\(\"\\)\\)"
  c++
  "\\(R\\(\"\\)[^ ()\\\n\r\t]\\{0,16\\}(\\)")

;; c-ml-string-opener-re
(c-lang-defvar c-ml-string-opener-re (c-lang-const c-ml-string-opener-re))

;; c-ml-string-max-opener-len
(c-lang-defconst c-ml-string-max-opener-len
  "If non-nil, the maximum length of a multi-line string opener."
  t
  #f
  pike
  2
  c++
  19)

;; c-ml-string-max-opener-len
(c-lang-defvar c-ml-string-max-opener-len (c-lang-const c-ml-string-max-opener-len))

;; c-ml-string-any-closer-re
(c-lang-defconst c-ml-string-any-closer-re
  "If non-nil, a regexp that matches any multi-line string closer.\nIt may also match context.\n\nA search for this regexp starting at the end of the corresponding\nopener must find the first closer as the first match.\n\nSuch a closer must include a \" character.  (match-string 1)\nmatches the actual delimiter and (match-string 2) matches the\nactual \".  If a delimiter contains several \"s, it is\nrecommended to regard the last of them as \"the\" \"."
  t
  #f
  pike
  "\\(?:\\=\\|[^\\\"]\\)\\(?:\\\\.\\)*\\(\\(\"\\)\\)"
  c++
  "\\()[^ ()\\n\r\t]\\{0,16\\}\\(\"\\)\\)")

;; c-ml-string-any-closer-re
(c-lang-defvar c-ml-string-any-closer-re (c-lang-const c-ml-string-any-closer-re))

;; c-ml-string-max-closer-len
(c-lang-defconst c-ml-string-max-closer-len
  "If non-nil, the maximum length of a multi-line string closer.\nThis must include the length of any \"context trailer\" following\nthe actual closer and any \"context leader\" preceding it.  This\nvariable is ignored when `c-ml-string-back-closer-re' is non-nil."
  t
  #f
  c++
  18)

;; c-ml-string-max-closer-len
(c-lang-defvar c-ml-string-max-closer-len (c-lang-const c-ml-string-max-closer-len))

;; c-ml-string-max-closer-len-no-leader
(c-lang-defconst c-ml-string-max-closer-len-no-leader
  "If non-nil, the maximum length of a ml string closer without its leader.\nBy \"leader\" is meant the context bytes preceding the actual\nmulti-line string closer, that part of\n`c-ml-string-any-closer-re''s match preceding (match-beginning 1)."
  t
  #f
  pike
  1
  c++
  18)

;; c-ml-string-max-closer-len-no-leader
(c-lang-defvar c-ml-string-max-closer-len-no-leader (c-lang-const c-ml-string-max-closer-len-no-leader))

;; c-ml-string-back-closer-re
(c-lang-defconst c-ml-string-back-closer-re
  "A regexp to move back out of a putative ml closer point is in.\n\nThis variable need only be non-nil for languages with multi-line\nstring closers that can contain an indefinite length \"leader\"\npreceding the actual closer.  It was designed for formats where\nan unbounded number of \\s or \"s might precede the closer\nproper, for example in Pike Mode or csharp-mode.\n\nIf point is in a putative multi-line string closer, a backward\nregexp search with `c-ml-string-back-closer-re' will leave point\nin a \"safe place\", from where a forward regexp search with\n`c-ml-string-any-closer-re' can test whether the original\nposition was inside an actual closer.\n\nWhen non-nil, this variable should end in \"\\\\\\==\".  Note that\nsuch a backward search will match a minimal string, so a\n\"context character\" is probably needed at the start of the\nregexp.  The value for csharp-mode would be something like\n\"\\\\(?:\\\\`\\\\|[^\\\"]\\\\)\\\"*\\\\\\==\"."
  t
  #f
  pike
  "\\(?:\\`\\|[^\\\"]\\)\\(?:\\\\.\\)*\\=")

;; c-ml-string-back-closer-re
(c-lang-defvar c-ml-string-back-closer-re (c-lang-const c-ml-string-back-closer-re))

;; c-make-ml-string-closer-re-function
(c-lang-defconst c-make-ml-string-closer-re-function
  "If non-nil, a function which creates a closer regexp matching an opener.\n\nSuch a function is given one argument, a multi-line opener (a\nstring), and returns a regexp which will match the corresponding\ncloser.  When this regexp matches, (match-string 1) should be the\nactual closing delimiter, and (match-string 2) the \"active\" \"\nit contains.\n\nA forward regexp search for this regexp starting at the end of\nthe opener must find the closer as its first match."
  t
  (if (%c-true (c-lang-const c-ml-string-any-closer-re)) 'c-ml-string-make-closer-re #f)
  c++
  'c-c++-make-ml-string-closer-re)

;; c-make-ml-string-closer-re-function
(c-lang-defvar c-make-ml-string-closer-re-function (c-lang-const c-make-ml-string-closer-re-function))

;; c-make-ml-string-opener-re-function
(c-lang-defconst c-make-ml-string-opener-re-function
  "If non-nil, a function which creates an opener regexp matching a closer.\n\nSuch a function is given one argument, a multi-line closer (a\nstring), and returns a regexp which will match the corresponding\nopener.  When this regexp matches, (match-string 1) should be the\nactual opening delimiter, and (match-string 2) the \"active\" \"\nit contains.\n\nA backward regexp search for this regexp starting at the start of\nthe closer might not find the opener as its first match, should\nthere be copies of the opener contained in the multi-line string."
  t
  (if (%c-true (c-lang-const c-ml-string-opener-re)) 'c-ml-string-make-opener-re #f)
  c++
  'c-c++-make-ml-string-opener-re)

;; c-make-ml-string-opener-re-function
(c-lang-defvar c-make-ml-string-opener-re-function (c-lang-const c-make-ml-string-opener-re-function))

;; c-ml-string-cpp-or-opener-re
(c-lang-defconst c-ml-string-cpp-or-opener-re
  t
  (concat (or "\\(" "") (or (or (and (%c-true (c-lang-const c-anchored-cpp-prefix)) (c-lang-const c-anchored-cpp-prefix)) "\\`a\\`") "") (or "\\)\\|\\(" "") (or (or (and (%c-true (c-lang-const c-ml-string-opener-re)) (c-lang-const c-ml-string-opener-re)) "\\`a\\`") "") (or "\\)" "")))

;; c-ml-string-cpp-or-opener-re
(c-lang-defvar c-ml-string-cpp-or-opener-re (c-lang-const c-ml-string-cpp-or-opener-re))

;; c-cpp-or-ml-match-offset
(c-lang-defconst c-cpp-or-ml-match-offset
  t
  (if (%c-true (c-lang-const c-anchored-cpp-prefix)) (+ 2 (regexp-opt-depth (c-lang-const c-anchored-cpp-prefix))) 2))

;; c-cpp-or-ml-match-offset
(c-lang-defvar c-cpp-or-ml-match-offset (c-lang-const c-cpp-or-ml-match-offset))

;; c-has-quoted-numbers
(c-lang-defconst c-has-quoted-numbers
  "Whether the language has numbers quoted like 4'294'967'295."
  t
  #f
  (c c++)
  #t)

;; c-has-quoted-numbers
(c-lang-defvar c-has-quoted-numbers (c-lang-const c-has-quoted-numbers))

;; c-has-compound-literals
(c-lang-defconst c-has-compound-literals
  "Whether literal initializers {...} are used other than in initializations."
  t
  #f
  (c c++)
  #t)

;; c-has-compound-literals
(c-lang-defvar c-has-compound-literals (c-lang-const c-has-compound-literals))

;; c-modified-constant
(c-lang-defconst c-modified-constant
  "Regexp that matches a “modified” constant literal such as \"L\\='a\\='\",\na “long character”.  In particular, this recognizes forms of constant\nwhich `c-backward-sexp' needs to be called twice to move backwards over."
  t
  #f
  (c c++ objc)
  "L'\\([^\\'\t\f\n\r]\\|\\\\.\\)'")

;; c-modified-constant
(c-lang-defvar c-modified-constant (c-lang-const c-modified-constant))

;; c-symbol-start
(c-lang-defconst c-symbol-start
  "Regexp that matches the start of a symbol, i.e. any identifier or\nkeyword.  It's unspecified how far it matches.  Does not contain a \\|\noperator at the top level."
  t
  (concat (or "[" "") (or c-alpha "") (or "_]" ""))
  (c c++)
  (concat (or "[" "") (or c-alpha "") (or "_$]" ""))
  java
  (concat (or "[" "") (or c-alpha "") (or "_@]" ""))
  objc
  (concat (or "[" "") (or c-alpha "") (or "_@$]" ""))
  pike
  (concat (or "[" "") (or c-alpha "") (or "_`]" "")))

;; c-symbol-start
(c-lang-defvar c-symbol-start (c-lang-const c-symbol-start))

;; c-symbol-chars
(c-lang-defconst c-symbol-chars
  "Set of characters that can be part of a symbol.\nThis is of the form that fits inside [ ] in a regexp."
  t
  (concat (or c-alnum "") (or "_$" ""))
  objc
  (concat (or c-alnum "") (or "_$@" "")))

;; c-symbol-chars
(c-lang-defvar c-symbol-chars (c-lang-const c-symbol-chars))

;; c-dollar-in-ids
(c-lang-defconst c-dollar-in-ids
  "Non-nil when a dollar (can be) a non-standard constituent of an identifier."
  t
  (string-match (c-lang-const c-symbol-start) "$"))

;; c-symbol-char-key
(c-lang-defconst c-symbol-char-key
  "Regexp matching a sequence of at least one identifier character."
  t
  (concat (or "[" "") (or (c-lang-const c-symbol-chars) "") (or "]+" "")))

;; c-symbol-char-key
(c-lang-defvar c-symbol-char-key (c-lang-const c-symbol-char-key))

;; c-symbol-key
(c-lang-defconst c-symbol-key
  "Regexp matching identifiers and keywords (with submatch 0).  Assumed\nto match if `c-symbol-start' matches on the same position."
  t
  (concat (or (c-lang-const c-symbol-start) "") (or "[" "") (or (c-lang-const c-symbol-chars) "") (or "]\\{,1000\\}" ""))
  pike
  (concat (or (c-lang-const c-symbol-key awk) "") (or "\\|" "") (or (c-make-keywords-re #f (or (c-lang-const c-overloadable-operators) '())) "")))

;; c-symbol-key
(c-lang-defvar c-symbol-key (c-lang-const c-symbol-key))

;; c-symbol-key-depth
(c-lang-defconst c-symbol-key-depth
  t
  (regexp-opt-depth (c-lang-const c-symbol-key)))

;; c-nonsymbol-chars
(c-lang-defconst c-nonsymbol-chars
  "This is the set of chars that can't be part of a symbol, i.e. the\nnegation of `c-symbol-chars'."
  t
  (concat (or "^" "") (or (c-lang-const c-symbol-chars) "")))

;; c-nonsymbol-chars
(c-lang-defvar c-nonsymbol-chars (c-lang-const c-nonsymbol-chars))

;; c-nonsymbol-key
(c-lang-defconst c-nonsymbol-key
  "Regexp that matches any character that can't be part of a symbol.\nIt's usually appended to other regexps to avoid matching a prefix.\nIt's assumed to not contain any submatchers."
  t
  (concat (or "[" "") (or (c-lang-const c-nonsymbol-chars) "") (or "]" "")))

;; c-nonsymbol-key
(c-lang-defvar c-nonsymbol-key (c-lang-const c-nonsymbol-key))

;; c-identifier-ops
(c-lang-defconst c-identifier-ops
  "The operators that make up fully qualified identifiers.  nil in\nlanguages that don't have such things.  See `c-operators' for a\ndescription of the format.  Binary operators can concatenate symbols,\ne.g. \"::\" in \"A::B::C\".  Prefix operators can precede identifiers,\ne.g. \"~\" in \"~A::B\".  Other types of operators aren't supported.\n\nThis value is by default merged into `c-operators'."
  t
  #f
  c++
  '((prefix "~" "??-" "compl") (right-assoc "::") (prefix "::"))
  java
  '((left-assoc "."))
  idl
  '((left-assoc "::") (prefix "::"))
  pike
  '((left-assoc "::") (prefix "::") (left-assoc ".")))

;; c-opt-identifier-concat-key
(c-lang-defconst c-opt-identifier-concat-key
  t
  (let ((ops (c-filter-ops (or (c-lang-const c-identifier-ops) '()) '(left-assoc right-assoc) #t))) (if (%c-true ops) (begin (c-make-keywords-re #t (or ops '()))) #f)))

;; c-opt-identifier-concat-key
(c-lang-defvar c-opt-identifier-concat-key (c-lang-const c-opt-identifier-concat-key))

;; c-opt-identifier-concat-key-depth
(c-lang-defconst c-opt-identifier-concat-key-depth
  t
  (regexp-opt-depth (c-lang-const c-opt-identifier-concat-key)))

;; c-opt-identifier-prefix-key
(c-lang-defconst c-opt-identifier-prefix-key
  t
  (let ((ops (c-filter-ops (or (c-lang-const c-identifier-ops) '()) '(prefix) #t))) (if (%c-true ops) (begin (c-make-keywords-re #t (or ops '()))) #f)))

;; c-opt-identifier-prefix-key
(c-lang-defvar c-opt-identifier-prefix-key (c-lang-const c-opt-identifier-prefix-key))

;; c-after-id-concat-ops
(c-lang-defconst c-after-id-concat-ops
  "Operators that can occur after a binary operator on `c-identifier-ops'\nin identifiers.  nil in languages that don't have such things.\n\nOperators here should also have appropriate entries in `c-operators' -\nit's not taken care of by default."
  t
  #f
  c++
  '("~" "*")
  java
  '("*"))

;; c-opt-after-id-concat-key
(c-lang-defconst c-opt-after-id-concat-key
  t
  (concat (or (c-lang-const c-symbol-start) "") (or (if (%c-true (c-lang-const c-after-id-concat-ops)) (concat (or "\\|" "") (or (c-make-keywords-re #t (or (c-lang-const c-after-id-concat-ops) '())) "")) "") "")))

;; c-identifier-start
(c-lang-defconst c-identifier-start
  "Regexp that matches the start of an (optionally qualified) identifier.\nIt should also match all keywords.  It's unspecified how far it\nmatches."
  t
  (concat (or (c-lang-const c-symbol-start) "") (or (if (%c-true (c-lang-const c-opt-identifier-prefix-key)) (concat (or "\\|" "") (or (c-lang-const c-opt-identifier-prefix-key) "")) "") "")))

;; c-identifier-start
(c-lang-defvar c-identifier-start (c-lang-const c-identifier-start))

;; c-identifier-key
(c-lang-defconst c-identifier-key
  "Regexp matching a fully qualified identifier, like \"A::B::c\" in\nC++.  It does not recognize the full range of syntactic whitespace\nbetween the tokens; `c-forward-name' has to be used for that.  It\nshould also not match identifiers containing parenthesis groupings,\ne.g. identifiers with template arguments such as \"A<X,Y>\" in C++."
  t
  (concat (or (if (%c-true (c-lang-const c-opt-identifier-prefix-key)) (concat (or "\\(" "") (or (c-lang-const c-opt-identifier-prefix-key) "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "\\)?" "")) "") "") (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" "") (or (if (%c-true (c-lang-const c-opt-identifier-concat-key)) (concat (or "\\(" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or (c-lang-const c-opt-identifier-concat-key) "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or (if (%c-true (c-lang-const c-after-id-concat-ops)) (concat (or "\\(" "") (or (c-make-keywords-re #t (or (c-lang-const c-after-id-concat-ops) '())) "") (or (concat (or "\\(" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" "") (or "\\)?" "")) "") (or "\\|" "") (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" "") (or "\\)" "")) (concat (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" ""))) "") (or "\\)*" "")) "") "")))

;; c-identifier-key
(c-lang-defvar c-identifier-key (c-lang-const c-identifier-key))

;; c-annotation-re
(c-lang-defconst c-annotation-re
  "Regexp that matches the first token of an annotation or nil.\nCurrently only used in Java Mode."
  t
  #f
  java
  "\\_<@[[:alnum:]]+\\_>")

;; c-annotation-re
(c-lang-defvar c-annotation-re (c-lang-const c-annotation-re))

;; c-module-name-re
(c-lang-defconst c-module-name-re
  "This regexp matches (a component of) a module name.\nCurrently (2022-09) just C++ Mode uses this."
  t
  #f
  c++
  (concat (or (c-lang-const c-symbol-key) "") (or "\\(?:\\." "") (or (c-lang-const c-symbol-key) "") (or "\\)*" "")))

;; c-module-name-re
(c-lang-defvar c-module-name-re (c-lang-const c-module-name-re))

;; c-identifier-last-sym-match
(c-lang-defconst c-identifier-last-sym-match
  t
  #f)

;; c-multiline-string-start-char
(c-lang-defconst c-multiline-string-start-char
  "Set if the language supports multiline string literals without escaped\nnewlines.  If t, all string literals are multiline.  If a character,\nonly literals where the open quote is immediately preceded by that\nliteral are multiline.\n\nNote that from CC Mode 5.36, this character use is obsolete,\nhaving been superseded by the \"multi-line string\" mechanism.\nIf both mechanisms are set for a language, the newer one prevails\nover the old `c-multiline-string-start-char'.  See the variables\nin the page containing `c-ml-string-opener-re' in cc-langs.el for\nfurther directions."
  t
  #f)

;; c-multiline-string-start-char
(c-lang-defvar c-multiline-string-start-char (c-lang-const c-multiline-string-start-char))

;; c-escaped-newline-takes-precedence
(c-lang-defconst c-escaped-newline-takes-precedence
  "Set if the language resolves escaped newlines first.\nThis makes a difference in a string like \"...\\\\\n\".  When\nthis variable is nil, the first backslash escapes the second,\nleaving an unterminated string.  When it's non-nil, the string is\ncontinued onto the next line, and the first backslash escapes\nwhatever begins that next line."
  t
  #f
  (c c++ objc pike)
  #t)

;; c-escaped-newline-takes-precedence
(c-lang-defvar c-escaped-newline-takes-precedence (c-lang-const c-escaped-newline-takes-precedence))

;; c-string-innards-re-alist
(c-lang-defconst c-string-innards-re-alist
  t
  (mapcar (lambda (delim) (cons delim (or (concat (or (if (%c-true (c-lang-const c-escaped-newline-takes-precedence)) "\\(\\\\\\(\\\\?\n\\|.\\)\\|[^\\\n\r" "\\(\\\\\\(\n\\|.\\)\\|[^\\\n\r") "") (or (%string delim) "") (or "]\\)*" "")) '()))) (if (%c-true (or (and (%c-true (%c-false (c-lang-const c-multiline-string-start-char))) (%c-false (c-lang-const c-multiline-string-start-char))) (c-characterp (c-lang-const c-multiline-string-start-char)))) (if (%c-true (c-lang-const c-single-quotes-quote-strings)) '(#\" #\') '(#\")) #f)))

;; c-string-innards-re-alist
(c-lang-defvar c-string-innards-re-alist (c-lang-const c-string-innards-re-alist))

;; c-opt-cpp-symbol
(c-lang-defconst c-opt-cpp-symbol
  "The symbol which starts preprocessor constructs when in the margin."
  t
  "#"
  (java awk)
  #f)

;; c-opt-cpp-symbol
(c-lang-defvar c-opt-cpp-symbol (c-lang-const c-opt-cpp-symbol))

;; c-opt-cpp-prefix
(c-lang-defconst c-opt-cpp-prefix
  "Regexp matching the prefix of a cpp directive in the languages that\nnormally use that macro preprocessor.  Tested at bol or at boi.\nAssumed to not contain any submatches or \\| operators."
  t
  "\\s *#\\s *"
  (java awk)
  #f)

;; c-opt-cpp-prefix
(c-lang-defvar c-opt-cpp-prefix (c-lang-const c-opt-cpp-prefix))

;; c-anchored-cpp-prefix
(c-lang-defconst c-anchored-cpp-prefix
  "Regexp matching the prefix of a cpp directive anchored to BOL,\nin the languages that have a macro preprocessor."
  t
  "^\\s *\\(#\\)\\s *"
  (java awk)
  #f)

;; c-anchored-cpp-prefix
(c-lang-defvar c-anchored-cpp-prefix (c-lang-const c-anchored-cpp-prefix))

;; c-opt-cpp-start
(c-lang-defconst c-opt-cpp-start
  "Regexp matching the prefix of a cpp directive including the directive\nname, or nil in languages without preprocessor support.  The first\nsubmatch surrounds the directive name."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) (concat (or (c-lang-const c-opt-cpp-prefix) "") (or "\\([" "") (or c-alnum "") (or "]+\\)" "")) #f)
  pike
  (concat (or (c-lang-const c-opt-cpp-prefix) "") (or "\\([" "") (or c-alnum "") (or "]+\\|!\\)" "")))

;; c-opt-cpp-start
(c-lang-defvar c-opt-cpp-start (c-lang-const c-opt-cpp-start))

;; c-cpp-message-directives
(c-lang-defconst c-cpp-message-directives
  "List of cpp directives (without the prefix) that are followed by a\nstring message."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) '("error") #f)
  (c c++ objc pike)
  '("error" "warning"))

;; c-cpp-message-directives-re
(c-lang-defconst c-cpp-message-directives-re
  t
  (c-make-keywords-re #t (or (c-lang-const c-cpp-message-directives) '())))

;; noncontinued-line-end
(c-lang-defconst noncontinued-line-end
  t
  "\\(\\=\\|\\(\\=\\|[^\\]\\)[\n\r]\\)")

;; ncle-depth
(c-lang-defconst ncle-depth
  t
  (regexp-opt-depth (c-lang-const noncontinued-line-end)))

;; c-cpp-messages-re
(c-lang-defconst c-cpp-messages-re
  t
  (if (%c-true (c-lang-const c-cpp-message-directives)) (concat (or (c-lang-const noncontinued-line-end) "") (or (c-lang-const c-opt-cpp-prefix) "") (or (c-lang-const c-cpp-message-directives-re) "") (or "\\s +\\(\\(\\\\\\(\\\\?\n\\|.\\)\\|[^\n]\\)*\\)$" "")) #f))

;; c-cpp-messages-re
(c-lang-defvar c-cpp-messages-re (c-lang-const c-cpp-messages-re))

;; c-cpp-message-match-no
(c-lang-defconst c-cpp-message-match-no
  t
  (if (%c-true (c-lang-const c-cpp-messages-re)) (+ 1 (c-lang-const ncle-depth) (regexp-opt-depth (c-lang-const c-cpp-message-directives-re))) #f))

;; c-cpp-message-match-no
(c-lang-defvar c-cpp-message-match-no (c-lang-const c-cpp-message-match-no))

;; c-cpp-include-directives
(c-lang-defconst c-cpp-include-directives
  "List of cpp directives (without the prefix) that are followed by a\nfile name in angle brackets or quotes."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) '("include") #f)
  c
  '("include" "embed")
  objc
  '("include" "import"))

;; c-cpp-include-key
(c-lang-defconst c-cpp-include-key
  t
  (if (%c-true (if (%c-true (c-lang-const c-anchored-cpp-prefix)) (c-lang-const c-cpp-include-directives) #f)) (concat (or (c-lang-const c-anchored-cpp-prefix) "") (or (c-make-keywords-re #t (or (c-lang-const c-cpp-include-directives) '())) "") (or "[ \t]*" "")) regexp-unmatchable))

;; c-cpp-include-key
(c-lang-defvar c-cpp-include-key (c-lang-const c-cpp-include-key))

;; c-opt-cpp-macro-define
(c-lang-defconst c-opt-cpp-macro-define
  "Cpp directive (without the prefix) that is followed by a macro\ndefinition, or nil if the language doesn't have any."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) "define" #f))

;; c-opt-cpp-macro-define
(c-lang-defvar c-opt-cpp-macro-define (c-lang-const c-opt-cpp-macro-define))

;; c-opt-cpp-macro-define-start
(c-lang-defconst c-opt-cpp-macro-define-start
  t
  (if (%c-true (c-lang-const c-opt-cpp-macro-define)) (concat (or (c-lang-const c-opt-cpp-prefix) "") (or (c-lang-const c-opt-cpp-macro-define) "") (or "[ \t]+\\(\\(\\sw\\|_\\)+\\)\\(([^)]*)\\)?" "") (or "\\([ \t]\\|\\\\\n\\)*" "")) #f))

;; c-opt-cpp-macro-define-start
(c-lang-defvar c-opt-cpp-macro-define-start (c-lang-const c-opt-cpp-macro-define-start))

;; c-opt-cpp-macro-define-id
(c-lang-defconst c-opt-cpp-macro-define-id
  t
  (if (%c-true (c-lang-const c-opt-cpp-macro-define)) (concat (or (c-lang-const c-opt-cpp-prefix) "") (or (c-lang-const c-opt-cpp-macro-define) "") (or "[ \t]+\\(\\sw\\|_\\)+" "")) #f))

;; c-opt-cpp-macro-define-id
(c-lang-defvar c-opt-cpp-macro-define-id (c-lang-const c-opt-cpp-macro-define-id))

;; c-anchored-hash-define-no-parens
(c-lang-defconst c-anchored-hash-define-no-parens
  t
  (if (%c-true (c-lang-const c-opt-cpp-macro-define)) (concat (or (c-lang-const c-anchored-cpp-prefix) "") (or (c-lang-const c-opt-cpp-macro-define) "") (or "[ \t]+[a-zA-Z0-9_]+\\([^(a-zA-Z0-9_]\\|$\\)" "")) #f))

;; c-cpp-expr-directives
(c-lang-defconst c-cpp-expr-directives
  "List of cpp directives (without the prefix) that are followed by an\nexpression."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) '("if" "elif" "elifdef" "elifndef") #f))

;; c-cpp-expr-intro-re
(c-lang-defconst c-cpp-expr-intro-re
  "Regexp which matches the start of a CPP directive which contains an\nexpression, or nil if there aren't any in the language."
  t
  (if (%c-true (c-lang-const c-cpp-expr-directives)) (concat (or (c-lang-const c-opt-cpp-prefix) "") (or (c-make-keywords-re #t (or (c-lang-const c-cpp-expr-directives) '())) "")) #f))

;; c-cpp-expr-intro-re
(c-lang-defvar c-cpp-expr-intro-re (c-lang-const c-cpp-expr-intro-re))

;; c-cpp-expr-functions
(c-lang-defconst c-cpp-expr-functions
  "List of functions in cpp expressions."
  t
  (if (%c-true (c-lang-const c-opt-cpp-prefix)) '("defined") #f)
  pike
  '("defined" "efun" "constant"))

;; c-cpp-expr-functions-key
(c-lang-defconst c-cpp-expr-functions-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-cpp-expr-functions) '())))

;; c-cpp-expr-functions-key
(c-lang-defvar c-cpp-expr-functions-key (c-lang-const c-cpp-expr-functions-key))

;; c-assignment-operators
(c-lang-defconst c-assignment-operators
  "List of all assignment operators."
  t
  '("=" "*=" "/=" "%=" "+=" "-=" ">>=" "<<=" "&=" "^=" "|=")
  java
  (append (or (c-lang-const c-assignment-operators) '()) '(">>>="))
  c++
  (append (or (c-lang-const c-assignment-operators) '()) '("and_eq" "or_eq" "xor_eq" "??!=" "??'="))
  idl
  #f)

;; c-operators
(c-lang-defconst c-operators
  "List describing all operators, along with their precedence and\nassociativity.  The order in the list corresponds to the precedence of\nthe operators: The operators in each element are a group with the same\nprecedence, and the group has higher precedence than the groups in all\nfollowing elements.  The car of each element describes the type of the\noperator group, and the cdr is a list of the operator tokens in it.\nThe operator group types are:\n\n`prefix'        Unary prefix operators.\n`postfix'       Unary postfix operators.\n`postfix-if-paren'\n\t\tUnary postfix operators if and only if the chars have\n\t\tparenthesis syntax.\n`left-assoc'    Binary left associative operators (i.e. a+b+c means (a+b)+c).\n`right-assoc'   Binary right associative operators (i.e. a=b=c means a=(b=c)).\n`right-assoc-sequence'\n                Right associative operator that constitutes of a\n                sequence of tokens that separate expressions.  All the\n                tokens in the group are in this case taken as\n                describing the sequence in one such operator, and the\n                order between them is therefore significant.\n\nOperators containing a character with paren syntax are taken to match\nwith a corresponding open/close paren somewhere else.  A postfix\noperator with close paren syntax is taken to end a postfix expression\nstarted somewhere earlier, rather than start a new one at point.  Vice\nversa for prefix operators with open paren syntax.\n\nNote that operators like \".\" and \"->\" which in language references\noften are described as postfix operators are considered binary here,\nsince CC Mode treats every identifier as an expression."
  t
  `(,@(or (if (%c-true (c-lang-const c-opt-cpp-prefix)) (begin `((prefix "#" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("%:" "??=")) #f) '())) (left-assoc "##" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("%:%:" "??=??=")) #f) '())))) #f) '()) ,@(or (c-lang-const c-identifier-ops) '()) ,@(or (cond ((%c-true (or (and (%c-true (c-major-mode-is 'c++-mode)) (c-major-mode-is 'c++-mode)) (c-major-mode-is 'java-mode))) '((postfix-if-paren "<" ">"))) ((%c-true (c-major-mode-is 'pike-mode)) '((prefix "global" "predef"))) ((%c-true (c-major-mode-is 'java-mode)) '((prefix "super"))) (else #f)) '()) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '((prefix "dynamic_cast" "static_cast" "reinterpret_cast" "const_cast" "typeid" "alignof"))) #f) '()) (left-assoc "." ,@(or (if (%c-true (c-major-mode-is 'java-mode)) #f (begin '("->"))) '())) (postfix "++" "--" "[" "]" "(" ")" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("<:" ":>" "??(" "??)")) #f) '())) (prefix "++" "--" "+" "-" "!" "~" ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("not" "compl")) #f) '()) ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("*" "&" "sizeof" "??-")) #f) '()) ,@(or (if (%c-true (c-major-mode-is 'objc-mode)) (begin '("@selector" "@protocol" "@encode")) #f) '()) ,@(or (cond ((%c-true (c-major-mode-is 'c++-mode)) '("new" "delete")) ((%c-true (c-major-mode-is 'java-mode)) '("new")) ((%c-true (c-major-mode-is 'pike-mode)) '("class" "lambda" "catch" "throw" "gauge")) (else #f)) '()) "(" ")" ,@(or (if (%c-true (c-major-mode-is 'pike-mode)) (begin '("[" "]")) #f) '())) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '((left-assoc ".*" "->*"))) #f) '()) (left-assoc "*" "/" "%") (left-assoc "+" "-") (left-assoc "<<" ">>" ,@(or (if (%c-true (c-major-mode-is 'java-mode)) (begin '(">>>")) #f) '())) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin `((left-assoc "<=>"))) #f) '()) (left-assoc "<" ">" "<=" ">=" ,@(or (if (%c-true (c-major-mode-is 'java-mode)) (begin '("instanceof")) #f) '())) (left-assoc "==" "!=" ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("not_eq")) #f) '())) (left-assoc "&" ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("bitand")) #f) '())) (left-assoc "^" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("??'")) #f) '()) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("xor")) #f) '())) (left-assoc "|" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("??!")) #f) '()) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("bitor")) #f) '())) (left-assoc "&&" ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("and")) #f) '())) (left-assoc "||" ,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("??!??!")) #f) '()) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("or")) #f) '())) (right-assoc-sequence "?" ":") (right-assoc ,@(or (c-lang-const c-assignment-operators) '())) ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '((prefix "throw" "co_await" "co_yield"))) #f) '()) (left-assoc ","))
  idl
  `((prefix "#") (left-assoc "##") ,@(or (c-lang-const c-identifier-ops) '()) (prefix "+" "-" "~") (left-assoc "*" "/" "%") (left-assoc "+" "-") (left-assoc "<<" ">>") (left-assoc "&") (left-assoc "^") (left-assoc "|")))

;; c-operator-list
(c-lang-defconst c-operator-list
  t
  (c-filter-ops (or (c-lang-const c-operators) '()) #t #t))

;; c-operator-re
(c-lang-defconst c-operator-re
  t
  (regexp-opt (or (c-lang-const c-operator-list) '())))

;; c-operator-re
(c-lang-defvar c-operator-re (c-lang-const c-operator-re))

;; c-bin-tern-operators
(c-lang-defconst c-bin-tern-operators
  t
  (c-filter-ops (or (c-lang-const c-operators) '()) '(left-assoc right-assoc right-assoc-sequence) #t))

;; c-unary-operators
(c-lang-defconst c-unary-operators
  t
  (c-filter-ops (or (c-lang-const c-operators) '()) '(prefix postfix postfix-if-paren) #t))

;; c-non-after-{}-operators
(c-lang-defconst #{c-non-after-{}-operators}#
  "Operators which can't appear after a block {..} construct."
  t
  (c--set-difference (or (c-lang-const c-bin-tern-operators) '()) (or (c-lang-const c-unary-operators) '()) ':test string-equal)
  awk
  (remove "/" (c-lang-const #{c-non-after-{}-operators}#)))

;; c-non-after-{}-ops-re
(c-lang-defconst #{c-non-after-{}-ops-re}#
  t
  (regexp-opt (or (c-lang-const #{c-non-after-{}-operators}#) '())))

;; c-non-after-{}-ops-re
(c-lang-defvar #{c-non-after-{}-ops-re}# (c-lang-const #{c-non-after-{}-ops-re}#))

;; c-overloadable-operators
(c-lang-defconst c-overloadable-operators
  "List of the operators that are overloadable, in their \"identifier\nform\".  See also `c-opt-op-identifier-prefix'."
  t
  #f
  c++
  '("new" "delete" "+" "-" "*" "/" "%" "^" "??'" "xor" "&" "bitand" "|" "??!" "bitor" "~" "??-" "compl" "!" "=" "<" ">" "+=" "-=" "*=" "/=" "%=" "^=" "??'=" "xor_eq" "&=" "and_eq" "|=" "??!=" "or_eq" "<<" ">>" ">>=" "<<=" "==" "!=" "not_eq" "<=>" "<=" ">=" "&&" "and" "||" "??!??!" "or" "++" "--" "," "->*" "->" "()" "[]" "\"\"" "<::>" "??(??)")
  pike
  '("`+" "`-" "`&" "`|" "`^" "`<<" "`>>" "`*" "`/" "`%" "`~" "`==" "`<" "`>" "`!" "`[]" "`[]=" "`->" "`->=" "`()" "``+" "``-" "``&" "``|" "``^" "``<<" "``>>" "``*" "``/" "``%" "`+="))

;; c-overloadable-operators-regexp
(c-lang-defconst c-overloadable-operators-regexp
  t
  #f
  c++
  (c-make-keywords-re #f (or (c-lang-const c-overloadable-operators) '())))

;; c-overloadable-operators-regexp
(c-lang-defvar c-overloadable-operators-regexp (c-lang-const c-overloadable-operators-regexp))

;; c-opt-op-identifier-prefix
(c-lang-defconst c-opt-op-identifier-prefix
  "Regexp matching the token before the ones in\n`c-overloadable-operators' when operators are specified in their\n\"identifier form\".  This typically matches \"operator\" in C++ where\noperator functions are specified as e.g. \"operator +\".  It's nil in\nlanguages without operator functions or where the complete operator\nidentifier is listed in `c-overloadable-operators'.\n\nThis regexp is assumed to not match any non-operator identifier."
  t
  #f
  c++
  (c-make-keywords-re #t '("operator")))

;; c-opt-op-identifier-prefix
(c-lang-defvar c-opt-op-identifier-prefix (c-lang-const c-opt-op-identifier-prefix))

;; c-ambiguous-overloadable-or-identifier-prefixes
(c-lang-defconst c-ambiguous-overloadable-or-identifier-prefixes
  t
  (c--intersection (or (c-filter-ops (or (c-lang-const c-identifier-ops) '()) '(prefix) #t) '()) (or (c-lang-const c-overloadable-operators) '()) ':test string-equal))

;; c-ambiguous-overloadable-or-identifier-prefix-re
(c-lang-defconst c-ambiguous-overloadable-or-identifier-prefix-re
  t
  (c-make-keywords-re #t (or (c-lang-const c-ambiguous-overloadable-or-identifier-prefixes) '())))

;; c-ambiguous-overloadable-or-identifier-prefix-re
(c-lang-defvar c-ambiguous-overloadable-or-identifier-prefix-re (c-lang-const c-ambiguous-overloadable-or-identifier-prefix-re))

;; c-other-op-syntax-tokens
(c-lang-defconst c-other-op-syntax-tokens
  "List of the tokens made up of characters in the punctuation or\nparenthesis syntax classes that have uses other than as expression\noperators."
  t
  '("{" "}" "(" ")" "[" "]" ";" ":" "," "=" "/*" "*/" "//")
  (c c++ pike)
  (append '("#" "##" "::" "...") (or (c-lang-const c-other-op-syntax-tokens) '()))
  (c c++)
  (append '("*") (or (c-lang-const c-other-op-syntax-tokens) '()))
  c++
  (append '("&" "<%" "%>" "<:" ":>" "%:" "%:%:") (or (c-lang-const c-other-op-syntax-tokens) '()))
  objc
  (append '("#" "##" "+" "-") (or (c-lang-const c-other-op-syntax-tokens) '()))
  idl
  (append '("#" "##") (or (c-lang-const c-other-op-syntax-tokens) '()))
  pike
  (append '("..") (or (c-lang-const c-other-op-syntax-tokens) '()) (or (c-lang-const c-overloadable-operators) '()))
  awk
  '("{" "}" "(" ")" "[" "]" ";" "," "=" "/"))

;; c-all-op-syntax-tokens
(c-lang-defconst c-all-op-syntax-tokens
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-other-op-syntax-tokens) '()) (or (c-lang-const c-operator-list) '())) '()) ':test string-equal))

(c-lang-defconst c-nonsymbol-token-char-list
  ;; "List containing all chars not in the word, symbol or syntactically
  ;; irrelevant syntax classes, i.e. all punctuation, parenthesis and
  ;; string delimiter chars."
  ;;
  ;; Emacs's `char' is an integer, so `char-syntax' takes it directly and
  ;; `c-int-to-char' wraps it for the list; here the character functions
  ;; take characters, so the conversion moves to those calls.
  t
  (c-with-syntax-table
      (c-lang-const c-mode-syntax-table)
      (lambda ()
        ;; "Only go through the chars in the printable ASCII range."
        (let ((list '()) (char 32))
          (let loop ()
            (if (< char 127)
                (begin
                  ;; Emacs's `'(?w ?_ ?< ?> ?\ )' is a *literal* here
                  ;; too: `list' is a bound variable in this `let' and a
                  ;; Lisp-1 would call it (the tree's oldest trap).
                  (or (memv (char-syntax (c-int-to-char char))
                            '(#\w #\_ #\< #\> #\space))
                      (set! list (cons (c-int-to-char char) list)))
                  (set! char (+ char 1))
                  (loop))
                #f))
          list))))
(c-lang-defvar c-nonsymbol-token-char-list
  (c-lang-const c-nonsymbol-token-char-list))

;; c-nonsymbol-token-regexp
(c-lang-defconst c-nonsymbol-token-regexp
  t
  (c-make-keywords-re #f (or (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`\\(\\s.\\)+\\'") '())))

;; c-nonsymbol-token-regexp
(c-lang-defvar c-nonsymbol-token-regexp (c-lang-const c-nonsymbol-token-regexp))

;; c-assignment-op-regexp
(c-lang-defconst c-assignment-op-regexp
  t
  (if (%c-true (c-lang-const c-assignment-operators)) (concat (or "=\\([^=]\\|$\\)" "") (or "\\|" "") (or (c-make-keywords-re #f (or (c--set-difference (or (c-lang-const c-assignment-operators) '()) '("=") ':test string-equal) '())) "")) regexp-unmatchable))

;; c-assignment-op-regexp
(c-lang-defvar c-assignment-op-regexp (c-lang-const c-assignment-op-regexp))

;; c-negation-op-re
(c-lang-defconst c-negation-op-re
  t
  "!\\([^=]\\|$\\)")

;; c-negation-op-re
(c-lang-defvar c-negation-op-re (c-lang-const c-negation-op-re))

;; c-arithmetic-operators
(c-lang-defconst c-arithmetic-operators
  "List of all arithmetic operators, including \"+=\", etc."
  t
  (append (or (c-lang-const c-assignment-operators) '()) (or `("+" "-" "*" "/" "%" "<<" ">>" ,@(or (if (%c-true (c-major-mode-is 'c++-mode)) '("<=>") #f) '()) "<" ">" "<=" ">=" "==" "!=" "&" "^" "|" "&&" "||") '())))

;; c-arithmetic-op-regexp
(c-lang-defconst c-arithmetic-op-regexp
  t
  (c-make-keywords-re #f (or (c-lang-const c-arithmetic-operators) '())))

;; c-arithmetic-op-regexp
(c-lang-defvar c-arithmetic-op-regexp (c-lang-const c-arithmetic-op-regexp))

;; c-:$-multichar-token-regexp
(c-lang-defconst c-:$-multichar-token-regexp
  t
  (c-make-keywords-re #f (or (c-filter-ops (or (c-lang-const c-operators) '()) #t ".+:$") '())))

;; c-:$-multichar-token-regexp
(c-lang-defvar c-:$-multichar-token-regexp (c-lang-const c-:$-multichar-token-regexp))

;; c-<>-multichar-token-regexp
(c-lang-defconst c-<>-multichar-token-regexp
  t
  (c-make-keywords-re #f (or (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t ".[<>]\\|[<>].") '())))

;; c-<>-multichar-token-regexp
(c-lang-defvar c-<>-multichar-token-regexp (c-lang-const c-<>-multichar-token-regexp))

;; c-<-op-cont-regexp
(c-lang-defconst c-<-op-cont-regexp
  t
  (c-make-keywords-re #f (or (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`<." (lambda (op) (%substring op 1))) '())))

;; c-<-op-cont-regexp
(c-lang-defvar c-<-op-cont-regexp (c-lang-const c-<-op-cont-regexp))

;; c-<-pseudo-digraph-cont-regexp
(c-lang-defconst c-<-pseudo-digraph-cont-regexp
  "Regexp matching the continuation of a pseudo digraph starting \"<\".\nThis is used only in C++ Mode, where \"<::\" is handled as a\ntemplate opener followed by the \"::\" operator - usually."
  t
  regexp-unmatchable
  c++
  "::\\([^:>]\\|$\\)")

;; c-<-pseudo-digraph-cont-regexp
(c-lang-defvar c-<-pseudo-digraph-cont-regexp (c-lang-const c-<-pseudo-digraph-cont-regexp))

;; c-<-pseudo-digraph-cont-len
(c-lang-defconst c-<-pseudo-digraph-cont-len
  "The maximum length of the main bit of a `c-<-pseudo-digraph-cont-regexp' match.\nThis doesn't count the merely contextual bits of the regexp match."
  t
  0
  c++
  2)

;; c-<-pseudo-digraph-cont-len
(c-lang-defvar c-<-pseudo-digraph-cont-len (c-lang-const c-<-pseudo-digraph-cont-len))

;; c->-op-cont-tokens
(c-lang-defconst c->-op-cont-tokens
  t
  (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`>." (lambda (op) (%substring op 1)))
  java
  (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`>[^>]\\|\\`>>[^>]" (lambda (op) (%substring op 1))))

;; c->-op-cont-regexp
(c-lang-defconst c->-op-cont-regexp
  t
  (c-make-keywords-re #f (or (c-lang-const c->-op-cont-tokens) '())))

;; c->-op-cont-regexp
(c-lang-defvar c->-op-cont-regexp (c-lang-const c->-op-cont-regexp))

;; c->-op-without->-cont-regexp
(c-lang-defconst c->-op-without->-cont-regexp
  t
  (c-make-keywords-re #f (or (c--set-difference (or (c-lang-const c->-op-cont-tokens) '()) (or (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`>>" (lambda (op) (%substring op 1))) '()) ':test string-equal) '())))

;; c->-op-without->-cont-regexp
(c-lang-defvar c->-op-without->-cont-regexp (c-lang-const c->-op-without->-cont-regexp))

;; c-multichar->-op-not->>->>>-regexp
(c-lang-defconst c-multichar->-op-not->>->>>-regexp
  t
  (c-make-keywords-re #f (or (c--set-difference (or (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\(.>\\|>.\\)") '()) '(">>" ">>>") ':test string-equal) '())))

;; c-multichar->-op-not->>->>>-regexp
(c-lang-defvar c-multichar->-op-not->>->>>-regexp (c-lang-const c-multichar->-op-not->>->>>-regexp))

;; c-:-op-cont-tokens
(c-lang-defconst c-:-op-cont-tokens
  t
  (c-filter-ops (or (c-lang-const c-all-op-syntax-tokens) '()) #t "\\`:." (lambda (op) (%substring op 1))))

;; c-:-op-cont-regexp
(c-lang-defconst c-:-op-cont-regexp
  t
  (c-make-keywords-re #f (or (c-lang-const c-:-op-cont-tokens) '())))

;; c-:-op-cont-regexp
(c-lang-defvar c-:-op-cont-regexp (c-lang-const c-:-op-cont-regexp))

;; c-stmt-delim-chars
(c-lang-defconst c-stmt-delim-chars
  t
  "^;{}?:")

;; c-stmt-delim-chars
(c-lang-defvar c-stmt-delim-chars (c-lang-const c-stmt-delim-chars))

;; c-stmt-boundary-skip-chars
(c-lang-defconst c-stmt-boundary-skip-chars
  t
  (if (%c-true (c-lang-const c-opt-cpp-symbol)) (concat (or (%substring (c-lang-const c-stmt-delim-chars) 0 1) "") (or (c-lang-const c-opt-cpp-symbol) "") (or (%substring (c-lang-const c-stmt-delim-chars) 1) "")) (c-lang-const c-stmt-delim-chars))
  (c c++)
  (concat (or (%substring (c-lang-const c-stmt-boundary-skip-chars) 0 1) "") (or "[" "") (or (%substring (c-lang-const c-stmt-boundary-skip-chars) 1) "")))

;; c-stmt-boundary-skip-chars
(c-lang-defvar c-stmt-boundary-skip-chars (c-lang-const c-stmt-boundary-skip-chars))

;; Emacs's `(append (substring STR 1) nil)' - `append' over a *string*
;; spreads its characters, as Emacs's `append` does and Scheme's does
;; not. The characters are this port's character objects (the consumers
;; compare them with `char-after'), where Emacs holds code points.
(c-lang-defconst c-stmt-boundary-skip-list
  t
  (string->list (or (%substring (c-lang-const c-stmt-boundary-skip-chars) 1)
                    "")))
(c-lang-defvar c-stmt-boundary-skip-list
  (c-lang-const c-stmt-boundary-skip-list))

(c-lang-defconst c-stmt-boundary-skip-list-with-comma
  t
  (string->list (or (%substring (c-lang-const c-stmt-boundary-skip-chars-with-comma)
                                1)
                    "")))
(c-lang-defvar c-stmt-boundary-skip-list-with-comma
  (c-lang-const c-stmt-boundary-skip-list-with-comma))

;; c-stmt-delim-chars-with-comma
(c-lang-defconst c-stmt-delim-chars-with-comma
  t
  "^;,{}?:")

;; c-stmt-delim-chars-with-comma
(c-lang-defvar c-stmt-delim-chars-with-comma (c-lang-const c-stmt-delim-chars-with-comma))

;; c-stmt-boundary-skip-chars-with-comma
(c-lang-defconst c-stmt-boundary-skip-chars-with-comma
  t
  (if (%c-true (c-lang-const c-opt-cpp-symbol)) (concat (or (%substring (c-lang-const c-stmt-delim-chars-with-comma) 0 1) "") (or (c-lang-const c-opt-cpp-symbol) "") (or (%substring (c-lang-const c-stmt-delim-chars-with-comma) 1) "")) (c-lang-const c-stmt-delim-chars-with-comma))
  c++
  (concat (or (%substring (c-lang-const c-stmt-boundary-skip-chars-with-comma) 0 1) "") (or "[" "") (or (%substring (c-lang-const c-stmt-boundary-skip-chars-with-comma) 1) "")))

;; c-stmt-boundary-skip-chars-with-comma
(c-lang-defvar c-stmt-boundary-skip-chars-with-comma (c-lang-const c-stmt-boundary-skip-chars-with-comma))

;; c-pack-ops
(c-lang-defconst c-pack-ops
  "Ops which signal C++11's \"parameter pack\""
  t
  #f
  c++
  '("..."))

;; c-pack-key
(c-lang-defconst c-pack-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-pack-ops) '())))

;; c-pack-key
(c-lang-defvar c-pack-key (c-lang-const c-pack-key))

;; c-auto-ops
(c-lang-defconst c-auto-ops
  t
  #f
  c++
  '("=" "->"))

;; c-auto-ops-re
(c-lang-defconst c-auto-ops-re
  t
  (c-make-keywords-re #f (or (c-lang-const c-auto-ops) '())))

;; c-auto-ops-re
(c-lang-defvar c-auto-ops-re (c-lang-const c-auto-ops-re))

;; c-haskell-op
(c-lang-defconst c-haskell-op
  t
  #f
  c++
  '("->"))

;; c-haskell-op-re
(c-lang-defconst c-haskell-op-re
  t
  (c-make-keywords-re #f (or (c-lang-const c-haskell-op) '())))

;; c-haskell-op-re
(c-lang-defvar c-haskell-op-re (c-lang-const c-haskell-op-re))

;; c-pre-start-tokens
(c-lang-defconst c-pre-start-tokens
  "List of operators following which an apparent declaration (e.g.\n\"t1 *fn (t2 *b);\") is most likely to be an actual declaration\n(as opposed to an arithmetic expression)."
  t
  '(";" "{" "}"))

;; c-pre-start-tokens
(c-lang-defvar c-pre-start-tokens (c-lang-const c-pre-start-tokens))

;; c-pre-lambda-tokens
(c-lang-defconst c-pre-lambda-tokens
  "List of tokens which may precede a lambda declaration.\nIn C++ this is something like \"[a,b] (foo, bar) -> int { ... };\".\nCurrently (2016-08) only used in C++ mode."
  t
  (c--set-difference (or (c--delete-duplicates (or (append (or (c-lang-const c-operator-list) '()) (or (c-lang-const c-other-op-syntax-tokens) '())) '())) '()) (or (append '("#" "%:" "??=" "##" "%:%:" "??=??=" "::" "." "->" "]" "<:" ":>" "??(" "??)" "??-" "new" "delete" ")" ".*" "->*" "??'" "??!" "??!??!" "??!=" "??'=") '("<%" "%>" "<:" ":>" "%:" "%:%:" "#" "##" "::" "...")) '()) ':test string-equal))

;; c-pre-lambda-tokens-re
(c-lang-defconst c-pre-lambda-tokens-re
  t
  (c-make-keywords-re #t (or (c-lang-const c-pre-lambda-tokens) '())))

;; c-pre-lambda-tokens-re
(c-lang-defvar c-pre-lambda-tokens-re (c-lang-const c-pre-lambda-tokens-re))

;; c-simple-ws
(c-lang-defconst c-simple-ws
  "Regexp matching an ordinary whitespace character.\nDoes not contain a \\| operator at the top level."
  t
  "\\(\\s \\|[\n\r]\\)")

;; c-simple-ws-depth
(c-lang-defconst c-simple-ws-depth
  t
  (regexp-opt-depth (c-lang-const c-simple-ws)))

;; c-line-comment-starter
(c-lang-defconst c-line-comment-starter
  "String that starts line comments, or nil if such don't exist.\nLine comments are always terminated by newlines.  At least one of\n`c-block-comment-starter' and this one is assumed to be set.\n\nNote that it's currently not enough to set this to support a new\ncomment style.  Other stuff like the syntax table must also be set up\nproperly."
  t
  "//"
  awk
  "#")

;; c-line-comment-starter
(c-lang-defvar c-line-comment-starter (c-lang-const c-line-comment-starter))

;; c-block-comment-starter
(c-lang-defconst c-block-comment-starter
  "String that starts block comments, or nil if such don't exist.\nBlock comments are ended by `c-block-comment-ender', which is assumed\nto be set if this is.  At least one of `c-line-comment-starter' and\nthis one is assumed to be set.\n\nNote that it's currently not enough to set this to support a new\ncomment style.  Other stuff like the syntax table must also be set up\nproperly."
  t
  "/*"
  awk
  #f)

;; c-block-comment-starter
(c-lang-defvar c-block-comment-starter (c-lang-const c-block-comment-starter))

;; c-block-comment-ender
(c-lang-defconst c-block-comment-ender
  "String that ends block comments, or nil if such don't exist.\n\nNote that it's currently not enough to set this to support a new\ncomment style.  Other stuff like the syntax table must also be set up\nproperly."
  t
  "*/"
  awk
  #f)

;; c-block-comment-ender
(c-lang-defvar c-block-comment-ender (c-lang-const c-block-comment-ender))

;; c-block-comment-ender-regexp
(c-lang-defconst c-block-comment-ender-regexp
  t
  (if (%c-true (c-lang-const c-block-comment-ender)) (regexp-quote (c-lang-const c-block-comment-ender)) regexp-unmatchable))

;; c-block-comment-ender-regexp
(c-lang-defvar c-block-comment-ender-regexp (c-lang-const c-block-comment-ender-regexp))

;; c-block-comment-awkward-chars
(c-lang-defconst c-block-comment-awkward-chars
  "List of characters which, inside a block comment, could be the first\ncharacter of a double character construct.  This doesn't include\nbackslash."
  t
  (if (%c-true (> (%length (c-lang-const c-block-comment-ender)) 1)) (begin (list (aref (c-lang-const c-block-comment-ender) 0))) #f))

;; c-block-comment-awkward-chars
(c-lang-defvar c-block-comment-awkward-chars (c-lang-const c-block-comment-awkward-chars))

;; c-font-lock-comment-end-skip
(c-lang-defconst c-font-lock-comment-end-skip
  t
  (if (%c-true (c-lang-const c-block-comment-ender)) (concat (or "[ \t]*" "") (or (c-lang-const c-block-comment-ender-regexp) "")) regexp-unmatchable))

;; font-lock-comment-end-skip
(c-lang-setvar font-lock-comment-end-skip (c-lang-const c-font-lock-comment-end-skip))

;; c-comment-start-regexp
(c-lang-defconst c-comment-start-regexp
  t
  (let ((re (c-make-keywords-re #f (or (list (c-lang-const c-line-comment-starter) (c-lang-const c-block-comment-starter)) '())))) (if (%c-true (memq 'gen-comment-delim (or c-emacs-features '()))) (concat (or re "") (or "\\|\\s!" "")) re)))

;; c-comment-start-regexp
(c-lang-defvar c-comment-start-regexp (c-lang-const c-comment-start-regexp))

;; c-block-comment-start-regexp
(c-lang-defconst c-block-comment-start-regexp
  t
  (if (%c-true (c-lang-const c-block-comment-starter)) (regexp-quote (c-lang-const c-block-comment-starter)) regexp-unmatchable))

;; c-block-comment-start-regexp
(c-lang-defvar c-block-comment-start-regexp (c-lang-const c-block-comment-start-regexp))

;; c-line-comment-start-regexp
(c-lang-defconst c-line-comment-start-regexp
  t
  (if (%c-true (c-lang-const c-line-comment-starter)) (regexp-quote (c-lang-const c-line-comment-starter)) regexp-unmatchable))

;; c-line-comment-start-regexp
(c-lang-defvar c-line-comment-start-regexp (c-lang-const c-line-comment-start-regexp))

;; c-last-c-comment-end-on-line-re
(c-lang-defconst c-last-c-comment-end-on-line-re
  "Regexp which matches the last block comment ender on the\ncurrent line, if any, or nil in those languages without block\ncomments.  When a match is found, submatch 1 contains the comment\nender."
  t
  "\\(\\*/\\)\\([^*]\\|\\*+\\([^*/]\\|$\\)\\)*$"
  awk
  #f)

;; c-last-c-comment-end-on-line-re
(c-lang-defvar c-last-c-comment-end-on-line-re (c-lang-const c-last-c-comment-end-on-line-re))

;; c-literal-start-regexp
(c-lang-defconst c-literal-start-regexp
  t
  (concat (or (c-lang-const c-comment-start-regexp) "") (or "\\|" "") (or (if (%c-true (memq 'gen-string-delim (or c-emacs-features '()))) "\"\\|\\s|" "\"") "")))

;; c-literal-start-regexp
(c-lang-defvar c-literal-start-regexp (c-lang-const c-literal-start-regexp))

;; c-doc-comment-start-regexp
(c-lang-defconst c-doc-comment-start-regexp
  "Regexp to match the start of documentation comments."
  t
  regexp-unmatchable
  (c c++ objc)
  "/\\*[*!]"
  java
  "/\\*\\*"
  pike
  "/[/*]!")

;; c-doc-comment-start-regexp
(c-lang-defvar c-doc-comment-start-regexp (c-lang-const c-doc-comment-start-regexp))

;; c-block-comment-is-default
(c-lang-defconst c-block-comment-is-default
  "Non-nil when the default comment style is block comment."
  t
  #f
  c
  #t)

;; c-block-comment-is-default
(c-lang-defvar c-block-comment-is-default (c-lang-const c-block-comment-is-default))

;; comment-start
(c-lang-defconst comment-start
  "String that starts comments inserted with M-; etc.\n`comment-start' is initialized from this."
  t
  (concat (or (if (%c-true (c-lang-const c-block-comment-is-default)) (c-lang-const c-block-comment-starter) (c-lang-const c-line-comment-starter)) "") (or " " "")))

;; comment-start
(c-lang-setvar comment-start (c-lang-const comment-start))

;; comment-end
(c-lang-defconst comment-end
  "String that ends comments inserted with M-; etc.\n`comment-end' is initialized from this."
  t
  (if (%c-true (c-lang-const c-block-comment-is-default)) (concat (or " " "") (or (c-lang-const c-block-comment-ender) "")) ""))

;; comment-end
(c-lang-setvar comment-end (c-lang-const comment-end))

;; comment-start-skip
(c-lang-defconst comment-start-skip
  "Regexp to match the start of a comment plus everything up to its body.\n`comment-start-skip' is initialized from this."
  t
  (concat (or "\\(?:" "") (or (c-concat-separated (or (mapcar (lambda (cs) (if (%c-true cs) (begin (concat (or (regexp-quote cs) "") (or "+" ""))) #f)) (list (c-lang-const c-line-comment-starter) (c-lang-const c-block-comment-starter))) '()) "\\|") "") (or "\\)\\s *" "")))

;; comment-start-skip
(c-lang-setvar comment-start-skip (c-lang-const comment-start-skip))

;; comment-end-can-be-escaped
(c-lang-defconst comment-end-can-be-escaped
  "When non-nil, escaped EOLs inside comments are valid.\nThis works in Emacs >= 25.1."
  t
  #f
  (c c++ objc)
  #t)

;; comment-end-can-be-escaped
(c-lang-setvar comment-end-can-be-escaped (c-lang-const comment-end-can-be-escaped))

;; c-syntactic-ws-start
(c-lang-defconst c-syntactic-ws-start
  t
  (concat (or "\\s \\|" "") (or (c-make-keywords-re #f (or (append (or (list (c-lang-const c-line-comment-starter) (c-lang-const c-block-comment-starter) (if (%c-true (c-lang-const c-opt-cpp-prefix)) (begin "#") #f)) '()) '("\n" "\r")) '())) "") (or "\\|\\\\[\n\r]" "") (or (if (%c-true (memq 'gen-comment-delim (or c-emacs-features '()))) (begin "\\|\\s!") #f) "")))

;; c-syntactic-ws-start
(c-lang-defvar c-syntactic-ws-start (c-lang-const c-syntactic-ws-start))

;; c-syntactic-ws-end
(c-lang-defconst c-syntactic-ws-end
  t
  (concat (or "\\s \\|" "") (or (c-make-keywords-re #f (or (append (or (if (%c-true (c-lang-const c-block-comment-ender)) (begin (list (%string (elt (or (c-lang-const c-block-comment-ender) '()) (- (%length (c-lang-const c-block-comment-ender)) 1))))) #f) '()) '("\n" "\r")) '())) "") (or (if (%c-true (memq 'gen-comment-delim (or c-emacs-features '()))) (begin "\\|\\s!") #f) "")))

;; c-syntactic-ws-end
(c-lang-defvar c-syntactic-ws-end (c-lang-const c-syntactic-ws-end))

;; c-unterminated-block-comment-regexp
(c-lang-defconst c-unterminated-block-comment-regexp
  t
  (if (%c-true (c-lang-const c-block-comment-starter)) (begin (concat (or (regexp-quote (c-lang-const c-block-comment-starter)) "") (or (let ((end (c-lang-const c-block-comment-ender))) (cond ((%c-true (= (%length end) 1)) (concat (or "[^" "") (or end "") (or "\n\r]*" ""))) ((%c-true (= (%length end) 2)) (concat (or "[^" "") (or (%substring end 0 1) "") (or "\n\r]*" "") (or "\\(" "") (or (regexp-quote (%substring end 0 1)) "") (or "+" "") (or "[^" "") (or (cond ((%c-true (= (elt (or end '()) 0) (elt (or end '()) 1))) (concat (or (%substring end 0 1) "") (or "\n\r" ""))) ((%c-true (= (elt (or end '()) 1) 93)) (concat (or (%substring end 1 2) "") (or "\n\r" "") (or (%substring end 0 1) ""))) (else (concat (or (%substring end 0 1) "") (or "\n\r" "") (or (%substring end 1 2) "")))) "") (or "]" "") (or "[^" "") (or (%substring end 0 1) "") (or "\n\r]*" "") (or "\\)*" ""))) (else (error "Can't handle a block comment ender of length %s" (%length end))))) ""))) #f))

;; c-block-comment-regexp
(c-lang-defconst c-block-comment-regexp
  t
  (if (%c-true (c-lang-const c-unterminated-block-comment-regexp)) (begin (concat (or (c-lang-const c-unterminated-block-comment-regexp) "") (or (let ((end (c-lang-const c-block-comment-ender))) (cond ((%c-true (= (%length end) 1)) (regexp-quote end)) ((%c-true (= (%length end) 2)) (concat (or (regexp-quote (%substring end 0 1)) "") (or "+" "") (or (regexp-quote (%substring end 1 2)) ""))) (else (error "Can't handle a block comment ender of length %s" (%length end))))) ""))) #f))

;; c-nonwhite-syntactic-ws
(c-lang-defconst c-nonwhite-syntactic-ws
  t
  (c-concat-separated (or (list (if (%c-true (c-lang-const c-line-comment-starter)) (begin (concat (or (regexp-quote (c-lang-const c-line-comment-starter)) "") (or "[^\n\r]*[\n\r]" ""))) #f) (c-lang-const c-block-comment-regexp) "\\\\[\n\r]" (if (%c-true (memq 'gen-comment-delim (or c-emacs-features '()))) (begin "\\s!\\S!*\\s!") #f)) '()) "\\|"))

;; c-syntactic-ws
(c-lang-defconst c-syntactic-ws
  t
  (concat (or (c-lang-const c-simple-ws) "") (or "*" "") (or "\\(" "") (or (concat (or "\\(" "") (or (c-lang-const c-nonwhite-syntactic-ws) "") (or "\\)" "") (or (c-lang-const c-simple-ws) "") (or "*" "")) "") (or "\\)*" "")))

;; c-syntactic-ws-depth
(c-lang-defconst c-syntactic-ws-depth
  t
  (regexp-opt-depth (c-lang-const c-syntactic-ws)))

;; c-nonempty-syntactic-ws
(c-lang-defconst c-nonempty-syntactic-ws
  t
  (concat (or "\\(" "") (or (c-lang-const c-simple-ws) "") (or "\\|" "") (or (c-lang-const c-nonwhite-syntactic-ws) "") (or "\\)+" "")))

;; c-nonempty-syntactic-ws-depth
(c-lang-defconst c-nonempty-syntactic-ws-depth
  t
  (regexp-opt-depth (c-lang-const c-nonempty-syntactic-ws)))

;; c-single-line-syntactic-ws
(c-lang-defconst c-single-line-syntactic-ws
  t
  (if (%c-true (c-lang-const c-block-comment-regexp)) (concat (or "\\s *\\(" "") (or (c-lang-const c-block-comment-regexp) "") (or "\\s *\\)*" "")) "\\s *"))

;; c-single-line-syntactic-ws-depth
(c-lang-defconst c-single-line-syntactic-ws-depth
  t
  (regexp-opt-depth (c-lang-const c-single-line-syntactic-ws)))

;; c-syntactic-eol
(c-lang-defconst c-syntactic-eol
  t
  (concat (or (c-lang-const c-single-line-syntactic-ws) "") (or "\\(" "") (or (c-concat-separated (or (list (if (%c-true (c-lang-const c-line-comment-starter)) (begin (regexp-quote (c-lang-const c-line-comment-starter))) #f) (if (%c-true (c-lang-const c-unterminated-block-comment-regexp)) (begin (concat (or (c-lang-const c-unterminated-block-comment-regexp) "") (or "$" ""))) #f) "\\\\$" "$") '()) "\\|") "") (or "\\)" "")))

;; c-syntactic-eol
(c-lang-defvar c-syntactic-eol (c-lang-const c-syntactic-eol))

;; beginning-of-defun-function
(c-lang-defconst beginning-of-defun-function
  "Function to which beginning-of-defun-function will be set."
  t
  'c-beginning-of-defun
  awk
  'c-awk-beginning-of-defun)

;; beginning-of-defun-function
(c-lang-setvar beginning-of-defun-function (c-lang-const beginning-of-defun-function))

;; end-of-defun-function
(c-lang-defconst end-of-defun-function
  "Function to which end-of-defun-function will be set."
  t
  'c-end-of-defun
  awk
  'c-awk-end-of-defun)

;; end-of-defun-function
(c-lang-setvar end-of-defun-function (c-lang-const end-of-defun-function))

;; c-paragraph-start
(c-lang-defconst c-paragraph-start
  "Regexp to append to `paragraph-start'."
  t
  "$"
  java
  "\\(@[a-zA-Z]+\\_>\\|$\\)"
  pike
  "\\(@[a-zA-Z_-]+\\_>\\([^{]\\|$\\)\\|$\\)")

;; c-paragraph-start
(c-lang-defvar c-paragraph-start (c-lang-const c-paragraph-start))

;; c-paragraph-separate
(c-lang-defconst c-paragraph-separate
  "Regexp to append to `paragraph-separate'."
  t
  "$"
  pike
  (c-lang-const c-paragraph-start))

;; c-paragraph-separate
(c-lang-defvar c-paragraph-separate (c-lang-const c-paragraph-separate))

;; c-primitive-type-kwds
(c-lang-defconst c-primitive-type-kwds
  "Primitive type keywords.  As opposed to most other keyword lists, the\nkeywords listed here are fontified with the type face instead of the\nkeyword face.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled.\n\nDo not try to modify this list for end user customizations; the\n`*-font-lock-extra-types' variable, where `*' is the mode prefix, is\nthe appropriate place for that."
  t
  '("char" "double" "float" "int" "long" "short" "signed" "unsigned" "void")
  c
  (append '("_Bool" "_Complex" "_Imaginary" "_Decimal32" "_Decimal64" "_Decimal128" "bool" "char8_t" "char16_t" "char32_t" "nullptr_t") (or (c-lang-const c-primitive-type-kwds) '()))
  c++
  (append '("bool" "wchar_t" "char8_t" "char16_t" "char32_t" "nullptr_t") (or (c-lang-const c-primitive-type-kwds) '()))
  objc
  (append '("id" "Class" "SEL" "IMP" "BOOL") (or (c-lang-const c-primitive-type-kwds) '()))
  java
  '("boolean" "byte" "char" "double" "float" "int" "long" "short" "void")
  idl
  '("Object" "ValueBase" "any" "boolean" "char" "double" "fixed" "float" "long" "octet" "sequence" "short" "string" "void" "wchar" "wstring" "ref" "unsigned" "strong")
  pike
  '("array" "float" "function" "int" "mapping" "mixed" "multiset" "object" "program" "string" "this_program" "void"))

;; c-return-kwds
(c-lang-defconst c-return-kwds
  "Keywords which return a value to the calling function."
  t
  '("return")
  c++
  '("return" "co_return")
  idl
  #f)

;; c-return-key
(c-lang-defconst c-return-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-return-kwds) '())))

;; c-return-key
(c-lang-defvar c-return-key (c-lang-const c-return-key))

;; c-primitive-type-key
(c-lang-defconst c-primitive-type-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-primitive-type-kwds) '())))

;; c-primitive-type-key
(c-lang-defvar c-primitive-type-key (c-lang-const c-primitive-type-key))

;; c-primitive-type-prefix-kwds
(c-lang-defconst c-primitive-type-prefix-kwds
  "Keywords that might act as prefixes for primitive types.  Assumed to\nbe a subset of `c-primitive-type-kwds'."
  t
  #f
  (c c++ objc)
  '("long" "short" "signed" "unsigned")
  idl
  '("long" "unsigned" "strong"))

;; c-typedef-kwds
(c-lang-defconst c-typedef-kwds
  "Prefix keyword(s) like \"typedef\" which make a type declaration out\nof a variable declaration."
  t
  '("typedef")
  (awk idl java)
  #f)

;; c-typedef-key
(c-lang-defconst c-typedef-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-typedef-kwds) '())))

;; c-typedef-key
(c-lang-defvar c-typedef-key (c-lang-const c-typedef-key))

;; c-typeof-kwds
(c-lang-defconst c-typeof-kwds
  "Keywords followed by a parenthesized expression, which stands for\nthe type of that expression."
  t
  #f
  c
  '("typeof" "typeof_unqual")
  c++
  '("decltype" "typeof"))

;; c-typeof-key
(c-lang-defconst c-typeof-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-typeof-kwds) '())))

;; c-typeof-key
(c-lang-defvar c-typeof-key (c-lang-const c-typeof-key))

;; c-template-typename-kwds
(c-lang-defconst c-template-typename-kwds
  "Keywords which, within a template declaration, can introduce a\ndeclaration with a type as a default value.  This is used only in\nC++ Mode, e.g. \"<typename X = Y>\"."
  t
  #f
  c++
  '("class" "typename"))

;; c-template-typename-key
(c-lang-defconst c-template-typename-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-template-typename-kwds) '())))

;; c-template-typename-key
(c-lang-defvar c-template-typename-key (c-lang-const c-template-typename-key))

;; c-self-contained-typename-kwds
(c-lang-defconst c-self-contained-typename-kwds
  "Keywords where the following name is a type name which can be\nused in declarations without the keyword."
  t
  #f
  c++
  '("typename"))

;; c-self-contained-typename-key
(c-lang-defconst c-self-contained-typename-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-self-contained-typename-kwds) '())))

;; c-self-contained-typename-key
(c-lang-defvar c-self-contained-typename-key (c-lang-const c-self-contained-typename-key))

;; c-type-with-paren-kwds
(c-lang-defconst c-type-with-paren-kwds
  "Keywords followed by a parenthesis expression, which form types."
  t
  #f
  c
  '("_BitInt"))

;; c-type-with-paren-key
(c-lang-defconst c-type-with-paren-key
  "Adorned regexp which matches an element of `c-type-with-paren-kwds'."
  t
  (c-make-keywords-re #t (or (c-lang-const c-type-with-paren-kwds) '())))

;; c-type-with-paren-key
(c-lang-defvar c-type-with-paren-key (c-lang-const c-type-with-paren-key))

;; c-type-prefix-kwds
(c-lang-defconst c-type-prefix-kwds
  "Keywords where the following name - if any - is a type name, and\nwhere the keyword together with the symbol works as a type in\ndeclarations.\n\nNote that an alternative if the second part doesn't hold is\n`c-type-list-kwds'.  Keywords on this list are typically also present\non one of the `*-decl-kwds' lists."
  t
  #f
  (c objc)
  '("struct" "union" "enum")
  c++
  (append '("class" "typename") (or (c-lang-const c-type-prefix-kwds c) '())))

;; c-type-prefix-key
(c-lang-defconst c-type-prefix-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-type-prefix-kwds) '())))

;; c-type-prefix-key
(c-lang-defvar c-type-prefix-key (c-lang-const c-type-prefix-key))

;; c-type-modifier-with-parens-kwds
(c-lang-defconst c-type-modifier-with-parens-kwds
  "Keywords which have parenthesis expressions which modify a type.\nThey can appear anywhere in the type.  Not included here are kwds which\nstand in place of a type, namely those in `c-no-type-kwds'."
  t
  #f
  c
  '("alignof" "alignas" "_Alignas" "_Alignof"))

;; c-type-modifier-with-parens-key
(c-lang-defconst c-type-modifier-with-parens-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-type-modifier-with-parens-kwds) '())))

;; c-type-modifier-with-parens-key
(c-lang-defvar c-type-modifier-with-parens-key (c-lang-const c-type-modifier-with-parens-key))

;; c-type-internal-paren-kwds
(c-lang-defconst c-type-internal-paren-kwds
  t
  (append (or (c-lang-const c-type-with-paren-kwds) '()) (or (c-lang-const c-type-modifier-with-parens-kwds) '())))

;; c-type-internal-paren-key
(c-lang-defconst c-type-internal-paren-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-type-internal-paren-kwds) '())))

;; c-type-internal-paren-key
(c-lang-defvar c-type-internal-paren-key (c-lang-const c-type-internal-paren-key))

;; c-type-modifier-prefix-kwds
(c-lang-defconst c-type-modifier-prefix-kwds
  "Type modifier keywords which can appear in front of a type.  These can\nalso occur almost anywhere in types but they don't build a type of\nthemselves.  Unlike the keywords on `c-primitive-type-kwds', they are\nfontified with the keyword face and not the type face."
  t
  #f
  c
  '("const" "restrict" "volatile")
  c++
  '("const" "noexcept" "volatile")
  objc
  '("const" "volatile")
  java
  '("final")
  t
  (append (or (c-lang-const c-no-type-kwds) '()) (or (c-lang-const c-type-modifier-with-parens-kwds) '()) (or (c-lang-const c-type-modifier-prefix-kwds) '())))

;; c-opt-type-modifier-prefix-key
(c-lang-defconst c-opt-type-modifier-prefix-key
  t
  (if (%c-true (c-lang-const c-type-modifier-prefix-kwds)) (c-make-keywords-re #t (or (c-lang-const c-type-modifier-prefix-kwds) '())) #f))

;; c-opt-type-modifier-prefix-key
(c-lang-defvar c-opt-type-modifier-prefix-key (c-lang-const c-opt-type-modifier-prefix-key))

;; c-type-modifier-kwds
(c-lang-defconst c-type-modifier-kwds
  "Type modifier keywords.  These can occur almost anywhere in types except\nat the start, but they don't build a type of themselves.  Unlike the keywords\non `c-primitive-type-kwds', they are fontified with the keyword face and not\nthe type face."
  t
  (c-lang-const c-type-modifier-prefix-kwds)
  c++
  (append (or (c-lang-const c-type-modifier-prefix-kwds) '()) '("throw")))

;; c-opt-type-modifier-key
(c-lang-defconst c-opt-type-modifier-key
  t
  (if (%c-true (c-lang-const c-type-modifier-kwds)) (c-make-keywords-re #t (or (c-lang-const c-type-modifier-kwds) '())) #f))

;; c-opt-type-modifier-key
(c-lang-defvar c-opt-type-modifier-key (c-lang-const c-opt-type-modifier-key))

;; c-opt-type-component-key
(c-lang-defconst c-opt-type-component-key
  t
  (if (%c-true (or (and (%c-true (c-lang-const c-primitive-type-prefix-kwds)) (c-lang-const c-primitive-type-prefix-kwds)) (c-lang-const c-type-modifier-kwds))) (c-make-keywords-re #t (or (append (or (c-lang-const c-primitive-type-prefix-kwds) '()) (or (c-lang-const c-type-modifier-kwds) '())) '())) #f))

;; c-opt-type-component-key
(c-lang-defvar c-opt-type-component-key (c-lang-const c-opt-type-component-key))

;; c-type-start-kwds
(c-lang-defconst c-type-start-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-primitive-type-kwds) '()) (or (c-lang-const c-type-prefix-kwds) '()) (or (c-lang-const c-type-modifier-kwds) '()) (or (c-lang-const c-type-with-paren-kwds) '())) '()) ':test string-equal))

;; c-type-decl-suffix-ws-ids-kwds
(c-lang-defconst c-type-decl-suffix-ws-ids-kwds
  "\"Identifiers\" that when immediately following a declarator have semantic\neffect in the declaration, but are syntactically like whitespace."
  t
  #f
  c++
  '("final" "override"))

;; c-type-decl-suffix-ws-ids-key
(c-lang-defconst c-type-decl-suffix-ws-ids-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-type-decl-suffix-ws-ids-kwds) '())))

;; c-type-decl-suffix-ws-ids-key
(c-lang-defvar c-type-decl-suffix-ws-ids-key (c-lang-const c-type-decl-suffix-ws-ids-key))

;; c-class-id-suffix-ws-ids-kwds
(c-lang-defconst c-class-id-suffix-ws-ids-kwds
  "\"Identifiers\" that when immediately following the identifier\nof a class declaration have semantic effect in the declaration,\nbut are syntactically like whitespace."
  t
  #f
  c++
  '("final"))

;; c-class-id-suffix-ws-ids-key
(c-lang-defconst c-class-id-suffix-ws-ids-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-class-id-suffix-ws-ids-kwds) '())))

;; c-class-id-suffix-ws-ids-key
(c-lang-defvar c-class-id-suffix-ws-ids-key (c-lang-const c-class-id-suffix-ws-ids-key))

;; c-class-decl-kwds
(c-lang-defconst c-class-decl-kwds
  "Keywords introducing declarations where the following block (if any)\ncontains another declaration level that should be considered a class.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled.\n\nNote that presence on this list does not automatically treat the\nfollowing identifier as a type; the keyword must also be present on\n`c-type-prefix-kwds' or `c-type-list-kwds' to accomplish that."
  t
  #f
  c
  '("struct" "union")
  c++
  '("class" "struct" "union")
  objc
  '("struct" "union" "@interface" "@implementation" "@protocol")
  java
  '("class" "@interface" "interface")
  idl
  '("component" "eventtype" "exception" "home" "interface" "struct" "union" "valuetype" "storagehome" "storagetype" "catalog" "executor" "manages" "segment")
  pike
  '("class"))

;; c-class-key
(c-lang-defconst c-class-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-class-decl-kwds) '())))

;; c-class-key
(c-lang-defvar c-class-key (c-lang-const c-class-key))

;; c-enum-list-kwds
(c-lang-defconst c-enum-list-kwds
  "Keywords introducing declarations where the following block (if\nany) is an enum list.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  '("enum")
  (awk)
  #f)

(c-lang-defconst c-enum-list-key
  ;; "Regexp matching the start of declarations where the following block
  ;; is a brace list."
  ;;
  ;; The `condition-case' is a compatibility fallback for derived modes
  ;; still setting the pre-2024 name; `guard' catches this tree's error,
  ;; which is what the "got no prior value" failure is.
  t
  (let ((liszt (guard (e (#t (c-lang-const c-enum-list-kwds)))
                  (c-lang-const c-brace-list-decl-kwds))))
    (c-make-keywords-re #t liszt)))
(c-lang-defvar c-enum-list-key (c-lang-const c-enum-list-key))

;; c-after-enum-list-kwds
(c-lang-defconst c-after-enum-list-kwds
  "Keywords that might follow keywords in `c-enum-list-kwds'\nand precede the opening brace."
  t
  #f
  c++
  '("class" "struct"))

(c-lang-defconst c-after-enum-list-key
  ;; "Regexp matching keywords that can fall between an enum-list keyword
  ;; and the associated brace list."
  t
  (let ((liszt (guard (e (#t (c-lang-const c-after-enum-list-kwds)))
                  (c-lang-const c-after-brace-list-decl-kwds))))
    (c-make-keywords-re #t liszt)))
(c-lang-defvar c-after-enum-list-key (c-lang-const c-after-enum-list-key))

;; c-recognize-post-brace-list-type-p
(c-lang-defconst c-recognize-post-brace-list-type-p
  "Set to t when we recognize a colon and then a type after an enum,\ne.g., enum foo : int { A, B, C };"
  t
  #f
  (c c++)
  #t)

;; c-recognize-post-brace-list-type-p
(c-lang-defvar c-recognize-post-brace-list-type-p (c-lang-const c-recognize-post-brace-list-type-p))

;; c-other-block-decl-kwds
(c-lang-defconst c-other-block-decl-kwds
  "Keywords where the following block (if any) contains another\ndeclaration level that should not be considered a class.  For every\nkeyword here, CC Mode will add a set of special syntactic symbols for\nthose blocks.  E.g. if the keyword is \"foo\" then there will be\n`foo-open', `foo-close', and `infoo' symbols.\n\nThe intention is that this category should be used for block\nconstructs that aren't related to object orientation concepts like\nclasses (which thus also include e.g. interfaces, templates,\ncontracts, structs, etc).  The more pragmatic distinction is that\nwhile most want some indentation inside classes, it's fairly common\nthat they don't want it in some of these constructs, so it should be\nsimple to configure that differently from classes.  See also\n`c-class-decl-kwds'.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  #f
  (c objc)
  '("extern")
  c++
  '("namespace" "extern")
  idl
  '("module" "composition"))

;; c-other-decl-block-key
(c-lang-defconst c-other-decl-block-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-other-block-decl-kwds) '())))

;; c-other-decl-block-key
(c-lang-defvar c-other-decl-block-key (c-lang-const c-other-decl-block-key))

;; c-other-decl-block-key-in-symbols-alist
(c-lang-defvar c-other-decl-block-key-in-symbols-alist (mapcar (lambda (elt) (cons elt (or (if (%c-true (string=? elt "extern")) 'inextern-lang (intern (concat (or "in" "") (or elt "")))) '()))) (c-lang-const c-other-block-decl-kwds)))

;; c-defun-type-name-decl-kwds
(c-lang-defconst c-defun-type-name-decl-kwds
  "Keywords introducing a named block, where the name is a \"defun\"\n    name."
  t
  (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-enum-list-kwds) '())))

;; c-defun-type-name-decl-key
(c-lang-defconst c-defun-type-name-decl-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-defun-type-name-decl-kwds) '())))

;; c-defun-type-name-decl-key
(c-lang-defvar c-defun-type-name-decl-key (c-lang-const c-defun-type-name-decl-key))

;; c-typedef-decl-kwds
(c-lang-defconst c-typedef-decl-kwds
  "Keywords introducing declarations where the identifier(s) being\ndeclared are types.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-enum-list-kwds) '()))
  (c c++ objc idl pike)
  (append (or (c-lang-const c-typedef-decl-kwds) '()) '("typedef"))
  idl
  (delete "exception" (append (or (c-lang-const c-typedef-decl-kwds) '()) (or #f '()))))

;; c-typedef-decl-key
(c-lang-defconst c-typedef-decl-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-typedef-decl-kwds) '())))

;; c-typedef-decl-key
(c-lang-defvar c-typedef-decl-key (c-lang-const c-typedef-decl-key))

;; c-using-kwds
(c-lang-defconst c-using-kwds
  "Keywords which behave like `using' in C++"
  t
  #f
  c++
  '("using"))

;; c-using-key
(c-lang-defconst c-using-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-using-kwds) '())))

;; c-using-key
(c-lang-defvar c-using-key (c-lang-const c-using-key))

;; c-no-type-kwds
(c-lang-defconst c-no-type-kwds
  "Keywords which remove the need to specify a type in declarations"
  t
  #f
  c++
  '("auto")
  java
  '("var"))

;; c-no-type-key
(c-lang-defconst c-no-type-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-no-type-kwds) '())))

;; c-no-type-key
(c-lang-defvar c-no-type-key (c-lang-const c-no-type-key))

;; c-no-type-with-equals-kwds
(c-lang-defconst c-no-type-with-equals-kwds
  "Keywords after which no type is needed when there's an = sign."
  t
  #f
  c
  '("auto"))

;; c-no-type-with-equals-key
(c-lang-defconst c-no-type-with-equals-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-no-type-with-equals-kwds) '())))

;; c-no-type-with-equals-key
(c-lang-defvar c-no-type-with-equals-key (c-lang-const c-no-type-with-equals-key))

;; c-typeless-decl-kwds
(c-lang-defconst c-typeless-decl-kwds
  "Keywords introducing declarations where the (first) identifier\n(declarator) follows directly after the keyword, without any type.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-enum-list-kwds) '()))
  c
  #f
  idl
  (append (or (c-lang-const c-typeless-decl-kwds) '()) '("factory" "finder" "native" "key" "stores" "facet"))
  pike
  (append (or (c-lang-const c-class-decl-kwds) '()) '("constant")))

;; c-equals-type-clause-kwds
(c-lang-defconst c-equals-type-clause-kwds
  "Keywords which are followed by an identifier then an \"=\"\n  sign, which declares the identifier to be a type."
  t
  #f
  c++
  '("using"))

;; c-equals-type-clause-key
(c-lang-defconst c-equals-type-clause-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-equals-type-clause-kwds) '())))

;; c-equals-type-clause-key
(c-lang-defvar c-equals-type-clause-key (c-lang-const c-equals-type-clause-key))

;; c-lambda-spec-kwds
(c-lang-defconst c-lambda-spec-kwds
  "Keywords which are specifiers of certain elements of a C++ lambda function.\nThis is only used in C++ Mode."
  t
  #f
  c++
  '("mutable" "constexpr" "consteval" "static"))

;; c-lambda-spec-key
(c-lang-defconst c-lambda-spec-key
  t
  (if (%c-true (c-lang-const c-lambda-spec-kwds)) (c-make-keywords-re #t (or (c-lang-const c-lambda-spec-kwds) '())) #f))

;; c-lambda-spec-key
(c-lang-defvar c-lambda-spec-key (c-lang-const c-lambda-spec-key))

;; c-equals-nontype-decl-kwds
(c-lang-defconst c-equals-nontype-decl-kwds
  "Keywords which are followed by an identifier then an \"=\"\nsign, which declares the identifier to be something other than a\ntype."
  t
  #f
  c++
  '("concept"))

;; c-equals-nontype-decl-key
(c-lang-defconst c-equals-nontype-decl-key
  t
  (if (%c-true (c-lang-const c-equals-nontype-decl-kwds)) (begin (c-make-keywords-re #f (or (c-lang-const c-equals-nontype-decl-kwds) '()))) #f))

;; c-equals-nontype-decl-key
(c-lang-defvar c-equals-nontype-decl-key (c-lang-const c-equals-nontype-decl-key))

;; c-fun-name-substitute-kwds
(c-lang-defconst c-fun-name-substitute-kwds
  "Keywords which take the place of type+declarator at the beginning\nof a function-like structure, such as a C++20 \"requires\"\nexpression.  An arglist may or may not follow such a keyword.\nNot to be confused with `c-requires-clause-kwds'."
  t
  #f
  c++
  '("requires"))

;; c-fun-name-substitute-key
(c-lang-defconst c-fun-name-substitute-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-fun-name-substitute-kwds) '())))

;; c-fun-name-substitute-key
(c-lang-defvar c-fun-name-substitute-key (c-lang-const c-fun-name-substitute-key))

;; c-requires-clause-kwds
(c-lang-defconst c-requires-clause-kwds
  "Keywords which introduce a C++ requires clause, or something analogous.\nThis should not be confused with `c-fun-name-substitute-kwds'."
  t
  #f
  c++
  '("requires"))

;; c-requires-clause-key
(c-lang-defconst c-requires-clause-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-requires-clause-kwds) '())))

;; c-requires-clause-key
(c-lang-defvar c-requires-clause-key (c-lang-const c-requires-clause-key))

;; c-modifier-kwds
(c-lang-defconst c-modifier-kwds
  "Keywords that can prefix normal declarations of identifiers\n(and typically act as flags).  Things like argument declarations\ninside function headers are also considered declarations in this\nsense.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  #f
  (c c++)
  '("constexpr" "extern" "inline" "register" "static" "thread_local")
  c
  (append '("auto" "_Thread_local") (or (c-lang-const c-modifier-kwds) '()))
  c++
  (append '("consteval" "constinit" "explicit" "friend" "mutable" "template" "virtual") (or (c-lang-const c-modifier-kwds) '()))
  objc
  '("auto" "bycopy" "byref" "extern" "in" "inout" "oneway" "out" "static")
  idl
  '("abstract" "attribute" "const" "consumes" "custom" "emits" "import" "in" "inout" "local" "multiple" "oneway" "out" "private" "provides" "public" "publishes" "readonly" "typeid" "typeprefix" "uses" "primary" "state" "bindsTo" "delegatesTo" "implements" "proxy" "storedOn")
  java
  '("abstract" "const" "default" "final" "native" "private" "protected" "public" "static" "strictfp" "synchronized" "transient" "volatile")
  pike
  '("final" "inline" "local" "nomask" "optional" "private" "protected" "public" "static" "variant"))

;; c-other-decl-kwds
(c-lang-defconst c-other-decl-kwds
  "Keywords that can start or prefix any declaration level construct,\nbesides those on `c-class-decl-kwds', `c-enum-list-kwds',\n`c-other-block-decl-kwds', `c-typedef-decl-kwds',\n`c-typeless-decl-kwds' and `c-modifier-kwds'.\n\nIf any of these also are on `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds' then the associated clauses\nwill be handled."
  t
  #f
  c++
  '("export")
  objc
  '("@class" "@defs" "@end" "@property" "@dynamic" "@synthesize" "@compatibility_alias")
  java
  '("import" "package")
  pike
  '("import" "inherit"))

;; c-decl-start-kwds
(c-lang-defconst c-decl-start-kwds
  "Keywords that always start declarations, wherever they occur.\nThis can be used for declarations that aren't recognized by the normal\ncombination of `c-decl-prefix-re' and `c-decl-start-re'."
  t
  #f
  pike
  '("class"))

;; c-decl-hangon-kwds
(c-lang-defconst c-decl-hangon-kwds
  "Keywords that can occur anywhere in a declaration level construct.\nThis is used for self-contained things that can be tacked on anywhere\non a declaration and that should be ignored to be able to recognize it\ncorrectly.  Typical cases are compiler extensions like\n\"__attribute__\" or \"__declspec\":\n\n    __declspec(noreturn) void foo();\n    class __declspec(dllexport) classname {...};\n    void foo() __attribute__((noreturn));\n\nNote that unrecognized plain symbols are skipped anyway if they occur\nbefore the type, so such things are not necessary to mention here.\nMentioning them here is necessary only if they can occur in other\nplaces, or if they are followed by a construct that must be skipped\nover (like the parens in the \"__attribute__\" and \"__declspec\"\nexamples above).  In the last case, they also need to be present on\none of `c-type-list-kwds', `c-ref-list-kwds',\n`c-colon-type-list-kwds', `c-paren-nontype-kwds', `c-paren-type-kwds',\n`c-<>-type-kwds', or `c-<>-arglist-kwds'."
  t
  #f
  (c c++)
  '("__attribute__" "__declspec")
  c++
  (append (or (c-lang-const c-decl-hangon-kwds) '()) '("alignas")))

;; c-decl-hangon-key
(c-lang-defconst c-decl-hangon-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-decl-hangon-kwds) '())))

;; c-decl-hangon-key
(c-lang-defvar c-decl-hangon-key (c-lang-const c-decl-hangon-key))

;; c-prefix-spec-kwds
(c-lang-defconst c-prefix-spec-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-enum-list-kwds) '()) (or (c-lang-const c-other-block-decl-kwds) '()) (or (c-lang-const c-typedef-decl-kwds) '()) (or (c-lang-const c-typeless-decl-kwds) '()) (or (c-lang-const c-modifier-kwds) '()) (or (c-lang-const c-other-decl-kwds) '()) (or (c-lang-const c-decl-start-kwds) '()) (or (c-lang-const c-decl-hangon-kwds) '())) '()) ':test string-equal))

;; c-prefix-spec-kwds-re
(c-lang-defconst c-prefix-spec-kwds-re
  t
  (c-make-keywords-re #t (or (c-lang-const c-prefix-spec-kwds) '())))

;; c-prefix-spec-kwds-re
(c-lang-defvar c-prefix-spec-kwds-re (c-lang-const c-prefix-spec-kwds-re))

;; c-specifier-key
(c-lang-defconst c-specifier-key
  t
  (c-make-keywords-re #t (or (c--set-difference (or (c-lang-const c-prefix-spec-kwds) '()) (or (append (or (c-lang-const c-type-start-kwds) '()) (or (c-lang-const c-<>-arglist-kwds) '())) '()) ':test string-equal) '())))

;; c-specifier-key
(c-lang-defvar c-specifier-key (c-lang-const c-specifier-key))

;; c-postfix-spec-kwds
(c-lang-defconst c-postfix-spec-kwds
  t
  (append (or (c-lang-const c-postfix-decl-spec-kwds) '()) (or (c-lang-const c-decl-hangon-kwds) '())))

;; c-not-decl-init-keywords
(c-lang-defconst c-not-decl-init-keywords
  t
  (c-make-keywords-re #t (or (c--set-difference (or (c-lang-const c-keywords) '()) (or (append (or (c-lang-const c-type-start-kwds) '()) (or (c-lang-const c-prefix-spec-kwds) '()) (or (c-lang-const c-typeof-kwds) '())) '()) ':test string-equal) '())))

;; c-not-decl-init-keywords
(c-lang-defvar c-not-decl-init-keywords (c-lang-const c-not-decl-init-keywords))

;; c-not-primitive-type-keywords
(c-lang-defconst c-not-primitive-type-keywords
  "List of all keywords apart from primitive types (like \"int\")."
  t
  (c--set-difference (or (c-lang-const c-keywords) '()) (or (c-lang-const c-primitive-type-kwds) '()) ':test string-equal)
  c++
  (append (or (c-lang-const c-not-primitive-type-keywords) '()) '("more")))

;; c-not-primitive-type-keywords-regexp
(c-lang-defconst c-not-primitive-type-keywords-regexp
  t
  (c-make-keywords-re #t (or (c-lang-const c-not-primitive-type-keywords) '())))

;; c-not-primitive-type-keywords-regexp
(c-lang-defvar c-not-primitive-type-keywords-regexp (c-lang-const c-not-primitive-type-keywords-regexp))

;; c-protection-kwds
(c-lang-defconst c-protection-kwds
  "Access protection label keywords in classes."
  t
  #f
  (c++ java)
  '("private" "protected" "public")
  objc
  '("@private" "@protected" "@package" "@public" "@required" "@optional"))

;; c-protection-key
(c-lang-defconst c-protection-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-protection-kwds) '())))

;; c-protection-key
(c-lang-defvar c-protection-key (c-lang-const c-protection-key))

;; c-post-protection-token
(c-lang-defconst c-post-protection-token
  "The token which (may) follow a protection keyword,\ne.g. the \":\" in C++ Mode's \"public:\".  nil if there is no such token."
  t
  #f
  c++
  ":")

;; c-post-protection-token
(c-lang-defvar c-post-protection-token (c-lang-const c-post-protection-token))

;; c-block-decls-with-vars
(c-lang-defconst c-block-decls-with-vars
  "Keywords introducing declarations that can contain a block which\nmight be followed by variable declarations, e.g. like \"foo\" in\n\"class Foo { ... } foo;\".  So if there is a block in a declaration\nlike that, it ends with the following `;' and not right away.\n\nThe keywords on list are assumed to also be present on one of the\n`*-decl-kwds' lists."
  t
  #f
  (c objc)
  '("struct" "union" "enum" "typedef")
  c++
  '("class" "struct" "union" "enum" "typedef"))

;; c-opt-block-decls-with-vars-key
(c-lang-defconst c-opt-block-decls-with-vars-key
  t
  (if (%c-true (c-lang-const c-block-decls-with-vars)) (c-make-keywords-re #t (or (c-lang-const c-block-decls-with-vars) '())) #f))

;; c-opt-block-decls-with-vars-key
(c-lang-defvar c-opt-block-decls-with-vars-key (c-lang-const c-opt-block-decls-with-vars-key))

;; c-postfix-decl-spec-kwds
(c-lang-defconst c-postfix-decl-spec-kwds
  "Keywords introducing extra declaration specifiers in the region\nbetween the header and the body (i.e. the \"K&R-region\") in\ndeclarations."
  t
  #f
  java
  '("extends" "implements" "throws")
  idl
  '("context" "getraises" "manages" "primarykey" "raises" "setraises" "supports" "as" "const" "implements" "of" "ref"))

;; c-postfix-decl-spec-key
(c-lang-defconst c-postfix-decl-spec-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-postfix-decl-spec-kwds) '())))

;; c-postfix-decl-spec-key
(c-lang-defvar c-postfix-decl-spec-key (c-lang-const c-postfix-decl-spec-key))

;; c-nonsymbol-sexp-kwds
(c-lang-defconst c-nonsymbol-sexp-kwds
  "Keywords that may be followed by a nonsymbol sexp before whatever\nconstruct it's part of continues."
  t
  #f
  (c c++ objc)
  '("extern"))

;; c-make-top-level-kwds
(c-lang-defconst c-make-top-level-kwds
  "Keywords which make declarations they introduce be handled as top-level."
  t
  #f
  (c c++ objc)
  '("extern"))

;; c-make-top-level-key
(c-lang-defconst c-make-top-level-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-make-top-level-kwds) '())))

;; c-make-top-level-key
(c-lang-defvar c-make-top-level-key (c-lang-const c-make-top-level-key))

;; c-type-list-kwds
(c-lang-defconst c-type-list-kwds
  "Keywords that may be followed by a comma separated list of type\nidentifiers, where each optionally can be prefixed by keywords.  (Can\nalso be used for the special case when the list can contain only one\nelement.)\n\nAssumed to be mutually exclusive with `c-ref-list-kwds'.  There's no\nreason to put keywords on this list if they are on `c-type-prefix-kwds'.\nThere's also no reason to add keywords that prefixes a normal\ndeclaration consisting of a type followed by a declarator (list), so\nthe keywords on `c-modifier-kwds' should normally not be listed here\neither.\n\nNote: Use `c-typeless-decl-kwds' for keywords followed by a function\nor variable identifier (that's being defined)."
  t
  #f
  c++
  '("operator")
  objc
  '("@class")
  java
  '("import" "new" "extends" "super" "implements" "throws")
  idl
  '("manages" "native" "primarykey" "supports" "as" "implements" "of" "scope")
  pike
  '("inherit"))

;; c-ref-list-kwds
(c-lang-defconst c-ref-list-kwds
  "Keywords that may be followed by a comma separated list of\nreference (i.e. namespace/scope/module) identifiers, where each\noptionally can be prefixed by keywords.  (Can also be used for the\nspecial case when the list can contain only one element.)  Assumed to\nbe mutually exclusive with `c-type-list-kwds'.\n\nNote: Use `c-typeless-decl-kwds' for keywords followed by a function\nor variable identifier (that's being defined)."
  t
  #f
  c++
  '("namespace")
  java
  '("package")
  idl
  '("import" "module" "composition")
  pike
  '("import"))

;; c-colon-type-list-kwds
(c-lang-defconst c-colon-type-list-kwds
  "Keywords that may be followed (not necessarily directly) by a colon\nand then a comma separated list of type identifiers, where each\noptionally can be prefixed by keywords.  (Can also be used for the\nspecial case when the list can contain only one element.)"
  t
  #f
  c++
  '("class" "struct")
  idl
  '("component" "eventtype" "home" "interface" "valuetype" "storagehome" "storagetype"))

;; c-colon-type-list-re
(c-lang-defconst c-colon-type-list-re
  "Regexp matched after the keywords in `c-colon-type-list-kwds' to skip\nforward to the colon.  The end of the match is assumed to be directly\nafter the colon, so the regexp should end with \":\".  Must be a\nregexp if `c-colon-type-list-kwds' isn't nil."
  t
  (if (%c-true (c-lang-const c-colon-type-list-kwds)) (if (%c-true (c-lang-const c-opt-identifier-concat-key)) (concat (or "\\([^][{}();,/#=:]\\|" "") (or (c-lang-const c-opt-identifier-concat-key) "") (or "\\)*:" "")) "[^][{}();,/#=:]*:") #f))

;; c-colon-type-list-re
(c-lang-defvar c-colon-type-list-re (c-lang-const c-colon-type-list-re))

;; c-sub-colon-type-list-re
(c-lang-defconst c-sub-colon-type-list-re
  "Regexp matching buffer content that may come between a keyword in\n`c-colon-type-list-kwds' and a putative colon, or nil if there are no\nsuch keywords.  Exception: it does not match any C++ attributes."
  t
  (if (%c-true (c-lang-const c-colon-type-list-re)) (%substring (c-lang-const c-colon-type-list-re) 0 -1) #f))

;; c-sub-colon-type-list-re
(c-lang-defvar c-sub-colon-type-list-re (c-lang-const c-sub-colon-type-list-re))

;; c-paren-nontype-kwds
(c-lang-defconst c-paren-nontype-kwds
  "Keywords that may be followed by a parenthesis expression that doesn't\ncontain type identifiers."
  t
  #f
  (c c++)
  '("__attribute__" "__declspec" "static_assert")
  c
  (append (or (c-lang-const c-paren-nontype-kwds) '()) '("_Static_assert"))
  c++
  (append (or (c-lang-const c-paren-nontype-kwds) '()) '("noexcept" "alignas")))

;; c-paren-nontype-key
(c-lang-defconst c-paren-nontype-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-paren-nontype-kwds) '())))

;; c-paren-nontype-key
(c-lang-defvar c-paren-nontype-key (c-lang-const c-paren-nontype-key))

;; c-paren-type-kwds
(c-lang-defconst c-paren-type-kwds
  "Keywords that may be followed by a parenthesis expression containing\ntype identifiers separated by arbitrary tokens."
  t
  #f
  c++
  '("throw")
  objc
  '("@defs")
  idl
  '("switch")
  pike
  '("array" "function" "int" "mapping" "multiset" "object" "program"))

;; c-paren-any-kwds
(c-lang-defconst c-paren-any-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-paren-nontype-kwds) '()) (or (c-lang-const c-paren-type-kwds) '())) '()) ':test string-equal))

;; c-<>-type-kwds
(c-lang-defconst c-<>-type-kwds
  "Keywords that may be followed by an angle bracket expression\ncontaining type identifiers separated by \",\".  The difference from\n`c-<>-arglist-kwds' is that unknown names are taken to be types and\nnot other identifiers.  `c-recognize-<>-arglists' is assumed to be set\nif this isn't nil."
  t
  #f
  objc
  '("id")
  idl
  '("sequence" "ref"))

;; c-pre-concept-<>-kwds
(c-lang-defconst c-pre-concept-<>-kwds
  "Keywords that may be followed by an angle bracket expression containing\nuses of \"concepts\".  This is currently (2022-09) used only by C++."
  t
  #f
  c++
  '("template"))

;; c-pre-concept-<>-key
(c-lang-defconst c-pre-concept-<>-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-pre-concept-<>-kwds) '())))

;; c-pre-concept-<>-key
(c-lang-defvar c-pre-concept-<>-key (c-lang-const c-pre-concept-<>-key))

;; c-<>-arglist-kwds
(c-lang-defconst c-<>-arglist-kwds
  "Keywords that can be followed by a C++ style template arglist; see\n`c-recognize-<>-arglists' for details.  That language constant is\nassumed to be set if this isn't nil."
  t
  #f
  c++
  '("template" "const_cast" "dynamic_cast" "reinterpret_cast" "static_cast")
  idl
  '("fixed" "string" "wstring"))

;; c-<>-sexp-kwds
(c-lang-defconst c-<>-sexp-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-<>-type-kwds) '()) (or (c-lang-const c-<>-arglist-kwds) '()) (or (c-lang-const c-import-<>-kwds) '())) '()) ':test string-equal))

;; c-opt-<>-sexp-key
(c-lang-defconst c-opt-<>-sexp-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-<>-sexp-kwds) '())))

;; c-opt-<>-sexp-key
(c-lang-defvar c-opt-<>-sexp-key (c-lang-const c-opt-<>-sexp-key))

;; c-inside-<>-type-kwds
(c-lang-defconst c-inside-<>-type-kwds
  "Keywords which, used inside a C++ style template arglist, introduce a type."
  t
  #f
  java
  '("extends" "super"))

;; c-inside-<>-type-key
(c-lang-defconst c-inside-<>-type-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-inside-<>-type-kwds) '())))

;; c-inside-<>-type-key
(c-lang-defvar c-inside-<>-type-key (c-lang-const c-inside-<>-type-key))

;; c-brace-id-list-kwds
(c-lang-defconst c-brace-id-list-kwds
  "Keywords that may be followed by a brace block containing a comma\nseparated list of identifier definitions, i.e. like the list of\nidentifiers that follows the type in a normal declaration."
  t
  (c-lang-const c-enum-list-kwds))

;; c-block-stmt-1-kwds
(c-lang-defconst c-block-stmt-1-kwds
  "Statement keywords followed directly by a substatement."
  t
  '("do" "else")
  c++
  '("do" "else" "try")
  objc
  '("do" "else" "@finally" "@try" "@autoreleasepool")
  java
  '("do" "else" "finally" "try")
  idl
  #f)

;; c-block-stmt-1-key
(c-lang-defconst c-block-stmt-1-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-block-stmt-1-kwds) '())))

;; c-block-stmt-1-key
(c-lang-defvar c-block-stmt-1-key (c-lang-const c-block-stmt-1-key))

;; c-block-stmt-1-2-kwds
(c-lang-defconst c-block-stmt-1-2-kwds
  "Statement keywords optionally followed by a paren sexp.\nKeywords here should also be in `c-block-stmt-1-kwds'."
  t
  #f
  java
  '("try"))

;; c-block-stmt-1-2-key
(c-lang-defconst c-block-stmt-1-2-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-block-stmt-1-2-kwds) '())))

;; c-block-stmt-1-2-key
(c-lang-defvar c-block-stmt-1-2-key (c-lang-const c-block-stmt-1-2-key))

;; c-block-stmt-2-kwds
(c-lang-defconst c-block-stmt-2-kwds
  "Statement keywords followed by a paren sexp and then by a substatement."
  t
  '("for" "if" "switch" "while")
  c++
  '("for" "if" "switch" "while" "catch")
  objc
  '("for" "if" "switch" "while" "@catch" "@synchronized")
  java
  '("for" "if" "switch" "while" "catch" "synchronized")
  idl
  #f
  pike
  '("for" "if" "switch" "while" "foreach")
  awk
  '("for" "if" "switch" "while"))

;; c-block-stmt-2-key
(c-lang-defconst c-block-stmt-2-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-block-stmt-2-kwds) '())))

;; c-block-stmt-2-key
(c-lang-defvar c-block-stmt-2-key (c-lang-const c-block-stmt-2-key))

;; c-generic-kwds
(c-lang-defconst c-generic-kwds
  "The keyword \"_Generic\" which introduces a C11 generic statement."
  t
  #f
  c
  '("_Generic"))

;; c-generic-key
(c-lang-defconst c-generic-key
  t
  (if (%c-true (c-lang-const c-generic-kwds)) (c-make-keywords-re #t (or (c-lang-const c-generic-kwds) '())) #f))

;; c-generic-key
(c-lang-defvar c-generic-key (c-lang-const c-generic-key))

;; c-block-stmt-kwds
(c-lang-defconst c-block-stmt-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-block-stmt-1-kwds) '()) (or (c-lang-const c-block-stmt-2-kwds) '())) '()) ':test string-equal))

;; c-block-stmt-hangon-kwds
(c-lang-defconst c-block-stmt-hangon-kwds
  "Keywords which may directly follow a member of `c-block-stmt-1/2-kwds'."
  t
  #f
  c++
  '("constexpr"))

;; c-block-stmt-hangon-key
(c-lang-defconst c-block-stmt-hangon-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-block-stmt-hangon-kwds) '())))

;; c-block-stmt-hangon-key
(c-lang-defvar c-block-stmt-hangon-key (c-lang-const c-block-stmt-hangon-key))

;; c-opt-block-stmt-key
(c-lang-defconst c-opt-block-stmt-key
  t
  (if (%c-true (or (and (%c-true (c-lang-const c-block-stmt-1-kwds)) (c-lang-const c-block-stmt-1-kwds)) (c-lang-const c-block-stmt-2-kwds))) (c-make-keywords-re #t (or (append (or (c-lang-const c-block-stmt-1-kwds) '()) (or (c-lang-const c-block-stmt-2-kwds) '())) '())) #f))

;; c-opt-block-stmt-key
(c-lang-defvar c-opt-block-stmt-key (c-lang-const c-opt-block-stmt-key))

;; c-paren-clause-kwds
(c-lang-defconst c-paren-clause-kwds
  "Keywords which can stand in the place of paren sexps in conditionals.\nThis applies only to conditionals in `c-block-stmt-with-kwds'."
  t
  #f
  c++
  '("consteval"))

;; c-paren-clause-key
(c-lang-defconst c-paren-clause-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-paren-clause-kwds) '())))

;; c-paren-clause-key
(c-lang-defvar c-paren-clause-key (c-lang-const c-paren-clause-key))

;; c-block-stmt-with-kwds
(c-lang-defconst c-block-stmt-with-kwds
  "Statement keywords which can be followed by a keyword instead of a parens.\nSuch a keyword is a member of `c-paren-clause-kwds."
  t
  #f
  c++
  '("if"))

;; c-block-stmt-with-key
(c-lang-defconst c-block-stmt-with-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-block-stmt-with-kwds) '())))

;; c-block-stmt-with-key
(c-lang-defvar c-block-stmt-with-key (c-lang-const c-block-stmt-with-key))

;; c-simple-stmt-kwds
(c-lang-defconst c-simple-stmt-kwds
  "Statement keywords followed by an expression or nothing."
  t
  '("break" "continue" "goto" "return")
  c++
  '("break" "continue" "goto" "return" "co_return")
  objc
  '("break" "continue" "goto" "return" "@throw")
  java
  '("assert" "break" "continue" "goto" "return" "throw")
  idl
  #f
  pike
  '("break" "continue" "return")
  awk
  '("break" "continue" "return" "delete" "exit" "getline" "next" "nextfile" "print" "printf"))

;; c-simple-stmt-key
(c-lang-defconst c-simple-stmt-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-simple-stmt-kwds) '())))

;; c-simple-stmt-key
(c-lang-defvar c-simple-stmt-key (c-lang-const c-simple-stmt-key))

;; c-paren-stmt-kwds
(c-lang-defconst c-paren-stmt-kwds
  "Statement keywords followed by a parenthesis expression that\nnevertheless contains a list separated with `;' and not `,'."
  t
  '("for")
  idl
  #f)

;; c-paren-stmt-key
(c-lang-defconst c-paren-stmt-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-paren-stmt-kwds) '())))

;; c-paren-stmt-key
(c-lang-defvar c-paren-stmt-key (c-lang-const c-paren-stmt-key))

;; c-asm-stmt-kwds
(c-lang-defconst c-asm-stmt-kwds
  "Statement keywords followed by an assembler expression."
  t
  #f
  (c c++)
  '("asm" "__asm__"))

;; c-opt-asm-stmt-key
(c-lang-defconst c-opt-asm-stmt-key
  t
  (if (%c-true (c-lang-const c-asm-stmt-kwds)) (c-make-keywords-re #t (or (c-lang-const c-asm-stmt-kwds) '())) #f))

;; c-opt-asm-stmt-key
(c-lang-defvar c-opt-asm-stmt-key (c-lang-const c-opt-asm-stmt-key))

;; c-case-kwds
(c-lang-defconst c-case-kwds
  "The keyword(s) which introduce a \"case\" like construct.\nThis construct is \"<keyword> <expression> :\"."
  t
  '("case"))

;; c-case-kwds-regexp
(c-lang-defconst c-case-kwds-regexp
  t
  (c-make-keywords-re #t (or (c-lang-const c-case-kwds) '())))

;; c-case-kwds-regexp
(c-lang-defvar c-case-kwds-regexp (c-lang-const c-case-kwds-regexp))

;; c-label-kwds
(c-lang-defconst c-label-kwds
  "Keywords introducing colon terminated labels in blocks."
  t
  '("case" "default"))

;; c-label-kwds-regexp
(c-lang-defconst c-label-kwds-regexp
  t
  (c-make-keywords-re #t (or (c-lang-const c-label-kwds) '())))

;; c-label-kwds-regexp
(c-lang-defvar c-label-kwds-regexp (c-lang-const c-label-kwds-regexp))

;; c-before-label-kwds
(c-lang-defconst c-before-label-kwds
  "Keywords that might be followed by a label identifier."
  t
  '("goto")
  (java pike)
  (append '("break" "continue") (or (c-lang-const c-before-label-kwds) '()))
  idl
  #f
  awk
  #f)

;; c-import-<>-kwds
(c-lang-defconst c-import-<>-kwds
  "Keywords which can start an expression like \"import <...>\" in C++20.\nThe <, and > operators are like those of #include <...>, they are\nnot really template operators."
  t
  #f
  c++
  '("import"))

;; c-module-kwds
(c-lang-defconst c-module-kwds
  "The keywords which introduce module constructs in C++20 onwards."
  t
  #f
  c++
  '("module" "import" "export"))

;; c-module-key
(c-lang-defconst c-module-key
  t
  (if (%c-true (c-lang-const c-module-kwds)) (c-make-keywords-re #t (or (c-lang-const c-module-kwds) '())) #f))

;; c-module-key
(c-lang-defvar c-module-key (c-lang-const c-module-key))

;; c-constant-kwds
(c-lang-defconst c-constant-kwds
  "Keywords for constants."
  t
  #f
  (c c++)
  '("NULL" "false" "true" "nullptr")
  objc
  '("nil" "Nil" "YES" "NO" "IBAction" "IBOutlet" "NS_DURING" "NS_HANDLER" "NS_ENDHANDLER")
  idl
  '("TRUE" "FALSE")
  java
  '("true" "false" "null")
  pike
  '("UNDEFINED"))

;; c-constant-key
(c-lang-defconst c-constant-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-constant-kwds) '())))

;; c-constant-key
(c-lang-defvar c-constant-key (c-lang-const c-constant-key))

;; c-primary-expr-kwds
(c-lang-defconst c-primary-expr-kwds
  "Keywords besides constants and operators that start primary expressions."
  t
  #f
  c++
  '("operator" "this")
  objc
  '("super" "self")
  java
  '("this")
  pike
  '("this"))

;; c-expr-kwds
(c-lang-defconst c-expr-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-primary-expr-kwds) '()) (or (c-filter-ops (or (c-lang-const c-operator-list) '()) #t "\\`\\(\\w\\|\\s_\\)+\\'") '())) '()) ':test string-equal))

;; c-lambda-kwds
(c-lang-defconst c-lambda-kwds
  "Keywords that start lambda constructs, i.e. function definitions in\nexpressions."
  t
  #f
  pike
  '("lambda"))

;; c-inexpr-block-kwds
(c-lang-defconst c-inexpr-block-kwds
  "Keywords that start constructs followed by statement blocks which can\nbe used in expressions (the gcc extension for this in C and C++ is\nhandled separately by `c-recognize-paren-inexpr-blocks')."
  t
  #f
  pike
  '("catch" "gauge"))

;; c-inexpr-class-kwds
(c-lang-defconst c-inexpr-class-kwds
  "Keywords that can start classes inside expressions."
  t
  #f
  java
  '("new")
  pike
  '("class"))

;; c-inexpr-brace-list-kwds
(c-lang-defconst c-inexpr-brace-list-kwds
  "Keywords that can start brace list blocks inside expressions.\nNote that Java specific rules are currently applied to tell this from\n`c-inexpr-class-kwds'."
  t
  #f
  java
  '("new"))

;; c-opt-inexpr-brace-list-key
(c-lang-defconst c-opt-inexpr-brace-list-key
  t
  (if (%c-true (c-lang-const c-inexpr-brace-list-kwds)) (c-make-keywords-re #t (or (c-lang-const c-inexpr-brace-list-kwds) '())) #f))

;; c-opt-inexpr-brace-list-key
(c-lang-defvar c-opt-inexpr-brace-list-key (c-lang-const c-opt-inexpr-brace-list-key))

;; c-flat-decl-block-kwds
(c-lang-defconst c-flat-decl-block-kwds
  t
  (c--delete-duplicates (or (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-other-block-decl-kwds) '()) (or (c-lang-const c-inexpr-class-kwds) '())) '()) ':test string-equal))

;; c-brace-stack-thing-key
(c-lang-defconst c-brace-stack-thing-key
  t
  (c-make-keywords-re #t (or (append (or (c-lang-const c-flat-decl-block-kwds) '()) (or (if (%c-true (c-lang-const c-recognize-<>-arglists)) '("{" "}" ";" "*" "," ")" ":" "<") '("{" "}" ";" "*" "," ")" ":")) '())) '())))

;; c-brace-stack-thing-key
(c-lang-defvar c-brace-stack-thing-key (c-lang-const c-brace-stack-thing-key))

;; c-brace-stack-no-semi-key
(c-lang-defconst c-brace-stack-no-semi-key
  t
  (c-make-keywords-re #t (or (append (or (c-lang-const c-flat-decl-block-kwds) '()) (or (if (%c-true (c-lang-const c-recognize-<>-arglists)) '("{" "}" "<") '("{" "}")) '())) '())))

;; c-brace-stack-no-semi-key
(c-lang-defvar c-brace-stack-no-semi-key (c-lang-const c-brace-stack-no-semi-key))

;; c-decl-block-key
(c-lang-defconst c-decl-block-key
  t
  (let* ((decl-kwds (append (or (c-lang-const c-class-decl-kwds) '()) (or (c-lang-const c-other-block-decl-kwds) '()) (or (c-lang-const c-inexpr-class-kwds) '()))) (unambiguous (c--set-difference (or decl-kwds '()) (or (c-lang-const c-type-start-kwds) '()) ':test string-equal)) (ambiguous (c--intersection (or decl-kwds '()) (or (c-lang-const c-type-start-kwds) '()) ':test string-equal))) (if (%c-true ambiguous) (concat (or (c-make-keywords-re #t (or unambiguous '())) "") (or "\\|" "") (or (c-make-keywords-re #t (or ambiguous '())) "")) (c-make-keywords-re #t (or unambiguous '())))))

;; c-decl-block-key
(c-lang-defvar c-decl-block-key (c-lang-const c-decl-block-key))

;; c-bitfield-kwds
(c-lang-defconst c-bitfield-kwds
  "Keywords that can introduce bitfields."
  t
  #f
  (c c++ objc)
  '("char" "int" "long" "signed" "unsigned"))

;; c-opt-bitfield-key
(c-lang-defconst c-opt-bitfield-key
  t
  #f
  (c c++)
  (c-make-keywords-re #t (or (c-lang-const c-bitfield-kwds) '())))

;; c-opt-bitfield-key
(c-lang-defvar c-opt-bitfield-key (c-lang-const c-opt-bitfield-key))

;; c-other-kwds
(c-lang-defconst c-other-kwds
  "Keywords not accounted for by any other `*-kwds' language constant."
  t
  #f
  idl
  '("truncatable" "entity" "process" "service" "session" "storage"))

;; c-std-abbrev-keywords
(c-lang-defconst c-std-abbrev-keywords
  "List of keywords which may need to cause electric indentation."
  t
  '("else" "while")
  c++
  (append (or (c-lang-const c-std-abbrev-keywords) '()) '("catch"))
  java
  (append (or (c-lang-const c-std-abbrev-keywords) '()) '("catch" "finally"))
  idl
  #f)

;; c-std-abbrev-keywords
(c-lang-defvar c-std-abbrev-keywords (c-lang-const c-std-abbrev-keywords))

    ;;------------------------------------------------------------------
    ;; `c-kwds-lang-consts' (`cc-langs.el:3581')
    ;;------------------------------------------------------------------
    ;; "List of all the language constants that contain keyword lists."
    ;; Emacs walks the `c-lang-constants' obarray with `mapatoms'; the
    ;; registry answers its names instead, *sorted by name* where
    ;; `mapatoms' has obarray order - a named departure, and the only
    ;; order-sensitive one: the membership is what reaches the keyword
    ;; lists, and every regexp built from them is `regexp-opt''s order.
    ;; Like Emacs, this is computed where it stands: a `*-kwds' constant
    ;; defined later in the file (there is one, `c-pre-id-bracelist-kwds')
    ;; is not in it, and that was measured on Emacs 31.1.
    (define c-kwds-lang-consts
      (let loop ((names (c-lang-constant-names)) (out '()))
        (cond ((null? names) (reverse out))
              ((string-suffix-p "-kwds" (symbol->string (car names)))
               (loop (cdr names) (cons (car names) out)))
              (else (loop (cdr names) out)))))

(c-lang-defconst c-keywords
  ;; "All keywords as a list."
  ;;
  ;; `(or (c-lang-const ,k) '())': Emacs's `append' ignores a nil
  ;; argument; a constant here may be `#f', which `append' would refuse.
  t
  (c--delete-duplicates
   (c-lang-defconst-eval-immediately
    `(append ,@(or (mapcar (lambda (kwds-lang-const)
                             `(or (c-lang-const ,kwds-lang-const) '()))
                          c-kwds-lang-consts)
                   '())
             (quote ())))
   ':test string-equal))

;; c-keywords-regexp
(c-lang-defconst c-keywords-regexp
  t
  (c-make-keywords-re #t (or (c-lang-const c-keywords) '())))

;; c-keywords-regexp
(c-lang-defvar c-keywords-regexp (c-lang-const c-keywords-regexp))

;; c-stmt-block-only-keywords
(c-lang-defconst c-stmt-block-only-keywords
  "All keywords which unambiguously signify a statement block (as opposed to\n   a brace list) when occurring inside braces."
  t
  (c--set-difference (or (c-lang-const c-keywords) '()) (or (append (or (c-lang-const c-primary-expr-kwds) '()) (or (c-lang-const c-constant-kwds) '()) (or `(,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("typeid" "dynamic_cast" "static_cast" "const_cast" "reinterpret_cast" "alignof")) #f) '())) '()) (or (c-lang-const c-type-modifier-prefix-kwds) '()) (or (c-lang-const c-overloadable-operators) '()) (or (c-lang-const c-template-typename-kwds) '()) (or `(,@(or (if (%c-true (c-major-mode-is 'c++-mode)) (begin '("reflexpr")) #f) '())) '()) (or `(,@(or (if (%c-true (c-major-mode-is '(c-mode c++-mode))) (begin '("sizeof")) #f) '())) '()) (or (c-lang-const c-pre-lambda-tokens) '()) (or (c-lang-const c-block-decls-with-vars) '()) (or (c-lang-const c-primitive-type-kwds) '())) '()) ':test string-equal))

;; c-stmt-block-only-keywords-regexp
(c-lang-defconst c-stmt-block-only-keywords-regexp
  t
  (concat (or "\\(\\_<\\|\\=\\)" "") (or (c-make-keywords-re #t (or (c-lang-const c-stmt-block-only-keywords) '())) "")))

;; c-stmt-block-only-keywords-regexp
(c-lang-defvar c-stmt-block-only-keywords-regexp (c-lang-const c-stmt-block-only-keywords-regexp))

(c-lang-defconst c-keyword-member-alist
  ;; "An alist with all the keywords in the cars. The cdr for each
  ;; keyword is a list of the symbols for the `*-kwds' lists that
  ;; contains it."
  ;;
  ;; Emacs's imperative loop with its `setcdr'; ported step for step.
  t
  (let ((kwd-list-alist
            (c-lang-defconst-eval-immediately
             `(list ,@(mapcar (lambda (kwds-lang-const)
                                `(cons ',kwds-lang-const
                                       (or (c-lang-const ,kwds-lang-const)
                                           '())))
                              c-kwds-lang-consts))))
           (result-alist '()))
       (let loop ((rest kwd-list-alist))
         (if (null? rest)
             result-alist
             (begin
               (let ((lang-const (caar rest))
                     (kwd-list (cdar rest)))
                 (let inner ((ks kwd-list))
                   (if (null? ks)
                       #f
                       (begin
                         (let* ((kwd (car ks))
                                (elem (assoc kwd result-alist)))
                           (unless elem
                             (set! elem (list kwd))
                             (set! result-alist (cons elem result-alist)))
                           (unless (memq lang-const (cdr elem))
                             (set-cdr! elem (cons lang-const (cdr elem)))))
                         (inner (cdr ks))))))
               (loop (cdr rest)))))))

;; `c-keywords-obarray' (`cc-langs.el:3663'): Emacs builds an obarray
;; whose symbols' property lists carry the `*-kwds' membership. There
;; is no obarray in this tree, so the same information is a hash keyed
;; by the keyword *string* whose value is the membership list -
;; `c-keyword-member-alist' indexed the second way, as the note above
;; planned. `cc-engine.scm''s `c-keyword-sym'/`c-keyword-member' read it.
;;
;; **It is a `c-lang-defvar`, as in Emacs, and that is load-bearing.**
;; Building it evaluates `c-keyword-member-alist', whose evaluation runs
;; `c-make-keywords-re' - and that calls `string-match' on every
;; keyword. Done lazily on the first `c-keyword-sym' call it clobbered
;; the match data of the caller: `c-forward-keyword-clause' reads
;; `(match-end match)' right after asking `c-keyword-sym', and a
;; keyword lookup from a `looking-at' context found the match data of
;; whatever keyword string `c-make-keywords-re' had checked last. Emacs
;; computes this at language-init time, before any of that.
(c-lang-defvar c-keywords-obarray
  (let ((alist (c-lang-const c-keyword-member-alist))
        (table (make-hash-table)))
    (for-each (lambda (entry)
                (hash-set! table (car entry) (cdr entry)))
              (if (list? alist) alist '()))
    table))

;; c-regular-keywords-regexp
(c-lang-defconst c-regular-keywords-regexp
  t
  (c-make-keywords-re #t (or (c--set-difference (or (c-lang-const c-keywords) '()) (or (append (or (c-lang-const c-primitive-type-kwds) '()) (or (c-lang-const c-constant-kwds) '()) (or (c-lang-const c-type-with-paren-kwds) '())) '()) ':test string-equal) '())))

;; c-regular-keywords-regexp
(c-lang-defvar c-regular-keywords-regexp (c-lang-const c-regular-keywords-regexp))

;; c-primary-expr-regexp-details
(c-lang-defconst c-primary-expr-regexp-details
  t
  (let* ((prefix-ops (c-filter-ops (or (c-lang-const c-operators) '()) '(prefix) (lambda (op) (not (%c-true (string-match "\\s)" op)))))) (postfix-ops (c-filter-ops (or (c-lang-const c-operators) '()) '(postfix) (lambda (op) (not (%c-true (string-match "\\s)" op)))))) (in-or-postfix-ops (c-filter-ops (or (c-lang-const c-operators) '()) '(postfix postfix-if-paren left-assoc right-assoc right-assoc-sequence) #t)) (nonkeyword-prefix-ops (c-filter-ops (or prefix-ops '()) #t "\\`\\(\\s.\\|\\s(\\|\\s)\\)+\\'")) (nonkeyword-postfix-ops (c-filter-ops (or postfix-ops '()) #t "\\`\\(\\s.\\|\\s(\\|\\s)\\)+\\'")) (cast-ops (c-filter-ops (or prefix-ops '()) #t "\\`\\s(\\'")) (ambiguous-pre/postfix-ops (c--set-difference (or (c--intersection (or nonkeyword-prefix-ops '()) (or nonkeyword-postfix-ops '()) ':test string-equal) '()) (or cast-ops '()) ':test string-equal)) (unambiguous-prefix-ops (c--set-difference (or nonkeyword-prefix-ops '()) (or in-or-postfix-ops '()) ':test string-equal)) (ambiguous-prefix-ops (c--intersection (or nonkeyword-prefix-ops '()) (or in-or-postfix-ops '()) ':test string-equal)) (ambiguous-prefix-non-postfix-ops (c--set-difference (or (c--set-difference (or ambiguous-prefix-ops '()) (or ambiguous-pre/postfix-ops '()) ':test string-equal) '()) (or cast-ops '()) ':test string-equal)) (primary-expression-keywords-string (c-make-keywords-re #t (or (append (or (c-lang-const c-primary-expr-kwds) '()) (or (c--set-difference (or prefix-ops '()) (or nonkeyword-prefix-ops '()) ':test string-equal) '())) '()))) (primary-expression-keywords-string-depth (regexp-opt-depth primary-expression-keywords-string)) (ambiguous-pre/postfix-string (c-make-keywords-re #f (or ambiguous-pre/postfix-ops '()))) (ambiguous-pre/postfix-string-depth (regexp-opt-depth ambiguous-pre/postfix-string)) (ambiguous-prefix-non-postfix-string (c-make-keywords-re #f (or ambiguous-prefix-non-postfix-ops '()))) (ambiguous-prefix-non-postfix-string-depth (regexp-opt-depth ambiguous-prefix-non-postfix-string)) (per-++---match (+ 2 primary-expression-keywords-string-depth)) (per-&*+--match (+ 1 per-++---match ambiguous-pre/postfix-string-depth)) (#{per-(-match}# (+ 1 per-&*+--match ambiguous-prefix-non-postfix-string-depth))) (list (concat (or "\\(" "") (or primary-expression-keywords-string "") (or "\\|" "") (or "\\(" "") (or ambiguous-pre/postfix-string "") (or "\\)\\|\\(" "") (or ambiguous-prefix-non-postfix-string "") (or "\\)\\|" "") (or "\\((\\)" "") (or "\\)" "") (or "\\|" "") (or (c-lang-const c-symbol-start) "") (or "\\|" "") (or "\\.?[0-9]" "") (or "\\|" "") (or (c-make-keywords-re #f (or unambiguous-prefix-ops '())) "") (or "\\|" "") (or "\\s\"" "") (or (if (%c-true (memq 'gen-string-delim (or c-emacs-features '()))) "\\|\\s|" "") "")) per-++---match per-&*+--match #{per-(-match}#)))

;; c-primary-expr-regexp
(c-lang-defconst c-primary-expr-regexp
  t
  (car (c-lang-const c-primary-expr-regexp-details)))

;; c-primary-expr-regexp
(c-lang-defvar c-primary-expr-regexp (c-lang-const c-primary-expr-regexp))

;; c-per-++---match
(c-lang-defconst c-per-++---match
  t
  (cadr (c-lang-const c-primary-expr-regexp-details)))

;; c-per-++---match
(c-lang-defvar c-per-++---match (c-lang-const c-per-++---match))

;; c-per-&*+--match
(c-lang-defconst c-per-&*+--match
  t
  (car (cddr (c-lang-const c-primary-expr-regexp-details))))

;; c-per-&*+--match
(c-lang-defvar c-per-&*+--match (c-lang-const c-per-&*+--match))

;; c-per-\(-match
(c-lang-defconst #{c-per-(-match}#
  t
  (cadr (cddr (c-lang-const c-primary-expr-regexp-details))))

;; c-per-\(-match
(c-lang-defvar #{c-per-(-match}# (c-lang-const #{c-per-(-match}#))

;; c-decl-start-colon-kwd-re
(c-lang-defconst c-decl-start-colon-kwd-re
  "Regexp matching a keyword that is followed by a colon, where\n  the whole construct can precede a declaration.\n  E.g. \"public:\" in C++."
  t
  regexp-unmatchable
  c++
  (c-make-keywords-re #t (or (c-lang-const c-protection-kwds) '())))

;; c-decl-start-colon-kwd-re
(c-lang-defvar c-decl-start-colon-kwd-re (c-lang-const c-decl-start-colon-kwd-re))

;; c-decl-prefix-re
(c-lang-defconst c-decl-prefix-re
  "Regexp matching something that might precede a declaration, cast or\nlabel, such as the last token of a preceding statement or declaration.\nThis is used in the common situation where a declaration or cast\ndoesn't start with any specific token that can be searched for.\n\nThe regexp should not match bob; that is done implicitly.  It can't\nrequire a match longer than one token.  The end of the token is taken\nto be at the end of the first submatch, which is assumed to always\nmatch.  It's undefined whether identifier syntax (see\n`c-identifier-syntax-table') is in effect or not.  This regexp is\nassumed to be a superset of `c-label-prefix-re' if\n`c-recognize-colon-labels' is set.\n\nBesides this, `c-decl-start-kwds' is used to find declarations.\n\nNote: This variable together with `c-decl-start-re' and\n`c-decl-start-kwds' is only used to detect \"likely\"\ndeclaration/cast/label starts.  I.e. they might produce more matches\nbut should not miss anything (or else it's necessary to use text\nproperties - see the next note).  Wherever they match, the following\nconstruct is analyzed to see if it indeed is a declaration, cast or\nlabel.  That analysis is not cheap, so it's important that not too\nmany false matches are triggered.\n\nNote: If a declaration/cast/label start can't be detected with this\nvariable, it's necessary to use the `c-type' text property with the\nvalue `c-decl-end' on the last char of the last token preceding the\ndeclaration.  See the comment blurb at the start of cc-engine.el for\nmore info."
  t
  "\\([{}();,]+\\)"
  java
  "\\([{}(;,<]+\\)"
  c++
  "\\([{}();:,<]+\\)"
  objc
  (concat (or "\\([{}();,]+\\|" "") (or (c-make-keywords-re #f (or (c-lang-const c-protection-kwds) '())) "") (or "\\)" ""))
  pike
  "\\([{}()[;,]+\\)")

;; c-decl-prefix-re
(c-lang-defvar c-decl-prefix-re (c-lang-const c-decl-prefix-re))

;; c-decl-start-re
(c-lang-defconst c-decl-start-re
  "Regexp matching the start of any declaration, cast or label.\nIt's used on the token after the one `c-decl-prefix-re' matched.  This\nregexp should not try to match those constructs accurately as it's\nonly used as a sieve to avoid spending more time checking other\nconstructs."
  t
  (c-lang-const c-identifier-start))

;; c-decl-start-re
(c-lang-defvar c-decl-start-re (c-lang-const c-decl-start-re))

;; c-decl-prefix-or-start-re
(c-lang-defconst c-decl-prefix-or-start-re
  t
  (cond ((%c-true (if (%c-true (c-lang-const c-decl-start-kwds)) (c-lang-const c-anchored-hash-define-no-parens) #f)) (concat (or (c-lang-const c-decl-prefix-re) "") (or "\\|" "") (or (c-lang-const c-anchored-hash-define-no-parens) "") (or "\\|" "") (or (c-make-keywords-re #t (or (c-lang-const c-decl-start-kwds) '())) ""))) ((%c-true (c-lang-const c-decl-start-kwds)) (concat (or (c-lang-const c-decl-prefix-re) "") (or "\\|" "") (or (c-make-keywords-re #t (or (c-lang-const c-decl-start-kwds) '())) ""))) ((%c-true (c-lang-const c-anchored-hash-define-no-parens)) (concat (or (c-lang-const c-decl-prefix-re) "") (or "\\|" "") (or (c-lang-const c-anchored-hash-define-no-parens) ""))) (else (c-lang-const c-decl-prefix-re))))

;; c-decl-prefix-or-start-re
(c-lang-defvar c-decl-prefix-or-start-re (c-lang-const c-decl-prefix-or-start-re))

;; c-dposr-cpp-macro-depth
(c-lang-defconst c-dposr-cpp-macro-depth
  t
  (if (%c-true (c-lang-const c-anchored-hash-define-no-parens)) (+ (regexp-opt-depth (c-lang-const c-decl-prefix-re)) 1) #f))

;; c-dposr-cpp-macro-depth
(c-lang-defvar c-dposr-cpp-macro-depth (c-lang-const c-dposr-cpp-macro-depth))

;; c-cast-parens
(c-lang-defconst c-cast-parens
  t
  (c-filter-ops (or (c-lang-const c-operators) '()) '(prefix) "\\`\\s(\\'" (lambda (op) (elt (or op '()) 0))))

;; c-cast-parens
(c-lang-defvar c-cast-parens (c-lang-const c-cast-parens))

(c-lang-defconst c-block-prefix-disallowed-chars
  "List of characters which are disallowed in a syntactic symbol
when placed directly after a brace list starter in a block prefix."
  ;; The default derivation, with the `xlate' lambda written out: it
  ;; collects the characters of OP that have punctuation or paren syntax
  ;; (Emacs's `c-int-to-char' is the identity; here `aref' answers a code
  ;; point and the char is what the list below holds).
  t
  (c--set-difference
      (c-lang-const c-nonsymbol-token-char-list)
      (c-filter-ops
       (append (or (c-lang-const c-identifier-ops) '())
               (list (cons #f (or (c-lang-const c-after-id-concat-ops)
                                  '()))))
       #t #t
       (lambda (op)
         (let ((pos 0) (res '()))
           (let loop ()
             (if (string-match "\\(\\s.\\|\\s(\\|\\s)\\)" op pos)
                 (begin
                   (set! res (cons (c-int-to-char (aref op (match-beginning 1)))
                                   res))
                   (set! pos (match-end 0))
                   (loop))
                 #f))
           res)))
      ':test equal?)
  t
  (if (c-lang-const c-opt-cpp-prefix)
         (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                            '(#\#))
         (c-lang-const c-block-prefix-disallowed-chars))
  (c++ objc idl)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\:))
  (c++ java)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\,))
  (java pike)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\( #\)))
  (c c++ objc)
  (c--set-difference (c-lang-const c-block-prefix-disallowed-chars)
                     '(#\" #\')))

;; c-block-prefix-charset
(c-lang-defconst c-block-prefix-charset
  t
  (c-make-bare-char-alt (or (c-lang-const c-block-prefix-disallowed-chars) '()) #t))

;; c-block-prefix-charset
(c-lang-defvar c-block-prefix-charset (c-lang-const c-block-prefix-charset))

;; c-type-decl-prefix-keywords-key
(c-lang-defconst c-type-decl-prefix-keywords-key
  t
  (if (%c-true (or (and (%c-true (c-lang-const c-type-modifier-kwds)) (c-lang-const c-type-modifier-kwds)) (c-lang-const c-modifier-kwds))) (regexp-opt (or (c--delete-duplicates (or (append (or (c-lang-const c-type-modifier-kwds) '()) (or (c-lang-const c-modifier-kwds) '())) '()) ':test string-equal) '()) 'symbols) #f))

;; c-maybe-typeless-specifier-re
(c-lang-defconst c-maybe-typeless-specifier-re
  "Regexp matching keywords which might, but needn't, declare variables with\nno explicit type given, or nil in languages without such specifiers."
  t
  (c-lang-const c-opt-type-modifier-prefix-key)
  c
  (c-lang-const c-type-decl-prefix-keywords-key))

;; c-maybe-typeless-specifier-re
(c-lang-defvar c-maybe-typeless-specifier-re (c-lang-const c-maybe-typeless-specifier-re))

;; c-type-decl-prefix-key
(c-lang-defconst c-type-decl-prefix-key
  "Regexp matching any declarator operator that might precede the\nidentifier in a declaration, e.g. the \"*\" in \"char *argv\".  This\nregexp should match \"(\" if parentheses are valid in declarators.\nThe operator found is either the first submatch (if it is not a\nkeyword) or the second submatch (if it is)."
  t
  (if (%c-true (c-lang-const c-type-decl-prefix-keywords-key)) (concat (or "\\(\\`a\\`\\)\\|" "") (or (c-lang-const c-type-decl-prefix-keywords-key) "")) "\\`a\\`")
  (c objc)
  (concat (or "\\(" "") (or "[*(]" "") (or "\\)\\|" "") (or (c-lang-const c-type-decl-prefix-keywords-key) ""))
  c++
  (concat (or "\\(" "") (or "&&" "") (or "\\|" "") (or "\\.\\.\\." "") (or "\\|" "") (or "[*(&~]" "") (or "\\)\\|\\(" "") (or (c-lang-const c-type-decl-prefix-keywords-key) "") (or "\\|" "") (or (concat (or "\\(" "") (or (c-lang-const c-identifier-start) "") (or "\\)" "")) "") (or "\\)" "") (or "\\([^=_]\\|$\\)" ""))
  pike
  "\\(\\*\\)\\([^=]\\|$\\)")

;; c-type-decl-prefix-key
(c-lang-defvar c-type-decl-prefix-key (c-lang-const c-type-decl-prefix-key))

;; c-type-decl-operator-prefix-key
(c-lang-defconst c-type-decl-operator-prefix-key
  "Regexp matching any declarator operator which isn't a keyword,\nthat might precede the identifier in a declaration, e.g. the\n\"*\" in \"char *argv\".  The end of the first submatch is taken\nas the end of the operator.  Identifier syntax is in effect when\nthis is matched (see `c-identifier-syntax-table')."
  t
  regexp-unmatchable
  (c objc)
  (concat (or "\\(\\*\\)" "") (or "\\([^=]\\|$\\)" ""))
  c++
  (concat (or "\\(" "") (or "\\.\\.\\." "") (or "\\|" "") (or "\\*" "") (or "\\)" "") (or "\\([^=]\\|$\\)" ""))
  pike
  "\\(\\*\\)\\([^=]\\|$\\)")

;; c-type-decl-operator-prefix-key
(c-lang-defvar c-type-decl-operator-prefix-key (c-lang-const c-type-decl-operator-prefix-key))

;; c-type-decl-suffix-key
(c-lang-defconst c-type-decl-suffix-key
  "Regexp matching the declarator operators that might follow after the\nidentifier in a declaration, e.g. the \"[\" in \"char argv[]\".  This\nregexp should match \")\" if parentheses are valid in declarators.  If\nit matches an open paren of some kind, the type declaration check\ncontinues at the corresponding close paren, otherwise the end of the\nfirst submatch is taken as the end of the operator.  Identifier syntax\nis in effect when this is matched (see `c-identifier-syntax-table')."
  t
  (if (%c-true (c-lang-const c-type-modifier-kwds)) (concat (or "\\((\\|" "") (or (regexp-opt (or (c-lang-const c-type-modifier-kwds) '()) 'symbols) "") (or "\\)" "")) "\\((\\)")
  (c c++ objc)
  (concat (or "\\(" "") (or "[)[(]" "") (or (if (%c-true (c-lang-const c-type-modifier-kwds)) (concat (or "\\|" "") (or (regexp-opt (or (append (or (c-lang-const c-fun-name-substitute-kwds) '()) (or (c-lang-const c-type-modifier-kwds) '())) '()) 'symbols) "")) "") "") (or "\\)" ""))
  java
  "\\([[()]\\)"
  idl
  "\\([[(]\\)")

;; c-type-decl-suffix-key
(c-lang-defvar c-type-decl-suffix-key (c-lang-const c-type-decl-suffix-key))

;; c-after-suffixed-type-decl-key
(c-lang-defconst c-after-suffixed-type-decl-key
  "This regexp is matched after a declarator expression where\n`c-type-decl-suffix-key' has matched.  If it matches then the\nconstruct is taken as a declaration.  It's typically used to match the\nbeginning of a function body or whatever might occur after the\nfunction header in a function declaration or definition.  It's\nundefined whether identifier syntax (see `c-identifier-syntax-table')\nis in effect or not.\n\nNote that it's used in cases like after \"foo (bar)\" so it should\nonly match when it's certain that it's a declaration, e.g., \"{\" but\nnot \",\" or \";\"."
  t
  "{"
  t
  (if (%c-true (c-lang-const c-postfix-spec-kwds)) (concat (or (c-lang-const c-after-suffixed-type-decl-key) "") (or "\\|" "") (or (c-make-keywords-re #t (or (c-lang-const c-postfix-spec-kwds) '())) "")) (c-lang-const c-after-suffixed-type-decl-key))
  c++
  "[{:]")

;; c-after-suffixed-type-decl-key
(c-lang-defvar c-after-suffixed-type-decl-key (c-lang-const c-after-suffixed-type-decl-key))

;; c-after-suffixed-type-maybe-decl-key
(c-lang-defconst c-after-suffixed-type-maybe-decl-key
  t
  (concat (or "\\(" "") (or (c-lang-const c-after-suffixed-type-decl-key) "") (or "\\)" "") (or "\\|[;,]" "")))

;; c-after-suffixed-type-maybe-decl-key
(c-lang-defvar c-after-suffixed-type-maybe-decl-key (c-lang-const c-after-suffixed-type-maybe-decl-key))

;; c-opt-type-concat-key
(c-lang-defconst c-opt-type-concat-key
  "Regexp matching operators that concatenate types, e.g. the \"|\" in\n\"int|string\" in Pike.  The end of the first submatch is taken as the\nend of the operator.  nil in languages without such operators.  It's\nundefined whether identifier syntax (see `c-identifier-syntax-table')\nis in effect or not."
  t
  #f
  pike
  "\\([|.&]\\)\\($\\|[^|.&]\\)")

;; c-opt-type-concat-key
(c-lang-defvar c-opt-type-concat-key (c-lang-const c-opt-type-concat-key))

;; c-opt-type-suffix-key
(c-lang-defconst c-opt-type-suffix-key
  "Regexp matching operators that might follow after a type, or nil in\nlanguages that don't have such operators.  The end of the first\nsubmatch is taken as the end of the operator.  This should not match\nthings like C++ template arglists if `c-recognize-<>-arglists' is set.\nIt's undefined whether identifier syntax (see `c-identifier-syntax-table')\nis in effect or not."
  t
  #f
  (c c++ objc pike)
  "\\(\\.\\.\\.\\)"
  java
  (concat (or "\\(\\[" "") (or (c-lang-const c-simple-ws) "") (or "*\\]\\|\\.\\.\\.\\)" "")))

;; c-opt-type-suffix-key
(c-lang-defvar c-opt-type-suffix-key (c-lang-const c-opt-type-suffix-key))

(c-lang-defvar c-known-type-key
  ;; "Regexp matching the known type identifiers."
  ;;
  ;; Emacs's `(boundp (c-mode-symbol "font-lock-extra-types"))' guard is
  ;; cc-vars' registration of the variable's reader (see cc-defs'
  ;; `c-register-emacs-variable-reader!'); the `mapcar'/`delq nil' pairs
  ;; are written as the two collection loops they are.
  (let* ((extra-types (if (c-mode-var-boundp "font-lock-extra-types")
                          (c-mode-var "font-lock-extra-types")
                          '()))
         (regexp-strings
          (let loop ((rest extra-types) (out '()))
            (cond ((null? rest) (reverse out))
                  ((and (string? (car rest))
                        (string-match "[][.*+?^$\\\\]" (car rest)))
                   (loop (cdr rest) (cons (car rest) out)))
                  (else (loop (cdr rest) out)))))
         (plain-strings
          (let loop ((rest extra-types) (out '()))
            (cond ((null? rest) (reverse out))
                  ((and (string? (car rest))
                        (not (string-match "[][.*+?^$\\\\]" (car rest))))
                   (loop (cdr rest) (cons (car rest) out)))
                  (else (loop (cdr rest) out))))))
    (concat "\\_<\\("
            (c-concat-separated
             (append (list (c-make-keywords-re #f
                             (append (c-lang-const c-primitive-type-kwds)
                                     plain-strings)))
                     regexp-strings)
             "\\|")
            "\\)\\_>")))

;; c-special-brace-lists
(c-lang-defconst c-special-brace-lists
  "List of open- and close-chars that makes up a pike-style brace list,\ni.e., for a ([ ]) list there should be a cons (?\\[ . ?\\]) in this\nlist."
  t
  #f
  pike
  '((#\{ . #\}) (#\[ . #\]) (#\< . #\>)))

;; c-special-brace-lists
(c-lang-defvar c-special-brace-lists (c-lang-const c-special-brace-lists))

;; c-recognize-knr-p
(c-lang-defconst c-recognize-knr-p
  "Non-nil means K&R style argument declarations are valid."
  t
  #f
  c
  #t)

;; c-recognize-knr-p
(c-lang-defvar c-recognize-knr-p (c-lang-const c-recognize-knr-p))

;; c-pre-id-bracelist-kwds
(c-lang-defconst c-pre-id-bracelist-kwds
  "Keywords which, preceding an identifier and brace, signify a bracelist.\nThis is only used in c++-mode."
  t
  #f
  c++
  '("new" "throw"))

;; c-pre-id-bracelist-key
(c-lang-defconst c-pre-id-bracelist-key
  t
  (c-make-keywords-re #t (or (c-lang-const c-pre-id-bracelist-kwds) '())))

;; c-pre-id-bracelist-key
(c-lang-defvar c-pre-id-bracelist-key (c-lang-const c-pre-id-bracelist-key))

;; c-pre-brace-non-bracelist-key
(c-lang-defconst c-pre-brace-non-bracelist-key
  "A regexp matching tokens which, preceding a brace, make it a non-bracelist."
  t
  regexp-unmatchable
  c++
  "&&?\\(\\S.\\|$\\)")

;; c-pre-brace-non-bracelist-key
(c-lang-defvar c-pre-brace-non-bracelist-key (c-lang-const c-pre-brace-non-bracelist-key))

;; c-recognize-nameless-type-decls
(c-lang-defconst c-recognize-nameless-type-decls
  "Non-nil means a type may be used in an arglist without an identifier."
  t
  #f
  c
  #t)

;; c-recognize-nameless-type-decls
(c-lang-defvar c-recognize-nameless-type-decls (c-lang-const c-recognize-nameless-type-decls))

;; c-recognize-typeless-decls
(c-lang-defconst c-recognize-typeless-decls
  "Non-nil means function declarations without return type should be\nrecognized.  That can introduce an ambiguity with parenthesized macro\ncalls before a brace block.  This setting does not affect declarations\nthat are preceded by a declaration starting keyword, so\ne.g. `c-typeless-decl-kwds' may still be used when it's set to nil."
  t
  #f
  (c c++ objc java)
  #t)

;; c-recognize-typeless-decls
(c-lang-defvar c-recognize-typeless-decls (c-lang-const c-recognize-typeless-decls))

;; c-recognize-<>-arglists
(c-lang-defconst c-recognize-<>-arglists
  "Non-nil means C++ style template arglists should be handled.  More\nspecifically, this means a comma separated list of types or\nexpressions surrounded by \"<\" and \">\".  It's always preceded by an\nidentifier or one of the keywords on `c-<>-type-kwds' or\n`c-<>-arglist-kwds'.  If there's an identifier before then the whole\nexpression is considered to be a type."
  t
  (or (and (%c-true (pair? (c-lang-const c-<>-type-kwds))) (pair? (c-lang-const c-<>-type-kwds))) (pair? (c-lang-const c-<>-arglist-kwds)))
  java
  #t)

;; c-recognize-<>-arglists
(c-lang-defvar c-recognize-<>-arglists (c-lang-const c-recognize-<>-arglists))

;; c-<>-notable-chars-re
(c-lang-defconst c-<>-notable-chars-re
  "A regexp matching any single character notable inside a <...> construct.\nThis must include \"<\" and \">\", and should include \",\", and\nany character which cannot be valid inside such a construct.\nThis is used in `c-forward-<>-arglist-recur' to try to detect\nsequences of tokens which cannot be a template/generic construct.\nWhen \"(\" is present, that defun will attempt to parse a\nparenthesized expression inside the template.  When \")\" is\npresent it will treat an unbalanced closing paren as a sign of\nthe invalidity of the putative template construct."
  t
  "[<;{},|+&>)-]"
  c++
  "[<;{},>()]")

;; c-<>-notable-chars-re
(c-lang-defvar c-<>-notable-chars-re (c-lang-const c-<>-notable-chars-re))

;; c-enum-clause-introduction-re
(c-lang-defconst c-enum-clause-introduction-re
  t
  (if (%c-true (c-lang-const c-enum-list-kwds)) (concat (or (c-make-keywords-re #t (or (c-lang-const c-enum-list-kwds) '())) "") (or "[^][{};/#=]*" "") (or "{" "")) regexp-unmatchable))

;; c-enum-clause-introduction-re
(c-lang-defvar c-enum-clause-introduction-re (c-lang-const c-enum-clause-introduction-re))

;; c-enums-contain-decls
(c-lang-defconst c-enums-contain-decls
  "Non-nil means that an enum structure can contain declarations."
  t
  #f
  java
  #t)

;; c-enums-contain-decls
(c-lang-defvar c-enums-contain-decls (c-lang-const c-enums-contain-decls))

;; c-recognize-paren-inits
(c-lang-defconst c-recognize-paren-inits
  "Non-nil means that parenthesis style initializers exist,\ni.e. constructs like\n\nFoo bar (gnu);\n\nin addition to the more classic\n\nFoo bar = gnu;"
  t
  #f
  c++
  #t)

;; c-recognize-paren-inits
(c-lang-defvar c-recognize-paren-inits (c-lang-const c-recognize-paren-inits))

;; c-recognize-bare-brace-inits
(c-lang-defconst c-recognize-bare-brace-inits
  "Non-nil means that brace initializers without \"=\" exist,\ni.e. constructs like\n\nint foo[] {1, 2, 3};\n\nin addition to the more classic\n\nint foo[] = {1, 2, 3};"
  t
  #f
  c++
  #t)

;; c-recognize-bare-brace-inits
(c-lang-defvar c-recognize-bare-brace-inits (c-lang-const c-recognize-bare-brace-inits))

;; c-recognize-paren-inexpr-blocks
(c-lang-defconst c-recognize-paren-inexpr-blocks
  "Non-nil to recognize gcc style in-expression blocks,\ni.e. compound statements surrounded by parentheses inside expressions."
  t
  #f
  (c c++)
  #t)

;; c-recognize-paren-inexpr-blocks
(c-lang-defvar c-recognize-paren-inexpr-blocks (c-lang-const c-recognize-paren-inexpr-blocks))

;; c-opt-<>-arglist-start
(c-lang-defconst c-opt-<>-arglist-start
  t
  (if (%c-true (c-lang-const c-recognize-<>-arglists)) (concat (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" "") (or (c-lang-const c-syntactic-ws) "") (or "<" "")) #f))

;; c-opt-<>-arglist-start
(c-lang-defvar c-opt-<>-arglist-start (c-lang-const c-opt-<>-arglist-start))

;; c-opt-<>-arglist-start-in-paren
(c-lang-defconst c-opt-<>-arglist-start-in-paren
  t
  (if (%c-true (c-lang-const c-opt-<>-arglist-start)) (concat (or "\\(" "") (or (c-lang-const c-opt-<>-arglist-start) "") (or "\\)\\|\\s)" "")) #f))

;; c-opt-<>-arglist-start-in-paren
(c-lang-defvar c-opt-<>-arglist-start-in-paren (c-lang-const c-opt-<>-arglist-start-in-paren))

;; c-opt-postfix-decl-spec-key
(c-lang-defconst c-opt-postfix-decl-spec-key
  t
  #f
  c++
  (concat (or ":?" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "\\(virtual" "") (or (c-lang-const c-simple-ws) "") (or "+\\)?\\(" "") (or (c-make-keywords-re #f (or (c-lang-const c-protection-kwds) '())) "") (or "\\)" "") (or (c-lang-const c-simple-ws) "") (or "+" "") (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" ""))
  java
  (c-make-keywords-re #t (or (c-lang-const c-postfix-spec-kwds) '())))

;; c-opt-postfix-decl-spec-key
(c-lang-defvar c-opt-postfix-decl-spec-key (c-lang-const c-opt-postfix-decl-spec-key))

;; c-recognize-colon-labels
(c-lang-defconst c-recognize-colon-labels
  "Non-nil if generic labels ending with \":\" should be recognized.\nThat includes labels in code and access keys in classes.  This does\nnot apply to labels recognized by `c-label-kwds' and\n`c-opt-extra-label-key'."
  t
  #f
  (c c++ objc java pike)
  #t)

;; c-recognize-colon-labels
(c-lang-defvar c-recognize-colon-labels (c-lang-const c-recognize-colon-labels))

;; c-label-prefix-re
(c-lang-defconst c-label-prefix-re
  "Regexp like `c-decl-prefix-re' that matches any token that can precede\na generic colon label.  Not used if `c-recognize-colon-labels' is\nnil."
  t
  "\\([{};]+\\)")

;; c-label-prefix-re
(c-lang-defvar c-label-prefix-re (c-lang-const c-label-prefix-re))

;; c-nonlabel-token-key
(c-lang-defconst c-nonlabel-token-key
  "Regexp matching things that can't occur in generic colon labels,\nneither in a statement nor in a declaration context.  The regexp is\ntested at the beginning of every sexp in a suspected label,\ni.e. before \":\".  Only used if `c-recognize-colon-labels' is set."
  t
  (concat (or (c-make-keywords-re #t (or (c--set-difference (or (c-lang-const c-keywords) '()) (or (append (or (c-lang-const c-label-kwds) '()) (or (c-lang-const c-protection-kwds) '())) '()) ':test string-equal) '())) ""))
  (c objc pike idl)
  (concat (or "\"\\|" "") (or (c-lang-const c-nonlabel-token-key) ""))
  c++
  (concat (or "\\s(\\|\"\\|" "") (or (c-lang-const c-nonlabel-token-key) "")))

;; c-nonlabel-token-key
(c-lang-defvar c-nonlabel-token-key (c-lang-const c-nonlabel-token-key))

;; c-nonlabel-nonparen-token-key
(c-lang-defconst c-nonlabel-nonparen-token-key
  "Regexp matching things that can't occur in generic colon labels,\nneither in a statement nor in a declaration context, with the\nexception of an open parenthesis.  The regexp is tested at the\nbeginning of every sexp in a suspected label, i.e. before \":\".\nOnly used if `c-recognize-colon-labels' is set."
  t
  (concat (or (c-make-keywords-re #t (or (c--set-difference (or (c-lang-const c-keywords) '()) (or (append (or (c-lang-const c-label-kwds) '()) (or (c-lang-const c-protection-kwds) '())) '()) ':test string-equal) '())) ""))
  (c objc pike idl)
  (concat (or "\"\\|" "") (or (c-lang-const c-nonlabel-nonparen-token-key) ""))
  c++
  (concat (or "[{[]\\|\"\\|" "") (or (c-lang-const c-nonlabel-nonparen-token-key) "")))

;; c-nonlabel-nonparen-token-key
(c-lang-defvar c-nonlabel-nonparen-token-key (c-lang-const c-nonlabel-nonparen-token-key))

;; c-nonlabel-token-2-key
(c-lang-defconst c-nonlabel-token-2-key
  "Regexp matching things that can't occur two symbols before a colon in\na label construct.  This catches C++'s inheritance construct \"class foo\n: bar\".  Only used if `c-recognize-colon-labels' is set."
  t
  regexp-unmatchable
  c++
  (c-make-keywords-re #t '("class")))

;; c-nonlabel-token-2-key
(c-lang-defvar c-nonlabel-token-2-key (c-lang-const c-nonlabel-token-2-key))

;; c-opt-extra-label-key
(c-lang-defconst c-opt-extra-label-key
  "Optional regexp matching labels.\nNormally, labels are detected according to `c-nonlabel-token-key' and\n`c-decl-prefix-re'.  This regexp can be used if there are additional\nlabels that aren't recognized that way."
  t
  #f
  objc
  (c-make-keywords-re #t (or (c-lang-const c-protection-kwds) '())))

;; c-opt-extra-label-key
(c-lang-defvar c-opt-extra-label-key (c-lang-const c-opt-extra-label-key))

;; c-opt-friend-key
(c-lang-defconst c-opt-friend-key
  t
  #f
  c++
  (concat (or "friend" "") (or (c-lang-const c-simple-ws) "") (or "+" "") (or "\\|" "") (or (concat (or "template" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "<.+>" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "friend" "") (or (c-lang-const c-simple-ws) "") (or "+" "")) "")))

;; c-opt-friend-key
(c-lang-defvar c-opt-friend-key (c-lang-const c-opt-friend-key))

;; c-opt-method-key
(c-lang-defconst c-opt-method-key
  t
  #f
  objc
  (concat (or "^\\s *" "") (or "\\([+-]\\)" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or (concat (or "\\(" "") (or "([^)]*)" "") (or (c-lang-const c-simple-ws) "") (or "*" "") (or "\\)?" "")) "") (or "\\(" "") (or (c-lang-const c-symbol-key) "") (or "\\)" "")))

;; c-opt-method-key
(c-lang-defvar c-opt-method-key (c-lang-const c-opt-method-key))

;; c-type-decl-end-used
(c-lang-defconst c-type-decl-end-used
  t
  (or (and (%c-true (c-lang-const c-recognize-colon-labels)) (c-lang-const c-recognize-colon-labels)) (if (%c-true (c-lang-const c-label-kwds)) #t #f))
  objc
  #t)

;; c-type-decl-end-used
(c-lang-defvar c-type-decl-end-used (c-lang-const c-type-decl-end-used))

;; c-maybe-decl-faces
(c-lang-defconst c-maybe-decl-faces
  "List of faces that might be put at the start of a type when\n`c-font-lock-declarations' runs.  This must be evaluated (with `eval') at\nruntime to get the actual list of faces.  This ensures that face name\naliases in Emacs are resolved."
  t
  '(list #f font-lock-type-face c-reference-face-name font-lock-keyword-face)
  java
  (append (or (c-lang-const c-maybe-decl-faces) '()) '(font-lock-preprocessor-face)))

;; c-maybe-decl-faces
(c-lang-defvar c-maybe-decl-faces (c-lang-const c-maybe-decl-faces))
    ))
