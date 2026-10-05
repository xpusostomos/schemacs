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
 (only (schemacs editor cmds) internal-self-insert))

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

(test-end "schemacs_editor_cmds")
