(define-library (schemacs editor character)
  ;; This library mirrors GNU Emacs's `src/character.c' - the width of a
  ;; character, which is how many screen *columns* it occupies and is not
  ;; the same thing as how many characters it takes to write it.
  ;;
  ;; It matters as soon as a buffer holds anything outside ASCII. A CJK
  ;; ideograph is one character and two columns; a combining acute is one
  ;; character and no columns at all. An editor that counts characters
  ;; where it should count columns draws the text correctly - the terminal
  ;; and the font both know the real width - and then puts the cursor, the
  ;; region and everything after it in the wrong place by one column per
  ;; wide character.
  ;;
  ;; The table itself is `characters.sld', which is
  ;; `lisp/international/characters.el'; this file is the C, which creates
  ;; the table and owns the default. The two names differ by one letter
  ;; because Emacs's do.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor characters) char-width-ranges))

  (export
   *tab-width*
   char-width
   char-width-default
   sanitize-char-width)

  (begin

    (define *tab-width* (make-parameter 8))
    ;; ^ GNU Emacs's `tab-width'. Emacs defines it in `buffer.c' and
    ;; `CHARACTER_WIDTH' reads it through `SANE_TAB_WIDTH (current_buffer)',
    ;; which is why the default and the tab case of `char-width' below are
    ;; here. It is a parameter rather than a buffer-local because this
    ;; project has one value for the buffer being drawn rather than a value
    ;; per buffer - the same decision `disp-table.sld' records.
    ;;
    ;; It is *defined* here, rather than in `buffer.sld' where Emacs
    ;; defines it, because of the import graph: `buffer.sld' imports
    ;; `frame.sld', which imports `xdisp.sld', which imports
    ;; `disp-table.sld', which imports this library - so a `tab-width' in
    ;; `buffer.sld' is not reachable from the width code without a cycle.
    ;; `disp-table.sld' imports it from here for the same reason. There is
    ;; exactly one, so the two cannot disagree.

    (define char-width-default 1)
    ;; ^ `Vchar_width_table = Fmake_char_table (Qnil, make_fixnum (1))'
    ;; in `syms_of_character'. A character in none of the table's ranges
    ;; is one column wide.

    (define (sanitize-char-width width)
      ;; Emacs's `sanitize_char_width': a width outside 0..1000 is taken
      ;; to be 1000, so a broken table cannot make redisplay allocate
      ;; nonsense.
      ;;--------------------------------------------------------------
      (if (and (<= 0 width) (<= width 1000)) width 1000))

    (define (char-width-table-ref c)
      ;; The table's answer for C: the width of the range it falls in, or
      ;; the default 1.
      ;;
      ;; A bisection rather than a scan: the ranges are sorted and
      ;; disjoint, there are 400-odd of them, and this runs once per
      ;; character of every line drawn.
      ;;--------------------------------------------------------------
      (let ((ranges char-width-ranges))
        (let loop ((lo 0) (hi (vector-length ranges)))
          (if (>= lo hi)
              char-width-default
              (let* ((mid (quotient (+ lo hi) 2))
                     (r (vector-ref ranges mid)))
                (cond ((< c (vector-ref r 0)) (loop lo mid))
                      ((< (vector-ref r 1) c) (loop (+ mid 1) hi))
                      (else (vector-ref r 2))))))))

    (define (char-width ch)
      ;; GNU Emacs's `char-width': the width of CH in columns when
      ;; displayed in the current buffer.
      ;;
      ;; This is Emacs's `CHARACTER_WIDTH' macro (`buffer.h'), which is
      ;; what `char_width' starts from. The C writes it as one nested
      ;; conditional and the branches are worth keeping in its order,
      ;; because they are not all table lookups:
      ;;
      ;;   0x20..0x7E   1        - printable ASCII, whatever the table says
      ;;   above 0x7F   the table
      ;;   tab          `tab-width'
      ;;   newline      0        - a newline ends a line, it does not occupy one
      ;;   other control characters, DEL included:
      ;;               2 in caret notation (^M), 4 as an octal escape (\015)
      ;;
      ;; The 2-versus-4 choice is Emacs's `ctl-arrow', a buffer-local
      ;; variable this editor does not have yet - `disp-table.sld' always
      ;; draws caret notation - so it is the 2 here. `char_width' then
      ;; applies the buffer's display table; this editor has no
      ;; `buffer-display-table' either, so there is nothing to apply.
      ;;--------------------------------------------------------------
      (let ((c (char->integer ch)))
        (cond
         ((and (<= #x20 c) (< c #x7f)) 1)
         ((< #x7f c) (sanitize-char-width (char-width-table-ref c)))
         ((char=? ch #\tab) (*tab-width*))
         ((char=? ch #\newline) 0)
         (else 2))))

    ))
