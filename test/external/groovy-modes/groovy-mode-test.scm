;; Tests for `(schemacs external groovy-modes groovy-mode)', transcribed
;; from the package's own `test/groovy-unit-test.el' (the upstream
;; Groovy-Emacs-Modes repository). Every `should-indent-to` and
;; `should-preserve-indent` pair is one test here, with the same source
;; and the same expected result; every `with-highlighted-groovy` body is
;; transcribed with its assertions.
;;
;; **The expectations are the upstream file's**, and each was also
;; measured against Emacs 31.1 with the same groovy-mode: the indentation
;; differential over these 51 pairs is byte-identical, and the face
;; differential over the whole file's snippets is run-for-run identical
;; (see DEPARTURES.md). `ert' becomes `srfi 64' and the two macros become
;; procedures, which is the whole of the translation.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) generate-new-buffer current-buffer set-buffer
       set-buffer-local-value! buffer-local-value)
 (only (schemacs editfns) insert buffer-string buffer-substring-no-properties
       point point-min point-max goto-char char-after buffer-substring)
 (only (schemacs textprop) get-text-property)
 (only (schemacs search) search-forward)
 (only (schemacs cmds) backward-char forward-char)
 (only (schemacs indent) indent-region)
 (only (schemacs indentc) *indent-tabs-mode*)
 (only (schemacs font-lock) font-lock-ensure)
 (only (schemacs fns) nth)
 (only (schemacs electric) electric-indent-chars)
 (only (schemacs imenu) imenu-generic-expression imenu--make-index-alist
       *imenu-use-markers*)
 (schemacs external groovy-modes groovy-mode))

;;-------------------------------------------------------------
;; The macros, as procedures
;;-------------------------------------------------------------
(define (with-temp-groovy src thunk)
  ;; `(with-temp-buffer (insert SRC) (groovy-mode) ...)': a fresh buffer
  ;; per call, so no test sees another's mode state.
  (let ((b (generate-new-buffer "*groovy-test*")))
    (set-buffer b)
    (insert src)
    (groovy-mode)
    (thunk)))

(define (with-highlighted-groovy src thunk)
  ;; `with-highlighted-groovy': insert, `groovy-mode', and fontify the
  ;; whole buffer before THUNK runs.
  (with-temp-groovy src
    (lambda ()
      ;; The C's `(goto-char (point-min))' before fontifying - the
      ;; searches in the test bodies start from point.
      (goto-char (point-min))
      (font-lock-ensure)
      (thunk))))

(define (should-indent-to src expected)
  ;; `should-indent-to': indent the whole buffer and answer the result,
  ;; which `test-equal' compares with EXPECTED.
  (with-temp-groovy src
    (lambda ()
      (parameterize ((*indent-tabs-mode* #f))
        (indent-region (point-min) (point-max)))
      (buffer-substring-no-properties (point-min) (point-max)))))

(define (should-preserve-indent src) (should-indent-to src src))

(define (faces-at-point)
  (let ((faces (get-text-property (point) 'face)))
    (if (list? faces) faces (list faces))))

(define (face-at-point)
  (let ((faces (get-text-property (point) 'face)))
    (if (list? faces) (car faces) faces)))

(test-begin "schemacs_external_groovy_mode")

;;-------------------------------------------------------------
(test-begin "schemacs_groovy_mode_smoke")
(test-assert "groovy-mode activates"
  (with-temp-groovy ""
    (lambda () (eq? (buffer-local-value (current-buffer) 'major-mode)
                    'groovy-mode))))
(test-end "schemacs_groovy_mode_smoke")

;;-------------------------------------------------------------
;; Indentation - one test per `should-indent-to'/`should-preserve-indent'
;; pair, in the upstream file's order.
;;-------------------------------------------------------------
(test-begin "schemacs_groovy_mode_indent")
(test-equal "case 01" "#!/usr/bin/env groovy\nprintln 'Hello from the shebang line'" ;; case 01 (preserve)
            (should-indent-to "#!/usr/bin/env groovy\nprintln 'Hello from the shebang line'" "#!/usr/bin/env groovy\nprintln 'Hello from the shebang line'"))
(test-equal "case 02" "\ndef foo() {\n    bar()\n}" ;; case 02 (indent-to)
            (should-indent-to "\ndef foo() {\nbar()\n}" "\ndef foo() {\n    bar()\n}"))
(test-equal "case 03" "\ndef foo() { // blah\n    def bar = 123\n}" ;; case 03 (preserve)
            (should-indent-to "\ndef foo() { // blah\n    def bar = 123\n}" "\ndef foo() { // blah\n    def bar = 123\n}"))
(test-equal "case 04" "\n/* if for while else */\ndef foo = true" ;; case 04 (preserve)
            (should-indent-to "\n/* if for while else */\ndef foo = true" "\n/* if for while else */\ndef foo = true"))
(test-equal "case 05" "\n// if for while else\ndef foo = true" ;; case 05 (preserve)
            (should-indent-to "\n// if for while else\ndef foo = true" "\n// if for while else\ndef foo = true"))
(test-equal "case 06" "\ndef foo = 'if for while else'\ndef bar = true" ;; case 06 (preserve)
            (should-indent-to "\ndef foo = 'if for while else'\ndef bar = true" "\ndef foo = 'if for while else'\ndef bar = true"))
(test-equal "case 07" "\nwhile (true)\n    foo()" ;; case 07 (preserve)
            (should-indent-to "\nwhile (true)\n    foo()" "\nwhile (true)\n    foo()"))
(test-equal "case 08" "\nfor (i = 0; i < 10; i++)\n    foo()" ;; case 08 (preserve)
            (should-indent-to "\nfor (i = 0; i < 10; i++)\n    foo()" "\nfor (i = 0; i < 10; i++)\n    foo()"))
(test-equal "case 09" "\nif (true)\n    foo()\nelse\n    bar()" ;; case 09 (preserve)
            (should-indent-to "\nif (true)\n    foo()\nelse\n    bar()" "\nif (true)\n    foo()\nelse\n    bar()"))
(test-equal "case 10" "\nif (true)\n    if (true)\n        foo()" ;; case 10 (preserve)
            (should-indent-to "\nif (true)\n    if (true)\n        foo()" "\nif (true)\n    if (true)\n        foo()"))
(test-equal "case 11" "\nif (x) bar()\nfoo()" ;; case 11 (preserve)
            (should-indent-to "\nif (x) bar()\nfoo()" "\nif (x) bar()\nfoo()"))
(test-equal "case 12" "\nif (x) { bar() }\nfoo()" ;; case 12 (preserve)
            (should-indent-to "\nif (x) { bar() }\nfoo()" "\nif (x) { bar() }\nfoo()"))
(test-equal "case 13" "\nbar()\nif (true)\n    foo()" ;; case 13 (preserve)
            (should-indent-to "\nbar()\nif (true)\n    foo()" "\nbar()\nif (true)\n    foo()"))
(test-equal "case 14" "\nif (true)\n    foo()\nbar()" ;; case 14 (preserve)
            (should-indent-to "\nif (true)\n    foo()\nbar()" "\nif (true)\n    foo()\nbar()"))
(test-equal "case 15" "\nif (true)\n    // stuff\n    foo()" ;; case 15 (preserve)
            (should-indent-to "\nif (true)\n    // stuff\n    foo()" "\nif (true)\n    // stuff\n    foo()"))
(test-equal "case 16" "\nwhile (true)\t\t\n    foo()" ;; case 16 (preserve)
            (should-indent-to "\nwhile (true)\t\t\n    foo()" "\nwhile (true)\t\t\n    foo()"))
(test-equal "case 17" "\nif (true) {\n    foo()\n}" ;; case 17 (preserve)
            (should-indent-to "\nif (true) {\n    foo()\n}" "\nif (true) {\n    foo()\n}"))
(test-equal "case 18" "\nif (x) foo() else\n    bar()" ;; case 18 (preserve)
            (should-indent-to "\nif (x) foo() else\n    bar()" "\nif (x) foo() else\n    bar()"))
(test-equal "case 19" "\nwhile (true)\n    if (x) foo()\n    else bar()" ;; case 19 (preserve)
            (should-indent-to "\nwhile (true)\n    if (x) foo()\n    else bar()" "\nwhile (true)\n    if (x) foo()\n    else bar()"))
(test-equal "case 20" "\nwhile (true)\n    if (x) foo()\n\nif (y) bar()\nelse baz()\n" ;; case 20 (preserve)
            (should-indent-to "\nwhile (true)\n    if (x) foo()\n\nif (y) bar()\nelse baz()\n" "\nwhile (true)\n    if (x) foo()\n\nif (y) bar()\nelse baz()\n"))
(test-equal "case 21" "\nwhile (a)\n\n    if (b) c()\n    else if (d) e()\n    else while (f)\n        for (;;)\n            if (g)\n                if (h) i()\n                else if (j) k()\n                else while (l) m()\n\nif (n) m()\n" ;; case 21 (preserve)
            (should-indent-to "\nwhile (a)\n\n    if (b) c()\n    else if (d) e()\n    else while (f)\n        for (;;)\n            if (g)\n                if (h) i()\n                else if (j) k()\n                else while (l) m()\n\nif (n) m()\n" "\nwhile (a)\n\n    if (b) c()\n    else if (d) e()\n    else while (f)\n        for (;;)\n            if (g)\n                if (h) i()\n                else if (j) k()\n                else while (l) m()\n\nif (n) m()\n"))
(test-equal "case 22" "\ndef a = b +\n    1" ;; case 22 (preserve)
            (should-indent-to "\ndef a = b +\n    1" "\ndef a = b +\n    1"))
(test-equal "case 23" "\ndef a = b+\n    1" ;; case 23 (preserve)
            (should-indent-to "\ndef a = b+\n    1" "\ndef a = b+\n    1"))
(test-equal "case 24" "\ndef a = 'foo'+\n    'bar'" ;; case 24 (preserve)
            (should-indent-to "\ndef a = 'foo'+\n    'bar'" "\ndef a = 'foo'+\n    'bar'"))
(test-equal "case 25" "\ndef a = b ||\n    1" ;; case 25 (preserve)
            (should-indent-to "\ndef a = b ||\n    1" "\ndef a = b ||\n    1"))
(test-equal "case 26" "\n// def a = b+\n1" ;; case 26 (preserve)
            (should-indent-to "\n// def a = b+\n1" "\n// def a = b+\n1"))
(test-equal "case 27" "\ndef x = /foo/\n1" ;; case 27 (preserve)
            (should-indent-to "\ndef x = /foo/\n1" "\ndef x = /foo/\n1"))
(test-equal "case 28" "\ndef a = b()+\n    1" ;; case 28 (preserve)
            (should-indent-to "\ndef a = b()+\n    1" "\ndef a = b()+\n    1"))
(test-equal "case 29" "\ndef a = b[3]+\n    1" ;; case 29 (preserve)
            (should-indent-to "\ndef a = b[3]+\n    1" "\ndef a = b[3]+\n    1"))
(test-equal "case 30" "\ndef a = b--+\n    1" ;; case 30 (preserve)
            (should-indent-to "\ndef a = b--+\n    1" "\ndef a = b--+\n    1"))
(test-equal "case 31" "\ndef a = b+++\n    1" ;; case 31 (preserve)
            (should-indent-to "\ndef a = b+++\n    1" "\ndef a = b+++\n    1"))
(test-equal "case 32" "def foo() {\n    label1:\n    bar()\n    baz()\n\n    label2:\n    test()\n    other_function_call()\n}" ;; case 32 (preserve)
            (should-indent-to "def foo() {\n    label1:\n    bar()\n    baz()\n\n    label2:\n    test()\n    other_function_call()\n}" "def foo() {\n    label1:\n    bar()\n    baz()\n\n    label2:\n    test()\n    other_function_call()\n}"))
(test-equal "case 33" "\nfunc arg1,\n    arg2" ;; case 33 (preserve)
            (should-indent-to "\nfunc arg1,\n    arg2" "\nfunc arg1,\n    arg2"))
(test-equal "case 34" "\nfunc 'arg1',\n    'arg2'" ;; case 34 (preserve)
            (should-indent-to "\nfunc 'arg1',\n    'arg2'" "\nfunc 'arg1',\n    'arg2'"))
(test-equal "case 35" "\ndef func(int a, int b) {\n    call_method 'arg1',\n        'arg2'\n    call_method [\n        'arg1',\n        'arg2',\n    ]\n}" ;; case 35 (preserve)
            (should-indent-to "\ndef func(int a, int b) {\n    call_method 'arg1',\n        'arg2'\n    call_method [\n        'arg1',\n        'arg2',\n    ]\n}" "\ndef func(int a, int b) {\n    call_method 'arg1',\n        'arg2'\n    call_method [\n        'arg1',\n        'arg2',\n    ]\n}"))
(test-equal "case 36" "\ndef func(int a, int b) {\n    call_method arg1: /arg1/,\n        arg2: /arg2/\n}" ;; case 36 (preserve)
            (should-indent-to "\ndef func(int a, int b) {\n    call_method arg1: /arg1/,\n        arg2: /arg2/\n}" "\ndef func(int a, int b) {\n    call_method arg1: /arg1/,\n        arg2: /arg2/\n}"))
(test-equal "case 37" "\nfoobar(\n    baz: 1,\n    biz: 2,\n)" ;; case 37 (preserve)
            (should-indent-to "\nfoobar(\n    baz: 1,\n    biz: 2,\n)" "\nfoobar(\n    baz: 1,\n    biz: 2,\n)"))
(test-equal "case 38" "\ndef foo() {\n    def f = { ->\n        \"foo\"\n    }\n}" ;; case 38 (preserve)
            (should-indent-to "\ndef foo() {\n    def f = { ->\n        \"foo\"\n    }\n}" "\ndef foo() {\n    def f = { ->\n        \"foo\"\n    }\n}"))
(test-equal "case 39" "\ndef foo() {\n    def f = { def bar ->\n        \"foo\"\n    }\n}" ;; case 39 (preserve)
            (should-indent-to "\ndef foo() {\n    def f = { def bar ->\n        \"foo\"\n    }\n}" "\ndef foo() {\n    def f = { def bar ->\n        \"foo\"\n    }\n}"))
(test-equal "case 40" "\ndef x = [[\n    1\n]]" ;; case 40 (preserve)
            (should-indent-to "\ndef x = [[\n    1\n]]" "\ndef x = [[\n    1\n]]"))
(test-equal "case 41" "\nfoo\n    .bar()" ;; case 41 (preserve)
            (should-indent-to "\nfoo\n    .bar()" "\nfoo\n    .bar()"))
(test-equal "case 42" "\ntry {\n    foo()\n} finally {\n    bar()\n}" ;; case 42 (preserve)
            (should-indent-to "\ntry {\n    foo()\n} finally {\n    bar()\n}" "\ntry {\n    foo()\n} finally {\n    bar()\n}"))
(test-equal "case 43" "\nswitch (foo) {\n    case Class1:\n        bar()\n        break\n    default:\n        baz()\n}" ;; case 43 (preserve)
            (should-indent-to "\nswitch (foo) {\n    case Class1:\n        bar()\n        break\n    default:\n        baz()\n}" "\nswitch (foo) {\n    case Class1:\n        bar()\n        break\n    default:\n        baz()\n}"))
(test-equal "case 44" "\nswitch (foo) {\n    case Class1:\n        if (bar) {\n            bar()\n        }\n        break\n    default:\n        baz()\n}" ;; case 44 (preserve)
            (should-indent-to "\nswitch (foo) {\n    case Class1:\n        if (bar) {\n            bar()\n        }\n        break\n    default:\n        baz()\n}" "\nswitch (foo) {\n    case Class1:\n        if (bar) {\n            bar()\n        }\n        break\n    default:\n        baz()\n}"))
(test-equal "case 45" "\nswitch (foo) {\n    case Class1 :\n        bar()\n}" ;; case 45 (preserve)
            (should-indent-to "\nswitch (foo) {\n    case Class1 :\n        bar()\n}" "\nswitch (foo) {\n    case Class1 :\n        bar()\n}"))
(test-equal "case 46" "\nswitch (foo) {\n    case Class1:\n        x? y: z\n}" ;; case 46 (preserve)
            (should-indent-to "\nswitch (foo) {\n    case Class1:\n        x? y: z\n}" "\nswitch (foo) {\n    case Class1:\n        x? y: z\n}"))
(test-equal "case 47" "\ndef x = [\n    1,\n    2,\n]" ;; case 47 (preserve)
            (should-indent-to "\ndef x = [\n    1,\n    2,\n]" "\ndef x = [\n    1,\n    2,\n]"))
(test-equal "case 48" "\ndef x = [1,\n         2,\n         3,\n]" ;; case 48 (preserve)
            (should-indent-to "\ndef x = [1,\n         2,\n         3,\n]" "\ndef x = [1,\n         2,\n         3,\n]"))
(test-equal "case 49" "\ndef x = [\n    'a string ' +\n        'another string',\n    'another element'\n]" ;; case 49 (preserve)
            (should-indent-to "\ndef x = [\n    'a string ' +\n        'another string',\n    'another element'\n]" "\ndef x = [\n    'a string ' +\n        'another string',\n    'another element'\n]"))
(test-equal "case 50" "\n[1, 2, 3]\n    .findAll {\n        it % 2 == 0\n    }\n" ;; case 50 (preserve)
            (should-indent-to "\n[1, 2, 3]\n    .findAll {\n        it % 2 == 0\n    }\n" "\n[1, 2, 3]\n    .findAll {\n        it % 2 == 0\n    }\n"))
(test-equal "case 51" "\n[1, 2, 3]\n    .collect { it ->\n        it + 1\n    }\n" ;; case 51 (preserve)
            (should-indent-to "\n[1, 2, 3]\n    .collect { it ->\n        it + 1\n    }\n" "\n[1, 2, 3]\n    .collect { it ->\n        it + 1\n    }\n"))

(test-end "schemacs_groovy_mode_indent")

;;-------------------------------------------------------------
;; Highlighting - every `with-highlighted-groovy' body in the upstream
;; file, in its order.
;;-------------------------------------------------------------
(test-begin "schemacs_groovy_mode_highlight")

(test-assert "triple double quote: a lone quote inside is a string"
  (with-highlighted-groovy "x = \"\"\"foo \" bar \"\"\""
    (lambda ()
      (search-forward "bar")
      (eq? (face-at-point) 'font-lock-string-face))))

(test-assert "triple double quote: triple single quotes inside are a string"
  (with-highlighted-groovy "foo = \"\"\"aaa ''' bbb ''' ccc\"\"\""
    (lambda ()
      (search-forward "bbb")
      (eq? (face-at-point) 'font-lock-string-face))))

(test-assert "triple double quote: a / at its end does not confuse the comment"
  (with-highlighted-groovy "blah \"\"\"baz/\"\"\"\n// foo"
    (lambda ()
      (search-forward "f")
      (eq? (face-at-point) 'font-lock-comment-face))))

(test-assert "triple double quote: /$ inside it is not a dollar-slashy close"
  (with-highlighted-groovy "\"\"\"\n/$\n\"\"\"\nfoo = 1"
    (lambda ()
      (search-forward "foo")
      (not (eq? (face-at-point) 'font-lock-string-face)))))

(test-assert "triple single quote: a lone quote inside is a string"
  (with-highlighted-groovy "x = '''foo ' bar '''"
    (lambda ()
      (search-forward "bar")
      (eq? (face-at-point) 'font-lock-string-face))))

(test-assert "triple single quote: triple double quotes inside are a string"
  (with-highlighted-groovy "foo = '''xxx \"\"\" yyy \"\"\" zzz'''"
    (lambda ()
      (search-forward "yyy")
      (eq? (face-at-point) 'font-lock-string-face))))

(test-assert "an annotation is an annotation"
  (with-highlighted-groovy "@Test() private foo = 1"
    (lambda ()
      (search-forward "Test")
      (backward-char 1)
      (eq? (face-at-point) 'groovy-annotation-face))))

(test-assert "@interface is an annotation"
  (with-highlighted-groovy "public @interface Anno {}"
    (lambda ()
      (search-forward "interface")
      (backward-char 1)
      (eq? (face-at-point) 'groovy-annotation-face))))

(test-assert "a bare interface is a keyword"
  (with-highlighted-groovy "public interface Interface1 {}"
    (lambda ()
      (search-forward "interface")
      (backward-char 1)
      (eq? (face-at-point) 'font-lock-keyword-face))))

(test-assert "interpolation: $foo in a double-quoted string"
  (with-highlighted-groovy "x = \"$foo\""
    (lambda () (search-forward "$")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "interpolation: $foo in a triple-double-quoted string"
  (with-highlighted-groovy "x = \"\"\"$foo\"\"a\""
    (lambda () (search-forward "$")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "interpolation: an escaped \\$ is not interpolated"
  (with-highlighted-groovy "x = \"\\$foo\""
    (lambda () (search-forward "$")
      (not (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "interpolation: $foo$bar needs no separator"
  (with-highlighted-groovy "x = \"$foo$bar\""
    (lambda () (search-forward "b")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "interpolation: \\$$foo still interpolates"
  (with-highlighted-groovy "x = \"\\$$foo\""
    (lambda () (search-forward "f")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "interpolation: ${foo}"
  (with-highlighted-groovy "x = \"${foo}\""
    (lambda () (search-forward "f")
      (equal? '(font-lock-variable-name-face) (faces-at-point)))))
(test-assert "interpolation: ${foo}\\${bar} is escaped"
  (with-highlighted-groovy "x = \"${foo}\\${bar}"
    (lambda () (search-forward "b")
      (equal? '(font-lock-string-face) (faces-at-point)))))
(test-assert "interpolation: ${foo}\\\\${bar} is not escaped"
  (with-highlighted-groovy "x = \"${foo}\\\\${bar}"
    (lambda () (search-forward "b")
      (equal? '(font-lock-variable-name-face) (faces-at-point)))))
(test-assert "interpolation: ${foo}\\\\\\${bar} is escaped"
  (with-highlighted-groovy "x = \"${foo}\\\\\\${bar}"
    (lambda () (search-forward "b")
      (equal? '(font-lock-string-face) (faces-at-point)))))
(test-assert "interpolation: ${foo}\\\\\\\\${bar} is not escaped"
  (with-highlighted-groovy "x = \"${foo}\\\\\\\\${bar}"
    (lambda () (search-forward "b")
      (equal? '(font-lock-variable-name-face) (faces-at-point)))))

(test-assert "single quotes: $foo is a string"
  (with-highlighted-groovy "x = '$foo'"
    (lambda () (search-forward "$")
      (equal? '(font-lock-string-face) (faces-at-point)))))
(test-assert "single quotes: ${foo} is a string"
  (with-highlighted-groovy "x = '${foo}'"
    (lambda () (search-forward "f")
      (equal? '(font-lock-string-face) (faces-at-point)))))
(test-assert "single quotes: '''$foo''' is a string"
  (with-highlighted-groovy "x = '''$foo'''"
    (lambda () (search-forward "$")
      (equal? '(font-lock-string-face) (faces-at-point)))))
(test-assert "single quotes: '''${foo}''' is a string"
  (with-highlighted-groovy "x = '''${foo}'''"
    (lambda () (search-forward "f")
      (equal? '(font-lock-string-face) (faces-at-point)))))

(test-assert "slashy interpolation: /$foo/"
  (with-highlighted-groovy "x = /$foo/"
    (lambda () (search-forward "$")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "slashy interpolation: /$foo$bar/"
  (with-highlighted-groovy "x = /$foo$bar/"
    (lambda () (search-forward "b")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "slashy interpolation: /${foo}/"
  (with-highlighted-groovy "x = /${foo}/"
    (lambda () (search-forward "f")
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "slashy interpolation: a backslash escapes nothing but / there"
  (with-highlighted-groovy "x = /${foo}\\${bar}/"
    (lambda () (search-forward "b")
      (memq 'font-lock-variable-name-face (faces-at-point)))))

(test-assert "comments: // foo"
  (with-highlighted-groovy "// foo"
    (lambda () (search-forward " ")
      (memq 'font-lock-comment-face (faces-at-point)))))
(test-assert "comments: // alone is a comment, not an empty slashy string"
  (with-highlighted-groovy "// foo\n//\n"
    (lambda () (search-forward "\n") (backward-char 1)
      (memq 'font-lock-comment-face (faces-at-point)))))

(test-assert "slashy string: simple"
  (with-highlighted-groovy "x = /foo/"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))
(test-assert "slashy string: after ||"
  (with-highlighted-groovy "x || /foo/"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))
(test-assert "slashy string: multiline"
  (with-highlighted-groovy "x = \"bar\" + /foo\nbaz/"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))
(test-assert "slashy string: division is not a string"
  (with-highlighted-groovy "x = y / z"
    (lambda () (search-forward "z") (forward-char -1)
      (not (memq 'font-lock-string-face (faces-at-point))))))
(test-assert "slashy string: ending with $/ does not confuse it"
  (with-highlighted-groovy "x = /foo$/ + bar"
    (lambda () (search-forward "bar") (forward-char -1)
      (not (memq 'font-lock-string-face (faces-at-point))))))
(test-assert "slashy string: a tilde before / does not confuse it"
  (with-highlighted-groovy "somePattern = ~/+/;\nfinal int foo = -1;"
    (lambda () (search-forward "foo")
      (not (memq 'font-lock-string-face (faces-at-point))))))
(test-assert "slashy string: comments do not confuse it"
  (with-highlighted-groovy "def bar /* foo */"
    (lambda () (search-forward "foo")
      (not (memq 'font-lock-string-face (faces-at-point))))))
(test-assert "slashy string: an escaped backslash before the close"
  (with-highlighted-groovy "x = /foo\\// + bar"
    (lambda () (search-forward "bar") (forward-char -1)
      (not (memq 'font-lock-string-face (faces-at-point))))))

(test-assert "slashy string: a later argument"
  (with-highlighted-groovy "text.replaceAll(abc, /foo/)"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))

(test-assert "slashy string: containing $"
  (with-highlighted-groovy "x = /$ foo $/"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))

(test-assert "dollar-slashy string: contents"
  (with-highlighted-groovy "x = $/foo/$"
    (lambda () (search-forward "foo")
      (memq 'font-lock-string-face (faces-at-point)))))
(test-assert "dollar-slashy string: later code is not a string"
  (with-highlighted-groovy "x = $/foo/$\nbar"
    (lambda () (search-forward "b")
      (not (memq 'font-lock-string-face (faces-at-point))))))

(test-assert "variable assignment: x = 1"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "x = 1"
      (lambda () (search-forward "x") (backward-char 1)
        (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "variable assignment: in an if"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "if (x = \"foo\") {"
      (lambda () (search-forward "x") (backward-char 1)
        (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "variable assignment: after a declaration"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "Foo y; x = 1"
      (lambda () (search-forward "x") (backward-char 1)
        (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "variable assignment: =~ is not an assignment"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "(x =~ /bar/)"
      (lambda () (search-forward "x") (backward-char 1)
        (not (memq 'font-lock-variable-name-face (faces-at-point)))))))
(test-assert "variable assignment: == is not an assignment"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "x == bar"
      (lambda () (search-forward "x") (backward-char 1)
        (not (memq 'font-lock-variable-name-face (faces-at-point)))))))
(test-assert "variable assignment: a named annotation argument is not an assignment"
  (parameterize ((*groovy-highlight-assignments* #t))
    (with-highlighted-groovy "@Foo(x=false)"
      (lambda () (search-forward "x") (backward-char 1)
        (not (memq 'font-lock-variable-name-face (faces-at-point)))))))

(test-assert "variable declaration: def x"
  (with-highlighted-groovy "def x"
    (lambda () (search-forward "x") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: private String x = 1"
  (with-highlighted-groovy "private String x = 1"
    (lambda () (search-forward "x") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: after another declaration"
  (with-highlighted-groovy "Foo x; def y = 1"
    (lambda () (search-forward "x") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: parameterized type"
  (with-highlighted-groovy "List<Map<String, Object>> x"
    (lambda () (search-forward "x") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: a comma list"
  (with-highlighted-groovy "String a, b, c, d"
    (lambda () (search-forward "b") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: def (a, b, c) = [1, 2, 3]"
  (with-highlighted-groovy "def (a, b, c) = [1, 2, 3]"
    (lambda () (search-forward "b") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: in a closure parameter list"
  (with-highlighted-groovy "[:].each { String x, def y ->"
    (lambda () (search-forward "y") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))
(test-assert "variable declaration: a method parameter"
  (with-highlighted-groovy "private void fooBar(Foo x) {"
    (lambda () (search-forward "x") (backward-char 1)
      (memq 'font-lock-variable-name-face (faces-at-point)))))

(test-assert "not a variable: in a list literal"
  (with-highlighted-groovy "def (a, b, c) = [1, x, 3]"
    (lambda () (search-forward "x") (backward-char 1)
      (not (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "not a variable: as a call argument"
  (with-highlighted-groovy "def (a, b, c) = foo(1, x, 3)"
    (lambda () (search-forward "x") (backward-char 1)
      (not (memq 'font-lock-variable-name-face (faces-at-point))))))
(test-assert "not a variable: a bare symbol"
  (with-highlighted-groovy "x"
    (lambda ()
      (not (memq 'font-lock-variable-name-face (faces-at-point))))))

(test-assert "function name: void fooBar"
  (with-highlighted-groovy "private void fooBar(Foo x) {"
    (lambda () (search-forward "foo")
      (memq 'font-lock-function-name-face (faces-at-point)))))
(test-assert "function name: List<String> fooBar"
  (with-highlighted-groovy "private List<String> fooBar() {"
    (lambda () (search-forward "foo")
      (memq 'font-lock-function-name-face (faces-at-point)))))

(test-equal "groovy--remove-comments: nothing to remove"
  "foo\nbar" (groovy--remove-comments "foo\nbar"))
(test-equal "groovy--remove-comments: a line comment"
  "foo " (groovy--remove-comments "foo // bar"))
(test-equal "groovy--remove-comments: a block comment"
  "foo  baz" (groovy--remove-comments "foo /* bar */ baz"))

(test-end "schemacs_groovy_mode_highlight")


(test-begin "schemacs_groovy_mode_wiring")

;; The two mode-body installations the tree now has the machines for
;; (`groovy-mode.el:1006' and `:1010'), and what the installed imenu
;; expression indexes. Emacs 31.1 with these three expressions and this
;; fixture answers Classes=(Foo), Interfaces=(I), Closures=(bar).
(with-temp-groovy "class Foo {\n  interface I {\n  }\n  def bar = {\n  }\n}\n"
  (lambda ()
    (test-equal "groovy-mode installs its imenu expression"
                groovy-imenu-regexp
                (imenu-generic-expression))
    (test-assert "and extends electric-indent-chars with its braces"
                 (let ((chars (electric-indent-chars)))
                   (and (memv (char->integer #\{) chars)
                        (memv (char->integer #\}) chars)
                        (memv 10 chars)
                        (= (length chars) 10))))
    (let ((index (parameterize ((*imenu-use-markers* #f))
                   (imenu--make-index-alist))))
      (define (names title)
        (let ((entry (assoc title index)))
          (and entry (map car (cdr entry)))))
      (test-equal "imenu finds the class" '("Foo") (names "Classes"))
      (test-equal "the interface" '("I") (names "Interfaces"))
      (test-equal "and the closure" '("bar") (names "Closures")))))

(test-end "schemacs_groovy_mode_wiring")

(test-end "schemacs_external_groovy_mode")
