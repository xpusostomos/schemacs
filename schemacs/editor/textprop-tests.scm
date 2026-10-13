(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor engine)
       allocate-buffer buffer-beg buffer-z text-editor-delete-from-cursor
text-editor-set-cursor text-editor-text-props)
 (only (schemacs editor intervals)
       find-interval next-interval interval-position interval-last-pos
       interval-total-length
       interval-plist string-intervals)
 (only (schemacs editor buffer)
       *inhibit-read-only* erase-buffer get-buffer-create set-buffer
       set!buffer-read-only set-buffer-modified-p text-editor-undo-list with-current-buffer
)
 ;; the `(t . TOKEN)' entry `record_first_change' pushes is read back with
 ;; `undo.c`'s own predicate for it.
 (only (schemacs editor undo) undo-modified-entry?)
 (only (schemacs editor editfns)
       buffer-substring buffer-substring-no-properties insert insert-and-inherit
       propertize)
 (only (schemacs editor fns) concat copy-sequence)
 (prefix (schemacs editor textprop) tp:)
 (only (ice-9 exceptions) exception-message))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor textprop)', which mirrors GNU
;; Emacs's `textprop.c': the Lisp API over the interval tree.
;;
;; The tests are written the way Elisp writes them - `put-text-property',
;; then `get-text-property' to read it back - because the point of this
;; library is that those names mean here what they mean in Emacs.
;;
;; Positions are Emacs's: one-based, and a 10-character buffer is
;; `1' to `11', with `point-max' at 11. Strings keep their own
;; zero-based offsets, as Emacs's do.

(test-begin "schemacs_editor_textprop")

(define (buffer-of text)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert text))
    ed))

(define (runs ed)
  ;; The tree as (FIRST LAST PLIST) per run, so a test can see the shape
  ;; a change left behind.
  ;;--------------------------------------------------------------
  (let loop ((i (find-interval (text-editor-text-props ed) 1))
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
    (tp:put-text-property 3 6 'face 'bold ed)
    (map (lambda (pos) (tp:get-text-property pos 'face ed))
         '(3 4 5 6 7))))

(test-equal '((1 3 ()) (3 6 (face bold)) (6 11 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (runs ed)))

;; `text-properties-at' answers the whole plist of the character there,
;; and answers none at the end of the buffer, where there is no character
;; - which is what Emacs's `(position == LENGTH (i) + i->position)'
;; check is for.
(test-equal '((face bold) () ())
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (list (tp:text-properties-at 4 ed)
          (tp:text-properties-at 7 ed)
          (tp:text-properties-at 11 ed))))

;; `add-text-properties' *merges*: a second property joins the first
;; rather than replacing the plist. That is the difference from
;; `set-text-properties', and it is the one most easily got wrong.
;; The new property is consed onto the *front* of the plist, as the C
;; does with `Fcons (sym1, Fcons (val1, i->plist))'; the order is not part
;; of what a property list means, but it is what the code produces.
(test-equal '((mouse-face highlight face bold) (mouse-face highlight))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:add-text-properties 3 8 '(mouse-face highlight) ed)
    (list (tp:text-properties-at 4 ed)
          (tp:text-properties-at 7 ed))))

;; A property added again with a different value is *replaced*, not
;; duplicated - the plist keeps one entry per property.
(test-equal '(face italic)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:put-text-property 4 5 'face 'italic ed)
    (tp:text-properties-at 4 ed)))

;; `set-text-properties' replaces the whole plist, so a property that was
;; there and is not in the new list goes.
;; Position 2 is the first character of the range, so it has the new
;; plist too - the range is 2..5, and 2 is inside it.
(test-equal '((face italic) (face italic))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:put-text-property 3 6 'mouse-face 'highlight ed)
    (tp:set-text-properties 3 6 '(face italic) ed)
    (list (tp:text-properties-at 4 ed)
          (tp:text-properties-at 3 ed))))

;; Setting no properties at all empties the range - and the runs it left
;; collapse back into their neighbours, so the buffer is one run again.
;; The runs the change walked stay as runs - the C merges an interval
;; only into one this same set already changed (`prev_changed'), so runs
;; outside the range are untouched and remain separate. They are all
;; default intervals afterwards, which is what the empty plists say.
(test-equal '(() (1 3 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:set-text-properties 3 6 '() ed)
    (list (tp:text-properties-at 4 ed)
          (car (runs ed)))))

;; `remove-text-properties' takes the named properties and leaves the
;; rest - the difference from `set-text-properties', which takes all.
;; The name list is written the way Elisp writes it - names only, no
;; values - which is an odd-length list, and the library must take it.
(test-equal '(mouse-face highlight)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:put-text-property 3 6 'mouse-face 'highlight ed)
    (tp:remove-text-properties 3 6 '(face) ed)
    (tp:text-properties-at 4 ed)))

;; ...and answers whether anything was actually removed.
(test-equal '(#t #f)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (list (tp:remove-text-properties 3 6 '(face) ed)
          (tp:remove-text-properties 3 6 '(face) ed))))

;; `next-single-property-change' walks from one run to the next: from
;; inside the bold run the next change is where it ends, and past it there
;; is no further change.
(test-equal '(6 6 #f)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (list (tp:next-single-property-change 3 'face ed)
          (tp:next-single-property-change 5 'face ed)
          (tp:next-single-property-change 6 'face ed))))

;; ...and `previous-single-property-change' walks back to where the
;; current run began.
(test-equal '(3 3)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (list (tp:previous-single-property-change 5 'face ed)
          (tp:previous-single-property-change 6 'face ed))))

;; A limit is answered with rather than searched past, which is how a
;; renderer asks "does this change before the end of the line?".
(test-equal '(4 4)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (list (tp:next-single-property-change 3 'face ed 4)
          (tp:next-single-property-change 4 'face ed 4))))

;; An empty buffer has no properties and no runs: there is no character to
;; hang them on, as in Emacs.
(test-equal '(() #f)
  (let ((ed (buffer-of "")))
    (list (tp:text-properties-at 1 ed)
          (text-editor-text-props ed))))

;; A property the buffer has nowhere answers #f rather than erroring.
(test-equal #f
  (let ((ed (buffer-of "abcdefghij")))
    (tp:get-text-property 4 'face ed)))

;; The properties move with the text, because the engine calls
;; `offset-intervals' from beside `adjust-markers-for-insertion!' on every
;; insert. Text put in *before* a run carries the run along with it.
(test-equal '(5 8 (face bold))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (text-editor-set-cursor ed 1)
    (with-current-buffer ed (insert "XY"))
    (let ((i (find-interval (text-editor-text-props ed) 5)))
      (list (interval-position i) (interval-last-pos i) (interval-plist i)))))

;; ...and text deleted before a run pulls it back - the same call with a
;; negative length.
(test-equal '(1 4 (face bold))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (text-editor-set-cursor ed 1)
    (text-editor-delete-from-cursor ed 2)
    (let ((i (find-interval (text-editor-text-props ed) 2)))
      (list (interval-position i) (interval-last-pos i) (interval-plist i)))))

;; Text inserted *inside* a run with plain `insert` **does not** take the
;; run's properties. It does not stop at the old characters either - the
;; run is still one interval on each side of the insertion - but the new
;; text itself comes out bare, because `insert` is
;; `general_insert_function` with `inherit` false, which reaches
;; `graft_intervals_into_buffer`'s `!source` branch and *clears* the new
;; range (`set_text_properties_1` with Qnil).
;;
;; Measured, `emacs -Q --batch`, on exactly this text and this insertion:
;;   (with-temp-buffer (insert "abcdefghij")
;;     (put-text-property 3 6 'face 'bold)
;;     (goto-char 4) (insert "XYZ") ...)
;;   => (1 3 nil) (3 4 bold) (4 7 nil) (7 9 bold) (9 14 nil)
;;
;; This test used to expect the sticky answer below, which was *this
;; tree's* behaviour and not Emacs's - a passing test pinning the
;; departure. It became visible when `insert` was put onto
;; `insert_from_string` with the inherit flag carried through.
(test-equal '((1 3 ()) (3 4 (face bold)) (4 7 ()) (7 9 (face bold)) (9 14 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (set-buffer ed)
    (text-editor-set-cursor ed 4)
    (insert "XYZ")
    (runs ed)))

;; ...and `insert-and-inherit`, the same call with the flag on, is the
;; sticky rule: the run grows across the new text and one interval covers
;; all of it. Emacs's answer for the same three lines with
;; `insert-and-inherit` is `(1 3 nil) (3 9 bold) (9 14 nil)`.
(test-equal '((1 3 ()) (3 9 (face bold)) (9 14 ()))
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (set-buffer ed)
    (text-editor-set-cursor ed 4)
    (insert-and-inherit "XYZ")
    (runs ed)))

;; The tree still covers the buffer after an insertion whose new text is
;; *cleared*.
;;
;; `graft_intervals_into_buffer`'s no-source branch does two things when
;; `inherit` is false: it clears the new range - `set_text_properties_1`,
;; which **splits the root** when the range begins inside it - and then
;; balances the tree. It balanced the tree the function had read at its
;; top rather than the buffer's current root, so the buffer was left
;; pointing at an *interior* interval and every interval outside that
;; subtree was silently discarded.
;;
;; Measured before the fix: a 146-character buffer whose root interval was
;; 41 characters, and the next whole-buffer delete of it never terminated
;; (`adjust_intervals_for_deletion` cannot make progress against a tree
;; that does not cover the text). That is a hang, not a wrong answer, so
;; what this test pins is the invariant that was violated: the root's
;; total is the buffer's length, and the runs tile it end to end.
;; (buffer-length root-total first-run-start last-run-end): the last is
;; `point-max', so the runs tile the buffer exactly, and the second equals
;; the first when the tree covers it.
(test-equal '(13 13 1 14)
  (let ((ed (buffer-of "abcdefghij")))
    (tp:put-text-property 3 6 'face 'bold ed)
    (tp:put-text-property 7 9 'face 'italic ed)
    (set-buffer ed)
    ;; position 2 and not 1: the clear then begins *inside* the root, which
    ;; is what makes `set_text_properties_1` split it - the case that was
    ;; broken. An insert at `point-min` alone does not split the root.
    (text-editor-set-cursor ed 2)
    (insert "XYZ")
    (let* ((len (- (buffer-z ed) (buffer-beg ed)))
           (root (text-editor-text-props ed))
           (rs (runs ed)))
      (list len
            (interval-total-length root)
            ;; the runs tile 1..len+1 with no gap and no overlap: the first
            ;; starts at 1 and the last ends at `point-max'
            (car (car rs))
            (cadr (car (reverse rs)))))))

;; ------------------------------------------------------------------
;; properties on a *string*
;;
;; A propertized string is still a string - the tree lives in a Guile
;; object property, keyed by the string's identity - so all the string
;; functions go on working, which is the point of doing it that way.
;; What follows is Emacs's behaviour, measured with `emacs -Q --batch'
;; for the same calls: `copy-sequence', `concat', `insert' and
;; `buffer-substring' all carry properties, and a string that merely
;; looks the same does not have them.

(define (pstr)
  (propertize "abcdef" 'face 'bold))

(test-equal "a propertized string is a string"
  '(6 "abcdef")
  (list (string-length (pstr)) (string-copy (pstr))))

(test-equal "and carries the property, at every character of it"
  '(bold bold (face bold))       ; `get-text-property' answers the value
  (let ((s (pstr)))
    (list (tp:get-text-property 0 'face s)
          (tp:get-text-property 3 'face s)
          (tp:text-properties-at 5 s))))

(test-equal "past the last character there is no property"
  #f
  (tp:get-text-property 6 'face (pstr)))

;; the key is the *object*, not the text: Emacs's properties are on the
;; string, not on the characters, and this is that same fact
(test-equal "a string that only looks the same has none"
  #f
  (tp:get-text-property 0 'face "abcdef"))

(test-equal "and neither is a copy, until something copies them"
  #f
  (string-intervals (string-copy (pstr))))

;; "the elements ... are shared" is the C's note for lists and vectors;
;; for a string it copies the properties, which is `copy_intervals'
(test-equal '(#t bold)
  (let ((c (copy-sequence (pstr))))
    (list (string? c) (tp:get-text-property 0 'face c))))

;; "an unknown property is simply not there", and `text-properties-at'
;; of a plain string is the empty list
(test-equal '(() #f)
  (list (tp:text-properties-at 0 "abc") (tp:get-text-property 0 'face "abc")))

;; ------------------------------------------------------------------
;; concat, which is how a property survives being built into a line

(test-equal "properties ride through concat at the offsets they went in at"
  '(#f bold #f)
  (let ((c (concat "ab" (pstr) "yz")))
    (list (tp:get-text-property 0 'face c)
          (tp:get-text-property 2 'face c)
          (tp:get-text-property 8 'face c))))

(test-equal "and the result is a string of the whole length"
  10
  (string-length (concat "ab" (pstr) "yz")))

(test-equal "a concat of plain strings has no properties at all"
  '(() "abc")
  (list (tp:text-properties-at 0 (concat "a" "b" "c")) (concat "a" "b" "c")))

(test-equal "and the argument forms `concat' takes"
  '("ab" "" "ab")
  (list (concat (list #\a) "" "b") (concat) (concat '(#\a) "b")))

;; ------------------------------------------------------------------
;; the round trip through a buffer

(define (fresh-buffer name)
  ;; A buffer per test: `insert' appends, so a shared one would carry the
  ;; previous test's text into the next.
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create name)))
    (set-buffer ed)
    (erase-buffer)
    ed))

(test-equal "insert grafts a string's properties into the buffer"
  '("abcdef" bold bold)
  (let ((ed (fresh-buffer "*textprop-string-tests*")))
    (insert (pstr))
    (list (buffer-substring-no-properties 1 7)
          (tp:get-text-property 1 'face)
          (tp:get-text-property 6 'face))))

(test-equal "and buffer-substring carries them back out"
  (list "abcdef" '(face bold))
  (let ((ed (fresh-buffer "*textprop-string-tests*")))
    (insert (pstr))
    (let ((out (buffer-substring 1 7)))
      (list out (tp:text-properties-at 0 out)))))

(test-equal "which buffer-substring-no-properties does not"
  #f
  (let ((ed (fresh-buffer "*textprop-string-tests*")))
    (insert (pstr))
    (tp:get-text-property 0 'face (buffer-substring-no-properties 1 7))))

;; a string inserted after propertized text does not take its properties:
;; `insert' passes `inherit' false, which is `general_insert_function''s 0
(test-equal "plain text inserted beside it stays plain"
  '((face bold) ())   ; `text-properties-at' answers the plist
  (let ((ed (fresh-buffer "*textprop-string-tests*")))
    (insert (pstr))
    (insert "xyz")
    (list (tp:text-properties-at 1 ed) (tp:text-properties-at 7 ed))))

;; ------------------------------------------------------------------
;; `add-text-properties' adds *all* of a plist
;;
;; `interval-has-all-properties' answered after the first property - "I
;; have this one" - instead of checking every one, so
;; `add-text-properties-1' decided the interval needed no change and
;; added nothing. Every multi-property plist whose first property was
;; already present went missing, which is how dired names ended up
;; carrying no `mouse-face': ls-lisp had already put `dired-filename' on
;; them, and `dired-filename' is the first property dired adds.

(test-equal '(#t highlight "here")
  (let ((ed (fresh-buffer "*textprop-add-all*")))
    (insert "abc")
    ;; the first property alone, as ls-lisp leaves the name
    (tp:put-text-property 1 4 'dired-filename #t ed)
    ;; then the plist whose *first* property is already there
    (tp:add-text-properties 1 4 (list 'dired-filename #t
                                      'mouse-face 'highlight
                                      'help-echo "here")
                            ed)
    (list (tp:get-text-property 1 'dired-filename ed)
          (tp:get-text-property 1 'mouse-face ed)
          (tp:get-text-property 1 'help-echo ed))))

;; and the guard still holds: a plist that really is all present is left
;; alone rather than rewritten - the values in PLIST win when they differ
(test-equal '(#t other)
  (let ((ed (fresh-buffer "*textprop-add-guard*")))
    (insert "abc")
    (tp:put-text-property 1 4 'a #t ed)
    (tp:put-text-property 1 4 'b 'old ed)
    (tp:add-text-properties 1 4 (list 'a #t 'b 'other) ed)
    (list (tp:get-text-property 1 'a ed)
          (tp:get-text-property 1 'b ed))))


;; `remove-text-properties' over a range that begins *before* the
;; property: GNU Emacs's `Fremove_text_properties' walks to the first
;; interval that has something and removes from there. Without that walk
;; the function answered #t and changed nothing, which is what
;; `dired-fontify-line''s line-wide removal hit - it clears a whole line
;; and the face sits on the file name in the middle of it.
(test-equal "remove-text-properties: the range may begin before the property"
  (list #f #f)
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert "abcdefghij")
    (tp:put-text-property 7 9 'face 'zz ed)
    (tp:remove-text-properties 1 11 '(face) ed)
    (list (tp:get-text-property 7 'face ed)
          (tp:get-text-property 8 'face ed))))

(test-equal "remove-text-properties: a range that ends inside the property"
  (list #f 'zz)
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert "abcdefghij")
    (tp:put-text-property 7 9 'face 'zz ed)
    (tp:remove-text-properties 1 8 '(face) ed)
    (list (tp:get-text-property 7 'face ed)
          (tp:get-text-property 8 'face ed))))

;; ------------------------------------------------------------------
;; `modify_text_properties' - the read-only gate
;;
;; A property write goes through `prepare_to_modify_buffer_1` and so
;; consults the buffer's read-only flag, exactly as Emacs's does.
;; Measured on Emacs 31.1: `put-text-property` on a read-only buffer
;; signals `(buffer-read-only #<buffer>)`, and is allowed when
;; `inhibit-read-only` is bound to t. Both halves are here because the
;; first alone would be indistinguishable from "property writes are
;; broken".
;;
;; **This gate is load-bearing for font-lock**, which fontifies read-only
;; buffers - dired's among them - through `with-silent-modifications`
;; (`subr.el:5473`), whose `inhibit-read-only` binding is what lets them.
;; Before 2026-10-12 the property layer consulted nothing, so none of this
;; could fail; `font-lock-tests.scm` and `dired-mode-tests.scm` are what
;; caught it when it could.

(test-equal "put-text-property on a read-only buffer signals"
  "Buffer is read-only"
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert "abcdefghij")
    (set!buffer-read-only ed #t)
    (guard (e (#t (exception-message e)))
      (tp:put-text-property 1 3 'face 'bold ed)
      "no error")))

(test-equal "and is allowed with `inhibit-read-only'"
  (list 'bold 'bold)
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert "abcdefghij")
    (set!buffer-read-only ed #t)
    (parameterize ((*inhibit-read-only* #t))
      (tp:put-text-property 1 3 'face 'bold ed))
    (list (tp:get-text-property 1 'face ed)
          (tp:get-text-property 2 'face ed))))

;; ------------------------------------------------------------------
;; `modify_text_properties' - `record_first_change'
;;
;; The C raises the counter behind a guard:
;;
;;     if (MODIFF <= SAVE_MODIFF)
;;       record_first_change ();
;;     modiff_incr (&MODIFF, 1);
;;
;; so the *first* change after a save leaves the `(t . TOKEN)' entry that
;; says where the file was last saved - and a property change is a change,
;; so it leaves one too. This tree's version had no `record_first_change`
;; at all, which meant undoing back past a face change could not make the
;; buffer unmodified again.
;;
;; **It is pinned at the entry rather than end to end, and that is
;; deliberate.** Doing it through `undo' would also need `undo.c''s
;; `record_property_change' (`:191'), which records the property's old
;; value as an undo entry of its own; that is named as not carried on
;; `record-insert', and without it the two trees' undo lists differ for
;; reasons that have nothing to do with this test. Measured on Emacs 31.1:
;; after a save and `put-text-property', `buffer-undo-list' holds both a
;; property entry and a `(t . TIME)' entry.
(test-equal "the property-change raise records the first change since the save"
  #t
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert "abcdefghij")
    (set-buffer-modified-p #f)
    (tp:put-text-property 1 3 'face 'bold ed)
    (let loop ((l (text-editor-undo-list ed)))
      (cond ((null? l) #f)
            ((undo-modified-entry? (car l)) #t)
            (else (loop (cdr l)))))))

(test-end "schemacs_editor_textprop")
