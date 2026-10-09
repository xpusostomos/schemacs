(import
  (scheme base)
  (scheme cxr)
  (schemacs lens)
  (only (schemacs comparator) make-default-comparator)
  (only (schemacs hash-table)
        hash-table?  default-hash  string-hash
        hash-table-set!
        make-hash-table
        hash-table-size
        alist->hash-table
        hash-table->alist
        hash-table-for-each
        make-string-comparator
        )
  (only (srfi 64) test-begin test-end test-skip test-error
        test-assert test-equal test-eqv test-eq)
  )

;; -------------------------------------------------------------------------------------------------

(test-begin "schemacs_lens")

(test-equal (cons 1 '()) (lens-set 1 #f =>car))
(test-equal (cons '() 2) (lens-set 2 #f =>cdr))

(define =>list3-first  (lens =>car))
(define =>list3-second (lens =>cdr =>car))
(define =>list3-third  (lens =>cdr =>cdr =>car))
(define =>list3-end    (lens =>cdr =>cdr =>cdr))
(define list3
  (let*((a #f)
        (a (lens-set   1 a =>list3-first))
        (a (lens-set   2 a =>list3-second))
        (a (lens-set   3 a =>list3-third)))
    a))

(test-equal '(1 2 3) list3)
(test-equal 1 (view list3 =>list3-first))
(test-equal 2 (view list3 =>list3-second))
(test-equal 3 (view list3 =>list3-third))
(test-assert (null? (view list3 =>list3-end)))

(test-equal 3 (lens-unit-count =>list3-third))
(test-equal 2 (lens-unit-count =>list3-second))
(test-equal 1 (lens-unit-count =>list3-first))
(test-equal 9 (lens-unit-count (lens =>list3-end =>list3-end =>list3-third)))

(define tt (make-hash-table (make-default-comparator)))
(define (=>tt-key key) (=>hash-key*! key))

(define h (alist->hash-table '(("one" . 1) ("zero" . 0)) (make-string-comparator)))

(define h2
  (alist->hash-table
   `(("one" . 1)
     ("zero" .
      ,(alist->hash-table
        `(("two" .
           ,(alist->hash-table
             '(("four" . 4)
               ("five" . 5))
             (make-string-comparator)
             ))
          ("three" . 3))
        (make-string-comparator)
        )))
   (make-string-comparator)
   ))

(test-equal 0 (view h (=>tt-key "zero")))
(test-equal 1 (view h (=>tt-key "one")))
(lens-set 111 h (=>tt-key "one"))

(test-equal 111 (view h (=>tt-key "one")))

(set! h
  (let*((h #f)
        (h (lens-set 1 h (=>hash-key! "one")))
        (h (lens-set 0 h (=>hash-key! "zero"))))
    h))

(test-assert
    (let ((a (hash-table->alist h)))
      (or
       (equal? a '(("zero" . 0) ("one" . 1)))
       (equal? a '(("one" . 1) ("zero" . 0)))))
  )

(test-equal 1 (view h (=>hash-key! "one")))
(test-equal 0 (view h (=>hash-key! "zero")))

(test-equal
    '(("one" . 1))
  (let*((h (unit-lens-set #f h (=>tt-key "zero"))))
    (hash-table->alist h))
  )

;; Test canonicalized hash keys

(test-equal 1 (view h2 (=>hash-key! "one")))
(test-equal 4
  (view
   h2 (=>hash-key! "zero")
      (=>hash-key! "two")
      (=>hash-key! "four")))

(define-values (_ result)
  (update&view (lambda _ (values #f #f))
   h2 (=>hash-key! "zero")
      (=>hash-key! "two")
      (=>hash-key! "four")))

(test-assert
    (not
     (view
      h2 (=>hash-key! "zero")
         (=>hash-key! "two")
         (=>hash-key! "four"))))

(test-equal '(("five" . 5))
  (hash-table->alist
   (view h2 (=>hash-key! "zero") (=>hash-key! "two"))))

(lens-set #f h2 (=>hash-key! "zero") (=>hash-key! "two"))

(test-equal '(("three" . 3))
  (hash-table->alist (view h2 (=>hash-key! "zero"))))

(lens-set #f h2 (=>hash-key! "one"))
(lens-set #f h2 (=>hash-key! "zero"))

(test-assert (null? (hash-table->alist h2)))

(lens-set 5 h2 (=>hash-key! "zero") (=>hash-key! "two") (=>hash-key! "five"))
(test-equal 5 (view h2 (=>hash-key! "zero") (=>hash-key! "two") (=>hash-key! "five")))
(test-equal 5 (view h2 "zero" "two" "five"))

(lens-set
 (vector
  "zero" "one"
  (lens-set
   "how are you" (make-hash-table (make-string-comparator)) "hello"
   )
  "three"
  )
 h2 "zero" "three"
 )

(test-equal "one" (view h2 "zero" "three" 1))
(test-equal "how are you" (view h2 "zero" "three" 2 "hello"))

(test-equal (vector 1 2 3)
  (lens-set
   1 (lens-set
      2 (lens-set
         3 #f (=>vector-index! 2))
      (=>vector-index! 1))
   (=>vector-index! 0))
  )

;; -------------------------------------------------------------------------------------------------

(define ht
  (alist->hash-table
   `(("zero" . 0)
     ("one"  . 1)
     ("two"  . 2)
     ("AB" .
      ,(alist->hash-table
        `(("A" . "go-left")
          ("B" . "go-right")
          ("vec" .
          ,(vector
            (alist->hash-table ;; at index 0
             `(("C" . "go-up")
               ("D" . "go-down"))
             (make-string-comparator)
             )
            (alist->hash-table ;; at index 1
             '(("E" . "turn-around")
               ("F" . "jump"))
             (make-string-comparator)
             )
            #f ;; at index 2
            )))
        (make-string-comparator)
        )))
   (make-string-comparator)
   ))

(test-equal 0 (view ht "zero"))
(test-equal "go-left" (view ht "AB" "A"))
(test-equal "go-up" (view ht "AB" "vec" 0 "C"))
(test-equal #f (view ht "AB" "vec" 2))

;; --- Use the "lens-set" procedure to update elements ---
;;
;; The order of the arguments are:
;;
;;  1. the value to be inserted into the data structure
;;  2. the data structure to be updated
;;  3. zero or more lenses which can update the data structure

(lens-set '(20 30 40) ht "AB" "vec" 2)
  ;; Like writing { ht["AB"]["vec"][2] = [20,30,40]; } in JavaScript

(lens-set 222 ht "two")
  ;; Like writing { ht["two"] = 222; } in JavaScript

(test-equal 222 (view ht "two"))
  ;; { ht["two"]; }

(test-equal '(20 30 40) (view ht "AB" "vec" 2))
  ;; ht["AB"]["vec"][2]

(let-values ;; The "update" procedure returns two values
    (((ht sum)
      (update&view
       (lambda (items) (values (cons 10 items) (apply + items)))
       ht "AB" "vec" 2))
     )
   (test-equal 90 sum) ; sum calculated prior to update
   (test-equal '(10 20 30 40) ; list after update
     (view ht "AB" "vec" 2))
  )


;; -------------------------------------------------------------------------------------------------

(define (=>depth-first-search select?)
  ;; This lens finds the first node in a tree for which the `SELECT?`
  ;; predicate return #t. The full path to the node is returned.
  ;; Updates return the path to the element updated as the second
  ;; value.

  (let*((getter ;; ----------------------------------------------
         ;; Returns the first node succeeding on application of
         ;; `SELECT?` The path is applied to `select?` but is not
         ;; returned.
         (lambda (node)
           (call/cc
            (lambda (return)
              (let loop ((node node) (path '()))
                (cond
                 ((select? node path) (return node))
                 ((hash-table? node)
                  (hash-table-for-each
                   (lambda (key node) (loop node (cons key path)))
                   node)
                  #f)
                 ((vector? node)
                  (let ((len (vector-length node)))
                    (let next ((i 0))
                      (cond
                       ((< i len)
                        (loop node (cons i path))
                        (next (+ 1 i)))
                       (else #f)))))
                 (else #f)))))
           ))
        (updater ;; --------------------------------------------------
         ;; The updater function takes an updating procedure to alter
         ;; the value to which this lens is referring. Since this is a
         ;; depth-first search, the updating procedure is applied to
         ;; the first element selected by the `SELECT?` predicate. The
         ;; updating procedure must return 2 values: 1. the updated
         ;; node, and 2. some arbitrary other value. When many lenses
         ;; are composed in sequence for the `UPDATE` procedure, the
         ;; last lens in the sequence will return this arbitrary
         ;; value.
         ;;
         ;; In this example, the arbitrary second value returned is
         ;; the second return value of `UPDATER` CONS'ed to the path
         ;; of selected node, or #f if nothing is selected.
         (lambda (updater node)
           (call/cc
            (lambda (return)
              (let loop ((node node) (path '()))
                (cond
                 ((select? node path)
                  ;; ********* THIS IS INTERESTING! *********
                  ;; This is what makes lenses different from
                  ;; generalized `SET!`:

                  (let-values (((node result) (updater node)))
                    (return node (cons result path)))

                  ;; Notice how we can define our lens to not only
                  ;; return the result of `UPDATER`` but also return
                  ;; the "path". When this lens is used with
                  ;; `LENS-SET` this information is discarded, but if
                  ;; you use `UPDATE` the lens you define can choose
                  ;; to return additional information that you might
                  ;; find useful.
                  )
                 ((hash-table? node)
                  (hash-table-for-each
                   (lambda (key subnode)
                     (let-values
                         (((subnode result)
                           (loop node (cons key path))))
                       (cond
                        (result
                         (hash-table-set! node key subnode)
                         (return node result))
                        (else (values)))))
                   node))
                 ((vector? node)
                  (let ((len (vector-length node)))
                    (let next ((i 0))
                      (cond
                       ((< i len)
                        (loop (vector-ref node i) (cons i path))
                        (next (+ 1 i)))))))
                 (else (values node #f))))))
           ))

        (setter ;; --------------------------------------------------------
         ;; We use the `DEFAULT-UNIT-LENS-SETTER` procedure that is
         ;; provided by `(SCHEMACS LENS)` to derive the setter automatically.
         ;; The default setter uses the updater and discards the second of
         ;; the returned VALUES.
         (default-unit-lens-setter updater))
        )
    ;; Use the `UNIT-LENS` procedure provided by `(SCHEMACS LENS)` to
    ;; construct a lens. This constructs a data structure associating
    ;; a getter, setter, and updater procedure all together.
    (unit-lens getter setter updater `(=>depth-first-search ,select?))
    ))

(define =>DFS =>depth-first-search)

(define (select-by-key-symbol sym)
  (lambda (o path) (and (pair? path) (eq? sym (car path)))))

(define (select-by-key-string name)
  (lambda (o path) (and (pair? path) (string=? name (car path)))))

(set! ht
  (alist->hash-table
   (list
    (cons 'zero 0) (cons 'one 1) (cons 'two 2)
    (cons 'elements
     (alist->hash-table
      (list
       (cons 'earth "solid")
       (cons 'wind  "gas")
       (cons 'fire  "plasma")
       (cons 'water "liquid")
       (cons 'periodic-table
        (vector
          #f "Hydrogen" "Helium" "Lithium" "Berylium" "Boron"
          "Carbon" "Nitrogen" "Oxygen" "Flourine" "Neon")))
      )))
   (make-default-comparator)
   ))

(test-equal "Hydrogen"
  (view ht (=>DFS (select-by-key-symbol 'periodic-table)) 1))

(test-equal "liquid"
  (view ht (=>DFS (select-by-key-symbol 'elements)) 'water))

;; -------------------------------------------------------------------------------------------------

;; How to define lenses for a record type.

(define-record-type <color-type>
  (make<color> r g b)
  color-type?
  (r red   set!red)
  (g green set!green)
  (b blue  set!blue))

;; Here we define the lenses:

(define =>red*!   (record-unit-lens red   set!red))
(define =>green*! (record-unit-lens green set!green))
(define =>blue*!  (record-unit-lens blue  set!blue))

;; Here we use the lenses to define a value "yellow"

(define yellow
  (let ((c (make<color> 0 0 0)))
    (lens-set 255 c =>red*!)
    (lens-set 255 c =>green*!)
    c))

;; Constrcuts a color defaulting to black.
(define (new-color) (make<color> 0 0 0))

;; A predicate that returns true if the color is black.
(define (black? c) (or (not c) (= 0 (red c) (green c) (blue c))))

(define =>red!   (=>canonical =>red*! new-color black?))
(define =>green! (=>canonical =>green*! new-color black?))
(define =>blue!  (=>canonical =>blue*! new-color black?))

  ;; Now we can use the canonical lenses to construct a color. For
  ;; example, canonical "=>green" will apply (new-color) if
  ;; `lens-set` applies the lens to #f.

(let*((c (lens-set 255 #f =>green!))
      (c (lens-set 255 c  =>blue!))
      (cyan (make<color> 0 255 255)))
  (test-assert
      (and (= (view cyan =>green!) (view c =>green!))
           (= (view cyan =>blue!)  (view c =>blue!))
           (= (view cyan =>red!)   (view c =>red!))
           ))

  ;; Setting the color to black with our canonical lenses will return
  ;; #f in place of a color, since the canonical lens uses the
  ;; `black?` predicate to decide if the <COLOR-TYPE> value is
  ;; "empty."
  
  (let*((c (lens-set 0 c =>green!))
        (c (lens-set 0 c =>blue!)))
    (test-equal #f c) ;; #f
    ))

  ;; To declare a new translation rule, pass two arguments:
  ;;
  ;;  1. the type of index you want to use as a lens, must be
  ;;     `'symbol`, `'string`, or `'integer'`.
  ;;
  ;;  2. a predicate that returns `#T` for records applied to it,
  ;; 
  ;;  3. a lens constructor that constructs a lens using the symbol,
  ;;     string, or integer.

(define (symbol->color-lens sym)
  (cond
   ((or (eq? sym 'r) (eq? sym 'red)) =>red!)
   ((or (eq? sym 'g) (eq? sym 'green)) =>green!)
   ((or (eq? sym 'b) (eq? sym 'blue)) =>blue!)
   (else (error "not a color field name, must be 'red, 'green, or 'blue" sym))
   ))

(declare-rule/index->lens
  'symbol            ;; 1. the type of value that can be used as an index
  color-type?        ;; 2. the predicate to identify the record
  symbol->color-lens ;; 3. the procedure to convert a symbol to a lens
  )

  ;; Now we can use ordinary symbols to access fields of a `<color-type>`.

(let ((c (make<color> 33 99 198)))
  (list (view c 'red) (view c 'green) (view c 'blue))
  )

;; -------------------------------------------------------------------------------------------------

(test-equal '(0 2 4 6 8 10 12 14 16)
  (update (endo-view =>cdr) '(0 2 4 6 8 9 10 12 14 16) (=>find-tail odd?)))

(define list-of-evens '(0 2 4 5 6 8))

(test-equal (caddr list-of-evens) ((lens-compose car =>cdr cdr) list-of-evens))

(test-equal (caddr list-of-evens) ((endo cdr cdr =>car) list-of-evens))

(set! list-of-evens (update (lambda (x) (+ 5 x)) list-of-evens (=>bring odd?)))

(define ll '())
(test-equal '()    (begin (set! ll (lens-set #f ll =>head)) ll))
(test-equal '(0)   (begin (set! ll (lens-set  0 ll =>head)) ll))
(test-equal '(1)   (begin (set! ll (lens-set  1 ll =>head)) ll))
(test-equal '()    (begin (set! ll (lens-set #f ll =>head)) ll))


(test-equal '(10 0 2 4 6 8) list-of-evens)

(test-assert (null? (view list-of-evens (=>bring odd?))))

(test-equal 0 (view list-of-evens (=>find (lambda (n) (= 0 n)))))

(test-assert (null? (view list-of-evens (=>find odd?))))

(set! list-of-evens (update (lambda _ '()) list-of-evens (=>bring (lambda (x) (> x 9)))))

(test-equal '(0 2 4 6 8) list-of-evens)

(set! h '((zero . 0) (one . 1) (two . 2) (three . 3) (four . 4)))

(set! h (update (lambda (x) (* 100 x)) h (=>assq 'four)))

(test-equal '((zero . 0) (one . 1) (two . 2) (three . 3) (four . 400)) h)

(set! h (lens-set 4 h (lens (=>assq 'four))))

(test-equal '((zero . 0) (one . 1) (two . 2) (three . 3) (four . 4)) h)

(set! h (lens-set 5 h (lens (=>assq 'five))))

(test-equal '((zero . 0) (one . 1) (two . 2) (three . 3) (four . 4) (five . 5)) h)

(set! h (lens-set -1 h (=>assoc-by =>bring eq? '-one)))

(test-equal '((-one . -1) (zero . 0) (one . 1) (two . 2) (three . 3) (four . 4) (five . 5)) h)

;; -------------------------------------------------------------------------------------------------

(define =>initial
  ;; This one lens can update the "initial" values of three different
  ;; data types.
  (=>guard
    (list vector? (=>vector-index! 0))
    (list hash-table? (=>hash-key! ""))
    (list (lambda (pair) (or (pair? pair) (null? pair))) =>car)))

(test-equal (vector "Hello" #f #f)
  (lens-set "Hello" (vector #f #f #f) =>initial))

(test-equal '(("" . "Hello"))
  (hash-table->alist
   (lens-set "Hello" (make-hash-table (make-string-comparator)) =>initial)))

(test-equal '("Hello")
  (lens-set "Hello" '() =>initial))

(test-equal (list 2 3 1 0)
  (let*((field 0)
        (s (lambda (i v)
             (set! field (lens-set v field (=>bit-field*! i)))
             (and (eq? v (view field (=>bit-field*! i))) field)
             )))
    (list (s 1 #t) (s 0 #t) (s 1 #f) (s 0 #f))
    ))

;; -------------------------------------------------------------------------------------------------

(test-end "schemacs_lens")

