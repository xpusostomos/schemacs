;; Tests for `(schemacs progmodes cc-engine)' - the first tranche of
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
 (only (guile) hash-ref hash-set!)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer
       buffer-local-value set-buffer-local-value!)
 (only (schemacs editfns) insert goto-char point delete-region save-excursion
       point-min point-max buffer-substring-no-properties char-after
       char-before narrow-to-region widen)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs search) looking-at)
 (only (schemacs textprop) get-text-property text-property-any)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*
       c-skip-ws-chars-forward c-skip-ws-chars-backward c-clear-char-property)
 (only (schemacs cmds) beginning-of-line delete-char)
 (schemacs progmodes cc-langs)
 (schemacs progmodes cc-vars)
 (schemacs progmodes cc-styles)
 (schemacs progmodes cc-engine))

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
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
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

;;----------------------------------------------------------------------
;; The comment and syntactic-whitespace tools
;; (`c-forward-single-comment', `c-forward-comments',
;; `c-backward-comments', `c-skip-ws-chars-forward/-backward').
;;
;; Every expectation is Emacs 31.1's answer at the same position on this
;; fixture; a whole-file differential probes all five functions at every
;; position 1..59 and is identical to Emacs's.
;;----------------------------------------------------------------------
(define ws-fixture
  "a /* x */ b\n// line\nc \\\n d\n  e /* multi\nline */ f\n// last\n")

(define (with-ws-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert ws-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (thunk)))

(with-ws-buffer
 (lambda ()
   (define (probe f p)
     (goto-char p)
     (let ((r (f))) (list r (point))))
   (define (probe-skip f set p)
     (goto-char p)
     (let ((r (f set))) (list r (point))))

   (test-equal "forward-single-comment skips the space and the comment"
               '(#t 10) (probe c-forward-single-comment 2))
   (test-equal "with no comment following, it only skips whitespace"
               '(#f 11) (probe c-forward-single-comment 10))
   (test-equal "a line comment's newline is included" '(#t 21)
               (probe c-forward-single-comment 12))
   (test-equal "at a comment's own start there is nothing to skip" '(#f 14)
               (probe c-forward-single-comment 14))
   (test-equal "a line continuation is whitespace" '(#f 26)
               (probe c-forward-single-comment 22))

   (test-equal "forward-comments moves over whitespace and comments"
               '(#f 11) (probe c-forward-comments 2))
   (test-equal "and over a line comment onto its next line" '(#f 21)
               (probe c-forward-comments 13))
   (test-equal "and over a continuation and the space after it"
               '(#f 26) (probe c-forward-comments 22))
   (test-equal "and over several spaces" '(#f 30)
               (probe c-forward-comments 27))

   (test-equal "backward-comments moves back over the block comment"
               '(#f 2) (probe c-backward-comments 10))
   (test-equal "from the line's start there is nothing to move over"
               '(#f 22) (probe c-backward-comments 23))
   (test-equal "and from a continued line it stops after the last break"
               '(#f 22) (probe c-backward-comments 25))
   (test-equal "from inside a multi-line comment it moves a character"
               '(#f 40) (probe c-backward-comments 41))
   (test-equal "over the whole second line comment" '(#f 50)
               (probe c-backward-comments 59))

   (test-equal "skip-ws-chars-forward takes the run of whitespace"
               '(1 3) (probe-skip c-skip-ws-chars-forward " \t\n" 2))
   (test-equal "and stops at a non-whitespace char"
               '(3 30) (probe-skip c-skip-ws-chars-forward " \t\n" 27))
   (test-equal "skip-ws-chars-backward takes the run before point"
               '(-1 12) (probe-skip c-skip-ws-chars-backward " \t\n" 13))
   (test-equal "and stops before a non-whitespace char"
               '(-3 27) (probe-skip c-skip-ws-chars-backward " \t\n" 30))
   (test-equal "a zero answer when nothing matches" '(0 1)
               (probe-skip c-skip-ws-chars-backward " \t\n" 1))))

;;----------------------------------------------------------------------
;; Token boundaries (`c-beginning-of-current-token',
;; `c-simple-skip-symbol-backward'), moved up for `c-backward-sws'.
;; Expectations are Emacs 31.1's on the same buffer; a per-position
;; differential (bot/sss and the list wrappers, 423 lines) is identical.
;;----------------------------------------------------------------------
(define token-fixture
  "int foo_bar(baz);\nif (a->b) x++;\n((a) (b))\n(x\n")

(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert token-fixture)
  (set-buffer-local-value! b 'major-mode 'c-mode)
  ;; `cc-mode.el:639' sets this buffer-locally; there is no
  ;; cc-mode yet, so the buffer does here what the mode will.
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (c-init-language-vars c-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))

  (define (probe f p) (goto-char p) (list (f) (point)))

  (test-equal "inside a symbol, backward to its start" '(#t 5)
              (probe c-beginning-of-current-token 9))
  (test-equal "between tokens it does not move" '(#f 4)
              (probe c-beginning-of-current-token 4))
  (test-equal "at the buffer start likewise" '(#f 1)
              (probe c-beginning-of-current-token 1))
  (test-equal "after an operator it moves over it" '(#t 13)
              (probe c-beginning-of-current-token 15))
  (test-equal "skip-symbol-backward from after 'int'" '(#t 1)
              (probe c-simple-skip-symbol-backward 4))
  (test-equal "and from inside foo_bar" '(#t 5)
              (probe c-simple-skip-symbol-backward 9))
  (test-equal "a word char after a paren" '(#t 36)
              (probe c-simple-skip-symbol-backward 37))
  (test-equal "and at the end of the buffer's last word" '(#t 45)
              (probe c-simple-skip-symbol-backward 46)))

;;----------------------------------------------------------------------
;; The syntactic-whitespace property helpers (`cc-engine.el:1908') and
;; the doc-comment defaults (`cc-mode.el:136'-`:147')
;;----------------------------------------------------------------------
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert "(a b)\n(c d)\n")
  (c-put-is-sws 2 3)
  (c-put-in-sws 1 4)
  (test-equal "c-put-is-sws marks its character"
              #t (get-text-property 2 'c-is-sws))
  (test-equal "c-put-in-sws marks its range"
              #t (get-text-property 3 'c-in-sws))
  (test-equal "text-property-any finds the rung by its value"
              2 (text-property-any 1 5 'c-is-sws #t))
  (c-remove-is-sws 2 3)
  (test-equal "c-remove-is-sws removes only c-is-sws"
              '(#f #t) (list (get-text-property 2 'c-is-sws)
                             (get-text-property 2 'c-in-sws)))
  (c-remove-is-and-in-sws 1 4)
  (test-equal "c-remove-is-and-in-sws removes both"
              '(#f #f) (list (get-text-property 2 'c-is-sws)
                             (get-text-property 3 'c-in-sws))))

(test-equal "the doc line-join regexp starts unmatchable"
            "\\`a\\`" (c-doc-line-join-re))
(test-equal "and so does the bright-comment one"
            "\\`a\\`" (c-doc-bright-comment-start-re))
(test-equal "the line-join end-char list starts nil" #f (c-doc-line-join-end-ch))

;;----------------------------------------------------------------------
;; Literal positions (`c-semi-pp-to-literal', `c-full-pp-to-literal',
;; `c-literal-limits'/`-start'/`-type', `c-in-literal') and the three
;; literal caches. Every expectation is Emacs 31.1's, measured on this
;; fixture with its syntax-table text properties stripped (this tree has
;; none); a whole-file differential probes seven functions at every
;; position and is identical.
;;----------------------------------------------------------------------
(define literal-fixture
  "int a = \"str\\\" x\"; /* block\n comment */ b; // line\nchar c = 'q'; \"open\n")

(define (with-literal-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert literal-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (thunk)))

(with-literal-buffer
 (lambda ()
   (define (semi p) (goto-char p) (let ((r (c-semi-pp-to-literal (point))))
                                    (list (%c-cadr r) (%c-caddr r))))
   (define (full p) (goto-char p) (let ((r (c-full-pp-to-literal (point))))
                                    (list (%c-cadr r) (%c-caddr r))))
   (define (at-lit f p) (goto-char p) (f))

   (test-equal "a state just before the string is outside" '(#f #f)
               (semi 9))
   (test-equal "inside the string: its type and start" '(string 9)
               (semi 10))
   (test-equal "the string's bounds" '(string (9 . 18))
               (full 10))
   (test-equal "inside the block comment: its type and start" '(c 20)
               (semi 21))
   (test-equal "an ordinary position after it is outside" '(#f #f)
               (semi 40))

   (test-equal "c-in-literal: string" 'string (at-lit c-in-literal 10))
   (test-equal "c-in-literal: comment" 'c (at-lit c-in-literal 21))
   (test-equal "c-in-literal: neither" #f (at-lit c-in-literal 40))
   (test-equal "c-in-literal: the second string" 'string
               (at-lit c-in-literal 67))
   (test-equal "c-literal-start: string" 9 (at-lit c-literal-start 10))
   (test-equal "c-literal-start: comment" 20 (at-lit c-literal-start 21))
   (test-equal "c-literal-start: neither" #f (at-lit c-literal-start 40))
   (test-equal "c-literal-start: the second string" 66
               (at-lit c-literal-start 67))
   (test-equal "c-literal-limits inside the string" '(9 . 18)
               (at-lit c-literal-limits 10))
   (test-equal "c-literal-type of the string's range" 'string
               (c-literal-type (cons 9 18)))
   (test-equal "c-literal-type of the block comment's range" 'c
               (c-literal-type (cons 20 34)))

   ;; The regression for the `forw_comment' resumption fix: probe every
   ;; position in order (filling the near caches), then ask 40 again -
   ;; before the fix the rescan resumed on the closing `*/''s second
   ;; character and never left the comment.
   (let loop ((p 1))
     (when (<= p 39)
       (goto-char p) (c-semi-pp-to-literal (point))
       (loop (+ p 1))))
   (test-equal "after probing every position, 40 is still outside" '(#f #f)
               (semi 40))))

;;----------------------------------------------------------------------
;; The syntactic-whitespace engine (`cc-engine.el:1800'-`:2694').
;;
;; Every expectation is Emacs 31.1's answer on this fixture, measured
;; with `emacs -Q --batch' in a real `c-mode' buffer first; the whole
;; table (forward and backward at all 102 positions, and
;; `c-partial-ws-p' over all 101 adjacent pairs) is identical both ways.
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (define (fwd p) (goto-char p) (c-forward-syntactic-ws) (point))
   (define (bwd p) (goto-char p) (c-backward-syntactic-ws) (point))
   (define (fwbw p) (list p (fwd p) (bwd p)))

   (test-equal "sws: at bob, over the #include directive" '(1 49 1) (fwbw 1))
   (test-equal "sws: at a directive's #" '(20 49 1) (fwbw 20))
   (test-equal "sws: at a line continuation" '(34 39 34) (fwbw 34))
   (test-equal "sws: inside a trailing block comment" '(55 85 55) (fwbw 55))
   (test-equal "sws: on the comment's second line" '(69 96 69) (fwbw 69))
   (test-equal "sws: at a comment end" '(81 85 81) (fwbw 81))
   (test-equal "sws: at the newline after a block comment" '(95 96 55) (fwbw 95))
   (test-equal "sws: at eob" '(102 103 102) (fwbw 102))

   ;; The second pass runs on the ladder the first one laid down; its
   ;; answers must not move.
   (test-equal "sws: a cached second pass answers the same" '(55 85 55)
               (fwbw 55))
   (test-equal "sws: a cached forward scan" 49 (fwd 1))

   (test-equal "c-point 'bosws at a directive" 1 (begin (goto-char 49) (c-point 'bosws)))
   (test-equal "c-point 'eosws at a directive" 49 (begin (goto-char 20) (c-point 'eosws)))
   (test-equal "c-point 'bosws after a comment" 55 (begin (goto-char 95) (c-point 'bosws)))

   (test-equal "c-partial-ws-p: inside a line continuation" #t
               (c-partial-ws-p 34 35))
   (test-equal "c-partial-ws-p: inside a directive's block comment" #t
               (c-partial-ws-p 81 82))
   (test-equal "c-partial-ws-p: ordinary text" #f
               (c-partial-ws-p 1 2))))

;;----------------------------------------------------------------------
;; `c-looking-at-c++-attribute' and `c-enclosing-c++-attribute'
;;----------------------------------------------------------------------
;; Emacs's `c-buffer-is-cc-mode' is a buffer-local set by the mode's
;; init; until `c-mode' exists here it is the parameter, bound as a
;; mode's init will bind it.
(define attr-fixture "int x; [[a]] int y; [[b]\n")

(define (with-attr-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert attr-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (thunk))))

(with-attr-buffer
 (lambda ()
   (define (att p) (goto-char p) (c-looking-at-c++-attribute))
   (define (enc p)
     (goto-char p)
     (let ((r (c-enclosing-c++-attribute)))
       (and r (cons (car r) (cdr r)))))

   (test-equal "c-looking-at-c++-attribute: the opening [[ of a balanced attribute"
               13 (att 8))
   (test-equal "c-looking-at-c++-attribute: between the two brackets" #f
               (att 9))
   (test-equal "c-looking-at-c++-attribute: an ordinary position" #f
               (att 14))
   (test-equal "c-looking-at-c++-attribute: an unbalanced [[b]" #f
               (att 21))

   (test-equal "c-enclosing-c++-attribute: inside the attribute"
               '(8 . 13) (enc 10))
   (test-equal "c-enclosing-c++-attribute: at the attribute's last char"
               '(8 . 13) (enc 13))
   (test-equal "c-enclosing-c++-attribute: just before it" #f (enc 7))
   (test-equal "c-enclosing-c++-attribute: at its first bracket" #f (enc 8))
   (test-equal "c-enclosing-c++-attribute: an unbalanced one" #f (enc 23))))

;;----------------------------------------------------------------------
;; The change hooks (`c-invalidate-sws-region-before'/`-after').
;;
;; Every value here - the literal type and limits the before-change hook
;; records, and the state of the ladder after the change - is Emacs
;; 31.1's answer on the same edits, measured with `emacs -Q --batch'.
;;----------------------------------------------------------------------
(c-buffer
 (lambda ()
   (define (in-sws-any from to)
     (let loop ((p from) (r #f))
       (if (< p to)
           (loop (+ p 1)
                 (if (or (get-text-property p 'c-in-sws)
                         (get-text-property p 'c-is-sws))
                     #t r))
           r)))

   (goto-char 1)
   (c-forward-sws)
   (test-equal "the ladder covers the region the forward scan crossed"
               '(#t #f) (list (in-sws-any 1 50) (in-sws-any 50 103)))

   (c-invalidate-sws-region-before 84 84)
   (test-equal "before-change: a block comment is noted with its bounds"
               (list 'c (cons 70 95)) (list c-sws-lit-type c-sws-lit-limits))
   (goto-char 84)
   (insert "xx")
   (c-invalidate-sws-region-after 84 86 0)
   (test-equal "after-change: the edited region's ladder is gone"
               #f (in-sws-any 82 100))

   (goto-char 55)
   (let ((bp (point)))
     (c-invalidate-sws-region-before bp (+ bp 1))
     (test-equal "before-change: a cpp directive is noted with its bounds"
                 (list 'pound (cons 56 97))
                 (list c-sws-lit-type c-sws-lit-limits))
     (delete-region bp (+ bp 1))
     (c-invalidate-sws-region-after bp bp 1))
   (test-equal "after-change: a damaged comment opener breaks the ladder"
               #f (in-sws-any 50 81))))

;;----------------------------------------------------------------------
;; Statement barriers and punctuation (`cc-engine.el:1457'-`:1560')
;;----------------------------------------------------------------------
;; Every expectation is Emacs 31.1's answer; the whole-table
;; differential - `c-punctuation-in' over 98 pairs and
;; `c-crosses-statement-barrier-p' over eleven ranges of two fixtures -
;; was identical.
(c-buffer
 (lambda ()
   (define (punct f to) (c-punctuation-in f to))
   (define (barrier f to)
     (goto-char f)
     (*c-maybe-labelp* #f)
     (list (c-crosses-statement-barrier-p f to) (*c-maybe-labelp*)))
   (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
     ;; Walk the whole 98-pair table first, as the differential did: the
     ;; table was identical to Emacs's, and walking it also primes the
     ;; syntax cache from both directions. The barrier runs below then
     ;; exercise `RE_SETUP_SYNTAX_TABLE_FOR_OBJECT' in the regexp engine
     ;; - without it the cache is left with a null interval and a later
     ;; `\s' search says "Error in syntax_table logic for to-the-end
     ;; intervals" (this suite has been seen failing that way).
     (for-each (lambda (f)
                 (for-each (lambda (to)
                             (when (< f to) (punct f to)))
                           '(20 35 55 60 82 96 103)))
               '(1 4 9 20 27 34 49 55 56 69 81 85 95 96 102))
     ;; The differential's seven ranges, in its order.
     (for-each (lambda (pair) (barrier (car pair) (cdr pair)))
               '((1 . 20) (4 . 20) (20 . 35) (36 . 55) (56 . 82)
                 (82 . 96) (96 . 103)))

     (test-equal "c-punctuation-in: none between the directive's start and its end"
                 #f (punct 1 20))
     (test-equal "c-punctuation-in: the '<' of <stdio.h>" 10 (punct 4 20))
     (test-equal "c-punctuation-in: the '#' of the second directive" 54
                 (punct 1 55))
     (test-equal "c-punctuation-in: an ordinary declaration's ';'" 101
                 (punct 96 103))
     (test-equal "c-punctuation-in: nothing after the block comment opens"
                 #f (punct 95 96))
     (test-equal "c-punctuation-in: the comment's closing '/' is punctuation"
                 93 (punct 81 96))

     (test-equal "c-crosses-statement-barrier-p: a directive tail crosses its ';'"
                 '(54 #f) (barrier 36 55))
     (test-equal "c-crosses-statement-barrier-p: a comment body crosses nothing"
                 '(#f #f) (barrier 82 96))
     (test-equal "c-crosses-statement-barrier-p: the last declaration's ';'"
                 '(101 #f) (barrier 96 103))
     (test-equal "c-crosses-statement-barrier-p: nothing before the first ';'"
                 '(#f #f) (barrier 1 20)))))

;; The label fixture: `c-maybe-labelp' is the *first* `:' that might
;; start a label, and a `?' clears it.
(define barrier-label-fixture
  "foo: bar; while (x) y; a ? b : c;\ncase 1: break;\n")

(c-buffer
 (lambda ()
   (delete-region (point-min) (point-max))
   (insert barrier-label-fixture)
   (define (barrier f to)
     (goto-char f)
     (*c-maybe-labelp* #f)
     (list (c-crosses-statement-barrier-p f to) (*c-maybe-labelp*)))
   (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
     (test-equal "a label colon before the first ';' is remembered" '(9 4)
                 (barrier 1 20))
     (test-equal "the same range ended before the ';'" '(9 4) (barrier 1 10))
     (test-equal "a colon after a '?' is not a label" '(22 #f) (barrier 12 25))
     (test-equal "and a 'case' clause's colon after a '?'" '(33 #f)
                 (barrier 26 45)))))

;;----------------------------------------------------------------------
;; Virtual semicolons (`cc-engine.el:14184'-`:14243')
;;----------------------------------------------------------------------
;; `Q_FOO (x)' on a line is a virtual semicolon when
;; `c-macro-with-semi-re' names Q_, at the last non-WS position - and
;; nowhere else on the line. Emacs 31.1 on this fixture: position 10 is
;; the only true one.
(define vsemi-fixture "Q_FOO (x) // comment\n  next;\nint y;\n")

(c-buffer
 (lambda ()
   (delete-region (point-min) (point-max))
   (insert vsemi-fixture)
   (set!c-macro-with-semi-re "Q_[A-Z]+")
   (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
     (test-equal "at the last character before the comment" #t
                 (and (c-at-macro-vsemi-p 10) #t))
     (test-equal "not at the line's start" #f (c-at-macro-vsemi-p 1))
     (test-equal "not after the comment starts" #f (c-at-macro-vsemi-p 11))
     (test-equal "point stands at the tested position" #t
                 (begin (goto-char 10) (c-at-macro-vsemi-p) (= (point) 10)))
     (test-equal "the c-mode language names c-at-macro-vsemi-p" #t
                 (and (c-at-vsemi-p 10) #t))
     (test-equal "c-vsemi-status-unknown-p names the C function" #t
                 (c-vsemi-status-unknown-p))
     (set-buffer-local-value! (current-buffer) 'c-at-vsemi-p-fn
                              'c-c++-vsemi-p)
     (test-equal "the c++ language's function is registered too" #t
                 (and (c-at-vsemi-p 10) #t)))))

;;----------------------------------------------------------------------
;; Token movement (`cc-engine.el:4947'-`:5191')
;;----------------------------------------------------------------------
;; Every row is Emacs 31.1's answer. The whole-fixture differential -
;; all 102 positions, both directions, the -2 and the -1 pairs - was
;; identical.
(c-buffer
 (lambda ()
   (define (tok2 p)
     (at p)
     (let ((f (c-forward-token-2)) (fp (point)))
       (at p)
       (let ((b (c-backward-token-2)) (bp (point)))
         (list f fp b bp))))
   (define (tok1 p)
     (at p)
     (let ((f (c-forward-token-1)) (fp (point)))
       (at p)
       (let ((b (c-backward-token-1)) (bp (point)))
         (list f fp b bp))))
   (define (eot p)
     (at p)
     (let ((r (c-end-of-token))) (list (and r #t) (point))))
   (define (eoct p)
     (at p)
     (let ((r (c-end-of-current-token))) (list (and r #t) (point))))
   (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
     (test-equal "c-forward-token-2 from BOB jumps the directive's tokens"
                 '(0 49 1 1) (tok2 1))
     (test-equal "c-forward-token-2 inside a symbol moves to its end"
                 '(0 10 0 1) (tok2 2))
     (test-equal "c-forward-token-2 from a directive's first line"
                 '(0 49 1 20) (tok2 20))
     (test-equal "c-forward-token-2 from the directive's ';' line"
                 '(0 53 1 49) (tok2 49))
     (test-equal "c-forward-token-2 from a macro's own line" '(0 85 0 54)
                 (tok2 55))
     (test-equal "c-forward-token-2 from inside the macro body" '(0 96 0 68)
                 (tok2 69))
     (test-equal "c-forward-token-2 from the comment's second line"
                 '(0 93 0 54) (tok2 85))
     (test-equal "c-forward-token-2 from the last comment line" '(0 96 0 54)
                 (tok2 95))
     (test-equal "c-forward-token-2 from the last declaration" '(0 100 0 68)
                 (tok2 96))
     (test-equal "c-forward-token-2 at the end of the buffer leaves the count"
                 '(1 101 0 100) (tok2 101))
     (test-equal "c-forward-token-2 at EOB" '(1 102 0 101) (tok2 102))

     (test-equal "c-forward-token-1 treats '==' as two tokens"
                 '(0 73 0 71) (tok1 72))
     (test-equal "c-forward-token-1 from the operator's second character"
                 '(0 85 0 71) (tok1 73))
     (test-equal "c-forward-token-1 backward splits '*/'" '(0 94 0 85)
                 (tok1 93))
     (test-equal "c-forward-token-1 agrees with -2 where there is no operator"
                 '(0 49 1 20) (tok1 20))

     (test-equal "c-end-of-token inside '#include's symbol" '(#t 9) (eot 2))
     (test-equal "c-end-of-token at the beginning of a symbol is a no-op"
                 '(#f 37) (eot 37))
     (test-equal "c-end-of-token at the last ';'" '(#t 102) (eot 101))
     (test-equal "c-end-of-current-token at a token's beginning does not move"
                 '(#f 2) (eoct 2))
     (test-equal "c-end-of-current-token inside a symbol moves to its end"
                 '(#t 9) (eoct 5))
     (test-equal "c-end-of-current-token inside a comment stays" '(#f 72)
                 (eoct 72)))))

;;----------------------------------------------------------------------
;; `c-syntactic-content' (`cc-engine.el:530').
;;
;; Emacs 31.1's answers on the same regions, paren-level nil and t.
;;----------------------------------------------------------------------
(define syntactic-fixture
  "#include <stdio.h>\n#define FOO(x) \\\n  ((x) + 1)\nint a; /* c1  c2 */\nint b[3];\nint f (int x,  char *y)\n{\n  return x;\n}\n")

(define (with-syntactic-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert syntactic-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (thunk)))

(with-syntactic-buffer
 (lambda ()
   (test-equal "c-syntactic-content: a directive tail" "int a;"
               (c-syntactic-content 1 55 #f))
   (test-equal "c-syntactic-content: the same with paren level" "int a;"
               (c-syntactic-content 1 55 #t))
   (test-equal "c-syntactic-content: from inside the directives" "int a;"
               (c-syntactic-content 20 60 #f))
   (test-equal "c-syntactic-content: from inside the directives, paren level" "int a;"
               (c-syntactic-content 20 60 #t))
   (test-equal "c-syntactic-content: a declaration run" "int b[3];int f(int x,char*y)"
               (c-syntactic-content 56 103 #f))
   (test-equal "c-syntactic-content: parens collapsed" "int b[];int f()"
               (c-syntactic-content 56 103 #t))
   (test-equal "c-syntactic-content: starting inside a comment" "c2*/int b[];i"
               (c-syntactic-content 63 80 #t))
   (test-equal "c-syntactic-content: an empty region" ""
               (c-syntactic-content 1 1 #f))))

;;----------------------------------------------------------------------
;; Syntactic scans: `c-syntactic-skip-backward',
;; `c-at-statement-start-p', `c-at-expression-start-p',
;; `c-on-identifier', `c-determine-limit', `c-syntactic-re-search-forward'
;; (`cc-engine.el:1562'-`:6012')
;;----------------------------------------------------------------------
;; Every row is Emacs 31.1's answer. The whole-input differentials were
;; identical: `c-syntactic-skip-backward' (both forms), the two
;; statement predicates, `c-on-identifier' and `c-determine-limit' at
;; every position of the fixture; `c-syntactic-re-search-forward' at
;; every position with three patterns; and the special-brace-list at
;; every position of the pike fixture.
(define stmt-fixture
  "#include <stdio.h>\n#define FOO(x) \\\n  ((x) + 1)\nint a;\n#define BAR 1 /* trailing\n   comment */\nint b; // x\n/* c */ int c = f (1, 2);\n")

(define (with-stmt-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert stmt-fixture)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    ;; `cc-mode.el:639' sets this buffer-locally; there is no
    ;; cc-mode yet, so the buffer does here what the mode will.
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (thunk))))

(with-stmt-buffer
 (lambda ()
   (define (at n) (goto-char n))
   (define (ssb p skip)
     (at p)
     (let ((r (c-syntactic-skip-backward skip #f #t)))
       (list (and r #t) (point))))
   (define (ass p) (at p) (and (c-at-statement-start-p) #t))
   (define (aes p) (at p) (and (c-at-expression-start-p) #t))
   (define (onid p) (at p) (c-on-identifier))
   (define (dl n p) (at p) (c-determine-limit n))
   (define (csr re p)
     (at p)
     (let ((r (c-syntactic-re-search-forward re #f #t #t #t)))
       (and r (point))))

   (test-equal "skip-backward at BOB does not move" '(#f 1) (ssb 1 "^;"))
   (test-equal "skip-backward from the second character" '(#t 1) (ssb 2 "^;"))
   (test-equal "skip-backward from a directive's start skips the line before"
               '(#t 55) (ssb 56 "^;"))
   (test-equal "skip-backward with the delimiter set stops after a directive"
               '(#t 54) (ssb 56 ";{}?:"))
   (test-equal "skip-backward at the end of a statement line skips the ';'"
               '(#t 54) (ssb 55 ";{}?:"))

   (test-equal "statement start at BOB" #t (ass 1))
   (test-equal "not at a directive's line body" #f (ass 2))
   (test-equal "a directive's start is a statement start" #t (ass 20))
   (test-equal "and so is the next one, after a declaration" #t (ass 56))
   (test-equal "a comment's continuation line is inside the statement" #t
               (ass 82))
   (test-equal "the line after a block comment" #t (ass 96))
   (test-equal "inside a declaration" #f (ass 101))
   (test-equal "the start of the comment-and-declaration line" #t (ass 108))

   (test-equal "expression start agrees at BOB" #t (aes 1))
   (test-equal "not inside a symbol" #f (aes 2))
   (test-equal "a directive's start" #t (aes 20))
   (test-equal "after a declaration" #t (aes 56))
   (test-equal "inside a comment" #t (aes 82))
   (test-equal "inside a declaration" #f (aes 101))

   (test-equal "on-identifier inside a symbol answers its start" 2 (onid 2))
   (test-equal "on-identifier on a keyword" 11 (onid 11))
   (test-equal "on-identifier directly after a keyword" 11 (onid 12))
   (test-equal "on-identifier at a ';'" #f (onid 36))
   (test-equal "on-identifier before the last ';'" 100 (onid 101))

   (test-equal "determine-limit 20 from BOB" 1 (dl 20 1))
   (test-equal "determine-limit 1 inside a keyword" 10 (dl 1 11))
   (test-equal "determine-limit 5 inside a keyword" 6 (dl 5 11))
   (test-equal "determine-limit 20 from a directive's start" 20 (dl 20 56))
   (test-equal "determine-limit 20 from inside a comment" 50 (dl 20 82))
   (test-equal "determine-limit 20 from a declaration line" 51 (dl 20 96))
   (test-equal "determine-limit 1 before a ';'" 100 (dl 1 101))

   (test-equal "syntactic search skips the directives' text" 52
               (csr "\\_<int\\_>" 1))
   (test-equal "syntactic search from the second directive" 99
               (csr "\\_<int\\_>" 56))
   (test-equal "syntactic search from the comment line" 99
               (csr "\\_<int\\_>" 96))
   (test-equal "syntactic search for a brace finds none outside literals"
               #f (csr "[[{]" 56))))

;; `c-looking-at-special-brace-list' (`cc-engine.el:13584'), every
;; position of a pike fixture; the whole table is Emacs 31.1's.
(define pike-brace-fixture "([a]) ({b}) (<c>) ([d]\n")

(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert pike-brace-fixture)
  (set-buffer-local-value! b 'major-mode 'pike-mode)
  ;; `cc-mode.el:639' sets this buffer-locally; there is no
  ;; cc-mode yet, so the buffer does here what the mode will.
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (c-init-language-vars pike-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table pike)))
  (parameterize ((*c-buffer-is-cc-mode* 'pike-mode))
    (define (at n) (goto-char n))
    (define (sbl p) (at p) (c-looking-at-special-brace-list))
    (test-equal "a closed ([ ]) list" '((1 . 6) #\[ . #\]) (sbl 1))
    (test-equal "at its first character, from the space before it" '((1 . 6) #\[ . #\])
               (sbl 2))
    (test-equal "a closed ({ }) list" '((6 . 12) #\{ . #\}) (sbl 6))
    (test-equal "a closed (< >) list" '((12 . 18) #\< . #\>) (sbl 12))
    (test-equal "an unclosed list answers its beginning only"
               '((18) #\[ . #\]) (sbl 18))
    (test-equal "at a list's content" #f (sbl 3))))

(test-end "schemacs_editor_cc_engine")

;;----------------------------------------------------------------------
;; `c-beginning-of-statement-1' (`cc-engine.el:793') and its automaton
;;----------------------------------------------------------------------
;; The whole-input differential is Emacs 31.1's answer at every position
;; of the fixture with six argument combinations - 2,292 answers, all
;; identical. The rows below are a selection: the macro start, statement
;; boundaries, `beginning' from an `else'/`else if', the do-while,
;; `catch'/`finally', labels, bitfields, and the HIT-LIM corner - where
;; the C's semicolon `if' takes the whole rest of the body as its else
;; forms, so a semicolon-led statement never reaches the limit test.
(test-begin "schemacs_editor_cc_engine_bos")
(define bos-fixture
  "int f (void)\n{\n  if (a)\n    b ();\n  else if (c)\n    d ();\n  else\n    e ();\n  while (x)\n    y ();\n  do\n    z ();\n  while (w);\n  for (;;)\n    q ();\n  switch (v)\n    {\n    case 1:\n      m ();\n      break;\n    default:\n      n ();\n    }\n  try { foo (); } catch (...) { bar (); } finally { baz (); }\nlbl:\n  goto lbl;\n  int bit : 3;\n  #define MAC(x) \\\n    ((x) + 1)\n  int g = MAC (2);\n}\n")
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert bos-fixture)
  (set-buffer-local-value! b 'major-mode 'c-mode)
  ;; `cc-mode.el:639' sets this buffer-locally; there is no
  ;; cc-mode yet, so the buffer does here what the mode will.
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (c-init-language-vars c-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (define (bos-check pos lim ig ne cd hl ret want-point)
      (goto-char pos)
      (let ((r (c-beginning-of-statement-1 lim ig ne cd hl)))
        (test-equal (list pos lim ig ne cd hl)
                    (list ret want-point) (list r (point)))))

    ;; no arguments
    (bos-check 1 #f #f #t #f #f 'same 1) ; the first character
    (bos-check 8 #f #f #t #f #f 'same 8) ; after a return type
    (bos-check 24 #f #f #t #f #f 'up 18) ; after a statement's terminator
    (bos-check 34 #f #f #t #f #f 'previous 18) ; after a bare ';'
    (bos-check 37 #f #f #t #f #f 'beginning 18) ; the 'else' resumes the 'if'
    (bos-check 58 #f #f #t #f #f 'previous 18) ; the second 'else' clause
    (bos-check 61 #f #f #t #f #f 'beginning 42) ; inside the else's body
    (bos-check 75 #f #f #t #f #f 'previous 18) ; after the last semicolon of the do-while
    (bos-check 115 #f #f #t #f #f 'beginning 100) ; 'beginning' from the else of the do-while
    (bos-check 124 #f #f #t #f #f 'up 115) ; inside the for header
    (bos-check 134 #f #f #t #f #f 'previous 133) ; the first ';' of 'for (;;)'
    (bos-check 135 #f #f #t #f #f 'previous 134) ; the second ';'
    (bos-check 146 #f #f #t #f #f 'previous 128) ; inside the switch body
    (bos-check 151 #f #f #t #f #f 'same 149) ; a case label
    (bos-check 165 #f #f #t #f #f 'same 165) ; after 'break;'
    (bos-check 177 #f #f #t #f #f 'label 170) ; the label line
    (bos-check 185 #f #f #t #f #f 'same 184) ; goto's body
    (bos-check 189 #f #f #t #f #f 'previous 184) ; after 'goto lbl;'
    (bos-check 251 #f #f #t #f #f 'previous 236) ; after the try block
    (bos-check 253 #f #f #t #f #f 'same 252) ; inside 'catch'
    (bos-check 263 #f #f #t #f #f 'same 252) ; inside the catch block
    (bos-check 276 #f #f #t #f #f 'previous 252) ; before 'finally'
    (bos-check 281 #f #f #t #f #f 'same 276) ; inside 'finally'
    (bos-check 285 #f #f #t #f #f 'same 285) ; after the finally block
    (bos-check 293 #f #f #t #f #f 'previous 286) ; after the switch's closing brace
    (bos-check 297 #f #f #t #f #f 'same 296) ; inside 'lbl'
    (bos-check 299 #f #f #t #f #f 'same 296) ; at the label's colon
    (bos-check 300 #f #f #t #f #f 'label 296) ; the line after the label
    (bos-check 310 #f #f #t #f #f 'same 303) ; after 'goto lbl;'
    (bos-check 315 #f #f #t #f #f 'previous 303) ; after the declaration
    (bos-check 326 #f #f #t #f #f 'same 315) ; after a bitfield
    (bos-check 330 #f #f #t #f #f 'previous 315) ; at a macro's '#'
    (bos-check 345 #f #f #t #f #f 'macro 330) ; the macro's continuation backslash
    (bos-check 346 #f #f #t #f #f 'macro 330) ; 
    (bos-check 351 #f #f #t #f #f 'macro 330) ; inside the macro body
    (bos-check 360 #f #f #t #f #f 'same 351) ; after the macro body
    (bos-check 363 #f #f #t #f #f 'previous 315) ; after a macro call
    (bos-check 378 #f #f #t #f #f 'same 363) ; the last statement

    ;; 1 #f #t #f #f
    (bos-check 34 1 #f #t #f #f 'previous 18) ; with LIM at 1
    (bos-check 37 1 #f #t #f #f 'beginning 18) ; with LIM
    (bos-check 61 1 #f #t #f #f 'beginning 42) ; with LIM
    (bos-check 115 1 #f #t #f #f 'beginning 100) ; with LIM
    (bos-check 177 1 #f #t #f #f 'label 170) ; with LIM
    (bos-check 297 1 #f #t #f #f 'same 296) ; with LIM
    (bos-check 330 1 #f #t #f #f 'previous 315) ; with LIM

    ;; #f #t #t #f #f
    (bos-check 177 #f #t #t #f #f 'same 170) ; IGNORE-LABELS: the label is not stepped over
    (bos-check 189 #f #t #t #f #f 'previous 170) ; IGNORE-LABELS
    (bos-check 297 #f #t #t #f #f 'same 296) ; IGNORE-LABELS
    (bos-check 299 #f #t #t #f #f 'same 296) ; IGNORE-LABELS
    (bos-check 311 #f #t #t #f #f 'same 296) ; IGNORE-LABELS

    ;; #f #f #f #t #f
    (bos-check 134 #f #f #f #t #f 'previous 133) ; COMMA-DELIM: ';' still delimits
    (bos-check 135 #f #f #f #t #f 'previous 134) ; COMMA-DELIM
    (bos-check 136 #f #f #f #t #f 'up 128) ; COMMA-DELIM

    ;; 30 #f #t #f #f
    (bos-check 34 30 #f #t #f #f 'previous 31) ; with LIM at 30
    (bos-check 37 30 #f #t #f #f 'previous 31) ; with LIM 30
    (bos-check 61 30 #f #t #f #f 'beginning 42) ; with LIM 30
    (bos-check 100 30 #f #t #f #f 'previous 78) ; with LIM 30
    (bos-check 115 30 #f #t #f #f 'beginning 100) ; with LIM 30

    ;; #f #f #t #f 1
    (bos-check 133 #f #f #t #f 1 #f 133) ; HIT-LIM
    (bos-check 134 #f #f #t #f 1 'previous 133) ; HIT-LIM: a semicolon-led statement skips the limit test
    (bos-check 135 #f #f #t #f 1 'previous 134) ; HIT-LIM
    (bos-check 136 #f #f #t #f 1 'up 128) ; HIT-LIM
    (bos-check 177 #f #f #t #f 1 'label 170) ; HIT-LIM
    (bos-check 297 #f #f #t #f 1 'same 296) ; HIT-LIM
))
(test-end "schemacs_editor_cc_engine_bos")

;;----------------------------------------------------------------------
;; The state cache (`cc-engine.el:3250'-`:4850')
;;----------------------------------------------------------------------
;; Two whole-input differentials against Emacs 31.1 are identical: the
;; forward scan at every position of the fixture (210 rows) and the
;; `ins'/`del'/`nar'/`wid' table that edits, invalidates and narrows it
;; (18 rows). The rows below pin the branches a regression takes out
;; first: the brace-pair cons elements that make the cache worth
;; having, the invalidation that must keep a *lower* brace pair
;; (`(46 . 66)', found by scanning back from the cache's top), and the
;; narrowing that has `c-parse-state' discover elements below
;; `point-min'.
(test-begin "schemacs_editor_cc_engine_state")
(define state-fixture
  "int f (void)\n{\n  if (a) {\n    b ();\n  } else {\n    c (d (e));\n  }\n  switch (x) {\n  case 1: {\n    break;\n  }\n  }\n  char *s = \"a { b\";\n  /* comment { */\n  // line {\n  g ();\n#if 0\n  junk ( { [ ;\n#endif\n  h ();\n}\n")
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert state-fixture)
  (set-buffer-local-value! b 'major-mode 'c-mode)
  ;; `cc-mode.el:639' sets this buffer-locally; there is no
  ;; cc-mode yet, so the buffer does here what the mode will.
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (c-init-language-vars c-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (define (state-row tag pos want-cache want-good want-min)
      (goto-char (min pos (point-max)))
      (test-equal (list tag pos)
                  (list want-cache want-good want-min)
                  (list (c-parse-state) (c-state-cache-good-pos)
                        (c-state-min-scan-pos))))

    ;; The forward scan - the warm-up and the rows in one walk, as the
    ;; differential measured them.
    (c-state-cache-init)
    (do ((p (point-min) (+ p 1))) ((> p (point-max)))
      (goto-char p)
      (c-parse-state)
      (cond
       ((= p 8)
        (test-equal 'forward-8 (list '(7) 1 1)
                    (list (c-state-cache) (c-state-cache-good-pos)
                          (c-state-min-scan-pos))))
       ((= p 100)
        (test-equal 'forward-100 (list '(92 80 (46 . 66) 14) 93 1)
                    (list (c-state-cache) (c-state-cache-good-pos)
                          (c-state-min-scan-pos))))
       ((= p 108)
        (test-equal 'forward-108 (list '((92 . 108) 80 (46 . 66) 14) 108 1)
                    (list (c-state-cache) (c-state-cache-good-pos)
                          (c-state-min-scan-pos))))
       ((= p 205)
        (test-equal 'forward-205
                    (list '(204 189 187 185 (80 . 112) 14) 190 1)
                    (list (c-state-cache) (c-state-cache-good-pos)
                          (c-state-min-scan-pos))))
       ((= p 209)
        (test-equal 'forward-209 (list '(187 185 (80 . 112) 14) 209 1)
                    (list (c-state-cache) (c-state-cache-good-pos)
                          (c-state-min-scan-pos))))))

    ;; An insertion at 100 above the cache's lower brace pair, then the
    ;; invalidation wrapper. `c-remove-stale-state-cache-backwards'
    ;; returns `(81 80 t)' and the append of the lower brace pair is
    ;; what puts `(46 . 66)' back.
    (goto-char 100)
    (c-truncate-lit-pos/state-cache 100)
    (insert "{")
    (c-invalidate-state-cache (point))
    (state-row 'ins 100 '(92 80 (46 . 66) 14) 93 1)
    (state-row 'ins 101 '(100 92 80 (46 . 66) 14) 93 1)
    (state-row 'ins 110 '((100 . 109) 92 80 (46 . 66) 14) 109 1)
    (state-row 'ins 150 '((92 . 113) 80 (46 . 66) 14) 113 1)
    (state-row 'ins 200 '(190 188 186 (92 . 113) 80 (46 . 66) 14) 191 1)

    ;; Delete it again.
    (goto-char 100)
    (c-truncate-lit-pos/state-cache 100)
    (delete-region 100 101)
    (c-invalidate-state-cache (point))
    (state-row 'del 100 '(92 80 (46 . 66) 14) 93 1)
    (state-row 'del 110 '((92 . 108) 80 (46 . 66) 14) 108 1)
    (state-row 'del 150 '((80 . 112) 14) 112 1)
    (state-row 'del 200 '(189 187 185 (80 . 112) 14) 190 1)

    ;; Narrowing: the cache starts empty at the new `point-min', and the
    ;; forward scans find the brace pairs below it.
    (narrow-to-region 30 180)
    (c-state-cache-init)
    (state-row 'nar 30 '() 30 30)
    (state-row 'nar 40 '() 35 30)
    (state-row 'nar 80 '((46 . 66)) 66 30)
    (state-row 'nar 120 '((80 . 112)) 112 30)
    (state-row 'nar 170 '((80 . 112)) 112 30)
    (state-row 'nar 180 '((80 . 112)) 170 30)

    ;; Widening again.
    (widen)
    (state-row 'wid 80 '((46 . 66) 14) 66 1)
    (state-row 'wid 120 '((80 . 112) 14) 112 1)
    (state-row 'wid 170 '((80 . 112) 14) 112 1)))
(test-end "schemacs_editor_cc_engine_state")

;;----------------------------------------------------------------------
;; `c-looking-at-c++-lambda-capture-list' (`cc-engine.el:14101')
;;----------------------------------------------------------------------
;; A whole-fixture differential: the answer at every `[' of the fixture,
;; Emacs 31.1's own. The true cases are lambda capture lists; the false
;; ones are the two `[' of a `[[attribute]]' (each rejected through the
;; character beside it), subscripts after a name (`a[i]'), inner `[' of
;; two-dimensional subscripts, and a `[' inside a string or a comment.
(test-begin "schemacs_editor_cc_engine_lambda_capture")
(define lambda-fixture
  "auto f = [x] (int y) { return x + y; };\nauto g = [] () { return 1; };\nauto h = [&, x] (auto&& z) { return z; };\nint a[3];\ny = a[i];\nint b[2][3];\nx = b[i][j];\n[[nodiscard]] int fn ();\nauto k = [](int q) { return q; };\nvoid m () { arr[i] = [this] { return v; }; }\nif (x [ 0 ]) ;\nauto n = []{ return 0; };\nconst char *s = \"[x]\";\n// [x] in a comment\n/* [x] */\nauto p = [=] { return s[0]; };\n")
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert lambda-fixture)
  (set-buffer-local-value! b 'major-mode 'c++-mode)
  (c-init-language-vars c++-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
    (define (cap-check pos want)
      (goto-char pos)
      (test-equal (list 'lambda-capture pos)
                  want
                  (c-looking-at-c++-lambda-capture-list)))
    (cap-check 10 #t)			; [x] of a lambda
    (cap-check 50 #t)			; [] of a lambda
    (cap-check 80 #t)			; [&, x] of a lambda
    (cap-check 118 #f)			; a[3] - a subscript after a name
    (cap-check 128 #f)			; a[i]
    (cap-check 138 #f)			; b[2][3]
    (cap-check 141 #f)			; the inner '[' of b[2][3]
    (cap-check 151 #f)			; b[i][j]
    (cap-check 154 #f)			; the inner '[' of b[i][j]
    (cap-check 159 #f)			; the first '[' of [[nodiscard]]
    (cap-check 160 #f)			; the second '[' of [[nodiscard]]
    (cap-check 193 #t)			; [](int q)
    (cap-check 233 #f)			; arr[i]
    (cap-check 239 #t)			; [this]
    (cap-check 269 #f)			; x [ 0 ]
    (cap-check 287 #t)			; []{ return 0; }
    (cap-check 321 #f)			; the '[' inside "[x]"
    (cap-check 330 #f)			; the '[' in the line comment
    (cap-check 350 #f)			; the '[' in the block comment
    (cap-check 366 #t)			; [=]
    (cap-check 380 #f)))		; s[0]
(test-end "schemacs_editor_cc_engine_lambda_capture")

;;----------------------------------------------------------------------
;; The keyword-clause helpers (`cc-engine.el:8567'-`:8644')
;;----------------------------------------------------------------------
;; `c-forward-noise-clause', `c-forward-noise-clause-not-macro-decl'
;; and `c-forward-over-colon-type-list', the three helpers
;; `c-forward-keyword-clause' stands on that need nothing unported. A
;; whole-fixture differential against Emacs 31.1 covered every position
;; of the fixture for all five forms (890 answers, identical); the rows
;; below pin the interesting ones - the noise macro with and without
;; parens, the unbalanced case, and the inheritance colon.
(test-begin "schemacs_editor_cc_engine_kw_helpers")
(define kw-fixture
  "NOISE(x) rest;\nNOISE (a, b) after;\nclass A : public B {};\nstruct S final : X::Y {};\nA::B::C c;\nvoid f () { g (); }\ntemplate <class T> T id (T x) { return x; }\nint q = a ? b : c;\n")
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert kw-fixture)
  (set-buffer-local-value! b 'major-mode 'c++-mode)
  (c-init-language-vars c++-mode)
  (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
  (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
  (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
    (define (kw-point tag pos thunk want)
      (goto-char pos)
      (thunk)
      (test-equal (list tag pos) want (point)))
    (define (kw-colon pos want-result want-point)
      (goto-char pos)
      (let ((r (c-forward-over-colon-type-list)))
        (test-equal (list 'colon pos)
                    (list want-result want-point)
                    (list r (point)))))

    ;; `c-forward-noise-clause' - over the name, the paren expression
    ;; and the syntactic whitespace.
    (kw-point 'noise 1 c-forward-noise-clause 10)
    (kw-point 'noise 6 c-forward-noise-clause 7)
    (kw-point 'noise 20 c-forward-noise-clause 29)
    (kw-point 'noise 22 c-forward-noise-clause 23)
    (kw-point 'noise 40 c-forward-noise-clause 42)

    ;; ... with STOP-AT-END the trailing whitespace stays.
    (kw-point 'noise-stop 1 (lambda () (c-forward-noise-clause #t)) 9)
    (kw-point 'noise-stop 6 (lambda () (c-forward-noise-clause #t)) 7)
    (kw-point 'noise-stop 20 (lambda () (c-forward-noise-clause #t)) 28)
    (kw-point 'noise-stop 22 (lambda () (c-forward-noise-clause #t)) 23)
    (kw-point 'noise-stop 40 (lambda () (c-forward-noise-clause #t)) 41)

    ;; `c-forward-noise-clause-not-macro-decl': MAYBE-PARENS goes over
    ;; the parens; nil stops after the name.
    (kw-point 'not-macro 1 (lambda () (c-forward-noise-clause-not-macro-decl #t)) 9)
    (kw-point 'not-macro 6 (lambda () (c-forward-noise-clause-not-macro-decl #t)) 9)
    (kw-point 'not-macro 20 (lambda () (c-forward-noise-clause-not-macro-decl #t)) 28)
    (kw-point 'not-macro 22 (lambda () (c-forward-noise-clause-not-macro-decl #t)) 28)
    (kw-point 'not-macro 40 (lambda () (c-forward-noise-clause-not-macro-decl #t)) 41)
    (kw-point 'not-macro-nil 1 (lambda () (c-forward-noise-clause-not-macro-decl #f)) 6)
    (kw-point 'not-macro-nil 6 (lambda () (c-forward-noise-clause-not-macro-decl #f)) 6)
    (kw-point 'not-macro-nil 20 (lambda () (c-forward-noise-clause-not-macro-decl #f)) 21)
    (kw-point 'not-macro-nil 22 (lambda () (c-forward-noise-clause-not-macro-decl #f)) 22)
    (kw-point 'not-macro-nil 40 (lambda () (c-forward-noise-clause-not-macro-decl #f)) 41)

    ;; `c-forward-over-colon-type-list' - only a C++ inheritance colon.
    (kw-colon 1 #f 1)
    (kw-colon 20 #f 20)
    (kw-colon 35 #t 45)
    (kw-colon 40 #t 45)
    (kw-colon 45 #f 45)))
(test-end "schemacs_editor_cc_engine_kw_helpers")

;;--------------------------------------------------------------
;; The declaration engine (`cc-engine.el:8424'-`:9860')
;;--------------------------------------------------------------
;; `c-forward-keyword-clause' and its two helpers,
;; `c-forward-<>-arglist' (+ recur, `c-backward-<>-arglist'),
;; `c-forward-name' and `c-forward-type', over two fixtures.
;;
;; **Every expectation here is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' in a real c++-mode/c-mode buffer: for each of the
;; two fixtures, all five probes (`c-forward-type', `c-forward-name',
;; `c-forward-keyword-clause' with and without STOP-AT-END, and
;; `c-forward-<>-arglist'/`c-backward-<>-arglist') at **every position**
;; with `c-found-types' cleared before each call - 2,280 answers for the
;; C++ fixture and 1,620 for the C one, all identical. The rows below
;; pin the interesting ones; the whole-fixture differential (both
;; fixtures) is what the port was built against.
;;
;; The C fixture's positions:
;;
;;     1  1-18   "#include <stdio.h>"      (75 ':' at 166? no - see below)
;;   ...
;; The tests name positions the way the differential does: the fixture
;; strings are built here so the arithmetic is visible.
(test-begin "schemacs_editor_cc_engine_declaration")
(define decl-cpp-fixture
  "namespace N { template <class T> class V {}; }\nstd::vector<int> v;\nFoo<Bar<Baz> > x;\nA<B>::C y;\nint z;\nunsigned long long w;\nstatic const char *p;\nstruct s { int m; } q;\nstruct s *r;\ntypedef struct { int a; } anon_t;\nenum { RED, GREEN } colour;\n_BitInt(32) big;\ntypeof (x) tx;\nauto a1 = 1;\ndecltype(v) d;\ntemplate <typename T, int N> struct Arr {};\nV<int> f(V<int> arg);\nx < y > z;\nif (a < b && c > d) {}\nstd::map<std::string, int> m;\nFoo<T>::bar<U> baz;\n")
(define decl-c-fixture
  "#include <stdio.h>\nstruct s { int m; };\ntypedef struct s S;\nstatic const char *p;\nunsigned long long w;\nint z = 0;\n_BitInt(32) big;\ntypeof (z) tz;\nregister count;\nextern foo_t my_foo;\nx < y > z;\nint f(int a, char *b);\nunion { int a; } u;\nconst volatile unsigned int q;\n")

;; The mode is a MACRO argument to `c-init-language-vars' and
;; `c-lang-const', so it must be a literal at the call site: SETUP is a
;; thunk that does the two initialisations for its own language.
(define (decl-expect fixture mode setup rows)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert fixture)
    (set-buffer-local-value! b 'major-mode mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (setup)
    (parameterize ((*c-buffer-is-cc-mode* mode))
      (for-each
      (lambda (row)
        (let ((tag (list-ref row 0)) (pos (list-ref row 1))
              (want (list-ref row 2)) (want-pt (list-ref row 3)))
          (goto-char pos)
          (c-clear-found-types)
          (let ((got (case tag
                       ((T) (c-forward-type))
                       ((N) (c-forward-name))
                       ((K) (and (let ((re (buffer-local-value
                                           (current-buffer)
                                           'c-keywords-regexp #f)))
                                   (and re (looking-at re)))
                                 (c-forward-keyword-clause 1)))
                       ((L) (and (let ((re (buffer-local-value
                                           (current-buffer)
                                           'c-keywords-regexp #f)))
                                   (and re (looking-at re)))
                                 (c-forward-keyword-clause 1 #t)))
                       ((A) (and (eq? (char-after pos) #\<)
                                 (c-forward-<>-arglist #f)))
                       ((B) (and (eq? (char-before pos) #\>)
                                 (c-backward-<>-arglist #f)))
                       (else (error "bad tag")))))
            (test-equal (list tag pos) (list want want-pt)
                        (list got (point))))))
       rows))))

;; The C++ rows: a `<` at 24 opens the template's arglist (and
;; `c-forward-type' consumes it); a keyword clause at 15 takes the
;; arglist with it; a qualified name ending in `<int>` is a 'template;
;; and the nested `Foo<Bar<Baz> >' parses from either end.
(decl-expect decl-cpp-fixture 'c++-mode
  (lambda ()
    (c-init-language-vars c++-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++))))
  '((T 24 #t 42)
    (A 24 #t 33)
    (B 33 #t 24)
    (K 15 #t 34)
    (L 15 #t 33)
    (N 48 template 65)
    (T 48 #t 65)
    (T 59 maybe 66)
    (N 59 #f 59)
    (A 59 #t 64)
    (B 64 #t 59)
    (N 68 template 83)
    (T 68 #t 83)
    (A 71 #t 82)
    (B 80 #t 75)
    (B 82 #t 71)
    (T 75 #f 81)))

;; The C rows: the implicit-int branch ("register count;" is 'no-id),
;; a known type from `c-known-type-key' ("extern foo_t" is 'known, and
;; stops after the type), the `#include <stdio.h>' arglist (which the
;; "import" branch does not take in C - it is an ordinary template
;; arglist), and `x < y > z' as two arglists read backwards.
(decl-expect decl-c-fixture 'c-mode
  (lambda ()
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
  '((T 49 #t 58)
    (T 148 no-id 157)
    (K 148 #t 157)
    (L 148 #t 156)
    (T 164 known 177)
    (T 171 known 177)
    (N 171 #t 177)
    (T 175 maybe 177)
    (T 177 maybe 183)
    (K 49 #t 56)
    (L 49 #t 55)
    (A 10 #t 19)
    (B 19 #t 10)
    (B 192 #t 187)))
(test-end "schemacs_editor_cc_engine_declaration")

;;--------------------------------------------------------------
;; The declarator (`cc-engine.el:9855'-`:10310')
;;--------------------------------------------------------------
;; `c-back-over-member-initializer-braces', `c-forward-class-decl',
;; the C++20 constraint machinery (`c-forward-primary-expression',
;; `c-forward-constraint-clause', `c-forward-c++-requires-clause'),
;; `c-in-id-arglist', `c-forward-decl-arglist' and
;; `c-forward-declarator'.
;;
;; **Every expectation here is Emacs 31.1's own answer**: the
;; differential called all eleven probes at **every position** of three
;; fixtures (this one, the C++ one above and the C one) with
;; `c-found-types' cleared before each call - 6,512 answers for this
;; fixture, 5,016 for the C++ one and 2,970 for the C one, all
;; identical. The rows below pin the interesting answers.
;;
;; The fixture's lines, for reading the positions:
;;
;;     1  1-27    "class C { public: int m; };"
;;     2  29-58   "struct S { int a; double b; };"
;;     3  60-108  "namespace N { class D : public C { void f(); }; }"
;;     4  110-130 "int (*fp)(int, char);"
;;     5  132-171 "void (*signal(int, void (*)(int)))(int);"
;;     6  173-184 "int arr[10];"
;;     7  186-205 "int x = f(1), y = 2;"
;;     8  207-222 "int xx = {1, 2};"
;;     9  224-258 "auto lam = [](int x) { return x; };"
;;    10  260-307 "template <typename T> requires C<T> struct R {};"
;;    11  309-341 "void req(int x) requires (N > 0);"
;;    12  343-388 "auto g() requires requires (T t) { t.foo(); };"
;;    13  390-411 "T operator+(T a, T b);"
;;    14  413-455 "Foo::Foo(int a) : x_(a), y_{1, 2}, z_(3) {}"
;;    15  457-485 "std::map<std::string, int> m;"
;;    16  487-500 "int *p1, **p2;"
;;    17  502-527 "typedef int (*fptr)(void);"
;;    18  529-558 "int a __attribute__((unused));"
;;    19  560-590 "struct T { int x : 3, y : 5; };"
(test-begin "schemacs_editor_cc_engine_declarator")
(define decl2-fixture
  "class C { public: int m; };\nstruct S { int a; double b; };\nnamespace N { class D : public C { void f(); }; }\nint (*fp)(int, char);\nvoid (*signal(int, void (*)(int)))(int);\nint arr[10];\nint x = f(1), y = 2;\nint xx = {1, 2};\nauto lam = [](int x) { return x; };\ntemplate <typename T> requires C<T> struct R {};\nvoid req(int x) requires (N > 0);\nauto g() requires requires (T t) { t.foo(); };\nT operator+(T a, T b);\nFoo::Foo(int a) : x_(a), y_{1, 2}, z_(3) {}\nstd::map<std::string, int> m;\nint *p1, **p2;\ntypedef int (*fptr)(void);\nint a __attribute__((unused));\nstruct T { int x : 3, y : 5; };\n")
;; Each row gets a FRESH buffer. cc-mode caches in text properties
;; (`c-is-sws', `c-in-sws', the `<>' paren markers), so an answer can
;; depend on what was probed before it; the expectations are what Emacs
;; alone in a fresh buffer answers, which is what a caller sees.
(define (decl2-expect rows)
  (for-each
   (lambda (row)
     (let ((b (allocate-buffer)))
       (set-buffer b)
       (insert decl2-fixture)
       (set-buffer-local-value! b 'major-mode 'c++-mode)
       (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
       (c-init-language-vars c++-mode)
       (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
       (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
         (let ((tag (list-ref row 0)) (pos (list-ref row 1))
               (want (list-ref row 2)) (want-pt (list-ref row 3)))
           (goto-char pos)
           (c-clear-found-types)
           (let ((got (case tag
                        ((D) (c-forward-declarator))
                        ((E) (c-forward-declarator (point-max) #t #t))
                        ((G) (and (eq? (char-after pos) #\() (c-forward-decl-arglist #f #f)))
                        ((H) (and (eq? (char-after pos) #\() (c-forward-decl-arglist #t #t)))
                        ((P) (c-forward-primary-expression))
                        ((Q) (c-forward-primary-expression (point-max) #t))
                        ((C) (c-forward-constraint-clause))
                        ((R) (c-forward-c++-requires-clause))
                        ((I) (c-in-id-arglist))
                        ((X) (c-forward-class-decl))
                        ((M) (c-back-over-member-initializer-braces))
                        (else (error "bad tag")))))
             (test-equal (list tag pos) (list want want-pt)
                         (list got (point))))))))
   rows))

;; A class/struct definition taken whole; the identifiers of the first
;; two declarations; `f()` in the namespace (an arglist taken); `(*fp)`
;; (decorated, with its arglist); `arr[10]`'s brackets; and the
;; constructor's declarators.
(decl2-expect
 '((X 1 27 27)
   (X 29 58 58)
   (D 7 (7 8 #f 9 #f #f) 9)
   (D 23 (23 24 #f #f #f #f) 24)
   (D 100 (100 101 #f #f #f #t) 103)
   (D 114 (116 118 #f #f #t #t) 130)
   (D 177 (177 180 #t #f #f #f) 184)
   (D 190 (190 191 #f 192 #f #f) 192)
   (D 254 (254 255 #f #f #f #f) 255)
   (D 279 (279 280 #f 305 #f #f) 305)
   (D 291 (291 295 #f 305 #f #f) 305)
   (D 303 (303 304 #f 305 #f #f) 305)
   (D 314 (314 317 #f #f #f #t) 341)
   (D 434 (434 435 #f #f #f #f) 435)))

;; `c-forward-decl-arglist' at every open paren of the fixture: the
;; `f()` of the namespace, the two arglists of `(*fp)(int, char)`, the
;; nested `void (*)(int)`, the lambda's `(int x)`, a requires clause's
;; `(N > 0)` and the member initializers' parens.
(decl2-expect
 '((G 101 #t 103)
   (H 101 #t 103)
   (G 119 #t 130)
   (H 119 #t 130)
   (G 145 #t 165)
   (G 159 #t 164)
   (G 166 #t 171)
   (G 237 #t 245)
   (G 317 #t 325)
   (G 334 #t 341)
   (G 349 #t 352)
   (G 370 #t 376)
   (G 383 #t 385)
   (G 401 #t 411)
   (G 421 #t 429)
   (G 433 #t 436)))

;; `c-in-id-arglist' inside the constructor's `x_(a)': every argument is
;; an identifier, so the cons of the paren's bounds and the position
;; after it. `c-back-over-member-initializer-braces' at the ',' after it
;; and after the `y_{1, 2}' brace list: both go back to just after the
;; constructor's ':' (430).
(decl2-expect
 '((I 434 (433 . 436) 434)
   (M 436 #t 430)
   (M 437 #t 430)))

;; The C++20 constraint machinery: `requires C<T>` (the clause at 282
;; takes `C<T>` and stops at 296), the primary expression `C<T>` itself
;; (291), `req`'s and the parenthesised constraint's own answers, and
;; the two `requires` of `auto g() requires requires (T #t) {...}`.
(decl2-expect
 '((R 282 #t 296)
   (P 291 #t 295)
   (Q 291 #t 295)
   (C 291 #t 296)
   (R 296 #t 305)
   (P 303 #t 304)
   (R 314 #t 325)
   (P 314 #t 317)
   (P 317 #t 325)
   (Q 317 #t 324)
   (C 317 #t 325)))
(test-end "schemacs_editor_cc_engine_declarator")

;;----------------------------------------------------------------------
;; The declaration decision, the statement block and the parse state
;;----------------------------------------------------------------------
;; Every expectation below is Emacs 31.1's own answer, measured with
;; `emacs -Q --batch' on the same fixture in a real c++-mode buffer and
;; with cc-mode.el's `category' properties stripped (there is no
;; cc-mode here yet). Each row builds a fresh buffer because cc-mode
;; caches in text properties - a position's answer can depend on what
;; was probed before it, and these are the one-probe-per-buffer answers.
;;
;; Positions:
;;   13  `{' of the namespace        15  `template'
;;   25  `class' inside the template 42  `{' of class V
;;   43  `}' of class V              46  `}' of the namespace
;;   48  `int (*fp)(int, char);'     70  `void f()'
;;   79  `{' of f                    90  `class C'
;;   98  `{' of C                   115  `}' of C
(test-begin "schemacs_editor_cc_engine_declaration_decision")

(define dd-fixture
  (string-append
   "namespace N { template <class T> class V {}; }\n"
   "int (*fp)(int, char);\n"
   "void f() { int x; }\n"
   "class C { public: int m; };\n"))

(define (dd-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert dd-fixture)
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c++-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
    (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
      (thunk))))

;; `c-looking-at-statement-block'/`-1': t for the namespace's, class V's,
;; f's and C's braces; `maybe' for -1 at class V's (its contents settle
;; nothing, its context does).
(for-each
 (lambda (row)
   (dd-buffer
    (lambda ()
      (let ((p (car row)))
        (goto-char p)
        (test-equal (list 'S p) (cadr row)
                    (list (c-looking-at-statement-block) (point)))
        (goto-char p)
        (test-equal (list 'L p) (caddr row)
                    (list (c-looking-at-statement-block-1) (point)))))))
 '((13 (#t 13) (#t 13))
   (42 (#t 42) (maybe 42))
   (79 (#t 79) (#t 79))
   (98 (#t 98) (#t 98))))

;; `c-forward-decl-or-cast-1' with context `top'. The CURIOUS one is
;; position 48: Emacs *accepts* `int (*fp)(int, char);' as a declaration
;; here (the preceding `}' is what makes it one) but returns nil for the
;; same text after `namespace N { ... }' in `fixture-decl.cpp'. That is
;; the CASE 19 regression: a `when' in value position answered the
;; unspecified value - true - and made every undecided construct a
;; declaration. These are the measured answers, not the plausible ones.
(for-each
 (lambda (row)
   (dd-buffer
    (lambda ()
      (goto-char (car row))
      (c-clear-found-types)
      (test-equal (list 'F (car row)) (cadr row)
                  (list (c-forward-decl-or-cast-1
                         (max (point-min) (1- (point))) 'top #f)
                        (point))))))
 '((48 ((52 #f #f 48 #t) 68))
   (70 ((75 #f #f 70 #t) 79))
   (90 ((96 (#t #f #f) #f 96 #t) 116))))

;; The `<>' suppression: `c-forward-decl-or-cast-1' at `template' marks
;; `<class T>' with the `category' property that gives it paren syntax,
;; and `c-parse-state' must ignore it - Emacs's `c-with-<->
;; -as-parens-suppressed' (`cc-engine.el:4582'). Without it the angle
;; bracket at 24 is in the parse state and every toplevel question is
;; wrong. The marks stay after the call (the suppression is restored).
(dd-buffer
 (lambda ()
   (goto-char 15)
   (c-clear-found-types)
   (c-forward-decl-or-cast-1 14 'top #f)
   (test-equal "the template's < is marked" '(4 . 62)
               (get-text-property 24 'syntax-table))
   (goto-char 25)
   (test-equal "the parse state does not contain it" '(13)
               (c-parse-state))
   (goto-char 43)
   (test-equal "and at the class's } only its own brace pair and the namespace"
               '(42 13) (c-parse-state))
   (test-equal "a class-qualified name lookup finds the class"
               (list #f 42) (list (c-directly-in-class-called-p "C") (point)))
   ;; A backward stale-cache scan (CASE 3 of
   ;; `c-remove-stale-state-cache-backwards') with no unmatched close
   ;; paren used to take its clause on `set!'s unspecified value and do
   ;; `(+ 1 #f)'. Asking again must answer, not raise.
   (goto-char 43)
   (test-equal "the parse state survives the backward scan" '(42 13)
               (c-parse-state))))

(test-end "schemacs_editor_cc_engine_declaration_decision")

(test-begin "schemacs_editor_cc_engine_label_knr")

;; The label scan, the K&R argument declarations and the declaration
;; header (`cc-engine.el:11817'-`:12741'). Every expectation here is
;; Emacs 31.1's own answer, measured on the same fixture text in a real
;; `c-mode'/`c++-mode' buffer one probe per fresh buffer - cc-mode
;; caches in text properties, so a long-lived buffer is not Emacs's
;; fresh answer. The probes that normalize a value the function does
;; not document end in `#f' on both sides (Elisp's nil).

(define (lk-buffer-cpp text thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c++-mode)
    ;; As `c-basic-common-init' does in a real mode buffer: several of
    ;; the declaration functions read the type hash.
    (c-clear-found-types)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
    (c-make-macro-with-semi-re)
    (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
      (thunk))))

(define (lk-buffer-c text thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (c-clear-found-types)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (c-make-macro-with-semi-re)
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (thunk))))

(define lk-cpp
  (string-append
   "class C { public: int m; };\n"
   "int h(int x) {\n"
   "  switch (x) { case 1: break; default: break; }\n"
   "goto-target:\n"
   "  return x;\n"
   "}\n"))

(define lk-lbl "int q(void)\n{\ndone:\n  return 1;\n}\n")

;; `c-forward-label': `public:' and the case labels answer t, the bare
;; goto target answers `goto-target', and `return' in a statement is
;; not a label (point unmoved).
(for-each
 (lambda (row)
   (lk-buffer-cpp lk-cpp
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'label (car row)) (cadr row)
                  (list (c-forward-label) (point))))))
 '((11 (#t 18))
   (59 (#t 66))
   (74 (#t 82))
   (107 (#f 107))))

(lk-buffer-c lk-lbl
 (lambda ()
   (goto-char 15)
   (test-equal "a goto target answers the symbol" '(goto-target 20)
               (list (c-forward-label) (point)))))

(define lk-knr
  (string-append
   "int foo (bar, baz, yuk)\n"
   "     int bar [];\n"
   "     int (*baz) (my_type);\n"
   "     int (*(* yuk) (void)) (void);\n"
   "{\n"
   "  return bar[baz] + yuk;\n"
   "}\n"))

;; `c-in-knr-argdecl' answers the first argument declaration's start and
;; does not move point.
(for-each
 (lambda (row)
   (lk-buffer-c lk-knr
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'knr (car row)) (cadr row)
                  (list (c-in-knr-argdecl) (point))))))
 '((24 (30 24))
   (30 (30 30))))

;; `c-beginning-of-decl-1' answers (MOVE . KNR-POS); the second row is
;; inside the K&R declarations, so KNR-POS is the first one's start.
(for-each
 (lambda (row)
   (lk-buffer-c lk-knr
    (lambda ()
      (goto-char (car row))
      (let ((r (c-beginning-of-decl-1)))
        (test-equal (list 'bod (car row)) (cadr row)
                    (list (car r) (cdr r) (point)))))))
 '((1 (same #f 1))
   (47 (same 30 1))))

;; `c-end-of-decl-1' skips the K&R declarations and the body block.
(lk-buffer-c lk-knr
 (lambda ()
   (goto-char 1)
   (test-equal "c-end-of-decl-1 reaches past the body" '(#t 132)
               (list (c-end-of-decl-1) (point)))))

(define lk-stmt
  (string-append
   "int f(int x)\n"
   "{\n"
   "  if (x) x = 1;\n"
   "  else if (x) x = 2;\n"
   "  do x--; while (x);\n"
   "  return x;\n"
   "}\n"))

;; `c-after-conditional' answers the start of the conditional it is
;; after, and nil when the point is not after one.
(for-each
 (lambda (row)
   (lk-buffer-c lk-stmt
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'cond (car row)) (cadr row)
                  (list (c-after-conditional) (point))))))
 '((25 (18 25))
   (46 (39 46))))

;; `c-skip-conditional' moves over the conditional and its parenthesized
;; predicate. Its value is not part of the contract, so the probe ends
;; in #f on both sides.
(for-each
 (lambda (row)
   (lk-buffer-c lk-stmt
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'skip (car row)) (cadr row)
                  (list (begin (c-skip-conditional) #f) (point))))))
 '((18 (#f 24))
   (34 (#f 45))
   (55 (#f 57))))

(lk-buffer-cpp "void f() { try { g(); } catch (...) { } }\n"
 (lambda ()
   (goto-char 12)
   (test-equal "c-skip-conditional over try" '(#f 15)
               (list (begin (c-skip-conditional) #f) (point)))))

;; The two anchors: at a brace that is already at the beginning of its
;; indentation neither moves.
(lk-buffer-c lk-stmt
 (lambda ()
   (goto-char 14)
   (test-equal "c-backward-to-block-anchor at boi"
               (list #f 14)
               (list (begin (c-backward-to-block-anchor) #f) (point)))))

(lk-buffer-c lk-stmt
 (lambda ()
   (goto-char 14)
   (test-equal "c-backward-to-decl-anchor at boi"
               (list #f 14)
               (list (begin (c-backward-to-decl-anchor) #f) (point)))))

;; `c-search-decl-header-end' stops after the `='/`{'/`;' it finds.
(lk-buffer-c "int x = 5;\nstruct s { int a; } sv;\n"
 (lambda ()
   (goto-char 1)
   (test-equal "c-search-decl-header-end stops after the =" '(#f 8)
               (list (begin (c-search-decl-header-end) #f) (point)))
   (goto-char 12)
   (test-equal "and after the block's opening brace" '(#f 22)
               (list (begin (c-search-decl-header-end) #f) (point)))))

;; `c-after-special-operator-id' answers the start of `operator==' from
;; the `(' that follows it.
(lk-buffer-cpp "struct S { bool operator==(const S& o) const; };\n"
 (lambda ()
   (goto-char 27)
   (test-equal "c-after-special-operator-id" '(17 27)
               (list (c-after-special-operator-id) (point)))))

(test-end "schemacs_editor_cc_engine_label_knr")

(test-begin "schemacs_editor_cc_engine_bracelist")

;; The bracelist machinery (`cc-engine.el:12966'-`:13582'): the
;; enclosing-decl-block lookup, the typed-enum colon and header scans,
;; the laomib cache loop, `c-looking-at-or-maybe-in-bracelist' and
;; `c-at-bracelist-p'. Every expectation is Emacs 31.1's own answer,
;; measured one probe per fresh buffer - cc-mode caches in text
;; properties (`c-is-sws', `c-in-sws'), so a long-lived buffer is not
;; Emacs's fresh answer.
;;
;; The fixture, for reading the positions:
;;
;;     line 1   1..28   "struct Point { int x, y; };"   newline 28
;;     line 2  29..43   "Point p{1, 2};"                newline 43
;;     line 3  44..65   "enum class E { A, B };"        newline 65
;;     line 4  66..95   "enum struct F : int { C, D };" newline 95
;;     line 5  96..113  "int a[] = {1, 2};"             newline 113

(define bl-fixture
  (string-append
   "struct Point { int x, y; };\n"
   "Point p{1, 2};\n"
   "enum class E { A, B };\n"
   "enum struct F : int { C, D };\n"
   "int a[] = {1, 2};\n"))

;; `c-looking-at-or-maybe-in-bracelist': `t' when point may be inside a
;; bracelist, a cons (START . IN-PAREN) when it starts one, nil when it
;; is neither.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (let ((r (c-looking-at-or-maybe-in-bracelist)))
        (test-equal (list 'lamib (car row)) (cadr row)
                    (if (pair? r)
                        (list (car r) (cdr r) (point))
                        (list r (point))))))))
 '((14 (#t 14))
   (36 (29 #f 36))
   (57 (44 #f 57))
   (87 (#f 87))
   (107 (97 #f 107))))

;; `c-backward-typed-enum-colon' leaves point before the colon of a
;; strongly-typed enum and answers t; on `enum class E' (no colon) it
;; answers nil and stays.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'enum-colon (car row)) (cadr row)
                  (list (c-backward-typed-enum-colon) (point))))))
 '((87 (#t 81))
   (57 (#f 57))))

;; `c-backward-over-enum-header' moves to the enum-like keyword and
;; answers t, in both enum spellings.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'enum-header (car row)) (cadr row)
                  (list (c-backward-over-enum-header) (point))))))
 '((87 (#t 67))
   (57 (#t 44))))

;; `c-at-enum-brace' answers the keyword's position.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'enum-brace (car row)) (cadr row)
                  (list (c-at-enum-brace) (point))))))
 '((87 (67 87))
   (57 (44 57))))

;; `c-laomib-loop' walks back to the `='; from the `{' inside the
;; initializer it leaves point before that brace.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'laomib (car row)) (cadr row)
                  (list (c-laomib-loop #f) (point))))))
 '((107 (#t 102))
   (106 (#t 102))
   (14 (#f 1))))

;; The enclosing declaration block.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'mebd (car row)) (cadr row)
                  (list (c-most-enclosing-decl-block (c-parse-state))
                        (point))))))
 '((20 (14 20))
   (40 (#f 40))))

;; `c-cheap-inside-bracelist-p' at the same positions.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'cibp (car row)) (cadr row)
                  (list (c-cheap-inside-bracelist-p (c-parse-state))
                        (point))))))
 '((20 (#f 20))
   (40 (#f 40))))

;; `c-at-bracelist-p' with the enclosing brace `c-parse-state' finds -
;; Emacs's own harness shape, and the answers of the same shape in
;; `tools/cc-decl-diff'.
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (let* ((paren-state (c-parse-state))
             (brace (c-most-enclosing-brace paren-state)))
        (test-equal (list 'at-bracelist (car row)) (cadr row)
                    (list brace
                          (and brace
                               (save-excursion (goto-char brace)
                                               (eqv? (char-after (point)) #\{))
                               (c-at-bracelist-p brace paren-state))))))))
 '((20 (14 #f))
   (40 (36 35))
   (60 (57 44))
   (90 (87 #f))
   (110 (107 97))))

;; `c-strip-conses' drops the conses and keeps the atoms, in order.
(lk-buffer-cpp "\n"
 (lambda ()
   (test-equal "c-strip-conses" '(1 6)
               (c-strip-conses (list 1 (cons 2 3) (cons 4 5) 6)))))

;; The declaration decision over the enum spellings. `enum class E'
;; answers E (not `class') as the declarator: the `maybe-typeless'
;; branch runs only when `at-type' is `maybe' or `found', and a
;; `when'-as-value that answers the unspecified (true) value ran it for
;; every type (see DEPARTURES.md).
(for-each
 (lambda (row)
   (lk-buffer-cpp bl-fixture
    (lambda ()
      (goto-char (car row))
      (test-equal (list 'decl (car row)) (cadr row)
                  (list (c-forward-decl-or-cast-1
                         (max (point-min) (- (point) 1)) 'top #f)
                        (point))))))
 '((1 ((8 (#t #f #f) #f 8 #t) 27))
   (29 ((35 #f #f 29 #t) 36))
   (67 ((79 (#t #f #f) #f 79 #t) 81))
   (97 ((101 #f #f 97 #t) 105))))

(test-end "schemacs_editor_cc_engine_bracelist")

(test-begin "schemacs_editor_cc_engine_find_decl")

;; `c-find-decl-spots' and the machinery under it. Every expectation is
;; Emacs 31.1's own answer, measured with `emacs -Q --batch' on the same
;; fixture (the script is in the handoff).
(define cfd-fixture
  "class A {\npublic:\n  void f(int x);\n  int y;\n};\n\nint g(void) { return 1; }\n")

(define (cfd-buffer text thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
    (thunk)))

(cfd-buffer cfd-fixture
 (lambda ()
   (let ((spots '()))
     (goto-char (point-min))
     (c-find-decl-spots (point-max)
                        (c-lang-const c-decl-start-re c)
                        #f
                        (lambda (match-pos in-macro top-level)
                          (set! spots (cons (list match-pos in-macro
                                                  top-level (point))
                                            spots))
                          #f))
     (test-equal "c-find-decl-spots finds the declaration spots Emacs finds"
                 '((0 #f #t 1) (10 #f #f 11) (28 #f #f 28) (35 #f #f 38)
                   (47 #f #t 49) (55 #f #t 55) (62 #f #f 63))
                 (reverse spots)))
   (test-equal "the brace stack at bob is the notional all-enclosing block"
               '(#f 1) (c-brace-stack-at 1))
   (test-equal "inside the class brace it is two deep"
               '(#f 2) (c-brace-stack-at 12))
   (test-equal "...and it stays two deep at the end of the class body"
               '(#f 2) (c-brace-stack-at 40))
   (test-equal "c-bs-at-toplevel-p is false inside the class"
               #f (c-bs-at-toplevel-p 12))
   (test-equal "...and true at bob"
               #t (c-bs-at-toplevel-p 1))))

(cfd-buffer "// aaa\n// bbb\n// ccc\nint x;\n"
 (lambda ()
   (test-equal "a line-comment range extends over the adjacent comments"
               (cons 1 14) (c-collect-line-comments (cons 8 14)))
   (test-equal "a range that does not start at a comment starter is returned"
               (cons 6 12) (c-collect-line-comments (cons 6 12)))))

(cfd-buffer "foo bar"
 (lambda ()
   (c-clear-found-types)
   (hash-set! (c-found-types) "B" #t)
   (hash-set! (c-found-types) "A" #t)
   (test-equal "c-list-found-types sorts the keys"
               '("A" "B") (c-list-found-types))
   (c-clear-found-types)
   (hash-set! (c-found-types) "foo" #t)
   (set!c-maybe-stale-found-type (list 'c-decl-id-start "foo" 1 3 " " "x"))
   (c-trim-found-types 1 2 1)
   (test-equal "c-trim-found-types removes the stale type"
               #f (hash-ref (c-found-types) "foo" #f))))

(test-end "schemacs_editor_cc_engine_find_decl")

;;----------------------------------------------------------------------
;; The `<'-`>' pair properties and their change functions
;; (`cc-engine.el:7035'-`:7511')
;;----------------------------------------------------------------------
;; Every expectation is Emacs 31.1's, measured in a real `c++-mode'
;; buffer with `inhibit-modification-hooks' bound and the functions
;; called in the order `cc-mode.el''s change hooks call them (those hooks
;; are not ported yet): `c-restore-<>-properties' is what
;; `c-common-init' runs over the whole buffer as a mode starts.
(define (angle-buffer text proc)
  (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (insert text)
      (set-buffer-local-value! b 'major-mode 'c++-mode)
      (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
      (c-init-language-vars c++-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
      (c-clear-found-types)
      ;; "Starting a mode is a sort of change": c-common-init's block.
      (set!c-new-BEG (point-min))
      (set!c-new-END (point-max))
      (c-restore-<>-properties (point-min) (point-max) 0)
      (proc))))

(test-begin "schemacs_editor_cc_engine_angle_props")

(angle-buffer "void f () { static_cast<int> (x); }\n"
 (lambda ()
   (test-equal "the mode's init marks static_cast's angle brackets"
               '((4 . 62) (5 . 60))
               (list (get-text-property 24 'syntax-table)
                     (get-text-property 28 'syntax-table)))
   (goto-char 24)
   (c-clear-<>-pair-props)
   (test-equal "c-clear-<>-pair-props removes the bracket's property"
               #f (get-text-property 24 'syntax-table))
   (test-equal "...and its partner's" #f
               (get-text-property 28 'syntax-table))))

(angle-buffer "void f () { static_cast<int> (x); }\n"
 (lambda ()
   (set!c-new-BEG 28)
   (set!c-new-END 29)
   (c-before-change-check-<>-operators 28 29)
   (delete-region 28 29)
   (c-after-change-check-<>-operators 28 28)
   (c-restore-<>-properties 28 28 1)
   (test-equal "deleting the \">\" leaves the \"<\" marked, as Emacs does"
               '(4 . 62) (get-text-property 24 'syntax-table))
   (test-equal "...and the truncated text is Emacs's"
               "void f () { static_cast<int (x); }\n"
               (buffer-substring-no-properties 1 (point-max)))))

(angle-buffer "x = \"abc\"; y = 1;\n"
 (lambda ()
   (test-equal "c-end-of-literal answers the end of the string literal"
               10 (c-end-of-literal (c-semi-pp-to-literal 8) 8))))

(angle-buffer "void f () { static_cast<int> (x); }\n"
 (lambda ()
   ;; This row is also the regression test for the `(car (cddr STATE))'
   ;; of a state with no literal: Emacs's `(car nil)' is nil, Scheme's
   ;; `(car '())' raised, and this was the first call to reach it.
   (c-unmark-<>-around-region 24 24 1)
   (test-equal "c-unmark-<>-around-region clears a pair a change splits"
               #f (get-text-property 24 'syntax-table))
   (test-equal "...at both ends" #f (get-text-property 28 'syntax-table))
   (test-equal "...and leaves (c-new-BEG c-new-END) alone"
               (list 1 37) (list (c-new-BEG) (c-new-END)))))

(test-end "schemacs_editor_cc_engine_angle_props")

;;----------------------------------------------------------------------
;; `c-guess-basic-syntax' (`cc-engine.el:14769'-`:16532')
;;----------------------------------------------------------------------
;; Every expected value below is Emacs 31.1's own answer on the same
;; text. The whole-fixture differential (this text and the fixtures
;; under `tools/cc-decl-diff/') was run both ways and is identical; the
;; rows here are the representative ones, kept so a break shows a
;; readable answer rather than a diff.
(test-begin "schemacs_editor_cc_engine_guess")

(define cgbs-fixture1
  "int main (int argc, char **argv)\n{\n  int i;\n  if (argc > 1)\n    return 1;\n  else\n    i = 0;\n  switch (i)\n    {\n    case 0:\n      break;\n    default:\n      i++;\n    }\n  for (i = 0; i < argc; i++)\n    {\n      printf (\"%s\\n\", argv[i]);\n    }\n  return 0;\n}\n")

(define (cgbs-buffer text thunk)
  ;; A `c-mode' buffer with the mode's init replayed: the language
  ;; variables, the syntax table, and the after-hook's two regexp
  ;; builders. `parse-sexp-ignore-comments' is what `cc-mode.el:639'
  ;; sets buffer-locally.
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (c-set-style "gnu")
      (c-clear-found-types)
      (c-make-noise-macro-regexps)
      (c-make-macro-with-semi-re)
      (thunk))))

(define (cgbs-at pos)
  (goto-char pos)
  (beginning-of-line)
  (c-guess-basic-syntax))

(cgbs-buffer
 cgbs-fixture1
 (lambda ()
   (test-equal "line 1 is a topmost intro" '((topmost-intro 1)) (cgbs-at 1))
   (test-equal "the defun brace" '((defun-open 1)) (cgbs-at 34))
   (test-equal "the defun body" '((defun-block-intro 34)) (cgbs-at 36))
   (test-equal "a statement" '((statement 38)) (cgbs-at 45))
   (test-equal "a substatement" '((substatement 47)) (cgbs-at 61))
   (test-equal "an else clause" '((else-clause 47)) (cgbs-at 75))
   (test-equal "a substatement body" '((substatement 77)) (cgbs-at 82))
   (test-equal "the statement after the if" '((statement 47)) (cgbs-at 93))
   (test-equal "a switch brace" '((substatement-open 95)) (cgbs-at 106))
   (test-equal "a case label" '((case-label 110)) (cgbs-at 112))
   (test-equal "a case body" '((statement-case-intro 116)) (cgbs-at 124))
   (test-equal "the default label" '((case-label 110)) (cgbs-at 137))
   (test-equal "the default body" '((statement-case-intro 141)) (cgbs-at 150))
   (test-equal "the switch's close" '((block-close 110)) (cgbs-at 161))
   (test-equal "the for statement" '((statement 95)) (cgbs-at 167))
   (test-equal "the for body brace" '((substatement-open 169)) (cgbs-at 196))
   (test-equal "the for body" '((statement-block-intro 200)) (cgbs-at 202))
   (test-equal "the for body's close" '((block-close 200)) (cgbs-at 234))
   (test-equal "the return" '((statement 169)) (cgbs-at 240))
   (test-equal "the defun's close" '((defun-close 34)) (cgbs-at 252))))

(cgbs-buffer
 "int a[] = {1, 2, 3};\nstruct S s = {.x = 1, .y = 2};\n"
 (lambda ()
   (test-equal "a top-level initializer" '((topmost-intro 1)) (cgbs-at 1))
   (test-equal "the next top-level line" '((topmost-intro 1)) (cgbs-at 22))))

(test-end "schemacs_editor_cc_engine_guess")

;;----------------------------------------------------------------------
;; Indentation calculation (`cc-engine.el:16537'-`:16738')
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_engine_offsets")

(cgbs-buffer
 "int main (int argc)\n{\n  int i;\n}\n"
 (lambda ()
   (set!c-basic-offset 4)
   (test-equal "a number is itself" 4 (c-evaluate-offset 4 #f 'test))
   (test-equal "a vector is itself" '#(0) (c-evaluate-offset '#(0) #f 'test))
   (test-equal "nil stays nil" #f (c-evaluate-offset #f #f 'test))
   (test-equal "+ is c-basic-offset" 4 (c-evaluate-offset '+ #f 'test))
   (test-equal "- is minus c-basic-offset" -4 (c-evaluate-offset '- #f 'test))
   (test-equal "++ doubles" 8 (c-evaluate-offset '++ #f 'test))
   (test-equal "-- doubles the negative" -8 (c-evaluate-offset '-- #f 'test))
   (test-equal "* halves" 2 (c-evaluate-offset '* #f 'test))
   (test-equal "/ halves the negative" -2 (c-evaluate-offset '/ #f 'test))
   (test-equal "min picks the smaller" 3 (c-evaluate-offset '(min 3 5) #f 'test))
   (test-equal "max picks the larger" 5 (c-evaluate-offset '(max 3 5) #f 'test))
   (test-equal "add sums" 7 (c-evaluate-offset '(add 3 4) #f 'test))
   (test-equal "a quoted offset in add is ignored" 3
               (c-evaluate-offset '(add 3 '(4)) #f 'test))
   (test-equal "first takes the first non-nil" 3
               (c-evaluate-offset '(first nil 3) #f 'test))
   (test-equal "a mistakenly quoted offset is nil" #f
               (c-evaluate-offset '(quote 3) #f 'test))
   ;; c-basic-offset is 4 in this buffer, so gnu's `+' offset for
   ;; defun-block-intro is 4 (Emacs answers 4 on the same text).
   (test-equal "c-get-offset through the old form" 4
               (c-get-syntactic-indentation '((defun-block-intro 34))))
   (test-equal "a zero-offset statement" 0
               (c-get-syntactic-indentation '((statement 38))))))

(test-end "schemacs_editor_cc_engine_offsets")


;;--------------------------------------------------------------
;; The multi-line string delimiter machinery (`cc-engine.el:7549'-`:7862')
;;--------------------------------------------------------------
;; Emacs 31.1's answers on a C++ raw string, measured with the same
;; calls (`/tmp/ml-em.el'); the mode's own initial propertization was
;; wiped on the Emacs side and is absent here, then both call
;; `c-maybe-re-mark-ml-string' at the same position.
(test-begin "schemacs_editor_cc_engine_ml_delims")

(define (cpp-raw-buffer thunk)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "auto s = R\"delim(abc)delim\";\nint b;\n")
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c++-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
    (let loop ((p 1))
      (when (<= p (1- (point-max)))
        (c-clear-char-property p 'syntax-table)
        (c-clear-char-property p 'c-fl-syn-tab)
        (loop (+ p 1))))
    (goto-char 12)
    (c-maybe-re-mark-ml-string)
    (thunk)))

(cpp-raw-buffer
 (lambda ()
   (define (delims-at p) (goto-char p) (c-ml-string-delims-around-point))
   (test-equal "inside the opener the delimiters are found"
     '((10 18 . 11) 21 28 . 27) (delims-at 11))
   (test-equal "... and point is in the opener"
     'open-delim (c-position-wrt-ml-delims (delims-at 12)))
   (test-equal "inside the string"
     'string (c-position-wrt-ml-delims (delims-at 18)))
   (test-equal "in the closer"
     'close-delim (c-position-wrt-ml-delims (delims-at 25)))
   (test-equal "just after the closer"
     'after-close (c-position-wrt-ml-delims (delims-at 28)))
   (test-equal "outside the string nothing is found"
     #f (delims-at 9))
   (test-equal "an opener intersecting the region is reported"
     '(10 18 . 11) (c-ml-string-opener-intersects-region 1 (point-max)))
   (test-equal "... for an inner region too"
     '(10 18 . 11) (c-ml-string-opener-intersects-region 13 15))))

(test-end "schemacs_editor_cc_engine_ml_delims")


;;--------------------------------------------------------------
;; `c-depropertize-ml-string' and the C++20 module check
;; (`cc-engine.el:8266'-`:8400')
;;--------------------------------------------------------------
;; Emacs 31.1's answers (`/tmp/dep-em.el'): a raw string whose
;; delimiter contains quotes gets '(1) on those quotes, the region
;; depropertizer removes them all, and a tight region around a C++20
;; module statement is extended to the statement's bounds.
(test-begin "schemacs_editor_cc_engine_ml_depropertize")

(define (props-in-buffer)
  (let loop ((p 1) (acc '()))
    (if (> p (point-max)) (reverse acc)
        (let ((st (get-text-property p 'syntax-table)))
          (if st (loop (+ p 1) (cons (list p st) acc))
              (loop (+ p 1) acc))))))

(define (cpp-buffer text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c++-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
    (let loop ((p 1))
      (when (<= p (1- (point-max)))
        (c-clear-char-property p 'syntax-table)
        (c-clear-char-property p 'c-fl-syn-tab)
        (loop (+ p 1))))
    b))

;; A raw string whose delimiter contains quotes; the quotes inside
;; the delimiters are at positions 13 and 20.

(cpp-buffer (string-append "auto s = R" (string #\") "d" (string #\")
                           "e(hi)d" (string #\") "e" (string #\") ";"
                           (string #\newline) "int b;" (string #\newline)))
(goto-char 12)
(c-maybe-re-mark-ml-string)
(test-equal "the quotes in a raw string's delimiters are punctuation"
  (list (list 13 '(1)) (list 20 '(1))) (props-in-buffer))
(c-depropertize-ml-strings-in-region 1 (point-max))
(test-equal "the region depropertizer removes them all"
  '() (props-in-buffer))
(test-equal "... leaving no neutralized character" #f c-neutralize-pos)

;; The C++20 module statement extension.
(cpp-buffer "module foo;\nint x;\nimport bar;\n")
(set!c-new-BEG 8) (set!c-new-END 9)
(c-before-after-change-check-c++-modules 10 10)
(test-equal "the region grows to the whole module statement"
  (list 1 12) (list (c-new-BEG) (c-new-END)))

(test-end "schemacs_editor_cc_engine_ml_depropertize")


;;--------------------------------------------------------------
;; `c-ml-string-back-to-neutral' (`cc-engine.el:7654')
;;--------------------------------------------------------------
(test-begin "schemacs_editor_cc_engine_ml_neutral")
(cpp-buffer (string-append "auto s = R" (string #\") "delim(abc)delim"
                           (string #\") ";"
                           (string #\newline) "int b;" (string #\newline)))
(goto-char 12)
(c-maybe-re-mark-ml-string)
(for-each
 (lambda (p)
   (goto-char p)
   (c-ml-string-back-to-neutral 10)
   (test-equal (string-append "back to neutral from " (number->string p))
     18 (point)))
 '(19 21 25 27 28))
(test-end "schemacs_editor_cc_engine_ml_neutral")


;;--------------------------------------------------------------
;; `c-ml-string-in-end-delim' (`cc-engine.el:7670')
;;--------------------------------------------------------------
(test-begin "schemacs_editor_cc_engine_ml_end_delim")
(cpp-buffer (string-append "auto s = R" (string #\") "delim(abc)delim"
                           (string #\") ";"
                           (string #\newline) "int b;" (string #\newline)))
(goto-char 12)
(c-maybe-re-mark-ml-string)
(for-each
 (lambda (case)
   (test-equal (string-append "in-end-delim from "
                              (number->string (car case)) " to "
                              (number->string (cadr case)))
     (list-ref case 3)
     (c-ml-string-in-end-delim (car case) (cadr case) (list-ref case 2))))
 (list (list 12 13 #f #f)
       (list 12 13 '(10 18 . 11) #f)
       (list 20 21 #f #f)
       (list 25 25 '(10 18 . 11) '(21 . 28))
       (list 26 27 #f #f)
       (list 28 29 #f #f)
       (list 30 31 #f #f)))
(test-end "schemacs_editor_cc_engine_ml_end_delim")


;;--------------------------------------------------------------
;; `c-before-change-check-ml-strings' (`cc-engine.el:7863') and
;; `c-after-change-unmark-ml-strings' (`:7953')
;;--------------------------------------------------------------
;; Each row is one change driven the way cc-mode's hooks drive it: the
;; region is the change's own, the before-change function runs, the edit
;; is made, the after-change function runs. The expectation is the whole
;; answer - the grown region, the disrupted flag, the buffer and the
;; `syntax-table' properties - measured on Emacs 31.1 first.
(test-begin "schemacs_editor_cc_engine_ml_change")

(define D (string #\"))
(define NL (string #\newline))
(define BS (string #\\))

(define ml-f1 (string-append "auto s = R" D "delim(abc)delim" D ";" NL
                             "int b;" NL))
(define ml-f2 (string-append "auto s = R" D "delim(abc;" NL "int b;" NL))
(define ml-f3 (string-append "int x;" NL "char *s = " D "abc" NL "def" D ";"
                             NL "int y;" NL))
(define ml-f4 (string-append "auto s = R" D "x(abc)x" D ";" NL "int b;" NL))
(define ml-f5 (string-append "#define M " BS NL "R" D "y(ab" BS NL "cd)y" D NL
                             "int b;" NL))

(define (ml-change-case text markpos beg end-old new)
  (cpp-buffer text)
  (goto-char markpos)
  (c-maybe-re-mark-ml-string)
  (set!c-new-BEG beg) (set!c-new-END end-old)
  (c-before-change-check-ml-strings beg end-old)
  (goto-char beg)
  (if new (insert new) (delete-char (- end-old beg)))
  (c-after-change-unmark-ml-strings
   beg (+ beg (if new (string-length new) 0)) (- end-old beg))
  (list (c-new-BEG) (c-new-END) c-ml-string-end-delim-disrupted
        (buffer-substring-no-properties (point-min) (point-max))
        (props-in-buffer)))

(test-equal "an edit inside a raw string's contents leaves the region"
  (list 19 19 #f
        (string-append "auto s = R" D "delim(aXbc)delim" D ";" NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f1 12 19 19 "X"))

(test-equal "deleting the closing quote disrupts the terminator"
  (list 10 28 #t
        (string-append "auto s = R" D "delim(abc)delim;" NL "int b;" NL)
        '())
  (ml-change-case ml-f1 12 27 28 #f))

(test-equal "inserting a quote before the closer disrupts it too"
  (list 10 38 #t
        (string-append "auto s = R" D "delim(abc)delim" D D ";" NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f1 12 27 27 D))

(test-equal "typing into the opener depropertizes the whole string"
  (list 10 28 #f
        (string-append "auto s = R" D "delimq((abc)delim" D ";" NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f1 12 17 17 "q("))

(test-equal "a raw string inside a new macro is depropertized"
  (list 1 1 #f
        (string-append "#define X auto s = R" D "delim(abc)delim" D ";" NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f1 12 1 1 "#define X "))

(test-equal "an edit inside an unterminated raw string keeps its fences"
  (list 19 19 #f
        (string-append "auto s = R" D "delim(aXbc;" NL "int b;" NL)
        '((11 (1)) (17 (15))))
  (ml-change-case ml-f2 12 19 19 "X"))

(test-equal "... until the edit completes it, and the fences go"
  (list 10 30 #f
        (string-append "auto s = R" D "delimq(abc;" NL "int b;" NL)
        '())
  (ml-change-case ml-f2 12 17 17 "q"))

(test-equal "an edit inside an ordinary multi-line string is left alone"
  (list 20 20 #f
        (string-append "int x;" NL "char *s = " D "aXbc" NL "def" D ";" NL
                       "int y;" NL)
        '())
  (ml-change-case ml-f3 20 20 20 "X"))

(test-equal "typing a closer after a terminated raw string changes nothing"
  (list 21 21 #f
        (string-append "auto s = R" D "x(abc)x" D ";)" NL "int b;" NL)
        '())
  (ml-change-case ml-f4 12 21 21 ")"))

(test-equal "typing a quote into a raw string's inside disrupts its closer"
  (list 10 30 #t
        (string-append "auto s = R" D "x(abc)x" D D ";" NL "int b;" NL)
        '())
  (ml-change-case ml-f4 12 19 19 D))

(test-equal "deleting the escaped newline of a macro extends to the macro"
  (list 1 26 #f
        (string-append "#define M " BS NL "R" D "y(ab" NL "cd)y" D NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f5 15 19 20 #f))

(test-equal "deleting into the closer disrupts it and keeps the region tight"
  (list 13 26 #t
        (string-append "#define M " BS NL "R" D "y(ab" BS NL "cdy" D NL
                       "int b;" NL)
        '())
  (ml-change-case ml-f5 15 23 24 #f))

(test-end "schemacs_editor_cc_engine_ml_change")
