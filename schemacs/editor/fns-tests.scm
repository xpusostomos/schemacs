(import
 (scheme base)
 (scheme char)
 (only (guile) sort)
 (schemacs editor fns)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 ;; the buffer a line count needs: `count-lines' and `line-number-at-pos'
 ;; are both `fns.scm''s now and both work on a buffer's text.
 (only (schemacs editor buffer)
       *current-buffer* allocate-buffer current-buffer erase-buffer
       get-buffer-create set-buffer)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor editfns) goto-char insert)
 (only (schemacs editor marker) copy-marker)
 (only (ice-9 exceptions) exception-message)
 )

;; fns.c's tests: the three string comparisons.
;;
;; `compare-strings'' answers are the ones minibuf-tests.scm already
;; checks through `(schemacs editor minibuf)', which re-exports it - and
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
;; count-lines and line-number-at-pos
;;
;; Both live in this library now. `line-number-at-pos' is `fns.c:6688' - a
;; DEFUN of *this* file - and it was in `editfns.scm' under a comment
;; citing `editfns.c', which is where it is not; the `count_lines' it
;; counts with is `xdisp.c:29892' and is placed beside it (the note on it
;; there says why, and why its name is not the Lisp `count-lines'').
;;
;; **`count-lines' here is the C *helper*, not Emacs's Lisp function of
;; the same spelling.** `simple.el:1800''s narrows to the range and can
;; answer one more: measured on Emacs 31.1, `(count-lines 1 6)' over
;; "a\nb\nc" is 3, where this walk from 1 to 6 finds the two newlines and
;; answers 2. So the values below are `display_count_lines''s, and the
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
        (list (count-lines b 1 6)
              (count-lines b 1 1)
              (count-lines b 3 5)
              (count-lines b 4 4)
              (count-lines b 1 5)
              (count-lines b 5 6))))))

;; `line-number-at-pos' is that walk from `point-min' plus one, so the two
;; agree: 2 newlines before `point-max' is line 3.
(test-equal '(3 3)
  (with-text "a\nb\nc"
    (lambda ()
      (let ((b (current-buffer)))
        (let ((from-walk (+ 1 (count-lines b 1 6))))
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

(test-end "schemacs_editor_fns")