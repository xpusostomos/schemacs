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
          colors curs-set endwin has-colors? idcok! idlok! initscr keypad! noecho!
          nonl! raw! scrollok! start-color! stdscr use-default-colors)
    (only (schemacs editor engine)
          new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) *current-frame* new-frame)
    ;; `startup.el' registers the eight standard colours before the
    ;; terminal's own initialization runs; `term/xterm.el' is that
    ;; initialization for an xterm.
    (only (schemacs editor tty-colors) tty-register-default-colors)
    (only (schemacs editor xterm) terminal-init-xterm)
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          face-list face-spec-recalc)
    (only (guile) getenv string-prefix?)
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
    )

  (export
   main-ncurses
   with-terminal
   )

  (begin

    ;; Terminal setup

    (define (terminal-background-mode)
      ;; GNU Emacs's `frame--current-background-mode' when nothing has
      ;; said what the background is - no `frame-background-mode', no
      ;; `background-mode' terminal parameter, and a tty whose
      ;; `background-color' is "unspecified-bg": `light' for a tty whose
      ;; type is xterm, rxvt, dtterm or eterm, else `dark'. An xterm that
      ;; answers `term/xterm.el''s query does not get here.
      ;;--------------------------------------------------------------
      (let ((term (or (getenv "TERM") "")))
        (if (or (string-prefix? "xterm" term)
                (string-prefix? "rxvt" term)
                (string-prefix? "dtterm" term)
                (string-prefix? "eterm" term))
            'light
            'dark)))

    (define (initialize-display-faces!)
      ;; What `startup.el' does to the terminal's faces, in its order:
      ;; `tty-register-default-colors', then
      ;; `tty-run-terminal-initialization' - which for TERM=xterm* is
      ;; `terminal-init-xterm' - then `frame-set-background-mode' and the
      ;; faces realized against what all that found out. The display's
      ;; class and colour count are ncurses's answers, which it only has
      ;; once `initscr' has run.
      ;;--------------------------------------------------------------
      (*display-type* (if (has-colors?) 'color 'mono))
      (*display-color-cells* (if (has-colors?) (max 1 (colors)) 0))
      (tty-register-default-colors)
      (when (string-prefix? "xterm" (or (getenv "TERM") ""))
        (terminal-init-xterm))
      (unless (*frame-background-mode*)
        (*frame-background-mode* (terminal-background-mode)))
      (for-each face-spec-recalc (face-list)))

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
          ;; Colours have to be started before a pair can be defined, and
          ;; asking first keeps a monochrome terminal from being told to do
          ;; something it cannot. `(schemacs editor xdisp)' defines the
          ;; pairs the faces ask for.
          (when (has-colors?)
            (start-color!)
            ;; A face that sets only one of its colours leaves the other
            ;; as the terminal's own - `term.c''s `turn_on_face' simply
            ;; does not send `setaf' for `FACE_TTY_DEFAULT_COLOR'. In
            ;; ncurses that colour is -1, and `init_pair' refuses -1
            ;; unless this has been called: without it Emacs's `region'
            ;; on a 16-colour dark display - `blue3' and no foreground -
            ;; came out as pair 0, black on black.
            (use-default-colors))
          (initialize-display-faces!)
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
