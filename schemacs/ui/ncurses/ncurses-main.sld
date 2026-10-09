(define-library (schemacs ui ncurses ncurses-main)
  ;; The ncurses-terminal editor's entry point. Entering and leaving
  ;; curses mode, drawing and reading keys are `term.sld`'s - the mirror
  ;; of GNU Emacs's `term.c` - and what is left here is the other half
  ;; of what Emacs splits between `term.c` and `emacs.c`'s main plus
  ;; `startup.el`: opening a frame on the terminal and loading the files
  ;; named on the command line.
  ;;
  ;; It is the last piece out of `(schemacs apps ncurses-editor)`, which
  ;; held the whole frontend when LAYOUT-PLAN.txt was written: the editing
  ;; half is in `(schemacs editor *)` - twenty libraries, one per Emacs file
  ;; - and this is the half that knows about the terminal. `main-ncurses.scm`
  ;; stays the entry point and calls `MAIN-NCURSES` here.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is the last step of.

  (import
    (scheme base)
    ;; Opening the terminal - curses mode, the display object, the face
    ;; initialization - is `term.sld''s (the mirror of Emacs's term.c);
    ;; what is left here is the entry point that opens an editor on one.
    (only (schemacs ui ncurses term) with-terminal)
    (only (schemacs editor engine)
          new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) *current-frame* new-frame)
    ;; Everything this needs of the editor: the buffers named on the
    ;; command line - which is `startup.el''s job, not this one's - and
    ;; then the command loop.
    ;; The first buffer is made through the buffer list, so that it is a
    ;; buffer the editor can find again by name - `buffer.c'.
    (only (schemacs editor buffer) *scratch-buffer-name* get-buffer-create)
    (only (schemacs editor files) note-file-read-only!)
    (only (schemacs editor startup) command-line-1)
    (only (schemacs editor keyboard) event-loop)
    ;; And the libraries that carry key bindings, imported for that alone:
    ;; a binding is installed when the library that states it is loaded
    ;; (`DEFINE-KEY' at load time, as `(define-key global-map ...)' is in
    ;; Emacs Lisp), so an editor that never loads `simple' has no C-f and
    ;; no `self-insert-command'. GNU Emacs has the same requirement and
    ;; meets it the same way - `loadup.el' loads simple.el, files.el,
    ;; window.el and the rest before the first command runs. Anything that
    ;; adds bindings has to be named here too.
    (only (schemacs editor simple) self-insert-layer)
    (only (schemacs editor isearch) isearch-forward)
    (only (schemacs editor window) split-window-below)
    (only (schemacs editor buff-menu) list-buffers)
    ;; `casefiddle.c' and `paragraphs.el': M-u/M-l/M-c, C-x C-u/C-l and
    ;; M-k/M-C-k - imported for their `define-key' forms, the same
    ;; reason as the four above.
    (only (schemacs editor casefiddle))
    (only (schemacs editor paragraphs))
    ;; `replace.el': M-% and C-M-% bind at load, the same reason as the
    ;; six above.
    ;; The mouse commands, imported for their *binding*: loading
    ;; `mouse.sld' is what puts `[down-mouse-1]' in the global map,
    ;; as Emacs's own line at the end of `mouse.el' does.
    (only (schemacs editor mouse))
    (only (schemacs editor replace))
    ;; The multilingual commands (`C-x RET ...`), which install their own
    ;; keys - `mule-cmds.el`. Not for a name: for the load.
    (only (schemacs editor mule-cmds))
    ;; `dired.el': C-x d binds at load, the same reason again.
    (only (schemacs editor dired))
    )

  (export
   main-ncurses
   with-terminal
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Main entry

    (define (main-ncurses . args)
      ;; The editor's entry point: GNU Emacs's `command-line'. There is
      ;; always a `*scratch*' buffer - Emacs makes one before it looks at
      ;; the command line, and every file named is visited after it - and
      ;; what the names on the command line do is `startup.el''s, which is
      ;; `command-line-1'.
      ;;------------------------------------------------------------------
      (let ((scratch (get-buffer-create *scratch-buffer-name*)))
        (with-terminal
         (lambda ()
           ;; The frame is made once the terminal is open, because its
           ;; size is the terminal's - a frame is a display of a
           ;; terminal, and knows how big that is.
           (let ((frame (new-frame scratch)))
             ;; The frame is the selected frame from here on, which is GNU
             ;; Emacs's `select-frame' - `frame-initialize' calls it as soon
             ;; as the first frame is made. It matters before the command
             ;; loop starts: `command-line-1' shows the files named on the
             ;; command line in the *selected* window, so it has to be
             ;; current before it runs.
             (parameterize ((*current-frame* frame))
               (command-line-1 args)
               ;; as `find-file-command' does, so that a file named on the
               ;; command line that cannot be written says so too
               (note-file-read-only! frame)
               (event-loop frame)))))))

    ))
