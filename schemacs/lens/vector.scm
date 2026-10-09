(define-library (schemacs lens vector)
  (import
    (scheme base)
    (scheme case-lambda)
    (scheme write)
    (only (srfi 1) fold)
    (only (schemacs lens)
          record-unit-lens unit-lens lens
          view lens-set update&view
          =>canonical
          =>vector-index!
          declare-rule/index->lens)
    (only (schemacs cursor)
          make<cursor-interface>
          declare-interface/cursor
          )
    )
  (export
   make<mutable-vector>
   mutable-vector-type? new-mutable-vector
   mutable-vector-copy mutable-vector->vector
   mutable-vector-empty? mutable-vector-length
   mutable-vector-store-size
   =>mutable-vector!
   =>mutable-vector-min-index
   =>mutable-vector-max-index
   =>mvector-index!
   =>mvector-index/default!
   mutable-vector-min-size
   *mutable-vector-grow*
   default-mutable-vector-grower
   mutable-vector-append!
   mutable-vector-shift!
   mutable-vector-fold
   mutable-vector-fold/index
   mutable-vector-for-each
   mutable-vector->list
   mutable-vector-fill!
   mutable-vector-clear!
   mutable-vector-iterate
   mutable-vector-delete-range!
   vector-copy-with)

  (begin

    (define-record-type <mutable-vector-type>
      (make<mutable-vector> vector min-index max-index)
      mutable-vector-type?
      (vector mutable-vector set!mutable-vector)
      (min-index mutable-vector-min-index set!mutable-vector-min-index)
      (max-index mutable-vector-max-index set!mutable-vector-max-index)
      )

    (define (resize-vector old-vec old-max-index old-store-size increase-by)
      (cond
       ((= 0 increase-by) old-vec)
       (else
        (let*((new-store-size ((*mutable-vector-grow*) old-store-size increase-by))
              (new-vec (make-vector new-store-size)))
          (vector-copy! new-vec 0 old-vec 0 old-max-index)
          new-vec
          ))))

    (define (mutable-vector-append! mvec . items)
      (let*((list-len (length items))
            (old-max-index (view mvec =>mutable-vector-max-index))
            (new-max-index (+ old-max-index list-len))
            (old-store-size (mutable-vector-store-size mvec))
            (vec
             (cond
              ((> new-max-index old-store-size)
               (let ((vec
                      (resize-vector
                       (view mvec =>mutable-vector!)
                       old-max-index old-store-size list-len)))
                 (lens-set vec mvec =>mutable-vector!)
                 vec))
              (else (view mvec =>mutable-vector!)))))
        (let loop
            ((i old-max-index)
             (items items))
          (cond
           ((or (null? items) (not items)) (values))
           (else
            (vector-set! vec i (car items))
            (loop (+ 1 i) (cdr items)))))
        (lens-set new-max-index mvec =>mutable-vector-max-index)
        new-max-index
        ))

    (define (new-mutable-vector init-store-size . elems)
      (let ((mvec
             (make<mutable-vector>
              (make-vector init-store-size) ;; mutable-vector
              0 ;; mutable-vector-min-index
              0 ;; mutable-vector-max-index
              )))
        (apply mutable-vector-append! mvec elems)
        mvec
        ))

    (define (mutable-vector-copy mvec)
      (make<mutable-vector>
       (vector-copy (mutable-vector mvec))
       (mutable-vector-min-index mvec)
       (mutable-vector-max-index mvec)
       ))

    (define (mutable-vector->vector mvec)
      (vector-copy
       (mutable-vector mvec)
       (mutable-vector-min-index mvec)
       (mutable-vector-max-index mvec)
       ))

    (define (mutable-vector-empty? vec)
      (or
       (not vec)
       (not (mutable-vector vec))
       (= (mutable-vector-min-index vec)
          (mutable-vector-max-index vec)
          )))

    (define (mutable-vector-length mvec)
      (- (mutable-vector-max-index mvec)
         (mutable-vector-min-index mvec)
         ))

    (define (mutable-vector-store-size vec)
      (vector-length (view vec =>mutable-vector!))
      )

    (define =>mutable-vector-min-index
      (record-unit-lens
       mutable-vector-min-index
       set!mutable-vector-min-index
       '=>mutable-vector-min-index
       ))

    (define =>mutable-vector-max-index
      (record-unit-lens
       mutable-vector-max-index
       set!mutable-vector-max-index
       '=>mutable-vector-max-index
       ))

    (define mutable-vector-min-size (make-parameter 4))

    ;; -------------------------------------------------------------------------------------------------

    (define (default-mutable-vector-grower old-store-size increase-by)
      ;; The default function used to parameterize
      ;; *mutable-vector-grow*. This function is not called directly by
      ;; any of the APIs in this module, it is always called by way of the
      ;; *mutable-vector-grow* parameter.
      (let ((new-vec-min-size (+ old-store-size increase-by)))
        (let loop ((new-vec-size (max 1 old-store-size)))
          (if (>= new-vec-size new-vec-min-size)
              (max old-store-size new-vec-size)
              (loop (* 2 new-vec-size))
              ))))

    (define *mutable-vector-grow*
      ;; This paramaterizable function describes how much to increases the
      ;; size of a mutable vector when given the current vector size and
      ;; the number of elements by which to increase its capacity.
      ;;------------------------------------------------------------------
      (make-parameter default-mutable-vector-grower)
      )

    (define =>mutable-vector!
      (=>canonical
       (record-unit-lens
        mutable-vector
        set!mutable-vector
        '=>mutable-vector!)
       (lambda () (new-mutable-vector (mutable-vector-min-size)))
       mutable-vector-empty?
       ))

    (define (=>mvector-index! i)
      (let ((make-=>i
             (lambda (record-in-focus)
               (=>vector-index!
                (+ i (view record-in-focus =>mutable-vector-min-index))))))
        (unit-lens
         (lambda (record-in-focus)
           (view record-in-focus =>mutable-vector! (make-=>i record-in-focus)))
         (lambda (record-in-focus new-info)
           (lens-set
            new-info record-in-focus
            =>mutable-vector!
            (make-=>i record-in-focus)))
         (lambda (updater record-in-focus)
           (update&view updater
            record-in-focus =>mutable-vector! (make-=>i record-in-focus)))
         (list '=>mvector-index i)
         )))

    (define =>mvector-index/default!
      ;; When viewing this lens, it will evaluates a function to produce a
      ;; default value when the given index `I` is not in bounds. On
      ;; `LENS-SET` or "UPDATE", this function changes nothing in the
      ;; mutable vector, failing silently. This lens is not canonical
      ;; because it does not resize the vector or check of the accessed
      ;; value is #f.
      ;;------------------------------------------------------------------
      (case-lambda
        ((i) (=>mvector-index/default! (lambda _ #f) i))
        ((make-default i)
         (let ((index (=>vector-index! i))
               (check-index
                (lambda (record-in-focus default action)
                  (cond
                   ((>= i (view record-in-focus =>mutable-vector-max-index))
                    (default))
                   (else (action))))))
           (unit-lens
            (lambda (record-in-focus)
              (check-index
               record-in-focus
               make-default
               (lambda () (view record-in-focus index))))
            (lambda (record-in-focus new-info)
              (check-index
               record-in-focus
               (lambda () record-in-focus)
               (lambda () (lens-set new-info record-in-focus index))))
            (lambda (updater record-in-focus)
              (check-index
               record-in-focus
               (lambda () record-in-focus)
               (lambda () (update&view updater record-in-focus index))))
            (list '=>mvector-index/default! i)
            )))))

    (define mutable-vector-shift! 
      ;; Remove a single element from the lowest index of the mutable
      ;; vector and return that element wrapped in a list. Elements in the
      ;; vector are not moved, rather the elements are replaced with `#f`
      ;; and the min index is incremented. You can specify a number of
      ;; elements to shift as an argument to this procedure, if the number
      ;; is negative, the vector can be "unshifted" but the elements
      ;; cannot be restored as they were replaced with `#f` values.
      ;; ------------------------------------------------------------------
      (case-lambda
        ((mvec) (mutable-vector-shift! mvec 1))
        ((mvec nelems)
         (let*((vec  (mutable-vector mvec))
               (lo   (mutable-vector-min-index mvec))
               (hi   (mutable-vector-max-index mvec))
               (top  (min hi (+ lo (max 0 nelems))))
               (returns
                (let loop ((i lo))
                  (cond
                   ((< i top)
                    (let ((elem (vector-ref vec i)))
                      (vector-set! vec i #f)
                      (cons elem (loop (+ i 1)))))
                   (else '()))))
               )
           (set!mutable-vector-min-index mvec (min hi (max 0 (+ nelems lo))))
           returns
           ))))

    (define (mutable-vector-find-min-length mvecs)
      (cond
       ((not mvecs) 0)
       ((null? mvecs) 0)
       (else
        (let ((len0 (mutable-vector-length (car mvecs))))
          (fold
           (lambda (mvec len)
             (min len (mutable-vector-length mvec)))
           len0 mvecs
           )))))

    (define (vector-collect-index final i vecs)
      (let loop ((vecs vecs))
        (cond
         ((null? vecs) final)
         (else
          (cons
           (vector-ref (car vecs) i)
           (loop (cdr vecs))
           )))))

    (define (mutable-vector-collect-index final i mvecs)
      (let loop ((mvecs mvecs))
        (cond
         ((null? mvecs) final)
         (else
          (cons
           (view (car mvecs) (=>mvector-index! i))
           (loop (cdr mvecs))
           )))))

    (define (mutable-vector-fold/index kons knil . mvecs)
      ;; Takes an iteration function `KONS` with an initial value `KNIL`
      ;; as the first two arguments. All remaining arguments `MVECS` must
      ;; be `<MUTABLE-VECTOR-TYPE>` values. This procedure iterates over
      ;; all indicies begining at zero and up to the length of the
      ;; shortest vector in `MVECS`. On each iteration the following
      ;; values are applied to `KONS`:
      ;;
      ;;    1.     the current index `i` as an integer,
      ;;    2..N.  the `i`th element in each of the `MVECS`,
      ;;    N+1.   the value returned by `KONS` on the previous iteration,
      ;;           or `KNIL` if this is the first iteration.
      ;;
      ;; The `KONS` function must return 1 value which is typically a
      ;; value of the same type as `KNIL`.
      ;;
      ;; This procedure returns 2 values: the number of elements iterated,
      ;; and the value returned by `KONS` on the its final iteration.
      ;;------------------------------------------------------------------
      (cond
       ((null? mvecs) knil)
       (else
        (let*((len (mutable-vector-find-min-length mvecs))
              (get-index
               (lambda (i) (lambda (vec) (view vec (=>mvector-index! i))))))
          (let loop ((i 0) (prev knil))
            (cond
             ((>= i len) (values len prev))
             (else
              (let ((get-index (get-index i)))
                (loop
                 (+ 1 i)
                 (apply kons i (mutable-vector-collect-index (list prev) i mvecs))
                 )))))))))

    (define (mutable-vector-fold kons knil . mvecs)
      ;; Similar to `MUTABLE-VECTOR-FOLD/INDEX` but the `KONS` function
      ;; need not take an index as the first argument, and the result of
      ;; this procedure returns only 1 value: the result of `KONS` as was
      ;; applied on the final iterateion.
      ;;------------------------------------------------------------------
      (let-values
          (((_count result)
            (apply
             mutable-vector-fold/index
             (lambda args (apply kons (cdr args)))
             knil mvecs
             )))
        result
        ))

    (define mutable-vector->list
      ;; Iterate over a mutable vector and collect each element into a
      ;; list. You can specify an end index `TO` to limit the number of
      ;; elements taken. For example if `TO` is 4 then a list of elements
      ;; starting from index 0 containing no more than 4 contiguous
      ;; elements after index 0 is returned.
      ;;
      ;; You can also apply both a `TO` and a `FROM` argument to this
      ;; procedure. This will iterate all contiguous elements at indicies
      ;; beginning from index `FROM` and up to but **not including** the
      ;; element at index `TO`. Indicies that are out of bounds are
      ;; clamped to in-bound indicies.
      ;;------------------------------------------------------------------
      (case-lambda
        ((mvec) (mutable-vector->list mvec 0 (mutable-vector-max-index mvec)))
        ((mvec to) (mutable-vector->list mvec 0 to))
        ((mvec from to)
         (let*-values
             (((vec) (mutable-vector mvec))
              ((lo) (mutable-vector-min-index mvec))
              ((hi) (mutable-vector-max-index mvec))
              ((from) (min hi (max lo (+ from lo))))
              ((to)   (min hi (max lo (+ to   lo ))))
              ((increment end)
               (cond
                ((< to from) (values -1 (- to 1)))
                (else (values 1 to))))
              )
           (let loop ((from from))
             (cond
              ((= from end) '())
              (else
               (cons
                (vector-ref vec from)
                (loop (+ from increment))
                ))))))))

    (define (mutable-vector-for-each proc . mvecs)
      (let ((len (mutable-vector-find-min-length mvecs)))
        (let loop ((i 0))
          (cond
           ((>= i len) (values))
           (else
            (apply proc (mutable-vector-collect-index '() i mvecs))
            (loop (+ 1 i))
            )))))

    (define (mutable-vector-fill! mvec fill)
      (vector-fill!
       (view mvec =>mutable-vector!)
       fill
       (view mvec =>mutable-vector-min-index)
       (view mvec =>mutable-vector-max-index)
       ))

    (define (mutable-vector-clear! mvec)
      ;; Clear the vector between the min and max indicies, allowing the
      ;; objects in those cells to be garbage collected, then reset the
      ;; max index to be the same as the min index.
      ;;------------------------------------------------------------------
      (mutable-vector-fill! mvec #f)
      (lens-set
       (view mvec =>mutable-vector-min-index)
       mvec
       =>mutable-vector-max-index
       ))

    (define mutable-vector-iterate
      ;; Beginning from index `START`, iterate over every index to find
      ;; the `Nth` element (1-based) in `MVEC` that satisfies the
      ;; predicate `PRED?` by applying each element in the vector to
      ;; `PRED?` in turn. `Nth` defaults to 1, `START` defaults to 0. If
      ;; `START` is negative, this signifies that the search direction
      ;; will be reversed, that is search indicies are iterated from the
      ;; end of the vector down toward the minimum index. If `Nth` is
      ;; zero, #f is returned. If `Nth` is negative, search in the
      ;; direction opposite that which is signified by the sign of the the
      ;; `START` index (when `Nth` and `START` are both negative or both
      ;; positive it means to search from lower to higher indicies). If
      ;; `PRED?` returns #f for every element at every index over which
      ;; iteration steps, #f is returned.
      ;;------------------------------------------------------------------
      (case-lambda
        ((pred? mvec) (mutable-vector-iterate pred? mvec 1 0))
        ((pred? mvec nth) (mutable-vector-iterate pred? mvec nth 0))
        ((pred? mvec nth start)
         (cond
          ((= nth 0) #f)
          (else
           (let*-values
               (((vec) (mutable-vector mvec))
                ((lo) (mutable-vector-min-index mvec))
                ((hi) (mutable-vector-max-index mvec))
                ((start end increment)
                 (cond
                  ((and (< nth 0)
                        (< start 0)) (values (+ hi start) hi 1))
                  ((< start 0)       (values (+ hi start) (- lo 1) -1))
                  (else              (values (+ lo start) hi 1))))
                )
             (let loop
                 ((counter (- (abs nth) 1))
                  (i start))
               (cond
                ((= i end) #f)
                (else
                 (let ((elem (vector-ref vec i)))
                   (cond
                    ((pred? elem)
                     (cond
                      ((<= counter 0) (- i lo))
                      (else
                       (loop (- counter 1) (+ i increment)))))
                    (else
                     (loop counter (+ i increment))
                     ))))))))))))


    (define (vector-for-range/index proc start nelems . vecs)
      ;; Not for export, does not do bounds checking consistent with other
      ;; APIs in this library: start and nelems must both be non-negative.
      (cond
       ((null? vecs) (values))
       (else
        (let loop ((nelems nelems) (i start))
          (cond
           ((<= nelems 0) (values))
           (else
            (apply proc i (vector-collect-index '() i vecs))
            (loop (- nelems 1) (+ i 1))
            ))))))


    (define (vector-for-range proc start nelems . vecs)
      (apply
       vector-for-range/index
       (lambda (i . elems) (apply proc elems))
       start nelems vecs
       ))


    (define mutable-vector-delete-range!
      ;; Remove contiguous elements in the vector `MVEC` starting from the
      ;; index `FROM` and up to **but not including** the index `TO`. It
      ;; is an error if either `FROM` or `TO` indicies are out of bounds.
      ;; 
      ;; If a forth argument, a procedure `PRE-DELETE`, is applied to this
      ;; procedure then before deleting the elements, iterate over the
      ;; range of elements to be deleted and `APPLY` each element to the
      ;; `PRE-DELETE` predicate in the same manner as the
      ;; `VECTOR-FOR-EACH` procedure except that the `PRE-DELETE` always
      ;; takes exactly one argument since there can only ever be 1 `MVEC`
      ;; argument applied to this procedure. This makes it possible to
      ;; apply some stateful update to elements before they are deleted
      ;; from the mutable vector, such as closing a string port. Also, if
      ;; the `FROM` index is greater than the `TO` index, `PRE-DELETE`
      ;; will iterate over these indicies from higher to lower index
      ;; order.
      ;;------------------------------------------------------------------
      (case-lambda
        ((mvec from to)
         (mutable-vector-delete-range! mvec from to #f))
        ((mvec from to pre-delete)
         (cond
          ((= from to) (values))
          (else
           (let*-values
               (((vec) (mutable-vector mvec))
                ((lo) (mutable-vector-min-index mvec))
                ((old-hi) (mutable-vector-max-index mvec))
                ((start) (+ lo from))
                ((end)   (+ lo to))
                ((from to pre-from pre-to increment)
                 (cond
                  ((< to from) (values (+ end 1) (+ start 1) start end -1))
                  (else (values start end start end 1))))
                ((len) (- to from))
                ((new-hi) (- old-hi len))
                )
             (when pre-delete
               (let loop ((i pre-from))
                 (cond
                  ((= i pre-to) (values))
                  (else
                   (pre-delete (vector-ref vec i))
                   (loop (+ i increment)))))
               )
             (vector-copy! vec from vec to old-hi)
             (vector-fill! vec #f new-hi old-hi)
             (set!mutable-vector-max-index mvec new-hi)
             ))))))


    (define (vector-copy-with vec copier)
      ;; deep-copy a vector with a `COPIER` for deep-copying stored elements.
      ;;------------------------------------------------------------------
      (vector-map copier vec)
      )

    ;;--------------------------------------------------------------------

    (declare-rule/index->lens 'integer mutable-vector-type? =>mvector-index!)

    (declare-interface/cursor mutable-vector-type?
     (make<cursor-interface>
      (lambda (obj i) (>= i (mutable-vector-length obj)))
      (lambda (obj i) (view obj (=>mvector-index! i)))
      #f (lambda (obj i) (values))
      ))

    ;;----------------------------------------------------------------
    ))
