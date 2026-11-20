(define-library (schemacs editor xdisp)
  ;; This library mirrors GNU Emacs's `xdisp.c': the redisplay. It draws
  ;; each window's rows of text, its mode line and the vertical border
  ;; beside it, then the echo area, then places the terminal cursor. What
  ;; it draws is derived entirely from state it can reach without knowing
  ;; about editing: the buffers the windows show, where their points are,
  ;; and the frame's echo area.
  ;;
  ;; Two things make that true, and both are why this library comes when
  ;; it does. The echo area is the frame's minibuffer *window*, drawn by
  ;; the same window loop as every other window - its buffer is the
  ;; prompt's during a read and the frame's echo buffer otherwise - so the
  ;; renderer has nothing to ask a minibuffer and paints no row by hand.
  ;; And a search match is nothing this library knows about at all: the
  ;; `isearch' and `lazy-highlight' faces reach it as *overlays* on the
  ;; buffer, through the same `attrs-at-buffer-position' every other face
  ;; comes through. A renderer that imported the minibuffer and the search
  ;; would sit in a cycle with them, and this is the knot the layout plan
  ;; cuts here - the search no longer has anything to tell it.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `display' is not in `(scheme base)' - it is `(scheme write)'s - and
    ;; `caddr' is `(scheme cxr)'s. The mode line's evaluator uses both, and
    ;; neither is missed until a mode line is drawn.
    (only (scheme write) display)
    (only (scheme cxr) caddr cadddr)
    ;; `filter' and `sort' order the overlay strings at a position, as
    ;; `load_overlay_strings' does with qsort.
    ;; `inexact->exact' is `posn-at-x-y''s: a mouse event's
    ;; coordinates arrive as inexact numbers and every cell here
    ;; is an exact one - `pgtk.sld''s `pgtk-ensure-surface!' makes
    ;; the same conversion for the same reason.
    (only (guile) delq filter sort string<? inexact->exact format
          ;; `string-pixel-width` measures the widest line of a string
          ;; that holds newlines, as the C's `buffer-text-pixel-size`
          ;; does over the work buffer.
          string-split)
    ;; The display interface: the redisplay draws through these generics
    ;; and never touches a terminal itself. `dispnew.sld' defines them,
    ;; and `term.sld' answers them for the curses terminal.
    (only (schemacs editor dispnew)
         ;; `get_window_cursor_type`'s `cursor_in_echo_area`
         ;; (`dispnew.c:7538`, read at `xdisp.c:34825`).
         *cursor-in-echo-area*
          current-display
          ;; `windows_or_buffers_changed` (`xdisp.c`): set by whoever
          ;; changes a face or forces a redisplay, read by the skip below.
          windows-or-buffers-changed? set-windows-or-buffers-changed!
          ;; `update_mode_lines` (`xdisp.c:775`): the cheaper flag, which
          ;; says only that the mode lines and the frame's menu bar have
          ;; to be recomputed. Set by a window or buffer switch; cleared
          ;; with the other one at the end of `redisplay-frames!`.
          update-mode-lines? set-update-mode-lines!
          write-glyphs! draw-box! face-metrics display-cell-size clear-frame-area!
          clear-end-of-line! ensure-surface!
          update-window-begin! update-window-end!
          update-begin! update-end!
          cursor-to! set-terminal-cursor!
          window-system-display?
          draw-window-cursor! erase-window-cursor! flush-display!
          ;; `FRAME_RIF (f)->define_frame_cursor` (`xdisp.c:36644`): the
          ;; hole that changes the pointer's shape over an area.
          display-define-frame-cursor
          ;; `FRAME_RIF (f)->draw_vertical_window_border` (`dispextern.h`),
          ;; the one-pixel separator a window-system frame draws between
          ;; side-by-side windows when it has no scroll bars.
          display-draw-vertical-border
          ;; The toolkit's scroll bar, which `set-vertical-scroll-bar`
          ;; creates, moves and sizes once per window per redisplay.
          display-set-window-scroll-bar display-redeem-scroll-bars
          realize-face
          lookup-face
          ;; how many pixels a cell is, which is what turns a mouse
          ;; event's coordinates into the cells the windows are
          ;; measured in - see `posn-at-x-y'.
          column-width line-height)
    ;; the markers, from marker.c's own library
    (only (schemacs editor marker) marker-position set-marker)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs editor intervals) make-buffer-string get)
    ;; `symbol-value`'s fallback for a minor mode's variable.
    (only (schemacs editor data) default-value default-boundp)
    
    ;; The line arithmetic is `editfns.c`'s, and it lives there now.
    (only (schemacs editor editfns)
         *message-log-function*
         buffer-substring-no-properties delete-region goto-char insert
         point point-max point-min
         ;; `%n`, the narrowing indicator (`decode_mode_spec`'s `'n'`)
         buffer-narrowed-p
         ;; `reset_outermost_restrictions` and its unwind, as one
         ;; bracket around every redisplay (`xdisp.c:17440`).
         %with-outermost-restrictions
         ;; `mode-line-widen`
         widen
         ;; `:propertize' in the mode line is Emacs's `propertize',
         ;; `editfns.c:3296'.
         propertize
         text-editor-cursor-column
         text-editor-get-end-of-line
         text-editor-get-start-of-line
         ;; `message_dolog` keeps the log buffer's point in a *marker*, so
         ;; that it follows the text it was on when the oldest lines are
         ;; trimmed off the front.
         point-marker)
    ;; The mode-line mouse commands are `bindings.el`'s, and a command is
    ;; what `define-command` makes. `command.scm` is a leaf - it imports
    ;; nothing of this tree but `intervals` - so the renderer can have it.
    (only (schemacs editor command) define-command call-interactively)
    ;; The mode line's *text properties*: `format-mode-line' returns a
    ;; propertized string in Emacs, and `render-window!' draws its runs by
    ;; the faces those properties name. `text-property-list' and
    ;; `add-text-properties-from-list' are what carry the properties
    ;; across the truncation that fits the line to the window.
    (only (schemacs editor textprop)
          get-text-property text-property-list add-text-properties-from-list)
    ;; `concat' is `fns.c`'s and is what joins a mode line's runs - and
    ;; unlike `string-append' it copies the pieces' text properties, as
    ;; the C's does; `pad-line`'s padding goes on through it.
    (only (schemacs editor fns) concat equal-including-properties %substring)
    ;; `string-width` is `character.c`'s, and `string-pixel-width` below
    ;; is the cell-model measurement over it.
    (only (schemacs editor character) string-width)
    ;; `%count-lines' is `xdisp.c''s own (`:29903') and reads straight from
    ;; this file's library - it is placed in `fns.scm' beside the
    ;; `line-number-at-pos' that wants it, because this library is the top
    ;; of the graph and a definition up here could not be reached from
    ;; below. See the note on it there.
    (only (schemacs editor fns) %count-lines)
    (only (schemacs editor frame)
         *current-frame* *echo-area-buffer* *minibuffer*
         *window-scroll-function*
         *frame-cursor-type* *frame-focus* frame-height frame-width
         ;; `string-pixel-width` measures in the frame's cells, and the
         ;; scroll bar's rectangle is in pixels of both axes
         frame-char-width frame-char-height
         ;; `FRAME_MENU_BAR_LINES (f)` - whether this frame draws a bar -
         ;; and `f->menu_bar_vector`, where `display_menu_bar` records the
         ;; column it drew each item at.
         %frame-menu-bar-lines %frame-tab-bar-lines %frame-tool-bar-lines
         ;; `FRAME_HAS_VERTICAL_SCROLL_BARS (f)`, which decides whether a
         ;; separator is drawn between side-by-side windows at all.
         frame-has-vertical-scroll-bars?
         frame-top-margin
         *current-buffer*
         frame-menu-bar-items set!frame-menu-bar-items
         frame-menu-bar-items-used set!frame-menu-bar-items-used
         frame-tab-bar-items set!frame-tab-bar-items
         frame-tab-bar-items-used set!frame-tab-bar-items-used
         frame-tool-bar-items set!frame-tool-bar-items
         frame-tool-bar-items-used set!frame-tool-bar-items-used
         ;; `FRAME_GARBAGED_P` / `SET_FRAME_GARBAGED` (`frame.h:1173`),
         ;; consumed by `clear-garbaged-frames!`.
         frame-garbaged-p set-frame-garbaged! frame-minibuffer-window
         ;; The echo area's buffers are global and `set_message` rotates
         ;; them (`frame.scm`); the renderer displays the current one and
         ;; resizes the window it is in.
         echo-area-message-buffer *resize-mini-windows* *max-mini-window-height*
         grow-mini-window shrink-mini-window
         window-minibuffer-p
         ;; `mode-line-default-help-echo` (`bindings.el:128`) asks whether
         ;; this window is the whole frame, and whether the minibuffer
         ;; window under it can be resized.
         frame-root-window minibuffer-window-active-p
         frame-message frame-selected-window
         ;; `render!' binds the display from the frame it was handed: the
         ;; frame's `output' is Emacs's `output_data', and this is what
         ;; makes it load-bearing rather than a slot nobody reads
         frame-output
         ;; `redisplay-frames!' walks them, as Emacs's redisplay does
         *frame-list*
         ;; `w->cursor_off_p', which `internal-show-cursor' turns off and
         ;; the cursor type is resolved against
         window-cursor-off?
         sync-frame-size! window-body-height window-body-top window-wants-tab-line
         window-tab-line-height window-parameter window-last-tab-line
         set!window-last-tab-line
         window-body-width window-buffer set!window-buffer window-height window-left
         ;; The text area's first column and the bar's share of the
         ;; window: `WINDOW_BOX_LEFT_EDGE_X` and the scroll bar macros.
         window-body-left window-scroll-bar-cols window-left-scroll-bar-cols
         window-vertical-scroll-bar-type window-config-scroll-bar-width
         window-config-scroll-bar-cols window-scroll-bar-width window-live-p
         scroll-bar-adjust-thumb-portion
         *mark-window-redisplay-function*
         window-list
         ;; `WINDOW_XFRAME (w)': the frame a window is on, which is what
         ;; the drawing of a window asks when the frame being drawn is
         ;; not the selected one
         window-frame
         selected-window *selected-window-override* *old-selected-window*
         window-point window-right-border? window-leftmost?
         window-top
         window-width
         ;; `w->start' and everything stored beside it: where the window's
         ;; display begins, where its last glyph was, and the line-number
         ;; cache `%l' counts from
         %window-start set-window-start! set-window-point!
         ;; `w->force_start`: set by `set-window-start!`, honoured and
         ;; cleared by `scroll-to-cursor!` (`xdisp.c:20746`).
         window-force-start? set-window-force-start?!
         ;; the redisplay's own write of `w->start` - see frame.scm
         %window-start-set!
         %window-end-pos %window-end-valid?
         set!%window-end-pos set!%window-end-vpos set!%window-end-valid?
         %window-base-line-number %window-base-line-pos
         set!%window-base-line-number set!%window-base-line-pos
         ;; `w->hscroll' and its friends, which the hscroll display and
         ;; auto hscrolling read and write
         %window-hscroll %window-min-hscroll
         %window-old-point %window-suspend-auto-hscroll?
         set!%window-hscroll
         set!%window-old-point set!%window-suspend-auto-hscroll?
         ;; What the window's matrix was built from, and the question
         ;; `window_outdated` asks about it - the skip below.
         window-outdated?
         window-last-buffer set!window-last-buffer
         window-last-modified set!window-last-modified
         window-last-overlay-modified set!window-last-overlay-modified
         window-last-start set!window-last-start
         window-last-width set!window-last-width
         window-last-height set!window-last-height
         window-last-hscroll set!window-last-hscroll
         window-last-point set!window-last-point
         window-last-mark set!window-last-mark
         window-last-mode-line set!window-last-mode-line
         ;; `mark_window_display_accurate`'s walk over the window tree
         window-internal? window-type? window-children)
    (only (schemacs editor disp-table)
         char-display-cursor-width char-display-width
         char-display-glyph display-text-width)
    ;; `current-line-display-column' is `indent.c''s walk - it moved out of
    ;; `disp-table.sld' on 2026-10-06, when it stopped being a second copy
    ;; of `scan_for_column' and became that function asked one question.
    ;; The line layout and `vertical-motion`, which are `indent.c`'s and
    ;; this renderer's both - one implementation, in the library below
    ;; both of them since 2026-11-07. What this file exports of them it
    ;; imports here, so its own callers keep their names.
    (only (schemacs editor indentc)
          current-line-display-column
          *truncate-partial-width-windows*
          line-display-texts buffer-line-texts-at buffer-line-texts
          window-line-start
          texts-glyph texts-width line-texts-width line-texts-column
          truncate-line pad-line
          window-full-width? window-truncates-lines? window-wraps?
          string->texts line-display-rows line-texts-rows hscroll-line-slice
          window-line-rows-at window-line-rows %window-line-rows
          window-line-slices-at window-line-slices %window-line-slices
          rows-above rows-row-of-column %row-of-position %row-beginning
          vertical-motion line-next-start window-start)
    ;; `mode-line-eol-desc' reads the buffer's coding system: its eol
    ;; half is what the mnemonic is drawn from.
    (only (schemacs editor coding)
          coding-system-eol-type coding-system-p coding-system-mnemonic)
    ;; `%z' names the terminal's coding systems on a terminal frame, and
    ;; `coding-system-eol-type-mnemonic' is `mule.el''s.
    (only (schemacs editor mule)
          terminal-coding-system keyboard-coding-system
          *enable-multibyte-characters*)
    ;; The `face' text property, and the faces themselves. A face reaches
    ;; the display through these libraries and no others: the property
    ;; says which faces are in effect, `xfaces' merges them and folds
    ;; them down, and the display realizes what that means on itself
    ;; (`realize-face').
    (only (schemacs editor textprop)
          get-text-property next-single-property-change
          previous-single-property-change text-properties-at)
    (only (schemacs editor buffer)
          *transient-mark-mode*
          ;; `mark_window_display_accurate_1` records what the rows were
          ;; built from, and `window_outdated` asks for the same two ticks.
          buffer-modified-tick buffer-overlay-modified-tick
          current-buffer get-buffer get-buffer-create with-current-buffer
          text-editor-undo-list set!text-editor-undo-list
          text-editor-cache-long-scans set!text-editor-cache-long-scans
          buffer-auto-hscroll-mode buffer-cursor-in-non-selected-windows
          buffer-cursor-type buffer-hscroll-margin buffer-hscroll-step
          buffer-local-value set-buffer-local-value! buffer-truncate-lines
          buffer-word-wrap local-variable-p
          ;; the buffer's own bounds and text, which the `%l' cache's
          ;; `BEG_UNCHANGED' accessors below read - `BEG' and `Z' are
          ;; `buffer.h:992''s macros and come from their own library, not
          ;; through the engine facade
          *inhibit-read-only*
          fetch-char buffer-beg buffer-z text-editor-text
          ;; `BVAR (b, mark)` - the slot itself, which redisplay reads
          ;; for the buffer it is drawing rather than the current one.
          %mark-marker
          ;; the mode line's mode name is the buffer's `mode-name'
          mode-name
          ;; and the overlays at a position are merged into its face
          overlay-end overlay-get overlay-priority overlay-start
          overlays-at overlays-in
          ;; `face_at_buffer_position`'s `*limit`: the next position a
          ;; face can change is the nearer of this and the next `face`
          ;; property change (`face-change-limit` below)
          next-overlay-change
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char set-point text-editor-buffer-name text-editor-text-props text-editor-file-name buffer-pt buffer-modified-p buffer-read-only?
          ;; `mode-line-toggle-modified`
          set-buffer-modified-p)
    ;; `BEG_UNCHANGED' (`buffer.h:156') is a field of the buffer's *text* -
    ;; `buffer-text' is this tree's `struct buffer_text' - and the two
    ;; accessors below are the only readers and writers of it here.
    (only (schemacs editor buffer-text)
          buffer-text-beg-unchanged set!buffer-text-beg-unchanged
          ;; `BUF_BEG`/`BUF_Z` - the whole text's ends, which is what
          ;; `note_mouse_highlight` falls back to for a run with no
          ;; change at either edge.
          buffer-text-base buffer-text-z)
    ;; `message_dolog`'s `insert_1_both (..., prepare = false, ...)` runs
    ;; with no modification hooks (`xdisp.c:12431`'s own reason), which is
    ;; this parameter's switch - see `prepare-to-modify-buffer-1`.
    (only (schemacs editor insdel) *inhibit-modification-hooks*)
    ;; The row and its glyphs - `struct glyph`/`struct glyph_row`
    ;; (`dispextern.h`), and the two matrices a window keeps.
    (only (schemacs editor glyph)
          <glyph> make-glyph glyph? glyph-type-char
          glyph-char glyph-face-id glyph-pixel-width glyph-voffset
          glyph-padding?
          set-glyph-char! set-glyph-face-id! set-glyph-pixel-width!
          set-glyph-type! set-glyph-padding! set-glyph-voffset!
          <glyph-row> make-glyph-row glyph-row?
          glyph-row-glyphs set-glyph-row-glyphs!
          glyph-row-used set-glyph-row-used!
          glyph-row-hash set-glyph-row-hash!
          glyph-row-enabled? set-glyph-row-enabled!
          glyph-row-mode-line? set-glyph-row-mode-line!
          glyph-row-truncated-on-right?
          set-glyph-row-truncated-on-right!
          glyph-row-continued? set-glyph-row-continued!
          glyph-row-displays-text? set-glyph-row-displays-text!
          glyph-row-ends-at-zv? set-glyph-row-ends-at-zv!
          glyph-row-fill-line? set-glyph-row-fill-line!
          glyph-row-start set-glyph-row-start!
          glyph-row-end set-glyph-row-end!
          glyph-row-x set-glyph-row-x!
          glyph-row-y set-glyph-row-y!
          glyph-row-ascent set-glyph-row-ascent!
          glyph-row-height set-glyph-row-height!
          glyph-row-pixel-width set-glyph-row-pixel-width!
          row-hash)
    (only (schemacs editor matrix)
          glyph-matrix-row-ref glyph-matrix-height glyph-matrix-width
          ;; the row vector, which `rows-above-in-window` walks
          glyph-matrix-rows
          ensure-window-matrices! window-current-matrix window-desired-matrix
          matrix-diff-rows matrix-mark-current! clear-glyph-matrix)

    ;; `overwrite-mode''s two mode-line lighters are `simple.el''s and
    ;; live beside the commands that set the variable; `minor-mode-alist'
    ;; below is what names them.
    (only (schemacs editor simple)
          *overwrite-mode-textual* *overwrite-mode-binary*
          ;; `mode-line-toggle-read-only` is `(read-only-mode 'toggle)`.
          read-only-mode
          ;; the `*Messages*' buffer's own mode, which `message-dolog'
          ;; switches a newly made buffer into
          messages-buffer-mode)
    ;; `run_window_change_functions` is `window.c`'s and lives in
    ;; `window.scm`; `redisplay_internal` calls it (`xdisp.c:17588`), so
    ;; this library calls it in `redisplay-frames!`. `window.scm` reaches
    ;; this one through `simple.scm`, which is a diamond and not a cycle.
    ;;
    ;; `window-at-side-p` is the question the pointer's shape asks
    ;; ("can this window's mode line be dragged?"), and `window.scm`
    ;; holds it for the same reason the mouse commands reach it there.
    (only (schemacs editor window) run-window-change-functions window-at-side-p
          ;; every mode-line command acts on the window that was clicked:
          ;; `(with-selected-window (posn-window (event-start event)) ...)`
          with-selected-window
          ;; the buffer-name item's two commands
          next-buffer previous-buffer)
    ;; `keymapp` decides whether a mode-line string under the pointer is
    ;; a clickable item - if it is, the pointer stays an arrow and the
    ;; mode line is not a resize handle at that glyph
    ;; (`xdisp.c:36805`).
    ;; `mode-line-default-help-echo` is a `bindings.el` defcustom.
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor keymap) keymapp
          ;; `make-mode-line-mouse-map` is a sparse keymap with one entry
          make-sparse-keymap define-key
          ;; `bindings--sort-menu-keymap` walks the toggles map and
          ;; keeps its prompt.
          map-keymap keymap-prompt)
    ;; `minor-mode-alist' is `bindings.el`'s and lives in `subr.scm`,
    ;; beside `add-minor-mode' - **the one function that writes it**. It
    ;; is imported here rather than declared here, which it was until
    ;; 2026-10-14: two `(make-parameter ...)' forms of the same name meant
    ;; the mode line read one and `add-minor-mode' wrote the other, so a
    ;; minor mode registered the Emacs way never reached the mode line.
    (only (schemacs editor subr) *minor-mode-alist* run-hooks
          ;; `note-mouse-highlight` reads a position list the same way the
          ;; mouse commands do - including the string a click landed on,
          ;; which is where a mode-line item's `keymap` and `pointer`
          ;; properties live.
          event-start posn-window posn-point posn-area posn-string
          ;; The seam `event-start`/`event-end` take their point-position
          ;; fallback through; installed at the end of this file.
          *event--posn-at-point-function*
          ;; `mode-line-position`'s `%C` arm rewrites the format string,
          ;; as `mode-line-position`'s `:eval` does in `bindings.el`.
          string-replace)
    ;; `find_newline' (`search.c:675'), which is what the C's
    ;; `scan_newline' is - the line arithmetic `message-dolog' walks the
    ;; log with.
    (only (schemacs editor search) find-newline)
    (only (schemacs editor faces) *undefined-face-attribute*
          ;; `%z' asks whether this frame has a window system behind it,
          ;; and the mode line's `:box` is read with the base face as the
          ;; inheritance source.
          *window-system* face-attribute)
    (only (schemacs editor xfaces)
          attribute-value face-attributes-empty face-realized-attributes
          merge-face-ref merge-face-vectors)
    )

  (export
   *messages-buffer-name* *message-log-max*
   ;; The two hooks a menu bar is refreshed through (`xdisp.c`'s
   ;; DEFVARs, run by the front end's `set_frame_menubar`).
   *activate-menubar-hook* *menu-bar-update-hook*
   ;; `menu_bar_items` as a seam (`keyboard.scm` installs it), the
   ;; recursion guard, and the terminal's bar: `update_menu_bar` builds
   ;; the items and `display_menu_bar` draws the row.
   *menu-bar-items-function* *inhibit-menubar-update*
   *tab-bar-items-function* *tab-bar-keymap-function*
   ;; The tool bar's two seams and its item update (`update_tool_bar`).
   *tool-bar-items-function* *tool-bar-keymap-function* update-tool-bar
   tool-bar-style tool-bar-get-system-style
   ;; The seam a front end fills with the desktop's `toolbar-style`
   ;; setting - Emacs's `current_tool_bar_style`.
   *tool-bar-system-style-function*
   *global-mode-string*
   overlay-arrow-position overlay-arrow-string
   ;; `Vinhibit_redisplay`, bound while a menu is up.
   *inhibit-redisplay*
   update-menu-bar display-menu-bar menu-item-width
   display-tty-menu-item
   ;; What a menu wrote over, for the redisplay that puts it back.
   invalidate-frame-rows!
   ;; `render!' and the mode line are what the rest calls. The search
   ;; highlight used to be here as a parameter; it is isearch's overlays
   ;; now, and the display only reads faces.
   cursor-screen-position
   ;; the run computation, which is what a caller can test without a
   ;; terminal: `draw-line!' itself needs one
   line-face-runs
   line-end-fill-attribute
   ;; Exported for the test that pins Emacs's `extend_face_id` rule, the
   ;; same way `line-end-fill-attribute` is.
   extend-fill-token
   *mode-line-format*
   ;; `files.el`'s, here for the mode line's `%@`; `read-file-name` uses
   ;; it too, to stay on the minibuffer for a remote name.
   file-remote-p
   ;; The window whose mode line is being formatted - the C's rebinding
   ;; of `selected-window' around `display_mode_lines' - and the face
   ;; picker that reads it (`bindings.el:872').
   *mode-line-window* mode-line-window-selected-p
   ;; `bindings.el''s other mode-line variable, and the construct that
   ;; reads it. A minor mode with a lighter adds itself to the alist.
   mode-line-minor-modes
   ;; the two steps of one minor-mode indicator's evaluation, which
   ;; `describe-mode` reads too (`help-fns.el:2348`'s
   ;; `(format-mode-line (assq mode minor-mode-alist))`).
   minor-mode-indicator-value minor-mode-lighter
   face-at-buffer-position
   overlay-strings-at
   face->attribute
   ;; the cursor's type, which the tests check without a display
   get-specified-cursor-type
   get-window-cursor-type
   format-mode-line
   *line-number-display-limit* *line-number-display-limit-width*
   *truncate-partial-width-windows*
   line-display-rows
   line-display-width
   ;; `subr-x.el`'s, for want of a `subr-x` library above `frame.scm`
   string-pixel-width
   mode-line-string
   ;; `bindings.el`'s mode-line items and the commands they name
   make-mode-line-mouse-map
   mode-line-modified mode-line-remote mode-line-narrowed
   propertized-buffer-identification mode-line-buffer-identification
   mode-line-read-only-map mode-line-modified-map mode-line-widen-map
   mode-line-change-eol-map mode-line-buffer-identification-map
   mode-line-toggle-read-only mode-line-toggle-modified mode-line-widen
   mode-line-change-eol mode-line-previous-buffer mode-line-next-buffer
   ;; `bindings.el`'s coding-system item and its help text.
   mode-line-coding-system-map mode-line-mule-info-help-echo
   mode-line-coding-system-describe mode-line-coding-system-set
   *describe-coding-system-function*
   *set-buffer-file-coding-system-command*
   mode-line-read-only-help-echo mode-line-modified-help-echo
   mode-line-remote-help-echo
   ;; `bindings.el:128`'s default help text for the mode line, and the
   ;; option that chooses it.
   mode-line-default-help-echo *mode-line-default-help-echo*
   ;; The major mode's and minor modes' buttons: the two help strings,
   ;; their keymaps, the toggles map and its sorter (`bindings.el:404`),
   ;; and the run a click's flattened string is cut into.
   mode-line-major-mode-help-echo mode-line-minor-mode-help-echo
   mode-line-major-mode-keymap mode-line-minor-mode-keymap
   mode-line-mode-menu bindings--sort-menu-keymap string-property-run-at
   ;; The line and column item and its menu (`bindings.el:620-762`).
   mode-line-column-line-number-mode-map line-column-mode-menu
   mode-line-position--column-line-properties
   *mode-line-position* *mode-line-percent-position*
   *mode-line-position-line-format* *mode-line-position-column-format*
   *mode-line-position-column-line-format*
   *column-number-indicator-zero-based*
   percent99 mode-line-symbol-value
   ;; The two evaluation steps a lighter goes through, which
   ;; `mouse.scm`'s completion table and `help-fns.scm`'s
   ;; `describe-minor-mode` family read.
   minor-mode-variable-true? minor-mode-indicator-value minor-mode-lighter
   render! redisplay-frames! *redisplay-in-progress* *after-redisplay-hook*
   fontification-functions set!fontification-functions!
   force-mode-line-update
   scroll-to-cursor!
   window-scroll window-move-screen-lines
   status-string
   window-end
   pos-visible-in-window-p
   ;; `keyboard.c`'s `posn-at-point` and `subr.el`'s
   ;; `event--posn-at-point`, which is what `event-start` answers for a
   ;; keyboard key.
   posn-at-point event--posn-at-point
   window-line-rows
   window-line-slices
   posn-at-x-y buffer-posn-from-coords
   ;; the mouse face: `note_mouse_highlight`, `mouse-highlight`, and the
   ;; two the renderer's face walk splits on (`*drawing-window*` is the
   ;; binding that says which window's rows are being built)
   note-mouse-highlight clear-mouse-face! mouse-highlight mouse-face-at
   *drawing-window*
   ;; The help-echo machinery of `note_mouse_highlight`: the seam
   ;; `keyboard.scm`'s `show-help-echo` is installed through, and the
   ;; clear the front end calls when the pointer leaves the frame.
   *show-help-echo-function* clear-help-echo!
   help-echo-at string-help-echo-at
   ;; The seam `mode-line-change-eol` reaches `set-buffer-file-coding-system`
   ;; through; `mule-cmds.scm` installs it as it loads (it cannot be
   ;; imported here - `mule-cmds` imports `files`, which imports this).
   *set-buffer-file-coding-system-function*
   ;; the glyph the pointer is on, which is what decides whether a motion
   ;; report is a movement at all - see `remember-mouse-glyph'
   remember-mouse-glyph
   track-mouse
   window-start
   window-truncates-lines?
   vertical-motion
   )

  (begin

    ;; There used to be a `*search-highlight*' parameter here, and before
    ;; that a `window' slot the renderer read: the search commands publish
    ;; what they found and the renderer drew it. It is gone. The search
    ;; highlight is *isearch's overlays* - `isearch-highlight' puts the
    ;; `isearch' face on the current match and the lazy highlighter puts
    ;; `lazy-highlight' on the others, exactly as GNU Emacs does - and the
    ;; display reads them the way it reads every other face, through
    ;; `attrs-at-buffer-position'. The renderer no longer knows that
    ;; searching exists, which is the whole point: it cannot disagree with
    ;; the search about what matched.

    ;;----------------------------------------------------------------
    ;; The `display' text property
    ;;
    ;; GNU Emacs's `handle_display_prop' (`xdisp.c'): a character whose
    ;; `display' property is a string is *drawn* as that string, while the
    ;; buffer keeps the character and every position stays where it was.
    ;; Dired is what asks for it - `dired--insert-disk-space' writes
    ;; ": (15 GiB available)" over the header's colon - and that is the
    ;; STRING branch of the C. The other branches - `(space :align-to
    ;; ...)', images, `(when ...)', `(height ...)', `(raise ...)' - are
    ;; NOT ported, and a `display' value that is not a string is ignored
    ;; here rather than faked: nothing in this tree sets one.
    ;;
    ;; The renderer here draws from a line *string*, so the substitution
    ;; has to be carried beside it. What is carried is a vector with one
    ;; entry per *buffer column* of the line - the column being what every
    ;; slice, face run and cursor position in this file is expressed in,
    ;; so nothing else has to change. An entry is the substituted string
    ;; where the property stands, and the line's own character otherwise;
    ;; the glyph an entry is drawn as, and the number of cells it takes,
    ;; are `texts-glyph' and `texts-width' below.
    ;;
    ;; The character is kept rather than its glyph because a tab's glyph
    ;; depends on the column it is drawn at, and a wrapped row starts at
    ;; screen column zero - see `line-display-rows'.
    ;;------------------------------------------------------------------

    (define (recenter-window-on-cursor! window ed cursor-start vheight)
      ;; Put WINDOW's start half a window's height *backward* from its
      ;; point - GNU Emacs's `recenter:' label (`xdisp.c:21150') at the
      ;; default settings, which is where every window whose point has
      ;; left it ends up.
      ;;
      ;; "Determine the window start relative to point": the C seats the
      ;; display iterator on point and sets
      ;;
      ;;     /* Set the window start half the height of the window
      ;;        backward from point.  */
      ;;     centering_position = window_box_height (w) / 2;
      ;;
      ;; (`xdisp.c:21230'), then walks back that far with
      ;; `move_it_vertically_backward (&it, centering_position)'
      ;; (`:21245') - by *rows*, so a wrapped line counts for the height
      ;; it takes, and it stops on a line beginning.
      ;;
      ;; **Both directions go through it**, and that is the part worth
      ;; having read the C for. `try_scrolling' - the scroll-by-a-few-
      ;; lines path, the one that would move the window by a single line
      ;; - is not even *called* at the default settings:
      ;;
      ;;     if ((0 < scroll_conservatively
      ;;          || 0 < emacs_scroll_step
      ;;          || temp_scroll_step
      ;;          || NUMBERP (scroll_up_aggressively)
      ;;          || NUMBERP (scroll_down_aggressively))
      ;;         && CHARPOS (startp) >= BEGV && ...)
      ;;       { ... try_scrolling ... }
      ;;
      ;; (`xdisp.c:21109'). `scroll-conservatively' and `scroll-step' are
      ;; both 0 and the two `aggressively' variables are both nil, so the
      ;; condition is false and control falls straight through to
      ;; `recenter:' whichever direction point left by. Scrolling by one
      ;; line is what a *configured* Emacs does; the default recentres.
      ;;
      ;; One guard after the walk (`:21250'): if the iterator was carried
      ;; past the top of the window the window starts at the beginning of
      ;; point's own line instead - "If cursor did not appear assume that
      ;; the middle of the window is in the first line of the window."
      ;;--------------------------------------------------------------
      (let loop ((back (quotient vheight 2)) (rows 0) (pos cursor-start))
        (if (or (<= back 0) (= pos (buffer-beg ed)))
            (%window-start-set!
             window (if (>= rows vheight) cursor-start pos))
            (let* ((above (text-editor-get-start-of-line ed (- pos 1)))
                   (tall (window-line-rows-at window above)))
              (loop (- back tall) (+ rows tall) above)))))

    (define (window-move-screen-lines window pos n)
      ;; POS moved N *screen rows* in WINDOW - negative toward the
      ;; beginning, positive toward the end - snapping to line starts as
      ;; Emacs's `move_it_vertically`/`move_it_vertically_backward` do.
      ;;
      ;; **A screen row, not a line.** A wrapped line is several rows,
      ;; and `scroll-down-command` counting *lines* overshot by the
      ;; wrapping factor: in a split window of long lines one PageUp
      ;; moved twenty logical lines - eighty rows - and the redisplay's
      ;; `scroll-to-cursor!` put the window straight back, so the view
      ;; stuck. Measured, 300-character lines in an 80-column terminal:
      ;; `window-start` 5863, 5554, then 5554 for ever.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (if (<= n 0)
            (let loop ((pos pos) (left (- n)))
              (if (or (<= left 0) (= pos (buffer-beg ed)))
                  pos
                  ;; The line before POS: POS is a line beginning, so its
                  ;; predecessor's start is the start of the line holding
                  ;; POS - 1 (the newline that ended it). **Stepping
                  ;; twice, to POS's line and then to the one before it,
                  ;; made every backward move two lines for one** - the
                  ;; scroll path `scroll-down-command`, `M-v` and the
                  ;; scroll bar all share; measured here as a six-line
                  ;; page landing twelve lines up.
                  (let ((prev (if (= pos (buffer-beg ed))
                                  pos
                                  (text-editor-get-start-of-line ed (- pos 1)))))
                    (if (= prev pos)
                        pos
                        (loop prev (- left (window-line-rows-at window prev)))))))
            (let loop ((pos pos) (left n))
              (if (or (<= left 0) (= pos (buffer-z ed)))
                  pos
                  (let* ((end (text-editor-get-end-of-line ed pos))
                         (next (if (< end (buffer-z ed)) (+ end 1) end)))
                    (if (= next pos)
                        pos
                        (loop next (- left (window-line-rows-at window pos))))))))))

    (define (window-scroll window n)
      ;; GNU Emacs's `window_scroll` (`window.c`) as the two commands use
      ;; it: move WINDOW's view N screen lines (negative toward the
      ;; beginning) and keep point in the window.
      ;;
      ;; Answers `moved`, `beginning` or `end`, which is the distinction
      ;; the commands report in the echo area.
      ;;
      ;; Emacs's `window_scroll_pixel_based` scrolls the display down or
      ;; up and then, if point is outside the window, moves it to the
      ;; window's first or last line (`window_scroll_pixel_based`'s
      ;; `display_done`/`set_cursor_from_row` tail). **The point rule is
      ;; what the stall was**: point sat below the window, the command
      ;; judged it visible because the judgment counted lines, and the
      ;; next redisplay's `scroll-to-cursor!` scrolled back.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (old (marker-position (%window-start window)))
             (vheight (window-body-height window))
             (new (window-move-screen-lines window old n)))
        (cond
         ((= new old) (if (> n 0) 'end 'beginning))
         (else
          (%window-start-set! window new)
          (let ((point (buffer-pt ed))
                (bottom (window-move-screen-lines window new vheight)))
            (when (or (< point new) (>= point bottom))
              (set-point ed (if (> n 0)
                                new
                                ;; **The last line that *starts* in the
                                ;; window**, not the line 23 rows on: a
                                ;; line start that many rows down is on
                                ;; the first row below the window, so
                                ;; the redisplay judged point invisible
                                ;; and recentred straight back - the
                                ;; stall again, one row out.
                                (last-visible-line-start window new vheight)))))
          'moved))))

    (define (set-vertical-scroll-bar window)
      ;; GNU Emacs's `set_vertical_scroll_bar` (`xdisp.c:20271`): tell the
      ;; toolkit what WINDOW's vertical scroll bar should show, creating
      ;; or moving the widget as the window's rectangle has changed.
      ;;
      ;; The C computes the distances first, and its three facts are the
      ;; buffer's accessible range, the window's start and its end:
      ;;
      ;;   whole = ZV - BEGV
      ;;   start = marker_position (w->start) - BEGV
      ;;   end   = Z - w->window_end_pos - BEGV
      ;;
      ;; `w->window_end_pos` is "Z minus the position of the last glyph",
      ;; which is exactly this tree's `window-end` - recorded as the rows
      ;; are built. The mini window with no echo-area text answers zeros,
      ;; which makes the toolkit draw a full-length thumb.
      ;;--------------------------------------------------------------
      (let* ((frame (window-frame window))
             (side (window-vertical-scroll-bar-type window))
             (bar-cols (if side (window-config-scroll-bar-cols window) 0))
             (cw (frame-char-width frame))
             (ch (frame-char-height frame))
             (left (if (eq? side 'left)
                       (window-left window)
                       (- (+ (window-left window) (window-width window))
                          bar-cols)))
             (data
              (let ((buffer (window-buffer window)))
                (if (not (and buffer (window-live-p window)))
                    (list 0 0 0)
                    (let* ((beg (buffer-beg buffer))
                           (zv (buffer-z buffer))
                           (end (- (window-end window) beg))
                           (start (- (window-start window) beg))
                           (whole (- zv beg)))
                      (when (< end start) (set! end start))
                      (when (< whole (- end start))
                        (set! whole (- end start)))
                      (list (- end start) start whole))))))
        ;; **The bar's box is the text area, not the window's whole
        ;; rectangle.** `pgtk_set_vertical_scroll_bar` asks
        ;; `window_box (w, ANY_AREA, 0, &window_y, 0, &window_height)`
        ;; (`pgtkterm.c:4248`), and `window_box_height` excludes the mode
        ;; line (and the tab and header lines), while its Y is the window
        ;; top *plus* those lines (`xdisp.c:1463-1479`). Sizing the bar to
        ;; the whole window made two stacked windows' bars join across the
        ;; mode line row, where Emacs draws the mode line out to the frame
        ;; edge.
        (display-set-window-scroll-bar
         (current-display) window side
         (* left cw) (* (window-body-top window) ch)
         (* bar-cols cw) (* (window-body-height window) ch)
         (car data) (cadr data) (caddr data))))

    (define (last-visible-line-start window start vheight)
      ;; The start of the last line of WINDOW that begins within its
      ;; VHEIGHT rows, walking from START - the position
      ;; `window_scroll_pixel_based` leaves point on when it scrolls the
      ;; display down (Emacs's `move_it_vertically_backward` from the
      ;; bottom lands on such a line).
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (let loop ((pos start) (used 0) (last start))
          (let ((next (line-next-start ed pos))
                (rows (window-line-rows-at window pos)))
            (if (or (not next) (>= (+ used rows) vheight))
                last
                (loop next (+ used rows) next))))))

    (define (scroll-to-cursor! window)
      ;; Adjust WINDOW's start so that its point is visible, as GNU
      ;; Emacs's redisplay does before drawing each window.
      ;;
      ;; "Visible" means the cursor's *screen row*, not its buffer line:
      ;; a wrapped line is several rows tall, so a window whose start is
      ;; a line has to be able to say that the cursor's line begins above
      ;; it and the cursor's own row does not. A window's start is always
      ;; a line beginning - Emacs's `start_at_line_beg', which is what
      ;; ordinary scrolling gives - so the start is a line and its rows
      ;; follow from it.
      ;;
      ;; When point is not visible the answer is
      ;; `recenter-window-on-cursor!', in *either* direction - which is
      ;; `redisplay_window`'s whole start decision at the default
      ;; settings. This function's job is the one thing that decision
      ;; needs from the display: whether the cursor's own row is on the
      ;; screen, which is a question about rows and not about lines.
      ;;--------------------------------------------------------------
      ;; **The point of *this window*, not of the buffer.** The C's
      ;; redisplay asks `window_point (w)' for the position a window is
      ;; to be scrolled to (`xdisp.c:16809'):
      ;;
      ;;   if (w == XWINDOW (selected_window)) pt = PT;
      ;;   else pt = clip_to_bounds (BEGV, marker_position (w->pointm), ZV);
      ;;
      ;; Reading the buffer's own cursor instead is what made two frames
      ;; on one buffer scroll as one: every frame's window was scrolled
      ;; to the buffer's point, and only the selected window's point is
      ;; the buffer's. Measured on Emacs 31.1 with point at 300 in a
      ;; 24-row frame: the selected frame's start is 232 and the other
      ;; frame's is still 1.
      ;; **The window's point and start are clipped to the accessible
      ;; range, as the C clips both.** `window_point` does
      ;; `pt = clip_to_bounds (BEGV, marker_position (w->pointm), ZV)`
      ;; (`xdisp.c:16812`); `redisplay_window` clamps its `startp` the
      ;; same way before anything is laid out (`:20781`: "if (CHARPOS
      ;; (startp) < BEGV) SET_TEXT_POS (startp, BEGV, BEGV_BYTE); else if
      ;; (CHARPOS (startp) > ZV) ..."). **A narrowing moves BEGV/ZV and
      ;; leaves both markers where they were** - markers are not clipped
      ;; by narrowing, measured on Emacs 31.1: `window-start` is still 1
      ;; after narrowing to 9..15 - so both clamps are the ordinary case
      ;; after `C-x n n`, not a corner. Without them the row walk below
      ;; read positions before BEGV, where `fetch-char` answers #f, and
      ;; that #f reached `char-display-width`: the Gtk redisplay died
      ;; with "Wrong type argument" after `C-x n n` and a keystroke.
      (let* ((ed (window-buffer window))
             (vheight (window-body-height window))
             (pt (max (buffer-beg ed) (min (window-point window) (buffer-z ed))))
             (start (max (buffer-beg ed) (min (window-start window) (buffer-z ed)))))
        (if (window-force-start? window)
            (begin
              ;; **`w->force_start`: the window starts where Lisp put
              ;; it.** `set-window-start` sets the flag (`window.c:1968`)
              ;; and `redisplay_window`'s `force_start:` label
              ;; (`xdisp.c:20746`) lays out from that start without
              ;; asking whether point is in view; if it is not, the C
              ;; moves *point* into the window instead - "Give up and
              ;; just move to the middle of the window" (`:20823`).
              ;; Without this the recentring below fought every caller
              ;; of `set-window-start`: a scroll bar dragged to the
              ;; middle of a buffer snapped straight back to point's
              ;; line on the very redisplay the drag's own `sit-for`
              ;; asked for.
              (set-window-force-start?! window #f)
              ;; The end position belongs to the row *after* the last
              ;; one drawn, which is not visible - the same strict test
              ;; the fast path below makes.
              (let ((bottom (window-move-screen-lines window start vheight)))
                (unless (and (<= start pt) (< pt bottom))
                  (set-point ed (window-move-screen-lines
                                 window start (quotient vheight 2)))))
              #t)
        ;; **The matrix drawn last time already answers it, when it is
        ;; still valid.** GNU Emacs's `try_cursor_movement`
        ;; (`xdisp.c:20700`) is this check: while point stays inside the
        ;; window's recorded text and nothing about the window has
        ;; changed, the cursor's row is on the screen because it was on
        ;; the screen a moment ago - no layout needed. Without it every
        ;; redisplay laid the window's lines out from its start to point
        ;; to count the rows, which on Gtk measured 1.5 ms and 325 KB of
        ;; garbage per keystroke *even when nothing had changed* (the
        ;; cursor-blink repaint paid it too). `(< pt end)` and not `<=`:
        ;; a position equal to the recorded end belongs to the row after
        ;; the last one drawn, which is the case that must scroll - and
        ;; it is rare enough to leave to the walk.
        (if (and (window-matrix-valid? window)
                 (<= start pt)
                 (< pt (window-end window)))
            #t
            (let ((cursor-start (text-editor-get-start-of-line ed pt)))
              (cond
               ((< cursor-start start)
                ;; point's line begins above the window, so point is not
                ;; visible
                (recenter-window-on-cursor! window ed cursor-start vheight))
               (else
                ;; walk down from the start to the cursor's line, counting
                ;; rows
                (let loop ((pos start) (used 0))
                  (cond
                   ((>= used vheight)
                    ;; the cursor's line has fallen off the bottom
                    (recenter-window-on-cursor! window ed cursor-start
                                                vheight))
                   ((= pos cursor-start)
                    ;; the cursor's line: visible only if its own row is
                    (let ((k (rows-row-of-column
                              (window-line-slices-at window pos)
                              (- pt cursor-start))))
                      (when (>= (+ used k) vheight)
                        ;; its row is below the window, so point is not
                        ;; visible
                        (recenter-window-on-cursor! window ed cursor-start
                                                    vheight))))
                   (else
                    (let ((next (line-next-start ed pos)))
                      ;; visible as it stands, or the walk ran past the end
                      ;; of the buffer, where there is nothing below to draw
                      (if next
                          (loop next
                                (+ used (window-line-rows-at window pos)))
                          #t))))))))))))

    (define (hscroll-window! window)
      ;; Auto hscrolling: bring WINDOW's point back into the window's
      ;; horizontal view when it has left it, before the window is drawn.
      ;; This is GNU Emacs's `hscroll_window_tree' (`xdisp.c:16625'),
      ;; which redisplay runs on every window before their matrices are
      ;; rebuilt, with the settings it reads off the buffer:
      ;; `auto-hscroll-mode' (t by default), `hscroll-margin' (5) and
      ;; `hscroll-step' (0).
      ;;
      ;; What it does, in the C's order:
      ;;
      ;;   * auto hscrolling that `scroll-left'/`scroll-right' suspended
      ;;     resumes when the window's point has moved since the last
      ;;     redisplay (`xdisp.c:16756': `w->suspend_auto_hscroll' clears
      ;;     when `window-point' differs from `old_pointm'), and the
      ;;     point is then remembered for the next comparison;
      ;;   * the cursor is in a *scroll margin* - within HSCROLL-MARGIN
      ;;     columns of the window's left edge while the window is
      ;;     already hscrolled, or within it of the right edge while the
      ;;     row is truncated there (`xdisp.c:16791-16800') - and the
      ;;     amount is then computed from the position of point on a line
      ;;     of infinite width.
      ;;
      ;; The amount is `hscroll-step''s: the default 0 means put point at
      ;; the window's horizontal centre (`xdisp.c:16851-16860',
      ;; `hscroll = max (0, it.current_x - text_area_width / 2)'), and a
      ;; measured `emacs -nw' confirms it: point at column 239 in an
      ;; 80-column window made `window-hscroll' 199 and the cursor sat in
      ;; column 40. The C's at-end-of-line variant (`text_area_width -
      ;; 4 * column_width' for the wanted position, `:16857') is not
      ;; ported: the iterator stops on the character at point, never on
      ;; the line break, and a point on the line break was measured
      ;; centring anyway (`goto-char' onto the break of a 250-column line
      ;; gave hscroll 210 = 250 - 80/2). The C's third trigger, for
      ;; `auto-hscroll-mode' = `current-line', belongs to that mode and
      ;; that mode is not ported.
      ;;
      ;; One knowing deviation: the C measures point's position from the
      ;; *cursor row of the previous redisplay* and converges over two
      ;; redisplays when point has moved to another line (a move onto a
      ;; short line from an hscrolled one resets the hscroll there). Here
      ;; the position is the point's own line's, so the same steady state
      ;; is reached in the one redisplay this renderer does.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (h (%window-hscroll window))
             (point (window-point window)))
        (when (and (%window-suspend-auto-hscroll? window)
                   (not (equal? point (%window-old-point window))))
          ;; "If the position of this window's point has explicitly
          ;; changed, no more suspend auto hscrolling" (`xdisp.c:16756')
          (set!%window-suspend-auto-hscroll? window #f))
        (set!%window-old-point window point)
        ;; **Nothing to decide when the window cannot be hscrolled.**
        ;; The two triggers below are "already hscrolled and the cursor
        ;; is in the left margin" and "the row is truncated at the right
        ;; edge and the cursor is in that margin". In a *wrapping*
        ;; window (`truncate-lines` off, the default) the second cannot
        ;; apply, and with `hscroll` 0 the first cannot either - so the
        ;; whole computation is skipped, and with it a layout of the
        ;; cursor's line on every redisplay. Measured on Gtk: the
        ;; cursor-line walk (`buffer-line-texts-at` and `scan_for_column`)
        ;; was ~1 ms and most of the allocation of a keystroke that had
        ;; changed nothing at all.
        (when (and (buffer-auto-hscroll-mode ed)
                   (or (> h 0) (not (window-wraps? window))))
        ;; The column is the *window's* point's, as the C's is
        ;; (`xdisp.c:16809' reads `marker_position (w->pointm)' for a
        ;; window that is not the selected one) - the buffer's own
        ;; cursor is only this window's point when it is the selected
        ;; one, so hscrolling a second frame's window would otherwise
        ;; follow the first frame's cursor.
        (let* ((start-of-point (text-editor-get-start-of-line ed point))
               (texts (buffer-line-texts-at window start-of-point))
               (width (window-body-width window))
               (margin (max 0 (buffer-hscroll-margin ed)))
               (point-x (if texts
                            (current-line-display-column
                             ed (- point start-of-point))
                            0))
               (cursor-x (max 0 (- point-x h)))
               (truncated-right?
                (and texts
                     (not (window-wraps? window))
                     (> (line-texts-width texts) (+ h width -1))))
               (step (buffer-hscroll-step ed))
               (wanted
                ;; `hscroll-step' 0 - neither a float nor a positive
                ;; integer is ported - centres point
                (quotient width 2))
               (new-h (max (max 0 (- point-x wanted))
                           (%window-min-hscroll window))))
          (when (and (not (%window-suspend-auto-hscroll? window))
                     (or (and (> h 0) (<= cursor-x margin))
                         (and truncated-right?
                              (>= cursor-x (- width margin))))
                     (not (= new-h h)))
            (set!%window-hscroll window new-h))))))

    (define *mode-line-window* (make-parameter #f))

    (define (mode-line-window-selected-p)
      ;; GNU Emacs's `mode-line-window-selected-p' (`bindings.el:872'):
      ;; "Return non-nil if we're updating the mode line for the selected
      ;; window. This function is meant to be called in `:eval' mode line
      ;; constructs to allow altering the look of the mode line depending
      ;; on whether the mode line belongs to the currently selected window
      ;; or not."
      ;;
      ;; The C compares `(selected-window)' against `old-selected-window',
      ;; because `display_mode_lines' *rebinds* `selected-window' to the
      ;; window whose mode line it is drawing and keeps the real one in
      ;; `old-selected-window' (`xdisp.c:29099'). This renderer does not
      ;; rebind `selected-window' - it binds `*mode-line-window*' around
      ;; the `format-mode-line' call - so the two sides are the same
      ;; comparison with the names the other way round.
      ;;
      ;; The C's second arm, a minibuffer active on some other window,
      ;; has no counterpart: the prompt is drawn on the selected frame
      ;; alone and `with-selected-window' is not ported.
      ;;--------------------------------------------------------------
      (eq? (selected-window) (*old-selected-window*)))

    ;;----------------------------------------------------------------
    ;; The mode line as a set of buttons - `bindings.el`'s own commands
    ;;----------------------------------------------------------------
    ;;
    ;; `mode-line-modified`, `mode-line-remote`, `%n` and the buffer
    ;; identification are *propertized strings* in Emacs: a `local-map`
    ;; (or `keymap`) property makes the characters a button and a
    ;; `mouse-face` makes them light up under the pointer. This renderer
    ;; honours both already - the click path reads the clicked string's
    ;; maps (`lookup-keymaps`, `keyboard.scm`) and `draw-mode-line!`
    ;; paints the `mouse-face` run - so what was missing was the
    ;; constructs themselves and the commands they name.
    ;;
    ;; **The `help-echo` properties are displayed by
    ;; `note_mouse_highlight`** (at the end of this file): Emacs shows
    ;; them through `show-help-function` (`keyboard.c:2259`) and
    ;; `tooltip.el`, and both are ported now.

    (define (mode-line-default-help-echo window)
      ;; GNU Emacs's `mode-line-default-help-echo` (`bindings.el:128`):
      ;; "Return default help echo text for WINDOW's mode line."
      ;;
      ;; This is the help a stretch of the mode line with no `help-echo`
      ;; property of its own shows - the C hangs it off the window as
      ;; `w->mode_line_help_echo` when the mode line is formatted and
      ;; `note_line_or_margin_highlight` falls back to it. The four
      ;; conditions are the C's, each spelling out when a mouse button
      ;; would do something: select the window, drag its bottom edge,
      ;; make it the only window, delete it.
      ;;--------------------------------------------------------------
      (let* ((frame (window-frame window))
             (line-1a
              ;; "Show text to select window only if the window is not
              ;; selected."
              (not (eq? window (frame-selected-window frame))))
             (line-1b
              ;; "Show text to drag mode line if either the window is not
              ;; at the bottom of its frame or the minibuffer window of
              ;; this frame can be resized." The check matches a
              ;; corresponding one in `mouse-drag-mode-line`.
              (or (not (window-at-side-p window 'bottom))
                  (let ((mini-window (frame-minibuffer-window frame)))
                    (and (eq? frame (window-frame mini-window))
                         (or (minibuffer-window-active-p mini-window)
                             (not (*resize-mini-windows*)))))))
             (line-2
              ;; "Show text make window occupy the whole frame only if it
              ;; doesn't already do that."
              (not (eq? window (frame-root-window frame))))
             (line-3
              ;; "Show text to delete window only if that's possible."
              (not (eq? window (frame-root-window frame)))))
        ;; The `if` is not a `when`: Elisp's nil for "no help" must be
        ;; `#f`, and this function's answer is passed to `(string? ...)`
        ;; - a `when` that does not fire answers the *unspecified* value,
        ;; which is true in Scheme.
        ;;
        ;; **Every piece is an `if` and not a `when`.** Elisp's `concat`
        ;; reads nil as "contributes nothing", which `(fns.c)`'s port
        ;; spells with `#f`; the *unspecified* value a `when` answers
        ;; when its test fails is not nil, and `concat` rejects it
        ;; ("Wrong type argument: sequencep"). This is the `when`-as-a-
        ;; value trap the handoffs name, met inside a `concat`.
        (if (or line-1a line-1b line-2 line-3)
            (concat
             (if (or line-1a line-1b)
                 (concat
                  "mouse-1: "
                  (if line-1a "Select window" #f)
                  (if line-1b
                      (if line-1a " (drag to resize)" "Drag to resize")
                      #f)
                  (if (or line-2 line-3) "\n" #f))
                 #f)
             (if line-2
                 (concat
                  "mouse-2: Make window occupy whole frame"
                  (if line-3 "\n" #f))
                 #f)
             (if line-3 "mouse-3: Remove window from frame" #f))
            #f)))

    (define-custom *mode-line-default-help-echo* mode-line-default-help-echo
      "Default help text for the mode line.
If the value is a string, it specifies the tooltip or echo area
message to display when the mouse is moved over the mode line.
If the value is a function, call that function with one argument
- the window whose mode line to display.  If the text at the
mouse position has a `help-echo' text property, that overrides
this variable."
      :type '(choice (const :tag "No help" :value nil)
                     function
                     (string :tag "Text"))
      :group 'mode-line)

    (define *set-buffer-file-coding-system-function* (make-parameter #f))

    (define *set-buffer-file-coding-system-command* (make-parameter #f))
    ;; ^ The *command* - `bindings.el`'s coding-system item mouse-3 calls
    ;; it interactively, so it needs the prompt, which the one-argument
    ;; seam above does not have. `mule-cmds.scm` installs both.

    (define *describe-coding-system-function* (make-parameter #f))
    ;; ^ `describe-coding-system` (`mule-diag.el:408`), which is
    ;; `mule-diag.scm`'s and above this library; installed as it loads.
    ;; ^ The seam `mode-line-change-eol` reaches `set-buffer-file-coding-system`
    ;; through. That function is `mule-cmds.scm`'s, and `mule-cmds`
    ;; imports `files` and `minibuffer`, which import this library - so
    ;; the call has to come *down* from there, as `barf-if-buffer-read-only`
    ;; comes down into `command.scm`. `mule-cmds.scm` installs it as it
    ;; loads; a session without that library gets an error naming the
    ;; function, which is the honest report.

    (define (make-mode-line-mouse-map mouse function)
      ;; GNU Emacs's `make-mode-line-mouse-map` (`bindings.el:30`):
      ;; "Return a keymap with single entry for mouse key MOUSE on the
      ;; mode line. MOUSE is defined to run function FUNCTION with no
      ;; args in the buffer corresponding to the mode line clicked."
      ;;--------------------------------------------------------------
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line mouse) function)
        map))

    (define-command (mode-line-toggle-read-only event)
      "Like toggling `read-only-mode', for the mode-line."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (read-only-mode 'toggle)))

    (define-command (mode-line-toggle-modified event)
      "Toggle the buffer-modified flag from the mode-line."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (set-buffer-modified-p (not (buffer-modified-p)))
        (force-mode-line-update)))

    (define-command (mode-line-widen event)
      "Widen a buffer from the mode-line."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (widen)
        (force-mode-line-update)))

    (define-command (mode-line-change-eol event)
      "Cycle through the various possible kinds of end-of-line styles."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (let* ((eol (coding-system-eol-type
                     (buffer-local-value (current-buffer)
                                         'buffer-file-coding-system
                                         'utf-8-unix)))
               (set (or (*set-buffer-file-coding-system-function*)
                        (error "~a"
                               (string-append
                                "`set-buffer-file-coding-system' is not"
                                " available (import (schemacs editor mule-cmds))")))))
          ;; `(cond ((eq eol 0) 'dos) ((eq eol 1) 'mac) (t 'unix))` in the
          ;; C, whose eol types are the integers this tree spells as
          ;; symbols - an undecided eol (`#f`) takes the same `unix`
          ;; branch there and here.
          (set (cond ((eq? eol 'unix) 'dos)
                     ((eq? eol 'dos) 'mac)
                     (else 'unix))))))

    ;; The buffer-name commands, `bindings.el:874-884`: a click on the
    ;; name goes to the previous buffer and mouse-3 to the next, in the
    ;; *clicked* window.

    (define-command (mode-line-previous-buffer event)
      "Like `previous-buffer', but temporarily select EVENT's window."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        ;; `(previous-buffer)` in Emacs: the default count, and the quiet
        ;; arm - this tree's commands take the optional arguments
        ;; explicitly (the `split-window-below` rule).
        (previous-buffer #f #f)))

    (define-command (mode-line-next-buffer event)
      "Like `next-buffer', but temporarily select EVENT's window."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (next-buffer #f #f)))

    (define mode-line-read-only-map
      (make-mode-line-mouse-map 'mouse-1 mode-line-toggle-read-only))
    (define mode-line-modified-map
      (make-mode-line-mouse-map 'mouse-1 mode-line-toggle-modified))
    (define mode-line-widen-map
      (make-mode-line-mouse-map 'mouse-2 mode-line-widen))
    (define mode-line-change-eol-map
      (make-mode-line-mouse-map 'mouse-1 mode-line-change-eol))

    ;; The coding-system item's map - `bindings.el:74-88`. Emacs binds
    ;; two anonymous `(lambda (e) (interactive "e") ...)` functions;
    ;; here they are named commands, because a binding in this tree is a
    ;; procedure and only a command has an interactive specification.
    (define-command (mode-line-coding-system-describe event)
      "Describe WINDOW's buffer coding system from the mode line."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (let ((coding (buffer-local-value (window-buffer (selected-window))
                                          'buffer-file-coding-system
                                          'utf-8-unix)))
          (when (and (*enable-multibyte-characters*) coding)
            ((or (*describe-coding-system-function*)
                 (error "~a"
                        (string-append
                         "`describe-coding-system' is not available"
                         " (import (schemacs editor mule-diag))")))
             coding)))))

    (define-command (mode-line-coding-system-set event)
      "Set the buffer coding system from the mode line."
      (interactive "e")
      (with-selected-window (posn-window (event-start event))
        (let ((command (*set-buffer-file-coding-system-command*)))
          (if command
              (call-interactively command)
              (error "~a"
                     (string-append
                      "`set-buffer-file-coding-system' is not available"
                      " (import (schemacs editor mule-cmds))"))))))

    (define mode-line-coding-system-map
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line 'mouse-1)
                    mode-line-coding-system-describe)
        (define-key map (vector 'mode-line 'mouse-3)
                    mode-line-coding-system-set)
        map))

    (define (mode-line-mule-info-help-echo window object point)
      ;; GNU Emacs's `mode-line-mule-info-help-echo` (`bindings.el:188`):
      ;; "Return help text specifying WINDOW's buffer coding system."
      ;;--------------------------------------------------------------
      (with-current-buffer (window-buffer window)
        (let ((coding (buffer-local-value (current-buffer)
                                          'buffer-file-coding-system
                                          ;; `%z` reads it the same way,
                                          ;; with the same literal: the
                                          ;; variable is `files.scm`'s,
                                          ;; above this library.
                                          'utf-8-unix)))
          (if coding
              (format #f
                      (string-append
                       "Buffer coding system (~a): ~a\n"
                       "mouse-1: Describe coding system\n"
                       "mouse-3: Set coding system")
                      (if (*enable-multibyte-characters*) "multi-byte" "unibyte")
                      coding)
              "Buffer coding system: none specified"))))

    (define mode-line-buffer-identification-map
      ;; `bindings.el:775`'s `defvar-keymap` less its header-line half
      ;; (this tree has no header line): mouse-1 is the previous buffer,
      ;; mouse-3 the next. Emacs also binds the header line's `down-`
      ;; events to `ignore` "so that the global keymap won't shine
      ;; through"; the mode line needs none, its `down-mouse-1` being the
      ;; drag handle - and an unbound press on this map is disposed of by
      ;; the C's mouse-event fallback anyway.
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line 'mouse-1) mode-line-previous-buffer)
        (define-key map (vector 'mode-line 'mouse-3) mode-line-next-buffer)
        map))

    ;; The mode name's and the lighters' buttons - `bindings.el:571-596`.
    ;;
    ;; **Departure**: Emacs binds the two menus as `(menu-item ... :filter
    ;; ...)` values and `read_char`'s menu prompting pops the keymap a
    ;; filter answers. This tree has neither the filter arm in a key
    ;; lookup nor the menu-prompting path, so the presses are bound to
    ;; the commands `mouse.scm` defines that build the same menu and pop
    ;; it at the click (`mouse-menu-major-mode-menu`,
    ;; `mode-line-minor-mode-menu`). `mouse.el`'s own menu builders -
    ;; `mouse-menu-major-mode-map`, `bindings--sort-menu-keymap` - are
    ;; the C code, ported where they belong.

    (define mode-line-major-mode-help-echo
      ;; `bindings.el:600`
      "Major mode\nmouse-1: Display major mode menu\nmouse-2: Show help for major mode\nmouse-3: Toggle minor modes")

    (define mode-line-minor-mode-help-echo
      ;; `bindings.el:539`
      "Minor mode\nmouse-1: Display minor mode menu\nmouse-2: Show help for minor mode\nmouse-3: Toggle minor modes")

    (define mode-line-major-mode-keymap
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line 'down-mouse-1)
                    'mouse-menu-major-mode-menu)
        (define-key map (vector 'mode-line 'mouse-2) 'describe-mode)
        (define-key map (vector 'mode-line 'down-mouse-3)
                    'mode-line-minor-mode-menu)
        map))

    (define mode-line-minor-mode-keymap
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line 'down-mouse-1)
                    'mouse-minor-mode-menu)
        (define-key map (vector 'mode-line 'mouse-2)
                    'mode-line-minor-mode-help)
        (define-key map (vector 'mode-line 'down-mouse-3)
                    'mode-line-minor-mode-menu)
        map))

    ;; `bindings.el:404-460', the toggles menu and its sort. The entries
    ;; Emacs has whose modes this tree carries, with the same labels,
    ;; help strings and `:button` forms - less the ones this tree's
    ;; imports reach, which is what keeps a click from signalling.
    ;;
    ;; **The `:button` expressions name this tree's readers.** Emacs's
    ;; minor-mode variable and command share one symbol; here the
    ;; command is a procedure and the state is a buffer-local slot
    ;; whose accessor is the reader (`buffer-overwrite-mode`,
    ;; `font-lock-mode-on?`, `buffer-auto-fill-function`) - and
    ;; `menu-item-eval-property` evaluates the form in the ambient
    ;; module, the editor's user environment, which `imports.scm`
    ;; fills. A user's own `imports.scm` that omits a library disables
    ;; the item quietly, the same rule the menu-bar items live by.
    (define mode-line-mode-menu
      (let ((map (make-sparse-keymap "Minor Modes")))
        (define-key map (vector 'auto-fill-mode)
          '(menu-item "Auto fill (Fill)" auto-fill-mode
                      :help "Automatically insert new lines"
                      :button (:toggle . (buffer-auto-fill-function
                                          (current-buffer)))))
        (define-key map (vector 'font-lock-mode)
          '(menu-item "Font Lock" font-lock-mode
                      :help "Syntax coloring"
                      :button (:toggle . (font-lock-mode-on?))))
        (define-key map (vector 'overwrite-mode)
          '(menu-item "Overwrite (Ovwrt)" overwrite-mode
                      :help "Overwrite mode: typed characters replace existing text"
                      :button (:toggle . (buffer-overwrite-mode
                                          (current-buffer)))))
        map))

    (define (bindings--menu-item-string item)
      ;; GNU Emacs's `bindings--menu-item-string` (`bindings.el:404`):
      ;; "Return the menu-item string for ITEM, or nil if not a
      ;; menu-item." `(eval name t)` is the string itself for the
      ;; menus here, whose item names are literals.
      (cond
       ((and (pair? item) (eq? (car item) 'menu-item) (pair? (cdr item)))
        (let ((name (cadr item)))
          (and (string? name) name)))
       ((and (pair? item) (string? (car item)))
        (car item))
       (else #f)))

    (define (bindings--sort-menu-keymap map)
      ;; GNU Emacs's `bindings--sort-menu-keymap` (`bindings.el:410`);
      ;; "Sort the bindings in MAP in alphabetical order by menu-item
      ;; string. The order of bindings in a keymap matters only when it
      ;; is used as a menu."
      ;;
      ;; **The answer is a record keymap here**, where Emacs `nconc`s a
      ;; list keymap onto a fresh one: `x-popup-menu` takes the record.
      ;; The sorted entries are defined back to front, because
      ;; `define-key` prepends and a menu draws in the map's own order.
      (let ((bindings '())
            (prompt (keymap-prompt map)))
        (map-keymap
         (lambda (key item)
           (set! bindings (cons (cons key item) bindings)))
         map)
        (let ((sorted (sort bindings
                            (lambda (a b)
                              (string<? (or (bindings--menu-item-string (cdr a))
                                            "")
                                        (or (bindings--menu-item-string (cdr b))
                                            "")))))
              (out (make-sparse-keymap prompt)))
          (for-each
           (lambda (entry)
             (define-key out (vector (car entry)) (cdr entry)))
           (reverse sorted))
          out)))

    ;;----------------------------------------------------------------
    ;; The line and column item - `bindings.el:620-762'
    ;;----------------------------------------------------------------
    ;;
    ;; `mode-line-position` is what decides whether the line and column
    ;; show at all, and the percentages in front of them. The three
    ;; modes are `simple.scm`'s; their values are read through the
    ;; construct's symbol conditionals, which `mode-line-symbol-value`
    ;; resolves.

    (define mode-line-column-line-number-mode-map
      ;; `bindings.el:620`'s keymap. **Departure**: Emacs binds
      ;; `[mode-line down-mouse-1]` to the menu keymap itself and
      ;; `read_char`'s menu prompting pops it; this tree has no such
      ;; prompting, so the press is bound to the command `mouse.scm`
      ;; defines (`mode-line-line-column-menu`) - the same shape as the
      ;; mode name's and the lighters' menus.
      (let ((map (make-sparse-keymap)))
        (define-key map (vector 'mode-line 'down-mouse-1)
                    'mode-line-line-column-menu)
        map))

    (define line-column-mode-menu
      ;; The `menu-map` of `bindings.el:621-636', less the header-line
      ;; half. The `:button` forms name the modes' generated readers,
      ;; for the reason `mode-line-mode-menu`'s do.
      (let ((menu-map (make-sparse-keymap
                       "Toggle Line and Column Number Display")))
        (define-key menu-map (vector 'size-indication-mode)
          '(menu-item "Display Size Indication" size-indication-mode
                      :help "Toggle displaying a size indication in the mode-line"
                      :button (:toggle . (size-indication-mode-variable))))
        (define-key menu-map (vector 'line-number-mode)
          '(menu-item "Display Line Numbers" line-number-mode
                      :help "Toggle displaying line numbers in the mode-line"
                      :button (:toggle . (line-number-mode-variable))))
        (define-key menu-map (vector 'column-number-mode)
          '(menu-item "Display Column Numbers" column-number-mode
                      :help "Toggle displaying column numbers in the mode-line"
                      :button (:toggle . (column-number-mode-variable))))
        menu-map))

    (define mode-line-position--column-line-properties
      ;; `bindings.el:721`'s `defconst`, the properties the line and
      ;; column text carries.
      (list 'local-map mode-line-column-line-number-mode-map
            'mouse-face 'mode-line-highlight
            'help-echo "Line number and Column number\nmouse-1: Display Line and Column Mode Menu"))

    (define-custom *mode-line-percent-position* '(-3 "%p")
      "Specification of \"percentage offset\" of window through buffer.
This option specifies both the field width and the type of offset
displayed in `mode-line-position', a component of the default
`mode-line-format'.

 nil        -- do not display the percentage offset
 '(-3 \"%o\") -- size of text above the window top as percentage of
                   text outside the window
 '(-3 \"%p\") -- size of text above the window top as percentage of
                   all the buffer text
 '(-3 \"%P\") -- size of text above the window bottom as percentage
                   of all the buffer text
 '(6 \"%q\")  -- percentage offsets of both top and bottom of the
                   window, separated by a dash"
      :type '(choice (const :tag "No percentage" nil)
                     (cons integer string))
      :version "28.1"
      :group 'mode-line)

    (define-custom *mode-line-position-line-format* '(" L%l")
      "Format used to display line numbers in the mode line.
This is used when `line-number-mode' is switched on.  The \"%l\"
format spec will be replaced by the line number.

Also see `mode-line-position-column-line-format'."
      :type '(list string)
      :version "28.1"
      :group 'mode-line)

    (define-custom *mode-line-position-column-format* '(" C%c")
      "Format used to display column numbers in the mode line.
This is used when `column-number-mode' is switched on.  The
\"%c\" format spec is replaced by the zero-based column number,
and \"%C\" is replaced by the one-based column number.

Also see `mode-line-position-column-line-format'."
      :type '(list string)
      :version "28.1"
      :group 'mode-line)

    (define-custom *mode-line-position-column-line-format* '(" (%l,%c)")
      "Format used to display combined line/column numbers in the mode line.
This is used when `column-number-mode' and `line-number-mode' are
switched on.  The \"%c\" format spec will be replaced by the
column number, which is zero-based if
`column-number-indicator-zero-based' is non-nil, and one-based if
`column-number-indicator-zero-based' is nil."
      :type '(list string)
      :version "28.1"
      :group 'mode-line)

    (define-custom *column-number-indicator-zero-based* #t
      "When non-nil, mode line displays column numbers zero-based.

This variable has effect only when Column Number mode is turned on,
which displays column numbers in the mode line."
      :type 'boolean
      :group 'mode-line)

    (define-custom *mode-line-position*
      (list
       (append (list ':propertize (list "" 'mode-line-percent-position))
               (list 'local-map mode-line-column-line-number-mode-map
                     'mouse-face 'mode-line-highlight
                     'help-echo "Window Scroll Percentage\nmouse-1: Display Line and Column Mode Menu"))
       (list 'size-indication-mode
             (list 8 (propertize " of %I"
                                 'local-map mode-line-column-line-number-mode-map
                                 'mouse-face 'mode-line-highlight
                                 'help-echo "Size indication mode\nmouse-1: Display Line and Column Mode Menu")))
       (list 'line-number-mode
             (list 'column-number-mode
                   (list 'column-number-indicator-zero-based
                         (list 10 (append
                                   (list ':propertize
                                         'mode-line-position-column-line-format)
                                   mode-line-position--column-line-properties))
                         (list 10 (append
                                   (list ':propertize
                                         (list ':eval
                                               (lambda ()
                                                 (string-replace
                                                  "%c" "%C"
                                                  (car (*mode-line-position-column-line-format*))))))
                                   mode-line-position--column-line-properties)))
                   (list 6 (append
                            (list ':propertize
                                  'mode-line-position-line-format)
                            mode-line-position--column-line-properties)))
             (list 'column-number-mode
                   (list 'column-number-indicator-zero-based
                         (list 6 (append
                                  (list ':propertize
                                        'mode-line-position-column-format)
                                  mode-line-position--column-line-properties))
                         (list 6 (append
                                  (list ':propertize
                                        (list ':eval
                                              (lambda ()
                                                (string-replace
                                                 "%c" "%C"
                                                 (car (*mode-line-position-column-format*))))))
                                  mode-line-position--column-line-properties))))))
      "Mode line construct for displaying the position in the buffer.
Normally displays the buffer percentage and, optionally, the
buffer size, the line number and the column number."
      :type 'sexp
      :group 'mode-line)

    ;; The help text `bindings.el` hangs on these items. They read their
    ;; window rather than the current buffer, which is the C's contract
    ;; for a `help-echo` function - `(WINDOW OBJECT POS)`.

    (define (mode-line-read-only-help-echo window object point)
      "Return help text specifying WINDOW's buffer read-only status."
      (format #f "Buffer is ~a\nmouse-1: Toggle"
              (if (buffer-read-only? (window-buffer window))
                  "read-only"
                  "writable")))

    (define (mode-line-modified-help-echo window object point)
      "Return help text specifying WINDOW's buffer modification status."
      (format #f "Buffer is ~amodified\nmouse-1: Toggle modification state"
              (if (buffer-modified-p (window-buffer window)) "" "not ")))

    (define (mode-line-remote-help-echo window object point)
      (let ((dir (buffer-local-value (window-buffer window)
                                     'default-directory #f)))
        (if (string? dir)
            (string-append (if (file-remote-p dir)
                               "Current directory is remote: "
                               "Current directory is local: ")
                           dir)
            "Current directory is nil")))

    (define mode-line-modified
      ;; GNU Emacs's `mode-line-modified` (`bindings.el:251`): `%1*` for
      ;; the read-only flag and `%1+` for the modified one, each with its
      ;; own map and the highlight face. The `%1*` expansion inherits
      ;; these properties through `inherit-mode-line-properties`, which
      ;; is the C's `display_mode_element` applying the enclosing
      ;; string's properties to what a `%` produces.
      ;; **The `help-echo` values are the functions, not their symbols.**
      ;; `bindings.el` writes `'help-echo 'mode-line-read-only-help-echo`,
      ;; and Emacs resolves the symbol through its obarray because
      ;; `FUNCTIONP` is true for a symbol with a function definition.
      ;; This tree has no function obarray, so the value is the procedure
      ;; itself - the same choice a keymap here makes when it holds a
      ;; command. `show-help-echo` calls a procedure value and evaluates
      ;; anything else.
      (list (propertize "%1*"
                        'help-echo mode-line-read-only-help-echo
                        'local-map mode-line-read-only-map
                        'mouse-face 'mode-line-highlight)
            (propertize "%1+"
                        'help-echo mode-line-modified-help-echo
                        'local-map mode-line-modified-map
                        'mouse-face 'mode-line-highlight)))

    (define mode-line-remote
      ;; GNU Emacs's `mode-line-remote` (`bindings.el:269`): `%1@` with a
      ;; highlight face and a help string that says whether the buffer's
      ;; directory is remote.
      (list (propertize "%1@"
                        'mouse-face 'mode-line-highlight
                        'help-echo mode-line-remote-help-echo)))

    (define mode-line-narrowed
      ;; The `%n` element of Emacs's `mode-line-modes` (`bindings.el:605`)
      ;; with its map: "mouse-2: Remove narrowing from buffer".
      (propertize " Narrow"
                  'help-echo "mouse-2: Remove narrowing from buffer"
                  'mouse-face 'mode-line-highlight
                  'local-map mode-line-widen-map))

    (define (propertized-buffer-identification fmt)
      ;; GNU Emacs's `propertized-buffer-identification` (`bindings.el:786`):
      ;; "Return a list suitable for `mode-line-buffer-identification'.
      ;; FMT is a format specifier such as \"%12b\". This function adds
      ;; text properties for face, help-echo, and local-map to it."
      ;;--------------------------------------------------------------
      (list (propertize fmt
                        'face 'mode-line-buffer-id
                        'help-echo
                        "Buffer name\nmouse-1: Previous buffer\nmouse-3: Next buffer"
                        'mouse-face 'mode-line-highlight
                        'local-map mode-line-buffer-identification-map)))

    (define mode-line-buffer-identification
      ;; GNU Emacs's `mode-line-buffer-identification` (`bindings.el:797`),
      ;; whose default is `(propertized-buffer-identification "%12b")`.
      (propertized-buffer-identification "%12b"))

    (define (mode-line-eol-desc)
      ;; The mode-line mnemonic for the EOL convention of WINDOW's buffer:
      ;; GNU Emacs's `mode-line-eol-desc' (`bindings.el:101'), which reads
      ;; `coding-system-eol-type' of `buffer-file-coding-system'.
      ;;
      ;; **It is the coding system's *eol type* and not a `line-break-*'
      ;; value**, which is what this read while the buffer's variable held
      ;; an eol convention instead of a coding system. The mnemonics are
      ;; `coding-system-eol-type-mnemonic''s (`mule.el'): `":"' for UNIX,
      ;; `"(DOS)"' for DOS and `"(Mac)"' for Mac, with an undecided eol
      ;; giving `eol-mnemonic-undecided', which is `":"' too.
      ;;
      ;; **The mnemonic is a button**: Emacs propertizes it with a
      ;; `keymap` for `mode-line-change-eol` and the highlight face, and
      ;; the help string names the convention. Emacs caches the string
      ;; per eol (`mode-line-eol-desc-cache`); a mode line is formatted
      ;; once per redisplay and the string is a handful of characters, so
      ;; the cache is not worth its state here.
      ;;--------------------------------------------------------------
      (let* ((window (*mode-line-window*))
             (cs (buffer-local-value (window-buffer window)
                                     'buffer-file-coding-system
                                     'utf-8-unix))
             (eol (coding-system-eol-type cs))
             (desc (cond ((eq? eol 'dos) "(DOS)")
                         ((eq? eol 'mac) "(Mac)")
                         (else ":"))))
        (propertize desc
                    'help-echo
                    (format #f "End-of-line style: ~a\nmouse-1: Cycle"
                            (cond ((eq? eol 'unix) "Unix-style LF")
                                  ((eq? eol 'dos) "DOS-style CRLF")
                                  ((eq? eol 'mac) "Mac-style CR")
                                  (else "Undecided")))
                    'keymap mode-line-change-eol-map
                    'mouse-face 'mode-line-highlight)))

    (define (mode-line-mode-name)
      ;; GNU Emacs's `mode-line-modes'' first element: the buffer's
      ;; `mode-name' between the delimiters `mode-line-modes-delimiters'
      ;; names - "(" and ")" by default, which is what makes a mode line
      ;; read `(Fundamental)'.
      ;;
      ;; GNU Emacs's `mode-line-modes` (`bindings.el:596') is
      ;; "(" MODE-NAME MODE-LINE-PROCESS %n MODE-LINE-MINOR-MODES ")" -
      ;; the lighters go *inside* the parentheses, which is what makes a
      ;; mode line read `(Fundamental Ovwrt)`. The two lighters start
      ;; with their own space, so nothing separates the name from them.
      ;;
      ;; Not ported from that construct: `mode-line-process` (no process
      ;; support) and the mouse maps on the name.
      ;;
      ;; **`%n` sits between the lighters and the `)`**, as the C's
      ;; construct has it, and is written out here rather than left as a
      ;; `%`-construct: this function builds the string the formatter
      ;; already expanded, so a `"%n"` in it would be printed as it
      ;; stands. A user's own `*mode-line-format*` that names `%n` gets it
      ;; from `mode-line-construct`.
      ;;--------------------------------------------------------------
      (let ((window (*mode-line-window*)))
        (if (not window)
            ""
            ;; `concat`, not `string-append`: the `%n` element is a
            ;; propertized string and only `concat` keeps its properties
            ;; (the `%1*` rule again).
            ;;
            ;; The mode name is the major-mode *button*: `bindings.el`'s
            ;; `(:propertize ("" mode-name) help-echo "Major mode..."
            ;; mouse-face mode-line-highlight local-map
            ;; mode-line-major-mode-keymap)` (`:601-611`).
            (concat "("
                    (propertize (mode-name (window-buffer window))
                                'mouse-face 'mode-line-highlight
                                'help-echo mode-line-major-mode-help-echo
                                'local-map mode-line-major-mode-keymap)
                    (mode-line-minor-modes)
                    (if (buffer-narrowed-p) mode-line-narrowed "")
                    ")"))))


    (define (minor-mode-indicator-value buffer indicator)
      ;; The *first* of the two evaluations an indicator goes through.
      ;; `minor-mode-alist` says "STRING need not be a string; any
      ;; mode-line construct is okay" - and `overwrite-mode`'s really is
      ;; not one: it is the symbol of the same name, which is the
      ;; *variable*, so what it stands for is that variable's value in
      ;; this buffer. That value is itself a symbol,
      ;; `overwrite-mode-textual` or `overwrite-mode-binary`, which
      ;; `minor-mode-lighter` below takes the second step on.
      ;;
      ;; Both steps collapsed into one is a bug worth naming: the
      ;; indicator was handed straight to `minor-mode-lighter`, which
      ;; looked for `overwrite-mode-textual` and was given
      ;; `overwrite-mode`, so every lighter came out empty and the mode
      ;; line said `(Fundamental)` in overwrite mode.
      ;;
      ;; **A list indicator is a mode-line construct and is evaluated**:
      ;; `text-scale-mode`'s is `(" " text-scale-mode-lighter)`, a space
      ;; and that variable's value in the buffer - which is how the
      ;; lighter reads ` +2`. The elements are evaluated and joined.
      ;;--------------------------------------------------------------
      (cond
       ((string? indicator) indicator)
       ((pair? indicator)
        (apply string-append
               (map (lambda (element)
                      (cond ((string? element) element)
                            ((symbol? element)
                             (let ((value (buffer-local-value buffer element #f)))
                               (if (string? value) value "")))
                            (else "")))
                    indicator)))
       ;; `symbol-value`'s rule: a buffer's own value if it has one,
       ;; otherwise the variable's *default* - which is where a `:global`
       ;; minor mode keeps its state (`default-value`, `data.scm`).
       ((symbol? indicator)
        (buffer-local-value buffer indicator (default-value indicator #f)))
       (else #f)))

    (define (minor-mode-lighter value)
      ;; The *second* evaluation: the symbol a variable held stands for
      ;; the string of the same name - `overwrite-mode-textual` is both
      ;; the name of the symbol and the name of the variable holding
      ;; " Ovwrt" (`simple.el:9384').
      ;;--------------------------------------------------------------
      (cond
       ((string? value) value)
       ((eq? value 'overwrite-mode-textual) *overwrite-mode-textual*)
       ((eq? value 'overwrite-mode-binary) *overwrite-mode-binary*)
       (else "")))

    (define (minor-mode-variable-true? buffer variable)
      ;; Whether VARIABLE - the first half of a `*minor-mode-alist*`
      ;; entry - is on in BUFFER. Emacs asks whether the variable is
      ;; bound and non-nil; this tree has no variable registry, so it is
      ;; asked of the buffer's own slots, where a `define-minor-mode`
      ;; mode's variable lives.
      ;;
      ;; `overwrite-mode` is not a flag: its value is the *kind* of
      ;; overwrite, `overwrite-mode-textual` or `-binary`, which is a
      ;; symbol and so true - the same answer the slot read gives, and
      ;; the one Emacs's `symbol-value` gives.
      ;;
      ;; The fallback is `symbol-value`'s: a variable with no local
      ;; value reads its *default*, which is where a `:global` minor
      ;; mode's state lives.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer variable (default-value variable #f)))

    (define (mode-line-minor-modes)
      ;; GNU Emacs's `mode-line-minor-modes` (`bindings.el:468`), which
      ;; is `(:eval (mode-line--minor-modes))`: the lighters of the minor
      ;; modes that are on, concatenated.
      ;;
      ;; `mode-line--minor-modes` computes more than this - the
      ;; `mode-line-collapse-minor-modes` hiding, and the clickable menu
      ;; `mode-line--make-lighter-menu` makes - and neither is carried:
      ;; the hiding is a 31.1 option nothing here sets, and the menu is
      ;; `mouse.scm`'s `minor-mode-menu-from-indicator`, bound on the
      ;; lighters' own map below.
      ;;--------------------------------------------------------------
      (let ((window (*mode-line-window*)))
        (if (not window)
            ""
            (let ((buffer (window-buffer window)))
              ;; "Minor mode\nmouse-1: Display minor mode menu\n..." -
              ;; `mode-line--minor-modes`' propertized `("" ,visible)`
              ;; (`bindings.el:544-552`).
              ;;
              ;; **One string per lighter, not one for the group.** In
              ;; Emacs each element of `("" ,visible)` is its own string
              ;; object, so `posn-object` over a lighter is that lighter
              ;; - which is what lets `mouse-minor-mode-menu` find the
              ;; one clicked (measured: a click on the third lighter of
              ;; `(Fundamental Ovwrt Fill)` answers `" Fill"`). This
              ;; renderer flattens the line, so `mode-line-lighter` - an
              ;; index, the stand-in for that identity, as
              ;; `mode-line-elt-no` is for a format element - marks each
              ;; lighter's run, and the posn and hover walks stop at it.
              ;; `concat`, not `string-append`: the per-lighter
              ;; properties below would be dropped by the latter (the
              ;; `%1*` rule again).
              (apply concat
                     (let loop ((entries (*minor-mode-alist*))
                                (index 0)
                                (acc '()))
                       (if (null? entries)
                           (reverse acc)
                           (let* ((entry (car entries))
                                  (lighter
                                   (if (minor-mode-variable-true? buffer (car entry))
                                       (minor-mode-lighter
                                        (minor-mode-indicator-value buffer
                                                                    (cadr entry)))
                                       "")))
                             (loop (cdr entries)
                                   (+ index 1)
                                   (cons (if (string=? lighter "")
                                             ""
                                             (propertize
                                              lighter
                                              'mouse-face 'mode-line-highlight
                                              'help-echo
                                              mode-line-minor-mode-help-echo
                                              'local-map
                                              mode-line-minor-mode-keymap
                                              'mode-line-lighter index))
                                         acc))))))))))

    (define (mode-line-front-space)
      ;; GNU Emacs's `mode-line-front-space' (`bindings.el:185'): "Mode
      ;; line construct to put at the front of the mode line." It is
      ;; `(:eval (if (display-graphic-p) " " "-"))' - a space in a window
      ;; and a dash on a terminal, and the dash is what makes a terminal
      ;; mode line read `-UUU:--' rather than starting at the mnemonic.
      ;;--------------------------------------------------------------
      (if (graphical-frame?) " " "-"))

    (define (mode-line-mule-info)
      ;; GNU Emacs's `mode-line-mule-info' (`bindings.el:203'): "Mode line
      ;; construct to report the multilingual environment. Normally it
      ;; displays current input method (if any activated) and mnemonics of
      ;; the following coding systems: coding system for saving or writing
      ;; the current buffer / coding system for keyboard input (on a text
      ;; terminal) / coding system for terminal output (on a text
      ;; terminal)."
      ;;
      ;; Emacs's is `("" (current-input-method ...) "%z" (:eval
      ;; (mode-line-eol-desc)))'. The input-method part is a conditional
      ;; construct on a variable and there are no input methods here, so
      ;; what is left is the two that matter - and they are spelled out
      ;; rather than named, because a symbol in this tree's format
      ;; resolves to nothing (see `*mode-line-format*').
      ;;--------------------------------------------------------------
      ;; The `%z` element carries the coding-system item's map, help
      ;; and highlight - `bindings.el:216-220`'s `(propertize "%z"
      ;; 'help-echo 'mode-line-mule-info-help-echo 'mouse-face
      ;; 'mode-line-highlight 'local-map mode-line-coding-system-map)`.
      ;; `expand-mode-line-string` copies a literal run's properties and
      ;; the `%z` construct's text inherits them, as `%1*` does.
      (list (propertize "%z"
                        'help-echo mode-line-mule-info-help-echo
                        'mouse-face 'mode-line-highlight
                        'local-map mode-line-coding-system-map)
            (list ':eval mode-line-eol-desc)))

    (define *global-mode-string*
      ;; GNU Emacs's `global-mode-string` (`bindings.el`): "String that
      ;; appears in mode line of each buffer. Variable `mode-line-format'
      ;; refers to it; modes that want to display something in the mode
      ;; line append to it (`display-time-mode` puts the clock there)."
      ;;
      ;; **Nothing here appends to it yet** - there is no
      ;; `display-time-mode` - so it is the empty list, and
      ;; `tab-bar-format-global` draws nothing from it, which is what
      ;; Emacs does before the clock is turned on.
      ;;
      ;; A parameter, as `*mode-line-format*` beside it is: a mode
      ;; `setq`s it and the redisplay reads it, and a plain variable read
      ;; by a compiled library is folded to its load-time value.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define overlay-arrow-position #f)
    ;; ^ GNU Emacs's `overlay-arrow-position' (`xdisp.c:38716'): "Marker
    ;; for where to display an arrow on top of the buffer text. This
    ;; must be the beginning of a line in order to work."
    ;;
    ;; A plain variable, as the C declares it - `occur--set-arrow' sets
    ;; it and `next-error` would. **The renderer does not draw overlay
    ;; arrows**: the C's `display_line` prepends `overlay-arrow-string`
    ;; to a line whose position matches an entry of
    ;; `overlay-arrow-variable-list`, and that walk is not ported. The
    ;; variable is carried so the commands that set it mean what they
    ;; say and a later renderer has something to read.

    (define overlay-arrow-string "=>")
    ;; ^ GNU Emacs's `overlay-arrow-string' (`xdisp.c:38724').

    (define *mode-line-format*
      ;; GNU Emacs's `mode-line-format': the template a window's mode line is
      ;; drawn from, evaluated by `FORMAT-MODE-LINE' below.
      ;;
      ;; The default is GNU Emacs's own for the parts this editor can show:
      ;; `mode-line-modified' (`("%1*" "%1+")' in `bindings.el', which is the
      ;; two-cell `--', `**' or `%%'), the buffer name in a twelve-wide field
      ;; (`mode-line-buffer-identification', `("%12b")' - a field that pads a
      ;; short name and leaves a long one alone), then the line and column
      ;; of the window's own point (`mode-line-position').
      ;;
      ;; Emacs's default also names variables in the format -
      ;; `mode-line-mule-info', `mode-line-position', `mode-line-modes'
      ;; and so on - and a symbol element is evaluated and its value
      ;; processed as a construct. `mode-line-position` is named that
      ;; way now that `mode-line-symbol-value` reads the three
      ;; registries the tree keeps (buffer slots, global defaults,
      ;; custom readers); the rest of the default is still spelled out
      ;; where this tree's construct is a function rather than a
      ;; variable.
      ;;--------------------------------------------------------------
      (make-parameter
       ;; `mode-line-front-space' and `mode-line-mule-info' first, which
       ;; is where Emacs's default puts them: the dash, then the coding
       ;; system mnemonics, then the end-of-line mnemonic - so a terminal
       ;; mode line reads `-UUU:' with a UTF-8 buffer in a UTF-8 terminal.
       ;;
       ;; **No space between the mnemonics and the flags**, and that is
       ;; measured rather than chosen: Emacs draws `-UU-:---' for an LF
       ;; file and `-UU-(DOS)---' for a CRLF one, so the end-of-line
       ;; mnemonic runs straight into `mode-line-modified'. This tree had
       ;; a space there and a test that pinned it, which is how a wrong
       ;; space becomes load-bearing.
       (list (list ':eval mode-line-front-space)
             (list ':eval mode-line-mule-info)
             mode-line-modified
             ;; `mode-line-remote', which Emacs has right here - between
             ;; `mode-line-modified' and `mode-line-window-dedicated'.
             mode-line-remote
             " "
             ;; `mode-line-buffer-identification' (`bindings.el:797`):
             ;; `%12b` carrying the `mode-line-buffer-id` face, so a
             ;; theme's colour for the buffer name is applied and the
             ;; default one makes it bold - and the map that makes a
             ;; click on the name go to the previous buffer.
             mode-line-buffer-identification
             ;; `mode-line-position' - named, as Emacs's default format
             ;; names it. A symbol element is evaluated and its value
             ;; processed as a construct (`mode-line-symbol-value`).
             'mode-line-position
       ;; and the mode name, where Emacs's default puts `mode-line-modes':
       ;; after the position, two spaces along. Emacs names the variable
       ;; in the format and evaluates it; there is no variable registry
       ;; here, so the construct that produces it is spelled out.
       "  "
       (list ':eval mode-line-mode-name))))

    (define *line-number-display-limit*
      ;; GNU Emacs's `line-number-display-limit' (`xdisp.c:38806'):
      ;; "Maximum buffer size for which line number should be displayed.
      ;; If the buffer is bigger than this, the line number does not
      ;; appear in the mode line. A value of nil means no limit." Nil by
      ;; default, which is `#f' here.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *line-number-display-limit-width*
      ;; GNU Emacs's `line-number-display-limit-width' (`xdisp.c:38812'):
      ;; "Maximum line width (in characters) for line number display. If
      ;; the average length of the lines near point is bigger than this,
      ;; then the line number may be omitted from the mode line." 200.
      ;;--------------------------------------------------------------
      (make-parameter 200))

    (define (buffer-beg-unchanged ed)
      ;; GNU Emacs's `BEG_UNCHANGED' (`buffer.h:156'): how many characters
      ;; at the beginning of the buffer are known not to have changed
      ;; since `set!buffer-beg-unchanged!' was last called. The `%l' cache
      ;; is only good while this still reaches past the line it remembers:
      ;;
      ;;     #define BASE_LINE_NUMBER_VALID_P(w)                      \
      ;;        (!current_buffer->clip_changed                     \
      ;;         && BEG_UNCHANGED >= (w)->base_line_pos)          \
      ;;
      ;; (`xdisp.c:19393').
      ;;
      ;; **Both accessors live here because both of the C's ends of this
      ;; field are `xdisp.c`'s.** The read is that validity rule, and the
      ;; write is `xdisp.c:18327`'s `BUF_BEG_UNCHANGED (b) = BUF_GPT (b)
      ;; - BUF_BEG (b)` - "everything is current as of now". `insdel.c`
      ;; shrinks the field as it modifies (`:1607', `:1749', `:2060') and
      ;; does that through `buffer-text` directly, which is where the
      ;; field really is.
      ;;--------------------------------------------------------------
      (buffer-text-beg-unchanged (text-editor-text ed)))

    (define (set!buffer-beg-unchanged! ed)
      ;; Say that everything the buffer holds is current as of now, so
      ;; that `buffer-beg-unchanged' counts from here. The C does this
      ;; from `mark_window_display_accurate_1', once per redisplay
      ;; (`xdisp.c:18327'); here the only reader is the `%l' cache, so it
      ;; is done when that cache is written - the same statement, made at
      ;; the one moment it is needed.
      ;;--------------------------------------------------------------
      (set!buffer-text-beg-unchanged
       (text-editor-text ed)
       (- (buffer-z ed) (buffer-beg ed))))

    (define (mode-line-line-number window)
      ;; What `%l' prints: the line point is on, counting from 1 - GNU
      ;; Emacs's `decode_mode_spec`'s `'l'` case (`xdisp.c:29580`), whose
      ;; answer is `topline + nlines'. TOPLINE is the line the window's
      ;; *start* is on; NLINES is `count_lines (w->start, PT)'. Counting
      ;; from the window's start rather than from `point-min' is what
      ;; keeps the construct cheap - the same count measured 20.3ms from
      ;; `point-min' against 0.033ms from the window's start.
      ;;
      ;; TOPLINE would itself be another such count from `point-min', and
      ;; that is precisely what `w->base_line_number' and
      ;; `w->base_line_pos' exist to avoid: a line *somewhere above* the
      ;; window whose number is known, so that only the distance from it
      ;; to the window has to be counted. The cache is refreshed when it
      ;; has grown too near or too far from the window, and abandoned -
      ;; `base_line_pos' set to -1 - for a window whose lines are too
      ;; long to find one in.
      ;;
      ;; The cache is only good while nothing *before the line it names*
      ;; has changed: a line number counts from `point-min', so an edit
      ;; above the cached line moves it, while an edit below does not.
      ;; The C tests exactly that, as
      ;;
      ;;     !clip_changed && BEG_UNCHANGED >= w->base_line_pos
      ;;
      ;; (`BASE_LINE_NUMBER_VALID_P', `xdisp.c:19393'), and discards the
      ;; cache when it fails. Without the test the number goes stale and
      ;; the mode line quietly shows the wrong line - measured at 160 of
      ;; 400 randomly-edited states before this was added.
      ;;
      ;; Answers #f where the C prints "??": when the buffer is over
      ;; `line-number-display-limit', or when the cache was abandoned.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (startpos (window-start window))
             (height (window-body-height window))
             (base-pos (%window-base-line-pos window))
             (limit (*line-number-display-limit*))
             (toobig (and limit
                          (> (- (buffer-z ed)
                                (buffer-beg ed))
                             limit))))
        (if (or (= base-pos -1) toobig)
            #f
            (let* ((cached (%window-base-line-number window))
                   (use-cache (and (> cached 0) (> base-pos 0)
                                   (<= base-pos startpos)
                                   (>= (buffer-beg-unchanged ed)
                                       base-pos)))
                   (line (if use-cache cached 1))
                   (linepos (if use-cache base-pos (buffer-beg ed)))
                   (nlines (%count-lines ed linepos startpos))
                   (topline (+ nlines line)))
              (let ((nlines-from-start
                     (lambda () (%count-lines ed startpos (window-point window)))))
                (cond
                 ((= startpos (buffer-beg ed))
                  (set!%window-base-line-number window topline)
                  (set!%window-base-line-pos window (buffer-beg ed))
                  (set!buffer-beg-unchanged! ed)
                  (+ topline (nlines-from-start)))
                 ;; "too close" to the window, too far from it, or never
                 ;; set: re-base it
                 ((or (< nlines (+ height 25))
                      (> nlines (+ (* height 3) 50))
                      (= linepos (buffer-beg ed)))
                  (let* ((wanted (+ (* height 2) 30))
                         (span (* (*line-number-display-limit-width*) wanted))
                         (limit-at (max (buffer-beg ed)
                                        (- startpos span)))
                         (gave-up (<= startpos limit-at))
                         (got (let loop ((n 0) (pos startpos))
                                (if (or (>= n wanted)
                                        (<= pos (buffer-beg ed)))
                                    (cons n pos)
                                    (loop (+ n 1)
                                          (text-editor-get-start-of-line
                                           ed (- pos 1)))))))
                    (if gave-up
                        ;; the lines were too long to find a base line in:
                        ;; give up on line numbers for this window
                        (begin
                          (set!%window-base-line-pos window -1)
                          (set!%window-base-line-number window 0)
                          #f)
                        (begin
                          (set!%window-base-line-number
                           window (- topline (car got)))
                          (set!%window-base-line-pos window (cdr got))
                          (set!buffer-beg-unchanged! ed)
                          (+ topline (nlines-from-start))))))
                 (else (+ topline (nlines-from-start)))))))))

    (define (decode-mode-spec-coding cs eol-flag)
      ;; GNU Emacs's `decode_mode_spec_coding' (`xdisp.c:29334'): the
      ;; mnemonic of the coding system CS, and - when EOL-FLAG - of its
      ;; end-of-line conversion after it. CS nil, or a name that is not a
      ;; coding system at all, is the C's "not yet decided" case: it
      ;; answers `-' on a multibyte buffer and the undecided eol.
      ;;
      ;; Emacs reaches the mnemonics through the coding system's plist;
      ;; here it is `coding-system-mnemonic', which is the same character.
      ;;--------------------------------------------------------------
      (if (not (coding-system-p cs))
          (string-append (if (*enable-multibyte-characters*) "-" " ")
                         (if eol-flag (eol-type-mnemonic #f) ""))
          (string-append (string (coding-system-mnemonic cs))
                         (if eol-flag (eol-type-mnemonic (coding-system-eol-type cs)) ""))))

    (define (eol-type-mnemonic eol)
      ;; GNU Emacs's `coding-system-eol-type-mnemonic' (`mule.el:1054'):
      ;; `eol-mnemonic-unix' is `:', `eol-mnemonic-dos' is `(DOS)',
      ;; `eol-mnemonic-mac' is `(Mac)' and `eol-mnemonic-undecided' is
      ;; `:' - which is the same question `mode-line-eol-desc' asks, and
      ;; answered the same way.
      ;;--------------------------------------------------------------
      (case eol
        ((dos) "(DOS)")
        ((mac) "(Mac)")
        (else ":")))

    (define (file-remote-p filename)
      ;; GNU Emacs's `file-remote-p' (`files.el'): "Test whether FILE
      ;; specifies a location on a remote system." Emacs asks the file
      ;; name handlers - `(find-file-name-handler file 'file-remote-p)' -
      ;; and returns nil when none matches.
      ;;
      ;; **Every name is local here, and that is the honest answer rather
      ;; than a stub.** `*file-name-handler-alist*' is empty - there is no
      ;; Tramp and no archive handler - so `find-file-name-handler'
      ;; answers #f for everything, which is the same thing Emacs answers
      ;; on a machine with no handlers loaded. It lives *here* rather than
      ;; in `files.sld' because `%@' is in this library and `files.sld' is
      ;; above it; when a handler list arrives it moves down beside
      ;; `find-file-name-handler', which is `fileio.sld''s.
      ;;--------------------------------------------------------------
      (if (string? filename) #f #f))

    (define (graphical-frame?)
      ;; GNU Emacs's `FRAME_WINDOW_P': whether this frame has a window
      ;; system behind it. It is what tells `%z' whether to name the
      ;; *terminal's* coding systems as well as the buffer's - a terminal
      ;; needs them and a window does not, "the terminal never needs to do
      ;; EOL conversion".
      ;;--------------------------------------------------------------
      (if (memq (*window-system*) '(x w32 ns pgtk)) #t #f))

    (define (percent99 n d)
      ;; GNU Emacs's `percent99` (`xdisp.c:29432`): "Return the
      ;; percentage N of D, rounded up, capped at 99." The C computes
      ;; `(d - 1 + 100.0 * n) / d` in floating point and truncates;
      ;; the same arithmetic over exact integers answers the same.
      ;;--------------------------------------------------------------
      (min (quotient (+ (* 100 n) (- d 1)) d) 99))

    (define (window-bottom-position window)
      ;; GNU Emacs's `BUF_Z (b) - w->window_end_pos` - the buffer
      ;; position the window's last drawn glyph is at. The window's
      ;; `end-pos` is stored as a distance from the *text* end, so the
      ;; text's Z is added back here. Before the first redisplay the
      ;; answer is the end of the buffer, which prints "All"/"Bottom",
      ;; the same as a fresh Emacs window does.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (- (buffer-text-z (text-editor-text ed))
           (%window-end-pos window))))

    (define (mode-line-construct spec window)
      ;; The text one `%'-construct stands for: GNU Emacs's
      ;; `decode_mode_spec'. SPEC is the character after the `%'.
      ;;
      ;; The constructs this editor can answer are the ones about the
      ;; buffer and the window's point, and the percentages of the
      ;; buffer above or below the window (`%o', `%p', `%P', `%q'). The
      ;; rest - the process (`%s') and the recursion depth (`%[',
      ;; `%]') - are printed as they stand, which is what Emacs does
      ;; with a construct it does not recognise either.
      ;;--------------------------------------------------------------
      ;; Only the constructs that ask for the position pay for it, and
      ;; they are computed inside their own case rather than in a `let*'
      ;; above: `decode_mode_spec' is called once per `%'-construct, so a
      ;; `let*' at the top of it computes the line and its text once per
      ;; construct in the format - five times over for the default mode
      ;; line, of which two constructs want them. Measured at line 20000
      ;; of a 20001-line buffer, that was 93ms for one mode line.
      (let* ((ed (window-buffer window))
             (point-pos (window-point window))
             (line-start (text-editor-get-start-of-line ed point-pos))
             ;; How many characters point is from the start of its line,
             ;; counting from zero. That is not yet `current-column': the
             ;; C's `current-column' (`indent.c:298') is the number of
             ;; *screen* columns, which is not the number of characters
             ;; when the line holds a tab or a wide character - nor when a
             ;; `display' property stands on the way, which moves the
             ;; columns after it along. The display widths are applied
             ;; below.
             (column (- point-pos line-start)))
        (case spec
          ((#\%) "%")
          ((#\b) (or (text-editor-buffer-name ed) "*scratch*"))
          ((#\f) (or (text-editor-file-name ed) ""))
          ;; The line point is on, counting from 1 - see
          ;; `mode-line-line-number', which is the C's `'l'` case. The C
          ;; prints "??" where the number cannot be had.
          ((#\l) (let ((n (mode-line-line-number window)))
                    (if n (number->string n) "??")))
          ;; `%c' is GNU Emacs's `(current-column)': the *screen* column,
          ;; counting from zero - "the leftmost column is displayed as
          ;; zero", which a terminal Emacs confirms: `(format-mode-line
          ;; "%c")' at the start of a line is "0". The engine's column is
          ;; a character count, so the construct converts it through the
          ;; line's display widths - which is what makes it 3 rather than
          ;; 2 after a CJK character, as Emacs's is.
          ((#\c) (number->string
                  (line-texts-column
                   (line-display-texts ed line-start)
                   column)))
          ;; `%C' is `%c' counting from one rather than zero
          ((#\C) (number->string
                  (+ 1 (line-texts-column
                        (line-display-texts ed line-start)
                        column))))
          ;; **`%n` is the narrowing indicator** (`xdisp.c:29737`): "Narrow"
          ;; with a leading space when the buffer is narrowed, and nothing
          ;; at all otherwise - `if (BUF_BEGV (b) > BUF_BEG (b) || BUF_ZV
          ;; (b) < BUF_Z (b)) return " Narrow";' and a fall-through to the
          ;; empty answer.
          ((#\n) (if (buffer-narrowed-p) " Narrow" ""))
          ;; `%*' is `%' read-only, `*' modified, `-' neither; `%+' is `*'
          ;; modified, `%' read-only, `-' neither; `%&' is `*' modified
          ((#\*) (if (buffer-read-only? ed)
                     "%"
                     (if (buffer-modified-p ed) "*" "-")))
          ((#\+) (if (buffer-modified-p ed)
                     "*"
                     (if (buffer-read-only? ed) "%" "-")))
          ((#\&) (if (buffer-modified-p ed) "*" "-"))
          ((#\i) (number->string (- (buffer-z ed) (buffer-beg ed))))
          ((#\I) (let ((n (- (buffer-z ed) (buffer-beg ed))))
                   (cond ((< n 10000) (number->string n))
                         ((< n 10000000)
                          (string-append (number->string (quotient n 1000)) "k"))
                         (else
                          (string-append (number->string (quotient n 1000000))
                                         "M")))))
          ;; The percentages - `xdisp.c:29757-29809`. `%o' is the
          ;; proportion of the window's travel through the buffer,
          ;; `%p' the text above the window top as a percentage of all
          ;; the text, `%P' the same for the window bottom, and `%q'
          ;; both at once. The "All"/"Top"/"Bottom" words are the C's,
          ;; and so is the `Top` prefix on `%P`.
          ((#\o)
           (let* ((toppos (window-start window))
                  (botpos (window-bottom-position window))
                  (begv (buffer-beg ed))
                  (zv (buffer-z ed)))
             (cond ((<= zv botpos)
                    (if (<= toppos begv) "All" "Bottom"))
                   ((<= toppos begv) "Top")
                   (else
                    (format #f "~2d%"
                            (percent99 (- toppos begv)
                                       (+ (- toppos begv) (- zv botpos))))))))
          ((#\p)
           (let* ((pos (window-start window))
                  (begv (buffer-beg ed))
                  (zv (buffer-z ed)))
             (if (<= (%window-end-pos window)
                     (- (buffer-text-z (text-editor-text ed)) zv))
                 (if (<= pos begv) "All" "Bottom")
                 (if (<= pos begv)
                     "Top"
                     (format #f "~2d%" (percent99 (- pos begv)
                                                  (- zv begv)))))))
          ((#\P)
           (let* ((toppos (window-start window))
                  (botpos (window-bottom-position window))
                  (begv (buffer-beg ed))
                  (zv (buffer-z ed)))
             (if (<= zv botpos)
                 (if (<= toppos begv) "All" "Bottom")
                 (string-append
                  (if (< begv toppos) "Top" "")
                  (format #f "~2d%" (percent99 (- botpos begv)
                                               (- zv begv)))))))
          ((#\q)
           (let* ((toppos (window-start window))
                  (botpos (window-bottom-position window))
                  (begv (buffer-beg ed))
                  (zv (buffer-z ed)))
             (if (and (<= toppos begv) (<= zv botpos))
                 "All   "
                 (let ((top-perc (if (<= toppos begv)
                                     0
                                     (percent99 (- toppos begv)
                                                (- zv begv))))
                       (bot-perc (if (<= zv botpos)
                                     100
                                     (percent99 (- botpos begv)
                                                (- zv begv)))))
                   (if (= top-perc bot-perc)
                       (format #f "~d%" top-perc)
                       (format #f "~d-~d%" top-perc bot-perc))))))
          ;; `%z' is the buffer's coding system, `%Z' the same with its
          ;; end-of-line conversion. On a *terminal* Emacs names the
          ;; keyboard's and the terminal's first, in that order - so a
          ;; terminal frame showing a UTF-8 buffer reads `UUU'.
          ((#\z #\Z)
           (let ((eol? (char=? spec #\Z))
                 ;; The *buffer-local*, read raw, as `mode-line-eol-desc'
                 ;; reads it and for the same reason: `buffer-file-coding-
                 ;; system' is `files.sld''s and that library is above
                 ;; this one. The default is the same literal.
                 (buffer-cs (buffer-local-value (window-buffer window)
                                                'buffer-file-coding-system
                                                'utf-8-unix)))
             (if (graphical-frame?)
                 (decode-mode-spec-coding buffer-cs eol?)
                 (string-append
                  (decode-mode-spec-coding (keyboard-coding-system) #f)
                  (decode-mode-spec-coding (terminal-coding-system) #f)
                  (decode-mode-spec-coding buffer-cs eol?)))))
          ;; `%@' is `mode-line-remote': "@" when the buffer's
          ;; `default-directory' is on a remote system and "-" when it is
          ;; not (`xdisp.c:29823'). It is the third character of the
          ;; `---' Emacs draws after the end-of-line mnemonic - measured,
          ;; `-UU-:---' for an LF file - and it is why this tree's mode
          ;; line read `--' there.
          ((#\@)
           (if (file-remote-p
                (buffer-local-value (window-buffer window)
                                    'default-directory
                                    "/"))
               "@" "-"))
          ;; `%-' is "enough dashes to fill the mode line": how many is only
          ;; known when the line is placed, so the drawing code pads instead
          ((#\-) "")
          (else (string #\% spec)))))

    (define (number-in-field? text)
      ;; Whether TEXT is a number, which is what decides which side a field
      ;; pads on. Measured from a terminal Emacs: `%6l' at the first line is
      ;; "     1" - a number is padded on the *left*, so that the digits line
      ;; up as point moves - and `%12b' is "probe       ", padded on the
      ;; right. The test is Emacs's: a leading digit or a minus sign.
      ;;--------------------------------------------------------------
      (and (> (string-length text) 0)
           (or (char-numeric? (string-ref text 0))
               (char=? (string-ref text 0) #\-))))

    (define (pad-mode-line-field text width)
      ;; TEXT in a field WIDTH wide, in the `%N<spec>' form: GNU Emacs pads a
      ;; number on the left and anything else on the right. The width is a
      ;; *floor*, not a ceiling: a text longer than the field is shown in
      ;; full. That is `store_mode_line_noprop' (xdisp.c), which copies the
      ;; whole string and then fills with spaces only while the count is
      ;; below the field width - a mode line just runs longer, and the
      ;; window edge is what cuts it off.
      ;;--------------------------------------------------------------
      (let ((len (string-length text)))
        (cond
         ((<= width len) text)
         ;; `concat`, so a propertized construct keeps its properties
         ;; through the field's padding.
         ((number-in-field? text)
          (concat (make-string (- width len) #\space) text))
         (else (concat text (make-string (- width len) #\space))))))

    (define (pad-mode-line-element text width)
      ;; TEXT in the field of an `(N ...)' element. This is a different
      ;; mechanism from `%N<spec>' and it pads differently: measured from the
      ;; same terminal Emacs, `(6 "%l")' at the first line is "1     " where
      ;; `%6l' is "     1". The element form is a *precision* - the text is
      ;; laid out to that width and short text simply does not fill it - so
      ;; the padding goes on the right whatever the text is.
      ;;--------------------------------------------------------------
      (let ((len (string-length text)))
        (if (>= len width)
            (mode-line-substring text 0 width)
            (concat text (make-string (- width len) #\space)))))

    (define (inherit-mode-line-properties text str position)
      ;; TEXT with the text properties the format string STR carries at
      ;; POSITION - the `%` that produced it. Emacs's `display_mode_element`
      ;; applies the enclosing string's properties to a copy of the string
      ;; it is about to expand (`xdisp.c:28520`), which is how a
      ;; `(propertize "%1*" 'local-map ...)` keeps its keymap on the
      ;; `-`/`*` the construct expands to.
      ;;--------------------------------------------------------------
      (let ((props (and (string? str)
                        (>= position 0)
                        (< position (string-length str))
                        (text-properties-at position str))))
        (if (null? props) text (apply propertize text props))))

    (define (expand-mode-line-string str window . rest)
      ;; STR with its `%'-constructs expanded: GNU Emacs's processing of a
      ;; string in a mode line. A `%' followed by digits is a field width, as
      ;; in `%12b'; a `%' followed by anything else is a construct. A `%' at
      ;; the very end is a literal `%'.
      ;;
      ;; **The properties travel with the literal characters.** This used
      ;; to `display` character by character into a string port, which
      ;; drops every text property - and the tab line's strings are
      ;; propertized (`keymap`, `face`, `tab`), so `format-mode-line`
      ;; rebuilt them bare and a tab could not be clicked even though the
      ;; string it was drawn from carried its keymap. The literal runs are
      ;; `mode-line-substring`s now, which copies the properties the way
      ;; the C's `substring` does, and only the *constructed* text (a
      ;; buffer name, a line number) arrives without them - which is what
      ;; Emacs gives it too.
      ;;--------------------------------------------------------------
      ;;
      ;; **Every character this expands carries the format element's
      ;; number** - GNU Emacs's `mode-line-elt-no`, added by
      ;; `store_mode_line_string` (`xdisp.c:29000`) to each part it
      ;; stores. It is what marks the boundaries of an element in the
      ;; flattened line: Emacs's redisplay tracks each element as its own
      ;; string object, and this property is the flattened stand-in for
      ;; that identity. `format-mode-line`'s own answer carries it too
      ;; (measured on Emacs 31.1: `(format-mode-line '("%z" "%1*" "%1+"))`
      ;; is `#("UUU--" 0 3 (mode-line-elt-no 2) 3 4 (mode-line-elt-no 3)
      ;; 4 5 (mode-line-elt-no 4))`).
      (let* ((elt-no (and (pair? rest) (car rest)))
             (n (string-length str)))
        (define (tag text)
          (if elt-no
              (propertize text 'mode-line-elt-no elt-no)
              text))
        (let loop ((i 0) (pct #f) (width #f) (start 0) (acc '()))
          (if (>= i n)
              (let* ((pieces (reverse
                              (if (< start n)
                                  (cons (mode-line-substring str start n) acc)
                                  acc))))
                (tag (if (null? pieces) "" (apply concat pieces))))
              (let ((c (string-ref str i)))
                (cond
                 ((and (char=? c #\%) (not width))
                  (loop (+ i 1) i 'pending start acc))
                 ((eq? width 'pending)
                  (cond
                   ((char-numeric? c)
                    (loop (+ i 1) pct (- (char->integer c) (char->integer #\0))
                          start acc))
                   ;; "`%%` is a literal `%`": one `%`, carrying the
                   ;; property of the `%` it came from.
                   ((char=? c #\%)
                    (loop (+ i 1) #f #f (+ i 1)
                          (let ((acc (if (< start pct)
                                         (cons (mode-line-substring str start pct)
                                               acc)
                                         acc)))
                            (cons (mode-line-substring str (- i 1) i) acc))))
                   (else
                    ;; **The construct's output carries the properties of
                    ;; the format string it was written in.** Emacs's
                    ;; `display_mode_element` copies a string and
                    ;; `set-text-properties`s it before the `%` walk
                    ;; (`xdisp.c:28520`), and `bindings.el` leans on that:
                    ;; `(propertize "%1*" 'local-map MAP)` is what makes
                    ;; the modified flag clickable, and `%` expands to `-`
                    ;; or `*` here.
                    (let ((text (inherit-mode-line-properties
                                 (mode-line-construct c window) str pct)))
                      (loop (+ i 1) #f #f (+ i 1)
                            (let ((acc (if (< start pct)
                                           (cons (mode-line-substring str start pct)
                                                 acc)
                                           acc)))
                              (cons text acc)))))))
                 ((integer? width)
                  (if (char-numeric? c)
                      (loop (+ i 1) pct (+ (* 10 width)
                                           (- (char->integer c) (char->integer #\0)))
                            start acc)
                      ;; **The properties go on the *constructed* text,
                      ;; not on the field's padding.** Emacs's
                      ;; `store_mode_line_string` adds the element's
                      ;; properties to the string it was given and then
                      ;; appends padding spaces that get only the
                      ;; `mode-line-elt-no` marker (`xdisp.c:29080`) - so
                      ;; `%12b`'s padding is not part of the buffer
                      ;; name's hover run and is not clickable.
                      (let ((text (pad-mode-line-field
                                   (inherit-mode-line-properties
                                    (mode-line-construct c window) str pct)
                                   width)))
                        (loop (+ i 1) #f #f (+ i 1)
                              (let ((acc (if (< start pct)
                                             (cons (mode-line-substring str start pct)
                                                   acc)
                                             acc)))
                                (cons text acc))))))
                 (else
                  (loop (+ i 1) pct width start acc))))))))

    (define (mode-line-symbol-value symbol buffer)
      ;; The value a mode-line construct names - GNU Emacs's
      ;; `symbol-value` as `display_mode_element` uses it, over the three
      ;; places this tree keeps variables:
      ;;
      ;;   1. the buffer's own slot (a `define-minor-mode` mode, a
      ;;      DEFVAR_PER_BUFFER like `truncate-lines`),
      ;;   2. the global default (`default-value`, where a `:global`
      ;;      minor mode's state lives),
      ;;   3. a customizable variable's reader (`define-custom` keeps it
      ;;      on the symbol as `custom-reader` - under the tree's
      ;;      starred spelling, so `mode-line-percent-position` in a
      ;;      construct finds `*mode-line-percent-position*`).
      ;;
      ;; **This is the "variable registry" the mode-line-format comment
      ;; used to say was missing.** It is not an obarray: a plain
      ;; `define`d variable is not reachable by name, which is the same
      ;; gap `describe-variable` has, and the reason the mode-line
      ;; variables are `define-custom`s.
      ;;--------------------------------------------------------------
      (let ((starred (string->symbol
                      (string-append "*" (symbol->string symbol) "*"))))
        (let ((reader (or (get symbol 'custom-reader)
                          (get starred 'custom-reader))))
          (cond
           ((and buffer (local-variable-p symbol buffer))
            (buffer-local-value buffer symbol #f))
           ((default-boundp symbol)
            (default-value symbol #f))
           (reader
            (reader (if (get symbol 'custom-reader) symbol starred)))
           (else #f)))))

    (define (format-mode-line format . args)
      ;; GNU Emacs's `format-mode-line': the mode line FORMAT produces for a
      ;; window, WINDOW being the second argument or the selected window.
      ;; A construct is a string, list, symbol, or nil; `:eval' holds a
      ;; zero-argument procedure in place of an Emacs Lisp form.
      ;;--------------------------------------------------------------
      (let ((window (if (pair? args) (car args) (selected-window))))
        (parameterize ((*mode-line-window* window))
          ;; **Emacs's `mode_line_elt_no`** (`xdisp.c:13934`),
          ;; incremented on *entry* to `display_mode_element`
          ;; (`:28500`) for every element processed: a list and each of
          ;; its members get a number of their own, while a string's
          ;; `%`-expansions share the string's number (the C's note: "an
          ;; element could be stored by parts. For example, "a%b" is
          ;; stored as two elements ... but they should be considered as
          ;; one element"). It reaches the answer as the
          ;; `mode-line-elt-no` property, which is what makes an
          ;; element's hover run stop at the element's edge.
          (let ((element-number 0))
          (let process ((construct format))
            (set! element-number (+ element-number 1))
            (let ((this-element element-number))
            (cond
             ((not construct) "")
             ((string? construct) (expand-mode-line-string construct window this-element))
             ((integer? construct) "")
             ((symbol? construct)
              ;; "A symbol is evaluated and the result is processed as
              ;; a construct" (`display_mode_element`) - the same rule
              ;; the conditional form below uses for its test.
              (process (mode-line-symbol-value construct
                                              (window-buffer window))))
             ((pair? construct)
              (cond
               ((and (eq? (car construct) ':propertize)
                     (pair? (cdr construct)))
                ;; GNU Emacs's `propertized-buffer-identification' is
                ;; `(propertize "%12b" 'face 'mode-line-buffer-id)', and
                ;; the `:propertize' construct is how that reaches the
                ;; string `format-mode-line` returns: the properties are
                ;; name/value pairs after the expression, and they are
                ;; *added* to whatever properties the text already has
                ;; (`propertize` copies, then `add-text-properties`).
                (let ((text (process (cadr construct))))
                  (if (pair? (cddr construct))
                      (apply propertize text (cddr construct))
                      text)))
               ((and (eq? (car construct) ':eval)
                     (pair? (cdr construct)))
                (process ((cadr construct))))
               ((symbol? (car construct))
                ;; GNU Emacs's conditional element
                ;; (`display_mode_element`): "If the symbol's value is
                ;; non-nil, process the second element; otherwise
                ;; process the third, if any." This was a placeholder
                ;; that always took the *else* branch - harmless while
                ;; no format used one, wrong the moment
                ;; `mode-line-position` did.
                (process (if (mode-line-symbol-value
                              (car construct) (window-buffer window))
                             (and (pair? (cdr construct)) (cadr construct))
                             (and (pair? (cdr construct))
                                  (pair? (cddr construct))
                                  (caddr construct)))))
               ((integer? (car construct))
                (let* ((width (car construct))
                       (rest (if (pair? (cdr construct)) (cadr construct) #f))
                       (text (process rest)))
                  (if (< width 0)
                      (if (> (string-length text) (- width))
                          ;; `mode-line-substring`, not `substring`:
                          ;; `Fsubstring` carries the properties.
                          (mode-line-substring text 0 (- width))
                          text)
                      (pad-mode-line-element text width))))
               ;; `concat`, not `string-append`: the latter drops the
               ;; text properties of its pieces, so a `:propertize`
               ;; construct lost its face the moment it was joined to
               ;; the rest of the line. GNU Emacs's `format-mode-line`
               ;; joins with `concat` for exactly this reason.
               (else (apply concat (map process construct)))))
             (else ""))))))))

    (define (mode-line-string window)
      ;; The window's mode line: GNU Emacs's `MODE-LINE-STRING' is what
      ;; its format produces for this window, which is the whole of it -
      ;; there is no hand-rolled string here any more. What the format
      ;; says, and what it may say, is in `*MODE-LINE-FORMAT*'.
      ;;
      ;; The name is the buffer's, not the file's: Emacs names a buffer
      ;; visiting a file after the file without its directory (that is
      ;; what `create-file-buffer' does), and names a buffer with no file
      ;; of its own - so a window can show "*Completions*", which visits
      ;; nothing.
      ;;
      ;; The hand-rolled indicator that used to be here is gone with it:
      ;; it reported `%%' for any read-only buffer, so a buffer that was
      ;; both modified and read-only showed `%%' when Emacs shows `%*'.
      ;; That is what `%1*' followed by `%1+' gives - see
      ;; ENGINE-FINDINGS.txt.
      ;;
      ;; The position is per window because point is: two windows on the
      ;; same buffer are at different places in it, and each mode line
      ;; says where its own window is.
      ;;--------------------------------------------------------------
      (parameterize ((*mode-line-window* window))
        (format-mode-line (*mode-line-format*) window)))

    (define (status-string frame)
      ;; The mode line of the selected window, which is the one the
      ;; frame is about.
      ;;--------------------------------------------------------------
      (mode-line-string (frame-selected-window frame)))

    ;;----------------------------------------------------------------
    ;; A line addressed by its *position* rather than its number
    ;;
    ;; GNU Emacs's redisplay never holds a line number: `struct it' walks
    ;; the buffer with absolute buffer positions, so a row costs the line
    ;; it draws and nothing more. Asking the engine for line N instead
    ;; means scanning from `point-min' for every row, which makes a
    ;; window on line 20000 cost 20000 scans - measured at 417ms for 24
    ;; rows, against 0.4ms for the same 24 rows at the top of the buffer.
    ;;
    ;; The two functions below are the position-addressed forms of
    ;; `buffer-line-string' and `line-outer-size', and the walks use them
    ;; wherever they already know where the line starts. There is no
    ;; Emacs function to mirror them with - the C reads the characters
    ;; one at a time as it produces glyphs - so they are the same
    ;; departure `buffer-line-string' is, split in two.
    ;;
    ;; The window's start is a marker - `w->start' - so the walks have
    ;; the first line's position for nothing. What `find_newline''s
    ;; `region_cache' (search.c) would finish off is the scans that
    ;; remain, which start from `point-min': `buffer-line-string',
    ;; `line-outer-size' and `text-editor-line-count', and the line
    ;; numbers the mode line's cache still has to walk for.
    ;;------------------------------------------------------------------

    (define (line-string-at ed line-start)
      ;; The contents of the line beginning at buffer position LINE-START,
      ;; without the line break that ends it. One forward scan to the line
      ;; break and no further.
      ;;--------------------------------------------------------------
      (make-buffer-string ed line-start
                               (text-editor-get-end-of-line ed line-start)))

    (define (line-outer-size-at ed line-start)
      ;; How many characters the line beginning at LINE-START advances the
      ;; buffer by - its contents plus its line break. Zero for a position
      ;; with no line break after it, which is the buffer's last line.
      ;;--------------------------------------------------------------
      (let ((end (text-editor-get-end-of-line ed line-start)))
        (+ (- end line-start)
           (if (< end (buffer-z ed)) 1 0))))


    ;; `display-column-of' used to sit here - the screen column at which
    ;; buffer column COL of a line is drawn, as the display width of the
    ;; line's *prefix*. It walked the line string, so a `display' property
    ;; on the way was not counted, and both of its callers now go through
    ;; `line-texts-column' with the line's texts instead.

    ;;----------------------------------------------------------------
    ;; Faces

    (define (face->attribute face-name . args)
      ;; The display's drawing token for a *named* face: GNU Emacs's
      ;; `face_at_buffer_position' where the face is known by name, which
      ;; is what the mode line and the echo area need. The realized
      ;; attributes are merged here - BASE under any other, and the
      ;; default face under BASE - and the display turns them into its
      ;; token (`realize-face' is the display side of a face).
      ;;
      ;; BASE is the default face everywhere but the mode line. A mode
      ;; line's text properties name faces like `mode-line-buffer-id'
      ;; that carry only the attributes they change (`:weight bold'), and
      ;; the rest must come from the mode line's own face - Emacs merges
      ;; them onto `mode_line_face_id`, not onto `default` (`xdisp.c`'s
      ;; `display_mode_element` calls `face_at_string_position` with the
      ;; mode line's face as the base).
      ;;--------------------------------------------------------------
      (let* ((base (if (pair? args) (car args) 'default))
             ;; **The base starts from the *default* face's attributes**,
             ;; which is Emacs's `realize_named_face` (`xfaces.c:6590`):
             ;; it calls `get_lface_attributes_no_remap` for `default`,
             ;; then `merge_face_vectors (symbol_attrs, attrs)` - so a
             ;; basic face that names no `:foreground` takes the default
             ;; face's. `mode-line` with only a background and a box
             ;; (`tsdh-dark`'s) is white text in Emacs for that reason;
             ;; merging the face's own chain alone left the foreground
             ;; unspecified, and an unspecified foreground is black in
             ;; the Gtk backend and the terminal default on a tty.
             (base-attrs (merge-face-ref base (merge-face-ref 'default '()))))
        (lookup-face (current-display)
                      (merge-face-vectors
                       ;; **A named face is the table's**, and anything
                       ;; else - a list of faces, an anonymous plist,
                       ;; `(:inherit (tab-line-tab-special tab-line-tab))'
                       ;; as `tab-line.el` writes it - is a face *reference*
                       ;; and goes through `merge_face_ref`, which is the
                       ;; function that knows all three forms.
                       (if (symbol? face-name)
                           (face-realized-attributes face-name)
                           (merge-face-ref face-name '()))
                       base-attrs))))

    (define (face-change-limit ed position limit)
      ;; The next position at or after POSITION where the face can differ,
      ;; and at least POSITION+1: `face_at_buffer_position`'s `*limit`
      ;; (`xfaces.c`), which is
      ;;
      ;;     *limit = next_single_property_change (pos, Qface, ...);
      ;;     l = next_overlay_change (pos);
      ;;     if (l < *limit) *limit = l;
      ;;
      ;; - a run of one face is [POSITION, LIMIT) and nothing inside it
      ;; can change. The region's own edges are candidates too, because
      ;; the redisplay merges the `region' face over the text face inside
      ;; it, so a run cannot span the mark.
      ;;
      ;; **This is what makes a row cheap.** Asking for the face at every
      ;; character is ~13us a character here - 0.64ms for a 50-column
      ;; row, measured - because each ask re-merges the `default' face
      ;; and walks the interval tree. Emacs asks once per run for the
      ;; same reason, and the primitive it asks with is
      ;; `next_single_property_change`.
      ;;--------------------------------------------------------------
      (let* ((by-property
              (or (next-single-property-change position 'face ed limit) limit))
             (by-overlay (next-overlay-change position))
             (by-region
              (if (buffer-local-value ed 'mark-active #f)
                  (let ((mark (and (%mark-marker ed)
                                   (marker-position (%mark-marker ed)))))
                    (if mark
                        (let ((point (buffer-pt ed)))
                          (let ((beg (min mark point)) (end (max mark point)))
                            (cond
                             ;; **An empty region covers nothing.** GNU
                             ;; Emacs 29+ highlights the region with an
                             ;; *overlay* (`redisplay--highlight-overlay-
                             ;; function`, `simple.el`), and a zero-length
                             ;; overlay has no characters - so it splits
                             ;; no run. Splitting on the point/mark
                             ;; position anyway gave two runs for a region
                             ;; that shows nothing.
                             ((not (< beg end)) limit)
                             ((and (> beg position) (< beg limit)) beg)
                             ((and (> end position) (< end limit)) end)
                             (else limit))))
                        limit))
                  limit))
             ;; **The mouse face's edges split a run too.** Emacs paints
             ;; the highlight in a second pass (`show_mouse_face`), so its
             ;; edges need not be `face`-change points; this renderer
             ;; resolves the face per run, and a run is only one face if
             ;; nothing inside it changes. Without this a `mouse-face` run
             ;; in the middle of a line - Dired's file names are one -
             ;; took the token of the run it sat inside, and hovering
             ;; painted nothing there.
             (by-mouse
              (if (and mouse-highlight
                       %mouse-face-window
                       (eq? (*drawing-window*) %mouse-face-window))
                  (cond ((and (> %mouse-face-beg position)
                              (< %mouse-face-beg limit))
                         %mouse-face-beg)
                        ((and (>= position %mouse-face-beg)
                              (< position %mouse-face-end)
                              (> %mouse-face-end position)
                              (< %mouse-face-end limit))
                         %mouse-face-end)
                        (else limit))
                  limit))
             (next (min by-property by-overlay by-region by-mouse)))
        (max (+ position 1) (min next limit))))

    (define (line-face-runs ed line-start len)
      ;; LINE-TEXT as maximal runs of characters that share one face:
      ;; `(FROM TO ATTRIBUTE)' in buffer columns, ATTRIBUTE being the
      ;; display's token for the face `attrs-at-buffer-position' finds.
      ;;
      ;; The runs, not the characters, are what gets drawn: a terminal is
      ;; told "these cells are bold" once per run rather than once per
      ;; character, and the *walk* is by run too - `face-change-limit`
      ;; jumps to the next position the face can change, which is the
      ;; C's `*limit`, instead of asking at every character.
      ;;
      ;; So the comparison that finds a run's end is on the merged,
      ;; *unrealized* attributes, and the face is realized once per run.
      ;; Realizing per character is 15us on the GTK display against
      ;; 1.2us for the attribute lookup - twelve times the cost, to
      ;; intern a face a run is about to hand over unchanged. With a
      ;; search face on every row of a wide window that is most of a
      ;; redisplay, which is what made isearch look like it had hung on
      ;; Gtk; a terminal's realize is a cheap intern, so nothing showed
      ;; there.
      ;;--------------------------------------------------------------
      (if (= len 0)
          '()
          (let loop ((from 0) (acc '()))
            (if (>= from len)
                (reverse acc)
                (let* ((position (+ line-start from))
                       (attrs (attrs-at-buffer-position ed position))
                       (next (face-change-limit ed position (+ line-start len)))
                       (to (min len (max (+ from 1) (- next line-start)))))
                  (loop to
                        (cons (list from to
                                    (lookup-face (current-display) attrs))
                              acc)))))))

    (define (draw-overlay-strings! entries row-y x)
      ;; Draw each `(OVERLAY . STRING)' of ENTRIES at X, in order, in the
      ;; overlay's own face, and answer the column the last one ended at.
      ;; GNU Emacs draws an overlay string with its overlay's face (the
      ;; `OVERLAY_STRING' case of `xdisp.c''s `display_string').
      ;;--------------------------------------------------------------
      (let loop ((rest entries) (x x))
        (if (null? rest)
            x
            (let* ((entry (car rest))
                   (text (cdr entry))
                   (face (overlay-get (car entry) 'face)))
              ;; A string with no `face' of its own is drawn in the
              ;; *default* face, as any other text without properties is
              ;; - not with "no face", which on a terminal is the
              ;; terminal's own colours and stops following a theme.
              (write-run! (current-display) (list text) row-y x
                          (face->attribute (or face 'default)))
              (loop (cdr rest) (+ x (line-display-width text)))))))

    (define (row-overlay-strings ed slice-start len)
      ;; The overlay strings to draw among the buffer columns of a row:
      ;; a vector of `(HEADS . TAILS)' indexed by column, `'()' where
      ;; there are none. The entry at LEN is the row's *end* - where the
      ;; `after-string' of an overlay that ends with the row goes.
      ;;--------------------------------------------------------------
      (let ((v (make-vector (+ len 1) '())))
        (let loop ((c 0))
          (when (<= c len)
            (let ((s (overlay-strings-at (+ slice-start c))))
              (when (or (pair? (car s)) (pair? (cdr s)))
                (vector-set! v c s))
              (loop (+ c 1)))))
        v))

    (define (row-metrics ed slice-start len)
      ;; The ascent and height of one screen row, in pixels: Emacs's
      ;; `compute_line_metrics` (`xdisp.c:24077`), which accumulates
      ;;
      ;;     row->ascent = it->max_ascent;
      ;;     row->height = it->max_ascent + it->max_descent;
      ;;
      ;; over the faces the row's glyphs are drawn in - "the row is as
      ;; tall as the tallest face on it". A row with one face is that
      ;; face's metrics; a row with several takes the greatest ascent and
      ;; the greatest descent independently, which is the C's two maxima
      ;; and not the maximum of their sums.
      ;;
      ;; **This is what makes a scaled line taller than its neighbours**
      ;; rather than moving them, which is the whole point of
      ;; `text-scale-mode`.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (let loop ((runs (line-face-runs ed slice-start len))
                   (ascent 0)
                   (descent 0))
          (if (null? runs)
              ;; A row with no glyphs of its own - an empty line, or the
              ;; cells after a short line - is one line of the default
              ;; face, which is `compute_line_metrics`'s
              ;; `it->max_descent = FRAME_LINE_HEIGHT` fallback.
              (if (and (= ascent 0) (= descent 0))
                  (let ((m (face-metrics display #f)))
                    (cons (car m) (+ (car m) (cdr m))))
                  (cons ascent (+ ascent descent)))
              (let* ((m (face-metrics display
                                      (attrs-at-buffer-position
                                       ed (+ slice-start (caar runs)))))
                     (a (max ascent (car m)))
                     (d (max descent (cdr m))))
                (loop (cdr runs) a d))))))

    (define (line-display-width line-string)
      ;; The width of LINE-STRING in screen cells: the sum of its
      ;; characters' widths, each tab taken to its next stop in the
      ;; column it lands on.
      ;;
      ;; This is GNU Emacs's `string-width' (`character.c'), which is what
      ;; the mode line's field widths and the continuation glyph are
      ;; decided by. It is also the only answer that is right for a line
      ;; holding a wide character, where counting characters gives one
      ;; cell too few for each of them.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (column 0))
        (if (>= i (string-length line-string))
            column
            (let ((ch (string-ref line-string i)))
              (loop (+ i 1) (+ column (char-display-width ch column)))))))

    (define (string-pixel-width string . args)
      ;; GNU Emacs's `string-pixel-width` (`subr-x.el:389`): "Return the
      ;; width of STRING in pixels. ... If you call this function to
      ;; measure pixel width of a string with embedded newlines, it
      ;; returns the width of the widest substring that does not include
      ;; newlines."
      ;;
      ;; **It lives here rather than in a `subr-x` library**, because it
      ;; needs the frame's cell size and `subr.scm` is below `frame.scm`.
      ;; It is the same placement `buffer-text-pixel-size` would have if
      ;; this tree had one.
      ;;
      ;; **The C's measurement is not carried, and cannot be**: the
      ;; function fills a work buffer and runs the display iterator over
      ;; it (`buffer-text-pixel-size`, `xdisp.c`), which asks the font.
      ;; Here a glyph is one cell, so a line's width is its cell width
      ;; times the frame's character width - the same product
      ;; `window-pixel-width` is. The optional BUFFER argument is dropped
      ;; for the same reason: a face remapping does not change a glyph's
      ;; width.
      ;;--------------------------------------------------------------
      (if (= (string-length string) 0)
          0
          (* (apply max (map string-width (string-split string #\newline)))
             (frame-char-width))))

    (define (draw-special-glyph! row-y x0 width glyph)
      ;; The continuation glyph (`\') or the truncation glyph (`$') in a
      ;; row's last cell. It is a special display character, not buffer
      ;; text, and Emacs draws it with the default face even inside a
      ;; region - `produce_special_glyphs' uses `DEFAULT_FACE_ID'.
      ;;--------------------------------------------------------------
      (write-run! (current-display) (list glyph) row-y (+ x0 width -1)
                  (face->attribute 'default)))

    (define (line-end-fill-attribute ed row-end row-width width)
      ;; Face used for cells after a line's text when the line-end
      ;; position is inside the active region. ROW-END is the buffer
      ;; position just past the row's last character - the position of the
      ;; line break that ends it, or of the first character of the row
      ;; below - and ROW-WIDTH how many screen cells the row took. A line
      ;; that ends at point-max has no line break and gets no extension
      ;; face in Emacs.
      ;;--------------------------------------------------------------
      (let* ((mark (marker-position (%mark-marker ed)))
             (point (buffer-pt ed))
             (region-start (and mark (min point mark)))
             (region-end (and mark (max point mark))))
        (and (< row-width width)
             (region-face-active? ed)
             region-start
             region-end
             (<= region-start row-end)
             (< row-end region-end)
             (< row-end (buffer-z ed))
             (region-face-at-position? ed row-end)
             ;; The region face's :extend fills newline space even in the
             ;; monochrome spec, where :extend itself is unspecified and
             ;; inverse-video is the visible TTY attribute.
             (let* ((attrs (merge-face-ref 'region
                                           (merge-face-vectors
                                            (face-realized-attributes 'default)
                                            (face-attributes-empty))))
                    (extend (attribute-value attrs ':extend))
                    (inverse (attribute-value attrs ':inverse-video))
                    (attribute (face-at-buffer-position ed (- row-end 1))))
               (and (or (and (not (eq? extend *undefined-face-attribute*))
                             extend)
                        (and (not (eq? inverse *undefined-face-attribute*))
                             inverse))
                    (not (= attribute 0))
                    attribute)))))

    (define (region-face-active? ed)
      (and (buffer-local-value ed 'transient-mark-mode
                               (*transient-mark-mode*))
           (buffer-local-value ed 'mark-active #f)
           (marker-position (%mark-marker ed))))

    (define (region-face-at-position? ed position)
      ;; Whether POSITION is covered by ED's active region. GNU Emacs
      ;; redisplay merges the `region' face while the mark is active and
      ;; transient-mark-mode is enabled; the region is [min(mark, point),
      ;; max(mark, point)). Read ED directly, as redisplay does for the
      ;; buffer belonging to the window it is drawing.
      ;;--------------------------------------------------------------
      (and (buffer-local-value ed 'transient-mark-mode
                               (*transient-mark-mode*))
           (buffer-local-value ed 'mark-active #f)
           (let ((mark (marker-position (%mark-marker ed))))
             (and mark
                  (let* ((point (buffer-pt ed))
                         (beginning (min mark point))
                         (end (max mark point)))
                    (and (>= position beginning)
                         (< position end)))))))

    ;;----------------------------------------------------------------
    ;; The mouse face - `note_mouse_highlight` (`xdisp.c:37061`)
    ;;----------------------------------------------------------------
    ;;
    ;; Clickable text - anything with a `mouse-face` property, which is
    ;; what Occur's lines and Dired's file names have - is highlighted
    ;; while the pointer is over it. The face is not a face the buffer's
    ;; glyphs carry: it is painted over them while the mouse is there,
    ;; which is why the state lives beside the display and not in the
    ;; text. GNU Emacs keeps it in `Mouse_HLInfo`, one per display; this
    ;; tree's front end is one display, so there is one set.

    (define mouse-highlight #t)
    ;; ^ GNU Emacs's `mouse-highlight` (`frame.c:7592`): "If non-nil,
    ;; clickable text is highlighted when mouse is over it." A plain
    ;; variable, not a parameter: Emacs `defvar`s it, nothing `let`s it,
    ;; and a user turns it off with `setq'. The self-assignment is what
    ;; keeps the compiler from folding it into a constant - a variable a
    ;; user's init file sets is not one (the `menu-bar.el` rule).
    (set! mouse-highlight mouse-highlight)

    (define %mouse-face-window #f)
    (define %mouse-face-beg #f)
    (define %mouse-face-end #f)
    (define %mouse-face-attrs #f)
    (define %mouse-face-string #f)
    ;; ^ `Mouse_HLInfo`'s `mouse_face_window`, `mouse_face_beg_*`/
    ;; `mouse_face_end_*` and `mouse_face_face_id`: the window whose text
    ;; is under the pointer, the run to paint, and the face to paint it
    ;; with. Emacs also records the beg/end *rows and columns*; those are
    ;; derived here from the positions when the rows are built.
    ;;
    ;; **`mouse-face-string` is the string the run is in**, when the
    ;; pointer is over a mode line rather than buffer text - Emacs's
    ;; `note_line_or_margin_highlight` has the same two cases, and its
    ;; `mouse_face_beg_col`/`_end_col` count columns of the drawn string.
    ;; BEG and END are then *string* indices (as in the C, where the
    ;; property walk is over STRING), and a lit buffer position can never
    ;; be taken for a lit string index because `attrs-at-buffer-position`
    ;; ignores the run while this is set.

    (define *drawing-window* (make-parameter #f))
    ;; ^ Dynamic, for the same reason GNU Emacs's `it.w` is: bound around
    ;; one window's row build (`display-window!`), so the face code can
    ;; tell whether the row it is building belongs to the window the
    ;; pointer is over. Emacs's `show_mouse_face` knows because it is
    ;; handed the window; this renderer resolves faces position by
    ;; position instead, hence the binding.

    (define (attrs-at-buffer-position ed position)
      ;; The *unrealized* face in effect at POSITION in ED: the merged
      ;; attribute vector GNU Emacs's `face_at_buffer_position' computes,
      ;; before anything is folded down to what the display can draw. The
      ;; `face' text property there - a face name, a property list, or a
      ;; list of either - is merged with the `default' face; `xfaces.c'
      ;; merges overlays after the text property, in *increasing* order
      ;; of priority so that the highest-priority one ends on top, which
      ;; is where the same list, sorted the same way, is merged here; and
      ;; the active region face follows those in Emacs's redisplay
      ;; pipeline, and is merged here after the property face.
      ;;
      ;; This is what the search highlight needs: `isearch' and
      ;; `lazy-highlight' are *overlay* faces in Emacs, so the face the
      ;; match is drawn with is this one with the search face merged
      ;; over it - NOT the search face alone, which is what replaces a
      ;; keyword's own colour with nothing.
      ;;
      ;; **The base is the *remapped* default face, not its global
      ;; definition.** The C begins with `default_face->lface' where
      ;; `default_face' came from `lookup_basic_face' (`xfaces.c:7005'),
      ;; which is the function that applies `face-remapping-alist' - so a
      ;; buffer whose `text-scale-mode' has remapped `default' starts from
      ;; the *scaled* face. Reading `face-realized-attributes` instead
      ;; takes the global definition, which is why `C-x +` used to make the
      ;; text wider and never taller: the glyphs were drawn at the scale
      ;; the display had been told, while every row was measured from the
      ;; unscaled default - so the rows below cut the taller glyphs off.
      ;;--------------------------------------------------------------
      (if (and mouse-highlight
               %mouse-face-window
               (not %mouse-face-string)
               (eq? (*drawing-window*) %mouse-face-window)
               (>= position %mouse-face-beg)
               (< position %mouse-face-end))
          ;; **One face for the whole run, and it is not the glyphs'
          ;; own.** GNU Emacs computes the mouse face once, at the
          ;; pointer's position, from the `default' face with the
          ;; `mouse-face' property merged over it - `face_at_buffer_position'
          ;; with MOUSE true (`xfaces.c:6955`) reads `Qmouse_face' for the
          ;; property name and starts from the default - and
          ;; `show_mouse_face` paints every glyph of the run with that one
          ;; face. The buffer's own faces under the highlight are not
          ;; consulted, which is why a search-hit line's colours become
          ;; the `highlight' face while the pointer is on it.
          ;;
          ;; **Departure**: Emacs does this as a second pass over the
          ;; built rows; this answers it where every other face is
          ;; decided. Same face, same run, same pixels.
          %mouse-face-attrs
          (let* ((attrs
                  (merge-face-ref (get-text-property position 'face ed)
                                  (merge-face-ref 'default
                                                  (face-attributes-empty))))
                 (attrs
                  (let loop ((ovs (reverse (overlays-at position #t))) (attrs attrs))
                    (if (null? ovs)
                        attrs
                        (loop (cdr ovs)
                              (merge-face-ref (overlay-get (car ovs) 'face) attrs))))))
            (if (region-face-at-position? ed position)
                (merge-face-ref 'region attrs)
                attrs))))

    (define (face-at-buffer-position ed position)
      ;; The display's token for the face in effect at POSITION in ED:
      ;; `attrs-at-buffer-position' folded down to what the terminal can
      ;; draw, which is the last thing `face_at_buffer_position' does.
      ;;
      ;; Emacs caches the realized face against the position, because
      ;; this runs per character; a cache is worth adding when the
      ;; renderer starts asking per character rather than per run.
      ;;--------------------------------------------------------------
      (lookup-face (current-display) (attrs-at-buffer-position ed position)))

    (define (overlay-strings-at position)
      ;; GNU Emacs's `load_overlay_strings' (xdisp.c:7104): the overlay
      ;; strings to draw at POSITION, as `(HEADS . TAILS)' - the
      ;; `before-string's that go before the character there and the
      ;; `after-string's that go after it.
      ;;
      ;; Only the overlays that *start or end* at POSITION are looked at,
      ;; which is what makes these strings appear once rather than along
      ;; the whole range, and only non-empty ones: a `before-string' of
      ;; "" is how an overlay says "put a face here", not "draw
      ;; something".
      ;;
      ;; The order is the C's `compare_overlay_entries' (xdisp.c:7044):
      ;; after-strings before before-strings when they come from
      ;; different overlays, after-strings by *decreasing* priority and
      ;; before-strings by *increasing* - so that the highest-priority
      ;; one ends up nearest the text either way.
      ;;
      ;; Not ported: the `window' property, which limits a string to one
      ;; window, and the invisible-text rule, which shows both the
      ;; before- and after-strings of an overlay whose text is hidden
      ;; (there is no `invisible' property here).
      ;;--------------------------------------------------------------
      (let ((entries
             ;; the C's query is over `[charpos - 1, charpos + 1]' - the
             ;; tree walk's coarse filter - and the exact `start ==
             ;; charpos' / `end == charpos' test comes after; an overlay
             ;; *ending* here is in `[position - 1, position)' and one
             ;; *starting* here is in `[position, position + 1)', so both
             ;; are wanted
             (let loop ((ovs (overlays-in (- position 1) (+ position 1)))
                        (acc '()))
               (cond
                ((null? ovs) (reverse acc))
                (else
                 (let* ((ov (car ovs))
                        (start (overlay-start ov))
                        (end (overlay-end ov))
                        (before (and (= start position)
                                     (overlay-get ov 'before-string)))
                        (after (and (= end position)
                                    (overlay-get ov 'after-string))))
                   (loop (cdr ovs)
                         (append (reverse
                                  (append
                                   (if (and (string? after) (< 0 (string-length after)))
                                       (list (list ov after #t)) '())
                                   (if (and (string? before) (< 0 (string-length before)))
                                       (list (list ov before #f)) '())))
                                 acc))))))))
        (let ((sorted (sort entries
                            (lambda (a b)
                              ;; the C's comparison, in the C's sense of
                              ;; "less": #t when A comes before B
                              (cond ((not (eq? (caddr a) (caddr b)))
                                     (if (eq? (car a) (car b))
                                         (caddr a)     ; same overlay: tail last
                                         (not (caddr a)))) ; tail before head
                                    ((not (= (overlay-priority (car a))
                                             (overlay-priority (car b))))
                                     (if (caddr a)
                                         (> (overlay-priority (car a))
                                            (overlay-priority (car b)))
                                         (< (overlay-priority (car a))
                                            (overlay-priority (car b)))))
                                    (else #f))))))
          ;; each entry keeps its overlay as well as its string, which
          ;; is the C's `string_overlays[]': the string is drawn in the
          ;; *overlay's* face, so the two cannot be separated
          (cons (map (lambda (e) (cons (car e) (cadr e)))
                     (filter (lambda (e) (not (caddr e))) sorted))
                (map (lambda (e) (cons (car e) (cadr e)))
                     (filter (lambda (e) (caddr e)) sorted))))))

    ;; `draw-match' and `highlight-matches' used to be here: the renderer
    ;; searched each drawn row for the pattern and painted what it found.
    ;; Both are gone with `*search-highlight*'. The matches are isearch's
    ;; overlays now and arrive through the ordinary face machinery, which
    ;; is also what fixed the row-by-row search's two blind spots - a
    ;; match spanning a line break, and a font-locked word losing its
    ;; colour inside a match.

    ;;----------------------------------------------------------------
    ;; The cursor's type
    ;;
    ;; How the cursor is drawn is a *type*, not a fixed box: Emacs's
    ;; `cursor-type' names a filled box, a hollow box, a bar, a
    ;; horizontal bar, or nothing at all, and the same variable decides
    ;; it per buffer. `cursor-cells' below answers how WIDE the cursor
    ;; is; these two answer *what* it is.
    ;;------------------------------------------------------------------

    (define (get-specified-cursor-type arg width)
      ;; GNU Emacs's `get_specified_cursor_type': the cursor a
      ;; `cursor-type' value names, as `(TYPE . WIDTH)'. WIDTH is what the
      ;; caller already has - Emacs's C takes it by pointer and only
      ;; overwrites it for the values that name one.
      ;;
      ;; The order of the C is worth keeping, because one of its cases is
      ;; surprising: for `(CAR . CDR)' it sets the *width* from CDR
      ;; before it looks at CAR, so `(hollow . 5)' comes out a hollow box
      ;; five wide - CDR is read even though `hollow' names no width.
      ;; That is Emacs's behaviour, not a transcription slip.
      ;;--------------------------------------------------------------
      (cond
       ((not arg) (cons 'no-cursor width))
       ((eq? arg 'box) (cons 'filled-box-cursor width))
       ((eq? arg 'hollow) (cons 'hollow-box-cursor width))
       ;; a bar's default width is 2, in the C, and is not the frame's
       ((eq? arg 'bar) (cons 'bar-cursor 2))
       ((eq? arg 'hbar) (cons 'hbar-cursor 2))
       ((and (pair? arg)
             (exact-integer? (cdr arg))
             (<= 0 (cdr arg)))
        (cons (cond ((eq? (car arg) 'box) 'filled-box-cursor)
                    ((eq? (car arg) 'bar) 'bar-cursor)
                    ((eq? (car arg) 'hbar) 'hbar-cursor)
                    (else 'hollow-box-cursor))
              (cdr arg)))
       ;; "Treat anything unknown as a hollow box cursor. It was bad to
       ;; signal an error; people have trouble fixing .Xdefaults with
       ;; Emacs, when it has something bad in it." - xdisp.c
       (else (cons 'hollow-box-cursor width))))

    (define (get-window-cursor-type window)
      ;; GNU Emacs's `get_window_cursor_type': what cursor to draw in
      ;; WINDOW, as `(TYPE WIDTH ACTIVE?)'.
      ;;
      ;; This is the rule that makes a window that is not selected show a
      ;; *hollow* cursor rather than a filled one, and a buffer whose
      ;; `cursor-type' is nil show none at all.
      ;;
      ;; Two things the C has are left out, and named rather than
      ;; silently dropped: a *window* may carry its own `cursor-type'
      ;; parameter (`w->cursor_type', which this tree has no window
      ;; parameters for), and a glyph that is an image or a widget gets a
      ;; hollow box instead (`xwidget' and `image' glyph types, which
      ;; this renderer does not have).
      ;;--------------------------------------------------------------
      (let* ((buffer (window-buffer window))
             ;; **The window's own frame.** The C's first line is
             ;; `f = XFRAME (w->frame)' and its test is against *that*
             ;; frame's selected window (`xdisp.c:34847'):
             ;;
             ;;   else if (w != XWINDOW (f->selected_window)
             ;;            || f != FRAME_DISPLAY_INFO (f)->highlight_frame)
             (frame (window-frame window))
             (selected (and frame (frame-selected-window frame)))
             ;; Emacs: "Detect a nonselected window or nonselected
             ;; frame" - a frame that is not the display's highlight
             ;; frame is treated as a non-selected one, so its cursor is
             ;; a hollow box rather than a filled one.
             ;;
             ;; `*frame-focus*' is this tree's stand-in for
             ;; `highlight_frame', and it is a flag where the C has a
             ;; frame - so "the window's frame is the highlight frame" is
             ;; that flag *and* the frame being the selected one. With a
             ;; single frame this is exactly `(*frame-focus*)', which is
             ;; what the test used to read.
             (highlighted? (and (*frame-focus*)
                                (eq? frame (*current-frame*))))
             (non-selected (or (not (eq? window selected))
                               (not highlighted?)))
             (active? (not non-selected))
             (wanted (buffer-cursor-type buffer))
             (frame-cursor (*frame-cursor-type*))
             (specified
              (cond
               ;; Never display a cursor in a window whose buffer asks
               ;; for none.
               ((not wanted) (cons 'no-cursor 1))
               ;; `t' means "the cursor specified for the frame"
               ((eq? wanted #t) frame-cursor)
               (else (get-specified-cursor-type wanted 1)))))
        (let ((shown
               (if non-selected
                   (let ((alt (buffer-cursor-in-non-selected-windows buffer)))
                     (cond
                      ;; a value of its own is a cursor type of its own
                      ((not (eq? alt #t)) (get-specified-cursor-type alt 1))
                      ;; `t' means the usual cursor *modified*: a filled
                      ;; box becomes hollow, and a bar one pixel narrower
                      (else
                       (cons (if (eq? (car specified) 'filled-box-cursor)
                                 'hollow-box-cursor
                                 (car specified))
                             (if (and (eq? (car specified) 'bar-cursor)
                                      (> (cdr specified) 1))
                                 (- (cdr specified) 1)
                                 (cdr specified))))))
                   ;; "Use normal cursor if not blinked off."
                   (if (window-cursor-off? window)
                       (cons 'no-cursor (cdr specified))
                       specified))))
          ;; the C's `active_cursor' out-parameter, which says whether the
          ;; frame the window is on has the focus; no backend consults it
          ;; yet (`x_draw_window_cursor' takes it and never reads it)
          (list (car shown) (cdr shown) active?))))

    (define (cursor-glyph ed position)
      ;; The buffer character POSITION in ED is drawn over, and the face
      ;; in effect there, as `(TEXT . TOKEN)'.
      ;;
      ;; A display that can only fill a rectangle needs both: Emacs's
      ;; cursor does not *hide* what is under it, it redraws the glyph in
      ;; the cursor's colours (`draw_phys_cursor_glyph' with
      ;; `DRAW_CURSOR'), so "the text inside the cursor stays visible".
      ;; Past the end of the line there is no character, and what is
      ;; under the cursor is the space beyond the text - Emacs draws the
      ;; cursor there too.
      ;;
      ;; **POSITION and not the buffer's own cursor.** The glyph under
      ;; the cursor is the one at the *window's* point
      ;; (`draw_phys_cursor_glyph' gets it from the glyph row the display
      ;; iterator stopped on), and only the selected window's point is
      ;; the buffer's. The echo area has no window and passes its
      ;; buffer's cursor.
      ;;--------------------------------------------------------------
      (let* ((line-start (text-editor-get-start-of-line ed position))
             (line-string (line-string-at ed line-start))
             (column (- position line-start)))
        (if (< column (string-length line-string))
            (cons (string (string-ref line-string column))
                  (face-at-buffer-position ed position))
            (cons " " (face->attribute 'default)))))

    (define (cursor-cells ed position)
      ;; How many cells wide the cursor over POSITION is drawn: the
      ;; width of the character there.
      ;;
      ;; Emacs puts the cursor on the glyph at point, so over a
      ;; double-width character it is two cells wide. Past the end of the
      ;; line there is no character to sit on, and Emacs draws a one-cell
      ;; cursor in the space beyond it - which is what this answers there.
      ;;
      ;; **It reads the character at the position, not a line string.**
      ;; This used to build the whole line with `line-string-at' and
      ;; index it - a string of the line, per call, to look at one
      ;; character. Emacs asks the glyph at point (`xdisp.c'), and what
      ;; is at a buffer position here is `fetch-char' - the same
      ;; `FETCH_CHAR' every other reader in the tree uses. `#f' from it
      ;; *is* "past the end of the line".
      ;;--------------------------------------------------------------
      (let* ((line-start (text-editor-get-start-of-line ed position))
             (ch (fetch-char ed position))
             (column (- position line-start)))
        (if ch
            (char-display-cursor-width ch
                                       (current-line-display-column ed column))
            1)))

    (define (window-pixel-y window row)
      ;; The pixel y, within WINDOW's text area, at which screen row ROW
      ;; is drawn - the sum of the heights of the rows above it.
      ;;
      ;; Emacs reads this off its glyph matrix: every row there carries
      ;; `row->y`, written as the display iterator laid it out, and the
      ;; cursor's `w->cursor.y` is one of those. This tree lays the rows
      ;; out on demand instead, so the same sum is walked for - which is
      ;; what `move_it_vertically_backward` does in the C when it has to
      ;; re-derive a position rather than read a row.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (let loop ((r 0) (y 0) (line-start (window-start window)))
          (if (or (>= r row) (not line-start))
              y
              (let* ((texts (line-display-texts ed line-start))
                     (slices (%window-line-slices window texts))
                     (want (min (- row r) (length slices))))
                (let inner ((rest slices) (n 0) (yy y))
                  (if (or (null? rest) (>= n want))
                      (let ((next (line-next-start ed line-start)))
                        (if next
                            (loop (+ r (length slices)) yy next)
                            yy))
                      (let* ((slice (car rest))
                             (m (row-metrics ed (+ line-start (car slice))
                                             (- (cdr slice) (car slice)))))
                        (inner (cdr rest) (+ n 1) (+ yy (cdr m)))))))))))

    (define (window-to-frame-pixel-y window y)
      ;; A pixel Y inside WINDOW's text area, as a frame pixel Y: GNU
      ;; Emacs's macro of the same name (`window.h:1078'),
      ;;
      ;;     #define WINDOW_TO_FRAME_PIXEL_Y(W, Y)  ((Y) + WINDOW_TOP_EDGE_Y (W))
      ;;
      ;; `WINDOW_TOP_EDGE_Y' is `WINDOW_TOP_PIXEL_EDGE', the frame y at
      ;; which the window starts, which here is its top row converted to
      ;; pixels. Everything the redisplay hands a display is in *frame*
      ;; pixels - `write-glyphs!` and `draw-window-cursor!` both draw into
      ;; the frame's one surface - so a window-relative y must cross this
      ;; before it is drawn. Without it every window below the first drew
      ;; its text over the top of the one above: a split window's lower
      ;; half painted at y 0, on top of the upper half's first rows.
      ;;--------------------------------------------------------------
      (+ y (row->pixel-y (window-body-top window))))

    (define (rows-above-in-window window line-start)
      ;; How many rows of WINDOW are above the line beginning at
      ;; LINE-START, answered from the glyph matrix instead of the buffer -
      ;; `rows-above`'s question, asked the way GNU Emacs asks it.
      ;;
      ;; **This is `try_cursor_movement`'s walk.** Emacs finds the row the
      ;; cursor is on by stepping through `w->current_matrix` and comparing
      ;; each row's `start` (`xdisp.c:19961`, `MATRIX_ROW_START_CHARPOS`),
      ;; and the matrix is exactly why that is cheap: a row *carries* the
      ;; position it was laid out from, so finding one costs a comparison
      ;; and not the layout of every line above it. `rows-above` lays out
      ;; each of those lines (`line-display-texts`, `line-texts-rows`) to
      ;; learn what the matrix already says - measured on a window of long
      ;; wrapped lines, 1.3 ms of a 2.8 ms keystroke.
      ;;
      ;; `#f` when the matrix cannot answer: it is not what the screen
      ;; holds (the window was not drawn this redisplay and something has
      ;; changed), or the line is not among its rows. The caller then falls
      ;; back to counting lines, which is always right and only slower.
      ;;------------------------------------------------------------------
      (and (window-matrix-valid? window)
           (let ((current (window-current-matrix window)))
             (and current
                  (let ((rows (glyph-matrix-rows current)))
                    (let loop ((i 0))
                      (cond ((>= i (vector-length rows)) #f)
                            ((not (vector-ref rows i)) #f)
                            ((= (glyph-row-start (vector-ref rows i)) line-start)
                             i)
                            ((> (glyph-row-start (vector-ref rows i)) line-start)
                             #f)
                            (else (loop (+ i 1))))))))))

    (define (cursor-screen-position window)
      ;; Where on the screen WINDOW's point belongs, as a pair, or #f
      ;; when it is scrolled out of view. In frame coordinates: the
      ;; window's own rows start below its top.
      ;;
      ;; It is the *window's* point that is placed, and only the
      ;; selected window shows a cursor - a terminal has one cursor, as
      ;; GNU Emacs draws only the selected window's. "The window's point"
      ;; is `window-point' and not the buffer's cursor: a window that is
      ;; not the selected one holds its own, and placing the cursor by
      ;; the buffer's put a second frame's cursor wherever the first
      ;; frame's point was.
      ;;
      ;; Point is always on a line the buffer really has - the engine
      ;; reports the end of a buffer whose last line has no break after
      ;; it as the end of that line, not as an empty line past it (see
      ;; `TEXT-EDITOR-INDEX-LINE-OFFSET'), which is where GNU Emacs puts
      ;; `point-max' too. A line break at the end of the buffer *does*
      ;; start an empty line, and that line gets a row of its own.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (pt (window-point window))
             (line-start (text-editor-get-start-of-line ed pt))
             (column (- pt line-start))
             (line-string (line-string-at ed line-start))
             (texts (line-display-texts ed line-start))
             (rows (window-line-slices-at window line-start))
             (width (window-body-width window))
             (vheight (window-body-height window))
             ;; The cursor's own row is not its line's row: a wrapped
             ;; line is several rows tall, so the rows above the cursor's
             ;; line have to be counted too - and within its line, the
             ;; rows before the one the cursor's column falls on. The
             ;; count above comes from the glyph matrix when it can answer
             ;; (see `rows-above-in-window`), which is what makes moving
             ;; point cost a cursor rather than a window.
             (screen-row (+ (or (rows-above-in-window window line-start)
                                (rows-above window line-start))
                            (rows-row-of-column rows column)))
             ;; The column within its *row*: a continuation row starts at
             ;; screen column zero, so the cursor's display column is
             ;; measured from where its row begins, not the line.
             (row-start (car (list-ref rows (rows-row-of-column rows column)))))
        ;; **`if' and not `when'.** A `when' whose test fails answers the
        ;; *unspecified* value, which is true in Scheme - so the caller's
        ;; `(when at ...)' drew a cursor at `(car #<unspecified>)' and
        ;; died. Measured: two frames, point 300 in the selected one, and
        ;; the other frame's cursor placement raised "Wrong type argument
        ;; in position 1 (expecting pair)". The docstring above has
        ;; always said `#f' here.
        (if (and (>= screen-row 0) (< screen-row vheight))
          (cons (+ screen-row (window-body-top window))
                (+ (window-body-left window)
                   (if (window-wraps? window)
                       ;; the column within its *row*: a continuation row
                       ;; starts at screen column zero, so the cursor's
                       ;; display column is measured from where its row
                       ;; begins, not the line.
                       (min (- (current-line-display-column ed column)
                               (line-texts-column texts (or row-start 0)))
                            (- width 1))
                       ;; a truncated line is one row, and an hscrolled
                       ;; row's first cell is the left truncation glyph
                       ;; that the character at the hscroll column is
                       ;; overwritten by - so the cursor's column is its
                       ;; display column less the hscroll, and never
                       ;; before the row's first cell, which is where
                       ;; `w->cursor.x' sits too (`xdisp.c' computes it
                       ;; from the glyphs' screen positions)
                       (max 0
                            (min (- (current-line-display-column ed column)
                                    (%window-hscroll window))
                                 (- width 1))))))
          #f)))

    (define (window-end window)
      ;; GNU Emacs's `window-end': "Return the end position of the text
      ;; visible in WINDOW." Emacs answers from `w->window_end_pos',
      ;; recorded as it drew; here the rows are laid out from the top line
      ;; by the same walk `render-window-rows!' makes.
      ;;
      ;; It is the end of the last *row* that fits, which is not the same
      ;; as the end of the last line: a line whose remaining rows fall off
      ;; the bottom ends the window part way through, and the answer is
      ;; where that row ends. A caller bounding a search is asking exactly
      ;; this - "is this match on the screen?" - so a whole-line answer
      ;; would reach below the window.
      ;;--------------------------------------------------------------
      ;;
      ;; When the window has been drawn and nothing has changed since,
      ;; the answer is already recorded - `w->window_end_pos' as a
      ;; distance from the end of the buffer, and the screen row it is
      ;; on. That is the whole point of those two fields: Emacs does not
      ;; find the end by walking the rows, it writes it down as it draws.
      ;; The walk below is for a window that has not been drawn yet.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window))
            (vheight (window-body-height window)))
        (if (%window-end-valid? window)
            (- (buffer-z ed) (%window-end-pos window))
            (let loop ((pos (window-start window)) (row 0))
              (if (>= row vheight)
                  pos
                  ;; the walk carries POS, the line's own buffer position,
                  ;; so each line it crosses costs that line and not its
                  ;; distance from the beginning of the buffer
                  (let* ((texts (buffer-line-texts-at window pos))
                         (slices (%window-line-slices window texts))
                         (fits (- vheight row)))
                    (if (>= fits (length slices))
                        (let ((next (line-next-start ed pos)))
                          (if next
                              (loop next (+ row (length slices)))
                              ;; the buffer's last line: it starts no
                              ;; other, so that is where the text ends
                              (text-editor-get-end-of-line ed pos)))
                        ;; the line is cut off by the bottom of the
                        ;; window: the last row that fits ends it
                        (+ pos (cdr (list-ref slices (- fits 1)))))))))))

    (define (pos-visible-in-window-p position . args)
      ;; GNU Emacs's `pos-visible-in-window-p` (`window.c:1977`): "Return
      ;; non-nil if position POS is currently on the frame in WINDOW."
      ;;
      ;; Emacs answers from the glyph matrix and can say whether the
      ;; character is *fully* visible (a line cut off at the bottom is
      ;; not, unless PARTIALLY); this tree's `window-end` already ends at
      ;; the last *row* that fits, so a position inside a line that is
      ;; cut off is past the answer and reads as not visible - the same
      ;; answer for the caller the completion window's TAB uses
      ;; (`completion--in-region-1` asks whether the list's last
      ;; character is on the screen).
      ;;
      ;; POSITION nil is WINDOW's point, as there; `t`, "the first
      ;; position of the last visible line", needs the row walk and is
      ;; not carried - nothing here asks for it. PARTIALLY, whose value
      ;; is the coordinates list, is accepted and ignored for the same
      ;; reason: this answers the boolean case.
      ;;--------------------------------------------------------------
      (let* ((window (if (and (pair? args) (car args))
                         (car args)
                         (selected-window)))
             (pos (if position position (window-point window)))
             (start (window-start window))
             (end (window-end window)))
        (and (>= pos start) (<= pos end) #t)))

    (define (posn-at-point position window)
      ;; GNU Emacs's `posn-at-point` (`keyboard.c:13594`): "Return
      ;; position information for buffer position POS in WINDOW. POS
      ;; defaults to point in WINDOW; WINDOW defaults to the selected
      ;; window. ... Return nil if POS is not visible in WINDOW."
      ;;
      ;; The C asks `pos_visible_in_window_p` for the glyph's pixel
      ;; coordinates and hands them to `posn_at_x_y`; this asks the row
      ;; walk the cursor is placed with for the position's *cell*
      ;; (screen row and column), and hands that to `posn-at-x-y` in
      ;; pixels - the same two steps, over the geometry this tree's
      ;; renderer actually laid out.
      ;;
      ;; **What is not carried, and what each would take.** Emacs's posn
      ;; has the OBJECT, POS, (COL . ROW), IMAGE and size fields; this
      ;; answers the four fields `posn-at-x-y` builds, whose AREA-OR-POS
      ;; is the buffer position, which is all any caller here reads. A
      ;; position inside a `display` string or an invisible run is
      ;; answered as the cell it is drawn on, not the string, because
      ;; the posn is rebuilt from the coordinates.
      ;;--------------------------------------------------------------
      (let* ((window (or window
                         (and (*current-frame*) (selected-window))))
             (ed (and window (window-buffer window)))
             (pos (or position (and window (window-point window)))))
        (and window
             ed
             ;; **No display, no cells to measure.** A headless test
             ;; (the help suites) has no display object and asks this
             ;; through `event-start`; there is no screen for the
             ;; position to be on, which is the nil answer.
             (current-display)
             (>= pos (buffer-beg ed))
             (<= pos (buffer-z ed))
             (let* ((line-start (text-editor-get-start-of-line ed pos))
                    (column (- pos line-start))
                    (rows (window-line-slices-at window line-start))
                    (k (rows-row-of-column rows column))
                    (texts (line-display-texts ed line-start))
                    (row-start (car (list-ref rows k)))
                    (width (window-body-width window))
                    (screen-row (+ (or (rows-above-in-window window line-start)
                                       (rows-above window line-start))
                                   k))
                    (vheight (window-body-height window)))
               (and (>= screen-row 0) (< screen-row vheight)
                    (let* ((display-col (current-line-display-column ed column))
                           (col (+ (window-body-left window)
                                   (if (window-wraps? window)
                                       (min (- display-col
                                               (line-texts-column texts
                                                                  (or row-start 0)))
                                            (- width 1))
                                       (max 0
                                            (min (- display-col
                                                    (%window-hscroll window))
                                                 (- width 1))))))
                           (row (+ screen-row (window-body-top window)))
                           (d (current-display)))
                      (posn-at-x-y (* col (column-width d))
                                   (* row (line-height d))
                                   (window-frame window))))))))

    (define (event--posn-at-point)
      ;; GNU Emacs's `event--posn-at-point` (`subr.el:1894`): the posn
      ;; `event-start` and `event-end` answer for anything that is not a
      ;; mouse event - a keyboard key, whose event is an integer or a
      ;; symbol, and nil. "Use `window-point` for the case when the
      ;; current buffer is temporarily switched to some other buffer",
      ;; and fall back to a short position list when point is off
      ;; screen.
      ;;
      ;; **`subr.el`'s function, placed here** (a named departure):
      ;; `event-start` is `subr.scm`'s and this needs a window and
      ;; `posn-at-point`, both above that library, so the fallback
      ;; arrives through `*event--posn-at-point-function*`.
      ;;
      ;; Not carried: the minibuffer-window arm - this tree's echo area
      ;; is an ordinary window and `(selected-window)` is it while a
      ;; prompt is up - and the `(setf (nth 5 posn) pos)` correction for
      ;; a posn whose OBJECT is a display string, because the posn
      ;; built here has no OBJECT field.
      ;;--------------------------------------------------------------
      (let ((window (and (*current-frame*) (selected-window))))
        (if (not window)
            #f
            (let ((pos (window-point window)))
              (or (posn-at-point pos window)
                  (list window pos (cons 0 0) 0))))))

    ;;----------------------------------------------------------------
    ;; Building rows - the C's `display_line`
    ;;----------------------------------------------------------------
    ;;
    ;; **This is the piece that makes a keystroke cheap.** GNU Emacs's
    ;; `display_line` (`xdisp.c`) does not draw: it fills a `glyph_row`
    ;; with `<glyph>`s, each carrying its character, its width and its
    ;; **face already resolved to an integer**. A redisplay builds the
    ;; rows a window should show and compares them with the ones it built
    ;; last time; the ones that match are not drawn at all.
    ;;
    ;; Before this, `draw-line!` was the only path: it walked a line's
    ;; characters, merged a face per run and handed Pango a string, for
    ;; every row of every window, on every keystroke. Measured at 16-25 ms
    ;; a key. Building a row instead costs ~0.011 ms, and *drawing* one
    ;; from a built row costs one `write-glyphs!` per run - so the saving
    ;; is not in the drawing, it is in not drawing the rows that did not
    ;; change.

    (define (%reset-glyph! g text token width)
      ;; Write one glyph into an existing `<glyph>`: the fields
      ;; `append_glyph` (`xdisp.c:6973') sets as it fills
      ;; `row->glyphs[area][row->used[area]++]`.
      ;;
      ;; **The record is reused, not replaced.** Emacs's glyph matrix is
      ;; a pool allocated once and written over every redisplay; this
      ;; tree's rows hold vectors of records, and making a fresh record
      ;; per cell per keystroke was 1,920 records - measured, 330 KB of
      ;; garbage for one 24x80 redisplay, which GC then had to collect
      ;; (half a keystroke's wall time). The vector `line-slice-glyphs`
      ;; and `extend-face-to-end-of-line` write into is the row's own
      ;; storage, and after `assign-row` swapped it out of the current
      ;; matrix it is nobody else's.
      ;;--------------------------------------------------------------
      (set-glyph-char! g text)
      (set-glyph-face-id! g token)
      (set-glyph-pixel-width! g width)
      (set-glyph-type! g glyph-type-char)
      (set-glyph-padding! g #f)
      (set-glyph-voffset! g 0)
      g)

    (define (line-slice-glyphs texts from to x0 line-start pool width)
      ;; The `<glyph>`s of one screen row: the slice [FROM, TO) of the
      ;; line's TEXTS, started at cell X0.
      ;;
      ;; **FROM and TO are column offsets into the line**, which is what
      ;; `line-texts-glyphs` and `line-texts-offsets` take; LINE-START is
      ;; the buffer position the line begins at, so the buffer position of
      ;; column I is `(+ line-start from i)`. The face is asked about that
      ;; position - `face_at_buffer_position` takes a buffer position, and
      ;; passing the column offset instead asked about position 0, which
      ;; is out of range.
      ;;
      ;; **One glyph per buffer column, built in one walk**, which is
      ;; what `append_glyph` does for a character: `texts-glyph` and
      ;; `texts-width` already know display strings, tabs and wide
      ;; characters, so each column's string and width come straight from
      ;; them. This used to build two lists first - `line-texts-glyphs`
      ;; and `line-texts-offsets` - and walk those; Emacs's `display_line`
      ;; appends each glyph as it produces it and builds neither, and the
      ;; lists were ~18% of this redisplay's allocation (measured: 10.3 MB
      ;; against 8.4 MB for 50 keystrokes).
      ;;
      ;; **The walk stays here rather than in `indentc`**, where the two
      ;; accessors live. Moving it there would make their calls
      ;; same-library and the two lists disappear *and* keep the calls
      ;; cheap; but the accessors would then have to write `<glyph>`
      ;; records, and `indentc` is text layout, not display. Measured on
      ;; a loaded machine, this walk and the list-building one are the
      ;; same wall time; the allocation is the difference.
      ;;
      ;; **The face is realized once per RUN, not once per glyph.** That
      ;; is `line-face-runs`' rule and its own note says why: realizing is
      ;; ~15us on GTK against ~1.2us for the attribute lookup, twelve
      ;; times the cost, "to intern a face a run is about to hand over
      ;; unchanged". Asked per glyph it is 24 rows by 80 columns of
      ;; realizes on every keystroke - measured here at 15.2ms of a 19.8ms
      ;; `render!`, which is the whole reason a keystroke was slow. The
      ;; comparison that splits a run is on the *unrealized* attributes
      ;; (the C's `face_id` is likewise resolved when the row is built,
      ;; from a face already interned), so consecutive glyphs sharing a
      ;; face share the token the first one paid for.
      ;;--------------------------------------------------------------
      (let* ((n (- to from))
             ;; **The row's own glyph storage, kept across redisplays.**
             ;; `POOL` is what the desired row held - after `assign-row`
             ;; swapped it out of the current matrix, storage nobody else
             ;; references - and it is written over in place, as Emacs's
             ;; glyph pool is. Its length is a *capacity*: a row needs
             ;; room for the window's whole width, because
             ;; `extend-face-to-end-of-line` fills the rest of the row
             ;; with space glyphs, and it must be able to do that in the
             ;; same vector. `used` (below, `n`) is what is drawn; the
             ;; length never is.
             (capacity (max n width))
             (vec (if (and pool (>= (vector-length pool) capacity))
                      pool
                      (make-vector capacity #f)))
             ;; **The faces come from the runs, not from an ask per
             ;; glyph.** `line-face-runs` walks by `face-change-limit`,
             ;; so a row of one face costs one attribute merge and one
             ;; realize however wide it is; asking `attrs-at-buffer-position`
             ;; at every glyph was ~13us a character (measured) and ran
             ;; the whole row's cost up with the window's width. A
             ;; `display` string stands for the column it starts on, and
             ;; a run is in buffer columns, so the two line up: glyph I
             ;; is character FROM+I.
             (runs (line-face-runs (current-buffer)
                                   (+ line-start from) (- to from))))
        ;; **The walk**: column by column from FROM, carrying the
        ;; screen column so a tab expands where it is drawn; the runs are
        ;; consumed in step - the first run still covering column I is
        ;; this glyph's face.
        (let loop ((i 0) (col 0) (rs runs))
          (when (< i n)
            (let* ((rs (let skip ((rs rs))
                         (if (and (pair? rs) (pair? (cdr rs))
                                  (>= i (cadr (car rs))))
                             (skip (cdr rs))
                             rs)))
                   (text-index (+ from i))
                   (token (if (pair? rs)
                              (caddr (car rs))
                              (lookup-face (current-display)
                                            (attrs-at-buffer-position
                                             (current-buffer)
                                             (+ line-start text-index)))))
                   (text (texts-glyph texts text-index col))
                   (w (max 1 (texts-width texts text-index col))))
              (let ((slot (vector-ref vec i)))
                (if (glyph? slot)
                    (%reset-glyph! slot text token w)
                    (vector-set! vec i
                                 (make-glyph text token w
                                             glyph-type-char #f 0))))
              (loop (+ i 1) (+ col w) rs))))
        (cons vec n)))

    (define (line-slice-glyphs-with-strings ed texts from to line-start ovs width)
      ;; The `<glyph>`s of one screen row when the row carries overlay
      ;; strings - GNU Emacs's `display_line` with `it->string` set.
      ;;
      ;; OVS is `row-overlay-strings`' vector: per buffer column of the
      ;; line, the `(before-string . after-string)` overlays there. In
      ;; Emacs the strings are *glyphs in the row*, pushed onto the
      ;; iterator by `get_overlay_strings` and appended by `append_glyph`
      ;; like any other character, so the row diff sees them and the
      ;; matrix carries them - which is why this builds glyphs rather
      ;; than drawing.
      ;;
      ;; **A second walk, and only for rows that have strings.** The
      ;; pool-reusing walk in `line-slice-glyphs` is what makes a
      ;; keystroke allocation-free, and a row with an overlay string is
      ;; rare enough (the echo row while a message shows) to pay for a
      ;; fresh vector. The strings' characters advance the screen column
      ;; as they go, so a tab after one expands from where the string
      ;; left off.
      ;;--------------------------------------------------------------
      (let* ((n (- to from))
             (specs '())
             (col 0)
             (push! (lambda (text token w)
                      (set! specs (cons (list text token w) specs))
                      (set! col (+ col w))))
             (push-string! (lambda (ov+str)
                             (let* ((ov (car ov+str))
                                    (text (cdr ov+str))
                                    (token (face->attribute
                                            (or (overlay-get ov 'face) 'default))))
                               (let loop ((i 0))
                                 (when (< i (string-length text))
                                   (let ((ch (string (string-ref text i))))
                                     (push! ch token (max 1 (line-display-width ch)))
                                     (loop (+ i 1)))))))))
        (let loop ((i 0))
          (when (< i n)
            (let* ((linecol (+ from i))
                   (entry (and ovs (< linecol (vector-length ovs))
                               (vector-ref ovs linecol))))
              ;; an entry is `(HEADS . TAILS)' or the empty list
              (when (pair? entry) (for-each push-string! (car entry)))
              (let ((text (texts-glyph texts linecol col))
                    (w (max 1 (texts-width texts linecol col))))
                (push! text (face-at-buffer-position ed (+ line-start linecol)) w))
              (when (pair? entry) (for-each push-string! (cdr entry)))
              (loop (+ i 1)))))
        ;; "The entry at LEN is the row's *end*" - the `after-string` of
        ;; an overlay that ends where the row does.
        (let ((entry (and ovs (< to (vector-length ovs)) (vector-ref ovs to))))
          (when (pair? entry) (for-each push-string! (cdr entry))))
        (let* ((specs (reverse specs))
               (made (length specs))
               (vec (make-vector (max made width) #f)))
          (let loop ((rest specs) (i 0))
            (when (pair? rest)
              (let ((spec (car rest)))
                (vector-set! vec i (make-glyph (car spec) (cadr spec) (caddr spec)
                                               glyph-type-char #f 0)))
              (loop (cdr rest) (+ i 1))))
          (cons vec made))))

    (define (extend-fill-token ed end last-token)
      ;; The face the rest of a row is filled with: GNU Emacs's
      ;; `extend_face_id` (`xdisp.c:24429`) -
      ;;
      ;;   (it->face_id == default_face->id || it->s != NULL)
      ;;   ? it->face_id
      ;;   : (it->glyph_row->ends_at_zv_p
      ;;      ? default_face->id
      ;;      : face_at_pos (it, LFACE_EXTEND_INDEX));
      ;;
      ;; END is the row end's buffer position - the line break, or
      ;; `point-max' for the buffer's last line - and LAST-TOKEN the token
      ;; of the row's last glyph.
      ;;
      ;; **`:extend` is what a face says about this.** `face_at_pos` with
      ;; the EXTEND filter merges only the faces at END that *specify*
      ;; `:extend` (`merge_named_face`, `xfaces.c:2527`), so the `isearch`
      ;; and `lazy-highlight` faces - neither has it - stop at the match,
      ;; while `region`, which has `:extend t`, reaches the edge of the
      ;; screen. This answers the last glyph's token when the merged
      ;; `:extend` is true and the default token when it is not. Emacs's
      ;; own fill face is the merge of the extending faces *alone*, which
      ;; differs from the last glyph's only when a non-extending face
      ;; covers END too - a font-locked word inside the region - and that
      ;; difference is named in DEPARTURES.md.
      ;;--------------------------------------------------------------
      (let ((default-token (face->attribute 'default)))
        (cond
         ((eqv? last-token default-token) last-token)
         ((>= end (buffer-z ed)) default-token)
         (else
          (let ((extend (attribute-value (attrs-at-buffer-position ed end)
                                         ':extend)))
            (if (and (not (eq? extend *undefined-face-attribute*)) extend)
                last-token
                default-token))))))

    (define (extend-face-to-end-of-line ed row end width)
      ;; GNU Emacs's `extend_face_to_end_of_line` (`xdisp.c:24379`) for a
      ;; *terminal*: fill the rest of the row with space glyphs carrying
      ;; the extended face, so the whole line is painted in one face.
      ;;
      ;; **A terminal cannot paint a background it has not written**, so
      ;; the cells to the right of the text have to be written too. GNU
      ;; Emacs does exactly this - the function's own comment: "If the
      ;; text area is empty, a space glyph is added to it to carry the
      ;; face used for clearing the line" - and it is what makes a theme
      ;; change look the same across a whole line. Without it the row's
      ;; tail is erased with `clear_end_of_line` under the *terminal's*
      ;; default colours (`\e[39;49m` then `\e[K`), while the text is
      ;; written with the face's explicit RGB; when the terminal's
      ;; palette changes, the text keeps its colours and the erased tail
      ;; takes the new ones, so the line ends in a jagged outline.
      ;; Measured on Emacs 31.1 in a pty: every text row is written as
      ;; the text plus spaces to the last column, wrapped in the default
      ;; face's `\e[38;2;…m\e[48;2;…m … \e[39;49m`.
      ;;
      ;; The face is `extend-fill-token`'s: the last glyph's when the
      ;; faces at the row's end say `:extend`, the default face when they
      ;; do not (the `isearch` highlight stops at the match; the region
      ;; reaches the edge), and the default face for a row with no glyphs
      ;; at all or one that ends at `point-max`.
      ;;--------------------------------------------------------------
      (let* ((vec (glyph-row-glyphs row))
             (n (glyph-row-used row))
             ;; the cells the row already covers, which is `it->current_x`
             ;; in the C: a glyph is one entry but a wide character is two
             ;; cells, so the count and the width are not the same number
             (used (let loop ((i 0) (w 0))
                     (if (>= i n)
                         w
                         (loop (+ i 1)
                               (+ w (glyph-pixel-width (vector-ref vec i)))))))
             (pad (- width used)))
        (when (> pad 0)
          ;; **The padding is written into the row's own storage**, the
          ;; same vector `line-slice-glyphs` just filled. Emacs's
          ;; `extend_face_to_end_of_line` appends glyphs to the row
          ;; (`append_glyph`), and appending to a pool that is already
          ;; wide enough allocates nothing. A `make-vector` here made a
          ;; second 80-slot vector and up to 80 new glyph records for
          ;; every row on every keystroke, which was the larger half of
          ;; the redisplay's garbage.
          (let* ((token (if (> n 0)
                            (extend-fill-token
                             ed end (glyph-face-id (vector-ref vec (- n 1))))
                            (face->attribute 'default)))
                 (need (+ n pad))
                 (vec (if (>= (vector-length vec) need)
                          vec
                          (let ((new (make-vector need #f)))
                            (let loop ((i 0))
                              (when (< i n)
                                (vector-set! new i (vector-ref vec i))
                                (loop (+ i 1))))
                            new))))
            (let loop ((i n))
              (when (< i need)
                (let ((slot (vector-ref vec i)))
                  (if (glyph? slot)
                      (%reset-glyph! slot " " token 1)
                      (vector-set! vec i
                                   (make-glyph " " token 1
                                               glyph-type-char #f 0))))
                (loop (+ i 1))))
            (set-glyph-row-glyphs! row vec)
            (set-glyph-row-used! row need)))))

    ;;----------------------------------------------------------------
    ;; `fontification-functions` (`xdisp.c:39022'), and the redisplay
    ;; hook that runs them (`handle_fontified_prop`, `xdisp.c:4667')
    ;;----------------------------------------------------------------
    ;;
    ;; "List of functions to call to fontify regions of text. Each
    ;; function is called with one argument POS. Functions must fontify a
    ;; region starting at POS in the current buffer, and give fontified
    ;; regions the property `fontified' with a non-nil value."
    ;;
    ;; Buffer-local, and set by `jit-lock-mode` (which lives in
    ;; `(schemacs editor jit-lock)`, above this library), so it is the
    ;; tree's per-buffer store rather than one of its hook parameters -
    ;; the same shape as `buffer-truncate-lines` above.
    ;;
    ;; **Not carried**: the `long-line-optimizations` narrowing, the
    ;; `memory-full` and `run-hooks` guards, and
    ;; `redisplay-skip-fontification-on-input` (nothing here reads
    ;; pending input from the renderer).
    (define (fontification-functions)
      (buffer-local-value (current-buffer) 'fontification-functions '()))
    (define (set!fontification-functions! value)
      (set-buffer-local-value! (current-buffer) 'fontification-functions value))

    (define *in-fontification-functions* (make-parameter #f))
    ;; ^ The C's `specbind (Qfontification_functions, Qnil)` (`:4702'):
    ;; while the functions run the variable is empty, so a fontifier that
    ;; causes a redisplay cannot recurse. A separate flag rather than a
    ;; rebound list, because the buffer's own list would win over a
    ;; parameter.

    (define (run-fontification-functions pos)
      ;; `handle_fontified_prop`: text whose `fontified` property is nil,
      ;; and whose position is before `Z`, is fontified before it is laid
      ;; out - each function is called with POS and fontifies a region
      ;; starting there.
      ;;--------------------------------------------------------------
      (when (and (not (*in-fontification-functions*))
                 (< pos (point-max))
                 (not (get-text-property pos 'fontified)))
        (let ((fns (fontification-functions)))
          (when (pair? fns)
            (parameterize ((*in-fontification-functions* #t))
              (for-each (lambda (f) (f pos)) fns))))))

    (define (build-row! ed row texts from to x0 y width
                        line-start more? truncated? row-width metrics)
      ;; Fill ROW from one screen row of a line: `display_line`.
      ;;
      ;; The row keeps the glyphs, the geometry it was drawn at, the two
      ;; markers the last cell carries (`$` for a truncated line, `\` for
      ;; a continued one) and the buffer positions it covers. The hash is
      ;; taken once, here, which is what `row_equal_p` compares first.
      ;;
      ;; **Overlay `before-string`/`after-string` are glyphs in the row**,
      ;; which is what GNU Emacs makes of them (`get_overlay_strings`
      ;; pushes the string onto the iterator and `append_glyph` puts it in
      ;; the row, `xdisp.c:6920`). They used not to be carried at all,
      ;; because nothing in this tree could make one; `minibuffer-message`
      ;; makes one now - the `[No match]` and `[Sole completion]` text
      ;; after a prompt - so a row that has any is built by
      ;; `line-slice-glyphs-with-strings`.
      ;;--------------------------------------------------------------
      ;; `handle_fontified_prop`: a row whose first position is not yet
      ;; fontified is fontified *before* it is built, so the glyphs see
      ;; the faces the fontifier put down. Emacs checks the property as
      ;; its iterator reaches each position; checking each row's start is
      ;; the same rule at the same granularity the row builder has.
      (run-fontification-functions (+ line-start from))
      (let* ((ovs (row-overlay-strings ed (+ line-start from) (- to from)))
             (any-strings?
              (let loop ((i 0))
                (cond ((>= i (vector-length ovs)) #f)
                      ((null? (vector-ref ovs i)) (loop (+ i 1)))
                      (else #t))))
             (made (if any-strings?
                       (line-slice-glyphs-with-strings
                        ed texts from to line-start ovs width)
                       (line-slice-glyphs texts from to x0 line-start
                                          (glyph-row-glyphs row) width)))
             (vec (car made))
             (n (cdr made)))
        (set-glyph-row-glyphs! row vec)
        (set-glyph-row-used! row n)
        ;; **A terminal's row is filled to the window's edge**, which is
        ;; `extend_face_to_end_of_line`'s terminal branch (`xdisp.c`) and
        ;; is called here because `display_line` calls it there - the
        ;; padding is part of the row, so the diff sees it and the whole
        ;; line is painted in the face. A window-system display needs no
        ;; glyphs for it: `draw-glyph-row!` paints the remainder with
        ;; `clear-end-of-line!` in the default face.
        (unless (window-system-display? (current-display))
          (extend-face-to-end-of-line ed row (+ line-start to) width))
        (set-glyph-row-x! row x0)
        (set-glyph-row-y! row y)
        ;; `compute_line_metrics`: the row is as tall as the tallest face
        ;; on it, which `row-metrics` has already worked out.
        (set-glyph-row-ascent! row (car metrics))
        (set-glyph-row-height! row (cdr metrics))
        (set-glyph-row-pixel-width!
         row (* width (car (display-cell-size (current-display)))))
        (set-glyph-row-start! row (+ line-start from))
        (set-glyph-row-end! row (+ line-start to))
        (set-glyph-row-mode-line! row #f)
        (set-glyph-row-continued! row more?)
        (set-glyph-row-truncated-on-right! row truncated?)
        (set-glyph-row-displays-text! row #t)
        (set-glyph-row-ends-at-zv! row #f)
        (set-glyph-row-fill-line! row (>= row-width width))
        (set-glyph-row-hash! row (row-hash row))
        (set-glyph-row-enabled! row #t)
        row))

    (define (build-blank-row! row ed x0 y width metrics)
      ;; GNU Emacs's `display_line` for a screen row past the end of the
      ;; buffer: `prepare_desired_row`, whose own comment is "Clear the
      ;; result glyph row and enable it", and then
      ;; `extend_face_to_end_of_line`, which on a terminal produces the
      ;; blank glyphs that carry the default face across the row.
      ;;
      ;; **The row is enabled and holds glyphs, and that is the point.**
      ;; A row left disabled is one the diff can never skip: the current
      ;; matrix holds what was last drawn while the desired row holds
      ;; nothing, so the row was cleared again on *every* redisplay. That
      ;; cost nothing while a clear was `ce` (three bytes); once a
      ;; terminal row is filled to the edge it is three bytes for each of
      ;; the blank rows below the text, per keystroke. Measured typing
      ;; one character into a one-line buffer: 2227 bytes per keystroke
      ;; against GNU Emacs 31.1's 211, and with it the editor fell behind
      ;; fast typing and ran the backlog off in bursts. Emacs builds the
      ;; row the first time and it compares equal for ever after.
      ;;--------------------------------------------------------------
      ;; **The row's glyph storage is kept**, which is
      ;; `prepare_desired_row`'s "row->enabled_p = true; row->used =
      ;; 0": a blank row is written from slot 0 by
      ;; `extend-face-to-end-of-line`, and writing over the row's own
      ;; glyphs allocates nothing. Resetting the vector here made every
      ;; blank row below the text allocate its width in glyph records
      ;; again on every redisplay.
      (set-glyph-row-used! row 0)
      ;; the same rule `build-row!` follows: the padding is a *terminal*
      ;; row's, because a window system paints the remainder with
      ;; `clear-end-of-line!` at draw time.
      (unless (window-system-display? (current-display))
        (extend-face-to-end-of-line ed row (buffer-z ed) width))
      (set-glyph-row-x! row x0)
      (set-glyph-row-y! row y)
      (set-glyph-row-ascent! row (car metrics))
      (set-glyph-row-height! row (cdr metrics))
      (set-glyph-row-pixel-width!
       row (* width (car (display-cell-size (current-display)))))
      (set-glyph-row-start! row (buffer-z ed))
      (set-glyph-row-end! row (buffer-z ed))
      (set-glyph-row-mode-line! row #f)
      (set-glyph-row-continued! row #f)
      (set-glyph-row-truncated-on-right! row #f)
      (set-glyph-row-displays-text! row #f)
      ;; **This row *is* the end of its line**, which is what
      ;; `ends_at_zv_p` means - the C's flag for a row whose last
      ;; character is the last of the buffer.
      (set-glyph-row-ends-at-zv! row #t)
      (set-glyph-row-fill-line! row #t)
      (set-glyph-row-hash! row (row-hash row))
      (set-glyph-row-enabled! row #t)
      row)

    ;;----------------------------------------------------------------
    ;; `update_window` - build the desired rows, draw the ones that changed
    ;;----------------------------------------------------------------
    ;;
    ;; **This is the C's `dispnew.c` loop, and it is where the speed comes
    ;; from.** `display_line` fills the desired matrix; the update walks
    ;; the desired and current matrices together and draws only the rows
    ;; that differ. A cursor move changes the cursor's row and the mode
    ;; line, so two rows are drawn out of twenty-four.

    (define (display-window! window)
      ;; GNU Emacs's `redisplay_window` (`xdisp.c`) for one window: bring
      ;; the desired matrix up to date with the buffer.
      ;;
      ;; This draws nothing. It builds rows - the expensive per-frame work
      ;; of walking the buffer and resolving faces - and leaves them in
      ;; the desired matrix for `update-window!` to compare.
      ;;--------------------------------------------------------------
      ;; **Which window's rows these are**, so `attrs-at-buffer-position`
      ;; can paint the mouse face over the run the pointer is on - the
      ;; equivalent of Emacs handing the window to `show_mouse_face`.
      (parameterize ((*drawing-window* window))
      ;; **The window's buffer is the current one while its rows are
      ;; built.** GNU Emacs's `redisplay_window` does
      ;; `set_buffer_internal (XBUFFER (w->contents))` for exactly this
      ;; reason: a face's realization reads buffer-local state -
      ;; `face-remapping-alist`, which `text-scale-mode` and its kin
      ;; adjust - and `face-at-buffer-position` asks the *current* buffer
      ;; for the face at a position. Without it the face was looked up in
      ;; whichever buffer happened to be current, and a position past that
      ;; buffer's end raised "Args out of range" - which is what `C-x C-f`
      ;; did, because the minibuffer's buffer is current while a prompt is
      ;; up and the window is showing the file.
      (with-current-buffer (window-buffer window)
      (let* ((ed (window-buffer window))
             (width (window-body-width window))
             ;; The window's left edge, in frame cells: a row is drawn at
             ;; the window's own column, not the frame's - a window to the
             ;; right of a split starts at X0. Passing 0 drew every
             ;; window's text in the leftmost column.
             (x0 (window-body-left window))
             (vheight (window-body-height window))
             ;; **The text area's bottom in *pixels***, GNU Emacs's
             ;; `window_text_bottom_y` - the `it.last_visible_y` that
             ;; `try_window` compares each row against. The window's
             ;; `height` is a row count because the frame's grid is rows,
             ;; but a row is as tall as the faces on it, and
             ;; `text-scale-mode` makes one line two or three lines tall.
             ;; Laying out `vheight` of those regardless ran the rows past
             ;; the window's own bottom: over its mode line, and over the
             ;; window beneath - measured with `C-x C-+` on a split frame,
             ;; rows of two sizes and two mode lines drawn on top of each
             ;; other, which is what Chris saw as "a real mess".
             ;; **A minibuffer window has no mode line, so its text
             ;; area is the whole of it.** `window_text_bottom_y` is
             ;; `window_box_height`, which is the window's pixel height
             ;; less the mode line (`xdisp.c`), and `MINI_WINDOW_P`
             ;; windows have none. Counting a row for it made a
             ;; one-row window's limit its own top - measured, the echo
             ;; area built no row at all (`glyphs: #()`, `enabled: #f`)
             ;; and the message never reached the screen. It went
             ;; unnoticed while the echo row was painted by hand.
             (y-limit (row->pixel-y (+ (window-top window)
                                       (window-height window)
                                       (if (window-minibuffer-p window)
                                           0 -1))))
             (desired (window-desired-matrix window)))
        ;; "If the window start is outside the accessible range, reset
        ;; it" - `redisplay_window`'s local `startp` clamp
        ;; (`xdisp.c:20781`: "if (CHARPOS (startp) < BEGV) SET_TEXT_POS
        ;; (startp, BEGV, BEGV_BYTE); else if (CHARPOS (startp) > ZV)
        ;; ..."). A narrowing moves `BEGV` without moving the window's
        ;; start *marker*, and every walk below begins there: unclamped,
        ;; `C-x n n` cleared the whole screen, because the row walk began
        ;; before the accessible portion and produced no rows at all.
        (let ((start (window-start window)))
          (unless (and (>= start (point-min)) (<= start (point-max)))
            (%window-start-set! window
                                (max (point-min) (min start (point-max))))))
        (let loop ((row 0)
                   (y (row->pixel-y (window-body-top window)))
                   (line-start (window-start window)))
          (if (or (>= row vheight) (>= y y-limit) (not desired))
              #t
              (let* ((texts (line-display-texts ed line-start))
                     (slices (%window-line-slices window texts)))
                (if (null? slices)
                    ;; past the buffer's end: the remaining rows are blank
                    ;; rows, **built and enabled** rather than left out -
                    ;; `display_line` is called for them for as long as
                    ;; the window has room (`try_window`'s `while
                    ;; (it.current_y < it.last_visible_y)`) and
                    ;; `prepare_desired_row` enables each one. Built
                    ;; rows compare equal on the next redisplay and are
                    ;; skipped; unbuilt ones are cleared again every time.
                    (let ((metrics (row-metrics ed line-start 0)))
                      (let blank ((r row) (yy y))
                        (if (< r vheight)
                            (let ((slot (glyph-matrix-row-ref desired r)))
                              (when slot
                                (build-blank-row! slot ed x0 yy width metrics))
                              (blank (+ r 1) (+ yy (cdr metrics))))
                            #t)))
                    (let* ((drawn (min (length slices) (- vheight row)))
                           (next-row
                            (let rloop ((rest slices) (k 0) (yy y) (r row))
                              (if (or (>= k drawn) (null? rest))
                                  (cons r yy)
                                  (let* ((slice (car rest))
                                         (metrics (row-metrics
                                                   ed (+ line-start (car slice))
                                                   (- (cdr slice) (car slice))))
                                         (slot (and desired
                                                    (glyph-matrix-row-ref desired r))))
                                    ;; **A row that would not fit in the
                                    ;; window's text area is not laid out
                                    ;; at all.** Emacs lays it out and
                                    ;; clips it at `it.last_visible_y`;
                                    ;; this renderer has no per-window
                                    ;; clip, so a half row here paints
                                    ;; over the mode line.
                                    (if (> (+ yy (cdr metrics)) y-limit)
                                        (cons r yy)
                                        (begin
                                    (when slot
                                      ;; **A row of an hscrolled line gives
                                      ;; its first cell to the left
                                      ;; truncation glyph.** The slice
                                      ;; `%window-line-slices` returns is
                                      ;; already shifted, but Emacs does not
                                      ;; *push* the text right for the
                                      ;; marker: `$` overwrites the cell at
                                      ;; the hscroll column and the text runs
                                      ;; from the second cell across WIDTH-1.
                                      ;; The row is drawn from X0+1 across
                                      ;; one cell fewer; `draw-glyph-row!`
                                      ;; puts the `$` before it.
                                      (let* ((hscrolled?
                                              (and (not (window-wraps? window))
                                                   (> (%window-hscroll window) 0)))
                                             (row-x (if hscrolled? (+ x0 1) x0))
                                             (row-width (if hscrolled? (- width 1) width)))
                                        (build-row! ed slot texts (car slice) (cdr slice)
                                                    row-x yy row-width line-start
                                                    (pair? (cdr rest))
                                                    ;; Cut off at the right
                                                    ;; edge - `row->
                                                    ;; truncated_on_right_p`,
                                                    ;; which `display_line`
                                                    ;; sets only when
                                                    ;; `it->line_wrap` is
                                                    ;; TRUNCATE. A *wrapped*
                                                    ;; line whose last row is
                                                    ;; short is not truncated,
                                                    ;; and marking it so put a
                                                    ;; `$' after the wrapped
                                                    ;; tail that Emacs never
                                                    ;; draws.
                                                    ;;
                                                    ;; On an hscrolled line the
                                                    ;; edge moves: it is
                                                    ;; `hscroll + width - 1`,
                                                    ;; the cell the left
                                                    ;; marker took.
                                                    (and (not (window-wraps? window))
                                                         (null? (cdr rest))
                                                         (> (line-texts-width texts)
                                                            (if hscrolled?
                                                                (+ (%window-hscroll window)
                                                                   width -1)
                                                                width)))
                                                    0 metrics)))
                                    (rloop (cdr rest) (+ k 1)
                                           (+ yy (cdr metrics)) (+ r 1)))))))))
                      ;; **`w->window_end_pos` is recorded here, as the
                      ;; rows are built.** The C writes it in
                      ;; `display_line` as it walks (`xdisp.c`), and
                      ;; `window-end` reads it back as `Z - pos` - "the
                      ;; end of the last *row* that fits", which is what a
                      ;; caller bounding a search or a scroll means. It
                      ;; used to be written by `render-window-rows!`, which
                      ;; the glyph-matrix path replaced; nothing wrote it
                      ;; after that, so `window-end` fell back to its own
                      ;; walk and `mouse-scroll-subr` - which measures from
                      ;; `(window-end)` - left point above the last visible
                      ;; row.
                      (let* ((last-row (car next-row))
                             (rows-drawn (- (car next-row) row))
                             (next (line-next-start ed line-start))
                             (end (cond ((< rows-drawn (length slices))
                                         ;; this line was cut off by the
                                         ;; bottom: the last row that fits
                                         ;; ends it
                                         (+ line-start
                                            (cdr (list-ref slices
                                                           (- rows-drawn 1)))))
                                        (next next)
                                        (else (text-editor-get-end-of-line
                                               ed line-start)))))
                        (set!%window-end-pos window (- (buffer-z ed) end))
                        (set!%window-end-vpos window (- last-row 1))
                        (set!%window-end-valid? window #t))
                      (let ((next (line-next-start ed line-start)))
                        (if next
                            (loop (car next-row) (cdr next-row) next)
                            ;; **Past the buffer's end the rows below the
                            ;; last line are built too**, which is
                            ;; `try_window`'s loop - `while (it.current_y
                            ;; < it.last_visible_y)` calls `display_line`
                            ;; for as long as the window has room, and
                            ;; `prepare_desired_row` enables each row it
                            ;; starts. A built blank row compares equal to
                            ;; the last one drawn and is skipped from then
                            ;; on; a row left unbuilt is one the diff
                            ;; cannot match, so it was cleared - as a
                            ;; whole row of spaces, on a terminal - on
                            ;; every redisplay.
                            (let ((metrics (row-metrics ed line-start 0)))
                              (let blank ((r (car next-row))
                                          (yy (cdr next-row)))
                                (if (and (< r vheight)
                                         (<= (+ yy (cdr metrics)) y-limit))
                                    (let ((slot (glyph-matrix-row-ref
                                                 desired r)))
                                      (when slot
                                        (build-blank-row! slot ed x0 yy
                                                          width metrics))
                                      (blank (+ r 1)
                                             (+ yy (cdr metrics))))
                                    #t))))))))))))))

    (define (update-window! window)
      ;; GNU Emacs's `update_window` (`dispnew.c:4400`): draw the rows the
      ;; desired matrix has that the current one does not.
      ;;
      ;; **Rows that match are not drawn at all**, which is the whole
      ;; point: `row_equal?` compares the hash first, so an unchanged row
      ;; costs one integer comparison.
      ;;--------------------------------------------------------------
      (let ((current (window-current-matrix window))
            (desired (window-desired-matrix window)))
        (when (and current desired)
          (update-window-begin! (current-display))
          (for-each (lambda (i)
                      (let ((d (glyph-matrix-row-ref desired i)))
                        (cond ((and d (glyph-row-enabled? d))
                               (draw-glyph-row! window d))
                              ;; **A row with nothing to show is blanked,
                              ;; not left as it was.** GNU Emacs's
                              ;; `update_window` clears a row whose
                              ;; desired row is not enabled; without that,
                              ;; a window that scrolled past the end of
                              ;; its buffer kept the rows that used to be
                              ;; there - the "corrupted screen" that
                              ;; showed up the moment the frame stopped
                              ;; being repainted whole.
                              (else (blank-glyph-row! window i d)))))
                    (matrix-diff-rows current desired))
          (matrix-mark-current! current desired)
          (update-window-end! (current-display)))))

    (define (blank-glyph-row! window index desired-row)
      ;; Blank one row of WINDOW: the cells are written as spaces in the
      ;; default face - `update_window`'s "this row is not enabled" case,
      ;; which is `clear_end_of_line` across the row's whole width
      ;; (`dispnew.c`).
      ;;--------------------------------------------------------------
      ;; **The row index, not the row's `y`.** A row that was never built
      ;; - every row past the end of the buffer - still carries the y its
      ;; record was made with (0), so blanking from the record wiped the
      ;; window's first line once for every empty row.
      (let ((y (row->pixel-y (+ (window-body-top window) index))))
        (fill-line-end-row! (current-display) window index y
                            (window-body-left window)
                            (window-body-width window)
                            (face->attribute 'default))))

    (define (draw-glyph-row! window row)
      ;; Draw a built row: one `write-glyphs!` per run of glyphs that share
      ;; a face - the C's `fill_glyph_string` run rule, which is exactly
      ;; "same face_id".
      ;;
      ;; The glyphs of a `<glyph-row>` are one per buffer column and each
      ;; carries its own face token, so the runs are found here rather
      ;; than in the face machinery - which is the point: no property
      ;; lookup, no face merge, no realization on the draw path.
      ;;
      ;; Three things GNU Emacs's `update_window` does with a row that
      ;; this has to do too, and each was a visible bug when it did not:
      ;;
      ;;  * **a run is drawn at its own column**, so a row does not paint
      ;;    each run over the last one;
      ;;  * **the cells past the end of the text are blanked**, because a
      ;;    terminal's `addstr` writes only what it is handed - "the new
      ;;    row is shorter than the old one" (`dispnew.c:4960`). Without
      ;;    it a shorter row kept the previous one's tail, which is how
      ;;    visiting a second file left the first one's lines on screen;
      ;;  * **`$` or `\` goes in the last cell** when the row is cut off
      ;;    or continues, in the default face (`produce_special_glyphs`).
      ;;--------------------------------------------------------------
      (let* ((glyphs (glyph-row-glyphs row))
             (n (glyph-row-used row))
             (y (glyph-row-y row))
             (x0 (glyph-row-x row))
             (width (window-body-width window))
             (marker? (or (glyph-row-continued? row)
                          (glyph-row-truncated-on-right? row)))
             ;; the last cell belongs to a marker when the row has one
             (limit (+ x0 width (if marker? -1 0))))
        ;; **The row is handed over whole, and the backend splits it into
        ;; runs** - `write_glyphs`' argument list, `(w, row, string, area,
        ;; len)`. The split moved out of here when the interface was
        ;; re-shaped: Emacs has it below the boundary (`fill_glyph_string`
        ;; for a window system, `tty_write_glyphs_1`'s own loop for a
        ;; terminal), and a redisplay that split for both back ends had an
        ;; opinion it should not have had.
        (when (> n 0)
          (write-glyphs! (current-display) window row 'text x0 glyphs n))
        ;; the cells past the text, blanked in the default face
        (let ((end (+ x0 (let sum ((i 0) (n2 0))
                            (if (>= i n) n2
                                (sum (+ i 1)
                                     (+ n2 (glyph-pixel-width
                                            (vector-ref glyphs i)))))))))
          (if (< end limit)
              (clear-end-of-line-row! (current-display) window 0 y end
                                      (- limit end)
                                      (face->attribute 'default))
              ;; **`write_row`: "Don't call clear_end_of_line if we
              ;; already wrote the whole line. The cursor will not be at
              ;; the right margin in that case but in the line below"-
              ;; and then `cursor_to (f, vpos, 0)`, "to make sure we are
              ;; in the right row, otherwise cursor movement with cmgoto
              ;; might use `ch' in the wrong row".
              ;;
              ;; It is not cosmetic. Writing the last column arms the
              ;; terminal's wrap; `cmplus` books that as "moved to the
              ;; next row", so `cm` and the terminal would both be one
              ;; row below where the picture is, and every later
              ;; `cursor_to` would be off by one. Going back to the row
              ;; cancels it. Measured, without this a 23-row frame drew
              ;; 62.
              (cursor-to! (current-display) window y x0)))
        ;; the left truncation glyph, when the row was drawn one cell in
        ;; from the window's left edge - which is what `display-window!`
        ;; does for an hscrolled line. `$` overwrites the cell at the
        ;; hscroll column rather than pushing the text right, as
        ;; `draw-line!`'s hscrolled branch did.
        (when (> x0 (window-body-left window))
          ;; at the window's *first* cell, which is the cell the text
          ;; gave up - `draw-special-glyph!` writes the last cell, so
          ;; this is its own `write-glyphs!`
          (write-run! (current-display) (list "$") y
                      (window-body-left window)
                      (face->attribute 'default)))
        ;; the right marker sits in the window's last cell, so the row's
        ;; own width (one cell short when it made room for the left
        ;; marker) is not what places it - `window-left window` plus the
        ;; window's width is.
        (let ((window-width (window-body-width window))
              (window-x (window-body-left window)))
          (cond ((glyph-row-continued? row)
                 (draw-special-glyph! y window-x window-width "\\"))
                ((glyph-row-truncated-on-right? row)
                 (draw-special-glyph! y window-x window-width "$"))))))

    (define (clear-end-of-line-row! display window index y x width token)
      ;; Blank the cells [X, X+WIDTH) of the row at pixel Y - GNU Emacs's
      ;; `clear_end_of_line (w, row, area, x)`, whose backend takes the
      ;; row's y from `row` and the width from `window_box_width (w,
      ;; area)`. This tree's callers have the y and the width already, so
      ;; the row is synthesised the way `write-run!` synthesises one.
      ;;--------------------------------------------------------------
      (when (> width 0)
        (clear-end-of-line! display window
                            (make-glyph-row (vector) 0 x y width 0 1 x x)
                            'text x width token)))

    (define (fill-line-end-row! display window index y x width token)
      ;; Fill [X, X+WIDTH) of the row at pixel Y so that the *line* carries
      ;; TOKEN to its edge.
      ;;
      ;; GNU Emacs's `extend_face_to_end_of_line` (`xdisp.c:24379`) is
      ;; called while the row is built, so its padding is glyphs; the two
      ;; rows that are cleared at draw time rather than built - a row past
      ;; the end of the buffer and the echo area's - have to be filled the
      ;; same way, or they keep the terminal's own colours where the rest
      ;; of the line has the face's. On a window system `clear-end-of-line!`
      ;; paints the background, which is the same result; on a terminal it
      ;; emits `ce`, which erases under whatever colours are current - not
      ;; the face's - so the cells have to be written.
      ;;--------------------------------------------------------------
      (when (> width 0)
        (if (window-system-display? display)
            (clear-end-of-line-row! display window index y x width token)
            (write-run! display (list (make-string width #\space)) y x token))))

    (define (write-run! display glyphs y x token)
      ;; Draw GLYPHS - a list, one per cell - at pixel Y, cell column X,
      ;; in TOKEN's face. A *one-run* `write-glyphs!`: the adapter for the
      ;; places that draw a fragment the redisplay made rather than a row
      ;; it built (an overlay string, a special glyph, a mode-line
      ;; segment, the echo area).
      ;;
      ;; **It builds the row the interface asks for.** `write_glyphs`
      ;; takes `(w, row, string, area, len)`, and a backend reads the
      ;; position from the row and the face from each *glyph*
      ;; (`glyph->face_id`), so a fragment has to arrive that way: the
      ;; vector is made with TOKEN on every glyph, and the row is given
      ;; the y and x the caller had.
      ;;--------------------------------------------------------------
      ;; **One glyph per CELL.** The interface asks for `(w, row,
      ;; string, area, len)` where each glyph is one cell, and a caller
      ;; that passes a whole *run* as a single element - the mode line and
      ;; the echo area do, one string for a stretch of text - has to have
      ;; it split, or `write-glyphs!` advances the cursor by one column
      ;; for a thirty-character run and every later run in the row is
      ;; addressed from where that drift left it. Measured, the mode line
      ;; read `-UU-:--- *p32.txt  &  -- L1 C0`.
      (let* ((cells (let loop ((rest glyphs) (acc '()))
                      (cond ((null? rest) (reverse acc))
                            ((string? (car rest))
                             (if (= (string-length (car rest)) 1)
                                 (loop (cdr rest) (cons (car rest) acc))
                                 (loop (cdr rest)
                                       (append (reverse
                                                (map string
                                                     (string->list
                                                      (car rest))))
                                               acc))))
                            (else (loop (cdr rest) (cons (car rest) acc))))))
             (n (length cells))
             (vec (if (= n 0)
                      (vector)
                      (list->vector
                       (map (lambda (g) (make-glyph g token 1 'char #f 0))
                            cells)))))
        (when (> n 0)
          (write-glyphs! display #f
                         (make-glyph-row vec n x y (max 1 n) 0 1 x x)
                         'text x vec n))))

    (define (row->pixel-y row)
      ;; The pixel y of screen row ROW, counting from the frame's top, as
      ;; the sum of the heights of the rows above it.
      ;;
      ;; **This is only right for rows that have never been laid out** -
      ;; the mode line, the echo area, a window border, and a window that
      ;; has not been drawn yet. The text rows are drawn by the walk in
      ;; `render-line-rows!`, which has their real heights and gives each
      ;; its own y. Emacs has the same split: `it->current_y` for text,
      ;; and `row->y` recorded once a row has been laid out.
      ;;
      ;; **A row is a *cell*, and a cell is `FRAME_LINE_HEIGHT` pixels** -
      ;; not `line-height`, which answers in this redisplay's own unit (1
      ;; on a windowed display, where a row is 20 pixels of real font).
      ;; `write-glyphs!` takes a pixel y, so multiplying by the redisplay
      ;; unit put the mode line at row 22 *pixels* from the top instead of
      ;; 440 - near the top of the window, which is exactly what Chris
      ;; saw: "it shows the mode line at the top".
      ;;--------------------------------------------------------------
      (* row (cdr (display-cell-size (current-display)))))

    ;;----------------------------------------------------------------
    ;; The mode line's text properties
    ;;
    ;; GNU Emacs's `format-mode-line` answers a *propertized* string:
    ;; the buffer name carries `mode-line-buffer-id`, and a theme that
    ;; sets that face colours it. Scheme's `substring` and
    ;; `string-append` do not carry a string's properties the way
    ;; Emacs's do, so the truncation and padding that fit the line to
    ;; the window go through these two - without them the whole line
    ;; was plain by the time it reached the display, which is why the
    ;; buffer name was drawn like the rest of the mode line.
    ;;------------------------------------------------------------------

    (define (mode-line-substring str start end)
      ;; GNU Emacs's `substring` keeps text properties ("The value is a
      ;; copy of SUBSTRING's elements; its properties are copied") -
      ;; `text_property_list` and `add_text_properties_from_list` moved
      ;; with the C's own range, so the triples are absolute and the
      ;; copy's offset is START.
      ;;--------------------------------------------------------------
      (let ((copy (substring str start end)))
        (add-text-properties-from-list copy
                                       (text-property-list str start end #f)
                                       (- start))
        copy))

    (define (mode-line-truncate str width)
      ;; `truncate-line` at the mode line, keeping its text properties.
      ;;--------------------------------------------------------------
      (cond ((<= (string-length str) width) str)
            ((<= width 0) "")
            (else (mode-line-substring str 0 width))))

    (define (mode-line-pad str width)
      ;; `pad-line` at the mode line, keeping its text properties:
      ;; `concat` rather than `string-append` because only `concat` is
      ;; `fns.c`'s and copies the pieces' properties.
      ;;--------------------------------------------------------------
      (let ((len (string-length str)))
        (if (< width len)
            (mode-line-truncate str width)
            (concat str (make-string (- width len) #\space)))))

    (define (draw-mode-line! line base row-y x0 . rest)
      ;; DRAW LINE at X0 in BASE, one `write-glyphs!` per run of equal
      ;; `face` text property, merged onto BASE - GNU Emacs's
      ;; `display_mode_element` drawing each run with
      ;; `face_at_string_position` under the mode line's face id. A run
      ;; with no face is the mode line's own.
      ;;
      ;; A run whose face carries `:box` also gets `draw-box!` around it.
      ;; **The box's vertical edges are only where the boxed region
      ;; begins and ends**, which is Emacs's `start_of_box_run_p` and
      ;; `end_of_box_run_p`: `restore_face_box_flags` (`xdisp.c:7426`)
      ;; sets the start only when the *previous* face had no box, so a
      ;; run of adjacent boxed faces - a mode line's buffer name over the
      ;; mode-line face, say - is one box and not a row of them.
      ;;
      ;; **The fifth argument is the mouse-face run under the pointer**,
      ;; `(BEG END VALUE)`, when this line is the one being hovered:
      ;; those characters are drawn with VALUE merged over the face they
      ;; already have, which is `face_at_string_position` with MOUSE true
      ;; and the glyph's own face as the base (`xdisp.c:36955`). A run
      ;; of text is therefore split where the hover begins and ends, and
      ;; each piece is drawn as its own run.
      ;;--------------------------------------------------------------
      (let* ((mouse (and (pair? rest) (car rest)))
             (m-beg (and mouse (car mouse)))
             (m-end (and mouse (cadr mouse)))
             (m-value (and mouse (caddr mouse)))
             (len (string-length line))
             (runs
              (let loop ((i 0) (acc '()))
                (if (>= i len)
                    (reverse acc)
                    (let* ((face (get-text-property i 'face line))
                           (j (let find ((k (+ i 1)))
                                (if (or (>= k len)
                                        (not (eq? (get-text-property
                                                   k 'face line)
                                                  face)))
                                    k
                                    (find (+ k 1))))))
                      (loop j (cons (list i j face) acc))))))
             ;; The runs split at the hover's edges. A run that the hover
             ;; does not touch stays one piece, which is the ordinary
             ;; mode line with no pointer on it.
             (segments
              (let loop ((rest runs) (acc '()))
                (if (null? rest)
                    acc
                    (let* ((run (car rest))
                           (i (car run))
                           (j (cadr run))
                           (face (caddr run)))
                      (loop (cdr rest)
                            (append
                             acc
                             (if (and mouse (< (max i m-beg) (min j m-end)))
                                 (let ((mid-beg (max i m-beg))
                                       (mid-end (min j m-end)))
                                   (append
                                    (if (< i mid-beg)
                                        (list (list i mid-beg face #f))
                                        '())
                                    (list (list mid-beg mid-end face #t))
                                    (if (< mid-end j)
                                        (list (list mid-end j face #f))
                                        '())))
                                 (list (list i j face #f)))))))))
             ;; The token and the box of each piece, once: the same
             ;; work either side of a hover boundary, and the box of the
             ;; *next* piece is what closes the previous one.
             (prepared
              (map (lambda (seg)
                     (let* ((face (caddr seg))
                            (lit? (cadddr seg))
                            (attrs
                             (merge-face-vectors
                              (if lit?
                                  (merge-face-ref m-value (if face face '()))
                                  (if face (merge-face-ref face '()) '()))
                              (merge-face-ref base '())))
                            (box (let ((v (attribute-value attrs ':box)))
                                   (and (not (eq? v *undefined-face-attribute*))
                                        v)))
                            (token (if lit?
                                       (face->attribute
                                        (merge-face-ref m-value
                                                        (if face face '()))
                                        base)
                                       (if face
                                           (face->attribute face base)
                                           (face->attribute base base)))))
                       (list (car seg) (cadr seg) token box lit?)))
                   segments)))
        (let loop ((rest prepared) (prev-boxed? #f) (prev-lit? #f))
          (when (pair? rest)
            (let* ((piece (car rest))
                   (i (car piece))
                   (j (cadr piece))
                   (token (caddr piece))
                   (box (cadddr piece))
                   (lit? (list-ref piece 4))
                   (next (if (pair? (cdr rest)) (cadr rest) #f))
                   (next-boxed? (and next (cadddr next) #t))
                   (next-lit? (and next (list-ref next 4)))
                   ;; `pgtk_draw_glyph_string` (`pgtkterm.c:2048`): the
                   ;; box's vertical edges are where the boxed *run*
                   ;; begins and ends, **and a mouse-face run always gets
                   ;; them** - `(hl == DRAW_MOUSE_FACE && (prev == NULL
                   ;; || prev->hl != s->hl))`. The mode line's own face
                   ;; has a box too, so without the second rule a
                   ;; highlight inside the line's box lost its left and
                   ;; right edges and drew only the top and bottom ones.
                   (left? (or (and (not prev-boxed?) #t)
                              (and lit? (not prev-lit?))))
                   (right? (or (and (not next-boxed?) #t)
                               (and lit? (not next-lit?)))))
              (write-run! (current-display)
                          (list (mode-line-substring line i j))
                          row-y (+ x0 i)
                          token)
              (when box
                (draw-box! (current-display) box token (+ x0 i) row-y
                           (- j i)
                           (cdr (display-cell-size (current-display)))
                           left? right?))
              (loop (cdr rest) (and box #t) (and lit? #t)))))
        ;; **`write_row`'s last three lines, which apply to any row.** A
        ;; mode line that fills the window arms the terminal's wrap;
        ;; `cmplus` books that as "moved to the next row", so `cm` ends
        ;; one row below the picture and every later `cursor_to` is off
        ;; by one. GNU Emacs ends `write_row` with `cursor_to (f, vpos,
        ;; 0)` for exactly this, and the mode line goes through
        ;; `write_row` there as well. Measured, without it a 23-row
        ;; frame drew 62.
        (cursor-to! (current-display) #f row-y x0)))

    (define (window-matrix-valid? window)
      ;; Whether the window's glyph matrices still describe what should be
      ;; on the screen, so that this redisplay can leave them alone.
      ;;
      ;; GNU Emacs's version of this question is two: `window_outdated`
      ;; (`window.c:231`) for the buffer, and `current_matrix_up_to_date_p`
      ;; (`xdisp.c:20576`) for everything else - the window's size, its
      ;; start, the horizontal scroll, and whether a redisplay has been
      ;; forced. When both say yes, `redisplay_window` runs
      ;; `try_cursor_movement` or `try_window_reusing_current_matrix` and
      ;; builds nothing: a `C-n` in the middle of a window costs a cursor
      ;; repaint.
      ;;--------------------------------------------------------------
      (and (not (windows-or-buffers-changed?))
           (not (frame-garbaged-p (window-frame window)))
           (not (window-outdated? window))
           ;; `w->start`: the same position the rows were built from. The
           ;; marker follows edits, so this only means anything together
           ;; with the ticks above - and `set-window-start!` can move it
           ;; with no buffer change at all (`recenter`).
           (let ((start (%window-start window)))
             (and start
                  (= (marker-position start) (window-last-start window))))
           (= (window-body-width window) (window-last-width window))
           (= (window-body-height window) (window-last-height window))
           (= (%window-hscroll window) (window-last-hscroll window))
           ;; **The region is drawn from the buffer's point and mark**,
           ;; so while one is active the rows depend on both and the
           ;; matrix is only good for the pair it was built with. GNU
           ;; Emacs gets the same invalidation from a different place:
           ;; `redisplay--update-region-highlight` (`simple.el:7332')
           ;; keeps the region in an *overlay* and moves it on every
           ;; redisplay, and moving an overlay raises `OVERLAY_MODIFF`
           ;; (`modify_overlay`), which `window_outdated` reads. This
           ;; tree's renderer computes the region's face from the mark
           ;; itself, so the pair has to be recorded where the rest of
           ;; the matrix's provenance is. Only while the region is
           ;; active: a window with no region is unaffected by point
           ;; moving, which is what makes `C-n` rebuild nothing.
           (let ((ed (window-buffer window)))
             (or (not (region-face-active? ed))
                 (and (= (window-point window)
                         (window-last-point window))
                      (= (marker-position (%mark-marker ed))
                         (window-last-mark window)))))))

    (define (mark-window-display-accurate-1 window accurate-p)
      ;; GNU Emacs's `mark_window_display_accurate_1` (`xdisp.c:18304`):
      ;; "Mark the display of leaf window W as accurate or inaccurate. If
      ;; ACCURATE_P, mark display of W as accurate. If !ACCURATE_P,
      ;; arrange for W to be redisplayed the next time
      ;; `redisplay_internal` is called."
      ;;
      ;; **The inaccurate direction is not optional once the redisplay
      ;; skips windows.** `redraw_frame` (`dispnew.c:3212`) clears the
      ;; surface and then ends with `mark_window_display_accurate
      ;; (FRAME_ROOT_WINDOW (f), 0)`, because a matrix that was built
      ;; against a screen which has since been wiped is not a matrix the
      ;; screen holds - and the C says so by zeroing the two ticks. A
      ;; renderer that wipes the screen and skips the windows whose ticks
      ;; still match paints nothing at all: measured, the file was on
      ;; screen, a second redisplay cleared it, and the buffer stayed
      ;; blank until a resize changed the window's size and forced a
      ;; rebuild.
      ;;
      ;; `w->last_had_star`, `last_point` and the `clip_changed`/
      ;; `prevent_redisplay_optimizations_p` resets are not carried -
      ;; nothing here reads them; the tree's fields are the ones
      ;; `window-matrix-valid?` asks about, and they are recorded here so
      ;; that there is one place that says what a matrix was built from.
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (set!window-last-modified
         window (if (and accurate-p buffer)
                    (buffer-modified-tick buffer)
                    ;; "W->last_modified = accurate_p ? BUF_MODIFF (b) : 0"
                    ;; - and a fresh buffer's tick is 1, so 0 is behind it.
                    0))
        (set!window-last-overlay-modified
         window (if (and accurate-p buffer)
                    (buffer-overlay-modified-tick buffer)
                    0))
        ;; The mode line row goes the same way: a frame whose surface was
        ;; just wiped has no row of ours on the screen, whatever was drawn
        ;; on it before.
        (unless accurate-p
          (set!window-last-mode-line window #f))
        ;; ...and so does the tab line's. **A cache is only good while the
        ;; screen still holds what it records**, and a window that has been
        ;; switched to another buffer - so that `window-wants-tab-line` is
        ;; false for a while and nothing redraws the row - comes back with
        ;; its old record intact. Without this the tab line row stayed
        ;; blank after `C-x <right>' `C-x <left>' when the formatted line
        ;; happened to be the same string it had been, which is the common
        ;; case for a window cycling between two buffers.
        (unless accurate-p
          (set!window-last-tab-line window #f))
        (when accurate-p
          (let ((start (%window-start window)))
            (set!window-last-buffer window buffer)
            (set!window-last-start window (and start (marker-position start)))
            (set!window-last-width window (window-body-width window))
            (set!window-last-height window (window-body-height window))
            (set!window-last-hscroll window (%window-hscroll window))
            ;; `w->last_point` - "if (w == XWINDOW (selected_window))
            ;; w->last_point = BUF_PT (b); else w->last_point =
            ;; marker_position (w->pointm)" (`xdisp.c:18352').
            (set!window-last-point window (window-point window))
            ;; and `w->last_mark`, -1 when the mark is not active
            ;; (`:18359').
            (set!window-last-mark
             window (if (region-face-active? buffer)
                        (marker-position (%mark-marker buffer))
                        -1))))))

    (define (mark-window-display-accurate windows accurate-p)
      ;; GNU Emacs's `mark_window_display_accurate` (`xdisp.c:18407`),
      ;; which walks the window tree rooted at its argument.
      ;;
      ;; **Departure**: Emacs hands it the root window and follows
      ;; `w->contents`/`w->next`; this tree's frame keeps a list of top
      ;; windows (`frame-windows`), so the walk takes that list and
      ;; recurses into `window-children`. Same leaves, same order.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (window)
         (if (window-internal? window)
             (mark-window-display-accurate (window-children window)
                                           accurate-p)
             (mark-window-display-accurate-1 window accurate-p)))
       windows))

    (define (render-window-mode-line! window)
      ;; Draw WINDOW's mode line and its vertical border - the part of a
      ;; window that is not glyph rows.
      ;;
      ;; **`update_window`'s diff, for the row the mode line occupies.**
      ;; GNU Emacs builds the mode line into the window's desired glyph
      ;; matrix (`display_mode_line`) and then compares that row with the
      ;; current matrix like any other, so an unchanged mode line costs
      ;; nothing. This tree draws it directly, outside the matrices, so
      ;; the same comparison is made here against what was last written:
      ;; the padded string, the face (which flips when the window is
      ;; selected), and **the row and column it went to** - a row compared
      ;; by content alone would be skipped at a position nothing had ever
      ;; been written to, which is what a split window that moved its mode
      ;; line up needs.
      ;;
      ;; Two things invalidate it beyond the content: a theme or face
      ;; change (`windows-or-buffers-changed?`, set by
      ;; `set-face-attribute`), and a surface that is about to be wiped
      ;; (`frame-garbaged-p`, and `mark-window-display-accurate-1` clears
      ;; the field when it wipes one).
      ;;--------------------------------------------------------------
      ;; **The mode line runs the window's whole width, the scroll bar
      ;; area included.** `display_mode_line` builds the row with
      ;; `full_width_p` set, so its face covers the fringes and the scroll
      ;; bar area and a toolkit bar does not interrupt it - and
      ;; `coordinates_in_window` tests `ON_MODE_LINE` before the scroll
      ;; bar columns (`window.c:1396-1418`), so a click there is a
      ;; mode-line click. Drawing it only across the body left the bar
      ;; columns as a gap at the right edge, with the bar of the window
      ;; below meeting this window's bar through it.
      (let* ((x0 (window-left window))
             (width (window-width window))
             ;; **The border is the window's last column.** It is *not*
             ;; `x0 + width`: that span is the mode line's, which now
             ;; covers the scroll bar area too, while the separator
             ;; column is the last cell of the window (the one
             ;; `window-body-width` leaves out of the body).
             (border (and (window-right-border? window)
                          (+ (window-left window) (window-width window) -1)))
             (y (row->pixel-y
                 (+ (window-top window) (window-height window) -1)))
             (line (mode-line-pad
                    (mode-line-truncate
                     ;; `display_mode_lines` (`xdisp.c:29099`) rebinds
                     ;; `selected_window` to WINDOW for the format and
                     ;; keeps the real one in `old_selected_window`.
                     (parameterize ((*old-selected-window* (selected-window))
                                    (*selected-window-override* window))
                       (mode-line-string window))
                     width)
                    width))
             (face (if (eq? window (selected-window))
                       'mode-line-active
                       'mode-line-inactive))
             ;; **The hover run, if the pointer is on this line.** The
             ;; string the pointer found must be this line - a redisplay
             ;; formats a fresh string every time, so the test is by
             ;; content and properties, as the record's is - and then
             ;; `(BEG END VALUE)` is painted over it.
             (mouse-run
              (and (eq? window %mouse-face-window)
                   %mouse-face-string
                   (equal-including-properties line %mouse-face-string)
                   (list %mouse-face-beg %mouse-face-end %mouse-face-attrs)))
             ;; **The run is part of the record**: a mode line whose text
             ;; did not change still has to be redrawn when the pointer
             ;; moves onto or off its items.
             (record (list line face y x0 mouse-run)))
        (unless (and (not (windows-or-buffers-changed?))
                     (not (frame-garbaged-p (window-frame window)))
                     ;; **Properties count**, which `equal?` does not see:
                     ;; the same characters with another face is another
                     ;; row.
                     (equal-including-properties (window-last-mode-line window)
                                                 record))
          (draw-mode-line! line face y x0 mouse-run)
          (set!window-last-mode-line window record))
        ;; **The separator between side-by-side windows.** GNU Emacs
        ;; draws it one of two ways, and this is the branch:
        ;;
        ;; * a window-system frame **with vertical scroll bars draws
        ;;   nothing** - `gui_draw_vertical_border` (`xdisp.c:37926`):
        ;;   "Don't do it for frames with vertical scroll bars because
        ;;   either the right scroll bar of a window, or the left scroll
        ;;   bar of its neighbor will suffice as a border." The bars are
        ;;   the separator; a column of `|' glyphs beside them is this
        ;;   renderer's invention and not Emacs's.
        ;; * a window-system frame **without** them draws a one-pixel
        ;;   line in the `vertical-border` face, from the top of the text
        ;;   area to its bottom - the C's `window_box_edges` + `y1 -= 1`
        ;;   - so it stops above the mode line (`xdisp.c:37946`).
        ;; * a terminal draws the `|' glyph in the window's last cell on
        ;;   every row of the window, mode line included, which is not
        ;;   this hook at all: `build_frame_matrix_from_leaf_window`
        ;;   replaces each row's last glyph with `right_border_glyph`
        ;;   (`dispnew.c:2574-2599`).
        ;;
        ;; Both of the C's branches are drawn - the right border of a
        ;; non-rightmost window and the left border of a non-leftmost one
        ;; land on the same column in this model, where the column
        ;; belongs to the window on the left (`window-right-border?`), so
        ;; one call draws what the two would.
        (when border
          (cond
           ((window-system-display? (current-display))
            (unless (frame-has-vertical-scroll-bars? (window-frame window))
              (let ((cw (frame-char-width (window-frame window)))
                    (ch (frame-char-height (window-frame window))))
                (display-draw-vertical-border
                 (current-display) window
                 (* border cw)
                 (* (window-body-top window) ch)
                 (- (* (+ (window-body-top window)
                          (window-body-height window))
                       ch)
                    1)))))
           (else
            (let loop ((row (window-top window))
                       (end (+ (window-top window) (window-height window))))
              (when (< row end)
                (write-run! (current-display) (list "|") (row->pixel-y row)
                            border (face->attribute 'vertical-border))
                (loop (+ 1 row) end))))))))

    (define (render-window-tab-line! window)
      ;; Draw WINDOW's tab line: the row above its text.
      ;;
      ;; GNU Emacs's `display_mode_line` with `TAB_LINE_ACTIVE_FACE_ID`
      ;; (`xdisp.c:28220`), reached from `display_mode_lines` for a
      ;; window `window_wants_tab_line` says wants one. The format is the
      ;; window parameter `tab-line-format' when the window names one,
      ;; and the *buffer's* `tab-line-format' otherwise
      ;; (`xdisp.c:28182`) - which is the variable `tab-line-mode` sets.
      ;;
      ;; **The string is `format-mode-line`'s**, the same evaluator the
      ;; mode line uses: `tab-line-format`'s default value is
      ;; `(:eval (tab-line-format))`, whose procedure returns one
      ;; propertized string with a face run per tab. `draw-mode-line!`
      ;; already draws runs of `face` properties, `:box` included, so a
      ;; tab's box and its face come from the string itself.
      ;;
      ;; The base face is `tab-line-active`/`tab-line-inactive` by
      ;; window selection, as the mode line's is (`faces.el:3039`: both
      ;; inherit `tab-line`, which is what gives the row its background).
      ;;--------------------------------------------------------------
      (when (window-wants-tab-line window)
      ;; The tab line spans the window's whole width for the mode line's
      ;; reason: the scroll bar starts below it, so this row has no bar
      ;; columns to leave out.
      (let* ((x0 (window-left window))
             (width (window-width window))
             (y (row->pixel-y (window-top window)))
             (format (or (window-parameter window 'tab-line-format)
                         (buffer-local-value (window-buffer window)
                                             'tab-line-format #f)))
             (line (mode-line-pad
                    (mode-line-truncate
                     (parameterize ((*old-selected-window* (selected-window))
                                    (*selected-window-override* window)
                                    (*mode-line-window* window))
                       (format-mode-line format window))
                     width)
                    width))
             (face (if (eq? window (selected-window))
                       'tab-line-active
                       'tab-line-inactive))
             (record (list line face y x0)))
        (unless (and (not (windows-or-buffers-changed?))
                     (not (frame-garbaged-p (window-frame window)))
                     ;; the mode line's rule, and the reason it matters
                     ;; more here: a tab line's characters stay the same
                     ;; while its faces follow the current tab.
                     (equal-including-properties (window-last-tab-line window)
                                                 record))
          (draw-mode-line! line face y x0)
          (set!window-last-tab-line window record)))))

    (define (force-mode-line-update . args)
      ;; GNU Emacs's `force-mode-line-update` (`buffer.c:1543`): mark the
      ;; mode line, or every mode line with ALL, for redrawing. "This
      ;; function also forces recomputation of the menu bar menus and the
      ;; frame title."
      ;;
      ;; **It sets `update_mode_lines` ONLY** - the C's body is
      ;; `update_mode_lines = 10` for ALL and `bset_update_mode_line` for
      ;; the current buffer's windows, and it never touches
      ;; `windows_or_buffers_changed`. It set both here until
      ;; 2026-11-20, and that is a *stronger* flag than the C: it makes
      ;; the redisplay treat the frame as garbaged (clear the surface,
      ;; throw the matrices away), where the C merely recomputes the mode
      ;; lines and the bars. The difference is observable: a search calls
      ;; this on every key (`isearch-update`), and with the strong flag
      ;; every key garbage-collected the frame - which lost the search's
      ;; own match highlight, caught by `tools/pty-check.py`'s
      ;; `isearch-multiline`.
      ;;
      ;; The two flags are distinct here for the same reason they are in
      ;; the C: `update-mode-lines?` means "the mode lines and the bars
      ;; have to be re-made", `windows-or-buffers-changed?` means "no
      ;; glyph matrix can be trusted". A caller that changes what the
      ;; mode line or the bar *says* wants the first.
      ;;--------------------------------------------------------------
      (set-update-mode-lines! #t)
      #f)

    (define *inhibit-redisplay* (make-parameter #f))
    ;; ^ GNU Emacs's `Vinhibit_redisplay` (`xdisp.c`, DEFVAR_BOOL "A
    ;; non-nil value means ignore redisplay requests"): "This is set
    ;; while a menu is active, to avoid messing the screen if some timer
    ;; calls `sit-for` or a similar function." The tty menu binds it for
    ;; as long as it is up; `render!` itself does not consult it, which
    ;; is the C's split - `update_frame_with_menu` is how a menu repaints
    ;; the frame underneath it.

    (define (redisplay-frames!)
      ;; Draw every frame. **GNU Emacs's redisplay is a loop over all of
      ;; them** - `FOR_EACH_FRAME (tail, frame)' (`xdisp.c:14350',
      ;; `:14291') - and that is why a second window keeps up when you
      ;; type in the first. This tree drew only the frame the command loop
      ;; was handed, so a frame that was *not* selected was drawn by
      ;; nobody at all: `make-frame' does not select the new frame (Emacs
      ;; is explicit about that, `frame.el:1055'), so `C-x 5 2' made a
      ;; window and then painted nothing into it.
      ;;
      ;; **One frame per display.** A terminal shows one frame at a time -
      ;; Emacs's `tty->top_frame' - so frames that share a display are
      ;; drawn only where the selected frame's display is, or each would
      ;; be painted over the last on a terminal holding several. A GUI
      ;; frame has its own display here, so all of them are drawn.
      ;;--------------------------------------------------------------
      (if (*inhibit-redisplay*)
          #f
          ;; `reset_outermost_restrictions` (`xdisp.c:17440'): "called
          ;; when redisplay starts, so that if a Lisp function executed
          ;; during redisplay calls (redisplay) while labeled
          ;; restrictions are in effect, these restrictions will not
          ;; become visible on display." `editfns.scm` carries the
          ;; pair; the wind is the C's specpdl unwind.
          (%with-outermost-restrictions
           (lambda ()
            (begin
            ;; **`run_window_change_functions`** (`xdisp.c:17588`): "Run
            ;; window change functions for each live frame. This function
            ;; must be called from a 'safe' position in
            ;; `redisplay_internal`." Emacs runs it after the echo-area
            ;; work and *before* any frame is drawn, and only when a
            ;; redisplay happens at all - `redisplay_internal` returns
            ;; early under `inhibit-redisplay` (`xdisp.c:17402`), which
            ;; is this branch's test.
            ;;
            ;; It is `window.c`'s function and lives in `window.scm`.
            ;; That library imports this one through `simple`, so the
            ;; import here is a diamond and not a cycle.
            (run-window-change-functions)
            (let ((selected (*current-frame*)))
              (let loop ((frames (*frame-list*)))
                (cond ((null? frames) #f)
                      (else
                       (let ((f (car frames)))
                         (when (or (eq? f selected)
                                   (not (eq? (frame-output f)
                                             (and selected
                                                  (frame-output selected)))))
                           (render! f)))
                       (loop (cdr frames))))))
            ;; **The flag is cleared once every frame has been drawn**,
            ;; which is where `redisplay_internal` clears it (`xdisp.c`):
            ;; it means "something changed since the last redisplay", and
            ;; after this one nothing has.
            (set-windows-or-buffers-changed! #f)
            ;; "update_mode_lines = 0; windows_or_buffers_changed = 0"
            ;; (`xdisp.c:18166`), the two of them together.
            (set-update-mode-lines! #f)
            ;; **And now nothing is being drawn**, so a front end may act
            ;; on what arrived while it was. A Gtk frame queues an input
            ;; event that comes in while a picture is being painted (the
            ;; cursor-blink timer repaints straight from a Gtk source),
            ;; and there is no read of its own to collect it; this is the
            ;; moment that is over. Emacs has no such hook - its command
            ;; loop reads the keyboard again the moment redisplay
            ;; returns - and the terminal front end has no queue to
            ;; drain, so the hook is #f there and costs one test.
            (when (*after-redisplay-hook*)
              ((*after-redisplay-hook*))))))))

    (define *after-redisplay-hook* (make-parameter #f))
    ;; ^ A thunk run after every redisplay has finished, for a front end
    ;; that owns the main loop and has queued input to dispatch. `#f` for
    ;; a front end whose read is the wait (the terminal's).

    (define *redisplay-in-progress* (make-parameter #f))
    ;; ^ GNU Emacs's `redisplaying_p` (`xdisp.c:`: "True means we are in
    ;; the middle of `redisplay_internal`"). It is what stops a redisplay
    ;; that a redisplay has asked for: `redisplay_internal` answers early
    ;; when it is already set. This tree needs it for the same reason and
    ;; one more - a front end that dispatches an event from a signal
    ;; handler must not do it here, or a window resize signal fired by the
    ;; drawing itself would run `ignore` and redisplay again, and again.

    (define *phys-cursor* (make-parameter #f))
    ;; ^ Where the cursor was last *painted*, and what was under it, as
    ;; `(DISPLAY ROW COLUMN CELLS TEXT TOKEN)' - GNU Emacs's
    ;; `w->phys_cursor` and `w->phys_cursor_on_p` (`window.h`). The
    ;; cursor is drawn over a row, so it has to be taken off again before
    ;; the next one is drawn; Emacs does that in `erase_phys_cursor`
    ;; (`xdisp.c:35146`) by redrawing the glyph underneath. A display
    ;; whose frame is repainted whole never showed the need; one that
    ;; draws only the rows that changed does - moving the cursor left a
    ;; trail of boxes behind it.

    (define (erase-phys-cursor!)
      ;; GNU Emacs's `erase_phys_cursor`: put the glyph that was under
      ;; the cursor back.
      ;;--------------------------------------------------------------
      (let ((saved (*phys-cursor*)))
        (when saved
          (*phys-cursor* #f)
          (apply erase-window-cursor! saved))))

    (define (note-phys-cursor! display row column cells text token)
      (*phys-cursor* (list display row column cells text token)))

    (define (clear-garbaged-frames! frame windows)
      ;; GNU Emacs's `clear_garbaged_frames` (`xdisp.c:13699`) for the one
      ;; frame being redisplayed. Its own note is the reason this is a
      ;; flag and not a clear:
      ;;
      ;;   This function is used where the old redisplay called
      ;;   redraw_garbaged_frames which in turn called redraw_frame which
      ;;   in turn called clear_frame.  The call to clear_frame was a
      ;;   source of flickering.  I believe a clear_frame is not
      ;;   necessary.  It should suffice in the new redisplay to
      ;;   invalidate all current matrices, and ensure a complete
      ;;   redisplay of all windows.
      ;;
      ;; **So the frame is never cleared, and this is what replaced the
      ;; `clear-frame-area!` that `render!` used to do unconditionally.**
      ;; Clearing the surface and then drawing only what the matrix diff
      ;; calls changed is not a redisplay - every row the diff skipped
      ;; stayed erased. That is what made paging to the end of a buffer
      ;; flicker between two screens, and it is why the scroll decision
      ;; (which reads `window-end`, computed from the row walk) and the
      ;; picture on the screen disagreed.
      ;;
      ;; A garbaged frame invalidates every current matrix, which is what
      ;; makes the diff select every row, and only then clears the
      ;; surface - once, before anything is drawn. A resize garbages the
      ;; frame too (`sync-frame-size!`), because the toolkit has already
      ;; thrown the old contents away.
      ;;--------------------------------------------------------------
      ;; **One rule for both front ends: a frame is repainted when it is
      ;; garbaged, and otherwise only the rows that changed.** The
      ;; terminal is no exception - `write-glyphs!` is handed a row, a
      ;; column and a run of glyphs and emits exactly that, with no scroll
      ;; region and no insert/delete character anywhere in the output
      ;; path - but it took four more rules before the diff could be
      ;; trusted, and they are all named in DEPARTURES.md: a raised
      ;; `OVERLAY_MODIFF`, a current row that was never on the screen
      ;; counting as blank, the region's point and mark, and `SET_FRAME_VISIBLE`'s
      ;; redisplay after a suspend. Measured on a 24x80 terminal over a
      ;; 59-line file, one `C-n` now writes ~250 bytes - the cursor's row
      ;; and the mode line - where the whole-screen repaint wrote the
      ;; frame.
      ;;
      ;; What a terminal *needs*, and what the C gives it in
      ;; `redraw_frame` (`dispnew.c:3212`), is the pair below: clear the
      ;; surface, and tell every window its matrix is no longer the
      ;; screen. **Skipping without the second half is what put a blank
      ;; screen on a fresh frame**: the first redisplay drew the file, a
      ;; second redisplay cleared the surface and skipped every window
      ;; whose ticks still matched, and the file only came back when a
      ;; resize changed a window's size and forced a rebuild.
      ;; **A buffer's restriction moving is a full repaint too.**
      ;; `narrow_to_region`/`Fwiden` set `clip_changed`
      ;; (`editfns.c:2989`), and `redisplay_internal` answers it by
      ;; invalidating every window's matrices and redisplaying the whole
      ;; frame - which is why the C can skip rows and still be right.
      ;; This tree sets `windows-or-buffers-changed` there
      ;; (`%clip-changed!`), and until this test the renderer trusted the
      ;; row diff and skipped the rows a narrowing kept: the screen was
      ;; left showing whatever the terminal had, which for `C-x n n` and
      ;; `C-x n d` was nothing at all after ncurses' own clear.
      (when (or (frame-garbaged-p frame)
                (windows-or-buffers-changed?))
        (when (not (graphical-frame?))
          (clear-frame-area! (current-display)))
        (for-each (lambda (w)
                    (ensure-window-matrices! w (window-body-width w)
                                            (window-body-height w))
                    (let ((m (window-current-matrix w)))
                      (when m (clear-glyph-matrix m))))
                  windows)
        ;; **And the windows are told their matrices are no longer the
        ;; screen.** `redraw_frame` (`dispnew.c:3212`) ends with
        ;; `mark_window_display_accurate (FRAME_ROOT_WINDOW (f), 0)` for
        ;; exactly this reason: the surface was just wiped, so no window's
        ;; recorded state describes what is on it any more. Without it the
        ;; redisplay skipped every window whose ticks still matched and
        ;; the screen stayed blank - the file was drawn, the second
        ;; redisplay cleared it, and nothing brought it back until a
        ;; resize changed the window's size (see the note on
        ;; `mark-window-display-accurate-1`).
        (mark-window-display-accurate windows #f)
        (set-frame-garbaged! frame #f)))

    (define (echo-area-text-rows window)
      ;; How many screen rows the text in WINDOW takes at the window's
      ;; width - what `resize_mini_window` measures in pixels
      ;; (`move_it_to (&it, ZV, ...)`, `xdisp.c:13360`) and what this
      ;; renderer measures in rows. An empty buffer is one row.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (if (not ed)
            1
            (with-current-buffer ed
              (let loop ((pos (point-min)) (rows 0))
                (if (>= pos (point-max))
                    (max 1 rows)
                    (let ((next (line-next-start ed pos)))
                      (loop (or next (point-max))
                            (+ rows (window-line-rows-at window pos))))))))))

    (define (resize-mini-window! window exact-p)
      ;; GNU Emacs's `resize_mini_window` (`xdisp.c:13310`): give the
      ;; minibuffer window the rows its text needs, within
      ;; `max-mini-window-height`, and take them from the window above.
      ;;
      ;; EXACT-P is the C's: `grow-only` shrinks the window back only when
      ;; EXACT-P or when the echo area is empty ("they return to their
      ;; normal size when the minibuffer is closed, or the echo area
      ;; becomes empty", `resize-mini-windows`).
      ;;--------------------------------------------------------------
      (and (window-minibuffer-p window)
           (let ((mode (*resize-mini-windows*)))
             (and mode
                  (let* ((frame (window-frame window))
                         (old (window-height window))
                         (frame-rows (frame-height frame))
                         (max-spec (*max-mini-window-height*))
                         (max-rows
                          (cond ((and (number? max-spec) (integer? max-spec))
                                 max-spec)
                                ((number? max-spec)
                                 (inexact->exact (floor (* max-spec frame-rows))))
                                ;; "max_height = windows_height / 4"
                                (else (quotient frame-rows 4))))
                         ;; "Correct that max. height if it's bogus."
                         (max-rows (max 1 (min max-rows frame-rows)))
                         (height (max 1 (min (echo-area-text-rows window) max-rows))))
                    (cond ((eq? mode 'grow-only)
                           ;; "Let it grow only, until we display an
                           ;; empty message, in which case the window
                           ;; shrinks again."
                           (cond ((> height old)
                                  (grow-mini-window window (- height old)))
                                 ((and (< height old)
                                       ;; "BEGV == ZV" of the *echo
                                       ;; buffer*, not of whatever
                                       ;; buffer happens to be current
                                       (or exact-p
                                           (with-current-buffer
                                               (window-buffer window)
                                             (= (point-min) (point-max)))))
                                  (shrink-mini-window window))))
                          ;; "Always resize to exact size needed."
                          ((not (= height old))
                           (grow-mini-window window (- height old))))
                    (not (= old (window-height window))))))))

    (define (render! frame)
      ;; Draw every window, then the echo area, then place the terminal
      ;; cursor at the selected window's point. Each window has its own
      ;; mode line, as GNU Emacs gives each window one; the echo area
      ;; belongs to the frame and is drawn last, over the bottom row.
      ;;--------------------------------------------------------------
      ;; **Draw on the frame's own display, and only the display.**
      ;; `current-display' is what every draw call below reaches for
      ;; (Emacs reaches `FRAME_TERMINAL (f)' the same way). With one
      ;; frame this is an identity rebind; with two it is what stops
      ;; frame B being drawn into A's window. The `or' is for the test
      ;; frames, whose output is #f.
      ;;
      ;; **`*current-frame*' is deliberately not bound here.** It was, so
      ;; that `selected-window' inside the drawing would answer the
      ;; frame being drawn - but `selected-window' is not "the frame
      ;; being drawn", it is Emacs's `selected_window', the selected
      ;; window of the *selected* frame, and redisplay's frame loop
      ;; (`FOR_EACH_FRAME', `xdisp.c:14350') never changes it. Binding it
      ;; made the drawn frame look selected, and `window-point'
      ;; (`frame.sld') answers *the buffer's* point for the selected
      ;; window - so while frame B was drawn it was scrolled to frame A's
      ;; point, and the two frames scrolled together however far apart
      ;; they were left.
      ;;
      ;; What the drawing actually needs about the frame it now asks for
      ;; by name: `window-frame' (`WINDOW_XFRAME (w)') for the mode-line
      ;; face and the cursor type, `(frame-selected-window frame)' and
      ;; `(window-list frame)' below for the rest.
      ;;
      ;; The call sites below are deliberately *not* rewritten to take a
      ;; display: they are the redisplay's oldest and most fragile code,
      ;; and rebinding here is the same answer for every one of them.
      (parameterize ((current-display (or (frame-output frame)
                                          (current-display)))
                     (*redisplay-in-progress* #t))
      (sync-frame-size! frame)
      (let* ((width (frame-width frame))
             (height (frame-height frame))
            ;; the *leaves*: a window that holds children shows no buffer
            ;; and has no mode line of its own, so what is drawn is the
            ;; windows at the bottom of the tree.
            ;;
            ;; **The minibuffer window is always one of them**, which is
            ;; the MINIBUF t form of `window-list`: the echo area is a
            ;; window now, so it is drawn by the same loop as any other
            ;; and nothing special-cases it. `render-window-mode-line!`
            ;; is what skips it - a minibuffer window has no mode line
            ;; (`MINI_WINDOW_P`).
            (windows (window-list frame #t))
            (body (delq (frame-minibuffer-window frame) windows)))
        ;; **The frame is not cleared.** GNU Emacs has no `clear_frame` in
        ;; the per-keystroke path at all: `update_window` writes into the
        ;; existing surface and the toolkit composites it, which is only
        ;; possible because a row that did not change is left alone. So a
        ;; `clear-frame-area!` here - which this used to do, though the
        ;; comment below already said it must not - wipes exactly the rows
        ;; the diff is about to skip, and they stay wiped until something
        ;; else marks them dirty. That is what made paging to the end
        ;; flash between two screens: the scroll decided from a window
        ;; whose rows had been erased, and each redisplay erased and
        ;; half-painted again.
        ;;
        ;; What still needs clearing is a surface that holds nothing of
        ;; ours: a frame drawn for the first time, and one just resized,
        ;; where the toolkit has already thrown the old contents away.
        ;; the surface exists before anything is drawn into it, whether
        ;; or not this redisplay clears
        (ensure-surface! (current-display))
        ;; **The cursor comes off before the frame is drawn.** It is
        ;; painted *into* the surface, so a row that the diff does not
        ;; select would keep the box the cursor left behind - Emacs's
        ;; `redisplay_window` calls `erase_phys_cursor` for the same
        ;; reason, and it is the only thing an incremental redisplay
        ;; needs that a full repaint got for free.
        (erase-phys-cursor!)
        ;; **The cursor is hidden for the whole frame update**, which is
        ;; `update_frame`'s `update_begin`/`update_end` pair
        ;; (`dispnew.c`), and for a terminal it is `tty_hide_cursor`/
        ;; `tty_show_cursor`. Without it the user watches the cursor walk
        ;; the screen as the rows are written - measured, it visibly
        ;; jumps to the mode line and back on every keystroke.
        (update-begin! (current-display))
        (clear-garbaged-frames! frame windows)
        ;; **The menu bar is built and drawn before the windows**, which
        ;; is `redisplay_internal`'s order: `update_menu_bar` runs before
        ;; any display line is filled "because it can call eval"
        ;; (`xdisp.c:14421`), and `display_menu_bar` draws the frame's
        ;; first rows. On a terminal it is a row of text; a window-system
        ;; frame's bar is its toolkit's and both calls return at once.
        (update-menu-bar frame)
        (update-tab-bar frame)
        (update-tool-bar frame)
        (unless (window-system-display? (current-display))
          (when (> (%frame-menu-bar-lines frame) 0)
            (display-menu-bar frame)))
        ;; The tab bar is drawn *below* the menu bar - the C's
        ;; `display_tab_bar` starts its iterator one row down when the
        ;; menu bar has a row (`xdisp.c:14717`) - and on a toolkit frame
        ;; too, where it is the first row of the text area.
        (when (> (%frame-tab-bar-lines frame) 0)
          (display-tab-bar frame))
        ;; Only the selected window is scrolled to show its point here:
        ;; it is the one point moves in, and its buffer is the one
        ;; commands act on. A window that is not selected keeps the view
        ;; it had, as GNU Emacs leaves a window's start alone until it
        ;; is displayed with its own point.
        ;; **`w->force_start` is consumed by the redisplay for every
        ;; window, not only the selected one.** The C clears it in
        ;; `redisplay_window`'s `force_start:` label (`xdisp.c:20746`)
        ;; whether or not the window is selected. This renderer runs the
        ;; start decision for the selected window alone - the force
        ;; branch of `scroll-to-cursor!` moves the *buffer's* point,
        ;; which is the displayed point only in the selected window - so
        ;; for the others the flag is cleared here. The caller's start is
        ;; already written, which is what the flag asks for, and clearing
        ;; it keeps it from being honoured stale the next time that
        ;; window is selected. Without this a TAB in a `*Completions*`
        ;; window (whose scroll-to-top branch calls `set-window-start!`,
        ;; as Emacs's `completion--scroll-completions` does) left the
        ;; flag set until that window's next `M-<down>`.
        (let ((selected (frame-selected-window frame)))
          (for-each (lambda (w)
                      (unless (eq? w selected)
                        (set-window-force-start?! w #f)))
                    body))
        (let ((selected (frame-selected-window frame)))
          (when selected (scroll-to-cursor! selected)))
        ;; auto hscrolling, for every window: `hscroll_window_tree'
        ;; walks the tree before any matrix is rebuilt
        ;; (`redisplay_internal', `xdisp.c'), and only the selected
        ;; window's *start* is scrolled, while hscrolling is a property
        ;; each window's own point decides
        (for-each hscroll-window! body)
        ;; **Build the rows, then draw the ones that changed.** GNU
        ;; Emacs's `redisplay_window` then `update_window`: the first makes
        ;; the desired matrix, the second compares it with what is on the
        ;; screen and draws only the difference. A cursor move therefore
        ;; costs the cursor's row and the mode line, not the frame.
        ;;
        ;; The frame is not cleared. That is not an optimisation but a
        ;; requirement: a row that is not re-drawn must still be on the
        ;; surface, and `clear-frame-area!` is what would wipe it. It is
        ;; still called when the frame is new or has been resized, where
        ;; every row genuinely must be painted.
        ;; **A window whose matrix is still good is left alone.** GNU
        ;; Emacs's `redisplay_window` asks `window_outdated` and
        ;; `current_matrix_up_to_date_p` and, when both are happy, builds
        ;; nothing at all - `try_cursor_movement` just moves the cursor
        ;; (`xdisp.c:20946`). That is the difference between a redisplay
        ;; that costs a window and one that costs a cursor: measured, a
        ;; `C-n` in the middle of a window used to rebuild every row of it
        ;; and now rebuilds none.
        ;;
        ;; **The mode line is still drawn**, below: it carries the line
        ;; and column, which change with every cursor motion, and Emacs
        ;; draws it for the same reason (`update_mode_lines`).
        ;;
        ;; A window that is *not* fresh is rebuilt and then diffed, which
        ;; is `try_window` and `update_window`.
        ;; **The echo area, before the window loop**, which is where
        ;; `redisplay_internal` puts `echo_area_display` (`xdisp.c:14425`):
        ;; the selected frame's minibuffer window displays the *echo
        ;; buffer* while there is a current message, and its own buffer
        ;; (` *Minibuf-0*`, or the prompt's) otherwise.
        ;;
        ;; The buffer is swapped in for the display and put back
        ;; afterwards, which is exactly `with_echo_area_buffer`'s
        ;; `wset_buffer` (`xdisp.c:12984`) - the window's own buffer is
        ;; never the echo buffer. Emacs reaches the same place through
        ;; `display_echo_area`, which also resizes the window first: a
        ;; message longer than the frame is wider than one row, and
        ;; `resize_mini_window` gives it the rows it needs from the
        ;; window above.
        ;; "`if (!NILP (echo_area_buffer[0]) || minibuf_level == 0)`"
        ;; (`xdisp.c:13783`) - **the echo area is displayed with no
        ;; message too**, which is what lets a grown minibuffer window
        ;; shrink back ("they return to their normal size ... when the
        ;; echo area becomes empty", `resize-mini-windows`). During a
        ;; read with no message it is left alone, because its row is the
        ;; prompt's.
        (let* ((mini (frame-minibuffer-window frame))
               (echo (and mini
                          (eq? frame (*current-frame*))
                          (echo-area-message-buffer)))
               (display-echo? (and mini (eq? frame (*current-frame*))
                                   (or echo (not (*minibuffer*)))))
               (saved (and echo
                           (list (window-buffer mini)
                                 (window-point mini)
                                 (marker-position (%window-start mini))))))
          (when display-echo?
            (when echo
              (set!window-buffer mini echo)
              (set-window-point! mini 1)
              (%window-start-set! mini 1))
            (resize-mini-window! mini #f))
          ;; One window at a time, build then draw, which is
          ;; `redisplay_window`'s own order.
          (for-each (lambda (w)
                    ;; A window with no buffer is never fresh - there is
                    ;; nothing to be fresh *about* - and `window-outdated?`
                    ;; has no buffer to ask either.
                    (unless (and (window-buffer w) (window-matrix-valid? w))
                      (ensure-window-matrices! w (window-body-width w)
                                               (window-body-height w))
                      ;; **A window that shows no buffer builds nothing.**
                      ;; The minibuffer window is one until a prompt is
                      ;; read (`minibuffer-window-active-p`), and Emacs's
                      ;; `redisplay_window` likewise has nothing to display
                      ;; for a window whose `w->contents` is nil. Its
                      ;; current matrix is emptied instead, so the diff
                      ;; draws nothing over the row and the echo-area block
                      ;; below is what paints there.
                      (if (window-buffer w)
                          (begin
                            (display-window! w)
                            (mark-window-display-accurate-1 w #t))
                          (let ((m (window-current-matrix w)))
                            (when m (clear-glyph-matrix m))))
                      (update-window! w))
                    ;; **The scroll bar is updated for every window, fresh
                    ;; or not.** GNU Emacs's early paths out of
                    ;; `redisplay_window` jump to `finish_scroll_bars`
                    ;; (`xdisp.c:20543`, `:20563`), so a window that
                    ;; needed no rows still has its thumb position
                    ;; brought up to date; the bar is outside the glyph
                    ;; matrix and the row diff knows nothing about it.
                    ;;
                    ;; **A minibuffer window has no bar**, and the C says
                    ;; so by leaving `redisplay_window` before that label:
                    ;; `if (MINI_WINDOW_P (w)) ... goto finish_menu_bars`
                    ;; (`xdisp.c:20532`) - which is *past*
                    ;; `finish_scroll_bars` (`:21616`). `window-scroll-bars`
                    ;; still reports the frame's two columns for it
                    ;; (measured on Emacs 31.1), but nothing draws one.
                    (unless (window-minibuffer-p w)
                      (set-vertical-scroll-bar w)))
                    windows)
          ;; A bar whose window has gone is destroyed - the C's
          ;; `judge_scroll_bars_hook`, at the end of the frame's
          ;; redisplay.
          (display-redeem-scroll-bars (current-display) windows)
          ;; ...and the minibuffer window's own buffer back, with the
          ;; start and point it had.
          (when saved
            (set!window-buffer mini (car saved))
            (set-window-point! mini (cadr saved))
            (%window-start-set! mini (caddr saved))))
        ;; **No mode line for the minibuffer window**, which is Emacs's
        ;; `MINI_WINDOW_P` test in `display_mode_lines`: a minibuffer
        ;; window is one row and that row is its text.
        ;; The tab line first: it is the row above the text, and
        ;; `display_mode_lines` draws mode line, tab line, header line in
        ;; that order (`xdisp.c:28166`) because each `display_mode_line`
        ;; claims the next free row from the bottom - here the rows are
        ;; fixed, so the order does not matter and the tab line is drawn
        ;; where it is read.
        (for-each render-window-tab-line! body)
        (for-each render-window-mode-line! body)
        ;; Place the terminal cursor: in the minibuffer while one is
        ;; active (Emacs's `cursor-in-echo-area'), else at the selected
        ;; window's point - the only window whose cursor is drawn, there
        ;; being one cursor on a terminal.
        ;; **The cursor is the selected window's, and the echo area
        ;; needs no branch of its own.** GNU Emacs's
        ;; `get_window_cursor_type` (`xdisp.c:34825`) asks whether
        ;; `w == XWINDOW (echo_area_window)`; the echo area gets a cursor
        ;; only while `cursor-in-echo-area` says so, and otherwise the
        ;; selected window does. While a prompt is read the minibuffer
        ;; window **is** the selected window (`read_minibuf`'s
        ;; `Fselect_window (minibuf_window)`, `minibuf.c:841`), so the
        ;; ordinary path puts the cursor on the prompt - at point in the
        ;; input, which is where it belongs. Click into another window
        ;; and that window is selected, so the cursor goes there and the
        ;; prompt stays drawn, which is what typing there looks like.
        ;;
        ;; **This used to be two branches**, because the echo row was
        ;; painted by hand and was not a window: the prompt's column had
        ;; to be composed from the prompt's width and the buffer's
        ;; column. It is buffer text now, so the row's own scan counts
        ;; it.
        (let ((selected (or (and (*cursor-in-echo-area*)
                                 (frame-minibuffer-window frame))
                            (frame-selected-window frame))))
          ;; **A window with no buffer has no cursor to draw.** GNU
          ;; Emacs's frame is made with `make_minibuffer_window`, whose
          ;; `w->contents` is nil until `read_minibuf`'s
          ;; `set_window_buffer` (`minibuf.c:840`), and `redisplay_window`
          ;; has nothing to walk for one. This block used to call
          ;; `(cursor-glyph BUFFER (window-point WINDOW))' with both #f in
          ;; that state - `window-point` of a bufferless window is its
          ;; unset marker - and the line scan raised "Wrong type argument
          ;; in position 2: #f".
          (when (and selected (window-buffer selected))
            (let ((at (cursor-screen-position selected)))
              (when at
                (let* ((buffer (window-buffer selected))
                       (cursor (get-window-cursor-type selected))
                       ;; the glyph under the cursor is the one at the
                       ;; *window's* point, as Emacs's is (the glyph row
                       ;; the display iterator stopped on)
                       (glyph (cursor-glyph buffer (window-point selected))))
                  (note-phys-cursor!
                   (current-display)
                   (window-to-frame-pixel-y
                    selected
                    (window-pixel-y
                     selected
                     (- (car at) (window-body-top selected))))
                   (cdr at)
                   (cursor-cells buffer (window-point selected))
                   (car glyph) (cdr glyph))
                  (draw-window-cursor! (current-display)
                                       ;; **The cursor's pixel y**, which
                                       ;; is `w->cursor.y` in the C: the
                                       ;; sum of the heights of the rows
                                       ;; above it, not its row index -
                                       ;; once rows differ in height those
                                       ;; are not the same.
                                       ;;
                                       ;; `cursor-screen-position`
                                       ;; answers a *frame* row (it adds
                                       ;; `window-top'), and
                                       ;; `window-pixel-y' walks rows
                                       ;; inside the window, so the
                                       ;; window's own top comes back off
                                       ;; before the walk and goes back
                                       ;; on with the heights in pixels.
                                       (window-to-frame-pixel-y
                                        selected
                                        (window-pixel-y
                                         selected
                                         (- (car at) (window-body-top selected))))
                                       (cdr at)
                                       (cursor-cells buffer
                                                     (window-point selected))
                                       (car cursor) (cadr cursor)
                                       (car glyph) (cdr glyph)))))))
        ;; **The display's own cursor is placed once the frame's text is
        ;; written.** GNU Emacs's `update_frame` ends with
        ;; `tty_set_cursor` (`dispnew.c`), which reads the cursor
        ;; position the redisplay recorded (`w->cursor`) and addresses
        ;; the hardware cursor there; the visibility is `update_begin`/
        ;; `update_end`'s. It is a separate step from drawing the cursor
        ;; even on a window-system display, where the default method does
        ;; nothing because the toolkit owns its cursor.
        ;;
        ;; Placing it here, before `update-end!` shows it, is the order
        ;; in Emacs's own `update_frame_with_menu` - and it is the order
        ;; that cannot be seen: the cursor is addressed while
        ;; `update-begin!` still has it hidden, so it never appears at
        ;; whatever cell the last glyph write left it in.
        (let ((phys (*phys-cursor*)))
          (when phys
            (set-terminal-cursor! (car phys) (cadr phys) (caddr phys))))
        ;; The screen is what was drawn: the display's flush, which for
        ;; this terminal honours the full-repaint `clear-frame-area!'
        ;; asked for (partial-update optimizations desync the physical
        ;; terminal when lines merge).
        (update-end! (current-display))
        (flush-display! (current-display))
        )))


    ;;----------------------------------------------------------------
    ;; Where the mouse is
    ;;
    ;; What a mouse event carries: GNU Emacs's `make_lispy_position'
    ;; (`keyboard.c') as `posn-at-x-y' (`keyboard.c:13009') reaches it.
    ;; It is here rather than in `keyboard.sld' for the reason the rest
    ;; of this file's walks are: the half that finds a *character* is
    ;; `buffer_posn_from_coords', which is `xdisp.c''s, and it has to
    ;; walk rows exactly as the renderer does or the two will disagree
    ;; about which row a wrapped line's second half is on.
    ;;------------------------------------------------------------------

    (define track-mouse #f)
    ;; ^ GNU Emacs's `track-mouse' - a C variable of `xdisp.c' - which is
    ;; whether the display makes an *event* of pointer motion at all.
    ;; Nil, this tree's #f, means it does not: an ordinary pass of the
    ;; pointer over a window is not a key, because Emacs does not make
    ;; one, and a front end that reported motion whenever it happened
    ;; would hand the command loop a `mouse-movement' it has nothing
    ;; bound for - "undefined key" on every move.
    ;;
    ;; `mouse-drag-track' sets it for as long as a drag is being tracked,
    ;; which is the only time the editor wants to know where the pointer
    ;; is, and `pgtk.sld''s motion handler reads it before queueing
    ;; anything (the other values Emacs knows - `drag-tracking',
    ;; `dropping', `drag-source' - are all true here, which is the same
    ;; test the C's front ends make: `!NILP (track_mouse)').
    ;;
    ;; **A plain variable and not a parameter**, because Emacs's is a
    ;; plain Lisp variable: `mouse-drag-track' `setq's it, saves the old
    ;; value in `old-track-mouse' and puts it back from the cleanup its
    ;; transient map runs on exit. There is no dynamic extent for a
    ;; parameter to be the analogue of - the cleanup runs after the
    ;; command that installed it has returned.
    ;;--------------------------------------------------------------

    (define (%posn-char-at texts from to column)
      ;; The offset within TEXTS of the character drawn at display COLUMN,
      ;; walking `from' to `to' and adding each text's own width - a wide
      ;; character takes two columns and a `display' property's string takes
      ;; its own - so counting characters would land a cell to the left of
      ;; what was clicked.
      ;;
      ;; The accumulation is `texts-width''s and `scan_for_column''s, which
      ;; is the walk the row was *drawn* with, so this cannot disagree with
      ;; what is on the screen. It walked the line's characters instead,
      ;; which is right only for a line no `display' property stands in -
      ;; and the one line in this tree that has one is Dired's disk-space
      ;; header, which is exactly where a click would land a cell out.
      ;;
      ;; It stops at `to': a click past the end of a slice is the end of
      ;; the slice.
      ;;--------------------------------------------------------------
      (let loop ((i from) (c 0))
        (if (or (>= i to) (>= c column))
            (min i to)
            (loop (+ i 1) (+ c (texts-width texts i c))))))

    (define (remember-mouse-glyph frame x y)
      ;; GNU Emacs's `remember_mouse_glyph' (`xdisp.c:2778'): "Return the
      ;; extents of glyph in FRAME for mouse event generation", as
      ;; `(X Y WIDTH HEIGHT)' in the frame's own units.
      ;;
      ;; **What it is for.** `note_mouse_movement' (`pgtkterm.c:5892')
      ;; remembers the glyph the pointer was last reported on and treats a
      ;; report that is still inside it as *no movement at all* - "If not,
      ;; ask for another motion event, so we can check again the next time
      ;; it moves." That filter is what makes a drag past the edge of a
      ;; window keep scrolling while the pointer is held out there: a
      ;; mouse reports its position many times a second, and only the
      ;; reports that leave the glyph become events a command can see.
      ;;
      ;; **A glyph here is the cell.** Emacs's version reads the window's
      ;; *glyph matrix* and answers the rectangle of the glyph under the
      ;; pointer in pixels - two cells wide for a wide character, the whole
      ;; row for a mode line glyph. This tree has no glyph matrix: a window
      ;; is drawn from the buffer a line at a time, and a character is one
      ;; cell wide except a wide one, which is two (`char-display-width').
      ;; So the extents are the cell, which is what Emacs answers for an
      ;; ordinary character anyway, and its `virtual_glyph' branch - "if
      ;; there is no glyph under the mouse, divide the screen into a grid
      ;; of the smallest glyph in the frame" - is the same answer for
      ;; everything else.
      ;;
      ;; The one place the two differ is a *wide* character: Emacs
      ;; remembers it as two cells wide, so a pointer moving within it is
      ;; not movement, where here it is. The difference can only make this
      ;; tree report *more* movement than Emacs and never less, and the
      ;; `mouse-position' query the drag scrolls by is unaffected by it.
      ;;--------------------------------------------------------------
      (let ((display (frame-output frame)))
        (list x y
              (if display (column-width display) 1)
              (if display (line-height display) 1))))

    (define (buffer-posn-from-coords window row column)
      ;; GNU Emacs's `buffer_posn_from_coords' (`xdisp.c'): the buffer
      ;; position of the character at ROW and COLUMN within WINDOW, both
      ;; counted from the window's own top-left corner. This tree counts
      ;; *cells* where the C counts pixels and glyphs.
      ;;
      ;; The walk is the renderer's own - the same `line-display-texts'
      ;; and `%window-line-slices' that `render-window-rows!' uses,
      ;; advanced by the same `line-next-start', and landing within a row
      ;; by `%posn-char-at', which is the row's own measure - which is what
      ;; makes the answer agree with what is on the screen. A second walk written by hand would be
      ;; free to disagree, and this file has a section on how that goes.
      ;;
      ;; #f when the coordinates are past the end of the text: there is
      ;; no character there to point at.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window))
            (vheight (window-body-height window))
            (start (window-start window)))
        ;; LAST-END carries the end of the line the walk last passed, and
        ;; is what a click *below* the text answers: there is no character
        ;; on that row, and Emacs's `buffer_posn_from_coords' walks the
        ;; rows it can and stops at the last one it reached, so a click
        ;; under a short file puts point at the end of the text. #f means
        ;; the window had no text at all to answer with.
        (let loop ((r 0) (line-start start) (last-end #f))
          (cond
           ((>= r vheight) last-end)
           ((not line-start) last-end)
           (else
            (let* ((texts (line-display-texts ed line-start))
                   (slices (%window-line-slices window texts)))
              (cond
               ((null? slices) last-end)
               ((< row (+ r (length slices)))
                (let ((slice (list-ref slices (- row r))))
                  (+ line-start
                     (%posn-char-at texts (car slice) (cdr slice)
                                    column))))
               ((not (line-next-start ed line-start))
                (text-editor-get-end-of-line ed line-start))
               (else
                (loop (+ r (length slices))
                      (line-next-start ed line-start)
                      (text-editor-get-end-of-line ed line-start))))))))))

    (define (%tab-line-string-at line pos)
      ;; The tab line's string that POS was drawn from, and POS's index in
      ;; it: the `(STRING . POS)` OBJECT field of a position list.
      ;;
      ;; **GNU Emacs's redisplay stores one of these per string** that
      ;; `format-mode-line` lays out (`store_mode_line_string`,
      ;; `xdisp.c:27444`), so `posn-string` on a tab-line hit gives *that
      ;; tab's own string* - which is what `tab-line--get-tab-property`
      ;; reads its `tab` property at position 1 of (`tab-line.el:854`).
      ;; This renderer formats the whole row into one string, so the
      ;; segment is rebuilt from the `tab` property's run: a tab's string
      ;; is `(concat SEPARATOR TAB-STRING)` (`tab-line.el:718`), so it
      ;; begins one character before the run - and a click on the
      ;; separator belongs to the string that follows it. Without this,
      ;; position 1 of the *whole row* is always the first tab, so every
      ;; click selected the first tab (and a click on a close button
      ;; closed it).
      ;;
      ;; A position outside any `tab` run - the scroll arrows, the `+`
      ;; button, the empty separator at the end - answers the whole row,
      ;; which is what it answered before and all those commands read.
      ;;--------------------------------------------------------------
      (let* ((len (string-length line))
             (pos (max 0 (min pos (max 0 (- len 1)))))
             (here (get-text-property pos 'tab line))
             (next (and (< (+ pos 1) len)
                        (get-text-property (+ pos 1) 'tab line))))
        (if (not (or here next))
            (cons line pos)
            ;; The run of one `tab` value, walked rather than asked of
            ;; `previous-single-property-change`: that answers nil at the
            ;; *first* character of a run, and 4 (not 5) at the start of
            ;; the next one - Emacs's own answers, measured - which is not
            ;; a boundary this can use directly.
            (let* ((start (if here pos (+ pos 1)))
                   (value (get-text-property start 'tab line))
                   (start (let loop ((i start))
                            (if (and (> i 0)
                                     (equal? (get-text-property (- i 1) 'tab line)
                                             value))
                                (loop (- i 1))
                                i)))
                   (end (let loop ((i start))
                          (if (and (< i len)
                                   (equal? (get-text-property i 'tab line)
                                           value))
                              (loop (+ i 1))
                              i)))
                   (seg-start (max 0 (- start 1))))
              (cons (%substring line seg-start end)
                    (- pos seg-start))))))

    (define (posn-at-x-y x y frame)
      ;; GNU Emacs's `posn-at-x-y' (`keyboard.c:13009'), which is
      ;; `make_lispy_position' with a timestamp of 0 and the frame's
      ;; default text area: the *position list* a mouse event carries,
      ;;
      ;;   (WINDOW AREA-OR-POS (X . Y) TIMESTAMP)
      ;;
      ;; which the `posn-' accessors in `subr.sld' walk.
      ;;
      ;; **X and Y are pixels, and everything below is cells**, so this
      ;; is where the display is asked how big a cell is. Emacs's
      ;; `window_from_coordinates' takes pixels and converts against each
      ;; window's own edges; a cell is one column and one row of the
      ;; frame here, for every window in it.
      ;;
      ;; The window is found by its own screen rectangle, which every
      ;; window carries (`window-top', `window-left', `window-width',
      ;; `window-height' - Emacs's `w->top_line' and its neighbours). A
      ;; response on its last row is the mode line, which is the one
      ;; non-text area this tree has: a press on a border, a fringe or a
      ;; scroll bar has no window here to be on, and Emacs's other area
      ;; symbols are not answered.
      ;;--------------------------------------------------------------
      (let ((column (quotient (inexact->exact (round x))
                              (column-width (current-display))))
            (row (quotient (inexact->exact (round y))
                           (line-height (current-display)))))
        (let loop ((rest (window-list frame)))
          (cond
           ((< row (frame-top-margin frame))
            ;; **The menu bar and the tab bar.** GNU Emacs's
            ;; `make_lispy_position` answers `(FRAME menu-bar (X . Y)
            ;; TIME)' for a position in the frame's top margin, which is
            ;; what `menu-bar-open-mouse` and `popup-menu` read - and
            ;; `tab-bar` for the rows the tab bar occupies, which is what
            ;; `tab-bar--event-to-item` reads. **The tab bar's rows are
            ;; below the menu bar's** - `display_tab_bar` starts its
            ;; iterator at `FRAME_MENU_BAR_LINES` (`xdisp.c:14717`).
            (list frame
                  (if (< row (- (frame-top-margin frame)
                                (%frame-tab-bar-lines frame)))
                      'menu-bar
                      'tab-bar)
                  (cons x y) 0))
           ((null? rest)
            ;; Outside every window: Emacs answers the frame, and the
            ;; position of a frame is the frame.
            (list frame #f (cons x y) 0))
           (else
            (let* ((w (car rest))
                   (top (window-top w))
                   (left (window-left w))
                   (height (window-height w))
                   (width (window-width w))
                   (body-left (window-body-left w))
                   (bar-cols (window-scroll-bar-cols w))
                   (bar-left (if (eq? (window-vertical-scroll-bar-type w) 'left)
                                 left
                                 (- (+ left width) bar-cols))))
              (if (and (>= row top) (< row (+ top height))
                       (>= column left) (< column (+ left width)))
                  (cond
                   ;; **`ON_VERTICAL_BORDER`: a line row's grabbable edge.**
                   ;; `coordinates_in_window` tests the mode, header and
                   ;; tab line rows *before* the scroll bar columns, and
                   ;; answers `ON_VERTICAL_BORDER` for the one-column strip
                   ;; at the window's edge - the part of the line that sits
                   ;; over a toolkit scroll bar - "to be able to resize
                   ;; windows horizontally in case we're using toolkit
                   ;; scroll bars" (`window.c:1405-1418`). `note_mouse_
                   ;; highlight` answers the horizontal-drag cursor for it
                   ;; and the help string "drag-mouse-1: resize"
                   ;; (`xdisp.c:37257`), and `[vertical-line down-mouse-1]`
                   ;; is `mouse-drag-vertical-line`.
                   ((and (or (and (= row top)
                                  (> (window-tab-line-height w) 0))
                             (and (= row (+ top height -1))
                                  (not (window-minibuffer-p w))))
                         (let ((side (window-vertical-scroll-bar-type w)))
                           (or (and (memq side '(#f right))
                                    (window-right-border? w)
                                    (= column (+ left width -1)))
                               (and (eq? side 'left)
                                    (not (window-leftmost? w))
                                    (= column left)))))
                    (list w 'vertical-line (cons x y) 0))
                   ;; **The tab line.** GNU Emacs's `coordinates_in_window`
                   ;; tests `WINDOW_WANTS_TAB_LINE_P` before the mode line
                   ;; and answers `(WINDOW tab-line (X . Y) TIME OBJECT)`,
                   ;; where OBJECT is the string drawn there and the
                   ;; character in it - the same `posn-string` shape a click
                   ;; on a display string gives, and the reason a tab can be
                   ;; clicked at all: `current_active_maps` reads the
                   ;; string's `keymap' property from it.
                   ;;
                   ;; The string is the one the last redisplay drew
                   ;; (`window-last-tab-line`, this renderer's record of it),
                   ;; so the answer agrees with what is on the screen.
                   ((and (= row top) (> (window-tab-line-height w) 0))
                    (let* ((record (window-last-tab-line w))
                           (line (and record (car record)))
                           (pos (- column body-left)))
                      (if (and line (string? line)
                               (>= pos 0) (< pos (string-length line)))
                          (list w 'tab-line (cons x y) 0
                                (%tab-line-string-at line pos))
                          (list w 'tab-line (cons x y) 0))))
                   ((and (= row (+ top height -1))
                           ;; **A minibuffer window has no mode line**, so
                           ;; its one row is text - GNU Emacs's
                           ;; `coordinates_in_window` asks
                           ;; `WINDOW_WANTS_MODELINE_P`, which is false for
                           ;; `MINI_WINDOW_P`. Reporting `mode-line` here
                           ;; is what made a click on the prompt a click on
                           ;; nothing: `posn-point` is nil for that area, so
                           ;; the prompt was selected but point never moved
                           ;; in it.
                           (not (window-minibuffer-p w)))
                    ;; **The mode line's string is the event's object**,
                    ;; which is GNU Emacs's `store_mode_line_string`
                    ;; (`xdisp.c`): the redisplay records each string it
                    ;; lays down in the glyph row, so a click's position
                    ;; carries `(STRING . CHARPOS)` and
                    ;; `current_active_maps` can read that string's
                    ;; `keymap`/`local-map` properties. Without it every
                    ;; mode-line item looked like plain mode line and
                    ;; nothing in `bindings.el` was clickable.
                    (let* ((record (window-last-mode-line w))
                           (line (and record (car record)))
                           (pos (- column body-left)))
                      (if (and line (string? line)
                               (>= pos 0) (< pos (string-length line)))
                          (list w 'mode-line (cons x y) 0 (cons line pos))
                          (list w 'mode-line (cons x y) 0))))
                   ;; **The scroll bar columns answer the bar only below
                   ;; the lines above.** `coordinates_in_window` tests
                   ;; the mode line and tab line *first*
                   ;; (`window.c:1396-1418`) and the scroll bar columns
                   ;; after them (`:1466`), so a point in the bar columns
                   ;; on the mode line row is a mode-line point - the
                   ;; mode line is drawn across the bar area, and clicking
                   ;; there drags the window edge. The toolkit widget
                   ;; really is over the body columns, so a real click
                   ;; never reaches here; a posn asked for from Lisp does.
                   ((and (> bar-cols 0)
                         (>= column bar-left)
                         (< column (+ bar-left bar-cols)))
                    (list w 'vertical-scroll-bar (cons x y) 0))
                   ;; **A text row's border column.** With no scroll
                   ;; bars the vertical border is the window's last
                   ;; column, and `coordinates_in_window` answers
                   ;; `ON_VERTICAL_BORDER` for it (`window.c:1448-1453`) -
                   ;; the horizontal-drag handle.
                   ((and (not (window-vertical-scroll-bar-type w))
                         (window-right-border? w)
                         (= column (+ left width -1)))
                    (list w 'vertical-line (cons x y) 0))
                   (else
                    (list w (buffer-posn-from-coords
                             w (- row (window-body-top w)) (- column body-left))
                          (cons x y) 0)))
                  (loop (cdr rest)))))))))

    ;;----------------------------------------------------------------
    ;; What the pointer is over - `note_mouse_highlight` (`xdisp.c:37061`)
    ;;----------------------------------------------------------------

    (define (mouse-face-at window position)
      ;; The `mouse-face` in effect at POSITION in WINDOW, as
      ;; `(VALUE BEG END)`, or #f. GNU Emacs's
      ;; `get_char_property_and_overlay` half of `note_mouse_highlight`
      ;; (`xdisp.c:37523`): "Find the highest priority overlay with a
      ;; mouse-face", and when there is none, the text property - with
      ;; the run its `previous-single-property-change` and
      ;; `next-single-property-change` answer, bounded by the window's
      ;; visible text as the C bounds them.
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (with-current-buffer buffer
          (let ((overlay
                 (let loop ((ovs (overlays-at position #t)))
                   ;; `overlays-at` with SORTED is already in *decreasing*
                   ;; priority order (`buffer.c`), which is the order the
                   ;; C's own loop reads backwards.
                   (cond ((null? ovs) #f)
                         ((overlay-get (car ovs) 'mouse-face) (car ovs))
                         (else (loop (cdr ovs)))))))
            (if overlay
                (list (overlay-get overlay 'mouse-face)
                      (overlay-start overlay)
                      (overlay-end overlay))
                (let ((value (get-text-property position 'mouse-face)))
                  (and value
                       (list value
                             (or (previous-single-property-change
                                  (+ position 1) 'mouse-face
                                  buffer (window-start window))
                                 (buffer-text-base (text-editor-text buffer)))
                             (or (next-single-property-change
                                  position 'mouse-face
                                  buffer (window-end window))
                                 (buffer-text-z (text-editor-text buffer)))))))))))

    (define (clear-mouse-face!)
      ;; GNU Emacs's `clear_mouse_face` (`xdisp.c:35680`): take the
      ;; highlight off the window that has it, and answer whether there
      ;; was one to take off.
      ;;--------------------------------------------------------------
      (if (not %mouse-face-window)
          #f
          (begin
            (mark-window-display-accurate-1 %mouse-face-window #f)
            (set! %mouse-face-window #f)
            (set! %mouse-face-beg #f)
            (set! %mouse-face-end #f)
            (set! %mouse-face-attrs #f)
            (set! %mouse-face-string #f)
            #t)))

    ;;----------------------------------------------------------------
    ;; The pointer's shape - `define_frame_cursor1` (`xdisp.c:36592`)
    ;;----------------------------------------------------------------
    ;;
    ;; `note_mouse_highlight` decides two things: which text wears the
    ;; mouse face, and what shape the pointer has over the area under it
    ;; ("Change the mouse pointer according to what is under it",
    ;; `xdisp.c:36790`, and the `set_cursor:` label at `:37701`). The
    ;; shape is *not* gated on `mouse-highlight` - that variable only
    ;; decides whether text lights up - and that is why the cursor is
    ;; noted before the face machinery below.

    (define (pointer-kind pointer)
      ;; GNU Emacs's `define_frame_cursor1`'s mapping of a `pointer` text
      ;; property value to a cursor (`xdisp.c:36600`). An unknown value is
      ;; the nontext cursor, as there.
      ;;--------------------------------------------------------------
      (case pointer
        ((arrow) 'nontext)
        ((hand) 'hand)
        ((text) 'text)
        ((hdrag) 'horizontal-drag)
        ((nhdrag) 'vertical-drag)
        ((vdrag) 'scrollbar)
        ((hourglass) 'hourglass)
        ((modeline) 'modeline)
        (else 'nontext)))

    (define (mode-line-draggable? window area)
      ;; Whether AREA is a line whose window edge can be dragged - the C's
      ;; `draggable_window_top_line`/`_bottom_line` (`xdisp.c:36777`):
      ;;
      ;;   bottom = ON_MODE_LINE && (!WINDOW_BOTTOMMOST_P (w)
      ;;                             || minibuf_level
      ;;                             || NILP (Vresize_mini_windows))
      ;;   top    = (ON_HEADER_LINE || ON_TAB_LINE) && !WINDOW_TOPMOST_P (w)
      ;;
      ;; `minibuf_level` is "a prompt is up", which this tree's
      ;; `*minibuffer*` answers; a minibuffer window is resized even at
      ;; the frame's bottom because `mouse-drag-mode-line` allows it for
      ;; the same two reasons (`mouse.el:1088`).
      ;;--------------------------------------------------------------
      (cond
       ((eq? area 'mode-line)
        (or (not (window-at-side-p window 'bottom))
            (*minibuffer*)
            (not (*resize-mini-windows*))))
       ((eq? area 'tab-line)
        (not (window-at-side-p window 'top)))
       (else #f)))

    (define (string-mouse-face-at string position)
      ;; The `mouse-face` in effect at POSITION in STRING, as
      ;; `(VALUE BEG END)`, or #f - GNU Emacs's
      ;; `note_line_or_margin_highlight` (`xdisp.c:36899`).
      ;;
      ;; The run is the *string*'s: the backward walk starts at
      ;; `charpos + 1` so that a run beginning at the character under the
      ;; pointer is included, the forward walk at the character itself,
      ;; and a walk that finds nothing is the string's own edge. That is
      ;; the C's `Fprevious_single_property_change (charpos + 1, ...)`
      ;; and `Fnext_single_property_change (pos, ...)` with their nil
      ;; answers replaced by 0 and `SCHARS`.
      ;;--------------------------------------------------------------
      ;;
      ;; **The run cannot cross a format element either.** In Emacs each
      ;; element is its own string object, so the property walk within it
      ;; stops at its edge; this tree's line is one flattened string, and
      ;; `mode-line-elt-no` is the stand-in for that identity. Without
      ;; it the four adjacent items of Emacs's default line (`:`, the two
      ;; flags and the remote flag, all sharing the `mode-line-highlight`
      ;; value) lit up together, where Emacs boxes them one at a time.
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (and (> n 0)
             (let* ((pos (min (max position 0) (- n 1)))
                    (value (get-text-property pos 'mouse-face string)))
               (and value
                    (let ((beg (or (previous-single-property-change
                                    (+ pos 1) 'mouse-face string #f)
                                   0))
                          (end (or (next-single-property-change
                                    pos 'mouse-face string #f)
                                   n))
                          (elt-beg
                           (or (previous-single-property-change
                                (+ pos 1) 'mode-line-elt-no string #f)
                               0))
                          (elt-end
                           (or (next-single-property-change
                                pos 'mode-line-elt-no string #f)
                               n))
                          ;; A lighter's own run, for the reason the
                          ;; element's is here: Emacs's lighters are
                          ;; separate string objects, and hovering one
                          ;; lights only it.
                          (lit-beg
                           (or (previous-single-property-change
                                (+ pos 1) 'mode-line-lighter string #f)
                               0))
                          (lit-end
                           (or (next-single-property-change
                                pos 'mode-line-lighter string #f)
                               n)))
                      (list value
                            (max beg elt-beg lit-beg)
                            (min end elt-end lit-end))))))))

    (define (string-pointer-at string position)
      ;; The `pointer` text property of STRING at POSITION, clamped to the
      ;; string - "CHARPOS can be beyond the last position of STRING due,
      ;; e.g., to min-width 'display' property" (`xdisp.c:36736`).
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (and (> n 0)
             (get-text-property (min (max position 0) (- n 1))
                                'pointer string))))

    (define (string-property-run-at posn prop)
      ;; The substring of POSN's string around its position that shares
      ;; PROP's value - what Emacs gets free from a posn's *string
      ;; object*: each mode-line element there is a string of its own, so
      ;; `posn-object` is exactly the run. This renderer's mode line is
      ;; one flattened string, so the run is cut out here.
      ;;
      ;; It is how a click on the minor-mode lighters finds `(""
      ;; ,visible)` - the string `lookup-minor-mode-from-indicator`
      ;; compares against a lighter (`mouse.el:298`, `bindings.el:956`).
      ;;--------------------------------------------------------------
      (let ((s (posn-string posn)))
        (and (pair? s)
             (let* ((string (car s))
                    (n (string-length string)))
               (and (> n 0)
                    (let* ((pos (min (max (cdr s) 0) (- n 1)))
                           (run (lambda (p)
                                  (list (or (previous-single-property-change
                                             (+ pos 1) p string #f)
                                            0)
                                        (or (next-single-property-change
                                             pos p string #f)
                                            n))))
                           (own (run prop))
                           ;; The walk cannot cross a format element
                           ;; (`mode-line-elt-no`) any more than a
                           ;; lighter's own run (`mode-line-lighter`) -
                           ;; both stand in for the per-string identity
                           ;; Emacs's redisplay keeps.
                           (elt (run 'mode-line-elt-no))
                           (lit (run 'mode-line-lighter)))
                      (substring string
                                 (max (car own) (car elt) (car lit))
                                 (min (cadr own) (cadr elt) (cadr lit)))))))))

    (define (string-keymap-at? string position)
      ;; Whether the string under the pointer is a clickable mode-line
      ;; item: `get_text_property (pos, Qlocal_map, string)` or `Qkeymap`
      ;; that is a keymap (`xdisp.c:36802`). Such a glyph keeps the
      ;; nontext pointer - the mode line is not a resize handle there.
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (and (> n 0)
             (let ((pos (min (max position 0) (- n 1))))
               (or (keymapp (get-text-property pos 'local-map string))
                   (keymapp (get-text-property pos 'keymap string)))))))

    (define (text-pointer-at window position)
      ;; The `pointer` property under a text position: overlays first, in
      ;; decreasing priority order, then the buffer's text property
      ;; (`xdisp.c:37660`).
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (with-current-buffer buffer
          (let loop ((overlays (overlays-at position)))
            (cond ((null? overlays)
                   (get-text-property position 'pointer buffer))
                  ((overlay-get (car overlays) 'pointer)
                   (overlay-get (car overlays) 'pointer))
                  (else (loop (cdr overlays))))))))

    (define (frame-cursor-for-posn posn run)
      ;; What the pointer's shape is over POSN - the C's `set_cursor:`
      ;; decision, in its order: a `pointer` property wins over
      ;; everything; then the named areas; then the text area, where a
      ;; `mouse-face` run answers the hand cursor.
      ;;--------------------------------------------------------------
      (let* ((area (posn-area posn))
             (window (posn-window posn))
             (position (posn-point posn))
             (string (posn-string posn))
             (pointer
              (or (and (pair? string) (string-pointer-at (car string)
                                                        (cdr string)))
                  (and (window-type? window)
                       (integer? position)
                       (text-pointer-at window position)))))
        (cond
         (pointer (pointer-kind pointer))
         ((memq area '(menu-bar tab-bar)) 'nontext)
         ;; `ON_VERTICAL_SCROLL_BAR` and `ON_HORIZONTAL_SCROLL_BAR` answer
         ;; the display's own scroll-bar cursors (`xdisp.c:36617`):
         ;; `vertical_scroll_bar_cursor` is `GDK_SB_V_DOUBLE_ARROW` and
         ;; `horizontal_scroll_bar_cursor` `GDK_SB_H_DOUBLE_ARROW`
         ;; (`pgtkterm.c:7243-7248`).
         ((eq? area 'vertical-scroll-bar) 'scrollbar)
         ((eq? area 'horizontal-scroll-bar) 'horizontal-scrollbar)
         ((eq? area 'vertical-line) 'horizontal-drag)
         ((memq area '(mode-line tab-line))
          (if (and (window-type? window)
                   (mode-line-draggable? window area)
                   (not (and (pair? string)
                             (string-keymap-at? (car string) (cdr string)))))
              'vertical-drag
              'nontext))
         (run 'hand)
         (else 'text))))

    (define (note-frame-cursor frame posn run)
      ;; Ask the display to show the shape the area under the pointer
      ;; asks for - `FRAME_RIF (f)->define_frame_cursor`
      ;; (`xdisp.c:37702`). A display with no pointer (a terminal) does
      ;; nothing: its method is the default.
      ;;--------------------------------------------------------------
      (let ((display (and frame (frame-output frame))))
        (and display
             (display-define-frame-cursor display frame
                                          (frame-cursor-for-posn posn run)))))

    ;;----------------------------------------------------------------
    ;; The help echo - `note_mouse_highlight`'s other half
    ;;----------------------------------------------------------------
    ;;
    ;; "If the mouse moved onto or out of a `mouse-face` region, start
    ;; displaying the highlighted text" is half of `note_mouse_highlight`
    ;; (`xdisp.c:37061`); the other half is the `help-echo` property, the
    ;; text a tooltip shows. The C finds it in three places - an overlay's
    ;; property, the buffer's text property, or the *string* drawn on a
    ;; mode line or tab line - and hands it, with the window and object it
    ;; was found in, to `show_help_echo` (`keyboard.c:2259`), which runs
    ;; the display function `tooltip.el` installs.
    ;;
    ;; **A named departure**: the C makes a `help-echo` *event* and
    ;; `read_char` shows it between commands, so a help function's
    ;; side-effects run in the command loop. This renderer calls
    ;; `show-help-echo` from the motion handler itself, as it already
    ;; does for the mouse face, because this front end's pointer events
    ;; are dispatched from Gtk signals and there is no read to carry the
    ;; event. `show_help_echo` swallows errors either way, so what runs
    ;; where is the only difference.

    (define *show-help-echo-function* (make-parameter #f))
    ;; ^ `show_help_echo` is `keyboard.c`'s and this library is below
    ;; `keyboard.scm`, so the call comes *up* through this parameter,
    ;; which `keyboard.scm` installs at load - the `*menu-bar-items-function*`
    ;; pattern in reverse. #f until then, and nothing is shown.

    (define %help-echo-previous #f)
    ;; ^ The C's `help_echo_string` as the last motion left it. The motion
    ;; handler generates a help event when either the new value or this
    ;; one is non-nil, which is what makes moving off a help item clear
    ;; the tooltip.

    (define (window-mode-line-help-echo window)
      ;; `display_mode_lines`' computation of `w->mode_line_help_echo`
      ;; (`xdisp.c:28141`): the buffer-local option is a function of the
      ;; window or a string, and nil is "use the string's own property or
      ;; nothing". Emacs computes it when the mode line is formatted; the
      ;; answer is the same at hover time and this asks then.
      ;;--------------------------------------------------------------
      (let ((default (buffer-local-value (window-buffer window)
                                         'mode-line-default-help-echo
                                         (*mode-line-default-help-echo*))))
        (cond ((procedure? default)
               (let ((value (default window)))
                 (and (string? value) value)))
              ((string? default) default)
              (else #f))))

    (define (string-help-echo-at string position)
      ;; The `help-echo` property in the string drawn at POSITION - the
      ;; C's `Fget_text_property (pos, Qhelp_echo, string)` with its
      ;; clamp (`xdisp.c:36732`: "CHARPOS can be beyond the last position
      ;; of STRING due, e.g., to min-width `display' property").
      ;;--------------------------------------------------------------
      (let ((n (string-length string)))
        (and (> n 0)
             (get-text-property (min (max position 0) (- n 1))
                                'help-echo string))))

    (define (text-help-echo-at window position)
      ;; The help echo of the buffer text at POSITION, as
      ;; `(HELP WINDOW OBJECT POS)` - the C's `check_help_echo`
      ;; (`xdisp.c:37583`): the highest-priority overlay with the
      ;; property first, then the text property. OBJECT is the overlay
      ;; when one answered, the buffer otherwise.
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (with-current-buffer buffer
          (let loop ((overlays (overlays-at position #t)))
            (cond
             ((null? overlays)
              (let ((help (get-text-property position 'help-echo buffer)))
                (and help (list help window buffer position))))
             ((overlay-get (car overlays) 'help-echo)
              (list (overlay-get (car overlays) 'help-echo)
                    window (car overlays) position))
             (else (loop (cdr overlays))))))))

    (define (help-echo-at posn)
      ;; What POSN is over, as `(HELP WINDOW OBJECT POS)` or #f. The
      ;; string case is `note_line_or_margin_highlight`'s
      ;; (`xdisp.c:36749`), and the mode-line fallback is its
      ;; `w->mode_line_help_echo` arm: only the mode line has one, and
      ;; its object is nil with position -1.
      ;;--------------------------------------------------------------
      (let ((window (posn-window posn))
            (area (posn-area posn))
            (string-pos (posn-string posn)))
        (cond
         ((pair? string-pos)
          (let ((string (car string-pos))
                (position (cdr string-pos)))
            (cond
             ((string-help-echo-at string position)
              => (lambda (help) (list help window string position)))
             ((and (eq? area 'mode-line) (window-type? window))
              (let ((help (window-mode-line-help-echo window)))
                (and help (list help window #f -1))))
             (else #f))))
         ;; "If the mouse is on a part of the mode line without any text
         ;; (e.g. past the right edge of the mode line text), use that
         ;; window's mode line help echo if it has been set"
         ;; (`xdisp.c:36741`). The C reaches this arm with STRING being
         ;; nil, which is a posn with no `posn-string` here.
         ((and (eq? area 'mode-line) (window-type? window))
          (let ((help (window-mode-line-help-echo window)))
            (and help (list help window #f -1))))
         ((and (window-type? window) (integer? (posn-point posn)))
          (text-help-echo-at window (posn-point posn)))
         (else #f))))

    (define (clear-help-echo!)
      ;; The C's leave path (`pgtkterm.c`'s button/leave handlers store a
      ;; nil help event): tell the display there is no help any more.
      ;; The front end calls this when the pointer leaves the frame; a
      ;; motion to a position with no help reaches the same state through
      ;; `note-mouse-highlight`.
      ;;--------------------------------------------------------------
      (when %help-echo-previous
        (let ((show (*show-help-echo-function*)))
          (when show (show #f #f #f #f))))
      (set! %help-echo-previous #f))

    (define (%note-help-echo help-entry)
      ;; Hand HELP-ENTRY to the display when the C would generate a help
      ;; event: the new value or the previous one is non-nil. A repeat of
      ;; the same help goes out again, because the C does too - the
      ;; deduplication is `tooltip-show-help`'s `(equal previous-help
      ;; msg)`, which keeps a repeated string from restarting the
      ;; tooltip's delay.
      ;;--------------------------------------------------------------
      (when (or help-entry %help-echo-previous)
        (let ((show (*show-help-echo-function*)))
          (when show
            (show (and help-entry (car help-entry))
                  (and help-entry (cadr help-entry))
                  (and help-entry (caddr help-entry))
                  (and help-entry (cadddr help-entry))))))
      (set! %help-echo-previous help-entry))

    (define (note-mouse-highlight frame x y)
      ;; GNU Emacs's `note_mouse_highlight` (`xdisp.c:37061`): what the
      ;; `mouse-face` machinery runs on every pointer movement - "If the
      ;; mouse moved onto or out of a mouse-face region, start displaying
      ;; the highlighted text on FRAME". X and Y are in the display's
      ;; coordinate unit - `posn-at-x-y`'s, which is cells where the C
      ;; reads pixels - and negative ones mean the pointer has gone,
      ;; which is the C's `note_mouse_highlight (frame, -1, -1)`.
      ;;
      ;; The face is the `default` face with the `mouse-face` value
      ;; merged over it, computed once at the position under the pointer -
      ;; `attrs-at-buffer-position` then paints the whole run with it
      ;; while `*drawing-window*` is the window it belongs to.
      ;;
      ;; Answers #t when the highlight changed and the screen has to be
      ;; redrawn. **Departure**: Emacs paints the run from here
      ;; (`show_mouse_face` draws into the current output); this marks
      ;; the window's matrix stale and redraws, because the unit of
      ;; painting in this renderer is the frame.
      ;;
      ;; **Departure**: a position below the last line of text answers
      ;; the end of that line (`buffer_posn_from_coords` does the same),
      ;; so a `mouse-face` run ending at `point-max` stays lit while the
      ;; pointer is on the blank rows under it. Emacs finds no glyph
      ;; there and clears.
      ;;--------------------------------------------------------------
      (let* ((gone? (or (not frame) (< x 0) (< y 0)))
             (posn (and (not gone?) (posn-at-x-y x y frame)))
             (window (and posn (posn-window posn)))
             (position (and posn (posn-point posn)))
             ;; What the pointer is over, for the tooltip. Emacs sets the
             ;; help variables before the cursor decision and the face
             ;; work, and identical positions go out again - see
             ;; `%note-help-echo`.
             (help-entry (and (not gone?) posn (help-echo-at posn)))
             (run (and mouse-highlight
                       (window-type? window)
                       (integer? position)
                       (mouse-face-at window position)))
             ;; **A mode line is not a buffer position at all** - the posn
             ;; has no `posn-point' - it has the *drawn string* and the
             ;; character in it (`store_mode_line_string`), and that is
             ;; where `bindings.el`'s mode-line items keep their
             ;; `mouse-face`. Emacs's `note_line_or_margin_highlight`
             ;; takes the same two cases: a buffer position, or a string
             ;; and a character in it.
             (string-run
              (and mouse-highlight
                   (pair? posn)
                   (eq? (posn-area posn) 'mode-line)
                   (let ((s (posn-string posn)))
                     (and (pair? s)
                          (string-mouse-face-at (car s) (cdr s)))))))
        ;; The help echo is not gated on `mouse-highlight` in the C
        ;; either: that variable only decides whether text lights up.
        (%note-help-echo help-entry)
        ;; The pointer's shape, before the face: the C's `set_cursor` is
        ;; the last thing `note_mouse_highlight` does, but it is the part
        ;; that has nothing to do with `mouse-highlight`, and a mode line
        ;; resized by the pointer is exactly this. A negative position is
        ;; the pointer leaving: the C returns without changing the shape.
        (unless gone?
          (note-frame-cursor frame posn run))
        (let ((changed?
               (cond
                ((or gone? (not mouse-highlight)) (clear-mouse-face!))
                (string-run
                 (let ((value (car string-run))
                       (string (car (posn-string posn))))
                   (if (and (eq? window %mouse-face-window)
                            (eq? string %mouse-face-string)
                            (= (cadr string-run) %mouse-face-beg)
                            (= (caddr string-run) %mouse-face-end)
                            (equal? value %mouse-face-attrs))
                       #f
                       (begin
                         (unless (eq? window %mouse-face-window)
                           (clear-mouse-face!))
                         (set! %mouse-face-window window)
                         (set! %mouse-face-string string)
                         (set! %mouse-face-beg (cadr string-run))
                         (set! %mouse-face-end (caddr string-run))
                         ;; The *value*, not a merged vector: the mode
                         ;; line merges it over the glyph's own face -
                         ;; `face_at_string_position` with MOUSE true and
                         ;; `glyph->face_id` as the base (`xdisp.c:36955`)
                         ;; - where the buffer-text branch below merges
                         ;; over the default face, as the C does there.
                         (set! %mouse-face-attrs value)
                         (mark-window-display-accurate-1 window #f)
                         #t))))
                ((or (not (window-type? window)) (not run))
                 (clear-mouse-face!))
                (else
                 (let ((attrs
                        (merge-face-ref
                         (car run)
                         (merge-face-ref 'default (face-attributes-empty)))))
                   (if (and (eq? window %mouse-face-window)
                            (not %mouse-face-string)
                            (= (cadr run) %mouse-face-beg)
                            (= (caddr run) %mouse-face-end)
                            (equal? attrs %mouse-face-attrs))
                       #f
                       (begin
                         (unless (eq? window %mouse-face-window)
                           (clear-mouse-face!))
                         (set! %mouse-face-window window)
                         (set! %mouse-face-string #f)
                         (set! %mouse-face-beg (cadr run))
                         (set! %mouse-face-end (caddr run))
                         (set! %mouse-face-attrs attrs)
                         (mark-window-display-accurate-1 window #f)
                         #t)))))))
          (when (and changed? (not (*redisplay-in-progress*)))
            (redisplay-frames!))
          changed?)))

    ;;----------------------------------------------------------------
    ;; The menu bar's two hooks - `xdisp.c`'s own, not `menu-bar.el`'s
    ;;------------------------------------------------------------------
    ;;
    ;; `set_frame_menubar` runs both before it recomputes the bar
    ;; (`xmenu.c:994-1000`): `activate-menubar-hook` first - the Lucid
    ;; hook, which lets a package *set* the bar wholesale - and then
    ;; `menu-bar-update-hook`, where a menu that rebuilds itself
    ;; registers (`menu-bar.el` puts `menu-bar-update-buffers` there).
    ;; They are `xdisp.c`'s DEFVARs (`:39113`, `:39128`), so they live
    ;; here rather than with the menus that use them.

    (define *activate-menubar-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `activate-menubar-hook' (`xdisp.c:39128').

    (define *menu-bar-update-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `menu-bar-update-hook' (`xdisp.c:39113'): "Hook run
    ;; before displaying a menu bar, usually to make the menu contents up
    ;; to date. Each function is called with no args and should update
    ;; the frame's menu bar contents."

    (define *menu-bar-items-function* (make-parameter #f))

    (define *tab-bar-items-function* (make-parameter #f))
    ;; ^ `tab_bar_items` is `keyboard.c`'s, in the library above this
    ;; one, so the redisplay asks for the tab bar's items through a seam
    ;; as it does for the menu bar's.

    (define *tab-bar-keymap-function* (make-parameter #f))
    ;; ^ `tab-bar-make-keymap` (`tab-bar.el`) is what the C reaches
    ;; through the `[tab-bar]' binding's `:filter`, and that library is
    ;; above this one too.
    ;; ^ `menu_bar_items' (`keyboard.c:8641'), as a seam.
    ;;
    ;; **A departure, and the same one `*record-window-buffer-function*`
    ;; is.** In Emacs this file calls `menu_bar_items` across files; here
    ;; the redisplay is `xdisp.scm` and the bar's items are
    ;; `keyboard.scm`'s, which imports this library - so the edge would
    ;; be a cycle. `keyboard.scm` installs its own `menu-bar-items` at
    ;; load time, and nothing else sets it.

    (define *inhibit-menubar-update* (make-parameter #f))
    ;; ^ GNU Emacs's `inhibit_menubar_update` (`xdisp.c:14406'): "If
    ;; called recursively during a menu update, do nothing. This can
    ;; happen when, for instance, an `activate-menubar-hook` causes a
    ;; redisplay."

    (define (update-menu-bar frame)
      ;; GNU Emacs's `update_menu_bar` (`xdisp.c:14422'): recompute the
      ;; frame's menu bar items before the frame is drawn.
      ;;
      ;; **The terminal's half only.** A window-system frame's bar is
      ;; rebuilt by its own backend (`set_frame_menubar`, which this
      ;; tree's gtk front end does in its `flush-display!`); a terminal's
      ;; bar is a row of text this redisplay draws, so its items are this
      ;; redisplay's to build.
      ;;
      ;; The hooks run *here* for the same reason `set_frame_menubar` runs
      ;; them there: they are what makes a bar whose contents change with
      ;; the buffer - the Buffers menu - current at the moment it is
      ;; drawn.
      ;;
      ;; **And for the reason `set_frame_menubar` runs them only sometimes
      ;; too.** `redisplay_window` reaches that function for a window whose
      ;; `update_mode_line` is set (`xdisp.c:21522`), and `update_menu_bar`
      ;; has the same guard of its own (`xdisp.c:14449`); the hooks and the
      ;; item read are the expensive part of this function. A bar that has
      ;; never been built falls through, so the first redisplay draws it.
      ;;--------------------------------------------------------------
      (when (and (not (window-system-display? (current-display)))
                 (> (%frame-menu-bar-lines frame) 0)
                 (*menu-bar-items-function*)
                 (not (*inhibit-menubar-update*))
                 (or (windows-or-buffers-changed?)
                     (update-mode-lines?)
                     (= 0 (frame-menu-bar-items-used frame))))
        (parameterize ((*inhibit-menubar-update* #t))
          (run-hooks (*activate-menubar-hook*))
          (run-hooks (*menu-bar-update-hook*))
          (let* ((items ((*menu-bar-items-function*)))
                 (vector (make-vector (* 4 (length items)) #f)))
            (let loop ((rest items) (i 0))
              (unless (null? rest)
                (let ((quad (car rest)))
                  (vector-set! vector i (list-ref quad 0))
                  (vector-set! vector (+ i 1) (list-ref quad 1))
                  (vector-set! vector (+ i 2) (list-ref quad 2))
                  (vector-set! vector (+ i 3) 0)
                  (loop (cdr rest) (+ i 4)))))
            (set!frame-menu-bar-items frame vector)
            ;; **The slot count**, not the item count: Emacs's
            ;; `menu_bar_items_used` is `ASIZE` of the vector and the
            ;; walk below steps four slots at a time. Storing the item
            ;; count here made the bar draw one item and stop.
            (set!frame-menu-bar-items-used frame (* 4 (length items)))))))

    (define (update-tab-bar frame)
      ;; GNU Emacs's `update_tab_bar` (`xdisp.c:14291`): recompute the
      ;; frame's tab bar items before the frame is drawn.
      ;;
      ;; **The terminal's half only**, for the reason `update-menu-bar`
      ;; gives: a window-system frame's tab bar is its toolkit's.
      ;;
      ;; **The keymap is rebuilt first.** The C reaches the tab bar's
      ;; keymap through `[tab-bar]`'s `:filter` (`get_keyelt`'s
      ;; `menu_item_eval_property` arm), and this tree's keymap lookup
      ;; does not apply filters - the evaluating function is
      ;; `keyboard.c`'s and `keymap.scm` is below it. The filter's work
      ;; is done here instead: `tab-bar-make-keymap` is asked for the
      ;; current keymap and the walk below then finds it as it finds any
      ;; other binding. A named departure, and the observable result is
      ;; the C's.
      ;;--------------------------------------------------------------
      ;; **Drawn on a toolkit frame too, as Emacs draws it.** GNU
      ;; Emacs's Gtk build has no tab-bar widget; its redisplay draws
      ;; the bar into `f->tab_bar_window` below the menu bar, and this
      ;; tree draws it as the first row of the text area on both kinds
      ;; of display (see `frame-top-margin`). So there is no
      ;; window-system guard here - unlike `update-menu-bar`, whose bar
      ;; *is* a toolkit widget.
      (when (and (> (%frame-tab-bar-lines frame) 0)
                 (*tab-bar-items-function*)
                 (or (windows-or-buffers-changed?)
                     (update-mode-lines?)
                     (= 0 (frame-tab-bar-items-used frame))))
        (let* ((items ((*tab-bar-items-function*)))
               ;; `TAB_BAR_ITEM_NSLOTS` is 6 - KEY, ENABLED, SELECTED,
               ;; CAPTION, BINDING, HELP (`dispextern.h:3408`) - where the
               ;; menu bar's item has 5.
               (vector (make-vector (* 6 (length items)) #f)))
          (let loop ((rest items) (i 0))
            (unless (null? rest)
              (let ((quad (car rest)))
                (vector-set! vector i (list-ref quad 0))
                (vector-set! vector (+ i 1) (list-ref quad 1))
                (vector-set! vector (+ i 2) (list-ref quad 2))
                (vector-set! vector (+ i 3) (list-ref quad 3))
                (vector-set! vector (+ i 4) (list-ref quad 4))
                (vector-set! vector (+ i 5) (list-ref quad 5))
                (loop (cdr rest) (+ i 6)))))
          (set!frame-tab-bar-items frame vector)
          (set!frame-tab-bar-items-used frame (* 6 (length items))))))

    (define *tool-bar-items-function* (make-parameter #f))

    (define *tool-bar-keymap-function* (make-parameter #f))
    ;; ^ `tool_bar_items` (`keyboard.c`) and `tool-bar-make-keymap`
    ;; (`tool-bar.el`), both above this library, so the redisplay asks
    ;; for them through seams as it does for the other two bars. The
    ;; keymap is what the C reaches through `[tool-bar]`'s `:filter`
    ;; (`get_keyelt`'s `menu_item_eval_property` arm), and this tree's
    ;; keymap lookup does not apply filters - the same departure
    ;; `*tab-bar-keymap-function*` records.

    (define (update-tool-bar frame)
      ;; GNU Emacs's `update_tool_bar` (`xdisp.c:15673`): recompute the
      ;; frame's tool bar items before the frame is drawn.
      ;;
      ;; Under `HAVE_EXT_TOOL_BAR` - which a Gtk build is - the only
      ;; thing this does is fill `f->tool_bar_items`; the toolkit widget
      ;; is rebuilt from it by the front end (`update_frame_tool_bar`,
      ;; `gtkutil.c:5843`), and the glyph-drawing half of the C is not
      ;; compiled at all. A terminal frame in such a build therefore has
      ;; no tool bar, which is `emacs -nw`'s behaviour: the row-drawing
      ;; code exists only in builds with no toolkit bar.
      ;;
      ;; **Emacs reads the items with the frame selected and its
      ;; selected window's buffer current** (`set_buffer_internal_1`
      ;; with `selected_frame`/`selected_window` saved and restored
      ;; around it), "because the calculation of the tool-bar keymap
      ;; uses the selected frame" (`xdisp.c:15740`) -
      ;; `tool-bar-make-keymap` asks
      ;; `(frame-parameter nil 'tool-bar-position)`. The bindings below
      ;; are that extent, and they matter because `render!` draws frames
      ;; other than the selected one too.
      ;;
      ;; The guard is the menu bar's (`xdisp.c:15713`): a keystroke that
      ;; changed nothing does not re-parse a bar.
      ;;--------------------------------------------------------------
      (when (and ;; `FRAME_EXTERNAL_TOOL_BAR (f)`: the C's `do_update`
                 ;; under `HAVE_EXT_TOOL_BAR` (`xdisp.c:15676`). A
                 ;; terminal frame in a Gtk build never gets it - the
                 ;; parameter handler that packs the widget is the Gtk
                 ;; one - so it computes no items at all, which is why
                 ;; `emacs -nw` has no tool bar rather than an
                 ;; invisible one.
                 (window-system-display? (frame-output frame))
                 (> (%frame-tool-bar-lines frame) 0)
                 (*tool-bar-items-function*)
                 (or (windows-or-buffers-changed?)
                     (update-mode-lines?)
                     (= 0 (frame-tool-bar-items-used frame))))
        (let ((window (frame-selected-window frame)))
          (parameterize ((*current-frame* frame)
                         (*current-buffer* (and window (window-buffer window)))
                         (*selected-window-override* window))
            (let ((vector (list->vector
                           (apply append ((*tool-bar-items-function*))))))
              ;; "Redisplay the tool-bar if we changed it."
              (let ((old (frame-tool-bar-items frame)))
                (unless (and old
                             (= (vector-length vector) (vector-length old))
                             (equal? vector old))
                  (set!frame-tool-bar-items frame vector)
                  ;; The slot count, as `frame-menu-bar-items-used`
                  ;; stores it: twelve per item.
                  (set!frame-tool-bar-items-used frame
                                                 (vector-length vector)))))))))

    (define tool-bar-style #f)
    ;; ^ GNU Emacs's `tool-bar-style` (a DEFVAR in `xdisp.c:39003`):
    ;; "Tool bar style to use. It can be one of image - show images only;
    ;; text - show text only; both - show both, text below image;
    ;; both-horiz - show text to the right of the image; text-image-horiz
    ;; - show text to the left of the image; any other - use system
    ;; default or image if no system default." A plain variable - nothing
    ;; `let`-binds it - with the self-assignment a user's `set!` needs
    ;; against the compiler's constant folding.
    (set! tool-bar-style tool-bar-style)

    (define *tool-bar-system-style-function* (make-parameter #f))
    ;; ^ Emacs's `current_tool_bar_style` (`xsettings.c:71`) is a C
    ;; variable filled from the desktop's own setting
    ;; (`org.gnome.desktop.interface`'s `toolbar-style`, `:227`) by the
    ;; toolkit build. This tree's editor core does not talk to a desktop
    ;; setting - only a front end can - so the read arrives through this
    ;; seam, which the Gtk front end installs with the GSettings reader
    ;; (`pgtk.scm`). `#f` means "no system style known", which is what
    ;; Emacs answers on a desktop that has no such setting.

    (define (tool-bar-get-system-style)
      ;; GNU Emacs's `tool-bar-get-system-style` (a DEFUN in
      ;; `xsettings.c:1348`): "Get the system tool bar style. If no
      ;; system tool bar style is known, return `tool-bar-style' if set
      ;; to a known style. Otherwise return image."
      ;;
      ;; Emacs's order: an explicitly set `tool-bar-style` wins; else
      ;; the desktop's setting; else `image`. Its Gtk build reads the
      ;; setting through GSettings, which on a GNOME-style desktop is
      ;; usually `both-horiz` - which is why Emacs's tool bar shows a
      ;; text label beside every icon and this tree's used not to.
      ;;--------------------------------------------------------------
      (if (memq tool-bar-style
                '(image text both both-horiz text-image-horiz))
          tool-bar-style
          (or (and (*tool-bar-system-style-function*)
                   ((*tool-bar-system-style-function*)))
              'image)))

    (define (display-tab-bar frame)
      ;; GNU Emacs's `display_tab_bar` (`xdisp.c:14696`) for a terminal:
      ;; "an ordinary screen line" drawn *below* the menu bar - the C's
      ;; iterator starts at `(FRAME_MENU_BAR_LINES (f) > 0 ? 1 : 0)`
      ;; (`:14717`) - with the `tab-bar` face, each item's caption laid
      ;; out left to right and its starting column recorded for the
      ;; click (`make_lispy_event`'s tty tab-bar branch reads the same
      ;; slots `display-menu-bar` records).
      ;;
      ;; The captions are strings with `face` properties of their own
      ;; (`tab-bar-tab` for the current tab, `tab-bar-tab-inactive` for
      ;; the rest), which `draw-mode-line!` draws run by run - the same
      ;; drawer the mode line and the tab line use.
      ;;--------------------------------------------------------------
      (let* ((dsp (current-display))
             (items (frame-tab-bar-items frame))
             (used (frame-tab-bar-items-used frame))
             (width (frame-width frame))
             ;; **The tab bar sits below the menu bar's rows** - and on a
             ;; toolkit frame those are *zero* rows (the bar is a widget),
             ;; so the offset is the top margin minus the tab bar's own
             ;; lines, not `%frame-menu-bar-lines` (whose default is 1).
             (y (row->pixel-y (- (frame-top-margin frame)
                                 (%frame-tab-bar-lines frame))))
             (text
              (let loop ((i 0) (x 0) (acc ""))
                (if (>= i used)
                    acc
                    (let* ((name (vector-ref items (+ i 3)))
                           ;; **`(space :align-to N)`**: a caption whose
                           ;; `display` property says where it starts is
                           ;; padded to that column - what
                           ;; `tab-bar-format-align-right` builds, and
                           ;; what the C's renderer honours through
                           ;; `display_string`'s `:align-to`. The unit is
                           ;; this renderer's, a cell.
                           (spec (get-text-property 0 'display name))
                           (target (and (pair? spec) (eq? (car spec) 'space)
                                        (pair? (cdr spec))
                                        (eq? (cadr spec) ':align-to)
                                        (caddr spec)))
                           (pad (if (and target (number? target))
                                    (max 0 (- target x))
                                    0)))
                      ;; **The spec replaces the character it is on**, as
                      ;; `(space :align-to N)` does in the C's
                      ;; `display_string`: the caption *is* the padding
                      ;; and nothing else, so the next item starts at
                      ;; column N. Drawing the space as well put the next
                      ;; item one column past the frame's edge.
                      ;; **`concat`, not `string-append`.** The C's
                      ;; renderer copies each caption with its text
                      ;; properties (`store_mode_line_string` adds the
                      ;; element's properties and `display_string` keeps
                      ;; them), and `tab-bar-format` leans on that:
                      ;; `tab-bar-tab-name-format-face` puts the current
                      ;; tab's `tab-bar-tab` face and the others'
                      ;; `tab-bar-tab-inactive` on the caption, and the
                      ;; close button's `close-tab` property and a menu
                      ;; item's `menu-item` property too. `string-append`
                      ;; builds a fresh string and drops all of it - so
                      ;; every tab was drawn in the bar's own face and
                      ;; looked alike. This is the same rule the mode
                      ;; line and the tab line follow.
                      (if target
                          (loop (+ i 6) (+ x pad)
                                (concat acc
                                        (if (> pad 0)
                                            (make-string pad #\space)
                                            "")))
                          (loop (+ i 6) (+ x (menu-item-width name))
                                (concat acc name))))))))
        (draw-mode-line! (concat
                          text (make-string (max 0 (- width (string-length text)))
                                            #\space))
                         'tab-bar y 0)))

    (define (menu-item-width string)
      ;; GNU Emacs's `menu_item_width` (`menu.c:1027`): the width of a
      ;; menu item in *cells* - `CHARACTER_WIDTH` per character, so a
      ;; wide character counts two. The display's `line-display-width` is
      ;; the same measure, which is why it is used here.
      ;;--------------------------------------------------------------
      (line-display-width string))

    (define (invalidate-frame-rows! frame covered)
      ;; FRAME's screen no longer holds what its glyph matrices say, for
      ;; the rows in COVERED - a list of `(Y . HEIGHT)` - because the
      ;; terminal wrote over them.
      ;;
      ;; This is the half of `screen_update` that Emacs gets from its
      ;; *saved glyph matrix*: `restore_desired_matrix` puts the rows
      ;; back into the desired matrix and `update_frame_with_menu` diffs
      ;; them against the current one, so only the cells that differ are
      ;; written. This tree keeps no frame matrix, but the per-window
      ;; current matrices *are* the screen-behind for the text rows, so
      ;; the same effect comes from invalidating exactly the rows the
      ;; menu covered: `update_window` then rewrites those rows and
      ;; skips every other one. The mode line, the echo area and the menu
      ;; bar are redrawn by every redisplay anyway.
      ;;
      ;; **Row granularity, not cell** - `update_text_area` is still not
      ;; ported, so a row is this redisplay's smallest unit. That is the
      ;; existing departure, not a new one.
      ;;--------------------------------------------------------------
      (define (row-covered? row)
        (let loop ((rest covered))
          (and (pair? rest)
               (or (and (>= row (car (car rest)))
                        (< row (+ (car (car rest)) (cdr (car rest)))))
                   (loop (cdr rest))))))
      (for-each
       (lambda (w)
         ;; A minibuffer window's one row is the echo area, redrawn whole
         ;; by every redisplay; there is no matrix of its text to spoil.
         (unless (window-minibuffer-p w)
           (let ((top (window-top w))
                 (body (window-body-height w))
                 (m (window-current-matrix w)))
             (when (and m (window-buffer w))
               (let loop ((i 0) (hit #f))
                 (if (>= i body)
                     ;; Only a window that lost a row is marked: one that
                     ;; kept all of its own is left to the skip.
                     (when hit (mark-window-display-accurate-1 w #f))
                     (let ((row (glyph-matrix-row-ref m i)))
                       (when (and row (row-covered? (+ top i)))
                         ;; `!current_row->enabled_p` is the diff's own
                         ;; "the screen is not this" test.
                         (set-glyph-row-enabled! row #f)
                         (set! hit #t))
                       (loop (+ i 1) hit))))))))
       (window-list frame)))

    (define (display-menu-bar frame)
      ;; GNU Emacs's `display_menu_bar` (`xdisp.c:27756`), for the
      ;; terminal: the bar is "an ordinary screen line", drawn with the
      ;; `menu` face, and each item's column is recorded in the vector for
      ;; `menu-bar-menu-at-x-y`.
      ;;
      ;; Each item is followed by one space (the C displays
      ;; `SCHARS (string) + 1' characters), and the rest of the row is
      ;; filled out in the menu face - `extend_face_to_end_of_line`.
      ;;--------------------------------------------------------------
      (let* ((dsp (current-display))
             (items (frame-menu-bar-items frame))
             (used (frame-menu-bar-items-used frame))
             (width (frame-width frame))
             (token (face->attribute 'menu))
             (y (row->pixel-y 0)))
        (write-run! dsp (list (make-string (max 1 width) #\space)) y 0
                    token)
        (let loop ((i 0) (x 0))
          (when (< i used)
            (let ((name (vector-ref items (+ i 1))))
              ;; "Remember where item was displayed."
              (vector-set! items (+ i 3) x)
              (let ((text (string-append name " ")))
                (when (< x width)
                  (write-run! dsp (list text) y x token))
                (loop (+ i 4) (+ x (menu-item-width text)))))))))

    (define (display-tty-menu-separator text width)
      ;; GNU Emacs's `display_tty_menu_separator` (`xdisp.c:27967`): the
      ;; cells of a separator row - the `--space` blank, the
      ;; `--double-line` rule of `=`, or a rule of `-`.
      ;;
      ;; The C reads `standard-display-table`'s box glyphs for the rule;
      ;; nothing here sets one, so the characters are the C's own
      ;; defaults. Answers WIDTH cells: the rule is WIDTH-2 long and is
      ;; padded to the one cell short of WIDTH that the left space leaves
      ;; - which is `Fmake_string (width - 1)` then `display_string (...
      ;; width ...)` in the C.
      ;;--------------------------------------------------------------
      (let ((c (cond ((string=? text "--space") #\space)
                     ((string=? text "--double-line") #\=)
                     (else #\-))))
        (string-append " " (make-string (max 0 (- width 2)) c) " ")))

    (define (display-tty-menu-item display text width token x y submenu
                                   separator?)
      ;; GNU Emacs's `display_tty_menu_item` (`xdisp.c:28003`): one menu
      ;; line at row Y, column X, WIDTH cells wide - "pad with a space on
      ;; the left, display the menu item, pad with spaces to WIDTH", and
      ;; `" >"` when the item opens a submenu.
      ;;
      ;; **Two departures, both because there is no glyph matrix.** The C
      ;; writes into `f->desired_matrix` and lets `update_frame_with_menu`
      ;; deliver the result; a terminal here *is* the screen, so the row
      ;; is written where it goes. And SEPARATOR? is passed in rather
      ;; than tested here: the predicate is `menu_separator_name_p`
      ;; (`keyboard.c:8608`) and that library is above this one. The
      ;; layout is the C's, cell for cell.
      ;;--------------------------------------------------------------
      (let* ((line (if separator?
                       (display-tty-menu-separator text width)
                       (let* ((pad (max 0 (- width 1 (menu-item-width text)
                                             (if submenu 2 0)))))
                         (string-append " " text
                                        (if submenu " >" "")
                                        (make-string pad #\space))))))
        (write-run! display (list line) (row->pixel-y y) x token)))

    ;;----------------------------------------------------------------
    ;; The `*Messages*' buffer - `message_dolog' and what feeds it
    ;;------------------------------------------------------------------

    (define *messages-buffer-name* (make-parameter "*Messages*"))
    ;; ^ GNU Emacs's `messages-buffer-name' (`xdisp.c:38597'): "Name of
    ;; the buffer in which `message' logs its messages."

    (define *message-log-max* (make-parameter 1000))
    ;; ^ GNU Emacs's `message-log-max' (`xdisp.c:38859'): "Maximum number
    ;; of lines to keep in the `*Messages*' buffer. If nil, disable
    ;; message logging." It was declared in `editfns.scm' until
    ;; 2026-10-14 - "the variable waiting for the buffer" - and both it
    ;; and the name above are `xdisp.c`'s: `Fmessage' reads neither, and
    ;; `message-dolog' below reads both.

    (define (message--back-lines from count)
      ;; `scan_newline (FROM, BEG, COUNT)' (`search.c:986'), which is
      ;; `find_newline' with the byte arguments -1: "Move COUNT line
      ;; boundaries back from FROM", stopping at the buffer's beginning.
      ;;
      ;; The C moves point; here the position comes back and the callers
      ;; say where point goes, which is the tree's convention for a scan.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (find-newline (current-buffer) from count (point-min)))
        (lambda (pos found) pos)))

    (define (message--times tail)
      ;; The N of the C's `sprintf (dupstr, " [%"PRIdMAX" times]", dups)'
      ;; read back - `strtoimax' and the `" times]\n"' after it
      ;; (`xdisp.c:12465'), which is how a folded line says how many times
      ;; it happened. #f when TAIL is not that.
      ;;--------------------------------------------------------------
      (and (>= (string-length tail) 10)
           (string=? (substring tail 0 2) " [")
           (let loop ((i 2))
             (cond ((>= i (string-length tail)) #f)
                   ((char-numeric? (string-ref tail i)) (loop (+ i 1)))
                   ;; `" times]"' is **seven** characters - space, t, i, m,
                   ;; e, s, ] - and the C wants the newline after it, so a
                   ;; match spans i .. i+8.
                   ((and (> i 2)
                         (<= (+ i 8) (string-length tail))
                         (string=? (substring tail i (+ i 7)) " times]")
                         (char=? (string-ref tail (+ i 7)) #\newline))
                    ;; **`n + 1', the C's own return**: a line already
                    ;; saying " [n times]" has now been seen n+1 times
                    ;; (`xdisp.c:12568'), and the caller prints what it
                    ;; is handed. Returning N rather than N+1 left every
                    ;; count stuck at two.
                    (+ 1 (string->number (substring tail 2 i))))
                   (else #f)))))

    (define (message-log-check-duplicate prev-bol this-bol)
      ;; GNU Emacs's `message_log_check_duplicate' (`xdisp.c:12535'):
      ;; "See if this line duplicates the previous one. If so, combine
      ;; duplicates." 0 means no; anything else is the number of times the
      ;; line has now been seen.
      ;;
      ;; **The `...' rule is the C's own**: a line that *differs* still
      ;; counts as a duplicate when the previous one had `...' just before
      ;; the difference - a continued line is folded onto what it
      ;; continues. `seen_dots' is the C's bool, and it answers 1, not 2.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (len (- (buffer-z ed) 1 this-bol))
             (p1 prev-bol)
             (p2 this-bol))
        (let loop ((i 0) (seen-dots #f))
          (if (>= i len)
              ;; The whole of the new line matched, so the previous line is
              ;; at least as long: what follows it decides.
              (let ((tail (buffer-substring-no-properties
                           (+ p1 len) (min (buffer-z ed) (+ p1 len 32)))))
                (cond ((and (> (string-length tail) 0)
                            (char=? (string-ref tail 0) #\newline))
                       2)
                      (else (or (message--times tail) 0))))
              ;; **The C's `seen_dots' test is not exclusive with the
              ;; comparison** (`xdisp.c:12543'): at each index it first
              ;; looks back three characters for `...' *and then* compares
              ;; the two lines at that same index. Written as two `cond'
              ;; clauses the dots clause won and the comparison at that
              ;; index was skipped - so a line that differed exactly where
              ;; the dots ended ran to the end of the loop and the tail
              ;; check answered 0, and "abc...Q" did not fold onto
              ;; "abc...xyz" the way Emacs folds it.
              (let ((seen-dots (or seen-dots
                                   (and (>= i 3)
                                        (char=? (fetch-char ed (+ p1 (- i 3))) #\.)
                                        (char=? (fetch-char ed (+ p1 (- i 2))) #\.)
                                        (char=? (fetch-char ed (+ p1 (- i 1))) #\.)))))
                (if (not (char=? (fetch-char ed (+ p1 i)) (fetch-char ed (+ p2 i))))
                    (if seen-dots 1 0)
                    (loop (+ i 1) seen-dots)))))))

    (define (message-dolog text nlflag)
      ;; GNU Emacs's `message_dolog' (`xdisp.c:12340'): append TEXT to the
      ;; `*Messages*' buffer - the half of `message' that is not the echo
      ;; area: "The message also goes into the `*Messages*' buffer, if
      ;; `message-log-max' is non-nil."
      ;;
      ;; NLFLAG says the text is a whole line. Only a whole line is folded
      ;; against its predecessor, and only a whole line counts towards
      ;; `message-log-max'.
      ;;
      ;; The C switches to the buffer, does the work and switches back,
      ;; saving point and the restrictions with markers; `with-current-buffer'
      ;; is the same thing said once.
      ;;--------------------------------------------------------------
      (when (*message-log-max*)
        (let* ((name (if (string? (*messages-buffer-name*))
                         (*messages-buffer-name*)
                         "*Messages*"))
               (new? (not (get-buffer name)))
               ;; The C's `oldbuf' and `old_deactivate_mark' (`xdisp.c:12357'),
               ;; both read from the *edited* buffer before the switch.
               (old-buffer (current-buffer))
               (old-deactivate-mark
                (buffer-local-value old-buffer 'deactivate-mark #f)))
          ;; **The buffer is read-only and the log writes to it anyway.**
          ;; `messages-buffer-mode' is a `special-mode', which makes the
          ;; buffer read-only, and the C's `insert_1_both (..., prepare =
          ;; false, ...)' is what skips the check - `prepare_to_modify_buffer'
          ;; is the thing that consults `inhibit-read-only', so that is
          ;; what stands in for it here. `PREPARE false' skips the *whole*
          ;; of `prepare_to_modify_buffer', though, and the hooks with it
          ;; - "we aren't prepared to run modification hooks", the C's own
          ;; words at `:12431' - so `inhibit-modification-hooks' is bound
          ;; beside it. The flag that matters here is
          ;; `deactivate_mark': when the log buffer *is* the edited buffer
          ;; (`*Messages*' is the one buffer that always is), an
          ;; unprepared insert would clear the very region `C-SPC ... M-w'
          ;; is making, which is why Emacs saves and restores it below.
          (parameterize ((*inhibit-read-only* #t)
                         (*inhibit-modification-hooks* #t))
          (with-current-buffer (get-buffer-create name)
            ;; "If we created it, set the major-mode."
            (when new? (messages-buffer-mode))
            ;; **The log buffer's point is saved, and put back.**
            ;; `message_dolog` reads `PT == Z` first and restores point
            ;; at the end: at the end it follows the new text, anywhere
            ;; else it stays where it was - as a *marker*, so trimming
            ;; the oldest lines moves it back with the text it was on.
            ;;
            ;; Without this every message yanked point to the end of
            ;; `*Messages*`, and marking a line to copy it out ran
            ;; `(message "Mark set")`, which moved point again - so the
            ;; region could not be made.
            (let ((point-at-end? (= (point) (point-max)))
                  (old-point (point-marker)))
            ;; "This is safe because we don't have undo in this buffer" -
            ;; and it does not cache long scans, the C's second line.
            ;;
            ;; `#t' is Emacs's `Qt' here: this tree's `buffer-undo-list'
            ;; keeps Emacs's sentinel, and `text-editor-undo-recording?'
            ;; is the C's `!EQ (..., Qt)'.
            (set!text-editor-undo-list (current-buffer) #t)
            (set!text-editor-cache-long-scans (current-buffer) #f)
            (goto-char (point-max))
            (insert text)
            (when nlflag
              (insert "\n")
              (let ((this-bol (message--back-lines (point-max) -2)))
                ;; "See if this line duplicates the previous one."
                (when (> this-bol (point-min))
                  (let ((prev-bol (message--back-lines this-bol -2)))
                    (let ((dups (message-log-check-duplicate prev-bol this-bol)))
                      ;; **`(not (zero? dups))', and not `dups'.** The C's
                      ;; `if (dups)' is false for 0, and 0 is *true* in
                      ;; Scheme - so written as a bare test this deletes the
                      ;; previous line for a line that is *not* a duplicate
                      ;; as well, which is how the first line of the log
                      ;; disappeared.
                      (when (and dups (not (zero? dups)))
                        (delete-region prev-bol this-bol)
                        (when (> dups 1)
                          (goto-char (- (point-max) 1))
                          (insert " [" (number->string dups) " times]")))))))
              ;; "If we have more than the desired maximum number of lines
              ;; in the `*Messages*' buffer now, delete the oldest ones."
              (when (and (exact-integer? (*message-log-max*)) (>= (*message-log-max*) 0))
                (delete-region
                 (point-min)
                 (message--back-lines (point-max)
                                      (- 0 (*message-log-max*) 1))))
              (if point-at-end?
                  (goto-char (point-max))
                  (goto-char (marker-position old-point)))
              (set-marker old-point #f)))))
          ;; `Vdeactivate_mark = old_deactivate_mark' (`xdisp.c:12526'),
          ;; written back after `set_buffer_internal (oldbuf)' - the
          ;; edited buffer's own flag, exactly as it was found.
          (set-buffer-local-value! old-buffer 'deactivate-mark
                                   old-deactivate-mark))))

    (define (log-message text)
      ;; GNU Emacs's `log_message' (`xdisp.c:12569'), the half of
      ;; `message3' that runs before the display: log TEXT if it is a
      ;; string, and do nothing at all if it is not - which is how
      ;; `message3_nolog''s empty case leaves the log alone.
      ;;
      ;; The C also clears the echo area and cancels the echoing here.
      ;; That side is the frame's in this tree and `editfns.scm` does it
      ;; at the display, one statement later.
      ;;
      ;; Not ported: `message_log_maybe_newline', which flushes a partial
      ;; line written by `print' - there is no `print' to the echo area
      ;; here.
      ;;--------------------------------------------------------------
      (when (string? text)
        (message-dolog text #t)))

    ;; The seam the log arrives through: `editfns.scm`'s `message` calls
    ;; this before it displays, as `message3' calls `log_message'.
    (*message-log-function* log-message)

    ;; **The scroll seam** (`frame.scm`'s `*window-scroll-function*`):
    ;; `scroll-up-command` is `simple.el`'s and a screen line is this
    ;; library's, so the command calls through here. Installed at load.
    (*window-scroll-function* window-scroll)

    ;; **The redisplay seam** (`frame.scm`'s
    ;; `*mark-window-redisplay-function*`): `set-window-scroll-bars` is
    ;; `window.c`'s and the glyph matrix is this library's, so marking a
    ;; window for redisplay goes through here. Installed at load.
    (*mark-window-redisplay-function*
     (lambda (window) (mark-window-display-accurate-1 window #f)))

    ;; **The point-position seam** (`subr.scm`'s
    ;; `*event--posn-at-point-function*`): `event-start` and `event-end`
    ;; answer the posn at point for anything that is not a mouse event,
    ;; as `subr.el` does, and the window it needs is here. Installed at
    ;; load; a caller outside a running display keeps the old #f.
    (*event--posn-at-point-function* event--posn-at-point)

    ))
