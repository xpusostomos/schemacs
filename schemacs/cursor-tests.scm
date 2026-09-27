(import
  (scheme base)
  (srfi 64) ;;testing
  ;; SRFI 69 is here for `hash-table-ref' and the like; `alist->hash-table'
  ;; is the project's own, so it is not taken from SRFI 69 as well -
  ;; importing a name from two places is what Guile warns about.
  (except (srfi 69) alist->hash-table)
  (schemacs cursor)
  (only (schemacs lens) lens-set view)
  (only (schemacs hash-table) alist->hash-table)
  )

(test-begin "schemacs_cursor")

;;--------------------------------------------------------------------
;; Preliminary setup

(define cur #f)
(define somevec (apply vector '(A B C D E)))
(define somelist '(A B C D E))
(define somstr "ABCDE")
(define somehash (alist->hash-table '((one . 1) (two . 2) (three . 3))))

(define-record-type <altvec-type>
  (vector->altvec vec) altvec-type? (vec altvec->vector))

(define (altvec . args) (vector->altvec (apply vector args)))
(define (altvec-length obj) (vector-length (altvec->vector obj)))
(define (altvec-ref obj i) (vector-ref (altvec->vector obj) i))
(define altvec-cursor-iface
  (make<cursor-interface>
   (lambda (obj i) (>= i (altvec-length obj)))
   altvec-ref #f (lambda (obj i) (values))
   ))

(declare-interface/cursor altvec-type? altvec-cursor-iface)

(define somealtvec (apply altvec '(A B C D E)))

;;--------------------------------------------------------------------

(set! cur (new-cursor somevec))

(test-eq 'A (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 0 (view cur =>cursor-index!))
(test-eqv 1 (cursor-step! cur))
(test-eq 'B (cursor-ref cur))
(test-eqv 2 (cursor-step! cur))
(test-eq 'C (cursor-ref cur))
(test-eqv 3 (cursor-step! cur))
(test-eq 'D (cursor-ref cur))
(test-eqv 4 (cursor-step! cur))
(test-eq 'E (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))
(test-eq 3 (let() (lens-set 3 cur =>cursor-index!) (view cur =>cursor-index!)))
(test-assert (not (cursor-end? cur)))
(test-eq 'D (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 4 (cursor-step! cur))
(test-eq 'E (cursor-ref cur))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))

;;--------------------------------------------------------------------

(set! cur (new-cursor somstr))

(test-eq #\A (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 0 (view cur =>cursor-index!))
(test-eqv 1 (cursor-step! cur))
(test-eq #\B (cursor-ref cur))
(test-eqv 2 (cursor-step! cur))
(test-eq #\C (cursor-ref cur))
(test-eqv 3 (cursor-step! cur))
(test-eq #\D (cursor-ref cur))
(test-eqv 4 (cursor-step! cur))
(test-eq #\E (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))
(test-eq 3 (let() (lens-set 3 cur =>cursor-index!) (view cur =>cursor-index!)))
(test-assert (not (cursor-end? cur)))
(test-eq #\D (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 4 (cursor-step! cur))
(test-eq #\E (cursor-ref cur))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))

;;--------------------------------------------------------------------

(set! cur (new-cursor somelist))

(test-eq 'A (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 0 (view cur =>cursor-index!))
(test-eqv 1 (cursor-step! cur))
(test-eq 'B (cursor-ref cur))
(test-eqv 2 (cursor-step! cur))
(test-eq 'C (cursor-ref cur))
(test-eqv 3 (cursor-step! cur))
(test-eq 'D (cursor-ref cur))
(test-eqv 4 (cursor-step! cur))
(test-eq 'E (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))


;;--------------------------------------------------------------------

(set! cur (new-cursor somehash))

(define (test-hash-step i end)
  (let ((a (cursor-ref cur)))
    (test-eq (cdr a) (hash-table-ref somehash (car a)))
    (test-eqv i (view cur =>cursor-index!))
    (test-assert (+ i 1) (cursor-step! cur))
    (test-eq end (cursor-end? cur))
    ))

(test-hash-step 0 #f)
(test-hash-step 1 #f)
(test-hash-step 2 #t)

;;--------------------------------------------------------------------

(set! cur (new-cursor somealtvec))

(test-eq 'A (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 0 (view cur =>cursor-index!))
(test-eqv 1 (cursor-step! cur))
(test-eq 'B (cursor-ref cur))
(test-eqv 2 (cursor-step! cur))
(test-eq 'C (cursor-ref cur))
(test-eqv 3 (cursor-step! cur))
(test-eq 'D (cursor-ref cur))
(test-eqv 4 (cursor-step! cur))
(test-eq 'E (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))
(test-eq 3 (let() (lens-set 3 cur =>cursor-index!) (view cur =>cursor-index!)))
(test-assert (not (cursor-end? cur)))
(test-eq 'D (cursor-ref cur))
(test-assert (not (cursor-end? cur)))
(test-eqv 4 (cursor-step! cur))
(test-eq 'E (cursor-ref cur))
(test-eqv 5 (cursor-step! cur))
(test-assert (cursor-end? cur))

;;--------------------------------------------------------------------

(test-end "schemacs_cursor")
