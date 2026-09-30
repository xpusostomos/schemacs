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
    ;; Key events: raw key -> keymap path
    ;;
    ;; Keyboard.sld reads keys through `read-input-event' and asks the
    ;; display what a key means; the decode is a terminal question (what
    ;; the keypad and terminfo say a code is), so the answer is this
    ;; display's method. It is the counterpart of term.c's key table -
    ;; `struct fkey_table keys[]' and the `term_get_fkeys_1' that fills
    ;; `input-decode-map' from it - which keyboard.c's `read_char' then
    ;; applies.
    ;;------------------------------------------------------------------

    (define named-key-names
      ;; The key at the front of an ncurses extended keyname, as the name
      ;; this editor's keymaps use for it. The names are terminfo's:
      ;; `kUP3' is the up key, and the `3' is the modifier.
      ;;--------------------------------------------------------------
      '(("UP" . "up") ("DN" . "down") ("LFT" . "left") ("RGT" . "right")
        ("HOM" . "home") ("END" . "end") ("DC" . "delete")
        ("IC" . "insert") ("PP" . "prior") ("NP" . "next")))

    (define named-key-modifiers
      ;; The digit ncurses puts after the key name, as the modifiers it
      ;; stands for. The digits are xterm's `CSI 1 ; N A' numbering, which
      ;; is the numbering terminfo's `kUP3'-style names are built from,
      ;; and GNU Emacs reads the sequences the same way in
      ;; `term/xterm.el' (`\e[1;3A' is `[M-up]' there).
      ;;
      ;; 2, 4, 6 and 8 all carry Shift, and this editor's keymaps have no
      ;; shift modifier - `(schemacs keymap)''s modifier table has ctrl,
      ;; meta, super, hyper and alt and no more - so those answer #f and
      ;; the key is reported unhandled, which is where it was before.
      ;;--------------------------------------------------------------
      '(("3" (meta)) ("5" (ctrl)) ("7" (meta ctrl))))

    (define (extended-key->keymap-path ev)
      ;; The keymap path for an extended keycode, or #f when it is not one
      ;; this editor knows a name for. ncurses names them from terminfo -
      ;; `(keyname 532)' answers "kDN3" - so what is decoded is that name:
      ;; the key, and the modifier digit after it.
      ;;
      ;; `keyname' can only be asked once the terminal is open, which is
      ;; why this cannot be a table built at load time. It costs one call
      ;; per modified key press, and nothing at all for the keys the
      ;; constants above already cover.
      ;;--------------------------------------------------------------
      (let ((name (keyname ev)))
        (and (string? name)
             (< 2 (string-length name))
             (char=? (string-ref name 0) #\k)
             (let* ((base (substring name 1 (- (string-length name) 1)))
                    (digit (string (string-ref name
                                               (- (string-length name) 1))))
                    (key (assoc base named-key-names))
                    (modifiers (assoc digit named-key-modifiers)))
               (and key modifiers
                    (append (cadr modifiers) (list (cdr key))))))))

    (define-method (key-event->keymap-path (d <tty-display>) ev)
      ;; Convert one of this terminal's key events to a keymap path: a
      ;; list of modifier symbols and characters (or #f when the event
      ;; cannot be converted).
      ;;
      ;; A keypad key becomes a *named* key - `("up")', `("down")',
      ;; `("home")' and the rest - which is what GNU Emacs sees a
      ;; terminal arrow key as. They used to be folded onto the control
      ;; key that moves the same way (KEY_UP to `(ctrl #\p)' and so on),
      ;; which is what a terminal does when it has no arrow keys; the
      ;; cost is that `M-<up>' - a key of its own in Emacs's
      ;; `minibuffer-local-completion-map' - arrived as M-C-p and could
      ;; not be bound. The control keys are still bound to the same
      ;; commands, so folding them is no longer a behaviour anything
      ;; depends on.
      ;;--------------------------------------------------------------
      (cond
       ((char? ev)
        (let ((ci (char->integer ev)))
          (cond
           ((char=? ev #\return) (list 'ctrl #\m))
           ((char=? ev #\newline) (list 'ctrl #\j))
           ((char=? ev #\esc) (list 'ctrl #\[))
           ((or (= ci 127) (char=? ev #\backspace))
            (list 'ctrl #\h))
           ;; NUL is C-@, and C-@ is C-SPC: one key, one byte, and the
           ;; binding for the mark is on it.
           ((= ci 0) (list 'ctrl #\@))
           ((and (< 0 ci) (< ci 27))
            (list 'ctrl (integer->char (+ 96 ci))))
           ((and (>= ci 28) (< ci 32))
            (list 'ctrl (integer->char ci)))
           ((and (>= ci 32) (not (= ci 127)))
            (list ev))
           (else #f))))
       ((integer? ev)
        (cond
         ((= ev KEY_LEFT)  (list "left"))
         ((= ev KEY_RIGHT) (list "right"))
         ((= ev KEY_UP)    (list "up"))
         ((= ev KEY_DOWN)  (list "down"))
         ((= ev KEY_HOME)  (list "home"))
         ((= ev KEY_END)   (list "end"))
         ((= ev KEY_DC)    (list "delete"))
         ;; DEL and BS are the same event in a terminal, and Emacs reads
         ;; that byte as `C-h' - which is why both spellings of the
         ;; backspace key land on the same binding here.
         ((= ev KEY_BACKSPACE) (list 'ctrl #\h))
         ((= ev KEY_RESIZE) (list 'resize))
         ;; Anything else: ncurses reports a key carrying a *modifier* as
         ;; an extended keycode - one above `KEY_MAX', named from
         ;; terminfo - and `M-<down>' arrives as the code ncurses calls
         ;; `kDN3' rather than as anything the constants above cover.
         (else (extended-key->keymap-path ev))))
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

    (define-method (draw-window-cursor! (d <tty-display>) row column cells)
      ;; The one terminal cursor, put where input shows itself going.
      ;;
      ;; CELLS is ignored: the cursor is the terminal's own, and a
      ;; terminal draws a cursor over a double-width character two cells
      ;; wide without being told - it knows the character there. There is
      ;; nothing to move it to but the character's first cell, which is
      ;; COLUMN.
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
      ;; keys mean to this terminal: a character, a keypad key's code, or
      ;; #f when nothing arrived - which is a timed-out read or the end
      ;; of input, the caller telling the two apart by the TIMEOUT it
      ;; asked for.
      ;;
      ;; The keypad's Backspace is answered as DEL (`#\backspace'), the
      ;; character the search and the prompt know it by. The keymap
      ;; decode reads both spellings of the byte as `C-h', so the command
      ;; loop cannot tell the difference.
      ;;--------------------------------------------------------------
      (timeout! (stdscr) timeout)
      (let ((ev (getch (stdscr))))
        (cond
         ((or (eqv? ev ERR) (eqv? ev #f)) #f)
         ((and (integer? ev) (= ev KEY_BACKSPACE)) #\backspace)
         (else ev))))

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