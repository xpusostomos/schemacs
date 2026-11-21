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
 (schemacs editor cc-defs))

(test-begin "schemacs_editor_cc_defs")

;; `c-mode' and the other core languages got their `c-mode-prefix'
;; when cc-defs loaded. A derived language exercises the fallback.
(c-add-language 'ccdefs-derived-mode 'c-mode)

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

(test-end "schemacs_editor_cc_defs")
