(define-library (schemacs editor dispnew)
  ;; This library mirrors GNU Emacs's `dispnew.c' and, with it, the
  ;; `struct redisplay_interface' of `dispextern.h': the interface
  ;; between the redisplay and a display. Emacs's redisplay (xdisp.c)
  ;; produces glyphs and never draws; dispnew.c's update machinery
  ;; hands them to a display through a per-display vtable of function
  ;; pointers - `write_glyphs', `update_window_begin_hook',
  ;; `draw_window_cursor', `flush_display' and the rest. The vtable is
  ;; expressed here as GOOPS generics dispatching on a display object,
  ;; `<display>'; each display type - the text terminal's
  ;; `<tty-display>', a graphics one later - answers the generics with
  ;; methods. The wording of the departure (a Scheme object system
  ;; where Emacs has a C struct) is in NCURSES-PLAN.txt.
  ;;
  ;; The generics are what a display provides, and the only way the
  ;; editor touches one: xdisp draws through these, keyboard reads
  ;; input through `read-input-event', and the platform sets
  ;; `current-display' when it opens a display. The redisplay never
  ;; imports a display driver.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.
  (import (oop goops) (scheme base))

  (export
   <display>
   current-display
   write-glyphs!
   clear-frame-area!
   update-window-begin!
   update-window-end!
   draw-window-cursor!
   flush-display!
   read-input-event
   key-event->key
   suspend-display!
   resume-display!
   realize-face
   screen-size
   column-width
   line-height
   mouse-position
   *mouse-event-keys*
   display-color-cells
   ;; the selections, which `select' reads and writes through
   get-selection
   set-selection!
   selection-owner?
   selection-exists?
   display-selections-supported?
   )

  (begin

    (define-class <display> ()
      ;; The kind of thing a display is. A display answers the generics
      ;; below; the class itself carries no data - everything a display
      ;; knows comes back through its methods - so it is the type the
      ;; generics dispatch on, with `eq?' identity (`#:pure').
      ;;--------------------------------------------------------------
      #:pure #t)

    (define current-display (make-parameter #f))
    ;; ^ The display the editor is running on: Emacs's `terminal'. The
    ;; platform sets it when it opens (`term.c''s `init_tty' makes the
    ;; terminal the editor's terminal); it is `#f' before any is open,
    ;; which a display call from a non-display context (a unit test
    ;; calling the redisplay's helpers) crashes on, loudly.

    ;;----------------------------------------------------------------
    ;; The generics: what the redisplay needs of a display
    ;;
    ;; Named after the operations of Emacs's `struct redisplay_interface'
    ;; where one exists, and after the terminal calls they stand for
    ;; otherwise. All are single-dispatch on the display; the window or
    ;; buffer being drawn is an argument, never a dispatch key.
    ;;
    ;; Positions and sizes are in PIXELS, which is Emacs's unit too:
    ;; xdisp.c produces glyphs carrying `pixel_width' and glyph rows
    ;; carrying pixel x/y (dispextern.h). A text terminal is the
    ;; degenerate case rather than a separate kind of thing - Emacs gives
    ;; a non-window frame `column_width = 1' and `line_height = 1'
    ;; (frame.c:1182), so on a terminal one character *is* one pixel unit
    ;; and the pixel numbers are the row and column numbers themselves.
    ;; `column-width' and `line-height' are the size of that unit, and
    ;; rows and columns are derived from the pixel size through them, as
    ;; Emacs derives `FRAME_COLS' from `FRAME_PIXEL_WIDTH'.
    ;;------------------------------------------------------------------

    (define-generic write-glyphs!)
    ;; Draw a run of TEXT at pixel Y, X with ATTRIBUTE: the cells xdisp
    ;; has decided are one face. Emacs's `write_glyphs'.
    ;; `(write-glyphs! display text y x attribute)'.

    (define-generic clear-frame-area!)
    ;; Clear the whole display surface, ready for the frame drawn next.
    ;; Emacs's `clear_frame_area' over the frame's whole rectangle.
    ;; `(clear-frame-area! display)'.

    (define-generic update-window-begin!)
    ;; A window is about to be updated: the begin half of Emacs's
    ;; `update_window_begin_hook'. `(update-window-begin! display)'.

    (define-generic update-window-end!)
    ;; The window being updated is done: Emacs's
    ;; `update_window_end_hook'. `(update-window-end! display)'.

    (define *mouse-event-keys*
      ;; The mouse events this tree's front ends make, by the symbol at
      ;; their head. GNU Emacs's `mouse-event-p' (`subr.el') answers the
      ;; same question of `event-basic-type'; this is the set itself,
      ;; because two places have to agree about it and a list written out
      ;; twice does not stay agreed.
      ;;
      ;;   `down-mouse-1'  `mouse-1'  `drag-mouse-1'       button 1
      ;;   `mouse-movement'                                the pointer
      ;;
      ;; **A release after the pointer has moved is `drag-mouse-1'**, not
      ;; `mouse-1' - `mouse.el:3781-3783' binds all three, and the third
      ;; is what re-establishes the region a drag leaves behind. A
      ;; front end whose decode drops it drops the *release*: the drag's
      ;; transient map is never popped and the pointer goes on moving the
      ;; region after the button is up.
      ;;
      ;; It lives here rather than in `keyboard.sld' because both sides
      ;; need it and neither can see the other: the command loop reads it
      ;; to know an event carries a position, and the display reads it to
      ;; know an event is one it made rather than a key to decode.
      ;;--------------------------------------------------------------
      '(down-mouse-1 mouse-1 drag-mouse-1
        down-mouse-2 mouse-2 drag-mouse-2
        down-mouse-3 mouse-3 drag-mouse-3
        mouse-movement))

    (define-generic mouse-position)
    ;; Where the pointer is on this display, as `(X . Y)' in the display's
    ;; own cell units, or `#f' when there is no pointer to be found - a
    ;; terminal, or a window that is not on the screen yet.
    ;;
    ;; GNU Emacs's `mouse_position_hook' (`terminal->mouse_position_hook'),
    ;; which `Fmouse_position' (`frame.c') calls through the frame's
    ;; terminal. `xterm.c''s `XTmouse_position' and `pgtkterm.c''s
    ;; `pgtk_mouse_position' are the two implementations Emacs has.
    ;;
    ;; **It is asked, not inferred from an event.** An event's coordinates
    ;; are relative to the window the pointer was over and mean nothing
    ;; once it leaves that window - so the one caller that needs the
    ;; position while the pointer is *outside* the frame, a drag past the
    ;; edge of a window, cannot read it off an event. Emacs resolves this
    ;; by querying the pointer (`XQueryPointer',
    ;; `gdk_window_get_device_position') every time, and so does this.
    ;;
    ;; `(mouse-position display)'.
    ;;
    ;; The default answers `#f' - "no position" - which is what a terminal
    ;; that cannot report one answers (`term.c:4383' leaves
    ;; `mouse_position_hook' null for a terminal with no mouse at all, and
    ;; `term_mouse_position', `term.c:2973', returns early leaving X and Y
    ;; nil when GPM has never been active). `frame.sld''s `mouse-position'
    ;; then gives the selected frame with nil coordinates, as the C's
    ;; docstring describes for "a mouseless terminal".
    (define-method (mouse-position (d <display>)) #f)

    (define-generic draw-window-cursor!)
    ;; Put the display cursor at pixel ROW, COLUMN (frame coordinates),
    ;; in the shape TYPE, over the text TEXT drawn in TOKEN's face.
    ;; Emacs's `draw_window_cursor'. `(draw-window-cursor! display row
    ;; column cells type width text token)'.
    ;;
    ;; CELLS is how many cells the *glyph* under the cursor takes: a
    ;; cursor over a double-width character is drawn over two cells, as
    ;; Emacs's is - it sits on the glyph, and the glyph is two cells.
    ;; WIDTH is the cursor's own measurement, which is a different number
    ;; and only some types use it: a bar's thickness, an hbar's height.
    ;; Emacs carries the two as `w->phys_cursor_width' and the
    ;; `cursor_width' out-parameter of `get_window_cursor_type'.
    ;;
    ;; TYPE is one of `filled-box-cursor', `hollow-box-cursor',
    ;; `bar-cursor', `hbar-cursor' and `no-cursor' - the C's own
    ;; `text_cursor_kinds' values, which `get-window-cursor-type'
    ;; resolves from the buffer's `cursor-type'.
    ;;
    ;; TEXT and TOKEN are the character under the cursor and its face,
    ;; and they are here because Emacs's cursor does not *hide* what is
    ;; under it: a filled box redraws the glyph in the cursor's colours
    ;; (`draw_phys_cursor_glyph' with `DRAW_CURSOR'), so that "the text
    ;; inside the cursor stays visible" (`xterm.c'). A display that can
    ;; only fill a rectangle must invert the glyph itself, and that takes
    ;; both.
    ;;
    ;; A display whose cursor is the system's - a terminal's, which the
    ;; terminal draws and inverts itself - may ignore every one of these
    ;; but ROW and COLUMN.

    (define-generic flush-display!)
    ;; Everything drawn since the last flap is now what the display
    ;; shows. Emacs's `flush_display'. `(flush-display! display)'.

    (define-generic read-input-event)
    ;; The next input event, or #f when there is none in TIMEOUT
    ;; milliseconds - a negative TIMEOUT blocks. An event's meaning is
    ;; the display's business; a keyboard reads a char, a mouse a
    ;; button. `(read-input-event display timeout)'.

    (define-generic key-event->key)
    ;; What this display says a raw event is, as the *key event* GNU
    ;; Emacs's `make_lispy_event' would have built: an integer carrying
    ;; the character and the modifier bits, or a symbol for a key that is
    ;; not a character (`up', `f1'), or #f when the display has no name
    ;; for it. The display's own key table answers, because
    ;; only the display knows what its codes mean - the terminfo/termcap
    ;; function-key table term.c builds from `struct fkey_table keys[]'
    ;; and turns into `input-decode-map', which keyboard.c's `read_char'
    ;; then applies. `(key-event->key display event)'.

    (define-generic suspend-display!)
    ;; Hand the display back to whatever is around it, so the editor
    ;; can be stopped - and `resume-display!' take it again. Emacs's
    ;; `Fsuspend_tty' / `Fresume_tty', which `suspend-frame' calls.
    ;; `(suspend-display! display)'.

    (define-generic resume-display!)
    ;; Take the display back after `suspend-display!'.
    ;; `(resume-display! display)'.

    (define-generic realize-face)
    ;; The display's token for a face whose realized attributes are
    ;; FACE-ATTRS: what the display will need to draw it. The token is
    ;; opaque to the redisplay, which only hands it back to
    ;; `write-glyphs!'. Emacs's face realization (`realize_face' in
    ;; xfaces.c) is per display for the same reason.
    ;; `(realize-face display face-attrs)'.

    (define-generic screen-size)
    ;; The display's size in pixels, as `(WIDTH . HEIGHT)' - Emacs's
    ;; frame `pixel_width' and `pixel_height'. The row and column counts
    ;; are derived from these through `column-width' and `line-height'.
    ;; `(screen-size display)'.

    (define-generic column-width)
    ;; The width of one character unit in pixels: Emacs's
    ;; `FRAME_COLUMN_WIDTH', which is 1 on a text terminal because one
    ;; character there *is* one pixel. `(column-width display)'.

    (define-generic line-height)
    ;; The height of one character unit in pixels: Emacs's
    ;; `FRAME_LINE_HEIGHT', 1 on a text terminal. `(line-height display)'.

    (define-generic display-color-cells)
    ;; How many colours the display can show at once - zero for a
    ;; monochrome one. `(display-color-cells display)'.

    ;; The selections - `PRIMARY', `SECONDARY' and `CLIPBOARD', the
    ;; window system's way of moving text between programs. These are
    ;; Emacs's `gui-backend-get-selection' and friends
    ;; (`select.el'), whose cl-defgenerics dispatch on the window
    ;; system; here the display is the dispatch key, as
    ;; `read-input-event' already is. The methods below are the
    ;; cl-defgenerics' *default* methods, which answer nil: a text
    ;; terminal has no selections - `xselect.c' never runs without a
    ;; window system - and a backend answers them with more specific
    ;; methods on its own display class (`pgtk-win.el''s methods for
    ;; `window-system' pgtk, which this tree's `pgtk.sld' mirrors).

    (define-generic get-selection)
    ;; Read a selection off the display. SELECTION is a symbol -
    ;; `PRIMARY', `SECONDARY' or `CLIPBOARD' - and TARGET-TYPE the kind
    ;; of data asked for (`STRING', `UTF8_STRING', `TIMESTAMP'). The
    ;; answer is the text, or #f when the selection has no text to
    ;; give. `(get-selection display selection target-type)'.
    (define-method (get-selection (d <display>) selection target-type) #f)

    (define-generic set-selection!)
    ;; Assert ownership of SELECTION holding VALUE, or - VALUE #f -
    ;; disown it, which is "there is no such selection".
    ;; `(set-selection! display selection value)'.
    (define-method (set-selection! (d <display>) selection value) #f)

    (define-generic selection-owner?)
    ;; Whether this process owns SELECTION. Emacs's
    ;; `gui-backend-selection-owner-p'.
    ;; `(selection-owner? display selection)'.
    (define-method (selection-owner? (d <display>) selection) #f)

    (define-generic selection-exists?)
    ;; Whether SELECTION has an owner at all, whoever it is. Emacs's
    ;; `gui-backend-selection-exists-p'.
    ;; `(selection-exists? display selection)'.
    (define-method (selection-exists? (d <display>) selection) #f)

    (define-generic display-selections-supported?)
    ;; Whether the display can carry selections at all - the question
    ;; `display-selections-p' asks a window-system-less display, and the
    ;; command loop's post-command selection update with it. Emacs asks
    ;; it of the terminal directly (`frame.el:2786''s terminal parameter
    ;; `xterm--set-selection'); here the answer is a method, because
    ;; frame.sld must not import xterm.sld - xterm.sld pulls ncurses
    ;; in, and the GTK build is ncurses-free.
    (define-method (display-selections-supported? (d <display>)) #f)

    ;;----------------------------------------------------------------
    ))