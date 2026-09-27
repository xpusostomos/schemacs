(define-library (schemacs editor disp-table)
  ;; This library mirrors GNU Emacs's `disp-table.el` - the table that
  ;; says how a character is *drawn* as against how it is stored - and
  ;; the `tab-width` variable that `buffer.c` defines and `indent.c`
  ;; consults.
  ;;
  ;; GNU Emacs renders a control character in the buffer as its caret
  ;; notation: the carriage return (a single character) is drawn as the
  ;; two-cell glyph ^M, and point takes one keystroke to cross it. Tabs
  ;; are drawn as whitespace up to the next tab stop. This layer converts
  ;; buffer characters to screen glyphs and maps buffer columns to screen
  ;; columns, so that the renderer above it only ever deals in cells.
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
          text-editor-line-editor-ref))

  (export
   *tab-width*
   char-display-glyph
   current-line-display-column
   expand-line-display
   )

  (begin

    (define *tab-width* (make-parameter 8))
    ;; ^ GNU Emacs's `tab-width', which is a buffer-local variable
    ;; defined in `buffer.c' and defaulting to 8. It is a parameter here
    ;; because this project has one value for the buffer being drawn
    ;; rather than a value per buffer.

    (define (char-display-glyph c col)
      ;; The display string for the buffer character C drawn at screen
      ;; column COL, and its width in screen cells is the string
      ;; length.
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

    (define (expand-line-display str width)
      ;; Expand a whole line string into its display form (caret
      ;; notation for control characters, tabs to tab stops), up to
      ;; WIDTH screen cells.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i 0) (col 0))
            (when (and (< i (string-length str)) (< col width))
              (let ((glyph (char-display-glyph (string-ref str i) col)))
                (display glyph port)
                (loop (+ i 1) (+ col (string-length glyph))))))
          (get-output-string port))))

    (define (current-line-display-column ed buffer-col)
      ;; The screen column at which buffer column BUFFER-COL of the
      ;; current line is drawn.
      ;;--------------------------------------------------------------
      (let loop ((j 0) (col 0))
        (if (>= j buffer-col)
            col
            (let ((ch (text-editor-line-editor-ref ed j)))
              (loop (+ 1 j)
                    (+ col (string-length
                            (char-display-glyph ch col))))))))

    ))
