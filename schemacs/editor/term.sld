(define-library (schemacs editor term)
  ;; This library mirrors GNU Emacs's `term.c': the text terminal.
  ;; Emacs has one redisplay that draws through a per-display interface
  ;; (`dispnew.sld''s generics here); this library is the implementation
  ;; of that interface for the curses terminal, in the way term.c is
  ;; for a text terminal: it opens the terminal (`with-terminal', which
  ;; used to be `ncurses.sld''s), draws on it (`write-glyphs!' and the
  ;; other display methods), reads keys from it (`read-input-event'),
  ;; and realizes a face into what a terminal can draw - the attribute
  ;; bits term.c's `turn_on_face' would emit.
  ;;
  ;; A graphics backend later is a sibling library filling the same
  ;; generics; nothing here is imported by the editor's redisplay,
  ;; which draws through `(schemacs editor dispnew)' alone.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.
  (import
    (scheme base)
    (oop goops)
    ;; The terminal itself.
    (ncurses curses)
    ;; The display interface this implements.
    (schemacs editor dispnew)
    ;; A face is realized through the same machinery the redisplay
    ;; merges faces with: `realize-tty-face' makes the realized face,
    ;; and what the terminal can draw of it is computed here - that
    ;; last step is the whole of this library's face code.
    (only (schemacs editor xfaces) attribute-value realize-tty-face)
    ;; Opening a terminal runs `startup.el''s color and face
    ;; initialization against it, so it needs what ncurses.sld used to
    ;; import for that: the eight standard colors, the xterm driver for
    ;; a TERM of xterm*, and the face registry to recalc.
    (only (schemacs editor tty-colors) tty-register-default-colors)
    (only (schemacs editor xterm)
          *input-decode-map* terminal-init-xterm
          *xterm--set-selection* *xterm--get-selection*
          xterm--tty-set-selection xterm--tty-get-selection)
    ;; `tty-select-active-regions' gates the tty branch of
    ;; `display-selections-p', which the selection methods answer for.
    (only (schemacs editor frame) *tty-select-active-regions*)
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          face-list face-spec-recalc)
    ;; The wait this library owns: `select' over the keyboard and the
    ;; back door's pipe, the pipe itself, and the clock its deadline is
    ;; measured with. `internal-time-units-per-second' is a VALUE and not
    ;; a call, as `pgtk.sld''s `pgtk-now-ms' reads it.
    (only (guile) getenv string-prefix? logior
          select pipe setvbuf fileno
          get-internal-real-time internal-time-units-per-second)
    ;; A terminal can be *told* that the back door has work, rather than
    ;; asking on a timer - see `with-terminal' and `read-input-event'.
    (only (schemacs repl) poll-repl! set-repl-wake!))

  (export
   with-terminal
   ;; The display object for an open terminal, for tests that want to
   ;; ask it something directly; nothing in the editor uses it by name.
   <tty-display>
   )

  (begin

    (define-class <tty-display> (<display>))
    ;; ^ A text terminal, the one display `with-terminal' opens.

    ;;----------------------------------------------------------------
    ;; Opening and leaving the terminal
    ;;
    ;; `with-terminal' is what `ncurses.sld' used to be: enter curses
    ;; mode, set the display and run the editor's face initialization
    ;; against the terminal it found, and restore the terminal even if
    ;; the editor raises an error. Its shape is Emacs's `init_tty'
    ;; followed by the frame's face startup.
    ;;------------------------------------------------------------------

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
      ;; class and colour count are the terminal's own answers, which it
      ;; only has once `initscr' has run.
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
      ;; Run THUNK with the terminal in curses mode, restoring the
      ;; terminal even if THUNK raises an error.
      ;;--------------------------------------------------------------
      (dynamic-wind
        (lambda ()
          (initscr)
          (noecho!)
          ;; `raw!' (not `cbreak!') so that C-c and C-z reach the
          ;; editor's keymap instead of raising signals.
          (raw!)
          (nonl!)
          (keypad! (stdscr) #t)
          (scrollok! (stdscr) #f)
          ;; The display the editor draws through from here on.
          (current-display (make <tty-display>))
          ;; Colours have to be started before a pair can be defined, and
          ;; asking first keeps a monochrome terminal from being told to do
          ;; something it cannot. A pair is defined at realize time by
          ;; `realize-face'.
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
          ;; **The back door can be woken here, so nothing has to poll
          ;; for it.** A terminal has no event loop to call back into, so
          ;; its wake is a byte in a pipe that the wait below selects on
          ;; beside the keyboard. It is the same hook `pgtk.sld''s
          ;; `with-gtk-display' sets with an `idle-add', and the
          ;; reasoning for a global rather than a parameter is there.
          (install-repl-wake!)
          )
        thunk
        (lambda () (endwin))
        ))

    ;;----------------------------------------------------------------
    ;; Key events: what the terminal sent -> the Emacs key event
    ;;
    ;; Keyboard.sld reads keys through `read-input-event' and asks the
    ;; display what a key means; the decode is a terminal question (what
    ;; the keypad and terminfo say a code is), so the answer is this
    ;; display's method. It is the counterpart of term.c's key table -
    ;; `struct fkey_table keys[]' and the `term_get_fkeys_1' that fills
    ;; `input-decode-map' from it - which keyboard.c's `read_char' then
    ;; applies.
    ;;------------------------------------------------------------------

    (define function-key-names
      ;; GNU Emacs's `struct fkey_table keys[]' (`term.c:1298'): "This
      ;; structure holds the information for the function keys. The first
      ;; element is the termcap/terminfo capability name and the second
      ;; the name of the Lisp symbol the key should be."
      ;;
      ;; `term_get_fkeys_1' (`term.c:1417') walks that table and, for
      ;; each capability the terminal has, does
      ;;
      ;;     Fdefine_key (Vinput_decode_map, <the escape sequence>, [SYM])
      ;;
      ;; so it keys the decode on the *sequence* `tgetstr' answers. The
      ;; table itself is no more than a pair of names per key, and that
      ;; is all this is.
      ;;
      ;; This editor's terminal layer has already turned the sequence
      ;; into an ncurses keycode by the time it is asked what a key
      ;; means, so the left column is the keycode rather than the
      ;; capability name: the same table with the same right column,
      ;; keyed on what there is to key on. That also makes it a table
      ;; that can be built at load time, where the version this replaced
      ;; had to ask the terminal at every key press.
      ;;
      ;; Not carried, each needing a terminfo lookup this binding does
      ;; not expose: the `kp-*' keypad keys, the `f0' to `f63' run, and
      ;; `insertline', `deleteline', `clearline' and `backtab'.
      ;;--------------------------------------------------------------
      (list (cons KEY_UP 'up)
            (cons KEY_DOWN 'down)
            (cons KEY_LEFT 'left)
            (cons KEY_RIGHT 'right)
            (cons KEY_HOME 'home)
            (cons KEY_END 'end)
            (cons KEY_DC 'delete)
            ;; Insert. Emacs's table spells the termcap name `kI' and its
            ;; symbol `insertchar' (`term.c:1331'), and the comment at
            ;; `bindings.el:1440' says "`insertchar' is what term.c
            ;; produces". Both `[insert]' and `[insertchar]' are bound to
            ;; `overwrite-mode' there, so both are bound here.
            (cons KEY_IC 'insertchar)
            ;; Page Up and Page Down, which nothing in this editor was
            ;; reaching at all until 2026-10-06: they arrived here, the
            ;; old decoder could not read their names, and they were
            ;; dead - which is how PgUp and PgDn came to look broken in
            ;; Dired. `bindings.el' binds `[prior]' and `[next]' to
            ;; `scroll-down-command' and `scroll-up-command'.
            (cons KEY_PPAGE 'prior)
            (cons KEY_NPAGE 'next)))

    (define (%sequence->event ev)
      ;; The event `input-decode-map' gives for the escape sequence an
      ;; ncurses keycode stands for, or #f when it is not one this
      ;; editor knows a sequence for.
      ;;
      ;; This is the path a *modified* function key takes, and the only
      ;; one it can take: ncurses decodes `\e[1;3A' - `M-up' - into an
      ;; extended keycode, `(keyname)' names that keycode from terminfo
      ;; (`kUP3'), and `tiget' turns the name back into the sequence the
      ;; map is keyed on. Emacs reaches the same table by a different
      ;; road: it never asks ncurses to decode at all, it reads the bytes
      ;; and consults `input-decode-map' directly (`keyboard.c').
      ;;
      ;; `tiget' errors for a capability the terminal does not have, and
      ;; a name this editor's keymaps do not know answers #f.
      ;;--------------------------------------------------------------
      (let ((name (keyname ev)))
        (if (not (string? name))
            #f
            (let ((sequence (guard (e (#t #f)) (tiget name))))
              (if (not (string? sequence))
                  #f
                  (let ((entry (assoc sequence (*input-decode-map*))))
                    (and entry (cdr entry))))))))

    (define-method (key-event->key (d <tty-display>) ev)
      ;; The *key event* for what the terminal sent - GNU Emacs's
      ;; `make_lispy_event' for a terminal, which `keyboard.c':8301 is:
      ;;
      ;;     buf.kind = ASCII_KEYSTROKE_EVENT;
      ;;     buf.modifiers = 0;
      ;;     buf.code = cbuf[i];
      ;;
      ;; The byte *is* the event. 24 is `C-x' - which is exactly what
      ;; `(kbd "C-x")' answers, the one-event vector `#(24)' - and 127 is
      ;; DEL and 8 is `C-h', two keys, because they are two bytes. Nothing
      ;; is folded here into a `ctrl' symbol and a letter: that spelling
      ;; is `(schemacs keymap)''s own key representation, which
      ;; `keymap-index' builds from the event where its char-table needs
      ;; one. Nor is there any "keymap path" in GNU Emacs for one to be
      ;; converted to - `define-key''s own docstring (`keymap.c':1084')
      ;; says a key is "a string or a vector of symbols and characters,
      ;; representing a sequence of keystrokes and events".
      ;;
      ;; A keypad key is the one thing that is not a byte: ncurses answers
      ;; a code for it, and Emacs reads an arrow key as the symbol `up'.
      ;; The meta protocol - ESC prefixing the next byte - is not here
      ;; either; it is the command loop's (`keyboard.c':2676').
      ;;--------------------------------------------------------------
      (cond
       ;; A byte, which is the event. `getch' answers a character for one.
       ((char? ev) (char->integer ev))
       ((integer? ev)
        (cond
         ;; The Backspace key: ncurses matched the terminal's `kbs', which
         ;; is `^?' on the terminals here - so what the terminal sent, and
         ;; what GNU Emacs would have read, is the DEL byte.
         ((= ev KEY_BACKSPACE) 127)
         ;; Not a key: the terminal changed size. Emacs reads that as
         ;; SIGWINCH, and `make_lispy_event' makes the `resize' event.
         ((= ev KEY_RESIZE) 'resize)
         ;; The function keys, from the table above.
         (else (let ((k (assq ev function-key-names)))
                 (if k
                     (cdr k)
                     ;; ...and anything else ncurses decoded but has no
                     ;; constant for.
                     (%sequence->event ev))))))
       (else #f)))

    ;;----------------------------------------------------------------
    ;; The display interface, for a text terminal
    ;;
    ;; Every `define-method' below is an implementation of a generic
    ;; from `(schemacs editor dispnew)'. The physical surface is
    ;; ncurses's `stdscr'; a graphics terminal has a different surface
    ;; but answers the same generics.
    ;;------------------------------------------------------------------

    (define-method (write-glyphs! (d <tty-display>) text y x attribute)
      ;; Draw TEXT at row Y, column X with ATTRIBUTE - or the terminal's
      ;; own appearance when ATTRIBUTE is #f, which is what not starting
      ;; a face means. This is the one operation everything a window
      ;; shows comes down to.
      ;;--------------------------------------------------------------
      (when attribute (attr-on! (stdscr) attribute))
      (addstr (stdscr) text #:y y #:x x)
      (when attribute (attr-off! (stdscr) attribute)))

    (define-method (clear-frame-area! (d <tty-display>))
      ;; Erase the whole screen. The full-repaint flag that follows is
      ;; this terminal's own: the partial-update optimizations (scroll
      ;; regions, insert/delete character) desync the physical terminal
      ;; when lines merge, so a forced whole repaint is asked for every
      ;; screen and `flush-display!' honours it. (`clearok!' cannot be
      ;; here - it must be asked for before the refresh that repaints.)
      ;;--------------------------------------------------------------
      (erase (stdscr))
      (clearok! (stdscr) #t))

    (define-method (update-window-begin! (d <tty-display>))
      ;; A terminal draws nothing at a window boundary - the begin/end
      ;; pair exists so a graphics backend can frame a window's damage
      ;; region, and it costs nothing to bracket the redisplay the same
      ;; way here.
      ;;--------------------------------------------------------------
      #t)

    (define-method (update-window-end! (d <tty-display>))
      #t)

    (define-method (draw-window-cursor! (d <tty-display>) row column cells
                                        type width text token)
      ;; The one terminal cursor, put where input shows itself going.
      ;;
      ;; Everything but the position and the type is ignored, and each for
      ;; a reason: the cursor is the *terminal's* own, so a terminal draws
      ;; a cursor over a double-width character two cells wide without
      ;; being told (CELLS), inverts the glyph under it without being
      ;; given it (TEXT and TOKEN), and has no bars or hollow boxes to
      ;; draw (WIDTH). What a terminal *can* be told is whether to show
      ;; its cursor at all, which is what `no-cursor' means - a buffer
      ;; whose `cursor-type' is nil.
      ;;
      ;; Emacs's tty does the same and no more: `term.c' draws no cursor
      ;; of its own, and its cursor handling is `tty_show_cursor' and
      ;; `tty_hide_cursor' around the one the terminal has.
      ;;--------------------------------------------------------------
      (curs-set (if (eq? type 'no-cursor) 0 1))
      (move (stdscr) row column))

    (define-method (flush-display! (d <tty-display>))
      ;; Make the screen show the frame: this is where the forced full
      ;; repaint asked for by `clear-frame-area!' is honoured.
      ;;--------------------------------------------------------------
      (refresh (stdscr)))

    ;;----------------------------------------------------------------
    ;; The back door's wake
    ;;
    ;; A terminal has no event loop to call back into, so the REPL's
    ;; notification has to arrive as something this display's wait can
    ;; see: a byte in a pipe, selected on beside the keyboard.
    ;; `set-repl-wake!' is the same hook Gtk sets with an `idle-add' -
    ;; `pgtk.sld''s `with-gtk-display' is where the reasoning for what it
    ;; is and why it is a global lives, and what follows is the
    ;; terminal's half of it.
    ;;------------------------------------------------------------------

    (define %wake-read #f)
    (define %wake-write #f)
    (define %wake-read-fd #f)
    ;; ^ The wake pipe and the descriptor the wait selects on, or #f
    ;; before the terminal is open.

    (define %keyboard-fd 0)
    ;; ^ The descriptor ncurses reads keys from. `initscr' takes the
    ;; terminal from stdin and `wgetch' reads `sp->_ifd', the same file
    ;; description, so this is that number - asked for rather than
    ;; assumed.

    (define (install-repl-wake!)
      ;; Say that this front end can be woken, with a pipe the server's
      ;; reader thread writes a byte to.
      ;;
      ;; **The write end is unbuffered and that is not optional.** A
      ;; buffered port holds the byte in its own buffer, where the
      ;; descriptor the wait selects on never sees it, and the wake then
      ;; silently does nothing - Guile's `(pipe)' hands back buffered
      ;; ports. `'none' is Guile's spelling of `_IONBF'.
      ;;--------------------------------------------------------------
      (unless %wake-write
        (set! %keyboard-fd
              (guard (e (else 0)) (fileno (current-input-port))))
        (let* ((p (pipe))
               (rd (car p))
               (wr (cdr p)))
          (setvbuf rd 'none)
          (setvbuf wr 'none)
          (set! %wake-read rd)
          (set! %wake-read-fd (fileno rd))
          (set! %wake-write wr)
          (set-repl-wake!
           ;; Writing must not raise into the server's reader thread - a
           ;; wake that fails is a wake that did not happen, and the poll
           ;; that follows the byte is what does the work.
           (lambda () (guard (e (else #f)) (write-u8 1 wr)))))))

    (define (tty-now-ms)
      ;; The clock the deadline in `read-input-event' is measured
      ;; against.
      ;;--------------------------------------------------------------
      (quotient (* 1000 (get-internal-real-time))
                internal-time-units-per-second))

    (define (drain-repl-wake)
      ;; Take out the bytes the server has written to the pipe. One byte
      ;; is written per queued operation, and a byte left unread would
      ;; make every later `select' return at once for ever. What is
      ;; queued is `poll-repl!''s to run, not this.
      ;;--------------------------------------------------------------
      (when (and %wake-read (char-ready? %wake-read))
        (unless (eof-object? (read-u8 %wake-read))
          (drain-repl-wake))))

    (define-method (read-input-event (d <tty-display>) timeout)
      ;; Read one key event, TIMEOUT milliseconds allowed - a negative
      ;; TIMEOUT blocks until one is there. What comes back is what the
      ;; keys mean to this terminal: a character, a keypad key's code, or
      ;; #f when nothing arrived - which is a timed-out read or the end
      ;; of input, the caller telling the two apart by the TIMEOUT it
      ;; asked for.
      ;;
      ;; **`select' owns every wait.** What stood here was `timeout!' and
      ;; a `getch', and the back door could then only be answered by
      ;; cutting the timeout short and asking again - a poll, ten times a
      ;; second, which is the last one in the tree and is what
      ;; `keyboard.sld' still asks for on behalf of a front end that
      ;; cannot be told it has work (`repl-wake'). The wait is now on two
      ;; descriptors: the keyboard, and the pipe `install-repl-wake!' has
      ;; the server write to.
      ;;
      ;; **`getch' is then called with no delay set**, because a byte is
      ;; already on the descriptor and a wait inside it would be a second
      ;; way to miss the caller's deadline. `nodelay' does not bound the
      ;; sequence-assembly wait - a lone ESC sits in that for ESCDELAY
      ;; before coming back - but it is reached only once a byte has been
      ;; *read*: ncurses consults the window's delay only while its own
      ;; buffer is empty, so the peek below is a zero-delay read when
      ;; there is nothing to read, and that is also what lets it report
      ;; KEY_RESIZE after a signal.
      ;;
      ;; The keypad's Backspace is answered as DEL, the byte the
      ;; terminal sends for it (`kbs=^?'): ncurses has matched that byte
      ;; to `kbs' and hands back its own code, and DEL is what GNU Emacs
      ;; would have read there.
      ;;--------------------------------------------------------------
      (let* ((deadline (and (>= timeout 0) (+ (tty-now-ms) timeout)))
             (wake %wake-read-fd))
        (let loop ((spins 0))
          ;; What ncurses is already holding comes first: a byte it took
          ;; while assembling a sequence, or the KEY_RESIZE a signal told
          ;; it about.
          (nodelay! (stdscr) #t)
          (let ((ev (getch (stdscr))))
            (if (not (or (eqv? ev ERR) (eqv? ev #f)))
                (if (and (integer? ev) (= ev KEY_BACKSPACE))
                    (integer->char 127)
                    ev)
                (let ((left (and deadline (- deadline (tty-now-ms)))))
                  (cond
                   ((and left (<= left 0)) #f)
                   ((>= spins 1)
                    ;; The descriptor said there was a key and `getch'
                    ;; found none, twice: that is the end of input, where
                    ;; a readable descriptor means `read' answers 0 for
                    ;; ever. A spurious readiness must not become a loop
                    ;; with nothing to end it, so it answers #f - which
                    ;; is what the caller reads as the end of input.
                    #f)
                   (else
                    ;; **`select' answers ONE value here: the three
                    ;; lists, not three values.** A `let' binding of
                    ;; the call therefore holds `((read) (write)
                    ;; (except))', and a `memq' against that is always
                    ;; false - which reads as "nothing is ever ready"
                    ;; and, with a blocking timeout, spins for ever
                    ;; without ever polling. The read set is the `car'.
                    (let ((ready (car (select (if wake (list %keyboard-fd wake)
                                                (list %keyboard-fd))
                                             '() '()
                                             (if left
                                                 (max 0.001 (/ left 1000.0))
                                                 #f)))))
                      (when (and wake (memq wake ready))
                        (drain-repl-wake)
                        (poll-repl!))
                      ;; Whether the keyboard, the back door or a signal
                      ;; ended the wait, the next turn reads the key if
                      ;; there is one - a resize announcing itself as an
                      ;; empty ready set must not lose the keypress that
                      ;; caused it.
                      (loop (if (memq %keyboard-fd ready) (+ spins 1) 0)))))))))))

    (define-method (screen-size (d <tty-display>))
      ;; The terminal's size in pixels, which for a terminal is its
      ;; columns by its rows: one character is one pixel unit, as Emacs
      ;; makes it with `column_width = 1' / `line_height = 1' on a
      ;; non-window frame (`frame.c''s `make_terminal_frame').
      ;;--------------------------------------------------------------
      (cons (cols) (lines)))

    (define-method (column-width (d <tty-display>))
      ;; One character is one pixel wide on a terminal: Emacs's
      ;; `FRAME_COLUMN_WIDTH' for a non-window frame.
      ;;--------------------------------------------------------------
      1)

    (define-method (line-height (d <tty-display>))
      ;; One character is one pixel tall on a terminal: Emacs's
      ;; `FRAME_LINE_HEIGHT' for a non-window frame.
      ;;--------------------------------------------------------------
      1)

    (define-method (display-color-cells (d <tty-display>))
      ;; How many colours the terminal can show at once, 0 for a
      ;; monochrome one.
      ;;--------------------------------------------------------------
      (if (has-colors?) (max 1 (colors)) 0))

    ;;----------------------------------------------------------------
    ;; The selection: OSC 52
    ;;
    ;; `gui-backend-set-selection' and `gui-backend-get-selection' for
    ;; `window-system' nil - `xterm.el''s tty methods, whose bodies are
    ;; xterm.sld's, because the dispatch here is the display and
    ;; xterm.sld has none. Two one-line delegations, and nothing for
    ;; `selection-owner?' / `selection-exists?': xterm.el defines
    ;; neither method for a terminal, so the defaults answer - #f -
    ;; and a tty Emacs, owning no selection, has `deactivate-mark''s
    ;; region branch always take PRIMARY. That is what Emacs's ttys do.
    ;;--------------------------------------------------------------

    (define-method (set-selection! (d <tty-display>) selection value)
      (xterm--tty-set-selection selection value))

    (define-method (get-selection (d <tty-display>) selection target-type)
      (xterm--tty-get-selection selection target-type))

    (define-method (display-selections-supported? (d <tty-display>))
      ;; The tty branch of `display-selections-p' (`frame.el:2786'):
      ;; `tty-select-active-regions' together with the terminal
      ;; parameter `xterm--set-selection', which the version handler
      ;; sets for an xterm that speaks OSC 52.
      ;;--------------------------------------------------------------
      (and (*tty-select-active-regions*) (*xterm--set-selection*) #t))

    ;;----------------------------------------------------------------
    ;; Realizing a face on a terminal
    ;;
    ;; The display side of a face: what the redisplay hands to
    ;; `write-glyphs!' is the terminal's own drawing token, and this is
    ;; where a realized face becomes one - the colour pair made and the
    ;; emphasis flags folded into one attribute number, which is all a
    ;; terminal can be told. `term.c''s `turn_on_face' does the same
    ;; from a cached face; the pair table here is `tty_face_1''s, and a
    ;; pair is made the first time a combination is asked for because a
    ;; terminal has only so many.
    ;;--------------------------------------------------------------

    (define *tty-color-pairs*
      ;; The colour pairs made so far, as `((FOREGROUND . BACKGROUND) .
      ;; PAIR)'.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (tty-color-pair foreground background)
      ;; The ncurses colour-pair number for FOREGROUND and BACKGROUND,
      ;; making the pair the first time it is asked for. A missing colour
      ;; is #f and becomes -1, which is how ncurses spells "the
      ;; terminal's own default". 0 means no pair at all.
      ;;--------------------------------------------------------------
      (cond
       ((and (not foreground) (not background)) 0)
       ((not (has-colors?)) 0)
       (else
        (let* ((key (cons foreground background))
               (entry (assoc key (*tty-color-pairs*))))
          (cond
           (entry (cdr entry))
           (else
            (let ((n (+ 1 (length (*tty-color-pairs*)))))
              (init-pair! n (if foreground foreground -1)
                          (if background background -1))
              (*tty-color-pairs* (cons (cons key n) (*tty-color-pairs*)))
              n)))))))

    (define (tty-face-attribute face)
      ;; A realized tty face as one ncurses attribute number: the bit
      ;; flags `term.c' would turn into escape sequences, which is all a
      ;; terminal can be told. The colour pair is made here, on first use.
      ;;--------------------------------------------------------------
      (let ((foreground (attribute-value face ':foreground))
            (background (attribute-value face ':background)))
        (let ((bits 0))
          (when (attribute-value face ':bold)
            (set! bits (logior bits A_BOLD)))
          (when (attribute-value face ':underline)
            (set! bits (logior bits A_UNDERLINE)))
          (when (attribute-value face ':reverse)
            (set! bits (logior bits A_REVERSE)))
          (let ((pair (tty-color-pair (if (number? foreground) foreground #f)
                                      (if (number? background) background #f))))
            (if (> pair 0) (logior bits (color-pair pair)) bits)))))

    (define-method (realize-face (d <tty-display>) face-attrs)
      ;; FACE-ATTRS - the realized attributes the redisplay merged - as
      ;; the terminal's attribute number, drawing token and pair table
      ;; included. This is the display's realization of a face, the step
      ;; after the redisplay chose what face a position has.
      ;;--------------------------------------------------------------
      (tty-face-attribute (realize-tty-face face-attrs)))

    ;;----------------------------------------------------------------
    ;; Suspending and resuming the terminal
    ;;
    ;; C-z hands the terminal back to whatever is around it and takes it
    ;; again: the two halves of `suspend-frame', which are Emacs's
    ;; `Fsuspend_tty' / `Fresume_tty' in term.c.
    ;;------------------------------------------------------------------

    (define-method (suspend-display! (d <tty-display>))
      ;; Leave curses mode so the editor can be stopped - the *before*
      ;; half of C-z, Emacs's `reset_sys_modes' for a terminal. The
      ;; shell stops the process; `resume-display!' restores.
      ;;--------------------------------------------------------------
      (endwin))

    (define-method (resume-display! (d <tty-display>))
      ;; Back from the shell: repaint the screen curses had left, the
      ;; *after* half of C-z (`init_sys_modes').
      ;;--------------------------------------------------------------
      (refresh (stdscr)))

    ;;----------------------------------------------------------------
    ))