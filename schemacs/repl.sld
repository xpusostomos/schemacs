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
  ;; **The server is Guile's, and lives in `schemacs/coop-server.scm`.**
  ;; It used to be copied into this file with a line added, because
  ;; upstream's server cannot be told that it has work: its contract is
  ;; that you call `poll-coop-repl-server` periodically, and polling it is
  ;; what made the GTK editor burn a quarter of a processor doing nothing
  ;; (see `pgtk.sld`'s `pgtk-wait!` for the measurements). Now that the
  ;; notification is a hook designed into that file - `#:notify`, written
  ;; up so it could be sent upstream - this library holds only what is
  ;; actually ours: the port file, the wake, and `start-repl!`.
  ;;
  ;; **The session must be evaluated in the main thread.** A parameter
  ;; binding is thread-local, so a REPL running in a thread of its own
  ;; sees the *default* of everything the editor set with `parameterize` -
  ;; `(*current-frame*)` is #f there and `(buffer-list)` is empty. That is
  ;; why the server's reader runs in a thread but the evaluation does not:
  ;; the reader posts, and the main thread's `poll-repl!` is what resumes
  ;; the session's continuation.
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
    ;; `poll-repl!' pins the module every expression is read and
    ;; evaluated in, which is the three below; see its comment.
    (only (guile) catch getenv getpid
          resolve-module save-module-excursion set-current-module)
    ;; The server itself, and the two ends of it: `eval' queues, `poll'
    ;; runs what has been queued.
    (only (schemacs coop-server)
          spawn-coop-repl-server poll-coop-repl-server)
    (only (system repl server) make-tcp-server-socket))

  (export repl-wake set-repl-wake!
          poll-repl! remove-repl-port-file! repl-open? repl-port-file
          start-repl!)

  (begin

    ;;------------------------------------------------------------------
    ;; Telling the front end there is work
    ;;------------------------------------------------------------------

    (define %repl-wake #f)
    ;; ^ How this front end is told that the back door has something to
    ;; do, or #f when it cannot be told. A front end that sets it needs no
    ;; polling: Gtk puts the wake on the GLib main loop (`idle-add'), and
    ;; a terminal will write a byte to the descriptor its wait selects on.
    ;;
    ;; `keyboard.sld' is the reader: with a wake it does not shorten its
    ;; waits at all, which is where the GTK editor's idle CPU went.

    (define (repl-wake)
      ;; Whether this front end can be told about queued work.
      ;;--------------------------------------------------------------
      %repl-wake)

    (define (set-repl-wake! thunk)
      ;; Say how to wake this front end, or #f for one that cannot be.
      ;;--------------------------------------------------------------
      (set! %repl-wake thunk))

    ;; **A plain variable, and not a parameter, and that is the whole
    ;; point.** A parameter is a fluid, and a fluid's value is captured
    ;; per *thread*, at the moment the thread is made. The wake is called
    ;; from the server's reader thread; that thread is made by the accept
    ;; thread, which `start-repl!' makes - and `main-gtk.scm' runs
    ;; `start-repl!' *before* `main-gtk', so before the front end's
    ;; `with-gtk-display' sets this. A parameter would therefore read `#f'
    ;; in every server thread for ever, the wake would do nothing, and the
    ;; editor - whose waits are no longer shortened precisely *because* it
    ;; believes it can be woken - would block until a key. The symptom was
    ;; an idle editor that answered a REPL only after a keystroke, at 0%
    ;; CPU, which read as the idle burn having been fixed. It had not
    ;; been: the editor had stopped hearing the back door at all.
    ;;
    ;; The value is a fact about the process - which front end this is -
    ;; and not state that varies with the dynamic extent, so a variable is
    ;; what it is.

    (define (wake!)
      ;; The server's notify procedure, called from whichever thread has
      ;; queued something - never from the main thread, which is the one
      ;; being woken. It ignores the server argument, because a front end
      ;; only has to be prodded; what is queued is `poll-repl!`'s to run.
      ;; Cheap and safe to call when nobody can be woken.
      ;;--------------------------------------------------------------
      (let ((w (repl-wake)))
        (when w (w))))

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
          ;; The socket first, so that a port already taken is refused
          ;; here rather than after a server has been made. `spawn-on!'s
          ;; caller walks to the next candidate when this answers #f.
          (let ((socket (make-tcp-server-socket #:port port)))
            (set! server (spawn-coop-repl-server socket #:notify (lambda (s) (wake!))))
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
      ;; `REPL-WAKE' never has to ask - see the note on it.
      ;;--------------------------------------------------------------
      (and server #t))

    (define (poll-repl!)
      ;; Run whatever the back door has queued. Called by the loops that
      ;; wait: from the wake where the front end can give one, and from a
      ;; timed turn where it cannot.
      ;;
      ;; **The whole queue is drained, not one item.** A wake says "there
      ;; is work", not "there is one item of work" - Gtk's `idle-add` is
      ;; one source per item today, but a wake that coalesces or a byte
      ;; that stands for a run of items is no less correct, and draining
      ;; makes this indifferent to which it is. That is what
      ;; `poll-coop-repl-server` answering #t or #f is for.
      ;;
      ;; **The module is pinned, and that is not decoration.** This
      ;; procedure is reached from wherever the editor's thread was
      ;; waiting, at whatever depth: the command loop between keys, or a
      ;; command's own prompt - and a prompt is read from inside
      ;; `(eval spec module)', so it has *that command's* module bound
      ;; for as long as it waits. Guile's REPL reads and evaluates every
      ;; expression in `(current-module)' (`(system repl repl)'), so
      ;; without this the meaning of what is typed at the back door
      ;; would depend on how deep the editor happened to be nested:
      ;; measured, `(module-name (current-module))` answered
      ;; `(guile-user)` at idle and was an *unbound variable* while
      ;; "Find file:" was up, because the module was then
      ;; `(schemacs editor files)` - a library that has no `import` to
      ;; offer, which broke the documented `tools/repl.py -m'.
      ;;
      ;; `(guile-user)` is what that tool's own docstring promises, and
      ;; it is where a name like `import` lives. Everyone else's module
      ;; is theirs; the back door's is ours.
      ;;--------------------------------------------------------------
      (when server
        (save-module-excursion
         (lambda ()
           (set-current-module (resolve-module '(guile-user)))
           (let loop ()
             (when (poll-coop-repl-server server) (loop)))))))

    (define (remove-repl-port-file!)
      ;; Delete the file this process wrote, if it wrote one. Called on
      ;; the way out; a file a *crash* leaves behind is the reader's
      ;; problem - `tools/repl.py' ignores one whose editor is gone.
      ;;--------------------------------------------------------------
      (when *repl-port*
        (catch #t (lambda () (delete-file (repl-port-file))) (lambda (k . a) #f))
        (set! *repl-port* #f)))

    ))
