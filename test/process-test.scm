;; Tests for `(schemacs process)' - src/process.c's subprocess half.  The
;; expectations are Emacs 31.1's own answers for the same programs: the
;; status strings and messages are `status_message' (`process.c:813'),
;; and the default filter's insertion at the process mark is
;; `internal-default-process-filter'.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (srfi srfi-13) string-contains string-prefix?)
 (only (schemacs buffer) get-buffer-create set-buffer current-buffer
       buffer-name buffer-local-value default-directory)
 (only (schemacs editfns) insert point point-min point-max buffer-string)
 (only (schemacs files) expand-file-name)
 (only (schemacs marker) marker-position)
 (schemacs process))

(define (wait-process p . rest)
  ;; Drive the wait loop until P is no longer running.
  (let ((limit (if (pair? rest) (car rest) 400)))
    (let loop ((i 0))
      (accept-process-output p 0.02)
      (if (and (< i limit) (eq? (process-status p) 'run))
          (loop (+ i 1))
          (process-status p)))))

(define (no-op-sentinel process message) #f)

(define (make-and-run name buffer command . rest)
  (let ((p (apply make-process
                  ':name name ':buffer buffer ':command command
                  ':connection-type 'pipe ':sentinel no-op-sentinel rest)))
    (wait-process p)
    p))

(define (buffer-text buffer)
  (set-buffer buffer)
  (buffer-string))

(test-begin "schemacs_process")

;; The object and its accessors.
(let* ((b (get-buffer-create "*proc-a*"))
       (p (make-process ':name "proc-a" ':buffer b
                        ':command '("/bin/sh" "-c" "echo hi")
                        ':connection-type 'pipe)))
  (test-assert "start-process answers a process" (processp p))
  (test-equal "process-name" "proc-a" (process-name p))
  (test-equal "get-process finds it by name" p (get-process "proc-a"))
  (test-assert "process-id is a positive number" (> (process-id p) 0))
  (test-assert "process-live-p while running"
               (process-live-p p))
  (test-assert "process-list contains it" (memq p (process-list)))
  (test-equal "get-buffer-process finds it from the buffer"
              p (get-buffer-process b))
  (wait-process p)
  (test-equal "a clean exit is exit" 'exit (process-status p))
  (test-equal "exit status 0" 0 (process-exit-status p))
  (test-assert "the output is in the buffer, in order"
               (string-prefix? "hi\n" (buffer-text b)))
  (test-assert "the default sentinel reports in the buffer"
               (string-contains (buffer-text b) "Process proc-a finished\n"))
  (test-equal "the process mark is at the end of its output"
              (point-max) (marker-position (process-mark p)))
  (test-equal "a finished process leaves process-list"
              #f (get-process "proc-a")))

;; stderr is mixed into the output, as Emacs's :stderr nil does.
(let ((p (make-and-run "proc-stderr" (get-buffer-create "*proc-err*")
                       '("/bin/sh" "-c" "echo out; echo err >&2"))))
  (test-equal "stderr arrives with stdout"
              "out\nerr\n" (buffer-text (process-buffer p))))

;; The sentinel: its arguments and the message text.
(let* ((messages '())
       (p (make-process ':name "proc-sent" ':buffer #f
                        ':command '("/bin/sh" "-c" "exit 3")
                        ':connection-type 'pipe
                        ':sentinel (lambda (proc msg)
                                     (set! messages (cons msg messages))))))
  (wait-process p)
  (test-equal "an abnormal exit's sentinel message"
              "exited abnormally with code 3\n" (car messages))
  (test-equal "process-exit-status after exit 3" 3 (process-exit-status p)))

(let* ((messages '())
       (p (make-process ':name "proc-sent2" ':buffer #f
                        ':command '("/bin/sh" "-c" "exit 0")
                        ':connection-type 'pipe
                        ':sentinel (lambda (proc msg)
                                     (set! messages (cons msg messages))))))
  (wait-process p)
  (test-equal "a clean exit's sentinel message" "finished\n" (car messages)))

;; A custom filter receives the text and the buffer is not used.
(let* ((got "")
       (p (make-process ':name "proc-filter" ':buffer #f
                        ':command '("/bin/sh" "-c" "printf 'abc\\ndef\\n'")
                        ':connection-type 'pipe
                        ':filter (lambda (proc text)
                                   (set! got (string-append got text))))))
  (wait-process p)
  (test-equal "a filter gets each chunk of output" "abc\ndef\n" got)
  (test-equal "set-process-filter replaces it"
              't (begin (set-process-filter p 't) (process-filter p))))

;; The child's environment and directory.
(let* ((b (get-buffer-create "*proc-env*"))
       (p (parameterize ((*process-environment*
                          (cons "FOO=bar" (*process-environment*))))
            (make-and-run "proc-env" b
                          '("/bin/sh" "-c" "printf '%s' \"$FOO\"")))))
  (test-equal "process-environment reaches the child" "bar" (buffer-text b)))

(let* ((dir (expand-file-name (default-directory)))
       ;; `default-directory' ends with a slash and `pwd' does not.
       (expected (if (and (> (string-length dir) 1)
                          (char=? (string-ref dir (- (string-length dir) 1)) #\/))
                     (substring dir 0 (- (string-length dir) 1))
                     dir))
       (b (get-buffer-create "*proc-cwd*"))
       (p (make-and-run "proc-cwd" b '("/bin/sh" "-c" "pwd"))))
  (test-assert "the child runs in default-directory"
               (let* ((text (buffer-text b))
                      (n (string-length text)))
                 (and (> n 0)
                      (char=? (string-ref text (- n 1)) #\newline)
                      (string=? (substring text 0 (- n 1)) expected)))))

;; Sending: a round trip through cat, and eof.
(let* ((b (get-buffer-create "*proc-cat*"))
       (p (make-process ':name "proc-cat" ':buffer b
                        ':command '("/bin/cat")
                        ':connection-type 'pipe)))
  (process-send-string p "hello\n")
  (let loop ((i 0))
    (accept-process-output p 0.02)
    (when (and (< i 200) (< (string-length (buffer-text b)) 6))
      (loop (+ i 1))))
  (test-equal "a process-send-string round trip" "hello\n" (buffer-text b))
  (process-send-eof p)
  (test-equal "eof ends the process" 'exit (wait-process p)))

;; process-send-region sends the buffer's text.
(let* ((b (get-buffer-create "*proc-region*"))
       (src (get-buffer-create "*proc-src*"))
       (p (make-process ':name "proc-region" ':buffer b
                        ':command '("/bin/cat")
                        ':connection-type 'pipe
                        ':sentinel no-op-sentinel)))
  (set-buffer src)
  (insert "region-text")
  (process-send-region p (point-min) (point-max))
  (process-send-eof p)
  (wait-process p)
  (test-equal "process-send-region" "region-text" (buffer-text b)))

;; delete-process.
(let* ((p (make-process ':name "proc-del" ':buffer #f
                        ':command '("/bin/sleep" "30")
                        ':connection-type 'pipe)))
  (delete-process p)
  (test-equal "delete-process sets a signal status" 'signal
              (process-status p))
  (test-equal "delete-process removes it from the list"
              #f (get-process "proc-del")))

;; signal-process.
(let* ((p (make-process ':name "proc-sig" ':buffer #f
                        ':command '("/bin/sleep" "30")
                        ':connection-type 'pipe)))
  (test-equal "signal-process answers 0" 0 (signal-process p 15))
  (test-equal "the process reports the signal" 'signal (wait-process p))
  (test-equal "and the signal number" 15 (process-exit-status p)))

;; A pty: the tty name, and the child seeing a terminal.
(let* ((b (get-buffer-create "*proc-pty*"))
       (p (make-process ':name "proc-pty" ':buffer b
                        ':command '("/bin/sh" "-c" "test -t 0 && echo TTY")
                        ':connection-type 'pty)))
  (test-assert "a pty process has a tty name"
               (and (string? (process-tty-name p))
                    (string-prefix? "/dev/" (process-tty-name p))))
  (wait-process p)
  (test-assert "the child's stdin is a terminal"
               (string-contains (buffer-text b) "TTY")))

(test-end "schemacs_process")
