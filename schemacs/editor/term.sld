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
    (only (schemacs editor xterm) terminal-init-xterm)
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          face-list face-spec-recalc)
    (only (guile) getenv string-prefix? logior))

  (export
   with-terminal
   ;; The display object for an open terminal, for tests that want to
   ;; ask it something directly; nothing in the editor uses it by name.
   <tty-display>
   ;; The single-key reads the prompt and search loops make, which are
   ;; terminal questions asked outside the command loop.
   tty-read-char
   tty-unget-event!
   tty-suspend!
   tty-resume!
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
          )
        thunk
        (lambda () (endwin))
        ))

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

    (define-method (draw-window-cursor! (d <tty-display>) row column)
      ;; The one terminal cursor, put where input shows itself going.
      ;;--------------------------------------------------------------
      (move (stdscr) row column))

    (define-method (flush-display! (d <tty-display>))
      ;; Make the screen show the frame: this is where the forced full
      ;; repaint asked for by `clear-frame-area!' is honoured.
      ;;--------------------------------------------------------------
      (refresh (stdscr)))

    (define-method (read-input-event (d <tty-display>) timeout)
      ;; Read one key event, TIMEOUT milliseconds allowed - a negative
      ;; TIMEOUT blocks until one is there. What comes back is what the
      ;; eys mean to this terminal: a character, a keypad key's code, or
      ;; #f when nothing arrived - which is a timed-out read or the end
      ;; of input, the caller telling the two apart by the TIMEOUT it
      ;; asked for.
      ;;--------------------------------------------------------------
      (timeout! (stdscr) timeout)
      (let ((ev (getch (stdscr))))
        (if (or (eqv? ev ERR) (eqv? ev #f)) #f ev)))

    (define-method (screen-size (d <tty-display>))
      ;; The terminal's size in rows and columns.
      ;;--------------------------------------------------------------
      (cons (lines) (cols)))

    (define-method (display-color-cells (d <tty-display>))
      ;; How many colours the terminal can show at once, 0 for a
      ;; monochrome one.
      ;;--------------------------------------------------------------
      (if (has-colors?) (max 1 (colors)) 0))

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
    ;; Raw single-key reads
    ;;
    ;; The prompt and search loops read one key outside the command
    ;; loop's read - the minibuffer's y-or-n question and isearch's own
    ;; reading of the typed key - and what they need is the bare
    ;; character, not an event for the keymap.
    ;;------------------------------------------------------------------

    (define (tty-suspend!)
      ;; Leave curses mode so the editor can be stopped: the *before*
      ;; half of `suspend-frame''s C-z, Emacs's `reset_sys_modes' for a
      ;; terminal. The shell stops the process; `tty-resume!' restores.
      ;;--------------------------------------------------------------
      (endwin))

    (define (tty-resume!)
      ;; Back from the shell: repaint the screen curses had left, the
      ;; *after* half of C-z (`init_sys_modes').
      ;;--------------------------------------------------------------
      (refresh (stdscr)))

    (define (tty-read-char)
      ;; One key from the terminal, with the keypad's Backspace made
      ;; the character DEL (`#\backspace') as the search and the prompt
      ;; know it, or #f at the end of input.
      ;;--------------------------------------------------------------
      (let* ((raw (getch (stdscr)))
             (ev (if (and (integer? raw) (= raw KEY_BACKSPACE))
                     #\backspace
                     raw)))
        ev))

    (define (tty-unget-event! ev)
      ;; Put a key event back on the terminal's input, to be read by the
      ;; next read - isearch's way of re-executing the key that ended
      ;; the search.
      ;;--------------------------------------------------------------
      (ungetch ev))

    ;;----------------------------------------------------------------
    ))