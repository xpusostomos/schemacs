(define-library (schemacs glyph)
  ;; This library mirrors GNU Emacs's `struct glyph` and `struct
  ;; glyph_row` from `src/dispextern.h`, and the comparison macros that
  ;; sit beside them - `GLYPH_EQUAL_P` and `GLYPH_CHAR_AND_FACE_EQUAL_P` -
  ;; with `row_equal_p` (`dispnew.c:1272`) built on top.
  ;;
  ;; **Why this exists at all.** The redisplay here used to draw straight
  ;; from the buffer: `draw-line!` walked a line's characters, worked out
  ;; each run's face and wrote it, every frame, for every window. That is
  ;; fine until a keystroke has to be cheap, because a keystroke redraws
  ;; everything - measured at 16-25 ms per key on a 5000-line file.
  ;;
  ;; Emacs is cheap for a structural reason, and these two records are the
  ;; whole of it: **each window keeps the rows it has already drawn, and a
  ;; redisplay builds the rows it wants and diffs them.** A row is an
  ;; array of glyphs whose face is already resolved to an integer, so
  ;; comparing two rows is a walk over fixed-size values and drawing one
  ;; is a walk over the same - no property lookup, no face merge, no
  ;; string building on the draw path. A cursor move then changes one
  ;; glyph and the redisplay emits one cell.
  ;;
  ;; The records carry Emacs's fields, in Emacs's order, minus the ones
  ;; that describe machinery this tree does not have - bidi, fringes,
  ;; images, xwidgets, margins - each named on the field it would be.
  ;;--------------------------------------------------------------

  (import (scheme base)
          ;; `inexact->exact` is Guile's, and a folded face's `:height`
          ;; can be a flonum.
          (only (guile) inexact->exact))

  (export
   ;; the C's enums, as far as this tree reaches
   glyph-type-char glyph-area-text
   ;; `struct glyph`
   <glyph> make-glyph glyph?
   glyph-char glyph-face-id glyph-pixel-width glyph-type
   glyph-padding? glyph-voffset
   set-glyph-char! set-glyph-face-id! set-glyph-pixel-width!
   set-glyph-type! set-glyph-padding! set-glyph-voffset!
   ;; `GLYPH_EQUAL_P` and `GLYPH_CHAR_AND_FACE_EQUAL_P`
   glyph-equal? glyph-char-and-face-equal?
   ;; `struct glyph_row`
   <glyph-row> make-glyph-row glyph-row?
   glyph-row-glyphs glyph-row-used
   set-glyph-row-glyphs! set-glyph-row-used!
   set-glyph-row-x! set-glyph-row-y! set-glyph-row-ascent!
   set-glyph-row-height! set-glyph-row-pixel-width!
   glyph-row-x glyph-row-y glyph-row-ascent glyph-row-height
   glyph-row-pixel-width
   glyph-row-hash set-glyph-row-hash!
   glyph-row-enabled? set-glyph-row-enabled!
   glyph-row-mode-line? set-glyph-row-mode-line!
   glyph-row-truncated-on-right? set-glyph-row-truncated-on-right!
   glyph-row-continued? set-glyph-row-continued!
   glyph-row-displays-text? set-glyph-row-displays-text!
   glyph-row-ends-at-zv? set-glyph-row-ends-at-zv!
   glyph-row-fill-line? set-glyph-row-fill-line!
   ;; `row->continuation_lines_width > 0` (`dispextern.h:1300`): this row
   ;; is a later screen line of a wrapped line. The left fringe's
   ;; continuation bitmap reads it.
   glyph-row-continuation-line? set-glyph-row-continuation-line!
   glyph-row-start glyph-row-end
   set-glyph-row-start! set-glyph-row-end!
   ;; `row_equal_p` and the hash it compares first
   row-equal? row-hash)

  (begin

    ;;----------------------------------------------------------------
    ;; The C's two enums
    ;;----------------------------------------------------------------
    ;;
    ;; `enum glyph_type` (`dispextern.h:431`) has six members and this
    ;; has one. `CHAR_GLYPH` is a character; the other five are
    ;; `COMPOSITE_GLYPH` (a composed sequence), `GLYPHLESS_GLYPH` (a
    ;; character no font has), `IMAGE_GLYPH`, `STRETCH_GLYPH` and
    ;; `XWIDGET_GLYPH`, and this redisplay draws none of them - there is
    ;; no composition table, no image support and no widget. The field is
    ;; kept anyway because `GLYPH_EQUAL_P` compares it first, and because
    ;; a future glyph kind has somewhere to go.
    ;;
    ;; `enum glyph_row_area` (`:881`) is LEFT_MARGIN/TEXT/RIGHT_MARGIN.
    ;; This tree has no margins, so a row has one area and no area
    ;; argument is carried anywhere.

    (define glyph-type-char 'char)
    (define glyph-area-text 'text)

    ;;----------------------------------------------------------------
    ;; `struct glyph`
    ;;----------------------------------------------------------------
    ;;
    ;; The C's fields, and what each is here:
    ;;
    ;;   charpos       the buffer position the glyph was drawn from, a
    ;;                 one-based position like every other in this tree
    ;;   object        the buffer; Emacs also allows a string, and this
    ;;                 redisplay only draws buffers
    ;;   frame         the frame the glyph was produced for - the C keeps
    ;;                 it "on tty frames only", because a `face_id` is an
    ;;                 index into *that frame's* face cache; here a face
    ;;                 token is interned per display, which is the same
    ;;                 scoping
    ;;   pixel_width   in pixels - the C's `short`, a fixnum here, and one
    ;;                 cell because this grid is one cell per pixel
    ;;                 (`column-width` is 1)
    ;;   ascent
    ;;   descent
    ;;   voffset       a raised or lowered glyph
    ;;   type          `glyph-type-char`
    ;;   multibyte_p   always true: every buffer here is multibyte
    ;;   padding_p     the second cell of a wide character
    ;;   face_id       the display's interned face token - **an
    ;;                 integer**, which is the point of the whole record
    ;;
    ;; Not carried, each because nothing here paints it: the box-line
    ;; flags (`:box` is drawn by `draw-box!` from the *face*, not from the
    ;; glyph), `overlaps_vertically_p`, `glyph_not_available_p` (a
    ;; missing font is Pango's problem and it draws the box for it),
    ;; `avoid_cursor_p`, the bidi fields, and the `slice`/`u` unions -
    ;; whose `ch` member is `char` here and whose other members belong to
    ;; the glyph kinds the enum does not carry.

    (define-record-type <glyph>
      (make-glyph char face-id pixel-width type padding? voffset)
      glyph?
      (char        glyph-char        set-glyph-char!)
      (face-id     glyph-face-id     set-glyph-face-id!)
      (pixel-width glyph-pixel-width set-glyph-pixel-width!)
      (type        glyph-type        set-glyph-type!)
      (padding?    glyph-padding?    set-glyph-padding!)
      (voffset     glyph-voffset     set-glyph-voffset!))

    (define (glyph-equal? x y)
      ;; GNU Emacs's `GLYPH_EQUAL_P` (`dispextern.h:671`): "Are glyphs *X
      ;; and *Y displayed equal?"
      ;;
      ;;   ((X)->type == (Y)->type
      ;;    && (X)->u.val == (Y)->u.val
      ;;    && GLYPH_SLICE_EQUAL_P (X, Y)
      ;;    && (X)->face_id == (Y)->face_id
      ;;    && (X)->frame == (Y)->frame
      ;;    && (X)->padding_p == (Y)->padding_p
      ;;    && (X)->left_box_line_p == (Y)->left_box_line_p
      ;;    && (X)->right_box_line_p == (Y)->right_box_line_p
      ;;    && (X)->voffset == (Y)->voffset
      ;;    && (X)->pixel_width == (Y)->pixel_width)
      ;;
      ;; `u.val` is the union compared as one integer - the character, for
      ;; a `CHAR_GLYPH` - and `GLYPH_SLICE_EQUAL_P` is about images and
      ;; compositions, of which this tree draws none. The box and
      ;; `avoid_cursor` flags are not carried (above), so what is left is
      ;; the six that decide what appears.
      ;;--------------------------------------------------------------
      (and (eq? (glyph-type x) (glyph-type y))
           ;; **`equal?`, not `eqv?`.** The C's `u.val` is an integer
           ;; character code, so `GLYPH_EQUAL_P`'s `==` works; this
           ;; tree's `glyph-char` is the cell's whole *string* (a
           ;; `display` property can make one cell several characters),
           ;; and `eqv?` on two equal strings is #f unless they are the
           ;; same object. Every rebuilt row therefore compared unequal
           ;; with the one on the screen, `update_window` redrew all of
           ;; them, and the matrix diff never matched - which is what
           ;; made a keystroke cost the whole window.
           (equal? (glyph-char x) (glyph-char y))
           (eqv? (glyph-face-id x) (glyph-face-id y))
           (eq? (glyph-padding? x) (glyph-padding? y))
           (eqv? (glyph-voffset x) (glyph-voffset y))
           (eqv? (glyph-pixel-width x) (glyph-pixel-width y))))

    (define (glyph-char-and-face-equal? x y)
      ;; GNU Emacs's `GLYPH_CHAR_AND_FACE_EQUAL_P` (`:685`): "Are
      ;; character codes, faces, padding_ps of glyphs *X and *Y equal?"
      ;; The weaker test `update_text_area` uses to decide that a run can
      ;; be left as it stands.
      ;;--------------------------------------------------------------
      (and (equal? (glyph-char x) (glyph-char y))
           (eqv? (glyph-face-id x) (glyph-face-id y))
           (eq? (glyph-padding? x) (glyph-padding? y))))

    ;;----------------------------------------------------------------
    ;; `struct glyph_row`
    ;;----------------------------------------------------------------
    ;;
    ;; A row is an array of glyphs plus the geometry it is drawn at.
    ;;
    ;;   glyphs        a vector of `<glyph>` - the C's `struct glyph *`
    ;;   used          how many of them there are
    ;;   x, y          the row's top-left in pixels, frame-relative
    ;;   pixel-width   its width
    ;;   ascent        where its baseline sits, from the row's top
    ;;   height        how many pixels tall
    ;;   hash          a checksum of the glyphs, so two rows are told
    ;;                 apart without walking them; the C keeps one
    ;;                 (`dispextern.h:942`) precisely so `row_equal_p`
    ;;                 can compare hashes before glyphs
    ;;   enabled?      "in a desired matrix, true means this row must be
    ;;                 updated; in a current matrix, false means the row
    ;;                 has been invalidated" (`:1040`)
    ;;   mode-line?    a mode or header line rather than text
    ;;   truncated-on-right? / continued?
    ;;                 which of `$` and `\` the last cell carries
    ;;   displays-text?  false for the blank row past the buffer's end
    ;;   ends-at-zv?   the row ends at the end of the buffer
    ;;   fill-line?    the last glyph's face runs to the window's edge
    ;;   start, end    the buffer positions this row begins and ends at
    ;;
    ;; Not carried: the three areas (no margins), the physical
    ;; ascent/height (this grid's rows are one height), the fringe and
    ;; overlay-arrow fields, `reversed_p` (no bidi), and the per-row
    ;; `redisplay` flag - `enabled?` is the one `row_equal_p`'s callers
    ;; actually read.

    (define-record-type <glyph-row>
      (make-glyph-row glyphs used x y pixel-width ascent height
                      start end continuation-line)
      glyph-row?
      (glyphs        glyph-row-glyphs        set-glyph-row-glyphs!)
      (used          glyph-row-used          set-glyph-row-used!)
      (x             glyph-row-x             set-glyph-row-x!)
      (y             glyph-row-y             set-glyph-row-y!)
      (pixel-width   glyph-row-pixel-width   set-glyph-row-pixel-width!)
      (ascent        glyph-row-ascent        set-glyph-row-ascent!)
      (height        glyph-row-height        set-glyph-row-height!)
      (start         glyph-row-start         set-glyph-row-start!)
      (end           glyph-row-end           set-glyph-row-end!)
      (hash          glyph-row-hash          set-glyph-row-hash!)
      ;; **The field names carry no `?`.** `define-record-type` derives the
      ;; setter by appending `!` to the field's name, so a field called
      ;; `enabled?` generates `set-glyph-row-enabled?!` - which is not the
      ;; name anything calls, and the failure is an unbound variable at the
      ;; first write rather than a load error. The `?` belongs to the
      ;; *accessor*, which is spelled out here.
      (enabled       glyph-row-enabled?      set-glyph-row-enabled!)
      (mode-line     glyph-row-mode-line?    set-glyph-row-mode-line!)
      (truncated-on-right glyph-row-truncated-on-right?
                          set-glyph-row-truncated-on-right!)
      (continued     glyph-row-continued?    set-glyph-row-continued!)
      (displays-text glyph-row-displays-text?
                     set-glyph-row-displays-text!)
      (ends-at-zv    glyph-row-ends-at-zv?   set-glyph-row-ends-at-zv!)
      (fill-line     glyph-row-fill-line?    set-glyph-row-fill-line!)
      ;; `MATRIX_ROW_CONTINUATION_LINE_P` (`dispextern.h:1300`): this row
      ;; continues a line begun on an earlier screen row.
      (continuation-line glyph-row-continuation-line?
                         set-glyph-row-continuation-line!))

    (define (row-hash row)
      ;; GNU Emacs's `hash_row` (`dispnew.c`): a checksum of the row's
      ;; glyphs, stored on the row as soon as `display_line` has built it
      ;; (`dispextern.h:942`). `row_equal_p` compares hashes first and
      ;; only walks the glyphs when they match, which is what makes an
      ;; unchanged row cost one integer comparison.
      ;;
      ;; The C's loop is
      ;;
      ;;   v = rows->hash;
      ;;   for (i = 0; i < used; ++i)  v = sxhash (glyphs[i].u.val, v);
      ;;
      ;; - a rolling hash over the glyph codes only, because the face and
      ;; the width are already implied by the code in Emacs's glyph table.
      ;; Here a character and a face are independent (the same character
      ;; in two faces is two glyphs), so both go in.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (v 5381))
        (if (>= i (glyph-row-used row))
            v
            (let ((g (vector-ref (glyph-row-glyphs row) i)))
              (loop (+ i 1)
                    (modulo (+ (* v 33)
                               (glyph-text-hash (glyph-char g))
                               (glyph-face-hash (glyph-face-id g)))
                            #x7fffffff))))))

    (define (glyph-face-hash face)
      ;; A glyph's face folded to one integer, so `row-hash` can add it.
      ;;
      ;; **The C's `glyph->face_id` is an integer index; this tree's token
      ;; is whatever `realize-face` answers**, and the terminal answers
      ;; the folded face plist (`struct face`'s fields), because that is
      ;; what `turn_on_face` reads. So the hash is over the plist's
      ;; values: two equal faces hash the same, and `row_equal_p`'s second
      ;; test - `glyph-equal?` - is what actually decides.
      ;;--------------------------------------------------------------
      (if (integer? face)
          face
          (let loop ((rest face) (v 5381))
            (cond ((not (pair? rest)) v)
                  ((null? (cdr rest)) (loop (cdr rest) v))
                  (else
                   (loop (cddr rest)
                         (modulo (+ (* v 33)
                                    (let ((e (cadr rest)))
                                      (cond ((not e) 0)
                                            ((number? e) (inexact->exact (abs e)))
                                            ((symbol? e) (string-length (symbol->string e)))
                                            (else 1))))
                                 #x7fffffff)))))))

    (define (glyph-text-hash text)
      ;; A glyph's text hashed to one integer, so `row-hash` can fold it in
      ;; with `+`. **This tree's `glyph-char` holds a string** - the run of
      ;; characters that one cell draws, which may be several for a `display`
      ;; property - where the C's holds a single character code. Adding the
      ;; string itself is "Wrong type argument in position 2: \"1\""; the
      ;; string's own rolling hash is the same number for the same text.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (v 5381))
        (if (>= i (string-length text))
            v
            (loop (+ i 1) (+ (* v 33) (char->integer (string-ref text i)))))))

    (define (row-equal? a b)
      ;; GNU Emacs's `row_equal_p` (`dispnew.c:1272`): "Return true if the
      ;; glyph rows A and B have equal contents."
      ;;
      ;;   if (a == b) return 1;
      ;;   else if (a->hash != b->hash) return 0;
      ;;   else { compare each area's glyphs with GLYPH_EQUAL_P }
      ;;
      ;; The C also compares the geometry - `x`, `y`, `pixel_width` - in
      ;; its caller, because a row that has moved must be redrawn even
      ;; when its contents did not change. That test is here, for the same
      ;; reason: it is about the row, and leaving it out is how a window
      ;; that scrolled without an edit would keep its old picture.
      ;;--------------------------------------------------------------
      (if (eq? a b)
          #t
          (and (eqv? (glyph-row-hash a) (glyph-row-hash b))
               (eqv? (glyph-row-used a) (glyph-row-used b))
               (eqv? (glyph-row-x a) (glyph-row-x b))
               (eqv? (glyph-row-y a) (glyph-row-y b))
               (eqv? (glyph-row-pixel-width a) (glyph-row-pixel-width b))
               (eq? (glyph-row-mode-line? a) (glyph-row-mode-line? b))
               (eq? (glyph-row-truncated-on-right? a)
                    (glyph-row-truncated-on-right? b))
               (eq? (glyph-row-continued? a) (glyph-row-continued? b))
               (eq? (glyph-row-displays-text? a)
                    (glyph-row-displays-text? b))
               (eq? (glyph-row-ends-at-zv? a) (glyph-row-ends-at-zv? b))
               (eq? (glyph-row-fill-line? a) (glyph-row-fill-line? b))
               (eq? (glyph-row-continuation-line? a)
                    (glyph-row-continuation-line? b))
               (let loop ((i 0))
                 (cond ((>= i (glyph-row-used a)) #t)
                       ((not (glyph-equal? (vector-ref (glyph-row-glyphs a) i)
                                           (vector-ref (glyph-row-glyphs b) i)))
                        #f)
                       (else (loop (+ i 1))))))))

    ))
