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
 (only (schemacs editor editfns) insert goto-char point delete-region
       buffer-substring-no-properties)
 (only (schemacs editor syntax) set-syntax-table)
 (only (schemacs editor textprop) get-text-property text-property-any)
 (only (schemacs editor cc-defs) c-lang-const *c-buffer-is-cc-mode*
       c-skip-ws-chars-forward c-skip-ws-chars-backward)
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
            "\\`a\\`" c-doc-line-join-re)
(test-equal "and so does the bright-comment one"
            "\\`a\\`" c-doc-bright-comment-start-re)
(test-equal "the line-join end-char list starts nil" #f c-doc-line-join-end-ch)

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

(test-end "schemacs_editor_cc_engine")
