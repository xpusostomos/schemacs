(define-library (schemacs editor data)
  ;; This library mirrors GNU Emacs's `src/data.c', of which the piece
  ;; the mode machinery needs is `make-local-variable'.
  ;;
  ;; One thing about the model here has to be said, because it is what
  ;; the function means in this tree: Emacs keeps a *default* value for
  ;; a variable beside the buffer-local one, and `make-local-variable'
  ;; copies the default into the buffer so that later changes to the
  ;; default stop reaching it. A buffer's slots here hold only the local
  ;; values, and the default is the caller's - `buffer-local-value'
  ;; takes it as its third argument. So "the value it previously had" is
  ;; the default the caller names, and that is what is copied in.

  (import
    (scheme base)
    (only (schemacs editor buffer)
          buffer-local-value set-buffer-local-value! current-buffer)
    )

  (export
   make-local-variable
   )

  (begin

    (define (make-local-variable key . args)
      ;; GNU Emacs's `make-local-variable' (`data.c':2245): "Make
      ;; VARIABLE have a separate value in the current buffer. Other
      ;; buffers will continue to share a common default value. (The
      ;; buffer-local value of VARIABLE starts out as the same value
      ;; VARIABLE previously had.) ... Return VARIABLE."
      ;;
      ;; KEY is the variable - a symbol for a ported Elisp variable, as
      ;; everything else in this tree's buffer-local store is. The
      ;; optional argument after it is the default to copy in, and the
      ;; one after that the buffer, which is the current one by default.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) #f))
             (buffer (if (and (pair? args) (pair? (cdr args)))
                         (cadr args)
                         (current-buffer))))
        (set-buffer-local-value! buffer key
                                 (buffer-local-value buffer key default))
        key))

    ))