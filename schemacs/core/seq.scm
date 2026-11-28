(define-library (schemacs core seq)
  ;; GNU Emacs's `lisp/emacs-lisp/seq.el', the generic sequence
  ;; operations. Only the three the external packages here use are
  ;; ported - `seq-filter`, `seq-remove` and `seq-find` - and their
  ;; *objective* is SRFI-1's `filter`, `remove` and `find`, which is
  ;; what they are written in terms of: the selection calls Guile's
  ;; implementation rather than re-implementing the walk.
  ;;
  ;; **A departure: the sequence type.** Emacs's functions are
  ;; `cl-defgeneric`s over lists, vectors and strings. Here a sequence is
  ;; a *list*: every caller in the tree hands one a list, and the
  ;; vector/string arms of `seq-filter` (which build a list anyway) are
  ;; not carried until something asks for them.

  (import (scheme base)
          (only (srfi srfi-1) filter list-copy take drop find-tail)
          ;; `seq-sort` is Emacs's `(sort (seq-copy list) pred)`, and the
          ;; sort itself is the runtime's.
          (only (guile) sort))

  (export seq-filter seq-remove seq-find seq-some seq-contains-p seq-union
          seq-uniq seq-difference
          seq-sort seq-sort-by seq-position seq-keep seq-subseq seq-take
          seq-drop seq-group-by seq-do-indexed seq-copy seq-length)

  (begin

    (define (seq-filter pred sequence)
      ;; GNU Emacs's `seq-filter` (seq.el): "Return a list of all the
      ;; elements in SEQUENCE for which PRED returns non-nil. This does
      ;; not modify SEQUENCE." SRFI-1's `filter` is the same operation
      ;; on a list.
      ;;--------------------------------------------------------------
      (filter pred sequence))

    (define (seq-remove pred sequence)
      ;; GNU Emacs's `seq-remove` (seq.el): "Return a list of all the
      ;; elements in SEQUENCE for which PRED returns nil" - Emacs's own
      ;; body is `seq-filter` with the negation, and so is this.
      ;;--------------------------------------------------------------
      (filter (lambda (elt) (not (pred elt))) sequence))

    (define (seq-find pred sequence . args)
      ;; GNU Emacs's `seq-find` (seq.el): "Return the first element in
      ;; SEQUENCE for which PRED returns non-nil. If no such element is
      ;; found, return DEFAULT." Written as Emacs's `catch`-and-throw
      ;; loop is written, because `(or (find ...) default)` would answer
      ;; DEFAULT for a found `#f` element - the ambiguity the docstring
      ;; itself names.
      ;;--------------------------------------------------------------
      (let ((default (if (pair? args) (car args) #f)))
        (let loop ((rest sequence))
          (cond ((null? rest) default)
                ((pred (car rest)) (car rest))
                (else (loop (cdr rest)))))))

    (define (seq-some pred sequence)
      ;; GNU Emacs's `seq-some` (seq.el): "Return the first non-nil value
      ;; returned by PRED when applied to an element of SEQUENCE, or nil
      ;; if no element fulfills the predicate." `occur-1` asks it whether
      ;; any buffer it is about to search *is* the output buffer, which
      ;; is why it answers the predicate's value rather than a boolean.
      ;;--------------------------------------------------------------
      (let loop ((rest sequence))
        (cond ((null? rest) #f)
              ((pred (car rest)) => (lambda (value) value))
              (else (loop (cdr rest))))))

    ;;--------------------------------------------------------------
    ;; The rest of what the tab line asks for. Emacs's are
    ;; `cl-defgeneric`s over lists, vectors and strings; these are the
    ;; list methods, which is this library's departure as a whole.
    ;;--------------------------------------------------------------

    (define (seq-copy sequence)
      ;; GNU Emacs's `seq-copy`: "Return a shallow copy of SEQUENCE."
      ;;--------------------------------------------------------------
      (list-copy sequence))

    (define (seq-length sequence)
      ;; GNU Emacs's `seq-length`: "Return the number of elements in
      ;; SEQUENCE."
      ;;--------------------------------------------------------------
      (length sequence))

    (define (seq-subseq sequence start . end-arg)
      ;; GNU Emacs's `seq-subseq` (seq.el:161): "Return the sequence of
      ;; elements of SEQUENCE from START to END. END is exclusive. ...
      ;; If START or END is negative, it counts from the end. Signal an
      ;; error if START or END are outside of the sequence".
      ;;
      ;; The C's list method does the arithmetic on the two indices and
      ;; then takes the slice; the bounds are the `unless` chain there,
      ;; which signals a plain `args-out-of-range` - the one condition
      ;; this tree has.
      ;;--------------------------------------------------------------
      (let* ((len (length sequence))
             (end (if (pair? end-arg) (car end-arg) len))
             (end (if (and end (< end 0)) (+ end len) end))
             (start (if (< start 0) (+ start len) start)))
        (unless (>= start 0)
          (error "Args out of range: ~a, ~a" sequence start))
        (unless (and end (<= end len))
          (error "Args out of range: ~a, ~a" sequence end))
        (unless (<= start end)
          (error "Args out of range: ~a, ~a" sequence start))
        (take (drop sequence start) (- end start))))

    (define (seq-take sequence n)
      ;; GNU Emacs's `seq-take`: "Return the sequence made of the first N
      ;; elements of SEQUENCE. ... If N is a negative integer or zero,
      ;; an empty sequence is returned."
      ;;--------------------------------------------------------------
      (seq-subseq sequence 0 (min (max n 0) (seq-length sequence))))

    (define (seq-drop sequence n)
      ;; GNU Emacs's `seq-drop`: "Remove the first N elements of SEQUENCE
      ;; and return the resulting sequence. ... If N is a negative
      ;; integer or zero, SEQUENCE is returned."
      ;;--------------------------------------------------------------
      (if (<= n 0)
          sequence
          (let ((length (seq-length sequence)))
            (seq-subseq sequence (min n length) length))))

    (define (seq-sort pred sequence)
      ;; GNU Emacs's `seq-sort`: "Sort SEQUENCE using PRED as the sorting
      ;; comparison function. ... The sort operates on a copy of
      ;; SEQUENCE and does not modify SEQUENCE."
      ;;--------------------------------------------------------------
      (sort (seq-copy sequence) pred))

    (define (seq-sort-by function pred sequence)
      ;; GNU Emacs's `seq-sort-by`: "Sort SEQUENCE transformed by
      ;; FUNCTION using PRED as the comparison function."
      ;;--------------------------------------------------------------
      (seq-sort (lambda (a b) (pred (function a) (function b)))
                sequence))

    (define (seq-position sequence elt . testfn-arg)
      ;; GNU Emacs's `seq-position`: "Return the (zero-based) index of the
      ;; first element in SEQUENCE \"equal\" to ELT. \"Equality\" is
      ;; defined by the function TESTFN, which defaults to `equal`."
      ;;--------------------------------------------------------------
      (let ((testfn (if (pair? testfn-arg) (car testfn-arg) equal?)))
        (let loop ((rest sequence) (index 0))
          (cond ((null? rest) #f)
                ((testfn (car rest) elt) index)
                (else (loop (cdr rest) (+ index 1)))))))

    (define (seq-keep function sequence)
      ;; GNU Emacs's `seq-keep`: "Apply FUNCTION to SEQUENCE and return
      ;; the list of all the non-nil results."
      ;;
      ;; `delq nil` is `filter` of the negation here, which is the same
      ;; answer for every value: Emacs's nil is false either way.
      ;;--------------------------------------------------------------
      (filter (lambda (x) x) (map function sequence)))

    (define (seq-contains-p sequence elt . testfn-arg)
      ;; GNU Emacs's `seq-contains-p` (`seq.el:448'): "Return non-nil if
      ;; SEQUENCE contains an element \"equal\" to ELT. \"Equality\" is
      ;; defined by the function TESTFN, which defaults to `equal'." The
      ;; C answers TESTFN's own value - it throws it from the
      ;; `seq-doseq' walk - so this does too.
      ;;--------------------------------------------------------------
      (let ((testfn (if (pair? testfn-arg) (car testfn-arg) equal?)))
        (let loop ((rest sequence))
          (cond ((null? rest) #f)
                ((testfn (car rest) elt))
                (else (loop (cdr rest)))))))

    (define (seq-union sequence1 sequence2 . testfn-arg)
      ;; GNU Emacs's `seq-union` (`seq.el:553'): "Return a list of all
      ;; the elements that appear in either SEQUENCE1 or SEQUENCE2.
      ;; \"Equality\" of elements is defined by the function TESTFN,
      ;; which defaults to `equal'. This does not modify SEQUENCE1 or
      ;; SEQUENCE2."
      ;;
      ;; The C is `(seq-reduce accum sequence2 (seq-reduce accum
      ;; sequence1 nil))' and an `nreverse'; `accum' conses the element
      ;; when the accumulator does not already hold it, so the answer is
      ;; in order of first appearance.
      ;;--------------------------------------------------------------
      (let* ((testfn (if (pair? testfn-arg) (car testfn-arg) equal?))
             (accum (lambda (acc elt)
                      (if (seq-contains-p acc elt testfn)
                          acc
                        (cons elt acc)))))
        (let reduce ((rest sequence1) (acc '()))
          (if (null? rest)
              (let finish ((rest sequence2) (acc acc))
                (if (null? rest)
                    (reverse acc)
                    (finish (cdr rest) (accum acc (car rest)))))
              (reduce (cdr rest) (accum acc (car rest)))))))

    (define (seq-uniq sequence . testfn-arg)
      ;; GNU Emacs's `seq-uniq`: "Return a list of the elements of
      ;; SEQUENCE with duplicates removed. TESTFN is used to compare
      ;; elements, and defaults to `equal`."
      ;;--------------------------------------------------------------
      (let ((testfn (if (pair? testfn-arg) (car testfn-arg) equal?)))
        (let loop ((rest sequence) (result '()))
          (cond ((null? rest) (reverse result))
                ((find-tail (lambda (x) (testfn x (car rest))) result)
                 (loop (cdr rest) result))
                (else (loop (cdr rest) (cons (car rest) result)))))))

    (define (seq-difference sequence1 sequence2 . testfn-arg)
      ;; GNU Emacs's `seq-difference`: "Return copy of SEQUENCE1 with
      ;; elements that appear in SEQUENCE2 removed. \"Equality\" of
      ;; elements is defined by the function TESTFN, which defaults to
      ;; `equal`."
      ;;--------------------------------------------------------------
      (let ((testfn (if (pair? testfn-arg) (car testfn-arg) equal?)))
        (filter (lambda (elt)
                  (not (find-tail (lambda (x) (testfn x elt)) sequence2)))
                sequence1)))

    (define (seq-group-by function sequence)
      ;; GNU Emacs's `seq-group-by`: "Apply FUNCTION to each element of
      ;; SEQUENCE. Separate the elements into an alist using the results
      ;; as keys. Keys are compared using `equal`."
      ;;
      ;; The C builds the alist backwards (`push`) and so the groups come
      ;; out in reverse order of first appearance; the elements inside
      ;; each group are `push`ed too. Written as the C's reduce with the
      ;; same pushes rather than a `reverse` at the end, because the
      ;; order it produces is the contract the tab line displays tabs in.
      ;;--------------------------------------------------------------
      (let loop ((rest sequence) (acc '()))
        (if (null? rest)
            acc
            (let* ((elt (car rest))
                   (key (function elt))
                   (cell (assoc key acc)))
              (if cell
                  (begin (set-cdr! cell (cons elt (cdr cell)))
                         (loop (cdr rest) acc))
                  (loop (cdr rest) (cons (list key elt) acc)))))))

    (define (seq-do-indexed function sequence)
      ;; GNU Emacs's `seq-do-indexed`: "Apply FUNCTION to each element of
      ;; SEQUENCE and return nil. Unlike `seq-map`, FUNCTION takes two
      ;; arguments: the element, and its index within the sequence."
      ;;--------------------------------------------------------------
      (let loop ((rest sequence) (index 0))
        (cond ((null? rest) '())
              (else (function (car rest) index)
                    (loop (cdr rest) (+ index 1)))))
      '())
    ))
