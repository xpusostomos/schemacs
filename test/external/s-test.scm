;; Tests for `(schemacs external s)', the s.el subset the Groovy modes
;; use.  Every expectation is the installed s.el's own answer, measured
;; in a batch Emacs with s on the load path.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs external s))

(test-begin "schemacs_external_s")
(test-equal "s-trim" "hello" (s-trim "  hello \n"))
(test-equal "s-trim-left" "x " (s-trim-left "\t x "))
(test-equal "s-trim-right" " x" (s-trim-right " x \r"))
(test-equal "s-split keeps empty fields" '("a" "b" "" "c")
            (s-split "," "a,b,,c"))
(test-equal "s-split with OMIT-NULLS" '("a" "b" "c")
            (s-split "," "a,b,,c" #t))
(test-assert "s-starts-with?" (s-starts-with? "foo" "foobar"))
(test-assert "the s-prefix alias and IGNORE-CASE"
             (s-starts-with-p "FOO" "foobar" #t))
(test-assert "s-ends-with?" (s-ends-with? "bar" "foobar"))
(test-assert "the s-suffix alias and IGNORE-CASE"
             (s-ends-with-p "BAR" "foobar" #t))
(test-assert "a suffix longer than the string does not match"
             (not (s-ends-with? "foobar" "bar")))
(test-assert "s-matches?" (s-matches? "^a.c$" "abc"))
(test-assert "a failed match is false, not the empty list"
             (not (s-matches-p "^c" "abc" 2)))
(test-assert "s-blank? of the empty string" (s-blank? ""))
(test-assert "s-blank? of nil" (s-blank? #f))
(test-assert "s-blank-str? of whitespace" (s-blank-str? "  \t"))
(test-assert "s-blank-str? of a word" (not (s-blank-str-p "x")))
(test-end "schemacs_external_s")
