(define-library (schemacs dispnew)
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
  (import (oop goops) (scheme base)
          (only (guile) make-hash-table hash-ref hash-set!))

  (export
   <display>
   current-display
   ;; `windows_or_buffers_changed` (`xdisp.c`) - see the note below.
   windows-or-buffers-changed? set-windows-or-buffers-changed!
   ;; `update_mode_lines` (`xdisp.c`) - its weaker sibling, see below.
   update-mode-lines? set-update-mode-lines!
   ;; `cursor_in_echo_area` (`dispnew.c:7538`): whether the cursor is
   ;; drawn in the echo area rather than in the selected window's text.
   *cursor-in-echo-area*
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
   window-system-display?
   set-terminal-cursor!
   update-begin! update-end! set-terminal-modes! reset-terminal-modes!
   flush-display!
   read-input-event
   key-event->key
   suspend-display!
   resume-display!
   delete-frame-display!
   realize-face
   lookup-face
   menu-show
   x-file-dialog
   ;; `x-show-tip` / `x-hide-tip` (`xfns.c`, and the Gtk build's in
   ;; `pgtkfns.c`): the tooltip window `tooltip.el` asks for.
   display-show-tip display-hide-tip
   screen-size
   column-width
   line-height
   face-metrics
   display-cell-size
   display-set-size!
   display-mouse-position
   ;; `frame.el`'s `pgtk-mouse-absolute-pixel-position`, `frame.c`'s
   ;; `set-mouse-pixel-position` hook, and `frame_raise_lower_hook`.
   display-mouse-absolute-pixel-position
   display-set-mouse-pixel-position
   display-raise-frame
   display-define-frame-cursor
   display-draw-vertical-border
   display-default-scroll-bar-width
   display-set-window-scroll-bar
   display-redeem-scroll-bars
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

    ;;----------------------------------------------------------------
    ;; The weaker of the two redisplay flags
    ;;
    ;; GNU Emacs's `update_mode_lines` (`xdisp.c:775`): "If this is
    ;; non-zero, the mode line needs to be updated for all windows." It is
    ;; what `bset_update_mode_line` (`xdisp.c:902`) sets on a buffer that
    ;; is shown somewhere, and it is read by two things that are more
    ;; expensive than a mode line:
    ;;
    ;;   * `redisplay_window` folds it into its local `update_mode_line`
    ;;     (`xdisp.c:20537`), which is what makes the *frame's menu bar* be
    ;;     recomputed (`:21522` - "When we reach a frame's selected window,
    ;;     redo the frame's menu bar");
    ;;   * and `update_menu_bar`'s own guard reads it beside
    ;;     `windows_or_buffers_changed` (`xdisp.c:14449`).
    ;;
    ;; **The two flags are not interchangeable, and that is the whole
    ;; reason this one exists.** `windows_or_buffers_changed` says no
    ;; cached glyph matrix can be trusted, so the redisplay rebuilds every
    ;; window; `update_mode_lines` says only that the *cheap* parts of a
    ;; redisplay - the mode line, the frame title, the menu bar - have to
    ;; be recomputed. A window switch sets this one and not the other in
    ;; Emacs, and folding it into the strong flag here (as
    ;; `force-mode-line-update` does, deliberately) made every `set-window-
    ;; start` a full repaint. Measured on Gtk before it existed: the menu
    ;; bar's item parse ran on every keystroke - 2.6 ms of the 7.1 ms that
    ;; `flush-display!` cost, on a keystroke that measured 9.9 ms.
    ;;------------------------------------------------------------------
    (define update-mode-lines #f)

    (define (update-mode-lines?)
      ;; The reader, for the reason `windows-or-buffers-changed?` has one.
      ;;--------------------------------------------------------------
      update-mode-lines)

    (define (set-update-mode-lines! value)
      (set! update-mode-lines (and value #t)))

    (define *cursor-in-echo-area* (make-parameter #f))
    ;; ^ GNU Emacs's `cursor-in-echo-area', `DEFVAR_BOOL` in
    ;; `dispnew.c:7538` and so false by default: whether to put a cursor
    ;; in the echo area - the minibuffer window - rather than in the
    ;; selected window's text. False means the echo area shows its
    ;; message with no cursor, which is what a frame whose minibuffer is
    ;; not being read wants.
    ;;
    ;; It is here rather than in `window.scm`, where this tree kept it,
    ;; because the two readers are the redisplay's:
    ;; `get_window_cursor_type` (`xdisp.c:34825`) asks it, and
    ;; `update_frame` honours it. `window.scm` re-exports it so that
    ;; every name that reached it there still does.

    (define-class <display> ()
      ;; The kind of thing a display is. A display answers the generics
      ;; below; the class itself carries no data - everything a display
      ;; knows comes back through its methods - so it is the type the
      ;; generics dispatch on, with `eq?' identity (`#:pure').
      ;;--------------------------------------------------------------
      #:pure #t)

    (define-generic window-system-display?)
    ;; GNU Emacs's `FRAME_WINDOW_P`: whether this display has a window
    ;; system behind it. It is what `extend_face_to_end_of_line`
    ;; (`xdisp.c`) asks before choosing how a row's remainder is filled -
    ;; a stretch glyph whose background the toolkit paints, or (for a
    ;; terminal) space glyphs written with the face's colours.
    ;; `(window-system-display? display)'.
    ;;
    ;; The class, not a frame's `window-system', because the redisplay
    ;; draws the frame's own display and this tree can have two.

    (define-method (window-system-display? (d <display>)) #f)

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

    (define-generic set-terminal-cursor!)
    ;; Put the display's own cursor where the redisplay decided it goes,
    ;; once the frame's text has been written - GNU Emacs's
    ;; `tty_set_cursor` (`dispnew.c`), which `update_frame` calls as its
    ;; last act before the final flush. It is a *separate* step from
    ;; drawing the cursor: `draw-window-cursor!` is the C's
    ;; `draw_window_cursor` hook, and a terminal has no such hook (its
    ;; `rif` is NULL) because the terminal draws the cursor itself.
    ;; `(set-terminal-cursor! display row column)'.
    ;;
    ;; A window-system display has nothing to place - the toolkit owns
    ;; its cursor - so the default method does nothing.

    (define-method (set-terminal-cursor! (d <display>) row column)
      #t)

    (define-generic clear-to-end!)
    ;; Erase from the cursor to the end of the screen - Emacs's
    ;; `clear_to_end` (`term.c:449`). `(clear-to-end! display)`.

    (define-generic clear-frame!)
    ;; Erase the whole terminal screen - Emacs's `clear_frame`
    ;; (`term.c:472`). `(clear-frame! display)`.

    (define-generic update-begin!)
    ;; The terminal's begin-update hook, Emacs's `update_begin`.
    ;; `(update-begin! display)`.
    ;;
    ;; **A display that is not a terminal has no such hook**, which is
    ;; the C's own arrangement: `update_begin` calls
    ;; `FRAME_TERMINAL (f)->update_begin_hook` only when it is non-NULL
    ;; (`dispnew.c`), and the window-system terminals leave the pair
    ;; NULL - their frame update is the toolkit's. So the default does
    ;; nothing and `term.sld` supplies the terminal's.

    (define-method (update-begin! (d <display>)) #t)

    (define-generic update-end!)
    ;; The terminal's end-update hook, Emacs's `update_end`
    ;; (`term.c:254`), which puts the cursor back.
    ;; `(update-end! display)`.

    (define-method (update-end! (d <display>)) #t)

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

    (define-generic display-mouse-absolute-pixel-position)
    ;; ^ `gdk_device_get_position` (`pgtkfns.c:3518`), which `frame.el`'s
    ;; `mouse-absolute-pixel-position` answers with. The default is `#f`
    ;; - a terminal has no pointer to report, and `frame.el`'s fallback
    ;; for that case is `(cons 0 0)`.
    (define-generic display-set-mouse-pixel-position)
    ;; ^ `FRAME_TERMINAL (f)->set_mouse_position_hook` (`frame_set_mouse_pixel_position`,
    ;; `frame.c:3360`): warp the pointer to (X, Y) in the frame's pixels.
    (define-generic display-raise-frame)
    ;; ^ `FRAME_TERMINAL (f)->frame_raise_lower_hook`, called by
    ;; `raise-frame` (`frame.c:3664`).
    (define-generic display-define-frame-cursor)
    ;; ^ GNU Emacs's `FRAME_RIF (f)->define_frame_cursor`
    ;; (`pgtkterm.c:2853` `pgtk_define_frame_cursor`), which
    ;; `define_frame_cursor1` (`xdisp.c:36592`) calls with the cursor the
    ;; area under the pointer asks for. CURSOR is one of the kinds
    ;; `define-frame-cursor!` names - `text` (`GDK_XTERM`), `nontext`
    ;; (`GDK_LEFT_PTR`), `hand` (`GDK_HAND2`), `hourglass`
    ;; (`GDK_WATCH`), `horizontal-drag` (`GDK_SB_H_DOUBLE_ARROW`),
    ;; `vertical-drag` (`GDK_SB_V_DOUBLE_ARROW`) or `modeline`.
    ;;
    ;; **A terminal has no pointer and so no shape to change**: the
    ;; default does nothing, which is what `term.c`'s
    ;; `define_frame_cursor` hole being absent means there.
    ;; `(display-define-frame-cursor display frame cursor)`.
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

    ;; The three hooks `frame.c` reaches through the terminal, and the
    ;; default of each is the terminal's: a display that cannot warp a
    ;; pointer or raise a window answers `#f' and the caller goes on.
    (define-method (display-mouse-absolute-pixel-position (d <display>)) #f)
    (define-method (display-set-mouse-pixel-position (d <display>) frame x y) #f)
    (define-method (display-raise-frame (d <display>) frame) #f)
    (define-method (display-define-frame-cursor (d <display>) frame cursor) #f)

    (define-generic display-draw-vertical-border)
    ;; ^ GNU Emacs's `FRAME_RIF (f)->draw_vertical_window_border (w, x,
    ;; y0, y1)` (`dispextern.h:3172`), the hook `gui_draw_vertical_border`
    ;; (`xdisp.c:37917`) calls for a window-system frame that has no
    ;; vertical scroll bars. Draw a one-pixel line at pixel column X from
    ;; pixel Y0 to Y1 in the `vertical-border` face - `xfns.c`'s and
    ;; `pgtkterm.c`'s `*_draw_vertical_window_border` both fill a
    ;; one-pixel rectangle with that face's foreground.
    ;;
    ;; **A terminal does not use this hook**, and that is Emacs's
    ;; arrangement rather than an omission: its frame matrix gets a `|'
    ;; glyph in the window's last cell instead
    ;; (`build_frame_matrix_from_leaf_window`, `dispnew.c:2574-2599`),
    ;; which is the renderer's glyph row and not a display method. The
    ;; default here draws nothing for that reason.
    ;; `(display-draw-vertical-border display window x y0 y1)`.
    (define-method (display-draw-vertical-border (d <display>)
                                                 window x y0 y1)
      #f)

    (define-generic display-default-scroll-bar-width)
    ;; ^ GNU Emacs's `terminal->set_scroll_bar_default_width_hook`
    ;; (`termhooks.h`; `x_set_scroll_bar_default_width`,
    ;; `xfns.c:2392`), which `gui_set_scroll_bar_width` calls when the
    ;; frame's `scroll-bar-width` parameter is nil: the width the
    ;; toolkit's own scroll bar wants, in the frame's pixels. Gtk asks
    ;; its theme's `slider-width` and `trough-border`
    ;; (`update_theme_scrollbar_width`, `gtkutil.c:4460`). A terminal
    ;; has no scroll bars, so its answer is 0.
    ;; `(display-default-scroll-bar-width display)`.
    (define-method (display-default-scroll-bar-width (d <display>)) 0)

    (define-generic display-set-window-scroll-bar)
    ;; ^ GNU Emacs's `FRAME_TERMINAL (f)->set_vertical_scroll_bar_hook`
    ;; (`termhooks.h`), which `set_vertical_scroll_bar` (`xdisp.c:20271`)
    ;; calls at the end of every window's redisplay. SIDE is `left` or
    ;; `right` when the window shows a bar, `#f` when it does not (then
    ;; WIDTH is 0 and the display must take any bar away). X, Y, WIDTH and
    ;; HEIGHT are the bar's rectangle in the frame's pixels; PORTION,
    ;; POSITION and WHOLE are the buffer distances the thumb shows, as
    ;; `set_vertical_scroll_bar` computed them.
    ;;
    ;; **`(display-set-window-scroll-bar display window side x y width
    ;; height portion position whole)`.** A terminal draws no scroll
    ;; bars, so the default does nothing; its `window-scroll-bars` is
    ;; still reported, because `window.c`'s functions run on a terminal
    ;; too and answer the configured values with a zero displayed width.
    (define-method (display-set-window-scroll-bar (d <display>) window side
                                                   x y width height
                                                   portion position whole)
      #f)

    (define-generic display-redeem-scroll-bars)
    ;; ^ The second half of Emacs's `redeem_scroll_bar` /
    ;; `judge_scroll_bars_hook` pair: a scroll bar whose window is gone,
    ;; or which no redisplay used, is destroyed. Called once per frame at
    ;; the end of the redisplay with the windows that were drawn;
    ;; `(display-redeem-scroll-bars display windows)`.
    ;;
    ;; **This tree needs a list where the C needs a hook**: Emacs's
    ;; scroll bar object hangs off the window (`w->vertical_scroll_bar`)
    ;; and is freed per window; a display here keeps the toolkit widgets
    ;; and frees the ones whose window is not in the list.
    (define-method (display-redeem-scroll-bars (d <display>) windows) #f)

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

    (define *realized-face-caches* '())
    ;; The realized faces, per display: GNU Emacs's `FRAME_FACE_CACHE'.

    (define (lookup-face display face-attrs)
      ;; GNU Emacs's `lookup_face` (`xfaces.c`): "Look up a realized face
      ;; with a given combination of face attributes. This uses a
      ;; hashtable to look up faces by attributes. Return NULL if there is
      ;; no such face."
      ;;
      ;; **A face's token has to be the *same object* for the same
      ;; attributes**, which is why this exists. Emacs's glyphs carry a
      ;; `face_id`, an integer, and `GLYPH_EQUAL_P` compares them with
      ;; `==`; here the token is whatever `realize-face` made, and a fresh
      ;; one is made per realization. `glyph-equal?` compares tokens with
      ;; `eqv?`, so every rebuilt row compared *unequal* to the one on the
      ;; screen and `update_window` redrew the whole window on every
      ;; keystroke. That was cheap while a row was short and a `ce`; a
      ;; terminal row filled to the edge made it a frame's worth of
      ;; spaces per key. Measured typing one character into a one-line
      ;; buffer: 2311 bytes per keystroke, against GNU Emacs 31.1's 211.
      ;;
      ;; The cache is keyed by the *realized* attributes, so a theme
      ;; change - which produces different attributes - is a different
      ;; key and no invalidation is needed. It is not bounded: Emacs caps
      ;; its cache at `FACE_CACHE_SIZE` and prunes least-used faces,
      ;; which is worth porting if the count ever becomes large.
      ;;--------------------------------------------------------------
      (let ((cache (let ((hit (assq display *realized-face-caches*)))
                     (or (and hit (cdr hit))
                         (let ((h (make-hash-table)))
                           (set! *realized-face-caches*
                                 (cons (cons display h)
                                       *realized-face-caches*))
                           h)))))
        (or (hash-ref cache face-attrs)
            (let ((token (realize-face display face-attrs)))
              (hash-set! cache face-attrs token)
              token))))

    (define-generic menu-show)
    ;; GNU Emacs's `terminal->menu_show_hook` (`termhooks.h`): show the
    ;; menu just built into `menu_items` at X, Y, and answer the item the
    ;; user chose.
    ;;
    ;; The signature is the C's - `(f, xpos, ypos, menuflags, title,
    ;; &error_name)` - with the error name as an exception rather than an
    ;; out-parameter: `(menu-show display frame x y flags title)`.
    ;;
    ;; **The menu is read from `menu_items`, as the C reads it.** An
    ;; earlier draft passed a pane tree instead; that would have been a
    ;; second representation of what `(schemacs menu)` already
    ;; builds, and `tty_menu_show` would no longer be Emacs's function.
    ;; The terminal's implementation is in `(schemacs ui tty term)`; every
    ;; other display builds its menus with a toolkit and answers #f here.
    (define-method (menu-show (d <display>) frame x y flags title)
      #f)

    (define-generic x-file-dialog)
    ;; Ask the display's own file chooser for a file name: GNU Emacs's
    ;; `x-file-dialog` (`xfns.c' and, for Gtk, `pgtkfns.c:3625'), whose
    ;; real docstring is in `xfns.c':
    ;;
    ;;   (x-file-dialog PROMPT DIR &optional DEFAULT-FILENAME MUSTMATCH
    ;;                  ONLY-DIR-P)
    ;;
    ;; "Read a file name from the user, using a file dialog" - the
    ;; graphical chooser a menu or tool bar command gets instead of the
    ;; minibuffer. `read-file-name' reaches it only when
    ;; `next-read-file-uses-dialog-p' says so, so a terminal never calls
    ;; it; the default below is the C's own `check_window_system'
    ;; (`xfns.c`), which refuses every display that has no window
    ;; system.
    ;;
    ;; The display is the first argument because that is this tree's
    ;; spelling for a `struct terminal` hook (`menu-show`, above, takes
    ;; its frame for the same reason). MUSTMATCH and ONLY-DIR-P are
    ;; Emacs's two booleans: an existing file must be chosen, and only
    ;; a directory may be chosen.
    (define-method (x-file-dialog (d <display>) prompt dir default-filename
                                  mustmatch only-dir)
      (error "Window system frame should be used"))

    (define-generic display-show-tip)
    ;; GNU Emacs's `x-show-tip` (`xfns.c:8940`; the Gtk build's is
    ;; `pgtkfns.c:3077`): "Show STRING in a tooltip window ... on FRAME,
    ;; and hide it after TIMEOUT seconds." Answers whether a tip was
    ;; shown - the C answers nil either way, but the caller here
    ;; (`x-hide-tip`'s "was one open") is what needs the distinction, and
    ;; `tooltip-show` only *tests* for the display's existence.
    ;;
    ;; **PARMS, DX and DY are not passed down**, and on the Gtk build
    ;; that is exactly the C: with `use-system-tooltips` (the default)
    ;; `Fx_show_tip` calls `xg_show_tooltip (f, string)` and goes
    ;; straight to arming the hide timer, so the frame parameters and
    ;; the offsets never reach the display. A tooltip on this front end
    ;; is a *system* tooltip whose position the desktop chooses, which is
    ;; what real Emacs shows on the same desktop.
    (define-method (display-show-tip (d <display>) frame string timeout) #f)

    (define-generic display-hide-tip)
    ;; GNU Emacs's `x-hide-tip` (`xfns.c`): hide the tooltip if one is
    ;; shown, and answer non-nil when there was one. `pgtk_hide_tip`
    ;; cancels the hide timer first (`pgtkfns.c:2963`), which the Gtk
    ;; method below does.
    (define-method (display-hide-tip (d <display>)) #f)

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