(define-library (schemacs editor seq)
  ;; GNU Emacs's `lisp/emacs-lisp/seq.el', the generic sequence
  ;; operations. Only the three the external packages here use are
  ;; ported - `seq-filter`, `seq-remove` and `seq-find` - and their
  ;; *objective* is SRFI-1's `filter`, `remove` and `find`, which is
  ;; what they are written in terms of: the selection calls Guile's
  ;; implementation rather than re-implementing the walk.
  ;;
  ;; **A departure: the sequence type.** Emacs's functions are
  ;; `cl-defgeneric`s over lists, vectors and strings. Here a sequence is
  ;; a *list*: every caller in the tree hands one a list, and the
  ;; vector/string arms of `seq-filter` (which build a list anyway) are
  ;; not carried until something asks for them.

  (import (scheme base)
          (only (srfi srfi-1) filter))

  (export seq-filter seq-remove seq-find)

  (begin

    (define (seq-filter pred sequence)
      ;; GNU Emacs's `seq-filter` (seq.el): "Return a list of all the
      ;; elements in SEQUENCE for which PRED returns non-nil. This does
      ;; not modify SEQUENCE." SRFI-1's `filter` is the same operation
      ;; on a list.
      ;;--------------------------------------------------------------
      (filter pred sequence))

    (define (seq-remove pred sequence)
      ;; GNU Emacs's `seq-remove` (seq.el): "Return a list of all the
      ;; elements in SEQUENCE for which PRED returns nil" - Emacs's own
      ;; body is `seq-filter` with the negation, and so is this.
      ;;--------------------------------------------------------------
      (filter (lambda (elt) (not (pred elt))) sequence))

    (define (seq-find pred sequence . args)
      ;; GNU Emacs's `seq-find` (seq.el): "Return the first element in
      ;; SEQUENCE for which PRED returns non-nil. If no such element is
      ;; found, return DEFAULT." Written as Emacs's `catch`-and-throw
      ;; loop is written, because `(or (find ...) default)` would answer
      ;; DEFAULT for a found `#f` element - the ambiguity the docstring
      ;; itself names.
      ;;--------------------------------------------------------------
      (let ((default (if (pair? args) (car args) #f)))
        (let loop ((rest sequence))
          (cond ((null? rest) default)
                ((pred (car rest)) (car rest))
                (else (loop (cdr rest)))))))
    ))
