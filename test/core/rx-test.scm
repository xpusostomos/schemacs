;; Tests for `(schemacs core rx)': the whole of GNU Emacs's
;; `lisp/emacs-lisp/rx.el' - the sexp-to-regexp translator, the `rx'
;; macro with its delayed `literal'/`regexp' forms, `rx-define',
;; `rx-let-eval' and the `(pcase ... (rx ...))' pattern.
;;
;; Every expectation in `rx_to_string' is GNU Emacs 31.1's own
;; `(rx-to-string FORM t)' answer for the same form - the differential
;; in the handoff, byte for byte, over the forms Groovy's modes use
;; plus rx's own examples.  One form from that differential is NOT
;; here: `(eval (any "0-9"))' errors on both sides with different text,
;; because an `eval' form is evaluated in THIS library's module where
;; Emacs evaluates it in the caller's obarray (named in the library
;; header).  Its working spelling is in the table as
;; `(eval (list (quote seq) "0-9"))'.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs core rx)
 (schemacs core pcase)
 (schemacs search))

(test-begin "schemacs_core_rx_to_string")
(test-equal "(seq \"a\" \"b\")"
            "ab"
            (rx-to-string '(seq "a" "b") #t))
(test-equal "(seq bol \"foo\" eol)"
            "^foo$"
            (rx-to-string '(seq bol "foo" eol) #t))
(test-equal "(or \"abc\" \"abd\" \"x\")"
            "\\(?:ab[cd]\\|x\\)"
            (rx-to-string '(or "abc" "abd" "x") #t))
(test-equal "(any \"a-z\" digit)"
            "[a-z[:digit:]]"
            (rx-to-string '(any "a-z" digit) #t))
(test-equal "(* nonl)"
            ".*"
            (rx-to-string '(* nonl) #t))
(test-equal "(seq \"a\" (group \"b\") (group-n 3 \"c\") (backref 1))"
            "a\\(b\\)\\(?3:c\\)\\1"
            (rx-to-string '(seq "a" (group "b") (group-n 3 "c") (backref 1)) #t))
(test-equal "(repeat 3 \"x\")"
            "x\\{3\\}"
            (rx-to-string '(repeat 3 "x") #t))
(test-equal "(repeat 2 4 \"y\")"
            "y\\{2,4\\}"
            (rx-to-string '(repeat 2 4 "y") #t))
(test-equal "(>= 2 \"z\")"
            "z\\{2,\\}"
            (rx-to-string '(>= 2 "z") #t))
(test-equal "(= 4 \"q\")"
            "q\\{4\\}"
            (rx-to-string '(= 4 "q") #t))
(test-equal "(seq (? \"m\") (?? \"n\") (*? \"o\") (+? \"p\"))"
            "m?n??o*?p+?"
            (rx-to-string '(seq (? "m") (?? "n") (*? "o") (+? "p")) #t))
(test-equal "(minimal-match (* \"a\"))"
            "a*"
            (rx-to-string '(minimal-match (* "a")) #t))
(test-equal "(syntax word)"
            "\\w"
            (rx-to-string '(syntax word) #t))
(test-equal "(not-syntax word)"
            "\\W"
            (rx-to-string '(not-syntax word) #t))
(test-equal "(category digit)"
            "\\c6"
            (rx-to-string '(category digit) #t))
(test-equal "(not (any \"a\" \"b\"))"
            "[^ab]"
            (rx-to-string '(not (any "a" "b")) #t))
(test-equal "(not (any \"\\\\\"))"
            "[^\\]"
            (rx-to-string '(not (any "\\")) #t))
(test-equal "(intersection (any \"a-z\") (any \"m-z\"))"
            "[m-z]"
            (rx-to-string '(intersection (any "a-z") (any "m-z")) #t))
(test-equal "(seq word-boundary \"hi\" symbol-start)"
            "\\bhi\\_<"
            (rx-to-string '(seq word-boundary "hi" symbol-start) #t))
(test-equal "(literal \"a.b\")"
            "a\\.b"
            (rx-to-string '(literal "a.b") #t))
(test-equal "(regexp \"^x\")"
            "^x"
            (rx-to-string '(regexp "^x") #t))
(test-equal "(seq symbol-start (group (or (seq (+ upper) lower (0+ (or (syntax symbol) (syntax word)))) (seq (+ upper) (+ upper)))) symbol-end)"
            "\\_<\\([[:upper:]]+[[:lower:]]\\(?:\\s_\\|\\w\\)*\\|[[:upper:]]+[[:upper:]]+\\)\\_>"
            (rx-to-string '(seq symbol-start (group (or (seq (+ upper) lower (0+ (or (syntax symbol) (syntax word)))) (seq (+ upper) (+ upper)))) symbol-end) #t))
(test-equal "(seq (* space) symbol-start (group (* (seq (or (syntax word) (syntax symbol)) (* space)))))"
            "[[:space:]]*\\_<\\(\\(?:\\(?:\\w\\|\\s_\\)[[:space:]]*\\)*\\)"
            (rx-to-string '(seq (* space) symbol-start (group (* (seq (or (syntax word) (syntax symbol)) (* space))))) #t))
(test-equal "(seq symbol-start (group (+ (or (syntax word) (syntax symbol)))) symbol-end)"
            "\\_<\\(\\(?:\\w\\|\\s_\\)+\\)\\_>"
            (rx-to-string '(seq symbol-start (group (+ (or (syntax word) (syntax symbol)))) symbol-end) #t))
(test-equal "(seq line-start (0+ space) (0+ (or \"abstract\" \"public\") (+ space)) \"interface\" (+ space))"
            "^[[:space:]]*\\(?:\\(?:abstract\\|public\\)[[:space:]]+\\)*interface[[:space:]]+"
            (rx-to-string '(seq line-start (0+ space) (0+ (or "abstract" "public") (+ space)) "interface" (+ space)) #t))
(test-equal "(seq \"@\" symbol-start (+ (or (syntax word) (syntax symbol))) symbol-end)"
            "@\\_<\\(?:\\w\\|\\s_\\)+\\_>"
            (rx-to-string '(seq "@" symbol-start (+ (or (syntax word) (syntax symbol))) symbol-end) #t))
(test-equal "(or line-start space)"
            "^\\|[[:space:]]"
            (rx-to-string '(or line-start space) #t))
(test-equal "(or (seq symbol-start \"print\" symbol-end) (seq symbol-start \"printf\" symbol-end))"
            "\\_<print\\_>\\|\\_<printf\\_>"
            (rx-to-string '(or (seq symbol-start "print" symbol-end) (seq symbol-start "printf" symbol-end)) #t))
(test-equal "(seq (not (any \"\\\\\")) (group \"$\" (+ (or (syntax word) (syntax symbol))) symbol-end (? \".\" (+ (or (syntax word) (syntax symbol))) symbol-end)))"
            "[^\\]\\(\\$\\(?:\\w\\|\\s_\\)+\\_>\\(?:\\.\\(?:\\w\\|\\s_\\)+\\_>\\)?\\)"
            (rx-to-string '(seq (not (any "\\")) (group "$" (+ (or (syntax word) (syntax symbol))) symbol-end (? "." (+ (or (syntax word) (syntax symbol))) symbol-end))) #t))
(test-equal "(seq buffer-start \"#\")"
            "\\`#"
            (rx-to-string '(seq buffer-start "#") #t))
(test-equal "(seq \"/\" (not (any \"/\" \"*\")))"
            "/[^*/]"
            (rx-to-string '(seq "/" (not (any "/" "*"))) #t))
(test-equal "(or \"++\" \"--\")"
            "\\(?:\\+\\+\\|--\\)"
            (rx-to-string '(or "++" "--") #t))
(test-equal "(or \">\" \"<\")"
            "[<>]"
            (rx-to-string '(or ">" "<") #t))
(test-equal "(seq point (* space) \"(\")"
            "\\=[[:space:]]*("
            (rx-to-string '(seq point (* space) "(") #t))
(test-equal "(seq point (* space) \",\" (* space))"
            "\\=[[:space:]]*,[[:space:]]*"
            (rx-to-string '(seq point (* space) "," (* space)) #t))
(test-equal "(seq (or bol \"(\" \";\" \",\" \"{\") (regexp \"\\\\_<\\\\(?:def\\\\|class\\\\)\\\\_>\") (seq (+ space)))"
            "\\(?:^\\|[(,;{]\\)\\(?:\\_<\\(?:def\\|class\\)\\_>\\)[[:space:]]+"
            (rx-to-string '(seq (or bol "(" ";" "," "{") (regexp "\\_<\\(?:def\\|class\\)\\_>") (seq (+ space))) #t))
(test-equal "(seq line-start (0+ space) (group (+ (or (syntax word) (syntax symbol)))) (* space) \"=\")"
            "^[[:space:]]*\\(\\(?:\\w\\|\\s_\\)+\\)[[:space:]]*="
            (rx-to-string '(seq line-start (0+ space) (group (+ (or (syntax word) (syntax symbol)))) (* space) "=") #t))
(test-equal "(seq (group \"abc\") \"|\" (group \"def\"))"
            "\\(abc\\)|\\(def\\)"
            (rx-to-string '(seq (group "abc") "|" (group "def")) #t))
(test-equal "(seq (= 3 digit) \"-\" (>= 2 alpha))"
            "[[:digit:]]\\{3\\}-[[:alpha:]]\\{2,\\}"
            (rx-to-string '(seq (= 3 digit) "-" (>= 2 alpha)) #t))
(test-equal "(seq (not-char \"x\" \"y\"))"
            "[^xy]"
            (rx-to-string '(seq (not-char "x" "y")) #t))
(test-equal "(any \"A-Z\" \"a-z\" \"_\")"
            "[A-Z_a-z]"
            (rx-to-string '(any "A-Z" "a-z" "_") #t))
(test-equal "(seq bos (or \"a\" \"b\") eos)"
            "\\`[ab]\\'"
            (rx-to-string '(seq bos (or "a" "b") eos) #t))
(test-equal "(or)"
            "\\`a\\`"
            (rx-to-string '(or) #t))
(test-equal "(seq)"
            ""
            (rx-to-string '(seq) #t))
(test-equal "(seq (? \"a\") (repeat 0 1 \"b\"))"
            "a?b\\{0,1\\}"
            (rx-to-string '(seq (? "a") (repeat 0 1 "b")) #t))
(test-equal "(seq (group-n 1 \"x\") (backref 1))"
            "\\(?1:x\\)\\1"
            (rx-to-string '(seq (group-n 1 "x") (backref 1)) #t))
(test-equal "(seq anychar anything nonl)"
            "[^z-a][^z-a]."
            (rx-to-string '(seq anychar anything nonl) #t))
(test-equal "(seq (syntax whitespace) (syntax punctuation) (syntax string-delimiter))"
            "\\s-\\s.\\s|"
            (rx-to-string '(seq (syntax whitespace) (syntax punctuation) (syntax string-delimiter)) #t))
(test-equal "(seq (category space-for-indent) (category latin))"
            "\\c \\cl"
            (rx-to-string '(seq (category space-for-indent) (category latin)) #t))
(test-end "schemacs_core_rx_to_string")


;;--------------------------------------------------------------------
;; The macro: literal/regexp with values, and rx-define / rx-let-eval.
;; Emacs 31.1's answers for the same definitions.
;;--------------------------------------------------------------------
(test-begin "schemacs_core_rx_macro")
(define rx-test-literal "a.b")
(test-equal "a literal form quotes its runtime string" "a\\.b"
            (rx (literal rx-test-literal)))
(define rx-test-regexp "^x")
(test-equal "a regexp form passes its string through" "q\\(?:^x\\)"
            (rx "q" (regexp rx-test-regexp)))
(test-equal "a literal between strings" "aa\\.bb"
            (rx "a" (literal rx-test-literal) "b"))

(rx-define rx-test-word (+ (syntax word)))
(test-equal "rx-define defines an alias for the rx macro" "\\w+"
            (rx rx-test-word))
(test-equal "and for rx-to-string" "\\(?:\\w+\\)"
            (rx-to-string 'rx-test-word))
(rx-define rx-test-two (a b) (seq a "-" b))
(test-equal "rx-define with an argument list substitutes" "x-y"
            (rx (rx-test-two "x" "y")))
(test-equal "rx-let-eval binds a local definition" "\\(?:hi!\\)"
            (rx-let-eval '((rx-test-greeting "hi"))
                         (rx-to-string '(seq rx-test-greeting "!"))))
(test-end "schemacs_core_rx_macro")

;;--------------------------------------------------------------------
;; The pcase pattern - Emacs 31.1's answers for the same patterns.
;;--------------------------------------------------------------------
(test-begin "schemacs_core_rx_pcase")
(test-equal "a let binds the submatch" "b"
            (pcase "abc" ((rx "a" (let x "b")) x) (_ 'no)))
(test-equal "a non-matching string" 'no
            (pcase "zzz" ((rx "a") 'yes) (_ 'no)))
(test-equal "an empty pattern matches any string" 'empty-ok
            (pcase "abc" ((rx) 'empty-ok) (_ 'no)))
(test-equal "a named backref that does not match" 'no
            (pcase "a-b" ((rx (let x (+ (or (syntax word) (syntax symbol))))
                               "-" (backref x))
                          x)
                   (_ 'no)))
;; **The expansion is pure data.** A procedure object in it would make
;; the pattern unusable in a compiled library: Guile refuses a procedure
;; as a source constant at every optimization level ("unhandled
;; constant #<procedure>"), so a pattern carrying a closure crashes the
;; compiler rather than merely running slowly. The match procedures are
;; named (`rx--pcase-pred' and friends) and called with the regexp.
(test-assert "the expansion holds no procedures (it must compile)"
  (let walk ((d (pcase--macroexpand '(rx "a" (let x "b")))))
    (cond ((procedure? d) #f)
          ((pair? d) (and (walk (car d)) (walk (cdr d))))
          (else #t))))
(test-end "schemacs_core_rx_pcase")
