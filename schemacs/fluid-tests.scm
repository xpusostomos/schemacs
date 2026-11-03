(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs fluid) fluid-let)
 (only (guile) call-with-current-continuation))

;; `fluid-let`: dynamically scoped rebinding of an ordinary variable -
;; SRFI 226's form, and what Elisp's `let` on a `defvar`'d variable does.
;;
;; The cases below are the four ways out of the body (normal return, an
;; error, an escape through a continuation, and a loop back into the form
;; from outside), plus the two things that are easy to get wrong: the
;; values are `let`-parallel and not `let*`-sequential, and an assignment
;; inside the body is undone on the way out.

(test-begin "schemacs_fluid")

(define case-fold-search #t)
(define fill-column 70)

;;-------------------------------------------------------------
;; The plain case
;;-------------------------------------------------------------

(test-equal "inside the body the variable has the new value"
  '(#f 30)
  (fluid-let ((case-fold-search #f) (fill-column 30))
    (list case-fold-search fill-column)))

(test-equal "and the old values are back afterwards"
  '(#t 70)
  (begin
    (fluid-let ((case-fold-search #f) (fill-column 30))
      (list case-fold-search fill-column))
    (list case-fold-search fill-column)))

(test-equal "the body's value is the form's value"
  42
  (fluid-let ((fill-column 1)) 42))

(test-equal "and so are several values"
  '(1 2)
  (call-with-values (lambda () (fluid-let ((fill-column 1)) (values 1 2)))
                    list))

;;-------------------------------------------------------------
;; `let`, not `let*`
;;-------------------------------------------------------------
;; Every value expression is read before any variable is installed - so
;; `case-fold-search` gets the OUTER `fill-column`, not the 30 about to be
;; installed. Emacs's `let` says the same: `(let ((a 1) (b a)) b)` is the
;; outer `a`.
;;-------------------------------------------------------------

(test-equal "the values are evaluated before anything is installed"
  70
  (fluid-let ((case-fold-search fill-column) (fill-column 30))
    case-fold-search))

(test-equal "so a later binding does not see an earlier one"
  '(#t 30)
  (fluid-let ((case-fold-search case-fold-search) (fill-column 30))
    (list case-fold-search fill-column)))

;;-------------------------------------------------------------
;; Leaving early: an error, and an escape
;;-------------------------------------------------------------

(test-equal "an error in the body still restores"
  '(raised #t)
  (list (guard (e (#t 'raised))
          (fluid-let ((case-fold-search #f)) (error "boom")))
        case-fold-search))

(test-equal "escaping through a continuation still restores"
  '(escaped #t)
  (list (call-with-current-continuation
         (lambda (k)
           (fluid-let ((case-fold-search #f))
             (k 'escaped)
             'never)))
        case-fold-search))

;;-------------------------------------------------------------
;; Nesting, assigning, and no bindings at all
;;-------------------------------------------------------------

;; the third element is the point: the inner `fluid-let` restores to the
;; OUTER binding's value (#f), not to the global one (#t), so nesting
;; composes rather than clobbering.
(test-equal "a nested fluid-let restores to the outer binding, not the global"
  '(#f 30 #f)
  (fluid-let ((case-fold-search #f))
    (list case-fold-search
          (fluid-let ((fill-column 30)) fill-column)
          (begin (fluid-let ((case-fold-search #t)) case-fold-search)
                 case-fold-search))))

(test-equal "an assignment inside the body is undone on exit"
  '(5 #t)
  (list (fluid-let ((case-fold-search #f))
          (set! case-fold-search 5)
          case-fold-search)
        case-fold-search))

(test-equal "`(fluid-let () ...)` is just the body"
  7
  (fluid-let () 7))

(test-end "schemacs_fluid")
