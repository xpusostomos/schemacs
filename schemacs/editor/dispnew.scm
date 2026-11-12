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
   ;; `windows_or_buffers_changed` (`xdisp.c`) - see the note below.
   windows-or-buffers-changed? set-windows-or-buffers-changed!
   write-glyphs!
   draw-box!
   glyphs->text
   clear-frame-area!
   clear-end-of-line!
   ensure-surface!
   update-window-begin!
   update-window-end!
   draw-window-cursor!
   erase-window-cursor!
   ;; the terminal hooks, which are `struct terminal`'s `*_hook`
   ;; fields in Emacs (`termhooks.h`)
   cursor-to! raw-cursor-to! clear-to-end! clear-frame!
   update-begin! update-end! set-terminal-modes! reset-terminal-modes!
   flush-display!
   read-input-event
   key-event->key
   suspend-display!
   resume-display!
   delete-frame-display!
   realize-face
   screen-size
   column-width
   line-height
   face-metrics
   display-cell-size
   display-set-size!
   display-mouse-position
   *mouse-event-keys*
   display-color-cells
   display-font-families
   ;; the selections, which `select' reads and writes through
   get-selection
   set-selection!
   selection-owner?
   selection-exists?
   display-selections-supported?
   )

  (begin

    ;;----------------------------------------------------------------
    ;; What the redisplay must not trust
    ;;
    ;; GNU Emacs's `windows_or_buffers_changed` (`xdisp.c`): non-zero means
    ;; "a window's contents, its size or its faces have changed, so no
    ;; cached glyph matrix can be trusted". The redisplay reads it, and it
    ;; is *set* from far below - `xfaces.c' sets it when a face changes
    ;; (`:801`, `:3110`, `:3200`), `Fset_window_buffer` sets it, and
    ;; `force-mode-line-update` sets it.
    ;;
    ;; **Emacs keeps it in `xdisp.c' and here it cannot live there**: the
    ;; redisplay *skips* a window whose matrix is still good, so whoever
    ;; changes a face has to be able to say so, and faces are realized
    ;; below this library. This is the lowest library the redisplay, the
    ;; faces and the front ends all import - the same answer `*current-
    ;; buffer*' got when `frame' needed what `buffer' owned.
    ;;------------------------------------------------------------------

    (define windows-or-buffers-changed #f)

    (define (windows-or-buffers-changed?)
      ;; The reader, because the variable cannot be one across libraries:
      ;; Emacs's `windows_or_buffers_changed` is a C int that `xfaces.c`
      ;; writes and `xdisp.c` reads, and a Scheme binding is neither.
      ;;--------------------------------------------------------------
      windows-or-buffers-changed)

    (define (set-windows-or-buffers-changed! value)
      (set! windows-or-buffers-changed (and value #t)))

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

    (define-generic face-metrics)
    ;; The ascent and descent of a face on this display, in pixels, as
    ;; `(ASCENT . DESCENT)` - Emacs's `struct face`'s font, whose
    ;; `font->ascent` and `font->descent` are what
    ;; `compute_line_metrics` (`xdisp.c:24077`) accumulates into a glyph
    ;; row:
    ;;
    ;;     row->ascent = it->max_ascent;
    ;;     row->height = it->max_ascent + it->max_descent;
    ;;
    ;; **A row is as tall as the tallest face on it**, which is what makes
    ;; a line of scaled text taller than its neighbours instead of moving
    ;; them. A terminal answers `(0 . 1)` for everything - one line, one
    ;; pixel, as `FRAME_LINE_HEIGHT` is 1 there.
    ;; `(face-metrics display face-attrs)`.

    (define-generic write-glyphs!)
    ;; Draw LEN glyphs of ROW's area AREA, starting at cell column X.
    ;; GNU Emacs's `write_glyphs` (`dispextern.h`):
    ;;
    ;;   void (*write_glyphs) (struct window *w, struct glyph_row *row,
    ;;                         struct glyph *string, enum glyph_row_area area,
    ;;                         int len);
    ;;
    ;; **Everything the call needs is in ROW**, which is why the C passes
    ;; it: the pixel y is `row->y`, the pixel x comes from the row's own
    ;; geometry and the column, and each glyph carries its `face_id`. This
    ;; generic used to take `(glyphs y x attribute)` - a position and an
    ;; already-realized face - which meant the redisplay worked out what a
    ;; backend could work out for itself, and it left no place for a
    ;; terminal backend that wants to decide for itself.
    ;;
    ;; **The run split is the backend's**, as it is in Emacs: the GUI
    ;; backend groups by `face_id` exactly as `fill_glyph_string`
    ;; (`xdisp.c:31157`) does, and a terminal backend has its own writer.
    ;; Splitting above the interface put that decision in the redisplay
    ;; for both back ends whether or not they wanted it.
    ;;
    ;; One glyph is one buffer column: a character, or the string the
    ;; display table draws in its place.
    ;; `(write-glyphs! display window row area x glyphs len)`.

    (define-generic cursor-to!)
    ;; Put the cursor at screen row / cell column VPOS, HPOS - GNU Emacs's
    ;; `cursor_to` (`xdisp.c`), which is `tty_cursor_to` (`term.c:408`)
    ;; for a terminal. `(cursor-to! display window vpos hpos)`.

    (define-generic raw-cursor-to!)
    ;; Move the cursor to absolute screen row/column VPOS, HPOS without
    ;; the cost model - Emacs's `raw_cursor_to` (`term.c:430`), used when
    ;; nothing else is being drawn. `(raw-cursor-to! display vpos hpos)`.

    (define-generic clear-to-end!)
    ;; Erase from the cursor to the end of the screen - Emacs's
    ;; `clear_to_end` (`term.c:449`). `(clear-to-end! display)`.

    (define-generic clear-frame!)
    ;; Erase the whole terminal screen - Emacs's `clear_frame`
    ;; (`term.c:472`). `(clear-frame! display)`.

    (define-generic update-begin!)
    ;; The terminal's begin-update hook, Emacs's `update_begin`.
    ;; `(update-begin! display)`.

    (define-generic update-end!)
    ;; The terminal's end-update hook, Emacs's `update_end`
    ;; (`term.c:254`), which puts the cursor back.
    ;; `(update-end! display)`.

    (define-generic set-terminal-modes!)
    ;; Enter the terminal's program modes, Emacs's `set_terminal_modes`
    ;; (`term.c:202`). `(set-terminal-modes! display)`.

    (define-generic reset-terminal-modes!)
    ;; Leave them again, Emacs's `reset_terminal_modes` (`term.c:231`).
    ;; `(reset-terminal-modes! display)`.

    (define-generic clear-frame-area!)
    ;; Clear the whole display surface, ready for the frame drawn next.
    ;; Emacs's `clear_frame_area' over the frame's whole rectangle.
    ;; `(clear-frame-area! display)'.

    (define-generic ensure-surface!)
    ;; Make sure DISPLAY has a surface to draw into, without painting it.
    ;; Emacs makes a frame's surface when the frame is *realized* and
    ;; `clear_frame_area` only fills it; this tree had them in one call,
    ;; which is invisible until a redisplay legitimately stops clearing.
    ;; `(ensure-surface! display)`.

    (define-generic clear-end-of-line!)
    ;; Blank ROW's area AREA from cell column X to the window's right
    ;; edge. GNU Emacs's `clear_end_of_line`
    ;;
    ;;   void (*clear_end_of_line) (struct window *w, struct glyph_row *row,
    ;;                              enum glyph_row_area area, int x);
    ;;
    ;; whose whole job is the case a terminal's `addstr` cannot express:
    ;; "This can happen when the new row is shorter than the old one"
    ;; (`dispnew.c:4731`, `:4960`). **Both back ends need it** and only
    ;; one gets it for free: a GUI fill paints a rectangle, but `addstr`
    ;; writes over the cells it is given and leaves whatever was to their
    ;; right - which is how two files came to be visible in one window
    ;; after the second was visited.
    ;;
    ;; The backend takes the row's pixel y from ROW and the width from
    ;; `window_box_width (w, area)`, as Emacs's do; the height argument
    ;; the old shape carried is gone with them.
    ;; `(clear-end-of-line! display window row area x width)`.

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

    (define-generic display-mouse-position)
    ;; **`display-mouse-position' and not `mouse-position'**, which is
    ;; `frame.c`'s `Fmouse_position` and is `frame.scm`'s. This is the
    ;; *hole* the C calls through - `terminal->mouse_position_hook`,
    ;; `XQueryPointer` on X - and a C struct field has no Lisp name to
    ;; borrow, so it takes this tree's spelling for a display seam. It was
    ;; called `mouse-position' until 2026-10-14, which is two libraries
    ;; exporting one name with two bindings; `frame.scm' imported it under
    ;; this name anyway (`(rename ... mouse-position display-mouse-position)').
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
    (define-method (display-mouse-position (d <display>)) #f)

    (define-generic draw-box!)
    ;; Draw the `:box` face attribute around a run: GNU Emacs's
    ;; `draw_glyph_string_box` (`pgtkterm.c`, `xterm.c`). A terminal has
    ;; no box - `term.c`'s face realization drops `:box` entirely and
    ;; `tty_write_glyphs` draws only the run - so this is a no-op there.
    ;; `(draw-box! display box token x y cells height left? right?)`.
    ;;
    ;; BOX is the face's `:box` value, unparsed (`t`, a colour string, an
    ;; integer, a cons, or the `(:line-width ... :color ... :style ...)`
    ;; plist); TOKEN is the run's realized face, whose foreground and
    ;; background are the defaults the box's colour falls back to. X is
    ;; a cell column like `write-glyphs!`'s, Y a pixel, CELLS the run's
    ;; width in cells and HEIGHT its height in pixels. LEFT? and RIGHT?
    ;; are Emacs's `left_box_line_p`/`right_box_line_p`: a box drawn
    ;; over several runs has its vertical edges only where the boxed
    ;; region begins and ends.
    (define-method (draw-box! (d <display>) box token x y cells height
                              left? right?)
      #f)

    (define-generic erase-window-cursor!)
    ;; Take the cursor off the screen: GNU Emacs's `erase_phys_cursor`
    ;; (`xdisp.c:35146`), whose last act is
    ;;
    ;;     /* Erase the cursor by redrawing the character underneath it.  */
    ;;     draw_phys_cursor_glyph (w, cursor_row, hl);
    ;;
    ;; - the glyph at the *previous* cursor position, redrawn in its own
    ;; face. `(erase-window-cursor! display row column cells text token)',
    ;; with the arguments `draw-window-cursor!' takes less TYPE and
    ;; WIDTH: there is no shape to draw, only the glyph to put back.
    ;;
    ;; **This is not optional once a frame stops being repainted whole.**
    ;; The cursor is painted *over* a row, so moving it leaves the old
    ;; one behind - Chris, on GTK: "moving the cursor around leaves a
    ;; trail like a snake". Emacs gets it right by remembering
    ;; `w->phys_cursor` and erasing it before drawing the new one. A
    ;; terminal does not need the glyph put back - curses moves one
    ;; cursor - which is why its method here does nothing.

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

    (define (glyphs->text glyphs)
      ;; The run's cells as one string: the boundary's join, and the
      ;; counterpart of what a device takes. A terminal writes the cells;
      ;; Pango is handed a string built from the run, which is what GNU
      ;; Emacs's own pgtk back end does with a `struct glyph_string'.
      ;; It is here because all three displays want the same one.
      ;;--------------------------------------------------------------
      (if (string? glyphs) glyphs (apply string-append glyphs)))

    (define-generic delete-frame-display!)
    ;; A frame drawn on this display has been deleted: release what the
    ;; display holds for it. GNU Emacs's `terminal->delete_frame_hook',
    ;; which `delete_frame` calls once the frame is off `frame-list`
    ;; (`frame.c:2937`) - and the frame is already dead by then, which is
    ;; why this takes the display and not the frame.
    ;;
    ;; **What it means differs by display, and the difference is Emacs's.**
    ;; A window system's display holds one window per frame and destroys
    ;; it here - `pgtk_destroy_window` (`pgtkterm.c:600`) reaches
    ;; `pgtk_free_frame_resources` (`:445`), whose visible effect is
    ;; `gtk_widget_destroy (FRAME_WIDGET (f))` (`:579`); `x_destroy_window`
    ;; is the same thing over `XDestroyWindow` (`xterm.c`).
    ;;
    ;; A text terminal's display holds *all* its frames at once and
    ;; destroys nothing: Emacs's `tty_free_frame_resources` (`term.c:4326`)
    ;; frees the frame's face cache and its tty data and leaves the
    ;; terminal alone, because the frames on a tty are screens on one
    ;; terminal and the next redisplay draws the one that is still
    ;; selected. The default method below is therefore the terminal's
    ;; answer, and it is an answer rather than an omission - which is what
    ;; keeps `frame.sld` free of both front ends.
    ;; `(delete-frame-display! display)`.
    (define-method (delete-frame-display! (d <display>)) #t)

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

    (define-generic display-font-families)
    ;; The font families the display can draw with - what `font.c`'s
    ;; `font-family-list` asks each of the frame's font drivers
    ;; (`list_family`). A terminal has no font driver and answers nil;
    ;; a graphical one answers the family names as strings.
    ;; `(display-font-families display)`.

    (define-method (display-font-families (d <display>)) '())

    (define-generic display-cell-size)
    ;; The size of one character unit in *real* pixels, as
    ;; `(WIDTH . HEIGHT)' - `FRAME_COLUMN_WIDTH' and `FRAME_LINE_HEIGHT'
    ;; themselves, where `column-width' and `line-height' answer in this
    ;; redisplay's own unit (a windowed display counts in cells and
    ;; scales when it draws, so its answers are 1 and its pixels are
    ;; here). `frame-char-width' and `frame-char-height' read this, and
    ;; so does `display-pixel-width', which is `screen-size' times it.
    ;; `(display-cell-size display)'.


    (define-generic display-set-size!)
    ;; Ask the display for a frame of WIDTH x HEIGHT pixels: Emacs's
    ;; `set_window_size_hook' (`FRAME_TERMINAL (f)->set_window_size_hook'),
    ;; which `adjust_frame_size' calls once it has decided the native
    ;; size. `(display-set-size! display width height)'.
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