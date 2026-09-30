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

  (import
    (scheme base)
    (only (system repl coop-server)
          spawn-coop-repl-server poll-coop-repl-server)
    (only (system repl server) make-tcp-server-socket))

  (export poll-repl! repl-open? start-repl!)

  (begin

    (define server #f)
    ;; ^ The cooperative server, or #f when the back door is shut.

    (define (start-repl! port)
      ;; Open the back door on PORT. Called once, by an entry point that
      ;; was asked to - see `main-gtk.scm' and `SCHEMACS_REPL' in `seg'.
      ;;--------------------------------------------------------------
      (unless server
        (set! server (spawn-coop-repl-server
                      (make-tcp-server-socket #:port port)))))

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

    ))
