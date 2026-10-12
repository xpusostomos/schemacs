(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine) allocate-buffer)
 (only (schemacs editor buffer)
       *current-buffer* current-buffer erase-buffer get-buffer-create
       set-buffer)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor editfns)
       *text-quoting-style* buffer-string char-before format format-message
       forward-line goto-char insert insert-and-inherit insert-buffer-substring
       line-beginning-position line-end-position line-number-at-pos point
       propertize)
 (only (schemacs editor textprop) get-text-property)
 (only (ice-9 exceptions) exception-message))

;; editfns.c's position primitives, and `forward-line' with them.
;;
;; This file exists because nothing tested them: three of them were wrong
;; and the whole suite was green. `line-beginning-position' answered the
;; *previous* line's beginning for every call without an N (its absent-N
;; default was 0, so `(forward-line (- n 1))' was `-1'), and
;; `char-before' required a POS where Emacs's is optional and had no upper
;; bound where Emacs answers nil for one out of range.
;;
;; Every expectation below is `emacs -Q --batch' on this machine.
;;
;; **FIXED 2026-10-12**: `forward-line' used to leave point where it was
;; when the walk ran out and to answer 0 always (its counter was passed to
;; itself unchanged), so `kill-line`'s end-of-buffer test and
;; `paragraphs.scm`'s walks were told every move had succeeded. It is now
;; the C's body - `scan_newline_from_point`, the shortage answer, and the
;; "non-empty last line counts as moved" exception (`cmds.c:97' is its
;; home; it lives in `editfns.scm` only because `indent.scm` and
;; `indentc.scm`, which use it, sit below `cmds.scm`). The cases that run
;; out of buffer are tested below now, not just named.

(test-begin "schemacs_editor_editfns")

(define (with-text text thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*editfns-tests*")))
      (set-buffer b)
      (erase-buffer)
      (insert text)
      (thunk))))

;; "aaa\nbbb\nccc\nddd": four lines, the last without a trailing newline
(define lines "aaa\nbbb\nccc\nddd")

;; ------------------------------------------------------------------
;; `line-beginning-position' and `line-end-position'
;;
;; "With argument N not nil or 1, move forward N - 1 lines first" - so an
;; absent N is 1 and moves nothing.

;; Position ZV itself *is* included: on a buffer with no trailing newline
;; it answers the last line's beginning, which is what Emacs answers too
;; (measured: `(goto-char 16) (line-beginning-position)' is 13 in both).
;; The header used to name it as one line short; that was a `forward-line'
;; symptom and went with it.
(test-equal '(1 5 9 13 13)
  (with-text lines
    (lambda ()
      (map (lambda (at) (goto-char at) (line-beginning-position))
           (list 1 5 9 13 16)))))

;; with the argument given, with it given as nil (which must behave as
;; absent - Elisp spells it `(and arg 2)'), and with it 2
(test-equal '(1 5 9  1 5 9  5 9 13)
  (with-text lines
    (lambda ()
      (append
       (map (lambda (at) (goto-char at) (line-beginning-position 1))
            (list 1 5 9))
       (map (lambda (at) (goto-char at) (line-beginning-position #f))
            (list 1 5 9))
       (map (lambda (at) (goto-char at) (line-beginning-position 2))
            (list 1 5 9))))))

;; `line-end-position' is the line's own end, and with an N the end N
;; lines away. This one matched Emacs already; it is here so that the pair
;; is tested together and a change to either is caught.
(test-equal '(4 8 12 16  8 12 16 16)
  (with-text lines
    (lambda ()
      (append
       (map (lambda (at) (goto-char at) (line-end-position))
            (list 1 5 9 13))
       (map (lambda (at) (goto-char at) (line-end-position 2))
            (list 1 5 9 13))))))

;; ------------------------------------------------------------------
;; `char-before'
;;
;; The C's DEFUN is `0, 1, 0': POS is optional, defaults to point, and is
;; nil out of range. `(char-before)' is how the .el code this tree ports
;; spells it, so a required POS is not a small difference - it is a
;; wrong-number-of-arguments error inside a ported function, which is how
;; `dired-move-to-end-of-filename''s symlink path found it.

(test-equal '(#\c #\a #\c)
  (with-text "abc"
    (lambda ()
      (goto-char 4)                      ; the C's point after insert
      (let ((at-point (char-before)))
        (goto-char 2)
        (let ((at-2 (char-before)))
          (goto-char 4)
          (list at-point at-2 (char-before)))))))

;; out of range at either end: 0, 1 and 5 are nil on a three-character
;; buffer, and only 2 and 4 name a character
(test-equal '(#f #f #\a #\c #f #f)
  (with-text "abc"
    (lambda ()
      (map (lambda (pos) (char-before pos)) (list 0 1 2 4 5 100)))))

;; an explicit nil is the absent case, as in Emacs
(test-equal #\c
  (with-text "abc"
    (lambda ()
      (goto-char 4)
      (char-before #f))))

;; ------------------------------------------------------------------
;; `forward-line'
;;
;; The walk itself - the cases that do *not* run out of buffer, which is
;; the part this port has right. See the header for the part it has not.

(test-equal '((0 . 5) (0 . 9) (0 . 5) (0 . 1))
  (with-text lines
    (lambda ()
      (list
       (begin (goto-char 1) (cons (forward-line 1) (point)))
       (begin (goto-char 5) (cons (forward-line 1) (point)))
       (begin (goto-char 9) (cons (forward-line -1) (point)))
       (begin (goto-char 5) (cons (forward-line -1) (point)))))))

;; "Returns the count of lines left to move" - 0 when it moved
(test-equal '(0 0 0)
  (with-text "aaa\nbbb\nccc\n"
    (lambda ()
      (map (lambda (at) (goto-char at) (forward-line 1)) (list 1 5 9)))))

;; ...and the cases that DO run out of buffer, which this port got wrong
;; until 2026-10-12: the answer was always 0 (the walk passed its counter
;; to itself unchanged), and point was not moved to the end. The C's answer
;; is the *shortage* and it moves point as far as it can; the docstring's
;; exception - "a non-empty line at the end of the buffer counts as one
;; line successfully moved" - is the `FETCH_BYTE (PT_BYTE - 1) != '\n'`
;; clause. Every row is `emacs -Q --batch' on the same text.
(test-equal '((0 . 5) (1 . 9) (3 . 9))
  (with-text "abc\ndef\n"
    (lambda ()
      (list (begin (goto-char 1) (cons (forward-line 1) (point)))
            (begin (goto-char 9) (cons (forward-line 1) (point)))
            (begin (goto-char 5) (cons (forward-line 4) (point)))))))

;; No trailing newline: the last line counts as moved, so `(forward-line 1)`
;; from its start answers 0 and lands on `point-max' - and only from there
;; does it answer 1.
(test-equal '((0 . 4) (1 . 4))
  (with-text "abc"
    (lambda ()
      (list (begin (goto-char 1) (cons (forward-line 1) (point)))
            (begin (goto-char 4) (cons (forward-line 1) (point)))))))

;; Backward: the count is negative when it runs out of the front
(test-equal '((-1 . 1) (0 . 1))
  (with-text "abc\ndef\n"
    (lambda ()
      (list (begin (goto-char 1) (cons (forward-line -1) (point)))
            (begin (goto-char 5) (cons (forward-line -1) (point)))))))

;; `(forward-line 0)' is the beginning of the current line, and answers 0
(test-equal '(0 . 5)
  (with-text "abc\ndef\n"
    (lambda () (goto-char 7) (cons (forward-line 0) (point)))))

;; ------------------------------------------------------------------
;; `line-number-at-pos'

(test-equal '(1 2 3 4)
  (with-text lines
    (lambda ()
      (map (lambda (at) (goto-char at) (line-number-at-pos))
           (list 1 5 9 13)))))


;; ------------------------------------------------------------------
;; `format' and `format-message'

;; Every expectation below is what `emacs -Q --batch' answers for the
;; same call; the pairs were run side by side, and the float ones across
;; a matrix of values and precisions.

(test-equal "format: %s is princ, %S is prin1"
  '("x" "\"x\"" "(a b)" "(a \"b\")")
  (list (format "%s" "x")
        (format "%S" "x")
        (format "%s" (list 'a "b"))
        (format "%S" (list 'a "b"))))

(test-equal "format: the flags and widths C gives"
  '("[   42][42   ][00042][+42][ 42]")
  (list (format "[%5d][%-5d][%05d][%+d][% d]" 42 42 42 42 42)))

(test-equal "format: a precision on an integer is a minimum of digits, and turns off 0"
  '("[00042][  042]")
  (list (format "[%.5d][%05.3d]" 42 42)))

(test-equal "format: the radixes, and %#X's prefix"
  '("[ff][FF][0xff][10][010][101][101][0B101]")
  (list (format "[%x][%X][%#x][%o][%#o][%b][%B][%#B]"
                255 255 255 8 8 5 5 5)))

(test-equal "format: a precision on a string truncates"
  '("[abc][   abc]")
  (list (format "[%.3s][%6.3s]" "abcdef" "abcdef")))

(test-equal "format: %c takes a character code and %% is a percent"
  '("[A][A]" "100%")
  (list (format "[%c][%c]" 65 65)
        (format "100%%")))

(test-equal "format: a field number picks the argument by position"
  "two one"
  (format "%2$s %1$s" "one" "two"))

(test-equal "format: the float conversions are C's, exponent and all"
  '("[3.14][1.234500e+03][1e-05]")
  (list (format "[%.2f][%e][%g]" 3.14159 1234.5 0.00001)))

(test-assert "format: too few arguments is Emacs's error"
  (equal? "Not enough arguments for format string"
          (guard (e (#t (exception-message e))) (format "%d %d" 1))))

(test-assert "format: an unknown conversion is Emacs's error"
  (equal? "Invalid format operation %q"
          (guard (e (#t (exception-message e))) (format "%q" 1))))

(test-assert "format: a mismatched argument type is Emacs's error"
  (equal? "Format specifier doesn't match argument type"
          (guard (e (#t (exception-message e))) (format "%d" "x"))))

(test-equal "format-message: the default style is `curve' - no display table"
  "it\u2019s \u2018ok\u2019"
  (format-message "it's `ok'"))

(test-equal "format-message: under `curve' the quotes are the curved ones"
  "it’s ‘ok’"
  (parameterize ((*text-quoting-style* 'curve))
    (format-message "it's `ok'")))

(test-equal "insert-buffer-substring: the whole buffer, or a range"
  '("abc" "b")
  (let ((src (get-buffer-create "*editfns-tests-src*")))
    (set-buffer src) (erase-buffer) (insert "abc")
    (let ((dst (get-buffer-create "*editfns-tests-dst*")))
      (set-buffer dst) (erase-buffer)
      (insert-buffer-substring src)
      (let ((whole (buffer-string)))
        (erase-buffer)
        (insert-buffer-substring src 2 3)
        (list whole (buffer-string))))))

;; ------------------------------------------------------------------
;; `insert' and `insert-and-inherit': the one difference between them
;;
;; Both go through `general_insert_function', and the flag it carries
;; reaches `graft_intervals_into_buffer', where it decides what happens to
;; text that brings **no properties of its own**: `insert' has them
;; *cleared off* it, `insert-and-inherit` leaves it part of whatever
;; interval it landed in. Text that brings properties of its own - a
;; `propertize'd string - keeps them either way.
;;
;; Every expectation is `emacs -Q --batch' on the same text.

(define (prop-after-insert inserter)
  ;; The `face' at position 4 after ABC propertized bold, a D put after it,
  ;; and the face at 3 alongside - the pair the Emacs probe printed.
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create "*editfns-tests-prop*")))
    (set-buffer ed)
    (erase-buffer)
    (insert (propertize "abc" 'face 'bold))
    (goto-char 4)
    (inserter)
    (list (buffer-string)
          (get-text-property 4 'face ed)
          (get-text-property 3 'face ed))))

(test-equal "insert gives the new text no properties of the run it lands in"
  '("abcd" #f bold)
  (prop-after-insert (lambda () (insert "d"))))

(test-equal "insert-and-inherit gives it the run's"
  '("abcd" bold bold)
  (prop-after-insert (lambda () (insert-and-inherit "d"))))

;; A character argument is the same question - `general_insert_function'
;; encodes it and hands it to the same insert.
(test-equal "insert of a character does not inherit either"
  '("abcd" #f bold)
  (prop-after-insert (lambda () (insert #\d))))

(test-equal "insert-and-inherit of a character inherits"
  '("abcd" bold bold)
  (prop-after-insert (lambda () (insert-and-inherit #\d))))

;; Two arguments are two insertions, each asking the question afresh - so
;; neither inherits.
(test-equal "each argument of insert is inserted the same way"
  '("abcde" #f #f)
  (let ((ed (get-buffer-create "*editfns-tests-prop2*")))
    (set-buffer ed)
    (erase-buffer)
    (insert (propertize "abc" 'face 'bold))
    (goto-char 4)
    (insert "d" "e")
    (list (buffer-string)
          (get-text-property 4 'face ed)
          (get-text-property 5 'face ed))))

;; ...and a string that *does* carry properties keeps them through plain
;; `insert`: the graft is the string's own tree.
(test-equal "a propertized string keeps its properties through insert"
  '("abcd" italic)
  (let ((ed (get-buffer-create "*editfns-tests-prop3*")))
    (set-buffer ed)
    (erase-buffer)
    (insert "abc")
    (goto-char 4)
    (insert (propertize "d" 'face 'italic))
    (list (buffer-string) (get-text-property 4 'face ed))))

(test-end "schemacs_editor_editfns")
