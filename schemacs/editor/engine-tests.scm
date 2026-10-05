(import
 (scheme base)
 (scheme file)
 (schemacs editor engine)
 (only (schemacs ui text-buffer-impl) text-location-line text-location-column)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; **Sample text**
;;
;; Welcome to Schemacs, an application platform written in, and
;; programmable in, the Scheme programming language and providing
;; compatibility with GNU Emacs applications. The goals of this
;; project are
;;
;;   - to use the latest R7RS language standard
;;
;;   - to grow the Scheme software ecosystem
;;
;;   - to provide an integrated development environment (IDE)
;;     for Scheme software that is similar to GNU Emacs
;;
;;   - to be able to emulate Emacs applications

(define (strconcat elems)
  (call-with-port (open-output-string)
    (lambda (port)
      (let loop ((elems elems))
        (cond
         ((pair? elems)
          (let ((elem (car elems)))
            (cond
             ((char? elem) (write-char elem port))
             ((string? elem) (write-string elem port))
             (else (write elem port))
             )
            (loop (cdr elems))
            ))
         (else (get-output-string port))
         )))))

(define (find-diff-char str buf)
  ;; Compare a text buffer to a string, return the index of the first
  ;; character where the two strings do not match. Returns three values:
  ;;
  ;;  1. the index where the characters do not match
  ;;  2. the character in the string
  ;;  3. the character in the buffer
  ;;
  ;; If the string and buffer have the same textual content, 1. will
  ;; be the length of the string and buffer (which will be the same)
  ;; and 2. and 3. will be `#f`.
  ;;
  ;; A string index counts from 0 and a buffer position from 1, so the
  ;; buffer is read one ahead of the string.
  (let*((strlen (string-length str))
	(buflen (text-editor-char-count buf))
	(len (min strlen buflen))
	)
    ;;(display "strlen=") (write strlen) (display ", buflen=") (write buflen) (newline);;DEBUG
    (let loop ((i 0))
      ;;(display "f[") (write i) (display "]: ");;DEBUG
      (cond
       ((< i len)
	(let ((str-ch (string-ref str i))
	      (buf-ch (text-editor-get-char-index buf (+ i 1)))
	      )
	  ;;(display "s=") (write str-ch) (display ", b=") (write buf-ch) (newline);;DEBUG
	  (cond
	   ((char=? str-ch buf-ch) (loop (+ 1 i)))
	   (else (values i str-ch buf-ch))
	   )))
       ((< i buflen)
	;;(display " end of string\n");;DEBUG
	(values i #f (text-editor-get-char-index buf (+ i 1)))
	)
       ((< i strlen)
	;;(display " end of buffer\n");;DEBUG
	(values i (string-ref str i) #f)
	)
       (else (values i #f #f))
       ))))

;;--------------------------------------------------------------------
;; 0. Constant definitions

(define *sample-text-1*
  '("Welcome to Schemacs," " an application platform written" " in, and" #\newline
    "programmable in," " the Scheme" " programming language" " and"
    " providing\ncompatibility with" " GNU Emacs applications." " The goals of"
    " this\nproject are:" #\newline #\newline
    "  - to use" " the latest" " R7RS" " language standard" #\newline #\newline
    "  - to grow the Scheme software ecosystem" #\newline #\newline
    "  - to provide an integrated" " development environment" " (IDE)" #\newline
    "    for Scheme software that" " is similar to GNU Emacs" #\newline #\newline
    "  - to be able" " to emulate" " Emacs applications\n"
   ))

(define *sample-string-1* (strconcat *sample-text-1*))

;;--------------------------------------------------------------------

(test-begin "schemacs_editor_engine")

;;--------------------------------------------------------------------
;; 1. record and playback: the simplest test
;;
;; Just checks that the most basic functionality works. Inserts a list
;; of strings and characters into the text editor buffer, moves the
;; cursor to the beginning, dumps the buffer back to a stirng, compares
;; the string 

(define ed (new-text-editor))

(define (gb-insert-list ed elems)
  (let loop ((elems elems))
    (cond
     ((pair? elems)
      ;; Write the sample text into the text editor buffer.
      (text-editor-insert ed (car elems))
      (loop (cdr elems))
      )
     (else
      (text-editor-to-string ed)
      ))))

(test-assert
  (let*((ed-str (gb-insert-list ed *sample-text-1*))
	(cat-str *sample-string-1*)
	)
    (cond
     ((string=? ed-str cat-str) #t)
     (else
      (display "test 1 \"record and playback\": strings not equal\n")
      (display "-----------------------\n")
      (display "original string:\n")
      (display "-----------------------\n")
      (display cat-str) (newline)
      (display "-----------------------\n")
      (display "editor string:\n")
      (display "-----------------------\n")
      (display ed-str) (newline)
      (display "-----------------------\n")
      #f))))

;;--------------------------------------------------------------------
;; 2. index-by-index comparison
;;
;; Checks if the character indexing functions are working. This tests
;; a number of features related to tracking the length of lines.

(test-assert
 (let-values
     (((index str-ch buf-ch)
       (find-diff-char *sample-string-1* ed)
       ))
   (not (or str-ch buf-ch))
   ))

;;--------------------------------------------------------------------
(test-end "schemacs_editor_engine")

;;--------------------------------------------------------------------
;; 3. regression tests: cursor motion, navigation, and line breaks
;;
;; These exercise the procedures which navigate and edit the text
;; editor buffer, including round-trips through `text-load-port` and
;; `text-dump-port`, and CRLF-protocol files.

(test-begin "schemacs_editor_engine_motion")

;; Round-trip a buffer whose last line has no terminating line break.
(test-equal "AAA\nBBB\nno-newline"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "AAA\nBBB\nno-newline")
    (text-editor-to-string ed)))

;; Round-trip a buffer with empty lines.
(test-equal "AAA\n\nBBB\n\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "AAA\n\nBBB\n\n")
    (text-editor-to-string ed)))

;; Move the cursor to the start of the buffer, insert text, jump to a
;; middle line, insert, move to the end, insert. Verify nothing is
;; lost or misplaced.
(test-equal "SAAA\nB1BB\nCCC\nDDD\nE"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "AAA\nBBB\nCCC\nDDD\n")
    (text-editor-move-cursor ed -100)
    (text-editor-insert ed "S")
    (text-editor-set-cursor ed 2 1)
    (text-editor-insert ed "1")
    (text-editor-move-cursor ed 100)
    (text-editor-insert ed "E")
    (text-editor-to-string ed)))

;; A line break in the middle of a line splits the line, keeping the
;; characters after the cursor on the new current line.
(test-equal "HELLOW\nORLD\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "HELLOWORLD\n")
    (text-editor-move-cursor ed -5)
    (text-editor-insert ed "\n")
    (text-editor-to-string ed)))

;; Editing the last line of a buffer which does not end in a line
;; break must not introduce a line break.
(test-equal "aaa\nbbb\nc!cc"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "aaa\nbbb\n")
    (text-editor-insert ed "ccc")
    (text-editor-move-cursor ed -2)
    (text-editor-insert ed "!")
    (text-editor-to-string ed)))

;; A CRLF-protocol file must round-trip, including after edits.
(test-equal "one\r\ntwo\r\nthrXee\r\n"
  (let ((ed (new-text-editor line-break-crlf)))
    (text-editor-insert ed "one\r\ntwo\r\nthree\r\n")
    (text-editor-move-cursor ed -4)
    (text-editor-insert ed "X")
    (text-editor-to-string ed)))

;; A mid-line break in a CRLF-protocol file splits into two CRLF
;; lines.
(test-equal "HELLO\r\nWORLD\r\n"
  (let ((ed (new-text-editor line-break-crlf)))
    (text-editor-insert ed "HELLOWORLD\r\n")
    (text-editor-move-cursor ed -7)
    (text-editor-insert ed "\r\n")
    (text-editor-to-string ed)))

;; Cursor motion: the position tracks a sequence of moves and inserts.
;; START is `point-min', 1 - Emacs's coordinate, not an index - and the
;; second line's third character is position 9.
(test-assert
 (let ((ed (new-text-editor)))
   (text-editor-insert ed "alpha\nbeta\ngamma\n")
   ;; move to start
   (text-editor-move-cursor ed -100)
   (let ((start (text-editor-get-cursor ed)))
     (text-editor-set-cursor ed 2 2)
     (let ((mid (text-editor-get-cursor ed)))
       (and (= 1 start) (= 9 mid))))))

;; Deleting characters within a line.
(test-equal "hello\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello world\n")
    (text-editor-move-cursor ed -100)
    (text-editor-move-cursor ed 5)
    (text-editor-delete-from-cursor ed 6)
    (text-editor-to-string ed)))

;; Backward delete at the start of a line merges with the line before,
;; and leaves the cursor where the line break was.
(test-equal "alphabeta\ngamma\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha\nbeta\ngamma\n")
    (text-editor-set-cursor ed 2 0)
    (text-editor-delete-from-cursor ed -1)
    (text-editor-to-string ed)))

;; Forward delete past the end of a line merges with the next line,
;; counting the line break as one deleted character.
(test-equal "alphata\ngamma\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha\nbeta\ngamma\n")
    (text-editor-set-cursor ed 0 5)
    (text-editor-delete-from-cursor ed 3)
    (text-editor-to-string ed)))

;; A deletion spanning multiple lines merges and deletes.
(test-equal "alphagamma\n"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha\nbeta\ngamma\n")
    (text-editor-set-cursor ed 1 5)
    (text-editor-delete-from-cursor ed 6)
    (text-editor-to-string ed)))

(test-end "schemacs_editor_engine_motion")

;;--------------------------------------------------------------------
;; 4. regression tests: character indexing and copying
;;
;; These were written against the CDF, which read the line containing an
;; index out of a bucket table and reported every index that began a
;; line as out of bounds. The CDF is gone; an index is a `buffer-text'
;; position now, one-based as Emacs's are, and these check the same
;; things it did - that the first character of the buffer and of every
;; line is where it should be, and that a whole-buffer copy keeps it.

(test-begin "schemacs_editor_engine_char_index")

;; The first character of a single-line buffer - position 1, which is
;; `point-min'.
(test-equal #\X
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "X")
    (text-editor-set-cursor ed 1 0)
    (text-editor-get-char-index ed 1)))

;; Copying a whole single-line buffer keeps its first character.
(test-equal "one two"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "one two")
    (text-editor-set-cursor ed 1 0)
    (text-editor-copy-string ed 1 8)))

;; The first character of every line: position 5 begins the second line
;; and position 10 the third.
(test-equal '(#\a #\d #\h)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc\ndefg\nhi")
    (text-editor-set-cursor ed 1 0)
    (map (lambda (i) (text-editor-get-char-index ed i)) '(1 5 10))))

;; An index past the end of the buffer is still unresolvable.
(test-equal #f
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 0 0)
    (text-editor-get-char-index ed 4)))

(test-end "schemacs_editor_engine_char_index")

;;--------------------------------------------------------------------
;; 5. undo
;;
;; The undo list is GNU Emacs's `buffer-undo-list': newest entry first,
;; `(BEG . END)' for an insertion, `(TEXT . POS)' for a deletion, and
;; `()' for a boundary. The tests undo the way Emacs's `undo' command
;; does - strip the boundary the command loop left at the front, then
;; hand the rest to `text-editor-undo' - which is what the frontend does.

(test-begin "schemacs_editor_engine_undo")

(define (strip-boundaries list)
  (let loop ((list list))
    (if (and (pair? list) (null? (car list))) (loop (cdr list)) list)))

;; The command loop's half of the protocol, as the frontend implements
;; it: a run of undo commands keeps walking a saved tail
;; (`pending-undo-list'), because the records the undo itself creates -
;; which are the redo records - go to the front of the buffer's list and
;; must not be walked again. Without this, a second undo would redo.
(define *pending* (make-parameter #f))
(define *last-command* (make-parameter #f))

(define (undo-command! ed n)
  (let* ((pending (if (eq? (*last-command*) 'undo)
                      (*pending*)
                      (strip-boundaries (text-editor-undo-list ed))))
         (rest (text-editor-undo ed pending n)))
    (*pending* (if (null? rest) #f rest))
    (*last-command* 'undo)))

(define (redo-command! ed n)
  ;; Redoing is undoing the redo records at the front of the list.
  (text-editor-undo ed (strip-boundaries (text-editor-undo-list ed)) n))

(define (undo! ed n)
  ;; A single, isolated undo command (no chain).
  (parameterize ((*pending* #f) (*last-command* #f))
    (undo-command! ed n)))

;; An insertion is recorded as the range of characters it occupies, and
;; undoing it deletes that range.
(test-equal '((1 . 4) (t . 0))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-list ed)))

(test-equal '("" 1)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 1 0)
    (undo! ed 1)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

;; A deletion is recorded with the deleted text, so undo can put it
;; back without having to recover it from the buffer - which is what
;; makes undoing the deletion of a line break work.
(test-equal 6
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello\nworld")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (cdr (car (text-editor-undo-list ed)))))

(test-equal (list (cons (string #\newline) 6))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello\nworld")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (list (car (text-editor-undo-list ed)))))

(test-equal '("hello\nworld" 6)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello\nworld")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (undo! ed 1)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

;; Undo, redo, undo: the records an undo creates are ordinary entries at
;; the front of the list, so redoing is undoing them. Round-tripping
;; must be stable: delete, undo, redo, undo must visit the same two
;; states in alternation.
(test-equal '("helloworld" "hello\nworld" "hello\nworld")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello\nworld")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (undo! ed 1)                       ; undo the deletion
    (let ((after-undo (text-editor-to-string ed)))
      (redo-command! ed 1)             ; put the deletion back
      (list (text-editor-to-string ed)
            after-undo
            (begin (undo! ed 1) (text-editor-to-string ed))))))

;; A boundary ends a change group. Inserting, bounding, then inserting
;; again gives two steps, and each undo command takes one of them - the
;; second one walking the saved tail rather than the front of the list.
(test-equal '("abc" "")
  (parameterize ((*pending* #f) (*last-command* #f))
    (let ((ed (new-text-editor)))
      (text-editor-insert ed "abc")
      (text-editor-undo-boundary! ed)
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed "def")
      (let ((one (begin (undo-command! ed 1) (text-editor-to-string ed))))
        (list one (begin (undo-command! ed 1) (text-editor-to-string ed)))))))

;; Undoing past the oldest change reports nothing more to undo, because
;; there is no tail left to walk.
(test-equal '(#f "")
  (parameterize ((*pending* #f) (*last-command* #f))
    (let ((ed (new-text-editor)))
      (text-editor-insert ed "abc")
      (undo-command! ed 1)
      (list (*pending*) (text-editor-to-string ed)))))

;; A boundary is never recorded twice in a row, nor at the front of an
;; empty list (mg's rule), so the grouping cannot be split by accident.
(test-equal '(() (1 . 4) (t . 0))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-boundary! ed)
    (text-editor-undo-boundary! ed)
    (text-editor-undo-list ed)))

;; Adjacent insertions grow one entry rather than adding one each, the
;; way Emacs's `record_insert' and mg's `undo_add_insert' do.
(test-equal '((1 . 7) (t . 0))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-insert ed "def")
    (text-editor-undo-list ed)))

;; An insertion that does not abut the previous one starts a new entry,
;; rather than being folded into it.
(test-equal '((2 . 3) (1 . 4) (t . 0))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 2)
    (text-editor-insert ed "X")
    (text-editor-undo-list ed)))

;; Deletion is clamped, so what is recorded is what was really there:
;; deleting 100 characters of a 3-character buffer records 3, and undo
;; restores 3.
(test-equal '("abc" . 1)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 1 0)
    (text-editor-delete-from-cursor ed 100)
    (car (text-editor-undo-list ed))))

(test-equal "abc"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 0 0)
    (text-editor-delete-from-cursor ed 100)
    (undo! ed 1)
    (text-editor-to-string ed)))

;; A forward deletion records a positive POS (point was at the beginning
;; of the deleted text) and undo leaves point there; a backward deletion
;; records a negative POS (point was at the end) and undo leaves point
;; at the end of the restored text.
(test-equal 1
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 1)
    (text-editor-delete-from-cursor ed 2)
    (cdr (car (text-editor-undo-list ed)))))

(test-equal -1
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -2)
    (cdr (car (text-editor-undo-list ed)))))

(test-equal '("abcd" 3)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -2)
    (undo! ed 1)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

(test-equal '("abcd" 1)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 1)
    (text-editor-delete-from-cursor ed 2)
    (undo! ed 1)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

;; Reading a file records the insertion like any other, which is what
;; GNU Emacs's `insert-file-contents' does - its `buffer-undo-list'
;; after a 12-character read is `((1 . 13) (t . 0))', and so is this.
;; It is the *visit* that leaves nothing to undo, and that is
;; `find-file-noselect''s doing (`empty_undo_list_p', fileio.c:4125).
(test-equal '(((1 . 13) (t . 0)) "loaded\ntext\n")
  (let ((ed (new-text-editor)))
    (call-with-output-file "/tmp/schemacs-undo-test.txt"
      (lambda (port) (display "loaded\ntext\n" port)))
    (call-with-input-file "/tmp/schemacs-undo-test.txt"
      (lambda (port) (text-load-port ed port)))
    (list (text-editor-undo-list ed) (text-editor-to-string ed))))

;; Disabling undo drops the list and stops recording; enabling it again
;; starts a fresh, empty list (Emacs's `buffer-disable-undo' sets
;; `buffer-undo-list' to t, and `buffer-enable-undo' sets it to nil).
(test-equal '(#f 3 () ((4 . 8)))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-disable! ed)
    (let ((disabled (list (text-editor-undo-recording? ed)
                          (text-editor-char-count ed))))
      (text-editor-undo-enable! ed)
      (let ((enabled (text-editor-undo-list ed)))
        (text-editor-insert ed "wxyz")
        (append disabled
                (list enabled (text-editor-undo-list ed)))))))

;; The undo list is bounded: past `*undo-limit*' the OLDEST change
;; groups are dropped, never the newest, and never part of a group.
;; (Emacs' own policy is three-tiered and measured in bytes; this is the
;; simplified stand-in, so the test pins the direction of the trimming
;; rather than Emacs' exact thresholds.)
(test-equal '((4 . 5) () (3 . 4) () (2 . 3))
  (parameterize ((*undo-limit* 6))
    (let ((ed (new-text-editor)))
      (text-editor-insert ed "A")
      (let loop ((i 0))
        (when (< i 3)
          (text-editor-undo-boundary! ed)
          (text-editor-insert ed (number->string i))
          (loop (+ 1 i))))
      (text-editor-undo-list ed))))

;; Recording stays enabled when the list is trimmed away entirely: an
;; empty list is "nothing to undo yet", which is not the same as the
;; recording being switched off.
(test-equal #t
  (parameterize ((*undo-limit* 1))
    (let ((ed (new-text-editor)))
      (text-editor-insert ed "abc")
      (text-editor-undo-boundary! ed)
      (text-editor-insert ed "def")
      (text-editor-undo-recording? ed))))

(test-end "schemacs_editor_engine_undo")

;;--------------------------------------------------------------------
;; 6. the modified flag
;;
;; GNU Emacs's `buffer-modified-p': a buffer is modified when it has
;; changed since it was last saved or visited. It is cleared by saving
;; and by undoing back past every change made since the last save, which
;; is why the undo list carries a `(t . TOKEN)' mark of the last save.

(test-begin "schemacs_editor_engine_modified")

;; A fresh buffer has nothing to differ from its file.
(test-equal #f (text-editor-modified? (new-text-editor)))

;; Changing it marks it modified, and records where it was last in sync
;; so that undoing back there can unmark it.
(test-equal '(#t ((1 . 4) (t . 0)))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (list (text-editor-modified? ed) (text-editor-undo-list ed))))

;; Inserting nothing is not a change.
(test-equal #f
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "")
    (text-editor-modified? ed)))

;; Deleting nothing is not a change either (there is nothing after the
;; cursor to delete).
(test-equal #f
  (let ((ed (new-text-editor)))
    (text-editor-delete-from-cursor ed 5)
    (text-editor-modified? ed)))

;; Saving clears the flag and leaves the undo list alone, as in GNU
;; Emacs: the record of where the buffer was last in sync is what makes
;; undo able to clear the flag again later.
(test-equal '(#f ((1 . 6) (t . 0)))
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello")
    (text-editor-set-modified! ed #f)
    (list (text-editor-modified? ed) (text-editor-undo-list ed))))

;; Saving a buffer that is already unmodified changes nothing.
(test-equal '(#f 0)
  (let ((ed (new-text-editor)))
    (text-editor-set-modified! ed #f)
    (list (text-editor-modified? ed) (text-editor-save-token ed))))

;; Undoing back to the saved state makes the buffer unmodified again,
;; and redoing makes it modified again.
(test-equal '(#t #f "hello" #t "ahello")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "hello")        ; visit
    (text-editor-set-modified! ed #f)
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 0 0)
    (text-editor-insert ed "a")            ; the change to be undone
    (let ((before (text-editor-modified? ed)))
      (undo! ed 1)
      (let ((after (list (text-editor-modified? ed)
                         (text-editor-to-string ed))))
        (text-editor-undo ed (strip-boundaries
                              (text-editor-undo-list ed)) 1)  ; redo
        (append (list before) after
                (list (text-editor-modified? ed)
                      (text-editor-to-string ed)))))))

;; Undoing PAST the saved state leaves the buffer modified: the file
;; being saved at one point does not make the buffer match it at an
;; earlier point. This is what the token in the mark is for - Emacs
;; compares the visited file's modification time for the same reason.
(test-equal '(#f #t)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-modified! ed #f)        ; saved here: the file has "abc"
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (text-editor-insert ed "x")              ; now "abcx"
    (undo! ed 1)                             ; back to "abc" == the file
    (let ((at-save-point (text-editor-modified? ed)))
      (undo! ed 1)                           ; back past the save, to ""
      (list at-save-point (text-editor-modified? ed)))))

;; The flag works even when undo recording is switched off: it is a
;; property of the buffer, not of the undo list.
(test-equal '(#t #f)
  (let ((ed (new-text-editor)))
    (text-editor-undo-disable! ed)
    (text-editor-insert ed "abc")
    (let ((modified (text-editor-modified? ed)))
      (text-editor-set-modified! ed #f)
      (list modified (text-editor-modified? ed)))))

(test-end "schemacs_editor_engine_modified")

;;--------------------------------------------------------------------
;; 7. read-only buffers
;;
;; GNU Emacs's `buffer-read-only': while it is set the buffer refuses to
;; be changed at all - by typing, by deleting, and by undo, which is an
;; edit like any other.

(test-begin "schemacs_editor_engine_read_only")

(define (refused? thunk)
  ;; Whether THUNK signals an error, which is how a read-only buffer
  ;; refuses an edit.
  (guard (ex (else #t)) (thunk) #f))

(test-equal #f (text-editor-read-only? (new-text-editor)))

(test-equal '(#t #f)
  (let ((ed (new-text-editor)))
    (text-editor-set-read-only! ed #t)
    (let ((set (text-editor-read-only? ed)))
      (text-editor-set-read-only! ed #f)
      (list set (text-editor-read-only? ed)))))

;; Insertion is refused, and changes nothing.
(test-equal '(#t "abc")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (text-editor-set-cursor ed 0 0)
    (let ((refused (refused? (lambda () (text-editor-insert ed "X")))))
      (list refused (text-editor-to-string ed)))))

;; Deletion is refused, and changes nothing.
(test-equal '(#t "abc")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (text-editor-set-cursor ed 0 0)
    (let ((refused (refused? (lambda () (text-editor-delete-from-cursor ed 2)))))
      (list refused (text-editor-to-string ed)))))

;; Deleting nothing is not an edit, so it is not refused - there is
;; nothing to refuse.
(test-equal '(#f "abc")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (text-editor-set-cursor ed 0 0)
    (let ((refused (refused? (lambda () (text-editor-delete-from-cursor ed 0)))))
      (list refused (text-editor-to-string ed)))))

;; Undo is refused too, and refuses before it starts: a half-undone
;; change would be worse than none. (GNU Emacs's `undo' has the `*' in
;; its interactive spec that refuses a read-only buffer.)
(test-equal '(#t "Xabc")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 0 0)
    (text-editor-insert ed "X")
    (text-editor-set-read-only! ed #t)
    (let ((refused
           (refused? (lambda ()
                       (text-editor-undo ed
                                         (strip-boundaries
                                          (text-editor-undo-list ed))
                                         1)))))
      (list refused (text-editor-to-string ed)))))

;; Reading is unaffected: a read-only buffer can still be read.
(test-equal '("abc" 3)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (list (text-editor-to-string ed) (text-editor-char-count ed))))

;; Read-only and modified are independent: saving a buffer does not
;; change whether it refuses edits, and a read-only buffer can be
;; modified (by marking it so) without becoming editable.
(test-equal '(#f #t #t #t)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (text-editor-set-modified! ed #f)
    (let ((read-only (text-editor-read-only? ed))
          (unmodified (text-editor-modified? ed)))
      (text-editor-set-modified! ed #t)
      (list unmodified read-only
            (text-editor-modified? ed)
            (text-editor-read-only? ed)))))

;; Turning it off again lets the buffer be edited.
(test-equal '("Xabc" #f)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-read-only! ed #t)
    (text-editor-set-cursor ed 0 0)
    (text-editor-set-read-only! ed #f)
    (text-editor-insert ed "X")
    (list (text-editor-to-string ed) (text-editor-read-only? ed))))

(test-end "schemacs_editor_engine_read_only")

;;--------------------------------------------------------------------
;; 8. searching, and the mark
;;
;; `text-editor-search-forward' and `text-editor-search-backward' are
;; GNU Emacs's `search-forward' and `search-backward' (mg's
;; forwsrch/backsrch): they report where point would be left - past the
;; match forwards, at its start backwards. A line break counts as one
;; #\newline whichever line-break protocol the buffer uses, which is what
;; makes a match that spans lines findable.

(test-begin "schemacs_editor_engine_search")

(define (searchable)
  ;; "alpha beta gamma\nbeta delta\n": the two "beta"s are at 7..10 and
  ;; 18..21, and "gamma\nbeta" spans a line break.
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha beta gamma\nbeta delta\n")
    ed))

;; Forward: the position just past the match.
(test-equal 11 (text-editor-search-forward (searchable) "beta" 1 #t))
(test-equal 22 (text-editor-search-forward (searchable) "beta" 12 #t))

;; ... including when the search starts in the middle of the buffer, and
;; when it starts at a line break.
(test-equal 22 (text-editor-search-forward (searchable) "beta" 17 #t))
(test-equal #f (text-editor-search-forward (searchable) "beta" 23 #t))

;; Backward: the position of the start of the match.
(test-equal 7 (text-editor-search-backward (searchable) "beta" 17 #t))
(test-equal 7 (text-editor-search-backward (searchable) "beta" 11 #t))
(test-equal #f (text-editor-search-backward (searchable) "beta" 7 #t))

;; A match that spans a line break.
(test-equal 22 (text-editor-search-forward (searchable) "gamma\nbeta" 1 #t))
(test-equal 12 (text-editor-search-backward (searchable) "gamma\nbeta" 28 #t))

;; Case folding is the caller's choice, as it is for Emacs's
;; `search-forward', which only obeys `case-fold-search'.
(test-equal 11 (text-editor-search-forward (searchable) "BETA" 1 #t))
(test-equal #f (text-editor-search-forward (searchable) "BETA" 1 #f))

;; An empty search string finds nothing: it means "no search yet" to the
;; incremental search.
(test-equal #f (text-editor-search-forward (searchable) "" 1 #t))
(test-equal #f (text-editor-search-backward (searchable) "" 11 #t))

;; A pattern that would run off the end of the buffer finds nothing,
;; rather than reading past it. ("delta\n" IS there, at 22..28; two line
;; breaks are not.)
(test-equal 29 (text-editor-search-forward (searchable) "delta\n" 23 #t))
(test-equal #f (text-editor-search-forward (searchable) "delta\n\n" 23 #t))

;; The mark starts unset, and holds a character index once set.
(test-equal '(#f 7)
  (let ((ed (searchable)))
    (let ((unset (text-editor-mark ed)))
      (set!text-editor-mark ed 7)
      (list unset (text-editor-mark ed)))))

(test-end "schemacs_editor_engine_search")

;;--------------------------------------------------------------------
;; 9. regression tests: where the end of the buffer is
;;
;; A buffer whose last line has no line break after it has no line
;; beyond that one, and GNU Emacs puts `point-max' at the end of it.
;; `text-editor-index-line-offset` reported such a position on an empty
;; line past the end instead - a line the buffer does not have, and one
;; `text-editor-line-count` does not count - which made `C-e' leave
;; point where `beginning-of-line' could not reach: the start of the
;; empty line was the position point was already at, so `C-e' then
;; `C-a' moved point nowhere, and the mode line read `L2 C1' for a file
;; of one line. `text-editor-set-cursor' likewise let a line index past
;; the end through, so `next-line' at the last line of such a buffer
;; moved point off the end of the text altogether.

(test-begin "schemacs_editor_engine_end_of_buffer")

;; The end of a buffer with no trailing line break is the end of its
;; last line, not a line of its own.
(test-equal '(1 1 3 1 4)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-move-cursor ed 100)
    (list (text-editor-line-count ed)
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed)
          (text-editor-get-start-of-line ed)
          (text-editor-get-end-of-line ed))))

;; ... and the 1-based line and column the mode line shows agree.
(test-equal '(1 4)
  (let* ((ed (new-text-editor))
         (at (begin (text-editor-insert ed "abc")
                    (text-editor-move-cursor ed 100)
                    (text-editor-get-line-column ed))))
    (list (text-location-line at) (text-location-column at))))

;; Point at that end still reaches the beginning of the line, which is
;; what `C-e' then `C-a' does.
(test-equal 1
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-move-cursor ed 100)
    (text-editor-set-cursor ed (text-editor-get-end-of-line ed))
    (text-editor-set-cursor ed (text-editor-get-start-of-line ed))
    (text-editor-get-cursor ed)))

;; A line break at the end of the buffer does start a line: the buffer
;; has two lines and the empty one gets `point-max'.
(test-equal '(2 2 0 5 5)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc\n")
    (text-editor-move-cursor ed 100)
    (list (text-editor-line-count ed)
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed)
          (text-editor-get-start-of-line ed)
          (text-editor-get-end-of-line ed))))

;; A line number past the end of the buffer is `goto-line''s case, and
;; GNU Emacs moves point to the end of the buffer there - `forward-line'
;; with a count it cannot fulfil leaves point at `point-max'. Emacs:
;; `(goto-line 2)' in a buffer holding "abc" puts point at 4, line 1,
;; column 3, which is exactly this.
(test-equal '(1 4 3)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 2 0)
    (list (text-editor-cursor-line ed)
          (text-editor-get-cursor ed)
          (text-editor-char-count ed))))

;; With a line break at the end there is: the empty line the break
;; started is addressable, at the position the break ends at.
(test-equal '(2 5 2)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc\n")
    (text-editor-set-cursor ed 2 0)
    (list (text-editor-cursor-line ed)
          (text-editor-get-cursor ed)
          (text-editor-line-count ed))))

;; Typing a line break at the end of a buffer with no trailing break
;; starts a line, and point is on it.
(test-equal '(2 2 0)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc")
    (text-editor-move-cursor ed 100)
    (text-editor-insert ed "\n")
    (list (text-editor-line-count ed)
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; So does accepting a file whose text ends in a line break, and its
;; end is the empty line the break started.
(test-equal '(3 3 0)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "one\ntwo\n")
    (text-editor-move-cursor ed 100)
    (list (text-editor-line-count ed)
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; The end of a buffer with no trailing line break is the end of its
;; last line, and the engine's own state has to agree with that - not
;; just the line and column it reports. It used to append the line it
;; was editing and advance to an empty line past the end, which is a
;; line the buffer does not have: the line editor then held an empty
;; line, so `TEXT-EDITOR-CURSOR-COLUMN' answered 0 where Emacs answers 4,
;; `TEXT-EDITOR-LINE-COUNT' counted a line Emacs does not, and a
;; backwards deletion there took its line-merging path and deleted one
;; character fewer than it reported (which the undo entry then recorded
;; wrongly). The values below are what a real Emacs reports for the same
;; operations.

;; One line, and the cursor at the end of it - position 5, which is
;; `point-max', column 4 as Emacs counts it.
(test-equal '(1 4 5)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-set-cursor ed 5)
    (list (text-editor-line-count ed)
          (text-editor-cursor-column ed)
          (text-editor-get-cursor ed))))

;; Deleting backwards at the end takes the two characters before it:
;; Emacs: "abcd" with point at the end and `(delete-char -2)' is "ab"
;; with point 3.
(test-equal '("ab" 3 2)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-set-cursor ed 5)
    (let ((deleted (text-editor-delete-from-cursor ed -2)))
      (list (text-editor-to-string ed)
            (text-editor-get-cursor ed)
            deleted))))

;; ... and the deletion is recorded as what was really deleted, so
;; undoing it gives the buffer back: before this was fixed the entry said
;; two characters where one had gone, and undo corrupted the buffer.
(test-equal "abcd"
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (text-editor-set-cursor ed 4)
    (text-editor-undo-boundary! ed)
    (text-editor-delete-from-cursor ed -2)
    (text-editor-undo ed (text-editor-undo-list ed) 1)
    (text-editor-to-string ed)))

;; A buffer whose last line does end in a line break does have an empty
;; line after it, and the cursor can be on it: Emacs: "abcd\n" has two
;; lines and `(point-max)' is on the second.
(test-equal '(2 2 0)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd\n")
    (list (text-editor-line-count ed)
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; ... and deleting backwards there takes the break and the character
;; before it: Emacs: "abcd\n" with point at the end and
;; `(delete-char -2)' is "abc".
(test-equal '("abc" 4)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcd\n")
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed -2)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

;; Writing a line back while the cursor is in the middle of it leaves the
;; cursor there: Emacs: point after inserting "X" at position 3 of
;; "abcdef" is 4, and stays 4 while the buffer is read.
(test-equal '("abXcdef" 4 4)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (text-editor-set-cursor ed 3)          ; writes the line back
    (text-editor-insert ed "X")            ; the line is changed again
    (let ((before (text-editor-get-cursor ed)))
      (text-editor-copy-string ed 1 8)     ; a read, which writes back
      (list (text-editor-to-string ed) before (text-editor-get-cursor ed)))))

;; Deleting backwards in the middle of a line was always right, and stays
;; right: Emacs: point 3 of "abcdef" with `(delete-char -1)' is "acdef"
;; with point 2.
(test-equal '("acdef" 2)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -1)
    (list (text-editor-to-string ed) (text-editor-get-cursor ed))))

(test-end "schemacs_editor_engine_end_of_buffer")

;;--------------------------------------------------------------------
;; 10. the buffer's identity
;;
;; GNU Emacs keeps the buffer's name (`buffer-name') and the file it
;; visits (`buffer-file-name') on the buffer, not on the window: two
;; windows can show the same buffer, and a window can show a buffer
;; that visits no file at all. The mode line names the buffer (Emacs's
;; `%b'), and saving writes the file it visits.

(test-begin "schemacs_editor_engine_buffer_identity")

;; A new buffer is named as `generate-new-buffer' names one, and visits
;; no file.
(test-equal '("Untitled" #f)
  (let ((ed (new-text-editor)))
    (list (text-editor-buffer-name ed) (text-editor-file-name ed))))

;; Both are the buffer's own to set.
(test-equal '("scratch.md" "/tmp/x/scratch.md")
  (let ((ed (new-text-editor)))
    (set!text-editor-buffer-name ed "scratch.md")
    (set!text-editor-file-name ed "/tmp/x/scratch.md")
    (list (text-editor-buffer-name ed) (text-editor-file-name ed))))

;; The identity is independent of the text: loading a file into a
;; buffer does not name it, and naming it does not touch the text.
(test-equal '("alpha" "Untitled" 5)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha")
    (list (text-editor-to-string ed)
          (text-editor-buffer-name ed)
          (text-editor-char-count ed))))

;; A buffer with no file can be named after something that is not a
;; file at all - "*Completions*" - which is what a window showing one
;; puts in its mode line.
(test-equal "*Completions*"
  (let ((ed (new-text-editor)))
    (set!text-editor-buffer-name ed "*Completions*")
    (text-editor-buffer-name ed)))

(test-end "schemacs_editor_engine_buffer_identity")

;;--------------------------------------------------------------------
;; 11. markers: positions that follow the text
;;
;; GNU Emacs keeps a buffer's markers in a chain that the insert and
;; delete code adjusts, so a marker goes on pointing at the same
;; character as the text around it moves. The expectations below are
;; what a real Emacs reports for the same operations (`emacs --batch`,
;; checked one by one), which is the only way to be sure the boundary
;; rules are the same ones.

(test-begin "schemacs_editor_engine_markers")

;; A marker made with no buffer points nowhere, and reports nowhere.
(test-equal '(#f #f #t)
  (let ((m (new-marker)))
    (list (marker-position m) (marker-buffer m) (marker-type? m))))

;; A marker at index 3 of "abcdef" reports that, and its buffer.
(test-equal '(3 #t)
  (let* ((ed (new-text-editor))
         (m (begin (text-editor-insert ed "abcdef") (copy-marker ed 3))))
    (list (marker-position m) (eq? ed (marker-buffer m)))))

;; Text inserted BEFORE a marker carries it along: Emacs: a marker at 3
;; with "XY" inserted at 1 is at 5.
(test-equal 5
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 3)))
      (text-editor-set-cursor ed 1)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Text inserted AFTER a marker leaves it alone.
(test-equal 3
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 3)))
      (text-editor-move-cursor ed 100)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Text inserted EXACTLY at a marker is the boundary case: the default
;; marker (insertion type false) stays put and the text lands after it -
;; Emacs: a marker at 3, "XY" inserted at 3, is still at 3 in "abXYcd".
(test-equal '(3 "abXYcd")
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (let ((m (copy-marker ed 3)))
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed "XY")
      (list (marker-position m) (text-editor-to-string ed)))))

;; ... and one whose insertion type is true advances past it: Emacs: the
;; same case gives 5.
(test-equal 5
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (let ((m (copy-marker ed 3 #t)))
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Deletion does not shift markers, it collapses the ones inside the
;; deleted text to its start: Emacs: delete the three characters from
;; position 2 of "abcdef" with a marker at 4 leaves "aef" and the marker
;; collapsed to 2.
(test-equal '(2 "aef")
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 4)))
      (text-editor-set-cursor ed 2)
      (text-editor-delete-from-cursor ed 3)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A marker after the deleted text moves back by its length; one at the
;; far end of it does too.
(test-equal '(2 3)
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((at-end (copy-marker ed 5)) (after (copy-marker ed 6)))
      (text-editor-set-cursor ed 2)
      (text-editor-delete-from-cursor ed 3)
      (list (marker-position at-end) (marker-position after)))))

;; Deleting backwards takes the text before the cursor: Emacs: "abcdef"
;; with point at 5 and `(delete-char -2)' is "abef" with the marker that
;; was at 4 collapsed to 3.
(test-equal '(3 "abef")
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 4)))
      (text-editor-set-cursor ed 5)
      (text-editor-delete-from-cursor ed -2)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A backwards deletion at the very end of a buffer, which is a position
;; the engine used to get wrong (see the note in
;; `SCHEMACS_EDITOR_ENGINE_END_OF_BUFFER'): the markers inside the
;; deleted text collapse to where it began, and the buffer loses exactly
;; the two characters asked for.
(test-equal '(5 "abcd")
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 5)))
      (text-editor-set-cursor ed 7)
      (text-editor-delete-from-cursor ed -2)
      (list (marker-position m) (text-editor-to-string ed)))))

;; A marker that points nowhere is in no chain and follows nothing.
(test-equal #f
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (let ((m (copy-marker ed 3)))
      (set-marker! m #f)
      (text-editor-set-cursor ed 1)
      (text-editor-insert ed "XY")
      (marker-position m))))

;; Markers belong to a buffer: editing one leaves another's alone.
(test-equal '(3 5)
  (let* ((one (new-text-editor))
         (two (new-text-editor)))
    (text-editor-insert one "abcdef")
    (text-editor-insert two "abcdef")
    (let ((m1 (copy-marker one 3)) (m2 (copy-marker two 3)))
      (text-editor-set-cursor two 1)
      (text-editor-insert two "XY")
      (list (marker-position m1) (marker-position m2)))))

;; A line break is text too: a marker after it moves with it.
(test-equal '(6 "ab\ncd")
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcd")
    (let ((m (copy-marker ed 5)))
      (text-editor-set-cursor ed 3)
      (text-editor-insert ed #\newline)
      (list (marker-position m) (text-editor-to-string ed)))))

;; Undo replays through the same insert and delete procedures, so it
;; adjusts markers too: an insertion undone puts the marker back where
;; it was.
(test-equal '(3 5 3)
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    ;; A boundary, as the command loop places one between commands, so
    ;; that undoing takes back the insertion below and not this one too.
    (text-editor-undo-boundary! ed)
    (let ((m (copy-marker ed 3)))
      (let ((before (marker-position m)))
        (text-editor-set-cursor ed 1)
        (text-editor-insert ed "XY")
        (let ((after (marker-position m)))
          (text-editor-undo ed (text-editor-undo-list ed) 1)
          (list before after (marker-position m)))))))

;; The mark is a marker, so it follows the text: Emacs: a mark at 5 with
;; "XY" inserted before it is at 7.
(test-equal '(#f 5 7)
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "one two three")
    (let ((unset (text-editor-mark ed)))
      (set!text-editor-mark ed 5)
      (let ((set-at (text-editor-mark ed)))
        (text-editor-set-cursor ed 0)
        (text-editor-insert ed "XY")
        (list unset set-at (text-editor-mark ed))))))

;; ... and it is the same marker object throughout, so code that holds
;; it - `MARK-MARKER' - sees the moves rather than a replacement.
(test-equal '(9 9 #t)
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (set!text-editor-mark ed 3)
    (let ((before (mark-marker ed)))
      (set!text-editor-mark ed 9)
      ;; the same marker both times, so the one held follows the move
      (list (marker-position before) (marker-position (mark-marker ed))
            (eq? before (mark-marker ed))))))

;; Setting the mark to false leaves it unset again, pointing nowhere.
(test-equal #f
  (let* ((ed (new-text-editor)))
    (text-editor-insert ed "abcdef")
    (set!text-editor-mark ed 3)
    (set!text-editor-mark ed #f)
    (text-editor-mark ed)))

(test-end "schemacs_editor_engine_markers")

;;--------------------------------------------------------------------
;; 8. regression tests: the character count across a line merge
;;
;; `text-editor-char-count' is the buffer's size in characters, and
;; every position in the buffer is an index into it. The two procedures
;; that merge a line into its neighbour rearrange which line structure
;; holds a character rather than change what the buffer contains - but
;; they re-inserted the moved characters through
;; `text-editor-force-insert-char', which counts what it inserts, and
;; they never took off the line break they deleted. So the count gained
;; a line's length on every merge and drifted further from the text
;; with each one.
;;
;; The tests above check the *text* a merge leaves, and the text was
;; always right; that is why this survived. What was wrong was the
;; count, which nothing here was reading - until the completion window
;; put text properties on a buffer it had just emptied and refilled,
;; and the interval tree and the buffer disagreed about how big it was.

(test-begin "schemacs_editor_engine_char_count")

;; Deleting a line break forward merges the two lines, and the count
;; loses exactly that one character - not the length of the line that
;; moved up into the line editor.
(test-equal '(7 7 "abcdef\n")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc\ndef\n")
    (text-editor-set-cursor ed 1 3)
    (text-editor-delete-from-cursor ed 1)
    (list (text-editor-char-count ed)
          (string-length (text-editor-to-string ed))
          (text-editor-to-string ed))))

;; ...and the same backwards, which is the path a DEL at the start of a
;; line takes.
(test-equal '(7 7 "abcdef\n")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "abc\ndef\n")
    (text-editor-set-cursor ed 2 0)
    (text-editor-delete-from-cursor ed -1)
    (list (text-editor-char-count ed)
          (string-length (text-editor-to-string ed))
          (text-editor-to-string ed))))

;; A deletion crossing several lines merges once per line break, and
;; the count has to lose one character per merge and nothing else.
(test-equal '(0 0 "")
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "schemacs/\nscratch.md\nscratch-ro.md\n")
    (text-editor-set-cursor ed 0 0)
    (text-editor-delete-from-cursor ed 35)
    (list (text-editor-char-count ed)
          (string-length (text-editor-to-string ed))
          (text-editor-to-string ed))))

;; The count is what the buffer says it is for the whole round trip:
;; emptying the buffer and typing the text back in has to bring it back
;; to where it started.
(test-equal '(35 0 35)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "schemacs/\nscratch.md\nscratch-ro.md\n")
    (let ((full (text-editor-char-count ed)))
      (text-editor-set-cursor ed 0)
      (text-editor-delete-from-cursor ed (text-editor-char-count ed))
      (let ((emptied (text-editor-char-count ed)))
        (text-editor-insert ed "schemacs/\nscratch.md\nscratch-ro.md\n")
        (list full emptied (text-editor-char-count ed))))))

(test-end "schemacs_editor_engine_char_count")
