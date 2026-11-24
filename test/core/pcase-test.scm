;; Tests for `(schemacs core pcase)' - `pcase.el''s pattern language and
;; the binding macros built on it. Every expectation below was measured
;; on GNU Emacs 31.1 first with `emacs -Q --batch' for the same form;
;; Emacs's `nil' is this tree's `#f' where it is a *value*.
;;
;; The engine is a sequential walker rather than pcase.el's decision-tree
;; compiler (see the library header and DEPARTURES.md), so these tests
;; pin what a clause matches and what it binds - never the shape of the
;; expansion, except `pcase--macroexpand''s own datum answer.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-eq test-equal test-begin test-end)
        (schemacs core pcase)
        (only (schemacs symbol-props) get))

(test-begin "schemacs_core_pcase_clauses")

;;------------------------------------------------------------------
;; Literals, wildcards, and `nil' when nothing matches
;;------------------------------------------------------------------

(test-eq 'one (pcase 1 (1 'one) (2 'two)))
(test-eq 'two (pcase 2 (1 'one) (2 'two)))
(test-eq #f (pcase 3 (1 'one)))
(test-eq 'w (pcase 1 (_ 'w)))
(test-eq 'w (pcase 1 (t 'w)))
(test-eq 'yes (pcase "x" ("x" 'yes) (_ 'no)))
(test-eq 'sym (pcase 'foo ('foo 'sym) (_ 'other)))
(test-eq 'char (pcase #\a (#\a 'char) (_ 'other)))
;; **A keyword is a symbol in Scheme and does not self-evaluate**:
;; in *expression* position it needs Emacs's `'`:k' spelling. The
;; pattern side is Emacs's.
(test-eq 'kw (pcase ':k (:k 'kw) (_ 'other)))
;; a cons is compared with `equal' through the quote pattern
(test-eq 'list (pcase '(1 2) ('(1 2) 'list) (_ 'other)))

;;------------------------------------------------------------------
;; Backquote patterns: `,x' binds, a literal atom matches itself
;;------------------------------------------------------------------

(test-equal '(1 2) (pcase '(1 2) (`(,a ,b) (list a b))))
(test-eq 5 (pcase '(a . 5) (`(a . ,r) r)))
(test-eq 'two (pcase '(1 2) (`(1 ,x) (if (= x 2) 'two 'other))))
(test-eq 'other (pcase '(1 3) (`(1 2) 'two) (_ 'other)))
(test-equal (list 1 2)
            (pcase (vector 1 2) (`#(,a ,b) (list a b)) (_ 'no)))
(test-eq 'no (pcase (vector 1 2) (`#(,a) 'one) (_ 'no)))

;;------------------------------------------------------------------
;; `pred', `guard', `app', `let', `and', `or', `not'
;;------------------------------------------------------------------

(test-eq 'odd (pcase 5 ((pred odd?) 'odd) (_ 'even)))
(test-eq 'even (pcase 4 ((pred odd?) 'odd) (_ 'even)))
(test-eq 'odd (pcase 5 ((pred (not odd?)) 'even) (_ 'odd)))
(test-eq 'big (pcase 5 ((and x (guard (> x 3))) 'big) (_ 'small)))
(test-eq 'small (pcase 2 ((and x (guard (> x 3))) 'big) (_ 'small)))
(test-eq 'two (pcase '(1 2) ((app length 2) 'two) (_ 'other)))
(test-eq 'other (pcase '(1 2 3) ((app length 2) 'two) (_ 'other)))
(test-eq 5 (pcase 5 ((let y (+ 2 3)) y)))
(test-eq 'both (pcase 5 ((and (pred integer?) (pred odd?)) 'both) (_ 'no)))
;; a dotted backquote's tail pattern sees the *cdr*, a list here
(test-equal '(2) (pcase '(1 2) ((or `(0 . ,x) `(1 . ,x)) x)))
(test-equal 2 (pcase '(1 2) ((or `(0 2) `(1 ,x)) x)))
;; `not' succeeds when the inner pattern fails, and vice versa
(test-eq 5 (pcase 5 ((and (not (pred string?)) x) x)))
(test-eq 'yes (pcase "s" ((not (pred string?)) 'no) (_ 'yes)))

;;------------------------------------------------------------------
;; A repeated variable compares, it does not rebind
;;------------------------------------------------------------------

(test-eq 'same (pcase '(1 1) (`(,x ,x) 'same) (_ 'diff)))
(test-eq 'diff (pcase '(1 2) (`(,x ,x) 'same) (_ 'diff)))

(test-end "schemacs_core_pcase_clauses")

(test-begin "schemacs_core_pcase_bindings")

;;------------------------------------------------------------------
;; pcase-let*, pcase-let, pcase-dolist, pcase-lambda
;;------------------------------------------------------------------

(test-equal 3 (pcase-let* ((`(,a ,b) '(1 2)) (c (+ a b))) c))
(test-equal (list 1 2)
            (pcase-let ((`(,a) '(1)) (`(,b) '(2))) (list a b)))
(test-equal '(3 7)
            (let ((acc '()))
              (pcase-dolist (`(,a ,b) '((1 2) (3 4)))
                (set! acc (cons (+ a b) acc)))
              (reverse acc)))
(test-equal 3 ((pcase-lambda (`(,a ,b)) (+ a b)) '(1 2)))
(test-equal '(1 (2 3)) ((pcase-lambda (a . rest) (list a rest)) 1 2 3))

;;------------------------------------------------------------------
;; pcase-setq: it assigns, and answers the last assigned value
;;------------------------------------------------------------------

(test-equal '(1 2) (let ((a #f) (b #f))
                     (pcase-setq `(,a ,b) '(1 2))
                     (list a b)))
(test-equal 2 (let ((a #f) (b #f))
                (pcase-setq `(,a ,b) '(1 2))))
(test-equal 42 (let ((a #f)) (pcase-setq a 42)))
(test-equal '(1 2) (let ((a #f) (b #f))
                     (pcase-setq a 1 `(,b) '(2))
                     (list a b)))
(test-equal 2 (let ((a #f) (b #f))
                (pcase-setq a 1 `(,b) '(2))))

;;------------------------------------------------------------------
;; The non-strict `pcase-let*' is lenient, as Emacs's is
;;
;; Measured: a pattern that *tests* (a literal, a `pred', a `guard')
;; has its test ignored, a missing element binds nil, and a non-list
;; value binds nil for every element. `pcase-let*-strict' is the one
;; that signals. The expectations below are Emacs 31.1's answers.
;;------------------------------------------------------------------

(test-equal (list 'body 1) (pcase-let* ((`(,a) '(1 2))) (list 'body a)))
(test-equal (list 1 2 #f) (pcase-let* ((`(,a ,b ,c) '(1 2))) (list a b c)))
(test-equal (list #f #f #f) (pcase-let* ((`(,a ,b ,c) 5)) (list a b c)))

(test-equal 1 (pcase-let*-strict ((`(,a) '(1))) a))
(test-equal (list "`pcase' pattern does not match value: ~s ~s"
                  (list '(quasiquote ((unquote a))) '(1 2)))
            (guard (e (else (list (error-object-message e)
                                  (error-object-irritants e))))
              (pcase-let*-strict ((`(,a) '(1 2))) a)))

;;------------------------------------------------------------------
;; pcase-exhaustive
;;------------------------------------------------------------------

(test-eq 'one (pcase-exhaustive 1 (1 'one) (_ 'other)))
;; The condition is this tree's own template-plus-irritants `error'
;; (DEPARTURES.md): the message keeps Emacs's `~s' placeholder and the
;; value travels in the irritants.
(test-equal "No clause matching `~s'"
            (guard (e (else (error-object-message e)))
              (pcase-exhaustive 3 (1 'one))))
(test-equal '(3)
            (guard (e (else (error-object-irritants e)))
              (pcase-exhaustive 3 (1 'one))))

(test-end "schemacs_core_pcase_bindings")

(test-begin "schemacs_core_pcase_macros")

;;------------------------------------------------------------------
;; pcase-defmacro: the expander takes pattern data and returns pattern
;; data, and the name it defines is the caller's own binding.
;;------------------------------------------------------------------

(pcase-defmacro string-of (n)
  (list 'and '(pred string?) (list 'app 'string-length n)))

(test-assert (get 'string-of 'pcase-macroexpander))
(test-assert (procedure? string-of))
(test-equal '(and (pred string?) (app string-length 3))
            (pcase--macroexpand '(string-of 3)))
(test-eq 'three (pcase "abc" ((string-of 3) 'three) (_ 'other)))
(test-eq 'other (pcase "abcd" ((string-of 3) 'three) (_ 'other)))

(pcase-defmacro two (a b) (list 'and a b))
(test-eq 'yes (pcase 4 ((two (pred number?) (pred even?)) 'yes) (_ 'no)))
(test-eq 'no (pcase 3 ((two (pred number?) (pred even?)) 'yes) (_ 'no)))

(test-end "schemacs_core_pcase_macros")
