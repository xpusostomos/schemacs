(define-library (schemacs cus-edit)
  ;; GNU Emacs's `lisp/cus-edit.el', of which this tree carries the part
  ;; a caller outside Customize needs: `customize-set-variable' and the
  ;; `custom-quote' helper it stores values with.
  ;;
  ;; **The Customize UI is not carried** - the buffers, the widgets,
  ;; `custom-prompt-variable' and the rest - for the reason
  ;; `custom.scm`'s header gives: this tree has no widget library.  What
  ;; is here is what `compilation-menu-map`'s Skip submenu calls, and
  ;; what an init file's `(customize-set-variable 'x v)' would.
  ;;
  ;; The theme recording is `theme.scm`'s (`custom-push-theme`): the
  ;; function records the `user' theme's setting exactly as Emacs does,
  ;; so a later `custom-theme-reset-variables' or `disable-theme` sees
  ;; it.
  ;;
  ;; **Not carried**: `custom-load-symbol` (there is no
  ;; `custom-autoload`, so the declaring library has been loaded by the
  ;; time anything names the variable), and the interactive spec - which
  ;; prompts through widgets this tree does not have.

  (import
    (scheme base)
    (only (schemacs intervals) get put)
    (only (schemacs data) set-default keywordp)
    (only (schemacs chartab) char-table?)
    (only (schemacs theme) custom-push-theme))

  (export customize-set-variable custom-quote)

  (begin

    (define (custom-quote sexp)
      "Quote SEXP iff it is not self quoting."
      ;; `cus-edit.el:1293'.  The self-quoting test is the C's list of
      ;; types; a Scheme *procedure* is not one of them, so a procedure
      ;; value is quoted like any other non-self-quoting object - which
      ;; is Emacs's answer for a compiled function value too.
      ;;--------------------------------------------------------------
      (if (or (eq? sexp #t)
              (eq? sexp #f)
              (keywordp sexp)
              (and (pair? sexp) (eq? (car sexp) 'lambda))
              (string? sexp)
              (number? sexp)
              (vector? sexp)
              (char? sexp)
              (char-table? sexp))
          sexp
          (list 'quote sexp)))

    (define (customize-set-variable variable value . rest)
      "Set the default for VARIABLE to VALUE, and return VALUE.
VALUE is a Lisp object.

If VARIABLE has a `custom-set' property, that is used for setting
VARIABLE, otherwise `set-default' is used."
      ;; `cus-edit.el:1046'.
      ;;
      ;; The `:set' functions this tree keeps are two-argument
      ;; procedures taking (SYMBOL VALUE) - the same call the
      ;; `custom-initialize-*' functions make - and `set-default'
      ;; (`data.c`) has that shape too.
      ;;--------------------------------------------------------------
      (let ((comment (and (pair? rest) (car rest))))
        ;; `custom-load-symbol`: no `custom-autoload` here; see the
        ;; library header.
        (custom-push-theme 'theme-value variable 'user 'set
                           (custom-quote value))
        ((or (get variable 'custom-set)
             (get variable 'custom-writer)
             set-default)
         variable value)
        (put variable 'customized-value (list (custom-quote value)))
        ;; Emacs's `(string= comment "")' is nil for a nil COMMENT;
        ;; Scheme's `string=?' would signal, so the type test is explicit.
        (cond ((and (string? comment) (string=? comment ""))
               (put variable 'variable-comment #f)
               (put variable 'customized-variable-comment #f))
              (comment
               (put variable 'variable-comment comment)
               (put variable 'customized-variable-comment comment)))
        value))
    ))
