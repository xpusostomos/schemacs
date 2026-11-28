(define-library (schemacs core ring)
  ;; GNU Emacs's `lisp/emacs-lisp/ring.el', in Emacs 31.1, function for
  ;; function and in the file's own order.
  ;;
  ;; A ring is Emacs's own object: a cons of HEAD, a cons of LENGTH and
  ;; the vector. HEAD is the index of the oldest element, LENGTH how
  ;; many are in it, and the vector is the storage. Nothing here wraps it
  ;; in a record, because every accessor in Emacs takes the cons apart
  ;; and `ring-p` is a structurally recognisable test.
  ;;
  ;; The one representation note: an unused slot in the vector is
  ;; Emacs's nil and is `#f` here. Nothing reads a slot past the ring's
  ;; length (`ring-remove` writes `#f` back into the slot it empties),
  ;; so the difference is not observable through the API.
  ;;
  ;; `cl-deftype ring` (`(satisfies ring-p)`) is a compile-time type
  ;; alias with no run-time effect; it is not carried.

  (import (scheme base)
          ;; Emacs's `elt` is fns.c's and already ported; taking it from
          ;; there rather than hand-rolling a second one is the tree's
          ;; rule against duplicates.
          (only (schemacs fns) elt %length)
          ;; `mod` is data.c's, not a Scheme binding: `(scheme base)`
          ;; has no `mod`, and `ring-index`/`ring-insert` ask for it.
          (only (schemacs data) mod))

  (export ring-p make-ring ring-insert-at-beginning ring-plus1 ring-minus1
          ring-length ring-index ring-empty-p ring-size ring-copy
          ring-insert ring-remove ring-ref ring-elements ring-member
          ring-next ring-previous ring-extend ring-resize
          ring-insert+extend ring-remove+insert+extend
          ring-convert-sequence-to-ring)

  (begin

    (define (ring-p x)
      ;; GNU Emacs's `ring-p` (ring.el): "Return t if X is a ring; nil
      ;; otherwise."
      ;;--------------------------------------------------------------
      (and (pair? x) (integer? (car x))
           (pair? (cdr x)) (integer? (cadr x))
           (vector? (cddr x))))

    (define (make-ring size)
      ;; GNU Emacs's `make-ring` (ring.el): "Make a ring that can
      ;; contain SIZE elements."
      ;;--------------------------------------------------------------
      (cons 0 (cons 0 (make-vector size #f))))

    (define (ring-insert-at-beginning ring item)
      ;; GNU Emacs's `ring-insert-at-beginning` (ring.el): "Add to RING
      ;; the item ITEM, at the front, as the oldest item."
      ;;--------------------------------------------------------------
      (let* ((vec (cddr ring))
             (veclen (vector-length vec))
             (hd (car ring))
             (ln (cadr ring)))
        (set! ln (min veclen (+ ln 1)))
        (set! hd (ring-minus1 hd veclen))
        (vector-set! vec hd item)
        (set-car! ring hd)
        (set-car! (cdr ring) ln)
        ;; Emacs's last form is `setcar`, which answers the *value* it
        ;; stored (measured: `(ring-insert-at-beginning r 8)` is 8's
        ;; length, 2), so this answers the new LENGTH.
        ln))

    (define (ring-plus1 index veclen)
      ;; GNU Emacs's `ring-plus1` (ring.el): "Return INDEX+1, with
      ;; wraparound."
      ;;--------------------------------------------------------------
      (let ((new-index (+ index 1)))
        (if (= new-index veclen) 0 new-index)))

    (define (ring-minus1 index veclen)
      ;; GNU Emacs's `ring-minus1` (ring.el): "Return INDEX-1, with
      ;; wraparound."
      ;;--------------------------------------------------------------
      (- (if (zero? index) veclen index) 1))

    (define (ring-length ring)
      ;; GNU Emacs's `ring-length` (ring.el): "Return the number of
      ;; elements in the RING."
      ;;--------------------------------------------------------------
      (cadr ring))

    (define (ring-index index head ringlen veclen)
      ;; GNU Emacs's `ring-index` (ring.el): "Convert nominal ring index
      ;; INDEX to an internal index. The internal index refers to the
      ;; items ordered from newest to oldest. HEAD is the index of the
      ;; oldest element in the ring. RINGLEN is the number of elements
      ;; currently in the ring. VECLEN is the size of the vector in the
      ;; ring."
      ;;--------------------------------------------------------------
      (set! index (mod index ringlen))
      (mod (- (+ head (- ringlen index)) 1) veclen))

    (define (ring-empty-p ring)
      ;; GNU Emacs's `ring-empty-p` (ring.el): "Return t if RING is
      ;; empty; nil otherwise."
      ;;--------------------------------------------------------------
      (zero? (cadr ring)))

    (define (ring-size ring)
      ;; GNU Emacs's `ring-size` (ring.el): "Return the size of RING, the
      ;; maximum number of elements it can contain."
      ;;--------------------------------------------------------------
      (vector-length (cddr ring)))

    (define (ring-copy ring)
      ;; GNU Emacs's `ring-copy` (ring.el): "Return a copy of RING."
      ;;--------------------------------------------------------------
      (let ((vec (cddr ring))
            (hd (car ring))
            (ln (cadr ring)))
        (cons hd (cons ln (vector-copy vec)))))

    (define (ring-insert ring item)
      ;; GNU Emacs's `ring-insert` (ring.el): "Insert onto ring RING the
      ;; item ITEM, as the newest (last) item. If the ring is full, dump
      ;; the oldest item to make room."
      ;;--------------------------------------------------------------
      (let* ((vec (cddr ring))
             (veclen (vector-length vec))
             (hd (car ring))
             (ln (cadr ring)))
        ;; Emacs's `prog1 (aset ...)' answers what `aset` answers,
        ;; which is the item it stored.
        (vector-set! vec (mod (+ hd ln) veclen) item)
        (if (= ln veclen)
            (set-car! ring (ring-plus1 hd veclen))
            (set-car! (cdr ring) (+ ln 1)))
        item))

    (define (ring-remove ring . index-arg)
      ;; GNU Emacs's `ring-remove` (ring.el): "Remove an item from the
      ;; RING. Return the removed item. If optional INDEX is nil, remove
      ;; the oldest item. If it's numeric, remove the element indexed."
      ;; The optional argument is a rest parameter, as the tree spells
      ;; Emacs's `&optional`; `#f` is Emacs's nil for "not given".
      ;;--------------------------------------------------------------
      (let ((index (if (pair? index-arg) (car index-arg) #f)))
        (if (ring-empty-p ring)
            (error "Ring empty")
            (let* ((hd (car ring))
                   (ln (cadr ring))
                   (vec (cddr ring))
                   (veclen (vector-length vec))
                   (tl (mod (- (+ hd ln) 1) veclen)))
              ;; Emacs's `(when (null index) (setq index (1- ln)))'.
              ;; An absent index is #f, and Emacs's nil passed
              ;; explicitly is the same thing.
              (let ((index (if index index (- ln 1))))
                (set! index (ring-index index hd ln veclen))
                (let ((oldelt (vector-ref vec index)))
                  (let loop ((index index))
                    (unless (= index tl)
                      (vector-set! vec index (vector-ref vec (ring-plus1 index veclen)))
                      (loop (ring-plus1 index veclen))))
                  (vector-set! vec tl #f)
                  (set-car! (cdr ring) (- ln 1))
                  oldelt))))))

    (define (ring-ref ring index)
      ;; GNU Emacs's `ring-ref` (ring.el): "Return RING's INDEX element.
      ;; INDEX = 0 is the most recently inserted; higher indices
      ;; correspond to older elements. INDEX need not be <= the ring
      ;; length; the appropriate modulo operation will be performed."
      ;;--------------------------------------------------------------
      (if (ring-empty-p ring)
          (error "Accessing an empty ring")
          (let ((hd (car ring))
                (ln (cadr ring))
                (vec (cddr ring)))
            (vector-ref vec (ring-index index hd ln (vector-length vec))))))

    (define (ring-elements ring)
      ;; GNU Emacs's `ring-elements` (ring.el): "Return a list of the
      ;; elements of RING, in order, newest first."
      ;;--------------------------------------------------------------
      (let ((start (car ring))
            (size (ring-size ring))
            (vect (cddr ring)))
        (let loop ((var 0) (lst '()))
          (if (= var (cadr ring))
              lst
              (loop (+ var 1)
                    (cons (vector-ref vect (mod (+ start var) size)) lst))))))

    (define (ring-member ring item)
      ;; GNU Emacs's `ring-member` (ring.el): "Return index of ITEM if on
      ;; RING, else nil. Comparison is done via `equal'. The index is
      ;; 0-based." The C's `catch`/`throw` is a named let that answers
      ;; `#f` for Emacs's nil.
      ;;--------------------------------------------------------------
      (let loop ((ind 0))
        (cond ((= ind (ring-length ring)) #f)
              ((equal? item (ring-ref ring ind)) ind)
              (else (loop (+ ind 1))))))

    (define (ring-next ring item)
      ;; GNU Emacs's `ring-next` (ring.el): "Return the next item in the
      ;; RING, after ITEM. Raise error if ITEM is not in the RING."
      ;;--------------------------------------------------------------
      (let ((curr-index (ring-member ring item)))
        (unless curr-index (error "Item is not in the ring: `~a'" item))
        (ring-ref ring (ring-plus1 curr-index (ring-length ring)))))

    (define (ring-previous ring item)
      ;; GNU Emacs's `ring-previous` (ring.el): "Return the previous item
      ;; in the RING, before ITEM. Raise error if ITEM is not in the
      ;; RING."
      ;;--------------------------------------------------------------
      (let ((curr-index (ring-member ring item)))
        (unless curr-index (error "Item is not in the ring: `~a'" item))
        (ring-ref ring (ring-minus1 curr-index (ring-length ring)))))

    (define (ring-extend ring x)
      ;; GNU Emacs's `ring-extend` (ring.el): "Increase the size of RING
      ;; by X."
      ;;--------------------------------------------------------------
      (when (and (integer? x) (> x 0))
        (ring-resize ring (+ x (ring-size ring)))))

    (define (ring-resize ring size)
      ;; GNU Emacs's `ring-resize` (ring.el): "Set the size of RING to
      ;; SIZE. If the new size is smaller, then the oldest items in the
      ;; ring are discarded."
      ;;
      ;; `copy-hd`'s modulus is `length` in Emacs's own source, not
      ;; `old-size`; it is transcribed as it stands.
      ;;--------------------------------------------------------------
      (when (integer? size)
        (let ((length (ring-length ring))
              (new-vec (make-vector size #f)))
          (if (= length 0)
              (set-cdr! ring (cons 0 new-vec))
              (let* ((hd (car ring))
                     (old-size (ring-size ring))
                     (old-vec (cddr ring))
                     (copy-length (min size length))
                     (copy-hd (mod (+ hd (- length copy-length)) length)))
                (set-cdr! ring (cons copy-length new-vec))
                ;; If the ring is wrapped, the existing elements must be
                ;; written out in the right order.
                (let loop ((j 0))
                  (when (< j copy-length)
                    (vector-set! new-vec j
                                 (vector-ref old-vec (mod (+ copy-hd j) old-size)))
                    (loop (+ j 1))))
                (set-car! ring 0))))))

    (define (ring-insert+extend ring item . grow-arg)
      ;; GNU Emacs's `ring-insert+extend` (ring.el): "Like `ring-insert',
      ;; but if GROW-P is non-nil, then enlarge ring. Insert onto ring
      ;; RING the item ITEM, as the newest (last) item. If the ring is
      ;; full, behavior depends on GROW-P: If GROW-P is non-nil, enlarge
      ;; the ring to accommodate the new item. If GROW-P is nil, dump the
      ;; oldest item to make room for the new."
      ;;--------------------------------------------------------------
      (let ((grow-p (if (pair? grow-arg) (car grow-arg) #f)))
        (and grow-p
             (= (ring-length ring) (ring-size ring))
             (ring-extend ring 1))
        (ring-insert ring item)))

    (define (ring-remove+insert+extend ring item . grow-arg)
      ;; GNU Emacs's `ring-remove+insert+extend` (ring.el): "`ring-remove'
      ;; ITEM from RING, then `ring-insert+extend' it. This ensures that
      ;; there is only one ITEM on RING. If the RING is full, behavior
      ;; depends on GROW-P: If GROW-P is non-nil, enlarge the ring to
      ;; accommodate the new ITEM. If GROW-P is nil, dump the oldest item
      ;; to make room for the new."
      ;;--------------------------------------------------------------
      (let ((grow-p (if (pair? grow-arg) (car grow-arg) #f)))
        (let loop ()
          (let ((ind (ring-member ring item)))
            (when ind
              (ring-remove ring ind)
              (loop))))
        (ring-insert+extend ring item grow-p)))

    (define (ring-convert-sequence-to-ring seq)
      ;; GNU Emacs's `ring-convert-sequence-to-ring` (ring.el): "Convert
      ;; sequence SEQ to a ring, and return the ring. If SEQ is already
      ;; a ring, return it. Members of SEQ that are `equal' to the first
      ;; member are not inserted, which will cause the resulting ring to
      ;; have nil elements."
      ;;--------------------------------------------------------------
      (if (ring-p seq)
          seq
          (let* ((size (%length seq))
                 (ring (make-ring size)))
            (let loop ((count 0))
              (when (< count size)
                (when (or (ring-empty-p ring)
                          (not (equal? (ring-ref ring 0) (elt seq count))))
                  (ring-insert-at-beginning ring (elt seq count)))
                (loop (+ count 1))))
            ring)))))
