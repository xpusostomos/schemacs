(define-library (schemacs core syntax-macros)
  ;; GNU Emacs's core control macros, ported so a ported function can be
  ;; written in Emacs's own shape.
  ;;
  ;; This file exists because the alternative - rewriting Emacs's code
  ;; into different Scheme - is a departure that hides itself. A port
  ;; that turns `(while (progn ...))' into `(let loop () (if (begin
  ;; ...) (loop) #f))', or `(setq x v)' into an accessor call, reads
  ;; as *similar* code, and similar code cannot be checked against the
  ;; original by eye. Emacs's constructs are ported here, once, and the
  ;; ported files use them as Emacs writes them.
  ;;
  ;; The rule this follows is the one at the top of AGENTS.md: if an
  ;; Emacs function uses a primitive this tree does not have, port the
  ;; primitive - never paper over it. And check first whether Guile
  ;; already has it: `while' did, and the cfd machinery was nonetheless
  ;; written around it with `let loop'.
  ;;
  ;; **Naming: the `-e' forms.** Four of these macros have a Scheme
  ;; counterpart whose answer differs from Emacs's: `when', `unless',
  ;; `while' and `cond'. R7RS leaves the no-answer path unspecified -
  ;; which in Scheme is *true* - while Elisp answers nil. Rather than
  ;; shadow a Scheme binding, the Emacs-answering versions carry an
  ;; `-e' suffix:
  ;;
  ;;     when-e   unless-e   while-e   cond-e
  ;;
  ;; **Use an `-e' form only where the result depends on the Emacs
  ;; difference** - in value position, in a condition, or wherever the
  ;; nil-versus-unspecified answer can be observed. In statement
  ;; position, where the value is discarded, use the plain Scheme or
  ;; Guile construct (`when', `unless', `(only (guile) while)',
  ;; `cond'), so the port reads as the original does.
  ;;
  ;; Importing is plain `(scheme base)'; none of the `-e' names clash
  ;; with it, and `cond' stays Guile's.
  ;;
  ;; **Why the difference matters.** This tree has been bitten by it
  ;; repeatedly (a `when' whose test fails used as a value, a `cond'
  ;; with no matching clause in a loop condition); the `-e' versions
  ;; answer `#f', as Emacs does.
  ;;
  ;; **`setq' and the parameter convention.** This tree's dynamically
  ;; bound variables are SRFI-39 parameters named `*name*', and a
  ;; parameter is set by *calling* it. `setq' follows the naming
  ;; convention: an identifier whose name is wrapped in stars is set by
  ;; calling it, anything else with `set!'. So
  ;;
  ;;     (setq *cfd-re-match* nil)     ->  (*cfd-re-match* #f)
  ;;     (setq c-macro-cache-pos 1)    ->  (set! c-macro-cache-pos 1)
  ;;
  ;; and `setq' answers the last value it set, as Elisp's does - which
  ;; matters, because Elisp code reads that value (a `(setq p ...)'
  ;; used as a condition is common). A starred *plain* variable, or an
  ;; unstarred parameter, would be set the wrong way; the convention
  ;; makes each impossible, and this comment is the place that says so.
  ;;
  ;; **What is deliberately not here.**
  ;;
  ;;   - `if' with several ELSE forms `(if a b c d)': R7RS's `if' is
  ;;     core syntax and a library cannot shadow it. Emacs's form is
  ;;     written `(if a b (begin c d))'.
  ;;   - `let' with a bare binding `(let (a b) ...)': same reason;
  ;;     write `(let ((a #f) (b #f)) ...)'.
  ;;   - `ignore-errors': catching every condition would also swallow
  ;;     C-g. The quit condition's predicate lives in `command.scm',
  ;;     which this leaf cannot import without a cycle.
  ;;   - `catch' and `throw': Emacs's tags are a non-local exit of
  ;;     their own; nothing in the ported files calls them yet.

  (import
    (scheme base)
    ;; `syntax-case' and its friends are what `setq' is written with;
    ;; `(scheme base)' has none of them.
    (only (guile) quasisyntax syntax syntax->datum syntax-case unsyntax))

  (export
   progn prog1 prog2
   while-e dolist dotimes
   push pop incf decf
   setq
   unwind-protect
   when-e unless-e cond-e)

  (begin

    ;;------------------------------------------------------------------
    ;; `progn', `prog1' and `prog2' - `subr.el'
    ;;------------------------------------------------------------------

    (define-syntax progn
      ;; `begin' is the same construct almost everywhere, and the port
      ;; writes `begin' where it can. The one difference is measured:
      ;; Elisp's `(progn)' answers nil, while Guile's `(begin)' with no
      ;; forms is a syntax error - "sequence of zero expressions in
      ;; form (begin)" - so a ported `(progn)' with an empty body is
      ;; not `(begin)'.
      (syntax-rules ()
        ((_) #f)
        ((_ form) form)
        ((_ form1 form2 ...) (begin form1 form2 ...))))

    (define-syntax prog1
      ;; "Execute FIRST and return its value. Do not return the value
      ;; of BODY" - `prog1' is Elisp's name for "evaluate the rest for
      ;; effect". `subr.el'.
      (syntax-rules ()
        ((_ first body ...)
         (let ((%prog1-result first))
           body ...
           %prog1-result))))

    (define-syntax prog2
      ;; "Execute FORM1, FORM2 and BODY sequentially; return value from
      ;; FORM2." - `subr.el'.
      (syntax-rules ()
        ((_ form1 form2 body ...)
         (begin form1 (prog1 form2 body ...)))))

    ;;------------------------------------------------------------------
    ;; `while-e' - `subr.el'
    ;;------------------------------------------------------------------

    (define-syntax while-e
      ;; "While TEST is true, evaluate BODY. Return nil." The test is
      ;; evaluated before every iteration, including the first, and the
      ;; loop answers nil when it finishes - which is what Emacs does
      ;; and what a caller testing the value relies on.
      (syntax-rules ()
        ((_ test body ...)
         (let %while-loop ()
           (if test
               (begin body ... (%while-loop))
               #f)))))

    ;;------------------------------------------------------------------
    ;; `dolist' and `dotimes' - `subr.el'
    ;;------------------------------------------------------------------

    (define-syntax dolist
      ;; "(dolist (VAR LIST [RESULT]) BODY...): Loop over a LIST.
      ;; Evaluate BODY with VAR bound to each car of LIST, then evaluate
      ;; RESULT with VAR bound to nil." The list is evaluated once, and
      ;; the form answers RESULT or nil.
      (syntax-rules ()
        ((_ (var list) body ...)
         (let %dolist-loop ((%dolist-rest list))
           (if (pair? %dolist-rest)
               (let ((var (car %dolist-rest)))
                 body ...
                 (%dolist-loop (cdr %dolist-rest)))
               #f)))
        ((_ (var list result) body ...)
         (let %dolist-loop ((%dolist-rest list))
           (if (pair? %dolist-rest)
               (let ((var (car %dolist-rest)))
                 body ...
                 (%dolist-loop (cdr %dolist-rest)))
               ;; Emacs evaluates RESULT with VAR bound to nil.
               (let ((var #f))
                 result))))))

    (define-syntax dotimes
      ;; "(dotimes (VAR COUNT [RESULT]) BODY...): Loop a certain number
      ;; of times." VAR runs from 0 to COUNT-1; COUNT is evaluated
      ;; once; the form answers RESULT or nil.
      (syntax-rules ()
        ((_ (var count) body ...)
         (let ((%dotimes-count count))
           (let %dotimes-loop ((%dotimes-i 0))
             (if (< %dotimes-i %dotimes-count)
                 (let ((var %dotimes-i))
                   body ...
                   (%dotimes-loop (+ %dotimes-i 1)))
                 #f))))
        ((_ (var count result) body ...)
         (let ((%dotimes-count count))
           (let %dotimes-loop ((%dotimes-i 0))
             (if (< %dotimes-i %dotimes-count)
                 (let ((var %dotimes-i))
                   body ...
                   (%dotimes-loop (+ %dotimes-i 1)))
                 ;; Emacs evaluates RESULT with VAR bound to COUNT, the
                 ;; number of iterations.
                 (let ((var %dotimes-count))
                   result)))))))

    ;;------------------------------------------------------------------
    ;; The list/arithmetic places - `subr.el'
    ;;------------------------------------------------------------------
    ;;
    ;; Emacs's `push', `pop', `incf' and `decf' take a generalized
    ;; variable (a symbol, or a place gv knows how to set). This tree
    ;; has no gv, so they take a *symbol*: `(push item var)' and the
    ;; rest. All four answer Elisp's value - `set!` answers the
    ;; unspecified value here, so each expansion finishes by naming the
    ;; new value.

    (define-syntax push
      (syntax-rules ()
        ((_ item var)
         (begin (set! var (cons item var))
                var))))

    (define-syntax pop
      (syntax-rules ()
        ((_ var)
         (let ((%pop-result (car var)))
           (set! var (cdr var))
           %pop-result))))

    (define-syntax incf
      (syntax-rules ()
        ((_ var)
         (begin (set! var (+ var 1))
                var))
        ((_ var delta)
         (begin (set! var (+ var delta))
                var))))

    (define-syntax decf
      (syntax-rules ()
        ((_ var)
         (begin (set! var (- var 1))
                var))
        ((_ var delta)
         (begin (set! var (- var delta))
                var))))

    ;;------------------------------------------------------------------
    ;; `setq' - `eval.c'
    ;;------------------------------------------------------------------
    ;;
    ;; The star test is the parameter convention read as syntax: a name
    ;; wrapped in stars is a parameter, and a parameter is set by
    ;; calling it. Everything else is a plain Scheme variable and is
    ;; set with `set!'. The value of the form is the last value set, as
    ;; Elisp's `setq' answers it.

    (define (%elisp-parameter-name? id)
      (and (symbol? id)
           (let ((name (symbol->string id)))
             (and (> (string-length name) 1)
                  (char=? (string-ref name 0) #\*)
                  (char=? (string-ref name (- (string-length name) 1))
                          #\*)))))

    (define-syntax setq
      ;; Elisp's `setq' evaluates each VALUE once and answers the last
      ;; one. The value is bound to a hygienic temporary for exactly
      ;; that reason: a parameter is set by calling it, and writing
      ;; `(begin (var value) value)' would evaluate VALUE twice - a
      ;; search in the value would run twice and skip a match.
      (lambda (stx)
        (syntax-case stx ()
          ((_)
           (syntax #f))
          ((_ var value)
           (if (%elisp-parameter-name? (syntax->datum (syntax var)))
               (quasisyntax (let ((%setq-value value))
                              (var %setq-value)
                              %setq-value))
               (quasisyntax (let ((%setq-value value))
                              (set! var %setq-value)
                              %setq-value))))
          ((_ var value rest ...)
           (if (%elisp-parameter-name? (syntax->datum (syntax var)))
               (quasisyntax (let ((%setq-value value))
                              (var %setq-value)
                              (setq rest ...)))
               (quasisyntax (let ((%setq-value value))
                              (set! var %setq-value)
                              (setq rest ...))))))))

    ;;------------------------------------------------------------------
    ;; `unwind-protect' - `eval.c'
    ;;------------------------------------------------------------------
    ;;
    ;; BODYFORM is one form, as in Emacs; the rest are the unwind forms,
    ;; run on every exit. `dynamic-wind' is the Scheme spelling, with
    ;; the before-thunk doing nothing.

    (define-syntax unwind-protect
      (syntax-rules ()
        ((_ body)
         (dynamic-wind (lambda () #f)
                       (lambda () body)
                       (lambda () #f)))
        ((_ body cleanup ...)
         (dynamic-wind (lambda () #f)
                       (lambda () body)
                       (lambda () cleanup ...)))))

    ;;------------------------------------------------------------------
    ;; `when-e', `unless-e' and `cond-e' with Elisp's values
    ;;------------------------------------------------------------------
    ;;
    ;; These are `(scheme base)'s, except that their no-answer path is
    ;; `#f' where R7RS leaves it unspecified - and an unspecified value
    ;; is true in Scheme. Every Elisp `when'/`unless'/`cond' in a value
    ;; position depends on that difference. `cond-e' is Emacs's `cond'
    ;; under a name of its own, so Guile's `cond' is left alone.

    (define-syntax when-e
      (syntax-rules ()
        ((_ test body ...)
         (if test
             (begin body ...)
             #f))))

    (define-syntax unless-e
      (syntax-rules ()
        ((_ test body ...)
         (if test
             #f
             (begin body ...)))))

    (define-syntax cond-e
      ;; The clauses are R7RS's and Elisp's alike - `(test body...)',
      ;; `(test)', `(test => procedure)' and `(else body...)'; the
      ;; difference is the `#f' the last rule answers when no clause
      ;; matches. The name is not `cond' because that binding belongs to
      ;; Guile; a ported file writes `conde' where Emacs writes `cond'.
      (syntax-rules (else =>)
        ((_)
         #f)
        ((_ (else body ...))
         (begin body ...))
        ((_ (test => procedure) clause ...)
         (let ((%conde-value test))
           (if %conde-value
               (procedure %conde-value)
               (cond-e clause ...))))
        ((_ (test) clause ...)
         (or test (cond-e clause ...)))
        ((_ (test body ...) clause ...)
         (if test
             (begin body ...)
             (cond-e clause ...)))))

    ))
