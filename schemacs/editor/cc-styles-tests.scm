;; Tests for `(schemacs editor cc-styles)', the style system of
;; `cc-styles.el'. Every expectation is Emacs 31.1's own answer,
;; measured with `emacs -Q --batch' in a real `c-mode' buffer (the
;; mode's init is replayed by hand here: `c-init-language-vars' and
;; `*c-buffer-is-cc-mode*', as `cc-fonts-tests' does until
;; `cc-mode.el' lands).
;;
;; The groups run in this order because the style system is global
;; state: the data group must see the virgin `c-style-alist', and the
;; group that adds and replaces styles runs last.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (guile) list-head)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) allocate-buffer set-buffer
       set-buffer-local-value! buffer-fill-column)
 (only (schemacs editor fill) fill-column adaptive-fill-mode
       adaptive-fill-regexp adaptive-fill-first-line-regexp)
 (only (schemacs editor indentc) *indent-tabs-mode*)
 (only (schemacs editor paragraphs)
       paragraph-start paragraph-separate paragraph-ignore-fill-prefix
       *page-delimiter*)
 (only (schemacs editor cc-defs) *c-buffer-is-cc-mode*)
 ;; Wholesale: `c-init-language-vars' expands into `cc-langs'
 ;; internals (`c-lang-set-local!' and friends), and a macro's output
 ;; resolves in the module that calls it.
 (schemacs editor cc-langs)
 (schemacs editor cc-vars)
 (schemacs editor cc-styles))

(define (style-vars name)
  (cdr (assoc name c-style-alist)))

(define (style-value name symbol)
  (cdr (assq symbol (style-vars name))))

;;----------------------------------------------------------------------
;; The data: the ten built-in styles and the registry
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_data")

(c-initialize-builtin-style)
(test-equal "the style list starts with the two generated styles"
            '("cc-mode" "user" "gnu" "k&r" "bsd" "stroustrup"
              "whitesmith" "ellemtel" "linux" "python" "java" "awk")
            (map car c-style-alist))

(test-equal "gnu indents by 2" 2 (style-value "gnu" 'c-basic-offset))
(test-equal "k&r indents by 5" 5 (style-value "k&r" 'c-basic-offset))
(test-equal "bsd indents by 8" 8 (style-value "bsd" 'c-basic-offset))
(test-equal "stroustrup indents by 4" 4
            (style-value "stroustrup" 'c-basic-offset))
(test-equal "whitesmith indents by 4" 4
            (style-value "whitesmith" 'c-basic-offset))
(test-equal "ellemtel indents by 3" 3
            (style-value "ellemtel" 'c-basic-offset))
(test-equal "linux sets indent-tabs-mode" #t
            (style-value "linux" 'indent-tabs-mode))
(test-equal "linux indents by 8" 8 (style-value "linux" 'c-basic-offset))
(test-equal "linux's cleanup list is brace-else-brace"
            '(brace-else-brace)
            (style-value "linux" 'c-cleanup-list))
(test-equal "python sets fill-column to 78" 78
            (style-value "python" 'fill-column))
(test-equal "python's block comment prefix is empty" ""
            (style-value "python" 'c-block-comment-prefix))
(test-equal "java indents by 4" 4 (style-value "java" 'c-basic-offset))
(test-equal "java aligns access labels at 0" 0
            (cdr (assq 'access-label
                       (style-value "java" 'c-offsets-alist))))
(test-equal "awk indents by 4" 4 (style-value "awk" 'c-basic-offset))
(test-equal "gnu names c-gnu-impose-minimum as a hook"
            'c-gnu-impose-minimum
            (style-value "gnu" 'c-special-indent-hook))

;; "Only do this once!"
(c-initialize-builtin-style)
(test-equal "a second initialisation changes nothing" 12
            (length c-style-alist))

(test-equal "there are sixteen style variables" 16
            (length c-style-variables))
(test-equal "they begin as cc-defs lists them"
            '(c-basic-offset c-comment-only-line-offset c-indent-comment-alist
              c-indent-comments-syntactically-p c-block-comment-prefix
              c-comment-prefix-regexp)
            (list-head c-style-variables 6))

(test-end "schemacs_editor_cc_styles_data")

;;----------------------------------------------------------------------
;; Resolving a style's variables (`c-get-style-variables')
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_get")

;; The fallback alist is merged in front of a base-less style, so the
;; *first* binding of a name wins - Emacs answers 4 here and applies 2
;; after `c-set-style' (see the next group). That duplicate is Emacs's
;; own, not a transcription slip.
(test-equal "a base-less style shows the fallback's binding first"
            '(c-basic-offset . 4)
            (assq 'c-basic-offset (c-get-style-variables "gnu" '())))
(test-equal "the fallback alist alone answers the same" 4
            (cdr (assq 'c-basic-offset (c-get-style-variables #f '()))))
(test-equal "style names are matched case-insensitively"
            '(c-basic-offset . 4)
            (assq 'c-basic-offset (c-get-style-variables "K&R" '())))
;; An undefined style reports "Undefined style: ..." and resolves to the
;; fallback alone, as Emacs's `c-benign-error' path does.
(test-equal "an undefined style resolves to the fallback"
            '(c-basic-offset . 4)
            (assq 'c-basic-offset (c-get-style-variables "nonesuch" '())))

(test-end "schemacs_editor_cc_styles_get")

;;----------------------------------------------------------------------
;; Choosing a style for a mode (`cc-choose-style-for-mode')
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_choose")

(test-equal "a string is the answer" "gnu"
            (cc-choose-style-for-mode 'c-mode "gnu"))
(test-equal "an alist entry for the mode wins" "linux"
            (cc-choose-style-for-mode
             'c-mode '((c-mode . "linux") (other . "bsd"))))
(test-equal "another mode takes the other entry" "bsd"
            (cc-choose-style-for-mode
             'java-mode '((c-mode . "linux") (other . "bsd"))))
(test-equal "a mode with no entry and no other falls back to gnu" "gnu"
            (cc-choose-style-for-mode 'java-mode '((c-mode . "linux"))))

(test-end "schemacs_editor_cc_styles_choose")

;;----------------------------------------------------------------------
;; Applying a style to a buffer
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_apply")

(define (cc-buffer thunk)
  (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (set-buffer-local-value! b 'major-mode 'c-mode)
      (c-init-language-vars c-mode)
      (thunk))))

(cc-buffer
 (lambda ()
   (c-set-style "gnu")
   (test-equal "gnu applies its own c-basic-offset after the fallback" 2
               (c-basic-offset))
   (test-equal "c-indentation-style records the style name" "gnu"
               (c-indentation-style))
   ;; `add-hook' LOCAL starts a fresh local value with `t', the marker
   ;; that says "run the global value too".
   (test-equal "the special indent hook carries add-hook's t marker"
               (list #t 'c-gnu-impose-minimum)
               (c-special-indent-hook))
   (test-equal "the style's statement-block-intro is applied" '+
               (cdr (assq 'statement-block-intro (c-offsets-alist))))
   (test-equal "and its topmost-intro-cont lineup"
               '(first c-lineup-topmost-intro-cont
                       c-lineup-gnu-DEFUN-intro-cont)
               (cdr (assq 'topmost-intro-cont (c-offsets-alist))))
   ;; Every fallback offset is installed too - `cpp-macro's is a vector,
   ;; which is Emacs's own shape for it.
   (test-equal "the fallback offsets are installed as well" #(0)
               (cdr (assq 'cpp-macro (c-offsets-alist))))

   (test-equal "c-set-offset changes an existing entry" 4
               (begin (c-set-offset 'statement-cont 4)
                      (cdr (assq 'statement-cont (c-offsets-alist)))))
   (test-equal "and answers nil" #f (c-set-offset 'statement-cont 4))
   (test-equal "an invalid symbol is not added" #f
               (begin (c-set-offset 'no-such-symbol 3)
                      (assq 'no-such-symbol (c-offsets-alist))))
   (test-equal "the style's hook is not duplicated by a re-apply"
               (list #t 'c-gnu-impose-minimum)
               (begin (c-set-style "gnu")
                      (c-special-indent-hook)))

   (c-set-style "python")
   (test-equal "python applies its basic offset" 8 (c-basic-offset))
   (test-equal "python applies fill-column" 78 (fill-column))
   (test-equal "python turns tabs on" #t (*indent-tabs-mode*))))

;; `c-set-style's DONT-OVERRIDE, measured in a c-mode buffer: t keeps
;; the value already in effect, nil overrides, and `set-from-style'
;; overrides because the variable's default is still `set-from-style'.
(cc-buffer
 (lambda ()
   (c-set-style "gnu")
   (c-set-style "bsd" #t)
   (test-equal "dont-override t keeps the current value" 2
               (c-basic-offset))
   (test-equal "but still records the new style name" "bsd"
               (c-indentation-style))
   (c-set-style "bsd" #f)
   (test-equal "dont-override nil applies the style" 8 (c-basic-offset))))

;; The mode-hook spelling: DONT-OVERRIDE `set-from-style' still applies
;; a style whose default is untouched, which is what makes it useful
;; from a hook - Emacs answers 8 for this same sequence.
(cc-buffer
 (lambda ()
   (c-set-style "gnu")
   (c-set-style "bsd" 'set-from-style)
   (test-equal "dont-override set-from-style applies an unset default" 8
               (c-basic-offset))))

(test-end "schemacs_editor_cc_styles_apply")

;;----------------------------------------------------------------------
;; The paragraph variables (`c-setup-paragraph-variables')
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_paragraph")

(cc-buffer
 (lambda ()
   (c-set-style "gnu")
   (c-setup-paragraph-variables)
   (test-equal "the comment prefix is the language's"
               "//+\\|\\**"
               (c-current-comment-prefix))
   (test-equal "paragraph-ignore-fill-prefix is on" #t
               (paragraph-ignore-fill-prefix))
   (test-equal "adaptive-fill-mode is on" #t (adaptive-fill-mode))
   (test-equal "paragraph-start is the comment prefix plus the language's"
               "[ \t]*\\(//+\\|\\**\\)[ \t]*$\\|^\f"
               (paragraph-start))
   (test-equal "paragraph-separate is the same for C" (paragraph-start)
               (paragraph-separate))
   (test-equal "adaptive-fill-regexp embeds the default with the prefix"
               "[ \t]*\\(//+\\|\\**\\)[ \t]*\\([-–!|#%;>*·•‣⁃◦ \t]*\\)"
               (adaptive-fill-regexp))
   (test-equal "adaptive-fill-first-line-regexp is anchored"
               "\\`[ \t]*\\(//+\\|\\**\\)[ \t]*\\'"
               (adaptive-fill-first-line-regexp))
   (test-equal "c-string-par-start" "\f\\|[ \t]*\\\\?$"
               c-string-par-start)
   (test-equal "c-string-par-separate" "[ \t\f]*\\\\?$"
               c-string-par-separate)
   (test-equal "page-delimiter is Emacs's formfeed" "^\f"
               (*page-delimiter*))))

(test-end "schemacs_editor_cc_styles_paragraph")

;;----------------------------------------------------------------------
;; Adding and replacing styles (`c-add-style') - mutates c-style-alist,
;; so it runs last.
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_styles_add")

(cc-buffer
 (lambda ()
   (c-add-style "foo" '("gnu" (c-basic-offset . 7)))
   (test-equal "a new style is added at the front" "foo"
               (car (car c-style-alist)))
   (c-set-style "foo")
   (test-equal "it inherits the base style's offsets" 7 (c-basic-offset))
   (test-equal "and keeps the base's other settings" '+
               (cdr (assq 'statement-block-intro (c-offsets-alist))))
   (c-add-style "bar" '((c-basic-offset . 9)) #t)
   (test-equal "SET-P applies the new style" (list 9 "bar")
               (list (c-basic-offset) (c-indentation-style)))
   (test-equal "a style with no base keeps its own entry"
               '((c-basic-offset . 9))
               (style-vars "bar"))
   (c-add-style "gnu" '("k&r" (c-basic-offset . 3)) #f)
   (test-equal "an existing style is replaced, not duplicated"
               '("gnu" "k&r" (c-basic-offset . 3))
               (assoc "gnu" c-style-alist))))

(test-end "schemacs_editor_cc_styles_add")
