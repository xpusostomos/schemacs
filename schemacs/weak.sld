(define-library (schemacs weak)

  ;; This library exists to provide a uniform interface to weak
  ;; collections - sets of objects that do not keep their members
  ;; alive - which no Scheme standard below R7RS-large has, and which
  ;; implementations spell differently. APIs exported here can be
  ;; imported exactly once per environment elsewhere in this program
  ;; without having to write a `COND-EXPAND` statement everywhere one
  ;; of these APIs is used. It is the same arrangement, for the same
  ;; reason, as `(SCHEMACS VECTOR)'.
  ;;
  ;; The engine needs one for its marker chain: GNU Emacs keeps each
  ;; buffer's markers in a chain that does NOT keep them alive (its
  ;; collector prunes the chain during the sweep), which is what makes
  ;; it safe for any code - including ported Emacs Lisp - to create
  ;; markers freely. A Scheme implementation has no sweep hook, so the
  ;; only way to get that behaviour is for the chain itself to hold its
  ;; members weakly. See the "Markers" section of the engine for what
  ;; it is used for.

  (import
    (scheme base)
    (scheme case-lambda)
    )

  (export
   new-weak-set
   weak-set?
   weak-set-add!
   weak-set-delete!
   weak-set-for-each
   weak-set-member?
   weak-set-size

   ;; A table rather than a set: an object mapped to a value, where the
   ;; object is held weakly and goes with its value when it is collected.
   ;; `(SCHEMACS EDITOR BUFFER)' needs one for the slots that belong to a
   ;; buffer without being part of the engine's record - its keymap and
   ;; its buffer-local variables. GNU Emacs keeps those *in* the buffer
   ;; struct so the collector can see them; a side table has to be weak or
   ;; it would keep every killed buffer alive.
   new-weak-table
   weak-table?
   weak-table-ref
   weak-table-set!
   weak-table-delete!
   weak-table-for-each
   weak-table-keys
   )

  (cond-expand

    (guile
     (import
       (only (guile)
             make-doubly-weak-hash-table  make-weak-key-hash-table
             hashq-set!  hashq-ref  hashq-remove!  hash-for-each  hash-fold
             hash-table?)))

    (else))

  (begin

    (cond-expand

      (guile

       (define (new-weak-set)
         ;; A set of objects that does not keep them alive: an object
         ;; that nothing else refers to is collected, and its place in
         ;; the set goes with it.
         ;;
         ;; A doubly-weak hash table keyed by identity is exactly that:
         ;; the key is held weakly, so an unreachable member is dropped
         ;; on the next collection, and the value is a constant, which
         ;; cannot be dropped. Guile takes its weak tables with the
         ;; ordinary `HASHQ-*' procedures.
         ;;--------------------------------------------------------------
         (make-doubly-weak-hash-table))

       (define (weak-set? thing) (hash-table? thing))

       (define (weak-set-add! set member)
         (hashq-set! set member #t)
         member)

       (define (weak-set-delete! set member)
         (hashq-remove! set member))

       (define (weak-set-member? set member)
         (and (hashq-ref set member) #t))

       (define (weak-set-for-each proc set)
         (hash-for-each (lambda (member _) (proc member)) set))

       (define (weak-set-size set)
         ;; Note that Guile's `HASH-COUNT' refuses a weak table, so the
         ;; members are counted by walking them.
         ;;--------------------------------------------------------------
         (hash-fold (lambda (_member _value count) (+ 1 count)) 0 set))

       (define (new-weak-table)
         ;; A key held weakly, its value held strongly: the entry is
         ;; dropped when nothing else refers to the key, and the value
         ;; goes with it. That is what makes it safe to hang a buffer's
         ;; own state off a table keyed by the buffer.
         ;;--------------------------------------------------------------
         (make-weak-key-hash-table))

       (define (weak-table? thing) (hash-table? thing))

       (define (weak-table-ref table key default)
         (let ((value (hashq-ref table key #f)))
           (if value value default)))

       (define (weak-table-set! table key value)
         (hashq-set! table key value)
         value)

       (define (weak-table-delete! table key)
         (hashq-remove! table key))

       (define (weak-table-for-each proc table)
         (hash-for-each (lambda (key value) (proc key value)) table))

       (define (weak-table-keys table)
         (hash-fold (lambda (key _value acc) (cons key acc)) '() table)))

      (else

       ;; Without weak collections the set holds its members as any
       ;; other collection would, so a member stays in it until
       ;; `WEAK-SET-DELETE!' is called: the engine's marker chain then
       ;; needs `SET-MARKER!' with no buffer to take a marker out of it.
       ;;--------------------------------------------------------------
       (define (new-weak-set) (list 'weak-set))

       (define (weak-set? thing)
         (and (pair? thing) (eq? 'weak-set (car thing))))

       (define (weak-set-add! set member)
         (set-cdr! set (cons member (cdr set)))
         member)

       (define (weak-set-delete! set member)
         (let loop ((rest (cdr set)) (seen '()))
           (cond
            ((null? rest) (set-cdr! set (reverse seen)))
            ((eq? (car rest) member) (set-cdr! set (append (reverse seen) (cdr rest))))
            (else (loop (cdr rest) (cons (car rest) seen))))))

       (define (weak-set-member? set member)
         (let loop ((rest (cdr set)))
           (cond ((null? rest) #f)
                 ((eq? (car rest) member) #t)
                 (else (loop (cdr rest))))))

       (define (weak-set-for-each proc set)
         (for-each proc (cdr set)))

       (define (weak-set-size set) (length (cdr set)))

       ;; Without weak collections the table holds its keys as any other
       ;; collection would, so an entry stays until it is deleted: a
       ;; killed buffer's slots are then freed by `WEAK-TABLE-DELETE!'
       ;; rather than by the collector.
       ;;--------------------------------------------------------------
       (define (new-weak-table) (list 'weak-table))

       (define (weak-table? thing)
         (and (pair? thing) (eq? 'weak-table (car thing))))

       (define (weak-table-ref table key default)
         (let ((entry (assq key (cdr table))))
           (if entry (cdr entry) default)))

       (define (weak-table-set! table key value)
         (let ((entry (assq key (cdr table))))
           (if entry
               (set-cdr! entry value)
               (set-cdr! table (cons (cons key value) (cdr table)))))
         value)

       (define (weak-table-delete! table key)
         (set-cdr! table
                   (let loop ((rest (cdr table)))
                     (cond ((null? rest) '())
                           ((eq? (caar rest) key) (cdr rest))
                           (else (cons (car rest) (loop (cdr rest))))))))

       (define (weak-table-for-each proc table)
         (for-each (lambda (entry) (proc (car entry) (cdr entry)))
                   (cdr table)))

       (define (weak-table-keys table)
         (map car (cdr table)))))

    ))
