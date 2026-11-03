(define-library (schemacs fluid)
  ;; `fluid-let` - SRFI 226's dynamically scoped rebinding of an ordinary
  ;; variable.
  ;;
  ;; **Why this file is not a mirror of an Emacs file.** Every other
  ;; library in this tree is named after the Emacs source it ports; this
  ;; one has no Emacs source, because Emacs does not need it. In Elisp
  ;; `defvar` makes a variable *special* and `let` on a special variable
  ;; rebinds it dynamically - save the old value, install the new, restore
  ;; on the way out - and that is what `fluid-let` is, spelled for a
  ;; language that has no special variables. It is a host-language
  ;; facility, like `(schemacs arrays)`, and it lives at the top of the
  ;; tree with it rather than under `editor/`.
  ;;
  ;; SRFI 226's name (`fluid-let`) and its semantics are used deliberately
  ;; rather than inventing something: `fluid-let*` and `parameterize` are
  ;; its neighbours there, and the standard's own `fluid-let` expands to
  ;; `parameterize` because SRFI 226 builds fluids on parameter objects.
  ;; **This one does not** - see below.
  ;;
  ;; **The easy implementation, and why it is the right one here.** SRFI
  ;; 226 implements a fluid as an identifier macro over a hidden parameter
  ;; object, so that `(fluid-let ((x 1)) ...)' can find `x`'s parameter and
  ;; `parameterize` it. That needs a way to get from the identifier to the
  ;; parameter at expansion time - in R6RS, a syntax property
  ;; (`define-property'), which Guile does not have (measured:
  ;; `syntax-local-value' is absent), so it would need a companion name for
  ;; every fluid instead.
  ;;
  ;; None of that is needed to rebind a *plain* variable: save the old
  ;; values, `set!` the new ones, run the body, restore. That is what this
  ;; macro does, and it is exactly what Emacs's dynamic `let` does - Emacs
  ;; saves the previous value in the specpdl and restores it, it does not
  ;; keep a box per thread. The two things the parameter-backed version
  ;; would add are per-thread values and continuation-correct restoration,
  ;; and neither is wanted in this editor (a per-thread `current-buffer`
  ;; *hides* state - see the `*repl-wake*' note in AGENTS.md - and the
  ;; editor's continuations are one-shot escapes).
  ;;
  ;; So the requirement is just: the variable must be an ordinary binding.
  ;; A parameter cannot be rebound this way and does not need to be -
  ;; `parameterize` is the form for those.

  (import
    (scheme base)
    ;; `syntax-case' and `generate-temporaries': the saved values need a
    ;; fresh name each, or two bindings collide on one name - measured, as
    ;; "duplicate bound variable in form (let ((old x) (old y)) ...)".
    (only (guile) generate-temporaries quasisyntax syntax syntax-case
          unsyntax unsyntax-splicing with-syntax))

  (export fluid-let)

  (begin

    (define-syntax fluid-let
      ;; Rebinds variables for the dynamic extent of the body:
      ;;
      ;;   (fluid-let ((case-fold-search #f)
      ;;               (fill-column 30))
      ;;     ...body...)
      ;;
      ;; NAME must be a variable - `set!`-able where the form appears -
      ;; and every value is evaluated *before* any of them is installed,
      ;; so this is `let`, not `let*`. Both are SRFI 226's rules, and both
      ;; are Emacs's for `let` on special variables:
      ;;
      ;;   (let ((a 1) (b a)) b)        ; b is the OUTER a, not 1
      ;;
      ;; The body's value (or values) is what the form returns. The
      ;; restore happens however the body leaves - normally, by an error,
      ;; or by escaping through a continuation - because it is a
      ;; `dynamic-wind` after-thunk.
      ;;
      ;; **An assignment inside the body is undone on exit**, as it is in
      ;; Elisp: the restore puts back the value the variable had on the
      ;; way in, whatever the body did to it in between.
      ;;--------------------------------------------------------------
      (lambda (stx)
        (syntax-case stx ()
          ((_ () body ...)
           ;; no bindings: the body alone, and not even a `dynamic-wind`
           #'(let () body ...))
          ((_ ((name value) ...) body ...)
           (with-syntax (((saved ...) (generate-temporaries #'(name ...)))
                         ((fresh ...) (generate-temporaries #'(name ...))))
             ;; **`saved` and `fresh` are read in the same `let`**: the old
             ;; values and the new ones are all evaluated before the first
             ;; `set!` runs, which is what makes the values parallel.
             #`(let ((saved name) ... (fresh value) ...)
                 (dynamic-wind
                   (lambda () (set! name fresh) ...)
                   (lambda () body ...)
                   (lambda () (set! name saved) ...))))))))

    ))
