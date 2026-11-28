(define-library (schemacs eval)
  ;; This library mirrors GNU Emacs's `src/eval.c', of which the pieces
  ;; the tree needs so far are `funcall' and `run-hook-wrapped'. (The evaluator itself
  ;; is Guile's, the same departure `eval-expression' and `eval-region'
  ;; carry; `called-interactively-p' is `command.scm''s.)
  ;;
  ;; **A function here is a procedure.** Emacs's `Ffuncall` dispatches on
  ;; a symbol (through its function cell) or a function object; a Scheme
  ;; symbol is not applicable, and this tree's keymaps and menu items
  ;; already hold procedures where Emacs holds symbols, so a caller that
  ;; hands `funcall' a symbol is asking for something no Scheme can do.
  ;; It signals rather than guessing at a registry.

  (import (scheme base)
          ;; A hook may be handed over as its parameter object; `hook-value`
          ;; dereferences it and merges a buffer-local half, exactly as the
          ;; `run-hooks` family in `subr.scm` does.
          (only (guile) parameter?)
          (only (schemacs buffer) hook-value))

  (export funcall run-hook-wrapped)

  (begin

    (define (funcall function . arguments)
      ;; GNU Emacs's `funcall' (`eval.c:3185`): "Call first argument as
      ;; a function, passing remaining arguments to it. Return the value
      ;; that function returns."
      ;;--------------------------------------------------------------
      (apply function arguments))

    (define (run-hook-wrapped hook wrap-function . args)
      ;; GNU Emacs's `run-hook-wrapped' (`eval.c:2981'): "Run HOOK,
      ;; passing each function through WRAP-FUNCTION. I.e. instead of
      ;; calling each function FUN directly with arguments ARGS, it
      ;; calls WRAP-FUNCTION with arguments FUN and ARGS. As soon as a
      ;; call to WRAP-FUNCTION returns non-nil, `run-hook-wrapped'
      ;; aborts and returns that value."
      ;;
      ;; HOOK is the hook's *value* - the list of procedures - for the
      ;; reason `(schemacs subr)'s `run-hooks' family takes it so: a
      ;; hook is a parameter here, and its value is what is to hand. A
      ;; hook that is one procedure is treated as a one-element list,
      ;; as `run_hook_with_args' does with a FUNCTIONP value. A
      ;; *parameter* is dereferenced first.
      ;;--------------------------------------------------------------
      (let ((hook (if (parameter? hook) (hook-value hook) hook)))
        (let loop ((rest (cond ((not hook) '())
                               ((procedure? hook) (list hook))
                               (else hook))))
          (cond ((null? rest) #f)
                (else
                 (let ((value (apply wrap-function (car rest) args)))
                   (if value value (loop (cdr rest)))))))))

    ))
