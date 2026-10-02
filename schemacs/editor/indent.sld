(define-library (schemacs editor indent)
  ;; This library mirrors GNU Emacs's `indent.c': the indentation
  ;; primitives. What is here so far is the one `set-fill-column'
  ;; needs - `current-column' - which is the screen column point sits
  ;; in: the number of *display* cells from the line's left edge, a
  ;; tab or a wide character taking more than one, which is what makes
  ;; it not the character count. `current_column' is the C's, and the
  ;; display widths are `(schemacs editor disp-table)''s - the same
  ;; machinery the mode line's `%c' reads.
  ;;
  ;; The rest of indent.c - `move-to-column', the tab-stops, the
  ;; indent-line functions - is not ported yet.

  (import
    (scheme base)
    (only (schemacs editor engine) text-editor-get-cursor)
    (only (schemacs editor buffer) current-buffer)
    (only (schemacs editor disp-table) current-line-display-column)
    )

  (export
   current-column
   )

  (begin

    (define (current-column)
      ;; GNU Emacs's `current-column' (indent.c:315): "Return the
      ;; horizontal position of point. Beginning of line is column 0."
      ;; The engine's cursor is a character index; the column is that
      ;; character's *display* column on its line, which
      ;; `current-line-display-column' walks the line's glyphs for.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (current-line-display-column
         ed (text-editor-get-cursor ed))))
    ))