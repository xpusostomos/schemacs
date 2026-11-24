(define-library (schemacs core pcase)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/pcase.el': the
  ;; ML-style pattern-matching macro and the binding macros built on it
  ;; (`pcase-let*`, `pcase-let`, `pcase-dolist`, `pcase-lambda`,
  ;; `pcase-setq`, `pcase-exhaustive`).
  ;;
  ;; **The pattern language is Emacs's**: `_` and `t` match anything; a
  ;; symbol binds and a repeated one compares with `eql` (here `eqv?`);
  ;; numbers, strings, characters and keywords match themselves; a
  ;; quoted value matches with `equal`; `(pred F)`, `(pred (not F))`,
  ;; `(guard E)`, `(app F PAT)`, `(let PAT E)`, `(and PAT...)`,
  ;; `(or PAT...)` and `(not PAT)` are Emacs's; and the backquote
  ;; pattern is written with Scheme's own quasiquote syntax, whose
  ;; `unquote` is Emacs's `,`. `,@` is unsupported, as it is in Emacs.
  ;;
  ;; **The engine is a sequential pattern walker, not pcase.el's
  ;; decision-tree compiler.** pcase.el compiles a set of patterns into
  ;; a tree, reordering and sharing tests through `pcase--split-*` and
  ;; the `pcase--subtype-bitsets` mutual-exclusion analysis. That is an
  ;; optimisation with no effect on which clause matches or what is
  ;; bound; it changes the shape and size of the expansion. This
  ;; library generates one match per clause instead; DEPARTURES.md
  ;; names it. The observable semantics are Emacs's, including the
  ;; body's value and `nil` when no clause matches.
  ;;
  ;; **`pcase-defmacro` expanders take pattern *data* and return
  ;; pattern data**, as in Emacs (whose expander body is ordinary Lisp
  ;; building a list). A pattern argument that names a *local* variable
  ;; inside an expression keeps its name but not its lexical identity,
  ;; because a pattern is converted to data; a `pred`/`guard`/`app`
  ;; expression written directly in a pattern is kept as syntax and has
  ;; no such limitation.

  (import
    (scheme base)
    (only (guile)
          datum->syntax gensym syntax syntax->datum syntax-case)
    (only (schemacs symbol-props) get put))

  (export pcase pcase-exhaustive pcase-lambda
          pcase-let pcase-let* pcase-let*-strict
          pcase-dolist pcase-setq pcase-defmacro
          pcase--macroexpand)

  (begin

    ;;----------------------------------------------------------------
    ;; Syntax walkers. Guile does not export `syntax-car' and friends
    ;; from `(guile)'; `syntax-case' destructuring gives them.
    ;;----------------------------------------------------------------

    (define (%syn-pair? s)
      (syntax-case s () ((_ . _) #t) (_ #f)))
    (define (%syn-null? s)
      (syntax-case s () (() #t) (_ #f)))
    (define (%syn-car s)
      (syntax-case s () ((a . _) (syntax a)) (_ #f)))
    (define (%syn-cdr s)
      (syntax-case s () ((_ . d) (syntax d)) (_ #f)))
    (define (%syn-list s)
      ;; A syntax object that is a proper list, as a list of syntax
      ;; objects.
      (let loop ((s s) (out '()))
        (if (%syn-pair? s)
            (loop (%syn-cdr s) (cons (%syn-car s) out))
            (reverse out))))
    (define (%syn-head s)
      (let ((d (syntax->datum s)))
        (and (pair? d) (car d))))

    (define (keyword-symbol? d)
      (and (symbol? d)
           (< 1 (string-length (symbol->string d)))
           (char=? #\: (string-ref (symbol->string d) 0))))

    (define (fresh-at stx name)
      (datum->syntax stx (gensym name)))

    (define (introduce-tree tree)
      ;; Turn the plain symbols of a generated form into identifiers
      ;; resolved at the use site. **A caller's own syntax objects are
      ;; left exactly as they are**: `datum->syntax' over a whole tree
      ;; would re-wrap them and lose the lexical context that makes a
      ;; body's free variables work. `quote' is not descended into, so
      ;; quoted data stays data.
      ;;--------------------------------------------------------------
      (cond
       ((symbol? tree) (datum->syntax #f tree))
       ((pair? tree)
        (if (eq? (car tree) 'quote)
            (datum->syntax #f (cons 'quote (cdr tree)))
            (cons (introduce-tree (car tree))
                  (introduce-tree (cdr tree)))))
       (else tree)))

    ;;----------------------------------------------------------------
    ;; The expansion state
    ;;----------------------------------------------------------------

    (define-record-type <pcase-state>
      (make-pcase-state stx fail assign? result lenient?)
      pcase-state?
      (stx pcase-state-stx)
      (fail pcase-state-fail)
      (assign? pcase-state-assign?)
      (result pcase-state-result)
      (lenient? pcase-state-lenient?))

    (define (%fresh st name)
      (fresh-at (pcase-state-stx st) name))

    (define (%fail st) (pcase-state-fail st))

    (define (%bind st name-syn val env k)
      ;; Bind pattern variable NAME-SYN to the value expression VAL,
      ;; then run K. NAME-SYN is the caller's own identifier for the
      ;; variable (a plain symbol in the datum would be macro-introduced
      ;; and invisible to the body). In assignment mode (`pcase-setq')
      ;; the binding is a `set!` of the surrounding variable instead.
      ;;--------------------------------------------------------------
      (let ((name (syntax->datum name-syn)))
        (if (pcase-state-assign? st)
            (list 'begin
                  (list 'set! name-syn val)
                  (list 'set! (pcase-state-result st) name-syn)
                  (k (cons (cons name name-syn) env)))
            (list 'let (list (list name-syn val))
                  (k (cons (cons name name-syn) env))))))

    ;;----------------------------------------------------------------
    ;; Literals
    ;;----------------------------------------------------------------

    (define (%literal-code datum val)
      (cond
       ((null? datum) (list 'null? val))
       ((boolean? datum) (if datum (list 'eq? val #t) (list 'not val)))
       ((or (number? datum) (char? datum)) (list 'eqv? val datum))
       ((string? datum) (list 'equal? val datum))
       ((symbol? datum) (list 'eq? val (list 'quote datum)))
       (else (list 'equal? val (list 'quote datum)))))

    (define (%literal-match st datum val k env)
      (if (pcase-state-lenient? st)
          (k env)
          (list 'if (%literal-code datum val) (k env) (%fail st))))

    ;;----------------------------------------------------------------
    ;; User pattern macros (`pcase-defmacro')
    ;;----------------------------------------------------------------

    (define (pcase--macroexpand pat)
      ;; Expand user-defined pattern macros until the head is not one.
      ;; PAT is a datum. Emacs's built-in sugar is handled by the
      ;; matcher itself, so only registered expanders are looked at.
      ;;--------------------------------------------------------------
      (let ((head (and (pair? pat) (car pat))))
        (if (and (symbol? head) (get head 'pcase-macroexpander))
            (pcase--macroexpand
             (apply (get head 'pcase-macroexpander) (cdr pat)))
            pat)))

    (define (register-pattern-macro! name procedure)
      (put name 'pcase-macroexpander procedure))

    ;;----------------------------------------------------------------
    ;; The matcher
    ;;
    ;; (%match ST PAT VAL ENV K) -> code
    ;;----------------------------------------------------------------

    (define (%match st pat val env k)
      (let ((datum (syntax->datum pat)))
        (cond
         ;;----------------------------------------------------------
         ;; Atoms
         ;;----------------------------------------------------------
         ((symbol? datum)
          (cond
           ((or (eq? datum '_) (eq? datum 't)) (k env))
           ((keyword-symbol? datum) (%literal-match st datum val k env))
           ((assq datum env)
            ;; Non-linear pattern: Emacs compares with `eql'. A
            ;; non-strict `pcase-let*' ignores the comparison.
            (if (pcase-state-lenient? st)
                (k env)
                (list 'if (list 'eqv? val (cdr (assq datum env)))
                      (k env) (%fail st))))
           (else (%bind st pat val env k))))
         ((or (number? datum) (string? datum) (char? datum) (boolean? datum))
          (%literal-match st datum val k env))
         ;;----------------------------------------------------------
         ;; Compound patterns
         ;;----------------------------------------------------------
         ((%syn-pair? pat)
          (let ((head (%syn-head pat))
                (args (%syn-list (%syn-cdr pat))))
            (cond
             ((eq? head 'quote)
              (%literal-match st (syntax->datum (%syn-car (%syn-cdr pat)))
                              val k env))
             ((eq? head 'quasiquote)
              (%qq-match st (%syn-car (%syn-cdr pat)) val env k))
             ((eq? head 'pred)
              (let ((fn (%syn-car args)))
                (if (pcase-state-lenient? st)
                    (k env)
                    (if (and (eq? (%syn-head fn) 'not)
                             (= 2 (length (%syn-list fn))))
                        (list 'if
                              (list (%syn-car (%syn-list (%syn-cdr fn))) val)
                              (%fail st) (k env))
                        (list 'if (list fn val) (k env) (%fail st))))))
             ((eq? head 'guard)
              (if (pcase-state-lenient? st)
                  (k env)
                  (list 'if (%syn-car args) (k env) (%fail st))))
             ((eq? head 'app)
              (let ((tmp (%fresh st "pcase-app"))
                    (fn (%syn-car args))
                    (sub (%syn-car (%syn-cdr args))))
                (list 'let (list (list tmp (list fn val)))
                      (%match st sub tmp env k))))
             ((eq? head 'let)
              (let ((tmp (%fresh st "pcase-let"))
                    (sub (%syn-car args))
                    (exp (%syn-car (%syn-cdr args))))
                (list 'let (list (list tmp exp))
                      (%match st sub tmp env k))))
             ((eq? head 'and) (%match-and st args val env k))
             ((eq? head 'or) (%match-or st args val env k))
             ((eq? head 'not)
              (let* ((code (%match st (%syn-car args) val env
                                   (lambda (e) #t)))
                     (r (%fresh st "pcase-not")))
                (list 'let (list (list r code))
                      (list 'if (list 'eq? r (%fail st))
                            (k env) (%fail st)))))
             ((and (symbol? head) (get head 'pcase-macroexpander))
              (%match st (datum->syntax (pcase-state-stx st)
                                        (pcase--macroexpand datum))
                      val env k))
             (else (error "Unknown pcase pattern: ~s" datum)))))
         (else (error "Unknown pcase pattern: ~s" datum)))))

    (define (%match-and st pats val env k)
      (if (null? pats)
          (k env)
          (%match st (car pats) val env
                  (lambda (env1)
                    (%match-and st (cdr pats) val env1 k)))))

    (define (%match-or st pats val env k)
      ;; Each alternative compiles the body (its bindings differ); a
      ;; failure is the state's failure object, so a body answering
      ;; `#f' is still a success.
      ;;--------------------------------------------------------------
      (if (null? pats)
          (%fail st)
          (let ((r (%fresh st "pcase-or"))
                (first (%match st (car pats) val env k)))
            (if (null? (cdr pats))
                first
                (list 'let (list (list r first))
                      (list 'if (list 'eq? r (%fail st))
                            (%match-or st (cdr pats) val env k)
                            r))))))

    ;;----------------------------------------------------------------
    ;; The backquote pattern (Scheme's quasiquote)
    ;;----------------------------------------------------------------

    (define (%qq-unquote? s)
      (let ((d (syntax->datum s)))
        (and (pair? d) (eq? (car d) 'unquote))))
    (define (%qq-splicing? s)
      (let ((d (syntax->datum s)))
        (and (pair? d) (eq? (car d) 'unquote-splicing))))

    (define (%qq-match st qpat val env k)
      (cond
       ((%qq-unquote? qpat)
        (%match st (%syn-car (%syn-cdr qpat)) val env k))
       ((%qq-splicing? qpat)
        (error "Unsupported QPAT: ~s" (syntax->datum qpat)))
       ((vector? (syntax->datum qpat))
        (%qq-vector-match st qpat val env k))
       ((%syn-pair? qpat)
        (if (eq? (%syn-head qpat) 'quasiquote)
            (error "Nested ` are not supported in Pcase patterns")
            (if (pcase-state-lenient? st)
                ;; Destructure without the shape test: a missing car or
                ;; cdr is nil, which is what Emacs's non-strict
                ;; `pcase-let*' binds.
                (let ((tmp (%fresh st "pcase-qq")))
                  (list 'let (list (list tmp val))
                        (%qq-match st (%syn-car qpat)
                                   (list 'if (list 'pair? tmp)
                                         (list 'car tmp) #f) env
                                   (lambda (env1)
                                     (%qq-match st (%syn-cdr qpat)
                                                (list 'if (list 'pair? tmp)
                                                      (list 'cdr tmp) #f)
                                                env1 k)))))
                (let ((tmp (%fresh st "pcase-qq")))
                  (list 'let (list (list tmp val))
                        (list 'if (list 'pair? tmp)
                              (%qq-match st (%syn-car qpat) (list 'car tmp) env
                                         (lambda (env1)
                                           (%qq-match st (%syn-cdr qpat)
                                                      (list 'cdr tmp) env1 k)))
                              (%fail st)))))))
       (else
        ;; Atoms inside a template are literals.
        (%literal-match st (syntax->datum qpat) val k env))))

    (define (%qq-vector-match st qpat val env k)
      (let* ((data (syntax->datum qpat))
             (n (vector-length data))
             (elements (map (lambda (d)
                              (datum->syntax (pcase-state-stx st) d))
                            (vector->list data)))
             (tmp (%fresh st "pcase-vec")))
        (list 'let
              (list (list tmp val))
              (list 'if
                    (if (pcase-state-lenient? st)
                        #t
                        (list 'and
                              (list 'vector? tmp)
                              (list '= (list 'vector-length tmp) n)))
                    (let loop ((i 0) (els elements) (env env))
                      (if (null? els)
                          (k env)
                          (%qq-match st (car els) (list 'vector-ref tmp i) env
                                     (lambda (env1)
                                       (loop (+ i 1) (cdr els) env1)))))
                    (%fail st)))))

    ;;----------------------------------------------------------------
    ;; The top-level expansion
    ;;----------------------------------------------------------------

    (define (%body-code body-items)
      (cond ((null? body-items) #f)
            ((null? (cdr body-items)) (car body-items))
            (else (cons 'begin body-items))))

    (define (%pcase-expand-form stx exp clauses)
      ;; EXP is syntax; CLAUSES is a list of (PAT . BODY-ITEMS), whose
      ;; bodies are syntax or data. Returns a syntax object.
      ;;--------------------------------------------------------------
      (let* ((fail (fresh-at stx "pcase-fail"))
             (st (make-pcase-state stx fail #f #f #f))
             (v (fresh-at stx "pcase-val")))
        (let loop ((clauses (reverse clauses)) (acc #f))
          (if (null? clauses)
              (introduce-tree
               (list 'let
                     (list (list v exp)
                           (list fail
                                 (list 'list (list 'quote 'pcase-fail))))
                     acc))
              (let* ((clause (car clauses))
                     (pat (car clause))
                     (bodies (cdr clause))
                     (r (fresh-at stx "pcase-r"))
                     (code (%match st pat v '()
                                   (lambda (env) (%body-code bodies)))))
                (loop (cdr clauses)
                      (list 'let (list (list r code))
                            (list 'if (list 'eq? r fail) acc r))))))))

    (define-syntax pcase
      (lambda (stx)
        (syntax-case stx ()
          ((_ exp clause ...)
           (%pcase-expand-form
            stx (syntax exp)
            (map (lambda (c)
                   (cons (%syn-car c) (%syn-list (%syn-cdr c))))
                 (%syn-list (syntax (clause ...)))))))))

    (define-syntax pcase-exhaustive
      (lambda (stx)
        (syntax-case stx ()
          ((_ exp clause ...)
           (let* ((x (fresh-at stx "pcase-x"))
                  (clauses
                   (map (lambda (c)
                          (cons (%syn-car c) (%syn-list (%syn-cdr c))))
                        (%syn-list (syntax (clause ...)))))
                  (clauses
                   (append clauses
                           (list (cons x
                                       (list (list 'error
                                                   "No clause matching `~s'"
                                                   x)))))))
             (%pcase-expand-form stx (syntax exp) clauses))))))

    ;;----------------------------------------------------------------
    ;; `pcase-let*' and its relatives
    ;;----------------------------------------------------------------

    (define (trivial-pat? patsyn)
      (let ((d (syntax->datum patsyn)))
        (and (symbol? d)
             (not (memq d '(_ t)))
             (not (keyword-symbol? d)))))

    (define (%pcase-let*-expand stx bindings body strict?)
      ;; BINDINGS is a list of (PAT EXP) whose members are syntax (EXP
      ;; may be #f, Emacs's missing form).
      ;;--------------------------------------------------------------
      (let loop ((bindings bindings))
        (if (null? bindings)
            (%body-code body)
            (let* ((binding (car bindings))
                   (pat (car binding))
                   (exp (cadr binding)))
              (if (trivial-pat? pat)
                  (list 'let (list (list pat exp))
                        (loop (cdr bindings)))
                  (let* ((fail (fresh-at stx "pcase-fail"))
                         (st (make-pcase-state stx fail #f #f
                                               (not strict?)))
                         (v (fresh-at stx "pcase-val"))
                         (r (fresh-at stx "pcase-r"))
                         (code (%match st pat v '()
                                       (lambda (env) (loop (cdr bindings))))))
                    (list 'let
                          (list (list v exp)
                                (list fail
                                      (list 'list (list 'quote 'pcase-fail))))
                          (list 'let (list (list r code))
                                (list 'if
                                      (list 'eq? r fail)
                                      (if strict?
                                          (list 'error
                                                "`pcase' pattern does not match value: ~s ~s"
                                                (list 'quote (syntax->datum pat))
                                                v)
                                          #f)
                                      r)))))))))

    (define (bindings-of bs)
      (map (lambda (b)
             (list (%syn-car b)
                   (if (%syn-pair? (%syn-cdr b))
                       (%syn-car (%syn-cdr b))
                       #f)))
           bs))

    (define-syntax pcase-let*
      (lambda (stx)
        (syntax-case stx ()
          ((_ bindings body ...)
           (introduce-tree
            (%pcase-let*-expand
             stx
             (bindings-of (%syn-list (syntax bindings)))
             (%syn-list (syntax (body ...)))
             #f))))))

    (define-syntax pcase-let*-strict
      (lambda (stx)
        (syntax-case stx ()
          ((_ bindings body ...)
           (introduce-tree
            (%pcase-let*-expand
             stx
             (bindings-of (%syn-list (syntax bindings)))
             (%syn-list (syntax (body ...)))
             #t))))))

    (define-syntax pcase-let
      (lambda (stx)
        (syntax-case stx ()
          ((_ bindings body ...)
           (let* ((bs (bindings-of (%syn-list (syntax bindings))))
                  (body (%syn-list (syntax (body ...)))))
             (if (null? (cdr bs))
                 (introduce-tree (%pcase-let*-expand stx bs body #f))
                 (let loop ((bs bs) (lets '()) (matches '()))
                   (if (null? bs)
                       (introduce-tree
                        (list 'let
                              (reverse lets)
                              (%pcase-let*-expand
                               stx (reverse matches) body #f)))
                       (let* ((b (car bs))
                              (pat (car b))
                              (exp (cadr b)))
                         (cond
                          ((memq (syntax->datum pat) '(_ t))
                           (loop (cdr bs)
                                 (cons (list (fresh-at stx "pcase-let") exp)
                                       lets)
                                 matches))
                          ((trivial-pat? pat)
                           (loop (cdr bs)
                                 (cons (list pat exp) lets)
                                 matches))
                          (else
                           (let ((tmp (fresh-at stx "pcase-let")))
                             (loop (cdr bs)
                                   (cons (list tmp exp) lets)
                                   (cons (list pat tmp) matches))))))))))))))

    (define-syntax pcase-dolist
      (lambda (stx)
        (syntax-case stx ()
          ((_ (pat lst) body ...)
           (let ((body (%syn-list (syntax (body ...)))))
             (if (trivial-pat? (syntax pat))
                 (introduce-tree
                  (list 'begin
                        (list 'for-each
                              (list 'lambda (list (syntax pat))
                                    (%body-code body))
                              (syntax lst))
                        #f))
                 (let ((tmp (fresh-at stx "pcase-x")))
                   (introduce-tree
                    (list 'begin
                          (list 'for-each
                                (list 'lambda (list tmp)
                                      (%pcase-let*-expand
                                       stx
                                       (list (list (syntax pat) tmp))
                                       body #f))
                                (syntax lst))
                          #f)))))))))

    (define (%lambda-split stx ll)
      ;; Split a lambda list into parameters and pcase-let* bindings,
      ;; preserving a dotted rest parameter.
      ;;--------------------------------------------------------------
      (let loop ((ps ll) (args '()) (binds '()))
        (cond
         ((%syn-null? ps)
          (list (reverse args) (reverse binds)))
         ((%syn-pair? ps)
          (let ((p (%syn-car ps)))
            (if (symbol? (syntax->datum p))
                (loop (%syn-cdr ps) (cons p args) binds)
                (let ((tmp (fresh-at stx "pcase-arg")))
                  (loop (%syn-cdr ps) (cons tmp args)
                        (cons (list p tmp) binds))))))
         (else
          (let ((tail (syntax->datum ps)))
            (if (symbol? tail)
                (list (append (reverse args) (datum->syntax stx tail))
                      (reverse binds))
                (error "Unsupported pcase-lambda parameter list")))))))

    (define-syntax pcase-lambda
      (lambda (stx)
        (syntax-case stx ()
          ((_ lambda-list body ...)
           (let* ((body (%syn-list (syntax (body ...))))
                  (split (%lambda-split stx (syntax lambda-list)))
                  (args (car split))
                  (bindings (cadr split)))
             (introduce-tree
              (list 'lambda args
                    (if (null? bindings)
                        (%body-code body)
                        (%pcase-let*-expand stx bindings body #f)))))))))

    (define (%pcase-setq-one stx pat val)
      (let ((d (syntax->datum pat)))
        (if (and (symbol? d) (not (memq d '(_ t)))
                 (not (keyword-symbol? d)))
            (list 'begin (list 'set! pat val) pat)
            (let* ((fail (fresh-at stx "pcase-fail"))
                   (res (fresh-at stx "pcase-res"))
                   (st (make-pcase-state stx fail #t res #f))
                   (v (fresh-at stx "pcase-val"))
                   (code (%match st pat v '() (lambda (env) res))))
              (list 'let
                    (list (list v val)
                          (list fail
                                (list 'list (list 'quote 'pcase-fail)))
                          (list res #f))
                    code)))))

    (define-syntax pcase-setq
      (lambda (stx)
        (syntax-case stx ()
          ((_ pat val rest ...)
           (let ((rests (%syn-list (syntax (rest ...)))))
             (if (not (even? (length rests)))
                 (error "wrong number of arguments to pcase-setq")
                 (introduce-tree
                  (if (null? rests)
                      (%pcase-setq-one stx (syntax pat) (syntax val))
                      (cons 'begin
                            (cons (%pcase-setq-one stx (syntax pat)
                                                   (syntax val))
                                  (let loop ((rs rests) (acc '()))
                                    (if (null? rs)
                                        (reverse acc)
                                        (loop (cddr rs)
                                              (cons (%pcase-setq-one
                                                     stx (car rs) (cadr rs))
                                                    acc))))))))))))))

    (define-syntax pcase-defmacro
      (lambda (stx)
        (syntax-case stx ()
          ((_ name args body ...)
           (let* ((define-form
                   (list 'define (syntax name)
                         (cons 'lambda
                               (cons (syntax args)
                                     (%syn-list (syntax (body ...)))))))
                  (register
                   (list (datum->syntax (syntax here)
                                        'register-pattern-macro!)
                         (list 'quote (syntax->datum (syntax name)))
                         (syntax name))))
             (introduce-tree
              (list 'begin define-form register)))))))
))
