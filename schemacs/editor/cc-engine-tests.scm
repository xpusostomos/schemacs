;; Tests for `(schemacs editor cc-engine)' - the first tranche of
;; `lisp/progmodes/cc-engine.el': the macro cache and the
;; preprocessor-directive machinery, the basic utilities, `c-point' and
;; the keyword lookup.
;;
;; **Every expectation here is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' on the same fixture text in a real `c-mode'
;; buffer before the port was written (the script is the one this file's
;; handoff names). A whole-fixture differential - all 72 answers in this
;; file - was run both ways and is identical.
;;
;; The fixture's positions, for reading the tests:
;;
;;     line 1  1..18   "#include <stdio.h>"       newline 19
;;     line 2  20..35  "#define FOO(x) \"          newline 36
;;     line 3  37..47  "  ((x) + 1)"              newline 48
;;     line 4  49..54  "int a;"                   newline 55
;;     line 5  56..80  "#define BAR 1 /* trailing" newline 81
;;     line 6  82..94  "   comment */"            newline 95
;;     line 7  96..101 "int b;"                   newline 102
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) allocate-buffer set-buffer current-buffer
       set-buffer-local-value!)
 (only (schemacs editor editfns) insert goto-char point
       buffer-substring-no-properties)
 (only (schemacs editor syntax) set-syntax-table)
 (only (schemacs editor textprop) get-text-property)
 (only (schemacs editor cc-defs) c-lang-const)
 (schemacs editor cc-langs)
 (schemacs editor cc-vars)
 (schemacs editor cc-engine))

(test-begin "schemacs_editor_cc_engine")

(define c-fixture
  "#include <stdio.h>\n#define FOO(x) \\\n  ((x) + 1)\nint a;\n#define BAR 1 /* trailing\n   comment */\nint b;\n")

(define (c-buffer thunk)
  ;; A `c-mode' buffer as `define-derived-mode' will build one: the
  ;; language variables initialised, the mode's syntax table installed,
  ;; and the major mode recorded (the lazy keyword table reads it).
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert c-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (thunk)))

(define (at n) (goto-char n))

(define (bom n) (at n) (list (c-beginning-of-macro) (point)))
(define (eom n) (at n) (c-end-of-macro) (point))

;;----------------------------------------------------------------------
;; The preprocessor-directive boundaries
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()

   (test-equal "in a directive's first line, the beginning is its start"
               '(#t 1) (bom 1))
   (test-equal "at the end of it too" '(#t 1) (bom 19))
   (test-equal "and on the '#' itself" '(#t 20) (bom 20))
   (test-equal "and on the directive's name" '(#t 20) (bom 21))
   (test-equal "a continued line belongs to the directive above it"
               '(#t 20) (bom 37))
   (test-equal "an ordinary line is not in a directive, and point stays"
               '(#f 49) (bom 49))
   (test-equal "the second directive" '(#t 56) (bom 56))
   (test-equal "its body's continuation" '(#t 56) (bom 70))
   (test-equal "and its comment's first line" '(#t 56) (bom 81))
   (test-equal "the comment's second line is inside the directive it continues"
               '(#t 56) (bom 82))
   (test-equal "nor the line after it" '(#f 96) (bom 96))
   (test-equal "nor end of buffer" '(#f 103) (bom 103))

   ;; `c-end-of-macro': the end is the end of the last continued line,
   ;; and a block comment opened in the directive is moved over.
   (test-equal "the end of a one-line directive" 48 (eom 20))
   (test-equal "from inside it, the same end" 48 (eom 21))
   (test-equal "from a continuation line" 48 (eom 37))
   (test-equal "an ordinary line ends at its own end-of-line" 55 (eom 49))
   (test-equal "a directive whose block comment spans lines ends after it"
               95 (eom 56))
   (test-equal "from inside that comment" 95 (eom 70))
   (test-equal "an ordinary last line" 102 (eom 96))

   ;; `c-syntactic-end-of-macro' and `c-no-comment-end-of-macro': the
   ;; "safe" end and the comment start of the same directives.
   (test-equal "the syntactic end of a whole-line directive" 48
               (begin (at 20) (c-syntactic-end-of-macro)))
   (test-equal "the block comment that runs past the directive is included"
               95 (begin (at 56) (c-syntactic-end-of-macro)))
   (test-equal "the syntactic end is the same without comments asked for"
               48 (begin (at 20) (c-no-comment-end-of-macro)))
   (test-equal "and so is this one" 95 (begin (at 56) (c-no-comment-end-of-macro)))

   ;; `c-forward-over-cpp-define-id' and `c-forward-to-cpp-define-body'
   ;; act only at the '#'.
   (test-equal "the #define'd identifier ends after FOO(x)" '(31 31)
               (begin (at 20) (list (c-forward-over-cpp-define-id) (point))))
   (test-equal "not at the directive's name" '(#f 21)
               (begin (at 21) (list (c-forward-over-cpp-define-id) (point))))
   (test-equal "and the second one" '(67 67)
               (begin (at 56) (list (c-forward-over-cpp-define-id) (point))))
   (test-equal "the body starts after the parameter list" '(39 39)
               (begin (at 20) (list (c-forward-to-cpp-define-body) (point))))
   (test-equal "#define FOO is not a body" '(#f 21)
               (begin (at 21) (list (c-forward-to-cpp-define-body) (point))))
   (test-equal "an object-like macro's body starts after its name" '(68 68)
               (begin (at 56) (list (c-forward-to-cpp-define-body) (point))))

   ;; `c-backward-single-comment'.
   (test-equal "at the buffer's start there is no comment" '(#f 1)
               (begin (at 1) (list (c-backward-single-comment) (point))))
   (test-equal "an ordinary line before it: point moves to the line's end"
               '(#f 48) (begin (at 49) (list (c-backward-single-comment) (point))))
   (test-equal "at the end of the 'int a;' line" '(#f 55)
               (begin (at 55) (list (c-backward-single-comment) (point))))
   (test-equal "at the directive's newline: nothing before it" '(#f 81)
               (begin (at 81) (list (c-backward-single-comment) (point))))
   (test-equal "the comment's last line's start" '(#f 81)
               (begin (at 82) (list (c-backward-single-comment) (point))))
   ;; Emacs answers t and leaves point at 70 - the beginning of the
   ;; comment's *first* line, not the comment's start at 69.
   (test-equal "after the block comment: found, before it" '(#t 70)
               (begin (at 95) (list (c-backward-single-comment) (point))))
   (test-equal "the same from the newline after it" '(#t 70)
               (begin (at 96) (list (c-backward-single-comment) (point))))
   (test-equal "inside the comment, at its text" '(#f 69)
               (begin (at 70) (list (c-backward-single-comment) (point))))))

;;----------------------------------------------------------------------
;; The macro cache: Emacs 31.1's own sequence, with the cache reset
;; explicitly between the steps so that nothing else's probing shows.
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (define (reset!) (set!c-macro-cache #f)
     (set!c-macro-cache-start-pos #f)
     (set!c-macro-cache-syntactic #f)
     (set!c-macro-cache-no-comment #f))

   (reset!) (at 70) (c-beginning-of-macro)
   (test-equal "after c-beginning-of-macro the cache holds the start"
               '(56) (c-macro-cache))
   (test-equal "and the probing position" 70 (c-macro-cache-start-pos))
   (test-equal "with nothing else known" '(#f #f)
               (list (c-macro-cache-syntactic) (c-macro-cache-no-comment)))

   (at 70) (c-end-of-macro)
   (test-equal "c-end-of-macro records the end on the cache's cdr"
               '(56 . 95) (c-macro-cache))
   (test-equal "and leaves the start position alone" 70
               (c-macro-cache-start-pos))

   (c-invalidate-macro-cache 60 61)
   (test-equal "a change inside the macro drops the known end" '(56)
               (c-macro-cache))
   (test-equal "and moves the start position back to the change" 60
               (c-macro-cache-start-pos))

   (reset!) (at 70) (c-beginning-of-macro)
   (c-invalidate-macro-cache 40 41)
   (test-equal "a change before the macro clears the cache" '(#f #f)
               (list (c-macro-cache) (c-macro-cache-start-pos)))

   (reset!) (at 20) (c-beginning-of-macro) (c-syntactic-end-of-macro)
   (test-equal "the syntactic end is cached beside the bounds"
               '(20 . 48) (c-macro-cache))
   (test-equal "and is the answer c-syntactic-end-of-macro gave" 48
               (c-macro-cache-syntactic))

   (reset!) (at 20) (c-beginning-of-macro) (c-no-comment-end-of-macro)
   (test-equal "the no-comment end is cached too" 48
               (c-macro-cache-no-comment))))

;;----------------------------------------------------------------------
;; `c-point' and `c-is-escaped'
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (at 42)
   (test-equal "c-point 'bol" 37 (c-point 'bol))
   (test-equal "c-point 'eol" 48 (c-point 'eol))
   (test-equal "c-point 'boi" 39 (c-point 'boi))
   (test-equal "c-point 'boll skips no continuation here" 20
               (begin (at 35) (c-point 'boll)))
   (test-equal "c-point 'eoll ends the logical line" 48
               (begin (at 35) (c-point 'eoll)))
   (test-equal "c-point 'bopl" 20 (begin (at 42) (c-point 'bopl)))
   (test-equal "c-point 'bonl" 49 (begin (at 42) (c-point 'bonl)))
   (test-equal "c-point 'eopl" 36 (begin (at 42) (c-point 'eopl)))
   (test-equal "c-point 'eonl" 55 (begin (at 42) (c-point 'eonl)))
   (test-equal "c-point 'iopl" 20 (begin (at 42) (c-point 'iopl)))
   (test-equal "c-point 'ionl" 49 (begin (at 42) (c-point 'ionl)))
   (test-equal "c-point with an explicit point answers for that point"
               37 (begin (at 1) (c-point 'bol 42)))
   (test-equal "and does not move point" 1 (point))

   ;; The arms whose helpers are not ported say so.
   (test-assert "c-point 'bod raises rather than guessing"
                (guard (e (#t #t))
                  (at 42) (c-point 'bod) #f))

   ;; `c-is-escaped' asks about the character at POS: 36 is the newline
   ;; that the backslash at 35 escapes, and 35 itself is not escaped.
   (test-equal "the newline after a backslash is escaped" #t
               (begin (at 36) (c-is-escaped 36)))
   (test-equal "the backslash itself is not" #f
               (begin (at 35) (c-is-escaped 35)))
   (test-equal "nor an ordinary character" #f
               (begin (at 42) (c-is-escaped 42)))))

;;----------------------------------------------------------------------
;; The keyword lookup (`c-keyword-sym', `c-keyword-member')
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (test-equal "int is a keyword, and the symbol is its name"
               'int (c-keyword-sym "int"))
   (test-equal "it is a primitive type keyword" #t
               (c-keyword-member (c-keyword-sym "int")
                                 'c-primitive-type-kwds))
   (test-equal "but not a class keyword" #f
               (c-keyword-member (c-keyword-sym "int") 'c-class-kwds))
   (test-equal "a made-up name is not a keyword" #f
               (c-keyword-sym "zzz"))
   (test-equal "a nil symbol is not a member of anything" #f
               (c-keyword-member #f 'c-primitive-type-kwds))))

;;----------------------------------------------------------------------
;; State variables, `c-calculate-state', `c-delq-from-dotted-list'
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (test-equal "a fresh buffer has no hungry delete" #f (c-hungry-delete-key))
   (test-equal "electric actions are on by default" #t (c-electric-flag))
   (test-equal "and auto-newline is off" #f (c-auto-newline))
   (set!c-electric-flag #f)
   (test-equal "setting one is per buffer" #f (c-electric-flag))
   (let ((home (current-buffer))
         (other (allocate-buffer)))
     (set-buffer other)
     (test-equal "and another buffer keeps the default" #t (c-electric-flag))
     (set-buffer home))

   (test-equal "no argument toggles t to nil" #f (c-calculate-state #f #t))
   (test-equal "a zero prefix toggles too" #f (c-calculate-state 0 #t))
   (test-equal "a negative prefix turns it off" #f
               (c-calculate-state -1 #f))
   (test-equal "a list prefix counts as its number" #t
               (c-calculate-state '(4) #f))
   (test-equal "a positive number turns it on" #t (c-calculate-state 3 #f))

   (test-equal "c-delq-from-dotted-list removes from the spine, keeping the tail"
               '(b . c) (c-delq-from-dotted-list 'a '(a b a . c)))
   (test-equal "and answers the list when nothing matches" '(a b)
               (c-delq-from-dotted-list 'z '(a b)))))

;;----------------------------------------------------------------------
;; The c-type property and the parsing-error report
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (at 56)
   (c-put-c-type-property 60 'foo)
   (test-equal "c-put-c-type-property sets the property"
               'foo (get-text-property 60 'c-type))
   (c-clear-c-type-property 56 70 'foo)
   (test-equal "c-clear-c-type-property removes it"
               #f (get-text-property 60 'c-type))

   (set!c-parsing-error "bad thing")
   (test-equal "c-echo-parsing-error answers the error string"
               "bad thing" (c-echo-parsing-error))
   (test-equal "and does the same when asked for quiet"
               "bad thing" (c-echo-parsing-error #t))
   (test-equal "with reporting enabled it answers the string as well"
               "bad thing"
               (begin (*c-report-syntactic-errors* #t)
                      (c-echo-parsing-error)))))

;;----------------------------------------------------------------------
;; `c-shift-line-indentation'
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (at 42)
   (c-shift-line-indentation 2)
   (test-equal "shifting line 3 right by two moves point and the text"
               '(44 "    ((x) + ")
               (list (point) (buffer-substring-no-properties 37 48)))))

(test-end "schemacs_editor_cc_engine")
