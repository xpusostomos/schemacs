(define-library (schemacs editor xdisp)
  ;; This library mirrors GNU Emacs's `xdisp.c': the redisplay. It draws
  ;; each window's rows of text, its mode line and the vertical border
  ;; beside it, then the echo area, then places the terminal cursor. What
  ;; it draws is derived entirely from state it can reach without knowing
  ;; about editing: the buffers the windows show, where their points are,
  ;; and the frame's echo area.
  ;;
  ;; Two things make that true, and both are why this library comes when
  ;; it does. The echo area's buffer and prompt are read from the frame
  ;; (`*echo-area-buffer*', `*echo-area-prompt*'), which is where GNU
  ;; Emacs keeps them, so the renderer has nothing to ask a minibuffer.
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
    (only (guile) delq filter sort inexact->exact)
    ;; The display interface: the redisplay draws through these generics
    ;; and never touches a terminal itself. `dispnew.sld' defines them,
    ;; and `term.sld' answers them for the curses terminal.
    (only (schemacs editor dispnew)
          current-display
          write-glyphs! draw-box! face-metrics display-cell-size clear-frame-area!
          clear-end-of-line! ensure-surface!
          update-window-begin! update-window-end!
          draw-window-cursor! erase-window-cursor! flush-display!
          realize-face
          ;; how many pixels a cell is, which is what turns a mouse
          ;; event's coordinates into the cells the windows are
          ;; measured in - see `posn-at-x-y'.
          column-width line-height)
    ;; the markers, from marker.c's own library
    (only (schemacs editor marker) marker-position set-marker)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs editor intervals) make-buffer-string)
    
    ;; The line arithmetic is `editfns.c`'s, and it lives there now.
    (only (schemacs editor editfns)
         *message-log-function*
         buffer-substring-no-properties delete-region goto-char insert
         point point-max point-min
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
    (only (schemacs editor fns) concat)
    ;; `count-lines' is `xdisp.c''s own (`:29892') and reads straight from
    ;; this file's library - it is placed in `fns.scm' beside the
    ;; `line-number-at-pos' that wants it, because this library is the top
    ;; of the graph and a definition up here could not be reached from
    ;; below. See the note on it there.
    (only (schemacs editor fns) count-lines)
    (only (schemacs editor frame)
         *current-frame* *echo-area-buffer* *echo-area-prompt*
         *frame-cursor-type* *frame-focus* frame-height frame-width
         ;; `FRAME_GARBAGED_P` / `SET_FRAME_GARBAGED` (`frame.h:1173`),
         ;; consumed by `clear-garbaged-frames!`.
         frame-garbaged-p set-frame-garbaged! frame-minibuffer-window
         window-minibuffer-p
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
         sync-frame-size! window-body-height
         window-body-width window-buffer window-height window-left
         window-list
         ;; `WINDOW_XFRAME (w)': the frame a window is on, which is what
         ;; the drawing of a window asks when the frame being drawn is
         ;; not the selected one
         window-frame
         selected-window window-point window-right-border?
         window-top
         window-width
         ;; `w->start' and everything stored beside it: where the window's
         ;; display begins, where its last glyph was, and the line-number
         ;; cache `%l' counts from
         %window-start set-window-start!
         %window-end-pos %window-end-valid?
         set!%window-end-pos set!%window-end-vpos set!%window-end-valid?
         %window-base-line-number %window-base-line-pos
         set!%window-base-line-number set!%window-base-line-pos
         ;; `w->hscroll' and its friends, which the hscroll display and
         ;; auto hscrolling read and write
         %window-hscroll %window-min-hscroll
         %window-old-point %window-suspend-auto-hscroll?
         set!%window-hscroll
         set!%window-old-point set!%window-suspend-auto-hscroll?)
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
          line-texts-offsets line-texts-glyphs line-texts-slice-width
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
          get-text-property next-single-property-change)
    (only (schemacs editor buffer)
          *transient-mark-mode*
          current-buffer get-buffer get-buffer-create with-current-buffer
          text-editor-undo-list set!text-editor-undo-list
          text-editor-cache-long-scans set!text-editor-cache-long-scans
          buffer-auto-hscroll-mode buffer-cursor-in-non-selected-windows
          buffer-cursor-type buffer-hscroll-margin buffer-hscroll-step
          buffer-local-value buffer-truncate-lines
          buffer-word-wrap
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
          fetch-char set-point text-editor-buffer-name text-editor-text-props text-editor-file-name buffer-pt buffer-modified-p buffer-read-only?)
    ;; `BEG_UNCHANGED' (`buffer.h:156') is a field of the buffer's *text* -
    ;; `buffer-text' is this tree's `struct buffer_text' - and the two
    ;; accessors below are the only readers and writers of it here.
    (only (schemacs editor buffer-text)
          buffer-text-beg-unchanged set!buffer-text-beg-unchanged)
    ;; The row and its glyphs - `struct glyph`/`struct glyph_row`
    ;; (`dispextern.h`), and the two matrices a window keeps.
    (only (schemacs editor glyph)
          <glyph> make-glyph glyph-char glyph-face-id glyph-pixel-width
          glyph-voffset glyph-padding? set-glyph-char!
          set-glyph-face-id! set-glyph-pixel-width!
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
          ensure-window-matrices! window-current-matrix window-desired-matrix
          matrix-diff-rows matrix-mark-current! clear-glyph-matrix)

    ;; `overwrite-mode''s two mode-line lighters are `simple.el''s and
    ;; live beside the commands that set the variable; `minor-mode-alist'
    ;; below is what names them.
    (only (schemacs editor simple)
          *overwrite-mode-textual* *overwrite-mode-binary*
          ;; the `*Messages*' buffer's own mode, which `message-dolog'
          ;; switches a newly made buffer into
          messages-buffer-mode)
    ;; `minor-mode-alist' is `bindings.el`'s and lives in `subr.scm`,
    ;; beside `add-minor-mode' - **the one function that writes it**. It
    ;; is imported here rather than declared here, which it was until
    ;; 2026-10-14: two `(make-parameter ...)' forms of the same name meant
    ;; the mode line read one and `add-minor-mode' wrote the other, so a
    ;; minor mode registered the Emacs way never reached the mode line.
    (only (schemacs editor subr) *minor-mode-alist*)
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
   ;; `render!' and the mode line are what the rest calls. The search
   ;; highlight used to be here as a parameter; it is isearch's overlays
   ;; now, and the display only reads faces.
   cursor-screen-position
   ;; the run computation, which is what a caller can test without a
   ;; terminal: `draw-line!' itself needs one
   line-face-runs
   line-end-fill-attribute
   *mode-line-format*
   ;; `bindings.el''s other mode-line variable, and the construct that
   ;; reads it. A minor mode with a lighter adds itself to the alist.
   mode-line-minor-modes
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
   mode-line-string
   render! redisplay-frames! *redisplay-in-progress*
   force-mode-line-update
   scroll-to-cursor!
   status-string
   window-end
   pos-visible-in-window-p
   window-line-rows
   window-line-slices
   posn-at-x-y buffer-posn-from-coords
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
            (set-window-start!
             window (if (>= rows vheight) cursor-start pos))
            (let* ((above (text-editor-get-start-of-line ed (- pos 1)))
                   (tall (window-line-rows-at window above)))
              (loop (- back tall) (+ rows tall) above)))))

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
      (let* ((ed (window-buffer window))
             (vheight (window-body-height window))
             (pt (window-point window))
             (cursor-start (text-editor-get-start-of-line ed pt))
             (start (window-start window)))
        (cond
         ((< cursor-start start)
          ;; point's line begins above the window, so point is not visible
          (recenter-window-on-cursor! window ed cursor-start vheight))
         (else
          ;; walk down from the start to the cursor's line, counting rows
          (let loop ((pos start) (used 0))
            (cond
             ((>= used vheight)
              ;; the cursor's line has fallen off the bottom
              (recenter-window-on-cursor! window ed cursor-start vheight))
             ((= pos cursor-start)
              ;; the cursor's line: visible only if its own row is
              (let ((k (rows-row-of-column
                        (window-line-slices-at window pos)
                        (- pt cursor-start))))
                (when (>= (+ used k) vheight)
                  ;; its row is below the window, so point is not visible
                  (recenter-window-on-cursor! window ed cursor-start vheight))))
             (else
              (let ((next (line-next-start ed pos)))
                ;; visible as it stands, or the walk ran past the end of
                ;; the buffer, where there is nothing below to draw
                (if next
                    (loop next (+ used (window-line-rows-at window pos)))
                    #t)))))))))

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
          (when (and (buffer-auto-hscroll-mode ed)
                     (not (%window-suspend-auto-hscroll? window))
                     (or (and (> h 0) (<= cursor-x margin))
                         (and truncated-right?
                              (>= cursor-x (- width margin))))
                     (not (= new-h h)))
            (set!%window-hscroll window new-h)))))

    (define *mode-line-window* (make-parameter #f))

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
      ;;--------------------------------------------------------------
      (let* ((window (*mode-line-window*))
             (cs (buffer-local-value (window-buffer window)
                                     'buffer-file-coding-system
                                     'utf-8-unix))
             (eol (coding-system-eol-type cs)))
        (cond ((eq? eol 'dos) "(DOS)")
              ((eq? eol 'mac) "(Mac)")
              (else ":"))))

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
      ;; support), the `%n` narrowing indicator (no narrowing) and the
      ;; mouse maps on the name.
      ;;--------------------------------------------------------------
      (let ((window (*mode-line-window*)))
        (if (not window)
            ""
            (string-append "(" (mode-name (window-buffer window))
                           (mode-line-minor-modes) ")"))))


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
       ((symbol? indicator) (buffer-local-value buffer indicator #f))
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
      ;;--------------------------------------------------------------
      (buffer-local-value buffer variable #f))

    (define (mode-line-minor-modes)
      ;; GNU Emacs's `mode-line-minor-modes` (`bindings.el:468`), which
      ;; is `(:eval (mode-line--minor-modes))`: the lighters of the minor
      ;; modes that are on, concatenated.
      ;;
      ;; `mode-line--minor-modes` computes more than this - the
      ;; `mode-line-collapse-minor-modes` hiding, and the clickable menu
      ;; `mode-line--make-lighter-menu` makes - and neither is carried,
      ;; there being one lighter here and no mode-line mouse maps.
      ;;--------------------------------------------------------------
      (let ((window (*mode-line-window*)))
        (if (not window)
            ""
            (let ((buffer (window-buffer window)))
              (apply string-append
                     (map (lambda (entry)
                            (if (minor-mode-variable-true? buffer (car entry))
                                (minor-mode-lighter
                                 (minor-mode-indicator-value buffer
                                                             (cadr entry)))
                                ""))
                          (*minor-mode-alist*)))))))

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
      (list "%z" (list ':eval mode-line-eol-desc)))

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
      ;; Emacs's default also names variables in the format - `mode-line-mule-info',
      ;; `mode-line-position', `mode-line-modes' and so on - and a symbol in
      ;; the format is evaluated at display time. This editor has no variable
      ;; registry yet, so a symbol here resolves to nothing, exactly as an
      ;; unbound variable does in Emacs; the default therefore spells out what
      ;; it shows rather than naming it. When the elisp layer brings a variable
      ;; registry, the names go back in.
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
             (list "%1*" "%1+")
             ;; `mode-line-remote', which Emacs has right here - between
             ;; `mode-line-modified' and `mode-line-window-dedicated'.
             "%1@"
             " "
             ;; `mode-line-buffer-identification' (`bindings.el:797'):
             ;; `%12b` carrying the `mode-line-buffer-id` face, so a
             ;; theme's colour for the buffer name is applied and the
             ;; default one makes it bold.
             (list ':propertize "%12b" 'face 'mode-line-buffer-id)
             " -- L" "%l" " C" "%c"
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
                   (nlines (count-lines ed linepos startpos))
                   (topline (+ nlines line)))
              (let ((nlines-from-start
                     (lambda () (count-lines ed startpos (window-point window)))))
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

    (define (mode-line-construct spec window)
      ;; The text one `%'-construct stands for: GNU Emacs's
      ;; `decode_mode_spec'. SPEC is the character after the `%'.
      ;;
      ;; The constructs this editor can answer are the ones about the buffer
      ;; and the window's point. The rest - the percentages of the buffer
      ;; above or below the window (`%p', `%P', `%o', `%q'), the coding
      ;; systems (`%z', `%Z'), the process (`%s') and the recursion depth
      ;; (`%[', `%]') - are printed as they stand, which is what Emacs does
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

    (define (expand-mode-line-string str window)
      ;; STR with its `%'-constructs expanded: GNU Emacs's processing of a
      ;; string in a mode line. A `%' followed by digits is a field width, as
      ;; in `%12b'; a `%' followed by anything else is a construct. A `%' at
      ;; the very end is a literal `%'.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i 0) (width #f))
            (when (< i (string-length str))
              (let ((c (string-ref str i)))
                (cond
                 ((and (char=? c #\%) (not width))
                  (loop (+ 1 i) 'pending))
                 ((eq? width 'pending)
                  (if (char-numeric? c)
                      (loop (+ 1 i) (- (char->integer c) (char->integer #\0)))
                      (let ((text (mode-line-construct c window)))
                        (display (if width text text) port)
                        (loop (+ 1 i) #f))))
                 ((integer? width)
                  (if (char-numeric? c)
                      (loop (+ 1 i) (+ (* 10 width)
                                       (- (char->integer c) (char->integer #\0))))
                      (begin
                        (display (pad-mode-line-field
                                  (mode-line-construct c window) width)
                                 port)
                        (loop (+ 1 i) #f))))
                 (else
                  (write-char c port)
                  (loop (+ 1 i) #f))))))
          (get-output-string port))))

    (define (format-mode-line format . args)
      ;; GNU Emacs's `format-mode-line': the mode line FORMAT produces for a
      ;; window, WINDOW being the second argument or the selected window.
      ;; A construct is a string, list, symbol, or nil; `:eval' holds a
      ;; zero-argument procedure in place of an Emacs Lisp form.
      ;;--------------------------------------------------------------
      (let ((window (if (pair? args) (car args) (selected-window))))
        (parameterize ((*mode-line-window* window))
          (let process ((construct format))
            (cond
             ((not construct) "")
             ((string? construct) (expand-mode-line-string construct window))
             ((integer? construct) "")
             ((symbol? construct) "")
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
                (process (if (and (pair? (cdr construct))
                                  (pair? (cddr construct)))
                             (caddr construct)
                             #f)))
               ((integer? (car construct))
                (let* ((width (car construct))
                       (rest (if (pair? (cdr construct)) (cadr construct) #f))
                       (text (process rest)))
                  (if (< width 0)
                      (if (> (string-length text) (- width))
                          (substring text 0 (- width))
                          text)
                      (pad-mode-line-element text width))))
               ;; `concat`, not `string-append`: the latter drops the
               ;; text properties of its pieces, so a `:propertize`
               ;; construct lost its face the moment it was joined to
               ;; the rest of the line. GNU Emacs's `format-mode-line`
               ;; joins with `concat` for exactly this reason.
               (else (apply concat (map process construct)))))
             (else ""))))))

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
        (realize-face (current-display)
                      (merge-face-vectors (face-realized-attributes face-name)
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
                            (cond ((and (> beg position) (< beg limit)) beg)
                                  ((and (> end position) (< end limit)) end)
                                  (else limit))))
                        limit))
                  limit))
             (next (min by-property by-overlay by-region)))
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
                                    (realize-face (current-display) attrs))
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
              (write-glyphs! (current-display) (list text) row-y x
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

    (define (draw-special-glyph! row-y x0 width glyph)
      ;; The continuation glyph (`\') or the truncation glyph (`$') in a
      ;; row's last cell. It is a special display character, not buffer
      ;; text, and Emacs draws it with the default face even inside a
      ;; region - `produce_special_glyphs' uses `DEFAULT_FACE_ID'.
      ;;--------------------------------------------------------------
      (write-glyphs! (current-display) (list glyph) row-y (+ x0 width -1)
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
            attrs)))

    (define (face-at-buffer-position ed position)
      ;; The display's token for the face in effect at POSITION in ED:
      ;; `attrs-at-buffer-position' folded down to what the terminal can
      ;; draw, which is the last thing `face_at_buffer_position' does.
      ;;
      ;; Emacs caches the realized face against the position, because
      ;; this runs per character; a cache is worth adding when the
      ;; renderer starts asking per character rather than per run.
      ;;--------------------------------------------------------------
      (realize-face (current-display) (attrs-at-buffer-position ed position)))

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
      (+ y (row->pixel-y (window-top window))))

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
             ;; rows before the one the cursor's column falls on.
             (screen-row (+ (rows-above window line-start)
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
          (cons (+ screen-row (window-top window))
                (+ (window-left window)
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

    (define (line-slice-glyphs texts from to x0 line-start)
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
      ;; **One glyph per buffer column**, which is what `append_glyph`
      ;; does for a character: `line-texts-glyphs` already walks display
      ;; strings, tabs and wide characters, so each entry is the string
      ;; that column draws and the glyph's width is its measured width.
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
      (let* ((strings (line-texts-glyphs texts from to))
             (offsets (list->vector (line-texts-offsets texts from to)))
             (n (length strings))
             (vec (make-vector n #f))
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
        (let loop ((i 0) (rest strings) (rs runs))
          (when (< i n)
            ;; Skip the runs that end at or before this glyph; the
            ;; first run still covering column I is this glyph's face.
            (let* ((rs (let skip ((rs rs))
                         (if (and (pair? rs) (pair? (cdr rs))
                                  (>= i (cadr (car rs))))
                             (skip (cdr rs))
                             rs)))
                   (token (if (pair? rs)
                              (caddr (car rs))
                              (realize-face (current-display)
                                            (attrs-at-buffer-position
                                             (current-buffer) (+ line-start from i)))))
                   (text (car rest))
                   (next-x (if (< (+ i 1) (vector-length offsets))
                               (vector-ref offsets (+ i 1))
                               (+ (vector-ref offsets i) (text-cells-width text))))
                   (w (max 1 (- next-x (vector-ref offsets i)))))
              (vector-set! vec i (make-glyph text token w 'char #f 0))
              (loop (+ i 1) (cdr rest) rs))))
        (cons vec n)))

    (define (text-cells-width text)
      ;; A glyph string's width in cells - `text-cells` is the display's,
      ;; and a row must not ask it, so this is the same sum over the
      ;; string's characters.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0))
        (if (>= i (string-length text))
            col
            (loop (+ i 1)
                  (+ col (char-display-width (string-ref text i) col))))))

    (define (build-row! row texts from to x0 y width
                        line-start more? truncated? row-width metrics)
      ;; Fill ROW from one screen row of a line: `display_line`.
      ;;
      ;; The row keeps the glyphs, the geometry it was drawn at, the two
      ;; markers the last cell carries (`$` for a truncated line, `\` for
      ;; a continued one) and the buffer positions it covers. The hash is
      ;; taken once, here, which is what `row_equal_p` compares first.
      ;;
      ;; **Not carried here: overlay `before-string`/`after-string`.** GNU
      ;; Emacs delivers those as *glyphs* (`get_overlay_strings` pushes
      ;; the string onto the iterator and the next `append_glyph` puts it
      ;; in the row, `xdisp.c:6920`), so they belong in this function and
      ;; not in a draw path of their own. They are absent because nothing
      ;; in this tree can make one yet: `buffer.scm` records that
      ;; `before-string`/`after-string` are not ported. `overlay-strings-at`
      ;; - a faithful `load_overlay_strings` - is ported and exported, so
      ;; the day an overlay can carry a string, this is where its glyphs go.
      ;;
      ;; The old `draw-line!` drew them, and it was deleted as dead along
      ;; with the rest of the pre-matrix renderer; keeping a second way to
      ;; draw a row alive for a feature that cannot occur is how the two
      ;; renderers came to disagree in the first place.
      ;;--------------------------------------------------------------
      (let* ((made (line-slice-glyphs texts from to x0 line-start))
             (vec (car made))
             (n (cdr made)))
        (set-glyph-row-glyphs! row vec)
        (set-glyph-row-used! row n)
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
             (x0 (window-left window))
             (vheight (window-body-height window))
             (desired (window-desired-matrix window)))
        (let loop ((row 0)
                   (y (row->pixel-y (window-top window)))
                   (line-start (window-start window)))
          (if (or (>= row vheight) (not desired))
              #t
              (let* ((texts (line-display-texts ed line-start))
                     (slices (%window-line-slices window texts)))
                (if (null? slices)
                    ;; past the buffer's end: the remaining rows are blank
                    (let clear ((r row))
                      (if (< r vheight)
                          (let ((slot (glyph-matrix-row-ref desired r)))
                            (when slot (set-glyph-row-enabled! slot #f))
                            (clear r (+ r 1)))
                          #t))
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
                                        (build-row! slot texts (car slice) (cdr slice)
                                                    row-x yy row-width line-start
                                                    (pair? (cdr rest))
                                                    ;; cut off at the right
                                                    ;; edge. On an hscrolled
                                                    ;; line the edge moves:
                                                    ;; `render-line-rows!`
                                                    ;; compares against
                                                    ;; `hscroll + width - 1`,
                                                    ;; the cell the left
                                                    ;; marker took.
                                                    (and (null? (cdr rest))
                                                         (> (line-texts-width texts)
                                                            (if hscrolled?
                                                                (+ (%window-hscroll window)
                                                                   width -1)
                                                                width)))
                                                    0 metrics)))
                                    (rloop (cdr rest) (+ k 1)
                                           (+ yy (cdr metrics)) (+ r 1)))))))
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
                             (next (line-next-start ed line-start))
                             (end (cond ((< drawn (length slices))
                                         ;; this line was cut off by the
                                         ;; bottom: the last row that fits
                                         ;; ends it
                                         (+ line-start
                                            (cdr (list-ref slices
                                                           (- drawn 1)))))
                                        (next next)
                                        (else (text-editor-get-end-of-line
                                               ed line-start)))))
                        (set!%window-end-pos window (- (buffer-z ed) end))
                        (set!%window-end-vpos window (- last-row 1))
                        (set!%window-end-valid? window #t))
                      (let ((next (line-next-start ed line-start)))
                        (if next
                            (loop (car next-row) (cdr next-row) next)
                            #t))))))))))

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
      (let ((y (row->pixel-y (+ (window-top window) index))))
        (clear-end-of-line! (current-display)
                            y (window-left window)
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
        ;; the runs, each written at the column it starts at; the answer
        ;; is the column the text ended at, where the blanking begins
        (let loop ((i 0) (col x0))
          (if (>= i n)
              (when (< col limit)
                (clear-end-of-line! (current-display) y col (- limit col)
                                    (face->attribute 'default)))
              (let* ((g (vector-ref glyphs i))
                     (token (glyph-face-id g)))
                (let run ((j (+ i 1))
                          (parts (list (glyph-char g)))
                          (cells (glyph-pixel-width g)))
                  (if (and (< j n)
                           (eqv? (glyph-face-id (vector-ref glyphs j)) token))
                      (let ((gj (vector-ref glyphs j)))
                        (run (+ j 1)
                             (cons (glyph-char gj) parts)
                             (+ cells (glyph-pixel-width gj))))
                      (begin
                        (write-glyphs! (current-display)
                                       (reverse parts) y col token)
                        (loop j (+ col cells))))))))
        ;; the left truncation glyph, when the row was drawn one cell in
        ;; from the window's left edge - which is what `display-window!`
        ;; does for an hscrolled line. `$` overwrites the cell at the
        ;; hscroll column rather than pushing the text right, as
        ;; `draw-line!`'s hscrolled branch did.
        (when (> x0 (window-left window))
          ;; at the window's *first* cell, which is the cell the text
          ;; gave up - `draw-special-glyph!` writes the last cell, so
          ;; this is its own `write-glyphs!`
          (write-glyphs! (current-display) (list "$") y
                         (window-left window)
                         (face->attribute 'default)))
        ;; the right marker sits in the window's last cell, so the row's
        ;; own width (one cell short when it made room for the left
        ;; marker) is not what places it - `window-left window` plus the
        ;; window's width is.
        (let ((window-width (window-body-width window))
              (window-x (window-left window)))
          (cond ((glyph-row-continued? row)
                 (draw-special-glyph! y window-x window-width "\\"))
                ((glyph-row-truncated-on-right? row)
                 (draw-special-glyph! y window-x window-width "$"))))))

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

    (define (draw-mode-line! line base row-y x0)
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
      ;;--------------------------------------------------------------
      (let* ((len (string-length line))
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
                                    (find (+ k 1)))))
                           (box (face-attribute (or face base)
                                                ':box #f base)))
                      (loop j (cons (list i j face box) acc)))))))
        (let loop ((rest runs) (prev-boxed? #f))
          (when (pair? rest)
            (let* ((run (car rest))
                   (i (car run))
                   (j (cadr run))
                   (face (caddr run))
                   (box (cadddr run))
                   (next (if (pair? (cdr rest)) (cadr rest) #f))
                   (next-boxed? (and next (cadddr next) #t))
                   (token (if face
                              (face->attribute face base)
                              (face->attribute base base))))
              (write-glyphs! (current-display)
                             (list (mode-line-substring line i j))
                             row-y (+ x0 i)
                             token)
              (when box
                (draw-box! (current-display) box token (+ x0 i) row-y
                           (- j i)
                           (cdr (display-cell-size (current-display)))
                           (and (not prev-boxed?) #t)
                           (and (not next-boxed?) #t)))
              (loop (cdr rest) (and box #t)))))))

    (define (render-window-mode-line! window)
      ;; Draw WINDOW's mode line and its vertical border - the part of a
      ;; window that is not glyph rows.
      ;;
      ;; **It is drawn every redisplay, and that is Emacs's rule too**:
      ;; `mode_line_update_needed` is the C's cheap test, and what it
      ;; guards is one row's formatting. The row *contents* here are the
      ;; mode line string, which changes with the buffer, the point and
      ;; every minor mode; formatting it is the cheap part and comparing
      ;; it would cost the same.
      ;;--------------------------------------------------------------
      (let* ((x0 (window-left window))
             (width (window-body-width window))
             (border (and (window-right-border? window) (+ x0 width))))
        (draw-mode-line! (mode-line-pad
                          (mode-line-truncate (mode-line-string window)
                                              width)
                          width)
                         (if (eq? window (selected-window))
                             'mode-line-active
                             'mode-line-inactive)
                         (row->pixel-y
                          (+ (window-top window) (window-height window) -1))
                         x0)
        (when border
          (let loop ((row (window-top window))
                     (end (+ (window-top window) (window-height window))))
            (when (< row end)
              (write-glyphs! (current-display) "|" (row->pixel-y row)
                             border (face->attribute 'vertical-border))
              (loop (+ 1 row) end))))))

    (define (force-mode-line-update . args)
      ;; GNU Emacs's `force-mode-line-update' (`xdisp.c`): mark the mode
      ;; line, or every mode line with ALL, for redrawing.
      ;;
      ;; **There is nothing to mark, and that is the honest port.** Emacs
      ;; keeps a `w->update_mode_line` flag because its redisplay seeks
      ;; the windows that changed; this one redraws every window on every
      ;; `render!`, so the mode line a command has just changed is
      ;; already in the next frame. `face-remap.el` calls this after
      ;; adjusting `face-remapping-alist` for the same reason - "Force
      ;; redisplay of this buffer" - and the redisplay that follows the
      ;; command does it.
      ;;--------------------------------------------------------------
      #f)

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
      (let ((selected (*current-frame*)))
        (let loop ((frames (*frame-list*)))
          (cond ((null? frames) #f)
                (else
                 (let ((f (car frames)))
                   (when (or (eq? f selected)
                             (not (eq? (frame-output f)
                                       (and selected (frame-output selected)))))
                     (render! f)))
                 (loop (cdr frames)))))))

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
      ;; terminal used to be excluded here - every keystroke erased the
      ;; screen and repainted all of it - on the strength of a note in
      ;; `clear-frame-area!` about the partial-update optimizations
      ;; (scroll regions, insert/delete character) desyncing the
      ;; physical terminal when lines merge. Those optimizations are
      ;; switched *off* in `with-terminal` (`idlok!` and `idcok!`), so
      ;; there was nothing to desync, and the terminal paid a whole
      ;; frame per keypress for it: measured on a 40x120 tty over a
      ;; 2000-line file, `render!` wrote 20 KB a keystroke, and the
      ;; screen visibly flashed. ncurses keeps its own account of the
      ;; screen and emits only the cells whose content differs, which is
      ;; the same diff `update_window` does - a cursor move now costs
      ;; one cell.
      (when (or (frame-garbaged-p frame)
                ;; **A terminal still repaints the frame it draws.**
                ;; GNU Emacs's terminal redisplay is `build_frame_matrix`
                ;; + `update_frame` (`dispnew.c`): every frame matrix is
                ;; rebuilt and handed to the terminal whole, and the
                ;; *terminal* decides how little of it to send. Here it
                ;; has to be the same, because ncurses takes its own
                ;; scrolling shortcut (`ESC [ 1 ; 22 r`, `ESC M` - it
                ;; shifts a region of rows) whenever it can, and a row
                ;; diff computed against the *unscrolled* matrix then
                ;; writes the wrong text: measured, `C-x i` drew the
                ;; inserted file over the echo-area row, and Dired's
                ;; marks never appeared. The erase is what tells ncurses
                ;; the whole screen is ours to redraw.
                (not (graphical-frame?)))
        (when (not (graphical-frame?))
          (clear-frame-area! (current-display)))
        (for-each (lambda (w)
                    (ensure-window-matrices! w (window-body-width w)
                                            (window-body-height w))
                    (let ((m (window-current-matrix w)))
                      (when m (clear-glyph-matrix m))))
                  windows)
        (set-frame-garbaged! frame #f)))

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
        (clear-garbaged-frames! frame windows)
        ;; Only the selected window is scrolled to show its point here:
        ;; it is the one point moves in, and its buffer is the one
        ;; commands act on. A window that is not selected keeps the view
        ;; it had, as GNU Emacs leaves a window's start alone until it
        ;; is displayed with its own point.
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
        (for-each (lambda (w)
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
                    (cond ((window-buffer w)
                   ;; **Every window is rebuilt every redisplay.** GNU
                   ;; Emacs returns early for a window that is not
                   ;; outdated (`window_outdated`, `window.c:231`), and
                   ;; that is the next step - but it needs
                   ;; `try_window_id` with it: a skipped window keeps the
                   ;; desired matrix `assign_row` swapped out of it, and
                   ;; `update_window` then compares an empty matrix
                   ;; against the screen.
                   (display-window! w))
                  (else
                   (let ((m (window-current-matrix w)))
                     (when m (clear-glyph-matrix m))))))
                  windows)
        (for-each update-window! windows)
        ;; **No mode line for the minibuffer window**, which is Emacs's
        ;; `MINI_WINDOW_P` test in `display_mode_lines`: a minibuffer
        ;; window is one row and that row is its text.
        (for-each render-window-mode-line! body)
        ;; **The echo area is drawn on one frame only.** GNU Emacs's
        ;; `echo_area_window' is `FRAME_MINIBUF_WINDOW (SELECTED_FRAME ())'
        ;; (`xdisp.c:13782') and `redisplay_window' draws the message only
        ;; for a window that *is* that one (`:20526'): "We've already
        ;; displayed the echo area glyphs in this window" is the answer
        ;; every other frame's minibuffer window gets. Drawing it on all
        ;; of them is what put the prompt - and, with it, everything typed
        ;; into the minibuffer - into every frame at once.
        (when (eq? frame (*current-frame*))
          ;; Echo area: the minibuffer when one is active, exactly as GNU
          ;; Emacs draws it (the minibuffer *is* the echo area while it is
          ;; being read), otherwise whatever message is pending.
          (let ((reading (*echo-area-buffer*)))
            (cond
             ;; While a minibuffer is being read its line is the prompt and
             ;; what has been typed, with any pending message appended after
             ;; it - which is what Emacs's `minibuffer-message' does, and it
             ;; is where the completion candidates have to go or they would
             ;; hide the very text being completed.
             ;;
             ;; The buffer and its prompt come from the frame, which is
             ;; where GNU Emacs keeps them too (`echo_area_buffer[0]', and
             ;; the prompt as text in that buffer). Nothing here knows what
             ;; a minibuffer is: it draws a buffer that happens to have a
             ;; prompt beside it, which is what the echo area is.
             (reading
              ;; Two writes, because the prompt carries a face and the
              ;; typed text does not. In GNU Emacs the prompt is text in
              ;; the minibuffer buffer carrying `minibuffer-prompt-properties'
              ;; - whose `face' is `minibuffer-prompt' - and the input after
              ;; it carries nothing, which is what `xdisp.c' draws. Drawing
              ;; the two as one plain string is why a prompt here had no
              ;; colour at all.
              (let* ((prompt (truncate-line (or (*echo-area-prompt*) "") width))
                     (pwidth (min (line-display-width prompt) width)))
                (when (> pwidth 0)
                  (write-glyphs! (current-display)
                                 prompt
                                 (row->pixel-y (- height 1)) 0
                                 (face->attribute 'minibuffer-prompt)))
                (write-glyphs! (current-display)
                               (truncate-line
                                (string-append
                                 ;; The echo buffer's characters, which
                                 ;; is `buffer-substring-no-properties'
                                 ;; over the whole of it - Emacs's
                                 ;; `echo_area_display' reads the same
                                 ;; text, through the glyph matrices.
                                 ;; It was `text-editor-to-string',
                                 ;; which was that composition under an
                                 ;; invented name (deleted 2026-10-13).
                                 (with-current-buffer reading
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))
                                 (frame-message frame))
                                (- width pwidth))
                               (row->pixel-y (- height 1)) pwidth
                               ;; The typed text carries no face
                               ;; property, so it is displayed in the
                               ;; *default* face - Emacs's echo area is
                               ;; the minibuffer window, redisplayed like
                               ;; any other. `#f' here meant the
                               ;; terminal's own colours, which is the
                               ;; same thing only until a theme sets the
                               ;; default face.
                               (face->attribute 'default))))
             (else
              (write-glyphs! (current-display)
                             (truncate-line (frame-message frame) width)
                             (row->pixel-y (- height 1)) 0
                             (face->attribute 'default))))))
        ;; Place the terminal cursor: in the minibuffer while one is
        ;; active (Emacs's `cursor-in-echo-area'), else at the selected
        ;; window's point - the only window whose cursor is drawn, there
        ;; being one cursor on a terminal.
        ;; The cursor follows the same rule: the echo area's cursor
        ;; belongs to the frame whose echo area it is, and every other
        ;; frame draws its own window's cursor as usual.
        ;;
        ;; **The echo area's cursor is the *selected* window's, and only
        ;; while that is the minibuffer.** GNU Emacs asks
        ;; `get_window_cursor_type` (`xdisp.c:34825') whether
        ;; `w == XWINDOW (echo_area_window)`; a window that is not that
        ;; one gets `*active_cursor = false` and no echo-area cursor at
        ;; all. This tree has no minibuffer window - the echo area is a
        ;; row of the frame - so the equivalent question is whether the
        ;; current buffer is still the prompt's: click into another
        ;; window and the prompt stays *drawn* (the block above reads
        ;; `*echo-area-buffer*`) while the cursor goes back to the
        ;; selected window, which is what typing there looks like.
        (let* ((echo (and (eq? frame (*current-frame*))
                          (*echo-area-buffer*)))
               ;; **`and` answers its *last* test**, so an `eq?` at the
               ;; end makes `reading` `#t` rather than the buffer - and
               ;; `(buffer-pt #t)` is "Wrong type argument ... #t". The
               ;; buffer comes last for that reason.
               (reading (and echo (eq? (current-buffer) echo) echo)))
          (if reading
              ;; At point in the input, where Emacs's `cursor-in-echo-area'
              ;; leaves it: a message is shown after the input, and it must
              ;; not drag the cursor along with it - a long one (the
              ;; completion candidates, say) would pin the cursor to the
              ;; right edge of the screen whatever point did.
              (let* ((cursor (get-window-cursor-type
                              (frame-selected-window frame)))
                     ;; **The echo area is not a window**, so its cursor is
                     ;; its buffer's own point - while the frame's windows
                     ;; are placed by `window-point' above. Emacs keeps the
                     ;; echo area's point in the minibuffer buffer, which
                     ;; is the same thing here.
                     (at (buffer-pt reading))
                     (glyph (cursor-glyph reading at)))
                (note-phys-cursor! (current-display)
                                   (row->pixel-y (- height 1))
                                   (min (+ (line-display-width
                                            (or (*echo-area-prompt*) ""))
                                           (current-line-display-column
                                            reading
                                            (text-editor-cursor-column reading)))
                                        (- width 1))
                                   (cursor-cells reading at)
                                   (car glyph)
                                   (cdr glyph))
                (draw-window-cursor! (current-display)
                                     (row->pixel-y (- height 1))
                                     (min (+ (line-display-width
                                              (or (*echo-area-prompt*) ""))
                                             (current-line-display-column
                                              reading
                                              (text-editor-cursor-column reading)))
                                          (- width 1))
                                     (cursor-cells reading at)
                                     (car cursor)
                                     (cadr cursor)
                                     (car glyph)
                                     (cdr glyph)))
              (let ((selected (frame-selected-window frame)))
                (when selected
                  (let ((at (cursor-screen-position selected)))
                    (when at
                      (let* ((buffer (window-buffer selected))
                             (cursor (get-window-cursor-type selected))
                             ;; the glyph under the cursor is the one at
                             ;; the *window's* point, as Emacs's is (the
                             ;; glyph row the display iterator stopped on)
                             (glyph (cursor-glyph buffer
                                                  (window-point selected))))
                        (note-phys-cursor!
                         (current-display)
                         (window-to-frame-pixel-y
                          selected
                          (window-pixel-y
                           selected
                           (- (car at) (window-top selected))))
                         (cdr at)
                         (cursor-cells buffer (window-point selected))
                         (car glyph) (cdr glyph))
                        (draw-window-cursor! (current-display)
                                             ;; **The cursor's pixel y**,
                                             ;; which is `w->cursor.y` in
                                             ;; the C: the sum of the
                                             ;; heights of the rows above
                                             ;; it, not its row index -
                                             ;; once rows differ in height
                                             ;; those are not the same.
                                             ;;
                                             ;; `cursor-screen-position'
                                             ;; answers a *frame* row (it
                                             ;; adds `window-top'), and
                                             ;; `window-pixel-y' walks
                                             ;; rows inside the window, so
                                             ;; the window's own top comes
                                             ;; back off before the walk
                                             ;; and goes back on with the
                                             ;; heights in pixels.
                                             (window-to-frame-pixel-y
                                              selected
                                              (window-pixel-y
                                               selected
                                               (- (car at) (window-top selected))))
                                             (cdr at)
                                             (cursor-cells buffer
                                                           (window-point selected))
                                             (car cursor) (cadr cursor)
                                             (car glyph) (cdr glyph)))))))))
        ;; The screen is what was drawn: the display's flush, which for
        ;; this terminal honours the full-repaint `clear-frame-area!'
        ;; asked for (partial-update optimizations desync the physical
        ;; terminal when lines merge).
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
           ((null? rest)
            ;; Outside every window: Emacs answers the frame, and the
            ;; position of a frame is the frame.
            (list frame #f (cons x y) 0))
           (else
            (let* ((w (car rest))
                   (top (window-top w))
                   (left (window-left w))
                   (height (window-height w))
                   (width (window-width w)))
              (if (and (>= row top) (< row (+ top height))
                       (>= column left) (< column (+ left width)))
                  (if (and (= row (+ top height -1))
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
                      (list w 'mode-line (cons x y) 0)
                      (list w (buffer-posn-from-coords
                               w (- row top) (- column left))
                            (cons x y) 0))
                  (loop (cdr rest)))))))))

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
               (new? (not (get-buffer name))))
          ;; **The buffer is read-only and the log writes to it anyway.**
          ;; `messages-buffer-mode' is a `special-mode', which makes the
          ;; buffer read-only, and the C's `insert_1_both (..., prepare =
          ;; false, ...)' is what skips the check - `prepare_to_modify_buffer'
          ;; is the thing that consults `inhibit-read-only', so that is
          ;; what stands in for it here.
          (parameterize ((*inhibit-read-only* #t))
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
              (set-marker old-point #f))))))))

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

    ))
