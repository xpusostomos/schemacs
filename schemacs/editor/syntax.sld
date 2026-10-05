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
          text-editor-point-min text-editor-point-max
          text-editor-set-cursor)
    (only (schemacs editor buffer) current-buffer)
    )

  (export
   skip-chars-forward
   skip-chars-backward
   )

  (begin

    ;; `point', `point-min' and `point-max' are `editfns.c''s names for
    ;; what the engine answers as `text-editor-get-cursor' and the two
    ;; bounds. They are the same values under private names here, so the
    ;; walks below read like the C they are ported from:
    ;; `(schemacs editor editfns)' imports this library, so this one
    ;; cannot import that back.
    (define (%point ed) (text-editor-get-cursor ed))
    (define (%point-min ed) (text-editor-point-min ed))
    (define (%point-max ed) (text-editor-point-max ed))

    (define (skip-chars-forward set . rest)
      ;; GNU Emacs's `skip-chars-forward' (syntax.c:1618): "Move point
      ;; forward, stopping before a character not in SET" - and answer
      ;; the distance moved. With the optional BOUND, no farther than
      ;; that position. The C moves point and answers the count; so does
      ;; this, the cursor being the engine's.
      ;;
      ;; BOUND is a position, one-based as every position here is. The C
      ;; clips it to the buffer's end (`skip_chars', syntax.c:1470).
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (bound (if (pair? rest) (car rest) #f))
             (lim (min (or bound (%point-max ed)) (%point-max ed)))
             (members (string->list set)))
        (let loop ((pos (%point ed)) (moved 0))
          (if (>= pos lim)
              moved
              (let ((c (text-editor-get-char-index ed pos)))
                (if (and c (memv c members))
                    (begin
                      (text-editor-set-cursor ed (+ pos 1))
                      (loop (+ pos 1) (+ moved 1)))
                    moved))))))

    (define (skip-chars-backward set . rest)
      ;; GNU Emacs's `skip-chars-backward' (syntax.c:1633): the mirror -
      ;; "Move point backward, stopping before a character not in SET."
      ;; BOUND is a position, and the C clips it to the buffer's
      ;; beginning.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (bound (if (pair? rest) (car rest) #f))
             (lim (max (or bound (%point-min ed)) (%point-min ed)))
             (members (string->list set)))
        (let loop ((pos (%point ed)) (moved 0))
          (if (<= pos lim)
              moved
              (let ((c (text-editor-get-char-index ed (- pos 1))))
                (if (and c (memv c members))
                    (begin
                      (text-editor-set-cursor ed (- pos 1))
                      (loop (- pos 1) (+ moved 1)))
                    moved))))))

    ))
