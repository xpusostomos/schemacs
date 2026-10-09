(define-library (schemacs lens)
  ;; A <unit-lens-type> is a structure containing functions for getting
  ;; and setting values in a data structure.  The getter retrieves a
  ;; information within a structure. The setter changes information
  ;; within the structure. Lenses are composable. The <lens-type> data
  ;; type is a structure containing a vector of many <unit-lens-type>
  ;; values, and each getter or setter from each <unit-lens-type> can
  ;; be applied in order to access or update items within items.
  ;; 
  ;; The `VIEW` function evaluates a `<LENS-TYPE>` to retrieve
  ;; information, the `UPDATE&VIEW` function evaluates a lens to update
  ;; information. Both `VIEW` and `UPDATE&VIEW` are fully composable,
  ;; so care should be taken to ensure that when constructing lenses
  ;; the lenses contain `<UNIT-LENS-TYPE>` data structures rather than
  ;; encapsulating `VIEW` or `UPDATE&VIEW` as getters or setters,
  ;; although this encapsulation might be desirable for certain APIs.
  ;;
  ;; In the case of `UPDATE&VIEW`, the following properties should generally
  ;; hold for all instances:
  ;;
  ;;   - The setter should set the item upon which the "lens" is
  ;;     focused contained within the data structure.
  ;;
  ;;   - The data structure may change, for example, in the case of
  ;;     vectors which might need to be resized. The structure that is
  ;;     modified must be returned as the first of 2 values. As often
  ;;     as possible, an empty structure should be replaced with the
  ;;     value #f and removed from containin structures.
  ;;
  ;;   - Updating the item upon which a lens is focused should also
  ;;     return a second value, possibly the result of some kind of
  ;;     fold, or possible the information in the structure that was
  ;;     replaced.
  ;;
  ;; Lenses should also contain within them a printable representation
  ;; of the lens itself, usually the symbol associated with the lens
  ;; structure in the environment itself.
  ;;
  ;; There are also "canonical" lenses which can be constructed using
  ;; `=>CANONICAL`. These are lenses that return `#F` when "viewing" a
  ;; value that is not there, as opposed to raising an error. When
  ;; updating a "canonical" lens, if the lens is focused on something
  ;; that does not yet exist, a new value can be inserted into the
  ;; object to make it exist.
  ;;
  ;; The names of symbols of the lenses in this module follow a
  ;; convention: if there is a canonical and a non-canonical version of
  ;; a lens, such as `=>HASH-KEY`, then the non-canonical lens is
  ;; suffixed with an asterisk ("*"). Non-canonical lenses can also be
  ;; mutating. A "bang" ("!")  indicates a record mutating lens, and
  ;; should be suffixed to the asterisk, if there is one:
  ;;
  ;;    `=>pure-lens`     :: replaces the target, and is canonical
  ;;    `=>impure-lens!`  :: mutates the target, and is canonical
  ;;    `=>pure-lens*`    :: replaces the target, is NOT canonical
  ;;    `=>impure-lens*!` :: mutates the target, is NOT canonical
  ;;
  ;;;   (Note: the above are not lenses, these are examples of how you
  ;;;    might name lenses when defining them.)
  ;; 
  ;; So "pure" lenses do not mutate the target values, they are
  ;; replaced and returned, wherease "impure" lenses do update the
  ;; object (but still return the same updated object).
  ;; -------------------------------------------------------------------

  (import
    (scheme base)
    (scheme write)
    (scheme case-lambda)
    (only (schemacs vector) vector-fold)
    (only (schemacs hash-table)
          hash-table-empty?  hash-table?  default-hash
          make-hash-table   alist->hash-table   hash-table->alist
          hash-table-size   hash-table-set!   hash-table-delete!
          hash-table-fold   hash-table-ref/default
          hash-table-update!/default
          )
    (only (schemacs bitwise) logbit? copy-bit)
    )

  (cond-expand
    (guile
     (import
       (only (srfi srfi-9 gnu) set-record-type-printer!)
       (only (srfi 28) format)
       (only (srfi 111) unbox set-box!))
     )
    (stklos
     (import (only (srfi 111) unbox set-box!)))
    (else
     ;; Guile does not seem to recognize the (library ...) clause in
     ;; "cond-expand" statements used in "define-library" statements.
     (cond-expand
       ((library (srfi 111))
        (import 
          (only (srfi 111) unbox set-box!))
        )
       (else))

     (cond-expand
       ((library (srfi 28))
        (import (only (srfi 28) format)))
       (mit)
       (else
        (import (only (rapid format) format)))
       )
     ))

  (export
   ;; -------------------- Main API --------------------
   lens  view  lens-set  lens-swap  update&view  update&  update
   lens-set!  lens-swap!  endo-set  endo-update  endo-view
   lens-compose  endo

   ;; ------------------- Unit lenses ------------------
   ;; When defining your own lenses
   ;; use unit-lens or record-unit-lens
   %unit-lens-type?  %lens-type?  unit-lens
   unit-lens-view  unit-lens-update  unit-lens-set  unit-lens-swap
   record-unit-lens  =>bit-field*!
   unit-lens-getter  unit-lens-setter  unit-lens-updater  unit-lens->expr
   default-unit-lens-setter  default-unit-lens-updater

   ;; ------------- Lenses introspection ---------------
   ;; Inspecting properties of lenses.
   lens-type?  vector->lens  lens->vector  lens-view  lens-unit-count

   ;; -- Extending lens indexing with other data types --
   ;; The `view` and `update&view` procedures can take integer, string, or
   ;; symbol values and automatically construct lenses out of these
   ;; for inspecting vectors and hash tables. If you have your own
   ;; record data which could also be indexed by integers, strings, or
   ;; symbols, you can use these procedures at the top-level of your
   ;; program (or in any statement that evaluates at load time), so
   ;; that `view`-ing or `update&view`-ing on constants will be able to
   ;; inspect structures of the types you constructed.
   declare-rule/index->lens
   get-rule-declaration/index->lens

   ;; ----------- Useful, pre-defined lenses -----------

   ;; Lists, and association Lists
   =>car  =>head  =>cdr
   =>find-tail  =>find  =>bring
   =>assoc-by  =>assoc  =>assv  =>assq

   ;; Vectors
   =>vector-index*! =>vector-index!
   *default-vector-constructor*  *default-vector-copier*

   ;; Hash tables
   =>hash-key*!  =>hash-key!  *default-hash-table-constructor*

   ;; Utility lenses
   =>self  =>const  =>true  =>false
   =>guard  =>on-update  =>canonical  =>encapsulate
   =>view-only-lens

   ;; Debugging lenses
   =>trace
   )

  (cond-expand
    ((or gambit guile stklos chibi)
     (export =>box)
     )
    (else))

  (begin

    (define-record-type <unit-lens-type>
      ;; When defining a record type with `UNIT-LENS`, the `SETTER` must
      ;; take 2 arguments: the `RECORD` itself and the `NEW-INFO` for the
      ;; field that is to be modified. The `RECORD` itself may be updated
      ;; destructively by the `SETTER`, however the `RECORD` *must* be
      ;; returned after an update regardless of whether it is
      ;; destructively updated or not. It is OK to replace the RECORD with
      ;; a new one containing a `NEW-INFO` in the appropriate `RECORD`
      ;; field.
      ;;------------------------------------------------------------------
      (make-unit-lens getter setter updater *->expr)
      %unit-lens-type?
      (getter  unit-lens-getter)
      (setter  unit-lens-setter)
      (updater unit-lens-updater)
      (*->expr unit-lens->expr)
      )

    (define unit-lens
      ;; Construct a new `<UNIT-LENS-TYPE>.` The `GETTER` is required, and
      ;; either the `SETTER` or `UPDATE&VIEW` procedures are required as
      ;; well. If only 2 arguments are given, they must be the getter and
      ;; updater, and the setter will be constructed by
      ;; `DEFAULT-UNIT-LENS-SETTER`.
      ;; 
      ;; - GETTER :: (lambda (record-in-focus)
      ;;                 #;(return information taken from the record within focus))
      ;; 
      ;; - SETTER :: (lambda (record-in-focus new-info)
      ;;                 #;(update&view the record within focus with the new info)
      ;;                 new-record-in-focus) ;; return the updated record-in-focus
      ;; 
      ;; - UPDATER :: (lambda (update&view record-in-focus)
      ;;                 (let-values
      ;;                       (((new-record-in-focus return)
      ;;                         #;(evaluate the \"update&view\" with \"record-in-focus\" as the argument)
      ;;                         ))
      ;;                   ;; The \"update&view\" function returns an updated \"record-in-focus\" and
      ;;                   ;; an arbitrary return value. Return both values:
      ;;                   (values new-record-in-focus return)))
      ;; 
      ;; Of course, if you supply both a `SETTER` and an `UPDATE&VIEW`
      ;; function, both can be used appropriately by the various lens
      ;; APIs. This is good if you want to define a lens that has
      ;; different performance characteristics depending on whether you
      ;; are simply setting new information or updating an existing
      ;; information.
      ;; 
      ;; The `*->EXPR` argument is an optional symbol used to identify
      ;; this unit lens.
      ;;------------------------------------------------------------------
      (case-lambda
        ((getter update&view)
         (unit-lens getter (default-unit-lens-setter update&view) update&view #f)
         )
        ((getter setter update&view) (unit-lens getter setter update&view #f))
        ((getter setter update&view *->expr)
         (if (and (not setter) (not update&view))
             (error
              "unit-lens function given #f for both setter and update&view arguments"
              setter update&view
              )
             (let ((setter (if setter setter (default-unit-lens-setter update&view)))
                   (update&view (if update&view update&view (default-unit-lens-updater getter setter)))
                   )
               (make-unit-lens getter setter update&view *->expr)
               )))))

    (define record-unit-lens
      ;; This function constructs a `<UNIT-LENS-TYPE>` from a `GETTER` and
      ;; `SETTER` function that has been defined using
      ;; `DEFINE-RECORD-TYPE.` It is assumed that the `SETTER` is a
      ;; destructive update on a mutable record type that returns no
      ;; value, and is /not/ a functional update that returns a new copy
      ;; of the record, because after the `SETTER` funtion is evaluated a
      ;; reference to the previous `RECORD-IN-FOCUS` is returned and
      ;; result returned by `SETTER` is ignored -- if you have otherwis
      ;; defined the `SETTER` argument as a functional update, *do not*
      ;; use this `RECORD-UNIT-LENS` constructor to define your lens, use
      ;; `IMMUTABLE-RECORD-LENS` instead.
      ;;------------------------------------------------------------------
      (case-lambda
        ((getter setter) (record-unit-lens getter setter #f))
        ((getter setter label)
         (let ((setter
                ;; Setters defined by define-record-type do not return the
                ;; record in focus, this wrapper returns the record in focus
                ;; after updating it.
                (lambda (record-in-focus new-info)
                  (setter record-in-focus new-info)
                  record-in-focus)))
           (unit-lens
            getter setter
            (default-unit-lens-updater getter setter)
            label
            )))))

    ;; (cond-expand
    ;;   (guile-3
    ;;    (set-record-type-printer!
    ;;     <unit-lens-type>
    ;;     (lambda (unit-lens port)
    ;;       (display
    ;;        (format "(<unit-lens-type> ~a)" (unit-lens->expr unit-lens))
    ;;        port))))
    ;;   (else))

    (define (unit-lens-view record-in-focus unit-lens)
      ;; Evaluate the getter of a `UNIT-LENS`.
      ;;------------------------------------------------------------------
      ((unit-lens-getter unit-lens) record-in-focus)
      )

    (define (default-unit-lens-updater getter setter)
      ;; Construct an update procedure that works on some field of a
      ;; record type, providing the getter and setter for that particular
      ;; field. The procedure constructed takes an updater function and
      ;; the record, evaluates getter on the record to get the old info,
      ;; evaluates `UPDATE&VIEW` on the old info and an arbitrary return
      ;; value, then the setter is used to update the info in the
      ;; record. Then two values are returned: the record, and the
      ;; arbitrary return value.
      ;;------------------------------------------------------------------
      (lambda (updater record-in-focus)
        (let-values (((new-info return) (updater (getter record-in-focus))))
          (values (setter record-in-focus new-info) return)
          )))

    (define (default-unit-lens-setter updater)
      ;; Construct a setter procedure that works on record as long as the
      ;; `UPDATE&VIEW` procedure given as an argument works like
      ;; `DEFAULT-UNIT-LENS-UPDATER.`
      ;;------------------------------------------------------------------
      (lambda (record-in-focus new-info)
        (let-values
            (((record-in-focus _return)
              (updater (lambda _ new-info) record-in-focus)
              ))
          record-in-focus
          )))

    (define (unit-lens-update updater record-in-focus unit-lens)
      ;; Evaluate the getter of a `UNIT-LENS` on the `RECORD-IN-FOCUS` and
      ;; evaluate an `UPDATE&VIEW` on the information returned by the getter of
      ;; the `LENS.` The `UPDATE&VIEW` function must return two values:
      ;; 
      ;;  1. a new record computed from the old info received from the
      ;;     `UNIT-LENS` getter, and
      ;; 
      ;;  2. an arbitrary return value.
      ;; 
      ;; The setter of the `UNIT-LENS` is used to update the `RECORD-IN-FOCUS` with
      ;; the new information that was returned by `UPDATE&VIEW`, then the result of
      ;; the updated `RECORD-IN-FOCUS` is returned as the first value, and the
      ;; arbitrary return value received from the `UPDATE&VIEW` function is returned
      ;; as the second value.
      ;;------------------------------------------------------------------
      ((unit-lens-updater unit-lens) updater record-in-focus)
      )

    (define (unit-lens-set new-info record-in-focus lens)
      ;; Similar to `UNIT-LENS-UPDATE` but takes a new piece of information
      ;; rather than an `UPDATE&VIEW` function. Returns only 1 value: the updated
      ;; `RECORD-IN-FOCUS.`
      ;;------------------------------------------------------------------
      ((unit-lens-setter lens) record-in-focus new-info)
      )

    (define (unit-lens-swap new-info record-in-focus lens)
      ;; Similar to `UNIT-LENS-SET` but returns the old information that
      ;; within the RECORD-IN-FOCUS after having replaced it with the
      ;; NEW-INFO value given as an argument.
      ;;
      ;; Note that this operation could update the `RECORD-IN-FOCUS` if
      ;; any of the `LENSES` are mutating.
      ;;------------------------------------------------------------------
      (let ((old-info ((unit-lens-getter lens) record-in-focus)))
        ((unit-lens-setter lens) record-in-focus new-info)
        old-info
        ))

    (define (=>bit-field*! nth-bit)
      (let ((getter (lambda (field) (logbit? nth-bit field)))
            (setter (lambda (field bool) (copy-bit nth-bit field bool)))
            )
        (unit-lens
         getter setter (default-unit-lens-updater getter setter)
         `(=>logbits*! ,nth-bit)
         )))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <lens-type>
      (vector->lens vec) ;; Construct a lens from a vector of unit lenses
      %lens-type?
      (vec lens->vector) ;; Get the vector of unit lenses comprising this lens.
      )

    (define (lens-type? o) (or (%lens-type? o) (%unit-lens-type? o)))

    (cond-expand
      (guile-3
       (set-record-type-printer!
        <lens-type>
        (lambda (lens port)
          (display
           (format "(<lens-type> ~a)" (lens->expr lens))
           port))))
      (else))

    (define (lens->expr lens)
      (cond
       ((%unit-lens-type? lens)
        (list 'lens (unit-lens->expr lens)))
       ((%lens-type?      lens)
        (cons
         'lens
         (map
          (lambda (unit)
            (cond
             ((%lens-type?      unit) (lens->expr      unit))
             ((%unit-lens-type? unit) (unit-lens->expr unit))
             (else (list 'error "lens->expr argument not a <LENS-TYPE> or <UNIT-LENS-TYPE>" unit))))
          (vector->list (lens->vector lens)))))
       (else (list 'error "lens->expr argument not a <LENS-TYPE> or <UNIT-LENS-TYPE>" lens))))


    (define (get-lens-index-type index)
      ;; Used internally by `LENS-VIEW` and `LENS-UPDATE`, each of which
      ;; constructed a partial procedure application to `TYPED-LENS-APPLY`
      ;; above where the first three arguments have already been applied,
      ;; and this procedure applies the last three according to the type
      ;; of `LENS`.
      (cond
       ((symbol?  index) 'symbol)
       ((string?  index) 'string)
       ((integer? index) 'integer)
       (else (error "cannot be used as a lens index" index))
       ))


    (define (apply-typed-lens record-in-focus lens proc)
      (let*((index-type (get-lens-index-type lens))
            (dispatch
             (lambda ()
               (let ((lens-constr
                      (get-rule-declaration/index->lens
                       index-type record-in-focus)))
                 (cond
                  (lens-constr (proc (lens-constr lens)))
                  (else (error "cannot index record by value of type"
                               index-type lens record-in-focus)))
                 )))
            )
        (cond
         ((eq? 'integer index-type)
          (cond
           ((vector? record-in-focus) (proc (=>vector-index! lens)))
           (else (dispatch))
           ))
         ((or (eq? 'symbol index-type) (eq? 'string index-type))
          (cond
           ((hash-table? record-in-focus) (proc (=>hash-key! lens)))
           (else (dispatch))
           ))
         (else
          (error "failed to dispatch on index type" index-type lens))
         )))


    (define (lens-view record-in-focus lens)
      ;; This function evaluates the getter on the `RECORD-IN-FOCUS` using
      ;; the single lens argument. The `LENS` argument to this procedure
      ;; must be of `<LENS-TYPE>` and not `<UNIT-LENS-TYPE>.` Use the
      ;; `VIEW` function to operate on an ad-hoc chain of lenses. If the
      ;; `LENS` argument is of `<LENS-TYPE>`, the chain of
      ;; `<UNIT-LENS-TYPE>` elements within have the getter applied in
      ;; order producing the next record in focus to be viewed by the next
      ;; lens in the chain.
      ;;------------------------------------------------------------------
      (cond
       ((%unit-lens-type? lens)
        (unit-lens-view record-in-focus lens))
       ((%lens-type? lens)
        (let*((vec (lens->vector lens))
              (len (vector-length vec))
              )
          (let loop ((record-in-focus record-in-focus) (i 0))
            (cond
             ((< i len)
              (loop (lens-view record-in-focus (vector-ref vec i)) (+ 1 i)))
             (else record-in-focus))
            )))
       (else
        (apply-typed-lens record-in-focus lens
         (lambda o (apply lens-view record-in-focus o))))
       ))


    (define (lens-update updater record-in-focus lens)
      ;; This function evaluates an `UPDATER` function on the
      ;; `RECORD-IN-FOCUS.` The single LENS argument must be of type
      ;; `<LENS-TYPE>` or `<UNIT-LENS-TYPE>`. Use the `UPDATE&VIEW`
      ;; function to operate on an ad-hoc chain of lenses. If the LENS
      ;; argument is of `<LENS-TYPE>`, the chain of `<UNIT-LENS-TYPE>`
      ;; elements within have the updater applied in order producing the
      ;; next record in focus to be updated by the next lens in the chain.
      ;;------------------------------------------------------------------
      (cond
       ((%unit-lens-type? lens) (unit-lens-update updater record-in-focus lens))
       ((%lens-type? lens)
        (let*((vec (lens->vector lens))
              (len (vector-length vec)))
          (let loop ((record-in-focus record-in-focus) (i 0))
            (cond
             ((< i len)
              (lens-update
               (lambda (record-in-focus) (loop record-in-focus (+ 1 i)))
               record-in-focus
               (vector-ref vec i)))
             (else
              (updater record-in-focus))
             ))
          ))
       (else
        (apply-typed-lens record-in-focus lens
         (lambda o (apply lens-update updater record-in-focus o))))
       ))


    (define (lens-unit-fold fold accum lens)
      ;; Try to perform a fold over every `<UNIT-LENS-TYPE>` values within
      ;; an object LENS. LENS might be of `<LENS-TYPE>` or `<UNIT-LENS-TYPE>`
      ;; values, or a list or tree of either of the above.
      ;;
      ;; NOTE that a recursive lens could result in this procedure looping
      ;; indefinitely, but this is allowed because the lens could be
      ;; designed to focus on a recursive data structure.
      ;;------------------------------------------------------------------
      (let loop ((accum accum) (lens lens))
        (cond
         ((not lens) accum)
         ((null? lens) accum)
         ((%unit-lens-type? lens) (fold accum lens))
         ((string? lens) (fold accum lens))
         ((integer? lens) (fold accum lens))
         ((symbol? lens) (fold accum lens))
         ((%lens-type? lens) ;; Recursively defined lenses
          (vector-fold (lambda (accum lens) (loop accum lens)) accum (lens->vector lens)))
         ((list? lens) ;; Recursively defined lenses
          (loop (loop accum (car lens)) (cdr lens)))
         (else
          (error "compound lens constructor contains at least one non-lens element" lens)))))


    (define (lens-unit-count lens)
      ;; Tries to approximate how many unit lenses make up a compound
      ;; lens.
      ;;------------------------------------------------------------------
      (lens-unit-fold (lambda (accum _lens) (+ 1 accum)) 0 lens))


    (define (compound-lens lenses)
      ;; Construct a lens from a list of lenses. Each lens element must be
      ;; a `<LENS-TYPE>` or `<UNIT-LENS-TYPE>`. Each lens element has all
      ;; of its `<UNIT-LENS-TYPE>` values extracted and stored into a new
      ;; lens. This function is called by the `LENS` function with all of
      ;; its arguments as the list of lens elements.
      ;;------------------------------------------------------------------
      (let*((count (lens-unit-count lenses))
            (vec (make-vector count)))
        (lens-unit-fold
         (lambda (i unit-lens)
           (vector-set! vec i unit-lens)
           (+ 1 i))
         0 lenses)
        (vector->lens vec)))


    (define (compound-view record-in-focus lenses)
      ;; This function should not be used directly, instead construct a
      ;; lens using the `LENS` constructor and use `LENS-VIEW` with it
      ;; instead. This function evaluates a list of lenses chaining each
      ;; lookup, i.e. each item looked up is used as the next record in
      ;; `RECORD-IN-FOCUS` for the next lens.
      ;;------------------------------------------------------------------
      (cond
       ((not   lenses) record-in-focus)
       ((null? lenses) record-in-focus)
       (else (compound-view (lens-view record-in-focus (car lenses)) (cdr lenses)))))


    (define (compound-update updater record-in-focus lenses)
      ;; This procedure usually need not be used directly, instead one
      ;; would construct a `<LENS-TYPE>` using the `LENS` constructor and
      ;; evaluate `UPDATER` with it instead. This procedure is different
      ;; in that it operates on a linked-list of lenses without
      ;; constructing a lens. Each lens is composed with the one following
      ;; it for lookups and updates, i.e. each `RECORD-IN-FOCUS` selects a
      ;; piece of information within it which becomes the next
      ;; `RECORD-IN-FOCUS` for the next lens in the list. After retrieving
      ;; the inner-most `RECORD-IN-FOCUS` the `UPDATE&VIEW` proecdure is
      ;; used to produce new information and an arbitrary return
      ;; value. Each new information is passed to the previous lens to be
      ;; updated within the previous `RECORD-IN-FOCUS` and returns the
      ;; arbitrary return value.
      ;;
      ;; Note that this operation could update the `RECORD-IN-FOCUS` if
      ;; any of the `LENSES` are mutating.
      ;;------------------------------------------------------------------
      (cond
       ((not   lenses) (updater record-in-focus))
       ((null? lenses) (updater record-in-focus))
       (else
        (let ((lens (car lenses)))
          (lens-update
           (lambda (record-in-focus)
             (let-values
                 (((record-in-focus return)
                   (compound-update updater record-in-focus (cdr lenses))
                   ))
               (values record-in-focus return)))
           record-in-focus lens)))))


    (define (compound-lens-set new-info record-in-focus lenses)
      ;; Similar to `COMPOUND-UPDATE`, but rather than taking an updating
      ;; function, simply takes new information and updates whatever info
      ;; was in the record upon which the lens is focused. Also, unlike
      ;; `UPDATE&VIEW`, this procedure returns only an updated
      ;; `RECORD-IN-FOCUS`, no second value is returned.
      ;;------------------------------------------------------------------
      (let-values
          (((record-in-focus _return)
            (compound-update
             (lambda (_) (values new-info #f))
             record-in-focus lenses)))
        record-in-focus))


    (define (compound-lens-set! new-info record-in-focus lenses)
      ;; Like `COMPOUND-LENS-SET` but assumes the `LENSES` will update the
      ;; `RECORD-IN-FOCUS` in place, and returns only the `NEW-INFO` after
      ;; updating the record.
      (let-values
          (((_rec return)
            (compound-update
             (lambda (_) (values new-info #f))
             record-in-focus lenses)))
        return))


    (define (compound-swap new-info record-in-focus lenses)
      ;; Similar to `COMPOUND-LENS-SET` but returns two values: the updated
      ;; RECORD-IN-FOCUS and the old info that existed prior to being
      ;; updated to the argument NEW-INFO.
      ;;------------------------------------------------------------------
      (compound-update
       (lambda (old-info) (values new-info old-info))
       record-in-focus lenses))


    (define (compound-swap! new-info record-in-focus lenses)
      ;; Similar to `COMPOUND-LENS-SWAP!`, but assumes the `LENSES` given
      ;; will update the `RECORD-IN-FOCUS` in place and only returns the
      ;; single value which was the previous value prior to the update.
      ;;------------------------------------------------------------------
      (let-values
          (((_rec return) (compound-swap new-info record-in-focus lenses)))
        return))

    ;; -------------------------------------------------------------------------------------------------

    (define (lens . lenses)
      ;; Construct a COMPOUND-LENS with the multiple arguments, rather
      ;; than with a single list argument. This function tries to
      ;; construct the lens such that each lens element is a
      ;; <UNIT-LENS-TYPE>, so it will expand <LENS-TYPE> and lists of
      ;; <UNIT-LENS-TYPE> types to extract all <UNIT-LENS-TYPE> components
      ;; in sequence. So although you may pass only one or two arguments
      ;; to this procedure, the constructed <LENS-TYPE> may contain many
      ;; more than two <UNIT-LENS-TYPE> values, it will contain the sum of
      ;; all <UNIT-LENS-TYPE> components within all arguments.
      ;;------------------------------------------------------------------
      (compound-lens lenses))


    (define (view record-in-focus . lenses)
      ;; Similar to COMPOUND-VIEW, but evaluate a list of lenses given as
      ;; arguments rather than as a linked-list, in order to retrieve
      ;; information. This procedure does not construct a new <LENS-TYPE>,
      ;; it uses all arguments as they are.
      (compound-view record-in-focus lenses))


    (define (update&view updater record-in-focus . lenses)
      ;; Similar to `COMPOUND-UPDATE`, evaluates a list of lenses given as
      ;; arguments, rather than a linked list, in order to update
      ;; information within the `RECORD-IN-FOCUS.` This procedure does not
      ;; construct a new `<LENS-TYPE>`, it uses all arguments as they are.
      ;;
      ;; Note that this operation could update the `RECORD-IN-FOCUS` if
      ;; any of the `LENSES` are mutating.
      ;;------------------------------------------------------------------
      (compound-update updater record-in-focus lenses))


    (define (update& updater record-in-focus . lenses)
      ;; The `UPDATE&^` procedure is similar to `UPDATE&VIEW`, where the
      ;; `UPDATER` procedure taken as an argument must return two values,
      ;; but the `UPDATE&` lens operation ignores the second value and
      ;; only returns the updated `RECORD-IN-FOCUS` -- the mnemonic is
      ;; that the value returned by `UPDATER` is lost, or you could that
      ;; the result "modulo" the second value is returned.  This is useful
      ;; if you have an `UPDATER` defined that usually returns 2 values
      ;; for use with `UPDATE&VIEW` but want only one value returned by
      ;; the lens `UPDATE&VIEW` operation.
      ;;
      ;; Note that this operation could update&view the `RECORD-IN-FOCUS`
      ;; if any of the `LENSES` are mutating.
      ;;------------------------------------------------------------------
      (let-values
          (((rec _return)
            (apply update&view updater record-in-focus lenses)))
        rec))


    (define (update updater record-in-focus . lenses)
      ;; The `UPDATE` procedure is much like the `UPDATE&` procedure,
      ;; except that the `UPDATER` procedure argument must return only an
      ;; updated record, no second value. Likewise, the `UPDATE&VIEW` lens
      ;; operation itself only returns a single value the second value is
      ;; not returned, the updated record. This function can be useful
      ;; when you want to updates the argument without returning a second
      ;; value.
      ;;
      ;; Note that this operation could update&view the `RECORD-IN-FOCUS` if
      ;; any of the `LENSES` are mutating.
      ;;------------------------------------------------------------------
      (let-values
          (((rec _return)
            (apply update&view (lambda (rec) (values (updater rec) #f))
             record-in-focus lenses)))
        rec))


    (define (lens-set new-info record-in-focus . lenses)
      ;; Similar to `UPDATE&VIEW`, but rather than taking an updating function,
      ;; simply takes a `NEW-INFO` and replaces whatever info was in the
      ;; `RECORD-IN-FOCUS.` Also, unlike `UPDATE&VIEW`, this function returns
      ;; only an updated `RECORD-IN-FOCUS`, no second value is returned.
      ;;------------------------------------------------------------------
      (compound-lens-set new-info record-in-focus lenses))


    (define (lens-set! new-info record-in-focus . lenses)
      ;; Similar to `LENS-SET`, but assumes the `LENSES` will update the
      ;; `RECORD-IN-FOCUS` in-place, and so simply reutrns `NEW-INFO`
      ;; rather than returning the updated `RECORD-IN-FOCUS`.
      ;;
      ;; WARNING: this lens does not compose nicely, it is just a
      ;; convenience to use in procedural code, like as one of the
      ;; procedures executed in a `BEGIN` statement.
      ;;------------------------------------------------------------------
      (compound-lens-set! new-info record-in-focus lenses))


    (define (lens-swap new-info record-in-focus . lenses)
      ;; Similar to `LENS-SET` but returns two values: the updated
      ;; `RECORD-IN-FOCUS` and the old information that existed within the
      ;; record prior to being updated by the `NEW-INFO.`
      ;;------------------------------------------------------------------
      (compound-swap new-info record-in-focus lenses))


    (define (lens-swap! new-info record-in-focus . lenses)
      ;; Similar to `LENS-SWAP`, but assumes the `LENSES` will update the
      ;; `RECORD-IN-FOCUS` in-place, and so simply reutrns the value that
      ;; was in `RECORD-IN-FOCUS` prior to when this update occurred. It
      ;; returns only the previous focused value, not the updated
      ;; `RECORD-IN-FOCUS`.
      ;;
      ;; WARNING: this lens does not compose nicely, it is just a
      ;; convenience to use in procedural code, like as one of the
      ;; procedures executed in a `BEGIN` statement.
      ;;------------------------------------------------------------------
      (compound-swap! new-info record-in-focus lenses))


    (define (endo-update updater . lenses)
      ;; This procedure constructs an "endofunctor" from a `LENS` and an
      ;; `UPDATER`. An endofunctor is a function that takes a single value
      ;; of one type as an argument, and returns a single updated value of
      ;; the same type. Endofunctors are easily composable with
      ;; higher-order functions (see SRFI 197 "Pipeline Operators", and
      ;; SRFI 235 "Combinators").
      ;;
      ;; The endofunctor constructed by this procedure will use the given
      ;; `LENS` argument to focus on its input data and apply the given
      ;; `UPDATER` to the focused value updating that input data, then the
      ;; upated data is returned.
      ;;------------------------------------------------------------------
      (lambda (record-in-focus) (apply update updater record-in-focus lenses)))


    (define (endo-set new-info . lenses)
      ;; This procedure constructs an "endofunctor" from a `LENS` and an
      ;; `UPDATER`. An endofunctor is a function that takes a single value
      ;; of one type as an argument, and returns a single updated value of
      ;; the same type. Endofunctors are easily composable with
      ;; higher-order functions (see SRFI 235 "Combinators").
      ;;
      ;; The endofunctor constructed by this procedure will use the given
      ;; `LENS` argument to focus on its input data and replace the
      ;; information that was focused with `NEW-INFO`, updating the input
      ;; data, then the upated data is returned.
      ;;------------------------------------------------------------------
      (lambda (record-in-focus) (apply lens-set new-info record-in-focus lenses)))


    (define (endo-view . lenses)
      ;; This procedure constructs an "endofunctor" from a sequence of
      ;; `LENS` or procedure arguments. An endofunctor is a function that
      ;; takes a single value of one type as an argument, and returns a
      ;; single updated value of the same type. Endofunctors are easily
      ;; composable with higher-order functions (see SRFI 197 "Pipeline
      ;; Operators", and SRFI 235 "Combinators").
      ;;
      ;; The endofunctor constructed by this procedure will use the given
      ;; `LENS` and procedure arguments to focus on its input data. You
      ;; may provide either lenses or procedures as arguments to
      ;; `ENDO-VIEW`, and as many arguments as you wish. Applying no
      ;; arguments constructs an indentity functor. Function composition
      ;; occurs from left to right, so for example, the following
      ;; expressions each construct a procedure which does the same thing
      ;; as `CADDR`.
      ;;
      ;; ```
      ;; (endo-view cdr cdr car)
      ;; (endo-view cdr =>cdr =>car)
      ;; (endo-view =cdr =>cdr car)
      ;; ```
      ;;------------------------------------------------------------------
      (let loop ((lenses lenses))
        (lambda (o)
          (cond
           ((null? lenses) o)
           (else
            (let*((lens (car lenses)))
              (cond
               ((procedure? lens) ((loop (cdr lenses)) (lens o)))
               ((lens-type? lens) ((loop (cdr lenses)) (view o lens)))
               (else (error "not a procedure or lens" lens)))
              ))
           ))))


    (define endo
      ;; A shorthand for `ENDO-VIEW`.
      ;;------------------------------------------------------------------
      endo-view)


    (define (lens-compose . lenses)
      ;; Similar to `endo-view` but composes lenses from right to
      ;; left. This is more natural if you think of the composition of
      ;; functions `(compose f g)` as `(lambda (x) (f (g x)))`.
      ;;
      ;; For example, the following proceedures all do the same thing:
      ;;
      ;; ```
      ;; (lens-compose =>car =>cdr =>cdr)
      ;; (lens-compose car cdr cdr)
      ;; (lens-compose car =>cdr cdr)
      ;; caddr
      ;;
      ;; (endo-view    =>cdr =>cdr =>car) ;; composes from left to right
      ;; (endo-view    cdr cdr car)
      ;; (endo-view    cdr =>cdr car)
      ;; ```
      ;;------------------------------------------------------------------
      (let loop ((lenses lenses))
        (lambda (o)
          (cond
           ((null? lenses) o)
           (else
            (let*((lens (car lenses)))
              (cond
               ((procedure? lens) (lens ((loop (cdr lenses)) o)))
               ((lens-type? lens) (view ((loop (cdr lenses)) o) lens))
               (else (error "not a procedure or lens" lens)))
              ))
           ))))

    ;; -------------------------------------------------------------------------------------------------

    (define (cons-lens this that cons label)
      (let ((getter (lambda (rec) (if (pair? rec) (this rec) '())))
            (setter
             (lambda (rec new)
               (cond
                ((not (pair? rec)) (if (not new) '() (cons new '())))
                (else (cons new (that rec))))
               )))
        (unit-lens
         getter setter
         (default-unit-lens-updater getter setter)
         label)))

    (define =>car
      ;; This lens is `=>CANONICAL` -- `'()` is returned if the pair is
      ;; equal to (cons '() '()) after an update.
      ;;------------------------------------------------------------------
      (cons-lens car cdr cons '=>car))


    (define =>head
      ;; This lens is similar to `=>CAR` except that it checks for both
      ;; `#F` and null lists '(), so lists constructed with `=>CAR` can
      ;; contain `#F` values, but lists constructed with `=>HEAD` can
      ;; not. The `=>HEAD` lens tends to compose better with other
      ;; `=>CANONICAL` lenses, since `=>CANONICAL` checks for `#F` values
      ;; to determine whether a new node needs to be constructed, and sets
      ;; `#F` if a node is updated to become empty.
      ;;------------------------------------------------------------------
      (let ((getter
             (lambda (cell) (if (pair? cell) (car cell) #f)))
            (setter
             (lambda (cell val)
               (cond
                ((not val) (if (pair? cell) (cdr cell) '()))
                (else (if (pair? cell) (cons val (cdr cell)) (list val)))
                )))
            )
        (unit-lens
         getter setter
         (default-unit-lens-updater getter setter)
         '=>car*)))


    (define =>cdr
      ;; This lens is `=>CANONICAL` -- `'()` is returned if the pair is
      ;; equal to `(CONS '() '())` after an update.
      ;;------------------------------------------------------------------
      (cons-lens cdr car (lambda (a b) (cons b a)) '=>cdr))

    ;; -------------------------------------------------------------------------------------------------

    (define (=>vector-index*! i)
      ;; Construct a `<UNIT-LENS-TYPE>` that can be used to access the
      ;; elements of a vector. The vector sized is *not* checked. The
      ;; `LABEL` argument is optional, it is used to label the
      ;; `<UNIT-LENS-TYPE>`, a default label can be provided instead. The
      ;; vector is not supplied to this lens, it is expected that the
      ;; vector will be passed as an argument to the `LENS-VIEW`
      ;; function. For example:
      ;; 
      ;;     (lens-view SOME-VECTOR (=>vector-index 0))
      ;; 
      ;; and of course you can chain it with other lenses:
      ;; 
      ;;     (lens .lens-A .lens-B (=>vector-index 0) .lens-C)
      ;;------------------------------------------------------------------
      (unit-lens
       (lambda (vec) (vector-ref vec i))
       (lambda (vec new-info) (vector-set! vec i new-info) vec)
       #f (list '=>vector-index*! i)))


    (define *default-vector-constructor*
      ;; When using a the canonical hash-key lens `=>VECTOR-INDEX!`,
      ;; updating a non-existent index in a non-existent vector must
      ;; construct a new vector so that it can guarantee an update. The
      ;; procedure in this parameter object is applied an index argument
      ;; so that a vector large enough to store an element at the index
      ;; can be constructed. The default constructor is the R7RS standard
      ;; `MAKE-VECTOR`, which does not initialize any elements of the
      ;; constructed vector. If you wish, you can parameterize this
      ;; procedure when using `=>VECTOR-INDEX!` lenses (NOTE that using
      ;; plain integers as lenses is the same as using `=>VECTOR-INDEX!`),
      ;; such that constructing a new vector initializes all elements to
      ;; `#F`, but this is not the default behavior because it can slows
      ;; down processes as vectors become large.
      ;;------------------------------------------------------------------
      (make-parameter (lambda (i) (make-vector (+ 1 i)))))

    (define *default-vector-copier*
      ;; Like with `*DEFAULT-VECTOR-CONSTRUCTOR*`, it is also possible to
      ;; parameterize the vector copier function used by
      ;; `=>VECTOR-INDEX!`.  See the documentation for
      ;; `*DEFAULT-VECTOR-CONSTRUCTOR*` to better understand how this is
      ;; used.
      ;;
      ;; The default value of this parameter is the R7RS standard
      ;; `VECTOR-COPY!` procedure. Whatever procedure you use to
      ;; parameterize this must take the same arguments as `VECTOR-COPY!`.
      ;;------------------------------------------------------------------
      (make-parameter vector-copy!))


    (define (=>vector-index! i)
      ;; This is the canonicalized `=>VECTOR-INDEX!` lens. It
      ;; automatically constructs vectors, or resizes vectors when the
      ;; index `I` is out of bounds, so that values can be stored.
      ;;
      ;; NOTE: that when you use a plain integer value as a lens, it
      ;; automatically applies that integer to this procedure to construct
      ;; a useful lens.
      ;;------------------------------------------------------------------
      (let ((getter
             (lambda (vec)
               (cond
                ((not vec) #f)
                ((<= (vector-length vec) i) #f)
                (else (vector-ref vec i))))
             )
            (updater
             (lambda (updater vec)
              (cond
               ((< i 0) (error "index out of bounds" i))
               (else
                (let*((vec (if (not vec) (make-vector (+ 1 i)) vec))
                      (len (vector-length vec)))
                  (cond
                   ((>= i len)
                    (let ((new-vec ((*default-vector-constructor*) (+ 1 len))))
                      ((*default-vector-copier*) new-vec 0 vec)
                      (let-values (((elem result) (updater #f)))
                        (vector-set! new-vec i elem)
                        (values new-vec result))))
                   (else
                    (let-values (((elem result) (updater (vector-ref vec i))))
                      (vector-set! vec i elem)
                      (values vec result))))))))
             )
            )
        (unit-lens getter (default-unit-lens-setter updater) updater `(=>vector-index! ,i)))
      )


    ;; -------------------------------------------------------------------------------------------------

    (define (=>hash-key*! key)
      ;;  Construct `<UNIT-LENS-TYPE>` that can be used to access the
      ;; elements of a SRFI-69 or SRFI-125 hash-table. To delete elements
      ;; in the hash table using this `=>HASH-KEY*!`, evaluate `LENS-SET`
      ;; with #f as the value to be stored.  If an `UPDATE&VIEW` is
      ;; performed on a `=>HASH-KEY*!` that does not exist in the hash
      ;; table, the update function receives `#F` as the default value to
      ;; be updated. Note that hash tables updated by this lens are NOT
      ;; reduced to canonical form unless you wrap the `=>HASH-KEY*!` lens
      ;; in a `=>CANONICAL` lens, where you would have to provide a
      ;; constructor function to be used when an update is performed on an
      ;; `#F` node.
      ;;------------------------------------------------------------------
      (unit-lens
       (lambda (table)
         (hash-table-ref/default table key #f))
       (lambda (table new-info)
         (if (not new-info)
             (hash-table-delete! table key)
             (hash-table-update!/default table key (lambda (_) new-info) #f))
         table)
       (lambda (updater table)
         (let ((return-box #f)
               (do-delete #f))
           (hash-table-update!/default
            table key
            (lambda (old-info)
              (let-values
                  (((new-info return) (updater old-info)))
                (set! return-box return)
                (unless new-info (set! do-delete #t))
                new-info))
            #f)
           (when do-delete (hash-table-delete! table key))
           (values table return-box)))
       (list '=>hash-key*! key)))


    (define *default-hash-table-constructor*
      ;; When using a the canonical hash-key lens `=>HASH-KEY`, updating
      ;; a non-existent key in a non-existent table must construct a new
      ;; hash table so that it can guarantee an update. The procedure in
      ;; this parameter object is applied no arguments to construct the
      ;; new hash table. By default the `MAKE-HASH-TABLE` procedure is
      ;; used, but you can parameterize this API to construct hash tables
      ;; with other arguemnts, for example a different number of buckets
      ;; or the weakness of references.
      (make-parameter make-hash-table)
      )


    (define (=>hash-key! key)
      ;; This is the `=>CANONICAL` version of `=>HASH-KEY*!`. When
      ;; evaluating `UPDATE&VIEW` or `LENS-SET`, a canonical hash key
      ;; automatically creates a new `<HASH-TABLE>` if the record in focus
      ;; is `#F`, and automatically returns `#F` if the update removes the
      ;; last key in the hash table.
      ;;
      ;; NOTE: that when you use a plain string or symbol value as a lens,
      ;; it automatically applies that integer to this procedure to
      ;; construct a useful lens.
      ;;------------------------------------------------------------------
      (=>canonical
       (=>hash-key*! key)
       (*default-hash-table-constructor*)
       hash-table-empty?))

    ;; -------------------------------------------------------------------------------------------------

    (define (=>find-tail yes?)
      ;; This lens search through a list for the first element that
      ;; matches the given predicate `YES?` and operates on the pair (the
      ;; cons cell) for which the `CAR` of the pair evaluated to `#T` when
      ;; applied to `YES?`. Viewing returns the pair for which the `CAR`
      ;; matched the `YES?` predicate, updating must return a new pair or
      ;; an empty list. If none of the list elements match `YES?` then the
      ;; updater is applied an empty list, or viewing returns an empty
      ;; list.
      ;;------------------------------------------------------------------
      (let*((viewer
             (lambda (pair)
               (let loop ((pair pair))
                 (cond
                  ((null? pair) '())
                  ((yes? (car pair)) pair)
                  (else (loop (cdr pair)))
                  ))
               ))
            (updater
             (lambda (up pair)
               (let loop ((pair pair))
                 (cond
                  ((null? pair) (up '()))
                  ((yes? (car pair)) (up pair))
                  (else
                   (let-values (((cdr-pair return) (loop (cdr pair))))
                     (values (cons (car pair) cdr-pair) return)))
                  ))
               ))
            )
        (unit-lens
         viewer
         (default-unit-lens-setter updater)
         updater
         `(=>find-tail ,yes?))
        ))

    (define (=>find yes?)
      ;; This lens updates the first item in a list that matches the given
      ;; predicate `YES?`. When updating, if no record is found, the
      ;; updater is passed the values `#F`, and can choose to create a new
      ;; value, which will be appended to the end of the list. Otherwise,
      ;; a new `CONS` pair is constructed and it replaces the pair that
      ;; was found by the `YES?` predicate.
      ;;------------------------------------------------------------------
      (=>encapsulate
       (lens (=>find-tail yes?) =>car)
       `(=>find ,yes?)))


    (define (=>bring yes?)
      ;; This lens is similar to `=>FIND` except in its updating
      ;; behavior. If a values is found, it is removed from the list when
      ;; updating and prepended to the head of the list if the value
      ;; returned by the updated is not `#F`. The element matching the
      ;; predicate is removed and nothing is prepended if the updating
      ;; procedure returns `#F`. Every time you update an element in the
      ;; list, it is moved to the head of the list. This "bubbling"
      ;; behavior is faster for items that are updated often.
      ;;------------------------------------------------------------------
      (let*((=>ulens (=>find-tail yes?))
            (viewer (endo-view =>ulens =>car))
            (updater
             (lambda (up rec)
               (let*-values
                   (((rec elem)
                     (update&view
                      (lambda (rec)
                        (cond
                         ((null? rec) (values '() '()))
                         (else (values (cdr rec) (car rec)))
                         ))
                      rec =>ulens))
                    ((elem return) (up elem))
                    )
                 (values (if (null? elem) rec (cons elem rec)) return)))
             ))
        (unit-lens viewer (default-unit-lens-setter updater) updater `(=>bring ,yes?))
        ))

    (define (=>assoc-by =>find equal? key)
      ;; Use the given `=>FIND` procedure, which must be either `=>FIND`
      ;; or `=>BRING`, or some derivation thereof, and pass it a
      ;; predicate that tests the `CAR` of each pair of an association
      ;; list to see if it is `EQUAL?` to the given `KEY`. If an
      ;; association pair is found by that predicate `view` will return
      ;; the `CDR` of the pair, where `UPDATE&VIEW` will update the `CDR` of
      ;; the pair.
      ;;------------------------------------------------------------------
      (let*((predicate
             (lambda (pair) (and (pair? pair) (equal? key (car pair)))))
            (=>ulens (=>find predicate))
            (viewer (endo-view =>ulens))
            (setter (lambda (rec val) (lens-set (cons key val) rec =>ulens)))
            (updater
             (lambda (up rec)
               (update&view
                (lambda (rec)
                  (let-values
                      (((elem return) (up (if (null? rec) #f (cdr rec)))))
                    (values (if elem (cons key elem) '()) return)
                    ))
                rec =>ulens)))
            )
        (unit-lens viewer setter updater `(=>assoc-by ,=>find ,equal? ,key))))

    (define (=>assoc key)
      ;; A convenient shorthand for `(=>ASSOC-BY =>FIND EQUAL?)`
      ;;------------------------------------------------------------------
      (=>assoc-by =>find equal? key))

    (define (=>assv key)
      ;; A convenient shorthand for `(=>ASSOC-BY =>FIND EQV?)`.
      ;;------------------------------------------------------------------
      (=>assoc-by =>find eqv? key))

    (define (=>assq key)
      ;; A convenient shorthand for `(=>ASSOC-BY =>FIND EQ?)`.
      ;;------------------------------------------------------------------
      (=>assoc-by =>find eq? key))

    ;; -------------------------------------------------------------------------------------------------

    (define (=>guard rule . rules)
      ;; This function constructs a lens from a list guard lenses. Each
      ;; guard is a list which must begin with a predicate, and after that
      ;; there must be zero or more other lens items. When the predicate
      ;; of a guard list matches, the remaining list items construct a
      ;; `compound-lens` that is used to view, set, or update.
      ;;------------------------------------------------------------------
      (let*((rules (cons rule rules))
            (by
             (lambda (rec)
               (lambda (item)
                 (cond
                  ((pair? item) ((car item) rec))
                  ((null? item) #f)
                  (else (error "cannot construct guard from non-list elements" item))
                  ))))
            (=>ulens
             (lambda (rec)
               (let ((found (view rules (=>find (by rec)) =>cdr)))
                 (cond
                  ((not found)
                   (error "no guard to handle record of given type" rec))
                  (else
                   (cond
                    ((null? found) =>self)
                    ((pair? found) (apply lens found))
                    (else (error "guard not cons'ed to list of lenses" found))
                    )))
                 ))))
        (unit-lens
         (lambda (rec) (view rec (=>ulens rec)))
         (lambda (rec val) (lens-set val rec (=>ulens rec)))
         (lambda (up rec) (update&view up rec (=>ulens rec)))
         (list
          '=>guard
          (map (lambda (lenses)
                 (cons (car lenses) (map lens->expr (cdr lenses))))
               rules)))
        ))

    ;; -------------------------------------------------------------------------------------------------

    (define =>self
      ;; The identity lens, operates on the record-in-focus itself.
      ;;------------------------------------------------------------------
      (unit-lens
       (lambda (record-in-focus) record-in-focus)
       (lambda (_ new-info) new-info)
       (lambda (updater record-in-focus) (updater record-in-focus))
       '=>self))

    (define (=>const val)
      ;; This lens operates on any data at all, but when applied to
      ;; `VIEW`, it always returns the value with which it was
      ;; constructed. When applied to `UPDATE&VIEW` or `LENS-SET`, it does
      ;; nothing. The updater procedure applied to `UPDATE&VIEW` is still
      ;; evaluated so it can produce the second return value.
      ;;------------------------------------------------------------------
      (unit-lens
       (lambda (rec) val)
       (lambda (rec _) rec)
       (lambda (updater rec)
         (let-values (((_ return) (updater val)))
           (values rec return)))
       `(=>const ,val)))


    (define =>false
      ;; A shorthand for defined as `(=>CONST #F)`
      ;;------------------------------------------------------------------
      (=>const #f))


    (define =>true
      ;; A shorthand for defined as `(=>CONST #T)`
      ;;------------------------------------------------------------------
      (=>const #t))


    (define (=>on-update lens filter)
      ;; This is similar to the =>SELF (identity) lens and behaves the
      ;; same as =>SELF when VIEW-ing the record in focus, but when
      ;; `UPDATE&VIEW`-ing, after the update has completed, this function
      ;; evlauates a `FILTER` function on the updated record in
      ;; focus. This allows the `FILTER` action to be triggered to modify
      ;; the record in focus every time the information pointed to by the
      ;; given `LENS` is changed. Some example use cases for this:
      ;; 
      ;;   1. to re-balance a tree after inserting items
      ;;   2. to sort a list or vector after changing elements within
      ;; 
      ;; The update occurs on the whole record (the outer-most record)
      ;; that `LENS` is inspecting, and not the information within the
      ;; record that is viewed or updated by the lens, again it is mostly
      ;; similar to the `=>SELF` lens.
      ;;------------------------------------------------------------------
      (unit-lens
       (lambda (record-in-focus) (view record-in-focus lens))
       (lambda (record-in-focus new-info)
         (filter (lens-set new-info record-in-focus lens)))
       (lambda (updater record-in-focus)
         (let-values
             (((record-in-focus return) (update&view updater record-in-focus lens)))
           (values (filter record-in-focus) return)))
       (list '=>on-update (lens->expr lens))))


    (define (=>canonical lens new-empty empty?)
      ;; This function defines a lens which can compose with another LENS
      ;; taken as an argument such that if the record in focus is `#F`, it
      ;; is treated as an empty record rather than raising an exception.
      ;; It is called `=>CANONICAL` because this allows records containing
      ;; all empty fields to be reduced to a single #f value, and also
      ;; allows new empty records to be constructed in place of an #f
      ;; value when the times comes to store new non-empty value into the
      ;; structure, thus allowing the lenses to grow or shrink data
      ;; structures as needed. How it works is is straight forward: the
      ;; `=>CANONICAL` lens first performs checks on the record in focus
      ;; to see if it is #f, and if so, simply returns #f rather than
      ;; evaluating the getter of the `LENS`. On `UPDATE&VIEW` or
      ;; `LENS-SET` if the record-in-focus is #f, the `NEW-EMPTY` thunk is
      ;; evaluated to produce a new node which can then be updated. If the
      ;; update removes fields from the record and the record in focus
      ;; becomes empty according to the EMPTY?  predicate the record is
      ;; again reduced to #f.
      ;; 
      ;; Passing `=>SELF` as the `LENS` argument `to` `=>CANONICAL` and
      ;; composing it with a `RECORD-UNIT-LENS` is a good way to create
      ;; records that change to `#F` as soon as the `EMPTY?` predicate
      ;; returns `#T`.
      ;;
      ;; NOTE that `=>CANONICAL` will prevent accessors from raising
      ;; exceptions when the current record in focus is #f, but this does
      ;; not prevent lenses composed with this one from doing so. Once you
      ;; use a `=>CANONICAL` lens, it is a good idea to use `=>CANONICAL`
      ;; lenses throughout the composition of lenses.
      ;;
      ;; NOTE that by convention, symbols for canonicalized lenses should
      ;; end in an asterisk, and if the lens mutates the container object
      ;; (is non-pure), the asterisk should come before the "bang" mark.
      ;;
      ;; Here is a quick overview of the symbol naming conventions.
      ;;
      ;;    `=>impure-lens*!` :: mutates the target, and is not canonical
      ;;    `=>pure-lens*`    :: replaces the target, and is not canonical
      ;;    `=>impure-lens!`  :: mutates the target, and is canonical
      ;;    `=>pure-lens`     :: replaces the target, and is canonical
      ;;------------------------------------------------------------------
      (unit-lens
       ;; ---------- getter ----------
       (lambda (record-in-focus)
         (if (not record-in-focus) #f (view record-in-focus lens)))
       ;; ---------- setter ----------
       (lambda (record-in-focus new-info)
         (let*((record-in-focus
                (if (not record-in-focus) (new-empty) record-in-focus))
               (result (lens-set new-info record-in-focus lens)))
           (if (or (not result) (empty? result)) #f result)))
       ;; ---------- updater ----------
       (lambda (updater record-in-focus)
         (let-values
             (((record-in-focus return)
               (update&view updater (if (not record-in-focus) (new-empty) record-in-focus) lens)))
           (values
            (cond
             ((and record-in-focus (empty? record-in-focus)) #f)
             (else record-in-focus))
            return)))
       (list '=>canonical (lens->expr lens))))


    (define (=>encapsulate lens label)
      ;; Defines a new <UNIT-LENS-TYPE> that encapsulates a <LENS-TYPE>.
      ;;------------------------------------------------------------------
      (cond
       ((%unit-lens-type? lens)
        (unit-lens
         (unit-lens-getter lens)
         (unit-lens-setter lens)
         (unit-lens-updater lens)
         label))
       ((%lens-type? lens)
        (unit-lens
         (lambda (record-in-focus) (view record-in-focus lens))
         (lambda (record-in-focus new-info) (lens-set new-info record-in-focus lens))
         (lambda (updater record-in-focus) (update&view updater record-in-focus lens))
         label))
       (else
        (error "=>encapsulate function argument ~a not a <UNIT-LENS-TYPE> or <LENS-TYPE>" lens))))

    ;; -------------------------------------------------------------------------------------------------

    (cond-expand
      ((or guile stklos (library (srfi 111)))
       (define =>box
         ;; Define a lens that updates a box object (see SRFI-111). This will
         ;; work on any closure which takes zero or one argument and which
         ;; updates a value within the closure when one argument is given.
         ;;------------------------------------------------------------------
         (unit-lens
          (lambda (record-in-focus) (unbox record-in-focus))
          (lambda (record-in-focus new-info) (set-box! record-in-focus new-info))
          (lambda (updater record-in-focus)
            (let-values (((result return) (updater (unbox record-in-focus))))
              (set-box! record-in-focus result)
              (values record-in-focus return)))
          '=>box)))
      (else))


    (define =>view-only-lens
      ;; Define a view-only (read-only) lens which fails silently if an
      ;; update is made to the record in focus.
      ;;
      ;; View-only lenses are useful when using the LENS procedure to
      ;; compose the view-only lens with other lenses in which the
      ;; read-only field is in an immutable object with an field
      ;; referencing an inner mutable object, and the view-only lens is
      ;; composed with a second lens mutates the inner mutable object.
      ;;
      ;; For example:
      ;;
      ;; ```
      ;; (define-record-type <immutable-thing-type>
      ;;   (immutable-thing a b)
      ;;   immutable-thing-type?
      ;;   (a  first-thing)
      ;;   (b  second-thing))
      ;;
      ;; (define =>first  (=>view-only-lens first-thing))
      ;; (define =>second (=>view-only-lens second-thing))
      ;;
      ;; (define-record-type <vec2D-type>
      ;;   (vec2D x y)
      ;;   (x  vec2D-x  set!vec2D-x)
      ;;   (y  vec2D-y  set!vec2D-y))
      ;;
      ;; (define =>vec2D-x! (record-unit-type vec2D-x set!vec2D-x))
      ;; (define =>vec2D-y! (record-unit-type vec2D-y set!vec2D-y))
      ;;
      ;; (define example (immutable-thing (vec2D 0 0) (vec2D 1 1)))
      ;;
      ;; (lens-set 4 example =>first-thing =>vec2D-x)
      ;; ```
      ;;------------------------------------------------------------------
      (case-lambda
        ((viewer) (=>view-only-lens viewer #f))
        ((viewer sym)
         (unit-lens
          viewer
          (lambda (record-in-focus new-info) record-in-focus)
          (lambda (updater record-in-focus)
            (let-values (((_ result) (updater (viewer record-in-focus))))
              (values record-in-focus result)))
          (list '=>view-only-lens (if sym sym viewer))))))

    ;; -------------------------------------------------------------------------------------------------

    (define =>trace
      ;; Construct a new debugging lens from another lens. The debugging
      ;; lens installs exception handlers. Two optional arguments
      ;; (optional in that you may pass #f as these arguments). The first
      ;; optional argument is PORT which is used as an argument to
      ;; `DISPLAY` to capture log output, the debugger reports on every
      ;; event that occurs as it is used to view or update records. The
      ;; second optional argument is a CONTINUATION constructed with
      ;; `CALL/CC` which is called with an ERROR object when an exception
      ;; is caught. If the CONTINUATION object is not provided, the ERROR
      ;; object is re-`RAISE`d.
      ;;------------------------------------------------------------------
      (case-lambda
        ((lens) (=>trace lens (current-output-port) #f))
        ((lens port) (=>trace lens port #f))
        ((lens port continuation)
         (let ((port (if port port (current-output-port))))
           (unit-lens
            ;; ---------- viewer ----------
            (lambda (record-in-focus)
              (display
               (format
                "(begin view on ~a:\n  #:record-in-focus (~a))\n"
                (lens->expr lens) record-in-focus)
               port)
              (with-exception-handler
                  (lambda (err)
                    (display
                     (format
                      "(error in view on ~a:\n  #:error ~a\n  #:record-in-focus (~a))\n"
                      (lens->expr lens) err record-in-focus)
                     port)
                    (if continuation (continuation err) (raise err)))
                (lambda ()
                  (let ((result (view record-in-focus lens)))
                    (display
                     (format
                      "(return from view on ~a:\n  #:record-in-focus (~a)\n  #:result (~a))\n"
                      (lens->expr lens) record-in-focus result)
                     port)
                    result))))
            ;; ---------- setter ----------
            (lambda (record-in-focus new-info)
              (display
               (format
                "(begin set! on ~a:\n  #:new-info (~a) #:record-in-focus (~a))\n"
                (lens->expr lens) new-info record-in-focus)
               port)
              (with-exception-handler
                  (lambda (err)
                    (display
                     (format
                      "(error in set! on ~a\n  #:error ~a\n  #:new-info (~a)\n  #:record-in-focus (~a))\n"
                      (lens->expr lens) err
                      new-info record-in-focus)
                     port)
                    (if continuation (continuation err) (raise err)))
                (lambda ()
                  (let ((result (lens-set new-info record-in-focus lens)))
                    (display
                     (format
                      "(return from set! on ~a:\n  #:new-info (~a)\n  #:record-in-focus (~a)\n  #:result (~a))\n"
                      (lens->expr lens) new-info record-in-focus result)
                     port)
                    result))))
            ;; ---------- updater ----------
            (lambda (updater record-in-focus)
              (display
               (format
                "(begin update&view on ~a:\n  #:record-in-focus (~a))\n"
                (lens->expr lens) record-in-focus)
               port)
              (with-exception-handler
                  (lambda (err)
                    (display
                     (format
                      "(error in update&view ~a:\n  #:error ~a\n  #:record-in-focus (~a))\n"
                      (lens->expr lens) err record-in-focus)
                     port)
                    (if continuation (continuation err) (raise err)))
                (lambda ()
                  (let-values (((result return) (update&view updater record-in-focus lens)))
                    (display
                     (format
                      "(return from update&view ~a:\n  #:record-in-focus (~a)\n  #:result (~a)\n  #:return (~a))\n"
                      (lens->expr lens) record-in-focus result return)
                     port)
                    (values result return)))))
            (lens->expr lens))))))


    (define (fail-if-incorrect-type record-in-focus =>lens correct-type? quoted-correct-type)
      (cond
       ((correct-type? record-in-focus) #f)
       (else
        (raise
         (error
          (format
           "assert failed for lens ~a, expecting ~a, record-in-focus is ~a"
           (lens->expr =>lens) quoted-correct-type record-in-focus))))))


    (define (=>assert =>lens correct-type? quoted-correct-type)
      (let ((assert-here
             (lambda (record-in-focus)
               (fail-if-incorrect-type
                record-in-focus =>lens correct-type? quoted-correct-type))))
        (unit-lens
         (lambda (record-in-focus)
           (unless (assert-here record-in-focus)
             (view record-in-focus =>lens)))
         (lambda (record-in-focus new-info)
           (unless (assert-here record-in-focus)
             (lens-set new-info record-in-focus =>lens)))
         (lambda (updater record-in-focus)
           (unless (assert-here record-in-focus)
             (update&view updater record-in-focus =>lens)))
         (list '=>assert (lens->expr =>lens)))))

    ;; -------------------------------------------------------------------------------------------------

    (define (local-listbox)
      (let ((listbox '()))
        (case-lambda
          (() listbox)
          ((up) (set! listbox (up listbox)) (values))
          )))

    (define *integer-indexable* (local-listbox))
    (define *string-indexable* (local-listbox))
    (define *symbol-indexable* (local-listbox))

    (define (indexing-rules-by-type t)
      (cond
       ((eq? t integer?) *integer-indexable*)
       ((eq? t string?)  *string-indexable*)
       ((eq? t symbol?)  *symbol-indexable*)
       ((eq? t 'integer) *integer-indexable*)
       ((eq? t 'string)  *string-indexable*)
       ((eq? t 'symbol)  *symbol-indexable*)
       (else (error "cannot construct lens indexing rules for given type" t))
       ))

    (define (lookup-listbox listbox)
      (lambda (rec)
        (let*((found (view (listbox) (=>find (lambda (item) ((car item) rec))))))
          (if found (cdr found) #f))))

    (define integer-lens-for (lookup-listbox *integer-indexable*))
    (define string-lens-for (lookup-listbox *string-indexable*))
    (define symbol-lens-for (lookup-listbox *symbol-indexable*))


    (define (get-rule-declaration/index->lens index-type rec)
      ;; This procedure returns the indexing rules that have been declared
      ;; for an index type `INDEX-TYPE` (where `INDEX-TYPE` **must** be
      ;; one of `'INTEGER`, `'STRING`, or `'SYMBOL`) which would work on
      ;; the given record `REC`. If you want to see if you can use apply a
      ;; lens operation to a data type with an integer, string, or symbol
      ;; as the lens, you use this function to lookup the index->lens
      ;; conversion rule.
      ;;
      ;; For example if you have a vector-like object "vec32" and want to
      ;; see if it is possilbe to index this object with an integer-valued
      ;; index, you can evaluate:
      ;;
      ;;    (get-rule-declaration/index->lens 'integer vec32)
      ;;
      ;; and if that returns non-null, then it is OK to index your "vec32"
      ;; with the expression:
      ;;
      ;;    (view vec32 5)
      ;;------------------------------------------------------------------
      ((lookup-listbox (indexing-rules-by-type index-type)) rec))


    (define (declare-rule/index->lens index-type record-type-predicate lens-constructor)
      ;; Call this procedure at the top-level of your program to update
      ;; the global list of record data types that for which `VIEW`,
      ;; `UPDATE&VIEW`, and other lens operations will recognize as data type
      ;; that can be indexed by integer values. This declaration takes 3
      ;; arguments:
      ;;
      ;;  1. `INDEX-TYPE`: specify what type of index values can you
      ;;     construct with `LENS-CONSTRUCTOR`. This argument must be a
      ;;     symbol `'INTEGER`, `'STRING`, or `'SYMBOL`, or it can take
      ;;     the predicates `INTEGER?`, `STRING?`, or `SYMBOL?` as well.
      ;;
      ;;  2. `RECORD-TYPE-PREDICATE`: a predicate that returns `#T` if the
      ;;      `RECORD-IN-FOCUS` is of a type that can be indexed by
      ;;      values of the `INDEX-TYPE`.
      ;;
      ;;  3. `LENS-CONSTRUCTOR`: a procedure that takes a single integer
      ;;     argument and constructs a `LENS` that can focus the record at
      ;;     that integer index.
      ;;------------------------------------------------------------------
      (let ((listbox (indexing-rules-by-type index-type)))
        (cond
         ((not (procedure? record-type-predicate))
          (error "indexing declaration did not specify a valid predicate type"
                 record-type-predicate))
         ((not (procedure? lens-constructor))
          (error "indexing declaration did not specify a lens constructor"
                 lens-constructor))
         (else
          (listbox
           (endo-set lens-constructor
            (=>assoc-by =>bring eq? record-type-predicate)))))
        ))

    ;;----------------------------------------------------------------
    ))
