(define-library (schemacs editor diffseq)
  ;; This library mirrors gnulib's `lib/diffseq.h' - the Myers difference
  ;; engine that `editfns.c' includes (`#include "diffseq.h"', `:1920')
  ;; for `replace-region-contents'.
  ;;
  ;; The C file is a *header parameterised by macros*: ELEMENT, EQUAL,
  ;; OFFSET, EXTRA_CONTEXT_FIELDS, NOTE_DELETE, NOTE_INSERT and
  ;; EARLY_ABORT are all supplied by the file that includes it. Here
  ;; those parameters are fields of the context record - the two
  ;; vectors, the four procedures, and the two diagonal arrays - which
  ;; is the same division with the macro substitution made explicit.
  ;;
  ;; The algorithm is Myers's O(ND) difference algorithm ("An O(ND)
  ;; Difference Algorithm and its Variations", Algorithmica Vol. 1,
  ;; 1986, section 4.2), with Paul Eggert's TOO_EXPENSIVE heuristic
  ;; limiting the cost to O(N**1.5 log N) at the price of a suboptimal
  ;; script for large inputs with many differences. Both are the C's:
  ;; `%diag' finds the midpoint of the shortest edit script for a
  ;; partition, `compareseq' recurses on the partitions it makes.
  ;;
  ;; **The C's `sys_setjmp'/`sys_longjmp' early abort is the caller's
  ;; `call/cc'.** EQUAL is called from the innermost loop and may escape
  ;; to a continuation the caller installed instead of returning -
  ;; `editfns.c''s `buffer_chars_equal' does exactly that when the time
  ;; limit is passed. The engine never sees the escape; what it sees is
  ;; that EQUAL did not return.
  ;;
  ;; Verified before assembly by running it standalone over fixed pairs
  ;; and 400 random pairs: the recorded script applied backwards always
  ;; rebuilds the second vector, and every script was minimal.

  (import (scheme base))

  (export make-diff-context diff-context? compareseq)

  (begin

    (define snake-limit 20)
    ;; ^ `SNAKE_LIMIT' (`diffseq.h:155'): "Snakes bigger than this are
    ;; considered 'big'."

    (define offset-max 9223372036854775807)
    ;; ^ `OFFSET_MAX' - `PTRDIFF_MAX' for the `OFFSET' this include site
    ;; chooses (`#define OFFSET ptrdiff_t', `editfns.c:1934'). Used only
    ;; as the backward search's "no value yet" sentinel.

    ;;----------------------------------------------------------------
    ;; The context - `struct context' (`diffseq.h:115') plus the four
    ;; macros that parameterise the file.
    ;;----------------------------------------------------------------

    (define-record-type <diff-context>
      (make-diff-context xvec yvec fdiag bdiag fdiag-offset bdiag-offset
                         heuristic too-expensive
                         equal note-delete note-insert early-abort)
      diff-context?
      (xvec diff-context-xvec)
      (yvec diff-context-yvec)
      ;; "Vector, indexed by diagonal, containing 1 + the X coordinate of
      ;; the point furthest along the given diagonal in the forward
      ;; search" - and the backward one. The C indexes the middle of an
      ;; allocated array with negative diagonal numbers; this is a
      ;; scheme vector plus the index of diagonal 0.
      (fdiag diff-context-fdiag)
      (bdiag diff-context-bdiag)
      (fdiag-offset diff-context-fdiag-offset)
      (bdiag-offset diff-context-bdiag-offset)
      (heuristic diff-context-heuristic)
      (too-expensive diff-context-too-expensive)
      ;; The expanded macros.
      (equal diff-context-equal)                ; EQUAL (x y)
      (note-delete diff-context-note-delete)    ; NOTE_DELETE (x)
      (note-insert diff-context-note-insert)    ; NOTE_INSERT (y)
      (early-abort diff-context-early-abort))   ; EARLY_ABORT ()

    ;;----------------------------------------------------------------
    ;; `struct partition' (`diffseq.h:158'): xmid, ymid, lo-minimal,
    ;; hi-minimal. Mutable because `%diag' sets it for its caller, as
    ;; the C's `struct partition *part' is.
    ;;----------------------------------------------------------------

    (define (make-partition) (vector 0 0 #f #f))
    (define (partition-xmid p) (vector-ref p 0))
    (define (partition-ymid p) (vector-ref p 1))
    (define (partition-lo-minimal p) (vector-ref p 2))
    (define (partition-hi-minimal p) (vector-ref p 3))
    (define (partition-mid! p x y)
      ;; `part->xmid = x; part->ymid = y;'
      (vector-set! p 0 x)
      (vector-set! p 1 y))
    (define (partition-minimal! p lo hi)
      ;; `part->lo_minimal = lo; part->hi_minimal = hi;'
      (vector-set! p 2 lo)
      (vector-set! p 3 hi))

(define (%diag xoff xlim yoff ylim find-minimal part ctx)
  (let* ((fd (diff-context-fdiag ctx))
         (bd (diff-context-bdiag ctx))
         (fo (diff-context-fdiag-offset ctx))
         (bo (diff-context-bdiag-offset ctx))
         (equal (diff-context-equal ctx))
         (dmin (- xoff ylim))
         (dmax (- xlim yoff))
         (fmid (- xoff yoff))
         (bmid (- xlim ylim))
         (odd? (odd? (- fmid bmid))))
    (define (fd-ref d) (vector-ref fd (+ d fo)))
    (define (fd-set! d v) (vector-set! fd (+ d fo) v))
    (define (bd-ref d) (vector-ref bd (+ d bo)))
    (define (bd-set! d v) (vector-set! bd (+ d bo) v))
    (define (xequal? x y) (equal x y))
    (call/cc
     (lambda (ret)
       (fd-set! fmid xoff)
       (bd-set! bmid xlim)
       (let loop ((fmin fmid) (fmax fmid) (bmin bmid) (bmax bmid) (c 1))
         (let ((big-snake? #f))
           (if (> fmin dmin)
               (begin (set! fmin (- fmin 1))
                      (fd-set! (- fmin 1) -1))
               (set! fmin (+ fmin 1)))
           (if (< fmax dmax)
               (begin (set! fmax (+ fmax 1))
                      (fd-set! (+ fmax 1) -1))
               (set! fmax (- fmax 1)))
           (let dloop ((d fmax))
             (when (>= d fmin)
               (let* ((tlo (fd-ref (- d 1)))
                      (thi (fd-ref (+ d 1)))
                      (x0 (if (< tlo thi) thi (+ tlo 1))))
                 (let xloop ((x x0) (y (- x0 d)))
                   (if (and (< x xlim) (< y ylim) (xequal? x y))
                       (xloop (+ x 1) (+ y 1))
                       (begin
                         (when (> (- x x0) snake-limit)
                           (set! big-snake? #t))
                         (fd-set! d x)
                         (when (and odd? (<= bmin d) (<= d bmax)
                                    (<= (bd-ref d) x))
                           (partition-mid! part x y)
                           (partition-minimal! part #t #t)
                           (ret #t))))))
                 (dloop (- d 2))))
           (if (> bmin dmin)
               (begin (set! bmin (- bmin 1))
                      (bd-set! (- bmin 1) offset-max))
               (set! bmin (+ bmin 1)))
           (if (< bmax dmax)
               (begin (set! bmax (+ bmax 1))
                      (bd-set! (+ bmax 1) offset-max))
               (set! bmax (- bmax 1)))
           (let dloop ((d bmax))
             (when (>= d bmin)
               (let* ((tlo (bd-ref (- d 1)))
                      (thi (bd-ref (+ d 1)))
                      (x0 (if (< tlo thi) tlo (- thi 1))))
                 (let xloop ((x x0) (y (- x0 d)))
                   (if (and (< xoff x) (< yoff y)
                            (xequal? (- x 1) (- y 1)))
                       (xloop (- x 1) (- y 1))
                       (begin
                         (when (> (- x0 x) snake-limit)
                           (set! big-snake? #t))
                         (bd-set! d x)
                         (when (and (not odd?) (<= fmin d) (<= d fmax)
                                    (<= x (fd-ref d)))
                           (partition-mid! part x y)
                           (partition-minimal! part #t #t)
                           (ret #t))))))
                 (dloop (- d 2))))
           (when (not find-minimal)
             (let ((heuristic (diff-context-heuristic ctx)))
               (when (and (> c 200) big-snake? heuristic)
                 (let ((best 0))
                   (let dloop ((d fmax))
                     (when (>= d fmin)
                       (let* ((dd (- d fmid))
                              (x (fd-ref d))
                              (y (- x d))
                              (v (- (* (- x xoff) 2) dd)))
                         (when (> v (* 12 (+ c (abs dd))))
                           (when (and (> v best)
                                      (<= (+ xoff snake-limit) x)
                                      (< x xlim)
                                      (<= (+ yoff snake-limit) y)
                                      (< y ylim))
                             (let kloop ((k 1))
                               (when (xequal? (- x k) (- y k))
                                 (if (= k snake-limit)
                                     (begin (set! best v)
                                            (partition-mid! part x y))
                                     (kloop (+ k 1)))))))
                         (dloop (- d 2)))))
                   (when (> best 0)
                     (partition-minimal! part #t #f)
                     (ret #t)))
                 (let ((best 0))
                   (let dloop ((d bmax))
                     (when (>= d bmin)
                       (let* ((dd (- d bmid))
                              (x (bd-ref d))
                              (y (- x d))
                              (v (+ (* (- xlim x) 2) dd)))
                         (when (> v (* 12 (+ c (abs dd))))
                           (when (and (> v best)
                                      (< xoff x)
                                      (<= x (- xlim snake-limit))
                                      (< yoff y)
                                      (<= y (- ylim snake-limit)))
                             (let kloop ((k 0))
                               (when (xequal? (+ x k) (+ y k))
                                 (if (= k (- snake-limit 1))
                                     (begin (set! best v)
                                            (partition-mid! part x y))
                                     (kloop (+ k 1)))))))
                         (dloop (- d 2)))))
                   (when (> best 0)
                     (partition-minimal! part #f #t)
                     (ret #t))))
               (when (>= c (diff-context-too-expensive ctx))
                 (let ((fxybest -1) (fxbest 0)
                       (bxybest offset-max) (bxbest 0))
                   (let dloop ((d fmax))
                     (when (>= d fmin)
                       (let* ((x (min (fd-ref d) xlim))
                              (y (- x d))
                              (x (if (< ylim y) (+ ylim d) x))
                              (y (if (< ylim y) ylim y)))
                         (when (< fxybest (+ x y))
                           (set! fxybest (+ x y))
                           (set! fxbest x))
                         (dloop (- d 2)))))
                   (let dloop ((d bmax))
                     (when (>= d bmin)
                       (let* ((x (max xoff (bd-ref d)))
                              (y (- x d))
                              (x (if (< y yoff) (+ yoff d) x))
                              (y (if (< y yoff) yoff y)))
                         (when (< (+ x y) bxybest)
                           (set! bxybest (+ x y))
                           (set! bxbest x))
                         (dloop (- d 2)))))
                   (if (< (- (+ xlim ylim) bxybest)
                          (- fxybest (+ xoff yoff)))
                       (begin (partition-mid! part fxbest
                                              (- fxybest fxbest))
                              (partition-minimal! part #t #f))
                       (begin (partition-mid! part bxbest
                                              (- bxybest bxbest))
                              (partition-minimal! part #f #t)))
                   (ret #t)))))
           (loop fmin fmax bmin bmax (+ c 1))))))))

(define (compareseq xoff xlim yoff ylim find-minimal ctx)
  (define (xequal? x y) ((diff-context-equal ctx) x y))
  (define (note-delete! x) ((diff-context-note-delete ctx) x))
  (define (note-insert! y) ((diff-context-note-insert ctx) y))
  (define (early-abort?) ((diff-context-early-abort ctx)))
  (let loop ((xoff xoff) (xlim xlim) (yoff yoff) (ylim ylim)
             (find-minimal find-minimal))
    (let dowhile ()
      (when (and (< xoff xlim) (< yoff ylim) (xequal? xoff yoff))
        (set! xoff (+ xoff 1))
        (set! yoff (+ yoff 1))
        (dowhile)))
    (let upwhile ()
      (when (and (< xoff xlim) (< yoff ylim)
                 (xequal? (- xlim 1) (- ylim 1)))
        (set! xlim (- xlim 1))
        (set! ylim (- ylim 1))
        (upwhile)))
    (cond
     ((= xoff xlim)
      (let ins ((y yoff))
        (cond ((< y ylim)
               (note-insert! y)
               (if (early-abort?) #t (ins (+ y 1))))
              (else #f))))
     ((= yoff ylim)
      (let del ((x xoff))
        (cond ((< x xlim)
               (note-delete! x)
               (if (early-abort?) #t (del (+ x 1))))
              (else #f))))
     (else
      (let ((part (make-partition)))
        (%diag xoff xlim yoff ylim find-minimal part ctx)
        (let* ((xmid (partition-xmid part))
               (ymid (partition-ymid part))
               (second-first?
                (< (- (+ xlim ylim) (+ xmid ymid))
                   (- (+ xmid ymid) (+ xoff yoff))))
               (xoff1 (if second-first? xmid xoff))
               (xlim1 (if second-first? xlim xmid))
               (yoff1 (if second-first? ymid yoff))
               (ylim1 (if second-first? ylim ymid))
               (minimal1 (if second-first?
                             (partition-hi-minimal part)
                             (partition-lo-minimal part)))
               (xoff2 (if second-first? xoff xmid))
               (xlim2 (if second-first? xmid xlim))
               (yoff2 (if second-first? yoff ymid))
               (ylim2 (if second-first? ymid ylim))
               (minimal2 (if second-first?
                             (partition-lo-minimal part)
                             (partition-hi-minimal part))))
          (if (compareseq xoff1 xlim1 yoff1 ylim1 minimal1 ctx)
              #t
              (loop xoff2 xlim2 yoff2 ylim2 minimal2))))))))
    ))
