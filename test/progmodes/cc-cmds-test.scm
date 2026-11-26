;; Tests for `(schemacs progmodes cc-cmds)' - the indentation command
;; layer of `lisp/progmodes/cc-cmds.el'.
;;
;; **Every expectation here is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' on the same fixture text in a real `c-mode'
;; buffer before the port was written. The script is
;; `/tmp/measure-cmds2.el` and `/tmp/measure3.el`/`measure4.el',
;; rebuilt from the cases below.
;;
;; The mode replay is `cc-engine-tests.scm`'s. **A test that edits must
;; use a fresh buffer per test**: cc-mode caches its parse state in
;; buffer-local slots and text properties, and the change functions
;; that invalidate them are `cc-mode.el`'s `c-before-change` and
;; `c-after-change`, which are not ported yet - so a second edit on the
;; same buffer can read the caches the first left. That is also why the
;; whole-buffer `c-indent-region` differential
;; (`tools/cc-cmds-diff/`) is green on single-pass fixtures and red on
;; the ones that need a line's reindentation to feed the next line's
;; parse; see that directory's README.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer
       buffer-local-value set-buffer-local-value!)
 (only (schemacs editfns) insert goto-char point point-min point-max
       forward-line buffer-substring line-beginning-position save-excursion
       bobp eobp)
 (only (schemacs cmds) end-of-line)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*)
 (schemacs progmodes cc-langs)
 (only (schemacs progmodes cc-vars)
       c-syntactic-indentation set!c-syntactic-indentation
       c-block-comment-flag
       *c-tab-always-indent*
       set!c-cleanup-list *c-electric-pound-behavior*
       c-make-noise-macro-regexps c-make-macro-with-semi-re)
 (only (schemacs progmodes cc-styles) c-set-style c-set-offset)
 (only (schemacs progmodes cc-engine)
       c-parsing-error c-electric-flag c-auto-newline c-hungry-delete-key
       set!c-electric-flag set!c-auto-newline set!c-hungry-delete-key
       c-clear-found-types c-literal-limits c-literal-type
       c-beginning-of-macro c-end-of-macro c-query-and-set-macro-start
       *c-macro-start*)
 ;; The line-up registry `c-run-special-indent-hook' resolves the
 ;; style's `c-gnu-impose-minimum' through is filled when this loads.
 (schemacs progmodes cc-align)
 (only (schemacs progmodes subword) subword-mode)
 (only (schemacs progmodes cc-cmds)
       c-backward-into-nomenclature
       c-indent-line c-newline-and-indent c-indent-command c-indent-exp
       c-backslash-region c-update-modeline
       c-toggle-auto-newline c-toggle-hungry-state c-toggle-electric-state
       c-toggle-syntactic-indentation c-toggle-comment-style
       c-syntactic-information-on-region *c-fix-backslashes*
       c-where-wrt-brace-construct c-in-function-trailer-p
       c-defun-name c-cpp-define-name c-declaration-limits
       c-defun-name-and-limits c-beginning-of-defun c-end-of-defun
       c-indent-defun
       c-beginning-of-statement c-end-of-statement
       c-back-over-illiterals c-forward-over-illiterals
       c-ascertain-preceding-literal c-ascertain-following-literal
       c-after-statement-terminator-p c-one-line-string-p
       c-beginning-of-sentence-in-comment c-end-of-sentence-in-comment
       c-beginning-of-sentence-in-string c-end-of-sentence-in-string
       c-comment-indent c-outline-level c-in-comment-line-prefix-p
       c-scan-conditionals
       c-electric-brace c-electric-semi&comma c-electric-colon
       c-electric-slash c-electric-star c-electric-pound c-electric-paren
       c-electric-backspace c-hungry-delete-backwards
       c-electric-delete-forward c-hungry-delete-forward
       c-electric-continued-statement c-electric-lt-gt
       c-post-text-conversion
       c-fill-paragraph c-do-auto-fill c-indent-new-comment-line
       c-context-line-break c-context-open-line)
 (only (schemacs newcomment) comment-start comment-end *comment-multi-line*)
 (only (schemacs command) *last-command-event*)
 (only (schemacs elec-pair) electric-pair-mode)
 (only (schemacs paren) *blink-paren-function*))

(test-begin "schemacs_editor_cc_cmds")

(define (fresh text)
  ;; A `c-mode' buffer as `define-derived-mode' will build one; see
  ;; `cc-engine-tests.scm'.
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (c-set-style "gnu")
      ;; `c-basic-common-init' clears the found-type table, and the
      ;; declaration machinery reads it. The mode's `:after-hook'
      ;; builds the noise-macro and vsemi regexps; without them
      ;; `c-forward-sws' looks up a #f one.
      (c-clear-found-types)
      (c-make-noise-macro-regexps)
      (c-make-macro-with-semi-re))
    ;; `c-basic-common-init' (`cc-mode.el`) sets these; cc-mode.el is
    ;; not ported, so the replay does what the mode will. The block
    ;; comment flag is the mode's default comment style.
    (set-buffer-local-value! b 'indent-line-function c-indent-line)
    (set-buffer-local-value! b 'c-block-comment-flag #t)
    b))

(define (contents)
  (buffer-substring (point-min) (point-max)))

;;--------------------------------------------------------------
;; `c-indent-line'
;;--------------------------------------------------------------
;; Emacs, measured: `(c-indent-line)' at "int x;" returns 2 and the
;; buffer becomes the indented text.
(let ((b (fresh "int f (void)\n{\nint x;\n  return x;\n}\n")))
  (goto-char (point-min))
  (forward-line 2)
  (test-equal "c-indent-line shifts the line and answers the shift"
              2
              (c-indent-line))
  (test-equal "c-indent-line's text" "int f (void)\n{\n  int x;\n  return x;\n}\n"
              (contents))
  (test-equal "c-indent-line leaves no parsing error" #f (c-parsing-error)))

;;--------------------------------------------------------------
;; `c-newline-and-indent'
;;--------------------------------------------------------------
;; Emacs, measured: at the end of "  int x = 1;" the call answers
;; point 31 and the new empty line carries the indentation (two spaces)
;; because `indent-to col' runs before the syntactic reindent.
(let ((b (fresh "int f (void)\n{\n  int x = 1;\n  int y = 2;\n}\n")))
  (goto-char (point-min))
  (forward-line 2)
  (end-of-line)
  (test-equal "c-newline-and-indent answers nil, as Emacs's `when' does"
              #f (c-newline-and-indent))
  (test-equal "c-newline-and-indent leaves point at 31" 31 (point))
  (test-equal "c-newline-and-indent's text"
              "int f (void)\n{\n  int x = 1;\n  \n  int y = 2;\n}\n"
              (contents)))

;;--------------------------------------------------------------
;; `c-indent-command'
;;--------------------------------------------------------------
;; Emacs, measured, with the default `c-tab-always-indent' t.
(let ((b (fresh "int f (void)\n{\nint x;\n}\n")))
  (goto-char (point-min))
  (forward-line 2)
  (c-indent-command #f)
  (test-equal "c-indent-command indents the line" "int f (void)\n{\n  int x;\n}\n"
              (contents)))

;;--------------------------------------------------------------
;; `c-indent-exp'
;;--------------------------------------------------------------
;; Emacs, measured: from the "{" line, the whole function body.
(let ((b (fresh "int f (void)\n{\nint x;\nreturn x;\n}\n")))
  (goto-char (point-min))
  (forward-line 1)
  (c-indent-exp #t)
  (test-equal "c-indent-exp indents the expression"
              "int f (void)\n{\n  int x;\n  return x;\n}\n"
              (contents)))

;;--------------------------------------------------------------
;; `c-backslash-region'
;;--------------------------------------------------------------
;; Emacs, measured: the four lines aligned at `c-backslash-column'
;; (48, a style value), each line's backslash preceded by the padding.
(let ((b (fresh "#define FOO(a, b) \\\n  do { \\\n    x (a); \\\n  } while (0)\n")))
  (goto-char (point-min))
  (c-backslash-region (point-min) (point-max) #f)
  (test-equal "c-backslash-region aligns the backslashes"
              "#define FOO(a, b)\t\t\t\t\\\n  do {\t\t\t\t\t\t\\\n    x (a);\t\t\t\t\t\\\n  } while (0)\n"
              (contents)))

;; Emacs, measured: deleting them takes the whitespace before each one.
(let ((b (fresh "#define FOO(a, b) \\\n  do { } \\\n  while (0)\n")))
  (goto-char (point-min))
  (c-backslash-region (point-min) (point-max) #t)
  (test-equal "c-backslash-region deletes the backslashes"
              "#define FOO(a, b)\n  do { }\n  while (0)\n"
              (contents)))

;;--------------------------------------------------------------
;; The toggles and `c-update-modeline'
;;--------------------------------------------------------------
;; Emacs, measured, with `mode-name' set to "C" as `c-mode' leaves it:
;; the flags answer and the mode line suffix is built from them.
(let ((b (fresh "int x;\n")))
  (set-buffer-local-value! b 'mode-name "C")
  (c-toggle-auto-newline 1)
  (test-equal "toggle-auto-newline sets the flag" #t (c-auto-newline))
  (test-equal "toggle-auto-newline turns electric on" #t (c-electric-flag))
  (test-equal "the mode line after auto-newline" "C/*la" (buffer-local-value b 'mode-name))
  (c-toggle-hungry-state 1)
  (test-equal "toggle-hungry-state sets the flag" #t (c-hungry-delete-key))
  (test-equal "the mode line after hungry" "C/*lah" (buffer-local-value b 'mode-name))
  (c-toggle-electric-state -1)
  (test-equal "toggle-electric-state clears the flag" #f (c-electric-flag))
  (test-equal "the mode line after electric off" "C/*h" (buffer-local-value b 'mode-name))
  (c-toggle-syntactic-indentation -1)
  (test-equal "toggle-syntactic-indentation clears the flag" #f (c-syntactic-indentation)))

;;--------------------------------------------------------------
;; `c-toggle-comment-style'
;;--------------------------------------------------------------
;; Emacs, measured: block is "/* " and " */", line is "// " and "".
;; The *initial* value comes from `c-basic-common-init' (cc-mode.el,
;; not ported), so the test sets the flag the way that init would.
(let ((b (fresh "int x;\n")))
  (set-buffer-local-value! b 'c-block-comment-flag #t)
  (c-toggle-comment-style 1)
  (test-equal "block comment start" "/* " (comment-start))
  (test-equal "block comment end" " */" (comment-end))
  (c-toggle-comment-style -1)
  (test-equal "line comment start" "// " (comment-start))
  (test-equal "line comment end" "" (comment-end))
  (test-equal "the flag follows the toggle" #f (c-block-comment-flag)))

;;--------------------------------------------------------------
;; `c-syntactic-information-on-region'
;;--------------------------------------------------------------
;; Emacs, measured: each line gets a comment at `comment-column' (32),
;; tab-filled by `indent-for-comment', holding the printed analysis.
(let ((b (fresh "int x;\nint y;\n")))
  (c-syntactic-information-on-region (point-min) (point-max))
  (test-equal "c-syntactic-information-on-region writes the analyses"
              "int x;\t\t\t\t/* ((topmost-intro 1)) */\nint y;\t\t\t\t/* ((topmost-intro 1)) */\n"
              (contents)))

;;--------------------------------------------------------------
;; `c-run-special-indent-hook'
;;--------------------------------------------------------------
;; Emacs, measured: with the gnu style and the block's offset forced to
;; 0, `c-indent-line' answers 0 (the shift it computed) and
;; `c-gnu-impose-minimum' - the hook entry the style installs, a
;; *symbol* in the hook list - adds the one-space minimum afterwards.
;; This is what the runner's symbol resolution is for.
(let ((b (fresh "int f (void)\n{\nint x;\n}\n")))
  (c-set-offset 'defun-block-intro 0)
  (goto-char (point-min))
  (forward-line 2)
  (test-equal "c-indent-line's return with the hook" 0 (c-indent-line))
  (test-equal "c-gnu-impose-minimum ran through the hook runner"
              "int f (void)\n{\n int x;\n}\n"
              (contents)))

(test-end "schemacs_editor_cc_cmds")


;;--------------------------------------------------------------
;; The defun movements (`cc-cmds.el:1569'-`:2426')
;;--------------------------------------------------------------
;; Every row was measured from `tools/cc-cmds-diff/emacs-defuns.el'
;; on the same text in a real `c-mode' buffer; the whole-position
;; differential over that fixture and `fixture-knr.c' is identical.
;; Each probe builds a fresh buffer, as the harness does, because the
;; caches are per buffer.
(test-begin "schemacs_editor_cc_cmds_defuns")

(define defun-text
  (string-append
   "struct S { int a; } gvar;\n"
   "static int f(void) { return 1; }\n"
   "int g(int a)\n"
   "{\n"
   "  if (a > 0)\n"
   "    {\n"
   "      return a;\n"
   "    }\n"
   "  return 0;\n"
   "}\n"))

(define (defun-row pos)
  (fresh defun-text)
  (goto-char pos)
  (list (c-where-wrt-brace-construct)
        (c-in-function-trailer-p)
        (c-defun-name)
        (c-cpp-define-name)
        (c-declaration-limits #f)
        (c-declaration-limits #t)
        (c-defun-name-and-limits #f)))

(define (defun-move pos thunk)
  (fresh defun-text)
  (save-excursion
    (goto-char pos)
    (let ((ret (thunk)))
      (cons (point) ret))))

(define (row pos)
  (list (defun-row pos)
        (defun-move pos (lambda () (c-beginning-of-defun)))
        (defun-move pos (lambda () (c-end-of-defun)))))

(test-equal "at the struct's header, position 1"
  (list (list 'at-header #f "gvar" #f '(1 . 27) '(1 . 27)
              (cons "gvar" (cons 1 27)))
        (cons 1 #f) (cons 27 #t))
  (row 1))

(test-equal "inside the struct's brace block, position 11"
  (list (list 'in-block #f "gvar" #f '(1 . 27) #f
              (cons "gvar" (cons 1 27)))
        (cons 1 #t) (cons 27 #t))
  (row 11))

(test-equal "in the struct's trailer, position 20"
  (list (list 'in-trailer 1 "gvar" #f '(1 . 27) '(1 . 27)
              (cons "gvar" (cons 1 27)))
        (cons 1 #t) (cons 27 #t))
  (row 20))

(test-equal "just after the struct, position 26"
  (list (list 'at-function-end #f #f #f #f '(27 . 60) #f)
        (cons 1 #t) (cons 60 #t))
  (row 26))

(test-equal "at the one-line function's header, position 27"
  (list (list 'at-header #f "f" #f '(27 . 60) '(27 . 60)
              (cons "f" (cons 27 60)))
        (cons 1 #t) (cons 60 #t))
  (row 27))

(test-equal "at the end of the one-line function, position 59"
  (list (list 'at-function-end #f #f #f #f '(60 . 130) #f)
        (cons 27 #t) (cons 130 #t))
  (row 59))

(test-equal "at g's header, position 60"
  (list (list 'at-header #f "g" #f '(60 . 130) '(60 . 130)
              (cons "g" (cons 60 130)))
        (cons 27 #t) (cons 130 #t))
  (row 60))

(test-equal "in g's header, position 61"
  (list (list 'in-header #f "g" #f '(60 . 130) '(60 . 130)
              (cons "g" (cons 60 130)))
        (cons 60 #t) (cons 130 #t))
  (row 61))

(test-equal "at the end of g, position 129"
  (list (list 'at-function-end #f #f #f #f #f #f)
        (cons 60 #t) (cons 130 #f))
  (row 129))

;; `c-indent-defun': Emacs 31.1's answer for this text (measured through
;; `tools/cc-cmds-diff/emacs-defuns.el' on `fixture-indent.c'), and the
;; whole-position differential over that fixture is identical.
(test-equal "c-indent-defun reindents the declaration"
  (list "int g(int a)\n{\n  if (a > 0)\n    {\n      return a;\n    }\n  return 0;\n}\n"
        1)
  (let ((b (fresh (string-append
                   "int g(int a)\n"
                   "{\n"
                   "if (a > 0)\n"
                   "{\n"
                   "return a;\n"
                   "}\n"
                   "  return 0;\n"
                   "}\n"))))
    (goto-char 1)
    (c-indent-defun)
    (list (contents) (point))))

(test-end "schemacs_editor_cc_cmds_defuns")


;;--------------------------------------------------------------
;; Movement by statements, sentences and conditionals
;;--------------------------------------------------------------
;; Rows measured with `tools/cc-cmds-diff/emacs-stmt.el' on the same
;; text in a real `c-mode' buffer; the whole-position differential is
;; identical on seven fixtures in both languages.
(test-begin "schemacs_editor_cc_cmds_statements")

(define stmt-text
  (string-append
   "#include <stdio.h>\n"
   "/* A block comment. It has two sentences.\n"
   "   Another sentence here.  */\n"
   "static int g (int a)\n"
   "{\n"
   "  // A line comment. With a sentence.\n"
   "  const char *s = \"A string. With two sentences. \\\n"
   "continued here.\";\n"
   "#if FOO\n"
   "  if (a) { return 1; }\n"
   "#else\n"
   "  a = 2; // done\n"
   "#endif\n"
   "  switch (a) {\n"
   "  case 1: a++; break;\n"
   "  default: a--;\n"
   "  }\n"
   "  return a;\n"
   "}\n"))

(define (stmt-mv pos thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (save-excursion
      (goto-char pos)
      (let ((ret (thunk)))
        (list (point) ret)))))

(define (stmt-lit-probe pos pred thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (save-excursion
      (goto-char pos)
      (let ((range (c-literal-limits)))
        (if (and (pair? range) (pred (c-literal-type range)))
            (let ((ret (thunk range)))
              (list (point) ret))
            #f)))))

(define (stmt-row pos)
  (fresh stmt-text)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (list (stmt-mv pos (lambda () (c-beginning-of-statement 1 #f #f)))
          (stmt-mv pos (lambda () (c-beginning-of-statement 1 #f #t)))
          (stmt-mv pos (lambda () (c-end-of-statement 1 #f #f)))
          (stmt-mv pos (lambda () (c-end-of-statement 1 #f #t)))
          (stmt-mv pos (lambda ()
                         (c-back-over-illiterals
                          (save-excursion
                            (and (not (bobp)) (c-beginning-of-macro)
                                 (point))))))
          (stmt-mv pos (lambda ()
                         (c-forward-over-illiterals
                          (save-excursion
                            (and (not (eobp)) (c-beginning-of-macro)
                                 (begin (c-end-of-macro) (point))))
                          #f)))
          (stmt-mv pos (lambda () (c-ascertain-preceding-literal)))
          (stmt-mv pos (lambda () (c-ascertain-following-literal)))
          (stmt-mv pos (lambda () (c-comment-indent)))
          (stmt-mv pos (lambda () (c-outline-level)))
          (stmt-mv pos (lambda () (c-in-comment-line-prefix-p)))
          (stmt-lit-probe pos (lambda (ty) (memq ty '(c c++)))
                          (lambda (r) (c-beginning-of-sentence-in-comment r)))
          (stmt-lit-probe pos (lambda (ty) (memq ty '(c c++)))
                          (lambda (r) (c-end-of-sentence-in-comment r))))))

(test-equal "at the #include, position 1"
  (list (list 1 #f) (list 1 #f) (list 19 #f) (list 19 #f)
        (list 1 (list #f))
        (list 19 (cons #f 'macro-boundary))
        (list 1 #f) (list 1 #f) (list 1 32) (list 1 0) (list 1 #f)
        #f #f)
  (stmt-row 1))

(test-equal "inside the block comment, position 21"
  (list (list 20 #f) (list 1 #f) (list 112 #f) (list 61 #f)
        (list 20 (cons #t 'macro-boundary))
        (list 112 (list #f))
        (list 21 #f) (list 21 #f) (list 21 0) (list 21 1) (list 21 #f)
        (list 20 #t) (list 61 #f))
  (stmt-row 21))

(test-equal "mid-comment, position 65"
  (list (list 20 #f) (list 23 #f) (list 112 #f) (list 87 #f)
        (list 20 (cons #t 'macro-boundary))
        (list 112 (list #f))
        (list 65 #f) (list 65 #f) (list 65 0) (list 65 3) (list 65 #f)
        (list 23 #f) (list 87 #f))
  (stmt-row 65))

(test-equal "at the comment's end, position 87"
  (list (list 20 #f) (list 65 #f) (list 112 #f) (list 112 #f)
        (list 20 (cons #t 'macro-boundary))
        (list 112 (list #f))
        (list 87 #f) (list 87 #f) (list 87 0) (list 87 27) (list 87 #f)
        (list 65 #f) (list 91 #t))
  (stmt-row 87))

(test-equal "on the line comment, position 115"
  (list (list 113 #f) (list 113 #f) (list 221 #f) (list 152 #f)
        (list 113 (list #f))
        (list 115 (cons #t 'literal))
        (list 115 #f) (list 115 (cons 117 153))
        (list 115 32) (list 115 2) (list 115 #t)
        #f #f)
  (stmt-row 115))

(test-equal "at #else, position 255"
  (list (list 253 #f) (list 253 #f) (list 258 #f) (list 258 #f)
        (list 253 (cons #f 'macro-boundary))
        (list 258 (cons #f 'macro-boundary))
        (list 255 #f) (list 255 #f) (list 255 7) (list 255 2) (list 255 #f)
        #f #f)
  (stmt-row 255))

(test-equal "at return a, position 350"
  (list (list 342 #f) (list 342 #f) (list 351 #f) (list 351 #f)
        (list 342 (list #f))
        (list 351 (list #f))
        (list 350 #f) (list 350 #f) (list 350 32) (list 350 10) (list 350 #f)
        #f #f)
  (stmt-row 350))

(define (stmt-scan pos . args)
  (fresh stmt-text)
  (goto-char pos)
  (guard (e (else 'error))
    (apply c-scan-conditionals args)))

(test-equal "conditional scan forward from 1" 283 (stmt-scan 1 1))
(test-equal "conditional scan backward from 283" 222 (stmt-scan 283 -1))
(test-equal "conditional scan forward from inside #if" 'error (stmt-scan 230 1))
(test-equal "conditional scan backward from 230" 'error (stmt-scan 230 -1))
(test-equal "conditional scan with target depth" 'error (stmt-scan 1 1 -1))
(test-equal "conditional scan with-else" 283 (stmt-scan 1 1 #f #t))

(test-end "schemacs_editor_cc_cmds_statements")

;;--------------------------------------------------------------
;; The filling half
;;--------------------------------------------------------------
;; Every expectation is Emacs 31.1's answer for the same text and
;; point, measured with `emacs -Q --batch' (`/tmp/measure-fill.el').
;; The mode replay sets `comment-multi-line' t around the commands, as
;; `c-basic-common-init' does for the real mode.
(test-begin "schemacs_editor_cc_cmds_filling")

(define (filling-case text pos thunk)
  (fresh text)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode)
                 (*comment-multi-line* #t))
    (goto-char pos)
    (let ((ret (thunk)))
      (list ret (point) (contents)))))

(let* ((text "int a;\n\n/* This is a long block comment which should be filled when point is inside it, because it is wider than seventy characters. */\nint b;\n")
       (r (filling-case text 60 (lambda () (c-fill-paragraph #f)))))
  (test-equal "c-fill-paragraph fills a block comment" #t (car r))
  (test-equal "c-fill-paragraph leaves point where it was" 60 (cadr r))
  (test-equal "c-fill-paragraph block comment text"
              "int a;\n\n/* This is a long block comment which should be filled when point is\n   inside it, because it is wider than seventy characters. */\nint b;\n"
              (caddr r)))

(let* ((text "int a; // a line comment which is long enough that filling it will wrap the text onto another line and keep the prefix\nint b;\n")
       (r (filling-case text 30 (lambda () (c-fill-paragraph #f)))))
  (test-equal "c-fill-paragraph fills a line comment" #t (car r))
  (test-equal "c-fill-paragraph line comment text"
              "int a; // a line comment which is long enough that filling it will\n       // wrap the text onto another line and keep the prefix\nint b;\n"
              (caddr r)))

(let* ((text "int a;\nint b;\n")
       (r (filling-case text 5 (lambda () (c-fill-paragraph #f)))))
  (test-equal "c-fill-paragraph answers t in code" #t (car r))
  (test-equal "c-fill-paragraph leaves code alone" text (caddr r)))

(let* ((text "char *s = \"a long string literal which should be filled when point is inside it, because it is wider than seventy\";\n")
       (r (filling-case text 20 (lambda () (c-fill-paragraph #f)))))
  (test-equal "c-fill-paragraph fills a string"
              "char *s = \"a long string literal which should be filled when point is inside it,\nbecause it is wider than seventy\";\n"
              (caddr r)))

(let* ((text "int a;\nint b; // line comment here\nint c;\n")
       (r (filling-case text 30 (lambda () (c-indent-new-comment-line)))))
  (test-equal "c-indent-new-comment-line continues a line comment" #f (car r))
  (test-equal "c-indent-new-comment-line line comment text"
              "int a;\nint b; // line comment\n       // here\nint c;\n"
              (caddr r)))

(let* ((text "/* block comment text here */\nint a;\n")
       (r (filling-case text 10 (lambda () (c-indent-new-comment-line)))))
  (test-equal "c-indent-new-comment-line breaks a block comment" #f (car r))
  (test-equal "c-indent-new-comment-line block comment text"
              "/* block\n   comment text here */\nint a;\n"
              (caddr r)))

(let* ((text "int x = 1; int y;\n")
       (r (filling-case text 11 (lambda () (c-indent-new-comment-line)))))
  (test-equal "c-indent-new-comment-line answers the indentation in code" 0 (car r))
  (test-equal "c-indent-new-comment-line in code text"
              "int x = 1;\nint y;\n" (caddr r)))

(let* ((text "int x = 1; int y;\n")
       (r (filling-case text 11 (lambda () (c-context-line-break)))))
  (test-equal "c-context-line-break answers the indentation in code" 0 (car r))
  (test-equal "c-context-line-break in code text"
              "int x = 1;\nint y;\n" (caddr r)))

(let* ((text "int a;\nint b; // line comment here\nint c;\n")
       (r (filling-case text 30 (lambda () (c-context-line-break)))))
  (test-equal "c-context-line-break in a line comment" #f (car r))
  (test-equal "c-context-line-break in a line comment text"
              "int a;\nint b; // line comment\n       // here\nint c;\n"
              (caddr r)))

(let* ((text "/* block comment text */\nint a;\n")
       (r (filling-case text 10 (lambda () (c-context-line-break)))))
  (test-equal "c-context-line-break in a block comment" #f (car r))
  (test-equal "c-context-line-break in a block comment text"
              "/* block\n   comment text */\nint a;\n" (caddr r)))

(let* ((text "char *s = \"some string text\";\n")
       (r (filling-case text 20 (lambda () (c-context-line-break)))))
  (test-equal "c-context-line-break in a string" #f (car r))
  (test-equal "c-context-line-break in a string text"
              "char *s = \"some str\ning text\";\n" (caddr r)))

(let* ((text "int x = 1; int y;\n")
       (r (filling-case text 11 (lambda () (c-context-open-line)))))
  (test-equal "c-context-open-line answers the indentation in code" 0 (car r))
  (test-equal "c-context-open-line leaves point before the new line" 11 (cadr r))
  (test-equal "c-context-open-line in code text"
              "int x = 1;\nint y;\n" (caddr r)))

(let* ((text "int a; // comment here\n")
       (r (filling-case text 20 (lambda () (c-context-open-line)))))
  (test-equal "c-context-open-line in a comment" #f (car r))
  (test-equal "c-context-open-line in a comment text"
              "int a; // comment h\n       // ere\n" (caddr r)))

;; The macro-start cache: `c-query-and-set-macro-start' must answer the
;; position on *every* call, and nil outside a macro. A parameter's
;; setter answers the OLD value (measured), so the port's write and
;; answer are two steps; the second call is what catches a one-step
;; translation, and `(symbolp nil)' is true in Elisp, so the nil case
;; must be recomputed rather than returned.
(let* ((text "#define M(x) do { x; } while (0)\nint a;\n")
       (b (fresh text)))
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (goto-char 20)
    (test-equal "c-query-and-set-macro-start answers the macro start"
                1 (c-query-and-set-macro-start))
    (goto-char 20)
    (test-equal "c-query-and-set-macro-start answers it again"
                1 (c-query-and-set-macro-start))
    (goto-char 1)
    (test-equal "c-query-and-set-macro-start at the macro's first line"
                1 (c-query-and-set-macro-start))))

(let* ((text "int a;\n")
       (b (fresh text)))
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode)
                 (*c-macro-start* 'unknown))
    (test-equal "c-query-and-set-macro-start is nil in plain code"
                #f (c-query-and-set-macro-start))))

;; Elisp's `(symbolp nil)' is true, so a cache left NIL is recomputed
;; when point comes to a macro. The one-line translation - `(symbol?)'
;; - answers the stale nil instead; this is that case.
(let* ((text "#define M(x) do { x; } while (0)\nint a;\n")
       (b (fresh text)))
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode)
                 (*c-macro-start* #f))
    (goto-char 20)
    (test-equal "c-query-and-set-macro-start recomputes from a nil cache"
                1 (c-query-and-set-macro-start))))

(test-end "schemacs_editor_cc_cmds_filling")

;;--------------------------------------------------------------
;; The electric keys (`cc-cmds.el:409'-`:1568'')
;;--------------------------------------------------------------
;; Every expectation is `tools/cc-electric-diff''s Emacs side: the same
;; command in `emacs -Q --batch' on the same text, key and flags. The
;; one scenario that disagrees (`brace-elseif') is not pinned here - see
;; that directory's README.
(test-begin "schemacs_editor_cc_cmds_electric")

(define (run-electric text command key arg auto cleanups hungry)
  (fresh text)
  (set!c-electric-flag #t)
  (set!c-syntactic-indentation #t)
  (set!c-auto-newline auto)
  (set!c-hungry-delete-key hungry)
  (if cleanups (set!c-cleanup-list cleanups))
  (goto-char (point-max))
  ;; `c-query-and-set-macro-start' writes this parameter (a `set', not a
  ;; `parameterize'), and the macro-start tests above have left a
  ;; position in it; an electric command that calls
  ;; `c-newline-and-indent' would then think it is inside a macro and
  ;; align backslashes.
  (parameterize ((*c-macro-start* #f)
                 (*last-command-event* key))
    (cond ((eq? arg 'none) (command))
          ((not arg) (command #f))
          (else (command arg))))
  (list (contents) (point)))

(test-equal "c-electric-brace hangs a defun brace"
            '("void f()\n{\n  " 14)
            (run-electric "void f()\n" c-electric-brace 123 #f #t #f #f))

(test-equal "c-electric-brace with auto-newline off"
            '("void f()\n{" 11)
            (run-electric "void f()\n" c-electric-brace 123 #f #f #f #f))

(test-equal "c-electric-brace hangs a substatement brace"
            '("if (x)\n  {\n    " 16)
            (run-electric "if (x)\n" c-electric-brace 123 #f #t #f #f))

(test-equal "c-electric-brace's numeric ARG suppresses the electrics"
            '("void f()\n{{" 12)
            (run-electric "void f()\n" c-electric-brace 123 2 #t #f #f))

(test-equal "c-electric-brace with c-electric-flag off"
            '("void f()\n{" 11)
            (let ((b (fresh "void f()\n")))
              (set!c-electric-flag #f)
              (set!c-syntactic-indentation #t)
              (set!c-auto-newline #t)
              (goto-char (point-max))
              (parameterize ((*c-macro-start* #f)
                             (*last-command-event* 123))
                (c-electric-brace #f))
              (list (contents) (point))))

(test-equal "c-electric-brace's empty-defun-braces cleanup"
            '("void f() {}\n" 13)
            (run-electric "void f() {\n  " c-electric-brace 125 #f #t
                          '(empty-defun-braces) #f))

(test-equal "c-electric-brace's one-liner-defun cleanup"
            '("void f() {return 1;}\n" 22)
            (run-electric "void f() { return 1;\n" c-electric-brace 125 #f #t
                          '(one-liner-defun) #f))

(test-equal "c-electric-brace's one-liner cleanup is undone when too long"
            '("void f() { aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff gggggggggg;\n}\n" 92)
            (run-electric
             "void f() { aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff gggggggggg;\n"
             c-electric-brace 125 #f #t '(one-liner-defun) #f))

(test-equal "c-electric-semi&comma inserts a newline"
            '("int x = 1;\n" 12)
            (run-electric "int x = 1" c-electric-semi&comma 59 #f #t #f #f))

(test-equal "c-electric-semi&comma adds none inside a paren list"
            '("for (i = 0; i < n;" 19)
            (run-electric "for (i = 0; i < n" c-electric-semi&comma 59 #f #t #f #f))

(test-equal "c-electric-semi&comma's list-close-comma cleanup"
            '("int a[] = {1, 2}," 18)
            (run-electric "int a[] = {1, 2}" c-electric-semi&comma 44 #f #t
                          '(list-close-comma) #f))

(test-equal "c-electric-colon's scope-operator cleanup"
            '("A: ::" 6)
            (run-electric "A: :" c-electric-colon 58 #f #t #f #f))

(test-equal "c-electric-slash in a line comment"
            '("int x; ///" 11)
            (run-electric "int x; //" c-electric-slash 47 #f #t #f #f))

(test-equal "c-electric-star after a slash indents a comment-only line"
            '("/*" 3)
            (run-electric "  /" c-electric-star 42 #f #t #f #f))

(test-equal "c-electric-pound aligns at the left edge"
            '("#" 2)
            (parameterize ((*c-electric-pound-behavior* '(alignleft)))
              (run-electric "    " c-electric-pound 35 #f #t #f #f)))

(test-equal "c-electric-paren's space-before-funcall cleanup"
            '("foo (" 6)
            (run-electric "foo" c-electric-paren 40 #f #t
                          '(space-before-funcall) #f))

(test-equal "c-electric-paren's compact-empty-funcall cleanup"
            '("foo()" 6)
            (run-electric "foo(" c-electric-paren 41 #f #t
                          '(compact-empty-funcall) #f))

(test-equal "c-electric-backspace with c-hungry-delete-key"
            '("int x;" 7)
            (run-electric "int x;   " c-electric-backspace 127 #f #t #f #t))

(test-equal "c-hungry-delete-backwards"
            '("int x;" 7)
            (run-electric "int x; \t " c-hungry-delete-backwards 127 'none #t #f #t))

(test-equal "c-electric-continued-statement reindents an else"
            '("if (x)\n  y;\n else" 18)
            (run-electric "if (x)\n  y;\nelse" c-electric-continued-statement
                          101 'none #t #f #f))

(test-equal "c-electric-lt-gt on an include delimiter"
            '("#include <" 11)
            (run-electric "#include " c-electric-lt-gt 60 #f #t #f #f))

(test-end "schemacs_editor_cc_cmds_electric")

;;----------------------------------------------------------------------
;; Text conversion support (`cc-cmds.el:5152')
;;----------------------------------------------------------------------
;; `c-post-text-conversion' deletes the character the text-conversion
;; machinery has just inserted and re-inserts it electrically. Every
;; expectation is Emacs 31.1's own (`/tmp/ptc.el` measured the four
;; rows on the same text).
(test-begin "schemacs_editor_cc_cmds_text_conversion")

(define (run-ptc text inserted ev)
  (fresh text)
  (set!c-electric-flag #t)
  (set!c-syntactic-indentation #t)
  (set!c-auto-newline #f)
  (set!c-hungry-delete-key #f)
  (goto-char (point-max))
  (insert inserted)
  (let ((result #f))
    (parameterize ((*c-macro-start* #f)
                   (*last-command-event* ev))
      (set! result (c-post-text-conversion)))
    (list (contents) (point) result)))

(test-equal "an inserted brace is taken back and inserted electrically"
            '("int f(){" 9 #t)
            (run-ptc "int f()" "{" 123))

(test-equal "an ordinary character is left alone"
            '("int f()x" 9 #f)
            (run-ptc "int f()" "x" 120))

(test-equal "a semicolon goes through c-electric-semi&comma"
            '("int a;" 7 #t)
            (run-ptc "int a" ";" 59))

(test-equal "a star goes through c-electric-star"
            '("int a*" 7 #t)
            (run-ptc "int a" "*" 42))

(test-end "schemacs_editor_cc_cmds_text_conversion")

;; ------------------------------------------------------------------
;; The `electric-pair-mode' blocks and the blink courtesy
;;
;; `cc-cmds.el` emulates `electric-pair-mode` around the insert
;; (`:911`, `:1288`, `:1373`, `:1420`) and calls
;; `blink-paren-function` itself after the insert. Every answer here is
;; Emacs 31.1's, measured with `emacs -Q --batch` on the same fixture in
;; a real `c-mode` buffer, with the mode enabled or disabled explicitly
;; per row. The blink call is exercised only for effect - it messages
;; and does not edit, so the buffer text is the assertion - and is what
;; the tree's `pos-visible-in-window-p` no-frame answer keeps from
;; erroring in a headless suite.

(test-begin "schemacs_editor_cc_cmds_electric_pair")

(define (pair-run text pos command key on auto)
  (fresh text)
  ;; The same fresh state `run-electric' sets: an earlier test may have
  ;; turned the electric flag or syntactic indentation off, and the
  ;; macro-start parameter is a `set', not a `parameterize', so a
  ;; previous macro test can leave a position in it.
  (set!c-electric-flag #t)
  (set!c-syntactic-indentation #t)
  (set!c-auto-newline (if auto #t #f))
  (set!c-hungry-delete-key #f)
  (electric-pair-mode (if on 1 -1))
  (goto-char pos)
  (parameterize ((*c-macro-start* #f)
                 (*last-command-event* (char->integer key)))
    (command #f))
  (list (contents) (point)))

(test-equal "an empty buffer gets a brace pair" '("{}" 2)
            (pair-run "" 1 c-electric-brace #\{ #t #f))
(test-equal "without the mode, only the brace" '("{" 2)
            (pair-run "" 1 c-electric-brace #\{ #f #f))
(test-equal "a defun's brace is paired" '("int f()\n{}" 10)
            (pair-run "int f()\n" 9 c-electric-brace #\{ #t #f))
(test-equal "without the mode, only the brace after a defun"
            '("int f()\n{" 10)
            (pair-run "int f()\n" 9 c-electric-brace #\{ #f #f))
(test-equal "auto-newline opens the paired brace" '("int f()\n{\n  \n}" 13)
            (pair-run "int f()\n" 9 c-electric-brace #\{ #t #t))
(test-equal "auto-newline without the pair" '("int f()\n{\n  " 13)
            (pair-run "int f()\n" 9 c-electric-brace #\{ #f #t))
(test-equal "a paren after a word is paired" '("foo()" 5)
            (pair-run "foo" 4 c-electric-paren #\( #t #f))
(test-equal "without the mode, only the paren" '("foo(" 5)
            (pair-run "foo" 4 c-electric-paren #\( #f #f))
;; The else branch: the insert is inside a comment or a string, so the
;; mode's own call is the only pairing (cc-cmds.el:1420).
(test-equal "a paren inside a comment is paired" '("/* ()" 5)
            (pair-run "/* " 4 c-electric-paren #\( #t #f))
(test-equal "a paren inside a comment, mode off" '("/* (" 5)
            (pair-run "/* " 4 c-electric-paren #\( #f #f))
(test-equal "a paren inside a string is paired" '("\"ab()" 5)
            (pair-run "\"ab" 4 c-electric-paren #\( #t #f))
;; Skipping the auto-inserted closer.
(test-equal "a close paren skips its pair" '("()" 3)
            (pair-run "()" 2 c-electric-paren #\) #t #f))
(test-equal "without the mode, the close paren is inserted" '("())" 3)
            (pair-run "()" 2 c-electric-paren #\) #f #f))
(test-equal "a close brace skips its pair" '("{}" 3)
            (pair-run "{}" 2 c-electric-paren #\} #t #f))

;; The blink courtesy: after a `}` the brace command calls the
;; `blink-paren-function` it saved before the insert
;; (cc-cmds.el:938-945); after a `)` the paren command does the same
;; (`:1416-1418`). Neither is Emacs's post-self-insert hook - the
;; command suppresses that - it is the explicit call.
(let ((called #f))
  (fresh "void f()\n{\n")
  (set!c-electric-flag #t)
  (set!c-syntactic-indentation #t)
  (set!c-auto-newline #f)
  (goto-char (point-max))
  (parameterize ((*blink-paren-function* (lambda () (set! called #t)))
                 (*c-macro-start* #f)
                 (*last-command-event* (char->integer #\})))
    (c-electric-brace #f))
  (test-assert "c-electric-brace blinks the paren after a close brace" called))
(let ((called #f))
  (fresh "foo(")
  (set!c-electric-flag #t)
  (set!c-syntactic-indentation #t)
  (set!c-auto-newline #f)
  (goto-char (point-max))
  (parameterize ((*blink-paren-function* (lambda () (set! called #t)))
                 (*c-macro-start* #f)
                 (*last-command-event* (char->integer #\))))
    (c-electric-paren #f))
  (test-assert "c-electric-paren blinks the paren after a close paren" called))

(electric-pair-mode -1)

(test-end "schemacs_editor_cc_cmds_electric_pair")

;;--------------------------------------------------------------
;; `c-backward-into-nomenclature' (`cc-cmds.el:1569') and the `w'
;; flag `c-update-modeline` reads from `subword-mode`'s variable.
;;--------------------------------------------------------------
;; Emacs 31.1, measured in a real `c-mode' buffer: the base mode line
;; is "C/*l", `subword-mode` adds "w" ("C/*lw"), and
;; `c-backward-into-nomenclature` from 7 on "fooBarBaz" lands at 4.
(let ((b (fresh "fooBarBaz")))
  (set-buffer-local-value! b 'mode-name "C")
  (c-update-modeline)
  (test-equal "the mode line before subword-mode" "C/*l"
              (buffer-local-value b 'mode-name))
  (subword-mode 1)
  (c-update-modeline)
  (test-equal "and after it, with the w flag" "C/*lw"
              (buffer-local-value b 'mode-name))
  (goto-char 7)
  (test-equal "c-backward-into-nomenclature moves back one subword"
              '(4 4)
              (list (c-backward-into-nomenclature 1) (point))))
