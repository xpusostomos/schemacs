(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer)
       *current-buffer* *inhibit-read-only* allocate-buffer buffer-name
       buffer-read-only? current-buffer erase-buffer get-buffer
       get-buffer-create major-mode set-buffer set-point with-current-buffer
       set-buffer-local-value! buffer-local-value
       *case-fold-search*)
 (only (schemacs frame) *current-frame* new-frame)
 (only (schemacs editfns)
       *inhibit-field-text-motion* *inhibit-message* *text-quoting-style*
       buffer-string char-before constrain-to-field field-beginning field-end
       format format-message get-pos-property point-max point-min
       forward-line goto-char insert insert-and-inherit insert-buffer-substring
       line-beginning-position line-end-position line-number-at-pos message
       point propertize
       ;; the restriction
       narrow-to-region widen save-restriction buffer-size delete-region
       buffer-substring char-after
       ;; the labeled restrictions over it, and the redisplay's bracket
       with-restriction without-restriction buffer-narrowed-p
       point-min-marker point-max-marker %with-outermost-restrictions
       char-equal subst-char-in-region insert-before-markers-and-inherit)
 (only (schemacs undo)
       text-editor-undo-enable! text-editor-undo-list
       text-editor-undo-recording?)
 (only (schemacs marker) make-marker marker-position set-marker)
 (only (schemacs xdisp) *message-log-max*)
 (only (schemacs simple) messages-buffer messages-buffer-mode)
 (only (schemacs textprop) get-char-property get-text-property put-text-property)
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

;; `%s` of a buffer is its *name* - `princ`'s answer (`print.c:1895`,
;; "else print_string (BVAR (XBUFFER (obj), name), ...)") - and `%S`
;; keeps `prin1`'s `#<buffer NAME>`. Measured on Emacs 31.1.
(test-equal '("fmt-buffer-name" "#<buffer fmt-buffer-name>")
  (let ((b (get-buffer-create "fmt-buffer-name")))
    (list (format "%s" b) (format "%S" b))))

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

;; ------------------------------------------------------------------
;; `message' and the `*Messages*' buffer
;;
;; `message3' is `log_message' (the `*Messages*' buffer) and *then* the
;; display, and the log half is `xdisp.scm`'s `message_dolog` - a port of
;; the C's. Every expectation below is `emacs -Q --batch' on Emacs 31.1,
;; run over the same keys.
;;
;; The duplicate folding is the C's `message_log_check_duplicate`
;; (`xdisp.c:12535'), and it returns **N + 1** for a line that already
;; says " [N times]" - so the count grows. Ours returned N, and four
;; identical messages read "a [2 times]" where Emacs reads "a [4 times]".

(define (messages-text)
  (with-current-buffer (get-buffer "*Messages*") (buffer-string)))

(define (messages-erase!)
  ;; `messages-buffer' is the one that creates the buffer *and* switches
  ;; it to `messages-buffer-mode' - the mode `message_dolog' gives it when
  ;; it is the one that creates it (`xdisp.c:12368').
  (with-current-buffer (messages-buffer)
    ;; `parameterize', not `let': a `let' binding of a parameter name is a
    ;; silent no-op (`*inhibit-read-only*' is one).
    (parameterize ((*inhibit-read-only* #t)) (erase-buffer))))

;; Emacs, four times: `(dotimes (i 4) (message "a"))' -> "a [4 times]".
;; And a fifth is " [5 times]": the count is read back out of the line.
(test-equal "a [4 times]\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "a") (message "a") (message "a") (message "a")
      (messages-text))))
(test-equal "a [5 times]\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "a") (message "a") (message "a") (message "a") (message "a")
      (messages-text))))

;; Two different lines both stay, and a repeat folds onto the one before.
(test-equal "a [2 times]\nb\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "a") (message "a") (message "b")
      (messages-text))))

;; The C's `seen_dots` rule (`xdisp.c:12544`): a line that *differs* still
;; counts as a duplicate when the previous one had "..." just before the
;; difference - a continued line folds onto what it continues. Emacs
;; answers "abc...Q\n" for these two.
(test-equal "abc...Q\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "abc...xyz") (message "abc...Q")
      (messages-text))))

;; `message-log-max' is "Maximum number of lines to keep"; 2 keeps the
;; last two, which is Emacs's "m3\nm4\n" for five messages.
(test-equal "m3\nm4\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (parameterize ((*message-log-max* 2))
        (message "m0") (message "m1") (message "m2")
        (message "m3") (message "m4"))
      (messages-text))))

;; nil disables the log entirely, which is the variable's other documented
;; job - the same messages leave the buffer empty.
(test-equal ""
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (parameterize ((*message-log-max* #f))
        (message "suppressed"))
      (messages-text))))

;; An empty message *clears* the echo area and logs nothing - the C's
;; `message1 (0)' arm, which never reaches `message3'.
(test-equal ""
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "") (message #f)
      (messages-text))))

;; `messages-buffer-mode' is a `special-mode': the buffer is read-only and
;; the log writes to it anyway (`message_dolog' inserts with PREPARE false,
;; which is what skips the read-only check), and its name is the C's
;; `messages-buffer-name'.
(test-equal (list "*Messages*" 'messages-buffer-mode #t)
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (message "one")
      (with-current-buffer (get-buffer "*Messages*")
        (list (buffer-name (messages-buffer)) (major-mode) (buffer-read-only? (current-buffer)))))))

;; The log is written before the display, so a message the echo area is
;; told not to show still reaches `*Messages*' - `message3''s order.
(test-equal "hidden\n"
  (with-text "x"
    (lambda ()
      (messages-erase!)
      (parameterize ((*inhibit-message* #t)) (message "hidden"))
      (messages-text))))

;;--------------------------------------------------------------------
;; Fields: `editfns.c`'s `find_field` and the motion it constrains
;;
;; A field is a run of text with one `field' property value, and the two
;; line positions hand their answers to `constrain-to-field'. That is how
;; `C-a` in a minibuffer stops at the end of the prompt instead of at the
;; start of the line - which is the start of the prompt, where `C-k` then
;; killed it.
;;
;; Every expectation is `emacs -Q --batch` on the same buffer: "Find
;; file: " with `field', `rear-nonsticky' and `front-sticky' over it, and
;; "abc" inserted after it - which is exactly what `read_minibuf` builds.
;;------------------------------------------------------------------

(test-begin "schemacs_editor_editfns_fields")

(define (with-prompt thunk)
  ;; **`*current-buffer*` is bound as well as the frame**, which is the
  ;; hazard this file's other frame tests already document: a buffer a
  ;; previous test left pinned is what `(current-buffer)` answers, and the
  ;; commands under test - `line-beginning-position` among them - ask it.
  (let ((ed (allocate-buffer)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (with-current-buffer ed
        (insert "Find file: ")
        (put-text-property (point-min) (point-max) 'rear-nonsticky #t)
        (put-text-property (point-min) (point-max) 'front-sticky #t)
        (put-text-property (point-min) (point-max) 'field #t)
        (insert "abc"))
      (thunk ed))))

;; The prompt is a field and the input is not: an insertion at 12 would
;; inherit nothing, which is `get-pos-property` asking the stickiness
;; rules.
(test-equal '(#t #f #f)
  (with-prompt
   (lambda (ed)
     (list (get-char-property 1 'field ed)
           (get-char-property 12 'field ed)
           (get-pos-property 12 'field ed)))))

;; `field-beginning`/`field-end` around a position *after* the field:
;; without ESCAPE-FROM-EDGE the field being asked about is the one the
;; insertion at 12 would be in, which begins at 12.
(test-equal '(12 1 15)
  (with-prompt
   (lambda (ed)
     (list (field-beginning 12 #f 1)
           (field-beginning 12 #t 1)
           (field-end 12 #f 15)))))

;; ...and the two line positions, which are what the commands use. The
;; absent N and N = 1 are the same answer, and N = 0 escapes to the
;; previous line - past the field, because ONLY-IN-LINE would otherwise
;; stop it.
(test-equal '(12 12 15 1 15 12)
  (with-prompt
   (lambda (ed)
     (define (at n) (set-point ed n))
     (list (begin (at 12) (line-beginning-position))
           (begin (at 12) (line-beginning-position 1))
           (begin (at 12) (line-beginning-position 2))
           (begin (at 12) (line-beginning-position 0))
           (begin (at 12) (line-end-position))
           (begin (at 12) (line-end-position 0))))))

;; `constrain-to-field` itself: a position outside the field is pulled
;; back to the boundary, and the nil NEW-POS form moves point.
(test-equal '(12 12 12)
  (with-prompt
   (lambda (ed)
     (set-point ed 12)
     (let ((moved (constrain-to-field #f 12 #f #t #f)))
       (list moved (point) (constrain-to-field 1 12 #f #t #f))))))

(test-end "schemacs_editor_editfns_fields")


;; **Narrowing** - `narrow-to-region`/`widen`/`save-restriction`
;; (`editfns.c:2948`, `:2901`, `:3150`). `point-min` and `point-max`
;; answer the accessible portion, `goto-char` clips to it, an insertion at
;; ZV grows it, and `buffer-size` is the whole text while `buffer-string`
;; is the accessible one - every expectation measured on Emacs 31.1.
(test-begin "schemacs_editor_editfns_narrowing")

(define (narrow-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "hello world")
    b))

(test-equal '(1 12)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (list (point-min) (point-max))))

;; Narrowing clips point into the new range (`if (PT < s) SET_PT (s); if
;; (e < PT) SET_PT (e)`), and `goto-char` clips to the edges.
(test-equal '(3 8 8 3 8)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (goto-char 12)
    (narrow-to-region 3 8)
    (let ((min (point-min)) (max (point-max)) (pt (point)))
      (goto-char 1)
      (let ((low (point)))
        (goto-char 20)
        (list min max pt low (point))))))

;; An insertion inside the restriction grows ZV, and the text outside it
;; is untouched.
(test-equal '(3 10 "llo wXY")
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 3 8)
    (goto-char (point-max))
    (insert "XY")
    (list (point-min) (point-max) (buffer-string))))

;; `buffer-size` is the whole text: "Narrowing is in effect, this returns
;; the size of the accessible portion" was the *old* docstring - Emacs
;; answers `Z - BEG`, which is 11 here however narrow the restriction.
(test-equal '(11 4)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 1 5)
    (list (buffer-size) (string-length (buffer-string)))))

;; `widen` puts both ends back.
(test-equal '(1 12)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 3 8)
    (widen)
    (list (point-min) (point-max))))

;; `save-restriction` restores what was in effect when it was entered -
;; including after an error. Measured on Emacs 31.1: inside the outer
;; form the restriction is the one the inner `save-restriction` left,
;; `(2 3)`, and the outer one comes back when the outer form ends.
(test-equal '((1 5) (2 3) (2 3) (1 5))
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 1 5)
    (let ((before (list (point-min) (point-max))))
      (let ((inside+after
             (save-restriction
               (narrow-to-region 2 3)
               (let ((inside (list (point-min) (point-max))))
                 (guard (e (#t #f))
                   (save-restriction
                     (narrow-to-region 2 2)
                     (error "boom")))
                 (list inside (list (point-min) (point-max)))))))
        (list before (car inside+after) (cadr inside+after)
              (list (point-min) (point-max)))))))

;; `delete-region` calls `validate_region` (`buffer.c:2504`), which
;; *signals* when either end is outside the accessible portion - it does
;; not clip. Measured on Emacs 31.1: "Args out of range: #<buffer ...>,
;; 1, 12".
(test-equal '(args-out-of-range "hello world")
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 3 5)
    (let ((threw (guard (e (#t 'args-out-of-range))
                   (delete-region 1 12)
                   #f)))
      (widen)
      (list threw (buffer-string)))))

;; **`validate_region` is what `buffer-substring` opens with too**
;; (`editfns.c:1674`): a range that reaches outside the restriction
;; signals, and `char-after` outside it is nil rather than an error. Both
;; measured on Emacs 31.1 in a buffer narrowed to 3..5.
(test-equal '(args-out-of-range "ll" #f #f)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 3 5)
    (list (guard (e (#t 'args-out-of-range)) (buffer-substring 1 12))
          (buffer-substring 3 5)
          (char-after 1)
          (char-after 9))))

(test-equal 'args-out-of-range
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (guard (e (#t 'args-out-of-range))
      (narrow-to-region 1 99))))

;; `char-after`'s POSITION is optional (`editfns.c`'s
;; `(char-after &optional POSITION)') and nil means point; it took a
;; required argument until 2026-11-22. Measured on Emacs 31.1.
(test-equal '(#\e #\e #f)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (goto-char 2)
    (list (char-after) (char-after 2) (char-after 99))))

(test-end "schemacs_editor_editfns_narrowing")

;;--------------------------------------------------------------------
;; Labeled restrictions - `with-restriction` / `without-restriction`
;;
;; `editfns.c`'s stack of `(LABEL BEGV-MARKER ZV-MARKER)` triplets, the
;; two `internal--labeled-*` DEFUNs and the two `subr.el` macros over
;; them. **Every expectation below is `emacs -Q --batch`'s own answer**
;; on "a\nb\nc" (point-max 6), measured before the port.
;;--------------------------------------------------------------------

(define (label-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert "a\nb\nc")
    b))

(test-begin "schemacs_editor_editfns_labeled")

;; The plain form narrows, and leaving it restores the whole text.
(test-equal '((2 6) (1 6))
  (let ((b (label-buffer)))
    (set-buffer b)
    (list (with-restriction 2 6 (list (point-min) (point-max)))
          (list (point-min) (point-max)))))

;; `narrow-to-region` inside a label is clamped to the label's bounds:
;; measured, 1..5 inside 2..6 gives 2..5.
(test-equal '(2 5)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (narrow-to-region 1 5)
      (list (point-min) (point-max)))))

;; ...while a range outside the *text* is still args-out-of-range: the
;; C validates before it clamps (`editfns.c:2974` follows the check).
(test-equal "Args out of range"
  (let ((b (label-buffer)))
    (set-buffer b)
    (guard (e (#t (exception-message e)))
      (with-restriction 2 6 :label 'x (narrow-to-region 1 7)))))

;; `widen` inside a label restores the label's bounds, not the text's.
(test-equal '(2 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (widen)
      (list (point-min) (point-max)))))

;; `without-restriction` with the same label lifts it - the bounds go
;; back to the outermost restriction's, so the whole text; with a
;; different label it does not, and `widen` stays inside the label.
(test-equal '(1 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (without-restriction :label 'x
        (list (point-min) (point-max))))))
(test-equal '(2 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (without-restriction :label 'y
        (list (point-min) (point-max))))))

;; Nested labels: the inner one wins inside, the outer one after.
(test-equal '((3 5) (2 6))
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (list (with-restriction 3 5 :label 'y
              (list (point-min) (point-max)))
            (list (point-min) (point-max))))))

;; `save-restriction` saves the labels beside the bounds: measured, the
;; widen inside stays at (2 6) and so does the state after the restore.
(test-equal '((2 6) (2 6))
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (list (save-restriction (widen) (list (point-min) (point-max)))
            (list (point-min) (point-max))))))

;; `erase-buffer` drops the labels before it widens (`buffer.c:2490`) -
;; measured (1 1 nil): the text is gone, the buffer is not narrowed, and
;; nothing is left to widen to.
(test-equal '(1 1 #f)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (erase-buffer)
      (list (point-min) (point-max) (buffer-narrowed-p)))))

;; Point is pulled inside the labeled range, as `narrow-to-region` pulls.
(test-equal '(4 2 4)
  (let ((b (label-buffer)))
    (set-buffer b)
    (goto-char 6)
    (with-restriction 2 4 :label 'x
      (list (point) (point-min) (point-max)))))

;; The plain form leaves *no* label, so a `widen` inside it is full.
(test-equal '(1 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 (widen) (list (point-min) (point-max)))))

;; A label inside a user's own narrowing widens only to its own bounds.
(test-equal '((3 5) (2 6))
  (let ((b (label-buffer)))
    (set-buffer b)
    (narrow-to-region 2 6)
    (list (with-restriction 3 5 :label 'x (list (point-min) (point-max)))
          (list (point-min) (point-max)))))

;; After `without-restriction` pops the outermost triplet, `widen` is
;; the whole text.
(test-equal '(1 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (without-restriction :label 'x
        (begin (widen) (list (point-min) (point-max)))))))

;; `point-min-marker` / `point-max-marker` are the accessible bounds.
(test-equal '(2 6)
  (let ((b (label-buffer)))
    (set-buffer b)
    (narrow-to-region 2 6)
    (list (marker-position (point-min-marker))
          (marker-position (point-max-marker)))))

;; The redisplay's bracket (`reset_outermost_restrictions`,
;; `xdisp.c:17440`): the buffer is widened to the outermost bounds while
;; it runs, and the innermost labeled bounds are back afterwards. No
;; Emacs-level expectation exists - only redisplay runs the C - so this
;; pins the C's contract.
(test-equal '((1 6) (2 6))
  (let ((b (label-buffer)))
    (set-buffer b)
    (with-restriction 2 6 :label 'x
      (list (%with-outermost-restrictions
             (lambda () (list (point-min) (point-max))))
            (list (point-min) (point-max))))))

(test-end "schemacs_editor_editfns_labeled")

;;--------------------------------------------------------------------
;; `subst-char-in-region`, `char-equal` and `insert-before-markers`
;;--------------------------------------------------------------------
;; Every expectation below is Emacs 31.1's own answer for the same call,
;; measured with `emacs -Q --batch'.

(test-begin "schemacs_editor_editfns_subst")

(test-equal '(#f "hellX wXrld")
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (list (subst-char-in-region (point-min) (point-max) #\o #\X)
          (buffer-string))))

;; "Both characters must have the same length of multi-byte form" - a
;; one-byte character cannot be replaced by a three-byte one.
(test-equal "Characters in `subst-char-in-region' have different byte-lengths"
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (guard (e (#t (exception-message e)))
      (subst-char-in-region 1 12 #\a #\€))))

;; Inside a narrowing it changes only what the restriction reaches.
(test-equal "heXXo world"
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 1 5)
    (subst-char-in-region 1 5 #\l #\X)
    (widen)
    (buffer-string)))

;; ... and a range reaching outside it is `validate_region`'s signal,
;; which is "Args out of range: #<buffer>, 1, 10" in Emacs 31.1.
(test-equal 'args-out-of-range
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (narrow-to-region 1 5)
    (guard (e (#t 'args-out-of-range))
      (subst-char-in-region 1 10 #\l #\X))))

;; noundo: the text changes, the undo list does not.
(test-equal '(0 "")
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (text-editor-undo-enable! b)
    (subst-char-in-region 1 6 #\o #\X #t)
    (list (length (text-editor-undo-list b))
          (if (text-editor-undo-recording? b) "" "off"))))

(test-equal '(#t #t #f)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (list (char-equal #\a #\a)
          (char-equal #\a #\A)
          (parameterize ((*case-fold-search* #f))
            (char-equal #\a #\A)))))

;; Equal characters answer t whatever the folding says, because the C
;; tests equality first.
(test-equal #t
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (parameterize ((*case-fold-search* #f)) (char-equal #\a #\a))))

;; `insert-before-markers-and-inherit` moves a marker at point past the
;; inserted text; plain `insert` leaves it before.
(test-equal '(4 2)
  (let ((b (narrow-buffer)))
    (set-buffer b)
    (let ((m (make-marker)))
      (set-marker m 2)
      (goto-char 2)
      (insert-before-markers-and-inherit "ZZ")
      (let ((before (marker-position m)))
        (delete-region 2 4)
        (set-marker m 2)
        (goto-char 2)
        (insert "ZZ")
        (list before (marker-position m))))))

(test-end "schemacs_editor_editfns_subst")

;;--------------------------------------------------------------------
;; The log's own buffer: a message must not deactivate its mark
;;--------------------------------------------------------------------
;; `message_dolog` inserts with PREPARE false (`xdisp.c:12406`) and
;; saves/restores `Vdeactivate_mark` around the work (`:12359`, `:12526`).
;; Without both, a message logged *into the buffer being edited* -
;; `*Messages*` is the one buffer that always is - set that buffer's
;; `deactivate-mark`, and the command loop deactivated the region `C-SPC`
;; had just made: "mark and copy has no effect in the Messages buffer".
(test-begin "schemacs_editor_editfns_message_mark")
(test-equal "logging into the current buffer does not set deactivate-mark"
  '(#f #t)
  (with-text "x"
    (lambda ()
      (let ((m (get-buffer-create "*Messages*")))
        (with-current-buffer m
          (messages-buffer-mode)
          (set-buffer-local-value! m 'deactivate-mark #f)
          (set-buffer-local-value! m 'mark-active #t)
          (message "logged")
          (list (buffer-local-value m 'deactivate-mark #f)
                (buffer-local-value m 'mark-active #f)))))))
(test-end "schemacs_editor_editfns_message_mark")

(test-end "schemacs_editor_editfns")
