(import
  (scheme base)
  (srfi 64)
  (schemacs elisp-eval print)
  (schemacs elisp-eval environment))

;; Regression tests for `(schemacs elisp-eval print)', which mirrors GNU
;; Emacs's `src/print.c': printing a Lisp object as the text that reads
;; back as it.
;;
;; **Every expectation below was measured on GNU Emacs 31.1 first**, with
;; `emacs -Q --batch -l' over the same forms - `(prin1-to-string X)', and
;; the `let'-bound print variables. That is the check the port is written
;; against; the source is still what the algorithm comes from.
;;
;; This library exists because `(write val stream)' is not `prin1'. The
;; two agree on a number and on a list and disagree everywhere else, and
;; the rows that show it are `t', `nil' and the two print variables.

(test-begin "schemacs_elisp_eval_print")

(define (sym name) (new-symbol name))
(define (prin1-string v) (elisp-prin1-to-string v))

;; A number is its digits, and a float is its own spelling.
(test-equal "24" (prin1-string 24))
(test-equal "-7" (prin1-string -7))
(test-equal "3.5" (prin1-string 3.5))

;; A string is quoted, and a quote or a backslash inside it is escaped -
;; which is exactly what `(write "a\"b")' would *not* give, being the same
;; text with Scheme's own spelling.
(test-equal "\"plain\"" (prin1-string "plain"))
(test-equal "\"a\\\"b\"" (prin1-string "a\"b"))
(test-equal "\"a\\\\b\"" (prin1-string "a\\b"))

;; A newline is printed as itself by default and as `\n' when
;; `print-escape-newlines' is on (`print.c:2928').
(test-equal "\"a\nb\"" (prin1-string "a\nb"))
(test-equal "\"a\\nb\""
  (parameterize ((*print-escape-newlines* #t)) (prin1-string "a\nb")))

;; `nil' and `t' are symbols here, and this is the row `(write ...)' gets
;; wrong: Scheme would say `#f' and `#t', and neither reads back as Lisp.
(test-equal "nil" (prin1-string nil))
(test-equal "t" (prin1-string t))

(test-equal "a" (prin1-string (sym "a")))
(test-equal "a-b" (prin1-string (sym "a-b")))
;; "CONFUSING" names (`print.c:2476'): a name that reads as a number, or
;; that begins with `?' or with a `.` not followed by a letter, gets its
;; first character escaped. `1+' does not read as a number, so it is plain.
(test-equal "1+" (prin1-string (sym "1+")))
(test-equal "\\?" (prin1-string (sym "?")))

;; A list is its elements, and a pair that is not a list is dotted.
(test-equal "(1 2 3)" (prin1-string (list 1 2 3)))
(test-equal "(1 . 2)" (prin1-string (cons 1 2)))
(test-equal "(1 (2 3))" (prin1-string (list 1 (list 2 3))))
(test-equal "()" (prin1-string '()))

;; `print-quoted' (`print.c:676', t) prints the reader syntax rather than
;; the three-element list; off, it prints the list.
(test-equal "'a" (prin1-string (list (sym "quote") (sym "a"))))
(test-equal "(quote a)"
  (parameterize ((*print-quoted* #f))
    (prin1-string (list (sym "quote") (sym "a")))))
(test-equal "#'a" (prin1-string (list (sym "function") (sym "a"))))
(test-equal "`a" (prin1-string (list (sym "backquote") (sym "a"))))

;; `print-length' and `print-level' (`print.c:2918', `:2923') abbreviate a
;; long list and a deep one. Both are nil here by default, which is why
;; the first row is not abbreviated.
(test-equal "(1 2 3 4)" (prin1-string (list 1 2 3 4)))
(test-equal "(1 2 ...)"
  (parameterize ((*print-length* 2)) (prin1-string (list 1 2 3 4))))
(test-equal "(...)"
  (parameterize ((*print-length* 0)) (prin1-string (list 1 2 3 4))))
(test-equal "(1 (2 3))" (prin1-string (list 1 (list 2 3))))
(test-equal "(1 ...)"
  (parameterize ((*print-level* 1)) (prin1-string (list 1 (list 2 3)))))

;; `princ' is `prin1' without the quotes and the escapes.
(test-equal "plain"
  (call-with-port (open-output-string)
    (lambda (port) (elisp-princ "plain" port) (get-output-string port))))
(test-equal "a\"b"
  (call-with-port (open-output-string)
    (lambda (port) (elisp-princ "a\"b" port) (get-output-string port))))

(test-end "schemacs_elisp_eval_print")
