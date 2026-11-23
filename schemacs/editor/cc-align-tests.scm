;; Tests for `(schemacs editor cc-align)': the line-up functions, each
;; called directly the way a line-up function is called - at a position,
;; with `c-syntactic-element' and `c-syntactic-context' bound - and
;; compared with Emacs 31.1's answer for the same call on the same text.
;;
;; The case table and the answers are `tools/cc-align-diff''s: that
;; harness runs the identical table through a running Emacs and through
;; this tree, and these are the Emacs answers it printed. An answer of
;; `error' is Emacs raising for that synthetic call; the port must raise
;; too. `c-gnu-impose-minimum''s answer is the line's indentation after
;; it ran.
;;
;; The mode replay is the other cc differentials': the language
;; variables, the syntax table, the gnu style, and (C++) the `<>'
;; properties `c-common-init' leaves.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor buffer) (schemacs editor editfns)
 (schemacs editor syntax) (schemacs editor cmds)
 (schemacs editor command)
 (only (schemacs editor search) search-forward)
 (only (schemacs editor indentc) current-indentation current-column)
 (schemacs editor cc-defs) (schemacs editor cc-langs)
 (schemacs editor cc-vars) (schemacs editor cc-styles)
 (schemacs editor cc-engine)
 (schemacs editor cc-align))

(define answers-c
  (list
    'error
    #f
    'error
    (vector 22)
    (vector 15)
    (vector 20)
    (vector 12)
    #t
    'error
    #f
    (vector 7)
    (vector 7)
    (vector 6)
    (vector 6)
    (vector 5)
    2
    2
    #f
    #f
    (vector 0)
    0
    0
    (vector 1)
    #f
    #f
    2
    (vector 11)
    (vector 25)
    'error
    4
    'stop
    #t
    #f
    'stop
    (vector 0)
    (vector 4)
    (vector 4)
    2
    (vector 4)
    5
    7
    9
    9))

(define answers-cpp
  (list
    (vector 10)
    (vector 4)
    2
    (vector 11)
    'c-lineup-arglist-intro-after-paren
    #f
    #f
    'stop))

(define cases-c
  '((assign-stmt c-lineup-assignments statement-cont ("+ c;" 0) ("+ c;" 0) #f)
    (assign-arg c-lineup-assignments arglist-cont-nonempty ("b);" 0) ("bar (" 0) ("bar (" 9))
    (math-stmt c-lineup-math statement-cont ("+ c;" 0) ("+ c;" 0) #f)
    (ternary c-lineup-ternary-bodies statement-cont (": (3 * arg" 0) ("return arg % 2" 0) #f)
    (cascaded c-lineup-cascaded-calls statement-cont ("->add (19)" 0) ("result = proc" 0) #f)
    (string-cont c-lineup-string-cont statement-cont ("string." 0) ("result = prefix" 0) #f)
    (argcont c-lineup-argcont arglist-cont ("+ ddd + eee" 0) ("foo (xyz" 0) #f)
    (argcont-1 c-lineup-argcont-1 arglist-cont ("+ ddd + eee" 0) ("foo (xyz" 0) #f)
    (argcont-plus c-lineup-argcont-+ arglist-cont ("+ ddd + eee" 0) ("foo (xyz" 0) #f)
    (argcont-scan c-lineup-argcont-scan arglist-cont ("+ ddd + eee" 0) ("foo (xyz" 0) #f)
    (arglist c-lineup-arglist arglist-cont-nonempty ("+ ddd" 0) ("foo (xyz" 0) ("foo (xyz" 4))
    (arglist-intro c-lineup-arglist-intro-after-paren arglist-intro ("+ ddd" 0) ("foo (xyz" 0) #f)
    (arglist-close-under c-lineup-arglist-close-under-paren arglist-close ("b);" 0) ("bar (" 0) ("bar (" 4))
    (close-paren c-lineup-close-paren arglist-close ("b);" 0) ("bar (" 0) ("bar (" 4))
    (arglist-operators c-lineup-arglist-operators arglist-cont-nonempty ("|| at_limit" 0) ("if (x < 10" 0) ("if (x < 10" 3))
    (indent-one c-indent-one-line-block defun-block-intro ("{m+=n; n=0;}" 0) ("void bare" 17) #f)
    (indent-multi c-indent-multi-line-block brace-list-intro ("{ 17," 0) ("int *foo[] = {" 0) ("int *foo[] = {" 13))
    (item-after-paren c-lineup-item-after-paren-at-boi brace-list-intro ("{ 17," 0) ("int *foo[] = {" 0) ("int *foo[] = {" 13))
    (runin c-lineup-runin-statements statement ("puts (\"Hello" 0) ("{ puts" 2) #f)
    (knr-comment c-lineup-knr-region-comment comment-intro ("/* This is the main" 0) ("/* This is the main" 0) #f
                 (func-decl-cont "/* This is the main" 0))
    (comment-anchored c-lineup-comment comment-intro ("* continuation" 0) ("* continuation" 0) #f)
    (comment-plain c-lineup-comment comment-intro ("/* A comment" 0) ("/* A comment" 0) #f)
    (c-comments c-lineup-C-comments c ("* continuation" 0) ("/* A comment" 0) #f)
    (gcc-asm c-lineup-gcc-asm-reg arglist-cont-nonempty ("(x)" 0) ("asm (" 0) ("asm (" 4))
    (gcc-asm-colon c-lineup-gcc-asm-reg arglist-cont-nonempty ("(y)" 0) ("asm (" 0) ("asm (" 4))
    (topmost-cont c-lineup-topmost-intro-cont topmost-intro-cont ("Bar," 0) ("int throws" 0) #f)
    (throws c-lineup-java-throws func-decl-cont ("Bar," 0) ("int throws" 0) #f)
    (java-inher c-lineup-java-inher inher-cont ("Bar," 0) ("throws Cyphr" 0) #f)
    (snug-do-while c-snug-do-while block-close ("x++;" 0) #f #f
                   (block-close "do\n    {" 7))
    (gnu-min c-gnu-impose-minimum defun-block-intro ("return result;" 0) ("return result;" 0) #f
             (defun-block-intro "return result;" 0))
    (semi-inside-parens c-semi&comma-inside-parenlist #f ("list))" 0) #f #f)
    (semi-inside-block c-semi&comma-inside-parenlist #f ("return result;" 0) #f #f)
    (semi-nonblanks-blank c-semi&comma-no-newlines-before-nonblanks #f ("return result;" 0) #f #f)
    (semi-nonblanks-nonblank c-semi&comma-no-newlines-before-nonblanks #f ("x++;" 0) #f #f)
    (respect-col-0 c-lineup-respect-col-0 comment-intro ("/* A comment" 0) ("/* A comment" 0) #f)
    (under-anchor c-lineup-under-anchor statement-cont ("+ c;" 0) ("+ c;" 0) #f)
    (dont-change c-lineup-dont-change statement-cont ("+ c;" 0) ("+ c;" 0) #f)
    (whitesmith c-lineup-whitesmith-in-block brace-list-intro ("{ 17," 0) ("{ 17," 0) #f)
    (after-whitesmith c-lineup-after-whitesmith-blocks brace-list-entry ("18" 0) ("{ 17," 0) #f)
    (objc-call c-lineup-ObjC-method-call objc-method-call-cont ("barBaz: barney" 0) ("[foo" 0) #f)
    (objc-call-colons c-lineup-ObjC-method-call-colons objc-method-call-cont ("barBaz: barney" 0) ("[foo" 0) #f)
    (objc-args c-lineup-ObjC-method-args objc-method-args-cont ("barBaz: barney" 0) ("[foo" 0) #f)
    (objc-args-2 c-lineup-ObjC-method-args-2 objc-method-args-cont ("barBaz: barney" 0) ("[foo" 0) #f)))

(define cases-cpp
  '((template-args c-lineup-template-args template-args-cont ("typename U>" 0) ("template <" 0) ("template <" 9))
    (template-margin c-lineup-template-args-indented-from-margin template-args-cont ("char> (1)" 0) ("foo<int" 0) ("foo<int" 3))
    (class-field c-lineup-class-field-cont class-field-cont ("typename U>" 0) ("template <" 0) #f)
    (inexpr c-lineup-inexpr-block inlambda ("return x + n;" 0) #f #f)
    (brace-2nd c-lineup-2nd-brace-entry-in-arglist brace-list-intro ("point_t{0.2, 0.5}," 0)
               ("set_line (" 0) ("line_t {point_t{0.4" 7)
               (brace-list-intro "line_t {point_t{0.4" 0)
               (brace-list-entry "point_t{0.4" 0)
               (arglist-cont-nonempty "set_line (" 0))
    (class-init-plus c-lineup-class-decl-init-+ brace-list-intro ("3.1" 0)
                     ("str_4 = {2," 0) ("str_4 = {2," 8)
                     (brace-list-intro "str_4 = {2," 0)
                     (brace-list-entry "str_4 = {2," 9))
    (class-init-after c-lineup-class-decl-init-after-brace brace-list-intro ("3.1" 0)
                      ("str_4 = {2," 0) ("str_4 = {2," 8)
                      (brace-list-intro "str_4 = {2," 0)
                      (brace-list-entry "str_4 = {2," 9))
    (semi-oneline c-semi&comma-no-newlines-for-oneline-inliners #f ("return;" 7) #f #f)))

(define fixture-c
  "/* The line-up fixture (C). Both harnesses locate positions by the\n   needles the case table names, so every needle is unique. */\n\nint assign_one (int a, int b, int c)\n{\n  int result = a + b\n    + c;\n  result = result\n    = 2;\n  return result;\n\n}\n\nint chain (int offset)\n{\n  result = proc->add (17)->add (18)\n    ->add (19) + offset;\n  return result;\n}\n\nvoid strings (char *prefix)\n{\n  result = prefix + \"A message \"\n    \"string.\";\n}\n\nint ternary (int arg)\n{\n  return arg % 2 == 0 ? arg / 2\n    : (3 * arg + 1);\n}\n\nvoid call (int a, int b)\n{\n  foo (xyz, aaa + bbb + ccc\n       + ddd + eee + fff);\n  bar (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n       b);\n  if (x < 10\n      || at_limit (x,\n                   list))\n    ;\n}\n\nvoid bare (void)\n{\n  {m+=n; n=0;}\n}\n\nvoid multiblock (void)\n{\n  int *foo[] = {\n    { 17,\n      18\n    }\n  };\n}\n\nvoid runin (void)\n{ puts (\"Hello world!\");\n  return;\n}\n\nint main ()\n/* This is the main function. */\n{\n  return 0;\n}\n\n/* A comment\n   * continuation\n   */\n\nvoid gcc_asm (int w, int x, int y)\n{\n  asm (\"foo %1, %0\\n\"\n       : \"=r\" (w),\n         \"=r\" (x)\n       :  \"0\" (y));\n}\n\nint throws (void) throws Cyphr,\n  Bar,\n  Vlod\n{\n  return 0;\n}\n\nvoid looping (void)\n{\n  do\n    {\n      x++;\n    }\n  while (x < 10);\n}\n\nvoid objcish (void)\n{\n  [foo blahBlah: fred\n       barBaz: barney];\n}\n")

(define fixture-cpp
  "/* The line-up fixture (C++). */\n\ntemplate <typename T,\n\t  typename U>\nstruct Pair {};\n\nvoid lambdas (int n)\n{\n  auto f = [&] (int x) {\n    return x + n;\n  };\n}\n\nvoid templates (void)\n{\n  foo<int,\n      char> (1);\n}\n\nvoid set_lines (void)\n{\n  set_line (line_t {point_t{0.4, 0.2},\n\t\t    point_t{0.2, 0.5},\n\t\t    point_t{0.1, 0.9}});\n}\n\nstruct STR2 {\n  int i; float f;\n} str_3 = {1, 1.7},\n  str_4 = {2,\n\t   3.1\n  };\n\nclass K {\npublic:\n  void one (void) { return; }\n};\n")

(define (needle spec)
  (if (not spec)
      #f
      (let ((n (car spec)) (delta (cadr spec)))
        (goto-char (point-min))
        (if (search-forward n #f #t)
            (+ (- (point) (string-length n)) delta)
            (error "Missing needle" n)))))

(define replay-count 0)
(define (replay! text mode)
  ;; A fresh buffer each time: the caches (`c-parse-state''s, the
  ;; literal caches, `syntax-ppss''s) are buffer-local, and refilling
  ;; one buffer with different text leaves them stale.
  (set! replay-count (+ 1 replay-count))
  (let ((b (get-buffer-create (string-append "cc-align-tests-"
                                             (number->string replay-count)))))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (set-syntax-table
     (if (eq? mode 'c++-mode)
         ((c-lang-const c-make-mode-syntax-table c++))
         ((c-lang-const c-make-mode-syntax-table c))))
    (parameterize ((*c-buffer-is-cc-mode* mode))
      (if (eq? mode 'c++-mode)
          (c-init-language-vars c++-mode)
          (c-init-language-vars c-mode))
      (c-set-style "gnu")
      (c-setup-paragraph-variables)
      (c-clear-found-types)
      (c-make-noise-macro-regexps)
      (c-make-macro-with-semi-re)
      (when (eq? mode 'c++-mode)
        (set!c-new-BEG (point-min))
        (set!c-new-END (point-max))
        (c-restore-<>-properties (point-min) (point-max) 0))
      (set!c-label-minimum-indentation 4))
    b))

(define (case-call case)
  (let* ((fn (list-ref case 1))
         (sym (list-ref case 2))
         (at (needle (list-ref case 3)))
         (anchor (needle (list-ref case 4)))
         (second (needle (list-ref case 5)))
         (ctxs (list-tail case 6))
         (elem (if sym (if second (list sym anchor second) (list sym anchor)) #f))
         (ctx (map (lambda (spec) (list (car spec) (needle (cdr spec))))
                   ctxs))
         (proc (eval fn (current-module))))
    (goto-char at)
    (parameterize ((*c-syntactic-element* elem)
                   (*c-syntactic-context* ctx)
                   (*last-command-event* #\;))
      (cond
       ((eq? fn 'c-gnu-impose-minimum)
        (proc)
        (current-indentation))
       ((memq fn '(c-semi&comma-inside-parenlist
                   c-semi&comma-no-newlines-before-nonblanks
                   c-semi&comma-no-newlines-for-oneline-inliners))
        (proc))
       (else
        (proc (if anchor (cons sym anchor) (list sym))))))))

(define (run-case case)
  ;; `*c-buffer-is-cc-mode*` stays bound while the cases run: a line-up
  ;; function reads language state through it (`c-looking-at-inexpr-block'
  ;; and the `%c-langvar' readers), as it does under `c-indent-line'.
  (parameterize ((*c-buffer-is-cc-mode*
                  (buffer-local-value (current-buffer) 'major-mode)))
    (case-call case)))

(define (check-cases cases answers)
  (for-each
   (lambda (case expected)
     (let ((name (symbol->string (car case))))
       (if (eq? expected 'error)
           (test-assert name
             (guard (e (else #t))
               (run-case case)
               #f))
           (test-equal name expected (run-case case)))))
   cases answers))

(test-begin "schemacs_editor_cc_align_probes_c")
(replay! fixture-c 'c-mode)
(check-cases cases-c answers-c)
(test-end "schemacs_editor_cc_align_probes_c")

(test-begin "schemacs_editor_cc_align_probes_cpp")
(replay! fixture-cpp 'c++-mode)
(check-cases cases-cpp answers-cpp)
(test-end "schemacs_editor_cc_align_probes_cpp")

;;----------------------------------------------------------------------
;; The registry: `c-valid-offset' accepts every line-up name, and
;; `c-evaluate-offset' runs one, the way `c-offsets-alist' does.
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_align_registry")
(replay! fixture-c 'c-mode)

(test-assert "a registered line-up name is a valid offset"
             (c-valid-offset 'c-lineup-dont-change))
(test-assert "a registered function name is too"
             (c-valid-offset 'c-gnu-impose-minimum))
(test-assert "an unregistered symbol is not"
             (not (c-valid-offset 'no-such-lineup-function)))
(let* ((anchor (needle '("+ c;" 0)))
       (expected (save-excursion
                   (goto-char anchor)
                   (vector (current-column))))
       (actual (save-excursion
                 (goto-char anchor)
                 (c-evaluate-offset 'c-lineup-under-anchor
                                    (list 'statement-cont anchor)
                                    'statement-cont))))
  (test-equal "c-evaluate-offset calls it with the old-style element"
              expected actual))

(test-end "schemacs_editor_cc_align_registry")
