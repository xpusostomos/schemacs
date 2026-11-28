(define-library (schemacs indentc)
  ;; This library mirrors GNU Emacs's `indent.c': the indentation
  ;; primitives. The name is `indentc' and not `indent' because Emacs has
  ;; *both* `src/indent.c' and `lisp/indent.el', which would want the same
  ;; file name here; the elisp half keeps the plain one, as `dired.sld'
  ;; keeps it against `diredc.sld'.
  ;;
  ;; What is here is the column arithmetic: `scan-for-column', which is the
  ;; one walk that answers "where on the screen is this buffer position",
  ;; and the three things built on it -
  ;;
  ;;   `current-column'            `current_column' / `current_column_1'
  ;;   `move-to-column'            `Fmove_to_column'
  ;;   `current-line-display-column'   this renderer's own name for the
  ;;                               same answer at an arbitrary column
  ;;
  ;; `current_column_1' (`indent.c:856') is literally one call to
  ;; `scan_for_column', and `current-line-display-column' is the same call
  ;; with an explicit end. There is one walk in Emacs and there is one
  ;; here; until 2026-10-06 there were two, and the copy had drifted.
  ;;
  ;; The rest of indent.c - the tab-stop list, `indent-line-to',
  ;; `compute-motion', `position-indentation', and the `indent-rigidly'
  ;; machinery - is not ported.

  (import
    ;; `define-custom' - the C variables `cus-start.el' makes
    ;; customizable (see the declaration below).
    (only (schemacs custom) define-custom)
    (scheme base)
    (only (schemacs character) char-width)
    
    (only (schemacs buffer) buffer-tab-width current-buffer
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char buffer-pt buffer-z
          ;; The line layout below reads the buffer's own
          ;; `truncate-lines' and `word-wrap', and moves point when
          ;; `vertical-motion' has walked.
          buffer-beg buffer-truncate-lines buffer-word-wrap set-point
          buffer-local-value)
    (only (schemacs editfns)
          delete-region forward-line goto-char insert-char point
          save-excursion
          text-editor-get-start-of-line text-editor-get-end-of-line)
    ;; The window and frame accessors the row layout measures with:
    ;; `xdisp.c`'s `init_iterator' reads the same fields.
    (only (schemacs frame)
          %window-hscroll %window-start frame-width selected-window
          window-body-width window-buffer window-frame window-width
          window-box-width
          window-left-fringe-width window-right-fringe-width
          ;; `window-start` answers the redisplay's marker (`w->start`).
          ;; It was defined in this library until the window-state pass;
          ;; `w->start` is `window.c`'s and it is in `frame.scm` now.
          window-start)
    ;; The character's on-screen width and the `display' string's, which
    ;; are what a row is measured in.
    (only (schemacs disp-table)
          char-display-glyph char-display-width display-text-width)
    ;; `%count-lines' is `xdisp.c:29903`'s and is `fns.c`'s here; the row
    ;; walk uses it for the `%l` cache's arithmetic.
    (only (schemacs fns) %count-lines)
    (only (schemacs textprop)
          get-text-property get-char-property text-prop-means-invisible
          next-single-property-change)
    (only (schemacs syntax) skip-chars-forward)
    (only (schemacs character) string-width)
    )

  (export
   *indent-tabs-mode*
   current-column
   current-indentation
   current-line-display-column
   indent-to
   move-to-column
   scan-for-column
   ;; The line layout, which `xdisp.c` owns in Emacs and which lives here
   ;; because `vertical-motion` is `indent.c`'s and `next-line` is below
   ;; `xdisp`. Moved 2026-11-07; `xdisp.scm` imports it back and re-exports
   ;; the names its own callers use.
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
   vertical-motion line-next-start window-start
   ;; The horizontal unit, bound by the display layer around a line's
   ;; layout: the advance of one column in the display's own units
   ;; (`face-text-width`), and one cell's width there.
   *line-text-measure* *line-unit-width*
   *line-measure-function* *line-unit-width-function*
   *line-reserve-width* *line-reserve-width-function*
   %call-with-line-measure
   )

  (begin

    (define *line-text-measure* (make-parameter #f))
    ;; ^ `(lambda (i col) width)`, in the display's own horizontal units
    ;; - pixels on a window system, character cells on a terminal - or #f
    ;; for the cell rule. Bound by the display layer around one line's
    ;; layout: a column's width is its glyph's advance in its *face's*
    ;; font, which is what `plans/PER-FACE-FONTS.md`'s stage 4 needs and
    ;; what `texts-width` cannot ask for by itself (the face lives above
    ;; this library).
    (define *line-unit-width* (make-parameter 1))
    ;; ^ One character cell in the same units: 9 on this Gtk display, 1
    ;; on a terminal. The row's right edge and its truncation marker are
    ;; one cell wide whatever the faces on the row are.

    (define *line-measure-function* (make-parameter #f))
    ;; ^ `(lambda (ed line-start texts) measure-or-#f)`, installed by
    ;; the display layer (`xdisp.scm`). It is the seam that lets the
    ;; layout measure with `face-text-width' without importing the face
    ;; machinery: Emacs's `init_iterator' knows the faces because it is
    ;; the redisplay.
    (define *line-unit-width-function* (make-parameter #f))
    ;; ^ `(lambda (window) units-per-cell)`, installed with it.

    (define *line-reserve-width* (make-parameter #f))
    ;; ^ The units a right/left edge marker (`$` or `\`) takes when there
    ;; is no fringe to draw it: `init_iterator`'s
    ;; `it->continuation_pixel_width` (`xdisp.c:3509`). One frame cell
    ;; only when the default face is the frame's font; a text-scaled
    ;; buffer's marker is as wide as its face.
    (define *line-reserve-width-function* (make-parameter #f))
    ;; ^ `(lambda (window) units)`, installed by `xdisp.scm`: the advance
    ;; of the default face's `\` in WINDOW's buffer. `#f` falls back to
    ;; the character cell.

    (define (%call-with-line-measure window ed line-start texts thunk)
      ;; Run THUNK with the line's per-column measurement bound, when the
      ;; display layer has installed one. LINE-START #f - the line-number
      ;; entry points - leaves the cell rule in place.
      ;;
      ;; ED is the buffer TEXTS came from, which is not always the
      ;; window's: `vertical-motion` measures the *current* buffer with
      ;; the window only for geometry, and `tab-line-auto-hscroll` is the
      ;; caller that does. The measure builds its face runs against ED,
      ;; and a run walk over the window's buffer read "Args out of range"
      ;; where the scratch buffer's line was longer.
      (let ((factory (*line-measure-function*))
            (unit-of (*line-unit-width-function*))
            (reserve-of (*line-reserve-width-function*)))
        (if (and factory line-start)
            (let* ((unit (if unit-of (unit-of window) 1))
                   (reserve (and reserve-of (reserve-of window))))
              (parameterize ((*line-text-measure*
                              (factory window ed line-start texts))
                             (*line-unit-width* unit)
                             (*line-reserve-width* (or reserve unit)))
                (thunk)))
            (thunk))))

    (define-custom *indent-tabs-mode* #t
      "Indentation can insert tabs if this is non-nil."
      :type 'boolean
      :group 'indent)
    ;; ^ GNU Emacs's `indent-tabs-mode', which the C defines here in
    ;; `indent.c:2579' as a `DEFVAR_BOOL': "Indentation can insert tabs
    ;; if this is non-nil." It is `t` there - `emacs -Q --batch` answers
    ;; `t` - and it was `#f` here until 2026-10-06, which made
    ;; `move-to-column`'s FORCE branch fill with spaces where Emacs fills
    ;; with a tab. The one consumer that wants it off binds it itself, as
    ;; Emacs's does: `dired-insert-directory` (`dired.el:1923', and
    ;; `dired.sld:719` here).

    (define (%column-width c col tab-width)
      ;; The column the character C ends at when it starts at column COL -
      ;; the C's per-character tail (`indent.c:800-833') for a buffer whose
      ;; characters are multibyte and whose `ctl-arrow' is on, which is
      ;; every buffer here:
      ;;
      ;;   a tab      to the next multiple of `tab-width'
      ;;   a control character, DEL included,   2 - the width of its
      ;;              caret notation, ^M or ^?
      ;;   anything else    `CHARACTER_WIDTH' (`buffer.h'), which is
      ;;              `char-width' - 1 for ASCII, 2 for a wide character,
      ;;              the table's answer above #x7F
      ;;
      ;; The C reaches the first two through `MULTIBYTE_BYTES_WIDTH' and
      ;; then `CHARACTER_WIDTH'; the 4-column branch beside them
      ;; (`indent.c:829') is the *unibyte* octal escape, `\015' rather
      ;; than `^M', and is not reachable here.
      ;;--------------------------------------------------------------
      (let ((ci (char->integer c)))
        (cond
         ((char=? c #\tab)
          (* tab-width (quotient (+ col tab-width) tab-width)))
         ((or (< ci #x20) (= ci #x7f)) (+ col 2))
         (else (+ col (char-width c))))))

    (define (%display-property-width ed pos)
      ;; `check_display_width' (`indent.c:474') for the case this tree can
      ;; reach: a `display' text property whose value is a string. The
      ;; width is measured from column 0 and *not* from the column the
      ;; property sits at, because that is what the C asks for - it calls
      ;; `Fstring_width (val, Qnil, Qnil)' (`indent.c:567'), and
      ;; `(string-width "\tY")' is 9 whatever column it stands at.
      ;; Measured: a display string "\tY" reached at column 3 makes the
      ;; next position column 12, not 9.
      ;;
      ;; Answers #f for "no width to add", which is the C's -1: no
      ;; property here, or a value that is not a string. The C's other
      ;; two value shapes - `(space ...)' specs and images - are not
      ;; produced anywhere in this tree, so they are not carried.
      ;;--------------------------------------------------------------
      (let ((prop (get-text-property pos 'display ed)))
        ;; `check_display_width' (`indent.c:567') measures the
        ;; property's string with `Fstring_width (val, Qnil, Qnil)' -
        ;; `string-width' with no FROM or TO.
        (and (string? prop) (string-width prop))))

    (define (scan-for-column ed endpos goalcol)
      ;; GNU Emacs's `scan_for_column' (`indent.c:607'): "Scanning from
      ;; the beginning of the current line, stop at the buffer position
      ;; ENDPOS or at the column GOALCOL or at the end of line, whichever
      ;; comes first.  Return the resulting buffer position and column in
      ;; ENDPOS and GOALCOL.  PREVCOL gets set to the column of the
      ;; previous position (it's always strictly smaller than the goal
      ;; column), and PREVPOS ... to the corresponding buffer character
      ;; position."
      ;;
      ;; The C writes five answers through pointers, two of them byte
      ;; positions this tree has none of, so what is answered here is four
      ;; values in the C's order: the position and column at the stop,
      ;; then the position and column one character before it. ENDPOS and
      ;; GOALCOL are #f for "absent", which is the C's NULL - no end means
      ;; point, and no goal means no upper bound.
      ;;
      ;; Not carried, with what each would need:
      ;;
      ;;   - `skip_invisible' (`indent.c:636'), which steps over text the
      ;;     `invisible' property hides. There is no invisibility here.
      ;;   - the display table's char vectors (`DISP_CHAR_VECTOR',
      ;;     `indent.c:756'): this tree has no `buffer-display-table', so
      ;;     a character has no glyph vector to be measured by.
      ;;   - compositions (`struct composition_it', `indent.c:697').
      ;;   - the long-line shortcut (`indent.c:632'), which assumes one
      ;;     column per character for a buffer with very long, truncated
      ;;     lines. It is an approximation Emacs takes to avoid being
      ;;     quadratic; this redisplay is already flat in buffer position
      ;;     since the 2026-10-05 window-start work, so there is nothing
      ;;     for it to rescue.
      ;;   - `ctl_arrow' (`indent.c:609'), a buffer-local that is on by
      ;;     default and that `disp-table.sld' always agrees with: it
      ;;     always draws caret notation, so the 2-column branch is the
      ;;     one taken.
      ;;   - the multibyte branch: every character here is one code point
      ;;     with one width.
      ;;--------------------------------------------------------------
      (let* ((tab-width (buffer-tab-width ed))
             (goal (or goalcol +inf.0))
             (end (or endpos (buffer-pt ed)))
             ;; "Start the scan at the beginning of this line with column
             ;; number 0" - the C's backward `find_newline (..., -1, ...)'
             ;; is the line's start.
             (bol (text-editor-get-start-of-line ed)))
        (let loop ((scan bol) (col 0) (prev-pos bol) (prev-col 0))
          (if (or (>= scan end) (>= col goal))
              (values scan col prev-pos prev-col)
              (let ((width (%display-property-width ed scan)))
                (if width
                    ;; A `display' string stands for the *whole run* of
                    ;; characters carrying it, so its width counts once and
                    ;; the scan jumps to the run's end - the C's `scan =
                    ;; endp; continue'. Without the jump the run's width is
                    ;; added once per character of it, which is what the
                    ;; copy this replaced did.
                    (let ((endp (next-single-property-change scan 'display ed)))
                      (if (and endp (> endp scan))
                          (loop endp (+ col width) scan col)
                          ;; the C's "avoid infinite loops with 0-width
                          ;; overlays": the character is still counted
                          (let ((c (fetch-char ed scan)))
                            (if (not c)
                                (values scan col prev-pos prev-col)
                                (loop (+ scan 1)
                                      (%column-width c col tab-width)
                                      scan col)))))
                    (let ((c (fetch-char ed scan)))
                      (if (or (not c) (char=? c #\newline))
                          ;; a newline ends the line: `goto endloop'
                          (values scan col prev-pos prev-col)
                          (loop (+ scan 1)
                                (%column-width c col tab-width)
                                scan col)))))))))

    (define (current-column)
      ;; GNU Emacs's `current-column' (`indent.c:305'): "Return the
      ;; horizontal position of point.  Beginning of line is column 0."
      ;;
      ;; The C has two answers inside it. Its own body (`indent.c:329')
      ;; scans *backwards* a byte at a time and is taken only when the
      ;; buffer "has no overlays, text properties, or multibyte
      ;; characters"; with any of those it calls `current_column_1'
      ;; (`indent.c:856'), which is one call to `scan_for_column' with no
      ;; goal and point as the end. Every buffer here is multibyte by
      ;; construction and carries text properties as soon as anything is
      ;; fontified, so it is always the second that answers.
      ;;
      ;; `last_known_column' and its two companions (`indent.c:43') are
      ;; not ported. That cache is keyed on point and `MODIFF', and
      ;; `invalidate_current_column' (`indent.c:322') is what the C calls
      ;; when the display table or `tab-width' changes - neither of which
      ;; this tree's `MODIFF' counts, so the cache could go stale with
      ;; nothing to catch it. It is a pure optimisation; port it only
      ;; together with those callers.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (scan-for-column (current-buffer) #f #f))
        (lambda (pos col prev-pos prev-col) col)))

    (define (current-line-display-column ed buffer-col)
      ;; The screen column at which buffer column BUFFER-COL of ED's
      ;; current line is drawn.
      ;;
      ;; This is not a C function: it is `scan_for_column' asked for one
      ;; particular answer, and it exists because the redisplay wants the
      ;; column of an arbitrary position on the line rather than of point.
      ;; It was a second, hand-rolled copy of the walk until 2026-10-06,
      ;; and being a copy it had drifted from the original in two ways the
      ;; copy could not show: it added a `display' property's width once
      ;; per character covered instead of once for the run, and measured
      ;; that string from the current column where Emacs measures it from
      ;; zero.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda ()
            (scan-for-column ed
                             (+ (text-editor-get-start-of-line ed) buffer-col)
                             +inf.0))
        (lambda (pos col prev-pos prev-col) col)))

    (define (move-to-column column . rest)
      ;; GNU Emacs's `move-to-column' (`indent.c:1112'): "Move point to
      ;; column COLUMN in the current line.  The column of a character is
      ;; calculated by adding together the widths as displayed of the
      ;; previous characters in the line.  This function ignores
      ;; line-continuation; there is no upper limit on the column number a
      ;; character can have and horizontal scrolling has no effect.  If
      ;; specified column is within a character, point goes after that
      ;; character.  If it's past end of line, point goes to end of line.
      ;;
      ;; Optional second argument FORCE non-nil means if COLUMN is in the
      ;; middle of a tab character, either change it to spaces (when
      ;; `indent-tabs-mode' is nil), or insert enough spaces before it to
      ;; reach COLUMN (otherwise).  In addition, if FORCE is t, and the
      ;; line is too short to reach COLUMN, add spaces/tabs to get there.
      ;; The return value is the current column."
      ;;
      ;; The C is a DEFUN and is M-x only, like this one; the interactive
      ;; spec ("NMove to column: ") is not registered, because nothing
      ;; this tree ports has needed to reach it as a command yet.
      ;;--------------------------------------------------------------
      (let ((force (if (pair? rest) (car rest) #f))
            (ed (current-buffer)))
        (call-with-values
            (lambda () (scan-for-column ed (buffer-z ed) column))
          (lambda (pos col prev-pos prev-col)
            (goto-char pos)
            ;; "If a tab char made us overshoot, change it to spaces and
            ;; scan through it again."
            (when (and force (> col column))
              (let ((c (fetch-char ed prev-pos)))
                (when (and (char? c)
                           (char=? c #\tab)
                           (< prev-col column)
                           (< prev-pos (point)))
                  ;; "Insert spaces in front of the tab to reach GOAL.  Do
                  ;; this first so that a marker at the end of the tab gets
                  ;; adjusted.  Now delete the tab, and indent to COL."
                  (goto-char prev-pos)
                  (insert-char #\space (- column prev-col))
                  ;; `del_range (PT, PT + 1)' - the tab is the character
                  ;; after point now, and `delete-region' takes Emacs's
                  ;; one-based positions like everything else at this
                  ;; layer.
                  (delete-region (point) (+ (point) 1))
                  (let ((goal-pt (point)))
                    (indent-to col #f)
                    (goto-char goal-pt))
                  (set! col column))))
            ;; "If line ends prematurely, add space to the end." - only
            ;; when FORCE is `t' itself, not merely non-nil.
            (when (and (< col column) (eq? force #t))
              (indent-to column #f)
              (set! col column))
            col))))

    (define (current-indentation)
      ;; GNU Emacs's `current-indentation' (indent.c:997): "Return the
      ;; indentation of the current line. This is the horizontal position
      ;; of the character following any initial whitespace."
      ;;
      ;; The C walks the line's bytes itself (`position_indentation'),
      ;; counting a tab at `tab-width'; asking `current-column' after
      ;; skipping the run answers the same thing, which is what the
      ;; docstring describes - and the skipping is `skip-chars-forward''s,
      ;; which is what the C's walk is. The C's one further rule, that
      ;; "text that has an invisible property is considered as having
      ;; width 0", has nothing to say here: there is no invisibility.
      ;;--------------------------------------------------------------
      (save-excursion
        (forward-line 0)
        (skip-chars-forward " \t")
        (current-column)))

    (define (indent-to column . rest)
      ;; GNU Emacs's `indent-to' (indent.c:947): "Indent from point with
      ;; tabs and spaces until COLUMN is reached. Optional second
      ;; argument MINIMUM says always do at least MINIMUM spaces even if
      ;; that goes past COLUMN; by default, MINIMUM is zero. Whether this
      ;; uses tabs or spaces depends on `indent-tabs-mode'. The return
      ;; value is the column where the insertion ends."
      ;;--------------------------------------------------------------
      (let* ((minimum (if (and (pair? rest) (car rest)) (car rest) 0))
             (fromcol (current-column))
             (mincol (max (+ fromcol minimum) column))
             (tab-width (buffer-tab-width (current-buffer))))
        (if (= fromcol mincol)
            mincol
            (let* ((fromcol (if (*indent-tabs-mode*)
                                (let ((n (- (quotient mincol tab-width)
                                            (quotient fromcol tab-width))))
                                  (if (not (= n 0))
                                      (begin
                                        (insert-char #\tab n)
                                        (* (quotient mincol tab-width) tab-width))
                                      fromcol))
                                fromcol)))
              (insert-char #\space (- mincol fromcol))
              mincol))))


    (define (line-display-texts ed line-start)
      ;; The line beginning at buffer position LINE-START as the vector of
      ;; texts described above, one entry per buffer column. LINE-START is
      ;; an engine position, which is what `get-text-property' takes; the
      ;; overlay layer is not consulted, because the C's
      ;; `handle_display_prop' reads the text property.
      ;;
      ;; **The characters are read at their positions** - `fetch-char' at
      ;; `(+ line-start i)' - where this was handed the whole line as a
      ;; string and indexed it. `init_iterator' (`xdisp.c') finds the
      ;; row's end with `find_newline' and produces a glyph per position;
      ;; building a string of the line first is the shortcut this file is
      ;; shedding, one reader at a time.
      ;;--------------------------------------------------------------
      (let ((line-end (text-editor-get-end-of-line ed line-start)))
        (let loop ((i 0) (acc '()))
          (if (>= (+ line-start i) line-end)
              (list->vector (reverse acc))
              (let* ((pos (+ line-start i))
                     (prop (and ed (get-text-property pos 'display ed)))
                     ;; **`invisible` text is zero columns wide.**
                     ;; `handle_invisible_prop` (`xdisp.c:5206`) runs
                     ;; after `handle_display_prop` (`:1018`), so a
                     ;; `display` string on the character wins; with no
                     ;; replacement the character is not displayed at
                     ;; all (1), or a `"..."` takes its place (2 - a
                     ;; `buffer-invisibility-spec` element whose cdr is
                     ;; non-nil). The ellipsis belongs to the *start* of
                     ;; a run, not to every character in it.
                     (invisible
                      (and ed
                           (text-prop-means-invisible
                            (get-char-property pos 'invisible ed) ed)))
                     (text
                      (cond
                       ((not ed) (fetch-char ed pos))
                       ((string? prop) prop)
                       ((= invisible 1) "")
                       ((= invisible 2)
                        (let ((before (and (> pos (buffer-beg ed))
                                           (not (= 0 (text-prop-means-invisible
                                                      (get-char-property
                                                       (- pos 1) 'invisible ed)
                                                      ed))))))
                          (if before "" "...")))
                       (else (fetch-char ed pos)))))
                (loop (+ i 1) (cons text acc)))))))

    (define (buffer-line-texts-at window line-start . args)
      ;; The texts of the line beginning at buffer position LINE-START in
      ;; WINDOW. This is the form everything in this file uses: a walk
      ;; that is stepping through a window's lines has the position
      ;; already, and asking for the line by *number* instead means
      ;; scanning from the beginning of the buffer for every row.
      ;;--------------------------------------------------------------
      ;; **The buffer is optional and means the current one when it is
      ;; given as such** (`vertical-motion` measures a buffer that the
      ;; window need not be showing - Emacs's `tab-line-auto-hscroll` is
      ;; the caller that does). Default: the window's own.
      (line-display-texts (if (pair? args) (car args) (window-buffer window))
                          line-start))

    (define (buffer-line-texts window line-index)
      ;; The texts of LINE-INDEX's line in WINDOW, or #f when the buffer
      ;; has no such line. For a caller that has a line number and no
      ;; position; it costs a scan of everything above the line, so the
      ;; walks use `buffer-line-texts-at' instead.
      ;;--------------------------------------------------------------
      (let* ((ed (window-buffer window))
             (start (and (<= 1 line-index)
                         (<= line-index (+ 1 (%count-lines ed (buffer-beg ed) (buffer-z ed))))
                         (window-line-start ed line-index))))
        (and start (buffer-line-texts-at window start))))

    (define (window-line-start ed line-index)
      ;; The position line LINE-INDEX begins at, or #f when the buffer has
      ;; no such line - the line-number form of the scan. One scan of
      ;; everything above the line, so it is for callers that have no
      ;; position, not for walks.
      ;;--------------------------------------------------------------
      (let loop ((line (- line-index 1)) (pos (buffer-beg ed)))
        (cond ((<= line 0) pos)
              ((>= pos (buffer-z ed)) #f)
              (else
               (let ((end (text-editor-get-end-of-line ed pos)))
                 (if (< end (buffer-z ed))
                     (loop (- line 1) (+ end 1))
                     #f))))))

    (define (texts-glyph texts i col)
      ;; Buffer column I of TEXTS as the string the redisplay writes for
      ;; it, drawn at screen column COL - `char-display-glyph', or the
      ;; `display' string standing there.
      ;;--------------------------------------------------------------
      (let ((entry (vector-ref texts i)))
        (if (string? entry) entry (char-display-glyph entry col))))

    (define (texts-width texts i col)
      ;; How wide buffer column I of TEXTS is, drawn at screen column
      ;; COL - in *cells* normally, or in the display's own units when
      ;; `*line-text-measure*` is bound (a face's advance in pixels).
      ;; `texts-glyph' is the string that width belongs to: `char-
      ;; display-width', the width of a `display' string, or the face
      ;; font's advance for that string.
      ;;--------------------------------------------------------------
      (let ((measure (*line-text-measure*)))
        (if measure
            (measure i col)
            (let ((entry (vector-ref texts i)))
              (if (string? entry)
                  (display-text-width entry col)
                  (char-display-width entry col))))))

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

    (define (line-texts-slice-width texts from to width)
      ;; How many screen cells the slice [FROM, TO) of TEXTS takes drawn
      ;; cut at WIDTH - `line-texts-width''s walk over a slice, answering
      ;; the column it reached. It is the width of the glyphs a row
      ;; *draws*, so the glyph starting before WIDTH is counted whole and
      ;; this can exceed WIDTH by a wide character's second cell, which is
      ;; what the row itself does.
      ;;
      ;; It is this walk rather than a width taken over the glyphs joined
      ;; into a string, because there is no string: the row is drawn glyph
      ;; by glyph from TEXTS, as GNU Emacs's `display_line' appends to a
      ;; glyph row and reads the width off the iterator - `it->current_x'
      ;; (`xdisp.c'). Joining the glyphs and measuring the result again
      ;; can only disagree with the walk that drew them, it makes the
      ;; widths here disagree with `line-texts-offsets' (which is this
      ;; walk), and it conses a string per row to do it.
      ;;--------------------------------------------------------------
      (let loop ((i from) (col 0))
        (if (or (>= i to) (>= col width))
            col
            (loop (+ i 1) (+ col (texts-width texts i col))))))

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

    (define-custom *truncate-partial-width-windows* 50
      "Non-nil means truncate lines in windows narrower than the frame.\nFor an integer value, truncate lines in each window narrower than the\nfull frame width, provided the total window width in column units is less\nthan that integer; otherwise, respect the value of ‘truncate-lines’.\nThe total width of the window is as returned by ‘window-total-width’, it\nincludes the fringes, the continuation and truncation glyphs, the\ndisplay margins (if any), and the scroll bar\n\nFor any other non-nil value, truncate lines in all windows that do\nnot span the full frame width.\n\nA value of nil means to respect the value of ‘truncate-lines’.\n\nIf ‘word-wrap’ is enabled, you might want to reduce the value of this.\n\nDon’t set this to a non-nil value when ‘visual-line-mode’ is\nturned on, as it could produce confusing results."
      :type '(choice (integer :tag "Truncate if narrower than") (const :tag "Respect `truncate-lines'" #f) (other :tag "Truncate if not full-width" #t))
      :group 'display
      :version "23.1")
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
      ;;
      ;; **The window's own frame**, not the selected one: the C is
      ;;
      ;;   WINDOW_PIXEL_WIDTH (W)
      ;;    == WINDOW_PIXEL_WIDTH (FRAME_ROOT_WINDOW (WINDOW_XFRAME (W)))
      ;;
      ;; (`window.h:701'). It read `(*current-frame*)' while `render!'
      ;; bound that to the frame being drawn, which made the two the same
      ;; thing by accident; with the binding gone they are not, and a
      ;; window in a second frame has to be measured against its own.
      ;;--------------------------------------------------------------
      (let ((frame (window-frame window)))
        (and frame
             (= (window-width window) (frame-width frame)))))

    (define (window-truncates-lines? window . args)
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
      (let ((ptw (buffer-local-value (if (pair? args) (car args)
                                         (window-buffer window))
                                     'truncate-partial-width-windows
                                     (*truncate-partial-width-windows*)))
            (cols (window-width window)))
        (or (not (= (%window-hscroll window) 0))
            (not (and (or (window-full-width? window)
                          (not ptw)
                          (and (exact-integer? ptw) (<= ptw cols)))
                      (not (buffer-truncate-lines
                            (if (pair? args) (car args)
                                (window-buffer window)))))))))

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

    (define (line-texts-rows texts width wrap? word-wrap? . args)
      ;; The screen rows TEXTS is drawn on, each a `(FIRST . LAST)'
      ;; pair of *buffer* columns. One row when the line is truncated or
      ;; short enough; several when it wraps.
      ;;
      ;; **WIDTH is in display units** - pixels on a window system,
      ;; character cells on a terminal - because that is what
      ;; `window_box_width' is and what the per-face measurement
      ;; answers. The optional RESERVE argument is the number of those
      ;; units a right-edge marker needs (`init_iterator`'s
      ;; `it->last_visible_x -= it->continuation_pixel_width`,
      ;; `xdisp.c:3509-3518'): one cell on a terminal, zero when a right
      ;; fringe draws the marker instead. It used to be a boolean
      ;; multiplied by the cell width, which could not express a
      ;; scaled-face marker.
      ;;--------------------------------------------------------------
      (let* ((unit (*line-unit-width*))
             (len (vector-length texts))
             (reserve (if (pair? args)
                          (car args)
                          (or (*line-reserve-width*) unit)))
             (reserve-width (cond ((number? reserve) reserve)
                                  (reserve (or (*line-reserve-width*) unit))
                                  (else 0)))
             (usable (max unit (- width reserve-width))))
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
      (let* ((unit (*line-unit-width*))
             (h (%window-hscroll window))
             ;; `window_box_width' in the display's units, and the
             ;; hscroll in the same units. A *column* count times the
             ;; cell is Emacs's `first_visible_x = w->hscroll *
             ;; FRAME_COLUMN_WIDTH` (`xdisp.c:3501').
             (width-units (window-box-width window))
             ;; `insert_left_trunc_glyphs` is only for a window with no
             ;; left fringe on a window system (`xdisp.c:23908`); with
             ;; one, the truncation is the fringe bitmap and no text cell
             ;; is given up. The right edge keeps its reserve only when
             ;; there is no right fringe (`:3510`).
             (left-reserve (zero? (window-left-fringe-width window)))
             (right-reserve (zero? (window-right-fringe-width window)))
             (left-reserve-width
              (if left-reserve (or (*line-reserve-width*) unit) 0))
             (right-reserve-width
              (if right-reserve (or (*line-reserve-width*) unit) 0))
             (h-units (* h unit))
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
            (loop (+ i 1)
                  (if (>= (vector-ref offsets i)
                          (+ h-units left-reserve-width))
                      i #f)))
           ((>= (vector-ref offsets i)
                (+ h-units (- width-units right-reserve-width)))
            (cons start i))
           (else (loop (+ i 1) start))))))

    (define (window-wraps? window . args)
      ;; Whether WINDOW lays a long line out over several screen rows.
      ;;--------------------------------------------------------------
      (not (apply window-truncates-lines? window args)))

    (define (window-line-rows-at window line-start)
      ;; How many screen rows the line beginning at LINE-START takes in
      ;; WINDOW: one when it is short enough or truncated, more when it
      ;; wraps.
      ;;--------------------------------------------------------------
      (let ((texts (buffer-line-texts-at window line-start)))
        (if texts (%window-line-rows window texts line-start) 1)))

    (define (window-line-rows window line-index)
      ;; `window-line-rows-at' for a caller with a line number and no
      ;; position.
      ;;--------------------------------------------------------------
      (let ((texts (buffer-line-texts window line-index)))
        (if texts
            (%window-line-rows window texts
                               (window-line-start (window-buffer window)
                                                  line-index))
            1)))

    (define (%window-line-rows window texts line-start)
      ;; `window-line-rows' over texts already in hand.
      ;;--------------------------------------------------------------
      (%call-with-line-measure
       window (window-buffer window) line-start texts
       (lambda ()
         (cond ((and (not (window-wraps? window))
                     (> (%window-hscroll window) 0))
                ;; an hscrolled line is one row, whatever its length
                1)
               (else
                (length (line-texts-rows
                         texts
                         (window-box-width window)
                         (window-wraps? window)
                         (buffer-word-wrap (window-buffer window))
                         (if (zero? (window-right-fringe-width window))
                             (or (*line-reserve-width*) (*line-unit-width*))
                             0))))))))

    (define (window-line-slices-at window line-start . args)
      ;; The `(FIRST . LAST)' buffer columns of each screen row the line
      ;; beginning at LINE-START takes in WINDOW - the rows to draw, in
      ;; order.
      ;;--------------------------------------------------------------
      (let ((texts (apply buffer-line-texts-at window line-start args)))
        (if texts
            (apply %window-line-slices window texts line-start args)
            '())))

    (define (window-line-slices window line-index)
      ;; `window-line-slices-at' for a caller with a line number and no
      ;; position.
      ;;--------------------------------------------------------------
      (let ((texts (buffer-line-texts window line-index)))
        (if texts
            (%window-line-slices
             window texts
             (window-line-start (window-buffer window) line-index))
            '())))

    (define (%window-line-slices window texts line-start . args)
      ;; `window-line-slices' over texts already in hand. The row walk
      ;; computes them itself, beside the line's buffer position, so that
      ;; a line with a `display' property is walked for it once.
      ;;--------------------------------------------------------------
      (%call-with-line-measure
       window (if (pair? args) (car args) (window-buffer window))
       line-start texts
       (lambda ()
         (cond ((and (not (window-wraps? window))
                     (> (%window-hscroll window) 0))
                (list (hscroll-line-slice window texts)))
               (else
                (line-texts-rows
                 texts
                 (window-box-width window)
                 (apply window-wraps? window args)
                 (buffer-word-wrap
                  (if (pair? args) (car args)
                      (window-buffer window)))
                 (if (zero? (window-right-fringe-width window))
                     (or (*line-reserve-width*) (*line-unit-width*))
                     0)))))))

    (define (rows-above window line-start)
      ;; How many screen rows the lines between WINDOW's top and the line
      ;; beginning at LINE-START take, not counting that line itself: what
      ;; a screen row has to be offset by when the window's top is a line
      ;; and the rows are not one per line. The walk carries the position
      ;; it is on, so each line it crosses costs that line.
      ;;--------------------------------------------------------------
      (let ((ed (window-buffer window)))
        (let loop ((pos (window-start window)) (used 0))
          (if (>= pos line-start)
              used
              (let ((next (line-next-start ed pos)))
                (if next
                    (loop next (+ used (window-line-rows-at window pos)))
                    used))))))

    (define (rows-row-of-column rows column)
      ;; Which of ROWS (a line's `(FIRST . LAST)' list) buffer column
      ;; COLUMN is drawn on - the row the cursor belongs to.
      ;;--------------------------------------------------------------
      (let loop ((rest rows) (k 0))
        (cond ((null? rest) 0)
              ((< column (cdr (car rest))) k)
              (else (loop (cdr rest) (+ k 1))))))

    (define (%row-of-position window line-start column . args)
      ;; Which screen row of the line beginning at LINE-START the buffer
      ;; column COLUMN is drawn on.
      ;;
      ;; A COLUMN at or past the end of the line is on its *last* row, and
      ;; that is not a corner case to shrug at: `vertical-motion' is asked
      ;; to move from `window-end', which is exactly such a position - the
      ;; far edge of the last row that fits, i.e. the line's own length.
      ;; `rows-row-of-column' answers 0 there, which is where the cursor
      ;; never is at the callers it was written for.
      ;;--------------------------------------------------------------
      (let loop ((rest (apply window-line-slices-at window line-start args))
                 (k 0))
        (cond ((null? rest) (max 0 (- k 1)))
              ((< column (cdr (car rest))) k)
              (else (loop (cdr rest) (+ k 1))))))

    (define (%row-beginning line row-slices k)
      ;; The buffer position of the first character drawn on row K of the
      ;; line at LINE - the position `vertical-motion' leaves point on. A
      ;; line with no rows to speak of (the empty line a final line break
      ;; starts) begins where it begins.
      ;;--------------------------------------------------------------
      (if (or (null? row-slices) (>= k (length row-slices)))
          line
          (+ line (car (list-ref row-slices k)))))

    (define (%row-position-of-column line row-slices k goal window)
      ;; The buffer position on screen row K of LINE nearest display column
      ;; GOAL - what the C's `move_it_vertically' leaves point on when
      ;; `vertical-motion' is handed a column. GOAL is counted from the
      ;; start of the *row*, not of the line: a wrapped row starts at
      ;; screen column zero, which is the same reason `line-texts-rows'
      ;; measures a tab from the row and not the line.
      ;;--------------------------------------------------------------
      (if (or (null? row-slices) (>= k (length row-slices)))
          line
          (let* ((slice (list-ref row-slices k))
                 (from (car slice))
                 (to (cdr slice))
                 (texts (buffer-line-texts-at window line)))
            (let loop ((i from) (col 0))
              (if (>= i to)
                  (+ line i)
                  (let ((w (texts-width texts i col)))
                    (if (> (+ col w) goal)
                        (+ line i)
                        (loop (+ i 1) (+ col w)))))))))

    (define (vertical-motion lines . rest)
      ;; GNU Emacs's `vertical-motion' (`indent.c:2207'): "Move point to
      ;; start of the screen line LINES lines down" - up when LINES is
      ;; negative - and answer "number of screen lines moved over; that
      ;; usually equals LINES, but may be closer to zero if beginning or
      ;; end of buffer was reached."
      ;;
      ;; **LINES may be a cons `(COLS . LINES)'**, as the C's first
      ;; argument may be: `line-move-visual' passes the column it wants
      ;; point on, so that moving down a wrapped line keeps the cursor
      ;; under where it was. COLS is a display column counted from the
      ;; start of the row - what the C measures against `it->current_x'.
      ;;
      ;; WINDOW supplies the width, the wrapping and the horizontal
      ;; scroll, as the C's second argument does. The buffer is the one
      ;; the window shows.
      ;;
      ;; Not carried: the C's third argument `cur-col' (a caller saying
      ;; where on its line it already is, to save the scan), and the
      ;; pixel-level partial scrolls of `move_it_vertically' - a row here
      ;; is a whole row.
      ;;--------------------------------------------------------------
      (let* ((goal (and (pair? lines) (car lines)))
             (lines (if (pair? lines) (cdr lines) lines))
             (window (or (and (pair? rest) (car rest)) (selected-window)))
             ;; **The buffer moved over is the *current* one**, and the
             ;; window is only its geometry - which is what the C does:
             ;; the iterator takes its width, wrapping and hscroll from
             ;; `w` and its characters from `current_buffer`. Reading the
             ;; text from the window's buffer instead is what made
             ;; `tab-line-auto-hscroll` - which measures in a scratch
             ;; buffer no window shows - see the *shown* buffer's lines
             ;; and answer "the tabs wrapped" every time.
             ;; ...and there is never no current buffer in a live editor
             ;; (Emacs has no such state), so the fallback is for a caller
             ;; that holds only a window - a test.
             (ed (or (current-buffer) (window-buffer window)))
             (pt (buffer-pt ed))
             (line-start (text-editor-get-start-of-line ed pt))
             (slices (window-line-slices-at window line-start ed))
             (k (%row-of-position window line-start (- pt line-start) ed))
             (left (abs lines))
             (down? (>= lines 0))
             (answer
              (let loop ((line line-start) (row-slices slices) (k k)
                         (left left) (moved 0))
                (cond
                 ((= left 0)
                  (list (if goal
                            (%row-position-of-column line row-slices k goal window)
                            (%row-beginning line row-slices k))
                        moved))
                 (down?
                  (if (< (+ k 1) (length row-slices))
                      (loop line row-slices (+ k 1) (- left 1) (+ moved 1))
                      (let ((next (line-next-start ed line)))
                        (if next
                            (loop next (window-line-slices-at window next ed)
                                  0 (- left 1) (+ moved 1))
                            ;; the end of the buffer: the C's walk stops
                            ;; at ZV and says how far it got
                            (list (buffer-z ed) moved)))))
                 ((> k 0)
                  (loop line row-slices (- k 1) (- left 1) (+ moved 1)))
                 ((= line (buffer-beg ed))
                  ;; the beginning of the buffer, the other edge
                  (list (buffer-beg ed) moved))
                 (else
                  (let* ((prev (text-editor-get-start-of-line ed (- line 1)))
                         (prev-slices (window-line-slices-at window prev ed)))
                    (loop prev prev-slices
                          (max 0 (- (length prev-slices) 1))
                          (- left 1) (+ moved 1))))))))
        (set-point ed (car answer))
        (if down? (cadr answer) (- (cadr answer)))))


    (define (line-next-start ed line-start)
      ;; Where the line after the one at LINE-START begins, or #f when it
      ;; is the buffer's last line - a line with no break after it starts
      ;; no other line. The empty line a final break does start is at
      ;; `point-max' and begins here like any other.
      ;;--------------------------------------------------------------
      (let ((end (text-editor-get-end-of-line ed line-start)))
        (if (< end (buffer-z ed)) (+ end 1) #f)))

    ))
