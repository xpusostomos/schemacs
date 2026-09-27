(define-library (schemacs ui platform ncurses)
  ;; The ncurses terminal: entering and leaving curses mode, and the entry
  ;; point that opens the editor on one. This is what GNU Emacs splits
  ;; between `term.c` (the terminal itself) and `emacs.c`'s main plus
  ;; `startup.el` (opening a frame on it and loading the file named on the
  ;; command line).
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
    ;; The terminal.
    (only (ncurses curses)
          curs-set endwin idcok! idlok! initscr keypad! noecho! nonl! raw!
          scrollok! stdscr)
    (only (schemacs editor engine)
          new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) new-frame)
    ;; Everything this needs of the editor: visiting the file named on the
    ;; command line, and then running the command loop.
    ;; The first buffer is made through the buffer list, so that it is a
    ;; buffer the editor can find again by name - `buffer.c'.
    (only (schemacs editor buffer) get-buffer-create)
    (only (schemacs editor files) find-file note-file-read-only!)
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
    )

  (export
   main-ncurses
   with-terminal
   )

  (begin

    ;; Terminal setup

    (define (with-terminal thunk)
      ;; Run THUNK with the terminal in curses mode, restoring the
      ;; terminal even if THUNK raises an error.
      ;;--------------------------------------------------------------
      (dynamic-wind
        (lambda ()
          (initscr)
          (noecho!)
          ;; `raw!` (not `cbreak!`) so that C-c and C-z reach the
          ;; editor's keymap instead of raising signals.
          (raw!)
          (nonl!)
          (keypad! (stdscr) #t)
          (scrollok! (stdscr) #f)
          ;; disable the insert/delete-character optimizations: they
          ;; corrupt the display when lines merge (ncurses tracks a
          ;; virtual screen the terminal no longer matches)
          (idcok! (stdscr) #f)
          (idlok! (stdscr) #f)
          (curs-set 1)
          )
        thunk
        (lambda () (endwin))
        ))

    ;;----------------------------------------------------------------
    ;; Main entry

    (define (main-ncurses . args)
      ;; With a file argument, load the file; with no arguments, start
      ;; with an empty unnamed buffer (the scratch buffer).
      ;;------------------------------------------------------------------
      (let ((ed (if (pair? args)
                    (find-file (car args))
                    ;; no file named: the scratch buffer, which visits
                    ;; nothing and is named as GNU Emacs names it
                    (get-buffer-create "*scratch*"))))
        (with-terminal
         (lambda ()
           ;; The frame is made once the terminal is open, because its
           ;; size is the terminal's - a frame is a display of a
           ;; terminal, and knows how big that is.
           (let ((frame (new-frame ed)))
             ;; The file's line-break convention needs no installing
             ;; here: `find-file' recorded it on the buffer it visited,
             ;; where saving reads it back.
             ;;
             ;; as `find-file-command' does, so that a file named on the
             ;; command line that cannot be written says so too
             (note-file-read-only! frame)
             (event-loop frame))
           ))))

    ))
