;; Tests for `(schemacs editor cc-langs)' - the language-variable
;; system ported from `lisp/progmodes/cc-langs.el'. The behaviour the
;; rest of cc-mode leans on: a `c-lang-defvar' becomes a buffer-local
;; value per language (with the constant's fallback chain applied),
;; `c-lang-setvar' does the same for a standard variable, values that
;; are not literal data are evaluated at run time, and a literal value
;; is baked into the generated init function at expansion time.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) allocate-buffer set-buffer current-buffer
       buffer-local-value set-buffer-local-value!)
 (only (schemacs editor cc-defs) c-add-language c-lang-defconst c-lang-const
       c-mode-symbol c-mode-var *c-buffer-is-cc-mode*)
 (schemacs editor cc-langs))

(test-begin "schemacs_editor_cc_langs")

(c-add-language 'cclangs-test-mode 'c-mode)

;; t holds the general value; c-mode, the base of cclangs-test-mode,
;; overrides it - so the test also exercises the fallback chain.
(c-lang-defconst cclangs-keywords
  t '("if" "else")
  c '("if" "else" "restrict"))

(c-lang-defvar cclangs-keywords-re (c-lang-const cclangs-keywords))
(c-lang-defvar cclangs-prefix "x-")
(c-lang-defvar cclangs-fn (lambda (n) (* n 2)))   ; not literal data
(c-lang-setvar comment-start "; ")

(define (run-init!) (c-init-language-vars cclangs-test-mode))

;;----------------------------------------------------------------------
;; Per-buffer values, with the constant's fallback chain applied
;;----------------------------------------------------------------------
(define b1 (allocate-buffer))
(set-buffer b1)
(run-init!)

(test-equal "a language variable is set in the buffer"
            '("if" "else" "restrict")
            (buffer-local-value b1 'cclangs-keywords-re))
(test-equal "a plain literal variable" "x-"
            (buffer-local-value b1 'cclangs-prefix))
(test-equal "c-lang-setvar sets the standard variable" "; "
            (buffer-local-value b1 'comment-start))
(test-assert "a non-literal value is a procedure"
             (procedure? (buffer-local-value b1 'cclangs-fn)))
(test-equal "and it works" 8
            ((buffer-local-value b1 'cclangs-fn) 4))

(define b2 (allocate-buffer))
(set-buffer b2)
(run-init!)
(test-equal "a second buffer gets its own value"
            '("if" "else" "restrict")
            (buffer-local-value b2 'cclangs-keywords-re))
(set-buffer-local-value! b1 'cclangs-prefix "changed-")
(test-equal "the first buffer's value is its own" "changed-"
            (buffer-local-value b1 'cclangs-prefix))
(test-equal "and the second's is untouched" "x-"
            (buffer-local-value b2 'cclangs-prefix))

;;----------------------------------------------------------------------
;; `c-mode-symbol' and `c-mode-var'
;;----------------------------------------------------------------------
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "the mode prefix makes the symbol" 'c-something
              (c-mode-symbol "something")))
(set-buffer b1)
(set-buffer-local-value! b1 'c-something 42)
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "and c-mode-var reads its buffer-local slot" 42
              (c-mode-var "something")))

;;----------------------------------------------------------------------
;; Baking: a generated init function keeps the values it was expanded
;; with, as compiled Emacs does.
;;----------------------------------------------------------------------
(c-lang-defconst cclangs-baked t 'old-value)
(c-lang-defvar cclangs-baked-var (c-lang-const cclangs-baked))
(define (init-early!) (c-init-language-vars cclangs-test-mode))
(c-lang-defconst cclangs-baked t 'new-value)

(define b3 (allocate-buffer))
(set-buffer b3)
(init-early!)
(test-equal "values are baked into the generated init" 'old-value
            (buffer-local-value b3 'cclangs-baked-var))
(test-equal "the constant itself has the new value" 'new-value
            (c-lang-const cclangs-baked c))

(test-end "schemacs_editor_cc_langs")
