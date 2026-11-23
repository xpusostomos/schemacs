;; Tests for `(schemacs editor cc-defs)' - the language-constant system
;; ported from `lisp/progmodes/cc-defs.el'. The three behaviours that
;; matter and that the cc-mode port will lean on: `LANG' overrides `t'
;; and a derived language falls back to its base, a VAL is evaluated
;; lazily once and cached (and invalidated when a constant it used is
;; redefined), and a VAL may refer to a constant defined later or to
;; itself (Emacs's setq-like sequencing).
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) current-module eval)
 (only (schemacs editor buffer) allocate-buffer set-buffer erase-buffer)
 (only (schemacs editor editfns) insert goto-char point)
 (only (schemacs editor textprop) put-text-property get-text-property)
 (only (schemacs editor command) signal-quit quit-condition?)
 (schemacs editor cc-defs))

(test-begin "schemacs_editor_cc_defs")

;;----------------------------------------------------------------------
;; `c-got-face-at' (`cc-defs.el:2122') - Emacs's answers, measured with
;; `emacs -Q --batch' on the same three-property fixture.
;;----------------------------------------------------------------------
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert "abcdef")
  (put-text-property 2 4 'face '(bold italic))
  (put-text-property 1 2 'face 'bold)
  (test-equal "c-got-face-at answers the tail from the matching face"
              '(italic) (c-got-face-at 2 '(italic)))
  (test-equal "c-got-face-at is nil when no listed face is there"
              #f (c-got-face-at 2 '(underline)))
  (test-equal "c-got-face-at answers the tail from the first matching face"
              '(bold italic) (c-got-face-at 2 '(italic bold)))
  (test-equal "c-got-face-at with a single face symbol"
              '(bold) (c-got-face-at 1 '(bold)))
  (test-equal "c-got-face-at at the second position of a face run"
              '(italic) (c-got-face-at 3 '(italic)))
  (test-equal "c-got-face-at where no face property exists"
              #f (c-got-face-at 5 '(bold))))

;; `c-mode' and the other core languages got their `c-mode-prefix'
;; when cc-defs loaded. A derived language exercises the fallback.
(eval-when (expand load eval)
  (c-add-language 'ccdefs-derived-mode 'c-mode))

;;----------------------------------------------------------------------
;; LANG overrides t; another language falls back to t
;;----------------------------------------------------------------------
(c-lang-defconst ccdefs-basic t '(1 2 3) c '(2 3 4))

(test-equal "the c value overrides t"
            '(2 3 4)
            (c-lang-const ccdefs-basic c))
(test-equal "another language falls back to t"
            '(1 2 3)
            (c-lang-const ccdefs-basic c++))
(test-equal "no LANG asks the current language"
            '(2 3 4)
            (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
              (c-lang-const ccdefs-basic)))

;;----------------------------------------------------------------------
;; Lazy evaluation, cached per mode
;;----------------------------------------------------------------------
(define counter 0)
;; A self-assignment marks the binding mutable: without it the compiler
;; folds reads of `counter' to 0, because the only `set!' on it lives in
;; a VAL evaluated by `eval' (AGENTS.md's "a compiled library folds its
;; own defvars").
(set! counter counter)
(c-lang-defconst ccdefs-count t (begin (set! counter (+ counter 1))
                                       'counted))

(test-equal "the first request evaluates the VAL" 'counted
            (c-get-lang-constant 'ccdefs-count #f 'c-mode))
(test-equal "and evaluates it once" 1 counter)
(test-equal "the second request is cached" 'counted
            (c-get-lang-constant 'ccdefs-count #f 'c-mode))
(test-equal "still once" 1 counter)

;;----------------------------------------------------------------------
;; A VAL may refer to a constant defined later
;;----------------------------------------------------------------------
(c-lang-defconst ccdefs-fwd t (list 'x (c-lang-const ccdefs-later)))
(c-lang-defconst ccdefs-later t 'y)

(test-equal "a forward reference resolves when the value is asked for"
            '(x y)
            (c-lang-const ccdefs-fwd c))

;;----------------------------------------------------------------------
;; A VAL may refer to itself: the assignment before the one being
;; evaluated, as Emacs's `setq'-like sequencing gives.
;;----------------------------------------------------------------------
(c-lang-defconst ccdefs-seq
  t 'base
  c (cons 'c (c-lang-const ccdefs-seq)))

(test-equal "a self-reference continues with the earlier assignment"
            '(c . base)
            (c-lang-const ccdefs-seq c))

;;----------------------------------------------------------------------
;; Fallback languages
;;----------------------------------------------------------------------
(c-lang-defconst ccdefs-fb t 't-value c 'c-value)
(c-lang-defconst ccdefs-fb2 t 't-only)

(test-equal "a derived language uses its base's explicit value"
            'c-value
            (c-lang-const ccdefs-fb ccdefs-derived))
(test-equal "and the t value where the base has no override"
            't-only
            (c-lang-const ccdefs-fb2 ccdefs-derived))

;;----------------------------------------------------------------------
;; Redefining a constant clears the values that depend on it
;;----------------------------------------------------------------------
(define dep-counter 0)
(set! dep-counter dep-counter)
(c-lang-defconst ccdefs-a t 'a1)
(c-lang-defconst ccdefs-b t (begin (set! dep-counter (+ dep-counter 1))
                                   (list (c-lang-const ccdefs-a))))

(test-equal "the dependent computes" '(a1)
            (c-get-lang-constant 'ccdefs-b #f 'c-mode))
(test-equal "once" 1 dep-counter)
(c-lang-defconst ccdefs-a t 'a2)
(test-equal "redefining the dependency recomputes the dependent" '(a2)
            (c-get-lang-constant 'ccdefs-b #f 'c-mode))
(test-equal "which is a second evaluation" 2 dep-counter)

;;----------------------------------------------------------------------
;; `c-lang-major-mode-is' sees fallback modes
;;----------------------------------------------------------------------
(parameterize ((*c-buffer-is-cc-mode* 'ccdefs-derived-mode))
  (test-assert "a derived language is its base mode"
               (c-lang-major-mode-is 'c-mode))
  (test-assert "and not an unrelated language"
               (not (c-lang-major-mode-is 'c++-mode))))
(parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
  (test-assert "a list of modes matches any of them"
               (c-lang-major-mode-is '(c-mode c++-mode))))

;;----------------------------------------------------------------------
;; Expansion: a value resolvable at expansion time is baked into it.
;; The observable Emacs behaviour: a use compiled while the constant had
;; an old value keeps that value after the constant is redefined.
;;----------------------------------------------------------------------
(c-lang-defconst ccdefs-bake t 'old)
(define (ccdefs-bake-get) (c-lang-const ccdefs-bake c))
(define bake-v1 (ccdefs-bake-get))
(c-lang-defconst ccdefs-bake t 'new)
(define bake-v2 (ccdefs-bake-get))

(test-equal "a known constant is baked into its use" 'old bake-v2)
(test-equal "and the constant itself has the new value" 'new
            (c-get-lang-constant 'ccdefs-bake #f 'c-mode))
(test-assert "an unknown language is refused at expansion time"
             (catch #t
               (lambda () (eval '(c-lang-const ccdefs-basic nonesuch)
                                (current-module))
                 #f)
               (lambda (key . args) #t)))

;;----------------------------------------------------------------------
;; `c-major-mode-is' and the `scan-lists' wrappers
;; (`cc-defs.el:541', `:780'-`:930')
;;
;; Every expectation is Emacs 31.1's answer on the same buffer.
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_cc_defs_scan")

(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "a quoted single mode is an eq test" #t
              (c-major-mode-is 'c-mode))
  (test-equal "another single mode is not the current one" #f
              (c-major-mode-is 'c++-mode))
  (test-equal "a quoted list answers the memq tail" '(c-mode c++-mode)
              (c-major-mode-is '(c-mode c++-mode)))
  (test-equal "a non-literal mode symbol works" #t
              (let ((m 'c-mode)) (c-major-mode-is m)))
  (test-equal "and a non-literal list answers its tail" '(c-mode)
              (let ((m '(c++-mode c-mode))) (c-major-mode-is m))))

(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert "(a (b)) x (c)\n")
  (define (at n) (goto-char n))
  (at 1) (test-equal "up-list-forward at the outer (" #f (c-up-list-forward))
  (at 4) (test-equal "up-list-forward inside (b)" 8 (c-up-list-forward))
  (at 4) (test-equal "up-list-backward from inside (b)" 1 (c-up-list-backward))
  (at 1) (test-equal "down-list-forward after the outer (" 2 (c-down-list-forward))
  (at 7) (test-equal "down-list-backward before the outer )" 6 (c-down-list-backward))
  (at 1) (test-equal "go-list-forward returns the position" 8
          (begin (c-go-list-forward)))
  (at 7) (test-equal "go-list-backward returns the position" 4
          (begin (c-go-list-backward)))
  (at 1) (test-equal "go-up-list-forward moves when there is a list" #f
          (c-go-up-list-forward))
  (at 7) (test-equal "go-up-list-backward moves to the list's start" #t
          (begin (c-go-up-list-backward) #t))
  (at 1) (test-equal "go-down-list-forward moves inside" #t
          (begin (c-go-down-list-forward) (= (point) 2)))
  (at 7) (test-equal "go-down-list-backward moves inside" #t
          (begin (c-go-down-list-backward) (= (point) 6)))
  (at 1) (test-equal "safe-scan-lists answers the same as scan-lists" 8
          (c-safe-scan-lists (point) 1 0))
  (at 13) (test-equal "and nil at a lone close paren" #f
          (c-safe-scan-lists (point) 1 0))
  (erase-buffer) (insert "((a)\n") (at 1)
  (test-equal "an unbalanced scan answers nil instead of signalling" #f
              (c-safe-scan-lists (point) 1 0))
  (at 1) (test-equal "and go-list-forward leaves point unmoved" #f
          (begin (c-go-list-forward) #f))
  (at 1) (test-equal "point is where it was" 1 (point)))

(test-equal "c-safe answers the body's value" 3 (c-safe (+ 1 2)))
(test-equal "c-safe answers #f for an error" #f (c-safe (error "boom")))
(test-equal "c-safe re-raises a quit (Emacs's condition-case does not catch one)"
            'quit
            (guard (e ((quit-condition? e) 'quit))
              (c-safe (signal-quit))
              'no-quit))

(test-end "schemacs_editor_cc_defs_scan")

;;----------------------------------------------------------------------
;; The property searches and the string fence (`cc-defs.el:1242',
;; `:1482')
;;----------------------------------------------------------------------
;; Emacs's answers for this fixture, measured with `emacs -Q --batch'
;; first.
(test-begin "schemacs_editor_cc_defs_props")

(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert "abcdef")
  (put-text-property 3 4 'syntax-table '(1))
  (put-text-property 4 5 'syntax-table '(1))
  (put-text-property 5 6 'c-is-sws #t)
  (put-text-property 5 6 'c-in-sws #t)
  (goto-char 1)
  (test-equal "c-search-forward-non-nil-char-property answers the value"
              '(1) (c-search-forward-non-nil-char-property 'syntax-table 20))
  (test-equal "...and leaves point just after the character"
              4 (point))
  (goto-char 2)
  (test-equal "...from a position before the run" '(1)
              (c-search-forward-non-nil-char-property 'syntax-table 20))
  (goto-char 1)
  (test-equal "...and nil when the limit comes first" #f
              (c-search-forward-non-nil-char-property 'syntax-table 2))
  (test-equal "...leaving point where it was" 1 (point))
  (goto-char 5)
  (c-put-string-fence 5)
  (test-equal "c-put-string-fence puts the (15) syntax-table value"
              '(15) (get-text-property 5 'syntax-table))
  (test-equal "...and clears c-is-sws" #f (get-text-property 5 'c-is-sws))
  (test-equal "...and c-in-sws" #f (get-text-property 5 'c-in-sws)))

(test-end "schemacs_editor_cc_defs_props")

(test-end "schemacs_editor_cc_defs")
