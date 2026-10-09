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
    ;; `char-alphabetic?' / `char-numeric?', which the word-constituent
    ;; predicate is built from - they arrived with the word motions from
    ;; `simple.sld', which had them imported.
    (scheme char)
    (only (schemacs editor engine)
          text-editor-get-cursor text-editor-get-char-index
          text-editor-point-min text-editor-point-max
          text-editor-set-cursor)
    (only (schemacs editor buffer) current-buffer)
    )

  (export
   skip-chars-forward
   skip-chars-backward
   word-char?
   forward-word-position backward-word-position
   word-run-end word-run-start
   )

  (begin

    (define (word-char? c)
      ;; The word-constituent predicate - the C's `WORD_CONSTITUENT'
      ;; (`syntax.h': "True if the character has word syntax"), which
      ;; `SYNTAX (c) == Sword' decides from the syntax table.
      ;;
      ;; **Its Emacs home is this file, and it was in `simple.sld`** -
      ;; as mg's `inword'/ISWORD, which is where the tree's word motions
      ;; came from. **The word motions moved with it**, and the import
      ;; graph is what shows the placement was wrong: `search.sld` and
      ;; `casefiddle.sld` both took word motion from `simple.sld`, and
      ;; both of those files belong *below* `simple.el` - `forward-word`
      ;; and `backward-word` are `syntax.c` DEFUNs (`scan_words`,
      ;; `syntax.c:1222' is their shared walk). Two lone imports made
      ;;
      ;;     simple -> select -> coding -> search -> simple
      ;;
      ;; a cycle, which no port of `coding.c` reachable from `select.el`
      ;; can live with. `simple.sld` imports this library already and
      ;; re-exports the names, so every existing importer is unchanged.
      ;;
      ;; Here it is still mg's `inword`/ISWORD: alphanumeric plus the
      ;; underscore. When the syntax tables come, this becomes
      ;; `SYNTAX (c) == Sword'.
      ;;--------------------------------------------------------------
      (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

    ;; The walk, mg's `forwword`/`backword` (`word.c`). The C's walk
    ;; moves point and answers a count of *words*; these answer a
    ;; position and leave the cursor alone, because that is the shape
    ;; every caller in this tree was written against - `word-run-end`
    ;; sets the cursor itself, walking the motion. The two `word-run-*`
    ;; names are mg's `delfword`/`delbword` counting loops and have no C
    ;; counterpart.
    ;;------------------------------------------------------------------

    (define (%char-at ed index)
      (text-editor-get-char-index ed index))

    (define (%inword-at ed index)
      ;; like mg's `inword`, over absolute character indices
      ;;--------------------------------------------------------------
      (let ((c (%char-at ed index)))
        (and c (word-char? c))))

    (define (forward-word-position ed)
      ;; Like mg's `forwword` (word.c:51): skip over non-word
      ;; characters, then over word characters. Returns the *position*
      ;; of the end of the next word - so `point-max' when there is no
      ;; word left, and the end of the word otherwise.
      ;;--------------------------------------------------------------
      (let ((max (text-editor-point-max ed)))
        (let loop ((i (text-editor-get-cursor ed)) (phase 'skip))
          (cond
           ((>= i max) max)
           ((eq? phase 'skip)
            (if (%inword-at ed i) (loop i 'word) (loop (+ i 1) 'skip)))
           (else
            (if (%inword-at ed i) (loop (+ i 1) 'word) i))))))

    (define (backward-word-position ed)
      ;; Like mg's `backword` (word.c:27): step back one character,
      ;; skip back over non-word characters, then back over word
      ;; characters, and step forward once, landing on the first
      ;; character of the word.
      ;;--------------------------------------------------------------
      (let ((i0 (text-editor-get-cursor ed))
            (min (text-editor-point-min ed)))
        (if (<= i0 min) min
            (let loop ((i (- i0 1)) (phase 'skip))
              (cond
               ((< i min) min)
               ((eq? phase 'skip)
                (if (%inword-at ed i) (loop i 'word) (loop (- i 1) 'skip)))
               (else
                (if (%inword-at ed i) (loop (- i 1) 'word) (+ i 1))))))))

    (define (word-run-end ed count)
      ;; The character index COUNT words forward of point, found the way
      ;; mg's `delfword' (word.c:397) counts its `size' before deleting:
      ;; walk the word motion, stopping when it stops advancing (the end
      ;; of the buffer).
      ;;--------------------------------------------------------------
      (let loop ((i 0) (pos (text-editor-get-cursor ed)))
        (if (>= i count)
            pos
            (begin
              (text-editor-set-cursor ed pos)
              (let ((next (forward-word-position ed)))
                (if (= next pos) pos (loop (+ 1 i) next)))))))

    (define (word-run-start ed count)
      ;; The character index COUNT words back from point, the mirror of
      ;; `word-run-end' and the way mg's `delbword' (word.c:453) counts.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (pos (text-editor-get-cursor ed)))
        (if (>= i count)
            pos
            (begin
              (text-editor-set-cursor ed pos)
              (let ((prev (backward-word-position ed)))
                (if (= prev pos) prev (loop (+ 1 i) prev)))))))

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
