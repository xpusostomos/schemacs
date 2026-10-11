;; Tests for `(schemacs editor marker)' - GNU Emacs's `marker.c', and the
;; two constructors that are `alloc.c`'s.
;;
;; The expectations are what a real Emacs reports for the same
;; operations (`emacs -Q --batch`, checked one by one), which is the only
;; way to be sure the boundary rules - what text inserted *at* a marker
;; does, what a deletion does to the markers inside it - are the same
;; ones. They moved here from `engine-tests.scm` with the functions.
;;
;; **The buffer is passed and not made current**, so the tests call
;; `build-marker` - the C's door when it has a buffer in hand
;; (`alloc.c:3801`) - rather than `copy-marker`, which acts on the
;; current buffer because Lisp has nothing else to pass. Both are tested,
;; and `with-current-buffer' is what the Lisp one needs.
;;-------------------------------------------------------------
(import
 (scheme base)
 (schemacs editor marker)
 (only (schemacs editor buffer) allocate-buffer with-current-buffer current-buffer)
 (only (schemacs editor engine)
       text-editor-insert text-editor-to-string text-editor-set-cursor
       text-editor-move-cursor text-editor-delete-from-cursor
       text-editor-undo-boundary! text-editor-undo-list)
 (only (schemacs editor simple) primitive-undo)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

(test-begin "schemacs_editor_marker")

;; A marker made with no buffer points nowhere, and reports nowhere.
(test-equal '(#f #f #t)
  (let ((m (make-marker)))
    (list (marker-position m) (marker-buffer m) (markerp m))))

;; A marker at index 3 of "abcdef" reports that, and its buffer.
(test-equal '(3 #t)
  (let* ((ed (allocate-buffer))
         (m (begin (text-editor-insert ed "abcdef") (build-marker ed 3))))
    (list (marker-position m) (eq? ed (marker-buffer m)))))

;; Text inserted BEFORE a marker carries it along: Emacs: a marker at 3
;; with "XY" inserted at 1 is at 5.
(test-equal 5
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 3)))
      (text-editor-set-cursor ed 1)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Text inserted AFTER a marker leaves it alone.
(test-equal 3
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 3)))
      (text-editor-move-cursor ed 100)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Text inserted EXACTLY at a marker is the boundary case: the default
;; marker (insertion type false) stays put and the text lands after it -
;; Emacs: a marker at 3, "XY" inserted at 3, is still at 3 in "abXYcd".
(test-equal '(3 "abXYcd")
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcd")
    (let ((m (build-marker ed 3)))
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed "XY")
      (list (marker-position m) (text-editor-to-string ed)))))

;; ... and one whose insertion type is true advances past it: Emacs: the
;; same case gives 5.
(test-equal 5
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcd")
    (let ((m (build-marker ed 3)))
      ;; the insertion type is a second call, as it is in the C
      (set-marker-insertion-type m #t)
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Deletion does not shift markers, it collapses the ones inside the
;; deleted text to its start: Emacs: delete the three characters from
;; position 2 of "abcdef" with a marker at 4 leaves "aef" and the marker
;; collapsed to 2.
(test-equal '(2 "aef")
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 4)))
      (text-editor-set-cursor ed 2)
      (text-editor-delete-from-cursor ed 3)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A marker after the deleted text moves back by its length; one at the
;; far end of it does too.
(test-equal '(2 3)
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((at-end (build-marker ed 5)) (after (build-marker ed 6)))
      (text-editor-set-cursor ed 2)
      (text-editor-delete-from-cursor ed 3)
      (list (marker-position at-end) (marker-position after)))))

;; Deleting backwards takes the text before the cursor: Emacs: "abcdef"
;; with point at 5 and `(delete-char -2)' is "abef" with the marker that
;; was at 4 collapsed to 3.
(test-equal '(3 "abef")
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 4)))
      (text-editor-set-cursor ed 5)
      (text-editor-delete-from-cursor ed -2)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A backwards deletion at the very end of a buffer, which is a position
;; the engine used to get wrong (see the note in
;; `SCHEMACS_EDITOR_ENGINE_END_OF_BUFFER'): the markers inside the
;; deleted text collapse to where it began, and the buffer loses exactly
;; the two characters asked for.
(test-equal '(5 "abcd")
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 5)))
      (text-editor-set-cursor ed 7)
      (text-editor-delete-from-cursor ed -2)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A marker that points nowhere is in no chain and follows nothing.
(test-equal #f
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 3)))
      (set-marker m #f)
      (text-editor-set-cursor ed 1)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Markers belong to a buffer: editing one leaves another's alone.
(test-equal '(3 5)
  (let* ((one (allocate-buffer))
         (two (allocate-buffer)))
    (text-editor-insert one "abcdef")
    (text-editor-insert two "abcdef")
    (let ((m1 (build-marker one 3)) (m2 (build-marker two 3)))
      (text-editor-set-cursor two 1)
      (text-editor-insert two "XY")
      (list (marker-position m1) (marker-position m2)))))

;; A line break is text too: a marker after it moves with it.
(test-equal '(6 "ab\ncd")
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcd")
    (let ((m (build-marker ed 5)))
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed #\newline)
      (list (marker-position m) (text-editor-to-string ed)))))

;; Undo replays through the same insert and delete procedures, so it
;; adjusts markers too: an insertion undone puts the marker back where
;; it was.
(test-equal '(3 5 3)
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    ;; A boundary, as the command loop places one between commands, so
    ;; that undoing takes back the insertion below and not this one too.
    (text-editor-undo-boundary! ed)
    (let ((m (build-marker ed 3)))
      (let ((before (marker-position m)))
        (text-editor-set-cursor ed 1)
        (text-editor-insert ed "XY")
        (let ((after (marker-position m)))
          (with-current-buffer ed (primitive-undo 1 (text-editor-undo-list ed)))
          (list before after (marker-position m)))))))
;; ------------------------------------------------------------------
;; copy-marker: the Lisp door, and its three argument forms

;; "(copy-marker)" points nowhere, as `make-marker' does.
(test-equal '(#f #f)
  (let ((m (copy-marker)))
    (list (marker-position m) (marker-buffer m))))

;; Given a *number*, it makes a marker at that position **in the current
;; buffer** - which is what Emacs documents, and the reason the tests
;; above pass a buffer to `build-marker' instead.
(test-equal '(4 #t)
  (with-current-buffer (allocate-buffer)
    (text-editor-insert (current-buffer) "abcdef")
    (let ((m (copy-marker 4)))
      (list (marker-position m) (eq? (current-buffer) (marker-buffer m))))))

;; Given a *marker*, it points where that one does, in that one's buffer.
(test-equal '(2 #t #f)
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let* ((from (build-marker ed 2))
           (copy (copy-marker from)))
      (list (marker-position copy)
            (eq? ed (marker-buffer copy))
            ;; a new one, not the same object
            (eq? from copy)))))

;; The second argument is the insertion type, and it is the *new*
;; marker's - the source's is left alone.
(test-equal '(#t #f #f)
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let* ((from (build-marker ed 2))
           (copy (copy-marker from #t)))
      (list (marker-insertion-type copy)
            (marker-insertion-type from)
            (marker-position (copy-marker))))))

;; ------------------------------------------------------------------
;; set-marker: the position, the buffer, and pointing nowhere

;; An integer position with an explicit buffer - the C's
;; `set_marker_both' with the bytepos dropped, which is what
;; `set_window_buffer' uses.
(test-equal 4
  (let ((m (make-marker))
        (ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (set-marker m 4 ed)
    (marker-position m)))

;; A position past the end is brought to the end, as `clip_to_bounds'
;; does - "a position outside the buffer is brought to the nearer end
;; rather than refused".
(test-equal '(7 1)
  (let ((m (make-marker))
        (ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (set-marker m 99 ed)
    (let ((high (marker-position m)))
      (set-marker m 0 ed)
      (list high (marker-position m)))))

;; Given a marker, the position is copied from it - and with no buffer
;; argument the *current* buffer is the one meant, as Emacs says.
(test-equal 3
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((from (build-marker ed 3))
          (to (make-marker)))
      (with-current-buffer ed (set-marker to from))
      (marker-position to))))

;; Pointing a marker nowhere takes it out of the buffer's chain, and its
;; last position is still answerable.
(test-equal '(#f 3 #f)
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 3)))
      (list (begin (set-marker m #f) (marker-position m))
            (marker-last-position m)
            (marker-buffer m)))))

;; `detach-marker' is `set-marker' with nowhere and no buffer.
(test-equal #f
  (let* ((ed (allocate-buffer)))
    (text-editor-insert ed "abcdef")
    (let ((m (build-marker ed 3)))
      (detach-marker m)
      (marker-position m))))

;; `marker-insertion-type' answers what the setter was given, and the
;; setter answers its own argument - the C returns TYPE, not the marker.
(test-equal '(#f #t #t)
  (let ((m (make-marker)))
    (let ((before (marker-insertion-type m)))
      (list before
            (set-marker-insertion-type m #t)
            (marker-insertion-type m)))))

;; `markers-in' lists the markers of the *current* buffer in a range,
;; including markers at both ends.
(test-equal 2
  (with-current-buffer (allocate-buffer)
    (text-editor-insert (current-buffer) "abcdef")
    ;; the markers are held, or the chain - which holds them weakly, as
    ;; Emacs's does - would be free to collect them before the question
    (let ((two (build-marker (current-buffer) 2))
          (three (build-marker (current-buffer) 3))
          (six (build-marker (current-buffer) 6)))
      (length (markers-in 2 3)))))

(test-end "schemacs_editor_marker")
