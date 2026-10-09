(define-library (schemacs arrays)
  ;; The two array primitives Guile does not have - a *ranged* copy and
  ;; a *reallocation* - which the gap buffer and the CDF need and which
  ;; are the residue of the original author's `(schemacs sequence)'.
  ;;
  ;; Guile made array *access* generic and left *construction* and
  ;; *ranged copying* concrete. `array-ref', `array-set!',
  ;; `array-length' and `array-for-each' work over `vector', `string',
  ;; `bytevector' and every SRFI-4 homogeneous vector without being told
  ;; which. But:
  ;;
  ;;  * `array-copy!' takes exactly two arguments (`(_ _)') - a whole
  ;;    array into a whole array. There is no start, no end.
  ;;  * `vector-copy!' refuses every SRFI-4 vector. Guile 3.0.11:
  ;;    "Wrong type argument in position 1 (expecting mutable vector):
  ;;    #u32(10 20 30 40)". There is no `u32vector-copy!' to fall back
  ;;    on, and `uniform-vector-copy' and `uniform-vector-copy!' do not
  ;;    exist at all.
  ;;  * `make-typed-array' *is* the generic constructor after all - it
  ;;    takes the very type symbol `array-type' answers with - so
  ;;    reallocation is "make one like this, copy the old contents in",
  ;;    which is `%array-resize'.
  ;;
  ;; There is deliberately no growth *policy* here. Emacs's is `make_gap'
  ;; and belongs with the gap buffer; the CDF's is its own, there being
  ;; no CDF in Emacs to copy. A library that picked one would be picking
  ;; for both.
  ;;
  ;; This is Guile-specific, and knowingly so: `make-typed-array' and
  ;; `array-type' are Guile extensions, not SRFI-63. The library it
  ;; replaces existed to be portable across Schemes; that is the price of
  ;; the removal, and it is recorded in the handoff.

  (import
    (scheme base)
    ;; Guile's own array procedures - `(scheme base)' does not have them.
    (only (guile)
          array-copy!
          make-shared-array
          make-typed-array
          array-type
          array-length
          )
    )

  (export
   %array-copy-range!
   %array-resize
   )

  (begin

    (define (%array-copy-range! to at from start end)
      ;; R7RS `copy!' order and meaning: copy the `(- end start)'
      ;; elements of `from' beginning at `start' into `to' beginning at
      ;; `at'. Any two array types, no fill value, and safe when the two
      ;; ranges overlap.
      ;;
      ;; `array-copy!' cannot say this, being whole-array only, so the
      ;; range is expressed as a *shared array* - a view of the same
      ;; store, `n' long, beginning where we want. That is the first
      ;; half of the trick, and it is all `make-shared-array' is for.
      ;;
      ;; The second half is the overlap. `array-copy!' is a forward
      ;; loop, which is correct only while the destination stays below
      ;; the source; above it, it reads elements it has already
      ;; overwritten. Reversing *both* views makes that same forward
      ;; copy move the elements in the opposite order - exactly
      ;; memmove's backward case. Reversal is a bijection, so this is
      ;; right whether or not `to' and `from' are the same array, and
      ;; the caller need not ask.
      ;;--------------------------------------------------------------
      (let* ((n (- end start))
             (view (if (> at start)
                       ;; descending: n-1, n-2, ... 0
                       (lambda (a lo)
                         (make-shared-array
                          a (lambda (i) (list (+ lo (- n 1 i)))) n))
                       ;; ascending: 0, 1, ... n-1
                       (lambda (a lo)
                         (make-shared-array
                          a (lambda (i) (list (+ lo i))) n)))))
        (array-copy! (view from start) (view to at))
        ))

    (define (%array-resize a new-len fill)
      ;; Reallocate `a' to `new-len' elements: the same array type, the
      ;; old contents copied into its prefix, the new tail `fill'. The
      ;; answer is `a' itself when the length is already right, which is
      ;; how a caller learns that nothing happened - the CDF tests it
      ;; with `eq?'.
      ;;
      ;; This is the author's `sequence-resize' in two steps, with the
      ;; type read off the array by `array-type' instead of looked up in
      ;; a table of fourteen.
      ;;--------------------------------------------------------------
      (let ((old-len (array-length a)))
        (if (= new-len old-len)
            a
            (let ((new (make-typed-array (array-type a) fill new-len)))
              (%array-copy-range! new 0 a 0 (min old-len new-len))
              new
              ))))
    ))
