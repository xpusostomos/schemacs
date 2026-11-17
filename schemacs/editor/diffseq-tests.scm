;; -*- mode: scheme; -*-
;; Tests for `(schemacs editor diffseq)' - gnulib's `lib/diffseq.h', the
;; Myers difference engine under `replace-region-contents'.
;;
;; The engine's contract is checked *without* Emacs, because it is not a
;; Lisp interface: what has to hold is that the recorded script, applied
;; the way `replace-region-contents' applies it, rebuilds the second
;; vector - and that a minimal script is minimal. The end-to-end
;; comparison against Emacs belongs to `replace-region-contents'' own
;; tests, where Emacs can be asked.

(import
  (scheme base)
  (scheme write)
  ;; the fuzz's generator, seeded so a run is reproducible
  (only (guile) random seed->random-state)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor diffseq) make-diff-context compareseq))

(test-begin "schemacs_editor_diffseq")

;; The harness: run the engine over two lists, answering the two bit
;; vectors of noted deletes and inserts, then rebuild the target from
;; them exactly as `replace-region-contents'' apply loop does.

(define (run-diff a b . opts)
  (let* ((heuristic (if (pair? opts) (car opts) #t))
         (too-expensive (if (and (pair? opts) (pair? (cdr opts)))
                            (cadr opts)
                            1000000))
         (na (length a))
         (nb (length b))
         (xa (list->vector a))
         (xb (list->vector b))
         (diags (+ na nb 3))
         (off (+ nb 1))
         (fdiag (make-vector diags -1))
         (bdiag (make-vector diags 9223372036854775807))
         (dels (make-vector na #f))
         (inss (make-vector nb #f))
         (ctx (make-diff-context
               xa xb fdiag bdiag off off heuristic too-expensive
               (lambda (x y) (equal? (vector-ref xa x) (vector-ref xb y)))
               (lambda (x) (vector-set! dels x #t))
               (lambda (y) (vector-set! inss y #t))
               (lambda () #f))))
    (compareseq 0 na 0 nb #f ctx)
    (vector dels inss)))

(define (apply-script a b dels inss)
  ;; The C's apply loop, rebuilt: walk backwards, replacing each run and
  ;; keeping every unmatched character. `--i; --j' after a run steps
  ;; past the matched character in front of it, which stays in the
  ;; buffer untouched - so it is emitted here too.
  (let ((av (list->vector a))
        (bv (list->vector b))
        (i (vector-length dels))
        (j (vector-length inss))
        (acc '()))
    (let loop ()
      (if (or (> i 0) (> j 0))
          (begin
            (if (or (and (> i 0) (vector-ref dels (- i 1)))
                    (and (> j 0) (vector-ref inss (- j 1))))
                (let ((end-b j))
                  (let shrinka ()
                    (when (and (> i 0) (vector-ref dels (- i 1)))
                      (set! i (- i 1))
                      (shrinka)))
                  (let shrinkb ()
                    (when (and (> j 0) (vector-ref inss (- j 1)))
                      (set! j (- j 1))
                      (shrinkb)))
                  (let gather ((k (- end-b 1)))
                    (when (>= k j)
                      (set! acc (cons (vector-ref bv k) acc))
                      (gather (- k 1))))
                  (when (and (> i 0) (> j 0))
                    (set! acc (cons (vector-ref av (- i 1)) acc))))
                (set! acc (cons (vector-ref av (- i 1)) acc)))
            (set! i (- i 1))
            (set! j (- j 1))
            (loop))
          acc))))

(define (script-cost dels inss)
  (+ (let c ((k 0) (n 0))
       (if (< k (vector-length dels))
           (c (+ k 1) (if (vector-ref dels k) (+ n 1) n))
           n))
     (let c ((k 0) (n 0))
       (if (< k (vector-length inss))
           (c (+ k 1) (if (vector-ref inss k) (+ n 1) n))
           n))))

(define (edit-distance a b)
  ;; The shortest script's cost, by the textbook DP - the yardstick the
  ;; engine's answer has to meet whenever no heuristic fires.
  (let* ((na (length a))
         (nb (length b))
         (av (list->vector a))
         (bv (list->vector b))
         (d (make-vector (* (+ na 1) (+ nb 1)) 0)))
    (define (ref x y) (vector-ref d (+ (* x (+ nb 1)) y)))
    (define (set-d! x y v) (vector-set! d (+ (* x (+ nb 1)) y) v))
    (let i1 ((x 1)) (when (<= x na) (set-d! x 0 x) (i1 (+ x 1))))
    (let j1 ((y 1)) (when (<= y nb) (set-d! 0 y y) (j1 (+ y 1))))
    (let xl ((x 1))
      (when (<= x na)
        (let yl ((y 1))
          (when (<= y nb)
            (set-d! x y
                    (if (equal? (vector-ref av (- x 1))
                                (vector-ref bv (- y 1)))
                        (ref (- x 1) (- y 1))
                        (+ 1 (min (ref (- x 1) y)
                                  (ref x (- y 1))))))
            (yl (+ y 1))))
        (xl (+ x 1))))
    (ref na nb)))

(define (check-pair a b)
  ;; The two invariants: the script rebuilds B, and it is minimal.
  (let* ((r (run-diff a b))
         (dels (vector-ref r 0))
         (inss (vector-ref r 1)))
    (list (equal? (apply-script a b dels inss) b)
          (= (script-cost dels inss) (edit-distance a b)))))

;; ------------------------------------------------------------------
;; Fixed cases. The second element of each result is minimality; the
;; first is that the script rebuilds the target.

(test-equal '((#t #t) (#t #t) (#t #t) (#t #t) (#t #t) (#t #t) (#t #t) (#t #t))
  (list (check-pair '(a b c) '(a b c))
        (check-pair '(a b c) '(a x c))
        (check-pair '(a b c) '(a c))
        (check-pair '(a b c) '(a b x c))
        (check-pair '(a b c) '(x a b c y))
        (check-pair '(1 2 3 4 5 6 7 8) '(1 9 3 4 5 6 7 8))
        (check-pair '() '(a b))
        (check-pair '(a b) '())))

;; An insertion at the very start and one at the very end.
(test-equal '((#t #t) (#t #t) (#t #t))
  (list (check-pair '(a b c) '(x a b c))
        (check-pair '(a b c) '(a b c x))
        (check-pair '(a b c) '(a b c))))

;; ------------------------------------------------------------------
;; Fuzz: 400 random pairs over a three-letter alphabet. Every script
;; must rebuild its target; with the defaults no heuristic fires at
;; these sizes, so every script must also be minimal.

(set! *random-state* (seed->random-state 42))

(test-equal '(#t 0)
  (let loop ((k 0) (apply-bad 0) (suboptimal 0))
    (if (< k 400)
        (let* ((la (random 12))
               (lb (random 12))
               (a (let g ((n la)) (if (= n 0) '() (cons (random 3) (g (- n 1))))))
               (b (let g ((n lb)) (if (= n 0) '() (cons (random 3) (g (- n 1))))))
               (r (run-diff a b))
               (dels (vector-ref r 0))
               (inss (vector-ref r 1))
               (ok (equal? (apply-script a b dels inss) b))
               (minimal (= (script-cost dels inss) (edit-distance a b))))
          (loop (+ k 1)
                (if ok apply-bad (+ apply-bad 1))
                (if minimal suboptimal (+ suboptimal 1))))
        (list (= apply-bad 0) suboptimal))))

;; ------------------------------------------------------------------
;; The heuristic paths still have to produce a script that applies, even
;; when the answer is allowed to be suboptimal.

;; too-expensive forced to 5: the `c >= too_expensive' branch answers a
;; midpoint rather than a minimal partition.
(test-assert "a forced TOO_EXPENSIVE script still rebuilds the target"
  (let* ((a '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20))
         (b '(20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1))
         (r (run-diff a b #t 5))
         (dels (vector-ref r 0))
         (inss (vector-ref r 1)))
    (equal? (apply-script a b dels inss) b)))

;; The big-snake heuristic: a long common run after more than 200 edit
;; steps forces the "best diagonal" search. The script must still apply.
(test-assert "a script from the big-snake heuristic still rebuilds the target"
  (let* ((common (make-list 40 'z))
         (a (append (let g ((n 250)) (if (= n 0) '() (cons (modulo n 3) (g (- n 1)))))
                    common))
         (b (append (let g ((n 250)) (if (= n 0) '() (cons (modulo (+ n 1) 3) (g (- n 1)))))
                    common))
         (r (run-diff a b))
         (dels (vector-ref r 0))
         (inss (vector-ref r 1)))
    (equal? (apply-script a b dels inss) b)))

(test-end "schemacs_editor_diffseq")
