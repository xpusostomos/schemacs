(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor buffer)
       get-buffer-create set-buffer current-buffer erase-buffer)
 (only (schemacs editor editfns)
       insert goto-char point buffer-string)
 (only (schemacs editor textprop) put-text-property)
 (only (schemacs editor indentc)
       current-column current-line-display-column move-to-column
       scan-for-column))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor indentc)', which mirrors GNU
;; Emacs's `indent.c' - the column arithmetic.
;;
;; Every expectation below was *measured* on GNU Emacs 31.1 rather than
;; reasoned about: `emacs -Q --batch' with the same buffer, the same
;; property and `current-column' / `move-to-column'. That is the check
;; the port is written against; the source is still what the algorithm
;; comes from.
;;
;; Two bugs are pinned here, both in the hand-rolled copy of the walk
;; that `current-line-display-column' used to be and that
;; `scan-for-column' replaced on 2026-10-06:
;;
;;   1. a `display' property's width was added once per character the
;;      property covered, instead of once for the whole run;
;;   2. that string was measured from the current column, where the C
;;      measures it from column 0 (`Fstring_width (val, Qnil, Qnil)').
;;
;; The second test below is the case that showed both at once. Before the
;; fix it answered (0 1 3 5 7 8 9) where Emacs answers (0 1 3 3 3 4 5).

(test-begin "schemacs_editor_indentc")

(define (buffer-of text)
  ;; A buffer of its own per test: `insert' appends, so a shared one
  ;; would carry the previous test's text into the next.
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create "*indentc-tests*")))
    (set-buffer ed)
    (erase-buffer)
    (insert text)
    ed))

(define (iota n)
  (let loop ((i 0) (acc '()))
    (if (>= i n) (reverse acc) (loop (+ i 1) (cons i acc)))))

(define (columns-at ed positions)
  ;; `current-column' at each of POSITIONS, in order. A loop rather than
  ;; a `map', because it moves point.
  ;;--------------------------------------------------------------
  (let loop ((ps positions) (acc '()))
    (if (null? ps)
        (reverse acc)
        (begin
          (goto-char (car ps))
          (loop (cdr ps) (cons (current-column) acc))))))

(define (at-column text column force)
  ;; `(point) (move-to-column COLUMN FORCE) (buffer-string)' - the three
  ;; things Emacs's probe printed. The move is bound before the list is
  ;; built on purpose: Guile evaluates `list''s operands left to right,
  ;; so `(point)' written inside the list would be read *before* the
  ;; move and always answer 1.
  ;;--------------------------------------------------------------
  (let ((ed (buffer-of text)))
    (goto-char 1)
    (let ((col (move-to-column column force)))
      (list (point) col (buffer-string)))))

;; A plain line counts one column per character, and the column at
;; `point-max' is the line's length.
(test-equal "current-column on a plain line"
  '(0 1 2 3 4 5 6)
  (columns-at (buffer-of "abcdef") '(1 2 3 4 5 6 7)))

;; A `display' string standing on a run of characters is *substituted for
;; the whole run*: its width counts once, and every position inside the
;; run reports the column the run ends at. Emacs, for "XY" on 2..5 of
;; "abcdef": 0 1 3 3 3 4 5.
(test-equal "a display run's width counts once, not once per character"
  '(0 1 3 3 3 4 5)
  (let ((ed (buffer-of "abcdef")))
    (put-text-property 2 5 'display "XY" ed)
    (columns-at ed '(1 2 3 4 5 6 7))))

;; ...and the substituted string is measured from column *0*, not from
;; where it stands. A display string "\tY" reached at column 3 is 9
;; columns wide, not 6, so the next position is column 12. Emacs agrees:
;; it answers 3 at position 4 and 12 at position 5.
(test-equal "a display string is measured from column zero"
  '(0 1 2 3 12 13 14 15)
  (let ((ed (buffer-of "abcXdef")))
    (put-text-property 4 5 'display "\tY" ed)
    (columns-at ed '(1 2 3 4 5 6 7 8))))

;; A tab goes to the next multiple of `tab-width' - 8 by default - so the
;; position after it is column 8.
(test-equal "current-column over a tab goes to the next tab stop"
  '(0 1 8 9)
  (columns-at (buffer-of "a\tb") '(1 2 3 4)))

;; A wide character takes two columns, so a position after it is two
;; further along than the character count says. The ideographic space
;; U+3000 is two columns wide.
(test-equal "current-column over a wide character"
  '(0 1 3 4)
  (columns-at (buffer-of "a　b") '(1 2 3 4)))

;; ------------------------------------------------------------------
;; move-to-column
;;
;; The answers below are Emacs 31.1's, from `emacs -Q --batch', in the
;; order `(point) (move-to-column COLUMN FORCE) (buffer-string)'.

(test-equal "move-to-column within the line"
  '(4 3 "abcdef")
  (at-column "abcdef" 3 #f))

;; Past the end of the line it goes to the end of the line, and reports
;; the column the line actually ends at - 2, not the 5 asked for.
(test-equal "move-to-column past the end of the line"
  '(3 2 "ab")
  (at-column "ab" 5 #f))

;; ...unless FORCE is `t' itself, which pads the line out to the column.
(test-equal "move-to-column past the end with FORCE t pads with spaces"
  '(6 5 "ab   ")
  (at-column "ab" 5 #t))

;; A tab overshoots a column in the middle of it: point goes *after* the
;; tab, and the column reported is 8, the tab stop it reached.
(test-equal "move-to-column landing inside a tab"
  '(3 8 "a\tb")
  (at-column "a\tb" 3 #f))

;; With FORCE, the tab is replaced: spaces are inserted in front of it to
;; reach the goal, the tab is deleted, and the line is then indented to
;; the column the tab had reached. Emacs keeps a tab there
;; (`indent-tabs-mode' is t by default) and lands point on the column
;; asked for, 4.
(test-equal "move-to-column FORCE splits the tab"
  '(4 3 "a  \tb")
  (at-column "a\tb" 3 #t))

;; Landing exactly on a tab stop is not "inside" the tab, so nothing is
;; rewritten and point sits after the tab.
(test-equal "move-to-column onto a tab stop exactly"
  '(3 8 "a\tb")
  (at-column "a\tb" 8 #f))

(test-equal "move-to-column to column zero"
  '(1 0 "abcdef")
  (at-column "abcdef" 0 #f))

;; A wide character straddling the goal: point goes after it, and the
;; column is the one it reached, 3.
(test-equal "move-to-column into a wide character goes after it"
  '(3 3 "a　b")
  (at-column "a　b" 2 #f))

;; ------------------------------------------------------------------
;; scan-for-column's four answers
;;
;; The C writes five through pointers, two of them byte positions this
;; tree has none of. What it means by PREVPOS/PREVCOL is "the position
;; and column one character before the stop", and the tab case is where
;; that is visible: the stop is after the tab at column 8, and the
;; character before it is the tab itself, at column 1.
(test-equal "scan-for-column answers the stop and the step before it"
  '(3 8 2 1)
  (let ((ed (buffer-of "a\tb")))
    (call-with-values
        (lambda () (scan-for-column ed 4 3))
      (lambda (pos col prev-pos prev-col) (list pos col prev-pos prev-col)))))

;; With no goal and no end it walks the whole of point's line - which is
;; `current_column_1' (`indent.c:856'), the answer `current-column'
;; gives.
(test-equal "scan-for-column with nothing asked walks to point"
  '(3 8 2 1)
  (let ((ed (buffer-of "a\tb")))
    (goto-char 3)
    (call-with-values
        (lambda () (scan-for-column ed #f #f))
      (lambda (pos col prev-pos prev-col) (list pos col prev-pos prev-col)))))

;; ------------------------------------------------------------------
;; current-line-display-column, the renderer's one-column-at-a-time form

(test-equal "current-line-display-column agrees with current-column"
  '(0 1 3 3 3 4 5)
  (let ((ed (buffer-of "abcdef")))
    (put-text-property 2 5 'display "XY" ed)
    (map (lambda (j) (current-line-display-column ed j)) '(0 1 2 3 4 5 6))))

(test-equal "current-line-display-column over a tab and a wide character"
  '(0 1 8 9 11 12)
  ;; six columns for a five-character line: the column *after* the last
  ;; character is a column too, and it is the one `point-max' reports.
  (let ((ed (buffer-of "a\tb　c")))
    (map (lambda (j) (current-line-display-column ed j)) (iota 6))))

(test-end "schemacs_editor_indentc")
