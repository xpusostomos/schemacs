(define-library (schemacs editor disp-table)
  ;; This library mirrors GNU Emacs's `disp-table.el` - the table that
  ;; says how a character is *drawn* as against how it is stored.
  ;;
  ;; GNU Emacs renders a control character in the buffer as its caret
  ;; notation: the carriage return (a single character) is drawn as the
  ;; two-cell glyph ^M, and point takes one keystroke to cross it. Tabs
  ;; are drawn as whitespace up to the next tab stop. This layer converts
  ;; buffer characters to screen glyphs and maps buffer columns to screen
  ;; columns, so that the renderer above it only ever deals in cells.
  ;;
  ;; A glyph is not always one cell wide, and that is the thing this
  ;; library exists to get right. A tab is several cells; a caret notation
  ;; is two; and a CJK ideograph is *one character* and *two cells*. So a
  ;; display string's length is not its width, and anything that walks a
  ;; line counting characters to find a screen column is wrong as soon as
  ;; the line holds a wide character. `char-display-width' is the width;
  ;; `line-display-offsets' and `expand-line-glyphs' are the two ways the
  ;; renderer walks a line without confusing the two. Emacs keeps the same
  ;; two facts apart in `struct glyph', which carries a display string and
  ;; a `pixel_width' and does not assume they agree.
  ;;
  ;; `*tab-width*' is `character.sld''s - defined there rather than here
  ;; because `char-width' of a tab is `tab-width', and that library cannot
  ;; import this one.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `DISPLAY' is not in `(scheme base)'; forgetting it reports as an
    ;; unbound variable at run time, when the renderer first draws a
    ;; line - the same trap as a missing `(scheme case-lambda)' (see
    ;; ENGINE-FINDINGS.txt), and one that the unit tests do not catch
    ;; because they never render.
    (only (scheme write) display)
    (only (schemacs editor engine)
          text-editor-line-editor-ref)
    ;; `char-width' is `character.c''s, and `*tab-width*' is defined there
    ;; too because `CHARACTER_WIDTH' reads it - see the note above.
    (only (schemacs editor character) *tab-width* char-width))

  (export
   *tab-width*
   char-display-cursor-width
   char-display-glyph
   char-display-width
   current-line-display-column
   expand-line-display
   expand-line-glyphs
   line-display-offsets
   )

  (begin

    (define (char-display-glyph c col)
      ;; The display string for the buffer character C drawn at screen
      ;; column COL. This is *what is written*; how many cells it takes
      ;; up is `char-display-width', and the two differ for a wide
      ;; character, whose glyph is one character and two cells.
      ;;--------------------------------------------------------------
      (cond
       ((char=? c #\tab)
        (make-string
         (- (*tab-width*) (modulo col (*tab-width*)))
         #\space))
       ((and (char<? c #\space))
        (string #\^ (integer->char (+ 64 (char->integer c)))))
       ((= (char->integer c) 127)
        "^?")
       (else (string c))))

    (define (char-display-width c col)
      ;; How many screen cells C occupies drawn at column COL.
      ;;
      ;; For the characters `char-display-glyph' substitutes - a tab, a
      ;; caret notation - the glyph's *length* is its width: the spaces a
      ;; tab expands to, and the two characters of `^M'. For a character
      ;; drawn as itself it is `char-width', which is where a wide
      ;; character is wider than it is long.
      ;;
      ;; If `char-display-glyph' ever substitutes for another character,
      ;; this has to be told about it - the two conds must agree.
      ;;--------------------------------------------------------------
      (let ((ci (char->integer c)))
        (if (or (char=? c #\tab) (< ci #x20) (= ci 127))
            (string-length (char-display-glyph c col))
            (char-width c))))

    (define (char-display-cursor-width c col)
      ;; How many cells a cursor drawn over C at column COL takes up: the
      ;; width of C's *first* glyph.
      ;;
      ;; Emacs draws the cursor on the glyph at point, so a wide
      ;; character - one glyph, two cells - gets a two-cell cursor, while
      ;; a tab or a caret notation, which are several one-cell glyphs,
      ;; gets a one-cell one. `char-display-width' is the wrong answer
      ;; here: that is the width of the whole substitution. A zero-width
      ;; character, which has no glyph of its own, is given one cell so
      ;; that the cursor is always visible.
      ;;--------------------------------------------------------------
      (let ((ci (char->integer c)))
        (if (or (char=? c #\tab) (< ci #x20) (= ci 127))
            1
            (max 1 (char-width c)))))

    (define (expand-line-display str width)
      ;; Expand a whole line string into its display form (caret
      ;; notation for control characters, tabs to tab stops) up to WIDTH
      ;; screen cells: the concatenation of the line's glyphs. The glyph
      ;; that crosses WIDTH is still written whole, as it always was; the
      ;; renderer clips what it draws, and clipping by *column* is now
      ;; its business rather than a `string-length' in here.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i 0) (col 0))
            (when (and (< i (string-length str)) (< col width))
              (let ((ch (string-ref str i)))
                (display (char-display-glyph ch col) port)
                (loop (+ i 1) (+ col (char-display-width ch col))))))
          (get-output-string port))))

    (define (expand-line-glyphs str)
      ;; STR as a list of its glyph strings, one per buffer character, in
      ;; order. `expand-line-display' is the concatenation of this; the
      ;; renderer wants it apart from that, because a *run* of characters
      ;; sharing a face is drawn as a slice of this list, and only the
      ;; character count indexes that slice. Slicing the concatenation
      ;; would mean indexing a string by a screen column, which is wrong
      ;; the moment a glyph is not one cell wide.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0) (acc '()))
        (if (>= i (string-length str))
            (reverse acc)
            (let ((ch (string-ref str i)))
              (loop (+ i 1)
                    (+ col (char-display-width ch col))
                    (cons (char-display-glyph ch col) acc))))))

    (define (line-display-offsets str)
      ;; Where each buffer column of STR is drawn, as a list of
      ;; LENGTH+1 screen columns - the last being the line's own display
      ;; width. `current-line-display-column' answers the same thing for
      ;; one column at a time; a line drawn in *runs* needs all of them at
      ;; once, because a run has to be cut in screen cells rather than in
      ;; buffer characters (a tab before the run has already moved the
      ;; text along).
      ;;--------------------------------------------------------------
      (let loop ((i 0) (col 0) (acc '()))
        (cond
         ((>= i (string-length str)) (reverse (cons col acc)))
         (else
          (let ((ch (string-ref str i)))
            (loop (+ 1 i)
                  (+ col (char-display-width ch col))
                  (cons col acc)))))))

    (define (current-line-display-column ed buffer-col)
      ;; The screen column at which buffer column BUFFER-COL of the
      ;; current line is drawn.
      ;;--------------------------------------------------------------
      (let loop ((j 0) (col 0))
        (if (>= j buffer-col)
            col
            (let ((ch (text-editor-line-editor-ref ed j)))
              (loop (+ 1 j)
                    (+ col (char-display-width ch col)))))))

    ))
