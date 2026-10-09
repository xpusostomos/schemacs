(define-library (schemacs hash-table)

  ;; This library exists to provide a uniform interface to common APIs
  ;; that might be defined in different places depending on which
  ;; Scheme implementation is running this code. APIs exported here
  ;; can be imported exactly once per environment elsehwere in this
  ;; program without having to write a `COND-EXPAND` statement
  ;; everywhere one of these APIs are used.
  ;;
  ;; NOTE that the function of this library is *not* to provide all
  ;; of the SRFI 125 API, but is to provide only the SRFI 125 APIs
  ;; that are used by the Schemacs project.

  ;; EXPORTS
  (export
   make-hash-table
   hash-table
   default-hash 
   string-hash  string-ci-hash
   alist->hash-table
   hash-table-unfold

   hash-table-empty?
   hash-table->alist
   hash-table-keys
   hash-table-values
   hash-table-copy
   hash-table-delete!
   hash-table-fold
   hash-table-ref
   hash-table-ref/default
   hash-table-set!
   hash-table-size
   hash-table-update!
   hash-table-update!/default
   hash-table-for-each
   hash-table-walk
   hash-table?

   ;; other helper functions
   make-integer-comparator
   make-string-comparator
   make-string-ci-comparator
   )

  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme char) string-ci=? string-ci<?)
    (only (schemacs comparator)
          comparator?
          make-comparator
          make-equal-comparator
          make-eqv-comparator
          make-eq-comparator
          make-default-comparator
          comparator-equality-predicate
          comparator-hash-function
          ))

  (cond-expand
   ((not lispkit)
    (import
     (only (schemacs comparator)
           string-hash
           string-ci-hash
           ))))

  (cond-expand
   ((and
     (or guile gambit (library (srfi 69)))
     (not (library (srfi 125)))
     )
    (import
     (only (srfi 69)
           hash-table->alist
           hash-table-keys
           hash-table-values
           hash-table-copy
           hash-table-delete!
           hash-table-fold
           hash-table-ref
           hash-table-ref/default
           hash-table-size
           hash-table-update!
           hash-table-update!/default
           hash-table-walk
           hash-table?
           hash
           )
     (rename (srfi 69)
             (hash-table-set!  srfi69:ht-set!)
             (make-hash-table srfi69:make-hash-table)
             (alist->hash-table srfi69:alist->hash-table)
             ))

    (begin

      (define default-hash
        (case-lambda
         ((a) (hash a))
         ((a b) (hash a))
         ))
      (define (hash-table-empty? ht) (= 0 (hash-table-size ht)))
      (define (hash-table-for-each proc ht) (hash-table-walk ht proc))

      (define %mk-hash-table
        (case-lambda
         (() (%mk-hash-table (make-default-comparator)))
         ((comp)
          (cond
           ((comparator? comp)
            (srfi69:make-hash-table
             (comparator-equality-predicate comp)
             (comparator-hash-function comp)
             ))
           ((procedure? comp) (%mk-hash-table comp #f))
           ))
         ((equal hash . _ignored)
          (cond
           ((not hash)
            (cond
             ((eq? equal equal?)      (%mk-hash-table (make-equal-comparator)))
             ((eq? equal eq?)         (%mk-hash-table (make-eq-comparator)))
             ((eq? equal eqv?)        (%mk-hash-table (make-eqv-comparator)))
             ((eq? equal string=?)    (%mk-hash-table (make-string-comparator)))
             ((eq? equal string-ci=?) (%mk-hash-table (make-string-ci-comparator)))
             ((eq? equal symbol=?)    (%mk-hash-table (make-eq-comparator)))
             ((eq? equal =)           (%mk-hash-table (make-integer-comparator)))
             (else (error "unknown equality predicate" equal))
             ))
           (else
            (make-comparator
             #t equal (lambda _ (error "ordering not supported")) hash
             ))))))

      (define (hash-table-set! ht . args)
        (let loop ((args args))
          (cond
           ((null? args) (values))
           (else
            (let ((key  (car args))
                  (tail (cdr args))
                  )
              (cond
               ((null? tail)
                (error "no value associated with key" key)
                )
               (else
                (let ((value (car tail)))
                  (srfi69:ht-set! ht key value)
                  (loop (cdr tail))
                  ))))))))

      (define (hash-table comp . pairs)
        (let ((ht (make-hash-table comp)))
          (let loop ((pairs pairs))
            (cond
             ((null? pairs) ht)
             ((pair? pairs)
              (let*((key (car pairs))
                    (more (cdr pairs))
                    (val (if (pair? more) (car more) #f))
                    )
                (srfi69:ht-set! ht key val)
                (loop (cdr more))
                ))
             (error "not a list of pairs" pairs)
             ))))

      (define (%alist->hash alist comp)
        (srfi69:alist->hash-table
         alist
         (comparator-equality-predicate comp)
         (comparator-hash-function comp)
         ))

      (define (hash-table-unfold stop? mapper successor seed comparator . args)
        (let ((ht (apply make-hash-table comparator args)))
          (let loop ((seed seed))
            (cond
             ((stop? seed) ht)
             (else
              (let-values (((key value) (mapper seed)))
                (srfi69:ht-set! ht key value)
                (loop (successor seed))
                ))))))

      ))

   ((and (library (srfi 125))
         (library (srfi 128))
         )
    (import
     (rename (srfi 125)
             (make-hash-table    srfi125:make-hash-table)
             (alist->hash-table  srfi125:alist->hash-table)
             )
     (only (srfi 125)
           hash-table
           hash-table-unfold
           hash-table-empty?
           hash-table->alist
           hash-table-keys
           hash-table-values
           hash-table-copy
           hash-table-delete!
           hash-table-fold
           hash-table-ref
           hash-table-ref/default
           hash-table-set!
           hash-table-size
           hash-table-update!
           hash-table-update!/default
           hash-table-for-each
           hash-table-walk
           hash-table?
           )
     (only (srfi 128)
           default-hash
           make-default-comparator
           ))
    (begin
      (define %mk-hash-table srfi125:make-hash-table)
      (define %alist->hash   srfi125:alist->hash-table)
      ))
   )

  (begin

    (define make-hash-table
      (case-lambda
       (() (%mk-hash-table (make-default-comparator)))
       ((comp . args) (apply %mk-hash-table comp args))
       ))

    (define alist->hash-table
      (case-lambda
       ((alist) (%alist->hash alist (make-default-comparator)))
       ((alist comp . args) (apply %alist->hash alist comp args))
       ))

    (define (make-integer-comparator)
      (make-comparator integer? = < (lambda (x) x))
      )

    (define (make-string-comparator)
      (make-comparator string? string=? string<? string-hash)
      )

    (define (make-string-ci-comparator)
      (make-comparator string? string-ci=? string-ci<? string-hash)
      )

    ))
