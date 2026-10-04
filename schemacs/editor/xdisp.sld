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
  ;; And what to draw as a search match arrives in `*search-highlight*',
  ;; which the search commands publish - in Emacs the same fact is the
  ;; `isearch' and `lazy-highlight' faces on the match. A renderer that
  ;; imported the minibuffer and the search would sit in a cycle with
  ;; them, and this is the knot the layout plan cuts here.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `display' is not in `(scheme base)' - it is `(scheme write)'s - and
    ;; `caddr' is `(scheme cxr)'s. The mode line's evaluator uses both, and
    ;; neither is missed until a mode line is drawn.
    (only (scheme write) display)
    (only (scheme cxr) caddr)
    ;; `filter' and `sort' order the overlay strings at a position, as
    ;; `load_overlay_strings' does with qsort.
    (only (guile) filter sort)
    ;; The display interface: the redisplay draws through these generics
    ;; and never touches a terminal itself. `dispnew.sld' defines them,
    ;; and `term.sld' answers them for the curses terminal.
    (only (schemacs editor dispnew)
          current-display
          write-glyphs! clear-frame-area!
          update-window-begin! update-window-end!
          draw-window-cursor! flush-display!
          realize-face)
    ;; The mode line reads a line and column out of the engine, which
    ;; answers with one of these.
    (only (schemacs ui text-buffer-impl)
          text-location-type? text-location-line text-location-column)

    (only (schemacs editor engine)
         line-break-newline line-break-crlf line-break-return
         string-search-forward text-editor-buffer-name text-editor-text-props
         text-editor-char-count text-editor-file-name
         text-editor-cursor-column text-editor-cursor-line
         text-editor-get-cursor text-editor-mark text-editor-get-end-of-line
         text-editor-get-line-column text-editor-get-start-of-line
         text-editor-line-count text-editor-line-editor-ref
         text-editor-line-outer-size text-editor-modified?
         text-editor-read-only? text-editor-text-line-ref
         text-editor-to-string text-line-inner->string)
    (only (schemacs editor frame)
         *current-frame* *echo-area-buffer* *echo-area-prompt*
         *frame-cursor-type* *frame-focus* frame-height frame-width
         frame-message frame-selected-window
         ;; `w->cursor_off_p', which `internal-show-cursor' turns off and
         ;; the cursor type is resolved against
         window-cursor-off?
         sync-frame-size! window-body-height
         window-body-width window-buffer window-height window-left
         window-list
         selected-window set!window-top-line window-point window-right-border?
         window-top
         window-top-line window-width
         ;; `w->hscroll' and its friends, which the hscroll display and
         ;; auto hscrolling read and write
         %window-hscroll %window-min-hscroll
         %window-old-point %window-suspend-auto-hscroll?
         set!%window-hscroll set!%window-min-hscroll
         set!%window-old-point set!%window-suspend-auto-hscroll?)
    (only (schemacs editor disp-table)
         char-display-cursor-width char-display-width
         char-display-glyph current-line-display-column display-text-width
         expand-line-display expand-line-glyphs line-display-offsets)
    ;; The `face' text property, and the faces themselves. A face reaches
    ;; the display through these libraries and no others: the property
    ;; says which faces are in effect, `xfaces' merges them and folds
    ;; them down, and the display realizes what that means on itself
    ;; (`realize-face').
    (only (schemacs editor textprop) get-text-property)
    (only (schemacs editor buffer)
          *transient-mark-mode*
          buffer-auto-hscroll-mode buffer-cursor-in-non-selected-windows
          buffer-cursor-type buffer-hscroll-margin buffer-hscroll-step
          buffer-local-value buffer-truncate-lines buffer-word-wrap
          ;; the mode line's mode name is the buffer's `mode-name'
          mode-name
          ;; and the overlays at a position are merged into its face
          overlay-end overlay-get overlay-priority overlay-start
          overlays-at overlays-in)

    (only (schemacs editor faces) *undefined-face-attribute*)
    (only (schemacs editor xfaces)
          attribute-value face-attributes-empty face-realized-attributes
          merge-face-ref merge-face-vectors)
    )

  (export
   ;; The search highlight is the search commands' to set, so it is
   ;; exported; `render!' and the mode line are what the rest calls.
   *search-highlight*
   cursor-screen-position
   highlight-matches
   ;; the run computation, which is what a caller can test without a
   ;; terminal: `draw-line!' itself needs one
   line-face-runs
   line-end-fill-attribute
   *mode-line-format*
   face-at-buffer-position
   overlay-strings-at
   face->attribute
   ;; the cursor's type, which the tests check without a display
   get-specified-cursor-type
   get-window-cursor-type
   format-mode-line
   *truncate-partial-width-windows*
   line-continuation-display?
   line-display-rows
   line-display-width
   mode-line-string
   render!
   scroll-to-cursor!
   status-string
   window-line-rows
   window-line-slices
   window-truncates-lines?
   )

  (begin

    (define *search-highlight*
      ;; What the renderer should draw as search matches, or false when
      ;; nothing should be: a pair of the search string and whether the
      ;; search folds case.
      ;;
      ;; The matching itself lives with the search commands - this is a
      ;; *display* fact, and it is here because the display layer must not
      ;; have to know who set it. In GNU Emacs the same fact is a text
      ;; property: isearch puts the `isearch\' face on the match point is
      ;; on and the `lazy-highlight\' face on the others, and `xdisp.c\'
      ;; draws whatever faces it finds. This editor has no text properties
      ;; and no overlays yet, so isearch publishes what it found here and
      ;; the renderer draws it.
      ;;--------------------------------------------------------------
      (make-parameter #f))
    (define (buffer-line-string ed i)
      ;; Get the displayable contents of line I (not including its
      ;; line break) as a string, or #f when I is past the end of the
      ;; buffer. The current line is read from the line editor, which
      ;; holds the live copy of the line under the cursor; every other
      ;; line is read from the lines gap-buffer.
      ;;
      ;; This is a departure, and there is no Emacs function to mirror
      ;; it with: xdisp.c never materialises a line as a string - it
      ;; walks the buffer with the display iterator (`struct it'),
      ;; fetching characters as it produces glyphs. Rendering from a
      ;; line string is this redisplay's shortcut.
      ;;--------------------------------------------------------------
      (cond
       ((= i (text-editor-cursor-line ed))
        ;; The live current line: the line editor's characters, from
        ;; the start of the line to the end of the line.
        (call-with-port (open-output-string)
          (lambda (port)
            (let* ((start (text-editor-get-start-of-line ed))
                   (end   (text-editor-get-end-of-line ed))
                   (len   (- end start)))
              (let loop ((j 0))
                (when (< j len)
                  (let ((ch (text-editor-line-editor-ref ed j)))
                    (when ch (write-char ch port)))
                  (loop (+ 1 j)))))
            (get-output-string port))))
       ((< i (text-editor-line-count ed))
        ;; the display form of the line: its contents WITHOUT the
        ;; terminating line break
        (text-line-inner->string (text-editor-text-line-ref ed i)))
       (else #f)))

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

    (define (line-display-texts ed line-start line-string)
      ;; LINE-STRING - the line beginning at buffer position LINE-START -
      ;; as the vector of texts described above, one entry per buffer
      ;; column. LINE-START is an engine position, which is what
      ;; `get-text-property' takes; the overlay layer is not consulted,
      ;; because the C's `handle_display_prop' reads the text property.
      ;;--------------------------------------------------------------
      (let ((len (string-length line-string)))
        (let loop ((i 0) (acc '()))
          (if (>= i len)
              (list->vector (reverse acc))
              (let ((prop (and ed
                               (get-text-property (+ line-start i)
                                                  'display ed))))
                (loop (+ i 1)
                      (cons (if (string? prop) prop (string-ref line-string i))
                            acc)))))))

    (define (buffer-line-texts window line-index)
      ;; The texts of LINE-INDEX's line in WINDOW, or #f when there is no
      ;; such line. Computing them needs the line's *buffer position*,
      ;; which `window-top-line-position' answers for any line.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             ;; The line number is tested here rather than left to
             ;; `buffer-line-string', because the position walk below has
             ;; no answer for a line that is not there.
             (line-string (and (>= line-index 0)
                               (< line-index (text-editor-line-count ed))
                               (buffer-line-string ed line-index))))
        (and line-string
             (line-display-texts ed
                                 (window-top-line-position ed line-index)
                                 line-string))))

    (define (texts-glyph texts i col)
      ;; Buffer column I of TEXTS as the string the redisplay writes for
      ;; it, drawn at screen column COL - `char-display-glyph', or the
      ;; `display' string standing there.
      ;;--------------------------------------------------------------
      (let ((entry (vector-ref texts i)))
        (if (string? entry) entry (char-display-glyph entry col))))

    (define (texts-width texts i col)
      ;; How many screen cells buffer column I of TEXTS takes, drawn at
      ;; screen column COL - `char-display-width', or the width of the
      ;; `display' string standing there. The two conds must agree with
      ;; `texts-glyph', as `char-display-width''s own note says.
      ;;--------------------------------------------------------------
      (let ((entry (vector-ref texts i)))
        (if (string? entry)
            (display-text-width entry col)
            (char-display-width entry col))))

    (define (line-texts-width texts)
      ;; The display width of TEXTS, all of it: `line-display-width' over
      ;; the texts rather than over the line's characters.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0))
        (if (>= i (vector-length texts))
            col
            (loop (+ i 1) (+ col (texts-width texts i col))))))

    (define (line-texts-column texts k)
      ;; The screen column at which buffer column K of TEXTS is drawn, so
      ;; a column a `display' property moved along is counted at where it
      ;; is really drawn.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0))
        (if (>= i k)
            col
            (loop (+ i 1) (+ col (texts-width texts i col))))))

    (define (line-texts-offsets texts from to)
      ;; Where each buffer column of the slice [FROM, TO) is drawn, as a
      ;; list of TO-FROM+1 screen columns, the last being the slice's own
      ;; width - `line-display-offsets'' walk over a vector of texts.
      ;;--------------------------------------------------------------
      (let loop ((i from) (col 0) (acc '()))
        (cond ((>= i to) (reverse (cons col acc)))
              (else
               (loop (+ i 1) (+ col (texts-width texts i col)) (cons col acc))))))

    (define (line-texts-glyphs texts from to)
      ;; The slice [FROM, TO) of TEXTS as a list of its glyph strings, one
      ;; per buffer column, in order - `expand-line-glyphs'' walk.
      ;;--------------------------------------------------------------
      (let loop ((i from) (col 0) (acc '()))
        (if (>= i to)
            (reverse acc)
            (let ((glyph (texts-glyph texts i col)))
              (loop (+ i 1)
                    (+ col (display-text-width glyph col))
                    (cons glyph acc))))))

    (define (line-texts-display texts from to width)
      ;; The slice [FROM, TO) of TEXTS as one string, cut at WIDTH screen
      ;; cells - `expand-line-display''s walk, and its same rule that the
      ;; glyph starting before WIDTH is written whole and the renderer
      ;; clips it by column.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i from) (col 0))
            (when (and (< i to) (< col width))
              (let ((glyph (texts-glyph texts i col)))
                (display glyph port)
                (loop (+ i 1) (+ col (display-text-width glyph col))))))
          (get-output-string port))))

    (define (truncate-line str width)
      (let ((len (string-length str)))
        (cond
         ((<= len width) str)
         ((<= width 0) "")
         (else (substring str 0 width)))))

    (define (pad-line str width)
      (let ((len (string-length str)))
        (cond
         ((< width len) (truncate-line str width))
         (else (string-append str (make-string (- width len) #\space))))))

    (define *truncate-partial-width-windows* (make-parameter 50))
    ;; ^ GNU Emacs's `truncate-partial-width-windows', which `xdisp.c'
    ;; declares and defaults to 50. Non-nil means truncate lines in
    ;; windows narrower than the frame; an *integer* means truncate a
    ;; partial-width window only when it is narrower than that many
    ;; columns; nil means let `truncate-lines' decide on its own.
    ;;
    ;; It is here rather than in `window.sld' because `init_iterator' is
    ;; where Emacs reads it, and `init_iterator' is `xdisp.c'.

    (define (window-full-width? window)
      ;; Whether WINDOW spans the whole frame: GNU Emacs's
      ;; `WINDOW_FULL_WIDTH_P'. This editor's windows are tiled the same
      ;; way, so a window is full width when it is as wide as the frame.
      ;;--------------------------------------------------------------
      (and (*current-frame*)
           (= (window-width window) (frame-width (*current-frame*)))))

    (define (window-truncates-lines? window)
      ;; Whether WINDOW cuts long lines off instead of continuing them:
      ;; the `it->line_wrap' test at the top of GNU Emacs's
      ;; `init_iterator' (`xdisp.c':3414), which asks four things.
      ;;
      ;;   1. `base_face_id == DEFAULT_FACE_ID' - this is the *text*
      ;;      area. A mode line or the echo area never wraps, and the
      ;;      callers of this ask only about text rows.
      ;;   2. `!it->w->hscroll' - a horizontally scrolled window cannot
      ;;      wrap as well (`init_iterator' sets `line_wrap' to TRUNCATE
      ;;      when `w->hscroll' is set), so a window with an `hscroll'
      ;;      truncates whatever `truncate-lines' says.
      ;;   3. the window is full-frame width, or
      ;;      `truncate-partial-width-windows' lets it wrap: nil lets it,
      ;;      `t' truncates every partial-width window, and an integer N
      ;;      truncates one narrower than N.
      ;;   4. `truncate-lines' is nil.
      ;;
      ;; and it wraps when all four hold, at a word when `word-wrap' is
      ;; set and at the edge otherwise.
      ;;--------------------------------------------------------------
      (let ((ptw (*truncate-partial-width-windows*))
            (cols (window-width window)))
        (or (not (= (%window-hscroll window) 0))
            (not (and (or (window-full-width? window)
                          (not ptw)
                          (and (exact-integer? ptw) (<= ptw cols)))
                      (not (buffer-truncate-lines
                            (window-buffer window))))))))

    (define (string->texts str)
      ;; STR's characters as a texts vector - what `line-display-texts'
      ;; builds for a line that carries no `display' property, and the
      ;; reason `line-display-rows' can keep taking a plain string.
      ;;--------------------------------------------------------------
      (let* ((n (string-length str))
             (v (make-vector n)))
        (let loop ((i 0))
          (when (< i n)
            (vector-set! v i (string-ref str i))
            (loop (+ i 1))))
        v))

    (define (line-display-rows line-string width wrap? word-wrap?)
      ;; LINE-STRING as the screen rows it is drawn on - `line-texts-rows'
      ;; over the line's own characters. A line that carries a `display'
      ;; property has to go through `line-texts-rows' with
      ;; `line-display-texts'' vector instead; this entry point is for a
      ;; string that carries none, which is what the mode line, the echo
      ;; area and the layout tests use.
      ;;--------------------------------------------------------------
      (line-texts-rows (string->texts line-string) width wrap? word-wrap?))

    (define (line-texts-rows texts width wrap? word-wrap?)
      ;; The screen rows LINE-STRING is drawn on, each a
      ;; `(FIRST . LAST)' pair of *buffer* columns. One row when the line
      ;; is truncated or short enough; several when it wraps.
      ;;
      ;; This is the heart of what `display_line' does in `xdisp.c': it
      ;; produces one screen row per call, and calls itself again for the
      ;; rest of the line. The two things it decides are where to break -
      ;; at the window edge, or at "the space or tab character nearest to
      ;; the right window edge" when `word-wrap' is set - and that a row
      ;; never holds more than WIDTH cells.
      ;;
      ;; The column a tab expands to is measured from the start of the
      ;; *row*, not of the line, because a wrapped row starts at screen
      ;; column zero. That is why this cannot use `line-display-offsets',
      ;; which measures from the start of the line.
      ;;
      ;; The last cell of a row that carries a marker is not text, and
      ;; that matters to the arithmetic: `init_iterator' reduces the
      ;; usable width by the marker's width - `it->last_visible_x -=
      ;; it->continuation_pixel_width' (`xdisp.c':3509-3518) - and only
      ;; when the window has no right fringe. This editor has no fringes,
      ;; so a row holds WIDTH-1 cells and the marker takes the last one.
      ;; Emacs on a terminal was measured doing exactly that: 100 `X' in
      ;; an 80-column window came out 79 and `\', then 21 on the row
      ;; below. Reserving the cell is what stops the marker from landing
      ;; on top of the line's last character and losing it.
      ;;--------------------------------------------------------------
      (let ((len (vector-length texts))
            (usable (max 1 (- width 1))))
        (cond
         ((or (not wrap?) (<= len 0))
          ;; truncated, or nothing to lay out: one row, the whole line
          (list (cons 0 len)))
         (else
          (let loop ((start 0) (i 0) (col 0) (space #f) (rows '()))
            (cond
             ((>= i len) (reverse (cons (cons start len) rows)))
             (else
              (let* ((entry (vector-ref texts i))
                     (w (texts-width texts i col)))
                (if (and (> (+ col w) usable) (> i start))
                    ;; this character does not fit and the row is not
                    ;; empty, so break here - or after the last space, if
                    ;; word wrapping and there is one. A `display' string
                    ;; standing on a column is not a space, whatever it
                    ;; looks like: the break is at a buffer space.
                    (let ((end (if (and word-wrap? space (> space start))
                                   (+ space 1)
                                   i)))
                      (loop end end 0 #f (cons (cons start end) rows)))
                    (loop start
                          (+ i 1)
                          (+ col w)
                          (if (and word-wrap?
                                   (char? entry)
                                   (char=? entry #\space))
                              i space)
                          rows))))))))))

    (define (hscroll-line-slice window texts)
      ;; The `(FIRST . LAST)' buffer columns an hscrolled window shows of
      ;; the line whose texts are TEXTS, always exactly one screen row's
      ;; worth. An hscrolled
      ;; window's view is the display columns from `first_visible_x' to
      ;; `last_visible_x' (`init_iterator', `xdisp.c:3501' and `:3509':
      ;; `first_visible_x = w->hscroll', `last_visible_x = first_visible_x
      ;; + body_width - truncation_pixel_width') - and the first *text*
      ;; column is one past `first_visible_x', because the character at
      ;; the hscroll column is the one the left truncation glyph
      ;; overwrites (`insert_left_trunc_glyphs', `xdisp.c:23884'): with
      ;; `hscroll' = H, `$' is drawn in the row's first cell and the
      ;; characters whose display columns lie in [H+1, H+WIDTH-1) fill
      ;; the rest, the right `$' taking the last cell. This was measured
      ;; against `emacs -nw': `hscroll' = 100 in an 80-column window drew
      ;; `$', characters 101 to 178, and `$'.
      ;;
      ;; The cut is made at a character boundary by display column - the
      ;; offsets `line-display-offsets' answers - because a tab or a wide
      ;; character is more than one cell and a hscroll of its middle
      ;; would tear it.
      ;;--------------------------------------------------------------
      (let* ((h (%window-hscroll window))
             (width (window-body-width window))
             (len (vector-length texts))
             ;; a vector, because the walk indexes it per character and
             ;; a `list-ref' per step would make a long line quadratic
             (offsets (list->vector (line-texts-offsets texts 0 len))))
        (let loop ((i 0) (start #f))
          (cond
           ((>= i len) (cons (or start len) len))
           ((not start)
            ;; the first character whose display column is past the
            ;; truncation glyph
            (loop (+ i 1) (if (>= (vector-ref offsets i) (+ h 1)) i #f)))
           ((>= (vector-ref offsets i) (+ h (- width 1)))
            (cons start i))
           (else (loop (+ i 1) start))))))

    (define (window-wraps? window)
      ;; Whether WINDOW lays a long line out over several screen rows.
      ;;--------------------------------------------------------------
      (not (window-truncates-lines? window)))

    (define (window-line-rows window line-index)
      ;; How many screen rows the buffer line LINE-INDEX takes in WINDOW:
      ;; one when it is short enough or truncated, more when it wraps.
      ;;--------------------------------------------------------------
      (let ((texts (buffer-line-texts window line-index)))
        (if texts (%window-line-rows window texts) 1)))

    (define (%window-line-rows window texts)
      ;; `window-line-rows' over texts already in hand.
      ;;--------------------------------------------------------------
      (cond ((and (not (window-wraps? window))
                  (> (%window-hscroll window) 0))
             ;; an hscrolled line is one row, whatever its length
             1)
            (else
             (length (line-texts-rows texts
                                      (window-body-width window)
                                      (window-wraps? window)
                                      (buffer-word-wrap
                                       (window-buffer window)))))))

    (define (window-line-slices window line-index)
      ;; The `(FIRST . LAST)' buffer columns of each screen row the buffer
      ;; line LINE-INDEX takes in WINDOW - the rows to draw, in order.
      ;;--------------------------------------------------------------
      (let ((texts (buffer-line-texts window line-index)))
        (if texts (%window-line-slices window texts) '())))

    (define (%window-line-slices window texts)
      ;; `window-line-slices' over texts already in hand. The row walk
      ;; computes them itself, beside the line's buffer position, so that
      ;; a line with a `display' property is walked for it once.
      ;;--------------------------------------------------------------
      (cond ((and (not (window-wraps? window))
                  (> (%window-hscroll window) 0))
             (list (hscroll-line-slice window texts)))
            (else
             (line-texts-rows texts
                              (window-body-width window)
                              (window-wraps? window)
                              (buffer-word-wrap
                               (window-buffer window))))))

    (define (rows-above window line)
      ;; How many screen rows the lines between WINDOW's top line and
      ;; LINE take, not counting LINE itself: what a screen row has to be
      ;; offset by when the window's top is a *line* and the rows are not
      ;; one per line.
      ;;--------------------------------------------------------------
      (let loop ((l (window-top-line window)) (used 0))
        (if (>= l line)
            used
            (loop (+ l 1) (+ used (window-line-rows window l))))))

    (define (rows-row-of-column rows column)
      ;; Which of ROWS (a line's `(FIRST . LAST)' list) buffer column
      ;; COLUMN is drawn on - the row the cursor belongs to.
      ;;--------------------------------------------------------------
      (let loop ((rest rows) (k 0))
        (cond ((null? rest) 0)
              ((< column (cdr (car rest))) k)
              (else (loop (cdr rest) (+ k 1))))))

    (define (scroll-to-cursor! window)
      ;; Adjust WINDOW's top line so that its point is visible, as GNU
      ;; Emacs's redisplay does before drawing each window.
      ;;
      ;; "Visible" means the cursor's *screen row*, not its buffer line:
      ;; a wrapped line is several rows tall, so a window whose top is a
      ;; line has to be able to say that the cursor's line begins above
      ;; it and the cursor's own row does not. A window's top is always a
      ;; line beginning - Emacs's `start_at_line_beg', which is what
      ;; ordinary scrolling gives - so the top is a line and its rows
      ;; follow from it.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (vheight (window-body-height window))
             (cursor-line (text-editor-cursor-line ed))
             (top (window-top-line window)))
        (cond
         ((< cursor-line top)
          ;; point is above the window
          (set!window-top-line window cursor-line))
         (else
          ;; walk down from the top to the cursor's line, counting rows
          (let loop ((line top) (used 0))
            (cond
             ((> line cursor-line) #t)          ; visible as it stands
             ((>= used vheight)
              ;; the cursor's line has fallen off the bottom: back up from
              ;; the cursor's own row until one more line will not fit
              (let back ((l cursor-line)
                         (need (+ 1 (rows-row-of-column
                                     (window-line-slices window cursor-line)
                                     (text-editor-cursor-column ed)))))
                (if (and (> l 0)
                         (< (+ need (window-line-rows window (- l 1))) vheight))
                    (back (- l 1) (+ need (window-line-rows window (- l 1))))
                    (set!window-top-line window l))))
             (else
              ;; the cursor's line: visible only if its own row is
              (if (= line cursor-line)
                  (let ((k (rows-row-of-column
                            (window-line-slices window line)
                            (text-editor-cursor-column ed))))
                    (when (>= (+ used k) vheight)
                      ;; its row is below the window, so it becomes the last
                      (let back ((l cursor-line) (need (+ 1 k)))
                        (if (and (> l 0)
                                 (< (+ need (window-line-rows window (- l 1)))
                                    vheight))
                            (back (- l 1)
                                  (+ need (window-line-rows window (- l 1))))
                            (set!window-top-line window l))))))
                  (loop (+ line 1) (+ used (window-line-rows window line))))))))))

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
        (let* ((texts (buffer-line-texts window (text-editor-cursor-line ed)))
               (width (window-body-width window))
               (margin (max 0 (buffer-hscroll-margin ed)))
               (point-x (if texts
                            (current-line-display-column
                             ed (text-editor-cursor-column ed))
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
      ;; GNU Emacs's `mode-line-eol-desc', which reads the buffer-local
      ;; `buffer-file-coding-system' in the window being rendered.
      ;;--------------------------------------------------------------
      (let* ((window (*mode-line-window*))
             (line-break
              (buffer-local-value (window-buffer window)
                                  'buffer-file-coding-system
                                  line-break-newline)))
        (cond ((eq? line-break line-break-crlf) "(DOS)")
              ((eq? line-break line-break-return) "(Mac)")
              ((eq? line-break line-break-newline) ":")
              (else ""))))

    (define (mode-line-mode-name)
      ;; GNU Emacs's `mode-line-modes'' first element: the buffer's
      ;; `mode-name' between the delimiters `mode-line-modes-delimiters'
      ;; names - "(" and ")" by default, which is what makes a mode line
      ;; read `(Fundamental)'.
      ;;
      ;; Not ported from that construct: `mode-line-process', the
      ;; `mode-line-minor-modes' lighters (there are no minor modes with
      ;; lighters yet) and the mouse maps on the name.
      ;;--------------------------------------------------------------
      (let ((window (*mode-line-window*)))
        (if (not window)
            ""
            (string-append "(" (mode-name (window-buffer window)) ")"))))

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
       (list (list ':eval mode-line-eol-desc)
             " "
             (list "%1*" "%1+")
             " "
             "%12b"
             " -- L" "%l" " C" "%c"
       ;; and the mode name, where Emacs's default puts `mode-line-modes':
       ;; after the position, two spaces along. Emacs names the variable
       ;; in the format and evaluates it; there is no variable registry
       ;; here, so the construct that produces it is spelled out.
       "  "
       (list ':eval mode-line-mode-name))))

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
      (let* ((ed (window-buffer window))
             (at (text-editor-get-line-column ed (window-point window)))
             ;; The line point is on, for `%c' and `%C': Emacs's
             ;; `current-column' is the number of *screen* columns from the
             ;; start of the line, which is not the number of characters
             ;; when the line holds a tab or a wide character - nor when a
             ;; `display' property stands on the way, which moves the
             ;; columns after it along.
             (line-index (- (text-location-line at) 1))
             (line (buffer-line-string ed line-index))
             (line-texts (and line
                              (line-display-texts
                               ed (window-top-line-position ed line-index)
                               line))))
        (case spec
          ((#\%) "%")
          ((#\b) (or (text-editor-buffer-name ed) "*scratch*"))
          ((#\f) (or (text-editor-file-name ed) ""))
          ((#\l) (number->string (text-location-line at)))
          ;; `%c' is GNU Emacs's `(current-column)': the *screen* column,
          ;; counting from zero - "the leftmost column is displayed as
          ;; zero", which a terminal Emacs confirms: `(format-mode-line
          ;; "%c")' at the start of a line is "0". The engine's column is
          ;; a character count, so the construct converts it through the
          ;; line's display widths - which is what makes it 3 rather than
          ;; 2 after a CJK character, as Emacs's is.
          ((#\c) (number->string (if line-texts
                                     (line-texts-column
                                      line-texts (- (text-location-column at) 1))
                                     (- (text-location-column at) 1))))
          ;; `%C' is `%c' counting from one rather than zero
          ((#\C) (number->string (if line-texts
                                     (+ 1 (line-texts-column
                                           line-texts
                                           (- (text-location-column at) 1)))
                                     (text-location-column at))))
          ;; `%*' is `%' read-only, `*' modified, `-' neither; `%+' is `*'
          ;; modified, `%' read-only, `-' neither; `%&' is `*' modified
          ((#\*) (if (text-editor-read-only? ed)
                     "%"
                     (if (text-editor-modified? ed) "*" "-")))
          ((#\+) (if (text-editor-modified? ed)
                     "*"
                     (if (text-editor-read-only? ed) "%" "-")))
          ((#\&) (if (text-editor-modified? ed) "*" "-"))
          ((#\i) (number->string (text-editor-char-count ed)))
          ((#\I) (let ((n (text-editor-char-count ed)))
                   (cond ((< n 10000) (number->string n))
                         ((< n 10000000)
                          (string-append (number->string (quotient n 1000)) "k"))
                         (else
                          (string-append (number->string (quotient n 1000000))
                                         "M")))))
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
         ((number-in-field? text)
          (string-append (make-string (- width len) #\space) text))
         (else (string-append text (make-string (- width len) #\space))))))

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
            (substring text 0 width)
            (string-append text (make-string (- width len) #\space)))))

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
               ((and (memq (car construct) '(:eval :propertize))
                     (pair? (cdr construct)))
                (process (if (eq? (car construct) ':eval)
                             ((cadr construct))
                             (cadr construct))))
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
               (else (apply string-append (map process construct)))))
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

    (define (line-outer-size ed line-index)
      ;; How many characters line LINE-INDEX advances the buffer's
      ;; character index by - its contents plus its line break, which is
      ;; what the CDF counts, and so what the next line's first character
      ;; is offset by.
      ;;--------------------------------------------------------------
      (text-editor-line-outer-size ed line-index))

    ;; `display-column-of' used to sit here - the screen column at which
    ;; buffer column COL of a line is drawn, as the display width of the
    ;; line's *prefix*. It walked the line string, so a `display' property
    ;; on the way was not counted, and both of its callers now go through
    ;; `line-texts-column' with the line's texts instead.

    ;;----------------------------------------------------------------
    ;; Faces

    (define (face->attribute face-name)
      ;; The display's drawing token for a *named* face: GNU Emacs's
      ;; `face_at_buffer_position' where the face is known by name, which
      ;; is what the mode line and the echo area need. The realized
      ;; attributes are merged here - the default face under any other -
      ;; and the display turns them into its token
      ;; (`realize-face' is the display side of a face).
      ;;--------------------------------------------------------------
      (realize-face (current-display)
                    (merge-face-vectors (face-realized-attributes face-name)
                                        (face-realized-attributes 'default))))

    (define (line-face-runs ed line-start line-string)
      ;; LINE-STRING as maximal runs of characters that share one face:
      ;; `(FROM TO ATTRIBUTE)' in buffer columns, ATTRIBUTE being what
      ;; `face-at-buffer-position' answers.
      ;;
      ;; The runs, not the characters, are what gets drawn: a terminal is
      ;; told "these cells are bold" once per run rather than once per
      ;; character, which is the same reason Emacs walks faces with
      ;; `next-single-property-change' instead of asking at every
      ;; position.
      ;;--------------------------------------------------------------
      (let ((len (string-length line-string)))
        (if (= len 0)
            '()
            (let loop ((i 1)
                     (start 0)
                     (attribute (face-at-buffer-position ed line-start))
                     (acc '()))
              (if (>= i len)
                  (reverse (cons (list start len attribute) acc))
                  (let ((a (face-at-buffer-position ed (+ line-start i))))
                    (if (equal? a attribute)
                        (loop (+ 1 i) start attribute acc)
                        (loop (+ 1 i) i a (cons (list start i attribute) acc)))))))))

    (define (line-glyph-run glyphs offsets from to width)
      ;; The text to write for the buffer columns [FROM, TO) of a line
      ;; whose per-character glyphs are the vector GLYPHS and whose screen
      ;; columns are the vector OFFSETS: `(TEXT . SCREEN-COLUMN)', or #f
      ;; when the run starts at or past the window's WIDTH and so is not
      ;; drawn at all.
      ;;
      ;; The cut is at a glyph boundary and made in *screen columns*,
      ;; which is why this is a walk and not a `substring'. A run is a
      ;; range of buffer characters; a character is not always one cell;
      ;; and a glyph that would begin past the edge ends the run there -
      ;; which is how GNU Emacs truncates a line at the window boundary.
      ;;--------------------------------------------------------------
      (let ((start (vector-ref offsets from)))
        (and (< start width)
             (let loop ((i from) (acc '()))
               (if (or (>= i to) (>= (vector-ref offsets i) width))
                   (cons (apply string-append (reverse acc)) start)
                   (loop (+ i 1) (cons (vector-ref glyphs i) acc)))))))

    (define (draw-overlay-strings! entries screen-row x)
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
              (write-glyphs! (current-display) text screen-row x
                             (and face (face->attribute face)))
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

    (define (row-string-elements? strings)
      ;; Whether any column of the row has an overlay string at all.
      ;;--------------------------------------------------------------
      (let loop ((c 0))
        (cond ((>= c (vector-length strings)) #f)
              ((null? (vector-ref strings c)) (loop (+ c 1)))
              (else #t))))

    (define (draw-row-with-strings! ed texts from to slice-start strings
                                    screen-row x0 width)
      ;; Draw a row that has overlay strings on it, and answer the column
      ;; it ended at. The row's buffer columns are [FROM, TO) of TEXTS.
      ;;
      ;; The strings are cells that are *not* buffer characters, so the
      ;; row can no longer be drawn as runs of the line's columns: every
      ;; column is walked in turn, its `before-string's drawn, then its
      ;; own glyph, then its `after-string's. That is what `xdisp.c''
      ;; iterator does - it delivers the overlay strings at a position
      ;; and then the character there.
      ;;--------------------------------------------------------------
      (let ((len (- to from)))
        (let loop ((c 0) (col 0))
          (if (or (> c len) (>= col width))
              col
              ;; a column with no strings has `'()' there, not a pair
              (let* ((strs (vector-ref strings c))
                     (heads (if (pair? strs) (car strs) '()))
                     (tails (if (pair? strs) (cdr strs) '()))
                     (col (draw-overlay-strings! heads screen-row
                                                 (+ x0 col))))
                (if (>= c len)
                    (draw-overlay-strings! tails screen-row (+ x0 col))
                    (let* ((i (+ from c))
                           (glyph (texts-glyph texts i col))
                           (w (texts-width texts i col)))
                      (when (< col width)
                        (write-glyphs!
                         (current-display) glyph screen-row
                         (+ x0 col)
                         (face-at-buffer-position ed (+ slice-start c))))
                      ;; and the `after-string's come after the character,
                      ;; not at the end of the row - which is what the
                      ;; first version of this got wrong
                      (loop (+ c 1)
                            (draw-overlay-strings! tails screen-row
                                                   (+ x0 col w))))))))))

    (define (draw-line! ed slice-start line-string texts slice
                        screen-row x0 width more? truncated?)
      ;; Draw one *screen row* of a line at SCREEN-ROW, X0. SLICE is the
      ;; row's own buffer columns in TEXTS - the caller cut them out of
      ;; the line, whose texts TEXTS are and whose string LINE-STRING is,
      ;; the latter for the region's line-end rule.
      ;;
      ;; A row of a long line is one of three things, and the last cell
      ;; says which: it *continues* on the next row (MORE?), it was *cut
      ;; off* by the window edge (TRUNCATED?), or it is the line's last
      ;; row. GNU Emacs marks the first with `\' and the second with
      ;; `$' (`produce_special_glyphs', `xdisp.c':33200 and :33287) - and
      ;; drawing `\' for a *truncated* line, which is what this did while
      ;; there was no wrapping at all, is the marker for the other thing.
      ;; A terminal was verified against `emacs -nw': 79 `X' then `\',
      ;; with the rest of the line on the row below.
      ;;
      ;; A row with overlay strings on it takes a different path: see
      ;; `draw-row-with-strings!'. A row without them is unchanged, so
      ;; the common case keeps its fast path.
      ;;--------------------------------------------------------------
      (let* ((from (car slice))
             (to (cdr slice))
             (len (- to from))
             ;; The row's own width: `display` holds no tabs or control
             ;; characters - they were expanded into it - so this is a sum
             ;; of character widths, and for a wide character that is 2
             ;; where a `string-length' would say 1.
             (display (line-texts-display texts from to width))
             ;; the row's own characters, which the two face walks below
             ;; ask the length of
             (slice-string (substring line-string from to))
             (strings (row-overlay-strings ed slice-start len))
             (drawn-width
              (if (row-string-elements? strings)
                  (draw-row-with-strings! ed texts from to slice-start strings
                                          screen-row x0 width)
                  (begin
                    (if (and (not (text-editor-text-props ed))
                             (not (region-face-active? ed)))
                        (write-glyphs! (current-display) display screen-row x0 #f)
                        (let ((offsets (list->vector
                                        (line-texts-offsets texts from to)))
                              (glyphs (list->vector
                                       (line-texts-glyphs texts from to))))
                          (for-each
                           (lambda (run)
                             (let ((drawn (line-glyph-run glyphs offsets
                                                          (car run) (cadr run) width)))
                               (when drawn
                                 (write-glyphs! (current-display) (car drawn)
                                                screen-row
                                                (+ x0 (cdr drawn)) (caddr run)))))
                           (line-face-runs ed slice-start slice-string))))
                    (line-display-width display)))))
        ;; The last cell, and what the row's own width was.
        (cond
         (more? (draw-special-glyph! screen-row x0 width "\\"))
         (truncated? (draw-special-glyph! screen-row x0 width "$"))
         (else
          ;; the line's own end: a region may extend its face into the
          ;; empty cells after the text
          (let ((fill (line-end-fill-attribute ed slice-start slice-string
                                               display width)))
            (when fill
              (write-glyphs! (current-display)
                             (make-string (- width drawn-width) #\space)
                             screen-row (+ x0 drawn-width) fill)))))))

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

    (define (line-continuation-display? line-string width)
      ;; Whether the logical line's full display width exceeds this row:
      ;; GNU Emacs puts a special continuation glyph in the final cell.
      ;; Tabs and control characters may occupy more than one display cell.
      ;;--------------------------------------------------------------
      (and (> width 0)
           (> (line-display-width line-string) width)))

    (define (draw-special-glyph! row x0 width glyph)
      ;; The continuation glyph (`\') or the truncation glyph (`$') in a
      ;; row's last cell. It is a special display character, not buffer
      ;; text, and Emacs draws it with the default face even inside a
      ;; region - `produce_special_glyphs' uses `DEFAULT_FACE_ID'.
      ;;--------------------------------------------------------------
      (write-glyphs! (current-display) glyph row (+ x0 width -1)
                     (face->attribute 'default)))

    (define (line-end-fill-attribute ed line-start line-string display width)
      ;; Face used for cells after a line's text when the line-end
      ;; position is inside the active region. LINE-STRING is the *row's*
      ;; text, so its length is the row's. A line that ends at point-max
      ;; has no newline position and gets no extension face in Emacs.
      ;;--------------------------------------------------------------
      (let* ((row-end (+ line-start (string-length line-string)))
             (mark (text-editor-mark ed))
             (point (text-editor-get-cursor ed))
             (region-start (and mark (min point mark)))
             (region-end (and mark (max point mark))))
        (and (< (line-display-width display) width)
             (region-face-active? ed)
             region-start
             region-end
             (<= region-start row-end)
             (< row-end region-end)
             (< row-end (text-editor-char-count ed))
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
           (text-editor-mark ed)))

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
           (let ((mark (text-editor-mark ed)))
             (and mark
                  (let* ((point (text-editor-get-cursor ed))
                         (beginning (min mark point))
                         (end (max mark point)))
                    (and (>= position beginning)
                         (< position end)))))))

    (define (face-at-buffer-position ed position)
      ;; The display's token for the face in effect at POSITION
      ;; in ED: GNU Emacs's `face_at_buffer_position'. The `face' text
      ;; property there - a face name, a property list, or a list of
      ;; either - is merged with the `default' face and folded down to
      ;; what the terminal can draw. `xfaces.c' merges overlays after the
      ;; text property; the active region face follows those in Emacs's
      ;; redisplay pipeline, and is merged here after the property face.
      ;;
      ;; Emacs caches the realized face against the position, because
      ;; this runs per character; a cache is worth adding when the
      ;; renderer starts asking per character rather than per run.
      ;;--------------------------------------------------------------
      (let* ((attrs
              (merge-face-ref (get-text-property position 'face ed)
                              (merge-face-vectors
                               (face-realized-attributes 'default)
                               (face-attributes-empty))))
             ;; and the overlays', merged over it in *increasing* order of
             ;; priority so that the highest-priority one ends on top -
             ;; which is what `xfaces.c''s `face_at_buffer_position' does
             ;; with the same list, sorted the same way.
             (attrs
              (let loop ((ovs (reverse (overlays-at position #t))) (attrs attrs))
                (if (null? ovs)
                    attrs
                    (loop (cdr ovs)
                          (merge-face-ref (overlay-get (car ovs) 'face) attrs))))))
        (realize-face (current-display)
                     (if (region-face-at-position? ed position)
                         (merge-face-ref 'region attrs)
                         attrs))))

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

    (define (draw-match row x0 glyphs offsets line-start len start end
                        point width)
      ;; Draw the part of the search match [START, END) that falls on this
      ;; line over the text already drawn there: in reverse video when
      ;; point is inside the match (GNU Emacs's `isearch' face) and in
      ;; bold otherwise (`lazy-highlight'). ROW is the screen row and X0
      ;; the screen column the window's text starts at.
      ;;
      ;; GLYPHS and OFFSETS are the line's, computed once by the caller
      ;; for all its matches.
      ;;
      ;; The match is cut out of the line as a range of *buffer*
      ;; characters and placed at its screen column, so a line holding a
      ;; wide character highlights the match itself and not the two cells
      ;; before it.
      ;;--------------------------------------------------------------
      (let* ((col (max 0 (- start line-start)))
             (to (min len (- end line-start)))
             (drawn (and (> to col)
                         (line-glyph-run glyphs offsets col to width))))
        (when drawn
          (write-glyphs!
           (current-display)
           (car drawn)
           row (+ x0 (cdr drawn))
           (face->attribute
            (if (and (<= start point) (<= point end))
                'isearch 'lazy-highlight))))))

    (define (highlight-matches window row line line-start width
                               pattern case-fold? x-offset texts from)
      ;; Draw the search matches that fall on this line over the line that
      ;; has just been drawn, so that what was found can be seen.
      ;;
      ;; The matching is done on the line's own text rather than through
      ;; the buffer: a buffer search re-reads the text from where it
      ;; starts, and a screenful of rows each searching a large buffer
      ;; costs far more than the drawing is worth - enough to look like a
      ;; hang. Only matches that lie wholly within the line are drawn, so
      ;; a search string containing a line break (typed as C-j) finds its
      ;; match and moves point, but nothing is highlighted for it.
      ;;
      ;; ROW is the row's own row *within the window* - the screen row
      ;; comes from adding `window-top' to it here, which is why the
      ;; caller passes `(+ row k)' and not the slice index `k' alone: `k'
      ;; counts the rows of one buffer line, and a match on the window's
      ;; second line drawn with `k' lands on the window's first row.
      ;;
      ;; X-OFFSET is how far right of the window's left edge the line's
      ;; first cell is drawn - one when the row begins with the left
      ;; truncation glyph, zero otherwise.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (row (+ row (window-top window)))
             (x0 (+ (window-left window) x-offset))
             (len (string-length line))
             ;; the row's buffer columns are [FROM, FROM+LEN) of TEXTS,
             ;; which is where the glyphs and screen columns come from -
             ;; the match is found in LINE's characters and drawn in the
             ;; row's glyphs, and a `display' property makes those differ
             (to (+ from len))
             (glyphs (list->vector (line-texts-glyphs texts from to)))
             (offsets (list->vector (line-texts-offsets texts from to)))
             (point (text-editor-get-cursor ed))
             (plen (string-length pattern)))
        (let loop ((at 0))
          (let ((found (string-search-forward line pattern at case-fold?)))
            (when (and found (<= (+ found plen) len))
              (draw-match row x0 glyphs offsets line-start len
                          (+ line-start found) (+ line-start found plen)
                          point width)
              ;; on to the next match, starting inside this one so that
              ;; overlapping matches are found too, as a repeated search
              ;; finds them
              (loop (+ 1 found)))))))

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
             (selected (frame-selected-window (*current-frame*)))
             ;; Emacs: "Detect a nonselected window or nonselected
             ;; frame" - a frame that is not the display's highlight
             ;; frame is treated as a non-selected one, so its cursor is
             ;; a hollow box rather than a filled one.
             (non-selected (or (not (eq? window selected))
                               (not (*frame-focus*))))
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

    (define (cursor-glyph ed)
      ;; The buffer character ED's cursor is drawn over, and the face in
      ;; effect there, as `(TEXT . TOKEN)'.
      ;;
      ;; A display that can only fill a rectangle needs both: Emacs's
      ;; cursor does not *hide* what is under it, it redraws the glyph in
      ;; the cursor's colours (`draw_phys_cursor_glyph' with
      ;; `DRAW_CURSOR'), so "the text inside the cursor stays visible".
      ;; Past the end of the line there is no character, and what is
      ;; under the cursor is the space beyond the text - Emacs draws the
      ;; cursor there too.
      ;;--------------------------------------------------------------
      (let* ((line (text-editor-cursor-line ed))
             (column (text-editor-cursor-column ed))
             (line-string (buffer-line-string ed line))
             (position (text-editor-get-cursor ed)))
        (if (and line-string (< column (string-length line-string)))
            (cons (string (string-ref line-string column))
                  (face-at-buffer-position ed position))
            (cons " " (face->attribute 'default)))))

    (define (cursor-cells ed)
      ;; How many cells wide the cursor over ED's point is drawn: the
      ;; width of the character at point.
      ;;
      ;; Emacs puts the cursor on the glyph at point, so over a
      ;; double-width character it is two cells wide. Past the end of the
      ;; line there is no character to sit on, and Emacs draws a one-cell
      ;; cursor in the space beyond it - which is what this answers there.
      ;;--------------------------------------------------------------
      (let* ((line (text-editor-cursor-line ed))
             (column (text-editor-cursor-column ed))
             (line-string (buffer-line-string ed line)))
        (if (and line-string (< column (string-length line-string)))
            (char-display-cursor-width
             (string-ref line-string column)
             (current-line-display-column ed column))
            1)))

    (define (cursor-screen-position window)
      ;; Where on the screen WINDOW's point belongs, as a pair, or #f
      ;; when it is scrolled out of view. In frame coordinates: the
      ;; window's own rows start below its top.
      ;;
      ;; It is the *window's* point that is placed, and only the
      ;; selected window shows a cursor - a terminal has one cursor, as
      ;; GNU Emacs draws only the selected window's.
      ;;
      ;; Point is always on a line the buffer really has - the engine
      ;; reports the end of a buffer whose last line has no break after
      ;; it as the end of that line, not as an empty line past it (see
      ;; `TEXT-EDITOR-INDEX-LINE-OFFSET'), which is where GNU Emacs puts
      ;; `point-max' too. A line break at the end of the buffer *does*
      ;; start an empty line, and that line gets a row of its own.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (line (text-editor-cursor-line ed))
             (column (text-editor-cursor-column ed))
             (line-string (buffer-line-string ed line))
             (texts (and line-string
                         (line-display-texts
                          ed (text-editor-get-start-of-line ed) line-string)))
             (width (window-body-width window))
             (vheight (window-body-height window))
             ;; The cursor's own row is not its line's row: a wrapped
             ;; line is several rows tall, so the rows above the cursor's
             ;; line have to be counted too - and within its line, the
             ;; rows before the one the cursor's column falls on.
             (screen-row (and line-string
                              (+ (rows-above window line)
                                 (rows-row-of-column
                                  (window-line-slices window line) column))))
             ;; The column within its *row*: a continuation row starts at
             ;; screen column zero, so the cursor's display column is
             ;; measured from where its row begins, not the line.
             (row-start (and line-string
                             (let ((rows (window-line-slices window line)))
                               (car (list-ref rows
                                              (rows-row-of-column rows column)))))))
        (when (and line-string
                   (>= screen-row 0) (< screen-row vheight))
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
                                 (- width 1)))))))))

    (define (window-top-line-position ed top-line)
      ;; The absolute buffer position of the first character of
      ;; TOP-LINE, the window's top row. GNU Emacs's redisplay walks
      ;; rows with absolute buffer positions; here they are anchored at
      ;; the line point is on - the engine answers that line's start for
      ;; free (`text-editor-get-start-of-line'), and the window is
      ;; scrolled at most a screenful from point (`scroll-to-cursor!').
      ;; The line sizes walked are the same `text-line-outer-size' the
      ;; row walk itself accumulates, so the two agree exactly.
      ;;--------------------------------------------------------------
      (let* ((cursor-line (text-editor-cursor-line ed))
             (anchor (text-editor-get-start-of-line ed)))
        (if (<= top-line cursor-line)
            ;; window is scrolled down from point: walk back to TOP-LINE
            (let loop ((line cursor-line) (pos anchor))
              (if (= line top-line)
                  pos
                  (loop (- line 1)
                        (- pos (or (line-outer-size ed (- line 1)) 0)))))
            ;; window scrolled above point: walk forward from it
            (let loop ((line cursor-line) (pos anchor))
              (if (= line top-line)
                  pos
                  (loop (+ line 1)
                        (+ pos (or (line-outer-size ed line) 0))))))))

    (define (render-window-rows! window ed width x0 vheight highlight)
      ;; Draw WINDOW's rows of text: the buffer lines from its top line
      ;; down, each taking as many screen rows as it lays out.
      ;;
      ;; The rows are not buffer lines. A line that wraps takes several,
      ;; so the walk is over the rows a line makes and the buffer line
      ;; only advances once they are used up - `display_line' in
      ;; `xdisp.c', which produces one row per call and calls itself for
      ;; the rest of the line. ROW is the screen row within the window,
      ;; LINE-START the buffer position the line begins at, which is what
      ;; lets a search match be found in buffer terms and drawn in screen
      ;; terms.
      ;;--------------------------------------------------------------
      (let loop ((row 0)
                 (line-index (window-top-line window))
                 (line-start (window-top-line-position
                              ed (window-top-line window))))
        (when (< row vheight)
          (let* ((line-string (buffer-line-string ed line-index))
                 ;; The line's `display' texts, from the buffer position
                 ;; the walk already has - so the two do not disagree.
                 (texts (and line-string
                             (line-display-texts ed line-start line-string)))
                 (slices (if texts
                             (%window-line-slices window texts)
                             '())))
            ;; No slices means there is no such line - the walk has run
            ;; past the end of the buffer, and there is nothing below to
            ;; draw.
            (when (pair? slices)
              (render-line-rows! window ed width x0 vheight highlight
                                 row line-start line-string texts slices)
              (loop (+ row (length slices))
                    (+ line-index 1)
                    (+ line-start (or (line-outer-size ed line-index) 0))))))))

    (define (render-line-rows! window ed width x0 vheight highlight
                               row line-start line-string texts slices)
      ;; One buffer line's screen rows, from ROW down.
      ;;--------------------------------------------------------------
      (let* ((hscrolled? (and (not (window-wraps? window))
                              (> (%window-hscroll window) 0)))
             (line-width (line-texts-width texts))
             ;; a row of an hscrolled line: the right truncation glyph is
             ;; drawn when the line's display width runs past
             ;; `last_visible_x' = hscroll + width - 1, which is what
             ;; `cursor_row->truncated_on_right_p' records
             (hscroll-truncated?
              (and hscrolled?
                   (> line-width
                      (+ (%window-hscroll window) width -1))))
             (truncated? (and (not (window-wraps? window))
                              (> line-width width))))
        (let rows-loop ((rest slices) (k 0))
          (when (and (pair? rest) (< (+ row k) vheight))
            (let* ((slice (car rest))
                   (more? (pair? (cdr rest)))
                   (slice-start (+ line-start (car slice)))
                   (slice-string (substring line-string (car slice) (cdr slice)))
                   (screen-row (+ row k (window-top window))))
              (if hscrolled?
                  ;; the row is `$' in its first cell - the left
                  ;; truncation glyph, which overwrites the character at
                  ;; the hscroll column rather than pushing the text
                  ;; right - then the visible characters from the second
                  ;; cell, and the right `$' in the last cell when the
                  ;; line runs past the view. `draw-line!' is handed the
                  ;; row minus its marker cells: text from X0+1 across
                  ;; WIDTH-1 columns, so its own right marker lands on
                  ;; the row's last column.
                  (let ((row-width (- width 1)))
                    ;; the left truncation glyph, in the row's FIRST cell
                    ;; - `draw-special-glyph!' is the last cell's glyph,
                    ;; so this writes its own
                    (write-glyphs! (current-display)
                                   "$" screen-row x0
                                   (face->attribute 'default))
                    (draw-line! ed slice-start line-string texts slice
                                screen-row (+ x0 1) row-width
                                #f hscroll-truncated?)
                    (when highlight
                      (highlight-matches window (+ row k) slice-string
                                         slice-start row-width
                                         (car highlight) (cdr highlight)
                                         1 texts (car slice))))
                  (begin
                    (draw-line! ed slice-start line-string texts slice
                                screen-row x0 width more?
                                (and truncated? (not more?)))
                    ;; the characters the current search matched, drawn
                    ;; over the row: the match point is in reverse video
                    ;; (GNU Emacs's `isearch' face) and the other matches
                    ;; in view in bold (`lazy-highlight')
                    (when highlight
                      (highlight-matches window (+ row k) slice-string
                                         slice-start width
                                         (car highlight) (cdr highlight)
                                         0 texts (car slice)))))
              (rows-loop (cdr rest) (+ k 1)))))))

    (define (render-window! window)
      ;; Draw one window: its rows of text within its rectangle, then its
      ;; mode line along its last row. The display is told a window
      ;; update is beginning and ending, the bookends Emacs's
      ;; `update_window_begin_hook' and `update_window_end_hook' give
      ;; its graphics backends.
      ;;--------------------------------------------------------------
      (update-window-begin! (current-display))
      (let* ((ed (window-buffer window))
             (width (window-body-width window))
             (x0 (window-left window))
             (vheight (window-body-height window))
             (border (and (window-right-border? window) (+ x0 width)))
             (highlight (*search-highlight*)))
        (render-window-rows! window ed width x0 vheight highlight)
        ;; the mode line, on the window's last row. The face is Emacs's
        ;; `mode-line' for the selected window and `mode-line-inactive'
        ;; for the others - and on a terminal `mode-line' is
        ;; `:inverse-video t', which is what this used to hardcode.
        (write-glyphs! (current-display)
                       (pad-line (truncate-line (mode-line-string window)
                                                width)
                                 width)
                       (+ (window-top window) (window-height window) -1)
                       x0
                       (face->attribute (if (eq? window (selected-window))
                                            'mode-line
                                            'mode-line-inactive)))
        ;; the vertical border between this window and the one to its
        ;; right: GNU Emacs draws it down every row of the windows,
        ;; their mode lines included
        (when border
          (let loop ((row (window-top window))
                     (end (+ (window-top window) (window-height window))))
            (when (< row end)
              (write-glyphs! (current-display) "|" row border #f)
              (loop (+ 1 row) end)))))
      (update-window-end! (current-display)))

    (define (render! frame)
      ;; Draw every window, then the echo area, then place the terminal
      ;; cursor at the selected window's point. Each window has its own
      ;; mode line, as GNU Emacs gives each window one; the echo area
      ;; belongs to the frame and is drawn last, over the bottom row.
      ;;--------------------------------------------------------------
      (sync-frame-size! frame)
      (let ((width (frame-width frame))
            (height (frame-height frame))
            ;; the *leaves*: a window that holds children shows no buffer
            ;; and has no mode line of its own, so what is drawn is the
            ;; windows at the bottom of the tree
            (windows (window-list frame)))
        (clear-frame-area! (current-display))
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
        (for-each hscroll-window! windows)
        (for-each render-window! windows)
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
                               (- height 1) 0
                               (face->attribute 'minibuffer-prompt)))
              (write-glyphs! (current-display)
                             (truncate-line
                              (string-append (text-editor-to-string reading)
                                             (frame-message frame))
                              (- width pwidth))
                             (- height 1) pwidth #f)))
           (else
            (write-glyphs! (current-display)
                           (truncate-line (frame-message frame) width)
                           (- height 1) 0 #f))))
        ;; Place the terminal cursor: in the minibuffer while one is
        ;; active (Emacs's `cursor-in-echo-area'), else at the selected
        ;; window's point - the only window whose cursor is drawn, there
        ;; being one cursor on a terminal.
        (let ((reading (*echo-area-buffer*)))
          (if reading
              ;; At point in the input, where Emacs's `cursor-in-echo-area'
              ;; leaves it: a message is shown after the input, and it must
              ;; not drag the cursor along with it - a long one (the
              ;; completion candidates, say) would pin the cursor to the
              ;; right edge of the screen whatever point did.
              (let ((cursor (get-window-cursor-type
                             (frame-selected-window frame))))
                (draw-window-cursor! (current-display)
                                     (- height 1)
                                     (min (+ (line-display-width
                                              (or (*echo-area-prompt*) ""))
                                             (current-line-display-column
                                              reading
                                              (text-editor-cursor-column reading)))
                                          (- width 1))
                                     (cursor-cells reading)
                                     (car cursor)
                                     (cadr cursor)
                                     (car (cursor-glyph reading))
                                     (cdr (cursor-glyph reading))))
              (let ((selected (frame-selected-window frame)))
                (when selected
                  (let ((at (cursor-screen-position selected)))
                    (when at
                      (let* ((buffer (window-buffer selected))
                             (cursor (get-window-cursor-type selected))
                             (glyph (cursor-glyph buffer)))
                        (draw-window-cursor! (current-display)
                                             (car at) (cdr at)
                                             (cursor-cells buffer)
                                             (car cursor) (cadr cursor)
                                             (car glyph) (cdr glyph)))))))))
        ;; The screen is what was drawn: the display's flush, which for
        ;; this terminal honours the full-repaint `clear-frame-area!'
        ;; asked for (partial-update optimizations desync the physical
        ;; terminal when lines merge).
        (flush-display! (current-display))
        ))

    ))
