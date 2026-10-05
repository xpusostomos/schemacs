(define-library (schemacs editor cdf)
  ;; A Cumulative Distribution Function (CDF) data type for which APIs
  ;; that can lazily construct and alter the CDF have been defined.
  ;; This data structure is specifically designed for use with the
  ;; Schemacs text editor engine, but may be of use in other places as
  ;; well, so it is provided as a library.
  ;;
  ;; It mirrors no Emacs file. GNU Emacs answers the question the CDF
  ;; answers - which line and column a buffer position is on, and what
  ;; the position of a line is - by keeping intervals over the buffer
  ;; (`intervals.c') and by walking the gap; the CDF is this project's
  ;; way of answering it in one lookup. It is here because the engine
  ;; uses it, and it is named after what it is rather than after a file
  ;; in Emacs, since there is no such file.
  ;;------------------------------------------------------------------

  (import
   (scheme base)
   (scheme case-lambda)
   ;;(scheme write) ;;DEBUG
   (only (schemacs arrays)
         %array-resize
         )
   (only (guile)
         array-length
         array-ref
         array-set!
         make-typed-array
         )
   )

  (export
   new-cdf  cdf-vector-type?
   cdf-vector-seq-type  cdf-vector  cdf-cursor  cdf-maximum
   cdf-ref  cdf-fill  cdf-invalidate!  cdf-push  cdf-pop
   cdf-find cdf-for-each
   )

  (begin

    (define-record-type <cdf-vector-type>
      ;; This is a cumultative distribution function (CDF) that is
      ;; designed to grow and shrink with a dynamic probability
      ;; distribution function (PDF) that can change over time. The
      ;; CDF is re-computed lazily, only recomputed when `CDF-FIND` is
      ;; called on a `CDF` for which it's associated PDF has changed.
      (make<cdf-vector> type vec cur max)
      cdf-vector-type?
      (type   cdf-vector-seq-type)
      ;; ^ The array type of the store, as `array-type` answers it - the
      ;; gap buffer's `gap-buffer-seq-type` is the same thing. It was an
      ;; interface object until `(schemacs sequence)` went.
      (vec    cdf-vector   set!cdf-vector)
      (cur    cdf-cursor   set!cdf-cursor)
      (max    cdf-maximum  set!cdf-maximum)
      )

    (define (%cdf-allocate-size len request)
      ;; The author's `default-allocate-function' (`sequence.sld:288'),
      ;; moved here. Unlike the gap buffer, the CDF mirrors no Emacs
      ;; file - Emacs answers what the CDF answers with intervals
      ;; (`intervals.c') - so there is no Emacs growth policy to copy,
      ;; and this is kept as it was. The `max 1' is what lets
      ;; `(new-cdf 0)' work.
      ;;--------------------------------------------------------------
      (let loop ((len (max 1 len)))
        (if (< len request) (loop (* 2 len)) len)
        ))

    (define (%cdf-allocate vec request)
      ;; Grow `VEC' to cover `REQUEST' - the author's
      ;; `sequence-allocate', now the two steps it always was. The same
      ;; vector comes back untouched when it is already big enough, and
      ;; `cdf-fill' tests that with `eq?'.
      ;;--------------------------------------------------------------
      (%array-resize vec (%cdf-allocate-size (array-length vec) request) 0)
      )

    (define new-cdf
      ;; Construct a cumulative distribution function (CDF) of type
      ;; `<cdf-vector-type>` of a given `SIZE` and (optionally) over
      ;; array type `TYPE`. If `TYPE` is not given it is `u64'.
      (case-lambda
       ((size) (new-cdf 'u64 size))
       ((type size)
        (make<cdf-vector> type (make-typed-array type 0 size) 0 0)
        )))

    (define (cdf-ref cdf i)
      (and
       (<= 0 i) (< i (cdf-cursor cdf))
       (array-ref (cdf-vector cdf) i)
       ))

    (define (cdf-fill cdf generate)
      ;; Internally, the CDF is modeled as vector and as a stack. The
      ;; stack is modeled by keeping a `cdf-cursor` value pointing at
      ;; the index that represents the top of the stack. You can push
      ;; or pop integers onto or off-of the stack, this stores
      ;; integers into the vector and moves the cursor.
      ;;
      ;; The `GENERATE` function must take two values, (1) `INDEX` is
      ;; the current index of the CDF vector, and (2) `ACCUM`, which
      ;; will be the value of the current top of the CDF stack when
      ;; `GENERATE` is applied. The `GENERATE` function must return
      ;; the integer value to be pushed to the CDF stack, or if the
      ;; generator is out of values, it must return `#f`.
      ;;
      ;; This function generates integers from the `GENERATE` function
      ;; given as an argument and pushes to the top of the CDF stack
      ;; the sum of each generated integer with the previous top of
      ;; the stack.  The last value pushed to the CDF stack is the
      ;; value returned by this function.
      ;;--------------------------------------------------------------
      (let*((vec    (cdf-vector cdf))
            (len    (array-length vec))
            (cursor (cdf-cursor cdf))
            (accum
             (if (< 0 cursor)
                 (array-ref vec (- cursor 1))
                 0)))
        (let loop ((cursor cursor) (accum accum) (vec vec) (len len))
          (let ((next (generate cursor accum)))
            (cond
             (next
              (let*-values
                  (((vec len)
                    (let ((new-vec (%cdf-allocate vec (+ 1 cursor))))
                      (cond
                       ((not (eq? vec new-vec))
                        (set!cdf-vector cdf new-vec)
                        (values new-vec (array-length new-vec))
                        )
                       (else (values vec len))
                       )))
                   ((accum) (+ accum next))
                   )
                (array-set! vec accum cursor)
                (loop (+ 1 cursor) accum vec len)
                ))
             (else
              (set!cdf-cursor cdf cursor)
              (set!cdf-maximum cdf accum)
              accum
              ))))))

    (define (cdf-invalidate! cdf cursor)
      ;; Set the new `cursor` for the CDF. If the cursor is less than
      ;; the current `cdf-cursor` value, this means every element
      ;; after the `cursor` is invalid and needs to be
      ;; recomputed. This function simply sets the `cdf-cursor` and
      ;; returns the value of the CDF at the new cursor position. If
      ;; `cursor` is greater than the current `cdf-cursor`, then the
      ;; `cdf-cursor` is not changed and `#f` is returned.
      ;;--------------------------------------------------------------
      (let ((old-cursor (cdf-cursor cdf))
            )
        (cond
         ((< old-cursor cursor) #f)
         (else
          (set!cdf-cursor cdf cursor)
          (cond
           ((< 0 cursor)
            (let ((maximum (array-ref (cdf-vector cdf) (- cursor 1))))
              (set!cdf-maximum cdf maximum)
              maximum
              ))
           (else
            (set!cdf-maximum cdf 0)
            0))))))

    (define (cdf-push cdf . elems)
      (cdf-fill
       cdf
       (lambda (cursor accum)
         (cond
          ((null? elems) #f)
          (else
           (let ((next (car elems)))
             (set! elems (cdr elems))
             next
             ))))))

    (define cdf-pop
      (case-lambda
       ((cdf) (cdf-pop cdf 1))
       ((cdf n) (cdf-invalidate! cdf (max 0 (- (cdf-cursor cdf) n))))
       ))

    (define (cdf-find cdf n)
      ;; Binary search returning which "bucket" I in a PDF does the
      ;; integer argument `N` fall into given a CDF computed for the
      ;; PDF. Takes two arguments
      ;;
      ;;   - `CDF` is the <cdf-vector-type>
      ;;
      ;;   - `N` the number to search for, and return which bucket
      ;;      into which it would be placed.
      ;;
      ;; In simpler terms, a discrete probability distribution
      ;; function (PDF) can be thought of as a sequence of buckets of
      ;; varying sizes modeled by a vector of integers where the index
      ;; of the bucket in the vector describes it's "address". A PDF
      ;; has a discrete cumulative distribution function (CDF) which
      ;; is a vector of integers, but at each address in the CDF we
      ;; store the sum of all bucket sizes before that address in the
      ;; PDF, allowing us to see the distance (in the same units the
      ;; bucket sizes measure) that any given vector index is from the
      ;; origin, which allows us to find an index using a binary
      ;; search algorithm. When a random integer `N` is "dropped" onto
      ;; the field of buckets (modeled by the PDF), we can find
      ;; address of bucket into which this random integer `N` will
      ;; fall. This function computes the address of the bucket `N`
      ;; falls into using a binary search.
      ;;
      ;; This procedure returns two values:
      ;;
      ;;  1. the index `I` of the bucket into which the value `N`
      ;;     falls. In the context of a text editor, if `N` is the
      ;;     index of a character (from the start of the whole buffer
      ;;     of characters) this function returns the line number on
      ;;     which that index is placed.
      ;;
      ;;  2. the sum `S` of the sizes of all buckets up to and
      ;;     including the index `I`. In the context of a text editor,
      ;;     this is the number of all characters in the buffer prior
      ;;     to the start of the line on which the index `N` is
      ;;     placed.
      ;;
      ;; If `N` is out-of-bounds, that is, does not fall into any
      ;; bucket (too far to the negative or positive ends of the
      ;; field) then `(values #f #f)` is the result.
      ;;--------------------------------------------------------------
      (let*((ref    array-ref)
            (cursor (cdf-cursor cdf))
            (vec    (cdf-vector cdf))
            (top    (and (< 0 cursor) (ref vec (- cursor 1))))
            )
        (cond
         ((or (not top) (<= top n)) (values #f #f))
         (else
          (let ((half (floor-quotient cursor 2)))
            (let loop ((interval half) (i half))
              ;; Here we have a cursor i which selects the current and next
              ;; element in the CDF vector. We want to check if the given
              ;; value `n` is somewhere in between.
              (let*((lo    (if (< 0 i) (ref vec (- i 1)) 0))
                    (hi    (and (< i cursor) (ref vec i)))
                    (small (and lo (< n lo)))
                    (big   (and hi (<= hi n)))
                    )
                (cond
                 ((or small big)
                  (let ((interval (max 1 (floor-quotient interval 2))))
                    (loop interval (if small (- i interval) (+ i interval)))
                    ))
                 (else (values i lo))
                 ))))))))

    (define (cdf-for-each proc cdf)
      ;; Map over the internal CDF vector, applying each value to
      ;; `proc`.  The `proc` should return `#t` or `#f` to control
      ;; whether iteration should continue. This procedure itself will
      ;; return `#t` if all CDF elements were applied to `PROC`, or
      ;; `#f` otherwise
      ;;--------------------------------------------------------------
      (let*((vec (cdf-vector cdf))
            (cursor (cdf-cursor cdf))
            (ref array-ref)
            )
        (let loop ((i 0))
          (cond
           ((< i cursor) (if (proc (ref vec i)) (loop (+ 1 i)) #f))
           (else #t)
           ))))

    ))

;;------------------------------------------------------------------------------
;; TODO: fix bug
;;
;; n = 124, cursor = 13, top = 446
;; interval = 6, i = 6, lo =244, hi = 245, small = #t, big = #f
;; interval = 6, i = 3, lo =185, hi = 198, small = #t, big = #f
;; interval = 3, i = 0, lo =0, hi = 61, small = #f, big = #t
;; interval = 0, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
;; interval = 1, i = 1, lo =61, hi = 124, small = #f, big = #t
