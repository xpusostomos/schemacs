(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine) new-text-editor)
 (only (schemacs editor buffer)
       *current-buffer* current-buffer erase-buffer get-buffer-create
       set-buffer)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor editfns)
       *text-quoting-style* buffer-string char-before format format-message
       forward-line goto-char insert insert-buffer-substring line-beginning-position
       line-end-position line-number-at-pos point)
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
;; Named and *not* covered, because it is a departure with its own cause:
;; `forward-line' does not clamp point to the end of the buffer when the
;; walk runs out - `(forward-line 1)' on a last line with no trailing
;; newline leaves point where it was, where the C moves it to ZV and
;; counts that line as moved (`cmds.c:108-142', through `find_newline',
;; search.c:675). That is why `indent-rigidly' loops forever on a region
;; whose last line has no newline, and why `(line-beginning-position 3)'
;; near the end of a buffer answers one line short. Three primitives are
;; missing for it and this file does not pretend otherwise.

(test-begin "schemacs_editor_editfns")

(define (with-text text thunk)
  (parameterize ((*current-frame* (new-frame (new-text-editor) 24 80))
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

;; Position ZV itself is deliberately absent from this list: with no
;; trailing newline Emacs answers ZV there (16 for this text) where this
;; answers the last line's beginning (13). Same root as the `forward-line'
;; note in the header - the line walk, not the primitive.
(test-equal '(1 5 9 13)
  (with-text lines
    (lambda ()
      (map (lambda (at) (goto-char at) (line-beginning-position))
           (list 1 5 9 13)))))

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

(test-end "schemacs_editor_editfns")
