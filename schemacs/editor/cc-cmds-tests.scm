;; Tests for `(schemacs editor cc-cmds)' - the indentation command
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
 (only (schemacs editor buffer) allocate-buffer set-buffer current-buffer
       buffer-local-value set-buffer-local-value!)
 (only (schemacs editor editfns) insert goto-char point point-min point-max
       forward-line buffer-substring line-beginning-position)
 (only (schemacs editor cmds) end-of-line)
 (only (schemacs editor syntax) set-syntax-table)
 (only (schemacs editor cc-defs) c-lang-const *c-buffer-is-cc-mode*)
 (schemacs editor cc-langs)
 (only (schemacs editor cc-vars)
       c-syntactic-indentation set!c-syntactic-indentation
       c-block-comment-flag
       *c-tab-always-indent*)
 (only (schemacs editor cc-styles) c-set-style c-set-offset)
 (only (schemacs editor cc-engine)
       c-parsing-error c-electric-flag c-auto-newline c-hungry-delete-key)
 ;; The line-up registry `c-run-special-indent-hook' resolves the
 ;; style's `c-gnu-impose-minimum' through is filled when this loads.
 (schemacs editor cc-align)
 (only (schemacs editor cc-cmds)
       c-indent-line c-newline-and-indent c-indent-command c-indent-exp
       c-backslash-region c-update-modeline
       c-toggle-auto-newline c-toggle-hungry-state c-toggle-electric-state
       c-toggle-syntactic-indentation c-toggle-comment-style
       c-syntactic-information-on-region *c-fix-backslashes*)
 (only (schemacs editor newcomment) comment-start comment-end))

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
      (c-set-style "gnu"))
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
