;; GNU Emacs's `test/lisp/emacs-lisp/ring-tests.el', transcribed, and
;; the return values the suite does not assert - measured on Emacs 31.1
;; with `emacs -Q --batch'.
;;
;; `ring-insert` answers the item (Emacs's `prog1 (aset ...)'), and
;; `ring-insert-at-beginning` answers the new length (its last form is
;; `setcar`, which answers the value stored); both were measured, not
;; read, because the two bodies look alike and answer differently.
;;
;; The error text: Emacs 31 renders `` `x' '' as curly quotes under
;; `text-quoting-style'; this tree's error reporter does not do the
;; substitution, so the message here keeps the backquote and the
;; apostrophe. That is the tree-wide quoting departure, not ring's.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end test-error)
        (only (schemacs core ring)
              ring-p make-ring ring-insert-at-beginning ring-plus1 ring-minus1
              ring-length ring-index ring-empty-p ring-size ring-copy
              ring-insert ring-remove ring-ref ring-elements ring-member
              ring-next ring-previous ring-extend ring-resize
              ring-insert+extend ring-remove+insert+extend
              ring-convert-sequence-to-ring)
        (only (schemacs data) mod)
        (only (schemacs subr) error-message-string))

(test-begin "schemacs_editor_ring")

;;------------------------------------------------------------------
;; ring-tests.el
;;------------------------------------------------------------------

(test-assert (ring-p (make-ring 5)))
(test-assert (ring-p (cons 0 (cons 0 (vector)))))
(test-assert (not (ring-p 5)))
(test-assert (not (ring-p '(0 . 0))))
(test-assert (not (ring-p '(0 0 0))))

;; `ring-tests-insert-at-beginning'
(let ((ring (make-ring 5)))
  (ring-insert-at-beginning ring 'foo)
  (ring-insert-at-beginning ring 'bar)
  (test-equal '(foo bar) (ring-elements ring)))

(test-equal 1 (ring-plus1 0 5))
(test-equal 0 (ring-plus1 4 5))
(test-equal 4 (ring-minus1 0 5))
(test-equal 3 (ring-minus1 4 5))

;; `ring-tests-length'
(let ((ring (make-ring 2)))
  (test-equal 0 (ring-length ring))
  (ring-insert ring 'a)
  (test-equal 1 (ring-length ring))
  (ring-insert ring 'b)
  (test-equal 2 (ring-length ring))
  (ring-insert ring 'c)
  (test-equal 2 (ring-length ring)))

;; `ring-tests-index'
(test-equal 2 (ring-index 0 0 3 3))
(test-equal 2 (ring-index 0 0 3 5))
(test-equal 1 (ring-index 0 2 3 3))
(test-equal 0 (ring-index 1 2 3 3))
(test-equal 2 (ring-index 2 2 3 3))

;; `ring-tests-empty-p'
(let ((ring (make-ring 5)))
  (test-assert (ring-empty-p ring))
  (ring-insert ring 1)
  (test-assert (not (ring-empty-p ring)))
  (ring-remove ring)
  (test-assert (ring-empty-p ring)))

;; `ring-tests-size'
(let ((ring (make-ring 2)))
  (test-equal 2 (ring-size ring))
  (ring-insert ring "a")
  (ring-insert ring "b")
  (ring-insert ring "c")
  (test-equal 2 (ring-size ring))
  (ring-extend ring 3)
  (test-equal 5 (ring-size ring)))

;; `ring-tests-copy'
(let ((ring1 (make-ring 3)))
  (ring-insert ring1 1)
  (ring-insert ring1 2)
  (let ((ring2 (ring-copy ring1)))
    (test-assert (not (eq? ring1 ring2)))
    (test-equal (ring-size ring1) (ring-size ring2))
    (test-equal (ring-elements ring1) (ring-elements ring2))))

;; `ring-tests-insert', and the value it answers
(let ((ring (make-ring 2)))
  (test-equal 'a (ring-insert ring 'a))
  (test-equal '(a) (ring-elements ring))
  (test-equal 'b (ring-insert ring 'b))
  (test-equal '(b a) (ring-elements ring))
  (ring-insert ring 'c)
  (test-equal '(c b) (ring-elements ring)))

;; `ring-tests-remove'
(let ((ring (make-ring 2)))
  (test-error (ring-remove ring))
  (ring-insert ring 'foo)
  (ring-insert ring 'bar)
  (test-assert (eq? (ring-remove ring) 'foo))
  (test-equal '(bar) (ring-elements ring))
  (ring-insert ring 'baz)
  (test-assert (eq? (ring-remove ring 0) 'baz))
  (test-equal '(bar) (ring-elements ring)))

;; `ring-tests-ref'
(let ((ring (make-ring 2)))
  (test-error (ring-ref ring 0))
  (ring-insert ring 'a)
  (test-assert (eq? (ring-ref ring 0) 'a))
  (ring-insert ring 'b)
  (test-assert (eq? (ring-ref ring 0) 'b))
  (test-assert (eq? (ring-ref ring 1) 'a))
  (test-assert (eq? (ring-ref ring 2) 'b)))

;; `ring-tests-elements'
(let ((ring (make-ring 5)))
  (ring-insert ring 3)
  (ring-insert ring 2)
  (ring-insert ring 1)
  (test-equal '(1 2 3) (ring-elements ring)))

;; `ring-tests-member'
(let ((ring (make-ring 3)))
  (ring-insert ring "foo")
  (ring-insert ring "bar")
  (test-equal 1 (ring-member ring "foo"))
  (test-equal 0 (ring-member ring "bar"))
  (test-assert (not (ring-member ring "baz"))))

;; `ring-tests-next' and its error message
(let ((ring (make-ring 3)))
  (ring-insert ring 'a)
  (ring-insert ring 'b)
  (test-assert (eq? (ring-next ring 'b) 'a))
  (test-assert (eq? (ring-next ring 'a) 'b))
  (test-equal "Item is not in the ring: `c'"
              (guard (e (#t (error-message-string e))) (ring-next ring 'c))))

;; `ring-tests-previous'
(let ((ring (make-ring 3)))
  (ring-insert ring 'a)
  (ring-insert ring 'b)
  (test-assert (eq? (ring-previous ring 'b) 'a))
  (test-assert (eq? (ring-previous ring 'a) 'b))
  (test-error (ring-previous ring 'c)))

;; `ring-tests-extend'
(let ((ring (make-ring 2)))
  (ring-insert ring 1)
  (ring-insert ring 2)
  (test-equal 2 (ring-size ring))
  (test-equal 2 (ring-length ring))
  (ring-extend ring 3)
  (ring-insert ring 3)
  (test-equal 5 (ring-size ring))
  (test-equal '(3 2 1) (ring-elements ring)))

;; `ring-resize/grow'
(let ((ring (make-ring 3)))
  (ring-insert ring 1)
  (ring-insert ring 2)
  (ring-insert ring 3)
  (ring-resize ring 5)
  (test-equal 5 (ring-size ring))
  (test-equal '(3 2 1) (ring-elements ring)))

;; `ring-resize/grow-empty'
(let ((ring (make-ring 3)))
  (ring-resize ring 5)
  (test-equal 5 (ring-size ring))
  (test-equal '() (ring-elements ring)))

;; `ring-resize/grow-wrapped-ring'
(let ((ring (make-ring 3)))
  (ring-insert ring 1)
  (ring-insert ring 2)
  (ring-insert ring 3)
  (ring-insert ring 4)
  (ring-insert ring 5)
  (ring-resize ring 5)
  (test-equal 5 (ring-size ring))
  (test-equal '(5 4 3) (ring-elements ring)))

;; `ring-resize/shrink'
(let ((ring (make-ring 5)))
  (ring-insert ring 1)
  (ring-insert ring 2)
  (ring-insert ring 3)
  (ring-insert ring 4)
  (ring-insert ring 5)
  (ring-resize ring 3)
  (test-equal 3 (ring-size ring))
  (test-equal '(5 4 3) (ring-elements ring)))

;;------------------------------------------------------------------
;; ring.el's remaining functions: the ert file does not reach them, so
;; every expectation here is Emacs 31.1's own, measured with
;; `emacs -Q --batch -l /tmp/ringmeas2.el'.
;;------------------------------------------------------------------

;; a full ring dumps its oldest item when GROW-P is nil, and grows by
;; one when it is not
(let ((ring (make-ring 2)))
  (ring-insert ring 1)
  (ring-insert ring 2)
  (ring-insert+extend ring 3)
  (test-equal '(3 2) (ring-elements ring))
  (test-equal 2 (ring-size ring))
  (ring-insert+extend ring 3 #t)
  (test-equal '(3 3 2) (ring-elements ring))
  (test-equal 3 (ring-size ring)))

;; `ring-remove+insert+extend' keeps exactly one copy, at the newest end
(let ((ring (make-ring 3)))
  (ring-insert ring 'a)
  (ring-insert ring 'b)
  (ring-insert ring 'a)
  (ring-remove+insert+extend ring 'a)
  (test-equal '(a b) (ring-elements ring))
  (test-equal 2 (ring-length ring)))

;; `ring-convert-sequence-to-ring' keeps a ring as it is, and skips a
;; member `equal' to the *first* member of SEQ - which is the ring's
;; newest, because each later insert goes in at the oldest end. The
;; first version of these rows expected "consecutive duplicates dropped,
;; newest first", and Emacs answered `(1 2 3 3 3 4)' for both - measured
;; afterwards from `emacs -Q --batch -l /tmp/ringmeas2.el', which is why
;; the expectations here are the measured ones.
(let ((ring (make-ring 3)))
  (test-assert (eq? ring (ring-convert-sequence-to-ring ring))))
(let ((ring (ring-convert-sequence-to-ring '(1 1 2 3 3 3 4))))
  (test-equal 6 (ring-length ring))
  (test-equal '(1 2 3 3 3 4) (ring-elements ring)))
;; a vector goes through the same `length' plus `elt'
(let ((ring (ring-convert-sequence-to-ring (vector 1 2 2 3))))
  (test-equal 4 (ring-length ring))
  (test-equal '(1 2 2 3) (ring-elements ring)))

;;------------------------------------------------------------------
;; data.c's `mod`, which the ring needs (`(scheme base)` has none).
;; All six answers measured on Emacs 31.1.
;;------------------------------------------------------------------

(test-equal 2 (mod -1 3))
(test-equal -2 (mod 1 -3))
(test-equal 2 (mod -7 3))
(test-equal -2 (mod 7 -3))
(test-equal 1.5 (mod -7.5 3))
(test-equal -1.5 (mod 7.5 -3))

(test-end "schemacs_editor_ring")
