(define-library (schemacs ui tty term)
  ;; This library mirrors GNU Emacs's `term.c': the text terminal, and
  ;; the only thing that writes to it.
  ;;
  ;; **There is one writer here, and that is the point.** It used to draw
  ;; through ncurses: `addstr' filled ncurses's virtual screen and
  ;; `refresh' flushed it, while everything else - the glyph matrices, the
  ;; row diff - was ours. Two accounts of the same screen. Measured, that
  ;; is not a theoretical worry: writing a face's attribute bytes
  ;; ourselves put all of them ahead of every glyph ncurses would later
  ;; flush, so no face could ever be applied, and asking ncurses to hold a
  ;; row diff of ours meant its own scroll shortcut moved the screen under
  ;; us. See `plans/TTY.md`.
  ;;
  ;; So the screen is ours now, and this file is Emacs's half of it:
  ;;
  ;;   `with-terminal'        init_tty + init_sys_modes + a frame
  ;;   `write-glyphs!'        tty_write_glyphs    (term.c:973)
  ;;   `clear-end-of-line!'   tty_clear_end_of_line
  ;;   `cursor-to!'           tty_cursor_to       (term.c:408)
  ;;   `clear-to-end!'        tty_clear_to_end
  ;;   `clear-frame!'         tty_clear_frame
  ;;   `update-begin!'        tty_update_begin
  ;;   `update-end!'          tty_update_end     (term.c:254)
  ;;   `set-terminal-modes!'  tty_set_terminal_modes   (term.c:202)
  ;;   `reset-terminal-modes!' tty_reset_terminal_modes (term.c:231)
  ;;   `realize-face'         realize_tty_face    (xfaces.c:6756)
  ;;   plus `turn_on_face' / `turn_off_face' (term.c:2111, :2203)
  ;;
  ;; The cursor-motion cost model is `(schemacs ui tty cm)' and the
  ;; terminal's modes and size are `(schemacs ui tty sysdep)' - both
  ;; `src/' files of their own in Emacs, and both libraries here.
  ;;
  ;; ncurses is `libtinfo' to this file now and nothing more: the
  ;; capability database `(schemacs ui tty tinfo)' reads, exactly as
  ;; GNU Emacs uses it.
  (import
    (scheme base)
    ;; `string-ci=?' compares `$COLORTERM' with "truecolor"
    ;; case-insensitively, as `term.c''s `strcasecmp' does.
    (only (scheme char) string-ci=?)
    ;; `display` is `(scheme write)`'s - `(scheme base)` does not export
    ;; it, which this file's gotcha section records. A helper written
    ;; with it dies on its first line and leaves an empty log behind.
    (only (scheme write) display)
    (oop goops)
    ;; The terminal database: `tgetstr`, `tparm`, `tputs`. This is the
    ;; half of ncurses Emacs links, and the only half this file uses.
    (only (schemacs ui tty tinfo) setup-term tgetstr tigetstr
          tigetnum tigetflag tparm tputs)
    ;; `src/cm.c`: the cursor-motion cost model.
    (schemacs ui tty cm)
    ;; `src/sysdep.c`: the terminal's modes, how big it is, and the byte
    ;; reader `xterm.el`'s terminal queries need.
    (only (schemacs ui tty sysdep)
          init-sys-modes reset-sys-modes get-tty-size *tty-fd*
          tty-read-query-byte tty-unread-query-bytes tty-flush-query-input
          tty-pushed-bytes? set-read-timeout! tty-read-byte)
    ;; The display interface this implements.
    (schemacs editor dispnew)
    (only (schemacs editor faces) *undefined-face-attribute*)
    (only (schemacs editor xfaces) attribute-value realize-tty-face)
    ;; `write-glyphs!` reads the row and the glyphs it is handed, exactly
    ;; as `tty_write_glyphs_1` reads `struct glyph`.
    (only (schemacs editor glyph)
          glyph-char glyph-face-id glyph-pixel-width glyph-row-y)
    ;; Opening a terminal runs `startup.el`'s color and face
    ;; initialization against it.
    (only (schemacs editor tty-colors) tty-register-default-colors)
    (only (schemacs ui tty xterm)
          *input-decode-map* terminal-init-xterm
          *xterm--set-selection*
          xterm--tty-set-selection xterm--tty-get-selection)
    (only (schemacs editor frame) *tty-select-active-regions*
          *frame-list* frame-output change-frame-size
          do-pending-window-change)
    ;; `init_signals` and the quit flag (`keyboard.c`): C-g and C-\ are the
    ;; terminal's interrupt characters, so they arrive as signals.
    (only (schemacs editor keyboard) init-signals *quit-flag* quit-char)
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          face-list face-spec-recalc)
    ;; The clock a read's deadline is measured with.
    (only (rnrs io ports) get-bytevector-some put-u8 get-u8)
    (only (rnrs bytevectors) bytevector-length bytevector-u8-ref)
    (only (guile) getenv string-prefix? logior logand ash delq
          delete last-pair caddr sort
          ;; `select` waits on the keyboard descriptor and the back door's
          ;; pipe - the same call GNU Emacs makes as `pselect`
          ;; (`process.c:5830').
          select sigaction SIGWINCH
          ;; The back door's wake: a pipe this process selects on, written
          ;; by the cooperative server's reader thread.
          pipe setvbuf
          get-internal-real-time internal-time-units-per-second)
    ;; The back door - how a client's work is handed to this thread.
    (only (scheme-utils repl server) repl-wake!)
    ;; **Nothing from the back door.** The command loop asks
    ;; `(schemacs editor keyboard)` for a timed read when the REPL is open
    ;; - `read-timeout-or` with a 100 ms cap for a front end that cannot be
    ;; woken - and calls `poll-repl!` between keys. That is all a terminal
    ;; needs; the pipe this library used to install existed to shorten the
    ;; wait with a `select`, and `read-input-event`'s `VTIME` does that
    ;; without one.
    )

  (export
   with-terminal
   ;; The display object for an open terminal, for tests that want to
   ;; ask it something directly; nothing in the editor uses it by name.
   <tty-display>
   ;; The capability table, for the tests that pin what the terminal was
   ;; told - the same ones `term.c`'s `TS_*` fields hold.
   tty-capability
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The terminal, and what it can do
    ;;
    ;; Every field here is a `TS_*` from `struct tty_display_info`
    ;; (`termchar.h`), filled the way `tty_init` fills it
    ;; (`term.c:4597-4762`) and used the way `term.c`'s hooks use it. It
    ;; is a Scheme record rather than a C struct for the same reason
    ;; `<cm>` is: nothing subclasses it, and every read is hot.
    ;;------------------------------------------------------------------

    (define-record-type <tty-caps>
      (make-tty-caps)
      tty-caps?
      ;; the screen's size, and the cursor-motion model
      (rows tty-rows set-tty-rows!)
      (cols tty-cols set-tty-cols!)
      (cm tty-cm set-tty-cm!)
      ;; the output capabilities, termcap's two-letter names
      (clr-to-bottom tty-clr-to-bottom set-tty-clr-to-bottom!)
      (clr-line tty-clr-line set-tty-clr-line!)
      (clr-frame tty-clr-frame set-tty-clr-frame!)
      (orig-pair tty-orig-pair set-tty-orig-pair!)
      (set-foreground tty-set-foreground set-tty-set-foreground!)
      (set-background tty-set-background set-tty-set-background!)
      (rgb-separate tty-rgb-separate set-tty-rgb-separate!)
      (enter-bold tty-enter-bold set-tty-enter-bold!)
      (enter-italic tty-enter-italic set-tty-enter-italic!)
      (enter-dim tty-enter-dim set-tty-enter-dim!)
      (enter-underline tty-enter-underline set-tty-enter-underline!)
      (exit-underline tty-exit-underline set-tty-exit-underline!)
      (enter-strike tty-enter-strike set-tty-enter-strike!)
      (enter-overline tty-enter-overline set-tty-enter-overline!)
      (standout tty-standout set-tty-standout!)
      (end-standout tty-end-standout set-tty-end-standout!)
      (exit-attribute tty-exit-attribute set-tty-exit-attribute!)
      (cursor-visible tty-cursor-visible set-tty-cursor-visible!)
      (cursor-normal tty-cursor-normal set-tty-cursor-normal!)
      (cursor-invisible tty-cursor-invisible set-tty-cursor-invisible!)
      (cursor-hidden tty-cursor-hidden set-tty-cursor-hidden!)
      (cursor-off tty-cursor-off set-tty-cursor-off!)
      (keypad-mode tty-keypad-mode set-tty-keypad-mode!)
      (end-keypad-mode tty-end-keypad-mode set-tty-end-keypad-mode!)
      (termcap-modes tty-termcap-modes set-tty-termcap-modes!)
      (end-termcap-modes tty-end-termcap-modes set-tty-end-termcap-modes!)
      ;; what the terminal is: booleans and counts
      (max-colors tty-max-colors set-tty-max-colors!)
      (autowrap tty-autowrap set-tty-autowrap!)
      (magicwrap tty-magicwrap set-tty-magicwrap!)
      (standout-mode tty-standout-mode set-tty-standout-mode!)
      (visible-cursor tty-visible-cursor set-tty-visible-cursor!))

    (define %terminal #f)
    ;; ^ The one open terminal, or #f. GNU Emacs has a list of terminals
    ;; (`terminal_list'); this tree has one per process, and `with-terminal'
    ;; is what opens and closes it.

    (define (tty-capability)
      ;; The open terminal's capability table, for a test that wants to
      ;; know what it was told.
      ;;--------------------------------------------------------------
      %terminal)

    (define *tty-inverse-video* (make-parameter #f))
    ;; ^ GNU Emacs's `inverse-video` (a `DEFVAR_BOOL`, `dispnew.c:7202`):
    ;; "Non-nil means invert the video attributes of all frames." It picks
    ;; *which way* the standout toggle goes for a default-coloured face
    ;; (`term.c:2119`), and it is a user option, so it is a parameter here.

    (define *tty-direct-color* (make-parameter #f))
    ;; ^ Non-#f when the terminal can be told a colour by its 24-bit value
    ;; instead of by palette index - GNU Emacs's `TF_rgb_separate' and
    ;; `TN_max_colors = 16777216` (`term.c:4755`).

    (define %output #f)
    ;; ^ The port the terminal's bytes go to. Emacs starts `fflush`ing in
    ;; `update_end`; this flushes at the same place.

    (define (%tty-write-string string)
      ;; `OUTPUT` (`term.c`): a whole capability, as bytes.
      ;;
      ;; Emacs writes with `fwrite` to a `FILE *`; this writes to
      ;; stdout and flushes at the end of the redisplay, which is what a
      ;; buffered `FILE *` amounts to. **The one difference is `cmputc`'s
      ;; seven-bit mask** - it is for single CHARACTERS, and a multi-byte
      ;; character has to go out whole. So a capability string is written
      ;; as a string, and only `cm`'s own single bytes are masked.
      ;;--------------------------------------------------------------
      (when (and string %output)
        (display string %output)))

    (define (%tty-write-byte b)
      ;; One byte, masked the way `cmputc` masks - "putc (c & 0177)".
      ;;--------------------------------------------------------------
      (when %output
        (write-u8 (logand b #o177) %output)))

    (define (%emit cap)
      ;; `OUTPUT1_IF` - write CAP's sequence when the terminal has one.
      ;;--------------------------------------------------------------
      (when cap (%tty-write-string cap)))

    (define (%emit-or-number cap number)
      ;; `OUTPUT1_IF` for a parameterised capability: `tparm` it first.
      ;;--------------------------------------------------------------
      (when cap (%tty-write-string (or (tparm cap number) ""))))

    ;;----------------------------------------------------------------
    ;; Opening and leaving the terminal
    ;;
    ;; `with-terminal' is Emacs's `init_tty' followed by `init_sys_modes'
    ;; and the frame's face startup, and `reset_sys_modes' on the way out.
    ;; It used to be `initscr` and `endwin`.
    ;;------------------------------------------------------------------

    (define (terminal-background-mode)
      ;; GNU Emacs's `frame--current-background-mode` when nothing has
      ;; said what the background is - `light` for a tty whose type is
      ;; xterm, rxvt, dtterm or eterm, else `dark`.
      ;;--------------------------------------------------------------
      (let ((term (or (getenv "TERM") "")))
        (if (or (string-prefix? "xterm" term)
                (string-prefix? "rxvt" term)
                (string-prefix? "dtterm" term)
                (string-prefix? "eterm" term))
            'light
            'dark)))

    (define (tty-capable-p caps)
      ;; GNU Emacs's `tty_capable_p` (`term.c:2230`), for the three
      ;; capabilities this tree asks about: can the terminal draw
      ;; reverse video, and can it underline.
      ;;
      ;; `MAY_USE_WITH_COLORS_P` is the other half - a terminal whose
      ;; `NC` says an attribute is "not allowed with colour" - and `NC`
      ;; is 0 on every terminal here, so the test is the capability.
      ;;--------------------------------------------------------------
      (and caps
           (let ((s (tty-standout caps)))
             (or (and s (not (string=? s ""))) #f))))

    (define (tty-direct-color-supported? caps term)
      ;; GNU Emacs's test, in its order (`term.c:4718-4762`):
      ;;
      ;;   if (tigetstr ("setf24") && tigetstr ("setb24"))      -> 24-bit
      ;;   else if (tigetstr ("setrgbf") && tigetstr ("setrgbb")) -> 24-bit
      ;;   else if (tigetflag ("RGB") > 0)                      -> 24-bit
      ;;   else if (tigetflag ("Tc") > 0
      ;;            || COLORTERM is "truecolor")                -> 24-bit
      ;;
      ;; **Three of these used not to be reachable**: the old comment
      ;; said guile-ncurses had no `tigetflag`/`tigetnum`. `tinfo.scm`
      ;; has both (they are `libtinfo`'s), so the C's whole test is here
      ;; and a terminal that advertises `Tc` is no longer drawn through
      ;; the palette.
      ;;--------------------------------------------------------------
      (let ((colorterm (getenv "COLORTERM")))
        (or (and (tigetstr "setf24") (tigetstr "setb24") #t)
            (and (tigetstr "setrgbf") (tigetstr "setrgbb") #t)
            (> (tigetflag "RGB") 0)
            (and (> (tigetflag "Tc") 0) #t)
            (and colorterm (string-ci=? colorterm "truecolor") #t)
            #f)))

    (define (%read-caps rows cols)
      ;; Fill the capability table from terminfo, in `tty_init`'s order
      ;; (`term.c:4597-4762`).
      ;;
      ;; The two that are not a plain `tgetstr` are the C's own:
      ;; `TS_enter_strike_through_mode` and `TS_enter_overline_mode` are
      ;; read with `tigetstr` because their names are more than two
      ;; characters, and `TS_end_standout_mode` falls back to `me` when
      ;; the terminal has no `se`.
      ;;--------------------------------------------------------------
      (let ((caps (make-tty-caps)))
        (set-tty-rows! caps rows)
        (set-tty-cols! caps cols)
        (set-tty-cm! caps (%cm-initialize! (make-cm) rows cols))
        (set-tty-clr-to-bottom! caps (tgetstr "cd"))
        (set-tty-clr-line! caps (tgetstr "ce"))
        (set-tty-clr-frame! caps (tgetstr "cl"))
        (set-tty-orig-pair! caps (tgetstr "op"))
        (when (tty-orig-pair caps)
          ;; "If `op' isn't available, don't support color because we
          ;; can't switch back to the default foreground and background."
          (set-tty-set-foreground! caps
                                   (or (tgetstr "AF") (tgetstr "Sf")))
          (set-tty-set-background! caps
                                   (or (tgetstr "AB") (tgetstr "Sb"))))
        (set-tty-enter-bold! caps (tgetstr "md"))
        (set-tty-enter-italic! caps (tgetstr "ZH"))
        (set-tty-enter-dim! caps (tgetstr "mh"))
        (set-tty-enter-underline! caps (tgetstr "us"))
        (set-tty-exit-underline! caps (tgetstr "ue"))
        (set-tty-enter-strike! caps (tigetstr "smxx"))
        (set-tty-enter-overline! caps (tigetstr "Smol"))
        (set-tty-standout! caps (tgetstr "so"))
        (set-tty-end-standout! caps (tgetstr "se"))
        (set-tty-exit-attribute! caps (tgetstr "me"))
        (set-tty-cursor-visible! caps (tgetstr "vs"))
        (set-tty-cursor-normal! caps (tgetstr "ve"))
        ;; `TS_cursor_invisible` (`vi`, `civis`): the sequence
        ;; `tty_hide_cursor` emits while the frame is being written.
        (set-tty-cursor-invisible! caps (tgetstr "vi"))
        (set-tty-keypad-mode! caps (tgetstr "ks"))
        (set-tty-end-keypad-mode! caps (tgetstr "ke"))
        (set-tty-termcap-modes! caps (tgetstr "ti"))
        (set-tty-end-termcap-modes! caps (tgetstr "te"))
        (set-tty-magicwrap! caps (> (tigetflag "xn") 0))
        (set-tty-autowrap! caps (or (tty-magicwrap caps) (> (tigetflag "am") 0)))
        ;; --- the four fallbacks, each copied from the C ---
        ;;
        ;; "If there's no standout mode, try to use underlining instead."
        (when (not (tty-standout caps))
          (set-tty-standout! caps (tty-enter-underline caps))
          (set-tty-end-standout! caps (tty-exit-underline caps)))
        ;; "If no `se' string, try using a `me' string instead. If that
        ;; fails, we can't use standout mode at all."
        (when (not (tty-end-standout caps))
          (let ((s (tgetstr "me")))
            (if s
                (set-tty-end-standout! caps s)
                (set-tty-standout! caps #f))))
        (set-tty-standout-mode! caps #f)
        (set-tty-cursor-hidden! caps #f)
        ;; `w->cursor_off_p` (`window.h`) for the one cursor this
        ;; terminal has: set by the redisplay when the cursor is not to
        ;; be shown, and read by `tty_update_end` before it shows it.
        (set-tty-cursor-off! caps #f)
        (set-tty-visible-cursor! caps #f)
        (set-tty-max-colors! caps
                             (if (tty-orig-pair caps)
                                 ;; **`colors`, not `Co`.** Emacs's
                                 ;; `tgetnum` is a *termcap* lookup, and
                                 ;; termcap's name for the colour count is
                                 ;; `Co`; `tigetnum` is terminfo's, where it
                                 ;; is `colors`. Measured, `Co` answers -2
                                 ;; here while `colors` answers 256 - so the
                                 ;; terminal had no colours at all and every
                                 ;; face came out plain.
                                 (max 0 (tigetnum "colors"))
                                 0))
        ;; --- the four ways a terminal can be told a 24-bit colour ---
        ;;
        ;; `term.c:4714-4760`, branch for branch. **The last two branches
        ;; ASSIGN the standard sequences**, because a terminal that only
        ;; advertises `Tc` or `COLORTERM=truecolor` has no `setf24` to
        ;; read - and collapsing the four into one boolean lost that,
        ;; which sent `\e[38;5;3229m` for a 24-bit pixel.
        (let ((setf24 (tigetstr "setf24"))
              (setb24 (tigetstr "setb24"))
              (setrgbf (tigetstr "setrgbf"))
              (setrgbb (tigetstr "setrgbb"))
              (colorterm (getenv "COLORTERM")))
          (cond
           ((and setf24 setb24)
            (set-tty-set-foreground! caps setf24)
            (set-tty-set-background! caps setb24)
            (set-tty-max-colors! caps 16777216))
           ((and setrgbf setrgbb)
            (set-tty-set-foreground! caps setrgbf)
            (set-tty-set-background! caps setrgbb)
            (set-tty-max-colors! caps 16777216)
            (set-tty-rgb-separate! caps #t))
           ((> (tigetflag "RGB") 0)
            (set-tty-max-colors! caps 16777216))
           ((or (> (tigetflag "Tc") 0)
                (and colorterm (string-ci=? colorterm "truecolor")))
            (set-tty-set-foreground! caps "\x1b[38;2;%p1%d;%p2%d;%p3%d%;m")
            (set-tty-set-background! caps "\x1b[48;2;%p1%d;%p2%d;%p3%d%;m")
            (set-tty-max-colors! caps 16777216)
            (set-tty-rgb-separate! caps #t))))
        caps))

    (define (initialize-display-faces!)
      ;; What `startup.el' does to the terminal's faces, in its order:
      ;; `tty-register-default-colors', then
      ;; `tty-run-terminal-initialization', then
      ;; `frame-set-background-mode' and the faces realized against what
      ;; all that found out.
      ;;--------------------------------------------------------------
      (*display-type* (if (< 0 (display-color-cells (current-display)))
                          'color 'mono))
      (*display-color-cells* (display-color-cells (current-display)))
      (tty-register-default-colors)
      (when (string-prefix? "xterm" (or (getenv "TERM") ""))
        (terminal-init-xterm))
      (unless (*frame-background-mode*)
        (*frame-background-mode* (terminal-background-mode)))
      (for-each face-spec-recalc (face-list)))

    (define (with-terminal thunk)
      ;; Run THUNK with the terminal open in the editor's mode, restoring
      ;; the terminal even if THUNK raises an error.
      ;;
      ;; Emacs's order, from `init_tty`: read the terminal's
      ;; description, put it in the mode the editor wants, set the
      ;; terminal modes (`ti`, `ks`), and send it to the alternate
      ;; screen. `reset_sys_modes` and `te`/`ke` undo it.
      ;;--------------------------------------------------------------
      (dynamic-wind
        (lambda ()
          (setup-term #f 1)
          (set! %output (current-output-port))
          (init-sys-modes)
          ;; **A SIGWINCH handler, so the wait can be interrupted.**
          ;; `SIGWINCH`'s default action is "ignore", and an ignored
          ;; signal does not interrupt `select` - so with no handler the
          ;; editor sat in `select` through a resize and never asked how
          ;; big the terminal was. Measured, with a handler a `select` on
          ;; a pipe returned after the signal with an empty ready set;
          ;; without one it waited the full timeout.
          ;;
          ;; **What the handler does is `handle_window_change_signal`**
          ;; (`dispnew.c:6606`): read the size and *park* it on the frame,
          ;; because a signal handler cannot re-tile windows - the C says
          ;; so where it calls `change_frame_size` with DELAY set. The
          ;; work is done by `do-pending-window-change` in the wait below.
          ;;
          ;; The version before this one had a handler that did nothing at
          ;; all, on the reasoning that the size is read again when the
          ;; frame is redrawn - and then nothing told the editor a redraw
          ;; was wanted, so a resized terminal kept drawing the size it
          ;; started with. Measured: at 40 rows the mode line stayed on
          ;; row 22.
          (sigaction SIGWINCH (lambda (sig) (handle-window-change-signal)))
          ;; GNU Emacs's `init_signals` runs from `main`, before the
          ;; terminal is opened; here it is the opening that says this
          ;; process has a keyboard at all.
          (init-signals)
          ;; The back door's wake, so that an idle editor can be woken by a
          ;; client instead of polling for one.
          (install-repl-wake!)
          (let* ((size (get-tty-size *tty-fd*))
                 (rows (car size))
                 (cols (cdr size))
                 (caps (%read-caps (if (> rows 0) rows 24)
                                   (if (> cols 0) cols 80))))
            (set! %terminal caps)
            ;; `cmputc` writes through the same port everything else
            ;; does, so the cost model and the drawing cannot disagree
            ;; about where the cursor is.
            (set-cmputc! %tty-write-byte)
            (cmcostinit (tty-cm caps))
            ;; `Wcm_init` -1 means the terminal cannot address the cursor
            ;; and Emacs refuses to start. Answering the same way is
            ;; better than a screen that cannot be drawn.
            (when (= -1 (Wcm-init (tty-cm caps)))
              (error "Terminal type is not powerful enough to run Schemacs"))
            (current-display (make <tty-display>))
            (*tty-direct-color* (tty-direct-color-supported? caps "xterm"))
            (set-terminal-modes! (current-display))
            (initialize-display-faces!)))
        thunk
        (lambda ()
          (when (current-display)
            (reset-terminal-modes! (current-display)))
          (reset-sys-modes)
          (set! %terminal #f)
          (set! %output #f))))


    ;;----------------------------------------------------------------
    ;; The display object
    ;;------------------------------------------------------------------

    (define-class <tty-display> (<display>))
    ;; ^ A text terminal, the one display `with-terminal' opens.
    ;;
    ;; **No fields.** Everything a terminal has is in `%terminal`, the
    ;; capability table - which is `struct tty_display_info`, and is one
    ;; per process the same way `terminal_list` is one entry here. The
    ;; display object is the handle the redisplay passes around, and a
    ;; copy of the table on it would be a second account of the same
    ;; screen, which is the departure this whole file exists to remove.

    ;;----------------------------------------------------------------
    ;; Appearances, emitted as bytes
    ;;
    ;; GNU Emacs's `turn_on_face`/`turn_off_face` (`term.c:2111`, `:2203`).
    ;; The capability names are termcap's, which is what `tgetstr` takes.
    ;;------------------------------------------------------------------

    (define (%cap-string caps name)
      ;; A capability by termcap name out of the table, so the face code
      ;; below reads like the C's `tty->TS_enter_bold_mode`.
      ;;--------------------------------------------------------------
      (cond ((string=? name "md") (tty-enter-bold caps))
            ((string=? name "us") (tty-enter-underline caps))
            ((string=? name "ue") (tty-exit-underline caps))
            ((string=? name "so") (tty-standout caps))
            ((string=? name "se") (tty-end-standout caps))
            ((string=? name "me") (tty-exit-attribute caps))
            ((string=? name "op") (tty-orig-pair caps))
            ((string=? name "AF") (tty-set-foreground caps))
            ((string=? name "AB") (tty-set-background caps))
            (else (tgetstr name))))

    (define (tty-hide-cursor caps)
      ;; GNU Emacs's `tty_hide_cursor` (`term.c:352`): "Make cursor
      ;; invisible" - and it is the whole of `tty_update_begin` (`:1860`),
      ;; so the cursor motions a redisplay makes are not seen.
      ;;
      ;; **Without it the cursor is visible walking over the frame.** It
      ;; is one terminal cursor, and every `cursor_to!` in the redisplay
      ;; moves it - so writing the mode line at the bottom of a window
      ;; takes the cursor there and back, in front of the user. Emacs
      ;; hides it for the frame update and shows it at the end
      ;; (`tty_show_cursor`, the tail of `tty_update_end`).
      ;;--------------------------------------------------------------
      (unless (tty-cursor-hidden caps)
        (set-tty-cursor-hidden! caps #t)
        (%emit (tty-cursor-invisible caps))))

    (define (tty-show-cursor caps)
      ;; GNU Emacs's `tty_show_cursor` (`term.c:362`).
      ;;--------------------------------------------------------------
      (when (tty-cursor-hidden caps)
        (set-tty-cursor-hidden! caps #f)
        (%emit (tty-cursor-normal caps))
        (when (tty-visible-cursor caps)
          (%emit (tty-cursor-visible caps)))))

    (define (tty-turn-on-highlight caps)
      ;; GNU Emacs's `tty_turn_on_highlight` (`term.c:326`):
      ;;
      ;;   if (!tty->standout_mode) OUTPUT_IF (tty, tty->TS_standout_mode);
      ;;   tty->standout_mode = 1;
      ;;--------------------------------------------------------------
      (unless (tty-standout-mode caps) (%emit (tty-standout caps)))
      (set-tty-standout-mode! caps #t))

    (define (tty-turn-off-highlight caps)
      ;; GNU Emacs's `tty_turn_off_highlight` (`term.c:318`):
      ;;
      ;;   if (tty->standout_mode) OUTPUT_IF (tty, tty->TS_end_standout_mode);
      ;;   tty->standout_mode = 0;
      ;;
      ;; **The flag is cleared whatever it was**, and that line was
      ;; missing here: this only emitted `se` when the flag was already
      ;; set, so a face with `:reverse` (the mode line, the prompt) left
      ;; it set for ever. Nothing visible followed, because
      ;; `tty-highlight-if-desired` emitted `so` again and `turn_on_face`
      ;; swaps the foreground and background while the flag is up - so
      ;; the picture stayed right while every later run carried an extra
      ;; `so`/`se` pair and its colours went out in the opposite order.
      ;; Found by a pty check that pins those bytes (`region-highlight`),
      ;; when an unrelated change stopped the mode line being redrawn.
      ;;--------------------------------------------------------------
      (when (tty-standout-mode caps) (%emit (tty-end-standout caps)))
      (set-tty-standout-mode! caps #f))

    (define (tty-highlight-if-desired caps)
      ;; GNU Emacs's `tty_highlight_if_desired` (`term.c:398`), which is
      ;; `tty_background_highlight`'s body too: "Set standout mode to the
      ;; mode specified for the text to be output" - on or off according
      ;; to `inverse-video`, not merely "emit `so` if we think we are in
      ;; it".
      ;;--------------------------------------------------------------
      (if (*tty-inverse-video*)
          (tty-turn-on-highlight caps)
          (tty-turn-off-highlight caps)))

    (define (tty-turn-on-face face)
      ;; GNU Emacs's `turn_on_face` (`term.c:2111`).
      ;;
      ;; FACE is this display's realized face - the plist
      ;; `realize-tty-face` folds down to, carrying exactly what
      ;; `struct face` does for a terminal.
      ;;--------------------------------------------------------------
      (let* ((caps %terminal)
             (fg (attribute-value face ':foreground))
             (bg (attribute-value face ':background))
             (fg-defaulted? (or (eq? fg *undefined-face-attribute*) (not fg)))
             (bg-defaulted? (or (eq? bg *undefined-face-attribute*) (not bg)))
             (reverse? (eq? (attribute-value face ':reverse) #t)))
        ;; "Use reverse video if the face specifies that. Do this first
        ;; because TS_end_standout_mode may be the same as
        ;; TS_exit_attribute_mode, which turns all appearances off."
        (when (and reverse?
                   (or (if (*tty-inverse-video*) (or fg-defaulted? bg-defaulted?)
                           (or fg-defaulted? bg-defaulted?))))
          (%emit (tty-standout caps))
          (set-tty-standout-mode! caps (not (tty-standout-mode caps))))
        (when (eq? (attribute-value face ':bold) #t)
          (%emit (tty-enter-bold caps)))
        (when (eq? (attribute-value face ':italic) #t)
          ;; "Italics mode is unavailable on many terminals. In that case,
          ;; map slant to dimmed text."
          (if (tty-enter-italic caps)
              (%emit (tty-enter-italic caps))
              (%emit (tty-enter-dim caps))))
        (when (attribute-value face ':underline)
          (%emit (tty-enter-underline caps)))
        (when (eq? (attribute-value face ':strike-through) #t)
          (%emit (tty-enter-strike caps)))
        (when (eq? (attribute-value face ':overline) #t)
          (%emit (tty-enter-overline caps)))
        (when (> (tty-max-colors caps) 0)
          (let ((ts (if (tty-standout-mode caps)
                        (tty-set-background caps)
                        (tty-set-foreground caps))))
            (when (and (not fg-defaulted?) ts)
              (%tty-write-string
               (if (tty-rgb-separate caps)
                   (or (tparm ts (ash fg -16) (logand (ash fg -8) 255)
                              (logand fg 255))
                       "")
                   (or (tparm ts fg) "")))))
          (let ((ts (if (tty-standout-mode caps)
                        (tty-set-foreground caps)
                        (tty-set-background caps))))
            (when (and (not bg-defaulted?) ts)
              (%tty-write-string
               (if (tty-rgb-separate caps)
                   (or (tparm ts (ash bg -16) (logand (ash bg -8) 255)
                              (logand bg 255))
                       "")
                   (or (tparm ts bg) ""))))))))

    (define (tty-turn-off-face face)
      ;; GNU Emacs's `turn_off_face` (`term.c:2203`).
      ;;--------------------------------------------------------------
      (let* ((caps %terminal)
             (fg (attribute-value face ':foreground))
             (bg (attribute-value face ':background)))
        (if (tty-exit-attribute caps)
            ;; "Capability `me' will turn off appearance modes
            ;; double-bright, half-bright, reverse-video, standout,
            ;; underline, overline, strike-through."
            (when (or (eq? (attribute-value face ':bold) #t)
                      (eq? (attribute-value face ':italic) #t)
                      (eq? (attribute-value face ':reverse) #t)
                      (attribute-value face ':underline)
                      (eq? (attribute-value face ':strike-through) #t)
                      (eq? (attribute-value face ':overline) #t))
              (%emit (tty-exit-attribute caps))
              (when (and (tty-end-standout caps)
                         (string=? (tty-exit-attribute caps)
                                   (tty-end-standout caps)))
                (set-tty-standout-mode! caps #f)))
            ;; "If we don't have `me' we can only have those appearances
            ;; that have exit sequences defined."
            (when (attribute-value face ':underline)
              (%emit (tty-exit-underline caps))))
        ;; "Switch back to default colors."
        (when (and (> (tty-max-colors caps) 0)
                   (or (and fg (not (eq? fg *undefined-face-attribute*)))
                       (and bg (not (eq? bg *undefined-face-attribute*)))))
          (%emit (tty-orig-pair caps)))))

    ;;----------------------------------------------------------------
    ;; Key events: what the terminal sent -> the Emacs key event
    ;;------------------------------------------------------------------

    (define (function-key-sequence->event sequence)
      ;; The event `input-decode-map` gives for SEQUENCE, or #f. This is
      ;; the *whole* of Emacs's function-key handling: `term_get_fkeys_1`
      ;; (`term.c:1417`) keys `input-decode-map` on the escape sequence
      ;; `tgetstr` answers for each capability, so looking the sequence up
      ;; is exactly what `read_char` does with it.
      ;;--------------------------------------------------------------
      (let ((entry (assoc sequence (*input-decode-map*))))
        (and entry (cdr entry))))

    (define-method (key-event->key (d <tty-display>) ev)
      ;; The *key event* for what the terminal sent - GNU Emacs's
      ;; `make_lispy_event` for a terminal (`keyboard.c:8301`):
      ;;
      ;;     buf.kind = ASCII_KEYSTROKE_EVENT;
      ;;     buf.modifiers = 0;
      ;;     buf.code = cbuf[i];
      ;;
      ;; The byte *is* the event, and 24 is `C-x`. A sequence that
      ;; `input-decode-map` knows becomes its named key - which is where
      ;; Emacs gets arrows, function keys and the modified ones.
      ;;--------------------------------------------------------------
      (cond
       ((char? ev) (char->integer ev))
       ((integer? ev) ev)
       ;; **A frame event is its own symbol.** A resize is not a key and
       ;; has no code a terminal ever sends: `read-input-event` makes it
       ;; when the wait applied a parked size change, and what it must
       ;; become is the event `special-event-map` is keyed on - `(kbd
       ;; "<resize>")` is the symbol `resize`, exactly as the gtk front
       ;; end's `*resize-code*` decodes to it. Answering #f here (which
       ;; this did) threw the resize away one frame after it was noticed,
       ;; so a resized terminal was never redrawn.
       ((symbol? ev) ev)
       ((string? ev)
        (or (function-key-sequence->event ev)
            ;; **A one-byte string that the decode map does not know is
            ;; that byte's event**, which is what `read_char` answers for
            ;; an ordinary keystroke - and what everything above compares
            ;; against. Falling back to the string would make `C-x` the
            ;; vector `("\x18")` instead of the event 24, and a keymap
            ;; lookup raises "a key is a sequence of events".
            (and (= (string-length ev) 1) (char->integer (string-ref ev 0)))))
       (else #f)))

    (define %function-key-sequences #f)
    ;; ^ Every sequence `input-decode-map` knows, longest first, so the
    ;; reader can tell a complete sequence from a prefix of one. Built
    ;; once, from the same map `key-event->key` reads.

    (define (%known-sequences)
      ;; The decode map's keys, longest first - `(\e[1;3A \eOA ...)`.
      ;; Longest first because `\e[1;3A` starts with `\e[` and the
      ;; shorter match would split it.
      ;;--------------------------------------------------------------
      (unless %function-key-sequences
        (set! %function-key-sequences
              (sort (map car (*input-decode-map*))
                    (lambda (a b) (> (string-length a) (string-length b))))))
      %function-key-sequences)

    (define (%sequence-prefix? seq sofar)
      ;; Is SOFAR the beginning of SEQ?
      ;;--------------------------------------------------------------
      (and (<= (string-length sofar) (string-length seq))
           (string=? sofar (substring seq 0 (string-length sofar)))))

    (define (%read-available)
      ;; Every byte that is on the terminal descriptor right now, as a
      ;; string - without waiting for more.
      ;;--------------------------------------------------------------
      (let loop ((acc '()))
        (if (char-ready? (current-input-port))
            (let ((b (read-u8 (current-input-port))))
              (if (eof-object? b)
                  (list->string (reverse acc))
                  (loop (cons (integer->char b) acc))))
            (list->string (reverse acc)))))

    (define %byte-queue '())
    ;; ^ Bytes read from the terminal and not yet turned into an event,
    ;; most recently read last. They live here rather than being read one
    ;; at a time because a *sequence* has to be assembled from the whole
    ;; burst the terminal sent - `\eOA` is three bytes and the event is
    ;; all three.

    (define (%unread-bytes string)
      ;; Put STRING back at the front of the queue, in order - the bytes
      ;; read past the end of an event belong to the next one.
      ;;--------------------------------------------------------------
      (let loop ((i (- (string-length string) 1)))
        (when (>= i 0)
          (set! %byte-queue
                (cons (char->integer (string-ref string i)) %byte-queue))
          (loop (- i 1)))))

    (define (%queue-byte! b)
      ;; Put one byte at the back of the queue - a byte read off the
      ;; descriptor and not yet turned into an event.
      ;;--------------------------------------------------------------
      (set! %byte-queue (append %byte-queue (list b))))

    (define %keyboard-fd 0)
    ;; ^ The descriptor the terminal reads keys from - stdin, which is
    ;; what `initscr` used and what `sysdep.scm` puts in raw mode. A
    ;; value rather than a call because `select` wants it on every read.

    (define (%take-port-bytes!)
      ;; Move the bytes the *descriptor* has into the queue, answering how
      ;; many that was.
      ;;
      ;; **`read(2)` on the fd, and `select` on the fd - not the port.**
      ;; Every other reader here is on the descriptor (`%blocking-read-byte`,
      ;; `%timed-read-byte`, `tty-read-query-byte`), and a port keeps a
      ;; buffer they cannot see: a byte that arrived in one is invisible
      ;; to `select`, and a byte `select` reports is not in the port. That
      ;; split is what made `ESC [ 2 ~` (Insert) assemble as `ESC` and
      ;; then push `[2~` back as three typed characters - measured, the
      ;; mode line read `I??` after a press of it.
      ;;--------------------------------------------------------------
      (let ((b (and (memq %keyboard-fd
                          (car (select (list %keyboard-fd) '() '() 0)))
                    (tty-read-byte))))
        (if (not b)
            0
            (begin
              (%queue-byte! b)
              1))))

    (define (%drain-bytes!)
      ;; Move everything the port has buffered into the queue.
      ;;
      ;; It stops when a round brings nothing, which is what keeps a typed
      ;; ESC from being held: nothing more has arrived, one round brings
      ;; none, and the assembly ends at ESC.
      ;;--------------------------------------------------------------
      (let loop ((n 0))
        (when (and (< n 16) (> (%take-port-bytes!) 0))
          (loop (+ n 1)))))

    (define (%wait-and-read deadline)
      ;; Wait for the descriptor with `select`, then read one byte off it.
      ;; Answers #f when the wait ended with nothing to read - a DEADLINE
      ;; that passed, the end of input, or a *resize*, which
      ;; `read-input-event` turns into its event.
      ;;
      ;; **An empty ready set is an event, and it is the whole of how a
      ;; terminal resize is noticed.** `select(2)` is on the manual's
      ;; never-restarted list, so a signal interrupts it and it returns
      ;; with nothing ready; a blocking `read` on a port would be restarted
      ;; instead and the resize never seen. That is why the wait is
      ;; `select` on the descriptor and not a read.
      ;;
      ;; **What follows the wait is `wait_reading_process_output`'s own
      ;; line** - "If we woke up due to SIGWINCH, actually change size
      ;; now", `do_pending_window_change (0)` at `process.c:5862`,
      ;; immediately after `pselect` returns and *before* the bytes are
      ;; looked at, so a key and a resize in the same moment both count.
      ;;
      ;; **The size is asked for here, not taken from the handler.** Guile
      ;; runs a `sigaction' handler at the VM's next safe point, and
      ;; measured, that point can be *after* `select` has already returned
      ;; to Scheme: the signal ends the wait, this code runs, and the
      ;; handler has not parked anything yet. So the wait does the read
      ;; Emacs's handler does, and the handler's own run is a harmless
      ;; second opinion. `do-pending-window-change` answers whether the
      ;; frame's size *actually* changed.
      ;;
      ;; **A wake with no size change waits again** rather than answering
      ;; `#f`: a `#f` on a blocking read is the end of input as far as the
      ;; command loop is concerned, and quitting the editor because a
      ;; signal arrived is not a resize. Emacs loops there for the same
      ;; reason.
      ;;--------------------------------------------------------------
      (let loop ()
        (let* ((left (and deadline (- deadline (tty-now-ms))))
               (watched (if %repl-wake-rd
                            (list %keyboard-fd %repl-wake-rd)
                            (list %keyboard-fd)))
               (ready (car (select watched '() '()
                                   (if left
                                       (max 0.001 (/ left 1000.0))
                                       #f)))))
          ;; **The back door first**: the server's reader thread wrote a
          ;; byte, and the thunk it queued is what runs the expression in
          ;; this thread - the only thread that owns the editor's state.
          ;; Emptying the pipe is what lets the next wait block again.
          (when (and %repl-wake-rd (memq %repl-wake-rd ready))
            (%drain-repl-wake!))
          ;; **"If we woke up due to SIGWINCH, actually change size now"**,
          ;; `wait_reading_process_output`'s own line (`process.c:5862`):
          ;; the size is read and applied *before* the bytes are looked
          ;; at, so a key and a resize in the same moment both count.
          (handle-window-change-signal)
          (when (do-pending-window-change #f)
            (set! %size-change-pending? #t))
          (cond
           ;; Readable: a byte, or #f at the end of input.
           ((memq %keyboard-fd ready) (tty-read-byte))
           ;; A resize. `read-input-event` answers it as an event and
           ;; clears the flag; if a byte was read above, the key wins and
           ;; the next read reports the resize.
           (%size-change-pending? #f)
           ;; Neither: the deadline has passed, or a signal woke us for
           ;; nothing. **Only the deadline ends the wait with nothing** -
           ;; answering #f for a spurious wake is what quit the editor,
           ;; because a #f on a blocking read is the end of input.
           ;; **A quit ends the wait too**, and it is the one signal that
           ;; cannot simply be waited through: `handle_interrupt` has
           ;; recorded it (`keyboard.c`), and GNU Emacs leaves
           ;; `wait_reading_process_output` for it by longjmp
           ;; (`quit_throw_to_read_char`). The flag is what is left of
           ;; that here; `read-input-event` answers the C-g it stands for.
           ((*quit-flag*) #f)
           ((and deadline (<= deadline (tty-now-ms))) #f)
           (else (loop))))))

    (define (%read-key-bytes deadline)
      ;; One *event* from the terminal, as bytes; #f when DEADLINE passed
      ;; with nothing read.
      ;;
      ;; A byte no `input-decode-map` sequence starts with is its own
      ;; event. A byte that does start one is read on while bytes are
      ;; already there, and a byte that arrives late ends the event at the
      ;; first character.
      ;;
      ;; **The late byte is pushed back, and that is the whole rule.**
      ;; `ESC` starts dozens of sequences, so waiting for the rest would
      ;; block until the user typed another key - `ESC %` (M-%) would hang
      ;; on the ESC. Emacs reads on for a function-key sequence too, and
      ;; what stops it is the next key: the same two layers, `read-event`
      ;; then `input-decode-map`.
      ;;--------------------------------------------------------------
      (when (null? %byte-queue)
        (%drain-bytes!))
      (let ((first (cond
                    ((pair? %byte-queue)
                     (let ((b (car %byte-queue)))
                       (set! %byte-queue (cdr %byte-queue))
                       b))
                    (else (%wait-and-read deadline)))))
        (if (not first)
            #f
            (begin
              ;; **The rest of the burst.** The drain above ran before the
              ;; first byte was read, so when it found nothing the byte
              ;; came from `%blocking-read-byte` and the *tail* of the
              ;; sequence - already on the descriptor - has not been taken
              ;; yet. Without this, `\e[2~` (Insert) assembled as `\e` and
              ;; the `[2~` came back as three typed characters.
              (%drain-bytes!)
              (let ((sofar (string (integer->char first))))
                (if (and (any-prefix? sofar)
                         (not (member sofar (%known-sequences))))
                    (assembling sofar)
                    sofar))))))

    (define (any-prefix? sofar)
      ;; Is SOFAR the beginning of any known sequence?
      ;;--------------------------------------------------------------
      (any (lambda (seq) (%sequence-prefix? seq sofar)) (%known-sequences)))

    (define (any pred lst)
      (cond ((null? lst) #f)
            ((pred (car lst)) #t)
            (else (any pred (cdr lst)))))

    (define (assembling sofar)
      ;; Read on while the bytes that have already arrived could still
      ;; complete a known sequence - and no further.
      ;;
      ;; A complete sequence is the event. A run that cannot complete one
      ;; ends the event at its first character, and the rest goes back on
      ;; the queue. A run that is a *prefix* with nothing more here right
      ;; now ends at its first character too: ESC alone is ESC.
      ;;--------------------------------------------------------------
      (let loop ((sofar sofar))
        (cond
         ((member sofar (%known-sequences)) sofar)
         ((null? %byte-queue)
          (%unread-bytes (substring sofar 1))
          (substring sofar 0 1))
         (else
          (let ((next (car %byte-queue)))
            (set! %byte-queue (cdr %byte-queue))
            (let ((more (string-append sofar (string (integer->char next)))))
              (cond
               ((member more (%known-sequences)) more)
               ((any-prefix? more) (loop more))
               (else
                ;; **Push back everything after the event's first
                ;; character - `more`, not `sofar`.** `NEXT` was taken off
                ;; the queue to build `more`, so pushing back only
                ;; `sofar`'s tail dropped it: measured, `ESC ~` (M-~)
                ;; arrived as a bare ESC and the `~` vanished, so
                ;; `not-modified` never ran and nothing was said.
                (%unread-bytes (substring more 1))
                (substring sofar 0 1)))))))))

    ;;----------------------------------------------------------------
    ;; The clock, and reading a key
    ;;------------------------------------------------------------------

    (define %repl-wake-rd #f)
    (define %repl-wake-wr #f)
    (define %repl-wake-thunk #f)
    ;; ^ The back door's wake - "a pipe a terminal selects on", which is
    ;; what `(scheme-utils repl server)`'s `repl-wake!' documents a host
    ;; with its own loop as supplying. **It was lost when this file stopped
    ;; being ncurses** - the terminal went back to a 100 ms cap on the read
    ;; instead, and that cap is only taken when `(repl-wake)` is false,
    ;; which it never is (the shared module's default is a GLib idle).
    ;; Measured: an idle editor with the door open answered nothing until a
    ;; key was typed.

    (define (install-repl-wake!)
      ;; Give the back door a way to wake *this* loop: one byte written to a
      ;; pipe, and the byte is what `%wait-and-read` selects on. The
      ;; argument is the thunk the server wants run on the thread that owns
      ;; the editor's state - here, the one about to wait.
      ;;--------------------------------------------------------------
      (let ((p (pipe)))
        (set! %repl-wake-rd (car p))
        (set! %repl-wake-wr (cdr p))
        ;; **Unbuffered, or the byte never reaches the descriptor.**
        ;; Guile's `(pipe)` gives buffered ports, and a `put-u8` that stays
        ;; in the buffer leaves `select` reporting nothing.
        (setvbuf %repl-wake-wr 'none)
        (repl-wake!
         (lambda (thunk)
           (set! %repl-wake-thunk thunk)
           (and %repl-wake-wr
                (begin (put-u8 %repl-wake-wr (char->integer #\newline))
                       #t))))))

    (define (%drain-repl-wake!)
      ;; Run what the server asked for and empty the pipe, so the next wait
      ;; blocks again.
      ;;--------------------------------------------------------------
      (let loop ((thunk %repl-wake-thunk))
        (set! %repl-wake-thunk #f)
        (when thunk (thunk))
        (when (char-ready? %repl-wake-rd)
          (get-u8 %repl-wake-rd)
          (loop %repl-wake-thunk))))

    (define %size-change-pending? #f)
    ;; ^ Whether the last wait applied a size change the editor has not
    ;; been told about yet.
    ;;
    ;; **This is how a signal is told from a timeout.** `select` answers an
    ;; empty ready set for both, so without it every timed read - a
    ;; `sit-for`, a minibuffer's next-timer wait - would look like a
    ;; resize and redraw the whole frame for nothing.
    ;;--------------------------------------------------------------

    (define (handle-window-change-signal)
      ;; GNU Emacs's `handle_window_change_signal` (`dispnew.c:6606`).
      ;;
      ;; "The frame size change obviously applies to a single
      ;; termcap-controlled terminal, but we can't decide which.
      ;; Therefore, we resize the frames corresponding to each tty." There
      ;; is one tty here, so this walks the frames drawn on it.
      ;;
      ;; **Nothing is re-tiled here.** The numbers go on the frame with
      ;; `change_frame_size`'s DELAY set - "they could not be reallocated
      ;; now ... let that be done later outside of the signal handler" -
      ;; and the wait below applies them.
      ;;
      ;; **The `> 5' / `> 2' guard is Emacs's**, and it is not decoration:
      ;; a pty that has never been given a size answers 0 x 0, and a
      ;; resize to nothing must not throw the layout away.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (when display
          (let* ((size (get-tty-size *tty-fd*))
                 (height (car size))
                 (width (cdr size)))
            (when (and (> width 5) (> height 2))
              (for-each
               (lambda (frame)
                 (when (eq? (frame-output frame) display)
                   (change-frame-size frame width height #f #t)))
               (*frame-list*)))))))

    (define (tty-now-ms)
      ;; The clock the deadline in `read-input-event' is measured
      ;; against.
      ;;--------------------------------------------------------------
      (quotient (* 1000 (get-internal-real-time))
                internal-time-units-per-second))

    (define-method (read-input-event (d <tty-display>) timeout)
      ;; Read one key event, TIMEOUT milliseconds allowed - a negative
      ;; TIMEOUT blocks until one is there.
      ;;
      ;; **The wait is `select`, on the descriptor `tty-read-byte` reads.**
      ;; Emacs uses `pselect` because it waits on subprocesses, several
      ;; terminals and a SIGCHLD pipe together; one keyboard needs `select`
      ;; for one thing - a *signal* has to end the wait - and a `read` on
      ;; the port would be restarted instead. Two things this pins down:
      ;; the waiting and the reading are on the **descriptor**, never on a
      ;; Scheme port, because a port keeps a buffer of its own that
      ;; `select` cannot see (measured: a burst written as one `write` was
      ;; lost by a `select` that said "not ready" while the bytes sat in
      ;; the port); and an empty ready set after a signal is *how a
      ;; resize is noticed*, which `%wait-and-read` acts on and this
      ;; answers as a `resize` event.
      ;;
      ;; **#f means a deadline expired with nothing read**, which is not
      ;; a resize - the command loop reads `#f` as "nothing happened,
      ;; wait again". The back door needs no timer of its own: the
      ;; cooperative server posts its work to *this* thread, and
      ;; `poll-repl!` runs it between keys.
      ;;--------------------------------------------------------------
      (if (tty-pushed-bytes?)
          ;; A byte pushed back by a terminal query is a key the user
          ;; typed, so it comes before anything the terminal has sent
          ;; since - `unread-command-events` is read first.
          ;; Nothing parked to apply: a query byte or nothing, and
          ;; "nothing" is a timed-out read, not a resize.
          (tty-read-query-byte 0)
          (let* ((deadline (and (>= timeout 0) (+ (tty-now-ms) timeout)))
                 (bytes (%read-key-bytes deadline)))
            (cond
             (bytes bytes)
             ;; **A resize, and only a resize.** `%wait-and-read` applies
             ;; a parked size change and says whether it applied one; a
             ;; deadline that simply expired applied nothing and answers
             ;; #f, which the command loop reads as "nothing happened,
             ;; wait again". Returning `resize` for every timeout - which
             ;; this did - both dropped real resizes (nothing downstream
             ;; knew the symbol) and would have made every timed wait
             ;; redraw the whole frame.
             (%size-change-pending? (set! %size-change-pending? #f) 'resize)
             ;; **The C-g the kernel turned into a signal.** `read_char`
             ;; answers `quit_char` for a pending quit
             ;; (`keyboard.c:2806`); the flag is left for `read-key-event`,
             ;; which is what clears it.
             ((*quit-flag*) quit-char)
             (else #f)))))

    ;;----------------------------------------------------------------
    ;; The display interface, for a text terminal
    ;;
    ;; Every `define-method' below is an implementation of a generic
    ;; from `(schemacs editor dispnew)', and its body is the `term.c`
    ;; hook of the same name.
    ;;------------------------------------------------------------------

    (define-method (write-glyphs! (d <tty-display>) window row area x
                                  glyphs len)
      ;; GNU Emacs's `tty_write_glyphs` (`term.c:973`).
      ;;
      ;; **The run split is here**, as `tty_write_glyphs_1`'s own loop has
      ;; it (`term.c:760`: "Identify a run of glyphs with the same face"),
      ;; and `turn_on_face`/`turn_off_face` bracket each run. One writer,
      ;; one output stream, in the order the C writes them.
      ;;
      ;; **Nothing is written past the frame's last column.** GNU Emacs
      ;; cannot reach that state: `write_row` writes `desired_row->used`,
      ;; and `build_frame_matrix` never lets a row exceed `FRAME_COLS`.
      ;; Here the renderer can hand over a wider row - a long line whose
      ;; slice was not cut to the window - and the terminal then autowraps
      ;; *in the middle of a run*, moving the real cursor down a row while
      ;; `cmplus` has counted only one wrap. Every later `cursor_to` is
      ;; then wrong and the following row is drawn over the wrong cells.
      ;; Measured, a 100-column line on an 80-column terminal put the next
      ;; buffer line on the same screen row as the wrapped tail. The clip
      ;; is where the C's guarantee is enforced instead.
      ;;--------------------------------------------------------------
      (let ((caps %terminal)
            (cm (tty-cm %terminal)))
        (let loop ((i 0) (col x))
          (when (and (< i len) (< col (cm-cols cm)))
            (let* ((g (vector-ref glyphs i))
                   (face (glyph-face-id g))
                   (end (let scan ((j (+ i 1)))
                          (if (and (< j len)
                                   (eq? (glyph-face-id
                                         (vector-ref glyphs j))
                                        face))
                              (scan (+ j 1))
                              j)))
                   (room (- (cm-cols cm) col))
                   (taken (let sum ((j i) (n 0))
                            (if (or (>= j end) (>= n room))
                                n
                                (sum (+ j 1)
                                     (+ n (glyph-pixel-width
                                           (vector-ref glyphs j)))))))
                   (runner (let build ((j i) (acc '()) (n 0))
                             (if (or (>= j end) (>= n room))
                                 (reverse acc)
                                 (build (+ j 1)
                                        (cons (glyph-char
                                               (vector-ref glyphs j))
                                              acc)
                                        (+ n (glyph-pixel-width
                                              (vector-ref glyphs j))))))))
              (cursor-to! d window (glyph-row-y row) col)
              (tty-highlight-if-desired caps)
              (when face (tty-turn-on-face face))
              (%tty-write-string (apply string-append runner))
              (when face (tty-turn-off-face face))
              (tty-turn-off-highlight caps)
              (%cm-plus taken)
              (cmcheckmagic cm)
              (loop end (+ col taken)))))))

    (define (%cm-plus n)
      ;; `cmplus (tty, n)` (`cm.h`) - where the cursor is now that N
      ;; more cells have been written.
      ;;
      ;;   if ((curX += n) >= FrameCols && !MagicWrap)
      ;;     { if (losewrap) losecursor;
      ;;       else if (AutoWrap) curX = 0, curY++;
      ;;       else curX--; }
      ;;--------------------------------------------------------------
      (let* ((cm (tty-cm %terminal))
             (nx (+ (cm-curX cm) n)))
        (set-cm-curX! cm nx)
        (when (and (>= nx (cm-cols cm)) (not (cm-magicwrap cm)))
          (cond ((cm-losewrap cm) (set-cm-curX! cm -1) (set-cm-curY! cm -1))
                ((cm-autowrap cm)
                 (set-cm-curX! cm 0)
                 (set-cm-curY! cm (+ (cm-curY cm) 1)))
                (else (set-cm-curX! cm (- nx 1)))))))

    (define-method (clear-end-of-line! (d <tty-display>) window row area x
                                       width token)
      ;; GNU Emacs's `tty_clear_end_of_line` (`term.c`): "clear from the
      ;; current cursor position to the end of the line" - and the
      ;; cursor may be MOVED, on a terminal lacking `ce`.
      ;;--------------------------------------------------------------
      (let* ((caps %terminal)
             (cm (tty-cm caps))
             (y (glyph-row-y row))
             (first-unused (+ x width)))
        (cursor-to! d window y x)
        (let ((ce (tty-clr-line caps)))
          (cond
           (ce
            (tty-turn-off-highlight caps)
            (%emit ce))
           ((= first-unused (cm-curX cm))
            ;; nothing to do
            #t)
           (else
            ;; write spaces
            (let ((n (- first-unused (cm-curX cm))))
              (when (> n 0)
                (%tty-write-string (make-string n #\space))
                (set-cm-curX! cm first-unused))))))))

    (define-method (ensure-surface! (d <tty-display>))
      ;; A terminal's "surface" is the screen it is open on; there is
      ;; nothing to make.
      ;;
      ;; **What it does do is put the cost model's idea of the screen in
      ;; step with it**, which is `adjust_frame_size`'s own line for a tty
      ;; frame (`frame.c:1053`, `:1088`):
      ;;
      ;;     FrameCols (FRAME_TTY (f)) = new_text_cols;
      ;;     FrameRows (FRAME_TTY (f)) = new_text_lines;
      ;;
      ;; **Without it a resized frame was still drawn 80 columns wide.**
      ;; The cost model's rows and columns were set once by `Wcm_init` at
      ;; startup, and `cmplus`'s wrap rule and `write-glyphs!`'s clip read
      ;; them - measured, a 100-column frame's mode line stopped at column
      ;; 79 while the `C-x 3` border moved to 49, because the border is an
      ;; absolute column and each row was clipped.
      ;;
      ;; It belongs to the display because the state is the display's: the
      ;; C reaches it through `FRAME_TTY (f)`, and this tree's frame has
      ;; no business importing `term.c`. `render!` calls this after
      ;; `sync-frame-size!` and before the first glyph, which is when the
      ;; C's line runs inside `adjust_frame_size`.
      ;;--------------------------------------------------------------
      (let ((size (screen-size d)))
        (when (and (> (car size) 0) (> (cdr size) 0))
          (set-cm-cols! (tty-cm %terminal) (car size))
          (set-cm-rows! (tty-cm %terminal) (cdr size))))
      #t)

    (define-method (clear-frame-area! (d <tty-display>))
      ;; Clear the screen, and forget where the cursor was: Emacs's
      ;; `clear_frame` for a termcap frame is `tty_clear_frame`, which
      ;; ends with `cmat (tty, 0, 0)`.
      ;;--------------------------------------------------------------
      (let* ((caps %terminal)
             (cm (tty-cm caps)))
        (when (tty-clr-frame caps)
          (tty-turn-off-highlight caps)
          (%emit (tty-clr-frame caps))
          (set-cm-curY! cm 0)
          (set-cm-curX! cm 0))))

    (define-method (update-window-begin! (d <tty-display>))
      #t)

    (define-method (update-window-end! (d <tty-display>))
      #t)

    (define-method (draw-box! (d <tty-display>) box token x y cells height
                              left? right?)
      ;; A terminal draws no box - `realize_tty_face` folds a face to
      ;; weight, slant, underline, strike-through, overline and a colour
      ;; pair, and `:box` is not among them.
      ;;--------------------------------------------------------------
      #f)

    (define-method (cursor-to! (d <tty-display>) window vpos hpos)
      ;; GNU Emacs's `tty_cursor_to` (`term.c:408`).
      ;;--------------------------------------------------------------
      (cmgoto (tty-cm %terminal) vpos hpos))

    (define-method (raw-cursor-to! (d <tty-display>) vpos hpos)
      ;; `tty_raw_cursor_to` (`term.c:430`).
      ;;--------------------------------------------------------------
      (cmgoto (tty-cm %terminal) vpos hpos))

    (define-method (clear-to-end! (d <tty-display>))
      ;; `tty_clear_to_end` (`term.c:449`).
      ;;--------------------------------------------------------------
      (let ((caps %terminal))
        (if (tty-clr-to-bottom caps)
            (begin (tty-turn-off-highlight caps)
                   (%emit (tty-clr-to-bottom caps)))
            #t)))

    (define-method (clear-frame! (d <tty-display>))
      ;; `tty_clear_frame` (`term.c:472`).
      ;;--------------------------------------------------------------
      (let ((caps %terminal))
        (when (tty-clr-frame caps)
          (tty-turn-off-highlight caps)
          (%emit (tty-clr-frame caps)))))

    (define-method (update-begin! (d <tty-display>))
      ;; GNU Emacs's `tty_update_begin` (`term.c`), which is exactly
      ;; `tty_hide_cursor`.
      ;;--------------------------------------------------------------
      (tty-hide-cursor %terminal))

    (define-method (set-terminal-cursor! (d <tty-display>) row column)
      ;; GNU Emacs's `tty_set_cursor` (`dispnew.c:5672`): address the
      ;; physical cursor at the position the redisplay recorded for it,
      ;; which `display_and_set_cursor` left in `w->cursor`. It is the
      ;; terminal's own cursor - there is no reverse-video cell to draw,
      ;; because this backend's cursor *is* the terminal's - so this is
      ;; where the terminal is told where it goes.
      ;;--------------------------------------------------------------
      (cursor-to! d #f row column))

    (define-method (update-end! (d <tty-display>))
      ;; `tty_update_end` (`term.c:254`):
      ;;
      ;;   if (!XWINDOW (selected_window)->cursor_off_p)
      ;;     tty_show_cursor (tty);
      ;;   tty_turn_off_insert (tty);
      ;;   tty_background_highlight (tty);
      ;;   fflush (tty->output);
      ;;
      ;; The cursor is shown here and *placed* by `set-terminal-cursor!`
      ;; - two steps, as they are two functions in the C. Hiding it
      ;; before the frame's text is written and showing it after is what
      ;; keeps the writes the redisplay makes from being visible as a
      ;; cursor walking the screen.
      ;;--------------------------------------------------------------
      (unless (tty-cursor-off %terminal)
        (tty-show-cursor %terminal))
      (flush-output-port (current-output-port)))

    (define-method (set-terminal-modes! (d <tty-display>))
      ;; `tty_set_terminal_modes` (`term.c:202`): `ti`, the cursor, `ks`,
      ;; and flush.
      ;;--------------------------------------------------------------
      (let ((caps %terminal))
        (%emit (tty-termcap-modes caps))
        (%emit (if (tty-visible-cursor caps)
                   (tty-cursor-visible caps)
                   (tty-cursor-normal caps)))
        (%emit (tty-keypad-mode caps))
        (losecursor (tty-cm caps))
        (flush-output-port (current-output-port))))

    (define-method (reset-terminal-modes! (d <tty-display>))
      ;; `tty_reset_terminal_modes` (`term.c:231`): `ke`, the cursor,
      ;; `te`, the default colours, and a raw CR "so kernel can track the
      ;; cursor hpos".
      ;;--------------------------------------------------------------
      (let ((caps %terminal))
        (when caps
          (tty-turn-off-highlight caps)
          (%emit (tty-end-keypad-mode caps))
          (%emit (tty-cursor-normal caps))
          (%emit (tty-end-termcap-modes caps))
          (%emit (tty-orig-pair caps))
          (%tty-write-byte (char->integer #\return))
          (flush-output-port (current-output-port)))))

    (define-method (erase-window-cursor! (d <tty-display>) row column cells
                                         text token)
      ;; Nothing to do: a terminal has one cursor that moves when the
      ;; next glyph is written, so there is never an old one left behind.
      ;;--------------------------------------------------------------
      #t)

    (define-method (draw-window-cursor! (d <tty-display>) row column cells
                                        type width text token)
      ;; **A terminal does not draw its cursor here**, and the C says so
      ;; structurally: `draw_window_cursor` is a hook of the
      ;; window-system redisplay interface, and a tty's `rif` is NULL
      ;; (`term.c`). The terminal has a cursor of its own, which the
      ;; redisplay *places* (`set-terminal-cursor!`) after the frame's
      ;; text has been written and *shows* at the end of the update
      ;; (`update-end!`).
      ;;
      ;; What is recorded here is whether the cursor is to be shown at
      ;; all - GNU Emacs's `cursor_off_p` (`window.h`), which
      ;; `tty_update_end` consults before showing. Emitting a show
      ;; sequence from this hook, as this used to, was what put the
      ;; cursor on screen at whatever cell the last glyph write left it
      ;; (the echo area's row, column 0) before the address moved it.
      ;;--------------------------------------------------------------
      (set-tty-cursor-off! %terminal (eq? type 'no-cursor)))

    (define-method (flush-display! (d <tty-display>))
      ;; Make the screen show the frame.
      ;;--------------------------------------------------------------
      (flush-output-port (current-output-port)))

    (define-method (screen-size (d <tty-display>))
      ;; The terminal's size in cells, which for a terminal is its size in
      ;; pixels - one character is one unit.
      ;;
      ;; **Asked every time, not remembered.** The size is read once at
      ;; `init_tty` into `FrameRows`/`FrameCols`, and GNU Emacs *updates*
      ;; them when it sees the terminal change: `change_frame_size` from
      ;; the SIGWINCH path. Nothing here installs that handler, so the
      ;; way a resize is noticed is this call - caching the startup size
      ;; meant a resized terminal kept drawing a 24-row frame: measured,
      ;; "at 40 rows the mode line is on row 22". `ioctl` is cheap and
      ;; `sync-frame-size!` is what asks.
      ;;--------------------------------------------------------------
      (let ((size (get-tty-size *tty-fd*)))
        (if (and (> (car size) 0) (> (cdr size) 0))
            (cons (cdr size) (car size))
            (let ((caps %terminal))
              (cons (tty-cols caps) (tty-rows caps))))))

    (define-method (column-width (d <tty-display>))
      ;; `FRAME_COLUMN_WIDTH' for a non-window frame.
      ;;--------------------------------------------------------------
      1)

    (define-method (line-height (d <tty-display>))
      ;; `FRAME_LINE_HEIGHT' for a non-window frame.
      ;;--------------------------------------------------------------
      1)

    (define-method (face-metrics (d <tty-display>) face-attrs)
      ;; A terminal has one height for every face.
      ;;--------------------------------------------------------------
      (cons 0 (max 1 (line-height d))))

    (define-method (display-set-size! (d <tty-display>) width height)
      ;; A terminal cannot be asked for a size - `set_window_size_hook'
      ;; is NULL on a termcap frame.
      ;;--------------------------------------------------------------
      #f)

    (define-method (display-cell-size (d <tty-display>))
      ;; One by one.
      ;;--------------------------------------------------------------
      (cons 1 1))

    (define-method (display-color-cells (d <tty-display>))
      ;; `TN_max_colors', which is 16777216 on a terminal that takes a
      ;; 24-bit colour.
      ;;--------------------------------------------------------------
      (let ((caps %terminal))
        (if (*tty-direct-color*)
            16777216
            (tty-max-colors caps))))

    ;;----------------------------------------------------------------
    ;; The selection: OSC 52
    ;;--------------------------------------------------------------

    (define-method (set-selection! (d <tty-display>) selection value)
      (xterm--tty-set-selection selection value))

    (define-method (get-selection (d <tty-display>) selection target-type)
      (xterm--tty-get-selection selection target-type))

    (define-method (display-selections-supported? (d <tty-display>))
      ;; The tty branch of `display-selections-p'.
      ;;--------------------------------------------------------------
      (and (*tty-select-active-regions*) (*xterm--set-selection*) #t))

    ;;----------------------------------------------------------------
    ;; Realizing a face on a terminal
    ;;--------------------------------------------------------------

    (define-method (realize-face (d <tty-display>) face-attrs)
      ;; FACE-ATTRS - the realized attributes the redisplay merged - as
      ;; this display's *token* for the face.
      ;;
      ;; **The token is the folded plist itself**, which is `struct
      ;; face`'s terminal half: `tty_bold_p`, `foreground`, `background`
      ;; and the rest are exactly what `turn_on_face` reads.
      ;;--------------------------------------------------------------
      (realize-tty-face face-attrs))

    ;;----------------------------------------------------------------
    ;; Suspending and resuming the terminal
    ;;--------------------------------------------------------------

    (define-method (suspend-display! (d <tty-display>))
      ;; C-z: `reset_sys_modes` for a terminal, Emacs's `Fsuspend_tty`.
      ;;--------------------------------------------------------------
      (reset-terminal-modes! d))

    (define-method (resume-display! (d <tty-display>))
      ;; Back from the shell: `init_sys_modes` again (`Fresume_tty`).
      ;;--------------------------------------------------------------
      (init-sys-modes)
      (set-terminal-modes! d))

    ;;----------------------------------------------------------------
    ))
