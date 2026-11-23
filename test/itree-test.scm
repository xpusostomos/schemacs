;; Tests for `(schemacs itree)', the port of GNU Emacs's
;; `src/itree.c'.
;;
;; The C's own tests are `test/manual/noverlay/itree-tests.c', which
;; includes `itree.c' to reach its static functions. The cases here are
;; that file's, ported to the public API and to a library that exports
;; its node accessors: the insert-rotation shapes, the two gap
;; operations with every combination of the advance flags, and the
;; iterators.
;;
;; A red-black tree with an offset scheme is exactly the kind of code
;; that is wrong only sometimes, so the last third is a randomised
;; model test: operations against an independent list-of-intervals
;; model, with `itree-check-tree' (the C's `check_tree', which its
;; checking build runs after every operation) called as well.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme write)
 (only (guile) sort list-head list-tail)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs itree))

(setvbuf (current-output-port) 'none)

(define (node value)
  ;; A fresh node - `itree_node_init' with no advance flags - whose
  ;; begin and end the caller sets through `itree-insert'.
  (let ((n (make<itree-node> #f #f #f 0 0 0 0 0 value #f #f #f)))
    (itree-node-init n #f #f value)
    n))

(define (root? tree n) (eq? (itree-tree-root tree) n))

(test-begin "schemacs_editor_itree")

;;--------------------------------------------------------------------
;; Insert: the shapes of `test_insert_1' .. `test_insert_6'
;;------------------------------------------------------------------
;;
;; Each case inserts 50, 30, 20, 10, 15, 5 in turn (and 50, 70, 80,
;; 90, 85, 95 for the mirror) and checks which node is the root, who
;; is whose child, and the red bits - which is what the C's cases do.

(define (insert-run values)
  (let* ((tree (itree-create))
         (nodes (map node values)))
    (let loop ((ns nodes) (vs values))
      (when (pair? ns)
        (itree-insert tree (car ns) (car vs) (car vs))
        (loop (cdr ns) (cdr vs))))
    (cons tree nodes)))

(test-equal "insert 1: one node is the black root"
  '(#t 1)
  (let* ((t+ns (insert-run '(50)))
         (tree (car t+ns)) (n (cadr t+ns)))
    (list (root? tree n) (itree-size tree))))

(test-equal "insert 2: the second node is a red left child"
  '(#t #t #f)
  (let* ((t+ns (insert-run '(50 30)))
         (tree (car t+ns)) (n50 (cadr t+ns)) (n30 (caddr t+ns)))
    (list (root? tree n50)
          (itree-node-red n30)
          (itree-node-right n50))))

(test-equal "insert 3: case 3.a rotates 30 to the root"
  '(#t #t #t)
  (let* ((t+ns (insert-run '(50 30 20)))
         (tree (car t+ns))
         (n50 (list-ref t+ns 1)) (n30 (list-ref t+ns 2)) (n20 (list-ref t+ns 3)))
    (list (root? tree n30)
          (itree-node-red n50)
          (itree-node-red n20))))

(test-equal "insert 4: case 1.a recolours rather than rotating"
  '(#t #f #f #f #t)
  (let* ((t+ns (insert-run '(50 30 20 10)))
         (tree (car t+ns))
         (n50 (list-ref t+ns 1)) (n30 (list-ref t+ns 2))
         (n20 (list-ref t+ns 3)) (n10 (list-ref t+ns 4)))
    (list (root? tree n30)
          (itree-node-red n50) (itree-node-red n30)
          (itree-node-red n20) (itree-node-red n10))))

(test-equal "insert 5: case 2.a makes 15 the left child of 30"
  '(#t #t #f #t #t #f)
  (let* ((t+ns (insert-run '(50 30 20 10 15)))
         (tree (car t+ns))
         (n30 (list-ref t+ns 2)) (n20 (list-ref t+ns 3))
         (n10 (list-ref t+ns 4)) (n15 (list-ref t+ns 5)))
    (list (root? tree n30)
          (eq? (itree-node-left n30) n15)
          (itree-node-red n15)
          (itree-node-red n20)
          (itree-node-red n10)
          (itree-node-left n20))))

(test-equal "insert 12: the mirror's second recolour"
  '(#t #t #t #t #t #t #t)
  (let* ((t+ns (insert-run '(50 70 80 90 85 95)))
         (tree (car t+ns))
         (n70 (list-ref t+ns 2)) (n85 (list-ref t+ns 5))
         (n95 (list-ref t+ns 6)))
    (list (root? tree n70)
          (eq? (itree-node-right n70) n85)
          (eq? (itree-node-right n85) (list-ref t+ns 4))
          (eq? (itree-node-left n85) (list-ref t+ns 3))
          (itree-node-red n85)
          (itree-node-red n95)
          (eq? (itree-node-right (list-ref t+ns 4)) n95))))

;; `test_insert_13': inserting 10, 20, 30, 40 leaves 20 at the root,
;; 10 and 30 its children, 40 the red right child of 30.
(test-equal "insert 13: the four-value shape"
  '(#t #t #t #t #t)
  (let* ((t+ns (insert-run '(10 20 30 40)))
         (tree (car t+ns))
         (n10 (list-ref t+ns 1)) (n20 (list-ref t+ns 2))
         (n30 (list-ref t+ns 3)) (n40 (list-ref t+ns 4)))
    (list (root? tree n20)
          (eq? (itree-node-left n20) n10)
          (eq? (itree-node-right n20) n30)
          (eq? (itree-node-right n30) n40)
          (itree-node-red n40))))

;; `test_insert_14': equal intervals all insert, and `itree_contains'
;; agrees with the tree.
(test-equal "insert 14: equal intervals and itree-contains"
  '(#t #t #t)
  (let* ((tree (itree-create))
         (a (node 'a)) (b (node 'b)) (c (node 'c)))
    (itree-insert tree a 10 10)
    (itree-insert tree b 10 10)
    (itree-insert tree c 10 10)
    (list (itree-contains tree a)
          (itree-contains tree b)
          (itree-contains tree c))))

;;--------------------------------------------------------------------
;; Gap insertion - `test_gap_insert_1' .. `test_gap_insert_11'
;;------------------------------------------------------------------
;;
;; One node and one gap operation per case; the answers are the C
;; test's own.

(define (gap-insert-case begin end front rear pos length before-markers)
  (let* ((tree (itree-create))
         (n (make<itree-node> #f #f #f 0 0 0 0 0 'gap #f #f #f)))
    (itree-node-init n front rear 'gap)
    (itree-insert tree n begin end)
    (itree-insert-gap tree pos length before-markers)
    (itree-check-tree tree)
    (list (itree-node-begin-of tree n) (itree-node-end-of tree n))))

(test-equal "gap insert 1: insertion inside the interval extends its end"
  '(100 220)
  (gap-insert-case 100 200 #f #f 110 20 #f))

(test-equal "gap insert 2: insertion after the interval changes nothing"
  '(100 200)
  (gap-insert-case 100 200 #f #f 300 10 #f))

(test-equal "gap insert 3: insertion before the interval moves it whole"
  '(115 215)
  (gap-insert-case 100 200 #f #f 0 15 #f))

(test-equal "gap insert 4: front-advance at the start moves the start"
  '(120 220)
  (gap-insert-case 100 200 #t #f 100 20 #f))

(test-equal "gap insert 5: without front-advance the start stays"
  '(100 220)
  (gap-insert-case 100 200 #f #f 100 20 #f))

(test-equal "gap insert 6: rear-advance at the end extends it"
  '(100 220)
  (gap-insert-case 100 200 #f #t 200 20 #f))

(test-equal "gap insert 7: without rear-advance the end stays"
  '(100 200)
  (gap-insert-case 100 200 #f #f 200 20 #f))

(test-equal "gap insert 8: an empty interval with both advances moves"
  '(120 120)
  (gap-insert-case 100 100 #t #t 100 20 #f))

(test-equal "gap insert 9: an empty interval with rear-advance extends"
  '(100 120)
  (gap-insert-case 100 100 #f #t 100 20 #f))

(test-equal "gap insert 10: an empty interval with front-advance stays"
  '(100 100)
  (gap-insert-case 100 100 #t #f 100 20 #f))

(test-equal "gap insert 11: an empty interval with no advances stays"
  '(100 100)
  (gap-insert-case 100 100 #f #f 100 20 #f))

;; `before_markers' makes every interval at POS behave as if it had
;; both advances set; the C test does not cover it, and buffer.c passes
;; it for `insert-before-markers'.
(test-equal "gap insert: before-markers moves both ends"
  '(120 220)
  (gap-insert-case 100 200 #f #f 100 20 #t))

;;--------------------------------------------------------------------
;; Gap deletion - `test_gap_delete_1' .. `test_gap_delete_8'
;;------------------------------------------------------------------

(define (gap-delete-case begin end pos length)
  (let* ((tree (itree-create))
         (n (node 'gap)))
    (itree-insert tree n begin end)
    (itree-delete-gap tree pos length)
    (itree-check-tree tree)
    (list (itree-node-begin-of tree n) (itree-node-end-of tree n))))

(test-equal "gap delete 1: a deletion inside contracts the end"
  '(100 180)
  (gap-delete-case 100 200 110 20))

(test-equal "gap delete 2: a deletion after changes nothing"
  '(100 200)
  (gap-delete-case 100 200 210 20))

(test-equal "gap delete 3: a deletion exactly at the end changes nothing"
  '(100 200)
  (gap-delete-case 100 200 200 20))

(test-equal "gap delete 4: a deletion before moves the interval back"
  '(80 180)
  (gap-delete-case 100 200 80 20))

(test-equal "gap delete 5: a deletion touching the start does the same"
  '(80 180)
  (gap-delete-case 100 200 70 20))

(test-equal "gap delete 6: a deletion covering the start clips it"
  '(80 100)
  (gap-delete-case 100 200 80 100))

(test-equal "gap delete 7: a deletion covering the end clips it"
  '(100 120)
  (gap-delete-case 100 200 120 100))

(test-equal "gap delete 8: a deletion covering everything collapses it"
  '(80 80)
  (gap-delete-case 100 200 80 220))

;;--------------------------------------------------------------------
;; `itree-node-set-region'
;;------------------------------------------------------------------

(test-equal "node-set-region moves an interval and keeps the tree valid"
  '(20 30 40 50)
  (let* ((tree (itree-create))
         (a (node 'a)) (b (node 'b)))
    (itree-insert tree a 10 20)
    (itree-insert tree b 40 50)
    (itree-node-set-region tree a 20 30)
    (itree-check-tree tree)
    (list (itree-node-begin-of tree a) (itree-node-end-of tree a)
          (itree-node-begin-of tree b) (itree-node-end-of tree b))))

;;--------------------------------------------------------------------
;; The iterators - ascending, descending, pre-order and post-order
;;------------------------------------------------------------------
;;
;; The twenty nodes 1..20 are inserted in a scrambled order; ascending
;; must answer them sorted, descending reversed, and the two tree
;; orders must visit each node exactly once with parents before
;; children (pre) or children before parents (post).

(define (collect-iteration order beg end)
  (let* ((tree (itree-create))
         (order-values '(12 5 18 3 9 15 20 1 7 11 14 17 19 2 4 6 8 10 13 16))
         (nodes '()))
    (for-each (lambda (v)
                (let ((n (node v)))
                  (itree-insert tree n v v)
                  (set! nodes (cons (cons v n) nodes))))
              order-values)
    (let ((iter (itree-iterator-start
                 (make<itree-iterator> #f 0 0 0 order)
                 tree beg end order)))
      (let loop ((n (itree-iterator-next iter)) (acc '()))
        (if n
            (loop (itree-iterator-next iter)
                  (cons (itree-node-data n) acc))
            (reverse acc))))))

(test-equal "ascending iteration is in order"
  '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)
  (collect-iteration 'ascending -1000000 1000000))

(test-equal "descending iteration is reversed"
  '(20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1)
  (collect-iteration 'descending -1000000 1000000))

(test-equal "ascending iteration is narrowed to [beg, end)"
  '(5 6 7 8 9 10 11)
  (collect-iteration 'ascending 5 12))

(test-equal "descending iteration is narrowed to [beg, end)"
  '(11 10 9 8 7 6 5)
  (collect-iteration 'descending 5 12))

(define (all-distinct? list)
  (cond ((null? list) #t)
        ((member (car list) (cdr list)) #f)
        (else (all-distinct? (cdr list)))))

(test-equal "pre-order visits every node once"
  '(#t 20)
  (let ((order (collect-iteration 'pre-order -1000000 1000000)))
    (list (all-distinct? order) (length order))))

(test-equal "post-order visits every node once"
  '(#t 20)
  (let ((order (collect-iteration 'post-order -1000000 1000000)))
    (list (all-distinct? order) (length order))))

(define (order-obeys-parents?)
  ;; Build the same tree and say whether every parent is visited before
  ;; its children (PRE_ORDER) or after them (POST_ORDER). Answers a pair
  ;; of booleans, one per rule, so one tree serves both tests.
  (let* ((tree (itree-create))
         (values '(12 5 18 3 9 15 20 1 7 11 14 17 19 2 4 6 8 10 13 16))
         (table '()))
    (for-each (lambda (v)
                (let ((n (node v)))
                  (itree-insert tree n v v)
                  (set! table (cons (cons v n) table))))
              values)
    (define (order-values order)
      (let ((iter (itree-iterator-start
                   (make<itree-iterator> #f 0 0 0 order)
                   tree -1000000 1000000 order)))
        (let loop ((n (itree-iterator-next iter)) (acc '()))
          (if n
              (loop (itree-iterator-next iter)
                    (cons (itree-node-data n) acc))
              (reverse acc)))))
    (define (index-of v list)
      (let loop ((l list) (i 0))
        (cond ((null? l) #f)
              ((= (car l) v) i)
              (else (loop (cdr l) (+ i 1))))))
    (define (rule-holds? order before?)
      (let ((order-list (order-values order)))
        (let loop ((vs values) (ok #t))
          (if (or (not ok) (null? vs))
              ok
              (let* ((v (car vs))
                     (n (cdr (assq v table)))
                     (parent (itree-node-parent n)))
                (if (not parent)
                    (loop (cdr vs) ok)
                    (let ((vi (index-of v order-list))
                          (pi (index-of (itree-node-data parent) order-list)))
                      (loop (cdr vs)
                            (and ok (if before? (< pi vi) (> pi vi)))))))))))
    (list (rule-holds? 'pre-order #t)
          (rule-holds? 'post-order #f))))

(test-equal "tree orders visit parents and children in the right direction"
  '(#t #t)
  (order-obeys-parents?))

;; An interval is answered for a query that overlaps it the way
;; `itree_node_intersects' says - `[begin, end)' on both sides, so a
;; query ending where the interval begins does not intersect it.
(test-equal "intersection is half-open"
  '(#t #t #f #f)
  (let* ((tree (itree-create))
         (n (node 'x)))
    (itree-insert tree n 10 20)
    (let ((iter (lambda (b e)
                  (let ((i (itree-iterator-start
                            (make<itree-iterator> #f 0 0 0 'ascending)
                            tree b e 'ascending)))
                    (not (not (itree-iterator-next i)))))))
      (list (iter 10 11)   ; contains the first character
            (iter 19 20)   ; contains the last one
            (iter 9 10)    ; ends where the interval begins
            (iter 20 21))))) ; begins where the interval ends

;;--------------------------------------------------------------------
;; A randomised model test
;;------------------------------------------------------------------
;;
;; The C's `test_generator_*' cases build random trees from a random
;; source with a fixed seed. This does the same against a model that
;; knows nothing about the tree: a list of `(node begin end)', moved
;; by the same gap operations the tree gets. After every operation the
;; invariants are checked, and every so often the ascending iteration
;; is compared with the model's own list of intervals.
;;
;; The model's gap rules are the overlay rules, written out
;; independently: an insertion at POS moves an end `>` POS, a start
;; `>=` POS when front-advance is set and `>` POS otherwise; a deletion
;; of [POS, POS+LEN) clips both ends into [POS, POS+LEN).

(define (model-insert-gap intervals pos length before-markers)
  (map (lambda (iv)
         (let* ((n (car iv)) (b (cadr iv)) (e (caddr iv))
                (front (itree-node-front-advance n))
                (rear (itree-node-rear-advance n))
                (nb (if (if before-markers (>= b pos) (> b pos))
                        (+ b length) b))
                (ne (if (or (> e pos)
                            (and (= e pos) (or before-markers rear)))
                        (+ e length) e)))
           (list n nb ne)))
       intervals))

(define (model-delete-gap intervals pos length)
  (map (lambda (iv)
         (let* ((n (car iv)) (b (cadr iv)) (e (caddr iv))
                (nb (if (< pos b) (max pos (- b length)) b))
                (ne (if (> e pos) (max pos (- e length)) e)))
           (list n nb ne)))
       intervals))

(define (model-sorted intervals)
  (sort (map (lambda (iv) (cadr iv)) intervals) <))

(define (sorted-iteration tree)
  (let ((iter (itree-iterator-start
               (make<itree-iterator> #f 0 0 0 'ascending)
               tree -1000000 1000000 'ascending)))
    (let loop ((n (itree-iterator-next iter)) (acc '()))
      (if n
          (loop (itree-iterator-next iter)
                (cons (list (itree-node-data n)
                            (itree-node-begin n)
                            (itree-node-end n))
                      acc))
          (reverse acc)))))

;; A tiny deterministic generator - the C tests pass a seed to their
;; random source and expect the same tree every time; `random' with a
;; fixed state would need `(srfi 27)', which is not imported anywhere
;; else in the suite.
(define (generator seed)
  (let ((state seed))
    (lambda (modulus)
      (set! state (modulo (+ (* state 1103515245) 12345) 2147483648))
      (modulo state modulus))))

(test-equal "random insert/remove/gap: the tree matches its model"
  #t
  (let* ((tree (itree-create))
         (gen (generator 20261114))
         (intervals '())
         (counter 0)
         (failures 0))
    (define (check! what)
      (guard (e (#t (set! failures (+ failures 1))
                    (display "FAILED: " (current-output-port))
                    (display what (current-output-port))
                    (newline)))
        (itree-check-tree tree)
        (let ((from-tree (map (lambda (x) (cadr x)) (sorted-iteration tree))))
          (unless (equal? from-tree (model-sorted intervals))
            (set! failures (+ failures 1))
            (display "model mismatch after " (current-output-port))
            (display what (current-output-port))
            (newline)))))
    (do ((i 0 (+ i 1)))
        ((= i 400))
      (let ((op (gen 3)))
        (cond
         ((= op 0) ; insert
          (let* ((b (+ 1 (gen 1000)))
                 (e (+ b (gen 50)))
                 (n (make<itree-node> #f #f #f 0 0 0 0 0 counter #f #f #f)))
            (itree-node-init n #f #f counter)
            (set! counter (+ counter 1))
            (itree-insert tree n b e)
            (set! intervals (append intervals (list (list n b e))))
            (check! 'insert)))
         ((= op 1) ; remove a random one
          (when (pair? intervals)
            (let* ((idx (gen (length intervals)))
                   (iv (list-ref intervals idx)))
              (itree-remove tree (car iv))
              (set! intervals
                    (append (list-head intervals idx)
                            (list-tail intervals (+ idx 1))))
              (check! 'remove))))
         (else ; a gap operation
          (let ((pos (+ 1 (gen 900)))
                (len (+ 1 (gen 40)))
                (which (gen 2)))
            (if (= which 0)
                (let ((before-markers (not (zero? (gen 2)))))
                  (itree-insert-gap tree pos len before-markers)
                  (set! intervals
                        (model-insert-gap intervals pos len before-markers))
                  (check! 'insert-gap))
                (begin
                  (itree-delete-gap tree pos len)
                  (set! intervals (model-delete-gap intervals pos len))
                  (check! 'delete-gap))))))))
    (zero? failures)))

(test-end "schemacs_editor_itree")
