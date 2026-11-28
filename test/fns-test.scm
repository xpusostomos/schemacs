(import
 (scheme base)
 (scheme char)
 (only (guile) sort)
 (schemacs fns)
 ;; `plist-member` is intervals.scm's - see the note in fns.scm.
 (only (schemacs intervals) plist-member)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 ;; the buffer a line count needs: `%count-lines' and `line-number-at-pos'
 ;; are both `fns.scm''s now and both work on a buffer's text. The Lisp
 ;; `count-lines' of the same subject is `simple.scm''s, and its
 ;; `ignore-invisible-lines' branch reads text properties.
 (only (schemacs buffer)
       *current-buffer* allocate-buffer current-buffer erase-buffer
       get-buffer-create set-buffer set-buffer-local-value!)
 (only (schemacs frame) *current-frame* new-frame)
 (only (schemacs editfns)
       goto-char insert narrow-to-region point point-min point-max
       propertize save-restriction)
 (only (schemacs marker) copy-marker)
 (only (schemacs textprop) get-text-property put-text-property)
 (only (schemacs simple) count-lines)
 (only (ice-9 exceptions) exception-message)
 )

;; fns.c's tests: the three string comparisons.
;;
;; `compare-strings'' answers are the ones minibuf-tests.scm already
;; checks through `(schemacs minibuf)', which re-exports it - and
;; they are checked again here because the function now *lives* in
;; fns.sld and a re-export is exactly the thing that can quietly stop
;; being the same function.
;;
;; `string-collate-lessp'' expectations were taken from `emacs -Q
;; --batch' on this machine, in the ambient locale, and they are the
;; reason it exists: the locale's collation is not character-code order,
;; which is what `string-lessp' gives.

(test-begin "schemacs_editor_fns")

;; ------------------------------------------------------------------
;; compare-strings

;; "abc" and "abd" first differ at index 2, and the answer is that index
;; *plus one*, signed by which string is less.
(test-equal '(#t -3 3 #t -4)
  (list (compare-strings "abc" 0 3 "abc" 0 3 #f)
        (compare-strings "abc" 0 3 "abd" 0 3 #f)
        (compare-strings "abd" 0 3 "abc" 0 3 #f)
        (compare-strings "ABc" 0 3 "abc" 0 3 #t)
        (compare-strings "hello" 0 5 "help" 0 4 #f)))

;; A range that runs out first is the lesser one, and the answer is
;; still "one more than the index": three characters were compared, so
;; four. `emacs -Q --batch' answers -4 and 4 here.
(test-equal '(-4 4)
  (list (compare-strings "abc" 0 3 "abcd" 0 4 #f)
        (compare-strings "abcd" 0 4 "abc" 0 3 #f)))

;; nil END means the end of the string, which is the C's nil
(test-equal '#t (compare-strings "abc" 0 #f "abc" 0 #f #f))

;; ------------------------------------------------------------------
;; string-lessp

(test-equal '(#t #f #t)
  (list (string-lessp "abc" "abd")
        (string-lessp "abd" "abc")
        (string-lessp "abc" "abcd")))

;; "Case is significant."
(test-equal '#f (string-lessp "abc" "ABC"))

;; ------------------------------------------------------------------
;; string-collate-lessp

;; Punctuation weighs less here than it does to `string-lessp', which
;; would put both "1 1" and "1.1" after both "11" and "12" because a
;; space and a dot sort above every digit.
;;
;; This is what `emacs -Q --batch' answers on this machine, which is
;; *not* the list the C's docstring shows: the docstring's example is
;; stale against this glibc, and measuring is what settles it.
(test-equal '("1 1" "1.1" "11" "1 2" "1.2" "12")
  (sort '("11" "12" "1 1" "1 2" "1.1" "1.2") string-collate-lessp))
(test-equal '("1 1" "1 2" "1.1" "1.2" "11" "12")
  (sort '("11" "12" "1 1" "1 2" "1.1" "1.2") string-lessp))

;; measured: `emacs -Q --batch' in this machine's locale
(test-equal '(#f #t)
  (list (string-collate-lessp "__pycache__" "pty-check.py")
        (string-collate-lessp "emacs" "emacs.txt")))

;; "Symbols are also allowed; their print names are used instead."
(test-equal '#t (string-collate-lessp 'abc "abd"))

;; "If IGNORE-CASE is non-nil, characters are converted to lower-case
;; before comparing them."
(test-equal '(#t #t)
  (list (string-collate-lessp "ABC" "abd")
        (string-collate-lessp "ABC" "abd" #f #t)))
(test-equal '#f (string-collate-lessp "abd" "ABC"))

;; "The optional argument LOCALE, a string, overrides the setting of
;; your current locale identifier for collation."
(test-equal '#t (string-collate-lessp "a" "b" "en_US.UTF-8"))

;; ------------------------------------------------------------------
;; %count-lines and line-number-at-pos
;;
;; Both live in this library now. `line-number-at-pos' is `fns.c:6688' - a
;; DEFUN of *this* file - and it was in `editfns.scm' under a comment
;; citing `editfns.c', which is where it is not; the `count_lines' it
;; counts with is `xdisp.c:29903' and is placed beside it (the note on it
;; there says why, and why the C helper now carries the `%').
;;
;; **`%count-lines' here is the C *helper*, not Emacs's Lisp function of
;; nearly the same spelling.** `simple.el:1800''s narrows to the range and
;; can answer one more: measured on Emacs 31.1, `(count-lines 1 6)' over
;; "a\nb\nc" is 3, where this walk from 1 to 6 finds the two newlines and
;; answers 2. That one is ported now, in `simple.scm' - the group below is
;; its. So the values here are `display_count_lines''s, and the
;; `line-number-at-pos' ones are the DEFUN's.
;;
;; Every `line-number-at-pos' expectation is `emacs -Q --batch' on this
;; machine, errors included.

(define (with-text text thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*fns-tests*")))
      (set-buffer b)
      (erase-buffer)
      (insert text)
      (thunk))))

;; "a\nb\nc" is five characters - a, newline, b, newline, c - and
;; `point-max' is 6. The newlines are at 2 and 4, so the walk counts two
;; over the whole buffer and none over an empty range.
(test-equal '(2 0 1 0 2 0)
  (with-text "a\nb\nc"
    (lambda ()
      (let ((b (current-buffer)))
        (list (%count-lines b 1 6)
              (%count-lines b 1 1)
              (%count-lines b 3 5)
              (%count-lines b 4 4)
              (%count-lines b 1 5)
              (%count-lines b 5 6))))))

;; `line-number-at-pos' is that walk from `point-min' plus one, so the two
;; agree: 2 newlines before `point-max' is line 3.
(test-equal '(3 3)
  (with-text "a\nb\nc"
    (lambda ()
      (let ((b (current-buffer)))
        (let ((from-walk (+ 1 (%count-lines b 1 6))))
          (goto-char 6)
          (list from-walk (line-number-at-pos)))))))

;; measured: point at 1 is line 1, at 3 line 2, at 5 and at 6 both line 3
;; (the last line has no trailing newline).
(test-equal '(1 2 3 3)
  (with-text "a\nb\nc"
    (lambda ()
      (map (lambda (at) (goto-char at) (line-number-at-pos))
           (list 1 3 5 6)))))

;; With POSITION the answer is that position's line and point does not
;; move: measured, 1 -> 1, 3 -> 2, 5 -> 3, 6 -> 3.
(test-equal '(1 2 3 3)
  (with-text "a\nb\nc"
    (lambda ()
      (list (line-number-at-pos 1)
            (line-number-at-pos 3)
            (line-number-at-pos 5)
            (line-number-at-pos 6)))))

;; **POSITION may be a marker**, the C's `MARKERP (position)' branch -
;; measured, `(line-number-at-pos (copy-marker 3))' is 2.
(test-equal 2
  (with-text "a\nb\nc"
    (lambda () (line-number-at-pos (copy-marker 3)))))

;; **ABSOLUTE is taken and cannot change the answer with nothing
;; narrowed.** The C chooses `BEG_BYTE' over `BEGV_BYTE' as the start of
;; the count, and it is the narrowing that makes those differ; measured,
;; `(line-number-at-pos nil t)' is the same as `(line-number-at-pos nil)'
;; wherever point is.
;;
;; Elisp's nil is spelled `#f' in this tree - there is no `nil' object to
;; pass, the Elisp layer having gone - so the C's nil POSITION with a
;; non-nil ABSOLUTE is `(line-number-at-pos #f #t)'.
(test-equal '(2 2)
  (with-text "a\nb\nc"
    (lambda ()
      (goto-char 3)
      (list (line-number-at-pos) (line-number-at-pos #f #t)))))

;; A POSITION outside `[point-min, point-max]' is `args-out-of-range':
;; measured, `(line-number-at-pos 0)' is `(args-out-of-range 0 1 6)' and
;; `(line-number-at-pos 99)' is `(args-out-of-range 99 1 6)' - the C
;; signal's three data, POSITION then BEG then Z. The tree raises through
;; `error', as `validate-region' does, so the message is the C's text
;; without its condition type.
(test-equal '("Args out of range" "Args out of range")
  (with-text "a\nb\nc"
    (lambda ()
      (list (guard (e (#t (exception-message e))) (line-number-at-pos 0))
            (guard (e (#t (exception-message e))) (line-number-at-pos 99))))))

;; A POSITION that is neither is the C's `CHECK_FIXNUM' - a condition type
;; this tree has not, so it is its ordinary type error.
(test-equal "Wrong type argument"
  (with-text "a\nb\nc"
    (lambda ()
      (guard (e (#t (exception-message e))) (line-number-at-pos "x")))))

;; ------------------------------------------------------------------
;; fns.c's `assq' - `%assq' in this tree, because Guile's core binding
;; cannot be shadowed by a library import (see the note in fns.scm).
;; Every expectation is `emacs -Q --batch`'s own answer.
;; ------------------------------------------------------------------

;; The docstring's last sentence: "Elements of ALIST that are not conses
;; are ignored." Emacs answers `(bar . 2)` for the first and nil for the
;; rest; Guile's `assq' raises on the first.
(test-equal '((bar . 2) (a . 1) #f #f #f)
  (list (%assq 'bar '(foo (bar . 2)))
        (%assq 'a '((a . 1) (b . 2)))
        (%assq 'c '((a . 1)))
        (%assq 'a '())
        (%assq 'a #f)))                 ; Elisp's nil, this tree's other spelling

;; The C walks with `FOR_EACH_TAIL' and then `CHECK_LIST_END': an improper
;; tail is `wrong-type-argument listp' with the whole ALIST as data -
;; measured, `(wrong-type-argument listp (a . b))'. The tree's type error
;; is the message alone.
(test-equal "Wrong type argument"
  (guard (e (#t (exception-message e))) (%assq 'x '(a . b))))

;; ------------------------------------------------------------------
;; simple.el's `count-lines' - the Lisp function, ported in simple.scm.
;; Every expectation below is `emacs -Q --batch`'s answer on the same
;; text, measured first.
;; ------------------------------------------------------------------

;; "a\nb\nc": the plain answer, an empty range, an end at a line start and
;; one in mid-line, a range that starts mid-line, and the last line with
;; no trailing newline.
(test-equal '(3 0 2 2 3 0 0 1 1 0 1 1)
  (with-text "a\nb\nc"
    (lambda ()
      (list (count-lines 1 6) (count-lines 1 1) (count-lines 1 4)
            (count-lines 1 5) (count-lines 2 6) (count-lines 2 2)
            (count-lines 4 4) (count-lines 2 3) (count-lines 5 6)
            (count-lines 6 6) (count-lines 1 2) (count-lines 1 3)))))

;; `narrow-to-region' sorts its arguments, which is how "the greater of
;; them" comes out right for a reversed range: measured, 3 for 6..1 and 2
;; for 4..2.
(test-equal '(3 2)
  (with-text "a\nb\nc"
    (lambda () (list (count-lines 6 1) (count-lines 4 2)))))

;; `save-excursion' is the body's first form, so point does not move.
(test-equal '(3 3)
  (with-text "a\nb\nc"
    (lambda ()
      (goto-char 3)
      (list (count-lines 1 6) (point)))))

;; The arguments may be markers, as they may be for `narrow-to-region'.
(test-equal 3
  (with-text "a\nb\nc"
    (lambda () (count-lines (copy-marker 1) (copy-marker 6)))))

(test-equal '(0 0)
  (with-text ""
    (lambda () (list (count-lines 1 1)
                     (count-lines (point-min) (point-max))))))

;; Inside an existing narrowing the function narrows to its own range, and
;; a range outside the buffer's text is `narrow-to-region''s
;; args-out-of-range - measured, 3 and 1, then "Args out of range".
(test-equal '(3 1 "Args out of range")
  (with-text "a\nb\nc"
    (lambda ()
      (save-restriction
        (narrow-to-region 2 6)
        (list (count-lines 2 6)
              (count-lines 3 5)
              (guard (e (#t (exception-message e)))
                     (count-lines 1 7)))))))

;; IGNORE-INVISIBLE-LINES: a line counts as invisible when its *newline*
;; carries an `invisible' property that `buffer-invisibility-spec' says
;; hides. Measured with "a\n" and "b\n" marked, over "a\nb\nc\nd": 4
;; without the flag (the branch is not taken), then 2 with the spec at its
;; default (t - any non-nil property hides), 3 with '(foo) and with
;; '(bar), and 4 with nil and with '().
(test-equal '(4 2 3 3 4 4)
  (with-text "a\nb\nc\nd"
    (lambda ()
      (let ((b (current-buffer)))
        (put-text-property 1 3 'invisible 'foo)
        (put-text-property 3 5 'invisible 'bar)
        (let ((no-flag (count-lines 1 8))      ; no slot: spec default t
              (default (count-lines 1 8 #t)))
          (set-buffer-local-value! b 'buffer-invisibility-spec '(foo))
          (let ((foo (count-lines 1 8 #t)))
            (set-buffer-local-value! b 'buffer-invisibility-spec '(bar))
            (let ((bar (count-lines 1 8 #t)))
              (set-buffer-local-value! b 'buffer-invisibility-spec #f)
              (let ((nil-spec (count-lines 1 8 #t)))
                (set-buffer-local-value! b 'buffer-invisibility-spec '())
                (list no-flag default foo bar nil-spec
                      (count-lines 1 8 #t))))))))))

;;------------------------------------------------------------------
;; fns.c's plist primitives - every expectation `emacs -Q --batch`'s own
;;------------------------------------------------------------------

(test-equal 2 (plist-get '(:a 1 :b 2) ':b))
;; a missing property and a property whose value is nil answer the same
(test-equal #f (plist-get '(:a 1 :b 2) ':c))
(test-equal #f (plist-get '(:a #f :b 2) ':a))
(test-equal '(:a #f :b 2) (plist-member '(:a #f :b 2) ':a))
(test-equal #f (plist-member '(:a 1) ':c))
(test-equal '(:a 1 :b 2 :c 3) (plist-put (list ':a 1 ':b 2) ':c 3))
(let ((p (list ':a 1 ':b 2)))
  (let ((q (plist-put p ':a 9)))
    (test-assert "plist-put modifies and answers the same list"
      (eq? p q))
    (test-equal '(:a 9 :b 2) q)))
(test-equal 2 (plist-get '("a" 1 "b" 2) "b" equal?))

;;------------------------------------------------------------------
;; `equal-including-properties' - and the `equal?' that cannot see a face
;;------------------------------------------------------------------
;;
;; Measured on Emacs 31.1 first: `(equal a b)' is t for two strings that
;; differ only in their `face' property, and `equal-including-properties'
;; is nil. That difference is what the redisplay's mode-line and tab-line
;; skips need - a tab line whose characters are unchanged while the
;; current tab moves has a different *face* at the same characters.
(test-equal '(#t #f #t #f #t #t)
  (let ((a (propertize "ab" 'face 'bold))
        (b (propertize "ab" 'face 'italic))
        (c (propertize "ab" 'face 'bold)))
    (list (equal-including-properties a c)
          (equal-including-properties a b)
          (equal-including-properties "ab" "ab")
          (equal-including-properties (list a 'x) (list b 'x))
          (equal-including-properties (list a 'x) (list c 'x))
          (equal? a b))))

;;------------------------------------------------------------------
;; `%substring' - Emacs's `substring', which keeps text properties
;;------------------------------------------------------------------
;;
;; Measured on Emacs 31.1 first: `(substring s 2)' of a wholly bold
;; "abcdef" is "cdef" with `face' bold at every position, a negative FROM
;; counts from the end, nil FROM/TO mean the ends - and a range out of
;; bounds, or FROM past TO, *signals* (`validate_subarray') rather than
;; clipping. Guile's `substring' is the no-properties variant.
(test-equal '(#t #t "cdef" "bc" "cdef" "ab")
  (let ((s (propertize "abcdef" 'face 'bold)))
    (list (eq? (get-text-property 0 'face (%substring s 2)) 'bold)
          (eq? (get-text-property 1 'face (%substring s 1 3)) 'bold)
          (%substring s 2)
          (%substring s 1 3)
          (%substring s -4)
          (%substring s #f 2))))

(test-equal '(#t #t #t)
  (let ((s (propertize "abcdef" 'face 'bold)))
    (list (guard (e (#t #t)) (%substring s 5 2) #f)
          (guard (e (#t #t)) (%substring s 9) #f)
          (guard (e (#t #t)) (%substring s -9) #f))))

;;------------------------------------------------------------------
;; `proper-list-p' (`fns.c:244') - measured on Emacs 31.1:
;; (3 0 nil nil nil), and a circular list is nil too.
;;------------------------------------------------------------------
(test-equal '(3 0 #f #f #f #f)
  (let ((x (list 1 2)))
    (set-cdr! (cdr x) x)
    (list (proper-list-p '(1 2 3))
          (proper-list-p '())
          (proper-list-p '(1 . 2))
          (proper-list-p "abc")
          (proper-list-p 5)
          (proper-list-p x))))

(test-end "schemacs_editor_fns")
;;------------------------------------------------------------------
;; `string-search' (`fns.c:6583') - case-sensitive, properties ignored,
;; a zero-based index or nil.  Measured on Emacs 31.1.
(test-begin "schemacs_editor_fns_string_search")
(test-equal "the first occurrence" 1 (string-search "b" "abc"))
(test-equal "a multi-character needle" 1 (string-search "bc" "abc"))
(test-equal "nil when absent" #f (string-search "z" "abc"))
(test-equal "an empty needle matches at the start" 0 (string-search "" "abc"))
(test-equal "START-POS is zero-based" 2 (string-search "c" "abc" 2))
(test-equal "a start past the only occurrence answers nil"
            #f (string-search "a" "abc" 1))
(test-equal "the empty needle at the end" 3 (string-search "" "abc" 3))
(test-equal "a start out of range signals"
            #t
            (guard (e (#t #t)) (string-search "a" "abc" 4) #f))
(test-end "schemacs_editor_fns_string_search")
