(define-library (schemacs ui tty term)
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
    ;; `string-ci=?' compares `$COLORTERM' with "truecolor" case-insensitively,
    ;; as `term.c''s `strcasecmp' does.
    (only (scheme char) string-ci=?)
    ;; `display` is `(scheme write)`'s - `(scheme base)` does not export
    ;; it, which this file's gotcha section records.
    (only (scheme write) display)
    (oop goops)
    ;; The terminal itself - its screen management (Phase A removes the
    ;; rest of it), and the input path.
    (ncurses curses)
    ;; The terminfo database, read and written the way Emacs reads and
    ;; writes it: `tigetstr`, `tparm`, `tputs`. See `plans/TTY.md`.
    (only (schemacs ui tty tinfo) setup-term tgetstr tigetstr
          tigetnum tigetflag tparm tputs)
    ;; The display interface this implements.
    (schemacs editor dispnew)
    ;; A face is realized through the same machinery the redisplay
    ;; merges faces with: `realize-tty-face' makes the realized face,
    ;; and what the terminal can draw of it is computed here - that
    ;; last step is the whole of this library's face code.
    ;; `*undefined-face-attribute*` is `faces.scm`'s - the "the face does
    ;; not say" value, which `xfaces` uses and re-exports one of.
    (only (schemacs editor faces) *undefined-face-attribute*)
    (only (schemacs editor xfaces) attribute-value realize-tty-face)
    ;; `write-glyphs!` reads the row it is handed: the pixel y is the
    ;; row's, and each glyph carries its own face - as `term.c`'s
    ;; `tty_write_glyphs` reads `glyph->face_id`.
    (only (schemacs editor glyph)
          glyph-char glyph-face-id glyph-pixel-width glyph-row-y)
    ;; Opening a terminal runs `startup.el''s color and face
    ;; initialization against it, so it needs what ncurses.sld used to
    ;; import for that: the eight standard colors, the xterm driver for
    ;; a TERM of xterm*, and the face registry to recalc.
    (only (schemacs editor tty-colors) tty-register-default-colors)
    (only (schemacs ui tty xterm)
          *input-decode-map* terminal-init-xterm
          *xterm--set-selection*
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
    (only (guile) getenv string-prefix? logior logand ash delq
          delete last-pair caddr
          select pipe setvbuf fileno
          get-internal-real-time internal-time-units-per-second)
    ;; A terminal can be *told* that the back door has work, rather than
    ;; asking on a timer - see `with-terminal' and `read-input-event'.
    (only (scheme-utils repl server) poll-repl! repl-wake!))

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

    (define *tty-direct-color* (make-parameter #f))
    ;; ^ Non-#f when the terminal can be told a colour by its 24-bit value
    ;; instead of by palette index - GNU Emacs's `TF_rgb_separate' and
    ;; `TN_max_colors = 16777216' (`term.c:4755'). A terminal with it is
    ;; drawn in exact colours; one without is drawn through the palette.

    (define (%tiget-safe name)
      ;; `tiget' for a capability the terminal may not have: this binding
      ;; answers #f for one that is absent (and raises for nothing it
      ;; knows), which is `tigetstr''s `(char *) -1' in the C.
      ;;--------------------------------------------------------------
      (guard (err (else #f)) (tiget name)))

    (define (tty-direct-color-supported?)
      ;; GNU Emacs's test, in its order (`term.c:4718-4762'):
      ;;
      ;;   if (tigetstr ("setf24") && tigetstr ("setb24"))  -> 24-bit
      ;;   else if (tigetstr ("setrgbf") && tigetstr ("setrgbb")) -> 24-bit
      ;;   else if (tigetflag ("RGB") > 0)                   -> 24-bit
      ;;   else if (tigetflag ("Tc") > 0
      ;;            || COLORTERM is "truecolor")             -> 24-bit
      ;;
      ;; **The two `tigetflag' tests are not reachable through this
      ;; binding**: guile-ncurses has `tiget' (a *string* capability) and
      ;; `colors' only - no `tigetflag' and no `tigetnum' (checked). A
      ;; terminal that advertises `Tc' or `RGB' and does not set
      ;; `COLORTERM' is therefore drawn through the palette here where
      ;; Emacs would use exact colours - named, and the two string
      ;; capabilities plus `COLORTERM' cover every terminal that sets
      ;; one of them.
      ;;
      ;; `can-change-color?' gates it because the colours are made
      ;; through `init-color!' below: a terminal that will not take the
      ;; redefinition cannot be drawn this way either.
      ;;--------------------------------------------------------------
      (let ((colorterm (getenv "COLORTERM")))
        (and (can-change-color?)
             ;; The colours are *made* in palette slots, so there have to
             ;; be slots - above the sixteen whose meanings are not ours.
             (> (colors) %tty-slot-floor)
             (or (and (%tiget-safe "setf24") (%tiget-safe "setb24") #t)
                 (and (%tiget-safe "setrgbf") (%tiget-safe "setrgbb") #t)
                 (and colorterm (string-ci=? colorterm "truecolor") #t)
                 #f))))

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
            (use-default-colors)
            ;; **Before `initialize-display-faces!', because that is what
            ;; asks the display how many colours it has** - and a
            ;; 24-bit terminal answers `16777216', which is what makes
            ;; `tty-color-24bit' (`tty-colors.scm') stop approximating
            ;; and give a colour its own value.
            (*tty-direct-color* (tty-direct-color-supported?))
            (when (*tty-direct-color*)
              ;; A slot has to be one the terminal has.
              (set! %tty-slot-limit (min 256 (colors)))
              (set! %tty-slots-taken 0)
              (*tty-color-slots* '())
              (*tty-color-pairs* '())))
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
      ;; was `(schemacs editor keymap)''s own key representation, and it is gone -
      ;; `keymap-index' normalises a key to its *events* now, and an event
      ;; is exactly what this answer already is. Nor is there any "keymap
      ;; path" in GNU Emacs for one to be converted to - `define-key''s own
      ;; docstring (`keymap.c':1084') says a key is "a string or a vector
      ;; of symbols and characters, representing a sequence of keystrokes
      ;; and events".
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

    (define-method (write-glyphs! (d <tty-display>) window row area x
                                  glyphs len)
      ;; Draw LEN glyphs of ROW from cell column X - GNU Emacs's
      ;; `write_glyphs` (`dispextern.h`), whose terminal method is
      ;; `tty_write_glyphs` (`term.c:973`) over the same argument list.
      ;;
      ;; A terminal writes one *run* at a time here, because `addstr`
      ;; writes a string in one face - which is `term.c`'s own split
      ;; inside `tty_write_glyphs_1` (`term.c:760`: "Identify a run of
      ;; glyphs with the same face"). The split is below the interface
      ;; now, where Emacs has it, rather than in the redisplay.
      ;;
      ;; **The row carries the position**: `row->y` is the pixel y, and a
      ;; terminal's line is one pixel tall, so `cursor_to (f, row, col)`
      ;; is that y (`frame.c:1182`).
      ;;--------------------------------------------------------------
      (let ((y (glyph-row-y row)))
        (let loop ((i 0) (col x))
          (when (< i len)
            (let* ((g (vector-ref glyphs i))
                   (token (glyph-face-id g))
                   (end (let scan ((j (+ i 1)))
                          (if (and (< j len)
                                   (eqv? (glyph-face-id (vector-ref glyphs j))
                                         token))
                              (scan (+ j 1))
                              j)))
                   (parts (let build ((j i) (acc '()))
                            (if (>= j end)
                                (reverse acc)
                                (build (+ j 1)
                                       (cons (glyph-char
                                              (vector-ref glyphs j))
                                             acc)))))
                   (cells (let sum ((j i) (n 0))
                            (if (>= j end)
                                n
                                (sum (+ j 1)
                                     (+ n (glyph-pixel-width
                                           (vector-ref glyphs j))))))))
              (%tty-write-run d parts y col token)
              (loop end (+ col cells)))))))

    (define (%tty-write-run d glyphs y x attribute)
      ;; One run: the cells from column X of the row at pixel Y, in
      ;; ATTRIBUTE's face - or the terminal's own appearance when
      ;; ATTRIBUTE is #f, which is what not starting a face means. This is
      ;; the old body of `write-glyphs!`, and it is what everything a
      ;; window shows comes down to.
      ;;
      ;; **Y is a pixel offset and a terminal's line is one pixel tall**,
      ;; so the row is Y itself - which is Emacs's tty backend: the glyph
      ;; matrix carries pixel y and `FRAME_LINE_HEIGHT` is 1
      ;; (`frame.c:1182`), so `cursor_to (f, row, col)` is the pixel y
      ;; divided by that one.
      ;;--------------------------------------------------------------
      ;; **The token is the folded face, and the drawing hands it to
      ;; ncurses.** `term.c`'s `turn_on_face` writes its sequences to the
      ;; terminal's output and then `tty_write_glyphs` writes the cells to
      ;; the same output, in that order - one writer. Here ncurses is the
      ;; writer: `addstr` fills its *virtual* screen and nothing reaches
      ;; the tty until `refresh`, so a byte we wrote ourselves would land
      ;; ahead of every glyph on the screen.
      ;;
      ;; Measured, and it is what turned Phase A's steps 1 and 2 round:
      ;; the whole capture was `ESC[7m ESC(B ESC[m` three times, then
      ;; `ESC[H ESC[2J` and the text - every attribute before every cell,
      ;; so no face could ever be applied. `tty-face-attribute` is the
      ;; conversion `turn_on_face` does, expressed as the one thing
      ;; ncurses can be told; `tty-turn-on-face` is the same function
      ;; written the way Emacs writes it, and it is wired when the screen
      ;; is (Phase B). See `plans/TTY.md`.
      ;;--------------------------------------------------------------
      (when attribute (attr-on! (stdscr) (tty-face-attribute attribute)))
      ;; The cells joined: a run is one face, so this is one `addstr'.
      (addstr (stdscr) (glyphs->text glyphs) #:y y #:x x)
      (when attribute (attr-off! (stdscr) (tty-face-attribute attribute))))

    (define-method (clear-end-of-line! (d <tty-display>) window row area x
                                       width token)
      ;; Blank the cells [X, X+WIDTH) of row Y. `addstr` writes over the
      ;; cells it is handed and leaves whatever was to their right, so a
      ;; row that got shorter than the one before kept the old row's
      ;; tail - which is how visiting a second file left the first one's
      ;; lines visible past the end of the new one's. GNU Emacs's tty
      ;; backend answers `clear_end_of_line` with
      ;; `tty_clear_end_of_line` (`term.c`), a run of spaces in the
      ;; row's own face, and that is what this is.
      ;;--------------------------------------------------------------
      (let ((y (glyph-row-y row)))
        (when (> width 0)
          (when token (attr-on! (stdscr) (tty-face-attribute token)))
          (addstr (stdscr) (make-string width #\space) #:y y #:x x)
          (when token (attr-off! (stdscr) (tty-face-attribute token))))))

    (define-method (ensure-surface! (d <tty-display>))
      ;; A terminal's "surface" is the screen it was opened on; there is
      ;; nothing to make. Emacs's tty backend likewise has no realize
      ;; step - `clear_frame` writes to the terminal it already has.
      ;;--------------------------------------------------------------
      #t)

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

    (define-method (draw-box! (d <tty-display>) box token x y cells height
                              left? right?)
      ;; A terminal draws no box. GNU Emacs's `realize_tty_face`
      ;; (`xfaces.c:6756`) folds a face down to weight, slant, underline,
      ;; strike-through, overline and a colour pair - `:box` is not among
      ;; them - and `tty_write_glyphs` writes the run and nothing else.
      ;; Measured, `tsdh-dark`'s red `:box` on the mode line is invisible
      ;; in a terminal Emacs. Asking for one here would be a departure.
      ;;--------------------------------------------------------------
      #f)

    (define-method (cursor-to! (d <tty-display>) window vpos hpos)
      ;; Put the terminal's cursor at VPOS, HPOS - GNU Emacs's
      ;; `tty_cursor_to` (`term.c:408`), whose body is `cmgoto` and then
      ;; `curs_set`. ncurses owns the cursor here, so `move` is that, and
      ;; `cmgoto` arrives with Phase 2 when the screen is ours.
      ;;--------------------------------------------------------------
      (move (stdscr) vpos hpos))

    (define-method (raw-cursor-to! (d <tty-display>) vpos hpos)
      ;; `tty_raw_cursor_to` (`term.c:430`): absolute, no cost model.
      ;;--------------------------------------------------------------
      (move (stdscr) vpos hpos))

    (define-method (clear-to-end! (d <tty-display>))
      ;; `tty_clear_to_end` (`term.c:449`): erase from the cursor down.
      ;;--------------------------------------------------------------
      (clrtobot (stdscr)))

    (define-method (clear-frame! (d <tty-display>))
      ;; `tty_clear_frame` (`term.c:472`).
      ;;--------------------------------------------------------------
      (erase (stdscr)))

    (define-method (update-begin! (d <tty-display>)) #t)

    (define-method (update-end! (d <tty-display>))
      ;; **Nothing yet, and it is `tty_update_end`'s job later.** Emacs's
      ;; puts the terminal cursor back where the redisplay said it should
      ;; be (`term.c:254` -> `tty_set_cursor`); here `ncurses` owns the
      ;; cursor and `draw-window-cursor!` is what places it.
      ;;--------------------------------------------------------------
      #t)

    (define-method (set-terminal-modes! (d <tty-display>))
      ;; `tty_set_terminal_modes` (`term.c:202`) sends `smcup` and
      ;; `smkx`. `initscr`/`keypad!` already did both, in
      ;; `with-terminal`; this becomes the real one in Phase 1.
      ;;--------------------------------------------------------------
      #t)

    (define-method (reset-terminal-modes! (d <tty-display>))
      ;; `tty_reset_terminal_modes` (`term.c:231`): `rmkx`, `rmcup`.
      ;; `endwin` does it today.
      ;;--------------------------------------------------------------
      #t)

    (define-method (erase-window-cursor! (d <tty-display>) row column cells
                                        text token)
      ;; **Nothing to do, and that is the terminal's own cursor.** A
      ;; terminal has one cursor that curses moves when the next glyph is
      ;; written, so there is never an old one left behind; the GUI has a
      ;; cursor *painted* into the surface, which is why it needs the
      ;; glyph put back (`erase_phys_cursor`).
      ;;--------------------------------------------------------------
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
    ;; `repl-wake!' is the same hook Gtk sets with an `idle-add' -
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
          (repl-wake!
           ;; **THE WAKE TAKES ONE ARGUMENT AND THIS FRONT END DOES NOT USE
           ;; IT.** The contract hands the wake a thunk to run on the thread
           ;; that owns the program's state, which is what Gtk's `idle-add'
           ;; needs (`pgtk.scm'); a terminal instead puts a byte where its own
           ;; wait will see it, and that wait is what runs the poll. The
           ;; parameter is named and ignored rather than dropped, because the
           ;; arity IS the contract.
           ;;
           ;; Writing must not raise into the server's reader thread - a
           ;; wake that fails is a wake that did not happen, and the poll
           ;; that follows the byte is what does the work.
           (lambda (drain) (guard (e (else #f)) (write-u8 1 wr)))))))

    (define (%tty-write string)
      ;; Put STRING on the terminal - `cmputc` (`term.c`), which is the
      ;; C's one-character writer and this tree's one write.
      ;;--------------------------------------------------------------
      (display string (current-output-port))
      (flush-output-port (current-output-port)))

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

    (define-method (face-metrics (d <tty-display>) face-attrs)
      ;; A terminal has one height for every face: `FRAME_LINE_HEIGHT` is
      ;; 1 there (`frame.c:1182`), so a row is one pixel tall whatever face
      ;; it is drawn in. Ascent 0, because the terminal places the glyph
      ;; itself.
      ;;--------------------------------------------------------------
      (cons 0 (max 1 (line-height d))))

    (define-method (display-set-size! (d <tty-display>) width height)
      ;; **A terminal cannot be asked for a size.** Its rows and columns
      ;; are the tty's, and Emacs's tty backend leaves
      ;; `set_window_size_hook' unset for exactly that reason
      ;; (`FRAME_TERMINAL (f)->set_window_size_hook' is NULL on a termcap
      ;; frame). The frame follows the terminal instead, which is
      ;; `sync-frame-size!`.
      ;;--------------------------------------------------------------
      #f)

    (define-method (display-cell-size (d <tty-display>))
      ;; And that *is* the pixel size here, which is why the two answers
      ;; above are 1: a terminal has no font to ask for a bigger cell.
      ;;--------------------------------------------------------------
      (cons 1 1))

    (define-method (display-color-cells (d <tty-display>))
      ;; How many colours the terminal can show at once, 0 for a
      ;; monochrome one - and `16777216' when it takes a colour by its
      ;; 24-bit value, which is what GNU Emacs answers on such a terminal
      ;; (`TN_max_colors', `term.c:4760'), and what a spec's
      ;; `(min-colors 256)' branches are tested against.
      ;;--------------------------------------------------------------
      (if (*tty-direct-color*)
          16777216
          (if (has-colors?) (max 1 (colors)) 0)))

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
      ;; PAIR)'. In direct colour the two ends are 24-bit pixels, not
      ;; palette indices.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define %tty-slots-taken 0)
    ;; ^ How many palette slots the direct-colour cache has handed out.
    (define %tty-slot-limit 256)
    ;; ^ The slots it may use: above the sixteen ANSI colours, whose
    ;; meanings other programs on the terminal share.
    (define %tty-slot-floor 16)

    (define *tty-color-slots* (make-parameter '()))
    ;; ^ The 24-bit colours given a palette slot, as `((PIXEL . SLOT)
    ;; ...)', most recently used first - the cache below.

    (define (%tty-split-pixel pixel)
      ;; PIXEL's three 8-bit components, as `init-color!' takes them.
      ;;--------------------------------------------------------------
      (list (ash pixel -16)
            (logand (ash pixel -8) #xff)
            (logand pixel #xff)))

    (define (%tty-slot-of-pixel pixel)
      ;; The palette slot that shows PIXEL, defining one if there is
      ;; none - **the one way a terminal that can take a 24-bit colour
      ;; can be drawn in exact colours through ncurses.** ncurses's
      ;; colour pairs take an index and nothing else: `init-pair!' refuses
      ;; a 24-bit value ("out of range -32768 to < 32767", measured),
      ;; and writing the `38;2;r;g;bm' sequence around `addstr' would
      ;; leave ncurses's own account of the screen and the cursor behind.
      ;; `init-color!' redefines a palette entry instead, and ncurses
      ;; sends it as OSC 4 in the right place in its output and resets
      ;; the palette on `endwin' (both measured) - so a colour a face
      ;; asks for is the colour the terminal shows, exactly, which is
      ;; what GNU Emacs's `TF_rgb_separate' path does with its own
      ;; escape sequences.
      ;;--------------------------------------------------------------
      (let ((hit (assq pixel (*tty-color-slots*))))
        (cond
         (hit
          ;; touch: most recently used first
          (*tty-color-slots* (cons hit (delq hit (*tty-color-slots*))))
          (cdr hit))
         (else
          (let ((slot
                 (cond
                  ((< %tty-slots-taken (- %tty-slot-limit %tty-slot-floor))
                   (set! %tty-slots-taken (+ %tty-slots-taken 1))
                   (- %tty-slot-limit %tty-slots-taken))
                  (else
                   ;; full: the least recently used slot, reused - and
                   ;; every pair that named it is stale, so they go.
                   (let ((victim (car (last-pair (*tty-color-slots*)))))
                     (*tty-color-slots* (delete victim (*tty-color-slots*)))
                     (*tty-color-pairs* '())
                     (cdr victim))))))
            (let ((rgb (%tty-split-pixel pixel)))
              ;; `init-color!' takes thousandths of the component, and
              ;; ncurses turns them back into eighths of a byte by
              ;; truncating - `(VALUE * 255) / 1000' - so the value handed
              ;; in is the *smallest* that truncates back to the byte it
              ;; came from. Rounding instead loses a step: measured,
              ;; `#123456' came back as `rgb:12/34/55'.
              (init-color! slot
                           (quotient (+ (* (car rgb) 1000) 254) 255)
                           (quotient (+ (* (cadr rgb) 1000) 254) 255)
                           (quotient (+ (* (caddr rgb) 1000) 254) 255)))
            (*tty-color-slots* (cons (cons pixel slot) (*tty-color-slots*)))
            slot)))))

    (define (tty-color-index color)
      ;; COLOR - a 24-bit pixel in direct colour, a palette index
      ;; otherwise - as the index the pair table wants.
      ;;--------------------------------------------------------------
      (cond ((not color) -1)
            ((*tty-direct-color*) (%tty-slot-of-pixel color))
            (else color)))

    ;;----------------------------------------------------------------
    ;; Appearances, emitted as bytes
    ;;
    ;; GNU Emacs's `turn_on_face`/`turn_off_face` (`term.c:2111`, `:2203`)
    ;; over the capability strings `tty_init` reads (`term.c:4642-4705`).
    ;; The names below are the *capability* names, which is what
    ;; `tgetstr` takes in the C - `md` for bold, `us` for underline, `me`
    ;; to turn everything off again.
    ;;------------------------------------------------------------------

    (define *tty-inverse-video* (make-parameter #f))
    ;; ^ GNU Emacs's `inverse-video` (a `DEFVAR_BOOL`, `dispnew.c:7492`):
    ;; "Non-nil means invert the video attributes of all frames." It picks
    ;; *which way* `tty_toggle_highlight` toggles standout for a
    ;; default-coloured face (`term.c:2121`), and it is a user option, so
    ;; it is a parameter here, per this tree's convention.

    (define (%cap name)
      ;; A capability string, or #f - **`tgetstr`, not `tigetstr`**.
      ;; The names below are termcap's two-letter ones (`md`, `us`,
      ;; `mr`, `me`, `op`, `AF`, `AB`) because that is what `term.c`
      ;; reads: `tgetstr ("md")` is `ESC[1m` while `tigetstr ("md")` is
      ;; #f, since terminfo spells bold `bold`. Measured both ways
      ;; against a C program linked to `-ltinfo`.
      ;;--------------------------------------------------------------
      (tgetstr name))

    (define (%emit cap)
      ;; `OUTPUT1_IF`: write CAP's sequence when the terminal has one.
      ;;--------------------------------------------------------------
      (let ((seq (and cap (%cap cap))))
        (when seq (%tty-write seq))))

    (define (tty-turn-on-face token)
      ;; GNU Emacs's `turn_on_face` (`term.c:2111`).
      ;;
      ;; TOKEN is this display's realized face - the plist
      ;; `realize-tty-face` folds down to, carrying exactly the fields
      ;; `struct face` does for a terminal: `tty_bold_p`, `tty_italic_p`,
      ;; `tty_reverse_p`, `underline`, `tty_strike_through_p`,
      ;; `tty_overline_p` and the two colours.
      ;;
      ;; Three rules from the C decide what is emitted:
      ;;
      ;;  * **`:inverse-video` swaps the colours** when both come from
      ;;    the face - `realize_tty_face` (`xfaces.c:6860`):
      ;;
      ;;      if (face->tty_reverse_p && !face_colors_defaulted)
      ;;        { swap (foreground, background); }
      ;;
      ;;    so the two colour sequences below carry the swap and no
      ;;    standout is needed.
      ;;  * **when a colour is defaulted there is nothing to swap**, and
      ;;    `turn_on_face` (`term.c:2118`) toggles standout instead -
      ;;    `so`/`se`, and which way depends on the *user option*
      ;;    `inverse-video` (`dispnew.c:7202`), not the face's attribute.
      ;;  * **bold is suppressed on a default-coloured inverted face** -
      ;;    `tty_suppress_bold_inverse_default_colors_p` (`xfaces.c:6869`),
      ;;    which is what keeps a reverse-video mode line readable.
      ;;
      ;; Everything is `tgetstr`'s termcap spelling (`md`, `us`, `so`,
      ;; `se`, `AF`, `AB`), which is what `term.c` reads.
      ;;--------------------------------------------------------------
      (let* ((fg (attribute-value token ':foreground))
             (bg (attribute-value token ':background))
             (fg-defaulted? (or (eq? fg *undefined-face-attribute*) (not fg)))
             (bg-defaulted? (or (eq? bg *undefined-face-attribute*) (not bg)))
             (reverse? (eq? (attribute-value token ':reverse) #t))
             (swap? (and reverse? (not fg-defaulted?) (not bg-defaulted?)))
             (fg (if swap? bg fg))
             (bg (if swap? fg bg)))
        ;; the appearance modes, in the C's order
        (when (and (eq? (attribute-value token ':bold) #t)
                   (not (and reverse? fg-defaulted? bg-defaulted?)))
          (%emit "md"))
        (when (eq? (attribute-value token ':italic) #t)
          ;; "Italics mode is unavailable on many terminals; map slant to
          ;; dimmed text" - `ZH`, else `mh`.
          (if (%cap "ZH") (%emit "ZH") (%emit "mh")))
        (when (attribute-value token ':underline)
          (%emit "us"))
        (when (eq? (attribute-value token ':strike-through) #t)
          (%emit "smxx"))
        (when (eq? (attribute-value token ':overline) #t)
          (%emit "Smol"))
        ;; standout, for the case there is no swap to make
        (when (and reverse? (not swap?))
          (if (*tty-inverse-video*)
              (%emit "se")
              (%emit "so")))
        ;; the colours: `AF`/`AB`, or the 24-bit pair when the terminal
        ;; has them (the same `setf24`/`setb24` the truecolor work reads).
        (unless fg-defaulted?
          (when fg
            (let ((seq (if (%cap "setf24")
                           (tparm "setf24" (ash fg -16)
                                  (logand (ash fg -8) 255) (logand fg 255))
                           (and (%cap "AF") (tparm "AF" fg)))))
              (when seq (%tty-write seq)))))
        (unless bg-defaulted?
          (when bg
            (let ((seq (if (%cap "setb24")
                           (tparm "setb24" (ash bg -16)
                                  (logand (ash bg -8) 255) (logand bg 255))
                           (and (%cap "AB") (tparm "AB" bg)))))
              (when seq (%tty-write seq)))))))

    (define (tty-turn-off-face token)
      ;; GNU Emacs's `turn_off_face` (`term.c:2203`).
      ;;
      ;; `me` turns off every appearance mode at once - "double-bright,
      ;; half-bright, reverse-video, standout, underline, overline,
      ;; strike-through" - and is used only when the face had one on;
      ;; otherwise there is nothing to undo. Then the colours go back to
      ;; the terminal's own with `op`.
      ;;--------------------------------------------------------------
      ;; **`me` only when something was turned on, and reverse only
      ;; counts when `tty-turn-on-face` would have sent it** - the same
      ;; guard, so the two cannot disagree. A face whose `:reverse` was
      ;; suppressed because it names both colours has nothing to undo.
      (let* ((fg (attribute-value token ':foreground))
             (bg (attribute-value token ':background))
             (reverse-emitted?
              (and (eq? (attribute-value token ':reverse) #t)
                   (or (eq? fg *undefined-face-attribute*)
                       (not fg)
                       (eq? bg *undefined-face-attribute*)
                       (not bg))))
             (on? (or (eq? (attribute-value token ':bold) #t)
                      (eq? (attribute-value token ':italic) #t)
                      reverse-emitted?
                      (attribute-value token ':underline)
                      (eq? (attribute-value token ':strike-through) #t)
                      (eq? (attribute-value token ':overline) #t))))
        (cond
         ((%cap "me") (when on? (%emit "me")))
         (else (when (attribute-value token ':underline) (%emit "ue")))))
      (let ((fg (attribute-value token ':foreground))
            (bg (attribute-value token ':background)))
        (when (or (and fg (not (eq? fg *undefined-face-attribute*)))
                  (and bg (not (eq? bg *undefined-face-attribute*))))
          (%emit "op"))))

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
              (init-pair! n
                          (tty-color-index foreground)
                          (tty-color-index background))
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
      ;; this display's *token* for the face.
      ;;
      ;; **The token is the folded plist itself now, not an ncurses
      ;; attribute integer.** GNU Emacs's realized face for a terminal is
      ;; `struct face`, whose `tty_bold_p`, `foreground`, `background` and
      ;; the rest are exactly what `realize-tty-face` folds down to - and
      ;; `turn_on_face` reads those fields to decide which sequences to
      ;; send. An integer could only be read by ncurses, which is the
      ;; thing this phase removes.
      ;;--------------------------------------------------------------
      (realize-tty-face face-attrs))

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