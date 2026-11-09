;; `seq.el`'s three functions this tree ported, and the subr/string
;; helpers the omarchy port was built on. Every expectation below is
;; GNU Emacs 31.1's own - `emacs -Q --batch' asked for the same calls.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (schemacs editor seq) seq-filter seq-remove seq-find)
        (only (schemacs editor subr)
              split-string replace-regexp-in-string shell-quote-argument
              string-trim string-trim-left string-trim-right)
        (only (schemacs editor simple) string-empty-p)
        (only (schemacs editor search) string-match))

(test-begin "schemacs_editor_seq")

;;------------------------------------------------------------------
;; seq.el
;;------------------------------------------------------------------

(test-equal '(1 3) (seq-filter odd? '(1 2 3 4)))
(test-equal '(2 4) (seq-remove odd? '(1 2 3 4)))
(test-equal 2 (seq-find even? '(1 2 3)))
(test-equal 'none (seq-find even? '(1 3) 'none))
;; the ambiguity its own docstring names: a found `#f` is not "not found"
(test-equal #f (seq-find (lambda (x) (eq? x #f)) '(1 #f 3) 'none))
(test-equal '() (seq-filter odd? '()))

;;------------------------------------------------------------------
;; subr.el - string-trim
;;
;; `string-trim` passes a nil START to `substring` when the leading trim
;; did not match, and Emacs's `substring` reads nil as 0. Guile's does
;; not, which is why `(string-trim "Ethereal\n")` raised
;; "Wrong type (expecting exact integer): #f" until the nil was resolved.
;;------------------------------------------------------------------

(test-equal "x" (string-trim "  x  "))
(test-equal "Ethereal" (string-trim "Ethereal\n"))
(test-equal "x  " (string-trim-left "  x  "))
(test-equal "  x" (string-trim-right "  x  "))
(test-equal "" (string-trim "   "))
(test-equal "abc" (string-trim "abc"))

;; ...and `string-match` with a nil START is a match from 0 (`search.c:384`)
(test-equal 1 (string-match "b" "abc" #f))
(test-equal 1 (string-match "b" "abc"))

;;------------------------------------------------------------------
;; subr.el - split-string
;;------------------------------------------------------------------

(test-equal '("a" "b") (split-string " a b "))
(test-equal '("a" "" "b") (split-string "a,,b" ","))
(test-equal '("a" "b" "") (split-string "a\nb\n" "\n"))

;;------------------------------------------------------------------
;; subr.el - replace-regexp-in-string and shell-quote-argument
;;
;; The shell quoting is the one that found a real bug in
;; `replace-match`: a `\\` in the replacement emitted two backslashes,
;; where `search.c:2693` emits one.
;;------------------------------------------------------------------

(test-equal "a b c d" (replace-regexp-in-string "[-_ ]+" " " "a-b_c d"))
(test-equal "a\\ b" (shell-quote-argument "a b"))
(test-equal "it\\'s" (shell-quote-argument "it's"))
(test-equal "''" (shell-quote-argument ""))

;;------------------------------------------------------------------
;; simple.el - string-empty-p
;;------------------------------------------------------------------

(test-assert (string-empty-p ""))
(test-assert (not (string-empty-p "a")))

(test-end "schemacs_editor_seq")
