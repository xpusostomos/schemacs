(define-library (schemacs external dash)
  ;; A SUBSET of the `dash' list library
  ;; (https://github.com/magnars/dash.el; the Emacs package here is
  ;; 20260221), holding exactly what `groovy-emacs-modes' uses: the
  ;; `->>' threading macro.  It lives under `schemacs/external'
  ;; because it is not part of GNU Emacs.
  ;;
  ;; `->>' threads the expression through the forms, inserting it as
  ;; the LAST item of each - `(-->' is the other direction).  Emacs's
  ;; definition (`dash.el:2132') tests `(listp form)' and appends;
  ;; `syntax-rules' distinguishes the two shapes by pattern, which is
  ;; the same decision made one level earlier.
  (import (scheme base))

  (export ->>)

  (begin

    (define-syntax ->>
      ;; "Thread the expr through the forms.  Insert X as the last item
      ;; in the first form, making a list of it if it is not a list
      ;; already.  If there are more forms, insert the first form as the
      ;; last item in second form, etc."
      ;;
      ;; A list form takes X as its last argument; a non-list form
      ;; becomes `(FORM X)'; with several forms the first threading's
      ;; result feeds the next.
      (syntax-rules ()
        ((_ x) x)
        ((_ x (h args ...)) (h args ... x))
        ((_ x (h args ...) more ...) (->> (h args ... x) more ...))
        ((_ x h) (h x))
        ((_ x h more ...) (->> (h x) more ...))))

    ))
