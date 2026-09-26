(import
 (scheme base)
 (schemacs editor engine)
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
	      (buf-ch (text-editor-get-char-index buf i))
	      )
	  ;;(display "s=") (write str-ch) (display ", b=") (write buf-ch) (newline);;DEBUG
	  (cond
	   ((char=? str-ch buf-ch) (loop (+ 1 i)))
	   (else (values i str-ch buf-ch))
	   )))
       ((< i buflen)
	;;(display " end of string\n");;DEBUG
	(values i #f (text-editor-get-char-index buf i))
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
    (text-editor-set-cursor ed 1 1)
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

;; Cursor motion: the character index tracks the position after a
;; sequence of moves and inserts.
(test-assert
 (let ((ed (new-text-editor)))
   (text-editor-insert ed "alpha\nbeta\ngamma\n")
   ;; move to start
   (text-editor-move-cursor ed -100)
   (let ((start (text-editor-get-cursor ed)))
     (text-editor-set-cursor ed 1 2)
     (let ((mid (text-editor-get-cursor ed)))
       (and (= 0 start) (= 8 mid))))))

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
    (text-editor-set-cursor ed 1 0)
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
    (text-editor-set-cursor ed 0 5)
    (text-editor-delete-from-cursor ed 6)
    (text-editor-to-string ed)))

(test-end "schemacs_editor_engine_motion")
