(define-library (schemacs vbal)
  ;; VBAL: Vector-Backed Assosication Lists. This is a way of packing
  ;; the information of an Association List into a vector that is not
  ;; expected to be immutable. Individual elements may be changed, but
  ;; the size of the vector does not without being reallocated.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    (scheme case-lambda))
  (export
   vbal-type?  vbal-length  vbal-copy
   alist->vbal  vbal->vector  vbal->alist  plist->vbal  vbal->plist
   vbal-find  vbal-assoc  vbal-assq  vbal-assv
   vbal-ref  vbal-set!  vbal-key-set!  vbal-value-set!
   vbal-map  vbal-map!  vbal-for-each
   )
  (begin

    (define-record-type <vbal-type>
      (make<vbal> vec)
      vbal-type?
      (vec vbal->vector)
      )

    (define (vbal-length vbal)
      (quotient (vector-length (vbal->vector vbal)) 2)
      )

    (define (vbal-copy vbal)
      (make<vbal> (vector-copy (vbal->vector vbal)))
      )

    (define (alist->vbal elems)
      (let*((len (length elems))
            (vec (make-vector (* 2 len)))
            )
        (let loop ((elems elems) (i 0))
          (cond
           ((pair? elems)
            (let ((elem (car elems)))
              (vector-set! vec i (car elem))
              (vector-set! vec (+ 1 i) (cdr elem))
              (loop (cdr elems) (+ 2 i))
              ))
           (else (make<vbal> vec))
           ))))

    (define (plist->vbal elems)
      (let*((len (length elems))
            (len (if (odd? len) (+ 1 len) len))
            (vec (make-vector len))
            )
        (let loop ((i 0) (elems elems))
          (cond
           ((null? elems)
            (when (odd? i) (vector-set! vec i #f))
            (make<vbal> vec)
            )
           (else
            (vector-set! vec i (car elems))
            (loop (+ 1 i) (cdr elems))
            )))))

    (define (vbal->alist vbal)
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            )
        (let loop ((i 0))
          (cond
           ((< i len)
            (cons
             (cons (vector-ref vec i) (vector-ref vec (+ 1 i)))
             (loop (+ 2 i))
             ))
           (else '())
           ))))

    (define (vbal->plist vbal)
      (vector->list (vbal->vector vbal))
      )

    (define (vbal-find pred vbal)
      ;; Takes a predicate `PRED` and for each association in `VBAL`
      ;; applies to `PRED` three arguments:
      ;;
      ;;  1. the integer index of the vector, this value can be used
      ;;     with `vbal-ref` to lookup the pair that is currently
      ;;     being used to evaluate `PRED`.
      ;;
      ;;  2. the association key
      ;;
      ;;  3. the association value
      ;;
      ;; `PRED` must return a single value. If the returned value is
      ;; `#F`, then `VBAL-FIND` continues on iterating to the next
      ;; association. If `VBAL-FIND` reaches the end of the `VBAL` and
      ;; `PRED` returns `#F` for all elements then `#F` is
      ;; returned. If `PRED` returns a non-`#F` result, iteration
      ;; halts and that result is returned as is.
      ;;------------------------------------------------------------------
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            )
        (let loop ((i 0))
          (cond
           ((< i len)
            (or (pred
                 (quotient i 2)
                 (vector-ref vec i)
                 (vector-ref vec (+ 1 i))
                 )
                (loop (+ 2 i))
                ))
           (else #f)
           ))))

    (define (&vbal-assoc compare)
      (lambda (obj vbal)
        (vbal-find
         (lambda (i key val) (and (compare obj key) (cons key val)))
         vbal
         )))

    (define vbal-assoc
      ;; Similar to the standard Scheme procedure `ASSOC` returns a
      ;; pair containing `(KEY . VALUE)` if `KEY` is `EQUAL?` to the
      ;; applied argument `OBJ`.
      ;;------------------------------------------------------------------
      (case-lambda
        ((obj vbal) ((&vbal-assoc equal?) obj vbal))
        ((obj vbal compare) ((&vbal-assoc compare) obj vbal))
        ))

    (define vbal-assq (&vbal-assoc eq?))
    (define vbal-assv (&vbal-assoc eqv?))

    (define (vbal-ref vbal i)
      ;; Using `VBAL` as a vector, this procedure looks-up the KEY and
      ;; VALUE at the given index `I`. Two values are returned, `KEY` and
      ;; `VALUE`.
      ;;------------------------------------------------------------------
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            (i (* 2 i))
            )
        (values
         (vector-ref vec i)
         (vector-ref vec (+ 1 i))
         )))

    (define (vbal-set! vbal i key val)
      ;; The counterpart to `VBAL-REF`, sets a `KEY` and `VALUE` at
      ;; the given index in the `VBAL`'s internal vector.
      ;;------------------------------------------------------------------
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            (i (* 2 i))
            )
        (vector-set! vec i key)
        (vector-set! vec (+ 1 i) val)
        (values)
        ))

    (define (vbal-key-set! vbal i key)
      ;; Like `VBAL-SET!` but only sets the key, not the value.
      ;;------------------------------------------------------------------
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            (i (* 2 i))
            )
        (vector-set! vec i key)
        (values)
        ))

    (define (vbal-value-set! vbal i value)
      ;; Like `VBAL-SET!` but only sets the value, not the key.
      ;;------------------------------------------------------------------
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            (i (* 2 i))
            )
        (vector-set! vec (+ 1 i) value)
        (values)
        ))

    (define (vbal-map! proc vbal)
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            )
        (let loop ((i 0))
          (cond
           ((< i len)
            (let-values
                (((key val)
                  (proc
                   (vector-ref vec i)
                   (vector-ref vec (+ 1 i))
                   )))
              (vector-set! vec i key)
              (vector-set! vec (+ 1 i) val)
              (loop (+ 2 i))
              ))
           (else vbal)
           ))))

    (define (vbal-map proc vbal)
      (vbal-map! proc (make<vbal> (vector-copy (vbal->vector vbal))))
      )

    (define (vbal-for-each proc vbal)
      (let*((vec (vbal->vector vbal))
            (len (vector-length vec))
            )
        (let loop ((i 0))
          (cond
           ((< i len)
            (proc (vector-ref vec i) (vector-ref vec (+ 1 i)))
            (loop (+ 2 i))
            )
           (else (values))
           ))))

    ;;----------------------------------------------------------------
    ))
