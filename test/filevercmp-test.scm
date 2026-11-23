;; -*- mode: scheme; -*-
;; Tests for `(schemacs filevercmp)' - gnulib's
;; `lib/filevercmp.c' - and `fns.c''s `string-version-lessp'.
;;
;; **Every expectation is `emacs -Q --batch''s own answer** for the same
;; pair, measured first. The whole corpus the expectations came from -
;; 50 names, all 2500 ordered pairs, driven through Emacs's
;; `string-version-lessp' - was diffed against `%filevercmp' with no
;; disagreement; this file is the readable subset of it, one case per
;; rule of the C.

(import
  (scheme base)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs filevercmp) %filevercmp)
  (only (schemacs fns) string-version-lessp)
  (only (ice-9 exceptions) exception-message))

(test-begin "schemacs_editor_filevercmp")

;; ------------------------------------------------------------------
;; `filenvercmp''s answers, one case per rule of the C. The exact
;; values are the C's own: the leading-'.' branches `return -1' / `1'
;; outright, while `verrevcmp' answers a difference of its ranks - so
;; the case-sensitivity pair below is a sign test, not a value.

;; "Special case for empty versions."
(test-equal '(-1 1 0)
  (list (%filevercmp "" "a") (%filevercmp "a" "") (%filevercmp "" "")))

;; "'.' sorts first, then '..', then other names with leading '.', then
;; other names."
(test-equal '(-1 -1 -1 1 -1 1 0 0)
  (list (%filevercmp "." "..") (%filevercmp ".." ".a")
        (%filevercmp ".a" "a") (%filevercmp "a" ".a")
        (%filevercmp ".a" ".b") (%filevercmp ".." ".")
        (%filevercmp "." ".") (%filevercmp ".." "..")))

;; The dpkg version rules: leading zeros are ignored, a longer digit
;; run wins, and `~' sorts before the end of the string.
(test-equal '(-1 -1 0 1 -1)
  (list (%filevercmp "1.0~rc1" "1.0") (%filevercmp "a9" "a10")
        (%filevercmp "a09" "a9") (%filevercmp "a10" "a9")
        (%filevercmp "foo" "foo1")))

;; "Cut file suffixes": the first pass compares `a' against `a' and
;; answers 0, and the second pass over the whole names is what decides.
(test-equal '(-1 -1 0)
  (list (%filevercmp "a.b" "a.b2") (%filevercmp "x.y2" "x2.y")
        (%filevercmp "a01" "a1")))

;; Case is significant and the ranking is the C's `c_isalpha' value
;; (65-90 for the capitals, 97-122 for the lower case).
(test-equal '(#t #f)
  (list (< (%filevercmp "ABC" "abc") 0) (< (%filevercmp "abc" "ABC") 0)))

;; ------------------------------------------------------------------
;; `string-version-lessp' - the same pairs through the Lisp function,
;; which is `(< (filenvercmp ...) 0)'.

(test-equal '(#t #f #f #t #f #f #t #t #f #t #t #t #f #t #t #t #t #t #f #t)
  (map (lambda (p) (string-version-lessp (car p) (cadr p)))
       '(("foo2.png" "foo12.png") ("foo10.png" "foo2.png")
         ("foo2.png" "foo2.png") ("1.0~rc1" "1.0") ("1.0" "1.0~rc1")
         ("a09" "a9") ("a9" "a10") ("" "a") ("a" "")
         ("." "..") (".." ".a") (".a" "a") ("a" ".a")
         ("foo" "foo1") ("a.tar.gz" "a.tar.gz2")
         ("<f1>" "<f2>") ("<f2>" "<f11>") ("<f1>" "<f11>")
         ("abc" "ABC") ("ABC" "abc"))))

;; "Symbols are also allowed; their print names are used instead."
(test-equal '(#t #f)
  (list (string-version-lessp 'foo2 'foo12)
        (string-version-lessp 'foo12 'foo2)))

;; ...and a non-string is the C's `CHECK_STRING'.
(test-equal "Wrong type argument: stringp"
  (guard (e (#t (exception-message e))) (string-version-lessp 42 "x")))

(test-end "schemacs_editor_filevercmp")
