;; Tests for `(schemacs repl-client)': the client half of the development
;; back door, which `se --repl[=PORT]' and `se --remote[=PORT] FILE...'
;; run.
;;
;; What is tested here is the part with logic in it: **which port files
;; count, and in what order** - the convention the client shares with
;; `start-repl!' and `tools/repl.py' - that connecting to a port nobody
;; listens on answers #f rather than raising, since a port file outlives
;; the editor that wrote it, **how one answer is read** (a socket pair
;; stands in for the connection, so the prompt rule can be exercised
;; exactly), and **what `--remote' sends** for a file name.
;;
;; The rest is a session, and a session is where a unit test stops: the
;; terminal's two directions are threads and blocking reads, and the
;; server's side is an editor. It is checked by hand instead - `se -w
;; --server=PORT FILE' in one window, then
;;
;;     printf '(buffer-file-name (current-buffer))\n' | se --repl=PORT
;;
;; which answers with the *editor's* file name, because that is where the
;; expression was evaluated. AGENTS.md has it, and `tools/pty-check.py''s
;; `back-door' check drives both ends against a real editor.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme file)
 ;; `flush-output-port' and `close-port' are `(scheme base)''s (R7RS puts
 ;; the port procedures there), and the socket constants are Guile's.
 (only (guile) AF_UNIX SOCK_STREAM delete-file
       getcwd mkdir setenv getenv getpid sleep socketpair)
 (only (srfi srfi-13) string-suffix?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs repl-client) repl-port-files repl-connect
       repl-read-to-prompt repl-answer-error? repl-file-expression))

(define (now-ms)
  (quotient (* 1000 (get-internal-real-time)) internal-time-units-per-second))

(define (touch! dir pid)
  ;; A port file as `start-repl!' writes one: the port number, nothing else.
  ;;-------------------------------------------------------------
  (let ((path (string-append dir "/schemacs-repl-" (number->string pid) ".port")))
    (call-with-output-file path (lambda (out) (display (+ 20000 pid) out)))
    path))

(test-begin "schemacs_repl_client")

;;-------------------------------------------------------------
;; The port files
;;-------------------------------------------------------------
;; `start-repl!' names them `schemacs-repl-<pid>.port' and puts the port
;; number in them; the client reads the directory, keeps the ones that fit
;; that shape, and answers them newest first, which is the editor a bare
;; `--repl' means. Three of the four candidates below are the point: a file
;; of another program, a file of ours holding no number, and one holding a
;; number are told apart.
;;
;; **A second between the files, not a millisecond.** `stat:mtime` is
;; whole seconds on some filesystems, so files written in the same second
;; have no order at all, and a test that asserts one is asserting the
;; filesystem's clock.
;;-------------------------------------------------------------
(define (port-file! dir pid)
  (let ((path (string-append dir "/schemacs-repl-" (number->string pid) ".port")))
    (call-with-output-file path (lambda (out) (display (+ 20000 pid) out)))
    path))

(let* ((saved (getenv "XDG_RUNTIME_DIR"))
       (dir (string-append "/tmp/schemacs-repl-test-" (number->string (getpid)))))
  (mkdir dir)
  (call-with-output-file (string-append dir "/something-else.port")
    (lambda (out) (display 1 out)))
  (call-with-output-file (string-append dir "/schemacs-repl-999.port")
    (lambda (out) (display "not a number" out)))
  (let ((third (port-file! dir 3000)))
    (sleep 1)
    (let ((second (port-file! dir 1000)))
      (sleep 1)
      (let ((first (port-file! dir 2000)))
        (sleep 1)
        (let ((newest (port-file! dir 2500)))
          (setenv "XDG_RUNTIME_DIR" dir)
          (test-equal
              "the port files are found - ours, with a number in them - newest first"
            '(2500 2000 1000 3000)
            (map (lambda (p) (- p 20000)) (repl-port-files)))
          (for-each delete-file (list first second third newest)))))
    (for-each delete-file (list (string-append dir "/something-else.port")
                                (string-append dir "/schemacs-repl-999.port")))
    (if saved
        (setenv "XDG_RUNTIME_DIR" saved)
        (setenv "XDG_RUNTIME_DIR" ""))))

;;-------------------------------------------------------------
;; Connecting
;;-------------------------------------------------------------
(test-equal "connecting to a port nobody listens on answers #f"
  #f
  (repl-connect 38671))

;; A port file holding nothing is not a candidate at all, so `--repl' with
;; one editor gone and no other running says "no editor is running" rather
;; than trying port 0.
(test-equal "a port file with no number in it is not a candidate"
  '()
  (let* ((saved (getenv "XDG_RUNTIME_DIR"))
         (dir (string-append "/tmp/schemacs-repl-test2-" (number->string (getpid))))
         (path (string-append dir "/schemacs-repl-1.port")))
    (mkdir dir)
    (call-with-output-file path (lambda (out) (display "" out)))
    (setenv "XDG_RUNTIME_DIR" dir)
    (let ((files (repl-port-files)))
      (delete-file path)
      (if saved
          (setenv "XDG_RUNTIME_DIR" saved)
          (setenv "XDG_RUNTIME_DIR" ""))
      files)))

;;-------------------------------------------------------------
;; Reading one answer
;;-------------------------------------------------------------
;; A session is a conversation with a prompt at the end of each turn, and
;; reading an answer means reading until that prompt. The rule is subtle
;; in one place and it has to be got right, because the two commands that
;; use it (`--repl' and `--remote') both stop on it.
;;
;; A socket pair stands in for the connection: what is written into one
;; end is what the reader reads from the other.
;;-------------------------------------------------------------
(define (with-a-connection thunk)
  (let ((pair (socketpair AF_UNIX SOCK_STREAM 0)))
    (let ((server (car pair))
          (client (cdr pair)))
      (dynamic-wind
       (lambda () #t)
       (lambda () (thunk server client))
       (lambda ()
         (catch #t (lambda () (close-port server)) (lambda args #f))
         (catch #t (lambda () (close-port client)) (lambda args #f)))))))

(define (put! port text)
  (display text port)
  (flush-output-port port))

(with-a-connection
 (lambda (server client)
   (put! server "banner\nscheme@(guile-user)> ")
   (test-equal "an answer is read up to and including its prompt"
     "banner\nscheme@(guile-user)> "
     (repl-read-to-prompt client))))

;; **The one that must not stop early.** A *value* can end with `>': a
;; buffer prints as `#<buffer README.md>' (`print.c:1895'). A reader that
;; stopped at a trailing `>' would answer with the value and leave the
;; prompt - and the next expression sent would then be answered by the
;; remains of this one's answer.
(with-a-connection
 (lambda (server client)
   (put! server "$1 = #<buffer README.md>\nscheme@(guile-user)> ")
   (test-equal "a value that ends with `>' is not mistaken for the prompt"
     "$1 = #<buffer README.md>\nscheme@(guile-user)> "
     (repl-read-to-prompt client))))

;; An error leaves the REPL in a *nested* prompt - `scheme@(guile-user)
;; [1]>' - which is how the editor says it failed, and it is still a
;; prompt as far as reading is concerned.
(with-a-connection
 (lambda (server client)
   (put! server "Unbound variable: nosuch\nEntering a new prompt.\n\
scheme@(guile-user) [1]> ")
   (let ((answer (repl-read-to-prompt client)))
     (test-assert "an error's nested prompt ends the read too"
       (and answer (string-suffix? "[1]> " answer)))
     (test-assert "... and the answer is told apart from a value's"
       (repl-answer-error? answer))
     (test-assert "... while a plain answer is not"
       (not (repl-answer-error? "$1 = 3\nscheme@(guile-user)> "))))))

(with-a-connection
 (lambda (server client)
   (put! server "half an answer\n")
   (close-port server)
   (test-equal "a connection that ends before a prompt answers #f"
     #f
     (repl-read-to-prompt client))))

;;-------------------------------------------------------------
;; What `--remote' sends
;;-------------------------------------------------------------
;; One `find-file' per file, which is what the user would have typed. A
;; relative name is expanded against *this* process's directory - the one
;; the command was typed in - and not the editor's, and the name goes in
;; as a string literal, because what is sent is text to be read.
;;-------------------------------------------------------------
(test-equal "a file becomes one find-file"
  (string-append "(find-file \"" (getcwd) "/x.txt\")")
  (repl-file-expression "x.txt"))

(test-equal "an absolute name is left alone"
  "(find-file \"/a/b.txt\")"
  (repl-file-expression "/a/b.txt"))

(test-equal "a quote or a backslash in the name cannot end the literal"
  "(find-file \"/a/b\\\"c\\\\d\")"
  (repl-file-expression "/a/b\"c\\d"))

(test-end "schemacs_repl_client")
