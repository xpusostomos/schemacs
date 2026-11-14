(define-library (schemacs editor frame)
  ;; This library mirrors GNU Emacs's frame and window state: `frame.c`
  ;; and the part of `window.c` that holds a window - which buffer it
  ;; shows, where its display starts, where point is in it, where it was
  ;; left, and the rectangle of the screen it occupies - together with
  ;; the window commands' own view of the selection.
  ;;
  ;; The two arrive in one library because they are entangled and this
  ;; project keeps one directory for both sides of Emacs's tree: a
  ;; window's point has to know whether its window is the selected one,
  ;; and the border query has to look at the frame's list of windows. In
  ;; GNU Emacs the same entanglement is spread across frame.c and
  ;; window.c (a single library per file is not available to C either).
  ;; The window *commands* - `split-window-below`, `delete-window`,
  ;; `other-window` and the rest of `window.el` - are in
  ;; `(schemacs editor window)`, which is where the tree they walk is
  ;; kept in shape. The tree itself is here, with the window record it is
  ;; made of.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is the first step of.

  (import
    (only (schemacs editor subr) kbd run-hooks run-hook-with-args)
    (scheme base)
    ;; `new-frame' takes an optional size, which is a `case-lambda': it
    ;; is not exported by `(scheme base)' and a missing import for it
    ;; reports as an unbound variable at run time rather than a
    ;; syntax error at the definition (see ENGINE-FINDINGS.txt).
    (scheme case-lambda)
    ;; The frame is a display-neutral thing: its size is the size its
    ;; display reports (`sync-frame-size!' asks the interface), and
    ;; stopping and resuming the terminal on C-z is the display's
    ;; business too (`suspend-display!' / `resume-display!', which
    ;; `suspend-frame' asks through the interface).
    ;; `Fmouse_position' asks the frame's terminal where the pointer is
    ;; (`FRAME_TERMINAL (f)->mouse_position_hook'), so the display's
    ;; answer is imported under a name of its own and the DEFUN below
    ;; takes Emacs's.
    (only (schemacs editor dispnew)
           column-width current-display delete-frame-display!
           display-cell-size display-selections-supported?
           display-mouse-position display-set-size! line-height
           resume-display! screen-size suspend-display!
           ;; `window-system-display?` is what tells a toolkit's menu bar
           ;; from a terminal's: see `frame-top-margin`.
           window-system-display?
           ;; `SET_FRAME_VISIBLE`'s `redisplay_other_windows`, which
           ;; `suspend-frame` needs when the terminal comes back.
           set-windows-or-buffers-changed!)
    (only (schemacs editor marker) build-marker marker-position set-marker make-marker)
    
    ;; `*current-buffer*' is the C global `current_buffer', which this
    ;; library writes (`select-window') and re-exports; its definition is
    ;; in the lower library, which defines the buffer record. The two
    ;; seams are this library's half of the arrangement - see the notes
    ;; where they are installed, at the end of this file.
    (only (schemacs editor buffer)
          *current-buffer* other-buffer current-buffer
          *current-editor-function* *replace-buffer-in-windows-function*
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char set-point buffer-beg buffer-pt
          ;; `window_outdated` (`window.c:231`) asks the buffer's two
          ;; modification ticks.
          buffer-modified-tick buffer-overlay-modified-tick)
    ;; The seam `insdel.scm` declares for `adjust_suspend_auto_hscroll` -
    ;; it reads the selected window, which is this library's, so it is
    ;; installed here.
    (only (schemacs editor insdel) *adjust-suspend-auto-hscroll-function*)
    ;; The echo area is this library's - the message, the expiry timer and
    ;; the row it is drawn on are all fields of the frame - and
    ;; `editfns.c`'s `message' is not. So `editfns.scm' declares the two
    ;; seam procedures and this installs them, which is also what lets
    ;; this library sit *above* it: the line arithmetic this file's
    ;; `window.c' code needs is `editfns.c`'s, and it could not reach one
    ;; while `editfns.scm' imported back into here.
    (only (schemacs editor editfns)
          *message-function* *current-message-function*
          ;; `window.c`'s line walks want a line start, and that is
          ;; `editfns.c`'s arithmetic - which is why this library sits
          ;; above `editfns.scm` and not below it.
          text-editor-get-start-of-line)
    ;; `suspend-frame' is a command and states its own key as the other
    ;; command libraries do.
    (only (schemacs editor command)
          current-prefix-arg define-command
          register-command! uarg->integer)
    ;; `special-event-map' is where the window system's events are
    ;; bound, as Emacs's is (`keyboard.c:14550').
    (only (schemacs editor keymap)
          define-key *default-keymap* *special-event-map*)
    ;; `SIGTSTP' is raised through `kill': `(scheme base)''s `raise'
    ;; raises an exception, not a signal.
    ;; `window-cursor-table' is held weakly - see the note above
    ;; `WINDOW-CURSOR-TABLE'. Guile's own weak table, a key held weakly.
    (only (guile)
          delq kill getpid SIGTSTP caddr
          make-weak-key-hash-table hashq-ref hashq-set!)
    ;; `w->cursor_off_p' and the blink's timers are kept beside the
    ;; window and the frame rather than in the window, for the reason
    ;; `buffer.sld' gives for its own slots: the record is shared and
    ;; changing it touches every library that makes a window.
    ;; `display-graphic-p' is a question about the window system the frame
    ;; is on, which is what the face machinery records.
    (only (schemacs editor faces)
          *window-system* *display-color-cells* *display-type*
          *frame-background-mode* *frame-background-mode-function*
          color-dark-p face-list face-attribute set-face-attribute
          face-override-spec face-spec-recalc)
    ;; A colour *name*'s RGB - `tty-colors.el''s table, which is what a
    ;; name means here, as `xfaces.c''s `tty_lookup_color' is.
    (only (schemacs editor tty-colors) tty-color-standard-values)
    (only (schemacs editor timer)
          cancel-timer run-at-time run-with-idle-timer run-with-timer))

  (export
   %window-point
   *current-frame* *frame-list* *frame-creation-function*
   *current-buffer*
   *before-make-frame-hook* *after-make-frame-functions*
   frame? frame-list frame-live-p frame-visible-p selected-frame
   select-frame with-selected-frame new-frame-on
   next-frame previous-frame other-frame delete-frame
   delete-other-frames make-frame make-frame-command
   display-graphic-p frame-name
   ;; frame.c's pixel geometry, which `text-scale-min-amount' and
   ;; `text-scale-max-amount' (`face-remap.el') are bounded by.
   frame-char-height frame-char-width
   frame-set-background-mode
   face-set-after-frame-default
   display-pixel-width display-pixel-height
   adjust-frame-size! *frame-inhibit-implied-resize* frame-inhibit-resize?
   *blink-cursor-blinks*
   *blink-cursor-delay*
   *blink-cursor-interval*
   *blink-cursor-mode*
   *frame-cursor-type*
   *frame-focus*
   *pre-command-hook*
   blink-cursor-check
   blink-cursor-idle-timer
   blink-cursor-timer
   blink-cursor--rescan-frames
   blink-cursor--should-blink
   blink-cursor-end
   blink-cursor-mode
   blink-cursor-suspend
   internal-show-cursor
   internal-show-cursor-p
   run-pre-command-hook!
   set!window-cursor-off?
   window-cursor-off?
   *minibuffer*
   *echo-area-buffer*
   *echo-area-prompt*
   current-editor
   display-selections-p
   *tty-select-active-regions*
   frame-height
   frame-width
   make-frame-window
   make<frame>
   ;; `FRAME_TOP_MARGIN (f)` - the rows above the text area - and
   ;; `FRAME_MENU_BAR_LINES (f)`.
   frame-top-margin %frame-menu-bar-lines
   ;; `f->menu_bar_vector` and `f->menu_bar_items_used`.
   frame-menu-bar-items set!frame-menu-bar-items
   frame-menu-bar-items-used set!frame-menu-bar-items-used
   ;; Frame parameters - `frame.c`'s `param_alist` and its readers.
   frame-parameters frame-parameter set-frame-parameter
   modify-frame-parameters store-in-alist
   *default-frame-alist* *initial-frame-alist*
   frame-parameters-alist
   ;; `FRAME_GARBAGED_P` and `SET_FRAME_GARBAGED` (`frame.h:1173`).
   frame-garbaged-p set-frame-garbaged!
   ;; `FRAME_MINIBUF_WINDOW (f)` and the test that it is being read.
   frame-minibuffer-window set!frame-minibuffer-window
   minibuffer-window-active-p window-minibuffer-p
   make<window>
   frame-editor
   frame-keymap-state
   frame-message
   frame-message-timer
   frame-quit-cont
   frame-output
   frame-selected-window
   mouse-position
   frame-type?
   frame-windows
   window-type?
   new-frame
   select-window
   selected-window
   set!%window-point
   set!frame-height
   set!frame-width
   set!frame-editor
   set!frame-keymap-state
   set-message!
   set!frame-message
   set!frame-message-timer
   set!frame-quit-cont
   set!frame-selected-window
   set!frame-windows
   set!window-buffer
   set!window-height
   set!window-left
   set!window-top
   set!window-width
   ;; GNU Emacs's `w->start' and what is stored beside it: where the
   ;; window's display begins, whether that was a line beginning, where
   ;; its last glyph was, and the line-number cache `%l' counts from.
   %window-start set!%window-start
   %window-start-at-line-beg set!%window-start-at-line-beg
   %window-prev-buffers set!%window-prev-buffers
   %window-next-buffers set!%window-next-buffers
   ;; The seam `set-window-buffer!' records through: `record-window-buffer`
   ;; is `window.el`'s, and this library is below the one that can write
   ;; it. `window.scm` installs the function at load, as `frame.scm`
   ;; installs the message function.
   *record-window-buffer-function*
   ;; The seam `scroll-up-command` scrolls through: a screen line is a
   ;; display fact, and `simple.scm` is below the library that knows one.
   ;; `xdisp.scm` installs `window-scroll` at load.
   *window-scroll-function*
   %window-end-pos set!%window-end-pos
   %window-end-vpos set!%window-end-vpos
   %window-end-valid? set!%window-end-valid?
   %window-base-line-number set!%window-base-line-number
   %window-base-line-pos set!%window-base-line-pos
   set-window-start!
   set-window-buffer!
   window-start-at-line-beg
   window-base-line-number
   window-base-line-pos
   resize-frame-windows!
   recenter
   suspend-frame
   set-window-point!
   sync-frame-size!
   ;; `change_frame_size` and `do_pending_window_change` (`dispnew.c`),
   ;; and the frame field a deferred change waits in.
   change-frame-size do-pending-window-change frame-new-size-p
   window-body-height
   window-children
   window-internal?
   window-parent
   set!window-children
   set!window-parent
   ;; the hscroll fields of the window record, which `xdisp' and
   ;; `window' read and write
   %window-hscroll set!%window-hscroll
   ;; what the window's matrix was built from - `window_outdated`'s fields
   window-last-buffer set!window-last-buffer
   window-last-modified set!window-last-modified
   window-last-overlay-modified set!window-last-overlay-modified
   window-last-start set!window-last-start
   window-last-width set!window-last-width
   window-last-height set!window-last-height
   window-last-hscroll set!window-last-hscroll
   ;; `w->last_point` and `w->last_mark` (`window.h`), which
   ;; `mark_window_display_accurate_1` writes: the point and the mark
   ;; the window's picture was built from.
   window-last-point set!window-last-point
   window-last-mark set!window-last-mark
   ;; The mode line row as it was last drawn, so a row that has not
   ;; changed is not written again - `update_window`'s diff for the row
   ;; the mode line occupies.
   window-last-mode-line set!window-last-mode-line
   ;; `window_outdated` (`window.c:231`), which the redisplay asks before
   ;; it trusts a window's glyph matrix.
   window-outdated?
   %window-min-hscroll set!%window-min-hscroll
   %window-suspend-auto-hscroll? set!%window-suspend-auto-hscroll?
   %window-old-point set!%window-old-point
   window-body-width
   window-buffer
   window-edges
   window-frame
   set!window-frame
   window-height
   window-left
   window-list
   window-point
   window-right-border?
   window-top
   window-width
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Windows
    ;;
    ;; GNU Emacs's window: a view of a buffer - which buffer, where its
    ;; display starts, where point is in it, and the rectangle of the
    ;; screen it occupies. Windows are not buffers: the same buffer can
    ;; be shown in more than one window, and each of those windows has
    ;; its own point and its own scroll position. A frame holds its
    ;; windows in a *tree*, one of them selected; commands act on the
    ;; selected window's buffer and the cursor is drawn in the selected
    ;; window.
    ;;
    ;; The tree is Emacs's: a window is either a *leaf*, which shows a
    ;; buffer, or an *internal* window, which holds two or more children
    ;; and shows nothing itself. `SPLIT-WINDOW' turns a leaf into an
    ;; internal window with two children, of which one is the leaf it was
    ;; - so a window a command had hold of stays valid across a split -
    ;; and `DELETE-WINDOW' removes a leaf and promotes its sibling. A
    ;; lookup that walks the tree in order therefore visits the leaves in
    ;; the order they are arranged on the screen, which is what
    ;; `WINDOW-LIST' answers and what makes `OTHER-WINDOW' cyclic in the
    ;; order Emacs makes it cyclic in.
    ;;
    ;; Each window keeps its own rectangle, rather than deriving it from
    ;; the tree: a leaf's is the rectangle it occupies, and an internal
    ;; window's is the union of its children's. That is a convenience for
    ;; the renderer (`WINDOW-EDGES' on a leaf is the whole answer) and it
    ;; is what the window commands maintain - split divides a rectangle
    ;; between two children, delete gives a removed leaf's rectangle to
    ;; its sibling.

    (define-record-type <window>
      (make<window>
       frame
       buffer point start start-at-line-beg
       end-pos end-vpos end-valid base-line-number base-line-pos
       top height left width parent children
       hscroll min-hscroll suspend-auto-hscroll? old-point
       prev-buffers next-buffers
       last-buffer last-modified last-overlay-modified last-start
       last-width last-height last-hscroll last-point last-mark
       last-mode-line)
      window-type?
      (frame     window-frame       set!window-frame)
      ;; ^ The frame this window is on: GNU Emacs's `w->frame', the first
      ;; field of `struct window' (`window.h'). A window belongs to the
      ;; frame that made it and never moves: `make_frame' sets it as each
      ;; of the frame's windows is made (`frame.c:1237', `:1248') and
      ;; `Fsplit_window_internal' gives the new window the frame of the
      ;; window it split (`window.c:5583', `wset_frame (n, frame)' with
      ;; `frame = WINDOW_FRAME (o)' at `:5412').
      ;;
      ;; Redisplay asks it - `WINDOW_XFRAME (w)' is `(XFRAME (w->frame))'
      ;; - to find the frame a window belongs to *when the frame being
      ;; drawn is not the selected one*, which is exactly what a second
      ;; `C-x 5 2' window is. `WINDOW_FULL_WIDTH_P' (`window.h:701'),
      ;; `WINDOW_RIGHTMOST_P' (`:687') and `get_window_cursor_type'
      ;; (`xdisp.c:34813') all read it; asking the selected frame instead
      ;; is what made two frames on one buffer draw as one view.
      (buffer    window-buffer      set!window-buffer)
      ;; ^ The <buffer> this window shows. Emacs's
      ;; `window-buffer'.
      (point     %window-point      set!%window-point)
      ;; ^ The <marker-type> this window is holding, which is point for
      ;; a window that is not selected: where point would be if it were.
      ;; A marker, and not a character index, because the text of the
      ;; buffer can change while this window is not selected - edit
      ;; above this window's point in another window showing the same
      ;; buffer, and the point this one comes back to is still on the
      ;; character it was left on. It is private because `WINDOW-POINT'
      ;; is the function that settles which point a window has - GNU
      ;; Emacs's `window-point', which answers with the buffer's own
      ;; point for the selected window.
      (start     %window-start      set!%window-start)
      ;; ^ A marker pointing to where in the text to start displaying -
      ;; GNU Emacs's `w->start' (`window.h'), a marker for the same
      ;; reason `point' above is one: the text can change under it and
      ;; the window must still begin at the same character.
      ;;
      ;; It is a marker and not a line index, which is what it was: a
      ;; line number is not a buffer position, so every use of it had to
      ;; convert, and each conversion is a scan of the buffer. The
      ;; renderer walks rows by position now, as the C's display iterator
      ;; does, and never converts.
      (start-at-line-beg %window-start-at-line-beg
                         set!%window-start-at-line-beg)
      ;; ^ Whether `start' was the beginning of a line when it was
      ;; chosen: GNU Emacs's `w->start_at_line_beg', which every site
      ;; that sets `start' sets beside it as
      ;; `(pos == BEGV || FETCH_BYTE (pos_byte - 1) == '\n')'. The row
      ;; walk relies on it - a window whose start is not a line
      ;; beginning would begin part way down a line.
      (end-pos   %window-end-pos    set!%window-end-pos)
      ;; ^ `Z - the buffer position of the last glyph in the current
      ;; matrix', GNU Emacs's `w->window_end_pos' - an offset from the
      ;; *end* of the buffer rather than a position, so that an edit
      ;; before the window's end leaves the number valid with no
      ;; adjustment.
      (end-vpos  %window-end-vpos   set!%window-end-vpos)
      ;; ^ The glyph matrix row of that last glyph: GNU Emacs's
      ;; `w->window_end_vpos', recorded as the window is drawn. It is
      ;; what says where the window's text stops on the screen without
      ;; walking the rows to find out.
      (end-valid %window-end-valid? set!%window-end-valid?)
      ;; ^ Whether the two above mean anything: GNU Emacs's
      ;; `w->window_end_valid', which redisplay sets false whenever the
      ;; window is redrawn or its buffer changes.
      (base-line-number %window-base-line-number set!%window-base-line-number)
      ;; ^ "Line number and position of a line somewhere above the top
      ;; of the screen. If this field is zero, it means we don't have a
      ;; base line": GNU Emacs's `w->base_line_number', the cache `%l'
      ;; counts from so that it does not count from `point-min'.
      (base-line-pos %window-base-line-pos set!%window-base-line-pos)
      ;; ^ Where that line begins. GNU Emacs's `w->base_line_pos',
      ;; where 0 means "no base line" and -1 means "do not display the
      ;; line number as long as this window shows this buffer".
      (top       window-top         set!window-top)
      ;; ^ The zero-based screen row of the window's first row.
      (height    window-height      set!window-height)
      ;; ^ The window's height in screen rows, including the row its
      ;; mode line is drawn on, as Emacs's `window-total-height' does.
      ;; `WINDOW-BODY-HEIGHT' is what the text gets.
      (left      window-left        set!window-left)
      ;; ^ The zero-based screen column of the window's first column.
      (width     window-width       set!window-width)
      ;; ^ The window's width in screen columns.
      (parent    window-parent      set!window-parent)
      ;; ^ The window holding this one, or false when the frame does.
      ;; Emacs's `window-parent'. A leaf's parent may be an internal
      ;; window or, when the frame holds it directly, nothing.
      (children  window-children    set!window-children)
      ;; ^ This window's children, in the order they are arranged on the
      ;; screen: empty for a leaf. Emacs's `window-child' and
      ;; `window-next-sibling', kept as a list because that is the order a
      ;; command wants them in.
      (hscroll   %window-hscroll    set!%window-hscroll)
      ;; ^ How many display columns the window's lines are scrolled left
      ;; by: a line's column is drawn at its display column less this.
      ;; Emacs's `w->hscroll', a window-local variable - `window-hscroll'
      ;; and `set-window-hscroll' are its Elisp face, in `window.c'.
      (min-hscroll %window-min-hscroll set!%window-min-hscroll)
      ;; ^ The least amount the window may be left scrolled by, which an
      ;; interactive `scroll-left'/`scroll-right' raises to the new
      ;; amount: Emacs's `w->min_hscroll', set at `window.c:7113' - "the
      ;; new scroll amount becomes the lower bound for automatic
      ;; scrolling".
      (suspend-auto-hscroll? %window-suspend-auto-hscroll?
                             set!%window-suspend-auto-hscroll?)
      ;; ^ Whether auto hscrolling is suspended for this window, which
      ;; `scroll-left'/`scroll-right' set and which clears when the
      ;; window's point moves: Emacs's `w->suspend_auto_hscroll'
      ;; (`xdisp.c:16756' clears it when `Fwindow_point' differs from
      ;; `old_pointm').
      (old-point %window-old-point  set!%window-old-point)
      ;; ^ The window point the last redisplay saw, for that comparison.
      ;; Emacs's `w->old_pointm', a marker there and the integer it
      ;; holds here - the comparison is `Fequal' either way.
      (prev-buffers %window-prev-buffers set!%window-prev-buffers)
      (next-buffers %window-next-buffers set!%window-next-buffers)
      (last-buffer window-last-buffer set!window-last-buffer)
      (last-modified window-last-modified set!window-last-modified)
      (last-overlay-modified window-last-overlay-modified
                             set!window-last-overlay-modified)
      (last-start window-last-start set!window-last-start)
      (last-width window-last-width set!window-last-width)
      (last-height window-last-height set!window-last-height)
      (last-hscroll window-last-hscroll set!window-last-hscroll)
      (last-point window-last-point set!window-last-point)
      ;; ^ `w->last_point` (`window.h`): "The point value for the
      ;; last redisplay of this window". Written by
      ;; `mark_window_display_accurate_1` (`xdisp.c:18352`), which asks
      ;; `BUF_PT` for the selected window and `marker_position
      ;; (w->pointm)` otherwise.
      (last-mark window-last-mark set!window-last-mark)
      (last-mode-line window-last-mode-line set!window-last-mode-line)
      ;; ^ `(STRING FACE Y X)` as the mode line row was last drawn, or
      ;; `#f` when nothing of ours is on that row. GNU Emacs needs no such
      ;; field: the mode line is a row of the window's glyph matrix
      ;; (`display_mode_line`) and `update_window` diffs it like any
      ;; other. This tree draws it directly, outside the matrices, so the
      ;; comparison the matrix would have made is made here.
      ;; ^ `w->last_mark`, the mark that redisplay was built from, and
      ;; -1 where Emacs's is -1: "the value of mark as it was in the last
      ;; display", with the C's rule that an inactive mark reads -1.
      ;; **This tree's redisplay reads the mark for every window**, not
      ;; for the selected one alone: the region's face is computed from
      ;; the buffer's point and mark in `line-display-texts`' callers, so
      ;; a window showing a buffer whose region moved has to be rebuilt
      ;; whether or not it is selected.
      ;; ^ What the window's glyph matrix was built from: the buffer, its
      ;; two modification ticks, the position it started at, its body size
      ;; and its horizontal scroll. GNU Emacs's `w->last_modified',
      ;; `w->last_overlay_modified' and `w->window_end_valid' are the same
      ;; idea - the redisplay asks `window_outdated' (`window.c:231')
      ;; whether it may trust the matrix it built last time, and skips
      ;; rebuilding it when it may.
      ;; ^ The buffers this window showed before the one it shows, and
      ;; the ones `switch-to-prev-buffer' has stepped off. GNU Emacs's
      ;; `w->prev_buffers' and `w->next_buffers' (`window.h`, fields of
      ;; the window itself since 30.1), reached through
      ;; `window-prev-buffers`/`set-window-prev-buffers` in `window.scm`.
      ;;
      ;; The entries are `(BUFFER START POINT)`: the buffer, the start
      ;; the window had for it and the window's point in it, as markers
      ;; so that they follow edits. `record-window-buffer` (`window.el`)
      ;; fills them.
      )

    (define (window-internal? window)
      ;; Whether WINDOW is an internal window rather than one showing a
      ;; buffer: it has children. Emacs's `window-combination-p'.
      ;;--------------------------------------------------------------
      (pair? (window-children window)))

    (define (window-list . args)
      ;; The frame's windows that show a buffer, in the order they are
      ;; arranged on the screen: GNU Emacs's `(window-list frame minibuf)'.
      ;; The tree's internal windows are not among them - nothing can be
      ;; shown in one and no command can select one.
      ;;
      ;; **MINIBUF decides about the minibuffer window**, exactly as
      ;; `window_list_1` does (`window.c`): "MINIBUF t means include the
      ;; minibuffer window, even if it isn't active. MINIBUF nil or
      ;; omitted means include the minibuffer window only if it's
      ;; active. MINIBUF neither nil nor t means never include the
      ;; minibuffer window." That rule is what makes `C-x o` cycle into
      ;; the prompt while it is being read and skip it otherwise - and
      ;; what keeps `posn-at-x-y` from answering the echo row when
      ;; nothing is being prompted there.
      ;;--------------------------------------------------------------
      (let* ((frame (if (pair? args) (car args) (*current-frame*)))
             (minibuf (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (all (let walk ((windows (if frame (frame-windows frame) '())))
                    (cond ((null? windows) '())
                          ((window-internal? (car windows))
                           (append (walk (window-children (car windows)))
                                   (walk (cdr windows))))
                          (else (cons (car windows) (walk (cdr windows))))))))
        (let ((mini (and frame (frame-minibuffer-window frame))))
          (cond
           ((not mini) all)
           ;; t: include it whether or not it is active
           ((eq? minibuf #t) all)
           ;; nil or omitted: include it only while it is active
           ((or (null? minibuf) (eq? minibuf #f))
            (if (minibuffer-window-active-p mini)
                all
                (delq mini all)))
           ;; any other value: never include it
           (else (delq mini all))
           ))))

    (define (window-minibuffer-p window)
      ;; GNU Emacs's `window-minibuffer-p' (`window.c`): "Return t if
      ;; WINDOW is a minibuffer window." The frame has exactly one, and it
      ;; is `FRAME_MINIBUF_WINDOW`.
      ;;--------------------------------------------------------------
      (and (window-type? window)
           (let ((frame (window-frame window)))
             (and frame (eq? window (frame-minibuffer-window frame))))))

    (define (minibuffer-window-active-p window)
      ;; GNU Emacs's `minibuffer-window-active-p' (`window.c:...`): whether
      ;; WINDOW is the frame's minibuffer window *and* is being used for a
      ;; read right now.
      ;;
      ;; It asks about the window's buffer, which is how Emacs can tell:
      ;; the minibuffer window always exists, and `read_minibuf` gives it
      ;; the prompt's buffer (`set_window_buffer`). Here it is the same
      ;; question - the window has a buffer, and that buffer is the one
      ;; `*echo-area-buffer*` names.
      ;;--------------------------------------------------------------
      (and window
           (window-type? window)
           (eq? window (and (*current-frame*)
                            (frame-minibuffer-window (*current-frame*))))
           (let ((b (window-buffer window)))
             (and b (eq? b (*echo-area-buffer*))))))

    (define (window-point window)
      ;; The character index point is at in WINDOW: GNU Emacs's
      ;; `window-point'. For the selected window that is the buffer's
      ;; own point - a buffer has one point, and the selected window is
      ;; where it is. For any other window it is the point the window is
      ;; holding, which is where point would be if that window were
      ;; selected.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (if (and frame
                 (eq? window (frame-selected-window frame)))
            (buffer-pt (window-buffer window))
            (marker-position (%window-point window)))))

    (define (set-window-point! window index)
      ;; Make point in WINDOW be at INDEX: GNU Emacs's
      ;; `set-window-point', which moves point itself when the window is
      ;; the selected one.
      ;;--------------------------------------------------------------
      (set-marker (%window-point window) index (window-buffer window))
      (when (eq? window (selected-window))
        (set-point (window-buffer window) index))
      index)

    (define (mouse-position)
      ;; GNU Emacs's `mouse-position' (`frame.c'): "Return a list
      ;; (FRAME X . Y) giving the current mouse frame and position. The
      ;; position is given in canonical character cells, where (0, 0) is
      ;; the upper-left corner of the frame ... If Emacs is running on a
      ;; mouseless terminal or hasn't been programmed to read the mouse
      ;; position, it returns the selected frame for FRAME and nil for X
      ;; and Y."
      ;;
      ;; **The display is asked, every time.** That is the C's shape -
      ;; `Fmouse_position' calls the terminal's `mouse_position_hook',
      ;; which on X is `XQueryPointer' - and it is not a detail: an
      ;; event's coordinates are relative to the window under the
      ;; pointer and say nothing once the pointer has left it, and the
      ;; one caller that needs the position there is a drag scrolling a
      ;; window's edge.
      ;;
      ;; `mouse-position-function' is not carried, and that is the one
      ;; departure: it is how a terminal answers the question (the
      ;; `xt-mouse.el' advice that reads it off the last mouse event),
      ;; so a drag in the terminal front end gets `nil' here and does not
      ;; scroll. Nothing in this tree reads a mouse on a terminal yet.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (position (and frame
                            (display-mouse-position (frame-output frame)))))
        (if position
            (cons frame position)
            (cons frame (cons #f #f)))))

    (define (window-body-height window)
      ;; The rows of the window available to text: everything above its
      ;; mode line. GNU Emacs's `window-body-height'.
      ;;--------------------------------------------------------------
      (max 1 (- (window-height window) 1)))

    (define (window-right-border? window)
      ;; Whether the last column of WINDOW is the vertical border that
      ;; separates it from a window to its right. Side by side windows
      ;; are divided by one column - GNU Emacs's frame vertical border,
      ;; drawn down a text terminal as `|' - and the column belongs to
      ;; the window on its left, which is why that window's width is one
      ;; more than the text it can show.
      ;;
      ;; **The window's own frame**, Emacs's `WINDOW_RIGHTMOST_P`
      ;; (`window.h:687') over `WINDOW_XFRAME (W)'. Reading the selected
      ;; frame meant a window in a second frame was tested against the
      ;; first frame's window tree - and `window-body-width' below is
      ;; this test, so the error reaches the wrapping and the cursor's
      ;; screen position.
      ;;--------------------------------------------------------------
      (let ((frame (window-frame window)))
        (and frame
             (let ((right (+ (window-left window) (window-width window)))
                   (top (window-top window))
                   (bottom (+ (window-top window) (window-height window))))
               ;; the frame's *leaves*, not the frame's list: a split puts
               ;; an internal window where a leaf stood, and an internal
               ;; window is not beside anything on the screen
               (let loop ((rest (window-list frame)))
                 (cond
                  ((null? rest) #f)
                  ((eq? (car rest) window) (loop (cdr rest)))
                  ((and (= (window-left (car rest)) right)
                        (< (window-top (car rest)) bottom)
                        (< top (+ (window-top (car rest))
                                  (window-height (car rest)))))
                   #t)
                  (else (loop (cdr rest)))))))))

    (define (window-body-width window)
      ;; The columns of the window available to text: GNU Emacs's
      ;; `window-body-width', which is the window's width less the
      ;; vertical border when it has a window to its right.
      ;;--------------------------------------------------------------
      (let ((width (window-width window)))
        (if (window-right-border? window) (- width 1) width)))

    (define (window-edges window)
      ;; The window's rectangle as (LEFT TOP RIGHT BOTTOM), Emacs's
      ;; `window-edges'. RIGHT and BOTTOM are one past the last row and
      ;; column the window draws on.
      ;;--------------------------------------------------------------
      (list (window-left window)
            (window-top window)
            (+ (window-left window) (window-width window))
            (+ (window-top window) (window-height window))))

    (define (set-window-start! window position)
      ;; Make WINDOW's display begin at buffer position POSITION - GNU
      ;; Emacs's `set-window-start' (`window.c'), whose body is
      ;;
      ;;     set_marker_restricted (w->start, pos, w->contents);
      ;;     w->start_at_line_beg = (pos == BEGV || FETCH_BYTE (pos - 1) == '\n');
      ;;
      ;; The C sets the two together at *every* site that touches
      ;; `start', so they cannot disagree, and this is that pair. The
      ;; character before the start is a line break exactly when the
      ;; start begins a line.
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        ;; `set_marker_restricted` makes the marker if the window has
        ;; none - which a window made without a buffer (`make_window`,
        ;; and this tree's minibuffer window) does not until its first
        ;; `set_window_buffer`.
        (if (%window-start window)
            (set-marker (%window-start window) position buffer)
            (set!%window-start window (build-marker buffer position)))
        ;; `fetch-char' is `char-after', so the comparison is `char=?'
        ;; and `#\newline' - and a position with no character before it is
        ;; the beginning of the buffer by definition.
        (set!%window-start-at-line-beg
         window
         (or (= position (buffer-beg buffer))
             (let ((before (fetch-char buffer (- position 1))))
               (and (char? before) (char=? #\newline before)))))
        position))

    (define *window-scroll-function*
      ;; GNU Emacs's `scroll-up-command` (`simple.el:5175`) is
      ;; `(scroll-up (prefix-numeric-value arg))` and `scroll-up` is
      ;; `(window_scroll (selected-window) ...)` (`window.c:7533`) - a
      ;; **screen**-line scroll, through `window_scroll_pixel_based`.
      ;; `simple.scm` cannot reach the display, so the call goes through
      ;; this seam, as `record-window-buffer` does; `xdisp.scm` installs
      ;; `window-scroll` at load and a front end with no display never
      ;; sees the seam called.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *record-window-buffer-function*
      ;; GNU Emacs's `Fset_window_buffer` calls `record-window-buffer`
      ;; (`window.c:4475`: `calln (Qrecord_window_buffer, window)`) on the
      ;; way in, so a window's previous buffer is recorded before it is
      ;; replaced. That function is `window.el`'s, in the library above
      ;; this one, so the call goes through this seam - the same device as
      ;; `*message-function*`.
      ;;--------------------------------------------------------------
      (make-parameter (lambda (window) #f)))

    (define (set-window-buffer! window buffer)
      ;; Show BUFFER in WINDOW - GNU Emacs's `set_window_buffer'
      ;; (`window.c:4337'). For a window that is actually changing
      ;; buffer the C does:
      ;;
      ;;   w->window_end_pos = 0;
      ;;   w->window_end_vpos = 0;
      ;;   w->hscroll = w->min_hscroll = 0;
      ;;   w->suspend_auto_hscroll = false;
      ;;   set_marker_both (w->pointm, buffer, BUF_PT (b), ...);
      ;;   set_marker_restricted (w->start, b->last_window_start, buffer);
      ;;   w->start_at_line_beg = false;
      ;;   w->base_line_number = 0;
      ;;
      ;; Everything the window recorded about what it was showing is
      ;; discarded, because all of it described the old buffer.
      ;;
      ;; Not ported: `b->last_window_start' (`window.c:2521'), the start
      ;; the buffer had in the last window to be disconnected from it -
      ;; it is a buffer-local slot, and this library is below the one
      ;; that owns the buffer's slots. It would also have no effect here:
      ;; `scroll-to-cursor!' recomputes a window's start from its point
      ;; on every redisplay, where the C's `w->start' survives until
      ;; redisplay decides otherwise. A buffer with no remembered start
      ;; is at `BEG', which is what `allocate_buffer' gives it too.
      ;;
      ;; One deliberate difference: the C writes `start_at_line_beg =
      ;; false' here and lets redisplay recompute it, where
      ;; `set-window-start!' computes it from the text at once. The
      ;; value is the same one redisplay would arrive at; writing it now
      ;; keeps the invariant that the flag always describes the start.
      ;;--------------------------------------------------------------
      (let ((old (window-buffer window)))
        ;; "Record the buffer the window was showing before it is
        ;; replaced" - the C's `calln (Qrecord_window_buffer, window)`
        ;; (`window.c:4475`), made only when the buffer is really
        ;; changing, which is the `if` it sits in.
        ;;
        ;; **And only when there was a buffer to record.** The minibuffer
        ;; window is bufferless until its first prompt, and recording that
        ;; `#f` puts a nil entry in its `prev-buffers`.
        (when (and old (not (eq? old buffer)))
          ((*record-window-buffer-function*) window))
        (set!window-buffer window buffer)
        (set!%window-end-pos window 0)
        (set!%window-end-vpos window 0)
        (set!%window-end-valid? window #f)
        (set!%window-base-line-number window 0)
        (set!%window-base-line-pos window 0)
        (set!%window-hscroll window 0)
        (set!%window-min-hscroll window 0)
        (set!%window-suspend-auto-hscroll? window #f)
        ;; **The point marker is made when the window first gets a
        ;; buffer.** `make_window` leaves `w->pointm` nil and
        ;; `set_window_buffer` makes it here (`set_marker_both (w->pointm,
        ;; buffer, BUF_PT (b), ...)`, `window.c:4375`); the minibuffer
        ;; window is made with no buffer, so it has none to write.
        (if (%window-point window)
            (set-marker (%window-point window) (buffer-pt buffer) buffer)
            (set!%window-point window (build-marker buffer (buffer-pt buffer))))
        (set-window-start! window 1)
        ;; **A window that changed buffer has nothing of the new one on
        ;; the screen**, so the frame is garbaged and the next redisplay
        ;; repaints all of it. GNU Emacs reaches the same place without a
        ;; flag: `set_window_buffer` ends with `w->window_end_valid =
        ;; false` and `redisplay_window` then finds the current matrix
        ;; does not describe what should be there and runs `redraw_frame`
        ;; through `try_window_reusing`'s failure path. This tree compares
        ;; matrices rather than checking a validity flag, and the rows it
        ;; would compare are the *old buffer's* - so without this the diff
        ;; matched them, drew nothing, and the previous file's lines stayed
        ;; on screen under the new file's. That is "two files in one
        ;; window".
        (unless (eq? old buffer)
          (set-frame-garbaged! (window-frame window) #t))
        window))

    (define (window-start-at-line-beg window)
      ;; Whether WINDOW's display begins at the beginning of a line.
      ;; GNU Emacs's `window-start-at-line-beg'? There is no Elisp
      ;; function for it - `w->start_at_line_beg' is read by `xdisp.c'
      ;; and `window.c' alone - so this is the accessor under this
      ;; tree's name for it.
      ;;--------------------------------------------------------------
      (%window-start-at-line-beg window))

    (define (window-base-line-number window)
      ;; The cached line number of `window-base-line-pos', or 0 when
      ;; there is none: the field GNU Emacs's `decode_mode_spec' reads
      ;; for `%l'. See `mode-line-construct' in `xdisp'.
      ;;--------------------------------------------------------------
      (%window-base-line-number window))

    (define (window-base-line-pos window)
      ;; Where that cached line begins - a buffer position, 0 for "no
      ;; base line", -1 for "do not show a line number in this window".
      ;;--------------------------------------------------------------
      (%window-base-line-pos window))

    (define (make-frame-window frame buffer top height left width)
      ;; A window filling the given rectangle, showing BUFFER: a leaf
      ;; FRAME holds directly.
      ;;--------------------------------------------------------------
      ;; The window's display begins at position 1, which is where GNU
      ;; Emacs's `set_window_buffer' puts `w->start' - and at `BEG' the
      ;; start *is* a line beginning, so `start-at-line-beg' is true
      ;; here exactly as the C's `(pos == BEGV || ...)' makes it.
      ;;
      ;; **The point is the buffer's, not 1.** `set_window_buffer` sets
      ;; the point marker from the buffer (`window.c:4375'):
      ;;
      ;;   set_marker_both (w->pointm, buffer, BUF_PT (b), BUF_PT_BYTE (b));
      ;;
      ;; so a frame made while point is in the middle of a buffer opens
      ;; showing that place. Written as 1, `C-x 5 2' put the new window
      ;; at the top of the file wherever the old one was - measured on
      ;; Emacs 31.1: point at 21, the new frame's `window-point' is 21.
      ;; **A window may show no buffer yet**, which is the minibuffer
      ;; window before a prompt is read: GNU Emacs's `make_window` gives
      ;; `w->contents` as nil and `set_window_buffer` fills it in
      ;; (`window.c:4337`). `minibuffer-window-active-p` is the test for
      ;; whether it has one.
      (if buffer
          (make<window> frame buffer (build-marker buffer (buffer-pt buffer))
                        (build-marker buffer 1) #t
                        0 0 #f 0 0
                        top height left width #f '()
                        0 0 #f 0 '() '()
                        ;; nothing built yet: `window_outdated?` says so
                        #f 0 0 0 0 0 0 0 -1 #f)
          (make<window> frame #f #f #f #f
                        0 0 #f 0 0
                        top height left width #f '()
                        0 0 #f 0 '() '()
                        #f 0 0 0 0 0 0 0 -1 #f)))

    ;;----------------------------------------------------------------
    ;; Editor state

    (define-record-type <frame>
      (make<frame>
       windows selected-window minibuffer-window height width
       message message-timer keymap-state quit-cont output name
       parameters garbaged new-width new-height new-size-p
       menu-bar-items menu-bar-items-used)
      frame-type?
      (windows   frame-windows   set!frame-windows)
      ;; ^ The frame's windows, top to bottom. Emacs's `window-list'.
      (minibuffer-window frame-minibuffer-window
                         set!frame-minibuffer-window)
      ;; ^ `f->minibuffer_window` (`frame.h`), read as
      ;; `FRAME_MINIBUF_WINDOW (f)`: **the window the echo area is**.
      ;; GNU Emacs gives every frame one (`make_frame` sets it,
      ;; `frame.c:1237`), it is the frame's last row, and its buffer is
      ;; the minibuffer while a prompt is being read. Emacs therefore has
      ;; no "echo area" concept in the redisplay path at all - a prompt is
      ;; an ordinary window showing an ordinary buffer, which is why a
      ;; click on it selects it and `C-x o` can cycle into it.
      ;;
      ;; This tree drew the echo area as a special row of the frame, and
      ;; that one departure was the root of three bugs at once: a click on
      ;; the prompt reached `select-window` as a *frame* ("Wrong type
      ;; argument: #<<frame> ..."), `C-x o` could not reach the prompt so
      ;; a click into another buffer could not be undone, and
      ;; `mouse-drag-track` asked `window-buffer` of a frame. The window
      ;; is made with the frame and is *always* in `frame-windows`; every
      ;; consumer asks `minibuffer-window-active-p` rather than being
      ;; handed it only when it is wanted.
      (selected-window frame-selected-window
                       set!frame-selected-window)
      ;; ^ The window commands act on and the cursor is drawn in, Emacs's
      ;; `selected-window'. #f only before the first window is made.
      (height    frame-height             set!frame-height)
      ;; ^ The frame's height in rows, GNU Emacs's `frame-height': the
      ;; rows the terminal gives the editor, which is what a window made
      ;; to fill the frame is measured against. It is taken from the
      ;; terminal when the frame is made and refreshed on each redisplay,
      ;; so that a window that gets resized is noticed.
      (width     frame-width              set!frame-width)
      ;; ^ The frame's width in columns, GNU Emacs's `frame-width'.
      (message    frame-message    set!frame-message-text)
      ;; ^ A message string drawn in the echo area, or false.
      (message-timer frame-message-timer set!frame-message-timer)
      ;; ^ The timer that will take that message down, or false for a
      ;; message that stays until the next key. GNU Emacs keeps the same
      ;; timer in `minibuffer-message-timer': `minibuffer-message' arms
      ;; it with `run-at-time' (`minibuffer.el:861') and
      ;; `clear-minibuffer-message' cancels it (`:1050'), which the C's
      ;; `clear_message' reaches through `clear-message-function'
      ;; (`xdisp.c:13663').
      ;;
      ;; The timer *is* the timeout - there is no separate time to
      ;; compare against, which is what lets a front end that owns its
      ;; loop wait for a key rather than for a clock. The command loop
      ;; used to hold a time here and give its key read a timeout while
      ;; one was pending; that poll is what this replaced.
      (keymap-state frame-keymap-state set!frame-keymap-state)
      ;; ^ A pending modal keymap lookup state, or false. It persists
      ;; between key events when a key chord (such as C-x C-s) is
      ;; partially entered.
      (quit-cont  frame-quit-cont  set!frame-quit-cont)
      ;; ^ An escape continuation captured by the event loop, invoked
      ;; by `save-buffers-kill-terminal` to exit the editor.
      (output     frame-output     set!frame-output)
      ;; ^ The display this frame is drawn on: Emacs's `output_data',
      ;; which points a frame at its terminal's output data. Set when
      ;; the frame is made (the display is the one the platform
      ;; opened), and #f for a frame made with no display - a test.
      ;;
      ;; There was a `crlf?' slot here, holding the visited file's
      ;; line-break convention. It is gone: the convention belongs to the
      ;; buffer, not to the frame a buffer happens to be shown in - GNU
      ;; Emacs keeps it in the buffer's `buffer-file-coding-system' - and
      ;; a frame-wide one meant that saving a CRLF file after visiting an
      ;; LF file rewrote it with LF, and the other way round. It is
      ;; buffer-local in `(schemacs editor files)' now.
      (name       frame-name       set!frame-name)
      ;; ^ The frame's name: `F1', `F2', ... - Emacs's `f->name', which
      ;; `fset_name (f, frame_next_F_name ())' sets as the frame is made
      ;; (`frame.c:1562'). The mode line shows it through `%F'
      ;; (`mode-line-frame-identification'), which this tree does not draw
      ;; yet; the name is here because a frame has one and it is what the
      ;; frame commands report.
      (garbaged   frame-garbaged-p  set-frame-garbaged!)
      ;; ^ `f->garbaged` (`frame.h:1172`): "True if frame F is currently
      ;; garbaged." The reader is `FRAME_GARBAGED_P` and the writer is
      ;; `SET_FRAME_GARBAGED` (`:1173`), which is what the two are named
      ;; for - Emacs spells a boolean predicate `..._P` and this tree
      ;; spells it `-p`, so neither carries a `?` that would belong to a
      ;; different kind of question. Consumed by `clear_garbaged_frames`
      ;; (`xdisp.c:13699`).
      ;;
      ;; **This is the whole of "the surface holds nothing of ours".**
      ;; Emacs's own note there says why a flag and not a clear:
      ;; "The call to clear_frame was a source of flickering. I believe
      ;; a clear_frame is not necessary. It should suffice ... to
      ;; invalidate all current matrices, and ensure a complete
      ;; redisplay of all windows." Clearing the surface and then
      ;; redrawing only the rows the diff calls changed leaves every
      ;; other row erased - which is a redisplay that flickers between
      ;; two half-painted screens, and the reason paging to the end of a
      ;; buffer appeared to loop.
      ;;
      ;; Set when the frame is made and when a resize throws the
      ;; toolkit's contents away (`f->resized_p`); consumed by
      ;; `render!`'s `clear-garbaged-frames!`.
      (parameters frame-parameters-alist set!frame-parameters-alist)
      ;; ^ `f->param_alist` (`frame.h`): the frame's parameters, as
      ;; `(NAME . VALUE)` pairs. `frame-parameters` (`frame.c:4083`) and
      ;; its three relatives below read and write it. A parameter that
      ;; only the display can act on is read where it is used: the gtk
      ;; front end asks `menu-bar-lines` when it decides whether the bar
      ;; is showing.
      (new-width  frame-new-width  set!frame-new-width)
      (new-height frame-new-height set!frame-new-height)
      (new-size-p frame-new-size-p set!frame-new-size-p)
      ;; ^ `f->new_width`, `f->new_height` and `f->new_size_p`
      ;; (`frame.h`): a size change that could not be made where it was
      ;; asked for, waiting to be applied. A signal handler runs at a
      ;; point where re-tiling windows is not safe - Emacs's
      ;; `handle_window_change_signal` says so in as many words: "Record
      ;; the new sizes, but don't reallocate the data structures now. Let
      ;; that be done later outside of the signal handler"
      ;; (`dispnew.c:6630`) - so a tty resize is parked here and applied
      ;; by `do-pending-window-change`. -1 in both means "no change
      ;; pending", as it does in the C: a native size is never negative.
      (menu-bar-items frame-menu-bar-items set!frame-menu-bar-items)
      (menu-bar-items-used frame-menu-bar-items-used
                           set!frame-menu-bar-items-used)
      ;; ^ `f->menu_bar_vector` and `f->menu_bar_items_used`
      ;; (`frame.h`): the menu bar's items as the redisplay last built
      ;; them, `[KEY NAME DEFS X KEY NAME DEFS X ...]`, X being the
      ;; column the item was drawn at. It is a *cache*, and the column is
      ;; the reason: `display_menu_bar` writes each item's position into
      ;; this vector as it draws it (`xdisp.c:27843`), and
      ;; `menu-bar-menu-at-x-y` (`menu.c:1049`) reads it back to turn a
      ;; click into the item under it. The gtk front end keeps its own
      ;; copy of the built array on the display; this is the one the
      ;; terminal's redisplay and the bar's commands share.
      )

    (define (window-outdated? window)
      ;; GNU Emacs's `window_outdated` (`window.c:231`): "True if leaf
      ;; window W doesn't reflect the actual state of displayed buffer due
      ;; to its text or overlays change."
      ;;
      ;; It is the question the redisplay asks before reusing a window's
      ;; glyph matrix: if neither tick has moved since the matrix was
      ;; built, the text it was built from is the text the buffer holds.
      ;; **The buffer itself is compared too.** A window that has just been
      ;; given another buffer may well find that buffer at the same tick -
      ;; two fresh buffers are both at 1 - and its matrix is of the wrong
      ;; text.
      ;;
      ;; **It is here and not in `window.scm`**, where Emacs's is: the
      ;; redisplay is `xdisp.scm`'s and `xdisp.scm` is *below*
      ;; `window.scm`, so a question the redisplay asks has to be
      ;; answerable from the library that owns the window record.
      ;;--------------------------------------------------------------
      (let ((buffer (window-buffer window)))
        (or (not (eq? buffer (window-last-buffer window)))
            (< (window-last-modified window) (buffer-modified-tick buffer))
            (< (window-last-overlay-modified window)
               (buffer-overlay-modified-tick buffer)))))

    (define (frame? thing)
      ;; GNU Emacs's `framep' (`frame.c'): "Return t if OBJECT is a
      ;; frame". Emacs also answers `t', `x', `w32' and the rest for the
      ;; *type*; this tree has one frame type, so it is a predicate.
      ;;--------------------------------------------------------------
      (frame-type? thing))

    ;;----------------------------------------------------------------
    ;; Frame parameters - `frame.c`'s `param_alist` and its readers
    ;;----------------------------------------------------------------

    (define *default-frame-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `default-frame-alist` (`frame.el:170`): "Alist of
    ;; default values for the parameters of all frames you create."
    ;; A frame's parameters start from this.

    (define *initial-frame-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `initial-frame-alist` (`frame.el:135`): "Alist of
    ;; frame parameters for the frame that is created at startup" -
    ;; merged over `default-frame-alist` for the first frame only.

    (define (store-in-alist alist prop value)
      ;; GNU Emacs's `store_in_alist` (`frame.c:4037`): "Store PROP's
      ;; VALUE into ALIST, which is an association list." A new pair is
      ;; *prepended*; an existing one is changed in place.
      ;;--------------------------------------------------------------
      (let ((cell (assq prop alist)))
        (if cell
            (begin (set-cdr! cell value) alist)
            (cons (cons prop value) alist))))

    (define (%make-frame-parameters)
      ;; The parameters a new frame starts with: `initial-frame-alist`
      ;; for the first frame, then `default-frame-alist` over it - which
      ;; is the order `make-frame` merges them in.
      ;;--------------------------------------------------------------
      ;; `frame-initial-frame-alist` (`frame.el:427`) is
      ;; `(append initial-frame-alist default-frame-alist)` - initial
      ;; first, so it *wins* where the two name the same parameter.
      (if (null? (*frame-list*))
          (append (*initial-frame-alist*) (*default-frame-alist*))
          (append (*default-frame-alist*) '())))

    (define (%frame-menu-bar-lines frame)
      ;; `FRAME_MENU_BAR_LINES` (`frame.h`), which `x_set_menu_bar_lines`
      ;; sets from the `menu-bar-lines` parameter. **A frame with no such
      ;; parameter shows the bar**: Emacs's toolkit backends build the
      ;; menu bar with the frame (`xg_create_frame_widgets`), and
      ;; `menu-bar-mode` is on by default - the parameter is how it is
      ;; turned off, not on.
      ;;--------------------------------------------------------------
      (let ((pair (assq 'menu-bar-lines (frame-parameters-alist frame))))
        (if pair (cdr pair) 1)))

    (define (frame-top-margin frame)
      ;; GNU Emacs's `FRAME_TOP_MARGIN` (`frame.h:1132`): the rows of the
      ;; frame above every window - "the menu bar, the tab bar and the
      ;; tool bar", of which a terminal has the first two. A window's
      ;; `top_line` is measured from here, not from the frame's own top
      ;; (`window.c:5021`), which is what makes the menu bar a row the
      ;; windows do not use.
      ;;
      ;; **A toolkit's menu bar is not one of those rows.** A Gtk frame's
      ;; bar is a widget stacked above the drawing area, so the frame's
      ;; text area begins below it already - `FRAME_MENU_BAR_LINES` is 0
      ;; on such a frame, and the `menu-bar-lines` parameter only says
      ;; whether the widget is showing. A terminal's bar *is* a row of
      ;; the text area, which is why this is the one place the two
      ;; differ.
      ;;--------------------------------------------------------------
      (let ((display (frame-output frame)))
        (if (and display (window-system-display? display))
            0
            (let ((pair (assq 'tab-bar-lines
                              (frame-parameters-alist frame))))
              (+ (%frame-menu-bar-lines frame)
                 (if pair (cdr pair) 0))))))

    (define (frame-parameters . args)
      ;; GNU Emacs's `frame-parameters` (`frame.c:4083`): "Return the
      ;; parameters-alist of frame FRAME."
      ;;
      ;; The C copies `f->param_alist` and then *stores* what the frame
      ;; knows: its name, size, whether it wants a mode line, its menu bar
      ;; lines. A stored value wins over a computed one only if it was
      ;; stored, which is what `store_in_alist` does.
      ;;
      ;; **Not stored here**: `foreground-color`/`background-color`/`font`
      ;; and the window-system keys. The first three are the face
      ;; machinery's - this library sits below it - and the rest describe
      ;; a display server this tree does not model.
      ;;--------------------------------------------------------------
      (let ((frame (if (and (pair? args) (car args)) (car args)
                       (*current-frame*))))
        (if (not (frame-live-p frame))
            #f
            (let ((alist (map (lambda (pair) (cons (car pair) (cdr pair)))
                              (frame-parameters-alist frame))))
              (set! alist (store-in-alist alist 'name (frame-name frame)))
              (set! alist (store-in-alist alist 'height (frame-height frame)))
              (set! alist (store-in-alist alist 'width (frame-width frame)))
              (set! alist (store-in-alist alist 'modeline #t))
              (set! alist (store-in-alist alist 'unsplittable #f))
              (set! alist (store-in-alist alist 'buffer-list '()))
              (set! alist (store-in-alist alist 'buried-buffer-list '()))
              (set! alist (store-in-alist alist 'menu-bar-lines
                                          (%frame-menu-bar-lines frame)))
              (set! alist (store-in-alist alist 'tab-bar-lines 0))
              (set! alist (store-in-alist alist 'visibility #t))
              (set! alist (store-in-alist alist 'no-accept-focus #f))
              alist))))

    (define (frame-parameter frame parameter)
      ;; GNU Emacs's `frame-parameter` (`frame.c:4172`): "Return FRAME's
      ;; value for parameter PARAMETER."
      ;;
      ;; The C answers `name` from the field without an alist lookup, and
      ;; everything else out of `frame-parameters` when the alist has no
      ;; entry - so a computed parameter (the size, the menu bar lines)
      ;; answers even though it was never stored.
      ;;--------------------------------------------------------------
      (let ((frame (or frame (*current-frame*))))
        (cond ((not (frame-live-p frame)) #f)
              ((eq? parameter 'name) (frame-name frame))
              (else
               (let ((pair (assq parameter (frame-parameters-alist frame))))
                 (if pair
                     (cdr pair)
                     (let ((all (assq parameter (frame-parameters frame))))
                       (and all (cdr all)))))))))

    (define (set-frame-parameter frame parameter value)
      ;; GNU Emacs's `set-frame-parameter` (`frame.c`): "Set FRAME's
      ;; parameter PARAMETER to VALUE." Stored, and acted on where the
      ;; parameter means something this tree can act on: `name` renames
      ;; the frame, and `menu-bar-lines` is read by the front end when it
      ;; decides whether the bar is showing.
      ;;--------------------------------------------------------------
      (let ((frame (or frame (*current-frame*))))
        (set!frame-parameters-alist
         frame (store-in-alist (frame-parameters-alist frame) parameter value))
        (when (eq? parameter 'name)
          (set!frame-name frame value))
        ;; **Turning the bar on or off re-tiles the frame.** GNU Emacs's
        ;; `x_set_menu_bar_lines` ends in `adjust_frame_size (f, -1, -1, 4,
        ;; false, Qmenu_bar_lines)`, which is what gives the text area the
        ;; row back (or takes it) - `FRAME_TOP_MARGIN` changed, and every
        ;; window's `top_line` is measured from it. Without this,
        ;; `menu-bar-mode -1` left a blank row at the top and a window one
        ;; row too short.
        (when (eq? parameter 'menu-bar-lines)
          (resize-frame-windows! frame (frame-height frame) (frame-width frame)
                                 (frame-height frame) (frame-width frame)))
        value))

    (define (modify-frame-parameters frame alist)
      ;; GNU Emacs's `modify-frame-parameters` (`frame.c:4244`): "Modify
      ;; FRAME according to new values of its parameters in ALIST."
      ;;
      ;; The C's terminal branch applies `height` and `width` through
      ;; `Fset_frame_size` and stores everything else. Here the size is
      ;; the compositor's and the mode line is drawn from `frame-height`
      ;; on every redisplay, so a stored size takes effect on the next
      ;; frame that is asked for - which is what `adjust-frame-size!`
      ;; already arranges for the font. Everything is stored either way,
      ;; which is what the C's last paragraph promises.
      ;;--------------------------------------------------------------
      (let ((frame (or frame (*current-frame*))))
        (for-each (lambda (entry)
                    (set-frame-parameter frame (car entry) (cdr entry)))
                  alist)
        frame))

    (define (face-set-after-frame-default frame . optional)
      ;; GNU Emacs's `face-set-after-frame-default' (`faces.el:2274'):
      ;; "Initialize the frame-local faces of FRAME. Calculate the face
      ;; definitions using the face specs, custom theme settings, X
      ;; resources, and `face--new-frame-defaults'. Finally, apply any
      ;; relevant face attributes found amongst the frame parameters in
      ;; PARAMETERS."
      ;;
      ;; **The placement is a departure, of the kind this tree already
      ;; has in `fileio.scm' and `menu-bar.scm'**: the function is
      ;; `faces.el''s, and it reads the frame's parameters, which are
      ;; this library's. `faces.scm' is below `frame.scm`, so the
      ;; function that needs both lives in the library that has the
      ;; upper half.
      ;;
      ;; **Not carried**: `face--new-frame-defaults' and
      ;; `internal-merge-in-global-face', the attributes a frame that is
      ;; not made yet carries. This tree has one set of face attributes
      ;; rather than one per frame plus a set of defaults, which
      ;; `faces.scm''s header names as the data-model deviation.
      ;;
      ;; It is what `disable-theme' runs after resetting the frame's
      ;; colours (`custom.el:1704'): a disabled theme's colour lives in
      ;; the default face until the frame parameters are put back over
      ;; it. `pgtk-ensure-font!' and `initialize-display-faces!' already
      ;; do this function's two halves at frame creation in their own
      ;; front ends; this is the same pair, in the same order, for a
      ;; caller that has no frame of its own to create.
      ;;--------------------------------------------------------------
      (let ((parameters (if (and (pair? optional) (car optional))
                            (car optional)
                            (frame-parameters frame))))
        ;; "The `reverse' is so that `default' goes first."
        (for-each (lambda (face)
                    ;; "Don't let invalid specs prevent frame creation."
                    (guard (err (else #f))
                      (face-spec-recalc face)))
                  (reverse (face-list)))
        ;; Apply attributes specified by frame parameters.
        (for-each
         (lambda (param)
           ;; The C's `(cdr (assq PARAM-NAME parameters))' - and it is
           ;; `assq''s answer that has to be tested, not the `cdr`'s:
           ;; `(cdr #f)' raises here where Elisp's `(cdr nil)' is nil.
           (let ((cell (assq (car param) parameters)))
             (when cell
               (set-face-attribute (cadr param) frame (caddr param)
                                   (cdr cell)))))
         '((foreground-color default :foreground)
           (background-color default :background)
           (font default :font)
           (border-color border :background)
           (cursor-color cursor :background)
           (scroll-bar-foreground scroll-bar :foreground)
           (scroll-bar-background scroll-bar :background)
           (mouse-color mouse :background))))
      frame)

    (define (frame-cancel-message-timer! frame)
      ;; Take down the timer that would clear FRAME's message, if one is
      ;; armed. GNU Emacs's `clear-minibuffer-message'
      ;; (`minibuffer.el:1050') is exactly this, and it is what
      ;; `clear-message-function' is set to (`minibuffer.el:1075') so
      ;; that the C's `clear_message' reaches it (`xdisp.c:13663').
      ;;--------------------------------------------------------------
      (let ((timer (frame-message-timer frame)))
        (when timer (cancel-timer timer))
        (set!frame-message-timer frame #f)))

    (define (set!frame-message frame text)
      ;; Put TEXT in FRAME's echo area, taking down any timeout the
      ;; message it replaces had. A timeout belongs to the message it
      ;; was set with (`SET-MESSAGE!'), and a plain `message' - the
      ;; command loop clearing the echo area, or an error being
      ;; reported - is not meant to inherit the previous one's and
      ;; disappear early.
      ;;--------------------------------------------------------------
      (frame-cancel-message-timer! frame)
      (set!frame-message-text frame text))

    (define (set-message! frame text . args)
      ;; Put TEXT in FRAME's echo area, taking it down again after
      ;; ARGS' first element seconds - or leaving it until the next key
      ;; when there is none. GNU Emacs's `message' pairs a string with
      ;; the timer `minibuffer-message' arms for it (`minibuffer.el:861',
      ;; `minibuffer-message-timeout' being the two seconds it uses);
      ;; the two are set together here so that a message cannot be left
      ;; with neither the previous message's timer nor its own.
      ;;
      ;; The timer clears the message by setting it to "", which is
      ;; Emacs's `(message nil)' from `minibuffer--delete-message-overlay'
      ;; (`minibuffer.el:846'). `timer-check!' answers whether it ran, so
      ;; the redisplay that shows the message gone is the same one a key
      ;; would have caused.
      ;;--------------------------------------------------------------
      (set!frame-message frame text)
      (when (and (pair? args) (car args))
        (set!frame-message-timer
         frame (run-at-time (car args) #f
                            (lambda () (set!frame-message frame ""))))))

    ;; The frame currently dispatching a key event. Commands read the
    ;; frame through this parameter.
    (define *current-frame* (make-parameter #f))

    ;; `*current-buffer*' is imported from `(schemacs editor buffer)' and
    ;; re-exported, so every library that asks this one for it still finds
    ;; it. GNU Emacs's `current_buffer' is declared in `buffer.c' and this
    ;; is the file that *writes* it, so both need it and a Scheme import
    ;; cannot be circular; the definition is in the lower library now,
    ;; which is the one that defines the buffer record. `select-window'
    ;; below still writes it, unchanged - writing a parameter needs no
    ;; import of the library that made it.

    (define *frame-cursor-type* (make-parameter (cons 'filled-box-cursor 1)))
    ;; ^ The cursor the *frame* wants, as `(TYPE . WIDTH)', which is what
    ;; a buffer whose `cursor-type' is `t' is asking for. GNU Emacs keeps
    ;; it in two fields of `struct frame' - `desired_cursor' and
    ;; `cursor_width' (`frame.h') - filled in by the frame parameter
    ;; handler `x_set_cursor_type' from the frame's `cursor-type'
    ;; parameter, whose default is `t' and so a filled box.
    ;;
    ;; This tree has no frame parameters yet, so it is a parameter - one
    ;; frame, one value, like `*transient-mark-mode*'. It is here rather
    ;; than in a backend because it is the frame's, as those two fields
    ;; are: a terminal and a window system ask the same question of it.
    ;; `(schemacs editor xdisp)''s `get-window-cursor-type' is what reads
    ;; it.
    ;;
    ;; The type symbols are the C's own enum values (`text_cursor_kinds'
    ;; in `dispextern.h') rather than the Lisp spellings a `cursor-type'
    ;; value uses, because this is the resolved answer.

    ;;----------------------------------------------------------------
    ;; The cursor's visibility, and the blinking that turns it off and on
    ;;
    ;; GNU Emacs keeps the flag on the window (`w->cursor_off_p') and the
    ;; blinking in `frame.el'. Both are here, next to the window record
    ;; they are about, because of the import graph: `internal-show-cursor'
    ;; is `dispnew.c''s, and it cannot live in `dispnew.sld' - that sets a
    ;; field of a *window*, and `frame.sld' imports `dispnew.sld', so the
    ;; other direction is a cycle. It is where a reader looking for the
    ;; window's fields will look, which is the point.
    ;;------------------------------------------------------------------

    (define window-cursor-table (make-weak-key-hash-table))
    ;; ^ The windows whose cursor has been blinked off, standing in for
    ;; the `bool_bf cursor_off_p : 1' that `struct window' has in Emacs.
    ;; Beside the window rather than in it so that adding it does not
    ;; change a record every library makes windows with.

    (define (window-cursor-off? window)
      ;; Whether WINDOW's cursor has been blinked off. GNU Emacs's
      ;; `w->cursor_off_p', which `get_window_cursor_type' reads as "use
      ;; normal cursor if not blinked off".
      ;;--------------------------------------------------------------
      (hashq-ref window-cursor-table window #f))

    (define (set!window-cursor-off? window off?)
      (hashq-set! window-cursor-table window (and off? #t)))

    (define (internal-show-cursor window show)
      ;; GNU Emacs's `internal-show-cursor': set WINDOW's cursor-visibility
      ;; flag, so that the next redisplay draws a cursor there or not.
      ;; WINDOW false means the selected window. SHOW false means do not
      ;; show a cursor, which is how a blink hides one.
      ;;
      ;; Emacs also does nothing here "while redisplaying", so that a
      ;; blink cannot change the cursor out from under the output
      ;; routines. This editor has no such flag: the redisplay runs to
      ;; completion between keys, and the only caller is the blink timer,
      ;; which runs between keys too.
      ;;--------------------------------------------------------------
      (set!window-cursor-off? (or window (selected-window)) (not show))
      ;; Emacs redraws when this has changed; here the caller redraws -
      ;; the command loop redraws after a timer ran, which is what makes
      ;; a blink visible.
      #f)

    (define (internal-show-cursor-p window)
      ;; GNU Emacs's `internal-show-cursor-p': whether the next redisplay
      ;; will draw a cursor in WINDOW, which false or omitted means the
      ;; selected window. `blink-cursor-timer-function' is its caller.
      ;;--------------------------------------------------------------
      (not (window-cursor-off? (or window (selected-window)))))

    (define *pre-command-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `pre-command-hook', which `keyboard.c' declares and
    ;; its command loop runs before each command. It is here rather than
    ;; in `keyboard.sld' for the same reason as the flag above: the blink
    ;; below *writes* it and the command loop *reads* it, and
    ;; `keyboard.sld' already imports this library - so the other
    ;; direction would be a cycle. It is with the other frame state.

    (define (run-pre-command-hook!)
      ;; Run the hook, as the command loop does before each command.
      ;; Emacs removes a hook function that signals, "since otherwise the
      ;; error might happen repeatedly and make Emacs nonfunctional";
      ;; this reports and carries on, which is what the command loop does
      ;; with a command's own errors.
      ;;--------------------------------------------------------------
      (for-each (lambda (function) (function)) (*pre-command-hook*)))

    ;;----------------------------------------------------------------
    ;; blink-cursor-mode (frame.el)
    ;;
    ;; Emacs's is a global minor mode, on by default in an interactive
    ;; session, and its docstring names the thing that decides where it
    ;; belongs: "This command is effective only on graphical frames. On
    ;; text-only terminals, cursor blinking is controlled by the
    ;; terminal." So on a terminal this does nothing at all, which is
    ;; right - a terminal blinks its own cursor, and there is one cursor
    ;; for it to blink.
    ;;
    ;; `define-minor-mode' does not exist in this tree yet, so the mode is
    ;; a command that toggles a variable, as `read-only-mode' is. What
    ;; `define-minor-mode' would give it - the customize group, the
    ;; lighter in the mode line - is named here rather than faked.
    ;;------------------------------------------------------------------

    (define *blink-cursor-mode* (make-parameter #t))
    ;; ^ on, as Emacs has it interactively: its `:init-value' is
    ;; `(not (or noninteractive no-blinking-cursor ...))'

    (define *blink-cursor-delay* (make-parameter 0.5))
    (define *blink-cursor-interval* (make-parameter 0.5))
    (define *blink-cursor-blinks* (make-parameter 10))

    (define blink-cursor-idle-timer #f)
    ;; ^ started after `blink-cursor-delay' seconds of idleness

    (define blink-cursor-timer #f)
    ;; ^ the repeating one that does the blinking

    (define blink-cursor-blinks-done 1)

    (define *frame-focus* (make-parameter #t))
    ;; ^ Whether the frame has the window system's focus: GNU Emacs's
    ;; `frame-focus-state', which its backends maintain. It is a
    ;; parameter here for the reason `*frame-cursor-type*' is - one frame,
    ;; one value - and `pgtk.sld' sets it from Gtk's focus events.
    ;;
    ;; Emacs asks, and it is worth asking: "with real emacs it only blinks
    ;; when the window has focus" (Chris). It also decides the cursor's
    ;; *shape*: `get_window_cursor_type' treats a frame that is not the
    ;; display's highlight frame as a non-selected one, which is a hollow
    ;; box rather than a filled one.

    (define (blink-cursor--should-blink)
      ;; GNU Emacs's `blink-cursor--should-blink': "Returns whether we
      ;; have any focused non-TTY frame." This editor has one frame, so
      ;; the two questions are the kind of display it is on - which is
      ;; what `*window-system*' records, Emacs's `display-graphic-p'
      ;; exactly - and whether it has the focus.
      ;;--------------------------------------------------------------
      (and (*blink-cursor-mode*) (*window-system*) (*frame-focus*) #t))

    (define (blink-cursor--rescan-frames)
      ;; GNU Emacs's `blink-cursor--rescan-frames', which its backends
      ;; call from `after-focus-change-function': look again, and stop
      ;; blinking if the answer is now no. When the frame regains the
      ;; focus, `blink-cursor-check' - which the command loop calls - is
      ;; what starts it again.
      ;;--------------------------------------------------------------
      (unless (blink-cursor-check)
        (blink-cursor-suspend)))

    (define (blink-cursor--start-idle-timer)
      ;; The 0.2 second floor is Emacs's, not a convenience: "to avoid
      ;; erratic behavior (or downright failure to display the cursor
      ;; during command execution) if they set blink-cursor-delay to a
      ;; very small or even zero value".
      ;;--------------------------------------------------------------
      (when blink-cursor-idle-timer (cancel-timer blink-cursor-idle-timer))
      (set! blink-cursor-idle-timer
            (run-with-idle-timer (max 0.2 (*blink-cursor-delay*))
                                 #t blink-cursor-start)))

    (define (blink-cursor--start-timer)
      (when blink-cursor-timer (cancel-timer blink-cursor-timer))
      (set! blink-cursor-timer
            (run-with-timer (*blink-cursor-interval*)
                            (*blink-cursor-interval*)
                            blink-cursor-timer-function)))

    (define (blink-cursor-start)
      ;; The idle timer's function: the editor has stopped being typed at,
      ;; so start blinking. The repeating timer is set up first, "so that
      ;; if this signals an error, blink-cursor-end is not added to
      ;; pre-command-hook".
      ;;--------------------------------------------------------------
      (when (not blink-cursor-timer)
        (set! blink-cursor-blinks-done 1)
        (blink-cursor--start-timer)
        (*pre-command-hook* (cons blink-cursor-end (*pre-command-hook*)))
        (internal-show-cursor #f #f)))

    (define (blink-cursor-timer-function)
      ;; Each call is one half of a blink. Emacs stops blinking after
      ;; `blink-cursor-blinks' of them - the cursor stays solid rather
      ;; than blinking for ever while you read.
      ;;--------------------------------------------------------------
      (internal-show-cursor #f (not (internal-show-cursor-p #f)))
      (set! blink-cursor-blinks-done (+ 1 blink-cursor-blinks-done))
      (when (and (> (*blink-cursor-blinks*) 0)
                 (<= (* 2 (*blink-cursor-blinks*)) blink-cursor-blinks-done))
        (blink-cursor-end)))

    (define (blink-cursor-end)
      ;; Stop blinking, and show the cursor: installed on
      ;; `pre-command-hook', so the first key you press after a pause
      ;; gives you a solid cursor to type at.
      ;;--------------------------------------------------------------
      (*pre-command-hook*
       (let loop ((rest (*pre-command-hook*)))
         (cond ((null? rest) '())
               ((eq? (car rest) blink-cursor-end) (cdr rest))
               (else (cons (car rest) (loop (cdr rest)))))))
      (internal-show-cursor #f #t)
      (when blink-cursor-timer
        (cancel-timer blink-cursor-timer)
        (set! blink-cursor-timer #f)))

    (define (blink-cursor-suspend)
      (blink-cursor-end)
      (when blink-cursor-idle-timer
        (cancel-timer blink-cursor-idle-timer)
        (set! blink-cursor-idle-timer #f)))

    (define (blink-cursor-check)
      ;; Start the idle timer if the mode is on and the frame can blink.
      ;; Idempotent, so the command loop can call it as often as it likes:
      ;; Emacs calls it from its focus-change and delete-frame hooks, and
      ;; this editor has neither, so the loop is where it is called.
      ;;--------------------------------------------------------------
      (when (and (blink-cursor--should-blink)
                 (not blink-cursor-idle-timer))
        (blink-cursor--start-idle-timer))
      (blink-cursor--should-blink))

    (define-command (handle-focus-in event)
      ;; GNU Emacs's `handle-focus-in' (`frame.el:353'): the frame has
      ;; received the window system's focus. Emacs sets the frame
      ;; parameter `last-focus-update' to t and runs `focus-in-hook'; this
      ;; tree's `*frame-focus*' is what `blink-cursor--should-blink' reads
      ;; and what `get-window-cursor-type' treats an unfocused frame by.
      ;;
      ;; Emacs's takes the EVENT as its argument - `(interactive "e")' -
      ;; and reads the frame from it: `(nth 1 event)' is the frame list
      ;; `make_lispy_focus_in' built, and it records the focus on *that*
      ;; frame's `last-focus-update' parameter, guarded by
      ;; `(frame-live-p frame)' (`frame.el:357').
      ;;
      ;; **This tree's focus is one flag, not one per frame** - the
      ;; departure AGENTS.md names, because Emacs's `highlight_frame' is a
      ;; field of the *display* and this tree has no such field. So the
      ;; event's frame is not consulted and the flag is set outright; the
      ;; `frame-live-p' guard has nothing to guard, since the flag names no
      ;; frame. Written when there was one frame, and left as it is rather
      ;; than half-ported: the honest fix is the per-display field.
      ;;--------------------------------------------------------------
      "Handle a focus-in event."
      (interactive "e")
      (*frame-focus* #t))

    (define-command (handle-focus-out event)
      ;; GNU Emacs's `handle-focus-out' (`frame.el:369'): the frame has
      ;; lost the window system's focus - and like `handle-focus-in', it
      ;; reads the frame from `*current-frame*' rather than from an event.
      ;;--------------------------------------------------------------
      "Handle a focus-out event."
      (interactive "e")
      (*frame-focus* #f))

    (define-command (blink-cursor-mode arg)
      "Toggle cursor blinking (Blink Cursor mode)."
      (interactive "P")
      (let ((on? (if arg
                     (< 0 (uarg->integer 1 arg))
                     (not (*blink-cursor-mode*)))))
        (*blink-cursor-mode* on?)
        (blink-cursor-suspend)
        (when on? (blink-cursor-check))
        ;; Emacs's `define-minor-mode' would echo this; the mode line
        ;; lighter it would also add is not implemented
        (set!frame-message (*current-frame*)
                           (if on?
                               "Blink Cursor mode enabled"
                               "Blink Cursor mode disabled"))))

    ;; the window system's events, bound where Emacs binds them - in the
    ;; library that owns the command (`bindings.el' has
    ;; `(define-key special-event-map ...)' and `keyboard.c:14550' does the
    ;; same in C)
    (define-key *special-event-map* (kbd "<focus-in>") handle-focus-in)
    (define-key *special-event-map* (kbd "<focus-out>") handle-focus-out)

    (define *minibuffer* (make-parameter #f))
    ;; ^ The minibuffer being read, or false: GNU Emacs's
    ;; `active-minibuffer-window', which is a fact about the selected
    ;; frame rather than about the minibuffer. `CURRENT-EDITOR' and
    ;; `MINIBUFFERP' read it, so it lives here with the frame state
    ;; rather than with the minibuffer's own code, which is in
    ;; `(schemacs editor minibuffer)'.

    (define *echo-area-buffer* (make-parameter #f))
    ;; ^ The buffer the echo area is showing, or false when it is showing
    ;; no buffer: GNU Emacs's `echo_area_buffer[0]'. While a minibuffer is
    ;; being read that buffer is the minibuffer's - Emacs gets there by
    ;; another route, because the minibuffer's *window* is the selected
    ;; window while it is read, so `current-buffer' is its buffer and
    ;; nothing has to say so. This project has no minibuffer window yet,
    ;; so the buffer that window would be showing is kept here, and
    ;; `read-from-minibuffer' binds it while it reads.
    ;;
    ;; It is here with the frame's other state because three things need
    ;; it and none of them may depend on the minibuffer's own code: the
    ;; display layer draws it (`X-DISPLAY' reads `echo_area_buffer' in GNU
    ;; Emacs too), and `CURRENT-EDITOR' answers with it, which is what
    ;; makes every editing command work in the prompt with no code of its
    ;; own.

    (define *echo-area-prompt* (make-parameter #f))
    ;; ^ The prompt drawn at the start of the echo area while a minibuffer
    ;; is being read, or false: what the display layer puts before the
    ;; buffer's text. GNU Emacs keeps the prompt *in* the buffer as the
    ;; `minibuffer-prompt' text property, which is why it needs no such
    ;; variable and why `minibuffer-prompt-end' can tell where the typed
    ;; text begins. This editor has neither text properties nor a
    ;; restriction on how far back point may go, so the prompt is beside
    ;; the buffer rather than in it, and this is where the display layer
    ;; finds it.

    (define (current-editor)
      ;; Which buffer the *selected window* shows - the window half of GNU
      ;; Emacs's `current-buffer', which is the buffer the window code
      ;; writes when the window changes.
      ;;
      ;; It is not `(current-buffer)' on its own: Emacs's `current_buffer'
      ;; is written by `set-buffer' as well as by the window code, and
      ;; `(schemacs editor buffer)''s `current-buffer' is what asks both -
      ;; `(or (*current-buffer*) (current-editor))'. Commands want *that*;
      ;; this is what the renderer, `display-buffer' and `switch-to-buffer'
      ;; want, and it is the fallback inside it.
      ;;
      ;; **It used to answer the echo-area buffer first**, so that a
      ;; minibuffer read was "current" without anyone saying so. Emacs
      ;; says so: `read_minibuf` does `Fset_buffer (minibuffer)`
      ;; (`minibuf.c:794`) and `record_unwind_current_buffer` (`:675`),
      ;; and `read-minibuffer-1` does the same pair now. Preferring the
      ;; echo area here was the reason a click in another window could not
      ;; make that window's buffer current while a prompt was up - the
      ;; prompt shadowed it from *below* the selection, not just while it
      ;; was being read.
      ;;--------------------------------------------------------------
      (let ((w (selected-window)))
        (and w (window-buffer w))))

    (define *tty-select-active-regions*
      ;; GNU Emacs's `tty-select-active-regions' (frame.el:2759): "If
      ;; non-nil, active regions automatically set the primary selection
      ;; on text terminals, if the terminal supports this" - the OSC 52
      ;; path, whose support `xterm--set-selection' records. Off, as
      ;; Emacs's is; xterm.sld's version handler turns the terminal's
      ;; parameter on.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (display-selections-p . args)
      ;; GNU Emacs's `display-selections-p' (frame.el:2770): whether
      ;; DISPLAY - nil meaning the selected frame's - supports
      ;; selections, "a way to transfer text or other data between
      ;; programs via special system buffers called `selection' or
      ;; `clipboard'".
      ;;
      ;; Emacs's frame-type cond has a branch for each kind of frame:
      ;; `pc' is MS-DOS's, of which there is none here, and the tty
      ;; branch is `tty-select-active-regions' together with the
      ;; terminal parameter `xterm--set-selection' - the OSC 52 path.
      ;; The question about the terminal is a method on the display
      ;; (`display-selections-supported?'), because importing xterm.sld
      ;; here would pull ncurses into the GTK build. What remains is
      ;; the window-system branch, `(memq frame-type '(x w32 ns pgtk))',
      ;; which answers t: and `framep-on-display' is this tree's one
      ;; window system at a time, which `*window-system*' is.
      ;;--------------------------------------------------------------
      (or (and (memq (*window-system*) '(x w32 ns pgtk)) #t)
          (and (not (*window-system*))
               ;; The selected frame's terminal, as Emacs asks it of the
               ;; frame - `(current-display)' is the same object today, and
               ;; reading it off the frame is what stays right when there
               ;; are several.
               (let ((d (or (let ((f (*current-frame*)))
                              (and f (frame-output f)))
                            (current-display))))
                 (and d (display-selections-supported? d))))))

    (define (%display-of args)
      ;; The display an optional DISPLAY-or-FRAME argument names: the
      ;; frame's own output when it is a frame, the display itself when it
      ;; is one, and the selected frame's otherwise - which is what
      ;; Emacs's `frame-char-height' and `display-pixel-width' do with a
      ;; nil argument.
      ;;--------------------------------------------------------------
      (let ((thing (and (pair? args) (car args))))
        (cond ((not thing) (or (and (*current-frame*)
                                    (frame-output (*current-frame*)))
                               (current-display)))
              ((frame? thing) (frame-output thing))
              (else thing))))

    (define (frame-char-height . args)
      ;; GNU Emacs's `frame-char-height' (`frame.c:4345'): "Height in
      ;; pixels of a line in the font in frame FRAME. If FRAME is omitted
      ;; or nil, the selected frame is used. For a terminal frame, the
      ;; value is always 1."
      ;;--------------------------------------------------------------
      (let ((display (%display-of args)))
        (if display
            (cdr (display-cell-size display))
            1)))

    (define (frame-char-width . args)
      ;; GNU Emacs's `frame-char-width' (`frame.c:4363'): the same
      ;; question across a line rather than down one.
      ;;--------------------------------------------------------------
      (let ((display (%display-of args)))
        (if display
            (car (display-cell-size display))
            1)))

    (define (display-pixel-height . args)
      ;; GNU Emacs's `display-pixel-height' (`frame.el:2817'): "Return the
      ;; height of DISPLAY's screen in pixels. ... For character
      ;; terminals, each character counts as a single pixel."
      ;;
      ;; **A departure: this is the frame's size, not the monitor's.**
      ;; Emacs asks the window system for the whole screen; this tree has
      ;; no screen object, and every frame here is as large as its
      ;; window. The one caller - `text-scale-max-amount' - wants an
      ;; upper bound on a glyph's pixel width, and a frame's width serves
      ;; it as well as a monitor's.
      ;;--------------------------------------------------------------
      (let ((display (%display-of args)))
        (if display
            (* (cdr (screen-size display))
               (cdr (display-cell-size display)))
            1)))

    (define (display-pixel-width . args)
      ;; GNU Emacs's `display-pixel-width' (`frame.el:2838'), with the
      ;; same departure as `display-pixel-height' above.
      ;;--------------------------------------------------------------
      (let ((display (%display-of args)))
        (if display
            (* (car (screen-size display))
               (car (display-cell-size display)))
            1)))

    (define (display-rows-cols display)
      ;; The display's size in character units, as `(ROWS . COLUMNS)': its
      ;; pixel size divided by the size of one character unit. This is
      ;; Emacs deriving `FRAME_COLS'/`FRAME_LINES' from
      ;; `FRAME_PIXEL_WIDTH'/`FRAME_PIXEL_HEIGHT' through
      ;; `FRAME_COLUMN_WIDTH'/`FRAME_LINE_HEIGHT'.
      ;;
      ;; On a terminal a character unit is one pixel, so these come out as
      ;; the terminal's own rows and columns. They are derived rather than
      ;; asked for so that a display whose unit is a real font - a
      ;; windowed one - answers the same question the same way.
      ;;--------------------------------------------------------------
      (let* ((size (screen-size display))
             (unit-width (max 1 (column-width display)))
             (unit-height (max 1 (line-height display))))
        (cons (quotient (cdr size) unit-height)
              (quotient (car size) unit-width))))

    ;;----------------------------------------------------------------
    ;; The background mode
    ;;
    ;; `frame-set-background-mode' (`frame.el:1529') and the two
    ;; functions under it: the face-spec branches that test
    ;; `(background dark)' and `(background light)' are only as right as
    ;; this answer, and this tree used to hardcode `light' on Gtk - so a
    ;; themed black frame read every light branch, and `Find file:' drew
    ;; `minibuffer-prompt''s `medium blue' on black.
    ;;--------------------------------------------------------------

    (define (%rgb-of name)
      ;; NAME's RGB as three [0,1] components, or #f when it is not a
      ;; colour name this tree knows. Emacs asks `color-values' - the
      ;; X server's or the terminal's, `tty_lookup_color' on a terminal -
      ;; and here the one table a name means anything by is
      ;; `tty-colors''.
      ;;--------------------------------------------------------------
      (let ((rgb (and (string? name)
                      (tty-color-standard-values name))))
        (and (list? rgb)
             (= 3 (length rgb))
             (map (lambda (c) (/ c 65535.0)) rgb))))

    ;; The user's own answer, which is `frame-terminal-default-bg-mode''s
    ;; first question (`frame.el:1591'): the `frame-background-mode'
    ;; *defvar*, the one a user sets in an init file to force dark or
    ;; light over every frame. It is not the recorded answer - that is
    ;; `*frame-background-mode*', the parameter the spec matcher reads -
    ;; and conflating the two is what made the recompute a no-op: once
    ;; initialization had written `light' into the recorded slot, the
    ;; override branch returned it and no theme's black could ever flip
    ;; the mode. Measured, the hook fired with the default face's
    ;; background already "black" and the computation answered the
    ;; recorded `light'.
    (define *frame-terminal-default-bg-mode* (make-parameter #f))

    (define (frame--current-background-mode frame)
      ;; GNU Emacs's `frame--current-background-mode' (`frame.el:1508').
      ;; The answer comes from FRAME's background colour:
      ;; `color-dark-p' over its values is dark, anything it cannot ask
      ;; falls back to the window system's own default - `light' for a
      ;; window system or an xterm-class terminal, `dark' for the bare
      ;; consoles.
      ;;
      ;; **The background colour is the default face's.** Emacs reads the
      ;; `background-color' frame parameter, which
      ;; `realize_default_face' filled from the face; here the fill is
      ;; the face's colour outright (`clear-frame-area!' reads it), so
      ;; the face *is* the parameter, and an unspecified background is
      ;; the `unspecified-fg' inverted-video case's neighbour - the C's
      ;; `(not (color-values ...))' fallback.
      ;;--------------------------------------------------------------
      (let* ((frame-default-bg-mode (*frame-terminal-default-bg-mode*))
             (bg-color (face-attribute 'default ':background))
             ;; `window-system' is the window-system-or-nil test the C's
             ;; `default-bg-mode' makes: a windowed display starts light,
             ;; a bare tty dark - "xterm and its cousins are asked
             ;; instead" being the tty half, which `(schemacs ui
             ;; ncurses xterm)''s OSC 11 answer already covers by
             ;; setting the parameter itself.
             (default-bg-mode (if (*window-system*) 'light 'dark)))
        (cond (frame-default-bg-mode)
              ((not (string? bg-color)) default-bg-mode)
              ((not (%rgb-of bg-color)) default-bg-mode)
              ((color-dark-p (%rgb-of bg-color)) 'dark)
              (else 'light))))

    (define *inhibit-frame-set-background-mode* (make-parameter #f))
    ;; ^ GNU Emacs's `inhibit-frame-set-background-mode' (`frame.el:
    ;; 1506'), the loop guard bug#911 was: `face-spec-recalc' sets the
    ;; default face's attributes, which re-reaches this function
    ;; through the hook the C's `calln' is, and the second entry would
    ;; recalculate for ever. It is bound round the recalculation.

    (define (frame-set-background-mode frame . keep-face-specs)
      ;; GNU Emacs's `frame-set-background-mode' (`frame.el:1529'):
      ;; "Set up display-dependent faces on FRAME."
      ;;
      ;; The mode and the display type are computed, compared against
      ;; what the frame last had, and when either changed the face specs
      ;; are chosen again - `face-spec-recalc' over every face, which is
      ;; the C's loop over the unmodified ones. The *modified* faces are
      ;; left alone there: a face with an override spec answers its
      ;; override, and recalc would take the user's own changes back
      ;; off. Emacs records the unmodified set by hashing each face's
      ;; current realization against its user spec; here a face with an
      ;; override spec is the same question asked one way, so the recalc
      ;; skips those and runs over the rest.
      ;;
      ;; There are no frame parameters to record the old values in, so
      ;; the comparison is against the parameters themselves - which is
      ;; the same comparison the C makes against the frame's, on a tree
      ;; whose one display is what both name.
      ;;--------------------------------------------------------------
      (let* ((bg-mode (frame--current-background-mode frame))
             (display-type
              (cond ((not (*window-system*))
                     (if (> (*display-color-cells*) 2) 'color 'mono))
                    ((> (*display-color-cells*) 2) 'color)
                    (else 'mono)))
             (old-bg-mode (*frame-background-mode*))
             (old-display-type (*display-type*)))
        (unless (and (eq? bg-mode old-bg-mode)
                     (eq? display-type old-display-type))
          ;; **The parameters are set, not parameterized.** A frame's
          ;; background mode is recorded state - the C's
          ;; `modify-frame-parameters' - and the recalculation below
          ;; reads it. A `parameterize' would bind it round the recalc
          ;; and revert, so the next spec test would see the old
          ;; answer; a plain `set!' on a parameter *is* its writer.
          (*frame-background-mode* bg-mode)
          (*display-type* display-type)
          ;; The inhibit is the C's own guard round the recalculation
          ;; (bug#911): without it the default face's recalculation
          ;; re-reaches this function through the background hook and
          ;; the recalculation never ends.
          (parameterize ((*inhibit-frame-set-background-mode* #t))
            (for-each
             (lambda (face)
               (unless (face-override-spec face)
                 (face-spec-recalc face)))
             (face-list)))
          #t)))

    ;; The seam faces.scm's `set-face-attribute' reaches for: the C's
    ;; `calln (Qframe_set_background_mode, frame)' when the default
    ;; face's background changes (`xfaces.c:3902'), which a library
    ;; below this one cannot spell. FRAME is the hook's one argument
    ;; and `#f' is what a caller without a frame passes - the selected
    ;; frame's answer being the one that matters on this tree.
    (define (%frame-background-mode-hook frame)
      (unless (*inhibit-frame-set-background-mode*)
        (frame-set-background-mode frame)))
    (*frame-background-mode-function* %frame-background-mode-hook)

    (define *frame-list* (make-parameter '()))
    ;; ^ GNU Emacs's `Vframe_list' (`frame.c:284'): every live frame, most
    ;; recently made first. It is pushed as each frame is made (`Fcons',
    ;; `frame.c:1438' and `:1560'), removed when one is deleted
    ;; (`delq_no_quit', `:2895'), and `frame-list' answers a *copy*
    ;; (`Fcopy_sequence', `:2176'). Selecting a frame does **not**
    ;; reorder it - `norecord' in `do_switch_frame' is about the window
    ;; and buffer record, not this list - so the order is creation order.
    ;;
    ;; A parameter for the reason `*coding-system-table*' is one: it is a
    ;; registry, and a test wants to build one from nothing.

    (define %next-frame-name
      ;; GNU Emacs's `frame_next_F_name' (`frame.c'): the name a frame is
      ;; given as it is made - `F1', `F2', and on. Emacs keeps a counter
      ;; on the keyboard object; a counter here, since there is one
      ;; keyboard (`kboard') in this editor too.
      ;;--------------------------------------------------------------
      (let ((n 0))
        (lambda ()
          (set! n (+ n 1))
          ;; **A *string***, as `f->name` is: the title, the
          ;; `name` parameter and `frame-parameters`' answer are all the
          ;; one string `"F1"`. It was a symbol here, which made
          ;; `(frame-parameter frame 'name)` answer a symbol where Emacs
          ;; answers a string.
          (string-append "F" (number->string n)))))

    (define (new-frame-on display editor height width)
      ;; A frame of HEIGHT x WIDTH showing EDITOR, drawn on DISPLAY -
      ;; GNU Emacs's `make_frame' given a terminal, which is what a frame
      ;; *is*: `f->terminal' is fixed when it is made and never changes
      ;; (`frame.c:1446' and `:1566' are the only assignments; `:2940'
      ;; nulls it as the frame dies).
      ;;
      ;; **The display is an argument and not `(current-display)` read
      ;; here**, because the whole point of a second frame is that it is
      ;; built for a display that is not the current one. Everything that
      ;; needs a frame on a particular display comes through here;
      ;; `new-frame' below is the common case and reads the ambient one.
      ;;--------------------------------------------------------------
      ;; **The frame is made first and its windows second**, which is
      ;; the order `make_frame' itself uses (`frame.c:1229'): the frame
      ;; object is allocated, then `root_window = make_window ()', then
      ;; `wset_frame (rw, frame)' tells the window which frame it is on.
      ;; A window's frame is fixed for its life, so it cannot be filled
      ;; in afterwards - the window has to be built knowing it.
      (let* ((frame (make<frame> '() #f #f height width
                                 "" #f #f #f display (%next-frame-name)
                                 ;; "The parameters a frame is made with":
                                 ;; `make-frame` merges `default-frame-alist`
                                 ;; (and, for the first frame,
                                 ;; `initial-frame-alist`) before it makes
                                 ;; one (`frame.el:830`).
                                 (%make-frame-parameters)
                                 ;; A frame that has never been drawn is
                                 ;; garbaged: the surface holds nothing,
                                 ;; so its matrices mean nothing yet.
                                 #t
                                 ;; Nothing is queued for later - -1 is
                                 ;; the C's "no size change pending".
                                 -1 -1 #f
                                 ;; No menu bar built yet.
                                 #f 0))
             ;; **The text area starts below the top margin**, which is
             ;; what makes the menu bar a row the windows do not use -
             ;; GNU Emacs's `r->top_line = FRAME_TOP_MARGIN (f)`
             ;; (`window.c:5021`). The echo row is still the frame's last.
             (window (make-frame-window frame editor
                                        (frame-top-margin frame)
                                        (max 1 (- height 1
                                                  (frame-top-margin frame)))
                                        0 width))
             ;; **The minibuffer window is the frame's last row**, made
             ;; with the frame as `make_frame` makes it (`frame.c:1237`,
             ;; `fset_minibuffer_window (f, make_minibuffer_window ())`).
             ;; It shows no buffer until a prompt is read, which is what
             ;; `minibuffer-window-active-p` asks; the row is drawn as
             ;; the echo area either way.
             (mini (make-frame-window frame #f
                                      (max 0 (- height 1)) 1 0 width)))
        (set!frame-minibuffer-window frame mini)
        (set!frame-windows frame (list window mini))
        (set!frame-selected-window frame window)
        ;; Every frame joins the list as it is made, exactly as
        ;; `make_frame' and `make_terminal_frame' push it.
        (*frame-list* (cons frame (*frame-list*)))
        frame))

    (define new-frame
      ;; A frame holding one window that fills the text area and shows
      ;; EDITOR. GNU Emacs's `frame-root-window' is the whole frame, and
      ;; a frame starts with just that one window.
      ;;
      ;; Its size is the terminal's; the three argument form is for
      ;; tests, which have no terminal to ask.
      ;;--------------------------------------------------------------
      (case-lambda
       ((editor)
        ;; With no size asked for, the display's size is the answer - a
        ;; frame is a display of a terminal, and knows how big that is.
        (let ((size (display-rows-cols (current-display))))
          (new-frame editor (car size) (cdr size))))
       ((editor height width)
        (new-frame-on (current-display) editor height width))))

    ;;------------------------------------------------------------------
    ;; Frames: the list, the selection, and the commands
    ;;------------------------------------------------------------------

    (define (selected-frame)
      ;; GNU Emacs's `selected-frame' (`frame.c:2140'): "Return the
      ;; selected frame." The command loop binds it; every command that
      ;; does not take a frame acts on this one.
      ;;--------------------------------------------------------------
      (*current-frame*))

    (define (frame-live-p frame)
      ;; GNU Emacs's `frame-live-p' (`frame.c'): "Return non-nil if
      ;; OBJECT is a live frame." `CHECK_LIVE_FRAME' is this test.
      ;;--------------------------------------------------------------
      (and (frame-type? frame) (memq frame (*frame-list*)) #t))

    (define (frame-visible-p frame)
      ;; GNU Emacs's `frame-visible-p' (`frame.c:1863'): "Return t for a
      ;; visible frame, `icon' for an iconified one, nil for an invisible
      ;; one." This tree hides nothing and has no iconification - every
      ;; live frame is drawn - so a live frame answers `t', which is the
      ;; `(eq t (frame-visible-p frame))' test Emacs's completion code
      ;; makes (`minibuffer.el:1765'). A non-frame or a deleted one is
      ;; nil, as there.
      ;;--------------------------------------------------------------
      (and (frame-live-p frame) #t))

    (define (frame-list)
      ;; GNU Emacs's `frame-list' (`frame.c:2161'): "Return a list of all
      ;; live frames." A *copy* - `Fcopy_sequence (Vframe_list)'
      ;; (`:2176') - so a caller cannot reorder the real list.
      ;;--------------------------------------------------------------
      (append (*frame-list*) '()))

    (define (select-frame frame)
      ;; GNU Emacs's `select-frame' (`frame.c:2097'): "Select FRAME.
      ;; Subsequent editing commands apply to its selected window."
      ;;
      ;; **The point moves with the frame.** `do_switch_frame' ends with
      ;;
      ;;   Fselect_window (f->selected_window, norecord);   (`frame.c')
      ;;
      ;; and that call is what runs `select_window_1' (`window.c:591'):
      ;; the window being left keeps the buffer's point in its `pointm',
      ;; and the window being selected hands its `pointm' to the buffer.
      ;; Two frames on one buffer therefore hold two points and the
      ;; buffer's is whichever frame is selected.
      ;;
      ;; Without it every frame was pinned to one point: typing in a
      ;; second frame moved the first frame's point too, so the two
      ;; scrolled together however far apart you left them.
      ;;
      ;; The swap is written out here rather than delegated to
      ;; `select-window' below, because that one reads `(selected-window)'
      ;; - which is `(frame-selected-window (*current-frame*))', the frame
      ;; this function is in the middle of changing.
      ;;
      ;; **The display follows the frame.** A frame's `output' is its
      ;; terminal and only the selected frame's terminal is the editor's,
      ;; which is what makes input and redisplay look at the right one.
      ;;--------------------------------------------------------------
      (unless (frame-type? frame)
        (error "Wrong type argument: framep"))
      (unless (frame-live-p frame)
        (error "Wrong type argument: frame-live-p"))
      ;; `let*' and not `let': `changing?' reads `old', and a `let'
      ;; binding's init is evaluated in the enclosing scope.
      (let* ((old (*current-frame*))
             ;; Emacs's `select_window' does nothing at all when the
             ;; window is already selected (`window.c:545'): it returns
             ;; through `record_and_return' without touching point.
             (changing? (not (eq? old frame))))
        (when changing?
          ;; the frame being left keeps the point its window had ...
          (let ((old-window (and old (frame-selected-window old))))
            (when old-window
              (set-marker (%window-point old-window)
                           (buffer-pt (window-buffer old-window))
                           (window-buffer old-window)))))
        (*current-frame* frame)
        (current-display (frame-output frame))
        ;; ... and the frame being selected gives the buffer its point.
        ;; This is `set_point_from_marker (XWINDOW (window)->pointm)',
        ;; which the C runs whether or not a window was left behind -
        ;; here that is the case of selecting the first frame, when
        ;; `*current-frame*' is still #f.
        (when changing?
          (let ((new-window (frame-selected-window frame)))
            (when new-window
              (set-point
               (window-buffer new-window)
               (marker-position (%window-point new-window))))))
        ;; **... and it makes that window's buffer current**, which is the
        ;; other thing `Fselect_window' does and the reason
        ;; `do_switch_frame' reaches it at all: "Make the selected
        ;; window's buffer current" (`window.c:534'). This is the half a
        ;; frame switch was missing - switch frames and every command
        ;; still acted on the buffer the frame you left was showing,
        ;; because nothing had told the buffer that the window had
        ;; changed. `(current-editor)' reads the *new* frame now, so it
        ;; answers that frame's buffer.
        (*current-buffer* (current-editor)))
      frame)

    (define-syntax with-selected-frame
      ;; GNU Emacs's `with-selected-frame' (`frame.el'): "Execute the
      ;; forms in BODY with FRAME as the selected frame.  The value
      ;; returned is the value of the last form in BODY.  See also
      ;; `with-temp-buffer' and `with-selected-window'."
      ;;
      ;; Emacs selects with NORECORD and restores in `unwind-protect';
      ;; `dynamic-wind' here is the same two calls around the body. It
      ;; is the first caller that made this worth having: `omarchy.el'
      ;; selects a graphical frame before asking `set-face-attribute'
      ;; to load a font, since that call acts on the selected frame.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ frame body ...)
         (let ((old-frame (selected-frame)))
           (dynamic-wind
             (lambda () (select-frame frame))
             (lambda () body ...)
             (lambda () (select-frame old-frame)))))))

    (define (%frame-step frame back?)
      ;; The frame after - or before - FRAME in the cyclic order, or #f
      ;; when FRAME is not in the list. Emacs's `next_frame' and
      ;; `prev_frame' (`frame.c:2380'-`:2415') walk the same list.
      ;;--------------------------------------------------------------
      (let* ((ordered (if back? (reverse (*frame-list*)) (*frame-list*)))
             (tail (memq frame ordered)))
        (and tail
             (let ((rest (cdr tail)))
               (if (null? rest) (car ordered) (car rest))))))

    (define (next-frame . args)
      ;; GNU Emacs's `next-frame' (`frame.c:2415'): "Return the next frame
      ;; in the cyclic ordering of frames." Emacs's MINIBUF argument picks
      ;; among minibuffer-only frames; this tree has none, so it is not
      ;; carried - the same departure `delete-frame' names.
      ;;--------------------------------------------------------------
      (let ((frame (if (pair? args) (car args) (*current-frame*))))
        (or (%frame-step frame #f) frame)))

    (define (previous-frame . args)
      ;; GNU Emacs's `previous-frame' (`frame.c:2441').
      ;;--------------------------------------------------------------
      (let ((frame (if (pair? args) (car args) (*current-frame*))))
        (or (%frame-step frame #t) frame)))

    (define-command (other-frame arg)
      ;; GNU Emacs's `other-frame' (`frame.el:1290'): "Select the next
      ;; frame in the cyclic ordering of frames." With a prefix argument,
      ;; that many frames along; a negative one goes backwards.
      ;;
      ;; Emacs's loop also skips frames whose `frame-visible-p' is not
      ;; `t'. Nothing here is iconified - there is no iconification to
      ;; do - so every frame is visible and the skip could never fire,
      ;; which is why the loop is not carried. `select-frame-set-input-
      ;; focus', which Emacs ends with, is an `x-focus-frame' call that
      ;; only means something on a window system; on a terminal Emacs's
      ;; own `display-multi-frame-p' guard skips it (`frame.el:1281').
      "Select the next frame (bound to C-x 5 o)."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let ((frame (*current-frame*)))
        (let loop ((i (abs arg)))
          (when (> i 0)
            (set! frame (if (< arg 0) (previous-frame frame) (next-frame frame)))
            (loop (- i 1))))
        (select-frame frame)))

    (define (delete-frame . args)
      ;; **Spelled with a rest argument rather than `define-command''s
      ;; fixed parameters**, because Emacs's is `(delete-frame &optional
      ;; frame force)' (`frame.c:3150') and a command here whose arguments
      ;; the interactive *expression* supplies must be given all of them
      ;; by a programmatic caller - so `(delete-frame)' and
      ;; `(delete-frame frame)' would both be arity errors. It is
      ;; registered as a command below, which is what `define-command'
      ;; does for a fixed list.
      ;;
      ;; GNU Emacs's `delete-frame' (`frame.c:3150', over `delete_frame'
      ;; at `:2598'): "Delete FRAME, eliminating it from use. ... The
      ;; frame is removed from `frame-list'."
      ;;
      ;; **The last frame is never silently deleted.** Without FORCE Emacs
      ;; signals "Attempt to delete the sole visible or iconified frame"
      ;; (`frame.c:2614'); with it, "Attempt to delete the only frame"
      ;; (`:2617'). Both are here as Emacs writes them.
      ;;
      ;; When the deleted frame was selected, Emacs picks a replacement
      ;; (`frame.c:2736'-`:2839') - the most recently used other frame,
      ;; else any other visible one on the terminal. With no iconification
      ;; and no MRU list, "the next in the list" is that rule reduced.
      ;;
      ;; Not carried, and named: `delete-frame-functions' and
      ;; `after-delete-frame-functions', `delete-before' child frames,
      ;; tooltip and surrogate-minibuffer frames, and the case where the
      ;; last frame is *forcibly* deleted, which exits Emacs with status
      ;; 70 (`:2835') - there is no forcible path here, since the last
      ;; frame is refused above.
      "Delete FRAME (bound to C-x 5 0)."
      ;; A nil FRAME means the selected frame, which is Emacs's
      ;; `decode_any_frame`: "if (NILP (frame)) frame = selected_frame"
      ;; (`frame.c:109'). It is the same call a programmatic `(delete-frame)'
      ;; makes, since a missing optional is a nil one.
      (let ((frame (let ((given (if (pair? args) (car args) #f)))
                     (or given (*current-frame*))))
            (force (and (pair? args) (pair? (cdr args)) (cadr args))))
      (cond
       ;; Emacs's `CHECK_LIVE_FRAME' first: something that is not a frame
       ;; at all is a type error, while a frame that is merely *dead* is
       ;; not - `delete_frame' answers nil for that (`frame.c:2611').
       ((not (frame-type? frame)) (error "Wrong type argument: framep"))
       ((not (frame-live-p frame)) #f)
       ((= 1 (length (*frame-list*)))
        (error (if force
                   "Attempt to delete the only frame"
                   "Attempt to delete the sole visible or iconified frame")))
       (else
        (let ((was-selected (eq? frame (*current-frame*))))
          (*frame-list*
           (let loop ((l (*frame-list*)) (acc '()))
             (cond ((null? l) (reverse acc))
                   ((eq? (car l) frame) (loop (cdr l) acc))
                   (else (loop (cdr l) (cons (car l) acc))))))
          (when was-selected
            (select-frame (car (*frame-list*))))
          ;; **The display takes the frame's surface away.**
          ;; `delete_frame` ends in `(*FRAME_TERMINAL (f)->delete_frame_hook)
          ;; (f)` (`frame.c:2937`), and without it the frame left
          ;; `frame-list` while its window stayed on the screen - a window
          ;; the editor had no frame for. `pgtk-frame-for` walks
          ;; `*frame-list*` and so answered #f for every event that arrived
          ;; on it, and those events were then acted on by whatever frame
          ;; *was* selected: deleting the frame you were in selected the
          ;; other one and closed nothing, and `C-x 5 0` in the window you
          ;; had just "deleted" complained about the sole frame with two
          ;; windows visibly open. The display answers this per its kind -
          ;; see `delete-frame-display!`.
          (let ((output (frame-output frame)))
            (when output (delete-frame-display! output)))
          ;; **nil, not the frame.** `Fdelete_frame` ends `return Qnil`
          ;; (`frame.c:3147') - every path of it does, including the one
          ;; for a frame that is already dead - so a REPL user sees `$1 =
          ;; #f` here where this used to print the frame it had just
          ;; deleted and Emacs prints nil.
          #f)))))

    (define (delete-other-frames . args)
      ;; GNU Emacs's `delete-other-frames' (`frame.el:3224'): "Delete all
      ;; frames on FRAME's terminal except FRAME, and make FRAME selected."
      ;; Spelled with a rest argument for `delete-frame''s reason: Emacs's
      ;; is `(delete-other-frames &optional frame iconify)'.
      ;;
      ;; Emacs's version has two rounds and a long list of frames it
      ;; spares - minibuffer frames, child frames, ancestors, and its
      ;; ICONIFY argument, which iconifies rather than deletes. None of
      ;; those exist here, so what is left is the plain rule.
      ;;
      ;; **It answers nil too**, which is `delete-frame`'s answer for its
      ;; reason: Emacs's body ends in a `dolist`, so what a caller gets
      ;; back is nothing at all. Measured the same way - a real Emacs in a
      ;; pty with two extra frames answers `nil' and leaves one.
      ;;--------------------------------------------------------------
      "Delete all other frames (bound to C-x 5 1)."
      (let ((frame (if (pair? args) (car args) (*current-frame*))))
        (let ((others (let loop ((l (*frame-list*)) (acc '()))
                        (cond ((null? l) (reverse acc))
                              ((eq? (car l) frame) (loop (cdr l) acc))
                              (else (loop (cdr l) (cons (car l) acc)))))))
          (for-each (lambda (f) (delete-frame f #f)) others)
          (when (frame-live-p frame) (select-frame frame)))
        #f))

    (define (display-graphic-p . args)
      ;; GNU Emacs's `display-graphic-p' (`frame.c'): "Return non-nil if
      ;; DISPLAY is a graphic display." The window system the frame is on
      ;; is what the face machinery records, and it is #f on a terminal.
      ;;--------------------------------------------------------------
      (and (memq (*window-system*) '(x w32 ns pgtk)) #t))

    (define *frame-creation-function* (make-parameter #f))
    ;; ^ GNU Emacs's `frame-creation-function' (`frame.el:30'): a
    ;; `cl-defgeneric' with one method per window system, `tty-create-
    ;; frame-with-faces' being the `(window-system nil)' one. Here it is a
    ;; parameter holding the front end's hook, so that this library never
    ;; imports a front end - the same arrangement that keeps `dispnew.sld'
    ;; free of ncurses and GTK.

    (define *before-make-frame-hook* (make-parameter '()))
    (define *after-make-frame-functions* (make-parameter '()))

    (define (make-frame . args)
      ;; GNU Emacs's `make-frame' (`frame.el:1021'): "Create a new frame
      ;; on DISPLAY... The new frame is returned."
      ;;
      ;; **It does not select the new frame.** Emacs's own docstring says
      ;; so (`frame.el:1055': "On graphical displays, this function does
      ;; not itself make the new frame the selected frame") - selecting is
      ;; `make-frame-command''s business, and only on a terminal.
      ;;
      ;; The order is Emacs's: `before-make-frame-hook', then
      ;; `frame-creation-function', then `after-make-frame-functions'
      ;; (`frame.el:1127', `:1129', `:1179').
      ;;
      ;; **Frame parameters are not carried**, and that is most of what
      ;; Emacs's `make-frame' does: it merges `window-system-default-
      ;; frame-alist', `default-frame-alist' and `frame-inherited-
      ;; parameters' (`frame.el:1096'-`:1109') before creating anything.
      ;; A frame here has no parameters to merge, so ARGS is taken for
      ;; shape and ignored. That is the named gap, not an oversight.
      ;;--------------------------------------------------------------
      ;; `(*before-make-frame-hook*)' and not `*before-make-frame-hook*':
      ;; a hook is a *parameter* here, so the bare name is the procedure
      ;; holding the list, not the list - `run-hooks' would call it with no
      ;; arguments and discard the value, running nothing at all.
      (run-hooks (*before-make-frame-hook*))
      (let ((create (*frame-creation-function*)))
        (unless create
          (error "This display cannot make more frames"))
        (let ((frame (create)))
          (run-hook-with-args (*after-make-frame-functions*) frame)
          frame)))

    (define-command (make-frame-command)
      ;; GNU Emacs's `make-frame-command' (`frame.el:936'): "Make a new
      ;; frame, on the same terminal as the selected frame. If the
      ;; terminal is a text-only terminal, this also selects the new
      ;; frame."
      ;;--------------------------------------------------------------
      "Make a new frame (bound to C-x 5 2)."
      (interactive)
      (if (display-graphic-p)
          (make-frame)
          (select-frame (make-frame))))

    ;; `delete-frame' and `delete-other-frames' are registered here rather
    ;; than by `define-command', because their Emacs shape has optional
    ;; arguments - see the note on `delete-frame'.
    ;;
    ;; **The spec is `#f', which means "no arguments".** That is Emacs's own
    ;; shape for both: `(interactive "")' (`frame.c:3150') and
    ;; `(interactive "i\nP")' (`frame.el:3224') pass the frame as *nothing*,
    ;; so each command reads `(*current-frame*)' itself. (The `P' half of
    ;; the second is ICONIFY, which this tree does not carry - the departure
    ;; the function names.)
    ;;
    ;; **`(list (*current-frame*) #f)' is the trap this argument lays**, and
    ;; it is what stood here: SPEC is an *expression* - a form for the
    ;; dispatcher to evaluate at the keypress to produce the argument list -
    ;; and `(list ...)' is a *call*, so what was registered was the list of
    ;; values, `(#f #f)`, built as the library loaded, when there was no
    ;; frame yet. At the keypress the dispatcher evaluated `(#f #f)' and so
    ;; applied `#f', and `C-x 5 0' answered **"Wrong type to apply: #f"** -
    ;; no frame could be deleted, including by `C-x 5 1'. Pass `#f' or a
    ;; *quoted* form; an unquoted one is evaluated here and now.
    (register-command! delete-frame #f)
    (register-command! delete-other-frames #f)

    (define-key *default-keymap* (kbd "C-x 5 2") make-frame-command)
    (define-key *default-keymap* (kbd "C-x 5 0") delete-frame)
    (define-key *default-keymap* (kbd "C-x 5 1") delete-other-frames)
    (define-key *default-keymap* (kbd "C-x 5 o") other-frame)

    (define min-safe-window-height 1)
    (define min-safe-window-width 2)
    ;; ^ The smallest a window may be left by a frame resize: GNU Emacs's
    ;; `MIN_SAFE_WINDOW_HEIGHT' and `MIN_SAFE_WINDOW_WIDTH' in `window.h',
    ;; which its `resize_frame_windows' respects. The Lisp variables
    ;; `window-min-height' and `window-min-width' - which the *split*
    ;; commands use, and which live in `window.el' - default to larger
    ;; numbers; Emacs has both, and so does this.

    (define (resize-frame-windows! frame old-height old-width new-height
                                   new-width)
      ;; Give the frame's windows the frame's new size, in proportion to
      ;; the size they had: GNU Emacs's `resize_frame_windows', of which
      ;; this is the result rather than the mechanism. Emacs hands the
      ;; root window the *difference* and lets `window_resize_apply'
      ;; distribute it among the children - machinery that also serves
      ;; `enlarge-window' and `window-combination-resize'. What it
      ;; produces, for a frame that has simply changed size, is each
      ;; window scaled to the new frame with the remainder kept whole at
      ;; the end, and that is what this computes.
      ;;
      ;; The row above the echo area is the text area: the echo area has
      ;; the frame's last row, as GNU Emacs's minibuffer window does.
      ;;--------------------------------------------------------------
      ;; **The top margin is the menu bar's.** `resize_frame_windows`
      ;; gives the root window `new_size = new_height - FRAME_TOP_MARGIN
      ;; - 1` rows starting at `FRAME_TOP_MARGIN` (`window.c:5050`), so a
      ;; frame with a bar divides its rows between the bar, the text area
      ;; and the echo row.
      (let ((margin (frame-top-margin frame)))
        (scale-window! (car (frame-windows frame))
                       0 0 old-width (max 1 (- old-height 1))
                       margin 0 new-width
                       (max 1 (- new-height margin 1))))
      ;; **The minibuffer window is the frame's last row, so a resize
      ;; moves it too.** `resize_frame_windows` (`window.c`) sizes the
      ;; root window to `new_height - 1` and leaves `FRAME_MINIBUF_WINDOW`
      ;; the row that is left. This walk used to re-tile only the first of
      ;; the frame's windows, so the minibuffer window kept the row it was
      ;; made with, and after any resize the prompt was drawn part way up
      ;; the frame - over the text - at a position that had nothing to do
      ;; with point and everything to do with the size the frame used to
      ;; be.
      (let ((mini (frame-minibuffer-window frame)))
        (when mini
          (set!window-top mini (max 0 (- new-height 1)))
          (set!window-left mini 0)
          (set!window-width mini new-width)
          (set!window-height mini 1))))

    (define *frame-inhibit-implied-resize* (make-parameter #f))
    ;; ^ GNU Emacs's `frame-inhibit-implied-resize' (`frame.el`): "Non-nil
    ;; means frames will not be resized to keep the same number of lines
    ;; and columns when the font changes." `t' inhibits for every
    ;; parameter, a list inhibits for the parameters it names, and the
    ;; symbol `force' inhibits always. `global-text-scale-adjust' binds it
    ;; to `(not global-text-scale-adjust-resizes-frames)'.

    (define (frame-inhibit-resize? frame horizontal parameter)
      ;; GNU Emacs's `frame_inhibit_resize' (`frame.c:200'): whether a
      ;; change to PARAMETER - `font', here - should leave the frame's
      ;; pixel size alone.
      ;;
      ;; The C also consults `fullscreen' and `is_tty_frame'; this tree
      ;; has neither a fullscreen parameter nor a separate terminal
      ;; frame type, and the caller (`adjust_frame_size` with inhibit 3)
      ;; is the font's own, so what is left is the variable.
      ;;--------------------------------------------------------------
      (let ((v (*frame-inhibit-implied-resize*)))
        (if (or (eq? v 'force) (eq? v #t))
            #t
            (and (pair? v) (memq parameter v) #t))))

    (define (adjust-frame-size! frame new-text-width new-text-height
                                inhibit pretend parameter . args)
      ;; GNU Emacs's `adjust_frame_size' (`frame.c:826'), for the case
      ;; this tree has: the *text* size in pixels and a window system
      ;; that can be asked to change the frame's native size.
      ;;
      ;; INHIBIT is the C's small integer, and the only value reached
      ;; here is 3 - "call set_window_size_hook if window minimum sizes
      ;; must be preserved or `frame_inhibit_resize' allows it ... also
      ;; used when the frame's default font changes", which is `x_new_font'.
      ;;
      ;; **What is not carried**: `frame_windows_min_size' (there is no
      ;; per-window minimum size here - `window-min-height'/`-width' are
      ;; the split commands' business), the internal border and margins
      ;; (neither exists), and the `fullscreen' parameter. The arithmetic
      ;; that is left - unit sizes, the new text columns and lines, and
      ;; the inhibit test - is the C's.
      ;;--------------------------------------------------------------
      (let* ((display (frame-output frame))
             ;; `FRAME_COLUMN_WIDTH' and `FRAME_LINE_HEIGHT' are the
             ;; *real* size of a character, which is what the frame's
             ;; rows and columns are pixels divided by - so it is
             ;; `display-cell-size' and not `column-width', which answers
             ;; in this redisplay's own unit (1 for a windowed display).
             ;;
             ;; **`screen-size' answers in the redisplay's unit**, so the
             ;; native size in real pixels is that times the cell; the two
             ;; are converted in one place rather than mixed.
             (cell (display-cell-size display))
             (unit-width (max 1 (car cell)))
             (unit-height (max 1 (cdr cell)))
             (size (screen-size display))
             (old-native-width (* (car size) unit-width))
             (old-native-height (* (cdr size) unit-height))
             (old-text-width (* (frame-width frame) unit-width))
             (old-text-height (* (frame-height frame) unit-height)))
        (if (= inhibit 5)
            ;; "call resize_frame_windows" and never the window system:
            ;; what `change_frame_size' does, which is what this tree's
            ;; `sync-frame-size!' already is.
            (sync-frame-size! frame)
            (let* ((inhibit-horizontal
                    (and (>= inhibit 2) (<= inhibit 4)
                         (frame-inhibit-resize? frame #t parameter)))
                   (inhibit-vertical
                    (and (>= inhibit 2) (<= inhibit 4)
                         (frame-inhibit-resize? frame #f parameter)))
                   (new-native-width
                    (if (and inhibit-horizontal (< inhibit 5))
                        old-native-width
                        (max new-text-width 1)))
                   (new-native-height
                    (if (and inhibit-vertical (< inhibit 5))
                        old-native-height
                        (max new-text-height 1)))
                   (new-cols (max 1 (quotient new-native-width unit-width)))
                   (new-lines (max 1 (quotient new-native-height unit-height))))
              ;; "For inhibit == 1 call the window_size_hook only if a
              ;; native size changes. For inhibit == 0 or 2 always call
              ;; it."
              (when (or (= inhibit 0) (= inhibit 2)
                        (and (not inhibit-horizontal)
                             (not (= new-native-width old-native-width)))
                        (and (not inhibit-vertical)
                             (not (= new-native-height old-native-height))))
                (display-set-size! (frame-output frame)
                                   new-native-width new-native-height))
              ;; **The tail runs whether or not the window system was
              ;; asked**, and it is the half that makes
              ;; `global-text-scale-adjust-resizes-frames` mean
              ;; something: the frame takes the new column and row count
              ;; and `resize_frame_windows` re-tiles it. Emacs reaches
              ;; this after the `set_window_size_hook` block with the
              ;; same "no change" early return.
              ;;
              ;; **Where the answer comes from**: the display's own size
              ;; once the hook has run, because `pgtk-resize!` records the
              ;; allocation and the display is the authority - not the
              ;; number computed above, which is what was *asked for*.
              ;; The two agree when the request was honoured, and differ
              ;; when it was not (an inhibited request, or a compositor
              ;; that refused), which is the case that matters.
              (let* ((size (display-rows-cols display))
                     (old-cols (frame-width frame))
                     (old-lines (frame-height frame))
                     (final-cols (if (> (car size) 0) (cdr size) new-cols))
                     (final-lines (if (> (car size) 0) (car size) new-lines)))
                (unless (and (= final-cols old-cols)
                             (= final-lines old-lines)
                             (= new-native-width old-native-width)
                             (= new-native-height old-native-height))
                  (set!frame-width frame final-cols)
                  (set!frame-height frame final-lines)
                  (when (or (not (= old-cols final-cols))
                            (not (= old-lines final-lines)))
                    (resize-frame-windows! frame old-lines old-cols
                                           final-lines final-cols))))
              #t))))

    (define delayed-size-change #f)
    ;; ^ `delayed_size_change` (`dispnew.c:121`): "True means SIGWINCH
    ;; happened when not safe." A plain variable and not a parameter,
    ;; because nothing `let`-binds it - it is a fact about the frames, not
    ;; about the dynamic extent of anything.

    (define (change-frame-size frame new-width new-height pretend delay)
      ;; GNU Emacs's `change_frame_size` (`dispnew.c:6742`) over
      ;; `change_frame_size_1` (`:6693`): give FRAME a new size.
      ;;
      ;; **DELAY means the caller cannot do the work here.** The C's
      ;; comment is the whole reason this function exists: "If DELAY,
      ;; assume we're being called from a signal handler, and queue the
      ;; change for later - perhaps the next redisplay. Since this tries
      ;; to resize windows, we can't call it from a signal handler"
      ;; (`:6735`). So the numbers are parked on the frame and
      ;; `do-pending-window-change` applies them where it is safe.
      ;;
      ;; PRETEND is Emacs's "don't change the frame's size, just say what
      ;; it would be". Nothing here passes it; it is carried because the
      ;; C's signature has it and a caller that has to ask the question
      ;; will want it.
      ;;--------------------------------------------------------------
      (if delay
          (begin
            (set!frame-new-width frame new-width)
            (set!frame-new-height frame new-height)
            (set!frame-new-size-p frame #t)
            (set! delayed-size-change #t))
          (begin
            ;; "Storing -1 in the new_width/new_height slots means that no
            ;; size change is pending" (`dispnew.c:6716`).
            (set!frame-new-width frame -1)
            (set!frame-new-height frame -1)
            (set!frame-new-size-p frame #f)
            ;; `adjust_frame_size (f, ..., 5, ...)`, whose inhibit 5 is
            ;; "call resize_frame_windows and never the window system".
            (%apply-frame-size frame new-width new-height pretend))))

    (define (%apply-frame-size frame new-width new-height pretend)
      ;; The half of `adjust_frame_size` (`frame.c`) that an inhibit-5
      ;; change needs: take the new size and re-tile the windows into it.
      ;;--------------------------------------------------------------
      (let ((old-height (frame-height frame))
            (old-width (frame-width frame)))
        (if (or (<= new-height 0)
                (and (= old-height new-height)
                     (= old-width new-width)))
            ;; **#f and not the value of an `unless`.** Scheme's
            ;; unspecified value is *true*, so a caller asking "did the
            ;; size change?" would be told yes on every call, and
            ;; `do-pending-window-change` would report a resize for every
            ;; wake - a redisplay loop.
            #f
            (begin
            (unless pretend
              (set!frame-height frame new-height)
              (set!frame-width frame new-width)
              (resize-frame-windows! frame old-height old-width
                                     new-height new-width))
            ;; **A resized frame is garbaged.** GNU Emacs's
            ;; `resize_frame_windows` is reached from
            ;; `change_frame_size`, whose callers set `f->resized_p`
            ;; and the redisplay's `clear_garbaged_frames` then
            ;; `redraw_frame`s a frame that "has been resized
            ;; (probably due to a window manager resize)" - the
            ;; toolkit has thrown the surface away, so nothing on it
            ;; is ours to keep. Without this a window grown by the
            ;; window manager kept drawing into the old rectangles
            ;; and scrolled only the top half of itself.
            (set-frame-garbaged! frame #t)
            ;; Answers whether the frame's size actually changed, which
            ;; the C leaves implicit: `adjust_frame_size` is a no-op for
            ;; an unchanged size, so nothing notices. A caller that has
            ;; to know - `do-pending-window-change`, because the command
            ;; loop reads a resize as a redisplay - needs to be told.
            #t))))

    (define (do-pending-window-change safe)
      ;; GNU Emacs's `do_pending_window_change` (`dispnew.c:6664`): "Do
      ;; any change in frame size that was requested by a signal."
      ;; Answers whether it applied one.
      ;;
      ;; The C's guard is `(redisplaying_p || dont_resize_frames) &&
      ;; !safe`, and neither of those can be read from here: they live
      ;; above this library (`redisplaying_p` is `xdisp`'s) and nothing
      ;; sets `dont_resize_frames` at all. What the guard protects is a
      ;; change asked for *during* a redisplay, and the one caller is a
      ;; wait for input, which is never one. SAFE is kept because the C's
      ;; signature has it and a caller that knows it is a redisplay can
      ;; say so.
      ;;--------------------------------------------------------------
      (let loop ((applied #f))
        (if (not delayed-size-change)
            applied
            (begin
              ;; The C clears the flag *before* the walk, because
              ;; `change_frame_size` can set it again from inside.
              (set! delayed-size-change #f)
              (for-each
               (lambda (frame)
                 ;; "Negative new_width or new_height values mean no
                 ;; change is required ... If new_size_p is not set,
                 ;; this means the size change was requested by
                 ;; adjust_frame_size but has not been honored by the
                 ;; window manager yet" (`dispnew.c:6679`).
                 (when (and (frame-new-size-p frame)
                            (or (>= (frame-new-height frame) 0)
                                (>= (frame-new-width frame) 0)))
                   (when (change-frame-size frame (frame-new-width frame)
                                            (frame-new-height frame) #f #f)
                     (set! applied #t))))
               (*frame-list*))
              (loop applied)))))

    (define (sync-frame-size! frame)
      ;; Take the frame's size from the terminal it is drawn on, if one
      ;; is open. A terminal that has been resized gives new numbers, so
      ;; this is what keeps `frame-height' and `frame-width' true; with
      ;; no terminal open (a test) there is nothing to ask and the frame
      ;; keeps the size it was made with.
      ;;
      ;; When the size has *changed*, the windows are re-tiled: GNU Emacs
      ;; does the same thing from `change_frame_size', which calls
      ;; `resize_frame_windows' in `window.c'. Without it a window keeps
      ;; the rectangle it was made with, and a terminal made smaller
      ;; draws its mode line off the bottom row.
      ;;--------------------------------------------------------------
      ;; The frame's own display, not the process's: a second frame's
      ;; size is its own window's. `render!' binds the display to the
      ;; frame's anyway, so this is the explicit form of the same thing -
      ;; and it is the correct one when a frame is sized from outside a
      ;; redisplay. The `or' covers the test frames, whose output is #f.
      (let ((display (or (frame-output frame) (current-display))))
        (when display
          (let ((size (display-rows-cols display)))
            (change-frame-size frame (cdr size) (car size) #f #f)))))

    (define (scale-window! window old-top old-left old-width old-height
                           new-top new-left new-width new-height)
      ;; WINDOW's rectangle goes from OL? to NEW?, and its children - if
      ;; it holds them - divide the new rectangle in proportion to the old
      ;; one, along the axis they are arranged on.
      ;;--------------------------------------------------------------
      (let ((children (window-children window)))
        (cond
         ((null? children)
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height))
         ((windows-stacked? children)
          ;; every node carries its own rectangle, as Emacs's
          ;; `window_resize_apply' leaves them: a *parent* that kept the
          ;; size it was made with would poison every later geometry
          ;; decision (an absorb that followed a stale bottom edge).
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height)
          (let ((old-total (let loop ((rest children) (sum 0))
                             (if (null? rest)
                                 sum
                                 (loop (cdr rest)
                                       (+ sum (window-height (car rest)))))))
                (new-total (max (* min-safe-window-height (length children))
                                new-height)))
            (let loop ((rest children) (offset 0))
              (unless (null? rest)
                (let* ((child (car rest))
                       (last? (null? (cdr rest)))
                       (old (window-height child))
                       (want (if last?
                                 (- new-total offset)
                                 (max min-safe-window-height
                                      (round (/ (* old new-total)
                                                old-total))))))
                  (scale-window! child
                                 (window-top child) (window-left child)
                                 old-width (window-height child)
                                 (+ new-top offset) new-left
                                 new-width want)
                  (loop (cdr rest) (+ offset want)))))))
         (else
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height)
          (let ((old-total (let loop ((rest children) (sum 0))
                             (if (null? rest)
                                 sum
                                 (loop (cdr rest)
                                       (+ sum (window-width (car rest)))))))
                (new-total (max (* min-safe-window-width (length children))
                                new-width)))
            (let loop ((rest children) (offset 0))
              (unless (null? rest)
                (let* ((child (car rest))
                       (last? (null? (cdr rest)))
                       (old (window-width child))
                       (want (if last?
                                 (- new-total offset)
                                 (max min-safe-window-width
                                      (round (/ (* old new-total)
                                                old-total))))))
                  (scale-window! child
                                 (window-top child) (window-left child)
                                 (window-width child) old-height
                                 new-top (+ new-left offset)
                                 want new-height)
                  (loop (cdr rest) (+ offset want))))))))))

    (define (windows-stacked? children)
      ;; Whether these sibling windows are arranged one above the other
      ;; rather than side by side: the axis their parent divided. Two
      ;; children that begin at the same column and the same width were
      ;; divided vertically, which is how `split-window-below' makes them.
      ;;--------------------------------------------------------------
      (and (pair? children)
           (pair? (cdr children))
           (= (window-left (car children)) (window-left (cadr children)))
           (= (window-width (car children)) (window-width (cadr children)))))

    (define-command (suspend-frame)
      ;; GNU Emacs's `suspend-frame' (C-z), which is `frame.el''s - "do
      ;; whatever is right to suspend the current frame". On a terminal
      ;; that is stopping the editor with SIGTSTP; the shell gives it back
      ;; with SIGCONT when the job is brought to the foreground.
      ;;
      ;; The display is asked to hand the terminal back first, so the
      ;; screen looks the way the shell left it, and to take it again
      ;; afterwards. GNU Emacs does the same around the `SIGTSTP' it
      ;; raises in `sysdep.c', through `Fsuspend_tty' / `Fresume_tty'.
      ;;
      ;; This is why the platform puts the terminal in `raw' mode rather
      ;; than `cbreak': in `raw' mode the terminal does not generate the
      ;; stop from the key itself, so the editor decides, which is what
      ;; Emacs does on a terminal too.
      ;;
      ;; Emacs's `SIGTSTP' is raised with `kill' rather than with Scheme's
      ;; `raise' because `(scheme base)''s `raise' raises an *exception*,
      ;; and `(guile)''s raises a signal; the two share a name.
      ;;--------------------------------------------------------------
      "Stop the editor and return to the shell (bound to C-z)."
      (interactive)
      ;; The selected frame's terminal - the thing that was stopped is
      ;; the frame's, not the process's.
      (let ((d (or (let ((f (*current-frame*)))
                     (and f (frame-output f)))
                   (current-display))))
        (suspend-display! d)
        (kill (getpid) SIGTSTP)
        (resume-display! d)
        ;; **Taking the terminal back is not the same as drawing on it.**
        ;; `Fresume_tty` (`term.c:2604`) ends with
        ;; `SET_FRAME_VISIBLE (root, true)`, and that macro's whole job
        ;; (`frame.h:1537`) is `redisplay_other_windows ()` - "make sure
        ;; the frame gets redisplayed if some changes were applied to it
        ;; while it wasn't visible". Whatever the editor did while the
        ;; shell had the screen was never drawn, and re-entering the
        ;; terminal (`ti`, `\e[?1049h`) has just blanked it besides.
        ;;
        ;; **The garbage is this tree's half of that**, and it is needed
        ;; only because the terminal can now be diffed: GNU Emacs's tty
        ;; redisplay rebuilds and hands over the whole frame matrix every
        ;; time, so a wiped surface costs it nothing to ignore. Here a
        ;; window whose glyphs still look current is left alone, so the
        ;; surface has to be declared empty. Measured, without it `C-z`
        ;; then `fg` came back to a blank screen until the next command.
        (set-windows-or-buffers-changed! #t)
        (for-each (lambda (f)
                    (when (eq? (frame-output f) d)
                      (set-frame-garbaged! f #t)))
                  (*frame-list*))))

    ;; The key GNU Emacs binds it to, beside the command as the other
    ;; libraries state theirs.
    (define-key *default-keymap* (kbd "C-z") suspend-frame)

    (define (selected-window)
      ;; The window commands act on: GNU Emacs's `(selected-window)'.
      ;;--------------------------------------------------------------
      (frame-selected-window (*current-frame*)))

    (define (select-window window)
      ;; Make WINDOW the selected window, the way GNU Emacs's
      ;; `select-window' does: the buffer's point is left in the window
      ;; being left, and WINDOW's point becomes the buffer's. Selecting
      ;; the window that is already selected changes nothing.
      ;;--------------------------------------------------------------
      (when (window-internal? window)
        (error "Attempt to select an internal window"))
      (let ((frame (*current-frame*))
            (old (selected-window)))
        (when (and old (not (eq? old window)))
          ;; the window being left keeps the point it had. **Only a
          ;; window that shows a buffer has a point to keep** - the C's
          ;; `if (BUFFERP (ow->contents))` (`window.c:600`) - and the
          ;; minibuffer window is one with no buffer until a prompt is
          ;; read (`redisplay_window` likewise skips a nil `contents`).
          (let ((old-buffer (window-buffer old)))
            (when old-buffer
              (set-marker (%window-point old)
                          (buffer-pt old-buffer)
                          old-buffer)))
          (set!frame-selected-window frame window)
          ;; ... and the one being selected gives the buffer its point.
          ;; `set_point_from_marker (w->pointm)` is conditional in the
          ;; same way: a window with no point marker has none to go to.
          (let ((new-buffer (window-buffer window)))
            (when (and new-buffer (%window-point window))
              (set-point new-buffer
                         (marker-position (%window-point window))))))
        ;; **`Fset_buffer (w->contents)' - the first line of
        ;; `Fselect_window' (`window.c:534'), which runs before the C
        ;; even tests whether the window is already selected.** "Make
        ;; the selected window's buffer current." Without it the current
        ;; buffer stayed wherever the last `set-buffer' put it, so a
        ;; `C-x 5 o' to another frame - or `C-x o' to another window -
        ;; left every command acting on the buffer you were looking at
        ;; *before* you switched, while the screen showed the other one.
        ;;
        ;; The answer is `(current-editor)' and not `(window-buffer
        ;; window)' because during a minibuffer read the selected window
        ;; in Emacs *is* the minibuffer window and what it shows is the
        ;; prompt's buffer. This tree has no minibuffer window, so the
        ;; echo area stands for it - which is exactly the case
        ;; `current-editor' exists for.
        ;; a nil answer leaves `*current-buffer*' as it was, which is
        ;; `Fset_buffer' handed a nil `contents' - the C checks
        ;; `BUFFERP (w->contents)' before it does anything with it
        (let ((buffer (current-editor)))
          (when buffer (*current-buffer* buffer)))
        window))

    (define-command (recenter arg)
      ;; GNU Emacs's `recenter' (`window.c:7219'): "Center point in
      ;; selected window and maybe redisplay frame." With a numeric
      ;; argument, point goes on screen line ARG - counting up from the
      ;; bottom when negative - and with no argument, or with a bare
      ;; `C-u', point goes on the middle line of the window. The way the
      ;; C's does it is to set the window's start to the position ARG
      ;; screen lines above point (`vmotion' computes it, and clips ARG
      ;; into [scroll-margin, height - scroll-margin - 1]) and let
      ;; redisplay draw from there.
      ;;
      ;; What is kept of the C's is the arithmetic and the setting of
      ;; the window start - here the window's top line, which redisplay
      ;; scrolls for visibility (`scroll-to-cursor!') but does not move
      ;; on its own. The screen-line arithmetic is line arithmetic,
      ;; since a line is a row here unless it wraps - and the wrapped
      ;; case is what `scroll-to-cursor!' already handles, so a top set
      ;; to a line ARG lines above point's is the same answer the C
      ;; gives without wrapped lines.
      ;;
      ;; Not ported: the frame erasure the REDISPLAY argument drives
      ;; (`recenter-redisplay' - this redisplay redraws the whole frame
      ;; every command anyway), `scroll-margin' (there is none here, so
      ;; the clip is [0, height - 1]), and the vscroll bookkeeping -
      ;; there is no vertical scroll offset a line start can carry.
      ;;--------------------------------------------------------------
      "Center point in selected window and maybe redisplay frame."
      (interactive (list (current-prefix-arg)))
      (let* ((window (selected-window))
             (ed (window-buffer window))
             (ht (window-body-height window))
             ;; "Just C-u as prefix means put point in the center of the
             ;; window" - a cons ARG is the bare `C-u', and no ARG is
             ;; centering too.
             (iarg (cond
                    ((not arg) (quotient ht 2))
                    ((pair? arg) (quotient ht 2))
                    (else
                     (let ((n (uarg->integer 1 arg)))
                       ;; negative counts up from the bottom
                       (if (< n 0) (+ n ht) n)))))
             ;; Don't let it get into the margin at either top or bottom.
             (iarg (max 0 (min iarg (- ht 1)))))
        ;; Set the new window start: the line IARG screen lines above
        ;; point's, or the top when there are not that many lines
        ;; above it - which is where `vmotion' stops, at `point-min'.
        (set-window-start!
         window
         (let loop ((n iarg) (pos (text-editor-get-start-of-line ed)))
           (if (or (<= n 0) (= pos (buffer-beg ed)))
               pos
               (loop (- n 1)
                     (text-editor-get-start-of-line ed (- pos 1))))))))

    ;; The key GNU Emacs binds it to (C-l), beside the command as the
    ;; other libraries state theirs.
    (define-key *default-keymap* (kbd "C-l") recenter)

    ;; The selected window's buffer, scroll position and file, under the
    ;; names the rest of this file already uses. They are what Emacs's
    ;; `current-buffer' and `window-start' are for the selected window,
    ;; and they keep the commands that act on "the buffer" reading as
    ;; such.

    (define (frame-editor frame)
      (window-buffer (frame-selected-window frame)))

    (define (set!frame-editor frame editor)
      ;; Showing a buffer in the frame's selected window is
      ;; `set_window_buffer' and nothing less: the window's start, its
      ;; end position and its line-number cache all described the buffer
      ;; that was there.
      (set-window-buffer! (frame-selected-window frame) editor))

    ;;----------------------------------------------------------------
    ;; The seams to `(schemacs editor buffer)'
    ;;
    ;; That library defines the buffer record, so this one is built on it
    ;; and it cannot import this one back. Emacs makes the same two calls
    ;; across the same seam - `buffer.c' reads the buffer the selected
    ;; window shows, and calls `replace_buffer_in_windows' to put another
    ;; one into a window - and gets away with it because C files may
    ;; include each other where Scheme libraries may not.
    ;;------------------------------------------------------------------
    (define (replace-buffer-in-windows buffer)
      ;; GNU Emacs's `replace_buffer_in_windows' (`window.c:3722'): show
      ;; some other buffer in every window that is showing BUFFER, so a
      ;; buffer can be killed without a window being left pointing at it.
      ;; `Fkill_buffer' calls it (`buffer.c:2032') *before* the buffer
      ;; leaves the buffer list, which is why the replacement is chosen
      ;; here rather than by the caller: while the dying buffer is still
      ;; listed, `other-buffer' cannot hand it straight back.
      ;;
      ;; One window per frame for now, so the walk is the selected
      ;; frame's window.
      ;;--------------------------------------------------------------
      (let ((window (and (*current-frame*) (selected-window))))
        (when (and window (eq? (window-buffer window) buffer))
          (set-window-buffer! window (other-buffer buffer)))
        #t))
    ;; The two seams, installed here because this is the library that has
    ;; the window code. `(schemacs editor buffer)' calls them where the C
    ;; would call into `window.c' directly.
    ;;
    ;; **The first one is guarded, and the guard is the point.** The
    ;; buffer library asks it for "the buffer the window code made
    ;; current" and there may be no frame at all - a script or a test
    ;; that calls `find-file' with nothing on screen - where `(current-
    ;; editor)' would walk into `(window-buffer #f)'. The caller used to
    ;; spell this guard itself, as `(and (*current-frame*)
    ;; (current-editor))'; it belongs on this side of the seam, because
    ;; `*current-frame*' is this library's.
    (*current-editor-function*
     (lambda () (and (*current-frame*) (current-editor))))
    (*replace-buffer-in-windows-function* replace-buffer-in-windows)

    ;; `editfns.c`'s `message' and `current-message' reach the echo area
    ;; through these two, declared in `editfns.scm' and installed here
    ;; because the message buffer and the frame that owns it are this
    ;; library's. They are the C's own two ends: `message3' writes
    ;; `FRAME_MESSAGE_BUF (f)' and `current-message' reads it back.
    (*message-function*
     (lambda (text)
       ;; `message3` (`xdisp.c:12592`) with no frame - a batch run, or a
       ;; message before the first frame exists - has no echo area to
       ;; write; `FRAME_MESSAGE_BUF (f)` is only reached through a live
       ;; frame. Silently dropping it is Emacs's answer there too (the
       ;; text has already gone to `*Messages*` through
       ;; `message_dolog`).
       (let ((frame (*current-frame*)))
         (when frame (set-message! frame text)))))
    (*current-message-function*
     (lambda ()
       (let ((frame (*current-frame*)))
         (and frame (frame-message frame)))))

    ;; `insdel.c`'s `adjust_suspend_auto_hscroll` (`insdel.c:226`): "If
    ;; the selected window's old pointm is adjacent or covered by the
    ;; region from FROM to TO, unsuspend auto hscroll in that window."
    ;; The function is `insdel.c`'s - `adjust_markers_for_replace` calls
    ;; it one line before its loop - but what it *reads* is the selected
    ;; window, which is this library's, so `insdel.scm` declares the seam
    ;; and this installs it, exactly as `*current-editor-function*` above
    ;; is declared there and installed here.
    (*adjust-suspend-auto-hscroll-function*
     (lambda (from to)
       (let ((window (and (*current-frame*)
                          (frame-selected-window (*current-frame*)))))
         (when (and window
                    (window-buffer window)
                    (eq? (window-buffer window) (current-buffer))
                    (>= (%window-old-point window) from)
                    (<= (%window-old-point window) to))
           (set!%window-suspend-auto-hscroll? window #f)))))

    ))
