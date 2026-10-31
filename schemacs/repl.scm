(define-library (schemacs repl)
  ;; HOW THIS EDITOR OPENS ITS BACK DOOR: the settings, and no names at all.
  ;;
  ;; **THE DOOR ITSELF IS `(scheme-utils repl server)`.** It was written here,
  ;; and the same file in scheme-shell, and it moved to the tree those two
  ;; programs share. What is left here is the part that is actually schemacs':
  ;; the settings that say what a back door in *this* editor is, made at the one
  ;; point where they can be made before anything opens one.
  ;;
  ;; **IT EXPORTS NOTHING, ON PURPOSE, and that is the fix for a real
  ;; complaint.** It used to re-export the door's procedures - `start-repl!'
  ;; behind a rename and a wrapper, `poll-repl!' and `repl-port-file' as
  ;; themselves, `repl-open?' and `remove-repl-port-file!' under schemacs'
  ;; older spellings - so that its callers went on importing the door from where
  ;; they always had. That is a facade: importing a name in order to export it
  ;; again, from a library that is not an implementation detail of anything.
  ;;
  ;; Two things went wrong because of it. A library that exports a name it also
  ;; imports **rebinds it silently**, which is what forced that rename in the
  ;; first place: without it, the wrapper called itself. And the ambiguity of
  ;; where a name lives reached out into `main.scm', which imported
  ;; `remove-repl-port-file!' and then reached back into this module for it with
  ;; `module-ref' two hundred lines later.
  ;;
  ;; So: callers import the door from the door, this library is imported for its
  ;; effect, and a name here would be the facade again.
  ;;
  ;; **A BACK DOOR IN THIS EDITOR IS TCP ON LOOPBACK, WITH ITS PORT WRITTEN
  ;; DOWN.** The port file, `tools/repl.py' and `se --repl=PORT' are all built on
  ;; that, so it is what this program asks for. The shared module's default is a
  ;; Unix socket, and its header says why that is the safer transport; changing
  ;; the transport is a separate piece of work from sharing the code, and it is
  ;; now the one line below when it is wanted.
  ;;
  ;; **The wake is NOT here.** Being woken is a property of the *front end* - the
  ;; terminal's half is `(schemacs ui ncurses term)' and Gtk's is
  ;; `(schemacs ui gtk pgtk)' - and the seam they install into is the shared
  ;; module's `repl-wake!'. What was also here was a second pair of names for it,
  ;; `repl-wake' and `set-repl-wake!' over a private variable plus an adapter to
  ;; bridge the arity, which was the facade's mistake again.
  (import
    (scheme base)
    ;; The door's settings, and only the settings: this library is imported for
    ;; its effect, so every name it takes is one it uses.
    (only (scheme-utils repl server)
          repl-directory-name! repl-transport-tcp! repl-module!
          repl-before-start! repl-after-poll!)
    ;; The session's namespace, which `(schemacs editor loadup)' builds:
    ;; `$XDG_CONFIG_HOME/imports.scm' when the user has one, the whole editor
    ;; when they do not. The same environment `M-:' and the init file get,
    ;; because all three are code the editor did not write.
    (only (schemacs editor loadup) open-user-environment!)
    ;; `poll-repl!' draws after it has run something, because nothing else
    ;; would - see `repl-after-poll!' below.
    (only (schemacs editor xdisp) redisplay-frames!))

  (export)

  (begin

    ;; The name in the path is this program's, so that a listing of the runtime
    ;; directory is a listing of this editor's instances.
    (repl-directory-name! "schemacs")

    (repl-transport-tcp!)

    ;; A symbol, or a list of symbols: the shared module resolves it to a module
    ;; at poll time, on the main thread, which is the only place a parameter
    ;; binding is this editor's.
    (repl-module! '(guile-user))

    ;; THE SESSION'S NAMESPACE FIRST, so that a client already connected when
    ;; the first expression arrives finds the editor there.
    (repl-before-start! open-user-environment!)

    ;; **It redraws afterwards**, and that is not a convenience: it is
    ;; `redisplay`'s job in the C. Emacs displays a change made from outside the
    ;; command loop because its main loop redisplays after it processes input,
    ;; and a socket *is* input. Here nothing would repaint at all - measured -
    ;; because the command loop's redisplay comes *after a command*, and this
    ;; runs in the wait between them.
    ;;
    ;; `redisplay-frames!' and not `render!': the C loops over every frame, the
    ;; same reason `read-key-event' draws with it after a special event.
    (repl-after-poll! redisplay-frames!)))
