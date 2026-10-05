(import
  (scheme base)
  (schemacs gap-buffer)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  )

;;------------------------------------------------------------------------------

(define (call-with-string-port f)
  (call-with-port (open-output-string)
    (lambda (port) (f port) (get-output-string port))
    ))

(define (write-index-val port)
  (lambda (i val)
    (write-char #\space port)
    (display i port)
    (write-char #\: port)
    (display val port)
    ))

(define (report-mismatch expect actual)
  (display "  expect: ") (display expect) (newline)
  (display "  actual: ") (display actual) (newline)
  )

(define (test-results=? expect actual)
  (cond
   ((equal? expect actual) #t)
   (else (report-mismatch expect actual) #f)
   ))

(define (gap-buffer-content-to-string gb for-each/index)
  (call-with-string-port
   (lambda (port)
     (for-each/index (write-index-val port) gb)
     )))

(define (test-gap-buffer-state gb)
  (list
   (cons 'cursor (gap-buffer-cursor gb))
   (cons 'weight (gap-buffer-weight gb))
   (cons 'length (gap-buffer-length gb))
   (cons
    'before
    (gap-buffer-content-to-string gb gap-buffer-for-each-before/index)
    )
   (cons
    'after
    (gap-buffer-content-to-string gb gap-buffer-for-each-after/index)
    )
   (cons
    'all
    (gap-buffer-content-to-string gb gap-buffer-for-each/index)
    )))

;;------------------------------------------------------------------------------

(test-begin "schemacs_GapBuffer")

;; The gap buffer takes the array *type* of its store now, not an
;; interface object - see `(schemacs arrays)'. `u16' is what
;; `(array-type (u16vector))' answers.
(define vif 'u16)

(define gb (new-gap-buffer vif 8 0))

(test-assert (gap-buffer-start-of-line? gb))
(test-assert (gap-buffer-end-of-line? gb))

(test-equal 8 (gap-buffer-length gb))
(test-equal 0 (gap-buffer-weight gb))
(test-assert (gap-buffer-start-of-line? gb))
(test-assert (gap-buffer-end-of-line? gb))

(test-assert
    (test-results=?
     '((cursor . 0) (weight . 0) (length . 8)
       (before . "")
       (after  . "")
       (all    . "")
       )
     (test-gap-buffer-state gb)
     ))

(define (gb-fill-string gb str)
  (string-for-each
   (lambda (c)
     (gap-buffer-insert-before
      gb (* 10 (- (char->integer c) 97))
      ))
   str
   ))

(gb-fill-string gb "abcdefghij")

(test-assert
    (test-results=?
     '((cursor . 10) (weight . 10) (length . 2009)
       (before . " 0:0 1:10 2:20 3:30 4:40 5:50 6:60 7:70 8:80 9:90")
       (after  . "")
       (all    . " 0:0 1:10 2:20 3:30 4:40 5:50 6:60 7:70 8:80 9:90")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-move-cursor gb -5)

(test-equal '(0 10 20 30 40 50 60 70 80 90)
  (let loop ((i 0))
    (cond
     ((< i 10) (cons (gap-buffer-ref gb i) (loop (+ 1 i))))
     (else '())
     )))

(test-equal '(40 50)
  (list
   (gap-buffer-ref-before gb #f)
   (gap-buffer-ref-after  gb #f)
   ))

(test-assert
    (test-results=?
     '((cursor . 5) (weight . 10) (length . 2009)
       (before . " 0:0 1:10 2:20 3:30 4:40")
       (after  . " 5:50 6:60 7:70 8:80 9:90")
       (all    . " 0:0 1:10 2:20 3:30 4:40 5:50 6:60 7:70 8:80 9:90")
       )
     (test-gap-buffer-state gb)
     ))


(gap-buffer-cursor-to-start gb)

(test-assert
    (test-results=?
     '((cursor . 0) (weight . 10) (length . 2009)
       (before . "")
       (after  . " 0:0 1:10 2:20 3:30 4:40 5:50 6:60 7:70 8:80 9:90")
       (all    . " 0:0 1:10 2:20 3:30 4:40 5:50 6:60 7:70 8:80 9:90")
       )
     (test-gap-buffer-state gb)
     ))

(set! gb (new-gap-buffer vif 4 0))

(gap-buffer-insert-before gb 10)

(test-assert
    (test-results=?
     '((cursor . 1) (weight . 1) (length . 4)
       (before . " 0:10")
       (after  . "")
       (all    . " 0:10")
       )
     (test-gap-buffer-state gb)
     ))


(gap-buffer-move-cursor gb -1)

(test-assert
    (test-results=?
     '((cursor . 0) (weight . 1) (length . 4)
       (before . "")
       (after  . " 0:10")
       (all    . " 0:10")
       )
     (test-gap-buffer-state gb)
     ))

(test-assert
    (test-results=?
     '((cursor . 0) (weight . 1) (length . 4)
       (before . "")
       (after  . " 0:10")
       (all    . " 0:10")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-move-cursor gb 1)

(test-assert
    (test-results=?
     '((cursor . 1) (weight . 1) (length . 4)
       (before . " 0:10")
       (after  . "")
       (all    . " 0:10")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-insert-before gb 20)
(gap-buffer-move-cursor gb -2)
(gap-buffer-insert-before gb 30)
(gap-buffer-move-cursor gb 3)

(test-assert
    (test-results=?
     '((cursor . 3) (weight . 3) (length . 4)
       (before . " 0:30 1:10 2:20")
       (after  . "")
       (all    . " 0:30 1:10 2:20")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-move-cursor gb -3)
(gap-buffer-insert-after gb 40)
(gap-buffer-move-cursor gb 2)

(test-assert
    (test-results=?
     '((cursor . 2) (weight . 4) (length . 4)
       (before . " 0:40 1:30")
       (after  . " 2:10 3:20")
       (all    . " 0:40 1:30 2:10 3:20")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-insert-after gb 50)

(test-assert
    (test-results=?
     '((cursor . 2) (weight . 5) (length . 2005)
       (before . " 0:40 1:30")
       (after  . " 2:50 3:10 4:20")
       (all    . " 0:40 1:30 2:50 3:10 4:20")
       )
     (test-gap-buffer-state gb)
     ))

(gap-buffer-move-cursor gb -2)
(gap-buffer-insert-after gb 60)
(gap-buffer-insert-after gb 70)
(gap-buffer-insert-after gb 80)
(gap-buffer-insert-after gb 90)

(test-assert
    (test-results=?
     '((cursor . 0) (weight . 9) (length . 2005)
       (before . "")
       (after  . " 0:90 1:80 2:70 3:60 4:40 5:30 6:50 7:10 8:20")
       (all    . " 0:90 1:80 2:70 3:60 4:40 5:30 6:50 7:10 8:20")
       )
     (test-gap-buffer-state gb)
     ))

(define (count-deletions gb n)
  (let ((count 0))
    (gap-buffer-delete gb n (lambda _ (set! count (+ 1 count)) 0))
    count))

(set! gb (new-gap-buffer vif 8 0))
(gb-fill-string gb "abcdefghij")
(gap-buffer-move-cursor gb -5)

(test-assert
    (test-results=?
     `((deleted-before . 2)
       (deleted-after  . 2)
       (cursor . 3) (weight . 6) (length . 2009)
       (before . " 0:0 1:10 2:20")
       (after  . " 3:70 4:80 5:90")
       (all    . " 0:0 1:10 2:20 3:70 4:80 5:90")
       )
     `((deleted-before . ,(count-deletions gb -2))
       (deleted-after  . ,(count-deletions gb 2))
       . ,(test-gap-buffer-state gb)
         )))

;; The lengths above are GNU Emacs's growth policy, not a doubling -
;; `make_gap' + `make_gap_larger' (insdel.c:583, :467): a grow adds
;; `max (shortfall, (Z - BEG) / 64)' plus `GAP_BYTES_DFL' (2000), so the
;; 2000 dominates on a store this small. The two growths in this file
;; are 8 -> 2009 (the ninth insert into an 8-element store, text 8) and
;; 4 -> 2005 (the fifth, text 4).
;;
;; `gap-buffer-allocate' asks for an exact total and only ever grows;
;; shrinking is `gap-buffer-compact''s.
(test-equal '(2009 3000 3000)
  (list
   (gap-buffer-length gb)
   (let ()
     (gap-buffer-allocate gb 3000)
     (gap-buffer-length gb)
     )
   (let ()
     (gap-buffer-allocate gb 50)
     (gap-buffer-length gb)
     )))

(test-equal '(10 80)
  (let ()
    (gap-buffer-move-cursor gb -3)
    (gap-buffer-delete gb 1)
    (gap-buffer-move-cursor gb 5)
    (gap-buffer-delete gb -1)
    (gap-buffer-update-min-max gb)
    (list (gap-buffer-minimum gb) (gap-buffer-maximum gb))
    ))

(test-end "schemacs_GapBuffer")
