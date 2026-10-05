(define-library (schemacs editor buffer-text)
  ;; GNU Emacs's `struct buffer_text' (`buffer.h':240): the text of a
  ;; buffer - the characters, the gap, and where the gap sits.
  ;;
  ;; Emacs keeps this as a C struct of five fields and reaches into it
  ;; through macros - `BEG_ADDR', `GPT', `Z', `GAP_SIZE', and the
  ;; address macros that subtract `BEG_BYTE' on every access. This is
  ;; those same five fields as an object with methods. **Emacs has no
  ;; such class**, so the class itself is a deliberate structural
  ;; departure; everything inside it is the struct and the arithmetic,
  ;; named rather than smeared through pointer macros.
  ;;
  ;; The layout is Emacs's, exactly. With `base' 1:
  ;;
  ;;   store index   0 ......gpt-base......gpt-base+gap-size......z-base
  ;;   contents      |  before  |    the gap    |       after        |
  ;;
  ;; `z' is a *position* - it is `point-max' - so the character count
  ;; is `(- z base)' and the allocation is that plus `gap-size'. Indices
  ;; into the store are 0-based; positions are `base'-based. `base' is
  ;; added or subtracted only at this API's edge, so every caller above
  ;; speaks one coordinate system.
  ;;
  ;; `BASE' IS A CONVENTION, NOT A KNOB. It is a parameter only so the
  ;; convention is written down instead of being a bare `1' in the
  ;; arithmetic (Emacs hard-codes `BEG = 1'). Two buffer-texts with
  ;; different bases cannot exchange positions - and positions do
  ;; travel, through markers and `insert-buffer-substring' - so every
  ;; instance must be built with the same base. Pass 1.
  ;;
  ;; Why not tiered or chunked: this is the simple implementation, on
  ;; purpose. Emacs's own gap buffer is one array of bytes; ours is one
  ;; `u32vector' of code points, which is the same thing with the
  ;; encoding removed. Tiers (a narrower store while the text allows
  ;; it) and chunking would go *inside* this class and change nothing
  ;; above it - that is the whole point of the boundary.

  (import
    (scheme base)
    (scheme case-lambda)
    (only (schemacs vector)
          make-u32vector u32vector? u32vector-ref u32vector-set!
          u32vector-length
          )
    ;; The ranged copy. `u32vector-copy!' does not exist, `vector-copy!'
    ;; refuses a `u32vector', and `array-copy!' is whole-array only - so
    ;; the one shift this class does is `%array-copy-range!'.
    (only (schemacs arrays)
          %array-copy-range!
          )
    )

  (export
   new-buffer-text  buffer-text-type?
   buffer-text-base  buffer-text-z
   buffer-text-length  buffer-text-allocation  buffer-text-gap-size
   buffer-text-ref  buffer-text-set!
   buffer-text-insert!  buffer-text-delete!  buffer-text-substring
   buffer-text-for-each
   buffer-text-clear!
   buffer-text-beg-unchanged  set!buffer-text-beg-unchanged
   *gap-bytes-dfl*  *gap-bytes-min*
   )

  (begin

    (define *gap-bytes-dfl* 2000)   ;; buffer.h:205
    (define *gap-bytes-min* 20)     ;; buffer.h:210

    (define-record-type <buffer-text-type>
      (make<buffer-text> base store gpt z gap-size beg-unchanged)
      buffer-text-type?
      (base     buffer-text-base)
      ;; ^ The coordinate base of every *position* this class answers,
      ;; and of `gpt' and `z' below. Emacs's `BEG' is 1.
      (store    buffer-text-store   set!buffer-text-store)
      ;; ^ The backing `u32vector': code points, one per element.
      (gpt      buffer-text-gpt     set!buffer-text-gpt)
      ;; ^ The gap position - Emacs's `GPT'. Its store index is
      ;; `(- gpt base)'.
      (z        buffer-text-z       set!buffer-text-z)
      ;; ^ The end position - Emacs's `Z', the struct's own field and
      ;; the answer to `point-max'. The character count is `(- z base)'.
      (gap-size buffer-text-gap-size set!buffer-text-gap-size)
      ;; ^ The number of unused elements - Emacs's `GAP_SIZE'.
      (beg-unchanged buffer-text-beg-unchanged
                     set!buffer-text-beg-unchanged)
      ;; ^ How many characters at the beginning of the buffer are known
      ;; not to have changed since the caches were last told that
      ;; everything is current - GNU Emacs's `beg_unchanged'
      ;; (`buffer.h:149'), a field of `struct buffer_text'. It is 0 for
      ;; a new buffer, which is the conservative answer: nothing is
      ;; known until something says so.
      ;;
      ;; Emacs keeps `end_unchanged' beside it, and `insert_1_both'
      ;; shrinks both to `GPT - BEG' and `Z - GPT' on every modification
      ;; (`insdel.c:1608'). Its readers are `window_outdated' and
      ;; `redisplay_internal''s frame-based redisplay, and neither is
      ;; ported; the one reader here is the `%l' cache's freshness test,
      ;; which the C spells `BASE_LINE_NUMBER_VALID_P' (`xdisp.c:19393').
      )

    ;;----------------------------------------------------------------
    ;; Positions and indices
    ;;
    ;; Everything below this line is 0-based store indices; everything
    ;; at the API is a `base'-based position. The conversion is these
    ;; two helpers and nothing else.

    (define (%index bt pos)
      ;; The store index of POSITION, ignoring the gap.
      (- pos (buffer-text-base bt))
      )

    (define (%position bt i)
      ;; The position of a store index.
      (+ i (buffer-text-base bt))
      )

    (define (%at bt i)
      ;; The store index of text index `I`, the gap taken into account -
      ;; Emacs's `BYTE_POS_ADDR' (buffer.h:1078) without the bytes.
      ;; Everything before the gap is where it says; everything after it
      ;; is `gap_size' further on.
      ;;--------------------------------------------------------------
      (let ((gpt-i (- (buffer-text-gpt bt) (buffer-text-base bt))))
        (if (< i gpt-i) i (+ i (buffer-text-gap-size bt)))
        ))

    ;;----------------------------------------------------------------
    ;; Sizes

    (define (buffer-text-length bt)
      ;; The number of characters - Emacs's `Z - BEG', and what
      ;; `buffer-size' answers. A *count*, so it does not shift with the
      ;; base.
      ;;--------------------------------------------------------------
      (- (buffer-text-z bt) (buffer-text-base bt))
      )

    (define (buffer-text-allocation bt)
      ;; How many elements the store holds: the characters plus the gap
      ;; - Emacs's `Z_BYTE - BEG_BYTE + GAP_SIZE'.
      ;;--------------------------------------------------------------
      (+ (buffer-text-length bt) (buffer-text-gap-size bt))
      )

    ;;----------------------------------------------------------------
    ;; Making one

    (define new-buffer-text
      ;; A new, empty buffer-text whose positions start at `BASE' and
      ;; whose store has room for `SIZE' characters. The gap starts at
      ;; the beginning, as Emacs's does in a fresh buffer.
      ;;--------------------------------------------------------------
      (case-lambda
       ((base) (new-buffer-text base 0))
       ((base size)
        (make<buffer-text> base (make-u32vector size 0) base base size 0)
        )))

    ;;----------------------------------------------------------------
    ;; Growing
    ;;
    ;; Emacs's `make_gap' + `make_gap_larger' (insdel.c:583, :467):
    ;;
    ;;     make_gap_larger (max (nbytes_added, (Z - BEG) / 64));
    ;;     nbytes_added = min (nbytes_added + GAP_BYTES_DFL, ...);
    ;;
    ;; "get enough to last a while" - at least a sixty-fourth of the
    ;; text, plus GAP_BYTES_DFL. There is no doubling anywhere in Emacs;
    ;; `/64' is a measured choice (the comment at :583-600) that wastes
    ;; at most 1.5% where a doubling wastes up to half.
    ;;
    ;; Emacs's other bound, `BUF_BYTES_MAX', has no analogue here.

    (define (%grow-size allocation length shortfall)
      (+ allocation (max shortfall (quotient length 64)) *gap-bytes-dfl*)
      )

    (define (%realloc! bt new-allocation)
      ;; Rebuild the store `NEW-ALLOCATION' elements long with the gap
      ;; in the same place and that much wider. The before-segment does
      ;; not move; the after-segment is copied to the far end, which is
      ;; where it belongs for the new gap - Emacs's `make_gap_larger'
      ;; reaches the same layout with an extra `gap_left'.
      ;;--------------------------------------------------------------
      (let*((base    (buffer-text-base bt))
            (old     (buffer-text-store bt))
            (gpt-i   (- (buffer-text-gpt bt) base))
            (z-i     (- (buffer-text-z bt) base))
            (after   (- z-i gpt-i))
            (gap     (buffer-text-gap-size bt))
            (new     (make-u32vector new-allocation 0))
            )
        (when (< 0 gpt-i)
          (%array-copy-range! new 0 old 0 gpt-i)
          )
        ;; The characters after the gap end at `z + gap_size' - see
        ;; `BUF_Z_ADDR', which is `beg + gap_size + z_byte - BEG_BYTE' -
        ;; so they are the last `after' elements of the old store and
        ;; belong at the end of the new one.
        (when (< 0 after)
          (%array-copy-range! new (- new-allocation after)
                                   old (+ gpt-i gap) (+ z-i gap))
          )
        (set!buffer-text-store bt new)
        (set!buffer-text-gap-size bt (- new-allocation z-i))
        ))

    (define (%ensure! bt need)
      ;; Make sure `NEED' characters fit in the gap, growing as Emacs
      ;; does if they do not. `NEED' is the shortfall's whole amount,
      ;; as `insert_1_both' hands `make_gap' the amount it lacks
      ;; (insdel.c:915).
      ;;--------------------------------------------------------------
      (let ((shortfall (- need (buffer-text-gap-size bt))))
        (when (< 0 shortfall)
          (%realloc! bt (%grow-size (buffer-text-allocation bt)
                                    (buffer-text-length bt)
                                    shortfall))
          )))

    ;;----------------------------------------------------------------
    ;; Moving the gap
    ;;
    ;; Emacs's `move_gap_both' (insdel.c:94) - "Move gap to byte
    ;; position BYTEPOS". `gap_left' copies the characters above the new
    ;; gap position upwards, `gap_right' copies those below it
    ;; downwards; both are one `%array-copy-range!`, which gets the
    ;; overlap right in either direction.

    (define (%move-gap! bt pos)
      (let*((base  (buffer-text-base bt))
            (store (buffer-text-store bt))
            (gpt-i (- (buffer-text-gpt bt) base))
            (gap   (buffer-text-gap-size bt))
            (pos-i (%index bt pos))
            )
        (cond
         ((= pos-i gpt-i) (values))
         ((< pos-i gpt-i)
          ;; gap_left: the characters between POS and the gap move up
          ;; to sit just past the gap's new end.
          (%array-copy-range! store (+ pos-i gap) store pos-i gpt-i)
          )
         (else
          ;; gap_right: the characters between the gap's end and POS
          ;; move down to sit just after the gap's new start.
          (%array-copy-range! store gpt-i store (+ gpt-i gap) (+ pos-i gap))
          ))
        (set!buffer-text-gpt bt (%position bt pos-i))
        ))

    ;;----------------------------------------------------------------
    ;; Reading and writing

    (define (buffer-text-ref bt pos)
      ;; The code point at POSITION. An exact integer, as Emacs's
      ;; `FETCH_CHAR' answers and as elisp has it, where a character is
      ;; an integer.
      ;;--------------------------------------------------------------
      (u32vector-ref (buffer-text-store bt) (%at bt (%index bt pos)))
      )

    (define (buffer-text-set! bt pos cp)
      (u32vector-set! (buffer-text-store bt) (%at bt (%index bt pos)) cp)
      )

    (define (buffer-text-substring bt from to)
      ;; The characters in positions `FROM' up to `TO' as a string -
      ;; Emacs's `buffer-substring', and the same half-open range.
      ;;--------------------------------------------------------------
      (let*((store (buffer-text-store bt))
            (n     (- to from))
            (first (%index bt from))
            (out   (make-string n #\space))
            )
        (let loop ((i 0))
          (cond
           ((< i n)
            (string-set! out i
                         (integer->char
                          (u32vector-ref store (%at bt (+ first i)))))
            (loop (+ 1 i))
            ))
          )
        out
        ))

    (define (buffer-text-for-each bt proc)
      ;; Call `(PROC POSITION CODE-POINT)' for every character. The
      ;; positions come out in this class's coordinates, so the caller
      ;; never converts.
      ;;--------------------------------------------------------------
      (let*((store (buffer-text-store bt))
            (base  (buffer-text-base bt))
            (n     (buffer-text-length bt))
            )
        (let loop ((i 0))
          (cond
           ((< i n)
            (proc (%position bt i) (u32vector-ref store (%at bt i)))
            (loop (+ 1 i))
            ))
          )
        ))

    ;;----------------------------------------------------------------
    ;; Inserting and deleting
    ;;
    ;; Emacs's `insert_1_both' (insdel.c:906) and `del_range_2': move
    ;; the gap to where the edit goes, then adjust. Neither needs a
    ;; shift - `%move-gap!' has already done the only one there is.

    (define (buffer-text-insert! bt pos thing)
      ;; Insert the characters of `THING' at POSITION. `THING' is a
      ;; string: a Scheme string is a sequence of code points, and it is
      ;; what everything above here deals in, so the element type never
      ;; leaks out of this class.
      ;;--------------------------------------------------------------
      (cond
       ((not (string? thing)) (error "buffer-text-insert!: not a string" thing))
       ((= 0 (string-length thing)) (values))
       (else
        (let ((n (string-length thing)))
          (%ensure! bt n)
          (%move-gap! bt pos)
          (let*((base  (buffer-text-base bt))
                (store (buffer-text-store bt))
                (gpt-i (- (buffer-text-gpt bt) base))
                )
            (let loop ((i 0))
              (cond
               ((< i n)
                (u32vector-set! store (+ gpt-i i)
                                (char->integer (string-ref thing i)))
                (loop (+ 1 i))
                ))
              )
            ;; The characters took the front of the gap, so the gap
            ;; shrinks by exactly that much and the end moves with it.
            (set!buffer-text-gpt bt (+ (buffer-text-gpt bt) n))
            (set!buffer-text-z bt (+ (buffer-text-z bt) n))
            (set!buffer-text-gap-size bt (- (buffer-text-gap-size bt) n))
            )))))

    (define (buffer-text-delete! bt from to)
      ;; Delete the characters in positions `FROM' up to `TO'.
      ;;
      ;; No shift at all: `%move-gap!' puts the gap immediately before
      ;; them, so they are simply absorbed into it and the characters
      ;; after them are already in the right place.
      ;;--------------------------------------------------------------
      (let ((n (- to from)))
        (cond
         ((< n 0) (error "buffer-text-delete!: backwards range" from to))
         ((= n 0) (values))
         (else
          (%move-gap! bt from)
          (set!buffer-text-gap-size bt (+ (buffer-text-gap-size bt) n))
          (set!buffer-text-z bt (- (buffer-text-z bt) n))
          ))))

    (define (buffer-text-clear! bt)
      ;; Empty the text, keeping the allocation - Emacs's
      ;; `erase-buffer' (buffer.c:2472) with the store left sized.
      ;;--------------------------------------------------------------
      (let ((base  (buffer-text-base bt))
            ;; Read the allocation before emptying, since it is
            ;; derived from the length.
            (alloc (buffer-text-allocation bt))
            )
        (set!buffer-text-gpt bt base)
        (set!buffer-text-z bt base)
        (set!buffer-text-gap-size bt alloc)
        ))

    ))
