(define-library (schemacs gap-buffer)
  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme write) display write);;DEBUG
    (scheme case-lambda)
    (only (schemacs arrays)
          %array-copy-range!
          )
    ;; The array operations Guile already has. There is no interface
    ;; object any more: the gap buffer is told the *array type* of its
    ;; store (`array-type''s answer - `#t' for a plain vector, `u32' for
    ;; a `u32vector', `vu8' for a bytevector) and everything else
    ;; dispatches on the store itself. See `(schemacs arrays)'.
    (only (guile)
          array-length
          array-ref
          array-set!
          make-typed-array
          )
    )
  (export
   gap-buffer-type?             new-gap-buffer
   gap-buffer-insert-before     gap-buffer-insert-after
   gap-buffer-move-cursor       gap-buffer-set-cursor
   gap-buffer-delete            gap-buffer-clear
   gap-buffer-clear-before      gap-buffer-clear-after

   gap-buffer-end-of-line?      gap-buffer-start-of-line?
   gap-buffer-for-each          gap-buffer-for-each/index
   gap-buffer-for-each-before   gap-buffer-for-each-before/index
   gap-buffer-for-each-after    gap-buffer-for-each-after/index
   gap-buffer-map!              gap-buffer-map/index!
   gap-buffer-map               gap-buffer-map/index

   gap-buffer-length            gap-buffer-weight
   gap-buffer-cursor            gap-buffer-free-space
   gap-buffer-update-min-max    gap-buffer-insert-min-max

   gap-buffer-ref
   gap-buffer-ref-before        gap-buffer-ref-after
   gap-buffer-cursor-to-start   gap-buffer-cursor-to-end

   *gap-bytes-dfl*              *gap-bytes-min*
   gap-buffer-grow              gap-buffer-allocate
   gap-buffer-compact
   gap-buffer-minimum           set!gap-buffer-minimum
   gap-buffer-maximum           set!gap-buffer-maximum
   )

  (begin

    (define-record-type <gap-buffer-type>
      (make<gap-buffer> type vec weight cursor min max)
      gap-buffer-type?
      (type    gap-buffer-seq-type)
      ;; ^ The *array type* of the backing store, as `array-type`
      ;; answers it: `#t` for a plain vector, `vu8` for a bytevector,
      ;; `u8`, `u16`, `u32` and so on for the homogeneous vectors. It is
      ;; what `make-typed-array` takes, so growing the store needs
      ;; nothing else. The author's table of fourteen interfaces said
      ;; the same thing in sixty times the space.
      (vec     gap-buffer-vector  set!gap-buffer-vector)
      ;; ^ The backing vector. This may be an ordinary vector
      ;; (satisfying `vector?`), or a `bytevector?`, or it may be a
      ;; homogeneous (unboxed) vector such as data which satisfy
      ;; the `u8vector?` or `u32vector?` predicates.
      (weight  gap-buffer-weight   set!gap-buffer-weight)
      ;; ^ The number of characters that have been inserted so
      ;; far. This may be any number from zero up to one minus the
      ;; length of the `gap-buffer-vector`.
      (cursor  gap-buffer-cursor   set!gap-buffer-cursor)
      ;; ^ The position where the gap begins, or you could think of it
      ;; as the position where the next element will be inserted by
      ;; `gap-buffer-insert!`.
      (min     gap-buffer-minimum  set!gap-buffer-minimum)
      (max     gap-buffer-maximum  set!gap-buffer-maximum)
      ;; ^ Tracks the lowest and highest valued element inserted,
      ;; useful only if the elements being buffered have some kind of
      ;; ordering.
      )

    (define (gap-buffer-update gb proc)
      ;; Most gap buffer updating functions need to have the gap
      ;; buffer deconstructed a bit, this function does that
      ;; deconstruction, mostly to save you from typing too much.
      ;;
      ;; The `proc` is applied 5 values:
      ;;
      ;;  1. the array type of the store
      ;;  2. the buffer vector
      ;;  3. the length of the buffer
      ;;  4. the weight, i.e. number of items in the buffer
      ;;  5. the cursor
      ;;--------------------------------------------------------------
      (let*((vec (gap-buffer-vector gb))
            (type (gap-buffer-seq-type gb))
            (len (array-length vec))
            )
        (proc
         type vec len
         (gap-buffer-weight gb)
         (gap-buffer-cursor gb)
         )))

    (define (%gap-buffer-make-store type size)
      ;; A new store of `SIZE` elements of `TYPE`.
      ;;
      ;; The author's constructor pairs (`make-u16vector`, `make-vector`)
      ;; let the fill be omitted, meaning "whatever the allocator left";
      ;; `make-typed-array` has no such case and wants one. A numeric
      ;; store is zeroed either way, and a plain vector is filled with
      ;; `#f` where it used to be left unspecified - no live element is
      ;; ever read out of the gap, so the fill only shows through in
      ;; slots the gap buffer has not written.
      ;;---------------------------------------------------------------
      (make-typed-array type (if (eq? type #t) #f 0) size)
      )

    (define (new-gap-buffer type store-size . fill-val)
      ;; Construct a new gap buffer over a store of `STORE-SIZE`
      ;; elements of array `TYPE` - `#t` for a plain vector, `u32` for a
      ;; `u32vector`, `vu8` for a bytevector, and so on. The optional
      ;; `FILL-VAL` initialises the store's cells.
      ;;---------------------------------------------------------------
      (make<gap-buffer>
       type
       (if (pair? fill-val)
           (make-typed-array type (car fill-val) store-size)
           (%gap-buffer-make-store type store-size)
           )
       0 0 #f #f
       ))

    (define (gap-buffer-length gb)
      (array-length (gap-buffer-vector gb))
      )

    (define (gap-buffer-end-of-line? gb)
      (= (gap-buffer-weight gb) (gap-buffer-cursor gb))
      )

    (define (gap-buffer-start-of-line? gb) (= 0 (gap-buffer-cursor gb)))

    (define *gap-bytes-dfl* 2000)   ;; buffer.h:205
    (define *gap-bytes-min* 20)     ;; buffer.h:210

    (define (%gap-grow-size len weight needed)
      ;; GNU Emacs's `make_gap' (insdel.c:583) and `make_gap_larger'
      ;; (:467), which is what a gap is grown BY:
      ;;
      ;;     make_gap_larger (max (nbytes_added, (Z - BEG) / 64));
      ;;     nbytes_added = min (nbytes_added + GAP_BYTES_DFL, ...);
      ;;
      ;; "If we have to get more space, get enough to last a while" -
      ;; at least a sixty-fourth of the text, plus GAP_BYTES_DFL. There
      ;; is no doubling anywhere in Emacs. The `/64' is a measured
      ;; choice, not a guess: the comment at :583-600 records that it
      ;; "already brings almost the best performance" while limiting the
      ;; wasted memory to 1.5%, where a doubling wastes up to half.
      ;;
      ;; Emacs's other bound, `BUF_BYTES_MAX', has no analogue in
      ;; Scheme and is not applied.
      ;;--------------------------------------------------------------
      (+ len (max needed (quotient weight 64)) *gap-bytes-dfl*)
      )

    (define (%gap-buffer-realloc! gb new-len)
      ;; Rebuild the store `NEW-LEN` elements long, keeping the gap, the
      ;; cursor and the weight where they are. This is Emacs's
      ;; `make_gap_larger'/`make_gap_smaller' pair minus the two-step
      ;; shuffle they need: they enlarge in place around a live gap and
      ;; so must move it first, where a new Scheme array is simply
      ;; written in the layout wanted.
      ;;
      ;; The same two copies serve growing and shrinking alike, because
      ;; where the segments go is decided by the NEW length and the
      ;; weight, never by the old: the text before the cursor starts at
      ;; 0, the text after it ends at the end, and the gap falls between
      ;; them.
      ;;--------------------------------------------------------------
      (gap-buffer-update
       gb
       (lambda (type old-vec old-len weight cursor)
         (cond
          ((or (= new-len old-len) (< new-len weight)) gb)
          (else
           (let ((new-vec (%gap-buffer-make-store type new-len))
                 (above (- weight cursor))
                 )
             (when (< 0 cursor)
               (%array-copy-range! new-vec 0 old-vec 0 cursor)
               )
             (when (< 0 above)
               (%array-copy-range!
                new-vec (- new-len above)
                old-vec (- old-len above) old-len
                ))
             (set!gap-buffer-vector gb new-vec)
             gb
             ))))))

    (define (gap-buffer-grow gb +size)
      ;; `+SIZE` is what is about to be inserted, and the grow happens
      ;; only when there is not room for it - GNU Emacs's `insert_1_both'
      ;; (insdel.c:915):
      ;;
      ;;     if (GAP_SIZE < nbytes)
      ;;       make_gap (nbytes - GAP_SIZE);
      ;;
      ;; The amount handed to the policy is therefore the shortfall, not
      ;; the insert.
      ;;--------------------------------------------------------------
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (let ((free (- len weight)))
           (when (< free +size)
             (%gap-buffer-realloc! gb (%gap-grow-size len weight (- +size free)))
             )
           gb
           ))))

    (define (gap-buffer-compact gb)
      ;; GNU Emacs's `compact_buffer' (buffer.c:1857):
      ;;
      ;;     ptrdiff_t size = clip_to_bounds (GAP_BYTES_MIN,
      ;;                                      BUF_Z_BYTE (buffer) / 10,
      ;;                                      GAP_BYTES_DFL);
      ;;     if (BUF_GAP_SIZE (buffer) > size)
      ;;       make_gap_1 (buffer, -(BUF_GAP_SIZE (buffer) - size));
      ;;
      ;; "If a buffer's gap size is more than 10% of the buffer size, or
      ;; larger than GAP_BYTES_DFL bytes, then shrink it accordingly.
      ;; Keep a minimum size of GAP_BYTES_MIN bytes."
      ;;
      ;; In Emacs the caller is the garbage collector. Nothing calls it
      ;; here yet - there is no equivalent pass - so it is exported for
      ;; whatever later wants to.
      ;;--------------------------------------------------------------
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (let ((size (min (max *gap-bytes-min* (quotient weight 10))
                          *gap-bytes-dfl*
                          )))
           (when (< size (- len weight))
             (%gap-buffer-realloc! gb (+ weight size))
             )
           gb
           ))))

    (define (gap-buffer-allocate gb new-size)
      ;; Similar to `gap-buffer-grow` but ensures the gap buffer is at
      ;; least `NEW-SIZE` elements large and grows the gap buffer
      ;; allocation if it is not big enough. If the requested
      ;; `NEW-SIZE` is smaller than the current allocation, no change
      ;; is made.
      ;;
      ;; Where `gap-buffer-grow` is handed an insert shortfall and asks
      ;; the growth policy what to do with it, this asks for an exact
      ;; total - Emacs's `enlarge_buffer_text' rather than `make_gap'.
      ;; Shrinking is `gap-buffer-compact`'s, so a smaller `NEW-SIZE`
      ;; than the store already is does nothing.
      ;;--------------------------------------------------------------
      (when (< (gap-buffer-length gb) new-size)
        (%gap-buffer-realloc! gb new-size)
        )
      gb
      )

    (define (gap-buffer-free-space gb)
      (- (array-length (gap-buffer-vector gb))
         (gap-buffer-weight gb)
         ))

    (define (gap-buffer-full? gb)
      (= 0 (gap-buffer-free-space gb))
      )

    (define (%gap-buffer-for-each proc gb)
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (cond
          ((not vec) (values))
          (else
           (let*((after  (- weight cursor))
                 (offset (- len weight))
                 )
             (proc array-ref vec len cursor after offset)
             ))))))

    (define (%gap-buffer-for-each-before proc ref vec cursor)
      (let loop ((i 0))
        (cond
         ((< i cursor) (proc i (ref vec i)) (loop (+ 1 i)))
         (else (values))
         )))

    (define (%gap-buffer-for-each-after proc ref vec len after offset)
      (let loop ((i (- len after)))
        (cond
         ((< i len) (proc (- i offset) (ref vec i)) (loop (+ 1 i)))
         (else (values))
         )))

    (define (%gap-buffer-without-index op)
      (lambda (proc gb)
        (op (lambda (_i . args) (apply proc args)) gb)
        ))

    (define (gap-buffer-for-each/index proc gb)
      ;; Apply an index and element value for each valid index in the
      ;; gap buffer (indicies in the gap are skipped). Similar to the
      ;; `gap-buffer-for-each` except the `PROC` applied to each
      ;; element is also applied an index. The return values of this
      ;; `PROC` are ignored.
      ;;
      ;; Takes two or three arguments:
      ;;
      ;;  1. `PROC` is a procedure which takes an index and a
      ;;     value. It is evaluated once for each value and it's
      ;;     associated index in the gap buffer.
      ;;
      ;;  2. `GB` is the gap buffer object.
      ;;
      ;;  3. Optional vector interface for the type of vector used to
      ;;     store the gap buffer object's elements. If not provided,
      ;;     it is inferred from the gap buffer's `gap-buffer-vector`
      ;;     field.
      (%gap-buffer-for-each
       (lambda (ref vec len cursor after offset)
         (%gap-buffer-for-each-before proc ref vec cursor)
         (%gap-buffer-for-each-after proc ref vec len after offset)
         )
       gb
       ))

    (define gap-buffer-for-each
      ;; Apply a element value for each valid index in the gap buffer
      ;; (elements in the gap are skipped).
      ;;
      ;; Takes three arguments:
      ;;
      ;;  1. `PROC` is a procedure which takes an element. It is
      ;;     evaluated once for each valid element in the gap buffer
      ;;     (indicies in the gap are skipped). The return values of
      ;;     this `PROC` are ignored.
      ;;
      ;;  2. Sequence interface for the type of vector used to store
      ;;     the gap buffer object's elements. If not provided, it is
      ;;     inferred from the gap buffer's `gap-buffer-vector` field.
      ;;
      ;;  3. `GB` is the gap buffer object.
      (%gap-buffer-without-index gap-buffer-for-each/index) 
      )

    (define (gap-buffer-for-each-before/index proc gb)
      ;; Like `gap-buffer-for-each/index`, but only operates on
      ;; elements before the cursor.
      (gap-buffer-update
       gb
       (lambda (_type vec _len _weight cursor)
         (%gap-buffer-for-each-before
          proc array-ref vec cursor
          ))
       ))

    (define gap-buffer-for-each-before
      ;; Like `gap-buffer-for-each-before/index` but the `PROC`
      ;; argument only takes a single argument: the buffer elements,
      ;; `PROC` does not take an index as an argument.
      (%gap-buffer-without-index gap-buffer-for-each-before/index) 
      )

    (define (gap-buffer-for-each-after/index proc gb)
      ;; Like `gap-buffer-for-each/index`, but only operates on
      ;; elements after the cursor.
      (%gap-buffer-for-each
       (lambda (ref vec len _cursor after offset)
         (%gap-buffer-for-each-after proc ref vec len after offset)
         )
       gb
       ))

    (define gap-buffer-for-each-after
      ;; Like `gap-buffer-for-each-after/index` but the `PROC` only
      ;; takes a single argument: the buffer elements. `PROC` does not
      ;; take an index as an argument.
      (%gap-buffer-without-index gap-buffer-for-each-after/index)
      )

    (define (%gap-buffer-map/index! proc gb to-vec)
      (gap-buffer-for-each/index
       (lambda (i elem) (array-set! to-vec (proc i elem) i))
       gb
       ))

    (define (gap-buffer-map/index! proc gb)
      ;; Similar to `gap-buffer-for-each/index`, except that the
      ;; return value of the `PROC` procedure is used to update each
      ;; element in the gap buffer in place.
      (%gap-buffer-map/index! proc gb (gap-buffer-vector gb))
      )

    (define gap-buffer-map! 
      ;; Like `gap-buffer-map/index!` but the `PROC` only takes a
      ;; single argument: the buffer elements. `PROC` does not take an
      ;; index as an argument.
      (%gap-buffer-without-index gap-buffer-map/index!)
      )

    (define (gap-buffer-map/index proc gb)
      ;; Like `gap-buffer-map/index!` except instead of updating each
      ;; element in place, a new gap buffer object is created and
      ;; updated with the elements returned by `PROC`. The `PROC`
      ;; procedure takes an index of the current element, and the
      ;; current element.
      (let*((type (gap-buffer-seq-type gb))
            (vec (gap-buffer-vector gb))
            (new-vec (%gap-buffer-make-store type (array-length vec)))
            (new-gb
             (make<gap-buffer>
              type  new-vec
              (gap-buffer-weight gb)
              (gap-buffer-cursor gb)
              (gap-buffer-minimum gb)
              (gap-buffer-maximum gb)
              )))
        (%gap-buffer-map/index! proc gb new-vec)
        new-gb
        ))

    (define (gap-buffer-insert-min-max gb new-val)
      (let ((old-min (gap-buffer-minimum gb))
            (old-max (gap-buffer-maximum gb))
            )
        (set!gap-buffer-minimum
         gb (or (and old-min (min new-val old-min)) new-val)
         )
        (set!gap-buffer-maximum
         gb (or (and old-max (max new-val old-max)) new-val)
         )
        new-val
        ))

    (define (gap-buffer-update-min-max gb)
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (let*((lo  (gap-buffer-minimum gb))
               (hi  (gap-buffer-maximum gb))
               (ref array-ref)
               )
           (cond
            ((and (< 0 weight) (not (and lo hi)))
             ;; Update only if there are elements, and if the lo or hi
             ;; value are invalid. The init value is the first or last
             ;; element depending on cursor position.
             (let*((i (if (< 0 cursor) 0 (- len 1)))
                   (init-val (ref vec i))
                   )
               (set! lo init-val)
               (set! hi init-val)
               (gap-buffer-for-each
                (lambda (elem)
                  (cond
                   ((< elem lo) (set! lo elem))
                   ((< hi elem) (set! hi elem))
                   (else (values))
                   ))
                gb
                )
               (set!gap-buffer-minimum gb lo)
               (set!gap-buffer-maximum gb hi)
               gb
               ))
            (else gb)
            )))))

    (define (gap-buffer-ref-before gb nothing)
      ;; Get the item just before the cursor
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (cond
          ((< 0 cursor)
           (array-ref vec (- cursor 1))
           )
          (else
           ;;(error "cannot reference empty gap buffer" gb)
           nothing
           )))))


    (define (gap-buffer-ref-after gb nothing)
      ;; Get the item just after the cursor
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (cond
          ((< cursor weight)
           (array-ref vec (- len (- weight cursor)))
           )
          (else
           ;;(error "cannot reference empty gap buffer" gb)
           nothing
           )))))

    (define (gap-buffer-ref gb i)
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (cond
          ((< i cursor) (array-ref vec i))
          (else (array-ref vec (+ i (- len weight))))
          ))))

    (define (%gapbuf-get-index-before cur _wt _len) cur)
    (define (%gapbuf-get-index-after  cur  wt  len) (- len 1 (- wt cur)))

    (define (%gap-buffer-insert get-index)
      (lambda (gb elem)
        (gap-buffer-grow gb 1)
        (gap-buffer-update
         gb
         (lambda (_type vec len weight cursor)
           (array-set! vec elem (get-index cursor weight len))
           (set!gap-buffer-weight gb (+ 1 weight))
           elem
           ))))

    (define gap-buffer-insert-after (%gap-buffer-insert %gapbuf-get-index-after))

    (define (gap-buffer-insert-before gb elem)
      ((%gap-buffer-insert %gapbuf-get-index-before) gb elem)
      (set!gap-buffer-cursor gb (+ 1 (gap-buffer-cursor gb)))
      )

    (define (gap-buffer-cursor-to-start gb)
      (gap-buffer-move-cursor gb (- (gap-buffer-cursor gb)))
      )

    (define (gap-buffer-cursor-to-end gb)
      (gap-buffer-move-cursor
       gb (- (gap-buffer-weight gb) (gap-buffer-cursor gb))
       ))

    (define (gap-buffer-move-cursor gb n)
      ;; Negative `N` moves the cursor toward the beginning of the
      ;; buffer, moves characters toward the end of the
      ;; buffer. Positive `N` moves the cursor toward the end of the
      ;; buffer, moves characters toward the beginning of the buffer.
      ;; ------------------------------------------------------------

      ;; The author's note here was that Guile's `vector-copy!` for the
      ;; SRFI-4 vectors is wrong:
      ;;
      ;;     move: len=4, weight=3, cursor=3, after=4, n=-3
      ;;     pre: #u16(30 10 20 20)
      ;;     vector-copy! at=1, start=0, end=3
      ;;     post: #u16(30 30 30 30)
      ;;
      ;; The "post:" vector should have been #u16(30 30 10 20). It is
      ;; still so - `vector-copy!` refuses a `u16vector' outright ("Wrong
      ;; type argument in position 1 (expecting mutable vector)"), and
      ;; `array-copy!` is a forward loop that corrupts this direction.
      ;; `%array-copy-range!' is what makes it right, by reversing both
      ;; sides of the copy - see `(schemacs arrays)'. There is no
      ;; `cond-expand' here any more: the loop that used to stand in for
      ;; the broken primitive was slower than the primitive and is gone.
      (gap-buffer-update
       gb
       (lambda (_type vec len weight cursor)
         (cond
          ((= n 0) 0)     ;; no movement
          ((= len weight) ;; no gap
           (set!gap-buffer-cursor gb (max 0 (min weight (+ n cursor))))
           )
          (else
           (let ((limit (min weight (max 0 (+ cursor n))))
                 (after (+ (- len weight) cursor))
                 )
             ;;(display "move: len=") (write len) (display ", weight=") (write weight) ;;NOTE
             ;;(display ", cursor=") (write cursor) (display ", after=") (write after) ;;NOTE
             ;;(display ", n=") (write n) (newline) ;;DEBUG
             (cond
              ((< n 0)
               (let ((n (max n (- cursor))))
                 ;;(display "pre: ") (write vec) (newline) ;;DEBUG
                 ;;(display "vector-copy! at=") (write (+ after n)) (display ", start=");;NOTE
                 ;;(write (+ cursor n)) (display ", end=") (write cursor) (newline) ;;NOTE
                 (%array-copy-range!
                  vec (+ after n)  vec (+ cursor n) cursor)
                 ;;(display "post: ") (write vec) (newline) ;;DEBUG
                 ))
              (else
               (let ((n (min n (- weight cursor))))
                 ;;(display "pre: ") (write vec) (newline) ;;DEBUG
                 ;;(display "vector-copy! at=") (write cursor) (display ", start=") (write after);;DEBUG
                 ;;(display ", end=") (write (+ after n)) (newline) ;;DEBUG
                 (%array-copy-range!
                  vec cursor  vec after (+ after n))
                 ;;(display "post: ") (write vec) (newline) ;;DEBUG
                 )))
             (set!gap-buffer-cursor gb limit)
             limit
             ))))))

    (define (gap-buffer-set-cursor gb index)
      ;; Move the gap buffer cursror to a given `INDEX`. The index
      ;; must be greater than or equal to 0 and less than the
      ;; `gap-buffer-weight` value. This function calls
      ;; `gap-buffer-move-cursor` after computing the difference of
      ;; the current `gap-buffer-cursor` and the given `INDEX`
      ;; argument.
      ;;--------------------------------------------------------------
      (gap-buffer-move-cursor gb (- index (gap-buffer-cursor gb)))
      )

    (define gap-buffer-delete
      ;; Delete N characters after the cursor. If N is negative,
      ;; delete N characters before the cursor. As an optional third
      ;; argument, you can pass a deletion function which maps over
      ;; all the elements that are about to be deleted. The deletion
      ;; function should take an element as input, and whatever is
      ;; returned is stored back to the vector before the cursor is
      ;; moved and makes those elements inaccessable. It allows you by
      ;; replacing values with `#f` for example, you can mark them for
      ;; removal by the garbage collector more immediately than they
      ;; would be if the cursor was simply moved and allowed those
      ;; inaccessible elements to linger in the storage vector. Note
      ;; there is no guarantee on the ordering in which the
      ;; deletion function is applied to the elements, if ordering is
      ;; important, please perform your own mapping and then call this
      ;; function with no third argument.
      ;;--------------------------------------------------------------
      (case-lambda
        ((gb n) (gap-buffer-delete gb n #f))
        ((gb n del)
         (gap-buffer-update
          gb
          (lambda (_type vec len weight cursor)
            (let*((n (max (- cursor) (min n (- weight cursor))))
                  (on-range
                   (lambda (from to)
                     (let loop ((i from))
                       (cond
                        ((< i to)
                         (array-set! vec (del (array-ref vec i)) i)
                         (loop (+ 1 i))
                         )
                        (else (values))
                        )))))
              (cond
               ((< n 0)
                (let ((new-cursor (+ cursor n)))
                  (set!gap-buffer-cursor gb new-cursor)
                  (set!gap-buffer-weight gb (+ weight n))
                  (when del (on-range new-cursor cursor))
                  n))
               ((> n 0)
                (let*((new-weight (- weight n))
                      (after (+ (- len weight) cursor))
                      )
                  (set!gap-buffer-weight gb new-weight)
                  (when del (on-range after (+ after n)))
                  n))
               (else 0) ;; nothing to do
               )))))))

    (define (gap-buffer-clear gb)
      ;; Reset the cursor and weight to zero, but otherwise do not
      ;; change the allocation of the gap buffer.
      ;;--------------------------------------------------------------
      (set!gap-buffer-weight  gb 0)
      (set!gap-buffer-cursor  gb 0)
      (set!gap-buffer-minimum gb #f)
      (set!gap-buffer-maximum gb #f)
      )

    (define (gap-buffer-clear-before gb)
      (let ((new-weight (- (gap-buffer-weight gb) (gap-buffer-cursor gb))))
	(set!gap-buffer-weight gb new-weight)
	(set!gap-buffer-cursor gb 0)
	))

    (define (gap-buffer-clear-after gb)
      (set!gap-buffer-weight gb (gap-buffer-cursor gb))
      )

    ))
