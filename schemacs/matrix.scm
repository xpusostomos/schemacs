(define-library (schemacs matrix)
  ;; This library mirrors GNU Emacs's `struct glyph_matrix` and the
  ;; update machinery of `src/dispnew.c` that operates on a pair of them:
  ;; `update_window` (`:4400`), `row_equal_p` (`:1272`) and
  ;; `assign_row`/`swap_glyph_pointers` (`:1009`, `:1035`).
  ;;
  ;; **The idea is one sentence**: a window keeps the rows it has already
  ;; drawn (`current-matrix`) and a redisplay builds the rows it wants
  ;; (`desired-matrix`); the update walks the two together and emits only
  ;; the rows that differ. A cursor move changes one glyph in one row, so
  ;; a cursor move costs one glyph.
  ;;
  ;; What that needs from the rest of the editor:
  ;;
  ;;   * rows are made of `<glyph>` records with the face *already* an
  ;;     integer (see `(schemacs glyph)`) - which is what makes a
  ;;     row cheap to compare and cheap to draw;
  ;;   * the frame's surface is **not** cleared between frames, because a
  ;;     row that was not re-drawn is still on it. That is the piece whose
  ;;     absence made a redraw-skip impossible before.
  ;;
  ;; Both matrices live on the window, as they do in `struct window`
  ;; (`window.h`), and are adjusted when the window's size changes.
  ;;--------------------------------------------------------------

  (import (scheme base)
          ;; `caddr` is not resolved through `(scheme base)` by the
          ;; library compiler, as elsewhere in this tree.
          (only (guile) caddr)
          (only (schemacs glyph)
                <glyph-row> make-glyph-row glyph-row?
                glyph-row-glyphs set-glyph-row-glyphs!
                glyph-row-used set-glyph-row-used!
                glyph-row-x set-glyph-row-x!
                glyph-row-y set-glyph-row-y!
                glyph-row-pixel-width set-glyph-row-pixel-width!
                glyph-row-ascent set-glyph-row-ascent!
                glyph-row-height set-glyph-row-height!
                glyph-row-start set-glyph-row-start!
                glyph-row-end set-glyph-row-end!
                glyph-row-hash set-glyph-row-hash!
                glyph-row-enabled? set-glyph-row-enabled!
                glyph-row-mode-line? set-glyph-row-mode-line!
                glyph-row-truncated-on-right?
                set-glyph-row-truncated-on-right!
                glyph-row-continued? set-glyph-row-continued!
                glyph-row-continuation-line?
                set-glyph-row-continuation-line!
                glyph-row-displays-text? set-glyph-row-displays-text!
                glyph-row-ends-at-zv? set-glyph-row-ends-at-zv!
                glyph-row-fill-line? set-glyph-row-fill-line!
                row-equal? row-hash))

  (export
   <glyph-matrix> make-glyph-matrix glyph-matrix?
   glyph-matrix-rows set-glyph-matrix-rows!
   glyph-matrix-width set-glyph-matrix-width!
   glyph-matrix-height set-glyph-matrix-height!
   glyph-matrix-row glyph-matrix-row-ref
   adjust-glyph-matrix
   clear-glyph-matrix clear-glyph-matrix-row
   ;; the update, `update_window`
   matrix-diff-rows assign-row matrix-mark-current!
   ;; `w->current_matrix` / `w->desired_matrix` on a window
   window-current-matrix window-desired-matrix
   set-window-current-matrix! set-window-desired-matrix!
   ensure-window-matrices!)

  (begin

    ;;----------------------------------------------------------------
    ;; `struct glyph_matrix`
    ;;----------------------------------------------------------------
    ;;
    ;; The C's fields, and what each is here:
    ;;
    ;;   rows            a vector of `<glyph-row>`
    ;;   rows-allocated  its length
    ;;   nrows           how many the window uses
    ;;   matrix-w, matrix-h
    ;;                   the grid, in cells
    ;;
    ;; Not carried: `pool` (the C allocates glyphs from a shared arena so
    ;; that a `memcpy` of a pool is a whole frame's worth of glyphs; a
    ;; Scheme vector of records needs no arena), the `matrix_x/y` origin
    ;; within a frame matrix (this tree has one matrix per *window*, never
    ;; a frame matrix), the `window_pixel_*` and vscroll bookkeeping
    ;; (`adjust_glyph_matrix` uses it to reuse rows; here the matrices are
    ;; simply resized), the marginal-area counts (no margins), and the
    ;; `no_scrolling_p`/`tab_line_p`/`header_line_p` flags, none of which
    ;; this redisplay consults.

    (define-record-type <glyph-matrix>
      (make-glyph-matrix rows width height)
      glyph-matrix?
      (rows    glyph-matrix-rows    set-glyph-matrix-rows!)
      (width   glyph-matrix-width   set-glyph-matrix-width!)
      (height  glyph-matrix-height  set-glyph-matrix-height!))

    (define (glyph-matrix-row-ref matrix n)
      ;; `MATRIX_ROW (matrix, n)` (`dispextern.h:1163`) - the row, or #f
      ;; when the matrix has no such row. The C's debug build asserts;
      ;; this answers #f, which every caller here treats the same way the
      ;; C's bounds check does.
      ;;--------------------------------------------------------------
      (and matrix
           (>= n 0)
           (< n (vector-length (glyph-matrix-rows matrix)))
           (vector-ref (glyph-matrix-rows matrix) n)))

    (define glyph-matrix-row glyph-matrix-row-ref)

    (define (blank-row n)
      ;; A row with nowhere to be and nothing on it: the C's
      ;; `clear_glyph_row` over a row that `adjust_glyph_matrix` has just
      ;; made.
      ;;--------------------------------------------------------------
      (make-glyph-row (vector) 0 0 0 0 0 1 n n #f))

    (define (adjust-glyph-matrix matrix width height)
      ;; GNU Emacs's `adjust_glyph_matrix` (`dispnew.c`): make MATRIX the
      ;; size of a window that is WIDTH cells by HEIGHT rows, keeping the
      ;; rows that already exist and making blank ones for the rest.
      ;;
      ;; The C's version also reuses *glyph* storage between rows and
      ;; records the window's pixel geometry; what matters here is that a
      ;; row that survives the resize keeps its contents, so a window that
      ;; grew by one row does not redraw the rows above it.
      ;;--------------------------------------------------------------
      (let* ((old (glyph-matrix-rows matrix))
             (old-n (if old (vector-length old) 0))
             (new (make-vector height #f)))
        (let loop ((i 0))
          (when (< i height)
            (vector-set! new i
                         (if (< i old-n) (vector-ref old i) (blank-row i)))
            (loop (+ i 1))))
        (set-glyph-matrix-rows! matrix new)
        (set-glyph-matrix-width! matrix width)
        (set-glyph-matrix-height! matrix height)))

    (define (clear-glyph-matrix-row row)
      ;; GNU Emacs's `clear_glyph_row`: forget what the row had.
      ;; `enabled_p` false is the C's "invalidated in a current matrix",
      ;; and it is also what makes `update_window` treat a desired row as
      ;; one it must draw.
      ;;--------------------------------------------------------------
      (set-glyph-row-used! row 0)
      (set-glyph-row-hash! row 0)
      (set-glyph-row-enabled! row #f)
      (set-glyph-row-mode-line! row #f)
      (set-glyph-row-truncated-on-right! row #f)
      (set-glyph-row-continued! row #f)
      (set-glyph-row-displays-text! row #f)
      (set-glyph-row-ends-at-zv! row #f)
      (set-glyph-row-fill-line! row #f)
      (set-glyph-row-continuation-line! row #f))

    (define (clear-glyph-matrix matrix)
      ;; `clear_glyph_matrix`: every row forgotten, both the desired one
      ;; before a redisplay builds it and the current one when the window
      ;; must be painted from scratch.
      ;;--------------------------------------------------------------
      (let ((rows (glyph-matrix-rows matrix)))
        (let loop ((i 0))
          (when (< i (vector-length rows))
            (clear-glyph-matrix-row (vector-ref rows i))
            (loop (+ i 1))))))

    ;;----------------------------------------------------------------
    ;; The update - `assign_row` and `swap_glyph_pointers`
    ;;----------------------------------------------------------------

    (define (assign-row current desired)
      ;; GNU Emacs's `assign_row` (`dispnew.c:1035`): "Assign glyph row
      ;; FROM to glyph row TO.  FROM must be in a desired glyph matrix,
      ;; and TO must be in a current matrix." The two exchange glyph
      ;; storage and copy everything else, so that the current matrix now
      ;; has what is on the screen and the desired one is free to be built
      ;; over.
      ;;
      ;; **`used` and `hash` swap with the storage, they are not copied.**
      ;; The C's `swap_glyph_pointers` exchanges `glyphs[i]`, `used[i]` and
      ;; `hash` in one loop, and `copy_row_except_pointers` then memcpy's
      ;; from `x` onward - which is *after* those three fields, so it never
      ;; touches them again. Copying `used` from the desired row instead
      ;; leaves the desired row claiming the count that went with the
      ;; vector it just gave away: `row_equal?` walks `used` entries of an
      ;; empty vector on the next redisplay and raises "Argument 2 out of
      ;; range" - and because `update-window!` runs inside the command
      ;; loop, that raise was a redisplay that quietly stopped.
      ;;--------------------------------------------------------------
      (let ((to-glyphs (glyph-row-glyphs current))
            (from-glyphs (glyph-row-glyphs desired))
            (to-used (glyph-row-used current))
            (from-used (glyph-row-used desired))
            (to-hash (glyph-row-hash current))
            (from-hash (glyph-row-hash desired)))
        (set-glyph-row-glyphs! current from-glyphs)
        (set-glyph-row-glyphs! desired to-glyphs)
        (set-glyph-row-used! current from-used)
        (set-glyph-row-used! desired to-used)
        (set-glyph-row-hash! current from-hash)
        (set-glyph-row-hash! desired to-hash))
      (set-glyph-row-x! current (glyph-row-x desired))
      (set-glyph-row-y! current (glyph-row-y desired))
      (set-glyph-row-pixel-width! current (glyph-row-pixel-width desired))
      (set-glyph-row-ascent! current (glyph-row-ascent desired))
      (set-glyph-row-height! current (glyph-row-height desired))
      (set-glyph-row-start! current (glyph-row-start desired))
      (set-glyph-row-end! current (glyph-row-end desired))
      (set-glyph-row-mode-line! current (glyph-row-mode-line? desired))
      (set-glyph-row-truncated-on-right!
       current (glyph-row-truncated-on-right? desired))
      (set-glyph-row-continued! current (glyph-row-continued? desired))
      (set-glyph-row-displays-text! current
                                    (glyph-row-displays-text? desired))
      (set-glyph-row-ends-at-zv! current (glyph-row-ends-at-zv? desired))
      (set-glyph-row-fill-line! current (glyph-row-fill-line? desired))
      (set-glyph-row-continuation-line!
       current (glyph-row-continuation-line? desired))
      (set-glyph-row-enabled! current #t))

    (define (matrix-diff-rows current desired)
      ;; GNU Emacs's `update_window` (`dispnew.c:4400`) reduced to what it
      ;; decides: for each row, "does the desired row differ from the one
      ;; on the screen?" A row the C calls `enabled_p` in the desired
      ;; matrix is one that was built this redisplay; a desired row that
      ;; is *not* enabled has not been built and is the C's
      ;; `swap_glyph_pointers` case - it keeps what the screen shows.
      ;;
      ;; The answer is the list of row indices to draw, and it is the
      ;; whole of the performance win: a `C-n` changes the cursor cell and
      ;; the mode line, so this returns two or three indices out of
      ;; twenty-four instead of every row of every window.
      ;;--------------------------------------------------------------
      (let ((height (min (glyph-matrix-height desired)
                         (glyph-matrix-height current))))
        (let loop ((i 0) (out '()))
          (if (>= i height)
              (reverse out)
              (let ((d (glyph-matrix-row-ref desired i))
                    (c (glyph-matrix-row-ref current i)))
                (loop (+ i 1)
                      ;; `update_window_line` (`dispnew.c:4749`): "If rows
                      ;; are at different X or Y, or rows have different
                      ;; height, or the current row is marked invalid,
                      ;; write the entire line."
                      ;;
                      ;; **`!current_row->enabled_p` is the one that was
                      ;; missing**, and it is not a detail: a row the
                      ;; current matrix has never held compares *equal* to
                      ;; a blank desired row, so the diff skipped it and
                      ;; whatever was on the screen under it stayed. A
                      ;; window whose matrix grew - a window that took
                      ;; over the rows of one deleted beside it - kept the
                      ;; deleted window's text and mode line. Measured,
                      ;; `C-x C-b` then `q` left the buffer list on screen
                      ;; below the file, and the same for the completions
                      ;; window.
                      (if (and d c
                               (glyph-row-enabled? c)
                               (eqv? (glyph-row-ascent d)
                                     (glyph-row-ascent c))
                               (eqv? (glyph-row-height d)
                                     (glyph-row-height c))
                               (row-equal? c d))
                          out
                          (cons i out))))))))

    (define (matrix-mark-current! current desired)
      ;; After a row has been drawn, the current matrix holds it - the C's
      ;; `assign_row` at the end of `update_window`'s per-row branch, and
      ;; its `current_row->enabled_p = true` (`dispnew.c:2865`).
      ;;--------------------------------------------------------------
      (let ((height (min (glyph-matrix-height desired)
                         (glyph-matrix-height current))))
        (let loop ((i 0))
          (when (< i height)
            (let ((d (glyph-matrix-row-ref desired i))
                  (c (glyph-matrix-row-ref current i)))
              (when (and d c (glyph-row-enabled? d))
                (assign-row c d)))
            (loop (+ i 1))))))

    ;;----------------------------------------------------------------
    ;; The two matrices on a window
    ;;----------------------------------------------------------------
    ;;
    ;; `w->current_matrix` and `w->desired_matrix` are fields of `struct
    ;; window` (`window.h`). This tree's `<window>` is a record in
    ;; `(schemacs frame)`, which is *below* this library - the
    ;; redisplay is built on the frame, not the other way round - so the
    ;; pair lives in a table here, keyed by the window. That is a
    ;; placement departure and it is named where it is made: the C keeps
    ;; them on the window because there is nowhere else to put them, and
    ;; a table keyed by the window is the same state with the same
    ;; lifetime.

    (define *window-matrices* (make-parameter '()))
    ;; ^ `((WINDOW CURRENT DESIRED) ...)`

    (define (window-matrix-entry window)
      (let loop ((rest (*window-matrices*)))
        (cond ((null? rest) #f)
              ((eq? (caar rest) window) (car rest))
              (else (loop (cdr rest))))))

    (define (window-current-matrix window)
      (let ((e (window-matrix-entry window)))
        (and e (cadr e))))

    (define (window-desired-matrix window)
      (let ((e (window-matrix-entry window)))
        (and e (caddr e))))

    (define (set-window-current-matrix! window m)
      (let ((e (window-matrix-entry window)))
        (if e
            (set-car! (cdr e) m)
            (*window-matrices*
             (cons (list window m #f) (*window-matrices*))))))

    (define (set-window-desired-matrix! window m)
      (let ((e (window-matrix-entry window)))
        (if e
            (set-car! (cddr e) m)
            (*window-matrices*
             (cons (list window #f m) (*window-matrices*))))))

    (define (ensure-window-matrices! window width height)
      ;; The C's `ensure_glyphs_for_window` (`dispnew.c:1829`): give WINDOW
      ;; its pair of matrices, sized WIDTH by HEIGHT, making them the first
      ;; time and resizing them after. A window that keeps its size keeps
      ;; its matrices, which is what lets the next redisplay skip rows.
      ;;--------------------------------------------------------------
      (let ((current (window-current-matrix window))
            (desired (window-desired-matrix window)))
        (if current
            (begin
              (unless (and (= width (glyph-matrix-width current))
                           (= height (glyph-matrix-height current)))
                (adjust-glyph-matrix current width height)
                (adjust-glyph-matrix desired width height))
              current)
            (let ((c (make-glyph-matrix (vector) 0 0))
                  (d (make-glyph-matrix (vector) 0 0)))
              (adjust-glyph-matrix c width height)
              (adjust-glyph-matrix d width height)
              (set-window-current-matrix! window c)
              (set-window-desired-matrix! window d)
              c))))

    ))
