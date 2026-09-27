(define-library (schemacs vector)

  ;; This library exists to provide a uniform interface to common APIs
  ;; that might be defined in different places depending on which
  ;; Scheme implementation is running this code. APIs exported here
  ;; can be imported exactly once per environment elsehwere in this
  ;; program without having to write a `COND-EXPAND` statement
  ;; everywhere one of these APIs are used.

  (import
   (scheme base)
   (scheme case-lambda)
   )
  (export
   vector-copy
   vector-fold
   )

  (cond-expand

    (guile

     (import
       ;; Only `VECTOR-FOLD' is wanted from SRFI 43: its other bindings
       ;; are the ones `(SCHEME BASE)' already provides - `VECTOR-COPY'
       ;; among them - and importing them from both made Guile warn
       ;; that `(schemacs vector)' had imported one name twice.
       (rename (only (srfi 43) vector-fold)
               (vector-fold old-vector-fold)
               ))
     (begin

      (define (vector-fold kons knil . vecs)
        ;; Re-define `VECTOR-FOLD` such that it's API is identical to
        ;; that of SRFI-133. To do this, the `INDEX` argument is no
        ;; longer passed to the `KONS` procedure on each iteration.
        (apply
         old-vector-fold
         (lambda (_index accum . elems) (apply kons accum elems))
         knil vecs
         ))

       ))

    ((or mit (library (srfi 133)))
     (import (only (srfi 133) vector-fold))
     )

    (else

     (begin

       (define (vector-fold kons knil . veclist)
         ;; This is an implementation of SRFI-133 `VECTOR-FOLD` written using
         ;; only APIs exposed by the `(SCHEME BASE)` library defined by the
         ;; R7RS Scheme standard.
         ;;------------------------------------------------------------------
         (let ((minlen
                (let loop ((veclist veclist) (minlen #f))
                  (cond
                   ((null? veclist) (if minlen minlen 0))
                   (else
                    (let ((thislen (vector-length (car veclist))))
                      (loop
                       (cdr veclist)
                       (if minlen (min thislen minlen) thislen)
                       )))))))
           (cond
            ((= 0 minlen) knil)
            (else
             (let loop ((i 0) (state knil))
               (cond
                ((>= i minlen) state)
                (else
                 (loop
                  (+ 1 i)
                  (apply
                   kons state
                   (map (lambda (vec) (vector-ref vec i))
                        veclist
                        ))))))))))

       )))

  (cond-expand
    ((or (library (srfi 4))
         (library (srfi 160))
         )
     (import
       (only
        (srfi 4)
        s8vector? make-s8vector s8vector s8vector-length
        s8vector-ref s8vector-set! s8vector->list list->s8vector

        u8vector? make-u8vector u8vector u8vector-length
        u8vector-ref u8vector-set! u8vector->list list->u8vector

        s16vector? make-s16vector s16vector s16vector-length
        s16vector-ref s16vector-set! s16vector->list list->s16vector

        u16vector? make-u16vector u16vector u16vector-length
        u16vector-ref u16vector-set! u16vector->list list->u16vector

        s32vector? make-s32vector s32vector s32vector-length
        s32vector-ref s32vector-set! s32vector->list list->s32vector

        u32vector? make-u32vector u32vector u32vector-length
        u32vector-ref u32vector-set! u32vector->list list->u32vector

        s64vector? make-s64vector s64vector s64vector-length
        s64vector-ref s64vector-set! s64vector->list list->s64vector

        u64vector? make-u64vector u64vector u64vector-length
        u64vector-ref u64vector-set! u64vector->list list->u64vector

        f32vector? make-f32vector f32vector f32vector-length
        f32vector-ref f32vector-set! f32vector->list list->f32vector

        f64vector? make-f64vector f64vector f64vector-length
        f64vector-ref f64vector-set! f64vector->list list->f64vector
        ))))

  (export
   s8vector? make-s8vector s8vector s8vector-length
   s8vector-ref s8vector-set! s8vector->list list->s8vector

   u8vector? make-u8vector u8vector u8vector-length
   u8vector-ref u8vector-set! u8vector->list list->u8vector

   s16vector? make-s16vector s16vector s16vector-length
   s16vector-ref s16vector-set! s16vector->list list->s16vector

   u16vector? make-u16vector u16vector u16vector-length
   u16vector-ref u16vector-set! u16vector->list list->u16vector

   s32vector? make-s32vector s32vector s32vector-length
   s32vector-ref s32vector-set! s32vector->list list->s32vector

   u32vector? make-u32vector u32vector u32vector-length
   u32vector-ref u32vector-set! u32vector->list list->u32vector

   s64vector? make-s64vector s64vector s64vector-length
   s64vector-ref s64vector-set! s64vector->list list->s64vector

   u64vector? make-u64vector u64vector u64vector-length
   u64vector-ref u64vector-set! u64vector->list list->u64vector

   f32vector? make-f32vector f32vector f32vector-length
   f32vector-ref f32vector-set! f32vector->list list->f32vector

   f64vector? make-f64vector f64vector f64vector-length
   f64vector-ref f64vector-set! f64vector->list list->f64vector
   )

   (cond-expand
     ((and (library (srfi 160)) 
           (not (library (srfi 4)))
           )
      (import
       (only (srfi 160)
        s8vector-copy!   u8vector-copy!
        s16-vector-copy! u16vector-copy!
        s32-vector-copy! u32vector-copy!
        s64-vector-copy! u64vector-copy!
        f32-vector-copy! f64vector-copy!
        ))
      (export
       s8vector-copy!   u8vector-copy!
       s16-vector-copy! u16vector-copy!
       s32-vector-copy! u32vector-copy!
       s64-vector-copy! u64vector-copy!
       f32-vector-copy! f64vector-copy!
       ))
     (else
      (begin

        (define (generic-vector-copy! iref iset length)
          (define (copy! to-vec to from-vec start end)
            (let*((start    (min start end))
                  (end      (max start end))
                  (copy-len (- end start))
                  (final    (+ to copy-len))
                  )
              (cond
               ;; Requesting copying of zero elements, already done.
               ((= 0 copy-len) (values))
               ;; To copy a range to itself, already done.
               ((and (eq? to-vec from-vec) (= to-vec start)) (values))
               ;; If there is overlap between the source and destination
               ((and (eq? to-vec from-vec) (< start to end))
                (let loop ((from (- end 1)) (i (- (+ to copy-len) 1)))
                  (iset to-vec i (iref from-vec from))
                  (cond
                   ((<= from to) (values))
                   (else (loop (- from 1) (- i 1)))
                   )))
               (else
                (let loop ((from start) (i to))
                  (cond
                   ((>= from end) (values))
                   (else
                    (iset to-vec i (iref from-vec from))
                    (loop (+ 1 from) (+ 1 i))
                    )))))))
          (case-lambda
            ((to-vec to from-vec)
             (copy! to-vec to from-vec 0 (length from-vec))
             )
            ((to-vec to from-vec start)
             (copy! to-vec to from-vec start (length from-vec))
             )
            ((to-vec to from-vec start end)
             (copy! to-vec to from-vec start end)
             )))

        (define s8vector-copy!
          (generic-vector-copy! s8vector-ref s8vector-set! s8vector-length)
          )

        (define u8vector-copy!
          (generic-vector-copy! u8vector-ref u8vector-set! u8vector-length)
          )

        (define s16vector-copy!
          (generic-vector-copy! s16vector-ref s16vector-set! s16vector-length)
          )

        (define u16vector-copy!
          (generic-vector-copy! u16vector-ref u16vector-set! u16vector-length)
          )

        (define s32vector-copy!
          (generic-vector-copy! s32vector-ref s32vector-set! s32vector-length)
          )

        (define u32vector-copy!
          (generic-vector-copy! u32vector-ref u32vector-set! u32vector-length)
          )

        (define s64vector-copy!
          (generic-vector-copy! s64vector-ref s64vector-set! s64vector-length)
          )

        (define u64vector-copy!
          (generic-vector-copy! u64vector-ref u64vector-set! u64vector-length)
          )

        (define f32vector-copy!
          (generic-vector-copy! f32vector-ref f32vector-set! f32vector-length)
          )

        (define f64vector-copy!
          (generic-vector-copy! f64vector-ref f64vector-set! f64vector-length)
          )

        ))))
