;; Tests for `(schemacs editor region-cache)', the port of GNU Emacs's
;; `region-cache.c'.
;;
;; The cache answers two questions - "is this region known, and does it
;; have the property?" and "where does that change?" - and its one
;; dangerous failure is answering "known" for text that has since
;; changed. `find_newline' skips a region the cache calls known, so a
;; false "known" makes it skip a newline and report a line beginning that
;; is not one.
;;
;; The randomised test at the end is therefore a *safety* test and not a
;; completeness one: the cache is allowed to forget, and it is not
;; allowed to claim knowledge the model says it cannot have.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) for-each)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs editor region-cache))

(setvbuf (current-output-port) 'none)

;; A buffer of LENGTH characters whose first position is 1, as every
;; buffer in this tree is - so the positions asked about run from 1 to
;; LENGTH + 1, that last being `point-max'.
(define (cache-for length) (new-region-cache 1))

(define (beg c) 1)

(test-begin "schemacs_editor_region_cache")

;;--------------------------------------------------------------------
;; A fresh cache knows nothing
;;------------------------------------------------------------------

(test-equal '(0 11)
  (let* ((c (cache-for 10)))
    (call-with-values (lambda () (region-cache-forward c 1 11 5)) list)))

(test-equal '(0 1)
  (let* ((c (cache-for 10)))
    (call-with-values (lambda () (region-cache-backward c 1 11 5)) list)))

;;--------------------------------------------------------------------
;; Knowing a region
;;------------------------------------------------------------------

;; Everything inside the region is known, and the region after it is
;; where the knowledge changes.
(test-equal '(1 6)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 6)
    (call-with-values (lambda () (region-cache-forward c 1 11 3)) list)))

;; and asking outside answers not-known, at the boundary.
(test-equal '(0 11)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 6)
    (call-with-values (lambda () (region-cache-forward c 1 11 7)) list)))

;; Looking back from inside the region: known, and it changes at the
;; region's start.
(test-equal '(1 1)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 6)
    (call-with-values (lambda () (region-cache-backward c 1 11 5)) list)))

;;--------------------------------------------------------------------
;; Boundaries collapse and extend
;;------------------------------------------------------------------

;; Knowing the neighbouring region extends the first rather than leaving
;; a boundary between them: they have the same value, so a boundary there
;; would say nothing. This is the whole of `set_cache_region''s work.
(test-equal 2
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 4)
    (know-region-cache c 1 11 4 8)
    (region-cache-boundaries c)))

;; and the extended region is known throughout, in one query: the
;; knowledge changes at 8, where the known run ends.
(test-equal '(1 8)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 4)
    (know-region-cache c 1 11 4 8)
    (call-with-values (lambda () (region-cache-forward c 1 11 5)) list)))

;; Knowing everything leaves one boundary, at the buffer's beginning:
;; there is no position at which the knowledge changes.
(test-equal 1
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 11)
    (region-cache-boundaries c)))

(test-equal '(1 11)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 11)
    (call-with-values (lambda () (region-cache-forward c 1 11 5)) list)))

;; Knowing a region in the middle leaves three: the start of the buffer,
;; the start of the region and its end.
(test-equal 3
  (let ((c (cache-for 20)))
    (know-region-cache c 1 21 5 10)
    (region-cache-boundaries c)))

;;--------------------------------------------------------------------
;; Invalidating
;;------------------------------------------------------------------

;; An invalidation covering the whole buffer throws the knowledge away,
;; and the next query is the one that cleans up after it.
(test-equal '(0 11)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 11)
    (invalidate-region-cache c 1 11 0 0)
    (call-with-values (lambda () (region-cache-forward c 1 11 5)) list)))

;; An invalidation of the *middle* keeps the knowledge either side of it.
;; HEAD is the characters unchanged at the beginning of the buffer and
;; TAIL those unchanged at the end, so this modification covers 5..7.
(test-equal '((1 5) (0 8) (1 11))
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 11)
    (invalidate-region-cache c 1 11 4 3)
    (list (call-with-values (lambda () (region-cache-forward c 1 11 2)) list)
          (call-with-values (lambda () (region-cache-forward c 1 11 6)) list)
          (call-with-values (lambda () (region-cache-forward c 1 11 9)) list))))

;; An insertion at the end, then one at the beginning, with a query
;; between them: the second invalidation must not claim to know the
;; region the first one changed. The buffer grows by one either time, and
;; the cache's basis is reconciled by the query in between.
(test-equal '(0 3)
  (let ((c (cache-for 10)))
    (know-region-cache c 1 11 1 11)
    ;; a character appended: the first 10 characters are unchanged, and
    ;; the one new character at 11 is not
    (invalidate-region-cache c 1 12 10 0)
    ;; a query revalidates against the new endpoints ...
    (region-cache-forward c 1 12 5)
    ;; ... and then a character is prepended: position 1 is new, and the
    ;; 10 that were known are now at 2..11. The knowledge must run out at
    ;; 3, which is the first position neither change touched.
    (invalidate-region-cache c 1 13 0 10)
    (call-with-values (lambda () (region-cache-forward c 1 13 1)) list)))

;;--------------------------------------------------------------------
;; Safety: the cache may forget, but must never claim stale knowledge
;;
;; A model of the buffer - one entry per character, saying whether the
;; cache is allowed to call it known - is put through the same sequence
;; of knowings and invalidations with the same buffer length, and every
;; position the cache calls known must be one the model calls known.
;;
;; Same length throughout, so that a position means the same thing to
;; both; an insertion would shift them and the model with them, which is
;; what `invalidate_region_cache''s HEAD/TAIL form exists to avoid having
;; to express.
;;------------------------------------------------------------------

(define (run-model steps)
  ;; A pseudo-random but reproducible sequence; no dependency on the
  ;; host's random source.
  (let* ((n 40)
         (model (make-vector (+ n 2) #f))
         (c (new-region-cache 1))
         (seed 12345)
         (next-int (lambda (m)
                     (set! seed (modulo (+ (* seed 1103515245) 12345)
                                        2147483648))
                     (modulo (quotient seed 65536) m))))
    (let loop ((i 0))
      (when (< i steps)
        (let* ((a (+ 1 (next-int 39)))
               (b (+ a 1 (next-int (- n a))))
               (head (next-int a))
               (tail (next-int (- n (- b 1)))))
          (if (even? (next-int 3))
              (begin
                (know-region-cache c 1 (+ n 1) a b)
                (let mark ((j a))
                  (when (< j b) (vector-set! model j #t) (mark (+ j 1)))))
              (begin
                (invalidate-region-cache c 1 (+ n 1) head tail)
                ;; the modified region is [1 + head, n + 1 - tail)
                (let mark ((j (+ 1 head)))
                  (when (< j (- (+ n 1) tail))
                    (vector-set! model j #f)
                    (mark (+ j 1)))))))
        (loop (+ i 1))))
    (cons c model)))

(define (stale-claim steps)
  ;; The first position the cache calls known and the model does not, or
  ;; #f when there is none.
  (let* ((cm (run-model steps))
         (c (car cm))
         (model (cdr cm))
         (n 40))
    (let loop ((j 1))
      (cond ((> j n) #f)
            (else
             (let ((known (call-with-values
                              (lambda () (region-cache-forward c 1 (+ n 1) j))
                            (lambda (v next) v))))
               (if (and (= known 1) (not (vector-ref model j)))
                   j
                   (loop (+ j 1)))))))))

(test-equal #f (stale-claim 200))
(test-equal #f (stale-claim 1000))

;; and the model is not vacuous: some position really is known by the
;; end, so the check above is not passing by knowing nothing.
(test-assert
 (let* ((cm (run-model 200))
        (c (car cm))
        (n 40))
   (let loop ((j 1))
     (cond ((> j n) #f)
           ((= 1 (call-with-values
                     (lambda () (region-cache-forward c 1 (+ n 1) j))
                   (lambda (v next) v)))
            #t)
           (else (loop (+ j 1)))))))

(test-end "schemacs_editor_region_cache")
