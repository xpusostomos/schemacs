(define-library (schemacs editor subr)
  ;; This library mirrors GNU Emacs's `subr.el': the small general
  ;; functions the rest of Emacs is written in terms of.
  ;;
  ;; What is here so far is one of them, `add-to-history', which the kill
  ;; ring and the mark ring both push onto. Subr is enormous and mostly
  ;; elisp-layer; it grows as the things that need it arrive.

  (import
    (scheme base)
    ;; `history-length' and `history-delete-duplicates' are `minibuf.c''s
    ;; variables, and `add-to-history' reads them for the maximum length
    ;; when the caller does not give one.
    (only (schemacs editor minibuf)
          *history-delete-duplicates* *history-length*)
    ;; `delete' is Guile's - R7RS has no list `delete'.
    (only (guile) delete)
    )

  (export
   add-to-history
   nthcdr
   )

  (begin

    (define (nthcdr n list)
      ;; GNU Emacs's `nthcdr': the tail of LIST after the first N
      ;; elements - and nil when the list is shorter than that, which is
      ;; the whole point of having it: Scheme's `list-tail' is an error
      ;; there, and Elisp's sloppiness is what the callers rely on.
      ;;--------------------------------------------------------------
      (let loop ((n n) (rest list))
        (if (or (<= n 0) (not (pair? rest)))
            rest
            (loop (- n 1) (cdr rest)))))

    (define (add-to-history history-list newelt . args)
      ;; GNU Emacs's `add-to-history': HISTORY-LIST with NEWELT on the
      ;; front, duplicates of it removed when
      ;; `history-delete-duplicates' says so, and the list cut back to
      ;; MAXELT - which answers with `history-length' when the caller
      ;; does not give one.
      ;;
      ;; It takes the list and answers a new one, rather than taking a
      ;; variable's name as Emacs's does: a Scheme procedure cannot set a
      ;; variable the caller names, so the setting is the caller's.
      ;;--------------------------------------------------------------
      (let* ((maxelt (if (pair? args) (car args) #f))
             (keep-all (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f))
             (maxelt (or maxelt (*history-length*))))
        (if (and (list? history-list)
                 (or keep-all
                     (not (string? newelt))
                     (< 0 (string-length newelt)))
                 ;; Elisp's `(car nil)' is nil, so Emacs's test is
                 ;; true for an empty list; Scheme's is an error, so
                 ;; the emptiness is tested for.
                 (or keep-all
                     (not (and (pair? history-list)
                               (equal? (car history-list) newelt)))))
            (let* ((history (if (*history-delete-duplicates*)
                                (delete newelt history-list)
                                history-list))
                   (history (cons newelt history)))
              (cond
               ((not (integer? maxelt)) history)
               ((<= maxelt 0) '())
               (else
                (let ((tail (nthcdr (- maxelt 1) history)))
                  (if (pair? tail) (set-cdr! tail '()))
                  history))))
            history-list)))

    ))
