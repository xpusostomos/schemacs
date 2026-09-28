(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine)
       new-text-editor text-editor-insert text-editor-char-count
       text-editor-set-cursor
       text-editor-text-props text-editor-to-string)
 (prefix (schemacs editor intervals) iv:))

;; Regression tests for `(schemacs editor intervals)', which mirrors GNU
;; Emacs's `intervals.c': the tree that holds text properties.
;;
;; The tests build trees by hand out of the same primitives that
;; `textprop.c' uses, because that is what the library is for - the Lisp
;; API over it is a separate library, and testing through that would not
;; tell a broken `split_interval_right' from a broken `put-text-property'.
;;
;; Positions are 0-based here, as the library's header explains, so a
;; 10-character buffer is `0' to `10' and not `1' to `11'.

;; Unbuffered output: srfi-64 writes as it goes, but a redirected stdout is
;; block-buffered, so a run that hangs shows nothing at all and the hang
;; cannot be located. (Found the hard way.)
(import (only (guile) setvbuf))
(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_intervals")

(define (editor-of text)
  ;; A buffer holding TEXT, with a root interval covering it, and the
  ;; tree stored on the buffer as Emacs stores it.
  ;;--------------------------------------------------------------
  (let ((ed (new-text-editor)))
    (text-editor-insert ed text)
    (iv:create-root-interval ed)
    ed))

(define (tree-of ed)
  ;; The current root. A split can change which node that is - a rotation
  ;; during balancing may make the new interval the root - so a test must
  ;; ask the buffer again rather than hold on to a node it split.
  ;;--------------------------------------------------------------
  (text-editor-text-props ed))

(define (intervals-of ed)
  ;; The tree as a list of (FIRST LAST PLIST), a form the tests can read.
  ;;--------------------------------------------------------------
  (let loop ((i (iv:find-interval (tree-of ed) 0))
             (acc '()))
    (if (not i)
        (reverse acc)
        (loop (iv:next-interval i)
              (cons (list (iv:interval-position i)
                          (iv:interval-last-pos i)
                          (iv:interval-plist i))
                    acc)))))

;; A fresh buffer's tree is one interval covering everything, with no
;; properties - GNU Emacs's `create_root_interval'.
(test-equal '(#t (0 10 ()))
  (let ((ed (editor-of "abcdefghij")))
    (list (eq? (text-editor-text-props ed)
               (iv:find-interval (tree-of ed) 0))
          (car (intervals-of ed)))))

;; `find_interval' answers with the interval containing a position, and
;; a position at the very end gives the interval holding the last
;; character, not nothing - which is what `text-properties-at' relies on
;; to answer nil at the end.
(test-equal '(0 0 0 0 0)
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed)))
    (map (lambda (pos) (iv:interval-position (iv:find-interval tree pos)))
         '(0 1 5 9 10))))

;; Splitting the root at 2 leaves an interval starting at 2, and the tree
;; still describes every character exactly once: `total-length' is the
;; buffer's length and the intervals tile it.
(test-equal (list 10 '((0 2 ()) (2 10 ())))
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (list (iv:interval-total-length (tree-of ed)) (intervals-of ed))))

;; Splitting that piece at 3 more gives the middle run 2..5, which is the
;; shape `put-text-property' builds: the run gets the properties and the
;; two ends keep none.
(test-equal '((0 2 ()) (2 5 (face bold)) (5 10 ()))
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (let ((middle (iv:split-interval-left rest 3)))
      ;; `split_interval_left' leaves the new interval with no
      ;; properties, which is what the C promises its caller - so only
      ;; the run the property is meant for is given one here.
      (iv:set!interval-plist middle '(face bold))
      (intervals-of ed))))

;; `next_interval' and `previous_interval' walk the runs in order, and
;; the tree's own shape does not change what they answer - that is the
;; point of the position cache they maintain.
(test-equal '(0 2 5)
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (let* ((middle (iv:split-interval-left rest 3))
           (first (iv:find-interval (tree-of ed) 0)))
      (list (iv:interval-position first)
            (iv:interval-position (iv:next-interval first))
            (iv:interval-position (iv:next-interval (iv:next-interval first)))))))

(test-equal '((2 5 ()) (0 2 ()) #f)
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (let* ((middle (iv:split-interval-left rest 3))
           (last (iv:find-interval (tree-of ed) 7)))
      (list (list (iv:interval-position (iv:previous-interval last))
                  (iv:interval-last-pos (iv:previous-interval last))
                  (iv:interval-plist (iv:previous-interval last)))
            (list (iv:interval-position
                   (iv:previous-interval (iv:previous-interval last)))
                  (iv:interval-last-pos
                   (iv:previous-interval (iv:previous-interval last)))
                  (iv:interval-plist
                   (iv:previous-interval (iv:previous-interval last))))
            (iv:previous-interval
             (iv:previous-interval (iv:previous-interval last)))))))

;; Inserting text in the middle of a run extends that run, which is what
;; `offset_intervals' with a positive length does: the run that held
;; 2..5 now holds 2..8, and the runs after it shift along.
;;
;; The new text *keeps* the run's properties - the C's
;; `adjust_intervals_for_insertion' simply grows the interval it landed
;; in, unless the sticky rules say otherwise. That is what makes inserted
;; text inherit from its neighbours, and it is the rule that `field'
;; properties in the minibuffer and `read-only' properties on text
;; depend on.
(test-equal '((0 2 ()) (2 8 (face bold)) (8 13 ()))
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (let ((middle (iv:split-interval-left rest 3)))
      (iv:set!interval-plist middle '(face bold))
      ;; three characters inserted at 4, inside the bold run
      (iv:offset-intervals ed 4 3)
      (intervals-of ed))))

;; Deleting takes characters off the run they were in, and a run emptied
;; by it leaves the tree.
(test-equal '((0 2 ()) (2 5 (face bold)) (5 7 ()))
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed))
         (rest (iv:split-interval-right tree 2)))
    (iv:copy-properties tree rest)
    (let ((middle (iv:split-interval-left rest 3)))
      (iv:set!interval-plist middle '(face bold))
      ;; three characters deleted at 7, off the end of the bold run
      (iv:offset-intervals ed 7 -3)
      (intervals-of ed))))

;; The whole tree vanishes when the last character goes, as it does in the
;; C (`adjust_intervals_for_deletion' on a full-length deletion).
(test-equal #f
  (let ((ed (editor-of "abcdefghij")))
    (iv:offset-intervals ed 0 -10)
    (text-editor-text-props ed)))

;; `interval_deletion_adjustment' answers how much it really deleted, and
;; clamps to what the interval it landed in had left.
(test-equal 3
  (let* ((ed (editor-of "abcdefghij"))
         (tree (text-editor-text-props ed)))
    (iv:interval-deletion-adjustment tree 2 3)))

;; `merge_properties_sticky': text inserted between two runs inherits from
;; the left unless the left is `rear-nonsticky' for that property.
(test-equal '(face bold)
  (iv:merge-properties-sticky '(face bold) '()))

;; ...with `rear-nonsticky' on the left stopping it, so nothing comes
;; through at all.
(test-equal '()
  (iv:merge-properties-sticky '(face bold rear-nonsticky (face)) '()))

;; ...and from the right when the right is `front-sticky' for it. The
;; `front-sticky' entry the right carries is inherited too, which is what
;; the C's last step adds whenever there is no `category' to say it more
;; compactly.
(test-equal '(front-sticky (face) face italic)
  (iv:merge-properties-sticky '()
                              '(face italic front-sticky (face))))

;; The sticky properties themselves are not inherited as ordinary
;; properties; only the stickiness they describe is.
(test-equal '(front-sticky (face) face bold)
  (iv:merge-properties-sticky '(face bold front-sticky (face)) '()))

(test-end "schemacs_editor_intervals")


;;--------------------------------------------------------------------
;; Inserting at the very beginning of a buffer that has properties
;;
;; `adjust_intervals_for_insertion' grows every interval above the
;; insertion point and *then*, once, works out what the new text's
;; properties are by merging the runs either side of it. The merge - and
;; the split it may ask for - was nested inside the growing walk, so it
;; ran once per ancestor instead of once: at position 0 of a tree two
;; levels deep it ran twice, and the second time split the interval that
;; the first split had already moved, leaving it with a negative length
;; and a position past the end of the buffer. The tree came apart
;; silently; the next thing to read it walked off the end and reported
;; "Wrong type argument in position 1 (expecting struct): #f".
;;
;; The tree below is the shape the `*Completions*' buffer has when its
;; help lines are inserted at `point-min', which is where this was found:
;; the run at the front carries a property of its own, and it is not the
;; root.

(test-begin "schemacs_editor_intervals_insert_at_beginning")

(define (valid-tree? ed)
  ;; Every interval's total is its own length plus its two subtrees', and
  ;; no length is negative - the two things Emacs's `check_interval_tree'
  ;; asserts.
  ;;--------------------------------------------------------------
  (define (sub i get)
    (let ((x (get i))) (if (iv:interval-type? x) (iv:interval-total-length x) 0)))
  (define (walk i)
    (or (not (iv:interval-type? i))
        (and (<= 0 (iv:interval-length i))
             (= (iv:interval-total-length i)
                (+ (iv:interval-length i)
                   (sub i iv:interval-left)
                   (sub i iv:interval-right)))
             (walk (iv:interval-left i))
             (walk (iv:interval-right i)))))
  (walk (tree-of ed)))

;; A twenty-character buffer whose tree is two runs, the left one carrying
;; a property and hanging below the root - so the growing walk has two
;; steps, which is what the bug needed.
(define (two-run-editor)
  (let* ((ed (editor-of "abcdefghij0123456789"))
         ;; `(make<interval> TOTAL-LENGTH POSITION LEFT RIGHT UP PLIST)'
         (head (iv:make<interval> 10 0 #f #f #f '(face shadow)))
         (root (iv:make<interval> 20 10 head #f #f '())))
    (iv:set!interval-up head root)
    (iv:set!interval-up root ed)
    (iv:set!buffer-intervals ed root)
    ed))

;; The tree as built, before the insertion: two runs, 0..10 and 10..20.
(test-equal '((0 10 (face shadow)) (10 20 ()))
  (intervals-of (two-run-editor)))

;; ...and after inserting five characters at the front: the text is
;; longer, the tree still adds up, and it is still a tree. The runs are
;; what the bug moved: the property run was split into pieces with a
;; *zero-length* interval among them - `(5 10 ()) (10 15 ()) (15 15
;; (face shadow))' - while the text came out right, which is what made it
;; silent. The five new characters take no properties, which is what
;; `merge_properties_sticky' answers for an insertion with nothing on its
;; left (`face' is not front-sticky, so it is not inherited forwards).
(test-equal '(#t 25 25 ((0 5 ()) (5 15 (face shadow)) (15 25 ()))
              "HELLOabcdefghij0123456789")
  (let ((ed (two-run-editor)))
    (text-editor-set-cursor ed 0)
    (text-editor-insert ed "HELLO")
    (list (valid-tree? ed)
          (iv:interval-total-length (tree-of ed))
          (text-editor-char-count ed)
          (intervals-of ed)
          (text-editor-to-string ed))))

(test-end "schemacs_editor_intervals_insert_at_beginning")
