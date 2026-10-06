(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor buffer)
       get-buffer-create set-buffer erase-buffer buffer-overwrite-mode
       set!buffer-overwrite-mode)
 (only (schemacs editor editfns)
       insert goto-char point buffer-string)
 (only (schemacs editor cmds)
       backward-char beginning-of-line end-of-line forward-char
       internal-self-insert))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor cmds)', which mirrors GNU
;; Emacs's `cmds.c'. What is here is overwrite mode, which is the
;; overwrite branch of `internal_self_insert' (`cmds.c:312') and nothing
;; else.
;;
;; Every expectation was *measured* on GNU Emacs 31.1 rather than worked
;; out: `emacs -Q --batch', the same text, `overwrite-mode' set to the
;; same value, point moved and `self-insert-command' called with the same
;; character. The whole point of the branch is that overwriting is not
;; "replace N characters" but "cover N columns", and the cases that show
;; it - a wide character overwritten by a narrow one, and the reverse -
;; are the ones a plausible-looking implementation gets wrong.

(test-begin "schemacs_editor_cmds")

(define wide (integer->char #x3000))
;; ^ an ideographic space: one character, two columns.

(define (overwrite text position mode char) (overwrite-n text position mode char 1))

(define (overwrite-n text position mode char n)
  ;; What the buffer and point are after typing CHAR at POSITION with
  ;; MODE in effect - the `(buffer-string)' and `(point)' Emacs's probe
  ;; printed.
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create "*cmds-tests*")))
    (set-buffer ed)
    (erase-buffer)
    (insert text)
    (set!buffer-overwrite-mode ed mode)
    (goto-char position)
    (internal-self-insert char n)
    (list (buffer-string) (point))))

;; With overwrite mode off it is an ordinary insert: the rest of the line
;; moves right and point follows the character.
(test-equal "with overwrite mode off, typing inserts"
  '("aXbcdef" 3)
  (overwrite "abcdef" 2 #f #\X))

;; ...and with it on, the character at point is replaced.
(test-equal "overwrite replaces the character at point"
  '("aXcdef" 3)
  (overwrite "abcdef" 2 'overwrite-mode-textual #\X))

;; At the end of the line there is nothing to overwrite, so it extends
;; the line instead.
(test-equal "overwrite at the end of the line extends it"
  '("abX" 4)
  (overwrite "ab" 3 'overwrite-mode-textual #\X))

;; A newline is inserted, not overwritten: `char-width' of a newline is
;; 0, and the C's `cwidth != 0' test is what makes that so.
(test-equal "a newline is inserted in textual overwrite mode"
  '("a\nb" 3)
  (overwrite "ab" 2 'overwrite-mode-textual #\newline))

;; ...but binary overwrite mode overwrites with anything, newline
;; included, which is the difference between the two modes.
(test-equal "binary overwrite replaces with a newline"
  '("a\n" 3)
  (overwrite "ab" 2 'overwrite-mode-binary #\newline))

;; A tab is one character and eight columns. Typing a one-column
;; character over it leaves seven columns to fill, so the tab stays and
;; the character goes in front of it - "Rather than add spaces, let's
;; just keep the tab" (`cmds.c:390').
(test-equal "textual overwrite before a tab keeps the tab"
  '("aX\tb" 3)
  (overwrite "a\tb" 2 'overwrite-mode-textual #\X))

;; ...where binary mode simply replaces the tab, which is what the
;; docstring of `binary-overwrite-mode' says it does.
(test-equal "binary overwrite replaces the tab itself"
  '("aXb" 3)
  (overwrite "a\tb" 2 'overwrite-mode-binary #\X))

;; The cases that show why the branch measures columns. A wide character
;; is one character and two columns; overwriting it with a one-column
;; character has to delete it *and* leave a space, or the rest of the
;; line would move left.
(test-equal "overwrite pads when the new character is narrower"
  (list (string #\a #\X #\space #\b) 3)
  (overwrite (string #\a wide #\b) 2 'overwrite-mode-textual #\X))

;; ...and the other way round it eats two characters for the two columns
;; the wide character will occupy.
(test-equal "overwrite eats two characters for a wide one"
  (list (string #\a wide) 3)
  (overwrite "abc" 2 'overwrite-mode-textual wide))

;; A repeat count overwrites as many times as it inserts.
(test-equal "overwrite with a repeat count"
  '("aXXXef" 5)
  (overwrite-n "abcdef" 2 'overwrite-mode-textual #\X 3))

;; The variable is the mode, and it is per buffer - `DEFVAR_PER_BUFFER`
;; in the C (`buffer.c:5480'). One buffer's overwrite mode is not
;; another's.
(test-equal '(#f overwrite-mode-textual #f)
  (let ((a (get-buffer-create "*cmds-a*"))
        (b (get-buffer-create "*cmds-b*")))
    (set!buffer-overwrite-mode a 'overwrite-mode-textual)
    (list (buffer-overwrite-mode b)
          (buffer-overwrite-mode a)
          (buffer-overwrite-mode b))))

;; ------------------------------------------------------------------
;; forward-char and backward-char, which are `move_point' (`cmds.c:40')
;;
;; Three things the C does and this tree did none of until 2026-10-06:
;; N is *optional* and a nil N is 1; the move stops at the buffer's
;; boundary; and it then **signals**, so a command that runs off the end
;; fails rather than quietly clamping. Every row is Emacs 31.1's, from
;; `emacs -Q --batch' over the same calls.

(define (move-result text position thunk)
  ;; (the error message or `no-error', point afterwards).
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create "*cmds-move*")))
    (set-buffer ed)
    (erase-buffer)
    (insert text)
    (goto-char position)
    (let ((outcome (guard (e (#t (if (error-object? e)
                                    (error-object-message e)
                                    'ERR)))
                     (thunk)
                     'no-error)))
      (list outcome (point)))))

(test-equal "backward-char at the beginning of the buffer signals"
  '("Beginning of buffer" 1)
  (move-result "ab" 1 (lambda () (backward-char))))

(test-equal "forward-char at the end of the buffer signals"
  '("End of buffer" 3)
  (move-result "ab" 3 (lambda () (forward-char))))

(test-equal "...and stops there rather than running past it"
  '("End of buffer" 3)
  (move-result "ab" 3 (lambda () (forward-char 5))))

;; "If N is omitted or nil, move point 1 character forward" - the
;; arity bug this was found by. `(forward-char)' was a
;; "Wrong number of arguments" error here.
(test-equal "forward-char with no argument moves one character"
  '(no-error 3)
  (move-result "ab" 2 (lambda () (forward-char))))

(test-equal "forward-char with a nil argument moves one character"
  '(no-error 3)
  (move-result "ab" 2 (lambda () (forward-char #f))))

(test-equal "a negative N goes the other way"
  '(no-error 1)
  (move-result "ab" 2 (lambda () (forward-char -1))))

;; ------------------------------------------------------------------
;; beginning-of-line and end-of-line, which take an optional N too
;;
;; Both are `(0, 1, "^p")' in `cmds.c' and both are one call over the
;; N-line arithmetic - `line-beginning-position' and `line-end-position'
;; with it. This tree's took **no argument at all**, so `(end-of-line 0)'
;; was an error and the behaviour was missing as well. Giving them the
;; argument is what then found the two bugs underneath: `line-end-position'
;; was not the C's `eol (n)', and `find-newline''s backward scan answered
;; one boundary found however many it had crossed.
;;
;; The table is Emacs 31.1's, from `emacs -Q --batch' over
;; "aaa\nbbb\nccc\nddd\n" from three starting points.

(define (bol-and-eol start n)
  ;; (bol, eol) from START with that N.
  ;;--------------------------------------------------------------
  (let ((ed (get-buffer-create "*cmds-lines*")))
    (set-buffer ed)
    (erase-buffer)
    (insert "aaa\nbbb\nccc\nddd\n")
    (goto-char start)
    (beginning-of-line n)
    (let ((b (point)))
      (goto-char start)
      (end-of-line n)
      (list b (point)))))

(test-equal "beginning-of-line and end-of-line with no argument"
  '(1 4)
  (bol-and-eol 1 #f))

(test-equal "...and with N moving forward N - 1 lines"
  '((5 8) (9 12))
  (list (bol-and-eol 1 2) (bol-and-eol 1 3)))

(test-equal "...and a positive N from a line that is not the first"
  '((13 16) (17 17))
  (list (bol-and-eol 9 2) (bol-and-eol 9 3)))

;; "They stop there": N of 0 and below scans *backward*, and runs off the
;; beginning of the buffer rather than wrapping.
(test-equal "an N of zero is the previous line"
  '((1 4) (5 8))
  (list (bol-and-eol 5 0) (bol-and-eol 9 0)))

(test-equal "a negative N scans further back and stops at the beginning"
  '((1 1) (1 1) (1 4))
  (list (bol-and-eol 1 -1) (bol-and-eol 5 -1) (bol-and-eol 9 -1)))

(test-end "schemacs_editor_cmds")
