;; Tests for `(schemacs progmodes cc-fonts)' - the first tranche of
;; `lisp/progmodes/cc-fonts.el': the face-name constants, the font-lock
;; helpers and the matcher constructors. Every expectation is GNU Emacs
;; 31.1's own answer, measured with `emacs -Q --batch' (`require
;; 'cc-mode') on the same fixtures before the port was written.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer
       set-buffer-local-value! local-variable-p)
 (only (schemacs editfns) insert goto-char point point-min point-max)
 (only (schemacs textprop) put-text-property get-text-property
       remove-text-properties)
 (only (schemacs syntax) *parse-sexp-lookup-properties*
       set-syntax-table)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*
       c-face-name-p)
 (only (schemacs progmodes cc-engine) c-clear-found-types)
 (only (schemacs font-lock)
       font-lock-fontify-keywords-region set!font-lock-keywords!
       font-lock-default-fontify-region font-lock-default-unfontify-region
       font-lock-default-fontify-syntactically
       *font-lock-fontify-region-function*
       *font-lock-unfontify-region-function*
       *font-lock-fontify-syntactically-function*
       font-lock-eval-keywords *font-lock-keyword-variables*
       font-lock-register-keyword-variable!)
 (schemacs progmodes cc-langs)
 (only (schemacs progmodes cc-engine)
       c-literal-faces c-restore-<>-properties
       c-new-BEG set!c-new-BEG c-new-END set!c-new-END
       c-doc-line-join-re c-doc-line-join-end-ch
       *c-fontify-new-found-type-function*
       *c-record-type-identifiers* *c-record-ref-identifiers*)
 (only (schemacs progmodes cc-vars) set!c-current-comment-prefix
       *c-doc-comment-style* c-doc-comment-style set!c-doc-comment-style
       c-stylevar-fallback)
 (only (schemacs core syntax-macros) setq)
 (schemacs progmodes cc-fonts))

(test-begin "schemacs_editor_cc_fonts")

(define (face-buffer text thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (thunk)))

;;----------------------------------------------------------------------
;; The face-name constants
;;----------------------------------------------------------------------
(test-equal "the preprocessor face is font-lock-preprocessor-face"
            'font-lock-preprocessor-face c-preprocessor-face-name)
(test-equal "the label face is font-lock-constant-face"
            'font-lock-constant-face c-label-face-name)
(test-equal "the constant face is font-lock-constant-face"
            'font-lock-constant-face c-constant-face-name)
(test-equal "the reference face is font-lock-constant-face here"
            'font-lock-constant-face c-reference-face-name)
(test-equal "the doc face is font-lock-doc-face"
            'font-lock-doc-face c-doc-face-name)
(test-equal "the doc-markup face is font-lock-doc-markup-face"
            'font-lock-doc-markup-face c-doc-markup-face-name)
(test-equal "the negation-char face is font-lock-negation-char-face"
            'font-lock-negation-char-face c-negation-char-face-name)

;;----------------------------------------------------------------------
;; The face helpers
;;----------------------------------------------------------------------
(face-buffer "abcdef"
 (lambda ()
   (c-put-font-lock-face 2 4 'bold)
   (test-equal "c-put-font-lock-face overrides the face"
               'bold (get-text-property 2 'face))
   (c-remove-font-lock-face 2 4)
   (test-equal "c-remove-font-lock-face takes it off"
               #f (get-text-property 2 'face))
   (c-put-font-lock-string-face 1 3)
   (test-equal "c-put-font-lock-string-face puts the string face"
               'font-lock-string-face (get-text-property 1 'face))))

;;----------------------------------------------------------------------
;; c-skip-comments-and-strings
;;----------------------------------------------------------------------
(face-buffer "foo ; foo\nbar foo"
 (lambda ()
   (put-text-property 5 10 'face 'font-lock-comment-face)
   (goto-char 5)
   (test-equal "c-skip-comments-and-strings skips a comment"
               (list #t 10)
               (list (c-skip-comments-and-strings 10) (point)))
   (goto-char 1)
   (test-equal "c-skip-comments-and-strings does nothing outside a literal"
               (list #f 1)
               (list (c-skip-comments-and-strings 10) (point)))))

;;----------------------------------------------------------------------
;; c-make-font-lock-search-function
;;----------------------------------------------------------------------
(face-buffer "foo ; foo\nbar foo"
 (lambda ()
   (put-text-property 5 10 'face 'font-lock-comment-face)
   (goto-char 1)
   ((c-make-font-lock-search-function
     "foo" (list 0 'font-lock-keyword-face #t))
    (point-max))
   (let ((faces (let loop ((i 1) (acc '()))
                  (if (> i 17)
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (list i (get-text-property i 'face)) acc))))))
     (test-equal "the matcher fontifies outside comments only"
                 '((1 font-lock-keyword-face) (2 font-lock-keyword-face)
                   (3 font-lock-keyword-face) (4 #f)
                   (5 font-lock-comment-face) (6 font-lock-comment-face)
                   (7 font-lock-comment-face) (8 font-lock-comment-face)
                   (9 font-lock-comment-face) (10 #f) (11 #f) (12 #f)
                   (13 #f) (14 #f)
                   (15 font-lock-keyword-face) (16 font-lock-keyword-face)
                   (17 font-lock-keyword-face))
                 faces))))

;;----------------------------------------------------------------------
;; The recording helpers
;;----------------------------------------------------------------------
(face-buffer "abcdef"
 (lambda ()
   (parameterize ((*c-record-type-identifiers* (list (cons 1 4)))
                  (*c-record-ref-identifiers* (list (cons 5 7))))
     (c-fontify-recorded-types-and-refs))
   (test-equal "c-fontify-recorded-types-and-refs puts the two faces on"
               (list 'font-lock-type-face 'font-lock-constant-face)
               (list (get-text-property 1 'face)
                     (get-text-property 5 'face)))))

(face-buffer "abcdef"
 (lambda ()
   (c-fontify-types-and-refs ((r (cons 2 5)))
     (setq *c-record-type-identifiers* (list r)))
   (test-equal "c-fontify-types-and-refs fontifies the recorded type"
               (list 'font-lock-type-face #f)
               (list (get-text-property 2 'face)
                     (get-text-property 1 'face)))))

;;----------------------------------------------------------------------
;; c-font-lock-cpp-messages (`cc-fonts.el:525')
;;----------------------------------------------------------------------
;; The fixture: `#error "bad 'thing' here"` on line 1. `#error' is 1-6,
;; the message group is the quoted text, 8..25 inclusive (the regexp's
;; group starts at the `"' and ends before the newline), and the two
;; apostrophes are at 13 and 19.
;;
;; **The `(3)' rewrite is measured against the source this tree ports**
;; (GITE's `cc-fonts.el', Emacs 32.0.50), run in a real `c-mode' buffer:
;; both apostrophes end `(3)' and the message carries
;; `font-lock-string-face'. The installed Emacs 31.1's *compiled*
;; `c-font-lock-cpp-messages' differs - it leaves the `(1)' properties
;; alone - which is a real difference between the installed Lisp and the
;; sources, not a porting question: GITE's source is the reference.
;;
;; `c-mode' marks the apostrophes `(1)' through its change hooks, which
;; are not ported yet; the test puts them on, as the mode will.
(define (c-message-buffer thunk)
  ;; `c-mode-var' reads the buffer's language variables through
  ;; `c-buffer-is-cc-mode', which the mode's init sets and this
  ;; buffer stands in for.
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert "#error \"bad 'thing' here\"\nint x;\n")
      (set-buffer-local-value! b 'major-mode 'c-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (put-text-property 13 14 'syntax-table '(1))
      (put-text-property 19 20 'syntax-table '(1))
      (thunk))))

(c-message-buffer
 (lambda ()
   ;; The function fontifies from point, as `font-lock-fontify-region'
   ;; calls its keywords.
   (goto-char (point-min))
   (test-equal "c-font-lock-cpp-messages returns nil"
               #f (c-font-lock-cpp-messages (point-max)))
   (test-equal "the message carries font-lock-string-face"
               (list 'font-lock-string-face 'font-lock-string-face #f #f)
               (list (get-text-property 8 'face)
                     (get-text-property 25 'face)
                     (get-text-property 7 'face)
                     (get-text-property 26 'face)))
   (test-equal "the apostrophes are rewritten from punctuation to symbol"
               (list '(3) '(3))
               (list (get-text-property 13 'syntax-table)
                     (get-text-property 19 'syntax-table)))))

;;----------------------------------------------------------------------
;; c-cpp-matchers (`cc-fonts.el:550')
;;----------------------------------------------------------------------
;; The fixture and the expected runs are Emacs 31.1's own, measured by
;; running the same list through `font-lock-fontify-keywords-region' in
;; a real `c-mode' buffer (`(let ((font-lock-keywords (c-lang-const
;; c-cpp-matchers))) (font-lock-fontify-keywords-region ...))'). Every
;; run below matches: `#include' and `<stdio.h>', `#define' and `FOO'
;; and its parameter, `#if' and `defined' and `#endif', and the
;; `#error' message as a string.
(define (face-runs limit)
  ;; The runs of one `face' value from position 1 to LIMIT.
  (let loop ((p 1) (last #f) (start 1) (runs '()))
    (if (> p limit)
        (reverse (if last (cons (list start p last) runs) runs))
        (let ((f (and (<= p (point-max)) (get-text-property p 'face))))
          (if (equal? f last)
              (loop (+ p 1) last start runs)
              (loop (+ p 1) f p
                    (if last (cons (list start p last) runs) runs)))))))

(define (c-cpp-buffer thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert "#include <stdio.h>\n#define FOO(x) ((x) + 1)\n#if defined(A)\n#error \"bad 'x' here\"\n#endif\nint x;\n")
      (set-buffer-local-value! b 'major-mode 'c-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (thunk))))

(c-cpp-buffer
 (lambda ()
   (test-equal "c-cpp-matchers has the eight entries C needs"
               8 (length (c-lang-const c-cpp-matchers)))
   (set!font-lock-keywords! (c-lang-const c-cpp-matchers))
   (font-lock-fontify-keywords-region (point-min) (point-max))
   (test-equal "the keyword pass fontifies the directives as Emacs does"
               '((1 9 font-lock-preprocessor-face)
                 (10 19 font-lock-string-face)
                 (20 27 font-lock-preprocessor-face)
                 (28 31 font-lock-function-name-face)
                 (32 33 font-lock-variable-name-face)
                 (45 48 font-lock-preprocessor-face)
                 (49 56 font-lock-preprocessor-face)
                 (60 66 font-lock-preprocessor-face)
                 (67 81 font-lock-string-face)
                 (82 88 font-lock-preprocessor-face))
               (face-runs (point-max)))
   (test-equal "the hard-space matcher made its inverted face"
               #t (and (c-face-name-p 'c-nonbreakable-space-face) #t))))


;;----------------------------------------------------------------------
;; c-basic-matchers-before (`cc-fonts.el:790')
;;----------------------------------------------------------------------
;; The same harness: the same list through the keyword pass in a real
;; `c-mode' / `c++-mode' buffer in Emacs 31.1, face runs by position.
;; The C fixture shows keywords, a constant and the negation character
;; (primitive types are left to `c-font-lock-declarations'); the C++
;; one adds the identifier-concat reference and the C++20 module names.
(define (c-basic-buffer text thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode 'c-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (thunk))))

(define (c++-basic-buffer text thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode 'c++-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c++-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
      (thunk))))

(c-basic-buffer "int x = 0;\nif (x) return NULL;\nsizeof (int);\nx = !x;\n"
 (lambda ()
   (set!font-lock-keywords! (c-lang-const c-basic-matchers-before))
   (font-lock-fontify-keywords-region (point-min) (point-max))
   (test-equal "c-basic-matchers-before fontifies C keywords as Emacs does"
               '((12 14 font-lock-keyword-face)
                 (19 25 font-lock-keyword-face)
                 (26 30 font-lock-constant-face)
                 (32 38 font-lock-keyword-face)
                 (50 51 font-lock-negation-char-face))
               (face-runs (point-max)))))

(c++-basic-buffer
 "int x;\nN::x = 1;\nusing T = int;\nmodule foo;\nimport bar;\nexport module baz;\n"
 (lambda ()
   (set!font-lock-keywords! (c-lang-const c-basic-matchers-before))
   (font-lock-fontify-keywords-region (point-min) (point-max))
   (test-equal "c-basic-matchers-before fontifies C++ names as Emacs does"
               '((8 9 font-lock-constant-face)
                 (18 23 font-lock-keyword-face)
                 (33 39 font-lock-keyword-face)
                 (40 43 font-lock-constant-face)
                 (45 51 font-lock-keyword-face)
                 (52 55 font-lock-constant-face)
                 (57 63 font-lock-keyword-face)
                 (64 70 font-lock-keyword-face)
                 (71 74 font-lock-constant-face))
               (face-runs (point-max)))))


;;----------------------------------------------------------------------
;; c-font-lock-declarators (`cc-fonts.el:1099')
;;----------------------------------------------------------------------
;; Emacs 31.1, measured directly: point at the first declarator, LIST t,
;; TYPES nil for the variable case and t for the type case.
(define (c-decl-buffer text thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode 'c-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (c-clear-found-types)
      (thunk))))

(c-decl-buffer "int foo, *bar;\n"
 (lambda ()
   (goto-char 5)
   (test-equal "c-font-lock-declarators returns nil"
               #f (c-font-lock-declarators (point-max) #t #f #f))
   (test-equal "the declarators are fontified as variables"
               '((5 8 font-lock-variable-name-face)
                 (11 14 font-lock-variable-name-face))
               (face-runs (point-max)))))

(c-decl-buffer "MyType x;\n"
 (lambda ()
   (goto-char 8)
   (test-equal "c-font-lock-declarators with TYPES t returns nil"
               #f (c-font-lock-declarators (point-max) #t #t #f))
   (test-equal "the declarator is fontified as a type"
               '((8 9 font-lock-type-face))
               (face-runs (point-max)))))


;;----------------------------------------------------------------------
;; c-get-fontification-context (`cc-fonts.el:1206')
;;----------------------------------------------------------------------
;; One buffer per row, as Emacs's own answer is measured: the function
;; caches `c-type' properties, so a row's answer can depend on what was
;; probed before it. Every expectation below is Emacs 31.1's, measured
;; with `emacs -Q --batch' on the same text and position.
(define (context-row text mode pos)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (cond ((eq? mode 'c-mode)
             (c-init-language-vars c-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
            (else
             (c-init-language-vars c++-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))))
      (c-clear-found-types)
      (let ((r (c-get-fontification-context pos #f)))
        (list (if (car r) (car r) 'nil)
              (if (eq? (cdr r) #t) 't 'nil))))))

(test-equal "a function's argument paren is a declaration arglist"
  '(arglist t)
  (context-row "int foo (int a, int b);\n" 'c-mode 10))
(test-equal "an ordinary open brace is not a declaration"
  '(nil nil)
  (context-row "struct S { int f; };\n" 'c-mode 11))
(test-equal "an enum's brace list is not a declaration"
  '(not-decl nil)
  (context-row "enum E { A, B };\n" 'c-mode 9))
(test-equal "an if's paren is not a declaration"
  '(nil nil)
  (context-row "void g (void) { if (x) foo (a, b); }\n" 'c-mode 32))
(test-equal "a C++ lambda body's brace" '(nil nil)
  (context-row "void g (void) { [x] (int y) { return y; }; }\n" 'c++-mode 30))
(test-equal "a C++ lambda's parameter paren" '(nil nil)
  (context-row "void g (void) { [x] (int y) { return y; }; }\n" 'c++-mode 21))
(test-equal "a C++ member initializer" '(nil nil)
  (context-row "struct T { T () : a (1), b (2) {} int a, b; };\n" 'c++-mode 23))
(test-equal "a template's angle bracket arglist" '(nil nil)
  (context-row "template <class T> void h (T t);\n" 'c++-mode 12))

;;----------------------------------------------------------------------
;; c-font-lock-declarations (`cc-fonts.el:1421')
;;----------------------------------------------------------------------
;; A mode's init is "a sort of change": `c-common-init' sets
;; (c-new-BEG c-new-END) to the whole buffer and runs the
;; c-before-font-lock functions, of which `c-restore-<>-properties' is
;; the one the declarations pass needs (a `<` must already carry its
;; paren syntax for `c-find-decl-spots''s false-match filter). That is
;; done by hand here - `cc-mode.el' is not ported - and then the whole
;; buffer is fontified. Every run below is Emacs 31.1's own, measured
;; with `emacs -Q --batch' on the same text.
(define (decl-fontify text mode)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (cond ((eq? mode 'c-mode)
             (c-init-language-vars c-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
            (else
             (c-init-language-vars c++-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))))
      (c-clear-found-types)
      (set!c-new-BEG (point-min))
      (set!c-new-END (point-max))
      (c-restore-<>-properties (point-min) (point-max) 0)
      (goto-char (point-min))
      (c-font-lock-declarations (point-max))
      (face-runs (point-max)))))

(test-equal "the C declaration fixture is fontified as Emacs does"
  '((1 4 font-lock-type-face)
    (5 8 font-lock-function-name-face)
    (10 13 font-lock-type-face)
    (14 15 font-lock-variable-name-face)
    (17 20 font-lock-type-face)
    (21 22 font-lock-variable-name-face)
    (32 35 font-lock-type-face)
    (36 37 font-lock-variable-name-face)
    (44 45 font-lock-variable-name-face)
    (62 63 font-lock-type-face)
    (66 69 font-lock-type-face)
    (70 71 font-lock-variable-name-face)
    (75 76 font-lock-type-face)
    (78 81 font-lock-type-face)
    (82 83 font-lock-function-name-face)
    (85 89 font-lock-type-face)
    (93 96 font-lock-type-face)
    (97 102 font-lock-variable-name-face)
    (108 113 font-lock-constant-face)
    (131 135 font-lock-type-face)
    (136 137 font-lock-function-name-face)
    (139 143 font-lock-type-face)
    (148 152 font-lock-type-face)
    (166 169 font-lock-type-face)
    (170 171 font-lock-variable-name-face))
  (decl-fontify
   "int foo (int a, int b);\nstatic int x = 1, *y;\ntypedef struct S { int f; } T;\nint g (void) { int local = 3; label: return local; }\nvoid h (void) { (void) x; if (x) { int z; } }\n"
   'c-mode))

(test-equal "the C++ declaration fixture is fontified as Emacs does"
  '((17 18 font-lock-type-face)
    (20 21 font-lock-type-face)
    (22 25 font-lock-function-name-face)
    (27 28 font-lock-type-face)
    (29 30 font-lock-variable-name-face)
    (32 33 font-lock-type-face)
    (34 35 font-lock-variable-name-face)
    (69 70 font-lock-type-face)
    (80 81 font-lock-type-face)
    (92 93 font-lock-function-name-face)
    (108 111 font-lock-type-face)
    (112 113 font-lock-variable-name-face)
    (118 122 font-lock-type-face)
    (123 124 font-lock-function-name-face)
    (142 145 font-lock-type-face))
  (decl-fontify
   "template <class T> T max (T a, T b) { return a > b ? a : b; }\nclass C : public B { public: C () : x (1) {} int x; };\nvoid f () { static_cast<int> (x); }\n"
   'c++-mode))

;;----------------------------------------------------------------------
;; The whole matcher chain, end to end (`c-matchers-3')
;;----------------------------------------------------------------------
;; A mode's fontification is `font-lock-default-fontify-region' over
;; `(c-lang-const c-matchers-3 LANG)' - the syntactic pass, then the
;; matchers - with `c-common-init''s "Starting a mode is a sort of
;; change" block replayed by hand (cc-mode.el is not ported). Every run
;; list below is Emacs 31.1's own, measured with `emacs -Q --batch' on
;; the same text in a real `c-mode'/`c++-mode'/`java-mode' buffer after
;; `(font-lock-ensure)'.
(define (esp-fontify text mode)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (cond ((eq? mode 'c-mode)
             (c-init-language-vars c-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
            ((eq? mode 'java-mode)
             (c-init-language-vars java-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table java))))
            (else
             (c-init-language-vars c++-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))))
      (c-clear-found-types)
      (set!c-new-BEG (point-min))
      (set!c-new-END (point-max))
      (c-restore-<>-properties (point-min) (point-max) 0)
      (cond ((eq? mode 'c-mode)
             (set!font-lock-keywords! (c-lang-const c-matchers-3 c)))
            ((eq? mode 'java-mode)
             (set!font-lock-keywords! (c-lang-const c-matchers-3 java)))
            (else
             (set!font-lock-keywords! (c-lang-const c-matchers-3 c++))))
      (goto-char (point-min))
      (parameterize ((*font-lock-fontify-region-function*
                      font-lock-default-fontify-region)
                     (*font-lock-unfontify-region-function*
                      font-lock-default-unfontify-region)
                     (*font-lock-fontify-syntactically-function*
                      font-lock-default-fontify-syntactically))
        (font-lock-default-fontify-region (point-min) (point-max)))
      (face-runs (point-max)))))

(test-equal "the C declaration fixture fontifies exactly as Emacs does"
  '((1 4 font-lock-type-face)
    (5 8 font-lock-function-name-face)
    (10 13 font-lock-type-face)
    (14 15 font-lock-variable-name-face)
    (17 20 font-lock-type-face)
    (21 22 font-lock-variable-name-face)
    (25 31 font-lock-keyword-face)
    (32 35 font-lock-type-face)
    (36 37 font-lock-variable-name-face)
    (44 45 font-lock-variable-name-face)
    (47 54 font-lock-keyword-face)
    (55 61 font-lock-keyword-face)
    (62 63 font-lock-type-face)
    (66 69 font-lock-type-face)
    (70 71 font-lock-variable-name-face)
    (75 76 font-lock-type-face)
    (78 81 font-lock-type-face)
    (82 83 font-lock-function-name-face)
    (85 89 font-lock-type-face)
    (93 96 font-lock-type-face)
    (97 102 font-lock-variable-name-face)
    (108 113 font-lock-constant-face)
    (115 121 font-lock-keyword-face)
    (131 135 font-lock-type-face)
    (136 137 font-lock-function-name-face)
    (139 143 font-lock-type-face)
    (148 152 font-lock-type-face)
    (157 159 font-lock-keyword-face)
    (166 169 font-lock-type-face)
    (170 171 font-lock-variable-name-face))
  (esp-fontify
   "int foo (int a, int b);\nstatic int x = 1, *y;\ntypedef struct S { int f; } T;\nint g (void) { int local = 3; label: return local; }\nvoid h (void) { (void) x; if (x) { int z; } }\n"
   'c-mode))

(test-equal "the C++ declaration fixture fontifies exactly as Emacs does"
  '((1 9 font-lock-keyword-face)
    (11 16 font-lock-keyword-face)
    (17 18 font-lock-type-face)
    (20 21 font-lock-type-face)
    (22 25 font-lock-function-name-face)
    (27 28 font-lock-type-face)
    (29 30 font-lock-variable-name-face)
    (32 33 font-lock-type-face)
    (34 35 font-lock-variable-name-face)
    (39 45 font-lock-keyword-face)
    (63 68 font-lock-keyword-face)
    (69 70 font-lock-type-face)
    (73 79 font-lock-keyword-face)
    (80 81 font-lock-type-face)
    (84 90 font-lock-keyword-face)
    (92 93 font-lock-function-name-face)
    (108 111 font-lock-type-face)
    (112 113 font-lock-variable-name-face)
    (118 122 font-lock-type-face)
    (123 124 font-lock-function-name-face)
    (130 141 font-lock-keyword-face)
    (142 145 font-lock-type-face))
  (esp-fontify
   "template <class T> T max (T a, T b) { return a > b ? a : b; }\nclass C : public B { public: C () : x (1) {} int x; };\nvoid f () { static_cast<int> (x); }\n"
   'c++-mode))

;; Java, and the class-bit bug this pins: `public' is a specifier and
;; `C' the type only if `c-known-type-key''s `[[:upper:]]' means an
;; upper-case letter - which it does with font-lock's case folding off.
;; When the class-bit table's upper and lower were transposed,
;; `public' matched `[[:upper:]]\sw*[[:lower:]]\sw' and the class name
;; and method name went unfaced. Every run is Emacs 31.1's.
(test-equal "the Java declaration fixture fontifies exactly as Emacs does"
  '((1 7 font-lock-keyword-face)
    (8 13 font-lock-keyword-face)
    (14 15 font-lock-type-face)
    (22 28 font-lock-keyword-face)
    (29 33 font-lock-type-face)
    (34 37 font-lock-function-name-face)
    (43 46 font-lock-type-face)
    (47 48 font-lock-variable-name-face)
    (60 63 font-lock-comment-delimiter-face)
    (63 71 font-lock-comment-face)
    (75 81 font-lock-type-face)
    (82 83 font-lock-variable-name-face)
    (86 90 font-lock-string-face))
  (esp-fontify
   "public class C {\n    static void foo () { int x = 1; }\n    // comment\n    String s = \"hi\";\n}\n"
   'java-mode))

(test-equal "enums, using, new and lambda captures fontify as Emacs does"
  '((1 5 font-lock-keyword-face)
    (6 7 font-lock-type-face)
    (10 11 font-lock-variable-name-face)
    (13 14 font-lock-variable-name-face)
    (18 24 font-lock-keyword-face)
    (25 26 font-lock-type-face)
    (29 32 font-lock-type-face)
    (33 34 font-lock-variable-name-face)
    (39 44 font-lock-keyword-face)
    (45 46 font-lock-type-face)
    (49 52 font-lock-type-face)
    (54 57 font-lock-type-face)
    (58 59 font-lock-variable-name-face)
    (65 68 font-lock-type-face)
    (70 71 font-lock-variable-name-face)
    (74 77 font-lock-keyword-face)
    (78 81 font-lock-type-face)
    (87 91 font-lock-type-face)
    (92 93 font-lock-function-name-face)
    (99 103 font-lock-keyword-face)
    (104 105 font-lock-variable-name-face)
    (109 110 font-lock-constant-face)
    (113 116 font-lock-type-face)
    (117 118 font-lock-variable-name-face)
    (122 128 font-lock-keyword-face))
  (esp-fontify
   "enum E { A, B };\nstruct S { int f; };\nusing T = int;\nint x = 0;\nint *p = new int (5);\nvoid g () { auto f = [x] (int y) { return y + x; }; }\n"
   'c++-mode))

(test-equal "a label after goto fontifies as Emacs does"
  '((1 4 font-lock-type-face)
    (5 6 font-lock-function-name-face)
    (8 12 font-lock-type-face)
    (16 18 font-lock-keyword-face)
    (25 31 font-lock-keyword-face)
    (37 41 font-lock-keyword-face)
    (42 46 font-lock-constant-face)
    (48 52 font-lock-constant-face)
    (54 60 font-lock-keyword-face))
  (esp-fontify
   "int f (void) { if (x) { return 1; } goto done; done: return 0; }\n"
   'c-mode))

(test-equal "comments' delimiters and strings fontify as Emacs does"
  '((1 4 font-lock-comment-delimiter-face)
    (4 7 font-lock-comment-face)
    (7 10 font-lock-comment-delimiter-face)
    (11 14 font-lock-type-face)
    (15 16 font-lock-variable-name-face)
    (18 21 font-lock-comment-delimiter-face)
    (21 25 font-lock-comment-face)
    (25 29 font-lock-type-face)
    (31 32 font-lock-variable-name-face)
    (35 40 font-lock-string-face)
    (42 48 font-lock-keyword-face)
    (49 50 font-lock-type-face)
    (53 56 font-lock-type-face)
    (57 58 font-lock-variable-name-face))
  (esp-fontify
   "/* aaa */\nint x; // bbb\nchar *s = \"ccc\";\nstruct T { int f; };\n"
   'c-mode))

(test-equal "a C++ comment inside a declaration fontifies as Emacs does"
  '((1 9 font-lock-keyword-face)
    (11 16 font-lock-keyword-face)
    (17 18 font-lock-type-face)
    (20 23 font-lock-comment-delimiter-face)
    (23 24 font-lock-comment-face)
    (24 27 font-lock-comment-delimiter-face)
    (28 29 font-lock-type-face)
    (30 33 font-lock-function-name-face)
    (35 36 font-lock-type-face)
    (37 38 font-lock-variable-name-face)
    (40 41 font-lock-type-face)
    (42 43 font-lock-variable-name-face)
    (47 53 font-lock-keyword-face)
    (71 74 font-lock-comment-delimiter-face)
    (74 87 font-lock-comment-face)
    (87 90 font-lock-type-face)
    (91 92 font-lock-variable-name-face))
  (esp-fontify
   "template <class T> /* t */ T max (T a, T b) { return a > b ? a : b; }\n// line comment\nint q = 1;\n"
   'c++-mode))

;;----------------------------------------------------------------------
;; The doc-comment styles (`cc-fonts.el:2567'-`:2677', `:3126'-`:3593')
;;----------------------------------------------------------------------
;; Every expectation below is GNU Emacs 31.1's own answer, measured with
;; `emacs -Q --batch' on the same text in a real mode buffer after
;; `(font-lock-ensure)' (`*c-buffer-is-cc-mode*' is held to the language
;; because cc-mode.el is not ported).

(define (doc-fontify text lang)
  (parameterize ((*c-buffer-is-cc-mode* lang))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode lang)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (cond ((eq? lang 'c-mode)
             (c-init-language-vars c-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
            ((eq? lang 'c++-mode)
             (c-init-language-vars c++-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++))))
            ((eq? lang 'java-mode)
             (c-init-language-vars java-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table java))))
            ((eq? lang 'pike-mode)
             (c-init-language-vars pike-mode)
             (set-syntax-table ((c-lang-const c-make-mode-syntax-table pike)))
             ;; The mode init sets this from
             ;; `c-comment-prefix-regexp' (`c-setup-paragraph-variables');
             ;; the value is Emacs pike-mode's, measured.
             (set!c-current-comment-prefix "//+!?\\|\\**")))
      ;; `c-set-style' is not ported yet (cc-styles.scm is next); the
      ;; one style variable the doc machinery reads is applied by hand,
      ;; which is what `c-set-style-1' does for it.
      (set!c-doc-comment-style (c-stylevar-fallback 'c-doc-comment-style))
      (c-clear-found-types)
      (set!c-new-BEG (point-min))
      (set!c-new-END (point-max))
      (c-restore-<>-properties (point-min) (point-max) 0)
      (set!font-lock-keywords!
       (c-compose-keywords-list
        (cond ((eq? lang 'c-mode) (c-lang-const c-matchers-3 c))
              ((eq? lang 'c++-mode) (c-lang-const c-matchers-3 c++))
              ((eq? lang 'java-mode) (c-lang-const c-matchers-3 java))
              (else (c-lang-const c-matchers-3 pike)))))
      (goto-char (point-min))
      (parameterize ((*font-lock-fontify-region-function*
                      font-lock-default-fontify-region)
                     (*font-lock-unfontify-region-function*
                      font-lock-default-unfontify-region)
                     (*font-lock-fontify-syntactically-function*
                      font-lock-default-fontify-syntactically))
        (font-lock-default-fontify-region (point-min) (point-max)))
      (face-runs (point-max)))))

(define (with-doc-style thunk)
  ;; A buffer with the standard doc style applied, as `c-set-style' does
  ;; at mode init (`cc-styles.scm' is not ported yet; the value a style
  ;; variable holds before that is the symbol `set-from-style', which is
  ;; Emacs's state too).
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (set!c-doc-comment-style (c-stylevar-fallback 'c-doc-comment-style))
    (thunk)))

(test-equal "the doc style is the mode's entry in the alist"
  '(gtkdoc gtkdoc javadoc autodoc #f)
  (with-doc-style
   (lambda ()
     (map (lambda (mode)
            (parameterize ((*c-buffer-is-cc-mode* mode))
              (c-get-doc-comment-style)))
          '(c-mode c++-mode java-mode pike-mode objc-mode)))))

(test-equal "before a style is applied the value is `set-from-style'"
  '(set-from-style #f)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (list (c-doc-comment-style)
          (and (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
                 (eq? (c-get-doc-comment-style) 'set-from-style))
               #f))))

(test-equal "a list of styles is returned as it stands"
  '(gtkdoc javadoc)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode)
                 (*c-doc-comment-style* '(gtkdoc javadoc)))
    (c-get-doc-comment-style)))

(test-equal "composing adds the doc keywords and moves the prepare first"
  (list #t #t)
  (with-doc-style
   (lambda ()
     (let ((base (c-lang-const c-matchers-3 c)))
       (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
         (let ((composed (c-compose-keywords-list base)))
           (list (= (length composed) (+ 1 (length base)))
                 (eq? (car composed) c-font-lock-complex-decl-prepare))))))))

(test-equal "a language with no doc style composes nothing"
  '(#t #t)
  (with-doc-style
   (lambda ()
     (let ((base (c-lang-const c-matchers-3 c)))
       (parameterize ((*c-buffer-is-cc-mode* 'objc-mode))
         (let ((composed (c-compose-keywords-list base)))
           ;; No style for objc-mode, so nothing is added (the kludge that
           ;; moves `c-font-lock-complex-decl-prepare' first still reorders
           ;; it, so the *length* is what says nothing was added); the doc
           ;; face is put among the literal faces by *any* composition
           ;; (Emacs's `setq' is global) - the two facts are independent.
           (list (= (length composed) (length base))
                 (and (memq c-doc-face-name c-literal-faces) #t))))))))

(test-equal "the composed list has the doc face among the literal faces"
  #t
  (with-doc-style
   (lambda ()
     (let ((base (c-lang-const c-matchers-3 c)))
       (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
         (c-compose-keywords-list base)))
     (and (memq c-doc-face-name c-literal-faces) #t))))

;; The function halves: `font-lock-eval-keywords' resolves the symbol in
;; the keyword table, calls a procedure entry (Emacs's `fboundp' arm) and
;; uses a list entry as it stands.
(test-equal "c-font-lock-keywords evaluates to the composed list"
  #t
  (with-doc-style
   (lambda ()
     (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
       (= (length (font-lock-eval-keywords 'c-font-lock-keywords))
          (+ 1 (length c-font-lock-keywords-3)))))))

(test-equal "c-font-lock-keywords-1 evaluates to its plain list"
  (length c-font-lock-keywords-1)
  (length (font-lock-eval-keywords 'c-font-lock-keywords-1)))

(test-equal "c-override-default-keywords unbinds a nil or default value"
  '(#t #t)
  (let ((table (*font-lock-keyword-variables*)))
    ;; Emacs unbinds DEF-VAR when its value is nil or one of the level
    ;; variables' values; the obarray stand-in is the keyword table.
    (font-lock-register-keyword-variable! 'probe-override-keywords #f)
    (c-override-default-keywords 'probe-override-keywords)
    (let ((gone (not (assq 'probe-override-keywords
                           (*font-lock-keyword-variables*)))))
      (font-lock-register-keyword-variable! 'probe-override-keywords '(keep))
      (c-override-default-keywords 'probe-override-keywords)
      (let ((kept (and (assq 'probe-override-keywords
                             (*font-lock-keyword-variables*))
                       #t)))
        (*font-lock-keyword-variables* table)
        (list gone kept)))))

(test-equal "c-set-doc-comment-res sets the autodoc regexps buffer-locally"
  (list "\\(@[\n\r][ \t]*/[/*]!\\)" '(#\!) #t #t)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (set!c-doc-comment-style (c-stylevar-fallback 'c-doc-comment-style))
    (parameterize ((*c-buffer-is-cc-mode* 'pike-mode))
      (c-set-doc-comment-res))
    (list (c-doc-line-join-re)
          (c-doc-line-join-end-ch)
          (and (local-variable-p 'c-doc-line-join-re b) #t)
          (and (local-variable-p 'c-doc-line-join-end-ch b) #t))))

(test-equal "and kills them for a style that has none"
  (list "\\`a\\`" #f #f)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (set!c-doc-comment-style (c-stylevar-fallback 'c-doc-comment-style))
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (c-set-doc-comment-res))
    (list (c-doc-line-join-re)
          (c-doc-line-join-end-ch)
          (and (local-variable-p 'c-doc-line-join-re b) #t))))

(test-equal "c-fontify-new-found-type answers nil with font-lock off"
  #f
  (c-fontify-new-found-type "SomeNewType"))

(test-equal "cc-fonts installs the found-type seam"
  #t
  (and (eq? (*c-fontify-new-found-type-function*) c-fontify-new-found-type)
       #t))

(test-equal "the gtkdoc fixture fontifies exactly as Emacs does"
  '((1 8 font-lock-doc-face)
    (8 15 (font-lock-doc-markup-face font-lock-doc-face))
    (15 20 font-lock-doc-face)
    (20 25 (font-lock-doc-markup-face font-lock-doc-markup-face
                                      font-lock-doc-face))
    (25 46 font-lock-doc-face)
    (46 51 (font-lock-doc-markup-face font-lock-doc-face))
    (51 60 font-lock-doc-face)
    (61 64 font-lock-type-face)
    (65 72 font-lock-function-name-face)
    (74 77 font-lock-type-face)
    (78 82 font-lock-variable-name-face)
    (86 92 font-lock-keyword-face))
  (doc-fontify
   "/**\n * foo_bar:\n * @arg1: the first\n *\n * Do foo() now.\n */\nint foo_bar (int arg1) { return arg1; }\n"
   'c-mode))

(test-equal "the javadoc fixture fontifies exactly as Emacs does"
  '((1 8 font-lock-doc-face)
    (8 14 (font-lock-doc-markup-face font-lock-doc-face))
    (14 30 font-lock-doc-face)
    (30 37 (font-lock-doc-markup-face font-lock-doc-face))
    (37 42 font-lock-doc-face)
    (42 53 (font-lock-doc-markup-face font-lock-doc-face))
    (53 64 font-lock-doc-face))
  ;; The comment alone: a declaration after it would depend on java's
  ;; declaration fontification, which has a pre-existing gap for the
  ;; modifier keywords (`public'/'static'/'abstract'); DEPARTURES.md's
  ;; 2026-11-23 section has the measurements. The doc machinery is what
  ;; this pins.
  (doc-fontify
   "/**\n * @param x the value\n * @return the {@code foo} result\n */\n"
   'java-mode))

(test-equal "the autodoc fixture fontifies exactly as Emacs does"
  '((1 5 font-lock-doc-face)
    (5 10 (font-lock-doc-markup-face font-lock-doc-face))
    (11 14 font-lock-type-face)
    (15 18 font-lock-function-name-face)
    (20 23 font-lock-type-face)
    (24 25 font-lock-variable-name-face)
    (27 47 font-lock-doc-face)
    (47 50 font-lock-type-face)
    (51 54 font-lock-function-name-face)
    (56 59 font-lock-type-face)
    (60 61 font-lock-variable-name-face)
    (65 71 font-lock-keyword-face))
  (doc-fontify
   "//! @decl int foo (int x)\n//! Does the thing.\nint foo (int x) { return x; }\n"
   'pike-mode))

(test-equal "the doxygen fixture fontifies exactly as Emacs does"
  '((1 35 font-lock-doc-face)
    (35 44 (font-lock-doc-markup-face font-lock-doc-face))
    (44 61 font-lock-doc-face)
    (62 65 font-lock-type-face)
    (66 73 font-lock-function-name-face))
  (doc-fontify
   "/** \\brief Does foo.\n *  See \\ref foo_bar() for details.\n */\nint foo_bar ();\n"
   'c++-mode))

(test-end "schemacs_editor_cc_fonts")
