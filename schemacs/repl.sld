(define-library (schemacs repl)
  ;; A development back door: talk to a *running* editor through Guile's
  ;; REPL server, so its own state can be read and poked without keys,
  ;; without a compositor, and without restarting it.
  ;;
  ;; Why this is worth having, in one sentence: the alternative for the GTK
  ;; backend is `wtype` to type at the window and `grim` to look at it, and
  ;; a keyed run goes to whichever window the compositor has focused, which
  ;; is not necessarily the editor. A silent mis-focus then produces a
  ;; screenshot of *something else* that looks exactly like evidence, and
  ;; one was believed here before the mis-focus was noticed. A REPL cannot
  ;; mis-focus: it is the process.
  ;;
  ;; It must be the *cooperative* server, not `--listen`. Guile's ordinary
  ;; REPL server runs the REPL in a thread of its own, and `make-parameter`
  ;; makes a fluid - a fluid binding is thread-local - so that thread sees
  ;; the *default* of every parameter the editor set with `parameterize`.
  ;; `(*current-frame*)` is #f there and `(buffer-list)` is empty, which is
  ;; no use at all. The cooperative server evaluates in the thread that
  ;; polls it, which is the editor's own.
  ;;
  ;; So the editor polls, where it waits:
  ;;
  ;;   * `pgtk.sld` polls once per turn of the loop it waits in, so a
  ;;     windowed editor answers while it is idle;
  ;;   * `keyboard.sld` polls once per command, so a terminal one answers
  ;;     between keys - its read blocks in `getch` and there is nothing
  ;;     else to hang it on.
  ;;
  ;; Both are no-ops until `start-repl!` has been called, so a normal run
  ;; pays a `#f` test per key and nothing else.
  ;;
  ;; **The port is written down**, in `$XDG_RUNTIME_DIR/schemacs-repl-PID`
  ;; (or `/tmp`, when the variable is unset; the runtime directory is a
  ;; tmpfs the session manager empties at logout, which is what makes it
  ;; the right home for a file that must not outlive the session). It is
  ;; there because a port nobody can name is no better than a fixed one:
  ;; `tools/repl.py` reads this file rather than computing anything, the
  ;; way `emacsclient` reads `$XDG_RUNTIME_DIR/emacs/server` rather than
  ;; working out a socket. A file left behind by a killed editor is
  ;; recognised by its *pid* - which is in the name - and ignored.
  ;;
  ;; This is not a port of `server.el': there is no `server-name`, no
  ;; `server-start` command, no socket file and none of the client
  ;; machinery. It is a back door for development, and that is all it
  ;; claims to be.

  (import
    (scheme base)
    ;; `(scheme file)' is here for `call-with-output-file' and
    ;; `delete-file' both - and `delete-file' must NOT also come from
    ;; `(guile)', which exports its own: the same name from two libraries
    ;; is a conflicting import in a `define-library', and the library then
    ;; does not compile at all.
    (scheme file)
    ;; a message needs saying, and `display' is `(scheme write)''s
    ;; (`newline' is `(scheme base)''s)
    (only (scheme write) display)
    (only (guile) catch getenv getpid)
    (only (system repl coop-server)
          spawn-coop-repl-server poll-coop-repl-server)
    (only (system repl server) make-tcp-server-socket))

  (export poll-repl! remove-repl-port-file! repl-open? repl-port-file
          start-repl!)

  (begin

    (define server #f)
    ;; ^ The cooperative server, or #f when the back door is shut.

    (define *repl-port* #f)
    ;; ^ The port it took, once it is open.

    (define (repl-port-file)
      ;; Where this process writes the port it took. The pid is in the
      ;; name so that several editors can have the back door open at once
      ;; and each file says which editor it belongs to.
      ;;--------------------------------------------------------------
      (string-append (or (getenv "XDG_RUNTIME_DIR") "/tmp")
                     "/schemacs-repl-" (number->string (getpid)) ".port"))

    (define (write-port! port)
      ;; Put the port where `tools/repl.py' looks for it.
      ;;--------------------------------------------------------------
      (call-with-output-file (repl-port-file)
        (lambda (out) (display port out))))

    (define (spawn-on! port)
      ;; The server on PORT, or #f when it cannot have it. A port already
      ;; in use is not an error worth stopping for: this is a back door.
      ;;--------------------------------------------------------------
      (catch #t
        (lambda ()
          (set! server (spawn-coop-repl-server
                        (make-tcp-server-socket #:port port)))
          #t)
        (lambda (key . args) #f)))

    (define (start-repl! . args)
      ;; Open the back door. PORT as an argument, or `SCHEMACS_REPL''s
      ;; number passed by an entry point - otherwise one is chosen here
      ;; and written to `repl-port-file'.
      ;;
      ;; A chosen port starts at 20000 + this process's pid reduced into
      ;; 0..11999, which is below Linux's ephemeral range (32768..60999 by
      ;; default) so that an ordinary outbound connection is not sitting on
      ;; it, and it walks upward from there until one binds. The number
      ;; never has to be known by anyone: it is in the file.
      ;;--------------------------------------------------------------
      (unless server
        (let ((port (if (pair? args) (car args)
                        (+ 20000 (modulo (getpid) 12000)))))
          (let loop ((candidate port) (left 32))
            (cond ((<= left 0)
                   ;; Every candidate was taken. Say so: otherwise "the
                   ;; door is shut" and "nobody asked for a door" look
                   ;; exactly alike from outside, which is a confusing
                   ;; thing to debug from.
                   (display "schemacs: no free port for the REPL back door")
                   (newline))
                  ((spawn-on! candidate)
                   (set! *repl-port* candidate)
                   (write-port! candidate))
                  (else (loop (+ candidate 1) (- left 1))))))))

    (define (repl-open?)
      ;; Whether the back door is open, so a wait can be shortened to give
      ;; the server a turn. The wait *blocks* otherwise, and a blocked
      ;; wait never polls: with this, a session that has opened the door
      ;; answers promptly and one that has not is not slowed at all.
      ;;--------------------------------------------------------------
      (and server #t))

    (define (poll-repl!)
      ;; Give the server a turn, if it is open. Called from the loops that
      ;; wait; cheap enough to call unconditionally.
      ;;--------------------------------------------------------------
      (when server
        (poll-coop-repl-server server)))

    (define (remove-repl-port-file!)
      ;; Delete the file this process wrote, if it wrote one. Called on
      ;; the way out; a file a *crash* leaves behind is the reader's
      ;; problem - `tools/repl.py' ignores one whose editor is gone.
      ;;--------------------------------------------------------------
      (when *repl-port*
        (catch #t (lambda () (delete-file (repl-port-file))) (lambda (k . a) #f))
        (set! *repl-port* #f)))

    ))
