(define-library (schemacs editor cc-langs)
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
                  syntax with-syntax syntax-case syntax->datum datum->syntax)
    (only (schemacs editor buffer) current-buffer set-buffer-local-value!
          buffer-local-value)
    (only (schemacs editor cc-defs) c-lang-const c-lang-defconst
          c-lang-constant-documentation c-literal-datum?
          *c-buffer-is-cc-mode*))
  (export c-lang-defvar c-lang-setvar c-make-emacs-variables-local
          c-make-init-lang-vars-fun c-init-language-vars
          c-lang-set-local! c-lang-var-value)

  (begin

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
                (else (loop (cdr l) (cons (car l) acc)))))))

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
    (define (%c-lang-defvar-doc var val)
      ;; The docstring, or the constant's when VAL is a plain
      ;; `(c-lang-const var)' - Emacs's special case.
      (if (and (pair? val)
               (eq? (car val) 'c-lang-const)
               (eq? (cadr val) var)
               (null? (cddr val)))
          (c-lang-constant-documentation var)
          #f))

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
                     (if (c-literal-datum? value)
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

    ))
