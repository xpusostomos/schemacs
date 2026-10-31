(define-library (schemacs repl-client)
  ;; The client half of the development back door: `se --repl[=NAME]', which
  ;; gives a running editor's terminal back to it as a REPL, and
  ;; `se --remote[=NAME] FILE...', which opens files in one.
  ;;
  ;; **IT STARTS NO EDITOR.** This is `emacsclient' the other way round: the
  ;; server side - `(server-start)', here `start-repl!' - is what an editor opens
  ;; with `--server', and this connects to one of those. What is typed here is
  ;; read and evaluated *in the editor's process*, at the back door
  ;; (`poll-repl!'), so this needs nothing but a socket - and it deliberately
  ;; does not load the editor's libraries, so that `se --repl' cannot start an
  ;; editor even by accident.
  ;;
  ;; **THE CLIENT ITSELF IS NOT HERE ANY MORE.** It was: the socket, the prompt,
  ;; the answer-to-an-error test, the expression text and the two threads of an
  ;; interactive session. Then the same code was written again in scheme-shell,
  ;; so all of it is `(scheme-utils repl client)' now and both programs ask it.
  ;; What is left here is the one thing that is schemacs': WHICH EDITOR a bare
  ;; `--repl' means.
  ;;
  ;; **A BARE `--repl' MEANS THE NEWEST EDITOR THAT ANSWERS.** That is the rule
  ;; the port files had ("the one started last"), and a socket's name still
  ;; carries the pid, so it is the same rule over a transport whose name is its
  ;; address. `SCHEMACS_INSTANCE=work se' names an editor instead, and then
  ;; `se --repl=work' asks for that one by name - which is the thing a Unix
  ;; socket can do and a port could not.
  (import
    (scheme base)
    (only (scheme-utils repl client)
          repl-connect repl-eval repl-run-session)
    ;; WHERE THE SOCKETS ARE, and which of them answer. The directory is this
    ;; program's, so listing it lists this editor's doors and nobody else's.
    (only (scheme-utils repl server) repl-directory socket-alive?)
    ;; `scandir', the clock and the working directory: the client's own
    ;; business. Nothing here reaches for the editor's libraries.
    (only (ice-9 ftw) scandir)
    ;; `sort' is `(guile)''s and not `(srfi srfi-1)''s in this Guile (measured:
    ;; importing it from srfi-1 fails the whole library with "no binding `sort'").
    (only (guile) catch getcwd sort stat stat:mtime)
    (only (srfi srfi-13) string-append string-suffix?))

  ;; THE TWO THE COMMAND LINE CALLS, and the two the suite tests: what
  ;; `--remote' puts on the wire, and which editor a bare `--repl' means.
  (export run-repl-client run-remote-files repl-file-expression repl-endpoint)

  (begin

    ;;------------------------------------------------------------------
    ;; Which editor
    ;;------------------------------------------------------------------

    (define (live-sockets)
      ;; The sockets in this program's directory that ANSWER, newest first.
      ;;
      ;; **Sorted by mtime, not by name**: a pid says nothing about when an
      ;; editor started, and "the one started last" is the rule the port files
      ;; used, so it is the rule here. A socket file outlives the editor that
      ;; made it, so which of them are *live* is settled by connecting -
      ;; `socket-alive?' - and never by the file being there.
      ;;--------------------------------------------------------------
      (let ((dir (catch #t repl-directory (lambda args #f))))
        (if (not dir)
            '()
            (let loop ((rest (catch #t (lambda () (scandir dir)) (lambda args '())))
                       (found '()))
              (cond
               ((null? rest)
                (map cdr (sort found (lambda (a b) (> (car a) (car b))))))
               ((not (string-suffix? ".sock" (car rest)))
                (loop (cdr rest) found))
               (else
                (let ((path (string-append dir "/" (car rest))))
                  (if (not (socket-alive? path))
                      (loop (cdr rest) found)
                      (let ((mtime (catch #t
                                     (lambda () (stat:mtime (stat path)))
                                     (lambda args 0))))
                        (loop (cdr rest) (cons (cons mtime path) found)))))))))))

    (define (repl-endpoint name option)
      ;; The socket path to talk to, or an error worth its own words.
      ;;
      ;; "no editor is running with the back door open" and "there is no editor
      ;; called that" are different things, and a user can act on the
      ;; difference: the first is fixed by starting one with `--server', the
      ;; second by asking for the name that exists. OPTION is `--repl' or
      ;; `--remote', for the message.
      ;;--------------------------------------------------------------
      (cond
       (name
        (let ((path (string-append (repl-directory) "/" name ".sock")))
          (if (socket-alive? path)
              path
              (error (string-append "no editor is called `" name "': nothing is "
                                    "listening on " path)))))
       (else
        (let ((live (live-sockets)))
          (if (pair? live)
              (car live)
              (error (string-append "no editor is running with the back door "
                                    "open, so " option " has nothing to "
                                    "connect to")))))))

    ;;------------------------------------------------------------------
    ;; `--repl'
    ;;------------------------------------------------------------------

    (define (run-repl-client name)
      ;; Find a server, connect to it, and be a REPL for it. NAME when
      ;; `--repl=NAME' named one, otherwise the newest editor that answers.
      ;;--------------------------------------------------------------
      (let ((socket (repl-connect (repl-endpoint name "--repl"))))
        (unless socket
          (error "the editor stopped between being found and being connected to"))
        (repl-run-session socket)))

    ;;------------------------------------------------------------------
    ;; `--remote'
    ;;------------------------------------------------------------------

    (define (repl-file-expression file)
      ;; What `--remote' sends for FILE: one `find-file', which is the command
      ;; the user would have typed.
      ;;
      ;; A RELATIVE NAME IS EXPANDED AGAINST THIS PROCESS'S DIRECTORY, which is
      ;; where the user typed the command and not where the editor is.
      ;;
      ;; **It is text to be READ**, so the name goes in as a string literal,
      ;; written out character by character - a name with a quote or a
      ;; backslash in it would otherwise end the literal or escape what
      ;; follows.
      ;;--------------------------------------------------------------
      (let ((name (if (and (> (string-length file) 0)
                           (char=? #\/ (string-ref file 0)))
                      file
                      (string-append (getcwd) "/" file))))
        (let loop ((i 0) (out "(find-file \""))
          (if (>= i (string-length name))
              (string-append out "\")")
              (let ((c (string-ref name i)))
                (loop (+ i 1)
                      (string-append out
                                     (if (or (char=? c #\") (char=? c #\\))
                                         (string #\\ c)
                                         (string c)))))))))

    (define (run-remote-files name files)
      ;; `--remote': open FILES in a running editor and leave. It is
      ;; `emacsclient' in one direction and no more than that - there is no
      ;; `server.el' protocol here, no `-dir' handshake and no
      ;; `find-file-noselect'/window dance: each name becomes one `find-file',
      ;; evaluated by the editor, and the editor draws the result.
      ;;
      ;; **Nothing is printed when it works.** The editor is the answer, which
      ;; is what `emacsclient' does too; an error the editor reported is
      ;; RAISED, so the launcher prints it and exits 1 - which is `repl-eval''s
      ;; default and the reason it has an option at all.
      ;;--------------------------------------------------------------
      (let ((path (repl-endpoint name "--remote")))
        (for-each (lambda (file) (repl-eval path (repl-file-expression file)))
                  files)))

    ))
