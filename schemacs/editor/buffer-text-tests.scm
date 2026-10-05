(import
  (scheme base)
  (schemacs editor buffer-text)
  (only (srfi 1) iota)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  )

;; `buffer-text' is GNU Emacs's `struct buffer_text' as an object. The
;; positions it answers are `base'-based, and the tests below are
;; written in those coordinates - with base 1 that means the first
;; character is at position 1 and `point-max' is `length + 1'.

(define (contents bt)
  (buffer-text-substring bt (buffer-text-base bt) (buffer-text-z bt))
  )

;; The two invariants that must hold after every operation: the end
;; position is the base plus the character count, and the store holds
;; exactly the characters plus the gap.
(define (check-invariants bt)
  (and (= (buffer-text-z bt)
          (+ (buffer-text-base bt) (buffer-text-length bt)))
       (= (buffer-text-allocation bt)
          (+ (buffer-text-length bt) (buffer-text-gap-size bt)))
       ))

(define (positions bt)
  (let ((acc '()))
    (buffer-text-for-each bt (lambda (pos cp) (set! acc (cons pos acc))))
    (reverse acc)))

(test-begin "schemacs_editor_buffer_text")

;;----------------------------------------------------------------------
;; An empty one. Emacs's `point-min' and `point-max' are both 1, so
;; position 1 exists even with no characters.

(let ((bt (new-buffer-text 1)))
  (test-equal 0 (buffer-text-length bt))
  (test-equal 1 (buffer-text-z bt))
  (test-equal 1 (buffer-text-base bt))
  (test-equal "" (contents bt))
  (test-equal '() (positions bt))
  (test-assert (check-invariants bt)))

;;----------------------------------------------------------------------
;; Inserting at the beginning, and reading it back.

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "hello")
  (test-equal 5 (buffer-text-length bt))
  (test-equal 6 (buffer-text-z bt))
  (test-equal "hello" (contents bt))
  (test-equal '(1 2 3 4 5) (positions bt))
  (test-assert (check-invariants bt))
  (test-equal (char->integer #\h) (buffer-text-ref bt 1))
  (test-equal (char->integer #\o) (buffer-text-ref bt 5)))

;;----------------------------------------------------------------------
;; Inserting in the middle and at the end. The gap has to move, which
;; is the one shift this class does.

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "held")
  (buffer-text-insert! bt 3 "X")          ; "heXld"
  (test-equal "heXld" (contents bt))
  (buffer-text-insert! bt 6 "!")          ; at point-max
  (test-equal "heXld!" (contents bt))
  (buffer-text-insert! bt 1 ">>")         ; at point-min
  (test-equal ">>heXld!" (contents bt))
  (test-assert (check-invariants bt)))

;;----------------------------------------------------------------------
;; Deleting.

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "abcdef")
  (buffer-text-delete! bt 3 5)            ; drop "cd" -> "abef"
  (test-equal "abef" (contents bt))
  (test-equal 4 (buffer-text-length bt))
  (buffer-text-delete! bt 1 3)            ; drop "ab"
  (test-equal "ef" (contents bt))
  (buffer-text-delete! bt 1 3)            ; everything
  (test-equal "" (contents bt))
  (test-equal 0 (buffer-text-length bt))
  (test-equal 1 (buffer-text-z bt))
  (test-assert (check-invariants bt))
  ;; and it still works after being emptied
  (buffer-text-insert! bt 1 "again")
  (test-equal "again" (contents bt)))

;;----------------------------------------------------------------------
;; `set!'

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "abc")
  (buffer-text-set! bt 2 (char->integer #\Z))
  (test-equal "aZc" (contents bt)))

;;----------------------------------------------------------------------
;; A substring that crosses the gap.

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "0123456789")
  (buffer-text-insert! bt 4 "AB")         ; gap now sits inside the text
  (test-equal "012AB3456789" (contents bt))
  (test-equal "2AB3" (buffer-text-substring bt 3 7))
  (test-equal "" (buffer-text-substring bt 4 4)))

;;----------------------------------------------------------------------
;; Growth. Inserting past the store has to reallocate, and the
;; characters either side of the gap must survive it. Emacs's policy
;; adds `max (shortfall, (Z - BEG) / 64)' plus GAP_BYTES_DFL (2000), so
;; the store jumps well past what was asked for.

(let ((bt (new-buffer-text 1 4)))          ; deliberately small
  (buffer-text-insert! bt 1 "0123456789")
  (test-equal "0123456789" (contents bt))
  (test-assert (< 4 (buffer-text-allocation bt)))
  ;; and the text still answers correctly after the move
  (let loop ((i 0))
    (cond
     ((< i 10)
      (test-equal (char->integer (string-ref "0123456789" i))
                  (buffer-text-ref bt (+ 1 i)))
      (loop (+ 1 i))
      )))
  (test-assert (check-invariants bt)))

;; Many insertions, so the store grows repeatedly and the gap lands in
;; different places each time.
(let ((bt (new-buffer-text 1 1)))
  (let loop ((i 0))
    (cond
     ((< i 40)
      (buffer-text-insert! bt (+ 1 i) (number->string (modulo i 10)))
      (loop (+ 1 i))
      )))
  (test-equal 40 (buffer-text-length bt))
  (test-equal (apply string-append
                     (map number->string
                          (map (lambda (i) (modulo i 10)) (iota 40))))
              (contents bt)))

;;----------------------------------------------------------------------
;; `clear!'

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "something")
  (let ((alloc (buffer-text-allocation bt)))
    (buffer-text-clear! bt)
    (test-equal 0 (buffer-text-length bt))
    (test-equal "" (contents bt))
    ;; the allocation is kept, so the gap is the whole store
    (test-equal alloc (buffer-text-allocation bt))
    (test-equal alloc (buffer-text-gap-size bt))
    (test-assert (check-invariants bt))))

;;----------------------------------------------------------------------
;; The base. It is a convention rather than a knob - every instance
;; must agree - but the arithmetic must not hard-code 1.

(let ((bt (new-buffer-text 0)))
  (test-equal 0 (buffer-text-base bt))
  (buffer-text-insert! bt 0 "xyz")
  (test-equal "xyz" (buffer-text-substring bt 0 (buffer-text-z bt)))
  (test-equal 3 (buffer-text-z bt))          ; base + length
  (test-equal '(0 1 2) (positions bt))
  (test-equal (char->integer #\z) (buffer-text-ref bt 2)))

;;----------------------------------------------------------------------
;; Inserting a whole string in one go, and mixed content.

(let ((bt (new-buffer-text 1)))
  (buffer-text-insert! bt 1 "line one\nline two\n")
  (test-equal "line one\nline two\n" (contents bt))
  (test-equal 18 (buffer-text-length bt))
  ;; a code point outside Latin-1
  (buffer-text-insert! bt 1 (string (integer->char #x4E2D)))
  (test-equal #x4E2D (buffer-text-ref bt 1))
  (test-equal 19 (buffer-text-length bt)))

(test-end "schemacs_editor_buffer_text")
