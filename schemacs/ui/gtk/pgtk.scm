(define-library (schemacs ui gtk pgtk)
  ;; This library mirrors the role of GNU Emacs's `src/pgtkterm.c': the
  ;; GTK display. `term.sld' is the text terminal's implementation of
  ;; `(schemacs editor dispnew)''s interface; this is the windowed one -
  ;; same generics, a different surface behind them, and nothing in the
  ;; editor changed to accommodate it. That is the point of the split.
  ;;
  ;; Two things about guile-gi shape this file, both measured rather than
  ;; guessed (GTK-PLAN.md records the experiments):
  ;;
  ;;   * The typelib surface is loaded into THIS module with
  ;;     `typelib->module', and only `<pgtk-display>' and
  ;;     `with-gtk-display' are exported. An R7RS `export' of the
  ;;     typelib's own names fails outright, so the names must stay
  ;;     private; that suits us anyway, since importing them wholesale
  ;;     shadows core bindings (it shadowed `begin').
  ;;   * `push-duplicate-handler!' must be called before any typelib
  ;;     generic is used. Without it every such call fails with a
  ;;     misleading "Too few \"in\" arguments" error.
  ;;
  ;; Drawing is done with guile-cairo, not guile-gi: guile-gi binds no
  ;; cairo primitives (no `move_to', `fill' or `paint'), while guile-cairo
  ;; has them all. The frame is drawn into an image surface we own; when
  ;; Gtk asks the drawing area for a repaint we paint that surface into
  ;; the context it hands us, wrapped as a guile-cairo context.
  ;;
  ;; Positions are pixels, and a character is one pixel - the same
  ;; degenerate case a text terminal is (`term.sld''s `column-width' is
  ;; 1). The editor's redisplay therefore works in cells as it always
  ;; has, and this file multiplies by a font metric to find the pixel.
  ;;
  ;; See GTK-PLAN.md for the plan this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; the `:box` parser reads a four-element result
    (only (scheme cxr) caddr cadddr)
    ;; The clipboard comes through Gtk's own C functions, which
    ;; guile-gi does not bind (see the selections section at the end).
    ;; The pointer procedures are `(system foreign)''s; `dynamic-link'
    ;; and `dynamic-func' are core bindings, which an R7RS library
    ;; reaches through `(guile)' - as `frame.sld''s SIGTSTP does.
    (only (system foreign) pointer->procedure string->pointer pointer->string
          pointer->bytevector null-pointer? make-pointer int void double
          unsigned-int make-c-struct parse-c-struct %null-pointer)
    (only (guile) dynamic-link dynamic-func assq-ref filter
          u32vector->list current-error-port simple-format exit logand)
    ;; `alist-delete' removes one selection from the ownership record;
    ;; `iota' builds the element offsets the 16- and 32-bit selection
    ;; data rows are read at.
    (only (srfi srfi-1) alist-delete iota make-list)
    (only (guile) ash logand logior lognot inexact->exact round
          get-internal-real-time internal-time-units-per-second)
    (oop goops)
    ;; The drawing primitives, which guile-gi does not bind.
    (cairo)
    ;; guile-gi, with its own `equal?' excepted: importing it wholesale
    ;; would shadow `(scheme base)''s. `connect' stays - which `connect'
    ;; is bound here is measured, not guessed: the duplicate-binding
    ;; `merge-generics' handler (pushed below) merges `(gi)''s connect
    ;; with the typelib surface's at this import, and the merged one is
    ;; the only `connect' that survives a real `(connect <GtkWindow>
    ;; <signal> handler)' call - either half alone reads a null GObject
    ;; and the editor dies.
    (except (gi) equal?)
    (gi repository)
    (gi util)
    ;; The GTK surface, from the module that holds it: see pgtk-names.scm
    ;; for why it is not loaded here. `only' is required - the surface is
    ;; thousands of names and importing them wholesale shadows core
    ;; bindings.
    (only (schemacs ui gtk pgtk-names)
          init-check! <GtkWindow> <GtkDrawingArea>
          widget:show-all widget:hide widget:destroy widget:queue-draw
          ;; a *child* widget has to select the events it wants -
          ;; see the button handlers below
          widget:add-events widget:get-window
          widget:can-focus widget:grab-focus widget:set-size-request
          widget:hexpand widget:vexpand window:resizable
          window:resize window:title
          ;; the pointer's own position, which `mouse-position' asks for -
          ;; Emacs's four calls in `pgtk_mouse_position' (`pgtkterm.c:3510')
          display:get-default-seat seat:get-pointer
          window:get-device-position window:get-display
          container:add
          connect set-prgname set-program-class idle-add
          source-remove? timeout-add
          ;; The main loop the read waits in. Gtk drives it; see
          ;; `pgtk-wait!'.
          main-loop:new main-loop:run main-loop:quit
          ;; `pgtk-wait!' drops a nested loop with it, and this
          ;; name had been used there *without* being imported
          ;; since the nested loops were written - the tree's
          ;; recurring missing-import class, invisible until the
          ;; branch that releases a nested loop is taken.
          main-loop:unref
          ;; Running Gtk's own main loop, which is what stage 2 of the
          ;; front-end work is: the loop is Gtk's, not ours.
          main main-quit
          modifier-type->number widget:get-allocated-width
          widget:get-allocated-height
          event:get-state event:get-keyval keyval-to-unicode
          ;; where a button event happened - `pgtk-event-cell' -
          ;; which was used there without being imported, so the
          ;; first click raised inside the signal handler, where
          ;; Gtk swallows it: a click that did nothing at all.
          event:get-coords
          ;;----------------------------------------------------------------
          ;; The menu bar's widgets - gtkutil.c's `create_menus',
          ;; `make_menu_item` and `make_widget_for_menu_item`.
          ;;
          ;; **Every one of these proxies is held for the display's whole
          ;; life** (`pgtk-hold-widget!'). A guile-gi proxy owns its
          ;; GObject through a toggle reference, so a proxy that is
          ;; collected destroys the widget even though Gtk's container
          ;; holds it - measured: a menu bar that survived one GC built
          ;; and then died with "instance with invalid (NULL) class
          ;; pointer" the moment the collector ran. Emacs has no proxy and
          ;; so no such rule.
          ;;----------------------------------------------------------------
          <GtkBox> <GtkMenuBar> <GtkMenu> <GtkMenuItem> <GtkCheckMenuItem>
          <GtkRadioMenuItem> <GtkSeparatorMenuItem> <GtkLabel>
          widget:get-style-context style-context:add-class
          style-context:add-provider
          css-provider:new
          css-provider:load-from-data?
          <GtkOrientation> <GtkAlign>
          box:pack-start box:set-homogeneous
          menu-shell:append menu-item:set-label menu-item:set-submenu
          check-menu-item:set-active check-menu-item:active
          radio-menu-item:join-group
          container:remove container:get-children
          label:set-text widget:set-sensitive widget:set-tooltip-text
          widget:set-halign widget:set-valign orientable:set-orientation)
    ;; `symbol->enum`, for the box's orientation; `(gi types)`'
    ;; (pgtk-names holds the typelib itself).
    (only (gi types) symbol->enum)
    ;; The display interface this implements.
    (only (schemacs editor dispnew)
          menu-show
          <display> *mouse-event-keys* clear-frame-area! clear-end-of-line!
          ensure-surface! column-width
          current-display
          delete-frame-display!
          display-cell-size
          display-color-cells display-font-families
          display-set-size!
          face-metrics
          draw-box! draw-window-cursor! erase-window-cursor! flush-display!
          key-event->key
          display-mouse-position get-selection line-height read-input-event
          realize-face resume-display! screen-size
          selection-exists? selection-owner?
          set-selection! suspend-display! update-window-begin!
          glyphs->text update-window-end! write-glyphs!
          ;; the terminal hooks and the row the Emacs-shaped
          ;; `write-glyphs!` takes (`define-generic`d beside it)
          cursor-to! raw-cursor-to! clear-to-end! clear-frame!
          window-system-display?
          update-begin! update-end! set-terminal-modes! reset-terminal-modes!
          ;; **Whether the menu bar has to be recomputed at all.** GNU
          ;; Emacs's `set_frame_menubar` is reached from `redisplay_window`
          ;; only when `update_mode_line` says so (`xdisp.c:21522`), and
          ;; the hooks and the `menu_items` parse below are its expensive
          ;; half - and they were running on every redisplay, 2.6 ms of
          ;; `flush-display!`'s 7.1 ms per keystroke. See the guard below.
          ;; on every redisplay. Both flags are `xdisp.c`'s and live in
          ;; dispnew for the reason its note gives.
          windows-or-buffers-changed? update-mode-lines?)
    ;; A glyph and a glyph row, which `write-glyphs!` now reads: the
    ;; pixel y is the row's, and each glyph carries its own face.
    (only (schemacs editor glyph)
          glyph-char glyph-face-id glyph-pixel-width glyph-row-y)
    ;; The Lisp half of a *read* of a selection this process owns:
    ;; `pgtk-get-local-selection' looks the requested target up in
    ;; `selection-converter-alist' - the C's `Vselection_converter_alist'
    ;; - and calls the handler it finds. See `select.sld'.
    (only (schemacs editor select)
          *selection-converter-alist*)
    ;; `decode-coding-string' turns the bytes a foreign selection arrived
    ;; as into the tree's code points; that is the half of
    ;; `gui-get-selection' that decodes a `foreign-selection' string, done
    ;; here because this is where the bytes are.
    (only (schemacs editor coding) decode-coding-string)
    ;; `x_new_font`'s resize: the frame keeps its rows and columns at the
    ;; new font unless `frame-inhibit-implied-resize' says otherwise.
    (only (schemacs editor frame) adjust-frame-size! *frame-list* frame-width
          frame-height frame-output frame-set-background-mode
          frame-selected-window window-buffer
          ;; `menu-bar-mode` turns the bar off by setting this on every
          ;; frame, and `set_frame_menubar` acts on it.
          frame-parameter)
    ;; Opening a display initializes faces against it, as `term.sld''s
    ;; `with-terminal' does.
    (only (schemacs editor faces)
          *display-color-cells* *display-type* *frame-background-mode*
          *window-system* face-attribute face-list face-spec-recalc
          set-face-attribute)
    (only (schemacs editor xfaces)
          attribute-value face-attributes-empty merge-face-ref)
    ;; reading a *window's* buffer, not the current one - see
    ;; `pgtk-ensure-font!`
    (only (schemacs editor buffer) with-current-buffer)
    ;; the window being edited, which a prompt takes the selection from
    (only (schemacs editor minibuffer) minibuffer-selected-window)
    ;; How many cells a character takes - a CJK ideograph is one character
    ;; and two cells, so a run is not `string-length' wide.
    (only (schemacs editor disp-table) char-display-width)
    ;; The event model, in `character.sld': the modifier bits a decoder
    ;; ORs into an event, the two C functions that fold a keysym into its
    ;; event - `make_ctrl_char' and `apply_modifiers' - and
    ;; `lispy_function_keys', which names a key that is not a character.
    (only (schemacs editor character)
          apply-modifiers char-ctl char-hyper char-meta char-shift
          char-super function-key-name make-ctrl-char)
    ;; A mouse event needs the *position* it happened at, which is the
    ;; redisplay's own walk - see `posn-at-x-y'.
    (only (schemacs editor xdisp) posn-at-x-y remember-mouse-glyph track-mouse
          *redisplay-in-progress* *after-redisplay-hook*
          ;; The two hooks `set_frame_menubar` runs before it recomputes
          ;; the bar.
          *activate-menubar-hook* *menu-bar-update-hook*)
    ;; `run-hooks` is `subr.el`'s, and a hook is the list of procedures
    ;; it is handed.
    (only (schemacs editor subr) run-hooks)
    ;; The frame's focus, which the window tells us about: it decides
    ;; whether the cursor blinks and whether it is drawn hollow.
    (only (schemacs editor frame)
          *current-frame*
          ;; `pgtk-title-frame!' gives a window its frame's name as a
          ;; title, as Emacs's `x_window' does from `f->name'
          ;; (`gtkutil.c:1656-1663').
          frame-name frame-output
          ;; The input path finds an event's frame through the window it
          ;; arrived on, and selecting it is what makes typing in a second
          ;; window work - Emacs's `focus-in-event' ends in
          ;; `select-frame-set-input-focus' (`frame.el:1264').
          *frame-list* select-frame
          ;; The selection read's failure messages ("No selection: %s"),
          ;; which go through the frame the display belongs to.
          set!frame-message)
    ;; The development back door. `poll-repl!' is a no-op unless
    ;; `main-gtk.scm' was asked to open it; this loop is the only place a
    ;; windowed editor is ever idle, so it is where the REPL gets its turn.
    (only (scheme-utils repl server) poll-repl! repl-wake!)
    ;; **The command loop's two hooks into this display.** When the front
    ;; end's own loop is the one absorbing input, `*dispatch-event*' is
    ;; the procedure an event is handed to and `command-loop-ready?' says
    ;; whether it can take one now; both are #f/the-loop's when a read is
    ;; outstanding instead. See `Pgtk-ENQUEUE!`.
    (only (schemacs editor keyboard)
          *dispatch-event* *unread-command-events* command-loop-ready?
          ;; a mouse event's own value, for the hand-over path above
          *last-read-event*
          ;; What the bar shows: `menu_bar_items`' `[menu-bar]` walk,
          ;; and `menu_separator_name_p`, which the widget builder needs
          ;; to know a `"--"` item from a real one.
          menu-bar-items menu-separator-name?)
    ;; A menu that is cancelled signals quit, exactly as C-g does.
    (only (schemacs editor command) signal-quit)
    ;; `menu-bar-open`'s toolkit branch: `pgtk-menu-bar-open`
    ;; (`term/pgtk-win.el:339`) is installed through this seam.
    (only (schemacs editor menu-bar) *menu-bar-open-function*)
    ;; The platform-independent half of the menu: `menu_items`, the
    ;; `widget_value` tree, and the click's key sequence.
    (only (schemacs editor menu)
          menu-items menu-items-used menu-items-n-panes
          set!menu-items-n-panes!
          ;; The slot layout and the two flags the popup reads.
          menu-items-pane-name menu-items-pane-prefix menu-items-pane-length
          menu-items-item-name menu-items-item-enable menu-items-item-value
          menu-items-item-equiv-key menu-items-item-definition
          menu-items-item-type menu-items-item-selected menu-items-item-help
          menu-items-item-length
          MENU-KEYMAPS MENU-FOR-CLICK
          init-menu-items finish-menu-items
          parse-single-submenu digest-single-submenu update-submenu-strings
          find-and-call-menu-selection
          make-widget-value widget-value?
          widget-value-name widget-value-key widget-value-contents
          widget-value-next widget-value-call-data widget-value-button-type
          widget-value-selected? widget-value-enabled? widget-value-help
          set!widget-value-name set!widget-value-contents set!widget-value-next
          set!widget-value-enabled! set!widget-value-button-type
          set!widget-value-selected! set!widget-value-key
          set!widget-value-call-data)
    ;; A colour *name* means what `term/tty-colors.el' says it means.
    (only (schemacs editor tty-colors) tty-color-standard-values))

  (export
   <pgtk-display>
   with-gtk-display
   pgtk-menu-bar-open
   ;; What opening a display does to the face machinery, so a test can do
   ;; it to a display with no window and then read what it draws - which
   ;; is how the *colour* of a face is checked without an eye on it.
   ;; `term.sld''s `initialize-display-faces!' is the same thing for a
   ;; terminal, and is private for the same reason: only opening a
   ;; display should call it.
   initialize-pgtk-faces!
   ;; The blocking read, exported for tests that drive it without a
   ;; window; nothing in the editor uses it by name.
   pgtk-read-event
   ;; The pointer's glyph filter, exported for the same reason: it is what
   ;; decides whether a motion report is a movement at all, and that is
   ;; worth a test of its own - see `note-mouse-movement'. Nothing in the
   ;; editor calls either by name.
   note-mouse-movement pgtk-mouse-moved
   ;; Call me back in MS milliseconds: how the timer module is told when
   ;; to come back once Gtk owns the loop.
   pgtk-arm-timer!
   ;; Running Gtk's own main loop, and leaving it, for the front end that
   ;; wants the loop to be Gtk's.
   ;; The loop, and the way out of it. `main-gtk' runs the one and hands
   ;; the other to the command loop as its `frame-quit-cont'.
   pgtk-main pgtk-main-quit
   pgtk-enqueue!
   ;; The queue itself, and the drain that dispatches it, for the test
   ;; that pins a queued key being delivered rather than stranded.
   pgtk-queue pgtk-drain-queue!
   ;; The current frame written to a PNG: how a windowed editor is
   ;; checked without a pair of eyes on it.
   pgtk-write-screenshot!
   ;; The window, so a test can push a synthetic key at it.
   pgtk-window
   ;; Opening one window and titling it, for the frame backend.
   pgtk-open-window pgtk-title-frame!
   ;; The selection read's own pieces, exported for tests - the same
   ;; reason `pgtk-read-event' and `note-mouse-movement' are. **The local
   ;; half needs no window and no Gtk**: it is the display's own record of
   ;; what it asserted, the converter table in `select.sld', and the C's
   ;; decode, so a test can set the record and read it back without a
   ;; clipboard anywhere. Nothing in the editor calls these by name.
   pgtk-selections
   pgtk-get-local-selection pgtk-clean-local-selection-data
   pgtk-get-selection-internal selection-data-to-lisp-data
   ;; What one character cell measures, in pixels, as `(WIDTH . HEIGHT)'.
   ;; The number is the font's, so a test that samples a cell's pixels has
   ;; to ask rather than assume it - the cell changes when the `default'
   ;; face's height does.
   pgtk-cell-size
   ;; The popup's tree, exported for the same reason: it is a pure
   ;; function of `menu_items' and the flags - the pane-is-a-submenu rule,
   ;; the title's two separators, and the `call_data' index the selection
   ;; walk-back compares against - and all three are worth a test that
   ;; needs no window. Nothing in the editor calls it by name.
   pgtk-popup-build-tree
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The typelib surface, privately
    ;;------------------------------------------------------------------


    ;; Before any generic above is called. Without these two, every
    ;; typelib generic misresolves and fails with "Too few \"in\"
    ;; arguments" - an error that reads like an arity bug and is not.
    (push-duplicate-handler! 'merge-generics)
    (push-duplicate-handler! 'shrug-equals)

    ;;----------------------------------------------------------------
    ;; The metrics of one character
    ;;
    ;; A cell is one pixel as far as the interface is concerned, but a
    ;; real font needs a real box to draw in, so the driver keeps the
    ;; cell's size in pixels and multiplies. The font is monospace, so
    ;; one advance serves every character.
    ;;
    ;; **The numbers are the font's, not this file's.** GNU Emacs's
    ;; `realize_default_face' (`xfaces.c:6062') opens the `default'
    ;; face's font and `x_new_font' (`xterm.c:27127') takes the frame's
    ;; measurements from the font that came back - `FRAME_COLUMN_WIDTH'
    ;; is the font's average width, `FRAME_LINE_HEIGHT' its height, and
    ;; the baseline sits at its ascent. That is what `pgtk-ensure-font!'
    ;; does below, and it is the whole of what
    ;; `global-text-scale-adjust' (`face-remap.sld') needs: the command
    ;; changes the `default' face's `:height', and the next redisplay
    ;; opens the font at the new size and measures it again.
    ;;
    ;; The values below are what a 15-pixel monospace font measures - the
    ;; numbers this file used to keep by hand - so that anything drawn
    ;; before the first realization still has a cell to draw in. They are
    ;; replaced before a frame is drawn.
    ;;
    ;; Two departures, and both are about *where* the metrics live:
    ;;
    ;;   * they are the process's, where Emacs keeps them on the frame
    ;;     (`FRAME_COLUMN_WIDTH'). Every display here is opened at the
    ;;     same resolution and the `default' face is global, so one set
    ;;     answers for all of them - until a frame wants a font of its
    ;;     own, which nothing here asks for yet;
    ;;   * the family is fixed to "monospace", where Emacs takes
    ;;     `:family' from the face. Opening a different family would also
    ;;     need `:foundry', `:weight' and `:slant' to be honoured, and
    ;;     those are font specs rather than measurements.
    ;;------------------------------------------------------------------

    (define *font-family* "monospace")
    (define *font-description* #f)
    ;; ^ The `PangoFontDescription' the layouts are set to, remade when
    ;; the size changes.
    (define *default-face-height* #f)
    ;; ^ The `:height' the current font was opened at, in tenths of a
    ;; point - the face attribute's own unit. This is what tells a
    ;; redisplay that the face has changed since the font was opened.
    (define *font-pixel-size* 15)
    (define *cell-width* 9)
    (define *cell-height* 18)
    (define *font-ascent* 13)
    ;; ^ The baseline's place in a cell, measured from the cell's top:
    ;; the font's ascent. 13 is what the `(- *cell-height* 5)' this file
    ;; used to compute at every baseline works out to for the 18-row
    ;; cell the constants above describe.

    (define (cell-x x) (* x *cell-width*))
    (define (cell-y y) (* y *cell-height*))

    (define (pgtk-cell-size)
      ;; The cell the text is drawn in, as `(WIDTH . HEIGHT)' in pixels -
      ;; the two numbers the redisplay's coordinates are multiplied by.
      ;; Emacs keeps them on the frame (`FRAME_COLUMN_WIDTH' and
      ;; `FRAME_LINE_HEIGHT'); they are the process's here, which the
      ;; section above explains.
      ;;--------------------------------------------------------------
      (cons *cell-width* *cell-height*))

    ;;----------------------------------------------------------------
    ;; Text, through Pango
    ;;----------------------------------------------------------------
    ;;
    ;; **Cairo's own `cairo-show-text' does no font fallback, and this
    ;; editor's text needs it.** It draws with the one face
    ;; `cairo-select-font-face' chose - "monospace" - and a character that
    ;; face has no glyph for comes out as the *missing glyph box*.
    ;; Measured: `\U00010400' (Deseret) draws as a box through the toy API
    ;; and as the glyph through Pango, on this machine, with the same
    ;; bytes arriving in both cases. A terminal is unaffected, which is why
    ;; this is the GTK front end only: the terminal asks its own font stack
    ;; for the glyph, and `ncurses' draws the character correctly.
    ;;
    ;; Pango lays a run out glyph by glyph, asking every font that can
    ;; answer, which is exactly the fallback that is missing - and it is
    ;; what every toolkit widget and Emacs's own GTK front end do.
    ;;
    ;; **It is reached by FFI rather than through the `PangoCairo'
    ;; typelib, and that is a real limitation rather than a preference.**
    ;; `pango_cairo_create_layout' takes a `cairo_t *'; the typelib's
    ;; binding of it is a guile-gi generic that accepts only a context gi
    ;; itself made, and the context here is guile-cairo's - a different
    ;; Goops class wrapping the same pointer. Handing it over fails with
    ;; "No applicable method", and so does the raw pointer from
    ;; `cairo-context->pointer'. So the functions are called directly,
    ;; through the same `dynamic-func' the clipboard FFI below uses, and
    ;; the pointer bridge takes the `cairo_t *' across.
    ;;
    ;; `pango_layout_new' needs no cairo at all - only a font map - so the
    ;; layout is made once from the font map's default context and reused
    ;; for every run, which is also what keeps this off the per-character
    ;; path.

    (define pango-foreign-fn
      (lambda (lib name ret args)
        (pointer->procedure ret (dynamic-func name (dynamic-link lib)) args)))

    (define pango-font-map-default
      (pango-foreign-fn "libpangocairo-1.0.so.0" "pango_cairo_font_map_get_default"
                        '* '()))
    (define pango-font-map-create-context
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_map_create_context"
                        '* (list '*)))
    (define pango-layout-new
      (pango-foreign-fn "libpango-1.0.so.0" "pango_layout_new" '* (list '*)))
    (define pango-layout-set-text
      (pango-foreign-fn "libpango-1.0.so.0" "pango_layout_set_text"
                        void (list '* '* int)))
    (define pango-layout-set-font-description
      (pango-foreign-fn "libpango-1.0.so.0" "pango_layout_set_font_description"
                        void (list '* '*)))
    (define pango-font-description-from-string
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_description_from_string"
                        '* (list '*)))
    (define pango-font-description-set-absolute-size
      (pango-foreign-fn "libpango-1.0.so.0"
                        "pango_font_description_set_absolute_size"
                        void (list '* double)))
    (define pango-layout-get-baseline
      (pango-foreign-fn "libpango-1.0.so.0" "pango_layout_get_baseline"
                        int (list '*)))
    (define pango-cairo-update-layout
      (pango-foreign-fn "libpangocairo-1.0.so.0" "pango_cairo_update_layout"
                        void (list '* '*)))
    (define pango-cairo-show-layout
      (pango-foreign-fn "libpangocairo-1.0.so.0" "pango_cairo_show_layout"
                        void (list '* '*)))

    ;; The font's own measurements, which are what a cell is made of.
    ;; `pango_font_get_metrics' is a Pango font's metrics, and the three
    ;; numbers below are the ones Emacs's `x_new_font' reads off a
    ;; `struct font'.
    (define pango-context-load-font
      (pango-foreign-fn "libpango-1.0.so.0" "pango_context_load_font"
                        '* (list '* '*)))
    (define pango-font-get-metrics
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_get_metrics"
                        '* (list '* '*)))
    (define pango-font-metrics-get-ascent
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_metrics_get_ascent"
                        int (list '*)))
    (define pango-font-metrics-get-descent
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_metrics_get_descent"
                        int (list '*)))
    (define pango-font-metrics-get-height
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_metrics_get_height"
                        int (list '*)))
    (define pango-font-metrics-get-approximate-char-width
      (pango-foreign-fn "libpango-1.0.so.0"
                        "pango_font_metrics_get_approximate_char_width"
                        int (list '*)))
    ;; The resolution Pango converts a point size at. Emacs does that
    ;; conversion itself with `POINT_TO_PIXEL' (`font.h:572') at
    ;; `FRAME_RES (f)'; here the number is the same one, asked of the font
    ;; map - and it is asked so that the conversion is the C's arithmetic
    ;; rather than a size handed to Pango in points and left to it.
    (define pango-font-map-get-resolution
      (pango-foreign-fn "libpangocairo-1.0.so.0"
                        "pango_cairo_font_map_get_resolution"
                        double (list '*)))
    ;; The three frees, because every size change opens a font and makes a
    ;; description: Emacs closes the old font when it realizes the face
    ;; again (`font_close_object'), and a `defcustom' the user can hold a
    ;; key down on must not leak one font per step.
    (define pango-font-description-free
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_description_free"
                        void (list '*)))
    (define pango-font-metrics-unref
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_metrics_unref"
                        void (list '*)))
    (define gobject-unref
      (pango-foreign-fn "libgobject-2.0.so.0" "g_object_unref"
                        void (list '*)))

    (define *pango-scale* 1024)
    ;; ^ `PANGO_SCALE': Pango counts in 1/1024 of a device unit, and
    ;; `pango_layout_get_baseline' answers in those.

    (define (pango-units->pixels units)
      ;; PANGO units as whole device pixels. `lround', which is what
      ;; `ftcrfont.c' rounds its own extents with.
      ;;--------------------------------------------------------------
      (inexact->exact (round (/ units *pango-scale*))))

    (define (point->pixel points dpi)
      ;; GNU Emacs's `POINT_TO_PIXEL' (`font.h:572'), which is where a
      ;; font spec's point size becomes the pixel size a font is opened
      ;; at: `(POINT * DPI / 72 + 0.5)', truncated.
      ;;--------------------------------------------------------------
      (inexact->exact (truncate (+ (/ (* points dpi) 72.0) 0.5))))

    (define (pixel->point pixels dpi)
      ;; GNU Emacs's `PIXEL_TO_POINT' (`font.h:579'): the point size
      ;; closest to a pixel size, which is how `set_lface_from_font'
      ;; gives the `default' face its `:height' when the face has none.
      ;; Multiply by ten at the call site for `:height''s tenths.
      ;;--------------------------------------------------------------
      (inexact->exact (truncate (+ (/ (* pixels 72.0) dpi) 0.5))))

    (define (pgtk-realize-font! pixels)
      ;; Open the font at PIXELS and take the cell's measurements from
      ;; it - Emacs's `realize_default_face' and `x_new_font' in one
      ;; place.
      ;;
      ;; The layout is given an *absolute* size in device units, which is
      ;; `pango_font_description_set_absolute_size''s own unit; see
      ;; `pgtk-ensure-layout!' for why it is not the description string.
      ;;--------------------------------------------------------------
      (let* ((context (pango-font-map-create-context (pango-font-map-default)))
             (fd (pango-font-description-from-string
                  (string->pointer *font-family*)))
             (was *font-description*))
        (pango-font-description-set-absolute-size fd (* pixels *pango-scale*))
        (let* ((font (pango-context-load-font context fd))
               (metrics (pango-font-get-metrics font (make-pointer 0))))
          (set! *font-pixel-size* pixels)
          (set! *font-ascent*
                (pango-units->pixels (pango-font-metrics-get-ascent metrics)))
          ;; **The line height is ascent plus descent**, which is the C's
          ;; own assignment: `FRAME_LINE_HEIGHT (f) = font_ascent +
          ;; font_descent' (`pgtkterm.c:897'), as `xterm.c:27144' and the
          ;; other window systems'. Pango's `get-height' is a different
          ;; number - it excludes part of the internal leading - and the
          ;; mismatch was a row a pixel taller than the cell: 20 against
          ;; 19 for this font, so the last text row of a window reached
          ;; into the mode line's row and its bottom half was painted
          ;; over - the truncated last line of the completions window.
          ;; `row-metrics' (`face-metrics' on this display) answers the
          ;; same ascent plus descent, which is why the two disagreed.
          (set! *cell-height*
                (max 1
                     (+ (pango-units->pixels
                         (pango-font-metrics-get-ascent metrics))
                        (pango-units->pixels
                         (pango-font-metrics-get-descent metrics)))))
          (set! *cell-width*
                (max 1 (pango-units->pixels
                        (pango-font-metrics-get-approximate-char-width metrics))))
          ;; The measurements are taken, so the font and its metrics can
          ;; go; the *description* is what the layouts are given, so it is
          ;; kept - and the one it replaces is freed, every layout that
          ;; was given it having been dropped just below.
          (pango-font-metrics-unref metrics)
          (gobject-unref font)
          (set! *font-description* fd)
          (when was (pango-font-description-free was))
          ;; **A layout keeps the description it was given**, so one made
          ;; at the old size goes on drawing at the old size however the
          ;; face changes. Every display's is dropped and remade - the
          ;; same thing Emacs's `fonts_changed' forces.
          (for-each (lambda (d) (set! (pgtk-layout d) #f)) (*pgtk-displays*)))))

    (define (pgtk-ensure-font!)
      ;; The frame's measurements, from the `default' face's `:height'.
      ;;
      ;; This is `realize_default_face' + `x_new_font': the face says how
      ;; big the text is, in tenths of a point; the pixel size is that at
      ;; the display's resolution; and the cell is whatever the font that
      ;; comes back measures. A face with no height - a fresh one, or one
      ;; `face-spec-recalc' has just reset - takes the height of the font
      ;; already open, which is `set_lface_from_font`'s rule
      ;; (`xfaces.c:2221') and what keeps a reset from moving the text.
      ;;
      ;; Nothing is done when the face has not changed, so this costs a
      ;; face read per call - which is why it can be asked on the
      ;; redisplay's own path (`screen-size').
      ;;--------------------------------------------------------------
      (let* ((dpi (pango-font-map-get-resolution (pango-font-map-default)))
             ;; **The *realized* default face, not its own `:height'.**
             ;; `realize_default_face' merges the face through the
             ;; buffer's `face-remapping-alist' before it opens a font,
             ;; which is what makes `text-scale-mode' - a relative
             ;; `:height' in that alist - change the size of the text.
             ;; The raw attribute answers the global face's height and
             ;; would miss every buffer-local scaling.
             ;;
             ;; **A departure, and it is the renderer's**: Emacs gives
             ;; every glyph row its own ascent and descent, so one
             ;; buffer's scaling makes that window's lines taller and
             ;; leaves the others alone. This renderer has *one* grid per
             ;; display - one font, one row height - so the face that is
             ;; merged here is the one the whole frame is drawn at. The
             ;; buffer current at redisplay is the one being edited, so
             ;; scaling a buffer scales the frame, and switching to an
             ;; unscaled buffer scales it back. Closing that needs
             ;; per-window row heights (`row->ascent'/'row->height' in
             ;; `dispextern.h'), which is a renderer of its own.
             ;; **The buffer is the *selected window's*, not
             ;; `(current-buffer)`.** A minibuffer prompt makes the echo
             ;; area current, so reading the current buffer's remapping
             ;; dropped a scaled frame back to the unscaled font for the
             ;; whole prompt - `C-x C-f` in a zoomed buffer made the
             ;; entire screen jump to the normal size, which is what Chris
             ;; saw. The window you are editing is the one that is scaled;
             ;; a prompt is not a window.
             (height (let ((w (let ((frame (*current-frame*)))
                               (and frame
                                    (or (minibuffer-selected-window)
                                        (frame-selected-window frame))))))
                       (if (and w (window-buffer w))
                           (with-current-buffer
                               (window-buffer w)
                             (attribute-value (merge-face-ref
                                               'default
                                               (face-attributes-empty))
                                              ':height))
                           (attribute-value (merge-face-ref
                                             'default
                                             (face-attributes-empty))
                                            ':height)))))
        ;; `unspecified' and nil are both "the face does not say": only a
        ;; number can be a height. A face with none takes the height of
        ;; the font already open, which is what `set_lface_from_font'
        ;; does for a face whose height is unspecified.
        ;;
        ;; **The merge can answer a *relative* height** - a flonum is a
        ;; scale factor, which is what `text-scale-mode` remaps with -
        ;; and `merge_face_heights` (`xfaces.c:2253') resolves it against
        ;; an absolute one: "relative X absolute => absolute". The
        ;; absolute here is the face's own `:height`, which is the last
        ;; size realized. A relative height is therefore a scale of the
        ;; *unscaled* face, not of the last scaled one - otherwise two
        ;; steps would compound into four.
        (let ((own (face-attribute 'default ':height)))
          (when (not (number? own))
            (set! own (pixel->point (* 10 *font-pixel-size*) dpi))
            (set-face-attribute 'default #f ':height own))
          (when (not (number? height))
            (set! height (pixel->point (* 10 *font-pixel-size*) dpi)))
          (when (inexact? height)
            (set! height (inexact->exact (round (* height own)))))
          (unless (eqv? height *default-face-height*)
            (let ((old-cell-width *cell-width*)
                  (old-cell-height *cell-height*))
            (pgtk-realize-font! (point->pixel (/ height 10.0) dpi))
            ;; **`x_new_font`'s last act** (`xterm.c:27167'): ask for the
            ;; frame to keep its rows and columns at the new font, unless
            ;; something has inhibited an implied resize. The row and
            ;; column count is the frame's *own* - `FRAME_COLS (f)' and
            ;; `FRAME_LINES (f)' at the moment the font changed.
            ;;
            ;; **The count is multiplied back with the OLD cell**,
            ;; captured just above: the pixels it asks for are the ones
            ;; those rows used to take, and `adjust_frame_size` with
            ;; inhibit 3 then either leaves them alone (`frame-inhibit-
            ;; implied-resize`) or grows them to fit the new font. Using
            ;; the new cell here would ask for exactly the size the frame
            ;; already has and the resize would never happen.
            (set! *default-face-height* height)
            (for-each
             (lambda (frame)
               (let ((d (frame-output frame)))
                 (when d
                   ;; `adjust_frame_size`'s `Qfont` case: inhibit 3, which
                   ;; resizes only if `frame_inhibit_resize` allows it.
                   (adjust-frame-size! frame
                                       (* (frame-width frame) old-cell-width)
                                       (* (frame-height frame) old-cell-height)
                                       3 #f 'font))))
             (*frame-list*)))))))

    (define (pgtk-ensure-layout! d)
      ;; D's text layout, made once. It belongs to a font map and not to a
      ;; cairo context, so a resize - which remakes the surface and the
      ;; context - does not invalidate it. A *font* size change does:
      ;; `pgtk-realize-font!' drops the layout of every open display, and
      ;; this makes the next one with the description that replaced it.
      ;;--------------------------------------------------------------
      (or (pgtk-layout d)
          (let ((layout (pango-layout-new
                         (pango-font-map-create-context (pango-font-map-default)))))
            ;; The description is made by `pgtk-realize-font!', which sets
            ;; its size in *device* units. That is deliberate: Pango reads
            ;; a size in a description string as *points*, which at this
            ;; resolution is a quarter again as large - `monospace 15' drew
            ;; 20-pixel glyphs where `cairo-set-font-size cr 15' drew 15 -
            ;; and `set_absolute_size' is the device-unit spelling.
            (unless *font-description* (pgtk-ensure-font!))
            (pango-layout-set-font-description layout *font-description*)
            (set! (pgtk-layout d) layout)
            layout)))

    (define (pgtk-show-text! d text x baseline)
      ;; TEXT with its left edge at X and its *baseline* at BASELINE.
      ;;
      ;; Pango places a layout by its top-left corner, so the move
      ;; subtracts the layout's own baseline - which is what makes this a
      ;; drop-in for `cairo-show-text', whose point is the baseline.
      ;;--------------------------------------------------------------
      (let* ((cr (pgtk-cr d))
             (cairo-t (cairo-context->pointer cr))
             (layout (pgtk-ensure-layout! d)))
        (pango-layout-set-text layout (string->pointer text "UTF-8") -1)
        (pango-cairo-update-layout cairo-t layout)
        (cairo-move-to cr x (- baseline (/ (pango-layout-get-baseline layout)
                                           *pango-scale*)))
        (pango-cairo-show-layout cairo-t layout)))

    ;;----------------------------------------------------------------
    ;; Faces
    ;;
    ;; `realize-face' answers a token the redisplay treats as opaque -
    ;; except that `xdisp.sld''s `line-end-fill-attribute' compares it
    ;; with `=', so it must be an INTEGER and 0 must mean "no face".
    ;; Faces are therefore interned to ids here, and the id's
    ;; attributes are kept beside it.
    ;;------------------------------------------------------------------

    (define (%colour-name name)
      ;; A colour name as the standard table spells it: lower case, with
      ;; no spaces. X's own name matching is case-insensitive and ignores
      ;; spaces - "DarkOrange", "darkorange" and "dark orange" all name
      ;; one colour - and a GUI frame gets that from the X server, since
      ;; `xfaces.c' hands the name to `XParseColor'. There is no X here,
      ;; so the normalisation is done by hand.
      ;;--------------------------------------------------------------
      (list->string
       (filter (lambda (c) (not (char=? c #\space)))
               (string->list (string-downcase name)))))

    (define (colour->rgb value)
      ;; A face colour as three cairo components, or #f when the face
      ;; does not name one. VALUE is a pixel integer, a colour name, or
      ;; the unspecified marker.
      ;;
      ;; A name is looked up in `term/tty-colors.el''s table - the same
      ;; table a terminal uses - rather than parsed here, because that is
      ;; where this editor already says what a colour name means.
      ;; `tty-color-standard-values' and not `tty-color-values': the
      ;; latter gives the *terminal's* rendering of a colour, which maps
      ;; `gray' to the palette's white.
      ;;--------------------------------------------------------------
      (cond
       ((integer? value)
        (list (/ (logand (ash value -16) 255) 255.0)
              (/ (logand (ash value -8) 255) 255.0)
              (/ (logand value 255) 255.0)))
       ((string? value)
        ;; The name as written, then the name normalised - see
        ;; `%colour-name'. Without the second try EVERY face realized to
        ;; the plain token on GTK and none of them drew in colour: the
        ;; standard specs' `(min-colors 88)' and `(min-colors 16)'
        ;; branches name "Firebrick", "chocolate1", "DarkOrange" and
        ;; "dark cyan", while the table's entries are "firebrick",
        ;; "chocolate1", "darkorange" and "darkcyan". A terminal never
        ;; met the difference, because its 8-colour branch names
        ;; "yellow", "red" and "magenta", which are spelled the same
        ;; either way.
        (let ((rgb (or (tty-color-standard-values value)
                       (tty-color-standard-values (%colour-name value)))))
          (and (list? rgb)
               (= 3 (length rgb))
               (map (lambda (c) (/ c 65535.0)) rgb))))
       (else #f)))

    (define (realize-face-token attrs)
      ;; ATTRS interned to an integer id, 0 for the plain face.
      ;;
      ;; `:inverse-video' is what a terminal draws the mode line and the
      ;; search match with - there is no colour on a monochrome terminal,
      ;; only swapped ones - so it is honoured by swapping the pair here.
      ;; With neither colour set the pair is black on white, and
      ;; inverting that gives white on black.
      ;;--------------------------------------------------------------
      (if (not attrs)
          0
          (let* ((foreground (colour->rgb (attribute-value attrs ':foreground)))
                 (background (colour->rgb (attribute-value attrs ':background)))
                 (inverse (eq? #t (attribute-value attrs ':inverse-video)))
                 (bold (eq? #t (attribute-value attrs ':bold)))
                 (underline (eq? #t (attribute-value attrs ':underline)))
                 (fg (if inverse (or background (list 1.0 1.0 1.0))
                         (or foreground (list 0.0 0.0 0.0))))
                 (bg (if inverse (or foreground (list 0.0 0.0 0.0))
                         background))
                 (key (list fg bg bold underline)))
            (if (and (equal? fg (list 0.0 0.0 0.0))
                     (not bg) (not bold) (not underline))
                0
                (let ((found (assoc key (*face-table*))))
                  (if found
                      (cdr found)
                      (let ((id (+ 1 (length (*face-table*)))))
                        (*face-table* (append (*face-table*)
                                              (list (cons key id))))
                        id)))))))

    (define *face-table* (make-parameter '()))
    ;; ^ `((KEY . ID) ...)`, id 0 meaning the plain face.

    (define (face-entry token)
      ;; The interned attributes for TOKEN, or #f. TOKEN may be #f or 0,
      ;; which the redisplay uses to mean "the display's own appearance"
      ;; - it is not an id, so there is no entry for it.
      ;;--------------------------------------------------------------
      (and (integer? token)
           (let loop ((lst (*face-table*)))
             (cond ((null? lst) #f)
                   ((= (cdr (car lst)) token) (car lst))
                   (else (loop (cdr lst)))))))

    (define (face-token-part token n)
      ;; Component N of TOKEN's `(FOREGROUND BACKGROUND BOLD UNDERLINE)'.
      ;; The table holds `(KEY . ID)`, so the key is taken first.
      ;;--------------------------------------------------------------
      (let ((found (face-entry token)))
        (and found (list-ref (car found) n))))

    (define (face-token-foreground token) (face-token-part token 0))
    (define (face-token-background token) (face-token-part token 1))

    ;;----------------------------------------------------------------
    ;; Keys
    ;;
    ;; The rule is Emacs's `xg_widget_key_press_event_cb'
    ;; (gtkutil.c:6520): a keysym that `keyval_to_unicode' maps to a
    ;; character is a character event, and everything else - the cursor
    ;; keys, function keys, the keypad - is an event whose code is the
    ;; keysym, which `key-event->key' then names.
    ;;
    ;; The modifiers are `pgtk_gtk_to_emacs_modifiers' (pgtkterm.c:5157):
    ;; note that Mod1 is META, not alt.
    ;;------------------------------------------------------------------

    (define (modifier-bits state)
      ;; The Gdk modifier STATE as the C's modifier *bits* - GNU Emacs's
      ;; `pgtk_gtk_to_emacs_modifiers' (pgtkterm.c:5157), with `x_x_to_emacs_modifiers'
      ;; deciding which Gdk mask is which. The masks are Gdk's: SHIFT 1,
      ;; CONTROL 4, MOD1 8, SUPER 1<<26, HYPER 1<<27, META 1<<28. MOD1
      ;; means META here, as Emacs has it - not Alt; Gdk has no Alt.
      ;;
      ;; This is the whole of what the backend is for: it hands the rest
      ;; of Emacs a bitmask, and `make_lispy_event' (keyboard.c:3783)
      ;; turns that and the keysym into one event. There is no list of
      ;; modifier *symbols* in the C's path, and no "keymap path".
      ;;--------------------------------------------------------------
      (let ((bits (if (integer? state) state 0)))
        (define (set? mask) (not (= 0 (logand bits mask))))
        (logior (if (set? 1) char-shift 0)
                (if (set? 4) char-ctl 0)
                (if (or (set? (ash 1 28)) (set? 8)) char-meta 0)
                (if (set? (ash 1 26)) char-super 0)
                (if (set? (ash 1 27)) char-hyper 0))))

    (define (keysym-event state keysym)
      ;; The *key event* for one keysym and Gdk modifier state - GNU
      ;; Emacs's `make_lispy_event' for a window system, over what
      ;; `xg_widget_key_press_event_cb' (gtkutil.c) hands over.
      ;;
      ;; `keyboard.c':3783 is the arithmetic, and it is three steps: the
      ;; keysym is the event's character; a Control modifier *folds* that
      ;; character with `make_ctrl_char' - so `C-x' is 24, the event
      ;; `(kbd "C-x")' answers, and not a `ctrl' symbol beside a letter;
      ;; and meta, alt, hyper and super become the matching bits on the
      ;; event. Shift is not among them: the keysym carries the case.
      ;;
      ;; A key that is not a character - an arrow, a function key - is the
      ;; *symbol* Emacs reads there, with the modifiers in its name:
      ;; `M-up', `C-left'. That is `apply_modifiers', the C's own.
      ;;--------------------------------------------------------------
      (let* ((bits (modifier-bits state))
             ;; What `make_lispy_event' ORs in: everything but Control
             ;; (folded into the character below) and Shift (in the
             ;; keysym).
             (extra (logand bits (lognot (logior char-ctl char-shift)))))
        (define (character code)
          (if (zero? (logand bits char-ctl))
              (logior extra code)
              (logior extra (make-ctrl-char code))))
        (cond
         ;; "First deal with keysyms which have defined translations to
         ;; characters" (gtkutil.c): ASCII.
         ((and (>= keysym 32) (< keysym 128)) (character keysym))
         ;; keysyms directly mapped to Unicode characters
         ((and (>= keysym #x01000000) (<= keysym #x0110FFFF))
          (character (logand keysym #xFFFFFF)))
         (else
          ;; A key that is not a character: a name this editor's keymaps
          ;; have for the keysym, with the modifiers on it.
          (let ((name (function-key-name keysym)))
            (cond
             ;; A key that is not a character is the *symbol* Emacs reads
             ;; there, with the modifiers in its name - `M-up', `C-left'.
             ;; The names are `lispy_function_keys'' (`keyboard.c':5513'),
             ;; which is where `escape', `return' and the arrows come
             ;; from; what those then *mean* - Return is 13, Escape is 27
             ;; - is `function-key-map''s, one translation further on,
             ;; and not this backend's business.
             (name (apply-modifiers bits (string->symbol name)))
             (else
              (let ((unicode (keyval-to-unicode keysym)))
                (and unicode (> unicode 0) (character unicode))))))))))

    ;;----------------------------------------------------------------
    ;; The display
    ;;------------------------------------------------------------------

    (define-class <pgtk-display> (<display>)
      (window  #:init-value #f #:accessor pgtk-window)
      ;; The drawing area: the widget Gtk asks for a repaint, and the
      ;; widget whose allocation is the size the display draws at.
      (area    #:init-value #f #:accessor pgtk-area)
      ;; The box the window holds, with the menu bar above the drawing
      ;; area - GNU Emacs's `FRAME_GTK_OUTER_WIDGET` (`wtop') holding the
      ;; edit widget and the menu bar (`gtkutil.c:1670').
      (vbox    #:init-value #f #:accessor pgtk-vbox)
      ;; The menu bar and what it is built from, which is Emacs's
      ;; `f->output_data.pgtk->menubar_widget' beside
      ;; `f->menu_bar_vector' and `f->menu_bar_items_used':
      ;; `menubar-held' is every proxy the current bar was built from
      ;; (see `pgtk-hold-widget!`), and `menubar-vector'/`menubar-used'
      ;; are the snapshot a click's `call_data` is an index into.
      (menubar       #:init-value #f #:accessor pgtk-menubar)
      (menubar-held  #:init-value '() #:accessor pgtk-menubar-held)
      (menubar-vector #:init-value #f #:accessor pgtk-menubar-vector)
      (menubar-used  #:init-value 0 #:accessor pgtk-menubar-used)
      (menubar-height #:init-value 0 #:accessor pgtk-menubar-height)
      ;; Whether the bar is currently taken down. An empty bar is hidden
      ;; once and then left alone; see `pgtk-set-frame-menubar`.
      (menubar-hidden #:init-value #f #:accessor pgtk-menubar-hidden?)
      ;; **The bar's theme**: the CSS provider that colours it and its
      ;; submenus, and the `(FOREGROUND . BACKGROUND)' it was last given,
      ;; so it is re-loaded only when the mode line's colours change. See
      ;; `pgtk-theme-menubar!`.
      (menubar-css   #:init-value #f #:accessor pgtk-menubar-css)
      (menubar-theme #:init-value #f #:accessor pgtk-menubar-theme)
      (surface #:init-value #f #:accessor pgtk-surface)
      ;; ^ The image surface the frame is drawn into, and the size it was
      ;; made at. `ensure-surface!' must not remake it while it is already
      ;; the right shape: Emacs's equivalent is the frame's X window,
      ;; which is *resized* and never recreated.
      (surface-size #:init-value #f #:accessor pgtk-surface-size)
      (cr      #:init-value #f #:accessor pgtk-cr)
      (layout  #:init-value #f #:accessor pgtk-layout)
      ;; ^ The Pango layout the text is drawn through. It belongs to a
      ;; font map rather than to the surface, so it outlives a resize.
      ;; The grid, in character cells: what the redisplay thinks the
      ;; display is, and what `screen-size' answers.
      (columns #:init-value 80 #:accessor pgtk-columns)
      (rows    #:init-value 24 #:accessor pgtk-rows)
      ;; Where the last button press was, and the *position list* that
      ;; press was, both kept because a release afterwards is a different
      ;; event - `drag-mouse-1' - which carries the press's position
      ;; beside the release's. Emacs keeps the same two things in
      ;; `f->mouse_moved' and in the drag's start event.
      (press-cell #:init-value #f #:accessor pgtk-press-cell)
      (press-posn #:init-value #f #:accessor pgtk-press-posn)
      ;; Input events the signal handler has collected.
      (queue   #:init-value '() #:accessor pgtk-queue)
      ;; The last allocation a redraw was asked for, so an unchanged one
      ;; does not ask again - which it otherwise does on every frame,
      ;; and redraws forever.
      (last-allocation #:init-value #f #:accessor pgtk-last-allocation)
      ;; The selections this display has asserted, as
      ;; `((SELECTION VALUE TIMESTAMP FRAME) ...)' - the C's
      ;; `selection_data' list. This is `pgtkselect.c''s
      ;; `LOCAL_SELECTION' (`:116') - the process's own bookkeeping of
      ;; what it owns, which is what `pgtk-selection-owner-p' answers
      ;; from, Gtk recording no owner for a plain `set_text', and what
      ;; `pgtk-get-local-selection' reads a value and a timestamp out of.
      (selections #:init-value '() #:accessor pgtk-selections)
      ;; The widget's allocation in PIXELS, as `size-allocate' last
      ;; reported it - GNU Emacs's `FRAME_PIXEL_WIDTH' and
      ;; `FRAME_PIXEL_HEIGHT'. Those are fields of `struct frame' which
      ;; its GTK backend refreshes from the configure event
      ;; (`pgtk_configure_event' into `x_set_window_size'), and redisplay
      ;; reads the field: it never asks the toolkit how big the window is.
      ;;
      ;; This slot was `drawn-size', set by nobody, guarding a comparison
      ;; in `pgtk-read-event' that therefore never fired. It is the same
      ;; question, asked usefully.
      (allocated-size #:init-value #f #:accessor pgtk-allocated-size)
      ;; Whether the pointer has left the glyph it was last reported on and
      ;; nothing has been made of it yet: GNU Emacs's `f->mouse_moved',
      ;; which its Gtk backend sets from the motion signal
      ;; (`note_mouse_movement') and its reader consumes to *make* a
      ;; `mouse-movement' event (`some_mouse_moved', `keyboard.c:1292').
      ;;
      ;; **A flag and not a queued event, and that is the whole mechanism.**
      ;; Gtk reports the pointer many times a second; one queued event per
      ;; report means one command per report, and a drag past the edge of a
      ;; window then scrolls a step per report instead of continuously. See
      ;; `note-mouse-movement'.
      ;;
      ;; Emacs keeps it on the *frame* and `some_mouse_moved' walks the
      ;; frames; a display here belongs to one frame, so it lives here and
      ;; the walk is over the displays.
      (mouse-moved #:init-value #f #:accessor pgtk-mouse-moved)
      ;; The glyph the pointer was last reported on, as `remember-mouse-glyph'
      ;; answers it - GNU Emacs's `dpyinfo->last_mouse_glyph' and
      ;; `last_mouse_glyph_frame'. #f before the first report.
      (last-mouse-glyph #:init-value #f #:accessor pgtk-last-mouse-glyph))

    (define (pgtk-frame-for d)
      ;; The frame drawn on display D, or #f if none is. A window knows its
      ;; display and a frame knows its display (`frame-output'), so this is
      ;; the walk from one to the other - which is what tells an input
      ;; event which frame it belongs to.
      ;;--------------------------------------------------------------
      (let loop ((l (*frame-list*)))
        (cond ((null? l) #f)
              ((eq? (frame-output (car l)) d) (car l))
              (else (loop (cdr l))))))

    (define (%pgtk-next-queued d)
      ;; The first queued item across every open window, as
      ;; `(DISPLAY . ITEM)', or #f. D is looked at first so that *its*
      ;; deadline sentinel is honoured; a sentinel belonging to another
      ;; display is skipped, since it is that read's business and not this
      ;; one's.
      ;;--------------------------------------------------------------
      (let loop ((ds (cons d (*pgtk-displays*))))
        (cond
         ((null? ds) #f)
         (else
          (let* ((cur (car ds))
                 (q (pgtk-queue cur)))
            (cond
             ((not (pair? q)) (loop (cdr ds)))
             ((and (eq? (car q) 'pgtk-deadline) (not (eq? cur d)))
              (loop (cdr ds)))
             (else (cons cur (car q)))))))))

    (define *pgtk-loop* #f)
    ;; ^ The loop the *outermost* wait runs in, made once - a `GMainLoop'
    ;; may be run again after it has been quit, so the common case does
    ;; not need a new one each time. See `pgtk-wait!'.

    (define *pgtk-running* '())
    ;; ^ The loops a wait is inside right now, innermost first, so that a
    ;; signal handler arriving while a *command* is running does not quit
    ;; a loop that is not running - GLib treats that as an error.
    ;;
    ;; **A list and not a flag, because a wait can nest.** GLib asserts
    ;; that `g_main_loop_run' is not called on a loop that is already
    ;; running, so a wait entered from inside another - which is what a
    ;; reentrant read is, and what the command loop will be once Gtk owns
    ;; it - needs a loop of its own. Nothing nests today: the
    ;; minibuffer's read happens during dispatch, after the outer read has
    ;; returned. It is built for nesting now so that it does not have to
    ;; be rebuilt when that changes.

    (define *timer-source* #f)
    ;; ^ The one-shot Gtk source armed for the next timer, or #f when none
    ;; is. See `pgtk-arm-timer!'.

    (define (pgtk-arm-timer! ms thunk)
      ;; Call THUNK in MS milliseconds, from Gtk's main loop, or cancel an
      ;; arrangement already made when MS is #f.
      ;;
      ;; This is how the timer module is told when to come back
      ;; (`(schemacs editor timer)''s `*timer-wake*') once Gtk owns the
      ;; main loop - with no read to arm there is otherwise nothing to
      ;; make an idle editor fire a timer.
      ;;
      ;; One at a time on purpose: the timer module reschedules whenever
      ;; the lists change, and a source per change would leave a trail of
      ;; them. The callback clears the slot before running THUNK, because
      ;; THUNK almost always reschedules.
      ;;--------------------------------------------------------------
      (when *timer-source*
        (source-remove? *timer-source*)
        (set! *timer-source* #f))
      (when ms
        (set! *timer-source*
              (timeout-add 0 (max 1 ms)
                           (lambda (data)
                             (set! *timer-source* #f)
                             (thunk)
                             ;; one shot: Gtk drops the source
                             #f)
                           #f))))

    (define (pgtk-main-loop)
      ;; The loop the outermost wait runs in, made on first use. A
      ;; windowless display never asks for one.
      ;;--------------------------------------------------------------
      (or *pgtk-loop*
          (let ((ml (main-loop:new #f #f)))
            (set! *pgtk-loop* ml)
            ml)))

    (define *pgtk-skip* (list 'skip))
    ;; ^ What a read answers for an item that is not an event: a modifier
    ;; key press, which Gtk delivers and a terminal consumes. A unique
    ;; object so that no real answer can be mistaken for it.

    (define (pgtk-enqueue! d ev)
      ;; Deliver one input event from a signal handler to the editor.
      ;;
      ;; **This is the one place every event goes through** - a key, a
      ;; resize, a focus change, a map, a deadline - and it is also the
      ;; one place that has to decide *how* to deliver it, because there
      ;; are two ways and which one applies changes during the editor's
      ;; life:
      ;;
      ;; - **Gtk owns the loop and the editor is waiting for input**: put
      ;;   the event on the queue and drain the queue, which runs the
      ;;   waiting commands and returns, so control goes back to
      ;;   `gtk_main`. That is what makes the loop absorbing input Gtk's
      ;;   own.
      ;; - **A read is outstanding** - a minibuffer prompt, an isearch -
      ;;   or a command is still running: queue it and wake the read. A
      ;;   nested read is waiting for a key of its own and is the only
      ;;   thing that can consume it.
      ;;
      ;; Doing the decision here rather than in the seven signal handlers
      ;; means they need no policy of their own: each says what happened
      ;; and this says where it goes.
      ;;--------------------------------------------------------------
      (let ((dispatch (*dispatch-event*)))
        ;; **Not while a redisplay is running.** The drawing asks Gtk to
        ;; lay out, the layout fires `size-allocate`, and this would
        ;; dispatch the resize event - whose handler is `ignore` and whose
        ;; only effect is another redisplay - inside the redisplay that
        ;; caused it. The redisplay in progress reads the size it just
        ;; observed, so queueing the event loses nothing.
        (if (and dispatch
                 (command-loop-ready?)
                 (null? *pgtk-running*)
                 (not (*redisplay-in-progress*)))
            ;; **The event joins the queue and the queue is drained**, not
            ;; handed over on its own. A key that arrived while a command
            ;; or a redisplay was running was queued by the branch below,
            ;; and *nothing reads the queue at the outermost level* - the
            ;; front end's command loop has no read of its own - so it
            ;; would sit there until the next prompt or search consumed
            ;; it, late and out of order. That is why the `C-s` after a
            ;; search could do nothing: it arrived while the exit
            ;; redisplay was running, was queued, and was never
            ;; dispatched. Draining dispatches the oldest event first, as
            ;; Emacs's command loop reads `kbd_buffer` in order.
            (begin
              (set! (pgtk-queue d) (append (pgtk-queue d) (list ev)))
              (pgtk-drain-queue! d dispatch))
            (begin
              (set! (pgtk-queue d) (append (pgtk-queue d) (list ev)))
              ;; **Nothing may be left with no reader.** A key queued
              ;; here - a command running, or a redisplay - is collected
              ;; by one of two readers: the read that waits for the next
              ;; key (a prompt, an isearch), or the redisplay itself,
              ;; through `*after-redisplay-hook*` (see the drain below).
              ;; The cursor-blink timer repaints straight from a Gtk
              ;; source with no read anywhere, and a key pressed during
              ;; that repaint was queued and stranded until the next key
              ;; - the "first C-s after a search did nothing" case - so
              ;; the redisplay is the reader for it.
              (pgtk-wake!)))))

    (define *draining* #f)
    ;; ^ Whether `pgtk-drain-queue!` is already dispatching. The
    ;; after-redisplay hook can fire inside a dispatch (a command's own
    ;; redisplay), and dispatching a command from inside another
    ;; command's redisplay is what `*redisplay-in-progress*` exists to
    ;; stop; the outer drain loop picks up whatever the inner one would
    ;; have.

    (define (pgtk-drain-queue! d dispatch)
      ;; Dispatch the events waiting in the queues, oldest first.
      ;;
      ;; **Every event goes through the two decodes a read uses**:
      ;; `pgtk-item->event' is this display's own form of the event and
      ;; `key-event->key' is the *key event* the command loop speaks - the
      ;; pair `read-key-event` calls, and the reason it exists. Handing
      ;; `dispatch-key` the first without the second is what sent `-1` -
      ;; the resize code - to the keymap as if it were a key, which is not
      ;; a key and has no binding.
      ;;
      ;; **The event's own value goes with the key here too.** This path
      ;; never goes through `read-key-event`, so a mouse click handled here
      ;; arrived at the command as `(down-mouse-1 (FRAME))' - the shape for
      ;; a frame event - and `posn-set-point' then selected the window the
      ;; editor was already in: a click that did nothing at all, with no
      ;; error, because selecting the window you are in is not an error.
      ;; The read path and `dispatch-input-event' both set this; this one
      ;; did not.
      ;;
      ;; The loop stops when the queues are empty, or when a command has
      ;; left a read outstanding (`*pgtk-running*` non-empty): that read
      ;; is the thing waiting for the remaining events, and it is where
      ;; Emacs's `read_char` would be. `*pgtk-skip*` - a modifier key
      ;; press - and the deadline sentinel (`#f`) are dropped, as the read
      ;; drops them.
      ;;--------------------------------------------------------------
      (unless *draining*
        (set! *draining* #t)
        (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let loop ()
             ;; **A key put back on `*unread-command-events*` first.**
             ;; Emacs consumes that list at the start of every
             ;; `read_char`; this front end's top level does not read, so
             ;; a key the command loop handed back - an isearch's
             ;; `isearch-other-meta-char`, which exits and re-executes the
             ;; key - was never taken up at all and sat until the next
             ;; prompt. It is an *event* already, so it goes straight to
             ;; the dispatch.
             (let ((unread (*unread-command-events*)))
               (cond
                ;; **`pair?`, not the list itself**: an empty list is
                ;; true in Scheme, and `(car '())` is the error that
                ;; made the Gtk front end answer nothing at all.
                ((pair? unread)
                 (*unread-command-events* (cdr unread))
                 (let ((ev (car unread)))
                   (*last-read-event* ev)
                   (dispatch ev))
                 (when (and (command-loop-ready?) (null? *pgtk-running*))
                   (loop)))
                (else
                 (let ((found (%pgtk-next-queued d)))
                   (when found
                     (let ((raw (pgtk-take-queued d found)))
                       (unless (eq? raw *pgtk-skip*)
                         (*last-read-event* raw)
                         (let ((event (and raw (key-event->key d raw))))
                           (when event (dispatch event)))))
                     (when (and (command-loop-ready?) (null? *pgtk-running*))
                       (loop)))))))))
         (lambda () (set! *draining* #f)))))

    (define (pgtk-wake!)
      ;; Wake the read that is waiting, if one is. "A wake with nobody
      ;; waiting is not an error and does nothing", which is what makes it
      ;; safe to call from a signal handler that runs while a command is
      ;; executing.
      ;;
      ;; **It is its own function because two things need it**: the queue
      ;; path, and a pointer movement, which wakes a read the moment it
      ;; happens - the read is what makes the event out of it
      ;; (`pgtk-mouse-movement-event').
      ;;--------------------------------------------------------------
      (when (pair? *pgtk-running*)
        (main-loop:quit (car *pgtk-running*))))

    (define (note-mouse-movement d x y)
      ;; GNU Emacs's `note_mouse_movement' (`pgtkterm.c:5892'), for one
      ;; motion report at frame cell X, Y:
      ;;
      ;;   "We have received a mouse movement event ... If the mouse is
      ;;    over a different glyph than it was last time, tell the
      ;;    mainstream emacs code by setting mouse_moved. If not, ask for
      ;;    another motion event, so we can check again the next time it
      ;;    moves."
      ;;
      ;; **This filter is what makes a drag that has left the window keep
      ;; scrolling.** The scroll loop runs `mouse-scroll-delay' apart
      ;; "until new input arrives" (`mouse-scroll-subr'), so *any* event
      ;; ends it - and a mouse held past the edge of a window goes on
      ;; reporting its position many times a second. Emacs turns all of
      ;; those into no event at all, because they are inside the glyph the
      ;; pointer was already on; the loop therefore goes on scrolling, a
      ;; step every quarter second, which is the "scrolls half a page at a
      ;; time" a drag past the edge looks like. Queueing an event per
      ;; report - which is what this did - ends the loop on every one of
      ;; them, and the drag then scrolls a step per report and stops the
      ;; moment the pointer stops reporting.
      ;;
      ;; Emacs sets the flag for a motion whose window is not the frame's
      ;; edit widget without comparing glyphs (`pgtkterm.c:5908'). A Gtk
      ;; motion signal is delivered to the widget it belongs to, so there
      ;; is no such event here; the comparison below is the whole of it.
      ;;--------------------------------------------------------------
      (let ((glyph (remember-mouse-glyph (or (pgtk-frame-for d) (*current-frame*))
                                         x y)))
        (if (equal? glyph (pgtk-last-mouse-glyph d))
            #f
            (begin
              (set! (pgtk-last-mouse-glyph d) glyph)
              ;; **One marker per movement, not one per report.** The flag
              ;; is Emacs's `f->mouse_moved' doing its job: it says "the
              ;; reader has not been told about this movement yet", so the
              ;; reports that arrive before it is told are already covered
              ;; and make no further marker. It is cleared where the event
              ;; is finally made (`pgtk-mouse-movement-event'), which is
              ;; Emacs's `pgtk_mouse_position' clearing it.
              (unless (pgtk-mouse-moved d)
                (set! (pgtk-mouse-moved d) #t)
                ;; **The marker goes through `pgtk-enqueue!', and that is
                ;; this front end's departure from Emacs.** Emacs's reader
                ;; *polls* `some_mouse_moved' (`keyboard.c:4525') each time
                ;; it wants an event; here Gtk's loop delivers every event
                ;; instead - an idle editor has no read outstanding at all
                ;; - so the movement is *posted* the way a key is, and the
                ;; event is still made when that item is delivered, from
                ;; the pointer's position at that moment.
                (pgtk-enqueue! d 'pgtk-mouse-moved))
              #t))))

    (define (pgtk-pointer-cell d)
      ;; Where the pointer is, in this display's own cells, or #f.
      ;;
      ;; **Asked of Gdk, every time** - GNU Emacs's `pgtk_mouse_position'
      ;; (`pgtkterm.c:3478'), whose calls these are:
      ;;
      ;;   win = gtk_widget_get_window (FRAME_GTK_WIDGET (f));
      ;;   seat = gdk_display_get_default_seat (dpyinfo->gdpy);
      ;;   device = gdk_seat_get_pointer (seat);
      ;;   win = gdk_window_get_device_position (win, device, &win_x,
      ;;                                        &win_y, &mask);
      ;;
      ;; **Answered as cells**, like every other coordinate this display
      ;; hands out - `posn-at-x-y' takes cells and `column-width' is 1 -
      ;; so the Gdk pixels are divided here.
      ;;
      ;; **The *edit widget*, not the toplevel.** `FRAME_GTK_WIDGET (f)'
      ;; is `FRAME_X_OUTPUT (f)->edit_widget' (`pgtkterm.h:484') - the
      ;; widget the frame's text is drawn in - and the drawing area is
      ;; this tree's edit widget. Asking the toplevel window instead was
      ;; what this did, and it is a different question with a different
      ;; answer.
      ;;
      ;; **Asked, not read off an event**: an event's coordinates are
      ;; relative to the window the pointer was over, and the pointer is
      ;; outside the window by definition whenever a drag is scrolling a
      ;; window's edge. It is also what makes one event enough however many
      ;; times the pointer was reported - see `note-mouse-movement'.
      ;;--------------------------------------------------------------
      (let ((area (pgtk-area d)))
        (if (not area)
            #f
            (let ((gdkwin (widget:get-window area)))
              (if (not gdkwin)
                  #f
                  (let* ((seat (display:get-default-seat
                                (window:get-display gdkwin)))
                         (device (seat:get-pointer seat)))
                    (let*-values (((_win x y _mask)
                                   (window:get-device-position gdkwin device)))
                      (cons (truncate (/ x *cell-width*))
                            (truncate (/ y *cell-height*))))))))))

    (define (pgtk-mouse-movement-event d)
      ;; The `mouse-movement' event GNU Emacs's `make_lispy_movement'
      ;; (`keyboard.c:7309') makes of a pointer that has moved: the key and
      ;; a position list built from the *queried* position.
      ;;
      ;; It is called when the marker `note-mouse-movement' posted is
       ;; delivered - by a read, or straight from the signal handler when
       ;; Gtk's loop is the one delivering - and it asks the pointer where
       ;; it is *now*, so every report that arrived in the meantime is
       ;; answered by this one event.
       ;;
      ;; The flag is cleared here, as `pgtk_mouse_position' clears it for
      ;; every frame on the display (`pgtkterm.c:3497'): asking where the
      ;; pointer is *is* reporting the movement. It is cleared for every
      ;; display and not just D's, which is Emacs's shape - its frames on
      ;; one connection share the one display-info - and this tree's front
      ;; end has one Gdk display behind all of them.
      ;;--------------------------------------------------------------
      (let ((cell (pgtk-pointer-cell d)))
        (for-each (lambda (other) (set! (pgtk-mouse-moved other) #f))
                  (cons d (*pgtk-displays*)))
        (and cell
             (list 'mouse-movement
                   (posn-at-x-y (car cell) (cdr cell)
                                (or (pgtk-frame-for d) (*current-frame*)))))))

    (define modifier-keysyms
      ;; The keysyms of the modifier keys themselves. Pressing one is not
      ;; a key this editor can act on, and Emacs never sees one at all -
      ;; a terminal, and a window system, consume them. Gtk delivers
      ;; them, so they are dropped here; otherwise every shift press is
      ;; reported as "unhandled event: 65515" (`0xffeb', Shift_L), which
      ;; is what the compositor sends when the window takes focus.
      ;;--------------------------------------------------------------
      (list #xffe1 #xffe2   ; Shift_L, Shift_R
            #xffe3 #xffe4   ; Control_L, Control_R
            #xffe7 #xffe8   ; Meta_L, Meta_R
            #xffe9 #xffea   ; Alt_L, Alt_R
            #xffeb #xffec   ; Super_L, Super_R
            #xffed #xffee   ; Hyper_L, Hyper_R
            #xffe5 #xffe6   ; Caps_Lock, Shift_Lock
            #xff7f #xfe03)) ; Num_Lock, ISO_Level3_Shift

    (define (pgtk-event-keysym e)
      ;; The keysym of a Gdk key event.
      ;;--------------------------------------------------------------
      (let*-values (((_ keysym) (event:get-keyval e)))
        keysym))

    (define (pgtk-event-cell e)
      ;; Where a Gtk button event happened, as the CELL the frame's
      ;; windows are measured in. A Gdk event carries pixels and every
      ;; window here is placed in cells, so this is the one conversion -
      ;; `gdk_event_get_coords' is the accessor, the same shape as
      ;; `event:get-keyval' above it.
      ;;--------------------------------------------------------------
      ;;
      ;; `gdk_event_get_coords' returns a *boolean* and two out
      ;; parameters, so guile-gi answers three values - the same shape as
      ;; `event:get-keyval' above it, which the tree binds as
      ;; `((_ keysym) ...)'. Binding two here put the boolean in X and
      ;; the X coordinate in Y, and then `round' raised on a boolean
      ;; *inside the signal handler*, where Gtk swallows it: the symptom
      ;; was a click that did nothing at all, which is the thing this
      ;; whole path exists to fix.
      ;;--------------------------------------------------------------
      (let*-values (((_ok x y) (event:get-coords e)))
        (cons (quotient (inexact->exact (round x)) *cell-width*)
              (quotient (inexact->exact (round y)) *cell-height*))))

    (define (pgtk-mouse-event from e symbol)
      ;; A Gtk button event as the *mouse event* GNU Emacs makes of one:
      ;;
      ;;   (SYMBOL (WINDOW POS-OR-AREA (X . Y) TIMESTAMP))
      ;;
      ;; which is what `subr.sld''s `posn-' accessors walk and what
      ;; `(interactive "e")' hands to a command - `mouse-drag-region'
      ;; being the one bound to `down-mouse-1'.
      ;;
      ;; The frame comes first, as it does for a key: a click in a window
      ;; that is not the selected frame's selects that frame before the
      ;; command runs, which is Emacs's own order for a mouse event -
      ;; the frame is selected and *then* the window inside it.
      ;;--------------------------------------------------------------
      (let ((f (or (pgtk-frame-for from) (*current-frame*))))
        (when (and f (not (eq? f (*current-frame*))))
          (select-frame f))
        (list symbol (pgtk-posn-for from e))))

    (define (pgtk-posn-for from e)
      ;; The *position list* a Gdk event makes:
      ;;
      ;;   (WINDOW AREA-OR-POS (X . Y) TIMESTAMP)
      ;;
      ;; which `subr.sld''s `posn-' accessors walk and `(interactive
      ;; "e")' hands to a command.
      ;;--------------------------------------------------------------
      (let* ((f (or (pgtk-frame-for from) (*current-frame*)))
             (cell (pgtk-event-cell e)))
        (posn-at-x-y (car cell) (cdr cell) f)))

    (define (pgtk-key-item d e)
      ;; What a key press is queued as: the event *decoded now*, in the
      ;; signal handler, exactly as GNU Emacs makes the Lisp key event
      ;; the moment the platform event arrives (`kbd_buffer_store_event`,
      ;; `keyboard.c`).
      ;;
      ;; **A queued event outlives the signal emission.** The queue is
      ;; drained by a read (a prompt, an isearch) or by the redisplay
      ;; that follows whatever was running - not necessarily while the
      ;; Gdk event is alive - so what is queued is the integer the decode
      ;; produced, not the platform event. (This is not what broke
      ;; `C-s` on Gtk: that was `return` arriving as a symbol, see
      ;; `isearch-read-key`. It is the shape Emacs has, and it means the
      ;; queue's contents are plain values.)
      ;;
      ;; A modifier key press is `*pgtk-skip*`, as the read path has it.
      ;;--------------------------------------------------------------
      (let ((raw (pgtk-item->event d e)))
        (if (eq? raw *pgtk-skip*)
            *pgtk-skip*
            (cons 'key-event raw))))

    (define (pgtk-encode-event e)
      ;; A GTK key press as the single INTEGER the interface carries: the
      ;; modifier state in the high bits and the keysym in the low ones.
      ;;
      ;; It has to be an integer because that is what `read-input-event'
      ;; may answer - a character or an integer - and a GTK key is
      ;; (modifiers, keysym), which neither a character nor a bare keysym
      ;; can hold. A terminal needs no such encoding because ncurses
      ;; folds the modifiers into the byte; its keypad codes are the same
      ;; idea (a terminal key that is not a character).
      ;;--------------------------------------------------------------
      ;; `event:get-state' and `event:get-keyval' are the Gdk accessors
      ;; whose C forms take an out-parameter, so each answers TWO values:
      ;; whether it worked, then the value. Taking the first alone yields
      ;; the success flag, which is a boolean - hence `let*-values'.
      ;;--------------------------------------------------------------
      (let*-values (((_ state) (event:get-state e))
                    ((_ keysym) (event:get-keyval e)))
        (+ keysym (ash (modifier-type->number state) 32))))

    (define (pgtk-decode-event code)
      ;; The `(MODIFIER-STATE . KEYSYM)' a code encodes.
      ;;--------------------------------------------------------------
      (cons (ash code -32) (logand code #xFFFFFFFF)))

    (define *focus-in-code* -2)
    (define *focus-out-code* -4)
    ;; ^ What the window system's focus events are reported as: the same
    ;; device as `*resize-code*' and `*delete-frame-code*', and for the
    ;; same reason - `read-input-event' may answer only a character or an
    ;; integer, so an event that is neither a key nor a character has to
    ;; be a code the key decoder turns into a path. Emacs's are the keys
    ;; `(focus-in (FRAME))' and `(focus-out (FRAME))' (`keyboard.c:6281'),
    ;; bound to their handlers in `special-event-map'
    ;; (`keyboard.c:14620').

    (define *delete-frame-code* -3)
    ;; ^ What the window manager's request to close the frame is reported
    ;; as: `*resize-code*' again, for the same reason
    ;; and with the same shape - a key event the command loop can dispatch,
    ;; bound to a command in `files.sld' (`handle-delete-frame', which is
    ;; `frame.el''s). Gtk's `delete-event' asks whether it may destroy the
    ;; window, and this is the answer being "not yet": Emacs's
    ;; `delete_event' queues `DELETE_WINDOW_EVENT' and `return TRUE' for
    ;; exactly the same reason, the command loop then deciding whether to
    ;; save and exit or to keep the window.

    (define *resize-code* -1)
    ;; ^ What a resize is reported as. `read-input-event' may answer only a
    ;; character or an integer, and a resize is neither a key nor a
    ;; character - so, like a terminal's own `KEY_RESIZE', it is a code of
    ;; this display's that the key decoder turns into `(resize)'.

    (define (pgtk-ensure-surface! d)
      ;; Make the drawing surface the size the WIDGET is, in pixels - not
      ;; the size of the grid. The grid is the allocation divided by a
      ;; cell, so it is always up to a cell smaller; the surface is what
      ;; is painted into the widget, so it is the larger of the two. A
      ;; surface is made when the display opens, and again after a resize,
      ;; because the old one is the wrong shape and would clip.
      ;;--------------------------------------------------------------
      (let* ((raw (or (pgtk-allocation d)
                      ;; No widget to ask - a display a test made. The
                      ;; size is the grid's at the *current* font, which
                      ;; is the same product `pgtk-open-window' has just
                      ;; worked out, taken again here so that a display
                      ;; whose font has changed since it was made is the
                      ;; right shape.
                      (cons (* (pgtk-columns d) *cell-width*)
                            (* (pgtk-rows d) *cell-height*))))
             ;; Exact integers, always: cairo answers an inexact surface
             ;; size with "invalid value (typically too big)", which
             ;; describes the number's type and not its magnitude, and
             ;; sends you hunting for a size that was never the problem.
             (size (cons (inexact->exact (round (car raw)))
                         (inexact->exact (round (cdr raw))))))
        ;; **A surface that is already the right shape is kept.**
        ;; Remaking it throws away every pixel the last redisplay drew,
        ;; and `ensure-surface!` runs at the top of every `render!` - so
        ;; with the row diff working (a row that did not change is not
        ;; drawn again) the frame came out blank one redisplay after it
        ;; was drawn: a file's text flashed and then vanished, and a
        ;; resize did the same again. Emacs's frame has one X window for
        ;; its whole life and *resizes* it; this is that.
        (if (and (pgtk-surface d) (equal? (pgtk-surface-size d) size))
            #t
        (let* ((surface (cairo-image-surface-create 'argb32
                                                    (car size) (cdr size)))
               (cr (cairo-create surface)))
          (set! (pgtk-surface d) surface)
          (set! (pgtk-surface-size d) size)
          (set! (pgtk-cr d) cr)
          ;; **A new surface is filled with the frame's background.**
          ;; `cairo-image-surface-create` makes a *transparent* one, and
          ;; until now `clear-frame-area!` did this fill on every
          ;; redisplay. A redisplay that does not clear (`clear-garbaged-
          ;; frames!` on a GUI frame) would otherwise leave the whole
          ;; surface unpainted - measured: a frame rendered twice, the
          ;; second not clearing, came out with every pixel non-white,
          ;; the echo row included. Emacs's realize fills the frame
          ;; (`x_make_gc` sets the background and the first
          ;; `x_clear_area` paints it), and this is that fill, made
          ;; where the surface is.
          ;;------------------------------------------------------------
          (apply cairo-set-source-rgb
                 cr
                 (or (colour->rgb (face-attribute 'default ':background))
                     (list 1.0 1.0 1.0)))
          (cairo-paint cr)))))

    (define (pgtk-resize! d width height)
      ;; Take the window's new size in pixels as the grid's new size, and
      ;; tell the command loop, which re-tiles the frame and redraws.
      ;;--------------------------------------------------------------
      ;; Nothing is remembered about the *size*: `screen-size' and the
      ;; surface both ask the widget. This only asks the command loop to
      ;; draw again - and only when the allocation has actually changed,
      ;; since asking on every frame redraws forever.
      ;;--------------------------------------------------------------
      (let ((last (pgtk-last-allocation d)))
        (unless (and last (= (car last) width) (= (cdr last) height))
          (set! (pgtk-last-allocation d) (cons width height))
          (pgtk-enqueue! d 'resize))))

    (define (pgtk-allocation d)
      ;; What the widget is actually allocated, in pixels.
      ;;
      ;; **Remembered, not asked.** The answer is recorded by the
      ;; `size-allocate' signal - which is the *same* signal that is this
      ;; display's only notice that the window has been resized at all
      ;; (`pgtk-resize!'), so reading the size from it adds no staleness
      ;; that did not already exist: a resize nobody hears about is a
      ;; resize that never gets redrawn either.
      ;;
      ;; Asking each time cost **3.2 ms per property** - measured, 3.18
      ;; and 3.22 - and a redisplay asked twice (`pgtk-ensure-surface!'
      ;; and `screen-size'), so four property reads were about 13 ms of
      ;; the ~21 ms a keystroke's redisplay cost. Emacs reads a field.
      ;;
      ;; The widget is asked only when nothing has been recorded, which
      ;; is the display-without-a-window case a test makes: it has no
      ;; widget to send a signal, and used to fall back on its remembered
      ;; pixel size - which the `or' at each caller still does.
      ;;--------------------------------------------------------------
      (or (pgtk-allocated-size d)
          (let ((area (pgtk-area d)))
            (if area
                (let ((w (widget:get-allocated-width area))
                      (h (widget:get-allocated-height area)))
                  (if (and (> w 0) (> h 0))
                      (begin
                        (set! (pgtk-allocated-size d) (cons w h))
                        (cons w h))
                      #f))
                #f))))

    (define (pgtk-cells d)
      ;; The grid, from the allocation. Falls back to what is remembered
      ;; when there is no window yet, which is what a test sees.
      ;;--------------------------------------------------------------
      (let ((size (pgtk-allocation d)))
        (if size
            (cons (max 1 (quotient (car size) *cell-width*))
                  (max 1 (quotient (cdr size) *cell-height*)))
            (cons (pgtk-columns d) (pgtk-rows d)))))

    (define (pgtk-now-ms)
      (quotient (* 1000 (get-internal-real-time))
                internal-time-units-per-second))

    (define (pgtk-main-quit)
      ;; Leave that loop: GNU Emacs's `Fkill_emacs' ends in `exit', and on
      ;; Gtk the nearest honest thing is to stop the loop that is running
      ;; the process and let the caller return.
      ;;--------------------------------------------------------------
      (main-quit))

    (define (pgtk-main)
      ;; Run Gtk's own main loop. It returns when `pgtk-main-quit' stops
      ;; it, and until then it is the loop that absorbs the editor's
      ;; input: the editor leaves no loop of its own running, so every
      ;; event - a key the command loop turns into a command, and equally
      ;; anything else in the window - is dispatched by this one.
      ;;
      ;; There is no idle-callback trick here on purpose. An earlier
      ;; version started the editor from inside `gtk_main' and then let
      ;; its command loop run, with every read in a `GMainLoop' of the
      ;; tree's own nested inside. That put `gtk_main' on the stack and
      ;; then never let it iterate again, so it bought nothing.
      ;;--------------------------------------------------------------
      (main))

    (define (pgtk-item->event from item)
      ;; What ITEM means as an event: `*pgtk-skip*' for something that is
      ;; not one - a modifier key press, which Gtk delivers and a terminal
      ;; consumes - and #f for the deadline sentinel.
      ;;
      ;; Split out of `pgtk-take-queued' rather than inlined, because what
      ;; an item *means* is a different question from where it is kept,
      ;; and this is the half that knows about frames and key encoding.
      ;;--------------------------------------------------------------
      (cond
       ((eq? item *pgtk-skip*) *pgtk-skip*)
       ((eq? item 'pgtk-deadline) #f)
       ((eq? item 'resize) *resize-code*)
       ((eq? item 'focus-in) *focus-in-code*)
       ((eq? item 'focus-out) *focus-out-code*)
       ((eq? item 'delete-frame) *delete-frame-code*)
       ;; A button, tagged by the handler that queued it: its event is
       ;; a mouse event and not a key, so it must not be asked for a
       ;; keysym.
       ((and (pair? item) (eq? (car item) 'button-press))
        (pgtk-mouse-event from (cdr item) 'down-mouse-1))
       ((and (pair? item) (eq? (car item) 'button-release))
        (pgtk-mouse-event from (cdr item) 'mouse-1))
       ;; **A release *after* the pointer moved is a different event** -
       ;; GNU Emacs's `drag-mouse-1', which `mouse.el:3783' binds to
       ;; `mouse-set-region'. It is what re-establishes the region the
       ;; drag's own cleanup takes down, and so what makes the highlight
       ;; survive letting the button go. The position list carries the
       ;; press's position *and* the release's, which is what
       ;; `event-end' reads the second of.
       ((and (pair? item) (eq? (car item) 'drag-release))
        (list 'drag-mouse-1 (pgtk-press-posn from)
              (pgtk-posn-for from (cdr item))))
       ;; The pointer moved and nobody has been told yet: **this is where
       ;; the `mouse-movement' event is made** - GNU Emacs's
       ;; `make_lispy_movement' (`keyboard.c:7309') reaching it from
       ;; `kbd_buffer_get_event''s `some_mouse_moved' branch (`:4525').
       ;; Making it here and not in the signal handler is the whole
       ;; mechanism: whichever reports arrived before this one are
       ;; answered by the *queried* pointer position, so a hundred
       ;; twitches are one event, and a drag's scroll loop - which ends on
       ;; any input at all - is not ended by each of them.
       ((eq? item 'pgtk-mouse-moved) (pgtk-mouse-movement-event from))
       ;; A menu selection: one key of the sequence a clicked item
       ;; stands for (`pgtk-menu-selection!`). It is already a *key*, so
       ;; it is tagged rather than decoded - `key-event->key` answers it
       ;; as it stands, and nothing asks it for a keysym.
       ((and (pair? item) (eq? (car item) 'menu-bar-event)) item)
       ;; A key decoded when it *arrived* (see `pgtk-key-item`): the
       ;; integer is the same one `read-input-event` would have answered,
       ;; and it is a value that can outlive the Gdk event it came from.
       ((and (pair? item) (eq? (car item) 'key-event)) (cdr item))
       ((memv (pgtk-event-keysym item) modifier-keysyms) *pgtk-skip*)
       (else
          ;; A key from a window that is not the selected frame's selects
          ;; it first, so the command acts on the frame the user typed
          ;; in. `focus-in-event' has usually done this already; this is
          ;; the belt to its braces, and it is what makes the second
          ;; window work when the window manager gives no focus event.
          (let ((f (pgtk-frame-for from)))
            (when (and f (not (eq? f (*current-frame*))))
              (select-frame f)))
          (pgtk-encode-event item))))

    (define (pgtk-take-queued d found)
      ;; Take the front of the queue and answer what the read should
      ;; answer for it: the front is dropped either way.
      ;;--------------------------------------------------------------
      (let ((from (car found)) (item (cdr found)))
        (set! (pgtk-queue from) (cdr (pgtk-queue from)))
        (pgtk-item->event from item)))

    (define (pgtk-wait! d timeout)
      ;; Wait until something has been queued, or TIMEOUT milliseconds
      ;; have passed. A negative TIMEOUT waits for as long as it takes.
      ;;
      ;; **A Gtk loop, not a pump of our own.** The wait is one
      ;; `g_main_loop_run`, which blocks until `g_main_loop_quit` - and
      ;; `pgtk-enqueue!` is what quits it, so the loop runs exactly until
      ;; there is something to read. Gtk knows which descriptors to watch,
      ;; how to sleep on them and what else it has to do while nothing is
      ;; happening; driving its iteration by hand from Scheme made us
      ;; answer those questions instead, badly.
      ;;
      ;; It is *nested* in Gtk's own main loop - `gtk_main', which
      ;; `pgtk-main' runs and which is what dispatches the editor's keys
      ;; in the ordinary way (`PGTK-ENQUEUE!`) - and that nesting is the
      ;; one thing the editor's reentrancy cannot avoid and does not want
      ;; to: a read that happens while a command is running (a minibuffer
      ;; prompt, an isearch, a yes-or-no question) is a wait inside a
      ;; wait, and every one of them is still a Gtk loop.
      ;;
      ;; Measured, on a window that is up and nothing happening: this
      ;; idles at nothing, while driving the loop by hand cost ~28 ms of
      ;; CPU per wake-up - guile-gi crossings plus Gtk's own handling -
      ;; and the old read woke once per 100 ms for as long as the back
      ;; door was open.
      ;;
      ;; The loop is made once and run again each wait, which is allowed:
      ;; a `GMainLoop' is a flag around a context, and `quit' clears it.
      ;;
      ;; **The deadline is a GSource.** One is armed only when the caller
      ;; asked for a timeout, which `keyboard.sld' does for the next timer
      ;; that is due - and, on a front end that cannot be *woken* rather
      ;; than one that can, to give the development REPL a turn. Gtk sets
      ;; `SET-REPL-WAKE!', so for it the cap is gone and this fires only
      ;; for timers; a read with no deadline arms no source at all and
      ;; blocks until a key, so an idle editor wakes for nothing.
      ;;--------------------------------------------------------------
      ;; `let*' and not `let': `loop' asks whether this wait is nested,
      ;; and a `let' binding's init is evaluated in the *enclosing* scope,
      ;; where `nested?' does not exist yet.
      (let* ((source (and (>= timeout 0)
                         (timeout-add
                          0 timeout
                          (lambda (data)
                            (poll-repl!)
                            (pgtk-enqueue! d 'pgtk-deadline)
                            #t)
                          #f)))
            ;; The outermost wait of *ours* runs the remembered loop, so
            ;; that a keystroke does not pay for making one; a wait inside
            ;; another needs a loop of its own, because GLib will not run
            ;; one that is already running.
            (nested? (pair? *pgtk-running*))
            (loop (if nested? (main-loop:new #f #f) (pgtk-main-loop))))
        (dynamic-wind
         (lambda () (set! *pgtk-running* (cons loop *pgtk-running*)))
         (lambda () (main-loop:run loop))
         (lambda ()
           (set! *pgtk-running* (cdr *pgtk-running*))
           (when nested? (main-loop:unref loop))
           (when source (source-remove? source))))))

    (define (pgtk-read-event d timeout)
      ;; Read one input event, TIMEOUT milliseconds allowed - a negative
      ;; TIMEOUT blocks. This is `read-input-event''s body: wait in Gtk's
      ;; main loop until the queue has something or the deadline passes.
      ;;
      ;; An event is `(MODIFIER-STATE . KEYSYM)'.
      ;;
      ;; A blocking read must never answer #f: `keyboard.sld' takes that
      ;; for the end of input and leaves the editor. Nor may it answer
      ;; anything for an item that is not a key, which is what
      ;; `*pgtk-skip*' keeps out of the answer.
      ;;
      ;; **Every window's queue, not just this one's.** With more than one
      ;; window open a keystroke arrives on the window that has the focus,
      ;; which need not be the display this read was called with
      ;; (`read-input-event' is given `(current-display)') - and draining
      ;; one queue meant the keys typed into a second window were never
      ;; read at all. Emacs has one queue per terminal with each event
      ;; tagged by frame; a queue per window scanned together is the same
      ;; thing here.
      ;;--------------------------------------------------------------
      (let ((deadline (and (>= timeout 0) (+ (pgtk-now-ms) timeout))))
        (let loop ()
          (let ((found (%pgtk-next-queued d)))
            (cond
             (found
              (let ((answer (pgtk-take-queued d found)))
                (if (eq? answer *pgtk-skip*) (loop) answer)))
             (else
              (let ((left (and deadline (- deadline (pgtk-now-ms)))))
                (if (and left (<= left 0))
                    ;; The deadline passed while nothing arrived.
                    #f
                    (begin
                      (pgtk-wait! d (if left (max 1 left) -1))
                      ;; Whatever woke it is on the queue now - or a
                      ;; source that is not ours was ready and the queue
                      ;; is still empty, in which case this waits again.
                      (loop))))))))))

    (define-method (read-input-event (d <pgtk-display>) timeout)
      (pgtk-read-event d timeout))

    (define-method (key-event->key (d <pgtk-display>) ev)
      ;; EV is the integer `read-input-event' answered; decode it into the
      ;; modifier state and keysym, and answer the *key event* GNU Emacs's
      ;; `make_lispy_event' would have - which is what `keysym-event'
      ;; builds. The four codes below are not keys at all: they are the
      ;; frame events the same decode carries, named as the keymaps name
      ;; them (`(kbd "<resize>")' and the three beside it).
      ;;--------------------------------------------------------------
      (cond
       ;; A mouse event needs no decoding: the display made it, in the
       ;; shape `subr.sld''s `posn-' accessors walk, and its *key* is the
       ;; symbol at its head.
       ;;
       ;; **The list is `dispnew.sld''s, and it was written out here
       ;; first** - which is how `drag-mouse-1' came to be missing from
       ;; it. A release after the pointer has moved is a `drag-mouse-1',
       ;; and while that name was absent this answered `#f' for it: the
       ;; read produced *nothing*, the release was thrown away, the
       ;; drag's transient map was never popped, and the pointer went on
       ;; moving the region after the button came up.
       ((and (pair? ev) (memq (car ev) *mouse-event-keys*))
        (car ev))
       ;; A menu selection is one key of the sequence the item stands
       ;; for - the C's `MENU_BAR_EVENT`, whose `event->arg` is already
       ;; the key (`keyboard.c:7231`).
       ((and (pair? ev) (eq? (car ev) 'menu-bar-event))
        (cdr ev))
       ((eqv? ev *resize-code*) 'resize)
       ((eqv? ev *focus-in-code*) 'focus-in)
       ((eqv? ev *focus-out-code*) 'focus-out)
       ((eqv? ev *delete-frame-code*) 'delete-frame)
       ((integer? ev)
        (let ((decoded (pgtk-decode-event ev)))
          (and decoded (keysym-event (car decoded) (cdr decoded)))))
       (else #f)))

    (define-method (screen-size (d <pgtk-display>))
      ;; In pixels, and a character is one pixel here, so this is the
      ;; grid in cells - asked of the window every time, so the redisplay
      ;; follows the window with no signal to keep in step.
      ;;
      ;; **The font is settled first**, because the grid is the window's
      ;; pixels divided by the size of a cell, and a cell is a fact about
      ;; the font. `sync-frame-size!' asks this before the frame is
      ;; tiled, so a `global-text-scale-adjust' takes effect in the same
      ;; redisplay that draws it rather than the one after.
      ;;--------------------------------------------------------------
      (pgtk-ensure-font!)
      (pgtk-cells d))

    (define-method (display-mouse-position (d <pgtk-display>))
      ;; **The generic has to be imported, or this defines a new one.** A
      ;; `define-method' on a name that is not bound makes a *fresh*
      ;; generic in this module with only this method on it, and the
      ;; caller - `(schemacs editor frame)''s `mouse-position', through
      ;; dispnew's generic - then has none at all: "No applicable method
      ;; for #<generic> mouse-position (0>". It compiles cleanly too, and
      ;; the "possibly unbound variable" warning does not fire, because
      ;; `define-method' is allowed to create the binding.
      ;;
      ;; Where the pointer is, asked of Gdk - GNU Emacs's
      ;; `pgtk_mouse_position' (`pgtkterm.c:3478'), whose calls these are:
      ;;
      ;;   win = gtk_widget_get_window (FRAME_GTK_WIDGET (f));
      ;;   seat = gdk_display_get_default_seat (dpyinfo->gdpy);
      ;;   device = gdk_seat_get_pointer (seat);
      ;;   win = gdk_window_get_device_position (win, device, &win_x,
      ;;                                        &win_y, &mask);
      ;;
      ;; **Answered as cells**, like every other coordinate this display
      ;; hands out - `posn-at-x-y` takes cells and `column-width` is 1 -
      ;; so the Gdk pixels are divided here.
      ;;
      ;; **Asked, not read off an event**: an event's coordinates are
      ;; relative to the window the pointer was over, and the pointer is
      ;; outside the window by definition whenever a drag is scrolling a
      ;; window's edge.
      ;;--------------------------------------------------------------
      ;; **The *edit widget*, not the toplevel.** `FRAME_GTK_WIDGET (f)'
      ;; is `FRAME_X_OUTPUT (f)->edit_widget' (`pgtkterm.h:484') - the
      ;; widget the frame's text is drawn in - and the drawing area is
      ;; this tree's edit widget. Asking the toplevel window instead was
      ;; what this did, and it is a different question with a different
      ;; answer.
      ;;--------------------------------------------------------------
      (let ((area (pgtk-area d)))
        (if (not area)
            #f
            (let ((gdkwin (widget:get-window area)))
              (if (not gdkwin)
                  #f
                  (let* ((seat (display:get-default-seat
                                (window:get-display gdkwin)))
                         (device (seat:get-pointer seat)))
                    (let*-values (((_win x y _mask)
                                   (window:get-device-position gdkwin device)))
                      (cons (truncate (/ x *cell-width*))
                            (truncate (/ y *cell-height*))))))))))

    (define-method (column-width (d <pgtk-display>)) 1)
    (define-method (line-height (d <pgtk-display>)) 1)
    (define-method (face-metrics (d <pgtk-display>) face-attrs)
      ;; The ascent and descent of the line this display draws, in pixels.
      ;;
      ;; **The answer is the *frame's* font, not the face's `:height`.**
      ;; That is what the renderer does: `pgtk-show-text!` draws every run
      ;; at `*font-pixel-size*`, so a face that names a height is drawn at
      ;; the frame's size whatever its row says. This used to answer the
      ;; face's own height, and the two disagreed the moment
      ;; `text-scale-mode` scaled one buffer: `pgtk-ensure-font!` resizes
      ;; the whole frame's font from the *current* buffer's default face,
      ;; while a neighbouring window's rows were measured from *its*
      ;; faces - 60-pixel rows in the scaled window and 21 in the other -
      ;; and those 21-pixel rows were drawn with 60-pixel glyphs on top of
      ;; each other. Measured with `C-x C-+` in a split frame.
      ;;
      ;; Emacs measures per face, because it opens a font per face. That
      ;; is the renderer this file has not written yet - see
      ;; `pgtk-ensure-font!`'s own note - and until it is, a row's height
      ;; has to be the height of what is drawn. The *width* is still the
      ;; frame's one cell for the same reason `text-scale` cannot widen
      ;; it: the column arithmetic assumes one pitch.
      ;;--------------------------------------------------------------
      (cons (max 1 *font-ascent*)
            (max 0 (- *cell-height* *font-ascent*))))

    (define *face-metrics-cache* '())
    ;; ^ `((PIXELS . (ASCENT . DESCENT)) ...)`. A redisplay asks for the
    ;; same face on every row, and opening a font per row would be the
    ;; most expensive thing in a repaint.

    (define-method (display-set-size! (d <pgtk-display>) width height)
      ;; Ask the window manager for WIDTH x HEIGHT pixels: GNU Emacs's
      ;; `set_window_size_hook' (`pgtk_set_window_size'), which
      ;; `adjust_frame_size' calls once it has decided the native size.
      ;; `window:resize' asks rather than insists - see
      ;; `pgtk-open-window' - so a compositor still gets the last word.
      ;;--------------------------------------------------------------
      (let ((win (pgtk-window d)))
        (when win (window:resize win width height))
        #t))

    (define-method (display-cell-size (d <pgtk-display>))
      ;; One cell in real pixels - `FRAME_COLUMN_WIDTH' and
      ;; `FRAME_LINE_HEIGHT', which `pgtk-ensure-font!' takes from the
      ;; font. The redisplay counts in cells (`column-width' is 1); this
      ;; is the size of one.
      ;;--------------------------------------------------------------
      (pgtk-cell-size))

    ;;----------------------------------------------------------------
    ;; The font families this display can draw with
    ;;------------------------------------------------------------------
    ;; GNU Emacs's `font-family-list` (`font.c:4442`) asks each font
    ;; driver of the frame for its families; Pango is this frame's
    ;; driver. **Through the FFI, not guile-gi**: `font-map:list-families`
    ;; exists but cannot marshal its out-array - measured, "unhandled
    ;; argument type 'pointer to CArray of type gpointer'" - so the C
    ;; call is made the way the Pango text already is.

    (define pango-font-map-list-families
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_map_list_families"
                        void (list '* '* '*)))
    (define pango-font-family-get-name
      (pango-foreign-fn "libpango-1.0.so.0" "pango_font_family_get_name"
                        '* (list '*)))
    (define %g-free-pointer
      (pointer->procedure void
                          (dynamic-func "g_free"
                                        (dynamic-link "libglib-2.0.so.0"))
                          (list '*)))

    (define-method (display-font-families (d <pgtk-display>))
      ;; The frame's families as a list of names, duplicates dropped -
      ;; the C's `Fmemq` test, keeping the first occurrence of each and
      ;; answering the list most-recently-seen first, as its `Fcons`
      ;; does.
      ;;--------------------------------------------------------------
      (let ((out-array (make-c-struct (list '*) (list %null-pointer)))
            (out-count (make-c-struct (list int) (list 0))))
        (pango-font-map-list-families (pango-font-map-default)
                                      out-array out-count)
        (let* ((array (car (parse-c-struct out-array (list '*))))
               (count (car (parse-c-struct out-count (list int)))))
          (if (or (= count 0) (null-pointer? array))
              '()
              (let ((ptrs (parse-c-struct array (make-list count '*))))
                (let loop ((rest ptrs) (acc '()))
                  (if (null? rest)
                      (begin (%g-free-pointer array) acc)
                      (let ((name
                             (pointer->string
                              (pango-font-family-get-name (car rest))
                              -1 "UTF-8")))
                        (loop (cdr rest)
                              (if (member name acc) acc (cons name acc)))))))))))

    (define-method (display-color-cells (d <pgtk-display>)) 16777216)

    (define-method (realize-face (d <pgtk-display>) face-attrs)
      (realize-face-token face-attrs))

    (define-method (ensure-surface! (d <pgtk-display>))
      ;; Make the drawing surface if it is not there. **This is
      ;; separate from `clear-frame-area!` because Emacs separates them**:
      ;; the surface is the frame's X window, made when the frame is
      ;; realized (`x_make_frame_visible` -> `x_wm_set_size_hint` and the
      ;; `x_create_bitmap` path), and `clear_frame_area` only fills it.
      ;; This tree used to make it inside `clear-frame-area!`, which was
      ;; harmless while every redisplay cleared - but a redisplay that
      ;; does not clear (a GUI frame with an unspoiled surface) then had
      ;; no surface to draw into at all.
      ;;--------------------------------------------------------------
      (pgtk-ensure-surface! d))

    (define-method (clear-frame-area! (d <pgtk-display>))
      ;; Fill the surface with the default face's background and start a
      ;; new frame: everything drawn from here overwrites it. The surface
      ;; is made here rather than at open, and remade after a resize,
      ;; because its size is the grid's.
      ;;
      ;; **The fill is the default face's background, and it used to be
      ;; hardcoded white.** Only the cells a glyph is written into are
      ;; painted by `write-glyphs!', so a themed `default' background -
      ;; `black', in a dark theme - left every cell with no glyph white,
      ;; and a theme changed the text and the mode line while the frame
      ;; stayed white: measured, `enable-theme' on this display left
      ;; `(face-attribute 'default ':background)' "black" and the screen
      ;; unchanged but for the mode line. Emacs's frame background is
      ;; the default face's (`x_fill_rectangle' over the frame with
      ;; `FRAME_BACKGROUND_PIXEL', which `realize_default_face' set from
      ;; the face).
      ;;--------------------------------------------------------------
      (pgtk-ensure-surface! d)
      (let ((cr (pgtk-cr d)))
        (when cr
          (apply cairo-set-source-rgb
                 cr
                 (or (colour->rgb (face-attribute 'default ':background))
                     (list 1.0 1.0 1.0)))
          (cairo-paint cr))))

    (define-method (clear-end-of-line! (d <pgtk-display>) window row area x
                                       width token)
      ;; Blank the cells [X, X+WIDTH) of row Y. A GUI fill already covers
      ;; the rectangle a run is drawn in, so this is what a *shorter* row
      ;; needs: the cells past its text still hold the previous frame's
      ;; glyphs. Same call as `write-glyphs!` makes for a run, without
      ;; any text - GNU Emacs's `gui_clear_end_of_line`
      ;; (`xdisp.c:34644`) fills from X to the window's right edge.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d))
            (y (glyph-row-y row)))
        (when (and cr (> width 0))
          (apply cairo-set-source-rgb
                 cr (or (face-token-background token)
                        (colour->rgb (face-attribute 'default ':background))
                        (list 1.0 1.0 1.0)))
          (cairo-rectangle cr (cell-x x) y
                           (* *cell-width* width) *cell-height*)
          (cairo-fill cr))))

    (define-method (update-window-begin! (d <pgtk-display>)) #t)
    (define-method (update-window-end! (d <pgtk-display>)) #t)

    (define (text-cells text)
      ;; How many cells TEXT occupies in this editor's model: the sum of
      ;; its characters' widths.
      ;;
      ;; `char-display-width' and not `string-length', which is the whole
      ;; reason a run cannot simply be handed to cairo: a CJK ideograph is
      ;; one character and two cells, so a run drawn as one string - or a
      ;; background rectangle measured by its length - is one cell short
      ;; for each of them.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0))
        (if (>= i (string-length text))
            col
            (loop (+ i 1)
                  (+ col (char-display-width (string-ref text i) col))))))

    (define (%pgtk-write-run d glyphs y x token)
      ;; One run: the cells [X, X+width) of the row at pixel Y, all in
      ;; TOKEN's face. The body of the old `write-glyphs!`, which is now
      ;; `write-glyphs!`'s per-run step below - `fill_glyph_string`'s
      ;; split is the caller's.
      ;;--------------------------------------------------------------
      ;; Draw TEXT at cell (X, Y), a *cluster* at a time.
      ;;
      ;; The surface is ours, so the cell grid is exact and there is no
      ;; clipping to leave to anyone else - but the grid is made of cells
      ;; and a string is made of characters, and the two stop agreeing at
      ;; the first wide character. So each cluster is placed at its own
      ;; cell column, and the column advances by the character's width
      ;; rather than by one. This is what the terminal does for us: it
      ;; advances by the width it knows the character has.
      ;;
      ;; A cluster is a character plus the zero-width characters after it
      ;; - a letter and its combining accent - which are drawn together so
      ;; that the accent lands on the letter and not on an empty cell.
      ;;
      ;; **A written cell shows only what was written.** That is what a
      ;; terminal does - a cell holds one character and one set of
      ;; attributes, so writing replaces what was there - and every caller
      ;; of this assumes it. Painting instead of replacing is what made
      ;; the continuation glyph land *on top of* the last character of a
      ;; long line, which reads as a mangled letter rather than as the
      ;; marker; and the same would be true of anything else drawn over
      ;; text. So the run's cells are filled first, with the face's own
      ;; background or with the display's when the face names none.
      ;;--------------------------------------------------------------
      ;; Pango takes a string, as GNU Emacs's pgtk back end hands it one
      ;; built from a `struct glyph_string' - so the join is here, at the
      ;; boundary, and a run is one face.
      (let ((cr (pgtk-cr d))
            (text (glyphs->text glyphs))
            (foreground (face-token-foreground token))
            (background (face-token-background token)))
        (when cr
          ;; The run's cells first: the face's own background, so that a
          ;; face which paints cells rather than glyphs - the mode line,
          ;; the region - is drawn, or the frame's, which is what the
          ;; frame was cleared to and so what a default cell shows.
          ;; **Y is already a pixel offset**, from the redisplay's own
          ;; row walk; only X is still a cell, because the horizontal
          ;; pitch is one per frame.
          ;; A run with no background of its own shows the *frame's* -
          ;; which is the default face's, `clear-frame-area!'s fill. The
          ;; hardcoded white this used to fall back to would punch white
          ;; holes in a themed frame wherever the face named no colour.
          (apply cairo-set-source-rgb
                 cr (or background
                        (colour->rgb (face-attribute 'default ':background))
                        (list 1.0 1.0 1.0)))
          (cairo-rectangle cr (cell-x x) y
                           (* *cell-width* (text-cells text))
                           *cell-height*)
          (cairo-fill cr)
          ;; An unspecified foreground is the *frame's* - the default
          ;; face's foreground, which is `FRAME_FOREGROUND_PIXEL` after
          ;; `realize_named_face` merged it in (`xfaces.c:6590`). Black
          ;; is right only for the frame that a dark theme replaces.
          (apply cairo-set-source-rgb
                 cr (or foreground
                        (colour->rgb (face-attribute 'default ':foreground))
                        (list 0.0 0.0 0.0)))
          (let loop ((i 0) (col 0))
            (when (< i (string-length text))
              (let* ((end (let scan ((j (+ i 1)))
                            (if (and (< j (string-length text))
                                     (= 0 (char-display-width
                                           (string-ref text j) col)))
                                (scan (+ j 1))
                                j)))
                     (c (string-ref text i)))
                (pgtk-show-text! d (substring text i end)
                                 (cell-x (+ x col))
                                 (+ y *font-ascent*))
                (loop end (+ col (char-display-width c col)))))))))

    (define-method (write-glyphs! (d <pgtk-display>) window row area x
                                  glyphs len)
      ;; Draw LEN glyphs of ROW, from cell column X - GNU Emacs's
      ;; `write_glyphs` (`dispextern.h`), whose `fill_glyph_string`
      ;; (`xdisp.c:31157`) does the same split this does:
      ;;
      ;;   while (glyph < last
      ;;          && glyph->type == CHAR_GLYPH
      ;;          && glyph->voffset == voffset
      ;;          && glyph->face_id == face_id ...)
      ;;
      ;; - a run is a maximal stretch of one face, and each run is drawn
      ;; once. **The split is here and not in the redisplay** because that
      ;; is where Emacs has it: a backend that can draw a mixed-face row
      ;; in one go (or must) is free to, and nothing above the interface
      ;; has an opinion.
      ;;
      ;; **The row carries the position.** `row->y` is the pixel y, which
      ;; is `it->current_y` after `display_line` laid the row out - a
      ;; pixel offset and not a screen row, since rows differ in height
      ;; once a buffer is scaled.
      ;;--------------------------------------------------------------
      (let ((y (glyph-row-y row))
            (x0 (+ x (if (eq? area 'text) 0 0))))
        (if (= len 0)
            (clear-end-of-line! d window row area x)
            (let loop ((i 0) (col x0))
              (when (< i len)
                (let* ((g (vector-ref glyphs i))
                       (token (glyph-face-id g))
                       (end (let scan ((j (+ i 1)))
                              (if (and (< j len)
                                       (eqv? (glyph-face-id
                                              (vector-ref glyphs j))
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
                  (%pgtk-write-run d parts y col token)
                  (loop end (+ col cells))))))))

    (define-method (cursor-to! (d <pgtk-display>) window vpos hpos)
      ;; A window system has no terminal cursor to move: the cursor is
      ;; *drawn*, by `draw-window-cursor!`, and `render!` does that after
      ;; the window loop. Emacs's `output_cursor_to` (`xdisp.c`) is the
      ;; same division for a frame with `FRAME_WINDOW_P`.
      ;;
      ;; It does not record where the cursor is either: this tree places
      ;; the cursor from `cursor-screen-position` at draw time, where
      ;; Emacs reads back `w->cursor` set by `display_and_set_cursor`.
      ;;--------------------------------------------------------------
      #t)

    (define-method (raw-cursor-to! (d <pgtk-display>) vpos hpos) #t)
    (define-method (window-system-display? (d <pgtk-display>)) #t)
    (define-method (clear-to-end! (d <pgtk-display>)) #t)
    (define-method (clear-frame! (d <pgtk-display>)) (clear-frame-area! d))
    (define-method (update-begin! (d <pgtk-display>)) #t)
    (define-method (update-end! (d <pgtk-display>)) #t)
    (define-method (set-terminal-modes! (d <pgtk-display>)) #t)
    (define-method (reset-terminal-modes! (d <pgtk-display>)) #t)

    ;;----------------------------------------------------------------
    ;; The `:box` face attribute
    ;;
    ;; GNU Emacs's `realize_x_face` (`xfaces.c:6445-6533`) turns the
    ;; face's `:box` value into a box type, a colour and two line
    ;; widths; `pgtk_draw_glyph_string_box` (`pgtkterm.c:2004`) then
    ;; draws it around the glyph string, and `pgtk_draw_box_rect`
    ;; (`:1960`) is the rectangle arithmetic below.
    ;;
    ;; A terminal has no box at all (`realize_tty_face` drops it), which
    ;; is why `term.sld` answers this generic with `#f`.
    ;;------------------------------------------------------------------

    (define (box-attributes box token)
      ;; BOX parsed as `(COLOUR VWIDTH HWIDTH TYPE)`, or `#f` for no
      ;; box. TYPE is `simple`, `raised` or `sunken`.
      ;;
      ;; The defaults are `xfaces.c:6445`'s: a colour string is a
      ;; one-pixel simple box in that colour; a number is a simple box
      ;; in the face's foreground, `N` pixels wide vertically and
      ;; horizontally (`(abs n) . n`); a `(VWIDTH . HWIDTH)` cons is the
      ;; same with the two widths given; and the plist form starts as a
      ;; one-pixel simple box in the foreground and takes `:line-width`,
      ;; `:color` and `:style` from there. `flat-button` with no colour
      ;; uses the *background* instead, which is the C's one exception
      ;; (`xfaces.c:6528`).
      ;;--------------------------------------------------------------
      (define fg (or (face-token-foreground token) (list 0.0 0.0 0.0)))
      (define bg (or (face-token-background token) (list 1.0 1.0 1.0)))
      (cond
       ((not box) #f)
       ((eq? box #t) (list fg 1 1 'simple))
       ((string? box) (list (or (colour->rgb box) fg) 1 1 'simple))
       ((integer? box) (list fg (abs box) box 'simple))
       ((and (pair? box) (integer? (car box)) (integer? (cdr box)))
        (list fg (car box) (cdr box) 'simple))
       ((pair? box)
        (let ((colour #f) (explicit? #f) (flat? #f) (vwidth 1) (hwidth 1)
              (type 'simple))
          (let loop ((rest box))
            (when (pair? rest)
              (when (pair? (cdr rest))
                (let ((keyword (car rest)) (value (cadr rest)))
                  (cond
                   ((eq? keyword ':line-width)
                    (cond
                     ((integer? value)
                      (set! vwidth (abs value))
                      (set! hwidth value))
                     ((and (pair? value) (integer? (car value))
                           (integer? (cdr value)))
                      (set! vwidth (car value))
                      (set! hwidth (cdr value)))))
                   ((eq? keyword ':color)
                    (when (string? value)
                      (let ((rgb (colour->rgb value)))
                        (when rgb
                          (set! colour rgb)
                          (set! explicit? #t)))))
                   ((eq? keyword ':style)
                    (cond ((eq? value 'released-button)
                           (set! type 'raised))
                          ((eq? value 'pressed-button)
                           (set! type 'sunken))
                          ((eq? value 'flat-button)
                           (set! type 'simple)
                           (set! flat? #t)))))))
              (loop (cddr rest))))
          ;; A plain box defaults to the foreground; a 3D one and
          ;; `flat-button` default to the background (the manual's rule,
          ;; which is what the C's relief colours and its flat-button
          ;; branch amount to).
          (cond ((and (eq? type 'simple) explicit?)
                 (list colour vwidth hwidth type))
                ((and (eq? type 'simple) flat?)
                 (list bg vwidth hwidth type))
                ((eq? type 'simple)
                 (list fg vwidth hwidth type))
                ;; raised/sunken without a colour: shadows from the
                ;; face's background (`pgtk_setup_relief_colors`).
                ((not explicit?) (list bg vwidth hwidth type))
                (else (list colour vwidth hwidth type)))))
       (else #f)))

    (define (rgb-lighten rgb)
      ;; Emacs makes the light relief with `x_alloc_lighter_color`'s
      ;; factor 1.2 (`pgtkterm.c:1848`). That function also works in
      ;; the display's colour depth and tries a delta; this frame's
      ;; colours are already floats, so the factor is applied to them.
      ;;--------------------------------------------------------------
      (map (lambda (v) (min 1.0 (* v 1.2))) rgb))

    (define (rgb-darken rgb)
      ;; The dark relief: factor 0.6 (`pgtkterm.c:1850`).
      ;;--------------------------------------------------------------
      (map (lambda (v) (* v 0.6)) rgb))

    (define (fill-box-rect! cr colour x y w h)
      (apply cairo-set-source-rgb cr colour)
      (cairo-rectangle cr x y w h)
      (cairo-fill cr))

    (define-method (draw-box! (d <pgtk-display>) box token x y cells height
                              left? right?)
      ;; Draw BOX around the run at cell X, pixel Y: the four sides of
      ;; `pgtk_draw_box_rect`, with the two colours of
      ;; `pgtk_draw_relief_rect` (`pgtkterm.c:1994`) when the box is 3D.
      ;; The C's diagonal corner triangles are not drawn - overlapping
      ;; square corners give the same visible edges.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d)))
        (when cr
          (let ((spec (box-attributes box token)))
            (when spec
              (let* ((colour (car spec))
                     (vwidth (max 1 (abs (cadr spec))))
                     (hwidth (max 1 (abs (caddr spec))))
                     (type (cadddr spec))
                     (left (cell-x x))
                     (right (+ (cell-x x) (* *cell-width* cells) -1))
                     (top y)
                     (bottom (+ y height -1))
                     (top-left-colour
                      (if (eq? type 'sunken) (rgb-darken colour) colour))
                     (bottom-right-colour
                      (if (eq? type 'sunken) (rgb-lighten colour) colour)))
                (when (eq? type 'raised)
                  (set! top-left-colour (rgb-lighten colour))
                  (set! bottom-right-colour (rgb-darken colour)))
                ;; left, right, top, bottom - the C's order
                (when left?
                  (fill-box-rect! cr top-left-colour left top vwidth height))
                (when right?
                  (fill-box-rect! cr bottom-right-colour
                                  (+ 1 (- right vwidth)) top vwidth height))
                (fill-box-rect! cr top-left-colour left top
                                (+ 1 (- right left)) hwidth)
                (fill-box-rect! cr bottom-right-colour left
                                (+ 1 (- bottom hwidth))
                                (+ 1 (- right left)) hwidth)))))))

    (define (frame-background-colour frame)
      ;; The frame's background, as cairo components: `FRAME_BACKGROUND_PIXEL`
      ;; is the `default' face's `:background', and a frame with no default
      ;; face to ask is white, which is the C's `WHITE_PIX_DEFAULT'.
      ;;--------------------------------------------------------------
      (or (and frame (colour->rgb (face-attribute 'default ':background frame)))
          (list 1.0 1.0 1.0)))

    (define (cursor-box-colour frame)
      ;; The colour the cursor is filled or outlined with - GNU Emacs's
      ;; `cursor_pixel' (`x_set_cursor_color', `xfns.c:1481`).
      ;;
      ;; **It is the `cursor' face's `:background`**, which is what a
      ;; theme sets: black on a light frame, white on a dark one, and
      ;; whatever a theme names in between. Emacs reaches it through the
      ;; `cursor-color` frame parameter (`xfaces.c` turns a change of the
      ;; face's background into that parameter and `x_set_cursor_color`
      ;; turns the parameter back into the pixel); this tree has no frame
      ;; parameters to wait for the end of a redisplay in, so the face is
      ;; read where the pixel is used.
      ;;
      ;; The C's two adjustments are kept: a cursor the colour of the
      ;; frame's own background is replaced by the mouse pointer's colour
      ;; (`x->mouse_pixel`), so a cursor can never be invisible, and a
      ;; missing answer falls back the same way.
      ;;
      ;; **What it used to be was black, always**, on the reasoning that
      ;; black is Emacs's default - true of a light frame, and the reason
      ;; every dark theme drew a cursor nobody could see.
      ;;--------------------------------------------------------------
      (let* ((bg (frame-background-colour frame))
             (pixel (or (and frame
                             (colour->rgb (face-attribute 'cursor ':background
                                                          frame)))
                        (list 0.0 0.0 0.0))))
        (if (equal? pixel bg)
            (let ((mouse (and frame
                              (colour->rgb (face-attribute 'mouse ':background
                                                           frame)))))
              (if (and mouse (not (equal? mouse bg))) mouse bg))
            pixel)))

    (define (cursor-ink-colour token frame)
      ;; The colour the glyph *under* the cursor is redrawn in. Emacs
      ;; draws a filled-box cursor by redrawing the glyph - "so that the
      ;; text inside the cursor stays visible" - with the face's own
      ;; background as the ink (`x_set_cursor_gc' sets `xgcv.foreground =
      ;; s->face->background'), or, for the default face, with the
      ;; frame's background (`x_set_cursor_color`'s
      ;; `cursor_foreground_pixel', which is `FRAME_BACKGROUND_PIXEL'
      ;; unless `x-cursor-fore-pixel' names another).
      ;;
      ;; **The fallback was white, not the frame's background**, so a
      ;; themed dark frame redrew the glyph under the cursor in white
      ;; whatever the theme's background was.
      ;;--------------------------------------------------------------
      (or (face-token-background token) (frame-background-colour frame)))

    (define-method (draw-window-cursor! (d <pgtk-display>) row column cells
                                        type width text token)
      ;; The cursor at the cell, in the shape TYPE.
      ;;
      ;; A *filled box* is not a black rectangle painted over the text -
      ;; that is what it used to be here, and it hid the character under
      ;; the cursor. Emacs fills the box and then redraws the glyph in
      ;; the ink colour (`draw_phys_cursor_glyph' with `DRAW_CURSOR'), so
      ;; the character stays readable. CELLS is how many cells the glyph
      ;; under the cursor takes, which is what the box has to cover.
      ;;
      ;; The box's rectangle is in cells because this display's grid is;
      ;; a bar's WIDTH is in *pixels*, as Emacs's is - its default of 2
      ;; is two pixels of a real font, not two cells.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d)))
        (when cr
          ;; **ROW is a pixel y and COLUMN a cell x.** The redisplay
          ;; hands the cursor the same coordinates it hands
          ;; `write-glyphs!' - a pixel y from its own row walk, which is
          ;; `w->cursor.y' in the C - and this used to multiply it by the
          ;; cell height a second time (`cell-y'): a cursor on row 3 of a
          ;; 20-pixel cell landed at 1200 pixels, below the document.
          ;; Chris, on the font-resizing editor: "it goes down a dozen
          ;; lines to an empty square, but the cursor flashes /" - the
          ;; glyph was right, the place was not. X stays a cell, the
          ;; horizontal pitch being one per frame, as in the run draw.
          (let ((left (cell-x column))
                (top row)
                (box-w (* *cell-width* (max 1 cells))))
            (let ((frame (pgtk-frame-for d)))
              (case type
                ((no-cursor) #t)
                ((filled-box-cursor)
                 (apply cairo-set-source-rgb cr (cursor-box-colour frame))
                 (cairo-rectangle cr left top box-w *cell-height*)
                 (cairo-fill cr)
                 ;; the glyph again, in the ink colour, so it is visible
                 (apply cairo-set-source-rgb cr (cursor-ink-colour token frame))
                 (pgtk-show-text! d text left (+ top *font-ascent*)))
                ((hollow-box-cursor)
                 (apply cairo-set-source-rgb cr (cursor-box-colour frame))
                 (cairo-set-line-width cr 1)
                 (cairo-rectangle cr (+ left 0.5) (+ top 0.5)
                                  (- box-w 1) (- *cell-height* 1))
                 (cairo-stroke cr))
                ((bar-cursor)
                 (apply cairo-set-source-rgb cr (cursor-box-colour frame))
                 (cairo-rectangle cr left top (max 1 width) *cell-height*)
                 (cairo-fill cr))
                ((hbar-cursor)
                 ;; the bar sits at the foot of the cell, as Emacs's does
                 (apply cairo-set-source-rgb cr (cursor-box-colour frame))
                 (cairo-rectangle cr left (- (+ top *cell-height*)
                                             (max 1 width))
                                  box-w (max 1 width))
                 (cairo-fill cr))
                (else #t)))))))

    (define-method (erase-window-cursor! (d <pgtk-display>) row column cells
                                        text token)
      ;; Put the glyph at the old cursor position back: GNU Emacs's
      ;; `erase_phys_cursor`'s last act, `draw_phys_cursor_glyph (w,
      ;; cursor_row, hl)` - the glyph at the *old* cursor position drawn
      ;; back in its own face. A box or bar cursor is painted over the
      ;; row, so the character under it is in the surface again only if
      ;; this puts it there: the row the cursor sits on is usually one
      ;; the diff did not select.
      ;;--------------------------------------------------------------
      (let ((cr (pgtk-cr d)))
        (when cr
          (let* ((left (cell-x column))
                 (top row)
                 (box-w (* *cell-width* (max 1 cells))))
            (apply cairo-set-source-rgb
                   cr
                   (or (face-token-background token)
                       (colour->rgb (face-attribute 'default ':background))
                       (list 1.0 1.0 1.0)))
            (cairo-rectangle cr left top box-w *cell-height*)
            (cairo-fill cr)
            ;; and the glyph in its own colour, which is what
            ;; `draw_phys_cursor_glyph` ends by doing
            (when (and text (> (string-length text) 0))
              (apply cairo-set-source-rgb
                     cr
                     (or (face-token-foreground token) (list 0.0 0.0 0.0)))
              (pgtk-show-text! d text left (+ top *font-ascent*)))))))

    (define (pgtk-present! d gtk-cr)
      ;; Paint what we have drawn into the context Gtk handed us. This is
      ;; where the picture is put on the screen, at the moment Gtk asks
      ;; for it, so there is no snapshot waiting to go stale and nothing
      ;; for Gtk to scale - it is our pixels, at their own size, drawn by
      ;; us.
      ;;
      ;; The context is Gtk's, wrapped by guile-gi; guile-cairo cannot use
      ;; another library's wrapper, so the pointer is read out of it and
      ;; wrapped again as a guile-cairo context.
      ;;--------------------------------------------------------------
      (let ((surface (pgtk-surface d))
            (cr (cairo-pointer->context (slot-ref gtk-cr 'value))))
        (when surface
          (cairo-set-source-surface cr surface 0 0)
          (cairo-paint cr))))

    (define-method (flush-display! (d <pgtk-display>))
      ;; What has been drawn becomes visible when Gtk next asks us to
      ;; paint: there is no buffer to hand over any more.
      ;;
      ;; **The menu bar is rebuilt here**, which is where GNU Emacs's
      ;; `redisplay_window` reaches `set_frame_menubar` from
      ;; (`xdisp.c:14489`): once per redisplay, after the frame's text,
      ;; because the bar is part of what the frame shows and the hook
      ;; that changes it runs during the same redisplay.
      ;;--------------------------------------------------------------
      (pgtk-set-frame-menubar d)
      (let ((area (pgtk-area d)))
        (when area (gtk-widget-queue-draw (pgtk-widget-pointer area)))))

    (define (pgtk-write-screenshot! d path)
      ;; Write what the display is showing to PATH as a PNG.
      ;;--------------------------------------------------------------
      (let ((surface (pgtk-surface d)))
        (when surface
          (cairo-surface-flush surface)
          (cairo-surface-write-to-png surface path))))

    (define-method (suspend-display! (d <pgtk-display>))
      ;; There is no SIGTSTP meaning for a window; hiding it is the
      ;; nearest thing, and leaves the editor able to be stopped.
      ;;--------------------------------------------------------------
      (let ((w (pgtk-window d)))
        (when w (widget:hide w))))

    (define-method (resume-display! (d <pgtk-display>))
      (let ((w (pgtk-window d)))
        (when w (widget:show-all w))))

    ;;----------------------------------------------------------------
    ;; Opening the display
    ;;------------------------------------------------------------------

    (define (initialize-pgtk-faces! d)
      ;; Tell the face machinery what this display can draw, then
      ;; recompute the specs against it, as `with-terminal' does.
      ;;
      ;; Each of the four is the frame parameter GNU Emacs's pgtk backend
      ;; sets, and each is a *separate* question - a face spec tests them
      ;; in different conjuncts, so getting one wrong silently picks a
      ;; branch written for another kind of display:
      ;;
      ;;   * `window-system' is `pgtk' - `pgtk_create_frame' sets it, as
      ;;     `xfns.c' sets `x'. It is what a spec's `(type tty)' branch is
      ;;     tested against, so leaving it #f makes every tty branch match
      ;;     on a graphical frame: `header-line' then comes out underlined
      ;;     and not inverse-video, which is a terminal's answer.
      ;;   * `display-type' is `color', which is what `pgtkfns.c:2781'
      ;;     sets explicitly - NOT the window system's name. It is what a
      ;;     `(class color)' branch is tested against, so setting it to
      ;;     `pgtk' makes every colour branch fail and drops the region to
      ;;     the spec's last-resort `(#t :background "gray")' instead of
      ;;     `lightgoldenrod2'.
      ;;   * `display-color-cells' is the display's own answer.
      ;;   * `frame-background-mode' is the frame's own answer, computed
      ;;     by `frame-set-background-mode' from the default face's
      ;;     background - which at initialization is the stock white -
      ;;     and is what a `(background dark)' branch is tested against.
      ;;     It used to be hardcoded `light', which is why a themed
      ;;     black frame read every light branch and `Find file:' drew
      ;;     `medium blue' on black.
      ;;--------------------------------------------------------------
      (*window-system* 'pgtk)
      (*display-color-cells* (display-color-cells d))
      (*display-type* 'color)
      (for-each face-spec-recalc (face-list))
      ;; **The mode is computed and the faces recalculated in one
      ;; place**, which is `x_create_frame''s `(frame-set-background-
      ;; mode frame t)' after its own face initialization
      ;; (`xfaces.c:2243' via `face-set-after-frame-default'). The
      ;; hardcode this replaces was an initialization of the parameter
      ;; and a recalculation of nothing.
      (frame-set-background-mode #f)
      ;; The `default' face has just been reset, which takes its
      ;; `:height' with it - so the font is opened again from what is
      ;; left, exactly as `face-set-after-frame-default' ends by
      ;; realizing the default face. It has to come after the reset:
      ;; before it, the recalculation would throw the height away.
      (pgtk-ensure-font!))

    (define *pgtk-displays* (make-parameter '()))
    ;; ^ The windows this process has open, newest first. Emacs keeps the
    ;; same information on its terminal - `tty->top_frame' and the frame
    ;; list; here it is the *backend* that knows a window exists, and the
    ;; input path needs it to find which frame an event belongs to. A
    ;; frame points at its display through `frame-output', which is the
    ;; direction redisplay uses; this is the other one.

    ;;----------------------------------------------------------------
    ;; The menu bar's theme
    ;;----------------------------------------------------------------
    ;;
    ;; **This is a deliberate departure from GNU Emacs.** Emacs's `menu`
    ;; face is "the font and colors of the menu bar and popup menus", but
    ;; its `(type x-toolkit)` branch is *empty* (`faces.el:3035`) - a GTK
    ;; frame's menus take the toolkit theme and no face colours them at
    ;; all. What is wanted here instead is the mode line's own colours, so
    ;; the bar and its submenus read as part of the editor rather than as
    ;; part of the desktop.
    ;;
    ;; The colours come from the `mode-line` face - the *active* window's,
    ;; which is the one the selected window draws - and they are applied
    ;; with a CSS provider carrying two class-scoped rules, so nothing
    ;; outside the bar is affected.

    (define *menubar-css-priority*
      ;; `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` (`gtkstyleprovider.h`):
      ;; above the theme's settings and below the user's own.
      600)

    (define (rgb->css rgb)
      ;; `(R G B)' in cairo's 0..1 as `#rrggbb', or #f.
      ;;--------------------------------------------------------------
      (and rgb
           (apply string-append
                  "#"
                  (map (lambda (c)
                         (let ((n (inexact->exact (round (* c 255)))))
                           (string-append (if (< n 16) "0" "")
                                          (number->string n 16))))
                       rgb))))

    (define (colour->css value)
      ;; A face attribute value as `#rrggbb`, or #f when it names no
      ;; colour - `colour->rgb` does the lookup, this only spells it.
      ;;--------------------------------------------------------------
      (rgb->css (colour->rgb value)))

    (define (pgtk-menubar-theme-colours frame)
      ;; `(FOREGROUND . BACKGROUND)' for the bar, from the `mode-line`
      ;; face of the frame's *active* window.
      ;;
      ;; A face that names no colour falls back the way the mode line
      ;; itself does: the default face's foreground and the frame's
      ;; background (`frame-background-colour`, which is the `default`
      ;; face's own `:background`).
      ;;--------------------------------------------------------------
      (cons (or (colour->css (face-attribute 'mode-line ':foreground frame))
                (colour->css (face-attribute 'default ':foreground frame))
                "#000000")
            (or (colour->css (face-attribute 'mode-line ':background frame))
                (rgb->css (frame-background-colour frame))
                "#ffffff")))

    (define (pgtk-menubar-css-text fg bg)
      ;; The two rules. A `:hover` inverts the pair, which is the mode
      ;; line's own emphasis seen the way Emacs's `menu` face says a menu
      ;; is emphasised on a tty - `:inverse-video t` - and keeps a
      ;; hovered item distinguishable without inventing a third colour.
      ;;--------------------------------------------------------------
      (string-append
       "menubar.schemacs-menubar { background-color: " bg ";"
       " background-image: none; color: " fg "; border: none; }\n"
       "menubar.schemacs-menubar > menuitem { background-color: " bg ";"
       " background-image: none; color: " fg "; border: none; }\n"
       "menubar.schemacs-menubar > menuitem:hover { background-color: " fg
       "; color: " bg "; }\n"
       "menu.schemacs-menu { background-color: " bg "; border-color: " fg
       "; }\n"
       "menu.schemacs-menu > menuitem { background-color: " bg ";"
       " background-image: none; color: " fg "; }\n"
       "menu.schemacs-menu > menuitem:hover,"
       " menu.schemacs-menu > menuitem:selected {"
       " background-color: " fg "; color: " bg "; }\n"
       "menu.schemacs-menu > separator { background-color: " fg "; }\n"))

    (define (pgtk-menubar-provider d)
      ;; The display's CSS provider, made the first time it is needed.
      ;;--------------------------------------------------------------
      (or (pgtk-menubar-css d)
          (let ((provider (css-provider:new)))
            (set! (pgtk-menubar-css d) provider)
            provider)))

    (define (pgtk-style-menu-widget! d w bar?)
      ;; Give W the class the rules are written against, and the provider
      ;; that carries them. Adding the provider to the widget's own
      ;; style context is what reaches a *popup* menu: it is a toplevel
      ;; window of its own, so a provider on the frame's widget would not
      ;; follow it.
      ;;--------------------------------------------------------------
      (let ((ctx (widget:get-style-context w)))
        (style-context:add-class ctx
                                 (if bar? "schemacs-menubar" "schemacs-menu"))
        (style-context:add-provider ctx (pgtk-menubar-provider d)
                                    *menubar-css-priority*)))

    (define (pgtk-theme-menubar! d)
      ;; Load the bar's colours, if they have changed since the last
      ;; redisplay. Cheap when they have not: two face lookups and an
      ;; `equal?`.
      ;;--------------------------------------------------------------
      (let ((frame (pgtk-frame-for d)))
        (when frame
          (let ((colours (pgtk-menubar-theme-colours frame)))
            (unless (equal? colours (pgtk-menubar-theme d))
              (set! (pgtk-menubar-theme d) colours)
              ;; **Two arguments, and the data is a *bytevector*.**
              ;; guile-gi maps `gtk_css_provider_load_from_data`'s
              ;; `(const gchar *data, gssize length)` to one bytevector
              ;; argument - a string is refused with "Wrong type
              ;; (expecting bytevector)" - and takes the length from it.
              (css-provider:load-from-data? (pgtk-menubar-provider d)
                                            (string->utf8
                                             (pgtk-menubar-css-text
                                              (car colours) (cdr colours)))))))))

    (define (pgtk-open-window columns rows)
      ;; Make one GTK window with a drawing area and wire its signals, and
      ;; answer the display that draws into it. The counterpart of one
      ;; `x_window (f)', which is what Emacs's `frame-creation-function'
      ;; method for pgtk ends up calling per frame.
      ;;
      ;; **The widgets are the frame's**, as Emacs's are -
      ;; `FRAME_GTK_OUTER_WIDGET (f) = wtop' and `FRAME_GTK_WIDGET (f) =
      ;; wfixed' (`gtkutil.c:1670') are fields of the frame, not of a
      ;; terminal - so FRAME is an argument here and not ambient state.
      ;; The display returned becomes that frame's `frame-output' and
      ;; nothing else's.
      ;;
      ;; **Every handler closes over its OWN `d', and that is the point of
      ;; the function.** While there was only `with-gtk-display' the
      ;; handlers could close over the one display and nothing could tell
      ;; them apart; with two windows each must queue into and repaint its
      ;; own.
      ;;
      ;; The title is set separately, by `pgtk-title-frame!', because it
      ;; is the *frame's* name and the frame is made after its display is
      ;; (a frame's `output' is a constructor argument here). Emacs gets
      ;; the other order - `make_frame' names the frame, then `x_window
      ;; (f)' titles the window from it (`gtkutil.c:1656-1663') - and this
      ;; arrives at the same place one call later.
      ;;--------------------------------------------------------------
      (let* ((width (* columns *cell-width*))
             (height (* rows *cell-height*))
             (win (make <GtkWindow>))
             (vbox (make <GtkBox>))
             (bar (make <GtkMenuBar>))
             (area (make <GtkDrawingArea>))
             (d (make <pgtk-display>)))
        (set! (pgtk-window d) win)
        (set! (pgtk-vbox d) vbox)
        (set! (pgtk-menubar d) bar)
        ;; The bar's theme is the mode line's colours; this is the class
        ;; its CSS is written against (`pgtk-theme-menubar!` loads it).
        (pgtk-style-menu-widget! d bar #t)
        (set! (pgtk-area d) area)
        (set! (pgtk-columns d) columns)
        (set! (pgtk-rows d) rows)
        ;; **The menu bar is above the drawing area, as Gtk wants it** -
        ;; GNU Emacs's `xg_create_frame_widgets` puts the menu bar and the
        ;; edit widget in a vertical box inside the toplevel
        ;; (`gtkutil.c:1800`), and `FRAME_GTK_WIDGET` is the edit widget
        ;; alone. The bar's size request is `1 x -1` for the reason the C
        ;; gives: a width of 1 keeps an empty bar from forcing a small
        ;; frame wider, and -1 takes its natural height.
        (orientable:set-orientation vbox
                                   (symbol->enum <GtkOrientation> 'vertical))
        (widget:set-size-request bar 1 -1)
        (box:pack-start vbox bar #f #f 0)
        (box:pack-start vbox area #t #t 0)
        ;; Keys arrive here and go on the queue the read drains. The
        ;; event is queued raw and decoded by the read. A toplevel window
        ;; receives key events without being told to ask for them;
        ;; setting an event mask on one crashes GTK.
        ;; A key is *queued* and the read that is waiting for it is woken
        ;; (`pgtk-enqueue!'). It is not dispatched from here even though
        ;; Gtk now owns the loop: the editor's command loop is the thing
        ;; that runs commands, it is reentrant, and it is *inside* a read
        ;; at every moment it could act - including the outermost one,
        ;; which nests in `gtk_main' like every other wait. Queuing is
        ;; what GNU Emacs's `read_char' finds when it looks at the
        ;; keyboard, and a key that arrives while a command is running is
        ;; simply waiting for the next read.
        (connect win (make <signal> #:name "key-press-event")
                 (lambda (w e)
                   (pgtk-enqueue! d (pgtk-key-item d e))
                   #t))
        ;; **The press and the release, on the drawing area.** A click
        ;; lands on the widget that draws, and that area IS the frame's
        ;; grid: its top-left corner is cell (0, 0), so an event's own
        ;; coordinates are the frame's. Both buttons are queued *tagged*,
        ;; because a Gdk button event must not be asked for a keysym -
        ;; `pgtk-item->event' tells the two apart by the tag.
        ;;
        ;; The press is what `mouse.el' binds: `[down-mouse-1]' starts a
        ;; drag, and the release is what ends one. A click is a drag of
        ;; no distance, which is why the release is queued at all.
        ;; **A child widget has to ask for the events; a toplevel must
        ;; not.** Gtk hands a button press to the widget under the
        ;; pointer only if that widget's window *selected* it, and this
        ;; area selected nothing - so the press went to the toplevel,
        ;; whose handler is the key one and knows nothing about buttons.
        ;; **The masks are 256 and 512, from Gdk's own enum** -
        ;; `GDK_BUTTON_PRESS_MASK = 1 << 8' and `GDK_BUTTON_RELEASE_MASK
        ;; = 1 << 9' (`gdktypes.h:436'). `1 << 2' and `1 << 3', which
        ;; stood here first, are `GDK_POINTER_MOTION_MASK' and its hint -
        ;; so the area asked for *motion* and the press went to whatever
        ;; else was listening, which is why a click did nothing at all
        ;; and, worse, why nothing at all was the symptom: no handler
        ;; ran, so there was no error to see. (The warning about setting
        ;; an event mask two hundred lines above is about the
        ;; *toplevel*, where it crashes Gtk.)
        ;; 768 is press|release; 4 more is `GDK_POINTER_MOTION_MASK'
        ;; (`1 << 2'), which the drag needs to see the pointer move
        ;; with the button held.
        (widget:add-events area 772)
        (connect area (make <signal> #:name "button-press-event")
                 (lambda (w e)
                   ;; The press's own position is kept, not just queued:
                   ;; the release is a *different event* when the pointer
                   ;; has moved, and that event carries both positions.
                   (set! (pgtk-press-cell d) (pgtk-event-cell e))
                   (set! (pgtk-press-posn d) (pgtk-posn-for d e))
                   (pgtk-enqueue! d (cons 'button-press e))
                   #t))
        (connect area (make <signal> #:name "button-release-event")
                 (lambda (w e)
                   ;; Emacs's test (`keyboard.c:6638') is whether the
                   ;; pointer has moved since the press by more than
                   ;; `double_click_fuzz', a few pixels. Measured in
                   ;; *cells* here, where a cell is 9 by 18 pixels and
                   ;; the fuzz is less than one, that is "a different
                   ;; cell" - named rather than guessed at.
                   (let ((moved? (not (equal? (pgtk-event-cell e)
                                              (pgtk-press-cell d)))))
                     (pgtk-enqueue! d
                                    (cons (if moved? 'drag-release
                                              'button-release)
                                          e)))
                   #t))
        ;; The pointer moving: GNU Emacs's `motion_notify_event'
        ;; (`pgtkterm.c:5943'). **It does not make a `mouse-movement'
        ;; event.** It asks `note_mouse_movement' whether the pointer has
        ;; left the glyph it was on, and if it has, records that it moved;
        ;; the event is made once, when that marker is delivered
        ;; (`pgtk-mouse-movement-event'), from the pointer's position at
        ;; that moment. A queued
        ;; event per Gtk report is what made a drag past the edge of the
        ;; window scroll a step per report and stop when the pointer
        ;; stopped: the scroll loop ends on any input at all.
        (connect area (make <signal> #:name "motion-notify-event")
                 (lambda (w e)
                   ;; **Only while a drag is being tracked.** Emacs's
                   ;; `track-mouse' decides whether motion is noticed at
                   ;; all here; the alternative is Emacs's own, a
                   ;; `[mouse-movement]' binding in the global map that
                   ;; ignores the event, which this tree does not have and
                   ;; does not want yet (mouse-face and the help echo are
                   ;; what read it there).
                   (if track-mouse
                       (let ((cell (pgtk-event-cell e)))
                         (note-mouse-movement d (car cell) (cdr cell)))
                       #f)
                   #t))
        ;; A size is REQUESTED, not set as a default. `set-default-size'
        ;; pins the window: Gtk then never accepts the size a compositor
        ;; tiles it to, and the compositor - handed a window it cannot
        ;; resize - scales the buffer instead, which is what stretched
        ;; text was. `window:resize' asks, so the window still starts a
        ;; sensible shape but follows whatever it is given.
        (set! (window:resizable win) #t)
        (window:resize win width height)
        ;; The allocation is read here and *kept*, because this is where
        ;; the size is known for free: `widget:get-allocated-*' costs
        ;; 3.2 ms apiece, and asking during redisplay asked again on
        ;; every frame for an answer that changes only when this signal
        ;; fires. `pgtk-allocation' answers from what is recorded here.
        ;;
        ;; **The drawing area's, not the window's.** The window now holds
        ;; a box with the menu bar above this area, so the window is
        ;; taller than the grid by the bar. What the display draws at,
        ;; and what `screen-size' counts cells in, is the area's
        ;; allocation - `FRAME_PIXEL_HEIGHT` in Emacs is the window's,
        ;; with the menu bar's rows subtracted (`frame.c`), and the
        ;; subtraction is what the box does instead.
        (connect area (make <signal> #:name "size-allocate")
                 (lambda (w rect)
                   (let ((aw (widget:get-allocated-width w))
                         (ah (widget:get-allocated-height w)))
                     (set! (pgtk-allocated-size d) (cons aw ah))
                     (pgtk-resize! d aw ah)
                     (pgtk-grow-by-menubar! d))
                   #t))
        ;; Draw again once the window has actually been mapped and
        ;; allocated: the first frame is drawn before that, and if the
        ;; window ends up a different size the editor should draw it
        ;; again at the size it really is.
        (connect win (make <signal> #:name "map-event")
                 (lambda (w e) (pgtk-enqueue! d 'resize) #f))
        ;; The window's focus, which the editor asks about twice: a
        ;; blinking cursor only blinks while the frame is focused - GNU
        ;; Emacs's `blink-cursor--should-blink' wants "any focused
        ;; non-TTY frame" - and an unfocused frame's cursor is drawn
        ;; hollow, as `get_window_cursor_type' does for a frame that is
        ;; not the display's highlight frame. Gtk reports both; nothing
        ;; else has to be asked.
        ;; A focus event can arrive while the window is being destroyed -
        ;; the teardown takes the focus away - and by then there is no
        ;; frame to show a cursor in. Nothing to do, and doing it anyway
        ;; is what took the editor down with a `struct-vtable' error on
        ;; `#f'.
        ;; The window system's focus events, which Emacs delivers as the
        ;; keys `(focus-in (FRAME))' and `(focus-out (FRAME))'
        ;; (`keyboard.c:6281') - and whose handlers are
        ;; `handle-focus-in'/`handle-focus-out' in `special-event-map'
        ;; (`keyboard.c:14620'). They are dispatched like any key, so a
        ;; user can rebind them, which is why they are not special-cased
        ;; here.
        (connect win (make <signal> #:name "focus-in-event")
                 (lambda (w e)
                   ;; **Select the frame this window draws**, which is what
                   ;; makes typing in a second window work: Gtk delivers
                   ;; `focus-in-event' before the keys addressed to the
                   ;; newly focused widget, so the command that follows
                   ;; acts on the right frame. Emacs does the same thing -
                   ;; its `focus-in-event' ends in
                   ;; `select-frame-set-input-focus' (`frame.el:1264').
                   (let ((f (pgtk-frame-for d)))
                     (when f (select-frame f)))
                   (when (*current-frame*) (pgtk-enqueue! d 'focus-in))
                   #f))
        ;; The window manager's request to close the frame - the X
        ;; client message `WM_DELETE_WINDOW', which Gtk delivers as
        ;; `delete-event'. Emacs's `delete_event' queues the event and
        ;; returns TRUE, so Gtk does not destroy the window: whether to
        ;; save and exit is the command loop's decision, not the
        ;; compositor's. Not answering this is what left a process with
        ;; no window running when the frame was closed.
        (connect win (make <signal> #:name "delete-event")
                 (lambda (w e)
                   (pgtk-enqueue! d 'delete-frame)
                   ;; TRUE: Gtk must not destroy the window
                   #t))
        (connect win (make <signal> #:name "focus-out-event")
                 (lambda (w e)
                   (when (*current-frame*) (pgtk-enqueue! d 'focus-out))
                   #f))
        ;; The area must not dictate the window's size: a window's
        ;; minimum size comes from its child, so a size request as large
        ;; as the window would pin it there. A one-cell request plus
        ;; expand lets the window be any size and gives the drawing area
        ;; the whole of it.
        ;;--------------------------------------------------------------
        (widget:set-size-request area 1 1)
        (set! (widget:hexpand area) #t)
        (set! (widget:vexpand area) #t)
        ;; Every repaint Gtk asks for is answered by painting our own
        ;; drawing into the context it gives us, at its size.
        (connect area (make <signal> #:name "draw")
                 (lambda (w cr) (pgtk-present! d cr) #t))
        ;; The toplevel holds the box, and the box holds the bar and the
        ;; area - `xg_create_frame_widgets`' arrangement.
        (container:add win vbox)
        ;; Key events go to the focused widget. A drawing area does not
        ;; take focus, so the window itself must - otherwise a keystroke
        ;; has nowhere to be delivered and the editor silently never
        ;; hears from the keyboard.
        (set! (widget:can-focus win) #t)
        (widget:show-all win)
        (widget:grab-focus win)
        (*pgtk-displays* (cons d (*pgtk-displays*)))
        d))

    ;;----------------------------------------------------------------
    ;; The menu bar - gtkutil.c's widget builders over menu.c's tree
    ;;----------------------------------------------------------------
    ;;
    ;; GNU Emacs builds the bar in three steps that this keeps apart the
    ;; same way: `set_frame_menubar` fills `menu_items` from
    ;; `menu_bar_items` and digests it into a `widget_value` tree
    ;; (`menu.c`, all of it in `(schemacs editor menu)`), `create_menus`
    ;; turns that tree into Gtk widgets (`gtkutil.c:3405`), and
    ;; `menubar_selection_callback` turns a click back into a key
    ;; sequence (`menu.c`'s `find_and_call_menu_selection`).

    (define (pgtk-hold-widget! d w)
      ;; Keep W's proxy alive for as long as the display lives.
      ;;
      ;; **This is not tidiness; without it the bar dies at the next
      ;; GC.** A guile-gi proxy owns its GObject through a toggle
      ;; reference, so when the proxy is collected the object goes with
      ;; it *even though Gtk's container holds it* - measured under
      ;; broadway: a bar that built and activated correctly lost its
      ;; widgets to `instance with invalid (NULL) class pointer` at the
      ;; first forced collection. Emacs has no proxy, so it has no such
      ;; rule; the nearest thing here is to hold them, exactly as
      ;; `pgtk-window`/`pgtk-area` are held (and for the same reason).
      ;;
      ;; A rebuild builds *new* widgets and leaves the old ones held, so
      ;; a proxy is never released while an object is alive.
      ;;--------------------------------------------------------------
      (set! (pgtk-menubar-held d) (cons w (pgtk-menubar-held d)))
      w)

    (define (pgtk-widget-for-menu-item d label key)
      ;; gtkutil.c's `make_widget_for_menu_item` (`:3222`): a horizontal
      ;; box with the label and, right-aligned, the key's description.
      ;;--------------------------------------------------------------
      (let ((wbox (pgtk-hold-widget! d (make <GtkBox>)))
            (wlbl (pgtk-hold-widget! d (make <GtkLabel>)))
            (wkey (pgtk-hold-widget! d (make <GtkLabel>))))
        (box:set-homogeneous wbox #f)
        (label:set-text wlbl label)
        (label:set-text wkey key)
        (widget:set-halign wlbl (symbol->enum <GtkAlign> 'start))
        (widget:set-valign wlbl (symbol->enum <GtkAlign> 'center))
        (widget:set-halign wkey (symbol->enum <GtkAlign> 'start))
        (widget:set-valign wkey (symbol->enum <GtkAlign> 'center))
        (box:pack-start wbox wlbl #t #t 0)
        (box:pack-start wbox wkey #f #f 0)
        wbox))

    (define (pgtk-make-menu-item d label key item group)
      ;; gtkutil.c's `make_menu_item` (`:3256`): the widget for one item,
      ;; without its submenu. Answers `(WIDGET . GROUP)`, GROUP being the
      ;; radio item a following radio joins or `#f`.
      ;;--------------------------------------------------------------
      (let* ((wtoadd (and key (pgtk-widget-for-menu-item d label key)))
             (type (widget-value-button-type item))
             (w (cond
                 ((eq? type 'toggle)
                  (let ((w (pgtk-hold-widget! d (make <GtkCheckMenuItem>))))
                    (unless wtoadd (menu-item:set-label w label))
                    (check-menu-item:set-active w
                                                (widget-value-selected? item))
                    w))
                 ((eq? type 'radio)
                  (let ((w (pgtk-hold-widget! d (make <GtkRadioMenuItem>))))
                    (unless wtoadd (menu-item:set-label w label))
                    ;; `gtk_radio_menu_item_new (group)` - joining a group
                    ;; that already has a first item is the same call.
                    (when group (radio-menu-item:join-group w group))
                    (when (widget-value-selected? item)
                      (check-menu-item:set-active w #t))
                    w))
                 (else
                  (let ((w (pgtk-hold-widget! d (make <GtkMenuItem>))))
                    (unless wtoadd (menu-item:set-label w label))
                    w)))))
        (when wtoadd (container:add w wtoadd))
        (unless (widget-value-enabled? item) (widget:set-sensitive w #f))
        (when (widget-value-help item)
          (widget:set-tooltip-text w (widget-value-help item)))
        (cons w (if (eq? type 'radio) (or group w) #f))))

    (define (pgtk-create-one-menuitem d item select-proc group)
      ;; gtkutil.c's `xg_create_one_menuitem` (`:3317`): the widget, its
      ;; tooltip, and the activate signal for a command.
      ;;--------------------------------------------------------------
      (let* ((label (or (widget-value-name item) " "))
             (key (and (string? (widget-value-key item))
                       (widget-value-key item)))
             (made (pgtk-make-menu-item d label key item group))
             (w (car made))
             (type (widget-value-button-type item)))
        ;; A submenu item has no command of its own; only a final item
        ;; does, which is the C's `item->call_data && !item->contents`.
        (when (and select-proc
                   (widget-value-call-data item)
                   (not (widget-value-contents item)))
          (connect w (make <signal> #:name "activate")
                   (lambda (widget)
                     ;; **A radio's deactivation emits this signal too**,
                     ;; which is `menubar_selection_callback`'s own guard
                     ;; (`xmenu.c:808`): without it the item being left
                     ;; would run its command as well.
                     (when (or (not (eq? type 'radio))
                               (check-menu-item:active widget))
                       (select-proc (widget-value-call-data item)))
                     #f)))
        (cons w (cdr made))))

    (define (pgtk-create-menus data d select-proc topmenu menu-bar-p)
      ;; gtkutil.c's `create_menus` (`:3405`): one menu shell for DATA,
      ;; recursing into every item that has contents. TOPMENU is an
      ;; existing shell to append to, or `#f` to make one.
      ;;--------------------------------------------------------------
      (let ((wmenu (or topmenu
                       (pgtk-hold-widget! d (if menu-bar-p
                                                (make <GtkMenuBar>)
                                                (make <GtkMenu>))))))
        ;; A *submenu* takes the bar's colours too; the bar itself got its
        ;; class when the window was made (`pgtk-open-window`).
        (unless (or topmenu menu-bar-p)
          (pgtk-style-menu-widget! d wmenu #f))
        (let loop ((item data) (group #f))
          (cond
           ((not item) wmenu)
           ((menu-separator-name? (widget-value-name item))
            (menu-shell:append wmenu
                               (pgtk-hold-widget! d
                                                  (make <GtkSeparatorMenuItem>)))
            (loop (widget-value-next item) #f))
           (else
            (let* ((made (pgtk-create-one-menuitem d item select-proc group))
                   (w (car made)))
              ;; "Create a possibly empty submenu for menu bar items,
              ;; since some themes don't highlight items correctly
              ;; without it" - the C's own note.
              (when (or (widget-value-contents item) menu-bar-p)
                (menu-item:set-submenu
                 w (pgtk-create-menus (widget-value-contents item) d
                                      select-proc #f #f)))
              (menu-shell:append wmenu w)
              (loop (widget-value-next item) (cdr made))))))))


    ;;----------------------------------------------------------------
    ;; Popup menus - `pgtk_menu_show` (`pgtkmenu.c:588`)
    ;;----------------------------------------------------------------
    ;;
    ;; The other half of the menu machinery: a menu that is not part of
    ;; the bar - `x-popup-menu` from Lisp, `popup-menu`, a major mode's
    ;; context menu. Emacs builds a `widget_value` tree from
    ;; `menu_items`, turns it into a `GtkMenu`, pops it up at the given
    ;; place, and runs its own little event loop until an item is
    ;; activated or the menu is dismissed. The answer is the selected
    ;; item's *index* in `menu_items`, which is then walked back to the
    ;; entry - the key sequence, for a keymap menu - that `popup-menu`
    ;; looks up and runs.
    ;;--------------------------------------------------------------

    (define *pgtk-popup-selection* (make-parameter #f))
    (define *pgtk-popup-active* (make-parameter #f))
    ;; ^ `pgtkmenu.c`'s `menu_item_selection` and `popup_activated_flag`
    ;; (`:70`, `:74`). Parameters because that is this tree's spelling of
    ;; the C's statics.

    ;; `create_and_show_popup_menu`'s anchor gravity, `GDK_GRAVITY_NORTH_WEST`
    ;; (`gdktypes.h:703`): the rectangle's upper-left corner is where the
    ;; menu's upper-left corner goes.
    (define GDK-GRAVITY-NORTH-WEST 1)

    ;; `gtk_main_iteration` and the popup functions are called through
    ;; `dynamic-func`, the same way the selections at the end of this
    ;; file are: guile-gi's own `menu:popup-at-*` generics take a
    ;; `GdkRectangle` it made, and the rectangle here is a C struct.
    (define gtk-popup-lib (dynamic-link "libgtk-3.so.0"))

    (define (pgtk-popup-fn name ret args)
      (pointer->procedure ret (dynamic-func name gtk-popup-lib) args))

    (define gtk-main-iteration
      (pgtk-popup-fn "gtk_main_iteration" int '()))
    (define gtk-menu-popup-at-pointer
      (pgtk-popup-fn "gtk_menu_popup_at_pointer" void (list '* '*)))
    (define gtk-menu-popup-at-rect
      (pgtk-popup-fn "gtk_menu_popup_at_rect" void
                     (list '* '* '* int int '*)))
    (define gtk-widget-get-mapped
      (pgtk-popup-fn "gtk_widget_get_mapped" int (list '*)))
    (define gtk-widget-get-window
      (pgtk-popup-fn "gtk_widget_get_window" '* (list '*)))
    (define gtk-widget-destroy
      (pgtk-popup-fn "gtk_widget_destroy" void (list '*)))
    ;; **`widget:queue-draw` through the C function instead of the
    ;; binding.** It is the last call of every redisplay (`flush-display!`)
    ;; and guile-gi's route to it costs 3.6 ms per call on this machine -
    ;; measured in a live window, against 0.0003 ms for the C function
    ;; itself - so a keystroke paid 3.6 ms to ask for one repaint. Nothing
    ;; about the call is a marshalling problem: it takes the widget and
    ;; returns void, and the pointer `pgtk-widget-pointer' hands over is
    ;; the same one guile-gi's proxy holds. See `pgtk-set-frame-menubar`
    ;; for the other half of that keystroke.
    (define gtk-widget-queue-draw
      (pgtk-popup-fn "gtk_widget_queue_draw" void (list '*)))

    (define (pgtk-widget-pointer w)
      ;; guile-gi's proxy for a GObject is a `<GFundamental>`, whose
      ;; `value` slot is the pointer the C functions take - the same slot
      ;; `(gi oop)`'s own `type-peek-object` reads. Nothing else in
      ;; guile-gi hands it out, which is why this is here.
      ;;--------------------------------------------------------------
      (slot-ref w 'value))

    (define (pgtk-popup-build-tree flags title)
      ;; `pgtk_menu_show`'s tree loop (`pgtkmenu.c:616-771`): "Create a
      ;; tree of widget_value objects representing the panes and their
      ;; items."
      ;;
      ;; It is `digest_single_submenu` (`menu.c:619`) with the popup's
      ;; own rules: a pane becomes a submenu only when it has a name and
      ;; the menu is *not* a keymap menu, and the title is prepended with
      ;; two separators beneath it.
      ;;--------------------------------------------------------------
      (let* ((items (menu-items))
             (used (menu-items-used))
             (root (make-widget-value "menu" #f #t #f))
             (save-wv #f)
             (prev-wv #f)
             (first-pane #t)
             (submenu-stack '()))
        (set!widget-value-button-type root 'none)
        (let loop ((i 0))
          (when (< i used)
            (let ((slot (vector-ref items i)))
              (cond
               ;; A submenu opens.
               ((not slot)
                (set! submenu-stack (cons save-wv submenu-stack))
                (set! save-wv prev-wv)
                (set! prev-wv #f)
                (set! first-pane #t)
                (loop (+ i 1)))
               ;; A submenu closes.
               ((eq? slot 'lambda)
                (set! prev-wv save-wv)
                (set! save-wv (car submenu-stack))
                (set! submenu-stack (cdr submenu-stack))
                (set! first-pane #f)
                (loop (+ i 1)))
               ;; A pane inside a submenu is skipped.
               ((and (eq? slot #t) (pair? submenu-stack))
                (loop (+ i menu-items-pane-length)))
               ;; "Ignore a nil in the item list. It's meaningful only
               ;; for dialog boxes."
               ((eq? slot 'quote)
                (loop (+ i 1)))
               ;; A new pane.
               ((eq? slot #t)
                (let* ((pane-name (vector-ref items (+ i menu-items-pane-name)))
                       (pane-string (or pane-name "")))
                  ;; "If there is just one top-level pane, put all its
                  ;; items directly under the top-level menu."
                  (when (= 1 (menu-items-n-panes))
                    (set! pane-string ""))
                  ;; "If the pane has a meaningful name, make the pane a
                  ;; top-level menu item with its items as a submenu
                  ;; beneath it."
                  (if (and (eqv? 0 (logand flags MENU-KEYMAPS))
                           (not (string=? pane-string "")))
                      (let ((wv (make-widget-value pane-string #f #t #f)))
                        (if save-wv
                            (set!widget-value-next save-wv wv)
                            (set!widget-value-contents root wv))
                        (set!widget-value-button-type wv 'none)
                        (set! save-wv wv)
                        (set! prev-wv #f))
                      (when first-pane
                        (set! save-wv root)
                        (set! prev-wv #f)))
                  (set! first-pane #f)
                  (loop (+ i menu-items-pane-length))))
               ;; An item within the current pane.
               (else
                (let* ((item-name (vector-ref items (+ i menu-items-item-name)))
                       (enable (vector-ref items (+ i menu-items-item-enable)))
                       (descrip (vector-ref items
                                            (+ i menu-items-item-equiv-key)))
                       (def (vector-ref items (+ i menu-items-item-definition)))
                       (type (vector-ref items (+ i menu-items-item-type)))
                       (selected (vector-ref items
                                             (+ i menu-items-item-selected)))
                       (help (vector-ref items (+ i menu-items-item-help)))
                       (wv (make-widget-value item-name #f (not (not enable))
                                              (and (string? help) help))))
                  (if prev-wv
                      (set!widget-value-next prev-wv wv)
                      (when save-wv (set!widget-value-contents save-wv wv)))
                  (when (string? descrip)
                    (set!widget-value-key wv descrip))
                  ;; "If this item has a null value, make the call_data
                  ;; null so that it won't display a box when the mouse
                  ;; is on it."
                  (when def
                    (set!widget-value-call-data wv i))
                  (set!widget-value-button-type
                   wv (cond ((not type) 'none)
                            ((eq? type ':toggle) 'toggle)
                            ((eq? type ':radio) 'radio)
                            (else (error "bad button type" type))))
                  (set!widget-value-selected! wv (not (not selected)))
                  (set! prev-wv wv)
                  (loop (+ i menu-items-item-length))))))))
        ;; "Deal with the title, if it is non-nil."
        (when title
          (let ((sep1 (make-widget-value "--" #f #f #f))
                (sep2 (make-widget-value "--" #f #f #f))
                (wv-title (make-widget-value title #f #t #f)))
            (set!widget-value-next sep2 (widget-value-contents root))
            (set!widget-value-next sep1 sep2)
            (set!widget-value-button-type wv-title 'none)
            (set!widget-value-next wv-title sep1)
            (set!widget-value-contents root wv-title)))
        root))

    (define (pgtk-popup-deactivate . _)
      ;; `popup_deactivate_callback` (`pgtkmenu.c:105`): the menu was
      ;; dismissed - Escape, a click elsewhere - so the loop ends with no
      ;; selection.
      ;;--------------------------------------------------------------
      (*pgtk-popup-active* #f))

    (define (pgtk-popup-selected call-data)
      ;; `popup_selection_callback` (`pgtkmenu.c:117`): "Treat the
      ;; pointer as an integer. There's no problem as long as pointers
      ;; have enough bits to hold small integers."
      ;;--------------------------------------------------------------
      (*pgtk-popup-selection* call-data)
      (*pgtk-popup-active* #f))

    (define (pgtk-create-and-show-popup-menu d tree x y for-click)
      ;; `create_and_show_popup_menu` (`pgtkmenu.c:528`): build the menu,
      ;; show it at (X, Y) - or at the pointer when it was a click - and
      ;; "process events that apply to the menu" until it pops down.
      ;;--------------------------------------------------------------
      (let ((menu (pgtk-create-menus tree d pgtk-popup-selected #f #f)))
        (widget:show-all menu)
        ;; "The menu is canceled if it is unmapped" - the same
        ;; `popup_deactivate_callback` the C connects through
        ;; `xg_create_widget`.
        (connect menu (make <signal> #:name "deactivate")
                 (lambda (widget) (pgtk-popup-deactivate) #f))
        (let ((mp (pgtk-widget-pointer menu)))
          (if for-click
              (gtk-menu-popup-at-pointer mp %null-pointer)
              ;; `gtk_menu_popup_at_rect (menu, window, &rect,
              ;; NORTH_WEST, NORTH_WEST, last_click_event)` - a one-cell
              ;; rectangle at (X, Y), which is where Emacs puts it too.
              (let ((rect (make-c-struct (list int int int int)
                                         (list x y 1 1))))
                (gtk-menu-popup-at-rect
                 mp
                 (gtk-widget-get-window (pgtk-widget-pointer (pgtk-area d)))
                 rect GDK-GRAVITY-NORTH-WEST GDK-GRAVITY-NORTH-WEST
                 %null-pointer)))
          (when (= 1 (gtk-widget-get-mapped mp))
            (*pgtk-popup-active* #t)
            ;; `popup_widget_loop` (`pgtkmenu.c:613`): "Process events in
            ;; the Gtk event loop until done." This is a *nested* turn of
            ;; the same loop the editor already runs inside
            ;; (`gtk_main`), which is what Emacs does here as well.
            (let loop ()
              (when (*pgtk-popup-active*)
                (gtk-main-iteration)
                (loop))))
          ;; `pop_down_menu`: the widget and its subtree go.
          (gtk-widget-destroy mp)
          #f)))

    (define (pgtk-menu-show d frame x y flags title)
      ;; `pgtk_menu_show` (`pgtkmenu.c:588`): build, show, and answer the
      ;; chosen item's entry.
      ;;--------------------------------------------------------------
      (if (<= (menu-items-used) menu-items-pane-length)
          (error "Empty menu")
          (let ((items (menu-items))
                (used (menu-items-used)))
            (*pgtk-popup-selection* #f)
            (pgtk-create-and-show-popup-menu
             d (pgtk-popup-build-tree flags title) x y
             (not (eqv? 0 (logand flags MENU-FOR-CLICK))))
            (let ((selection (*pgtk-popup-selection*)))
              (cond
               ((not selection)
                ;; "Make Cancel equivalent to C-g" - unless the menu was
                ;; clicked open, which is `MENU_FOR_CLICK`.
                (unless (not (eqv? 0 (logand flags MENU-FOR-CLICK)))
                  (signal-quit))
                #f)
               (else
                ;; "Find the selected item, and its pane, to return the
                ;; proper value."
                (let ((prefix #f)
                      (entry #f)
                      (subprefix-stack (make-vector (max used 1) #f))
                      (submenu-depth 0))
                  (let loop ((i 0))
                    (if (>= i used)
                        #f
                        (let ((slot (vector-ref items i)))
                          (cond
                           ((not slot)
                            (vector-set! subprefix-stack submenu-depth prefix)
                            (set! submenu-depth (+ submenu-depth 1))
                            (set! prefix entry)
                            (loop (+ i 1)))
                           ((eq? slot 'lambda)
                            (set! submenu-depth (- submenu-depth 1))
                            (set! prefix
                                  (vector-ref subprefix-stack submenu-depth))
                            (loop (+ i 1)))
                           ((eq? slot #t)
                            (set! prefix
                                  (vector-ref items
                                              (+ i menu-items-pane-prefix)))
                            (loop (+ i menu-items-pane-length)))
                           ((eq? slot 'quote)
                            (loop (+ i 1)))
                           (else
                            (set! entry
                                  (vector-ref items
                                              (+ i menu-items-item-value)))
                            (if (not (= selection i))
                                (loop (+ i menu-items-item-length))
                                (if (eqv? 0 (logand flags MENU-KEYMAPS))
                                    entry
                                    ;; `entry = list1 (entry)`, then the
                                    ;; prefix, then the submenu prefixes
                                    ;; from the deepest up.
                                    (let ((e (list entry)))
                                      (when prefix
                                        (set! e (cons prefix e)))
                                      (let down ((j (- submenu-depth 1)))
                                        (when (>= j 0)
                                          (let ((p (vector-ref
                                                    subprefix-stack j)))
                                            (when p
                                              (set! e (cons p e))))
                                          (down (- j 1))))
                                      e)))))))))))))))

    (define-method (menu-show (d <pgtk-display>) frame x y flags title)
      ;; GNU Emacs's `terminal->menu_show_hook` for a Gtk frame:
      ;; `pgtk_menu_show` (`pgtkmenu.c:588`).
      ;;--------------------------------------------------------------
      (pgtk-menu-show d frame x y flags title))

    (define (pgtk-menu-selection! d call-data)
      ;; xmenu.c's `menubar_selection_callback` (`:794`): the clicked
      ;; item's `call_data` is its index in the snapshot the bar was
      ;; built from, and what the command loop needs is the key sequence
      ;; it stands for.
      ;;
      ;; **Each key goes through `pgtk-enqueue!`, like a keystroke.**
      ;; The first is a *prefix* (`menu-bar`) and the rest are the keys
      ;; beneath it, so they must reach the command loop's modal lookup
      ;; one at a time, in order - which is exactly what a fast typist's
      ;; `C-x C-f' does. Emacs puts the same events in the keyboard
      ;; buffer; this front end has two ways in and `pgtk-enqueue!` is
      ;; the one that picks between them.
      ;;--------------------------------------------------------------
      (let ((vector (pgtk-menubar-vector d)))
        (when vector
          (find-and-call-menu-selection
           vector (pgtk-menubar-used d) call-data
           (lambda (key)
             (pgtk-enqueue! d (cons 'menu-bar-event key)))))))

    (define (pgtk-grow-by-menubar! d)
      ;; Keep the *grid* the same when the bar appears.
      ;;
      ;; GNU Emacs's `adjust_frame_size (f, -1, -1, 2, false,
      ;; Qmenu_bar_lines)` (`xmenu.c:1342`) grows the frame by the menu
      ;; bar's height instead of letting the edit area give the rows up,
      ;; which is why a menu bar never costs a line of text there. The
      ;; box gives them up by default, so this asks the window for the
      ;; height back - once per change of the bar's own height, so that
      ;; the resize it causes cannot ask again.
      ;;--------------------------------------------------------------
      (let ((bar (pgtk-menubar d))
            (win (pgtk-window d)))
        (when (and bar win)
          (let ((h (widget:get-allocated-height bar)))
            (when (and h (>= h 0) (not (= h (pgtk-menubar-height d))))
              (set! (pgtk-menubar-height d) h)
              (let ((alloc (pgtk-allocation d)))
                (when alloc
                  (window:resize win (car alloc) (+ (cdr alloc) h)))))))))

    (define (pgtk-menu-bar-open frame)
      ;; GNU Emacs's `pgtk-menu-bar-open` (`term/pgtk-win.el:339`) in its
      ;; "the bar is showing" branch: `(accelerate-menu frame)`, which is
      ;; `x_menu_bar_open_internal` (`xmenu.c:579`) -
      ;;
      ;;   set_frame_menubar (f, true);
      ;;   children = gtk_container_get_children (GTK_CONTAINER (menubar));
      ;;   g_signal_emit_by_name (children->data, "activate_item");
      ;;
      ;; "Start key navigation of the menu bar in FRAME. This initially
      ;; opens the first menu bar item and you can then navigate with the
      ;; arrow keys, select a menu entry with the return key or cancel
      ;; with the escape key."
      ;;
      ;; **The toolkit takes over from the signal**: GTK's own menu shell
      ;; reads the arrows, Return and Escape from here, which is why
      ;; there is nothing else to do. The bar is rebuilt first for the
      ;; reason `set_frame_menubar (f, true)` gives: the items have to be
      ;; current before the first one is opened.
      ;;--------------------------------------------------------------
      (let ((d (and frame (frame-output frame))))
        (when d
          (pgtk-set-frame-menubar d)
          (let ((bar (pgtk-menubar d)))
            (when bar
              (let ((children (container:get-children bar)))
                (when (pair? children)
                  ;; A `<signal>` is applicable: `(gi oop)`'s
                  ;; `initialize` sets its procedure to `%emit` with the
                  ;; signal fixed, so this is `g_signal_emit_by_name`.
                  ((make <signal> #:name "activate-item") (car children))
                  #t)))))))

    (define (pgtk-install-menubar! d items submenus vector)
      ;; Digest the freshly built `menu_items` into a `widget_value` tree
      ;; and hang Gtk widgets off the bar - the half of `set_frame_menubar`
      ;; that only runs when the array has changed.
      ;;--------------------------------------------------------------
      (let ((bar (pgtk-menubar d))
            (root (make-widget-value "menubar" #f #t #f)))
        (let loop ((rest submenus) (prev #f))
          (when (pair? rest)
            (let* ((sub (car rest))
                   (wv (begin
                         ;; The digest reads the pane count, and the C
                         ;; sets it per submenu before each call.
                         (set!menu-items-n-panes! (list-ref sub 2))
                         (digest-single-submenu
                          (list-ref sub 0) (list-ref sub 1)
                          (list-ref sub 3)))))
              (set!widget-value-enabled! wv #t)
              (set!widget-value-button-type wv 'none)
              (if prev
                  (set!widget-value-next prev wv)
                  (set!widget-value-contents root wv))
              (loop (cdr rest) wv))))
        ;; **The C's second loop** (`xmenu.c:1103`): each submenu's root
        ;; takes the *bar item's* name - which is why `digest_single_submenu`
        ;; leaves it as "menu" and this sets it - and only its *contents*
        ;; have their strings moved from `lname`/`lkey` to `name`/`key`.
        (let loop ((rest items) (wv (widget-value-contents root)))
          (when (and (pair? rest) wv)
            (set!widget-value-name wv (list-ref (car rest) 1))
            (update-submenu-strings (widget-value-contents wv))
            (loop (cdr rest) (widget-value-next wv))))
        ;; What the widgets' `call_data` indexes, kept beside the
        ;; widgets that carry it - `fset_menu_bar_vector`.
        (set! (pgtk-menubar-vector d) vector)
        (set! (pgtk-menubar-used d) (vector-length vector))
        ;; The old children are removed and their proxies left held;
        ;; Gtk unparents them, and a proxy released while its object
        ;; lives is the crash `pgtk-hold-widget!` exists to prevent.
        (for-each (lambda (w) (container:remove bar w))
                  (container:get-children bar))
        (if (null? (widget-value-contents root))
            (begin
              (widget:hide bar)
              (set! (pgtk-menubar-hidden? d) #t))
            (begin
              (pgtk-create-menus (widget-value-contents root) d
                                 (lambda (call-data)
                                   (pgtk-menu-selection! d call-data))
                                 bar #t)
              (widget:show-all bar)
              (set! (pgtk-menubar-hidden? d) #f)))))

    (define (pgtk-hide-menubar! d)
      ;; Take the bar down, once: remove its widgets and hide it.
      ;;
      ;; Used by both the empty-bar case and `menu-bar-lines` 0. Doing it
      ;; once matters: `container:get-children` and `widget:hide` are two
      ;; guile-gi crossings, measured at ~6 ms together, and running them
      ;; on every redisplay is a keystroke's worth of lag for a bar that
      ;; is not even showing.
      ;;--------------------------------------------------------------
      (let ((bar (pgtk-menubar d)))
        (unless (pgtk-menubar-hidden? d)
          (set! (pgtk-menubar-hidden? d) #t)
          (set! (pgtk-menubar-vector d) #f)
          (set! (pgtk-menubar-used d) 0)
          (for-each (lambda (w) (container:remove bar w))
                    (container:get-children bar))
          (widget:hide bar))))

    (define (pgtk-set-frame-menubar d)
      ;; GNU Emacs's `set_frame_menubar (f, false)` (`xmenu.c:970`): build
      ;; `menu_items` from `menu-bar-items`, and rebuild the widgets only
      ;; when the built array differs from the one they were made from.
      ;;
      ;; **The comparison is on the built array, not on the item list.**
      ;; That is Emacs's own rule - an `memcmp` over `menu_items` and a
      ;; length check (`xmenu.c:1082`) - and the difference matters: a
      ;; keymap's *contents* can change while `menu-bar-items` answers the
      ;; same objects, so comparing the list would leave a binding added
      ;; to an existing menu invisible. The array has a slot per item
      ;; pushed, so an added or removed binding changes it.
      ;;
      ;; `redisplay_window` decides *whether* to do the work at all from
      ;; `windows_or_buffers_changed` and `update_mode_lines`
      ;; (`xdisp.c:14443`). **That guard exists here now** -
      ;; `update-mode-lines?` is Emacs's `update_mode_lines` and
      ;; `windows-or-buffers-changed?` its `windows_or_buffers_changed`
      ;; - and the comment above it is corrected by it: comparing
      ;; afterwards gives the same *answer*, but only after the parse.
      ;; Emacs reaches this function only for a window whose
      ;; `update_mode_line` is set (`xdisp.c:21522`,
      ;; "When we reach a frame's selected window, redo the frame's menu
      ;; bar"), so a `C-n` never does it.
      ;;--------------------------------------------------------------
      (let ((bar (pgtk-menubar d)))
        (when bar
          ;; **`menu-bar-lines` turns the bar off**, which is what
          ;; `menu-bar-mode` sets on every frame
          ;; (`(set-frame-parameter frame 'menu-bar-lines val)`). The C's `x_set_menu_bar_lines` hides
          ;; the widget and leaves the display to redraw; this takes the
          ;; bar down once and forgets the built items, so turning it
          ;; back on rebuilds from scratch. The parameter is read before
          ;; the guard below because it is cheap and because turning the
          ;; bar off does not go through the redisplay flags.
          (let ((frame (pgtk-frame-for d)))
            (if (and frame (eqv? 0 (frame-parameter frame 'menu-bar-lines)))
                ;; Off: take it down and stop - the hooks and the rebuild
                ;; below would put it straight back.
                (pgtk-hide-menubar! d)
                ;; **Nothing that can change the bar is known to have
                ;; happened.** Two states count as already correct: the
                ;; bar has been built and its widgets are installed, or
                ;; there are no items and the bar is down. A bar that has
                ;; never been built (vector #f and not hidden) falls
                ;; through to the work below, which is what makes the
                ;; first redisplay draw it.
                (if (and (or (pgtk-menubar-hidden? d)
                             (pgtk-menubar-vector d))
                         (not (or (windows-or-buffers-changed?)
                                  (update-mode-lines?))))
                    #f
                (begin
          ;; **The bar is themed with the mode line's colours, until they
          ;; stop changing** - a theme is loaded by a command, and this is
          ;; the only place the bar is looked at. See "The menu bar's
          ;; theme" above. It is inside the guard because a theme load
          ;; sets `windows-or-buffers-changed?` (`set-face-attribute`
          ;; does), and that is exactly when the colours can differ.
          (pgtk-theme-menubar! d)
          ;; **The two hooks, as `set_frame_menubar` runs them**
          ;; (`xmenu.c:994-1000`): the Lucid hook first, which lets a
          ;; package set the bar wholesale, then `menu-bar-update-hook`,
          ;; where a menu that rebuilds itself registers. They run
          ;; before the items are read, and they run on every redisplay
          ;; because this tree has no `windows_or_buffers_changed` to
          ;; decide with; a hook that is expensive is a hook that should
          ;; be guarded by its own cheap test.
          (run-hooks (*activate-menubar-hook*))
          (run-hooks (*menu-bar-update-hook*))
          (let ((items (menu-bar-items)))
            (cond
             ((null? items)
              ;; **An empty bar is taken down once, not rebuilt.** The C
              ;; rebuilds it (`i != 0` in its guard) because its rebuild
              ;; is a few Lisp calls; here it is `container:get-children`
              ;; and `widget:hide`, two guile-gi crossings measured at
              ;; ~6 ms together - 6 ms *per redisplay*, which is a
              ;; keystroke's worth of lag for a bar that is not even
              ;; showing. Nothing can change a bar with no items except
              ;; items arriving, and the non-empty branch below is what
              ;; notices those.
              (pgtk-hide-menubar! d))
             (else
              (set! (pgtk-menubar-hidden? d) #f)
              (let ((submenus '()))
            (init-menu-items)
            (for-each
             (lambda (quad)
               (let ((start (menu-items-used)))
                 ;; The C's `menu_items_n_panes = 0` before every
                 ;; submenu: the count is per menu bar item, and a
                 ;; running total would give the second item's digest the
                 ;; first one's panes.
                 (set!menu-items-n-panes! 0)
                 (let ((top (parse-single-submenu
                             (list-ref quad 0) (list-ref quad 1)
                             (list-ref quad 2)))
                       (n (menu-items-n-panes)))
                   (set! submenus (cons (list start (menu-items-used) n top)
                                        submenus)))))
             items)
            (finish-menu-items)
            (let ((vector (vector-copy (menu-items) 0 (menu-items-used)))
                  (old (pgtk-menubar-vector d)))
              ;; The C's guard: unchanged, and not empty, means no work.
              (unless (and old
                           (> (vector-length vector) 0)
                           (equal? vector old))
                (pgtk-install-menubar! d items (reverse submenus) vector))))))))))))))

    (define (pgtk-title-frame! frame)
      ;; Give FRAME's window the frame's name as its title. GNU Emacs's
      ;; `x_window' sets the title from `f->title', else `f->name'
      ;; (`gtkutil.c:1656-1663'), and a frame's name is `F1', `F2', ... -
      ;; so two windows are tellable apart in the window manager, which is
      ;; how you see which one `C-x 5 o' selected. The editor titled its
      ;; one window with nothing at all before this.
      ;;
      ;; Called by whatever has *both* the frame and its window to hand:
      ;; the display is made first here (it is a constructor argument of
      ;; the frame), so the title cannot be set at open time.
      ;;--------------------------------------------------------------
      (let ((d (and frame (frame-output frame))))
        (when (and d (pgtk-window d) (frame-name frame))
          (set! (window:title (pgtk-window d)) (frame-name frame)))
        d))

    (define *pgtk-destroyed-displays* '())
    ;; ^ The displays whose windows `pgtk-close-window!' has destroyed,
    ;; held so that the Guile proxies of the widgets inside them outlive
    ;; the destruction. Their heavy resources - the cairo surface, the
    ;; context and the Pango layout - are dropped before the display is
    ;; parked here, so what is held is the display's own record and the two
    ;; widget objects.
    ;;
    ;; **This is guile-gi's ownership rule, measured rather than assumed.**
    ;; A widget's proxy holds a *toggle reference* to its GObject: the
    ;; object lives exactly as long as the proxy does. When the proxy is
    ;; collected, guile-gi drops that reference - and then its ordinary
    ;; finalizer calls `g_object_unref' on the object it has just released,
    ;; which is a double release. GLib reports it as
    ;;
    ;;     GLib-GObject-CRITICAL: g_object_unref: assertion
    ;;     'G_IS_OBJECT (object)' failed
    ;;
    ;; twice per closed window (the window and the drawing area inside it).
    ;; It is *guarded*, so it corrupts nothing - `g_object_unref' checks
    ;; and returns - but it is two CRITICAL lines on stderr for a perfectly
    ;; ordinary action, and it is a release of memory this process no longer
    ;; owns.
    ;;
    ;; Measured on a live editor, forcing `gc' after each step. These four
    ;; rows are why it is the whole *display* that is parked and not just
    ;; the window:
    ;;
    ;;   close a window, hold nothing                      -> 2 CRITICALs
    ;;   the same from `delete-frame', holding the
    ;;     window's proxy but not the display              -> 2 CRITICALs
    ;;   hold the display across the close                 -> 0
    ;;   **drop the big slots, then park it - this code**  -> 0
    ;;
    ;; Both proxies have to stay alive; the drawing area's does not follow
    ;; the window's. Parking the display costs its own record and the two
    ;; widget objects per frame closed - the heavy resources, the pixel
    ;; buffer above all (`columns x rows x 4' bytes), are dropped first and
    ;; so are not parked, and a human closes frames one at a time.
    ;;
    ;; Nothing here is masking a crash, which is worth knowing before
    ;; reading the hold that way: a destroyed widget is a *valid* object.
    ;; `(widget:visible win)' answers #f afterwards, a second
    ;; `(widget:destroy win)' passes `GTK_IS_WIDGET' without complaint, and
    ;; neither warns. The GObject outlives the destruction; it is only its
    ;; *release* that is wrong, and only in guile-gi's hands.
    ;;
    ;; **No Emacs code is being departed from here.** `pgtk_destroy_window`
    ;; and `tty_free_frame_resources` do the same destruction; what has no
    ;; counterpart is guile-gi's proxy, because Emacs has no proxy - the C
    ;; holds and releases its own references. This is the same category as
    ;; the AT-SPI and duplicate-`make' warnings AGENTS.md records, with the
    ;; difference that a cheap hold removes it rather than documenting it.

    (define (pgtk-close-window! d)
      ;; Destroy a window `pgtk-open-window' made, and forget it. Emacs's
      ;; counterpart is the teardown `x_free_frame_resources' does.
      ;;
      ;; The display is parked *before* the destroy, so that the widgets'
      ;; proxies are alive already when the objects change state - see
      ;; `*pgtk-destroyed-displays*'. The big slots go first, so that
      ;; parking the display does not park the frame's pixel buffer with
      ;; it.
      ;;--------------------------------------------------------------
      (let ((win (pgtk-window d)))
        (set! (pgtk-surface d) #f)
        (set! (pgtk-cr d) #f)
        (set! (pgtk-layout d) #f)
        (set! (pgtk-last-allocation d) #f)
        (set! *pgtk-destroyed-displays* (cons d *pgtk-destroyed-displays*))
        (when win (widget:destroy win)))
      (*pgtk-displays*
       (let loop ((l (*pgtk-displays*)) (acc '()))
         (cond ((null? l) (reverse acc))
               ((eq? (car l) d) (loop (cdr l) acc))
               (else (loop (cdr l) (cons (car l) acc))))))
      d)

    (define-method (delete-frame-display! (d <pgtk-display>))
      ;; The display's `terminal->delete_frame_hook`: a frame on this
      ;; display has been deleted, so its window goes away.
      ;;
      ;; This is `pgtk_destroy_window` (`pgtkterm.c:600`), whose whole
      ;; visible effect is the `gtk_widget_destroy (FRAME_WIDGET (f))` in
      ;; `pgtk_free_frame_resources` (`:445`). One display here is one
      ;; frame's window, so destroying the display is destroying the
      ;; frame's surface - and `pgtk-close-window!` drops it from
      ;; `*pgtk-displays*` as well, so a read stops looking at it.
      ;;
      ;; **The window is destroyed exactly once.** The window manager's
      ;; close request reaches `delete_event` first, and that handler
      ;; returns TRUE precisely so that Gtk does *not* destroy the widget
      ;; (`pgtk-open-window`): the command loop is asked instead, and
      ;; `handle-delete-frame` is what turns that request into a
      ;; `delete-frame` call, which arrives here. So both routes end in
      ;; this one destroy, and neither double-destroys.
      ;;--------------------------------------------------------------
      (pgtk-close-window! d))

    (define (with-gtk-display thunk)
      ;; Open the editor's GTK window, make it the editor's display, run
      ;; THUNK, and take it down afterwards. The counterpart of
      ;; `with-terminal'.
      ;;--------------------------------------------------------------
      ;; The name the window manager knows this window by. On Wayland the
      ;; app-id comes from the program name, which would otherwise be
      ;; `guile' - so a compositor rule cannot name this editor. Setting
      ;; both before Gtk is initialised is what makes it `schemacs'.
      ;;--------------------------------------------------------------
      (set-prgname "schemacs")
      (set-program-class "schemacs")
      ;; **Gtk needs a display, and `init-check!' answers #f when it cannot
      ;; open one.** That answer used to be thrown away, so a run with no
      ;; display went on to make a `<GtkWindow>' with no screen behind it:
      ;; Gtk logged three `GTK_IS_STYLE_PROVIDER_PRIVATE' assertions, then
      ;; dereferenced the NULL it had been handed, and the editor died
      ;; with a segmentation fault instead of saying what was wrong.
      ;;
      ;; Emacs dies in the same place for the same reason - `gtk_init'
      ;; (`pgtkterm.c:7133') exits the process when there is no display -
      ;; but it says so first. This says so in this tree's own words, as
      ;; `check-cairo!' does for its missing primitive.
      (unless (init-check!)
        (simple-format (current-error-port)
                       "~a: cannot open a display for the Gtk window.~%"
                       "schemacs")
        (simple-format (current-error-port)
                       "~%  Gtk needs a display: a Wayland compositor (`WAYLAND_DISPLAY')~%")
        (simple-format (current-error-port)
                       "  or an X server (`DISPLAY'). An `ssh' login has neither unless~%")
        (simple-format (current-error-port)
                       "  it forwards one.~%~%")
        (simple-format (current-error-port)
                       "  `~a' with no `-w' is a terminal editor and needs no display~%"
                       "schemacs")
        (simple-format (current-error-port)
                       "  at all.~%")
        (exit 1))
      ;; **The back door can be woken here, so nothing has to poll for
      ;; it.** The shared module's `repl-wake' is how a front end says
      ;; it can be told that the REPL has work; Gtk says it with an idle
      ;; callback, which the main loop runs out of the very
      ;; `g_main_loop_run' the read is blocked in. `keyboard.sld' asks
      ;; whether a wake exists and only shortens its waits when none does
      ;; - which is where this editor's idle CPU went (see
      ;; `pgtk-wait!': with the back door open the wait was capped at
      ;; 100 ms and every one of those turns cost ~13 ms of guile-gi
      ;; crossings).
      ;;
      ;; **It is a global and not a parameter**, because the server's
      ;; reader thread - which is what calls the wake - is made by
      ;; `start-repl!' before this front end exists, and a fluid's value
      ;; is captured per thread when the thread is made. As a parameter
      ;; this read `#f' in every server thread for ever, so nothing ever
      ;; woke the editor and only a keystroke let a queued expression
      ;; run. See `(scheme-utils repl server)''s `repl-wake!'.
      ;;
      ;; The wake is handed a thunk to run on the thread that owns the
      ;; program's state; this front end runs `poll-repl!' instead, which is the
      ;; same thing with the "no door open" guard on it. The parameter is named
      ;; and ignored: the arity is the contract.
      (repl-wake! (lambda (drain)
                    (idle-add 0 (lambda (data) (poll-repl!) #f) #f)))
      ;; **The font is settled before the window is made**, because the
      ;; window's pixel size is the number of rows and columns times a
      ;; cell, and a cell is the font's. Opening the window first sized it
      ;; from whatever metrics the module was born with (18-pixel rows)
      ;; and then realized the font (20) - so a window asked for 24 rows
      ;; held 21. Emacs has the same order for the same reason: the font
      ;; is loaded when the frame is created, and `x_window' sizes itself
      ;; from `FRAME_COLS' × `FRAME_COLUMN_WIDTH'.
      (pgtk-ensure-font!)
      ;; **This front end's `menu-bar-open`.** GNU Emacs's `menu-bar-open`
      ;; asks the *frame's type* which toolkit function to call
      ;; (`menu-bar.el:2859`); here the front end installs its own before
      ;; any key can be read, the same way it installs its frame creator
      ;; and its REPL wake.
      (*menu-bar-open-function* pgtk-menu-bar-open)
      (let ((d (pgtk-open-window 80 24)))
        (current-display d)
        (initialize-pgtk-faces! d)
        ;; **The input queue's second reader.** A key that arrives while
        ;; a redisplay is running is queued, and this front end's
        ;; outermost loop has no read to collect it; the redisplay
        ;; dispatches whatever arrived as soon as it has finished
        ;; (`*after-redisplay-hook*`, which `redisplay-frames!` runs).
        ;; Without it a key pressed during the cursor-blink repaint - or
        ;; during the redisplay after a command - sat in the queue until
        ;; the next key. (The `C-s`-for-ever bug was not this: it was
        ;; Return arriving as a symbol; see `isearch-read-key`.)
        (parameterize ((*after-redisplay-hook*
                       (lambda ()
                         (let ((dispatch (*dispatch-event*)))
                           (when (and dispatch (null? *pgtk-running*))
                             (pgtk-drain-queue! (current-display)
                                                dispatch))))))
        (dynamic-wind
         (lambda () #t)
         thunk
         (lambda ()
           (pgtk-close-window! d)
           ;; Clear the editor's display only when this was the last
           ;; window: with a second one open the editor still has one.
           (unless (pair? (*pgtk-displays*)) (current-display #f)))))))

    ;;----------------------------------------------------------------
    ;; The selections
    ;;
    ;; `pgtk-win.el''s four `gui-backend-*' methods, which are the C
    ;; DEFUNs of `pgtkselect.c'; `select.sld''s `gui-backend-*' reach
    ;; them through `dispnew''s selection generics, whose dispatch is
    ;; the display. A text terminal gets the default methods, which
    ;; answer #f - a terminal has no selections, and so an `emacs -nw'
    ;; kill and yank stay inside the kill ring. This display answers
    ;; with Gtk's clipboard.
    ;;
    ;; Gtk's clipboard and not the raw `gdk_selection_owner_set'
    ;; protocol `pgtkselect.c' speaks, because the clipboard *is* that
    ;; protocol as the toolkit abstracts it, and every other GTK
    ;; program talks to it through GtkClipboard. What is kept of the C
    ;; is the bookkeeping: the `selections' slot above is
    ;; `LOCAL_SELECTION' (`pgtkselect.c:116'), which
    ;; `pgtk-selection-owner-p' answers from.
    ;;
    ;; The C functions come through Guile's own FFI rather than
    ;; guile-gi, which binds no `clipboard:get': `gtk_clipboard_get''s
    ;; GdkAtom parameter carries no GType, and guile-gi skips functions
    ;; whose arguments it cannot map.
    ;;
    ;; The four generics MUST be imported from `dispnew' or the
    ;; `define-method's below make *new* generics of their own: the
    ;; dispatch through `select.sld' still resolves to `dispnew''s,
    ;; whose default methods answer #f, and the clipboard silently
    ;; receives nothing - which is what M-w did, and what this bug was.
    ;;------------------------------------------------------------------

    (define gtk-selection-lib (dynamic-link "libgtk-3.so.0"))
    (define gdk-selection-lib (dynamic-link "libgdk-3.so.0"))
    ;; `g_free' - GtkClipboard's text comes out as a `gchar *' that the
    ;; caller owns (its documentation: "free the returned value"), and
    ;; only GLib knows how. `libgobject-2.0' exports it.
    (define gobject-selection-lib (dynamic-link "libgobject-2.0.so.0"))

    (define (selection-foreign-fn lib name ret args)
      (pointer->procedure ret (dynamic-func name lib) args))

    (define gdk-atom-intern
      (selection-foreign-fn gdk-selection-lib "gdk_atom_intern" '* (list '* int)))
    ;; GDK's other direction: an atom's *name*, which is the only way to
    ;; tell one from another across the FFI. `gdk_atom_intern' interns by
    ;; name, so the atom `GDK_SELECTION_TYPE_ATOM' *is* the atom for the
    ;; string "ATOM" - `gdk_atom_intern_static_string ("ATOM")' - which is
    ;; why every comparison below is by name and none needs the C's
    ;; constants. The answer is a `gchar *' that the caller frees.
    (define gdk-atom-name
      (selection-foreign-fn gdk-selection-lib "gdk_atom_name" '* (list '*)))
    (define gtk-clipboard-get
      (selection-foreign-fn gtk-selection-lib "gtk_clipboard_get" '* (list '*)))
    (define gtk-clipboard-set-text
      (selection-foreign-fn gtk-selection-lib "gtk_clipboard_set_text"
                            void (list '* '* int)))
    (define gtk-clipboard-clear
      (selection-foreign-fn gtk-selection-lib "gtk_clipboard_clear"
                            void (list '*)))
    (define gtk-clipboard-wait-is-text-available?
      (selection-foreign-fn gtk-selection-lib "gtk_clipboard_wait_is_text_available"
                            int (list '*)))
    ;; `gtk_clipboard_wait_for_text' is Gtk's convenience for the one
    ;; target `UTF8_STRING' and **it is what `get-selection' used to call
    ;; whatever it was asked for** - so a TARGETS request, an ATOM
    ;; request, a LENGTH request all came back as the clipboard's text,
    ;; and that is the departure the port below removes. It is gone
    ;; rather than kept for the text targets, because the general read
    ;; answers those too, and by the coding system the target names rather
    ;; than by Gtk's guess.
    ;;
    ;; (Its one trap, recorded because it cost an afternoon: a NULL
    ;; pointer comes back through the FFI as a *true* pointer object, so
    ;; an empty clipboard has to be asked about with `null-pointer?' and
    ;; not with `(if text ...)'.)
    ;;
    ;; **The read that takes a *target*.** `gtk_clipboard_wait_for_contents'
    ;; converts the selection to the target atom asked
    ;; for and answers a `GtkSelectionData *' (transfer full) holding the
    ;; *bytes*, which is what `pgtk_get_window_property_as_lisp_data'
    ;; reads in the C - there via `gdk_selection_property_get' after a
    ;; `GDK_SELECTION_NOTIFY'. Gtk does the waiting inside the same nested
    ;; main loop the read already runs in, so the C's
    ;; `wait_reading_process_output' + atimer + timeout machinery is
    ;; Gtk's and is not ported: what the C does with the property once it
    ;; has it is what is below.
    (define gtk-clipboard-wait-for-contents
      (selection-foreign-fn gtk-selection-lib "gtk_clipboard_wait_for_contents"
                            '* (list '* '*)))
    ;; The four accessors of what came back. `GtkSelectionData' is the C's
    ;; `(data, length, data_type, format, target)' quintuple - the same
    ;; five things `pgtk_get_window_property' fills in - and its `data' is
    ;; the `unsigned char *' the property held.
    (define gtk-selection-data-get-data
      (selection-foreign-fn gtk-selection-lib "gtk_selection_data_get_data"
                            '* (list '*)))
    (define gtk-selection-data-get-length
      (selection-foreign-fn gtk-selection-lib "gtk_selection_data_get_length"
                            int (list '*)))
    (define gtk-selection-data-get-data-type
      (selection-foreign-fn gtk-selection-lib "gtk_selection_data_get_data_type"
                            '* (list '*)))
    (define gtk-selection-data-get-format
      (selection-foreign-fn gtk-selection-lib "gtk_selection_data_get_format"
                            int (list '*)))
    (define gtk-selection-data-free
      (selection-foreign-fn gtk-selection-lib "gtk_selection_data_free"
                            void (list '*)))
    (define gtk-get-current-event-time
      (selection-foreign-fn gtk-selection-lib "gtk_get_current_event_time"
                            unsigned-int '()))
    (define g-free
      (selection-foreign-fn gobject-selection-lib "g_free" void (list '*)))

    (define (selection-atom selection)
      ;; A selection symbol - `PRIMARY', `SECONDARY', `CLIPBOARD' - as a
      ;; GdkAtom. GDK expects these literal upper-case names, as
      ;; `pgtk-own-selection-internal''s docstring says: "(Those are
      ;; literal upper-case symbol names, since that's what GDK
      ;; expects.)"
      ;;
      ;; This is `symbol_to_gdk_atom' (`pgtkselect.c:119') as far as this
      ;; tree needs it. The C's three special cases -
      ;; `GDK_SELECTION_PRIMARY'/`_SECONDARY'/`_CLIPBOARD' - are the atoms
      ;; for the strings "PRIMARY"/"SECONDARY"/"CLIPBOARD"
      ;; (`gdk_atom_intern_static_string'), so interning the name is the
      ;; same atom; and the C's nil case (GDK_NONE) is not reached,
      ;; because `target-type' is checked to be a symbol before it gets
      ;; here and a selection is always one of the three.
      ;;--------------------------------------------------------------
      (gdk-atom-intern (string->pointer (symbol->string selection) "UTF-8") 0))

    (define (atom-name-string atom)
      ;; `gdk_atom_to_symbol' (`pgtkselect.c:138')'s first half: the
      ;; atom's name as a Scheme string, or #f for GDK_NONE and for an
      ;; atom that has none. The returned `gchar *' is ours to free.
      ;;--------------------------------------------------------------
      (and atom
           (not (null-pointer? atom))
           (let ((p (gdk-atom-name atom)))
             (and p
                  (not (null-pointer? p))
                  (let ((s (pointer->string p -1 "UTF-8")))
                    (g-free p)
                    s)))))

    (define (gdk-atom-to-symbol atom)
      ;; `gdk_atom_to_symbol' (`pgtkselect.c:138'): `(intern (gdk_atom_name
      ;; atom))' - a *symbol*, which is what a 32-bit ATOM selection data
      ;; row decodes to.
      ;;--------------------------------------------------------------
      (let ((name (atom-name-string atom)))
        (and name (string->symbol name))))

    (define *selection-clipboards* (make-parameter '()))
    ;; ^ `((SELECTION . <clipboard-pointer>) ...)'. `gtk_clipboard_get'
    ;; answers the same object for the same atom, so this is a cache,
    ;; not the ownership - that is the display's `selections' slot.

    (define (selection-clipboard selection)
      (or (assq-ref (*selection-clipboards*) selection)
          (let ((clip (gtk-clipboard-get (selection-atom selection))))
            (*selection-clipboards*
             (cons (cons selection clip) (*selection-clipboards*)))
            clip)))

    ;;----------------------------------------------------------------
    ;; Reading our own selection - `pgtk_get_local_selection'
    ;;----------------------------------------------------------------

    (define (local-selection d selection)
      ;; `LOCAL_SELECTION' (`pgtkselect.c:116'): the process's own record
      ;; of what it has asserted for SELECTION, as
      ;;
      ;;     (SELECTION VALUE TIMESTAMP FRAME)
      ;;
      ;; - the C's four-element `selection_data' list, `assq''d in the
      ;; terminal's `Vselection_alist'. This is the display's `selections'
      ;; slot, and it is **not** a question to GDK: Emacs answers a read
      ;; of its own selection out of here rather than round-tripping
      ;; through the server, which is what makes `(gui-get-selection
      ;; 'CLIPBOARD 'TARGETS)' answer with the target vector instead of
      ;; the text.
      ;;--------------------------------------------------------------
      (assq selection (pgtk-selections d)))

    (define (pgtk-get-local-selection d selection target-type local-request)
      ;; GNU Emacs's `pgtk_get_local_selection' (`pgtkselect.c:236'):
      ;; "Return the value of SELECTION for TARGET-TYPE, or nil if we do
      ;; not own SELECTION."
      ;;
      ;; LOCAL-REQUEST is the C's flag: true when the request came from
      ;; this process (`pgtk-get-selection-internal') and false when we
      ;; are answering another program's. It is passed straight to the
      ;; converter, where it decides whether TYPE is nil or the target -
      ;; and a nil TYPE is what makes the conversion free
      ;; (`xselect--encode-string' answers the string as it stands).
      ;; Every call here is local: the foreign-request path is Gtk's,
      ;; which answers with the text it was given rather than with the
      ;; converters. That is a departure and it is named on
      ;; `set-selection!'.
      ;;
      ;; Four things of the C's, in its order:
      ;;
      ;;   1. **TIMESTAMP is a special case** and never reaches the
      ;;      converter table - its answer is the timestamp in the local
      ;;      entry, the third element.
      ;;   2. `CHECK_SYMBOL (target_type)' - a target is a symbol, and
      ;;      that check is also what the table's `eq?' lookup needs.
      ;;   3. **A string value's text properties are consulted first**:
      ;;      `(get-text-property 0 target_type tem)', so a string can
      ;;      carry an alternative value for one target. There are no
      ;;      text properties on a selection string here - the value is
      ;;      whatever `gui-set-selection' was handed - so this arm
      ;;      answers nil and is written as the `#f' it is.
      ;;   4. the handler is called, and then the value it answered is
      ;;      **checked for transmissibility** - string, vector, symbol,
      ;;      integer, nil, or a `cons_to_signed' pair - and an error
      ;;      says so when it is none of those.
      ;;--------------------------------------------------------------
      (let ((local (local-selection d selection)))
        (if (not local)
            #f
            (if (eq? target-type 'TIMESTAMP)
                (list-ref local 2)
                (let ((handler (assq-ref (*selection-converter-alist*)
                                         target-type)))
                  ;; CHECK_SYMBOL: `target-type''s symbolness is what the
                  ;; `eq?' lookup above has already required.
                  (unless (symbol? target-type)
                    (error "Wrong type argument: symbolp"
                           target-type))
                  (let ((value (if handler
                                   (handler selection
                                            (if local-request #f target-type)
                                            (list-ref local 1))
                                   #f)))
                    (pgtk-clean-local-selection-data
                     (pgtk-check-local-selection-value handler value))))))))

    (define (pgtk-check-local-selection-value handler value)
      ;; The C's "Make sure this value is of a type that we could
      ;; transmit to another client" (`pgtkselect.c:284'): a string, a
      ;; vector, a symbol, an integer, nil, or the `(HIGH . LOW)' pair
      ;; `CONS_TO_INTEGER' takes. Anything else is "Invalid data returned
      ;; by selection-conversion function", naming the handler and the
      ;; value.
      ;;--------------------------------------------------------------
      (let* ((check (if (and (pair? value) (symbol? (car value)))
                        (cdr value)
                        value))
             (ok? (or (string? check)
                      (vector? check)
                      (symbol? check)
                      (integer? check)
                      (not value)
                      ;; `cons_to_signed'/`cons_to_unsigned''s shape: a
                      ;; cons whose car is an integer and whose cdr is one
                      ;; or a one-element list of one.
                      (and (pair? check)
                           (integer? (car check))
                           (or (integer? (cdr check))
                               (and (pair? (cdr check))
                                    (integer? (car (cdr check)))
                                    (null? (cdr (cdr check)))))))))
        (if ok?
            value
            (error (string-append "Invalid data returned by "
                                  "selection-conversion function: "
                                  (if handler "a handler" "no handler"))))))

    (define (pgtk-clean-local-selection-data obj)
      ;; GNU Emacs's `clean_local_selection_data' (`pgtkselect.c:1547'):
      ;; the `(HIGH . LOW)' pair a number was carried as becomes the
      ;; number again, and a one-element vector becomes its element - so
      ;; `xselect-convert-to-identity''s `(vector value)' comes back as
      ;; VALUE and a LENGTH conversion comes back as a number.
      ;;
      ;; The first clause of the C's is `(cons_to_signed obj 16)' - the
      ;; pair written out as `(a b)' rather than `(a . b)'.
      ;;--------------------------------------------------------------
      (let ((obj (if (and (pair? obj)
                          (integer? (car obj))
                          (pair? (cdr obj))
                          (integer? (car (cdr obj)))
                          (null? (cdr (cdr obj))))
                     (cons (car obj) (car (cdr obj)))
                     obj)))
        (cond
         ((and (pair? obj) (integer? (car obj)) (integer? (cdr obj)))
          (cond ((= 0 (car obj)) (cdr obj))
                ((= -1 (car obj)) (- (cdr obj)))
                (else obj)))
         ((vector? obj)
          (if (= 1 (vector-length obj))
              (pgtk-clean-local-selection-data (vector-ref obj 0))
              (list->vector
               (map pgtk-clean-local-selection-data (vector->list obj)))))
         (else obj))))

    ;;----------------------------------------------------------------
    ;; Reading a foreign selection's data
    ;;----------------------------------------------------------------

    (define (selection-data-size-for-format format)
      ;; `pgtk_size_for_format' (`pgtkselect.c:1082').
      ;;--------------------------------------------------------------
      (cond ((= format 8) 1)
            ((= format 16) 2)
            ((= format 32) 4)
            (else #f)))

    (define (selection-data-to-lisp-data bytes size type-name format)
      ;; GNU Emacs's `selection_data_to_lisp_data' (`pgtkselect.c:1266')
      ;; - the table its own comment lays out:
      ;;
      ;;   Type   Format  Size   Lisp Type
      ;;   ----   ------  ----   ---------
      ;;   *      8       *      String
      ;;   ATOM   32      1      Symbol
      ;;   ATOM   32      > 1    Vector of Symbols
      ;;   *      16      1      Integer
      ;;   *      16      > 1    Vector of Integers
      ;;   *      32      1      Integer
      ;;   *      32      > 1    Vector of the above
      ;;
      ;; BYTES is the data as a bytevector and SIZE its length in bytes,
      ;; TYPE-NAME the data type's atom name ("STRING", "ATOM", ...) and
      ;; FORMAT 8, 16 or 32.
      ;;
      ;; **One departure, and it is the tree's data model rather than
      ;; this function's**: the C's 8-bit answer is a *unibyte string*
      ;; that select.el then decodes by data type
      ;; (`gui-get-selection', with the `foreign-selection' property
      ;; recording which). Guile has no unibyte string, so the bytes are
      ;; decoded to the tree's code points here and rendered as a string -
      ;; which is the same decode at the same point in the pipeline, one
      ;; function earlier. A byte no charset can read becomes U+FFFD, the
      ;; substitution the renderer already makes.
      ;;
      ;; The 16- and 32-bit cases read the elements out of BYTES with the
      ;; endianness the protocol fixed (little on every display this
      ;; tree runs on; the C reads a native `short'/`int', and so does
      ;; this) and answer the integer, or the vector of them.
      ;;
      ;; The pair form - a single 32-bit value as `(HIGH . LOW)' - is the
      ;; C's `format 32, size sizeof(int)' case, which answers a plain
      ;; integer; the pair appears only on the way *out*
      ;; (`clean_local_selection_data').
      ;;--------------------------------------------------------------
      (cond
       ;; "NULL" is the C's `QNULL' - a conversion that happened and has
       ;; no value, which is `xselect-convert-to-delete' and
       ;; `-to-save-targets'.
       ((and type-name (string=? type-name "NULL")) #f)
       ((= format 8)
        (selection-bytes->string bytes))
       ((and (= format 32)
             (or (and type-name (string=? type-name "ATOM"))
                 (and type-name (string=? type-name "ATOM_PAIR"))))
        (let ((atoms
               (map (lambda (off)
                      (gdk-atom-to-symbol (u32-at bytes off)))
                    (iota (quotient size 4)))))
          (if (= size 4)
              (car atoms)
              (list->vector atoms))))
       ((and (= format 32) (= size 4))
        (let ((n (u32-at bytes 0)))
          (if (and type-name (string=? type-name "INTEGER"))
              (if (>= n #x80000000) (- n #x100000000) n)
              n)))
       ((and (= format 16) (= size 2))
        (let ((n (u16-at bytes 0)))
          (if (and type-name (string=? type-name "INTEGER"))
              (if (>= n #x8000) (- n #x10000) n)
              n)))
       ((= format 16)
        (list->vector
         (map (lambda (off)
                (let ((n (u16-at bytes off)))
                  (if (and type-name (string=? type-name "INTEGER"))
                      (if (>= n #x8000) (- n #x10000) n)
                      n)))
              (map (lambda (i) (* i 2)) (iota (quotient size 2))))))
       (else
        (list->vector
         (map (lambda (off)
                (let ((n (u32-at bytes off)))
                  (if (and type-name (string=? type-name "INTEGER"))
                      (if (>= n #x80000000) (- n #x100000000) n)
                      n)))
              (map (lambda (i) (* i 4)) (iota (quotient size 4))))))))

    (define (u16-at bytes off)
      (let ((b (lambda (i) (bytevector-u8-ref bytes (+ off i)))))
        (+ (b 0) (* 256 (b 1)))))

    (define (u32-at bytes off)
      (let ((b (lambda (i) (bytevector-u8-ref bytes (+ off i)))))
        (+ (b 0) (* 256 (b 1)) (* 65536 (b 2)) (* 16777216 (b 3)))))

    (define (selection-bytes->string bytes)
      ;; The C's `(make_unibyte_string (char *) data, size)' and then
      ;; select.el's decode by data type (`gui-get-selection',
      ;; `select.el:391'). The coding system is chosen from the data
      ;; type, which is the same list:
      ;;
      ;;   UTF8_STRING                 utf-8
      ;;   text/plain;charset=utf-8    utf-8
      ;;   COMPOUND_TEXT               compound-text-with-extensions
      ;;   C_STRING                    nil - the bytes as they are
      ;;   STRING                      iso-8859-1
      ;;   anything else               `selection-coding-system' if set,
      ;;                               else a guess, else nothing
      ;;
      ;; Only the two the tree carries are ever reached from a foreign
      ;; selection here: the tree has no compound-text and no `text/`
      ;; guessing. A byte no charset can read comes back as an
      ;; eight-bit code point, which cannot be a Scheme character, so it
      ;; is rendered U+FFFD - `coding.sld''s deviation #4.
      ;;--------------------------------------------------------------
      (let ((decoded (decode-coding-string bytes 'utf-8)))
        (list->string
         (map (lambda (cp)
                (if (< cp #x110000) (integer->char cp) #\xfffd))
              (u32vector->list decoded)))))

    ;;----------------------------------------------------------------
    ;; `pgtk-get-selection-internal', the DEFUN
    ;;----------------------------------------------------------------

    (define *pgtk-selection-alias-alist* (make-parameter '()))
    ;; ^ `Vpgtk_selection_alias_alist': `((ALIAS . REAL) ...)', empty by
    ;; default and settable from Lisp - Emacs's exits so that a program
    ;; can say "when I ask for X, ask for Y instead". Ported because
    ;; `pgtk_get_selection_internal' consults it first; nothing here sets
    ;; it.

    (define (pgtk-get-selection-internal d selection target-type
                                         time-stamp terminal)
      ;; GNU Emacs's `pgtk-get-selection-internal' (`pgtkselect.c:1606'):
      ;;
      ;;     (pgtk-get-selection-internal SELECTION-SYMBOL TARGET-TYPE
      ;;                                  &optional TIME-STAMP TERMINAL)
      ;;
      ;; "Request the selection value from the owner. If we are the
      ;; owner, simply return our selection value. If we are not the
      ;; owner, this will block until all of the data has arrived."
      ;;
      ;; TIME-STAMP and TERMINAL are accepted and unused: the timestamp
      ;; belongs to the `gdk_selection_convert' the C makes and Gtk does
      ;; not take one, and this display *is* the terminal the parameter
      ;; names.
      ;;
      ;; The order is the C's - the alias, then the local read, then the
      ;; foreign one - and the TARGETS vector rule at the end is
      ;; bug#72254's: "A window property holding just one item is
      ;; indistinguishable from an array of one element", so a TARGETS
      ;; answer is always a vector, even when Gtk reports one target.
      ;;--------------------------------------------------------------
      (unless (symbol? selection)
        (error "Wrong type argument: symbolp" selection))
      (unless (symbol? target-type)
        (error "Wrong type argument: symbolp" target-type))
      (if (eq? target-type 'MULTIPLE)
          (error "Retrieving MULTIPLE selections is currently unimplemented")
          (let* ((alias (assq selection (*pgtk-selection-alias-alist*)))
                 (selection (if alias
                                (begin
                                  (unless (symbol? (cdr alias))
                                    (error "Wrong type argument: symbolp"
                                           (cdr alias)))
                                  (cdr alias))
                                selection))
                 (val (pgtk-get-local-selection d selection target-type #t)))
            (if val
                (let ((val (if (and (pair? val) (symbol? (car val)))
                               (let ((v (cdr val)))
                                 (if (and (pair? v) (null? (cdr v)))
                                     (car v)
                                     v))
                               val)))
                  (pgtk-clean-local-selection-data val))
                (let ((v (pgtk-get-foreign-selection d selection target-type
                                                     time-stamp)))
                  (if (and (eq? target-type 'TARGETS)
                           (or (not v) (symbol? v)))
                      (if v (vector v) (vector))
                      v))))))

    (define (pgtk-get-foreign-selection d selection target-type time-stamp)
      ;; GNU Emacs's `pgtk_get_foreign_selection' (`pgtkselect.c:1012')
      ;; and `pgtk_get_window_property_as_lisp_data' (`:1185'), which is
      ;; what `gtk_clipboard_wait_for_contents' + the accessors + the
      ;; decode below are: the C issues `gdk_selection_convert' with the
      ;; TARGET atom, waits for `GDK_SELECTION_NOTIFY', reads the property
      ;; off the requestor window and converts it. Gtk does the first
      ;; three inside the clipboard call and the last is
      ;; `selection-data-to-lisp-data'.
      ;;
      ;; The two messages on failure are the C's, when there is no data:
      ;;
      ;;   "Selection owner couldn't convert: %s"  - someone owns the
      ;;       selection but would not convert to this target;
      ;;   "No selection: %s"                      - nobody owns it.
      ;;
      ;; The C tells them apart with
      ;; `gdk_selection_owner_get_for_display'; GtkClipboard's answer to
      ;; the same question is whether the clipboard offers *any* target,
      ;; which is what `gtk_clipboard_wait_for_targets' asks. Both answer
      ;; nil and say which it was, which is the C's contract.
      ;;
      ;; The C also puts a one-second "Selection owner didn't respond"
      ;; message on an atimer while it waits and times out after
      ;; `pgtk-selection-timeout'. Gtk's wait runs the same main loop and
      ;; hosts the timeout itself, so neither is ported - named, not
      ;; forgotten.
      ;;--------------------------------------------------------------
      (and (pgtk-window d)
           (let ((clip (selection-clipboard selection))
                 (target (selection-atom target-type)))
             (let ((sd (gtk-clipboard-wait-for-contents clip target)))
               (if (or (not sd) (null-pointer? sd))
                   (begin
                     (selection-no-data-message d selection target-type)
                     #f)
                   (let* ((size (gtk-selection-data-get-length sd))
                          (format (gtk-selection-data-get-format sd))
                          (type-name (atom-name-string
                                      (gtk-selection-data-get-data-type sd)))
                          (bytes (if (> size 0)
                                     (pointer->bytevector
                                      (gtk-selection-data-get-data sd)
                                      size 0 'vu8)
                                     (bytevector))))
                     (gtk-selection-data-free sd)
                     (and (>= size 0)
                          (selection-data-to-lisp-data bytes size type-name
                                                       format))))))))

    (define (selection-no-data-message d selection target-type)
      ;; The C's `(if (for_multiple) ... (if (gdk_selection_owner_get_for_display
      ;; ...) "Selection owner couldn't convert" "No selection"))'
      ;; (`pgtkselect.c:1205-1224'). The message goes through the frame
      ;; the display belongs to, as every message in this tree does.
      ;;--------------------------------------------------------------
      (let ((frame (pgtk-frame-for d)))
        (and frame
             (set!frame-message
              frame
              (if (selection-exists? d selection)
                  (string-append "Selection owner couldn't convert: "
                                 (symbol->string target-type))
                  (string-append "No selection: "
                                 (symbol->string selection)))))))

    (define-method (get-selection (d <pgtk-display>) selection target-type)
      ;; Read SELECTION off the display. This is `pgtk-get-selection-internal'
      ;; - the C's DEFUN, called here with no TIMESTAMP and no TERMINAL,
      ;; which is how `gui-get-selection' calls it.
      ;;
      ;; **`TIMESTAMP' is no longer answered #f.** It is the C's special
      ;; case inside `pgtk_get_local_selection': when we own the
      ;; selection its answer is the timestamp recorded with it, and when
      ;; we do not own it there is no local value and the foreign read is
      ;; asked - which is the C's behaviour too, and Gtk answers it from
      ;; the selection's own time.
      ;;--------------------------------------------------------------
      (pgtk-get-selection-internal d selection target-type #f #f))

    (define-method (set-selection! (d <pgtk-display>) selection value)
      ;; Assert SELECTION holding VALUE, or - VALUE #f - disown it,
      ;; which is "there is no such selection". This is
      ;; `pgtk-own-selection-internal' and
      ;; `pgtk-disown-selection-internal' through Gtk:
      ;; `gtk_clipboard_set_text' takes the ownership and sets the
      ;; text, `gtk_clipboard_clear' gives it up - and disowning, as the
      ;; C's, does nothing when we do not own the selection.
      ;;
      ;; VALUE is typically a string. The other simple values
      ;; `gui-set-selection' admits - a symbol, an integer - convert at
      ;; *request* time in the C (`selection-converter-alist', where a
      ;; symbol becomes its name for `STRING'); here the conversion
      ;; happens at assert time, which is the same text a reader gets.
      ;;
      ;; **The local record is the C's four-element list** -
      ;; `(SELECTION VALUE TIMESTAMP FRAME)' (`pgtk_own_selection',
      ;; `pgtkselect.c:151-160', writing `list4 (selection_name,
      ;; selection_value, INT_TO_INTEGER (timestamp), frame)') - because
      ;; that is what `pgtk_get_local_selection' reads back: element 1 is
      ;; the value a converter is called with and element 2 is what a
      ;; `TIMESTAMP' request answers. It used to be a `(SELECTION .
      ;; VALUE)' pair, which had no timestamp to answer with.
      ;;
      ;; The timestamp is `gtk_get_current_event_time''s, with the C's
      ;; fallback when there is no current event (that value is
      ;; GDK_CURRENT_TIME, 0): `dpyinfo->last_user_time'. **That field is
      ;; not ported** - it is refreshed from every input event, and its
      ;; only reader is this timestamp, which nothing in this tree asks
      ;; back (select.el reads a TIMESTAMP only when `window-system' is
      ;; `x', and this front end's is `pgtk'). So the fallback is 0, and
      ;; the full C expression is written out with the missing half
      ;; named rather than left to look like an oversight.
      ;;--------------------------------------------------------------
      (if value
          (let ((text (cond ((string? value) value)
                            ((symbol? value) (symbol->string value))
                            ((integer? value) (number->string value))
                            (else value)))
                (stamp (gtk-get-current-event-time)))
            (gtk-clipboard-set-text (selection-clipboard selection)
                                    (string->pointer text "UTF-8") -1)
            (set! (pgtk-selections d)
                  (cons (list selection value stamp (*current-frame*))
                        (alist-delete selection (pgtk-selections d)))))
          ;; Don't disown the selection when we're not the owner - the
          ;; C's early return, which answers nil.
          (when (assq selection (pgtk-selections d))
            (gtk-clipboard-clear (selection-clipboard selection))
            (set! (pgtk-selections d)
                  (alist-delete selection (pgtk-selections d))))))

    (define-method (selection-owner? (d <pgtk-display>) selection)
      ;; Whether this process owns SELECTION -
      ;; `pgtk-selection-owner-p', which answers from
      ;; `LOCAL_SELECTION': the process's own record of what it has
      ;; asserted, not a question to GDK.
      ;;--------------------------------------------------------------
      (and (pgtk-window d)
           (and (assq selection (pgtk-selections d)) #t)))

    (define-method (selection-exists? (d <pgtk-display>) selection)
      ;; Whether SELECTION has an owner at all, whoever owns it. The C
      ;; asks GDK (`gdk_selection_owner_get_for_display') after its own
      ;; bookkeeping; Gtk's clipboard-level question is
      ;; `gtk_clipboard_wait_is_text_available' - does anyone offer
      ;; text - which is the one the text-selection layer above asks.
      ;;--------------------------------------------------------------
      (and (pgtk-window d)
           (or (and (assq selection (pgtk-selections d)) #t)
               (= 1 (gtk-clipboard-wait-is-text-available?
                     (selection-clipboard selection))))))

    ))
