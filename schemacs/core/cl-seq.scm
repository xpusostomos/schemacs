(define-library (schemacs core cl-seq)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/cl-seq.el' - the
  ;; Common Lisp sequence functions `cl-lib' renames. It carries the
  ;; four the cc-mode language constants are built with,
  ;; `c-filter-ops' (`cc-langs.el:214') and the `c--*' helpers in
  ;; `cc-defs.el' (`c--set-difference', `c--intersection',
  ;; `c--delete-duplicates'): `cl-set-difference', `cl-intersection',
  ;; `cl-delete-duplicates' and the `cl-member' they are built on.
  ;;
  ;; **Which of these Emacs actually calls.** `cc-defs.el''s macros
  ;; test `(fboundp 'set-difference)'; measured on Emacs 31.1 with
  ;; `cl-lib' loaded it is nil (`cl-set-difference' is the fboundp one),
  ;; so the `cl-' spellings are the code paths behind the `c--*'
  ;; macros, and they are what is ported.
  ;
  ;; **The algorithms are `cl-seq.el''s, including two quirks that look
  ;; like bugs and are not ours to fix:**
  ;;
  ;;   * the default test is `eql' (`cl--check-test-nokey'), which in
  ;;     Scheme is `eqv?' - so two `equal' strings are *not* duplicates
  ;;     unless they are the same object, which is exactly what Emacs
  ;;     does, and `c--delete-duplicates' without a `:test' relies on
  ;;     it;
  ;;   * `cl-set-difference' and `cl-intersection' take the `memq' path
  ;;     when no keyword was given and the element is not a number
  ;;     (`(or cl-keys (numberp (car list)))'), and `cl-member''s own
  ;;     no-keyword default is `memql'. Numbers therefore compare by
  ;;     value on both paths where strings and other objects compare by
  ;;     identity on the `memq' path.
  ;;
  ;; `cl-intersection''s result is in the *reverse* of LIST2's order -
  ;; no `nreverse', as `cl-seq.el:896' has none - and `cl-delete-
  ;; duplicates' keeps the last of a run of duplicates (the first with
  ;; `:from-end'). Both are measured, not assumed.
  ;;
  ;; **A `:test` is a procedure.** Emacs's cl-lib accepts the *symbol* of
  ;; one (`:test 'string-equal`) and `funcall`s it through the obarray;
  ;; a symbol is not applicable here, so the ported call passes the
  ;; procedure itself, which is how the translated `cc-langs.el` VALs
  ;; are written.
  ;;
  ;; **Not carried, each because nothing here uses it:** `:start',
  ;; `:end', `:if' and `:if-not' (the three functions accept them in
  ;; Emacs; a call with one signals a clear error here rather than
  ;; silently ignoring it), the vector/string arms of `cl-delete-
  ;; duplicates', and `cl-member''s `:if'/`:if-not'. `cl-delete-
  ;; duplicates' is non-destructive here although Emacs's is not: a
  ;; Scheme quoted list need not be mutable, and no caller in the tree
  ;; observes the mutation.

  (import (scheme base))

  (export cl-member cl-set-difference cl-intersection cl-delete-duplicates)

  (begin

    (define-record-type <cl-sequence-keys>
      (%make-cl-sequence-keys test test-not key if-proc if-not start end
                              from-end)
      cl-sequence-keys?
      (test cl-sequence-keys-test)
      (test-not cl-sequence-keys-test-not)
      (key cl-sequence-keys-key)
      (if-proc cl-sequence-keys-if)
      (if-not cl-sequence-keys-if-not)
      (start cl-sequence-keys-start)
      (end cl-sequence-keys-end)
      (from-end cl-sequence-keys-from-end))

    (define (%cl-parse-keywords keys allowed)
      ;; `cl--parsing-keywords' (`cl-seq.el:50') for the keys these four
      ;; functions read. ALLOWED is the list of keyword symbols the
      ;; caller reads; any other keyword is Emacs's "Bad keyword
      ;; argument %s". A `:test-not' or `:if-not' sets the positive
      ;; slot and the `-not' flag, as the macro does.
      (let loop ((rest keys)
                 (test #f) (test-not #f) (key #f)
                 (if-proc #f) (if-not #f)
                 (start #f) (end #f) (from-end #f))
        (if (null? rest)
            (%make-cl-sequence-keys test test-not key if-proc if-not
                                    start end from-end)
            (let ((k (car rest)))
              (unless (memq k allowed)
                (error "Bad keyword argument ~a" k))
              (unless (pair? (cdr rest))
                (error "Bad keyword argument ~a" k))
              (let ((v (cadr rest)))
                (case k
                  ((:test) (loop (cddr rest) v test-not key if-proc if-not
                                 start end from-end))
                  ((:test-not) (loop (cddr rest) v #t key if-proc if-not
                                     start end from-end))
                  ((:key) (loop (cddr rest) test test-not v if-proc if-not
                                start end from-end))
                  ((:if) (loop (cddr rest) test test-not key v if-not
                               start end from-end))
                  ((:if-not) (loop (cddr rest) test test-not key v #t
                                   start end from-end))
                  ((:start) (loop (cddr rest) test test-not key if-proc
                                  if-not v end from-end))
                  ((:end) (loop (cddr rest) test test-not key if-proc
                                if-not start v from-end))
                  ((:from-end) (loop (cddr rest) test test-not key if-proc
                                     if-not start end v))))))))

    (define (%cl-check-key keys x)
      ;; `cl--check-key' (`cl-seq.el:80'): the `:key' function applied.
      (if (cl-sequence-keys-key keys)
          ((cl-sequence-keys-key keys) x)
          x))

    (define (%cl-check-test-nokey keys item x)
      ;; `cl--check-test-nokey' (`cl-seq.el:84'): the `:test' or `:if'
      ;; function's answer, negated for the `-not' spellings; with
      ;; neither, Emacs's `eql' - `eqv?' here.
      (let ((test (cl-sequence-keys-test keys))
            (if-proc (cl-sequence-keys-if keys)))
        (cond (test (eq? (not (test item x))
                         (cl-sequence-keys-test-not keys)))
              (if-proc (eq? (not (if-proc x))
                            (cl-sequence-keys-if-not keys)))
              (else (eqv? item x)))))

    (define (%cl-check-test keys item x)
      ;; `cl--check-test' (`cl-seq.el:92').
      (%cl-check-test-nokey keys item (%cl-check-key keys x)))

    (define (cl-member item list . keys)
      ;; GNU Emacs's `cl-member' (`cl-seq.el:740'): "Find the first
      ;; occurrence of ITEM in LIST. Return the sublist of LIST whose
      ;; car is ITEM."
      ;;
      ;; With no keyword the C falls to `memql' - `memv' here - where
      ;; every other function on this page takes the `memq' path; both
      ;; answer the same for symbols and numbers and #f for two equal
      ;; strings, which is the behaviour the language constants are
      ;; built against.
      ;;--------------------------------------------------------------
      (if (pair? keys)
          (let ((parsed (%cl-parse-keywords keys '(:test :test-not :key
                                                   :if :if-not))))
            (let loop ((rest list))
              (cond ((null? rest) #f)
                    ((%cl-check-test parsed item (car rest)) rest)
                    (else (loop (cdr rest))))))
          (memv item list)))

    (define (cl-set-difference list1 list2 . keys)
      ;; GNU Emacs's `cl-set-difference' (`cl-seq.el:931'): "Combine
      ;; LIST1 and LIST2 using a set-difference operation. The resulting
      ;; list contains all items that appear in LIST1 but not LIST2."
      ;;--------------------------------------------------------------
      ;; Emacs's nil is this tree's `#f` as well as its `'()`, and a
      ;; caller may hand either (`c-font-lock-declarators' hands the
      ;; `c-typedef' property, which is `#f' until a typedef has been
      ;; seen). Normalise both before the walk.
      (let ((list1 (if (pair? list1) list1 '()))
            (list2 (if (pair? list2) list2 '())))
        (if (or (null? list1) (null? list2))
            list1
            (let ((parsed (%cl-parse-keywords keys '(:test :test-not :key))))
            (let loop ((rest list1) (res '()))
              (cond ((null? rest) (reverse res))
                    ((if (or (pair? keys) (number? (car rest)))
                         (apply cl-member (%cl-check-key parsed (car rest))
                                list2 keys)
                         (memq (car rest) list2))
                     (loop (cdr rest) res))
                    (else (loop (cdr rest) (cons (car rest) res)))))))))

    (define (cl-intersection list1 list2 . keys)
      ;; GNU Emacs's `cl-intersection' (`cl-seq.el:896'): "Combine LIST1
      ;; and LIST2 using a set-intersection operation."
      ;;
      ;; Emacs walks the *shorter* list and accumulates with `push',
      ;; never reversing, so the answer is in the reverse of that list's
      ;; order. Measured: `(cl-intersection '("a" "b" "c") '("b" "c"
      ;; "d"))' is `("c" "b")'.
      ;;--------------------------------------------------------------
      (and (pair? list1) (pair? list2)
           (if (equal? list1 list2)
               list1
               (let ((parsed (%cl-parse-keywords keys '(:test :test-not
                                                        :key))))
                 (if (>= (length list1) (length list2))
                     #f
                     (let ((tmp list1))
                       (set! list1 list2)
                       (set! list2 tmp)))
                 (let loop ((rest list2) (res '()))
                   (cond ((null? rest) res)
                         ((if (or (pair? keys) (number? (car rest)))
                              (apply cl-member (%cl-check-key parsed
                                                              (car rest))
                                     list1 keys)
                              (memq (car rest) list1))
                          (loop (cdr rest) (cons (car rest) res)))
                         (else (loop (cdr rest) res))))))))

    (define (cl-delete-duplicates seq . keys)
      ;; GNU Emacs's `cl-delete-duplicates' (`cl-seq.el:369'): "Remove
      ;; all duplicate elements from SEQ."
      ;;
      ;; The answer is Emacs's: without `:from-end' the *last* of a run
      ;; of duplicates survives, in its place in the order; with it the
      ;; first. `:start'/`:end'/`:if'/`:if-not' are not carried (see
      ;; this library's header).
      ;;--------------------------------------------------------------
      (unless (list? seq)
        (error "`cl-delete-duplicates' here takes a list, not ~a" seq))
      (let ((parsed (%cl-parse-keywords keys '(:test :test-not :key
                                               :from-end))))
        (when (or (cl-sequence-keys-start parsed)
                  (cl-sequence-keys-end parsed)
                  (cl-sequence-keys-if parsed)
                  (cl-sequence-keys-if-not parsed))
          (error "`cl-delete-duplicates': :start/:end/:if/:if-not are not carried"))
        (let loop ((rest seq) (out '()))
          (cond ((null? rest) (reverse out))
                ((%cl-delete-duplicates-present?
                  parsed (%cl-check-key parsed (car rest))
                  (if (cl-sequence-keys-from-end parsed)
                      (reverse out)       ; already-emitted elements
                      (cdr rest)))
                 (loop (cdr rest) out))
                (else (loop (cdr rest) (cons (car rest) out)))))))

    (define (%cl-delete-duplicates-present? keys item candidates)
      ;; Does ITEM match any of CANDIDATES - the direction Emacs's
      ;; `cl--position' scan asks, with the same `cl--check-test'.
      ;;--------------------------------------------------------------
      (let loop ((rest candidates))
        (cond ((null? rest) #f)
              ((%cl-check-test keys item (car rest)) #t)
              (else (loop (cdr rest))))))

    ))
