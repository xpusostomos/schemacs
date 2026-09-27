(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor engine)
       new-text-editor text-editor-char-count text-editor-delete-from-cursor
       text-editor-insert text-editor-set-cursor text-editor-text-props)
 (only (schemacs editor intervals)
       find-interval next-interval interval-position interval-last-pos
       interval-plist)
 (prefix (schemacs editor textprop) tp:))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor textprop)', which mirrors GNU
;; Emacs's `textprop.c': the Lisp API over the interval tree.
;;
;; The tests are written the way Elisp writes them - `put-text-property',
;; then `get-text-property' to read it back - because the point of this
;; library is that those names mean here what they mean in Emacs.
;;
;; Positions are 0-based, as both libraries' headers explain: a
;; 10-character buffer is `0' to `10'.

(test-begin "schemacs_editor_textprop")

(define (buffer-of text)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed text)
    ed))

(define (runs ed)
  ;; The tree as (FIRST LAST PLIST) per run, so a test can see the shape
  ;; a change left behind.
  ;;--------------------------------------------------------------
  (let loop ((i (find-interval (text-editor-text-props ed) 0))
             (acc '()))
    (if (not i)
        (reverse acc)
        (loop (next-interval i)
              (cons (list (interval-position i)
                          (interval-last-pos i)
                          (interval-plist i))
                    acc)))))

;; A property put on a range reads back across exactly that range, and
;; not outside it - and the buffer was cut into three runs to hold it.
(test-equal '(bold bold bold #f #f)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (map (lambda (pos) (tp:get-text-property pos 'face ed))
         '(2 3 4 5 6))))

(test-equal '((0 2 ()) (2 5 (face bold)) (5 10 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (runs ed)))

;; `text-properties-at' answers the whole plist of the character there,
;; and answers none at the end of the buffer, where there is no character
;; - which is what Emacs's `(position == LENGTH (i) + i->position)'
;; check is for.
(test-equal '((face bold) () ())
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (list (tp:text-properties-at 3 ed)
          (tp:text-properties-at 6 ed)
          (tp:text-properties-at 10 ed))))

;; `add-text-properties' *merges*: a second property joins the first
;; rather than replacing the plist. That is the difference from
;; `set-text-properties', and it is the one most easily got wrong.
;; The new property is consed onto the *front* of the plist, as the C
;; does with `Fcons (sym1, Fcons (val1, i->plist))'; the order is not part
;; of what a property list means, but it is what the code produces.
(test-equal '((mouse-face highlight face bold) (mouse-face highlight))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (tp:add-text-properties 2 7 '(mouse-face highlight) ed)
    (list (tp:text-properties-at 3 ed)
          (tp:text-properties-at 6 ed))))

;; A property added again with a different value is *replaced*, not
;; duplicated - the plist keeps one entry per property.
(test-equal '(face italic)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (tp:put-text-property 3 4 'face 'italic ed)
    (tp:text-properties-at 3 ed)))

;; `set-text-properties' replaces the whole plist, so a property that was
;; there and is not in the new list goes.
;; Position 2 is the first character of the range, so it has the new
;; plist too - the range is 2..5, and 2 is inside it.
(test-equal '((face italic) (face italic))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (tp:put-text-property 2 5 'mouse-face 'highlight ed)
    (tp:set-text-properties 2 5 '(face italic) ed)
    (list (tp:text-properties-at 3 ed)
          (tp:text-properties-at 2 ed))))

;; Setting no properties at all empties the range - and the runs it left
;; collapse back into their neighbours, so the buffer is one run again.
;; The runs the change walked stay as runs - the C merges an interval
;; only into one this same set already changed (`prev_changed'), so runs
;; outside the range are untouched and remain separate. They are all
;; default intervals afterwards, which is what the empty plists say.
(test-equal '(() (0 2 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (tp:set-text-properties 2 5 '() ed)
    (list (tp:text-properties-at 3 ed)
          (car (runs ed)))))

;; `remove-text-properties' takes the named properties and leaves the
;; rest - the difference from `set-text-properties', which takes all.
;; The name list is written the way Elisp writes it - names only, no
;; values - which is an odd-length list, and the library must take it.
(test-equal '(mouse-face highlight)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (tp:put-text-property 2 5 'mouse-face 'highlight ed)
    (tp:remove-text-properties 2 5 '(face) ed)
    (tp:text-properties-at 3 ed)))

;; ...and answers whether anything was actually removed.
(test-equal '(#t #f)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (list (tp:remove-text-properties 2 5 '(face) ed)
          (tp:remove-text-properties 2 5 '(face) ed))))

;; `next-single-property-change' walks from one run to the next: from
;; inside the bold run the next change is where it ends, and past it there
;; is no further change.
(test-equal '(5 5 #f)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (list (tp:next-single-property-change 2 'face ed)
          (tp:next-single-property-change 4 'face ed)
          (tp:next-single-property-change 5 'face ed))))

;; ...and `previous-single-property-change' walks back to where the
;; current run began.
(test-equal '(2 2)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (list (tp:previous-single-property-change 4 'face ed)
          (tp:previous-single-property-change 5 'face ed))))

;; A limit is answered with rather than searched past, which is how a
;; renderer asks "does this change before the end of the line?".
(test-equal '(3 3)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (list (tp:next-single-property-change 2 'face ed 3)
          (tp:next-single-property-change 3 'face ed 3))))

;; An empty buffer has no properties and no runs: there is no character to
;; hang them on, as in Emacs.
(test-equal '(() #f)
  (let ((ed (buffer-of "")))
    (list (tp:text-properties-at 0 ed)
          (text-editor-text-props ed))))

;; A property the buffer has nowhere answers #f rather than erroring.
(test-equal #f
  (let ((ed (buffer-of "abcdefghij")))
    (tp:get-text-property 3 'face ed)))

;; The properties move with the text, because the engine calls
;; `offset-intervals' from beside `adjust-markers-for-insertion!' on every
;; insert. Text put in *before* a run carries the run along with it.
(test-equal '(4 7 (face bold))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (text-editor-set-cursor ed 0)
    (text-editor-insert ed "XY")
    (let ((i (find-interval (text-editor-text-props ed) 4)))
      (list (interval-position i) (interval-last-pos i) (interval-plist i)))))

;; ...and text deleted before a run pulls it back - the same call with a
;; negative length.
(test-equal '(0 3 (face bold))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (text-editor-set-cursor ed 0)
    (text-editor-delete-from-cursor ed 2)
    (let ((i (find-interval (text-editor-text-props ed) 1)))
      (list (interval-position i) (interval-last-pos i) (interval-plist i)))))

;; Text inserted *inside* a run takes the run's properties - the sticky
;; rule, which is what makes a `read-only' or `field' property survive an
;; edit instead of stopping at the old characters.
(test-equal '((0 2 ()) (2 8 (face bold)) (8 13 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 2 5 'face 'bold ed)
    (text-editor-set-cursor ed 4)
    (text-editor-insert ed "XYZ")
    (runs ed)))

(test-end "schemacs_editor_textprop")
