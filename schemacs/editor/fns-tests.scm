(import
 (scheme base)
 (scheme char)
 (only (guile) sort)
 (schemacs editor fns)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; fns.c's tests: the three string comparisons.
;;
;; `compare-strings'' answers are the ones minibuf-tests.scm already
;; checks through `(schemacs editor minibuf)', which re-exports it - and
;; they are checked again here because the function now *lives* in
;; fns.sld and a re-export is exactly the thing that can quietly stop
;; being the same function.
;;
;; `string-collate-lessp'' expectations were taken from `emacs -Q
;; --batch' on this machine, in the ambient locale, and they are the
;; reason it exists: the locale's collation is not character-code order,
;; which is what `string-lessp' gives.

(test-begin "schemacs_editor_fns")

;; ------------------------------------------------------------------
;; compare-strings

;; "abc" and "abd" first differ at index 2, and the answer is that index
;; *plus one*, signed by which string is less.
(test-equal '(#t -3 3 #t -4)
  (list (compare-strings "abc" 0 3 "abc" 0 3 #f)
        (compare-strings "abc" 0 3 "abd" 0 3 #f)
        (compare-strings "abd" 0 3 "abc" 0 3 #f)
        (compare-strings "ABc" 0 3 "abc" 0 3 #t)
        (compare-strings "hello" 0 5 "help" 0 4 #f)))

;; A range that runs out first is the lesser one, and the answer is
;; still "one more than the index": three characters were compared, so
;; four. `emacs -Q --batch' answers -4 and 4 here.
(test-equal '(-4 4)
  (list (compare-strings "abc" 0 3 "abcd" 0 4 #f)
        (compare-strings "abcd" 0 4 "abc" 0 3 #f)))

;; nil END means the end of the string, which is the C's nil
(test-equal '#t (compare-strings "abc" 0 #f "abc" 0 #f #f))

;; ------------------------------------------------------------------
;; string-lessp

(test-equal '(#t #f #t)
  (list (string-lessp "abc" "abd")
        (string-lessp "abd" "abc")
        (string-lessp "abc" "abcd")))

;; "Case is significant."
(test-equal '#f (string-lessp "abc" "ABC"))

;; ------------------------------------------------------------------
;; string-collate-lessp

;; Punctuation weighs less here than it does to `string-lessp', which
;; would put both "1 1" and "1.1" after both "11" and "12" because a
;; space and a dot sort above every digit.
;;
;; This is what `emacs -Q --batch' answers on this machine, which is
;; *not* the list the C's docstring shows: the docstring's example is
;; stale against this glibc, and measuring is what settles it.
(test-equal '("1 1" "1.1" "11" "1 2" "1.2" "12")
  (sort '("11" "12" "1 1" "1 2" "1.1" "1.2") string-collate-lessp))
(test-equal '("1 1" "1 2" "1.1" "1.2" "11" "12")
  (sort '("11" "12" "1 1" "1 2" "1.1" "1.2") string-lessp))

;; measured: `emacs -Q --batch' in this machine's locale
(test-equal '(#f #t)
  (list (string-collate-lessp "__pycache__" "pty-check.py")
        (string-collate-lessp "emacs" "emacs.txt")))

;; "Symbols are also allowed; their print names are used instead."
(test-equal '#t (string-collate-lessp 'abc "abd"))

;; "If IGNORE-CASE is non-nil, characters are converted to lower-case
;; before comparing them."
(test-equal '(#t #t)
  (list (string-collate-lessp "ABC" "abd")
        (string-collate-lessp "ABC" "abd" #f #t)))
(test-equal '#f (string-collate-lessp "abd" "ABC"))

;; "The optional argument LOCALE, a string, overrides the setting of
;; your current locale identifier for collation."
(test-equal '#t (string-collate-lessp "a" "b" "en_US.UTF-8"))

(test-end "schemacs_editor_fns")