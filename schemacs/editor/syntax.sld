(define-library (schemacs editor syntax)
  ;; This library mirrors GNU Emacs's `syntax.c': the character-skipping
  ;; primitives. What is here is `skip-chars-forward' and
  ;; `skip-chars-backward' - "Move point past characters in SET, like
  ;; `[ \t]'" - with point moved and the distance answered. The SET is
  ;; the string of characters to skip, which here is scanned with
  ;; `memv'; the C's bracket expressions (`^', ranges, character
  ;; classes) are what a regexp-grade reader would give, and are not
  ;; ported - every caller in the tree passes a plain character list
  ;; like " \t".
  ;;
  ;; The rest of syntax.c - the syntax tables, `looking-at' and the
  ;; `forward-sexp' family - waits for that same machinery.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (only (schemacs editor engine)
          text-editor-get-cursor text-editor-get-char-index
          text-editor-char-count text-editor-set-cursor)
    (only (schemacs editor frame) current-editor)
    )

  (export
   skip-chars-forward
   skip-chars-backward
   )

  (begin

    (define (skip-chars-forward set . rest)
      ;; GNU Emacs's `skip-chars-forward' (syntax.c:1618): "Move point
      ;; forward, stopping before a character not in SET" - and answer
      ;; the distance moved. With the optional BOUND, no farther than
      ;; that position. The C moves point and answers the count; so
      ;; does this, the cursor being the engine's.
      ;;--------------------------------------------------------------
      (let* ((ed (current-editor))
             (bound (if (pair? rest) (car rest) #f))
             (members (string->list set)))
        (let loop ((i (text-editor-get-cursor ed))
                   (moved 0)
                   ;; BOUND is a one-based position, the engine's index
                   ;; one below it
                   (count (if bound
                              (min (- bound 1) (text-editor-char-count ed))
                              (text-editor-char-count ed))))
          (if (>= i count)
              moved
              (let ((c (text-editor-get-char-index ed i)))
                (if (and c (memv c members))
                    (begin
                      (text-editor-set-cursor ed (+ i 1))
                      (loop (+ i 1) (+ moved 1) count))
                    moved))))))

    (define (skip-chars-backward set . rest)
      ;; GNU Emacs's `skip-chars-backward' (syntax.c:1633): the mirror
      ;; - "Move point backward, stopping before a character not in
      ;; SET."
      ;;--------------------------------------------------------------
      (let* ((ed (current-editor))
             (bound (if (pair? rest) (car rest) #f))
             (members (string->list set)))
        (let loop ((i (text-editor-get-cursor ed))
                   (moved 0)
                   (floor (if bound bound 0)))
          (if (<= i floor)
              moved
              (let ((c (text-editor-get-char-index ed (- i 1))))
                (if (and c (memv c members))
                    (begin
                      (text-editor-set-cursor ed (- i 1))
                      (loop (- i 1) (+ moved 1) floor))
                    moved))))))

    ))