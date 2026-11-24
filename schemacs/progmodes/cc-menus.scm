(define-library (schemacs progmodes cc-menus)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/cc-menus.el': the
  ;; imenu generic expressions CC Mode's modes install, and Objective-C's
  ;; index function. The file's Lisp is data built at load time, so the
  ;; concatenations below are the file's own, expression for expression.
  ;;
  ;; **The expressions are GITE's** (`lisp/progmodes/cc-menus.el',
  ;; Emacs 32.0.50). The installed Emacs 31.1's `cc-menus.el' has a
  ;; different Objective-C expression - a later group layout with
  ;; `\\(...\\)' groups the indices point into - so the two disagree
  ;; there; the port follows the source, as the cc-mode work always has,
  ;; and the difference is recorded in DEPARTURES.md.
  ;;
  ;; `cc-imenu-c-prototype-macro-regexp' is a `defvar' (a user-set
  ;; option, not a `defcustom'), so it is a plain variable, and it is
  ;; read when this library loads - as Emacs reads it when `cc-menus.el'
  ;; is loaded.

  (import
    (scheme base)
    (schemacs fns)
    (only (schemacs progmodes cc-defs) c-alpha c-alnum)
    (only (schemacs progmodes cc-engine) c-literal-limits)
    (only (schemacs editfns)
          point-max goto-char buffer-substring-no-properties)
    (only (schemacs search)
          re-search-backward match-beginning match-end
          match-string-no-properties)
    (only (schemacs imenu)
          set!imenu-generic-expression set!imenu-case-fold-search
          set!imenu-create-index-function))

  (export
   cc-imenu-c-prototype-macro-regexp
   cc-imenu-c++-generic-expression
   cc-imenu-c-generic-expression
   cc-imenu-java-ellipsis-regexp
   cc-imenu-java-build-type-args-regex
   cc-imenu-java-type-spec-regexp
   cc-imenu-java-comment-regexp
   cc-imenu-java-method-arg-regexp
   cc-imenu-java-generic-expression
   cc-imenu-objc-generic-expression-noreturn-index
   cc-imenu-objc-generic-expression-general-func-index
   cc-imenu-objc-generic-expression-proto-index
   cc-imenu-objc-generic-expression-objc-base-index
   cc-imenu-objc-generic-expression
   cc-imenu-objc-method-to-selector
   cc-imenu-objc-remove-white-space
   cc-imenu-objc-function
   cc-imenu-init)

  (begin

    ;;----------------------------------------------------------------
    ;; imenu integration
    ;;----------------------------------------------------------------

    (define cc-imenu-c-prototype-macro-regexp #f)

    ;; `cc-imenu-objc-generic-expression' depends on
    ;; `cc-imenu-c++-generic-expression', and the `cc-imenu-objc-
    ;; generic-expression-*-index' variables say where each regexp's
    ;; `\\(...\\)' groups start. They are initialised while the
    ;; expression's value is built, below, as in Emacs.

    (define cc-imenu-c++-generic-expression
      (append
       (list
        ;; Try to match `::operator' definitions first. Otherwise
       ;; `X::operator new ()' will be incorrectly recognized as
       ;; function `new ()' because the regexps work by backtracking
       ;; from the end of the definition.
       (list #f
             (concat
              "^\\_<.*"
              "[^" c-alnum "_:<>~]"     ; match any non-identifier char
                                        ; (note: this can be `\n')
              "\\("
              "\\([" c-alnum "_:<>~]*::\\)?" ; match an operator
              "operator\\_>[ \t]*"
              "\\(()\\|[^(]*\\)"        ; special case for `()' operator
              "\\)"
              "[ \t]*([^)]*)[ \t]*[^ \t;]") ; followed by ws, arg list,
                                        ; require something other than
                                        ; a `;' after the (...) to
                                        ; avoid prototypes.  Can't
                                        ; catch cases with () inside
                                        ; the parentheses surrounding
                                        ; the parameters.  e.g.:
                                        ; `int foo(int a=bar()) {...}'
             1)
       ;; Special case to match a line like `main() {}'
       ;; e.g. no return type, not even on the previous line.
       (list #f
             (concat
              "^"
              "\\([" c-alpha "_][" c-alnum "_:<>~]*\\)" ; match function name
              "[ \t]*("                 ; see above, BUT
              "[ \t]*\\([^ \t(*][^)]*\\)?)" ; the arg list must not start
              "[ \t]*[^ \t;(]")         ; with an asterisk or parentheses
             1)
       ;; General function name regexp
       (list #f
             (concat
              "^\\_<"                   ; line MUST start with symbol char
              ;; \n added to prevent overflow in regexp matcher.
              ;; https://lists.gnu.org/r/emacs-pretest-bug/2007-02/msg00021.html
              "[^()\n]*"                ; no parentheses before
              "[^" c-alnum "_:<>~]"     ; match any non-identifier char
              "\\([" c-alpha "_][" c-alnum "_:<>~]*\\)" ; match function name
              "\\([ \t\n]\\|\\\\\n\\)*(" ; see above, BUT the arg list
              "\\([ \t\n]\\|\\\\\n\\)*" ; must not start
              "\\([^ \t\n(*]"           ; with an asterisk or parentheses
              "[^()]*\\(([^()]*)[^()]*\\)*" ; Maybe function pointer arguments
              "\\)?)"
              "\\([ \t\n]\\|\\\\\n\\)*[^ \t\n;(]")
             1))
       ;; Special case for definitions using phony prototype macros like:
       ;; `int main _PROTO( (int argc,char *argv[]) )'.
       ;; This case is only included if
       ;; `cc-imenu-c-prototype-macro-regexp' is set. Only supported in
       ;; c-code, so no `:<>~' chars in function name!
       (if cc-imenu-c-prototype-macro-regexp
           (list (list #f
                 (concat
                  "^\\_<.*"             ; line MUST start with symbol char
                  "[^" c-alnum "_]"     ; match any non-identifier char
                  "\\([" c-alpha "_][" c-alnum "_]*\\)" ; match function name
                  "[ \t]*"              ; whitespace before macro name
                  cc-imenu-c-prototype-macro-regexp
                  "[ \t]*("             ; ws followed by first paren.
                  "[ \t]*([^)]*)[ \t]*)[ \t]*[^ \t;]" ; see above
                  ) 1))
           '())
       ;; Class definitions
       (list
        (list "Class"
             (concat
              "^"                       ; beginning of line is required
              "\\(template[ \t]*<[^>]+>[ \t]*\\)?" ; there may be a `template <...>'
              "\\(class\\|struct\\)[ \t]+"
              "\\("                     ; the string we want to get
              "[" c-alnum "_]+"         ; class name
              "\\(<[^>]+>\\)?"          ; possibly explicitly specialized
              "\\)"
              "\\([ \t\n]\\|\\\\\n\\)*[:{]")
             3))))

    (define cc-imenu-c-generic-expression
      cc-imenu-c++-generic-expression)

    ;; Auxiliary regexps for Java try to match their trailing whitespace
    ;; where appropriate, but _not_ starting whitespace.

    (define cc-imenu-java-ellipsis-regexp
      (concat
       "\\.\\{3\\}"
       "[ \t\n\r]*"))

    (define (cc-imenu-java-build-type-args-regex depth)
      ;; Build regexp for type arguments list with DEPTH allowed
      ;; nested angle brackets constructs.
      ;;--------------------------------------------------------------
      (if (> depth 0)
          (concat "<"
                  "[][.," c-alnum "_? \t\n\r]+"
                  (if (> depth 1) "\\(" #f)
                  (cc-imenu-java-build-type-args-regex (- depth 1))
                  (if (> depth 1)
                      (concat "[][.," c-alnum "_? \t\n\r]*"
                              "\\)*")
                      #f)
                  ">")
          #f))

    (define cc-imenu-java-type-spec-regexp
      (concat
       ;; zero or more identifiers followed by a dot
       "\\("
       "[" c-alpha "_][" c-alnum "_]*\\."
       "\\)*"
       ;; a single mandatory identifier without a dot
       "[" c-alpha "_][" c-alnum "_]*"
       ;; then choice:
       "\\("
       ;; (option 1) type arguments list which _may_ be followed with
       ;; brackets and/or spaces, then optional variable arity
       "[ \t\n\r]*"
       (cc-imenu-java-build-type-args-regex 3)
       "[][ \t\n\r]*"
       "\\(" cc-imenu-java-ellipsis-regexp "\\)?"
       "\\|"
       ;; (option 2) just brackets and/or spaces (there should be at
       ;; least one), then optional variable arity
       "[][ \t\n\r]+"
       "\\(" cc-imenu-java-ellipsis-regexp "\\)?"
       "\\|"
       ;; (option 3) just variable arity
       cc-imenu-java-ellipsis-regexp
       "\\)"))

    (define cc-imenu-java-comment-regexp
      (concat
       "/"
       "\\("
       ;; a traditional comment
       "\\*"
       "\\("
       "[^*]"
       "\\|"
       "\\*+[^/*]"
       "\\)*"
       "\\*+/"
       "\\|"
       ;; an end-of-line comment
       "/[^\n\r]*[\n\r]"
       "\\)"
       "[ \t\n\r]*"))

    ;; Comments are allowed before the argument, after any of the
    ;; modifiers and after the identifier.
    (define cc-imenu-java-method-arg-regexp
      (concat
       "\\(" cc-imenu-java-comment-regexp "\\)*"
       ;; optional modifiers
       "\\("
       ;; a modifier is either an annotation or "final"
       "\\("
       "@[" c-alpha "_]"
       "[" c-alnum "._]*"
       ;; TODO support element-value pairs!
       "\\|"
       "final"
       "\\)"
       ;; a modifier ends with comments and/or ws
       "\\("
       "\\(" cc-imenu-java-comment-regexp "\\)+"
       "\\|"
       "[ \t\n\r]+"
       "\\(" cc-imenu-java-comment-regexp "\\)*"
       "\\)"
       "\\)*"
       ;; type spec
       cc-imenu-java-type-spec-regexp
       ;; identifier
       "[" c-alpha "_]"
       "[" c-alnum "_]*"
       ;; optional comments and/or ws
       "[ \t\n\r]*"
       "\\(" cc-imenu-java-comment-regexp "\\)*"))

    (define cc-imenu-java-generic-expression
      (list
       (list #f
             (concat
              cc-imenu-java-type-spec-regexp
              "\\("                  ; method name which gets captured
                                        ; into index
              "[" c-alpha "_]"
              "[" c-alnum "_]*"
              "\\)"
              "[ \t\n\r]*"
              ;; An argument list that contains zero or more arguments.
              (concat
               "("
               "[ \t\n\r]*"
               "\\("
               "\\(" cc-imenu-java-method-arg-regexp ",[ \t\n\r]*\\)*"
               cc-imenu-java-method-arg-regexp
               "\\)?"
               ")"
               "[.,_" c-alnum " \t\n\r]*" ; throws etc.
               "{"))
             7)))

    ;;----------------------------------------------------------------
    ;; Internal variables
    ;;----------------------------------------------------------------

    (define cc-imenu-objc-generic-expression-noreturn-index #f)
    (define cc-imenu-objc-generic-expression-general-func-index #f)
    (define cc-imenu-objc-generic-expression-proto-index #f)
    (define cc-imenu-objc-generic-expression-objc-base-index #f)

    (define cc-imenu-objc-generic-expression
      (concat
       ;;
       ;; For C
       ;;
       ;; > Special case to match a line like `main() {}'
       ;; > e.g. no return type, not even on the previous line.
       ;; Pick a token by (match-string 1)
       (car (cdr (nth 1 cc-imenu-c++-generic-expression))) ; -> index += 2
       (begin (set! cc-imenu-objc-generic-expression-noreturn-index 1) "")
       ;; > Special case for definitions using phony prototype macros
       ;; > like: `int main _PROTO( (int argc,char *argv[]) )'.
       ;; Pick a token by (match-string 3)
       (if cc-imenu-c-prototype-macro-regexp
           (concat
            "\\|"
            (car (cdr (nth 3 cc-imenu-c++-generic-expression))) ; -> index += 1
            (begin
              (set! cc-imenu-objc-generic-expression-objc-base-index 4)
              (set! cc-imenu-objc-generic-expression-general-func-index 5)
              ""))
           (begin
             (set! cc-imenu-objc-generic-expression-objc-base-index 3)
             (set! cc-imenu-objc-generic-expression-general-func-index 4)
             ""))
       (begin (set! cc-imenu-objc-generic-expression-proto-index 3) "")
       ;;
       ;; For Objective-C
       ;; Pick a token by (match-string 3 or 4)
       ;;
       "\\|\\("
       "^[-+][:" c-alnum "()*_,<>\n\t ]*[;{]" ; Methods
       "\\|"
       "^@interface[\t ]+[" c-alnum "_]+[\t ]*:"
       "\\|"
       "^@interface[\t ]+[" c-alnum "_]+[\t ]*([" c-alnum "_]+)"
       "\\|"
       ;; For NSObject, NSProxy and Object... They don't have super
       ;; class.
       "^@interface[\t ]+[" c-alnum "_]+[\t ]*.*$"
       "\\|"
       "^@implementation[\t ]+[" c-alnum "_]+[\t ]*([" c-alnum "_]+)"
       "\\|"
       "^@implementation[\t ]+[" c-alnum "_]+"
       "\\|"
       "^@protocol[\t ]+[" c-alnum "_]+" "\\)"
       "\\|"
       ;; > General function name regexp
       ;; Pick a token by (match-string 4)
       (car (cdr (nth 2 cc-imenu-c++-generic-expression))))) ; -> index += 6

    ;; Imenu support for objective-c uses functions.
    (define (cc-imenu-objc-method-to-selector method)
      ;; Return the objc selector style string of METHOD.
      ;; Example:
      ;; - perform: (SEL)aSelector withObject: object1 withObject: object2; /* METHOD */
      ;; =>
      ;; -perform:withObject:withObject:withObject: /* selector */
      ;;--------------------------------------------------------------
      (let ((return "")                 ; String to be returned
            (p 0)                       ; Current scanning position in METHOD
            (pmax (string-length method))
            (char #f)                   ; Current scanning target
            (betweenparen 0)            ; CHAR is in parentheses.
            (argreq #f)                 ; An argument is required.
            (inargvar #f))              ; position of CHAR is in an argument variable.
        (let loop ()
          (when (< p pmax)
            (set! char (string-ref method p))
            (set! p (+ p 1))
            (cond
             ;; Is CHAR part of an objc token?
             ((and (not inargvar)       ; Ignore if CHAR is part of an argument variable.
                   (= 0 betweenparen)   ; Ignore if CHAR is in parentheses.
                   (or (and (char<=? #\a char) (char<=? char #\z))
                       (and (char<=? #\A char) (char<=? char #\Z))
                       (and (char<=? #\0 char) (char<=? char #\9))
                       (char=? #\_ char)))
              (if argreq
                  (begin
                    (set! inargvar #t)
                    (set! argreq #f))
                  (set! return (concat return (string char)))))
             ;; Or a white space?
             ((and inargvar (or (char=? #\space char) (char=? #\newline char)))
              (set! inargvar #f))
             ;; Or a method separator?
             ;; If a method separator, the next token will be an argument variable.
             ((char=? #\: char)
              (set! argreq #t)
              (set! return (concat return (string char))))
             ;; Or an open parentheses?
             ((char=? #\( char)
              (set! betweenparen (+ betweenparen 1)))
             ;; Or a close parentheses?
             ((char=? #\) char)
              (set! betweenparen (- betweenparen 1))))
            (loop)))
        return))

    (define (cc-imenu-objc-remove-white-space str)
      ;; Remove all spaces and tabs from STR.
      ;;--------------------------------------------------------------
      (let ((return "")
            (p 0)
            (max (string-length str))
            (char #f))
        (let loop ()
          (when (< p max)
            (set! char (string-ref str p))
            (set! p (+ p 1))
            (if (or (char=? char #\space) (char=? char #\tab))
                #f
                (set! return (concat return (string char))))
            (loop)))
        return))

    (define (cc-imenu-objc-function)
      ;; Imenu support for Objective C mode.
      ;;--------------------------------------------------------------
      (let ((methodlist '())
            (clist '())
            ;;
            ;; OBJC, Cnoreturn, Cgeneralfunc, Cproto are constants.
            ;;
            ;;                  *Warning for developers*
            ;; These constants depend on `cc-imenu-c++-generic-expression'.
            ;;
            (OBJC cc-imenu-objc-generic-expression-objc-base-index)
            ;; Special case to match a line like `main() {}'
            (Cnoreturn cc-imenu-objc-generic-expression-noreturn-index)
            ;; General function name regexp
            (Cgeneralfunc cc-imenu-objc-generic-expression-general-func-index)
            ;; Special case for definitions using phony prototype macros
            ;; like: `int main _PROTO( (int argc,char *argv[]) )'.
            (Cproto cc-imenu-objc-generic-expression-proto-index)
            (langnum #f)
            ;;
            (classcount 0)
            (toplist '())
            (str #f)
            (str2 #f)
            (intflen (string-length "@interface"))
            (implen (string-length "@implementation"))
            (prtlen (string-length "@protocol")))
        (goto-char (point-max))
        ;;
        (let loop ()
          (when (re-search-backward cc-imenu-objc-generic-expression #f #t)
            (when (not (c-literal-limits))
              (set! langnum (if (match-beginning OBJC)
                                OBJC
                                (cond
                                 ((match-beginning Cproto) Cproto)
                                 ((match-beginning Cgeneralfunc) Cgeneralfunc)
                                 ((match-beginning Cnoreturn) Cnoreturn)
                                 (else #f))))
              (set! str (buffer-substring-no-properties
                         (match-beginning langnum) (match-end langnum)))
              ;;
              (cond
               ;;
               ;; C
               ;;
               ((not (eqv? langnum OBJC))
                ;; Don't be fooled by @end // Classname.
                (when (not (char=? (string-ref
                                    (match-string-no-properties 0) 0)
                                   #\@))
                  (set! clist (cons (cons str (match-beginning langnum))
                                    clist))))
               ;;
               ;; ObjC
               ;;
               ;; An instance Method
               ((char=? (string-ref str 0) #\-)
                (set! str (concat "-" (cc-imenu-objc-method-to-selector str)))
                (set! methodlist (cons (cons str (match-beginning langnum))
                                       methodlist)))
               ;; A factory Method
               ((char=? (string-ref str 0) #\+)
                (set! str (concat "+" (cc-imenu-objc-method-to-selector str)))
                (set! methodlist (cons (cons str (match-beginning langnum))
                                       methodlist)))
               ;; Interface or implementation or protocol
               ((char=? (string-ref str 0) #\@)
                (set! classcount (+ classcount 1))
                (cond
                 ((and (> (string-length str) implen)
                       (string=? (substring str 0 implen) "@implementation"))
                  (set! str (substring str implen))
                  (set! str2 "@implementation"))
                 ((string=? (substring str 0 intflen) "@interface")
                  (set! str (substring str intflen))
                  (set! str2 "@interface"))
                 ((string=? (substring str 0 prtlen) "@protocol")
                  (set! str (substring str prtlen))
                  (set! str2 "@protocol"))
                 (else (set! str2 #f)))
                (when str2
                  (set! str (cc-imenu-objc-remove-white-space str))
                  (set! methodlist (cons (cons str2
                                               (match-beginning langnum))
                                         methodlist))
                  (set! toplist (cons (cons str methodlist) toplist))
                  (set! methodlist '()))))
              (loop))))
        ;; In this buffer, there is only one or zero
        ;; @{interface|implementation|protocol}.
        (if (< classcount 2)
            (let ((classname (and (pair? toplist) (car (car toplist))))
                  (p (and (pair? toplist)
                          (pair? (cdr (car toplist)))
                          (cdr (car (cdr (car toplist))))))
                  (last #f))
              (when classname
                (set! toplist (cons (cons classname p)
                                    (cdr (cdr (car toplist))))))
              ;; Add C lang token
              (if (pair? clist)
                  (if (pair? toplist)
                      (begin
                        (set! last toplist)
                        (let loop ()
                          (when (pair? (cdr last))
                            (set! last (cdr last))
                            (loop)))
                        (set-cdr! last clist))
                      (set! toplist clist))))
            ;; Add C lang tokens as a sub menu
            (if (pair? clist)
                (set! toplist (cons (cons "C" clist) toplist))))
        ;;
        toplist))

    (define (cc-imenu-init mode-generic-expression . rest)
      ;; `cc-menus.el:526'.
      ;;--------------------------------------------------------------
      (let ((mode-create-index-function (and (pair? rest) (car rest))))
        (set!imenu-generic-expression mode-generic-expression)
        (set!imenu-case-fold-search #f)
        (when mode-create-index-function
          (set!imenu-create-index-function mode-create-index-function))))))
