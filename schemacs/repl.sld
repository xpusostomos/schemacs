(define-library (schemacs repl)
  ;; A development back door: talk to a *running* editor through a Guile
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
  ;; **This is Guile's cooperative server, with one line added.** The
  ;; machinery below - the queue, the reader thread, the prompt that
  ;; suspends the session so the editor keeps running - is
  ;; `(system repl coop-server)`, copied rather than imported because of
  ;; the one line: the original cannot be told that it has work, so a
  ;; program using it must *poll* it. Polling is what made the GTK editor
  ;; burn a quarter of a processor doing nothing (`pgtk.sld`'s
  ;; `pgtk-wait!` has the measurements): with the back door open,
  ;; `keyboard.sld` shortened every wait to 100 ms so the server got a
  ;; turn, and each of those turns cost ~13 ms in guile-gi crossings.
  ;;
  ;; So `coop-repl-server-eval` - the *one* place every queued operation
  ;; goes through, whether it is a new client or an expression - calls
  ;; `(*repl-wake*)` after queueing. A front end that can be woken sets
  ;; that parameter and needs no cap at all; one that cannot leaves it #f
  ;; and keeps polling, which is what `keyboard.sld` asks about.
  ;;
  ;; **The session must be evaluated in the main thread.** A parameter
  ;; binding is thread-local, so a REPL running in a thread of its own
  ;; sees the *default* of everything the editor set with `parameterize` -
  ;; `(*current-frame*)` is #f there and `(buffer-list)` is empty. That is
  ;; why the reader runs in a thread but the evaluation does not: the
  ;; reader posts, and the main thread's `poll-repl!` is what resumes the
  ;; session's continuation.
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
    ;; `@@' reaches the private bindings of Guile's REPL, which is how
    ;; `(system repl coop-server)' reaches them too.
    ;;
    ;; The rest of this list is what Guile's own cooperative server gets
    ;; for free by being a `define-module' with `#:use-module (guile)'.
    ;; This is an R7RS `define-library' with an explicit import list, so
    ;; every core binding the ported code uses has to be named - and a
    ;; name that is missing is *not* a load error, because it sits inside
    ;; a procedure body. It is an unbound variable the first time that
    ;; procedure runs, which for `with-continuation-barrier' is the first
    ;; connection.
    (only (guile) @@ call-with-prompt abort-to-prompt with-continuation-barrier
          save-module-excursion false-if-exception
          fluid-ref with-fluids current-module set-current-module
          fileno close-fdes current-warning-port
          catch getenv getpid)
    (only (system base language) current-language)
    ;; The cooperative machinery, as `(system repl coop-server)' uses it.
    (ice-9 match)
    (ice-9 threads)
    (ice-9 q)
    (srfi srfi-9)
    (only (system repl server) make-tcp-server-socket))

  (export *repl-wake*
          poll-repl! remove-repl-port-file! repl-open? repl-port-file
          start-repl!)

  (begin

    ;;------------------------------------------------------------------
    ;; The private bindings, reached the way Guile's own cooperative
    ;; server reaches them
    ;;------------------------------------------------------------------

    ;; `start-repl*' is the REPL loop itself and `prompting-meta-read' is
    ;; how it reads one thing at a time; `run-server*' is the accept loop
    ;; and the three beside it are its bookkeeping. None is exported, and
    ;; `@@' is the sanctioned way in - `(system repl coop-server)' does
    ;; exactly this, which is what makes it a technique rather than a
    ;; trick.
    (define start-repl*        (@@ (system repl repl) start-repl*))
    (define prompting-meta-read (@@ (system repl repl) prompting-meta-read))
    (define run-server*        (@@ (system repl server) run-server*))
    (define add-open-socket!   (@@ (system repl server) add-open-socket!))
    (define close-socket!      (@@ (system repl server) close-socket!))
    (define guard-against-http-request
      (@@ (system repl server) guard-against-http-request))
    ;; The session's stack, which the reader thread carries across when it
    ;; takes over the read (`make-coop-reader').
    (define *repl-stack* (@@ (system repl repl) *repl-stack*))

    ;;------------------------------------------------------------------
    ;; Telling the front end there is work
    ;;------------------------------------------------------------------

    (define *repl-wake* (make-parameter #f))
    ;; ^ How this front end is told that the back door has something to
    ;; do, or #f when it cannot be told. A front end that sets it needs no
    ;; polling: Gtk puts the wake on the GLib main loop (`idle-add'), and
    ;; a terminal will write a byte to the descriptor its wait selects on.
    ;;
    ;; `keyboard.sld' is the reader: with a wake it does not shorten its
    ;; waits at all, which is where the GTK editor's idle CPU went.

    (define (wake!)
      ;; Called from whichever thread has queued something - never from
      ;; the main thread, which is the one being woken. Cheap and safe to
      ;; call when nobody can be woken.
      ;;--------------------------------------------------------------
      (let ((w (*repl-wake*)))
        (when w (w))))

    ;;------------------------------------------------------------------
    ;; The server, and its queue
    ;;
    ;; From `(system repl coop-server)' - the record, the queue it holds,
    ;; and the two ends of it: `coop-repl-server-eval' queues, and
    ;; `poll-coop-repl-server' runs what has been queued.
    ;;------------------------------------------------------------------

    (define-record-type <coop-repl-server>
      (%make-coop-repl-server mutex queue)
      coop-repl-server?
      (mutex coop-repl-server-mutex)
      (queue coop-repl-server-queue))

    (define (make-coop-repl-server)
      (%make-coop-repl-server (make-mutex) (make-q)))

    (define (coop-repl-server-eval coop-server opcode . args)
      ;; Queue a new instruction with the symbolic name OPCODE and an
      ;; arbitrary number of arguments, to be processed the next time
      ;; COOP-SERVER is polled.
      ;;
      ;; **This is the one place everything queued goes through** - a new
      ;; client and an expression alike - which is why the wake belongs
      ;; here and nowhere else. It is the single line this file adds to
      ;; Guile's.
      ;;--------------------------------------------------------------
      (with-mutex (coop-repl-server-mutex coop-server)
        (enq! (coop-repl-server-queue coop-server)
              (cons opcode args)))
      (wake!))

    (define (poll-coop-repl-server coop-server)
      ;; Apply a pending operation, if there is one, such as evaluating an
      ;; expression typed at the REPL prompt. This must be called from the
      ;; same thread that made the server - the editor's own.
      ;;--------------------------------------------------------------
      (let ((op (with-mutex (coop-repl-server-mutex coop-server)
                  (let ((queue (coop-repl-server-queue coop-server)))
                    (and (not (q-empty? queue))
                         (deq! queue))))))
        (when op
          (match op
            (('new-repl client)
             (start-repl-client coop-server client))
            (('eval coop-repl exp)
             ((coop-repl-cont coop-repl) exp))))))

    ;;------------------------------------------------------------------
    ;; One REPL session
    ;;
    ;; Also from `(system repl coop-server)'. The trick is the prompt: the
    ;; session runs `start-repl*' to its prompt, the prompt's escape
    ;; continuation is kept, and control returns to the editor. Evaluating
    ;; the next expression means calling that continuation, which is what
    ;; `poll-coop-repl-server' does with the `eval' it dequeued - so the
    ;; session is *suspended* rather than blocking, and the editor is free
    ;; between expressions.
    ;;------------------------------------------------------------------

    (define-record-type <coop-repl>
      (%make-coop-repl mutex condvar thunk cont)
      coop-repl?
      (mutex coop-repl-mutex)
      (condvar coop-repl-condvar)   ; signaled when thunk becomes non-#f
      (thunk coop-repl-read-thunk set-coop-repl-read-thunk!)
      (cont coop-repl-cont set-coop-repl-cont!))

    (define (make-coop-repl)
      (%make-coop-repl (make-mutex) (make-condition-variable) #f #f))

    (define (coop-repl-read coop-repl)
      ;; Read an expression via the thunk stored in COOP-REPL - which the
      ;; reader thread fills in, and signals this condition variable for.
      ;;--------------------------------------------------------------
      (let ((thunk
             (with-mutex (coop-repl-mutex coop-repl)
               (unless (coop-repl-read-thunk coop-repl)
                 (wait-condition-variable (coop-repl-condvar coop-repl)
                                          (coop-repl-mutex coop-repl)))
               (let ((thunk (coop-repl-read-thunk coop-repl)))
                 (unless thunk
                   (error "coop-repl-read: condvar signaled, but thunk is #f!"))
                 (set-coop-repl-read-thunk! coop-repl #f)
                 thunk))))
        (thunk)))

    (define (store-repl-cont cont coop-repl)
      ;; Save the partial continuation CONT within COOP-REPL.
      ;;--------------------------------------------------------------
      (set-coop-repl-cont! coop-repl
                           (lambda (exp)
                             (coop-repl-prompt
                              (lambda () (cont exp))))))

    (define (coop-repl-prompt thunk)
      (call-with-prompt 'coop-repl-prompt thunk store-repl-cont))

    (define (make-coop-reader coop-repl)
      ;; A reader for `start-repl*' that hands the job of reading to
      ;; another thread and suspends this one at the prompt.
      ;;--------------------------------------------------------------
      (lambda (repl)
        (let ((read-thunk
               ;; The REPL stack and the current module have to be carried
               ;; across to the thread that reads.
               (let ((stack (fluid-ref *repl-stack*))
                     (module (current-module)))
                 (lambda ()
                   (with-fluids ((*repl-stack* stack))
                     (set-current-module module)
                     (prompting-meta-read repl))))))
          (with-mutex (coop-repl-mutex coop-repl)
            (when (coop-repl-read-thunk coop-repl)
              (error "coop-reader: read-thunk is not #f!"))
            (set-coop-repl-read-thunk! coop-repl read-thunk)
            (signal-condition-variable (coop-repl-condvar coop-repl))))
        (abort-to-prompt 'coop-repl-prompt coop-repl)))

    (define (reader-loop coop-server coop-repl)
      ;; Read an expression for COOP-REPL and store it in COOP-SERVER for
      ;; later evaluation, for ever. Runs in a thread of its own.
      ;;--------------------------------------------------------------
      (coop-repl-server-eval coop-server 'eval coop-repl
                             (coop-repl-read coop-repl))
      (reader-loop coop-server coop-repl))

    (define (start-coop-repl coop-server)
      ;; A new REPL session: a thread to read for it, and the session
      ;; itself here, in the thread that polls - which is the editor's.
      ;;--------------------------------------------------------------
      ;; `stop-server-and-clients!' from a REPL closes the socket it is
      ;; reading, so the read raises; that is not an error worth dying of.
      (catch #t
        (lambda ()
          (let ((coop-repl (make-coop-repl)))
            (make-thread reader-loop coop-server coop-repl)
            (start-repl* (current-language) #f (make-coop-reader coop-repl))))
        (lambda (key . args) #f)))

    (define (start-repl-client coop-server client)
      ;; Run a cooperative REPL for COOP-SERVER, with all its input and
      ;; output over the socket CLIENT. Runs here, in the polling thread.
      ;;--------------------------------------------------------------
      ;; The client joins the list of open sockets with a `force-close'
      ;; that closes the descriptor: the port itself cannot safely be
      ;; closed from another thread.
      (add-open-socket! client (lambda () (close-fdes (fileno client))))
      (guard-against-http-request client)
      (with-continuation-barrier
       (lambda ()
         (coop-repl-prompt
          (lambda ()
            (parameterize ((current-input-port client)
                           (current-output-port client)
                           (current-error-port client)
                           (current-warning-port client))
              (with-fluids ((*repl-stack* '()))
                (save-module-excursion
                 (lambda ()
                   (start-coop-repl coop-server)))))

            ;; This may fail if the server is being stopped, because the
            ;; `force-close' above closes the descriptor rather than the
            ;; port. It is *inside* the prompt, as Guile's is: the lambda
            ;; is what the prompt runs, and the close belongs to the
            ;; session's end rather than to its setup.
            (false-if-exception (close-socket! client)))))))

    (define (make-coop-client-proc coop-server)
      (lambda (client addr)
        (coop-repl-server-eval coop-server 'new-repl client)))

    ;;------------------------------------------------------------------
    ;; The back door
    ;;------------------------------------------------------------------

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
          (let ((coop-server (make-coop-repl-server))
                (socket (make-tcp-server-socket #:port port)))
            (set! server coop-server)
            (make-thread run-server* socket (make-coop-client-proc coop-server))
            #t))
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
      ;; Whether the back door is open. A front end that can be woken by
      ;; `*repl-wake*' never has to ask - see the note on it.
      ;;--------------------------------------------------------------
      (and server #t))

    (define (poll-repl!)
      ;; Run whatever the back door has queued, if anything. Called by the
      ;; loops that wait: from `*repl-wake*''s wake where the front end
      ;; can give one, and from a timed turn where it cannot.
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
