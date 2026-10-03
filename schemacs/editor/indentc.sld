(define-library (schemacs editor indentc)
  ;; This library mirrors GNU Emacs's `indent.c': the indentation
  ;; primitives. The name is `indentc' and not `indent' because Emacs has
  ;; *both* `src/indent.c' and `lisp/indent.el', which would want the same
  ;; file name here; the elisp half keeps the plain one, as
  ;; `dired.sld' keeps it against `diredc.sld'.
  ;;
  ;; What is here so far is what `set-fill-column' and `indent-rigidly'
  ;; between them need - `current-column', which is the screen column
  ;; point sits in: the number of *display* cells from the line's left edge, a
  ;; tab or a wide character taking more than one, which is what makes
  ;; it not the character count. `current_column' is the C's, and the
  ;; display widths are `(schemacs editor disp-table)''s - the same
  ;; machinery the mode line's `%c' reads.
  ;;
  ;; The rest of indent.c - `move-to-column', the tab-stops, the
  ;; indent-line functions - is not ported yet.

  (import
    (scheme base)
    (only (schemacs editor engine) text-editor-cursor-column)
    (only (schemacs editor buffer) buffer-tab-width current-buffer)
    (only (schemacs editor editfns)
          forward-line insert-char point save-excursion)
    (only (schemacs editor syntax) skip-chars-forward)
    (only (schemacs editor disp-table) current-line-display-column)
    )

  (export
   *indent-tabs-mode*
   current-column
   current-indentation
   indent-to
   )

  (begin

    (define *indent-tabs-mode* (make-parameter #f))
    ;; ^ GNU Emacs's `indent-tabs-mode', which the C defines here in
    ;; `indent.c:2579' as a `DEFVAR_BOOL': "Indentation can insert tabs
    ;; if this is non-nil."

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

    (define (current-column)
      ;; GNU Emacs's `current-column' (indent.c:315): "Return the
      ;; horizontal position of point. Beginning of line is column 0."
      ;; The engine's cursor is a character index; the column is that
      ;; character's *display* column on its line, which
      ;; `current-line-display-column' walks the line's glyphs for.
      ;;--------------------------------------------------------------
      ;; `text-editor-cursor-column' and not the cursor's whole-buffer
      ;; index: the walk is over the *line's* characters, so what it wants
      ;; is how far into that line point is. Given the index instead it
      ;; reads past the end of any line but the first - measured: the
      ;; second line of a two-line buffer answers
      ;; "char->integer ... (expecting character): #f".
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (current-line-display-column ed (text-editor-cursor-column ed))))
    ))