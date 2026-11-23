(define-library (schemacs callproc)
  ;; GNU Emacs's `src/callproc.c', the synchronous subprocess call.
  ;;
  ;; **The mechanism is Guile's, the shape is the C's.** `call-process`
  ;; runs PROGRAM with ARGS and waits for it; this tree has no
  ;; `struct Lisp_Process`, no job control and no SIGCHLD handling, so
  ;; the child is Guile's `open-input-pipe`/`close-pipe` over `/bin/sh
  ;; -c`. That is a departure in mechanism with two visible
  ;; consequences, both named here:
  ;;
  ;;   * arguments are quoted for the shell with `shell-quote-argument`
  ;;     (`subr.sld`) rather than passed as an argv array, so a program
  ;;     with an unusual quoting requirement could differ from the C's
  ;;     `execvp`;
  ;;   * the shell is what lets the child's standard error be mixed into
  ;;     the destination, which is what `call-process` does ("Output here
  ;;     means both standard output and standard error output", and
  ;;     measured: a `sh -c "echo out; echo err >&2"` puts both in the
  ;;     buffer). Guile's pipe inherits stderr otherwise.
  ;;
  ;; The child reads `/dev/null` for standard input unless INFILE names
  ;; a file - the C's null device - and runs in `default-directory`.
  ;;
  ;; Only the synchronous call is ported. `call-process-region`,
  ;; `start-process`, `make-process` and the whole process-object
  ;; interface are not: nothing in this tree has a process to hold.

  (import (scheme base)
          (scheme file)
          (only (scheme cxr) cdddr)
          (ice-9 popen)
          (ice-9 textual-ports)
          (only (guile) status:exit-val status:term-sig)
          (only (schemacs subr) shell-quote-argument)
          (only (schemacs buffer)
                current-buffer default-directory buffer-name bufferp
                get-buffer with-current-buffer)
          (only (schemacs editfns) insert))

  (export call-process)

  (begin

    (define (%callproc-opt args n default)
      (let loop ((rest args) (k n))
        (cond ((null? rest) default)
              ((= k 0) (car rest))
              (else (loop (cdr rest) (- k 1))))))

    (define (%join-quoted strings)
      ;; STRINGS as one shell command line, each quoted by
      ;; `shell-quote-argument` - `mapconcat` with it, in Emacs's idiom.
      ;;--------------------------------------------------------------
      (let loop ((rest strings) (out ""))
        (if (null? rest)
            out
            (loop (cdr rest)
                  (if (string=? out "")
                      (shell-quote-argument (car rest))
                      (string-append out " "
                                     (shell-quote-argument (car rest))))))))

    (define (call-process program . args)
      ;; GNU Emacs's `call-process` (`callproc.c`): "Call PROGRAM
      ;; synchronously in separate process."
      ;;
      ;; INFILE (first optional) is the child's standard input, nil for
      ;; the null device. DESTINATION (second) is t for the current
      ;; buffer, a buffer or its name, `(:file FILE)`, nil to discard
      ;; and 0 to discard; DISPLAY (third) asks for a redisplay, which
      ;; this tree's command loop already does after every command.
      ;; The rest are the command's arguments.
      ;;--------------------------------------------------------------
      (let* ((infile (%callproc-opt args 0 #f))
             (destination (%callproc-opt args 1 #f))
             (display (%callproc-opt args 2 #f))
             (program-args (if (>= (length args) 3) (cdddr args) '()))
             (cmd (string-append
                   "cd " (shell-quote-argument (default-directory)) " && "
                   (%join-quoted (cons program program-args))
                   " < " (if infile
                              (shell-quote-argument infile)
                              "/dev/null")
                   ;; standard error into the destination, as the C does
                   " 2>&1"))
             (port (open-input-pipe cmd))
             (output (or (get-string-all port) ""))
             (status (close-pipe port))
             (exit (status:exit-val status))
             (signal (status:term-sig status)))
        ;; Where the output goes: the C's DESTINATION cases.
        (cond
         ((eq? destination #t)
          (insert output))
         ((and (pair? destination) (eq? (car destination) ':file))
          ;; `(:file FILE)': written over, as the C writes it.
          (call-with-output-file (cadr destination)
            (lambda (out) (put-string out output))
            #:encoding "UTF-8"))
         ((bufferp destination)
          (with-current-buffer destination (insert output)))
         ((and (string? destination) (get-buffer destination))
          (with-current-buffer (get-buffer destination) (insert output)))
         (else #t))
        ;; The answer: the exit status, or the signal that ended it.
        (cond (signal (string-append "signal " (number->string signal)))
              ((integer? exit) exit)
              (else #f))))))
