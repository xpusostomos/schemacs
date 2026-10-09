(import
  (scheme base)
  (scheme case-lambda)
  (schemacs lens)
  (schemacs lens bin-hash-table)
  (only (schemacs lens) view)
  (only (srfi 64)
        test-begin test-end test-assert test-equal)
  )

(test-begin "schemacs_lens_bin-hash-table")

(define empty-testbht (alist->bin-hash-table '()))

(test-assert (bin-hash-table-empty? empty-testbht))

(define testbht-alist
  '(("zero" . 0)
    ("one" . 1)
    ("two" . 2)))

(define testbht (alist->bin-hash-table testbht-alist))

(test-assert (not (bin-hash-table-empty? testbht)))

(test-assert
    (and
     (= 0 (view testbht (=>bin-hash-key! "zero")))
     (= 1 (view testbht (=>bin-hash-key! "one")))
     (= 2 (view testbht (=>bin-hash-key! "two")))
     ))

(test-assert (not (bin-hash-table-empty? testbht)))

(define permute3
  (case-lambda
    (() (list))
    ((a) (list (list a)))
    ((a b) (list (list a b) (list b a)))
    ((a b c)
     (list
      (list a b c) (list a c b)
      (list b a c) (list b c a)
      (list c a b) (list c b a)))))

(define testbht-alist-permutations (apply permute3 testbht-alist))

(test-assert
    (pair?
     (member
      (bin-hash-table->alist testbht)
      testbht-alist-permutations)))

(test-assert
    (let*((result
           (bin-hash-table-fold
            testbht
            (lambda (key val pair)
              (cons (string-append (car pair) "+" key) (+ (cdr pair) val)))
            '("" . 0)))
          (ok? (lambda (a b) (equal? result (cons a b))))
          )
      (or (ok? "+zero+one+two" 3)
          (ok? "+zero+two+one" 3)
          (ok? "+one+zero+two" 3)
          (ok? "+one+two+zero" 3)
          (ok? "+two+zero+one" 3)
          (ok? "+two+one+zero" 3))
      ))

(define testbht-copy (bin-hash-table-copy testbht))

(test-assert
    (begin
      (lens-set 100 testbht-copy (=>bin-hash-key! "one"))
      (and
       (= 0   (view testbht-copy (=>bin-hash-key! "zero")))
       (= 100 (view testbht-copy (=>bin-hash-key! "one")))
       (= 2   (view testbht-copy (=>bin-hash-key! "two")))
       (= 0   (view testbht      (=>bin-hash-key! "zero")))
       (= 1   (view testbht      (=>bin-hash-key! "one")))
       (= 2   (view testbht      (=>bin-hash-key! "two")))
       ))
  )

(test-assert
    (begin
      (lens-set #f testbht-copy (=>bin-hash-key! "one"))
      (and
       (pair?
        (member
         (bin-hash-table->alist testbht-copy)
         (permute3 '("zero" . 0) '("two" . 2))))
       (pair?
        (member
         (bin-hash-table->alist testbht)
         testbht-alist-permutations)))
      ))

(define testbht-null #f)
(set! testbht-null (lens-set 1 testbht-null (=>bin-hash-key! "one")))
(test-equal 1 (view testbht-null (=>bin-hash-key! "one")))

(test-end "schemacs_lens_bin-hash-table")
