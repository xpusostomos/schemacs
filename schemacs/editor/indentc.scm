(define-library (schemacs editor indentc)
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
    (scheme base)
    (only (schemacs editor character) char-width)
    (only (schemacs editor engine)
          text-editor-get-cursor text-editor-get-start-of-line
          text-editor-point-max text-editor-ref)
    (only (schemacs editor buffer) buffer-tab-width current-buffer)
    (only (schemacs editor editfns)
          delete-region forward-line goto-char insert-char point
          save-excursion)
    (only (schemacs editor textprop)
          get-text-property next-single-property-change)
    (only (schemacs editor syntax) skip-chars-forward)
    (only (schemacs editor disp-table) display-text-width)
    )

  (export
   *indent-tabs-mode*
   current-column
   current-indentation
   current-line-display-column
   indent-to
   move-to-column
   scan-for-column
   )

  (begin

    (define *indent-tabs-mode* (make-parameter #t))
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
        (and (string? prop) (display-text-width prop 0))))

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
             (end (or endpos (text-editor-get-cursor ed)))
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
                          (let ((c (text-editor-ref ed scan)))
                            (if (not c)
                                (values scan col prev-pos prev-col)
                                (loop (+ scan 1)
                                      (%column-width c col tab-width)
                                      scan col)))))
                    (let ((c (text-editor-ref ed scan)))
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
            (lambda () (scan-for-column ed (text-editor-point-max ed) column))
          (lambda (pos col prev-pos prev-col)
            (goto-char pos)
            ;; "If a tab char made us overshoot, change it to spaces and
            ;; scan through it again."
            (when (and force (> col column))
              (let ((c (text-editor-ref ed prev-pos)))
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

    ))
