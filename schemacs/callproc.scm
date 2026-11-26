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
          (only (scheme cxr) caddr cdddr)
          (ice-9 popen)
          (ice-9 textual-ports)
          (only (guile) status:exit-val status:term-sig)
          (only (schemacs subr) shell-quote-argument)
          (only (guile) delete-file)
          (only (schemacs buffer)
                current-buffer default-directory buffer-name bufferp
                get-buffer with-current-buffer)
          (only (schemacs editfns) insert buffer-substring point-min
                point-max delete-region widen)
          (only (schemacs fileio) make-temp-file-internal))

  (export call-process call-process-region shell-file-name)

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
             ;; "(REAL-BUFFER STDERR-FILE)": "REAL-BUFFER says what to do
             ;; with standard output ... STDERR-FILE says what to do with
             ;; standard error in the child. STDERR-FILE may be nil
             ;; (discard), t (mix it with ordinary output), or a file
             ;; name string" (`callproc.c:1081`).
             (dest-pair (and (pair? destination)
                             (not (eq? (car destination) ':file))))
             (real-destination (if dest-pair (car destination) destination))
             (stderr-file (if dest-pair (cadr destination) #t))
             (error-redirect
              (cond ((eq? stderr-file #t) " 2>&1")
                    ((string? stderr-file)
                     (string-append " 2> " (shell-quote-argument stderr-file)))
                    (else " 2>/dev/null")))
             (cmd (string-append
                   "cd " (shell-quote-argument (default-directory)) " && "
                   (%join-quoted (cons program program-args))
                   " < " (if infile
                              (shell-quote-argument infile)
                              "/dev/null")
                   error-redirect))
             (port (open-input-pipe cmd))
             (output (or (get-string-all port) ""))
             (status (close-pipe port))
             (exit (status:exit-val status))
             (signal (status:term-sig status)))
        ;; Where the output goes: the C's DESTINATION cases, after a
        ;; `(REAL-BUFFER STDERR-FILE)' pair has been taken apart.
        (cond
         ((eq? real-destination #t)
          (insert output))
         ((and (pair? real-destination) (eq? (car real-destination) ':file))
          ;; `(:file FILE)': written over, as the C writes it.
          (call-with-output-file (cadr real-destination)
            (lambda (out) (put-string out output))
            #:encoding "UTF-8"))
         ((bufferp real-destination)
          (with-current-buffer real-destination (insert output)))
         ((and (string? real-destination) (get-buffer real-destination))
          (with-current-buffer (get-buffer real-destination) (insert output)))
         (else #t))
        ;; The answer: the exit status, or the signal that ended it.
        (cond (signal (string-append "signal " (number->string signal)))
              ((integer? exit) exit)
              (else #f))))))

    (define shell-file-name
      ;; GNU Emacs's `shell-file-name' (`callproc.c`'s DEFVAR_LISP):
      ;; "File name to load inferior shells from. Initialized from the
      ;; SHELL environment variable, or to a system-dependent default."
      ;; Configured here as the C's default.
      "/bin/sh")

    (define (call-process-region start end program . args)
      ;; GNU Emacs's `call-process-region' (`callproc.c:1063'): "Send
      ;; text from START to END to a synchronous process running
      ;; PROGRAM. ... If START is nil, that means to use the entire
      ;; buffer contents ... If START is a string, then send that string
      ;; ... Delete the text if fourth arg DELETE is non-nil."
      ;;
      ;; The region is written to a temporary file and the child's
      ;; standard input redirected from it - the C's `create_temp_file'
      ;; path; the deletion is done after writing it, before the child
      ;; runs, which is the C's order. DEPARTURE: the file is created
      ;; by `make-temp-file-internal' in `temporary-file-directory',
      ;; where the C uses `small-temporary-file-directory' and falls
      ;; back to a pipe for large regions; the visible behaviour is the
      ;; same.
      ;;--------------------------------------------------------------
      (let* ((delete (if (pair? args) (car args) #f))
             (destination (if (and (pair? args) (pair? (cdr args)))
                              (cadr args) #f))
             (display (if (and (pair? args) (pair? (cdr args))
                               (pair? (cddr args)))
                          (caddr args) #f))
             (program-args (if (and (pair? args) (pair? (cdr args))
                                    (pair? (cddr args)))
                               (cdddr args) '()))
             (text (cond ((string? start) start)
                         ((not start) (buffer-substring (point-min) (point-max)))
                         (else (buffer-substring start end))))
             (infile (if (= (string-length text) 0)
                         #f
                         (make-temp-file-internal "call-process-region"
                                                  #f "" text))))
        (guard (e (#t (when infile (delete-file infile)) (raise e)))
          (when delete
            ;; "No need to save restrictions since we delete everything
            ;; anyway": START nil widens first; otherwise the C's
            ;; `Fdelete_region' is called and a string START is its
            ;; wrong-type error.
            (if (not start)
                (begin (widen) (delete-region (point-min) (point-max)))
                (delete-region start end)))
          (let ((status (apply call-process program infile destination display
                               program-args)))
            (when infile (delete-file infile))
            status))))
