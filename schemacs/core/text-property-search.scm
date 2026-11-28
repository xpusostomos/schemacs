(define-library (schemacs core text-property-search)
  ;; GNU Emacs's `lisp/emacs-lisp/text-property-search.el' - "search for
  ;; text properties" - in the file's own order.
  ;;
  ;; **The two commands' interactive specifications are not carried.**
  ;; Emacs's prompt completes over `obarray', which this tree does not
  ;; have (see AGENTS.md's "no obarray" note); nothing calls them
  ;; interactively yet - `compile.el' is the library's one consumer and
  ;; calls the functions programmatically - so they are plain
  ;; procedures here rather than `define-command's, and `M-x' does not
  ;; list them.  The behaviour a caller sees is Emacs's.
  ;;
  ;; `prop-match' is Emacs's `cl-defstruct' as a record; its accessors
  ;; keep the struct's names.

  (import
    (scheme base)
    (only (guile) caddr)
    (only (schemacs editfns) point point-min point-max goto-char eobp bobp)
    (only (schemacs textprop)
          get-text-property next-single-property-change
          previous-single-property-change))

  (export prop-match? make-prop-match prop-match-beginning prop-match-end
          prop-match-value
          text-property-search-forward text-property-search-backward
          text-property--find-end-forward text-property--find-end-backward
          text-property--match-p)

  (begin
    (define-record-type <prop-match>
      (make-prop-match beginning end value)
      prop-match?
      (beginning prop-match-beginning)
      (end prop-match-end)
      (value prop-match-value))

    (define (text-property-search-forward property . rest)
      "Search for next region of text where PREDICATE returns non-nil for PROPERTY.
PREDICATE is used to decide whether the value of PROPERTY at a given
buffer position should be considered as a match for VALUE.
VALUE defaults to nil if omitted.

If PREDICATE is a function, it will be called with two arguments:
VALUE and the value of PROPERTY at some buffer position.  The function
should return non-nil if these two values are to be considered a match.

Two special values of PREDICATE can also be used:
If PREDICATE is t, that means the value of PROPERTY must `equal' VALUE
to be considered a match.
If PREDICATE is nil (which is the default), the value of PROPERTY will
match if it is not `equal' to VALUE.  Furthermore, a nil PREDICATE
means that the match region ends where the value changes.

If NOT-CURRENT is non-nil, current buffer position is not examined for
matches: the function will search for the first region that doesn't
include point and has a value of PROPERTY that matches VALUE.

If no matches can be found, return nil and don't move point.
If found, move point to the end of the region and return a
`prop-match' object describing the match."
      ;; `text-property-search.el:32'.
      ;;--------------------------------------------------------------
      (let ((value (if (pair? rest) (car rest) #f))
            (predicate (if (and (pair? rest) (pair? (cdr rest)))
                           (cadr rest)
                           #f))
            (not-current (if (and (pair? rest) (pair? (cdr rest))
                                  (pair? (cddr rest)))
                             (caddr rest)
                             #f)))
        (cond
         ;; No matches at the end of the buffer.
         ((eobp) #f)
         ;; We're standing in the property we're looking for, so find the
         ;; end.
         ((and (text-property--match-p
                value (get-text-property (point) property) predicate)
               (not not-current))
          (text-property--find-end-forward (point) property value predicate))
         (else
          (let ((origin (point))
                (ended #f)
                (pos #f))
            ;; Find the next candidate.
            (let loop ()
              (unless ended
                (set! pos (next-single-property-change (point) property))
                (if (not pos)
                    (begin
                      (goto-char origin)
                      (set! ended #t))
                    (begin
                      (goto-char pos)
                      (if (text-property--match-p
                           value (get-text-property (point) property)
                           predicate)
                          (set! ended
                                (text-property--find-end-forward
                                 (point) property value predicate))
                          ;; Skip past this section of non-matches.
                          (begin
                            (set! pos
                                  (next-single-property-change
                                   (point) property))
                            (unless pos
                              (goto-char origin)
                              (set! ended #t))))))
                (loop)))
            (and (not (eq? ended #t)) ended))))))

    (define (text-property--find-end-forward start property value predicate)
      ;; `text-property-search.el:109'.
      ;;--------------------------------------------------------------
      (let ((end #f))
        (if (and value (not predicate))
            ;; This is the normal case: We're looking for areas where the
            ;; values aren't, so we aren't interested in sub-areas where the
            ;; property has different values, all non-matching value.
            (let ((ended #f))
              (let loop ()
                (unless ended
                  (set! end (next-single-property-change (point) property))
                  (if (not end)
                      (begin
                        (goto-char (point-max))
                        (set! end (point))
                        (set! ended #t))
                      (begin
                        (goto-char end)
                        (unless (text-property--match-p
                                 value (get-text-property (point) property)
                                 predicate)
                          (set! ended #t))))
                  (loop))))
            ;; End this at the first place the property changes value.
            (begin
              (set! end (next-single-property-change
                         (point) property #f (point-max)))
              (goto-char end)))
        (make-prop-match start end (get-text-property start property))))

    (define (text-property-search-backward property . rest)
      "Search for previous region of text where PREDICATE returns non-nil for PROPERTY.

Like `text-property-search-forward', which see, but searches backward,
and if a matching region is found, place point at the start of the region."
      ;; `text-property-search.el:136'.
      ;;--------------------------------------------------------------
      (let ((value (if (pair? rest) (car rest) #f))
            (predicate (if (and (pair? rest) (pair? (cdr rest)))
                           (cadr rest)
                           #f))
            (not-current (if (and (pair? rest) (pair? (cdr rest))
                                  (pair? (cddr rest)))
                             (caddr rest)
                             #f)))
        (cond
         ;; We're at the start of the buffer; no previous matches.
         ((bobp) #f)
         ;; We're standing in the property we're looking for, so find the
         ;; end.
         ((text-property--match-p
           value (get-text-property (- (point) 1) property) predicate)
          (let ((origin (point))
                (match (text-property--find-end-backward
                        (- (point) 1) property value predicate)))
            ;; When we want to ignore the current element, then repeat the
            ;; search if we haven't moved out of it yet.
            (if (and not-current
                     (equal? (get-text-property (point) property)
                             (get-text-property origin property)))
                (text-property-search-backward property value predicate
                                               not-current)
                match)))
         (else
          (let ((origin (point))
                (ended #f)
                (pos #f))
            ;; Find the previous candidate.
            (let loop ()
              (unless ended
                (set! pos (previous-single-property-change (point) property))
                (if (not pos)
                    (begin
                      (goto-char origin)
                      (set! ended #t))
                    (begin
                      (goto-char pos)
                      (if (text-property--match-p
                           value
                           (get-text-property (- (point) 1) property)
                           predicate)
                          (set! ended
                                (text-property--find-end-backward
                                 (- (point) 1) property value predicate))
                          ;; Skip past this section of non-matches.
                          (begin
                            (set! pos
                                  (previous-single-property-change
                                   (point) property))
                            (unless pos
                              (goto-char origin)
                              (set! ended #t))))))
                (loop)))
            (and (not (eq? ended #t)) ended))))))

    (define (text-property--find-end-backward start property value predicate)
      ;; `text-property-search.el:191'.
      ;;--------------------------------------------------------------
      (let ((end #f))
        (if (and value (not predicate))
            ;; This is the normal case: We're looking for areas where the
            ;; values aren't, so we aren't interested in sub-areas where the
            ;; property has different values, all non-matching value.
            (let ((ended #f))
              (let loop ()
                (unless ended
                  (set! end (previous-single-property-change (point) property))
                  (if (not end)
                      (begin
                        (goto-char (point-min))
                        (set! end (point))
                        (set! ended #t))
                      (begin
                        (goto-char end)
                        (unless (text-property--match-p
                                 value (get-text-property (- (point) 1) property)
                                 predicate)
                          (goto-char end)
                          (set! ended #t))))
                  (loop))))
            ;; End this at the first place the property changes value.
            (begin
              (set! end
                    (if (and (> (point) (point-min))
                             (text-property--match-p
                              value (get-text-property (- (point) 1) property)
                              predicate))
                        (previous-single-property-change
                         (point) property #f (point-min))
                        (point)))
              (goto-char end)))
        (make-prop-match end (+ 1 start) (get-text-property end property))))

    (define (text-property--match-p value prop-value predicate)
      ;; `text-property-search.el:225'.
      ;;--------------------------------------------------------------
      (cond
       ((eq? predicate #t)
        (set! predicate equal?))
       ((not predicate)
        (set! predicate (lambda (val p-val) (not (equal? val p-val))))))
      (predicate value prop-value))

    ))
