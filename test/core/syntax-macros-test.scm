;; Tests for `(schemacs core syntax-macros)' - the core Elisp control macros, ported
;; so a ported function can use Emacs's own constructs. Every
;; expectation here is GNU Emacs 31.1's answer for the same form,
;; measured with `emacs -Q --batch' before the macros were written; the
;; two that differ from R7RS - `when-e'/`unless-e'/`cond-e' answering `#f'
;; instead of an unspecified value - are the whole reason the library
;; carries the `-e' forms.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs core syntax-macros))

(test-begin "schemacs_syntax")

;;----------------------------------------------------------------------
;; `progn', `prog1' and `prog2'
;;----------------------------------------------------------------------

(test-equal "progn with no forms is nil"
            #f
            (progn))
(test-equal "progn answers its last form"
            2
            (progn 1 2))
(test-equal "prog1 answers its first form"
            1
            (prog1 1 2 3))
(test-equal "prog1 evaluates the rest, and in order"
            '(3 2)
            (let ((seen '()))
              (prog1 'first
                (set! seen (cons 2 seen))
                (set! seen (cons 3 seen)))
              seen))
(test-equal "prog2 answers its second form"
            2
            (prog2 1 2 3))
(test-equal "prog2 evaluates the first form first"
            '(1)
            (let ((seen '()))
              (prog2 (set! seen (cons 1 seen)) 2 3)
              seen))

;;----------------------------------------------------------------------
;; `while-e'
;;----------------------------------------------------------------------

(test-equal "while-e runs its body while the test holds"
            10
            (let ((sum 0) (i 0))
              (while-e (< i 5)
                (set! sum (+ sum i))
                (set! i (+ i 1)))
              sum))
(test-equal "while-e answers nil when it finishes"
            #f
            (while-e #f 1))
(test-equal "while-e runs no body when the test starts false"
            '()
            (let ((seen '()))
              (while-e #f (set! seen (cons 1 seen)))
              seen))
(test-equal "while-e with no body still evaluates the test"
            '(#t)
            (let ((seen '()))
              (while-e (begin (set! seen (cons #t seen)) #f))
              seen))
(test-equal "while-e re-tests after every iteration"
            3
            (let ((i 0))
              (while-e (< i 3)
                (set! i (+ i 1)))
              i))

;;----------------------------------------------------------------------
;; `dolist' and `dotimes'
;;----------------------------------------------------------------------

(test-equal "dolist visits each element in order"
            '(1 2 3)
            (let ((acc '()))
              (dolist (x '(1 2 3))
                (set! acc (cons x acc)))
              (reverse acc)))
(test-equal "dolist answers nil without a result form"
            #f
            (dolist (x '(1 2)) x))
(test-equal "dolist answers its result form"
            'done
            (dolist (x '(1 2) 'done) x))
(test-equal "dolist evaluates the result with the variable bound to nil"
            #f
            (dolist (x '(1 2) x) x))
(test-equal "dolist over the empty list runs no body"
            '()
            (let ((seen '()))
              (dolist (x '())
                (set! seen (cons x seen)))
              seen))
(test-equal "dotimes counts from zero to one less than the count"
            '(0 1 2)
            (let ((acc '()))
              (dotimes (i 3)
                (set! acc (cons i acc)))
              (reverse acc)))
(test-equal "dotimes answers nil without a result form"
            #f
            (dotimes (i 0) i))
(test-equal "dotimes answers its result form"
            'done
            (dotimes (i 3 'done) i))
(test-equal "dotimes evaluates the result with the variable bound to the count"
            3
            (dotimes (i 3 i)))
(test-equal "dotimes evaluates the count once"
            1
            (let ((calls 0))
              (dotimes (i (begin (set! calls (+ calls 1)) 2))
                i)
              calls))

;;----------------------------------------------------------------------
;; `push', `pop', `incf' and `decf'
;;----------------------------------------------------------------------

(test-equal "push conses onto the front and answers the new list"
            '(1 2)
            (let ((l '(2)))
              (push 1 l)))
(test-equal "push leaves the new list in the variable"
            '(1 2)
            (let ((l '(2)))
              (push 1 l)
              l))
(test-equal "pop answers the car and leaves the cdr"
            '(1 (2 3))
            (let ((l '(1 2 3)))
              (list (pop l) l)))
(test-equal "incf answers the new value"
            6
            (let ((n 5))
              (incf n)))
(test-equal "incf with a delta"
            7
            (let ((n 5))
              (incf n 2)))
(test-equal "decf answers the new value"
            4
            (let ((n 5))
              (decf n)))
(test-equal "decf with a delta"
            3
            (let ((n 5))
              (decf n 2)))

;;----------------------------------------------------------------------
;; `setq'
;;----------------------------------------------------------------------

(test-equal "setq sets a plain variable and answers the value"
            5
            (let ((x 1))
              (setq x 5)))
(test-equal "setq sets several variables in order and answers the last"
            '(3 2 3)
            (let ((x 1) (y 1))
              (let ((answer (setq x 2 y 3)))
                (list answer x y))))
(test-equal "setq with no pairs is nil"
            #f
            (setq))

(test-equal "setq evaluates a plain variable's value once"
            1
            (let ((n 0) (x #f))
              (setq x (begin (set! n (+ n 1)) n))
              n))

;; A dynamically bound variable is a parameter here; `setq' follows the
;; naming convention and calls it.
(define *setq-param* (make-parameter 1))

(test-equal "setq calls a parameter and answers the value"
            '(2 2)
            (let ((answer (setq *setq-param* 2)))
              (list answer (*setq-param*))))
(test-equal "setq evaluates a parameter's value once"
            1
            (let ((n 0))
              (setq *setq-param* (begin (set! n (+ n 1)) n))
              n))
(test-equal "setq sets the fluid binding inside parameterize"
            9
            (parameterize ((*setq-param* 5))
              (setq *setq-param* 9)
              (*setq-param*)))
(parameterize ((*setq-param* 5))
  (setq *setq-param* 9))
(test-equal "the parameter's outer value is restored"
            1
            (*setq-param*))

;;----------------------------------------------------------------------
;; `unwind-protect'
;;----------------------------------------------------------------------

(test-equal "unwind-protect runs its cleanups after the body and answers the body"
            '(2 (1))
            (let ((seen '()))
              (let ((value (unwind-protect 1
                             (set! seen (cons 1 seen)))))
                (list (+ value 1) seen))))
(test-equal "unwind-protect runs its cleanups when the body raises"
            'cleaned
            (let ((seen '()))
              (guard (e (else seen))
                (unwind-protect (raise 'boom)
                  (set! seen 'cleaned)))))

;;----------------------------------------------------------------------
;; `when-e', `unless-e' and `cond-e' with Elisp's values
;;----------------------------------------------------------------------

(test-equal "when-e is nil when the test fails"
            #f
            (when-e #f 1))
(test-equal "when-e answers its last body form"
            2
            (when-e #t 1 2))
(test-equal "unless-e is nil when the test holds"
            #f
            (unless-e #t 1))
(test-equal "unless-e answers its last body form"
            2
            (unless-e #f 1 2))
(test-equal "cond-e with no matching clause is nil"
            #f
            (cond-e (#f 1)))
(test-equal "cond-e answers the matching clause's last form"
            'b
            (cond-e ((= 1 2) 'a) (else 'b)))
(test-equal "cond-e's test-only clause answers the test"
            5
            (cond-e (5) (else 'no)))
(test-equal "cond-e's => clause passes the value to the procedure"
            6
            (cond-e ((assv 2 '((1 10) (2 6))) => cadr)
                   (else #f)))
(test-equal "cond-e with no clauses is nil"
            #f
            (cond-e))

(test-end "schemacs_syntax")
