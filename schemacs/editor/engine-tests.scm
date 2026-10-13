(import
 (scheme base)
 (scheme file)
 (schemacs editor engine)
 ;; `%mark-marker` is `BVAR (b, mark)` - the slot itself, which is what
 ;; the mark tests below are about now that `text-editor-mark` and
 ;; `set!text-editor-mark` are gone (they were that read and that write,
 ;; under invented names).
 (only (schemacs editor buffer)
       with-current-buffer set-buffer-modified-p %mark-marker
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char)
 ;; the property-change raise is `textprop.c`'s `modify_text_properties`,
 ;; in the library that owns it - it was `text-editor-note-property-change!`
 ;; in the engine until 2026-10-12.
 (only (schemacs editor textprop)
       modify-text-properties get-text-property put-text-property)
 ;; `make-buffer-string` is `editfns.c:1561`'s and left the engine for
 ;; `intervals.scm` on 2026-10-13 - it has to live below `search.scm`.
 (only (schemacs editor intervals) make-buffer-string)
 ;; The line and column arithmetic moved to `editfns.scm` on 2026-10-12 -
 ;; `bol', `eol' and the four facade names are `editfns.c`'s - so the
 ;; end-of-buffer tests below, which read them beside the engine's own
 ;; state, ask that library for them.
 (only (schemacs editor editfns)
       buffer-substring buffer-substring-no-properties point-max point-min
       text-editor-cursor-line text-editor-cursor-column
       text-editor-get-start-of-line text-editor-get-end-of-line
       ;; `mark-marker` is `editfns.c:265`'s and left the engine for that
       ;; library on 2026-10-12; it takes no buffer, as the C's takes none.
       mark-marker insert
)
 ;; The literal search is `search.c`'s and moved to `search.scm` on
 ;; 2026-10-12; the search block below reads it from there.
 (only (schemacs editor search)
       text-editor-search-forward text-editor-search-backward)
 (only (schemacs editor simple) primitive-undo)
 ;; The visited file's modification time is `fileio.c`'s, and the time
 ;; values it is written in are `timefns.c`'s. The engine reaches the
 ;; first through the seam `*buffer-visited-file-modtime-function*`,
 ;; which the tests below bind to check what a mark holds.
 (only (schemacs editor fileio) set-visited-file-modtime)
 (only (schemacs editor timefns) make-lisp-time)
 ;; The markers are `marker.scm`'s - marker.c's own library - and not the
 ;; engine's any more.
 (only (schemacs editor marker)
       make-marker build-marker markerp marker-buffer marker-position
       set-marker set-marker-insertion-type copy-marker)
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
	(buflen (- (buffer-z buf) (buffer-beg buf)))
	(len (min strlen buflen))
	)
    ;;(display "strlen=") (write strlen) (display ", buflen=") (write buflen) (newline);;DEBUG
    (let loop ((i 0))
      ;;(display "f[") (write i) (display "]: ");;DEBUG
      (cond
       ((< i len)
	(let ((str-ch (string-ref str i))
	      (buf-ch (fetch-char buf (+ i 1)))
	      )
	  ;;(display "s=") (write str-ch) (display ", b=") (write buf-ch) (newline);;DEBUG
	  (cond
	   ((char=? str-ch buf-ch) (loop (+ 1 i)))
	   (else (values i str-ch buf-ch))
	   )))
       ((< i buflen)
	;;(display " end of string\n");;DEBUG
	(values i #f (fetch-char buf (+ i 1)))
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

(define ed (allocate-buffer))

(define (gb-insert-list ed elems)
  (let loop ((elems elems))
    (cond
     ((pair? elems)
      ;; Write the sample text into the text editor buffer.
      (with-current-buffer ed (insert (car elems)))
      (loop (cdr elems))
      )
     (else
      (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))
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
;; editor buffer, including text that carries CR characters.

(test-begin "schemacs_editor_engine_motion")

;; Round-trip a buffer whose last line has no terminating line break.
(test-equal "AAA\nBBB\nno-newline"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "AAA\nBBB\nno-newline"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Round-trip a buffer with empty lines.
(test-equal "AAA\n\nBBB\n\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "AAA\n\nBBB\n\n"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Move the cursor to the start of the buffer, insert text, jump to a
;; middle line, insert, move to the end, insert. Verify nothing is
;; lost or misplaced.
(test-equal "SAAA\nB1BB\nCCC\nDDD\nE"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "AAA\nBBB\nCCC\nDDD\n"))
    (text-editor-move-cursor ed -100)
    (with-current-buffer ed (insert "S"))
    ;; **The engine's two-argument `text-editor-set-cursor` - "line N,
    ;; column C" - is gone** (2026-10-12): it had no Emacs counterpart,
    ;; being `goto-line' followed by `move-to-column'. Positions are what
    ;; the engine addresses text by, so the setups below name one. Here:
    ;; line 2 of `"SAAA\nBBB\nCCC\nDDD\n"` begins at 6, so its column 1 is
    ;; position 7.
    (text-editor-set-cursor ed (+ (buffer-beg ed) 6))
    (with-current-buffer ed (insert "1"))
    (text-editor-move-cursor ed 100)
    (with-current-buffer ed (insert "E"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; A line break in the middle of a line splits the line, keeping the
;; characters after the cursor on the new current line.
(test-equal "HELLOW\nORLD\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "HELLOWORLD\n"))
    (text-editor-move-cursor ed -5)
    (with-current-buffer ed (insert "\n"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Editing the last line of a buffer which does not end in a line
;; break must not introduce a line break.
(test-equal "aaa\nbbb\nc!cc"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "aaa\nbbb\n"))
    (with-current-buffer ed (insert "ccc"))
    (text-editor-move-cursor ed -2)
    (with-current-buffer ed (insert "!"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; CR characters are ordinary characters in the buffer - a line break is
;; not a property of the buffer any more, it is whatever characters are
;; in it - so text carrying CRLF round-trips like any other text.
(test-equal "one\r\ntwo\r\nthrXee\r\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "one\r\ntwo\r\nthree\r\n"))
    (text-editor-move-cursor ed -4)
    (with-current-buffer ed (insert "X"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; A mid-line CRLF splits into two CRLF lines.
(test-equal "HELLO\r\nWORLD\r\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "HELLOWORLD\r\n"))
    (text-editor-move-cursor ed -7)
    (with-current-buffer ed (insert "\r\n"))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Cursor motion: the position tracks a sequence of moves and inserts.
;; START is `point-min', 1 - Emacs's coordinate, not an index - and the
;; second line's third character is position 9.
(test-assert
 (let ((ed (allocate-buffer)))
   (with-current-buffer ed (insert "alpha\nbeta\ngamma\n"))
   ;; move to start
   (text-editor-move-cursor ed -100)
   (let ((start (buffer-pt ed)))
     ;; `line-beginning-position' for the line position 9 is on - the
     ;; second line of `"alpha\nbeta\ngamma\n"', which begins at 7. The
     ;; line-and-column cursor this used to address with is gone; what is
     ;; asserted is the arithmetic `goto-line' and `move-to-column' are
     ;; made of.
     (text-editor-set-cursor ed (text-editor-get-start-of-line ed 9))
     (let ((mid (buffer-pt ed)))
       (and (= 1 start) (= 7 mid))))))

;; Deleting characters within a line.
(test-equal "hello\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello world\n"))
    (text-editor-move-cursor ed -100)
    (text-editor-move-cursor ed 5)
    (text-editor-delete-from-cursor ed 6)
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Backward delete at the start of a line merges with the line before,
;; and leaves the cursor where the line break was.
(test-equal "alphabeta\ngamma\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "alpha\nbeta\ngamma\n"))
    ;; line 2 begins at 7, which is where column 0 of it is
    (text-editor-set-cursor ed (+ (buffer-beg ed) 6))
    (text-editor-delete-from-cursor ed -1)
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; Forward delete past the end of a line merges with the next line,
;; counting the line break as one deleted character.
(test-equal "alphata\ngamma\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "alpha\nbeta\ngamma\n"))
    (text-editor-set-cursor ed (+ (buffer-beg ed) 5))
    (text-editor-delete-from-cursor ed 3)
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; A deletion spanning multiple lines merges and deletes.
(test-equal "alphagamma\n"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "alpha\nbeta\ngamma\n"))
    (text-editor-set-cursor ed (+ (buffer-beg ed) 5))
    (text-editor-delete-from-cursor ed 6)
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

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
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "X"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (fetch-char ed 1)))

;; Copying a whole single-line buffer keeps its first character.
(test-equal "one two"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "one two"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (make-buffer-string ed 1 8)))

;; **`buffer-substring-no-properties` is not `buffer-string`**, and this
;; pins the difference because it is the kind a repoint loses silently:
;; `buffer-string` copies the interval tree into the string
;; (`make_buffer_string_both` with PROPS true, `editfns.c:1707') and
;; `buffer-substring-no-properties` passes PROPS false. `make-buffer-string`
;; is the one function underneath both, and its fourth argument is the
;; switch - so the two answers differ here and nowhere else in the file.
;;
;; (This was written to pin `text-editor-to-string`, an invented name for
;; the no-properties read over the whole buffer, which the engine kept
;; until 2026-10-13. Its 85 callers write the composition out now, which
;; is what Emacs's callers do - there is no DEFUN for it.)
(test-equal '(#f bold 3)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (with-current-buffer ed
      (put-text-property 1 3 'face 'bold))
    (list (get-text-property
           0 'face
           (with-current-buffer ed
             (buffer-substring-no-properties (point-min) (point-max))))
          ;; ... and the one that DOES pass PROPS carries it - so this
          ;; test fails if either half is changed into the other.
          (get-text-property 0 'face (make-buffer-string ed 1 4 #t))
          ;; `string-length` and not `length`: a library imported here
          ;; exports a `length` that is not Scheme's, so `(length "abc")`
          ;; raises "Wrong type argument ... \"abc\"" from a form that
          ;; reads perfectly.
          (string-length
           (with-current-buffer ed
             (buffer-substring-no-properties (point-min) (point-max)))))))

;; The first character of every line: position 5 begins the second line
;; and position 10 the third.
(test-equal '(#\a #\d #\h)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc\ndefg\nhi"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (map (lambda (i) (fetch-char ed i)) '(1 5 10))))

;; An index past the end of the buffer is still unresolvable.
(test-equal #f
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (fetch-char ed 4)))

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
         (rest (with-current-buffer ed (primitive-undo n pending))))
    (*pending* (if (null? rest) #f rest))
    (*last-command* 'undo)))

(define (redo-command! ed n)
  ;; Redoing is undoing the redo records at the front of the list.
  (with-current-buffer ed
    (primitive-undo n (strip-boundaries (text-editor-undo-list ed)))))

(define (undo! ed n)
  ;; A single, isolated undo command (no chain).
  (parameterize ((*pending* #f) (*last-command* #f))
    (undo-command! ed n)))

;; An insertion is recorded as the range of characters it occupies, and
;; undoing it deletes that range.
(test-equal '((1 . 4) (t . 0))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-list ed)))

(test-equal '("" 1)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (undo! ed 1)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

;; A deletion is recorded with the deleted text, so undo can put it
;; back without having to recover it from the buffer - which is what
;; makes undoing the deletion of a line break work.
(test-equal 6
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello\nworld"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (cdr (car (text-editor-undo-list ed)))))

(test-equal (list (cons (string #\newline) 6))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello\nworld"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (list (car (text-editor-undo-list ed)))))

;; **Point after the undo is where the boundary left it, not where the
;; deletion began** - `record_point` (`undo.c:50`) pushes the position
;; the command started at as an integer entry, `primitive-undo`'s
;; integer case is `(goto-char next)`, and it is applied after the
;; change's own entry. These expected the deleted text's start, which is
;; what a tree without that entry gives. Measured on Emacs 31.1 for the
;; same steps: the `undo-boundary` leaves point at the end of what was
;; inserted, and undoing restores point *there*.
(test-equal '("hello\nworld" 12)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello\nworld"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (undo! ed 1)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

;; Undo, redo, undo: the records an undo creates are ordinary entries at
;; the front of the list, so redoing is undoing them. Round-tripping
;; must be stable: delete, undo, redo, undo must visit the same two
;; states in alternation.
(test-equal '("helloworld" "hello\nworld" "hello\nworld")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello\nworld"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed 1)
    (undo! ed 1)                       ; undo the deletion
    (let ((after-undo (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))
      (redo-command! ed 1)             ; put the deletion back
      (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))
            after-undo
            (begin (undo! ed 1) (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))))

;; A boundary ends a change group. Inserting, bounding, then inserting
;; again gives two steps, and each undo command takes one of them - the
;; second one walking the saved tail rather than the front of the list.
(test-equal '("abc" "")
  (parameterize ((*pending* #f) (*last-command* #f))
    (let ((ed (allocate-buffer)))
      (with-current-buffer ed (insert "abc"))
      (text-editor-undo-boundary! ed)
      (text-editor-set-cursor ed 3)
      (with-current-buffer ed (insert "def"))
      (let ((one (begin (undo-command! ed 1) (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))
        (list one (begin (undo-command! ed 1) (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))))

;; Undoing past the oldest change reports nothing more to undo, because
;; there is no tail left to walk.
(test-equal '(#f "")
  (parameterize ((*pending* #f) (*last-command* #f))
    (let ((ed (allocate-buffer)))
      (with-current-buffer ed (insert "abc"))
      (undo-command! ed 1)
      (list (*pending*) (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))

;; A boundary is never recorded twice in a row, nor at the front of an
;; empty list (mg's rule), so the grouping cannot be split by accident.
(test-equal '(() (1 . 4) (t . 0))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-boundary! ed)
    (text-editor-undo-boundary! ed)
    (text-editor-undo-list ed)))

;; Adjacent insertions grow one entry rather than adding one each, the
;; way Emacs's `record_insert' and mg's `undo_add_insert' do.
(test-equal '((1 . 7) (t . 0))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (with-current-buffer ed (insert "def"))
    (text-editor-undo-list ed)))

;; An insertion that does not abut the previous one starts a new entry,
;; rather than being folded into it.
(test-equal '((2 . 3) (1 . 4) (t . 0))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-set-cursor ed 2)
    (with-current-buffer ed (insert "X"))
    (text-editor-undo-list ed)))

;; Deletion is clamped, so what is recorded is what was really there:
;; deleting 100 characters of a 3-character buffer records 3, and undo
;; restores 3.
(test-equal '("abc" . 1)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed (buffer-beg ed))
    (text-editor-delete-from-cursor ed 100)
    (car (text-editor-undo-list ed))))

(test-equal "abc"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed (buffer-beg ed))
    (text-editor-delete-from-cursor ed 100)
    (undo! ed 1)
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; A forward deletion records a positive POS (point was at the beginning
;; of the deleted text) and undo leaves point there; a backward deletion
;; records a negative POS (point was at the end) and undo leaves point
;; at the end of the restored text.
(test-equal 1
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 1)
    (text-editor-delete-from-cursor ed 2)
    (cdr (car (text-editor-undo-list ed)))))

(test-equal -1
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -2)
    (cdr (car (text-editor-undo-list ed)))))

;; **Point after the undo is where the boundary left it, not where the
;; deletion began** - `record_point` (`undo.c:50`) pushes the position
;; the command started at as an integer entry, `primitive-undo`'s
;; integer case is `(goto-char next)`, and it is applied after the
;; change's own entry. These expected the deleted text's start, which is
;; what a tree without that entry gives. Measured on Emacs 31.1 for the
;; same steps: the `undo-boundary` leaves point at the end of what was
;; inserted, and undoing restores point *there*.
(test-equal '("abcd" 5)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -2)
    (undo! ed 1)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

;; **Point after the undo is where the boundary left it, not where the
;; deletion began** - `record_point` (`undo.c:50`) pushes the position
;; the command started at as an integer entry, `primitive-undo`'s
;; integer case is `(goto-char next)`, and it is applied after the
;; change's own entry. These expected the deleted text's start, which is
;; what a tree without that entry gives. Measured on Emacs 31.1 for the
;; same steps: the `undo-boundary` leaves point at the end of what was
;; inserted, and undoing restores point *there*.
(test-equal '("abcd" 5)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 1)
    (text-editor-delete-from-cursor ed 2)
    (undo! ed 1)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

;; Inserting a file's characters records the insertion like any other,
;; which is what GNU Emacs's `insert-file-contents' does - its
;; `buffer-undo-list' after a 12-character read is `((1 . 13) (t . 0))',
;; and so is this. It is the *visit* that leaves nothing to undo, and
;; that is `find-file-noselect''s doing (`empty_undo_list_p',
;; fileio.c:4125). Reading the file is `(schemacs editor files)`'s now -
;; this is the insertion it performs.
(test-equal '(((1 . 13) (t . 0)) "loaded\ntext\n")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "loaded\ntext\n"))
    (list (text-editor-undo-list ed) (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))

;; Disabling undo drops the list and stops recording; enabling it again
;; starts a fresh, empty list (Emacs's `buffer-disable-undo' sets
;; `buffer-undo-list' to t, and `buffer-enable-undo' sets it to nil).
(test-equal '(#f 3 () ((4 . 8)))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-disable! ed)
    (let ((disabled (list (text-editor-undo-recording? ed)
                          (- (buffer-z ed) (buffer-beg ed)))))
      (text-editor-undo-enable! ed)
      (let ((enabled (text-editor-undo-list ed)))
        (with-current-buffer ed (insert "wxyz"))
        (append disabled
                (list enabled (text-editor-undo-list ed)))))))

;; The undo list is bounded: past `*undo-limit*' the OLDEST change
;; groups are dropped, never the newest, and never part of a group.
;; (Emacs' own policy is three-tiered and measured in bytes; this is the
;; simplified stand-in, so the test pins the direction of the trimming
;; rather than Emacs' exact thresholds.)
(test-equal '((4 . 5) () (3 . 4) () (2 . 3))
  (parameterize ((*undo-limit* 6))
    (let ((ed (allocate-buffer)))
      (with-current-buffer ed (insert "A"))
      (let loop ((i 0))
        (when (< i 3)
          (text-editor-undo-boundary! ed)
          (with-current-buffer ed (insert (number->string i)))
          (loop (+ 1 i))))
      (text-editor-undo-list ed))))

;; Recording stays enabled when the list is trimmed away entirely: an
;; empty list is "nothing to undo yet", which is not the same as the
;; recording being switched off.
(test-equal #t
  (parameterize ((*undo-limit* 1))
    (let ((ed (allocate-buffer)))
      (with-current-buffer ed (insert "abc"))
      (text-editor-undo-boundary! ed)
      (with-current-buffer ed (insert "def"))
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
(test-equal #f (buffer-modified-p (allocate-buffer)))

;; Changing it marks it modified, and records where it was last in sync
;; so that undoing back there can unmark it.
(test-equal '(#t ((1 . 4) (t . 0)))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (list (buffer-modified-p ed) (text-editor-undo-list ed))))

;; Inserting nothing is not a change.
(test-equal #f
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert ""))
    (buffer-modified-p ed)))

;; Deleting nothing is not a change either (there is nothing after the
;; cursor to delete).
(test-equal #f
  (let ((ed (allocate-buffer)))
    (text-editor-delete-from-cursor ed 5)
    (buffer-modified-p ed)))

;; Saving clears the flag and leaves the undo list alone, as in GNU
;; Emacs: the record of where the buffer was last in sync is what makes
;; undo able to clear the flag again later.
(test-equal '(#f ((1 . 6) (t . 0)))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello"))
    (with-current-buffer ed (set-buffer-modified-p #f))
    (list (buffer-modified-p ed) (text-editor-undo-list ed))))

;; The mark of the last save holds the *visited file's* modification
;; time, and the engine asks for it through a seam because `fileio.c` is
;; above it - a buffer's text and its visit to a file are different
;; things. A buffer that visits nothing records 0, which is what
;; `buffer_visited_file_modtime' answers for an unknown `modtime' and
;; what Emacs records there too.
(test-equal '((1 . 4) (t . 0))
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-list ed)))

;; ... and a buffer visiting a file records the file's time, which is
;; what lets an undo tell whether the file has moved since the mark was
;; made.
(test-equal '((1 . 4) (t 0 2317 0 0))
  (let ((ed (allocate-buffer)))
    (parameterize ((*buffer-visited-file-modtime-function*
                    (lambda (buffer) (make-lisp-time 2317 0))))
      (with-current-buffer ed (insert "abc"))
      (text-editor-undo-list ed))))

;; Undoing back to the saved state makes the buffer unmodified again,
;; and redoing makes it modified again.
(test-equal '(#t #f "hello" #t "ahello")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "hello"))        ; visit
    (with-current-buffer ed (set-buffer-modified-p #f))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed (buffer-beg ed))
    (with-current-buffer ed (insert "a"))            ; the change to be undone
    (let ((before (buffer-modified-p ed)))
      (undo! ed 1)
      (let ((after (list (buffer-modified-p ed)
                         (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))
        (with-current-buffer ed
          (primitive-undo 1 (strip-boundaries (text-editor-undo-list ed)))) ; redo
        (append (list before) after
                (list (buffer-modified-p ed)
                      (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))))

;; Undoing PAST the saved state leaves the buffer modified: the file
;; being saved at one point does not make the buffer match it at an
;; earlier point. This is what the recorded time in the mark is for -
;; `primitive-undo' marks the buffer unmodified only while the file still
;; holds the time it held when the mark was made.
;;
;; The save is two steps here because it is two steps in Emacs: writing
;; the file records its new modification time (`write-region'), and
;; clearing the modified flag does not touch it at all. A fileless buffer
;; would keep 0 throughout and the second undo would mark it unmodified -
;; which is Emacs's answer there too, and why this test has to move the
;; time to be about anything.
(test-equal '(#f #t)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (with-current-buffer ed
      ;; saved here: the file has "abc" and its time is now 1000
      (set-buffer-modified-p #f)
      (set-visited-file-modtime '(1000 . 1)))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed 3)
    (with-current-buffer ed (insert "x"))              ; now "abcx"
    (undo! ed 1)                             ; back to "abc" == the file
    (let ((at-save-point (buffer-modified-p ed)))
      (undo! ed 1)                           ; back past the save, to ""
      (list at-save-point (buffer-modified-p ed)))))

;; The flag works even when undo recording is switched off: it is a
;; property of the buffer, not of the undo list.
(test-equal '(#t #f)
  (let ((ed (allocate-buffer)))
    (text-editor-undo-disable! ed)
    (with-current-buffer ed (insert "abc"))
    (let ((modified (buffer-modified-p ed)))
      (with-current-buffer ed (set-buffer-modified-p #f))
      (list modified (buffer-modified-p ed)))))

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

(test-equal #f (buffer-read-only? (allocate-buffer)))

(test-equal '(#t #f)
  (let ((ed (allocate-buffer)))
    (set!buffer-read-only ed #t)
    (let ((set (buffer-read-only? ed)))
      (set!buffer-read-only ed #f)
      (list set (buffer-read-only? ed)))))

;; Insertion is refused, and changes nothing.
(test-equal '(#t "abc")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (text-editor-set-cursor ed (buffer-beg ed))
    (let ((refused (refused? (lambda () (with-current-buffer ed (insert "X"))))))
      (list refused (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))

;; Deletion is refused, and changes nothing.
(test-equal '(#t "abc")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (text-editor-set-cursor ed (buffer-beg ed))
    (let ((refused (refused? (lambda () (text-editor-delete-from-cursor ed 2)))))
      (list refused (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))

;; Deleting nothing is not an edit, so it is not refused - there is
;; nothing to refuse.
(test-equal '(#f "abc")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (text-editor-set-cursor ed (buffer-beg ed))
    (let ((refused (refused? (lambda () (text-editor-delete-from-cursor ed 0)))))
      (list refused (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))

;; Undo is refused too, and refuses before it starts: a half-undone
;; change would be worse than none. (GNU Emacs's `undo' has the `*' in
;; its interactive spec that refuses a read-only buffer.)
(test-equal '(#t "Xabc")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-undo-boundary! ed)
    (text-editor-set-cursor ed (buffer-beg ed))
    (with-current-buffer ed (insert "X"))
    (set!buffer-read-only ed #t)
    (let* ((refused
            (refused?
             (lambda ()
               (with-current-buffer ed
                 (primitive-undo
                  1 (strip-boundaries
                     (text-editor-undo-list ed))))))))
      (list refused (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))))

;; Reading is unaffected: a read-only buffer can still be read.
(test-equal '("abc" 3)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (- (buffer-z ed) (buffer-beg ed)))))

;; Read-only and modified are independent: saving a buffer does not
;; change whether it refuses edits, and a read-only buffer can be
;; modified (by marking it so) without becoming editable.
(test-equal '(#f #t #t #t)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (with-current-buffer ed (set-buffer-modified-p #f))
    (let ((read-only (buffer-read-only? ed))
          (unmodified (buffer-modified-p ed)))
      (with-current-buffer ed (set-buffer-modified-p #t))
      (list unmodified read-only
            (buffer-modified-p ed)
            (buffer-read-only? ed)))))

;; Turning it off again lets the buffer be edited.
(test-equal '("Xabc" #f)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (set!buffer-read-only ed #t)
    (text-editor-set-cursor ed (buffer-beg ed))
    (set!buffer-read-only ed #f)
    (with-current-buffer ed (insert "X"))
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-read-only? ed))))

(test-end "schemacs_editor_engine_read_only")

;;--------------------------------------------------------------------
;; 8. searching, and the mark
;;
;; `text-editor-search-forward' and `text-editor-search-backward' are
;; GNU Emacs's `search-forward' and `search-backward' (mg's
;; forwsrch/backsrch): they report where point would be left - past the
;; match forwards, at its start backwards. A line break in the buffer is
;; one #\newline, which is what makes a match that spans lines findable.

(test-begin "schemacs_editor_engine_search")

(define (searchable)
  ;; "alpha beta gamma\nbeta delta\n": the two "beta"s are at 7..10 and
  ;; 18..21, and "gamma\nbeta" spans a line break.
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "alpha beta gamma\nbeta delta\n"))
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
    (let ((unset (marker-position (%mark-marker ed))))
      (set-marker (%mark-marker ed) 7 ed)
      (list unset (marker-position (%mark-marker ed))))))

(test-end "schemacs_editor_engine_search")

;;--------------------------------------------------------------------
;; 9. regression tests: where the end of the buffer is
;;
;; A buffer whose last line has no line break after it has no line
;; beyond that one, and GNU Emacs puts `point-max' at the end of it.
;; `text-editor-index-line-offset` reported such a position on an empty
;; line past the end instead - a line the buffer does not have, and one
;; its own line count left out - which made `C-e' leave
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
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-move-cursor ed 100)
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed)
          (text-editor-get-start-of-line ed)
          (text-editor-get-end-of-line ed))))

;; ... and the line and column the mode line shows agree: the line
;; counting from 1 as `line-number-at-pos' does, the column from 0 as
;; `current-column' does.
(test-equal '(1 3)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-move-cursor ed 100)
    (list (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; The same pair for a position that is not point, which is what the
;; mode line asks for when the window it draws is not the selected one:
;; the line comes from the `count-lines' scan and the column from the
;; start of that line.
(test-equal '(2 1)
  (let* ((ed (allocate-buffer))
         (pos (begin (with-current-buffer ed (insert "ab\ncd"))
                     (text-editor-set-cursor ed 5)
                     (buffer-pt ed))))
    (list (+ 1 (count-lines ed (buffer-beg ed) pos))
          (- pos (text-editor-get-start-of-line ed pos)))))

;; Point at that end still reaches the beginning of the line, which is
;; what `C-e' then `C-a' does.
(test-equal 1
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-move-cursor ed 100)
    (text-editor-set-cursor ed (text-editor-get-end-of-line ed))
    (text-editor-set-cursor ed (text-editor-get-start-of-line ed))
    (buffer-pt ed)))

;; A line break at the end of the buffer does start a line: the buffer
;; has two lines and the empty one gets `point-max'.
(test-equal '(2 2 0 5 5)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc\n"))
    (text-editor-move-cursor ed 100)
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
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
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    ;; line 2 does not exist in `"abc"', and Emacs's `goto-line' stops at
    ;; `point-max' when the line runs out - which is what the old
    ;; line-addressed cursor did here too
    (text-editor-set-cursor ed (buffer-z ed))
    (list (text-editor-cursor-line ed)
          (buffer-pt ed)
          (- (buffer-z ed) (buffer-beg ed)))))

;; With a line break at the end there is: the empty line the break
;; started is addressable, at the position the break ends at.
(test-equal '(2 5 2)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc\n"))
    ;; the empty line the break started is `point-max'
    (text-editor-set-cursor ed (buffer-z ed))
    (list (text-editor-cursor-line ed)
          (buffer-pt ed)
          (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed))))))

;; Typing a line break at the end of a buffer with no trailing break
;; starts a line, and point is on it.
(test-equal '(2 2 0)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc"))
    (text-editor-move-cursor ed 100)
    (with-current-buffer ed (insert "\n"))
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; So does accepting a file whose text ends in a line break, and its
;; end is the empty line the break started.
(test-equal '(3 3 0)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "one\ntwo\n"))
    (text-editor-move-cursor ed 100)
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
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
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-set-cursor ed 5)
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
          (text-editor-cursor-column ed)
          (buffer-pt ed))))

;; Deleting backwards at the end takes the two characters before it:
;; Emacs: "abcd" with point at the end and `(delete-char -2)' is "ab"
;; with point 3.
(test-equal '("ab" 3 2)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-set-cursor ed 5)
    (let ((deleted (text-editor-delete-from-cursor ed -2)))
      (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))
            (buffer-pt ed)
            deleted))))

;; ... and the deletion is recorded as what was really deleted, so
;; undoing it gives the buffer back: before this was fixed the entry said
;; two characters where one had gone, and undo corrupted the buffer.
(test-equal "abcd"
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd"))
    (text-editor-set-cursor ed 4)
    (text-editor-undo-boundary! ed)
    (text-editor-delete-from-cursor ed -2)
    (with-current-buffer ed (primitive-undo 1 (text-editor-undo-list ed)))
    (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))))

;; A buffer whose last line does end in a line break does have an empty
;; line after it, and the cursor can be on it: Emacs: "abcd\n" has two
;; lines and `(point-max)' is on the second.
(test-equal '(2 2 0)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd\n"))
    (list (+ 1 (count-lines ed (buffer-beg ed) (buffer-z ed)))
          (text-editor-cursor-line ed)
          (text-editor-cursor-column ed))))

;; ... and deleting backwards there takes the break and the character
;; before it: Emacs: "abcd\n" with point at the end and
;; `(delete-char -2)' is "abc".
(test-equal '("abc" 4)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcd\n"))
    (text-editor-set-cursor ed 6)
    (text-editor-delete-from-cursor ed -2)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

;; Writing a line back while the cursor is in the middle of it leaves the
;; cursor there: Emacs: point after inserting "X" at position 3 of
;; "abcdef" is 4, and stays 4 while the buffer is read.
(test-equal '("abXcdef" 4 4)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdef"))
    (text-editor-set-cursor ed 3)          ; writes the line back
    (with-current-buffer ed (insert "X"))            ; the line is changed again
    (let ((before (buffer-pt ed)))
      (make-buffer-string ed 1 8)     ; a read, which writes back
      (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) before (buffer-pt ed)))))

;; Deleting backwards in the middle of a line was always right, and stays
;; right: Emacs: point 3 of "abcdef" with `(delete-char -1)' is "acdef"
;; with point 2.
(test-equal '("acdef" 2)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdef"))
    (text-editor-set-cursor ed 3)
    (text-editor-delete-from-cursor ed -1)
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))) (buffer-pt ed))))

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
  (let ((ed (allocate-buffer)))
    (list (text-editor-buffer-name ed) (text-editor-file-name ed))))

;; Both are the buffer's own to set.
(test-equal '("scratch.md" "/tmp/x/scratch.md")
  (let ((ed (allocate-buffer)))
    (set!text-editor-buffer-name ed "scratch.md")
    (set!text-editor-file-name ed "/tmp/x/scratch.md")
    (list (text-editor-buffer-name ed) (text-editor-file-name ed))))

;; The identity is independent of the text: loading a file into a
;; buffer does not name it, and naming it does not touch the text.
(test-equal '("alpha" "Untitled" 5)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "alpha"))
    (list (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max)))
          (text-editor-buffer-name ed)
          (- (buffer-z ed) (buffer-beg ed)))))

;; A buffer with no file can be named after something that is not a
;; file at all - "*Completions*" - which is what a window showing one
;; puts in its mode line.
(test-equal "*Completions*"
  (let ((ed (allocate-buffer)))
    (set!text-editor-buffer-name ed "*Completions*")
    (text-editor-buffer-name ed)))

(test-end "schemacs_editor_engine_buffer_identity")

;;--------------------------------------------------------------------
;; 11. the mark, which is a marker

(test-begin "schemacs_editor_engine_markers")

;; The mark is a marker, so it follows the text: Emacs: a mark at 5 with
;; "XY" inserted before it is at 7.
(test-equal '(#f 5 7)
  (let* ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "one two three"))
    (let ((unset (marker-position (%mark-marker ed))))
      (set-marker (%mark-marker ed) 5 ed)
      (let ((set-at (marker-position (%mark-marker ed))))
        (text-editor-set-cursor ed 0)
        (with-current-buffer ed (insert "XY"))
        (list unset set-at (marker-position (%mark-marker ed)))))))

;; ... and it is the same marker object throughout, so code that holds
;; it - `MARK-MARKER' - sees the moves rather than a replacement.
;;
;; **The mark at 9 in a six-character buffer is at 7**, because a marker
;; is a marker: `set-marker' clips the position to the buffer
;; (`clip_to_bounds`, `marker.c:558') and `point-max' is 7. Measured on
;; Emacs 31.1 for the same four steps, `(7 7 t)'. This expected `(9 9 #t)'
;; while our `set-marker` was storing the position unclipped.
(test-equal '(7 7 #t)
  (let* ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdef"))
    (set-marker (%mark-marker ed) 3 ed)
    (with-current-buffer ed
      (let ((before (mark-marker)))
        (set-marker (%mark-marker ed) 9 ed)
        ;; the same marker both times, so the one held follows the move
        (list (marker-position before) (marker-position (mark-marker))
              (eq? before (mark-marker)))))))

;; Setting the mark to false leaves it unset again, pointing nowhere.
(test-equal #f
  (let* ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdef"))
    (set-marker (%mark-marker ed) 3 ed)
    (set-marker (%mark-marker ed) #f ed)
    (marker-position (%mark-marker ed))))

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
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc\ndef\n"))
    (text-editor-set-cursor ed (+ (buffer-beg ed) 3))
    (text-editor-delete-from-cursor ed 1)
    (list (- (buffer-z ed) (buffer-beg ed))
          (string-length (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))
          (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))

;; ...and the same backwards, which is the path a DEL at the start of a
;; line takes.
(test-equal '(7 7 "abcdef\n")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abc\ndef\n"))
    ;; line 2 begins at 5 - which is also where the line break is
    (text-editor-set-cursor ed (+ (buffer-beg ed) 4))
    (text-editor-delete-from-cursor ed -1)
    (list (- (buffer-z ed) (buffer-beg ed))
          (string-length (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))
          (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))

;; A deletion crossing several lines merges once per line break, and
;; the count has to lose one character per merge and nothing else.
(test-equal '(0 0 "")
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "schemacs/\nscratch.md\nscratch-ro.md\n"))
    (text-editor-set-cursor ed (buffer-beg ed))
    (text-editor-delete-from-cursor ed 35)
    (list (- (buffer-z ed) (buffer-beg ed))
          (string-length (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))
          (with-current-buffer ed (buffer-substring-no-properties (point-min) (point-max))))))

;; The count is what the buffer says it is for the whole round trip:
;; emptying the buffer and typing the text back in has to bring it back
;; to where it started.
(test-equal '(35 0 35)
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "schemacs/\nscratch.md\nscratch-ro.md\n"))
    (let ((full (- (buffer-z ed) (buffer-beg ed))))
      (text-editor-set-cursor ed 0)
      (text-editor-delete-from-cursor ed (- (buffer-z ed) (buffer-beg ed)))
      (let ((emptied (- (buffer-z ed) (buffer-beg ed))))
        (with-current-buffer ed (insert "schemacs/\nscratch.md\nscratch-ro.md\n"))
        (list full emptied (- (buffer-z ed) (buffer-beg ed)))))))

(test-end "schemacs_editor_engine_char_count")

;;--------------------------------------------------------------------
;; The modification counters, against Emacs's own answers
;;
;; `buffer-modified-tick' and `buffer-chars-modified-tick' are `MODIFF'
;; and `CHARS_MODIFF'. Every line below was read off a real Emacs first:
;;
;;   emacs -Q --batch --eval '(progn
;;     (princ (format "%s %s %s" (buffer-modified-tick)
;;                            (buffer-chars-modified-tick)
;;                            (buffer-modified-p)))
;;     (insert "a") ...)'
;;
;; gave 1 1 nil / 2 2 t / 3 3 t / 3 3 nil / 4 3 t / 5 3 t / 9 9 t for
;; the seven steps here. The last is the point of `modiff_incr': ten
;; characters raise the counter by four, not by ten, because the rise is
;; logarithmic in the size of the change.
;;--------------------------------------------------------------------

(test-begin "schemacs_editor_engine_modiff")

(define (tick-triple ed)
  (list (buffer-modified-tick ed)
        (buffer-chars-modified-tick ed)
        (buffer-modified-p ed)))

(test-equal '((1 1 #f) (2 2 #t) (3 3 #t) (3 3 #f)
              (4 3 #t) (5 3 #t) (9 9 #t))
  (let ((ed (allocate-buffer)))
    (let ((steps (list (tick-triple ed))))
      (with-current-buffer ed (insert "a"))
      (set! steps (cons (tick-triple ed) steps))
      (with-current-buffer ed (insert "b"))
      (set! steps (cons (tick-triple ed) steps))
      ;; saving: the buffer is in sync with its file again
      (with-current-buffer ed (set-buffer-modified-p #f))
      (set! steps (cons (tick-triple ed) steps))
      ;; marking it modified without changing the text raises the tick,
      ;; so that the comparison comes out true again
      (with-current-buffer ed (set-buffer-modified-p #t))
      (set! steps (cons (tick-triple ed) steps))
      ;; a property change raises the tick and NOT the character tick
      (modify-text-properties ed 1 2)
      (set! steps (cons (tick-triple ed) steps))
      (with-current-buffer ed (insert "cccccccccc"))
      (set! steps (cons (tick-triple ed) steps))
      (reverse steps))))

;; A deletion is one change however many characters go, like an
;; insertion: ten characters raise the tick by four.
(test-equal 9
  (let ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "abcdefghij"))
    (text-editor-set-cursor ed 1)
    (with-current-buffer ed (set-buffer-modified-p #f))
    (text-editor-delete-from-cursor ed 10)
    (buffer-modified-tick ed)))

(test-end "schemacs_editor_engine_modiff")
