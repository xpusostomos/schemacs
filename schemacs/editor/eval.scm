(define-library (schemacs editor eval)
  ;; This library mirrors GNU Emacs's `src/eval.c', of which the piece
  ;; the cc-mode port needs so far is `funcall'. (The evaluator itself
  ;; is Guile's, the same departure `eval-expression' and `eval-region'
  ;; carry; `called-interactively-p' is `command.scm''s.)
  ;;
  ;; **A function here is a procedure.** Emacs's `Ffuncall` dispatches on
  ;; a symbol (through its function cell) or a function object; a Scheme
  ;; symbol is not applicable, and this tree's keymaps and menu items
  ;; already hold procedures where Emacs holds symbols, so a caller that
  ;; hands `funcall' a symbol is asking for something no Scheme can do.
  ;; It signals rather than guessing at a registry.

  (import (scheme base))

  (export funcall)

  (begin

    (define (funcall function . arguments)
      ;; GNU Emacs's `funcall' (`eval.c:3185`): "Call first argument as
      ;; a function, passing remaining arguments to it. Return the value
      ;; that function returns."
      ;;--------------------------------------------------------------
      (apply function arguments))

    ))
