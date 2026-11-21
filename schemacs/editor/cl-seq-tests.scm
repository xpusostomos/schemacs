;; Tests for `(schemacs editor cl-seq)' - the four `cl-lib' sequence
;; functions the cc-mode language constants are built with. Every
;; expectation here is Emacs 31.1's own answer, measured with
;; `emacs -Q --batch' (require 'cl-lib) before the port was written; the
;; quirks they pin are the ones cc-langs.el depends on.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor cl-seq)
 (schemacs editor fns))

(test-begin "schemacs_editor_cl_seq")

;;----------------------------------------------------------------------
;; `cl-set-difference'
;;----------------------------------------------------------------------
(test-equal "set-difference keeps list1's order"
            '("a" "c")
            (cl-set-difference '("a" "b" "c") '("b") ':test string-equal))
(test-equal "set-difference with nothing to remove is list1"
            '("a" "b" "c")
            (cl-set-difference '("a" "b" "c") '("z") ':test string-equal))
(test-equal "set-difference answers nil when every member is in list2"
            '()
            (cl-set-difference '("a" "b") '("b" "a" "c") ':test string-equal))
(test-equal "set-difference keeps a nil list2 short-circuit"
            '("c" "b" "a")
            (cl-set-difference '("c" "b" "a") '()))
;; No keyword: the C's `memq' path for non-numbers, `memql' for numbers.
(test-equal "set-difference without :test compares with eq for symbols"
            '(a)
            (cl-set-difference '(a b) '(b)))
;; Fresh (non-interned) strings: a compiled file shares its literals, and
;; the test is about `eq' identity, which Emacs's reader never shares.
(test-equal "set-difference without :test does not see equal strings"
            '("a" "b")
            (cl-set-difference (list (string-copy "a") (string-copy "b"))
                               (list (string-copy "b"))))
(test-equal "set-difference without :test compares numbers by value"
            '(1 3)
            (cl-set-difference (list 1 2 3) (list 2)))

;;----------------------------------------------------------------------
;; `cl-intersection' - the answer is in the reverse of list2's order
;;----------------------------------------------------------------------
(test-equal "intersection is the reverse of list2's order"
            '("c" "b")
            (cl-intersection '("a" "b" "c") '("b" "c" "d") ':test string-equal))
(test-equal "intersection of disjoint lists is nil"
            '()
            (cl-intersection '("a" "b" "c") '("x" "y") ':test string-equal))
(test-equal "intersection without :test takes the memq path"
            '()
            (cl-intersection (map string-copy '("a" "b" "c"))
                             (map string-copy '("b" "c" "d"))))
(test-equal "intersection of equal lists answers list1 untouched"
            '("a" "b")
            (cl-intersection '("a" "b") '("a" "b")))

;;----------------------------------------------------------------------
;; `cl-delete-duplicates'
;;----------------------------------------------------------------------
(test-equal "delete-duplicates with string-equal keeps the LAST of a run"
            '("b" "a" "c")
            (cl-delete-duplicates '("a" "b" "a" "c") ':test string-equal))
(test-equal "delete-duplicates :from-end keeps the first"
            '("a" "b" "c")
            (cl-delete-duplicates '("a" "b" "a" "c") ':test string-equal
                                  ':from-end #t))
(test-equal "delete-duplicates without :test does not see equal strings"
            '("a" "b" "a" "c")
            (cl-delete-duplicates (map string-copy '("a" "b" "a" "c"))))
(test-equal "delete-duplicates without :test compares numbers by value"
            '(2 1 3)
            (cl-delete-duplicates (list 1 2 1 3)))
(test-equal "delete-duplicates removes duplicate symbols"
            '(b a c)
            (cl-delete-duplicates '(a b a c)))
(test-equal "delete-duplicates of an empty list"
            '()
            (cl-delete-duplicates '()))

;;----------------------------------------------------------------------
;; `cl-member'
;;----------------------------------------------------------------------
(test-equal "cl-member answers the tail"
            '("b" "c")
            (cl-member "b" '("a" "b" "c") ':test string-equal))
(test-assert "cl-member without keys compares with memql"
             (not (cl-member (string-copy "b")
                             (map string-copy '("a" "b" "c")))))
(test-equal "cl-member finds a number by value without keys"
            '(2 3)
            (cl-member 2 '(1 2 3)))
(test-assert "a bad keyword is refused"
             (catch #t
               (lambda () (cl-set-difference '(a) '(b) ':nonsense #t) #f)
               (lambda (k . args) #t)))

(test-end "schemacs_editor_cl_seq")
