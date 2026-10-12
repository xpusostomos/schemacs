(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor buffer)
       get-buffer-create set-buffer erase-buffer)
 (only (schemacs editor editfns)
       insert goto-char point buffer-string)
 (only (schemacs editor casefiddle)
       casify-region
       upcase-word downcase-word capitalize-word)
 (only (schemacs editor engine)
       text-editor-undo-list set!text-editor-undo-list
       text-editor-undo-boundary!)
 ;; `upcase-region` and `downcase-region` are `casefiddle.c`'s, but they
 ;; read the region and so are defined in `simple.scm` now - the named
 ;; placement departure noted there. Their tests stay here, beside
 ;; `casify-region`'s, which is what they exercise.
 (only (schemacs editor simple)
       upcase-region downcase-region primitive-undo))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor casefiddle)', which mirrors GNU
;; Emacs's `casefiddle.c'.
;;
;; **Every expectation here was measured on GNU Emacs 31.1**, not worked
;; out: `emacs -Q --batch', the same text and point, the same command.
;; The tuple is the return value, the buffer and point after it, in that
;; order.
;;
;; What these are for is the shape `casify_region` has - the hooks and
;; the undo record around the *whole* region, with the characters written
;; in between them - and the three things that follow from it. A region
;; command answers **nil**, not the region's end, because it goes through
;; `casify_pnc_region` and throws the answer away. Point does not move for
;; a same-length change, because a character written in place moves
;; nothing. And the undo record is one deletion followed by one
;; insertion, *however many* characters the walk then wrote.
;;
;; `\\xHH;' is not how a non-ASCII character is written here - Guile's
;; string escape takes two hex digits, so `"\\x3a3;"' is the four
;; characters `:3;'. The Greek below is built with `integer->char'.

(test-begin "schemacs_editor_casefiddle")

(define *buffer-count* 0)
(define (fresh-buffer)
  ;; A buffer of this suite's own. `get-buffer-create' on one shared name
  ;; would carry the previous test's undo list into the next one.
  ;;--------------------------------------------------------------
  (set! *buffer-count* (+ *buffer-count* 1))
  (get-buffer-create (string-append "*casefiddle-tests*"
                                    (number->string *buffer-count*))))

(define (probe text position fn . args)
  ;; What the return value, the buffer and point are after calling FN at
  ;; POSITION - the `(list (funcall ...) (buffer-string) (point))' the
  ;; Emacs probe printed.
  ;;--------------------------------------------------------------
  (let ((ed (fresh-buffer)))
    (set-buffer ed)
    (erase-buffer)
    (insert text)
    (goto-char position)
    (let ((ret (apply fn args)))
      (list ret (buffer-string) (point)))))

(define (greeks . codes)
  ;; A string of code points, so that the Greek in these tests is spelled
  ;; as numbers rather than as something the reader may mis-take.
  ;;--------------------------------------------------------------
  (apply string (map integer->char codes)))

(define capital-sigma #x3a3)  ; Σ
(define small-sigma   #x3c3)  ; σ
(define final-sigma   #x3c2)  ; ς

;;--------------------------------------------------------------
;; The region commands
;;--------------------------------------------------------------

;; The region is upcased and the command answers nil - *not* the end of
;; the region, which is what `casify_region` itself answers and what this
;; used to return. Measured: `(upcase-region 1 4)` is nil in Emacs 31.1.
(test-equal "upcase-region upcases the region and answers nil"
  '(#f "ABC def" 3)
  (probe "abc def" 3 upcase-region 1 4))

;; Point does not move - not to the region's start, and not to its end -
;; wherever it was. A same-length case change writes the characters in
;; place, and writing in place moves nothing.
(test-equal "point before the region stays put"
  '(#f "ABC def" 1)
  (probe "abc def" 1 upcase-region 1 4))

(test-equal "point after the region stays put"
  '(#f "ABC def" 7)
  (probe "abc def" 7 upcase-region 1 4))

(test-equal "point inside the region stays put"
  '(#f "ABC def" 5)
  (probe "abc def" 5 upcase-region 1 5))

;; The arguments are sorted, so the region does not have to be given the
;; right way round.
(test-equal "the region's ends are swapped if they arrive backwards"
  '(#f "ABC def" 1)
  (probe "abc def" 1 upcase-region 4 1))

;; An empty region is "not modifying because nothing marked" and nothing
;; happens - and the command answers nil like any other.
(test-equal "an empty region changes nothing"
  '(#f "abc" 2)
  (probe "abc" 2 upcase-region 2 2))

;; A region past the end of the buffer is an error, which is
;; `validate_region`'s check - the C's `args_out_of_range_3`.
(test-assert "a region past the end of the buffer is an error"
  (let ((ed (fresh-buffer)))
    (set-buffer ed)
    (erase-buffer)
    (insert "abc")
    (guard (e (#t #t)) (upcase-region 1 9) #f)))

;; `upcase` does not care what a character's syntax is: the dash and the
;; underscore of "a-b_c" are upcased with the letters, there being no
;; case to change. `capitalize' does care, and is below.
(test-equal "upcase-region is not word-aware"
  '(#f "A-B_C" 1)
  (probe "a-b_c" 1 upcase-region 1 6))

;; `casify-region` is what `capitalize-region` calls; that DEFUN is not
;; ported, so this calls the one the C has (`casefiddle.c:534`) - and it
;; answers the end of the region, where the commands answer nil.
(test-equal "capitalize cases each word's start and lowers the rest"
  '(12 "The Foo Bar" 1)
  (probe "the FOO bar" 1 casify-region 'capitalize 1 12))

;;--------------------------------------------------------------
;; The word commands
;;--------------------------------------------------------------

;; "Convert to upper case from point to end of word, moving over" - and
;; point ends at the far end of the last word converted.
(test-equal "upcase-word moves over the words it cased"
  '(#f "HELLO WORLD foo" 12)
  (probe "hello world foo" 1 upcase-word 2))

;; "With negative argument, convert previous words but do not move" - so
;; point stays where it was, which is *after* the words converted.
(test-equal "downcase-word with a negative argument does not move point"
  '(#f "hello world foo" 16)
  (probe "hello world foo" 17 downcase-word -2))

(test-equal "capitalize-word over three words moves point past them"
  '(#f "A B C" 6)
  (probe "a b c" 1 capitalize-word 3))

;; From the middle of a word, capitalization starts at point: the part of
;; the word before point is not cased, and point moves to the word's end.
(test-equal "capitalize-word inside a word"
  '(#f "heLlo world" 6)
  (probe "hello world" 3 capitalize-word 1))

;;--------------------------------------------------------------
;; The Greek final sigma
;;--------------------------------------------------------------

;; "In Greek, lower case sigma has two forms: one when used in the middle
;; and one when used at the end of a word" (`casefiddle.c:189'), and the
;; rule is that a capital sigma downcased *at the end of a word* becomes
;; the final form.
;;
;; The first sigma below is followed by a space, so it is at a word's
;; end, and becomes ς. The second ends the buffer but does **not**,
;; because the context it is cased in is not within a word - the space
;; left it. That second half is the `was_inword` part of the condition,
;; and it is what a plausible-looking implementation gets wrong.
(test-equal "a sigma at a word's end takes the final form"
  (list #f (greeks #x3bf #x3b4 #x3bf final-sigma #x20 small-sigma) 1)
  (probe (greeks #x39f #x394 #x39f capital-sigma #x20 capital-sigma)
         1 downcase-region 1 7))

;; A sigma followed by another word constituent is the ordinary form, and
;; one that ends the buffer with no word before it is too.
(test-equal "a sigma inside a word is the ordinary form"
  (list #f (greeks small-sigma final-sigma) 1)
  (probe (greeks capital-sigma capital-sigma) 1 downcase-region 1 3))

(test-equal "a sigma continued by a letter is the ordinary form"
  (list #f (greeks small-sigma #x3b1) 1)
  (probe (greeks capital-sigma #x391) 1 downcase-region 1 3))

;; Upcasing is not the sigma rule's business - it is the *downcase* of a
;; capital sigma that has two answers.
(test-equal "upcasing a small sigma is one answer"
  (list #f (greeks capital-sigma capital-sigma) 1)
  (probe (greeks small-sigma final-sigma) 1 upcase-region 1 3))

;;--------------------------------------------------------------
;; The undo record
;;--------------------------------------------------------------

(define (undo-probe text position fn . args)
  ;; The undo list after FN, and then what one `primitive-undo' makes of
  ;; it - Emacs's own two probes, in the order they were taken. The list
  ;; starts empty, which is what `(setq buffer-undo-list nil)' did in the
  ;; Emacs measurement.
  ;;--------------------------------------------------------------
  (let ((ed (fresh-buffer)))
    (set-buffer ed)
    (erase-buffer)
    (insert text)
    (set!text-editor-undo-list ed '())
    (goto-char position)
    (apply fn args)
    (let ((entries (text-editor-undo-list ed)))
      (primitive-undo 1 entries)
      (list entries (buffer-string) (point)))))

;; The region is recorded as **one** deletion of the whole original
;; followed by **one** insertion of it, however many characters the walk
;; then writes. That is the point of `record_delete` and `record_insert`
;; bracketing the loop, and it is why one undo puts the whole region
;; back: the two records are a pair with no boundary between them, so
;; `primitive-undo` walks straight through both.
(test-equal "the region is one deletion and one insertion, and one undo reverses it"
  '(((1 . 4) ("abc" . 1)) "abc def" 1)
  (undo-probe "abc def" 3 upcase-region 1 4))

(test-end "schemacs_editor_casefiddle")
