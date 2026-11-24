(define-library (schemacs ui tty tty-main)
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
  ;; - and this is the half that knows about the terminal. `main-tty.scm`
  ;; stays the entry point and calls `MAIN-NCURSES` here.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is the last step of.

  (import
    (scheme base)
    ;; Opening the terminal - curses mode, the display object, the face
    ;; initialization - is `term.sld''s (the mirror of Emacs's term.c);
    ;; what is left here is the entry point that opens an editor on one.
    (only (schemacs ui tty term) with-terminal)
    (only (schemacs frame) *current-frame* new-frame)
    ;; Everything this needs of the editor: the buffers named on the
    ;; command line - which is `startup.el''s job, not this one's - and
    ;; then the command loop.
    ;; The first buffer is made through the buffer list, so that it is a
    ;; buffer the editor can find again by name - `buffer.c'.
    (only (schemacs buffer) *scratch-buffer-name* get-buffer-create)
    (only (schemacs files) note-file-read-only!)
    (only (schemacs startup) command-line-1)
    (only (schemacs keyboard) event-loop)
    ;; And the libraries that carry key bindings, imported for that alone:
    ;; a binding is installed when the library that states it is loaded
    ;; (`DEFINE-KEY' at load time, as `(define-key global-map ...)' is in
    ;; Emacs Lisp), so an editor that never loads `simple' has no C-f and
    ;; no `self-insert-command'. GNU Emacs has the same requirement and
    ;; meets it the same way - `loadup.el' loads simple.el, files.el,
    ;; window.el and the rest before the first command runs. Anything that
    ;; adds bindings has to be named here too.
    (only (schemacs simple))
    (only (schemacs isearch))
    (only (schemacs window))
    (only (schemacs buff-menu))
    ;; `casefiddle.c' and `paragraphs.el': M-u/M-l/M-c, C-x C-u/C-l and
    ;; M-k/M-C-k - imported for their `define-key' forms, the same
    ;; reason as the four above.
    (only (schemacs casefiddle))
    (only (schemacs textmodes paragraphs))
    ;; `fill.el`'s commands and the M-q binding it makes
    (only (schemacs textmodes fill))
    ;; `elec-pair.el`: the two modes, so M-x finds them without an
    ;; autoload (Emacs autoloads the file).
    (only (schemacs elec-pair))
    ;; `electric.el`: the C-j binding and the post-self-insert hook its
    ;; global mode installs at load, as the dump has them in Emacs.
    (only (schemacs electric))
    ;; Help mode installs `*help-mode-function*`, which is what puts
    ;; `*Help*` in `help-mode`; `C-h b` is bound by `help.scm`.
    (only (schemacs help-mode))
    ;; `describe-function`/`-variable`, whose commands `C-h f`/`-v` are
    ;; bound by that library, and the seam `describe-key` calls.
    (only (schemacs help-fns))
    ;; `novice.el`'s disabled-command prompt; loading it installs
    ;; `disabled-command-function` and the `query` form's asker, which
    ;; `command.scm`'s `run-command` reads.
    (only (schemacs novice))
    ;; `replace.el': M-% and C-M-% bind at load, the same reason as the
    ;; six above.
    ;; The mouse commands, imported for their *binding*: loading
    ;; `mouse.sld' is what puts `[down-mouse-1]' in the global map,
    ;; as Emacs's own line at the end of `mouse.el' does.
    (only (schemacs mouse))
    (only (schemacs replace))
    ;; `tool-bar.el`: the mode and its keymap. A terminal frame draws no
    ;; tool bar in a build that has a toolkit bar (`display_tool_bar` is
    ;; compiled out under `HAVE_EXT_TOOL_BAR`, which is why `emacs -nw`
    ;; shows none either), but the mode, the parameter and the `M-x`
    ;; command exist, as they do there.
    (only (schemacs tool-bar) tool-bar-setup)
    ;; `scroll-bar.el` - the toolkit binding and `scroll-bar-mode`. A
    ;; terminal draws no bars, but Emacs preloads the file in every build
    ;; and a click from a terminal mouse would reach the same command.
    (only (schemacs scroll-bar))
    ;; `tooltip.el` is preloaded in Emacs and turning it on is its load:
    ;; the mode installs `show-help-function` and the delay timer, and
    ;; with no mouse on a terminal the echo-area half is what would show.
    (only (schemacs tooltip))
    ;; The multilingual commands (`C-x RET ...`), which install their own
    ;; keys - `mule-cmds.el`. Not for a name: for the load.
    (only (schemacs international mule-cmds))
    ;; `describe-coding-system`, which the mode line's coding-system
    ;; item's mouse-1 reaches through xdisp's seam.
    (only (schemacs international mule-diag))
    ;; `dired.el': C-x d binds at load, the same reason again.
    (only (schemacs dired))
    ;; `tab-bar.el`: `C-x t ...` and the `[tab-bar]` binding are made
    ;; when it is loaded, the same reason as every line above.
    (only (schemacs tab-bar))
    ;; `face-remap.el': C-x C-M-+ and the three beside it, and the command
    ;; they call. Same reason as every line above - a binding is made by
    ;; the library that owns the command, so the front end has to load it.
    ;;
    ;; **The boot does load it, by another road**: `open-user-environment!'
    ;; imports `(schemacs imports)', which imports every editor
    ;; library. That road is the *user's* environment, though - a user
    ;; with their own `imports.scm' replaces it and gets no editor
    ;; library at all - so a front end that relies on it has bindings
    ;; that depend on a config file. This line is the one that makes them
    ;; the front end's.
    (only (schemacs face-remap))
    ;; `custom.el`'s theme half - `M-x load-theme`, `enable-theme` and
    ;; `disable-theme` register with the command table as this library
    ;; loads. Imported for that alone, as the binding-carrying libraries
    ;; above are.
    (only (schemacs theme)))

  (export
   main-tty
   with-terminal
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Main entry

    (define (main-tty . args)
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
               ;; `startup.el:1626`'s call, at the same place: after the
               ;; frame and before the init file. Nothing draws the bar
               ;; on this front end; the keymap and the mode are made
               ;; because Emacs makes them on a terminal too.
               (tool-bar-setup)
               (command-line-1 args)
               ;; as `find-file-command' does, so that a file named on the
               ;; command line that cannot be written says so too
               (note-file-read-only! frame)
               (event-loop frame)))))))

    ))
