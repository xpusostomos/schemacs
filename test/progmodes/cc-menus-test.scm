;; Tests for `(schemacs progmodes cc-menus)', a port of GNU Emacs's
;; `lisp/progmodes/cc-menus.el'. Every expectation is Emacs 31.1's own,
;; measured by loading GITE's `cc-menus.el' (the Emacs 32 source this
;; port follows) into the installed Emacs: the expressions and the four
;; Objective-C group indices were compared character for character, and
;; the two index alists below are what `imenu--generic-function' and
;; `cc-imenu-objc-function' answer on the same fixtures.

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer set-buffer-local-value!)
 (only (schemacs editfns) insert)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs imenu)
       *imenu-use-markers* *imenu-auto-rescan*
       imenu-generic-expression imenu-case-fold-search
       imenu-create-index-function imenu-default-create-index-function
       imenu--generic-function)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*)
 (schemacs progmodes cc-langs)
 (schemacs progmodes cc-vars)
 (schemacs progmodes cc-styles)
 (schemacs progmodes cc-engine)
 (only (schemacs progmodes cc-menus)
       cc-imenu-c-prototype-macro-regexp
       cc-imenu-c++-generic-expression cc-imenu-c-generic-expression
       cc-imenu-java-build-type-args-regex
       cc-imenu-java-generic-expression
       cc-imenu-objc-generic-expression-noreturn-index
       cc-imenu-objc-generic-expression-general-func-index
       cc-imenu-objc-generic-expression-proto-index
       cc-imenu-objc-generic-expression-objc-base-index
       cc-imenu-objc-method-to-selector
       cc-imenu-objc-remove-white-space
       cc-imenu-objc-function
       cc-imenu-init))

(test-begin "schemacs_editor_cc_menus")

(define c-fixture
  "static int
foo (int a)
{
  return a;
}

struct bar {
  int x;
};

int baz(void) { return 0; }
")

(define objc-fixture
  "@interface Foo : Bar
- (void)doIt:(int)x with:(int)y;
@end

@implementation Foo
- (void)doIt:(int)x with:(int)y { }
@end

static int helper(int a) { return a; }
")

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    b))

(define (index-of text expr)
  (fresh text)
  (parameterize ((*imenu-use-markers* #f)
                 (*imenu-auto-rescan* #f))
    (imenu--generic-function expr)))

;; The Objective-C language has to be initialised for `c-literal-limits',
;; which the index function calls; there is no objc-mode yet.
(define (objc-index text)
  (let ((b (fresh text)))
    (set-buffer-local-value! b 'major-mode 'objc-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars objc-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table objc)))
    (parameterize ((*c-buffer-is-cc-mode* 'objc-mode)
                   (*imenu-use-markers* #f)
                   (*imenu-auto-rescan* #f))
      (cc-imenu-objc-function))))

;;----------------------------------------------------------------------
;; The expressions
;;----------------------------------------------------------------------

(test-equal "the prototype macro regexp is unset, as Emacs leaves it" #f
            cc-imenu-c-prototype-macro-regexp)
(test-equal "the C expression is the C++ one" #t
            (eq? cc-imenu-c-generic-expression cc-imenu-c++-generic-expression))
(test-equal "four entries: operator, noreturn, general, class"
            '(#f #f #f "Class")
            (map car cc-imenu-c++-generic-expression))
(test-equal "with their capture groups"
            '(1 1 1 3)
            (map (lambda (item) (caddr item)) cc-imenu-c++-generic-expression))
(test-equal "Java's one entry captures group 7"
            '(7)
            (map (lambda (item) (caddr item)) cc-imenu-java-generic-expression))
(test-equal "the Objective-C group indices"
            '(1 4 3 3)
            (list cc-imenu-objc-generic-expression-noreturn-index
                  cc-imenu-objc-generic-expression-general-func-index
                  cc-imenu-objc-generic-expression-proto-index
                  cc-imenu-objc-generic-expression-objc-base-index))

;;----------------------------------------------------------------------
;; Java's type-argument builder
;;----------------------------------------------------------------------

(test-equal "depth 0 builds nothing" #f
            (cc-imenu-java-build-type-args-regex 0))
(test-equal "depth 1 is one flat pair of angle brackets"
            "<[][.,[:alnum:]_? \t\n\r]+>"
            (cc-imenu-java-build-type-args-regex 1))
(test-equal "depth 2 nests one group"
            "<[][.,[:alnum:]_? \t\n\r]+\\(<[][.,[:alnum:]_? \t\n\r]+>[][.,[:alnum:]_? \t\n\r]*\\)*>"
            (cc-imenu-java-build-type-args-regex 2))
(test-equal "depth 3 is the length Emacs builds" 126
            (string-length (cc-imenu-java-build-type-args-regex 3)))

;;----------------------------------------------------------------------
;; The Objective-C selector helpers
;;----------------------------------------------------------------------

(test-equal "the selector drops arguments and keeps the colons"
            "perform:withObject:withObject:"
            (cc-imenu-objc-method-to-selector
             "- perform: (SEL)aSelector withObject: object1 withObject: object2;"))
(test-equal "white space is removed everywhere"
            "@interfaceFoo:Bar"
            (cc-imenu-objc-remove-white-space " @interface Foo : Bar "))

;;----------------------------------------------------------------------
;; The index alists
;;----------------------------------------------------------------------

(test-equal "the C index"
            '(("Class" ("bar" . 41)) ("foo" . 12) ("baz" . 67))
            (index-of c-fixture cc-imenu-c-generic-expression))
(test-equal "the C++ index is the same on C code"
            '(("Class" ("bar" . 41)) ("foo" . 12) ("baz" . 67))
            (index-of c-fixture cc-imenu-c++-generic-expression))
(test-equal "the Objective-C index, with the C functions as a submenu"
            '(("C" ("helper" . 134))
              ("Foo:" ("@interface" . 1) ("-doIt:with:" . 22))
              ("Foo" ("@implementation" . 61) ("-doIt:with:" . 81)))
            (objc-index objc-fixture))

;;----------------------------------------------------------------------
;; cc-imenu-init
;;----------------------------------------------------------------------

(let ((b (fresh "")))
  (cc-imenu-init cc-imenu-c-generic-expression)
  (test-equal "cc-imenu-init installs the expression"
              #t (eq? (imenu-generic-expression) cc-imenu-c-generic-expression))
  (test-equal "and turns case folding off, as CC Mode wants"
              #f (imenu-case-fold-search))
  (test-equal "and leaves the index function alone"
              #t (eq? (imenu-create-index-function)
                      imenu-default-create-index-function))
  (let ((f (lambda () 'mine)))
    (cc-imenu-init #f f)
    (test-equal "a supplied index function is installed" #t
                (eq? (imenu-create-index-function) f))
    (test-equal "and the expression replaced with nil" #f
                (imenu-generic-expression))))

(test-end "schemacs_editor_cc_menus")
