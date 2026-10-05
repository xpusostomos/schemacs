(define-library (schemacs editor region-cache)
  ;; A port of GNU Emacs's `region-cache.c' - "Caching facts about
  ;; regions of the buffer, for optimization".
  ;;
  ;; Emacs finds line beginnings and ends by searching for newlines, and
  ;; for a buffer of ordinary lines that is the right design: the scan
  ;; costs about what keeping some cleverer structure would. It stops
  ;; being right for *very long* lines - `region-cache.c' names gene
  ;; editing, "lines on the order of tens of kilobytes" - where every
  ;; scan over one line costs tens of thousands of characters.
  ;;
  ;; So the cache notes regions it has already searched and found no
  ;; newline in, and the next search skips them whole. It holds
  ;; "known/unknown" information about regions rather than anything
  ;; about newlines specifically: `know-region-cache' says "this region
  ;; has the property", and the scanning functions answer "known, and it
  ;; has it", "known, and it does not", or "not known".
  ;;
  ;; The representation is a sorted array of boundaries, each a position
  ;; and a value applying to every character after it until the next
  ;; boundary. There is always a boundary at the buffer's beginning. To
  ;; keep insertions and deletions cheap the array has a *gap*, as the
  ;; text buffer does, and to let boundary positions float with edits
  ;; the positions before the gap are stored relative to the buffer's
  ;; beginning and those after it relative to the buffer's end. A
  ;; modification invalidates rather than repairs - `window.c' /
  ;; `insdel.c' call `invalidate-region-cache' on every change, and the
  ;; mess it leaves is cleaned up in one go by the next reader.
  ;;
  ;; Where this port departs, and why:
  ;;
  ;;  - The C reaches the buffer through `struct buffer *' and the `BEG'
  ;;    / `Z' macros. Here the caller passes the two endpoints, since
  ;;    this library sits under the engine and cannot see a
  ;;    `<text-editor-type>'. They are the arguments `buf' stands for.
  ;;
  ;;  - A boundary is a pair rather than a two-field C struct, and the
  ;;    array is a Scheme vector. The gap arithmetic is the C's.
  ;;
  ;;  - `xpalloc' grows an array by about 50% (`n = n0 + n0 / 2'),
  ;;    raised to whatever the caller needs. `%grow-boundaries!' is that
  ;;    policy, with no doubling anywhere - the tree had two doublings
  ;;    in it once and Emacs has none (see AGENTS.md).
  ;;
  ;;  - `pp_cache', the `ENABLE_CHECKING' pretty-printer, is not ported.
  ;;------------------------------------------------------------------
  (import
    (scheme base))

  (export
   new-region-cache
   know-region-cache
   invalidate-region-cache
   region-cache-forward
   region-cache-backward
   region-cache-boundaries      ; for tests: how many boundaries there are
   )

  (begin

    ;; How many elements to add to the gap when the array is resized.
    (define *new-cache-gap* 40)

    ;; If an invalidation would throw away information about this many
    ;; characters, revalidate the cache first to preserve it rather than
    ;; discarding it.
    (define *preserve-threshold* 500)

    (define-record-type <region-cache>
      (make<region-cache> boundaries gap-start gap-len cache-len
                          beg-unchanged end-unchanged buffer-beg buffer-end)
      region-cache?
      ;; ^ A sorted array of the positions where the known-ness of the
      ;; buffer changes, each with the value that applies from it on.
      (boundaries %cache-boundaries set!%cache-boundaries)
      ;; ^ `boundaries[gap-start ... gap-start + gap-len - 1]' is the gap.
      ;;
      ;; The gap is why a boundary's position is stored *relative*: those
      ;; before the gap relative to the buffer's beginning, those after
      ;; it relative to the buffer's end, so that an insertion or a
      ;; deletion at one end moves the boundaries at the other end
      ;; without touching them.
      (gap-start %cache-gap-start set!%cache-gap-start)
      (gap-len %cache-gap-len set!%cache-gap-len)
      ;; ^ The number of boundaries, not counting the gap.
      (cache-len %cache-len set!%cache-len)
      ;; ^ The areas that have not changed since the cache was last
      ;; cleaned out of invalid entries. These overlap when the buffer is
      ;; entirely unchanged.
      (beg-unchanged %cache-beg-unchanged set!%cache-beg-unchanged)
      (end-unchanged %cache-end-unchanged set!%cache-end-unchanged)
      ;; ^ The buffer's endpoints as the cache last knew them. Because
      ;; boundary positions are relative to them, a position can be read
      ;; back correctly without being told the buffer.
      (buffer-beg %cache-buffer-beg set!%cache-buffer-beg)
      (buffer-end %cache-buffer-end set!%cache-buffer-end))

    (define (region-cache-boundaries c)
      ;; How many boundaries the cache holds. Not in the C; the tests
      ;; read it to check that a boundary is neither added nor left
      ;; behind where it should not be.
      ;;--------------------------------------------------------------
      (%cache-len c))

    ;;----------------------------------------------------------------
    ;; Reading a boundary - the C's BOUNDARY_POS, BOUNDARY_VALUE and
    ;; SET_BOUNDARY_VALUE macros. An index at or after the gap is stored
    ;; after it in the array, hence the `+ gap-len'.
    ;;------------------------------------------------------------------

    (define (%boundary-slot c i)
      ;; The array index of boundary I.
      ;;--------------------------------------------------------------
      (if (< i (%cache-gap-start c))
          i
          (+ (%cache-gap-len c) i)))

    (define (%boundary-pos c i)
      ;; The buffer position of boundary I.
      ;;--------------------------------------------------------------
      (let ((slot (vector-ref (%cache-boundaries c) (%boundary-slot c i))))
        (if (< i (%cache-gap-start c))
            (+ (%cache-buffer-beg c) (car slot))
            (+ (%cache-buffer-end c) (car slot)))))

    (define (%boundary-value c i)
      ;; The value applying to the text after boundary I.
      ;;--------------------------------------------------------------
      (cdr (vector-ref (%cache-boundaries c) (%boundary-slot c i))))

    (define (%set-boundary-value! c i v)
      (set-cdr! (vector-ref (%cache-boundaries c) (%boundary-slot c i)) v))

    ;;----------------------------------------------------------------
    ;; Allocating
    ;;----------------------------------------------------------------

    (define (new-region-cache buffer-beg)
      ;; A new, empty cache for a buffer whose first position is
      ;; BUFFER-BEG - GNU Emacs's `new_region_cache' (`region-cache.c'),
      ;; which takes the buffer's `BEG' from the buffer. It holds one
      ;; boundary, at the buffer's beginning, with value 0: "unknown".
      ;;--------------------------------------------------------------
      (let ((c (make<region-cache> (make-vector *new-cache-gap* #f)
                                   0 *new-cache-gap* 0
                                   0 0 buffer-beg buffer-beg)))
        ;; Insert the boundary for the buffer start.
        (set!%cache-len c 1)
        (set!%cache-gap-len c (- *new-cache-gap* 1))
        (set!%cache-gap-start c 1)
        (vector-set! (%cache-boundaries c) 0 (cons 0 0))
        c))

    ;;----------------------------------------------------------------
    ;; Finding positions in the cache

    (define (%find-cache-boundary c pos)
      ;; The index of the last boundary at or before POS - the boundary
      ;; that says what the value is for the region POS.. POS + 1. GNU
      ;; Emacs's `find_cache_boundary', a binary search.
      ;;--------------------------------------------------------------
      (let loop ((low 0) (high (%cache-len c)))
        (if (< (+ low 1) high)
            (let* ((mid (+ (quotient low 2) (quotient high 2)
                           (if (and (odd? low) (odd? high)) 1 0)))
                   (boundary (%boundary-pos c mid)))
              (if (< pos boundary)
                  (loop low mid)
                  (loop mid high)))
            low)))

    ;;----------------------------------------------------------------
    ;; Moving the cache gap, inserting and deleting

    (define (%grow-boundaries! c min-size)
      ;; Make room for at least MIN-SIZE boundaries in the gap, by moving
      ;; the array into a larger one. GNU Emacs's `xpalloc', whose growth
      ;; is "about 50%" - `n = n0 + n0 / 2' - raised to whatever the
      ;; caller needs.
      ;;--------------------------------------------------------------
      (let* ((gap-len (%cache-gap-len c))
             (cache-len (%cache-len c))
             (capacity (+ gap-len cache-len))
             (needed (+ cache-len min-size))
             (n (max (+ capacity (quotient capacity 2)) needed))
             (new (make-vector n #f)))
        ;; the area after the gap moves to the end of the new array
        (let loop ((i (- cache-len 1)))
          (when (>= i (%cache-gap-start c))
            (vector-set! new (+ (- n cache-len) i)
                         (vector-ref (%cache-boundaries c)
                                     (+ gap-len i)))
            (loop (- i 1))))
        ;; the area before the gap keeps the indices it has
        (let loop ((i 0))
          (when (< i (%cache-gap-start c))
            (vector-set! new i (vector-ref (%cache-boundaries c) i))
            (loop (+ i 1))))
        ;; and the gap is now everything between them
        (set!%cache-boundaries c new)
        (set!%cache-gap-len c (- n cache-len))))

    (define (%move-cache-gap! c pos min-size)
      ;; Move the cache's gap to index POS, making room for at least
      ;; MIN-SIZE boundaries. GNU Emacs's `move_cache_gap'.
      ;;
      ;; Moving a boundary from one side of the gap to the other is what
      ;; re-expresses its position against the other end of the buffer,
      ;; so this is also where a boundary changes basis.
      ;;--------------------------------------------------------------
      (let* ((gap-start (%cache-gap-start c))
             (buffer-beg (%cache-buffer-beg c))
             (buffer-end (%cache-buffer-end c))
             (boundaries (%cache-boundaries c)))
        ;; Need we move the gap right?
        (let loop ()
          (when (< gap-start pos)
            ;; copy one boundary from after the gap to before it, and
            ;; convert its position to start-relative
            (let ((after (vector-ref boundaries
                                     (+ gap-start (%cache-gap-len c)))))
              (vector-set! boundaries gap-start
                           (cons (+ buffer-end (car after) (- buffer-beg))
                                 (cdr after))))
            (set! gap-start (+ gap-start 1))
            (loop)))
        (set!%cache-gap-start c gap-start)
        ;; To enlarge the gap the array has to be re-allocated, and that
        ;; is done here - after a right shift but before a left one, when
        ;; the part after the gap is smallest.
        (when (< (%cache-gap-len c) min-size)
          (%grow-boundaries! c min-size)
          (set! boundaries (%cache-boundaries c)))
        ;; Need we move the gap left?
        (let loop ()
          (when (< pos gap-start)
            (set! gap-start (- gap-start 1))
            ;; copy one boundary from before the gap to after it, and
            ;; convert its position to end-relative
            (let ((before (vector-ref boundaries gap-start)))
              (vector-set! boundaries (+ gap-start (%cache-gap-len c))
                           (cons (+ (car before) buffer-beg (- buffer-end))
                                 (cdr before))))
            (loop)))
        (set!%cache-gap-start c gap-start)))

    (define (%insert-cache-boundary! c i pos value)
      ;; Insert a boundary that will have index I. Emacs's
      ;; `insert_cache_boundary'.
      ;;
      ;; The gap has just been put at I, so the new boundary goes into
      ;; its first slot - which is written at the *raw* array index, as
      ;; the C's `c->boundaries[i]' is, and beginning-relative because a
      ;; boundary before the gap is stored that way. Reading it back
      ;; through the before/after-the-gap arithmetic would look one slot
      ;; past the end of the array.
      ;;--------------------------------------------------------------
      (%move-cache-gap! c i 1)
      (vector-set! (%cache-boundaries c) i
                   (cons (- pos (%cache-buffer-beg c)) value))
      (set!%cache-gap-start c (+ (%cache-gap-start c) 1))
      (set!%cache-gap-len c (- (%cache-gap-len c) 1))
      (set!%cache-len c (+ (%cache-len c) 1)))

    (define (%delete-cache-boundaries! c start end)
      ;; Delete the entries START to END - the C's
      ;; `delete_cache_boundaries'. The gap moves as little as it can,
      ;; which is the whole reason the gap is there.
      ;;--------------------------------------------------------------
      (let ((len (- end start)))
        (cond
         ((= len 0) #f)
         ;; gap is before the region: delete from the start forward
         ((<= (%cache-gap-start c) start)
          (%move-cache-gap! c start 0)
          (set!%cache-gap-len c (+ (%cache-gap-len c) len)))
         ;; gap is after the region: delete from the end backward
         ((<= end (%cache-gap-start c))
          (%move-cache-gap! c end 0)
          (set!%cache-gap-start c (- (%cache-gap-start c) len))
          (set!%cache-gap-len c (+ (%cache-gap-len c) len)))
         ;; gap is inside the region: just widen it
         (else
          (set!%cache-gap-start c start)
          (set!%cache-gap-len c (+ (%cache-gap-len c) len))))
        (set!%cache-len c (- (%cache-len c) len))))

    ;;----------------------------------------------------------------
    ;; Setting the value for a region

    (define (%set-cache-region! c start end value)
      ;; Establish VALUE for the buffer positions START to END. GNU
      ;; Emacs's `set_cache_region'.
      ;;
      ;; The work is making sure there are no boundaries *inside* the
      ;; region (the whole of it has the same value now, so they would
      ;; say nothing), while leaving exactly the boundaries that are
      ;; needed either side of it.
      ;;--------------------------------------------------------------
      (when (< start end)
        (let* ((start-ix (%find-cache-boundary c start))
               (end-ix (+ 1 (%find-cache-boundary c (- end 1))))
               ;; the value established by the last boundary before END;
               ;; if that boundary's domain runs past END a new boundary
               ;; there has to carry it
               (value-at-end (%boundary-value c (- end-ix 1))))
          ;; Delete every boundary strictly inside START..END.
          (%delete-cache-boundaries! c (+ start-ix 1) end-ix)
          ;; Make sure the right value is established coming *into* the
          ;; region from the left, and no boundary that says nothing.
          (if (= (%boundary-pos c start-ix) start)
              (if (and (> start-ix 0)
                       (= (%boundary-value c (- start-ix 1)) value))
                  (begin
                    (%delete-cache-boundaries! c start-ix (+ start-ix 1))
                    (set! start-ix (- start-ix 1)))
                  (%set-boundary-value! c start-ix value))
              (when (not (= (%boundary-value c start-ix) value))
                (%insert-cache-boundary! c (+ start-ix 1) start value)
                (set! start-ix (+ start-ix 1))))
          ;; This is equivalent to letting end_ix float with the
          ;; insertions and deletions just done.
          (set! end-ix (+ start-ix 1))
          ;; Make sure the right value is established leaving the region
          ;; to the right.
          (cond
           ((= end (%cache-buffer-end c))
            ;; there is no text after the region; nothing to do
            #f)
           ((or (>= end-ix (%cache-len c))
                (< end (%boundary-pos c end-ix)))
            ;; there is no boundary at END, but there may need to be one
            (when (not (= value-at-end value))
              (%insert-cache-boundary! c end-ix end value-at-end)))
           (else
            ;; there is a boundary at END; should it be there?
            (when (= value (%boundary-value c end-ix))
              (%delete-cache-boundaries! c end-ix (+ end-ix 1))))))))

    ;;----------------------------------------------------------------
    ;; Invalidating, and re-validating

    (define (invalidate-region-cache c buffer-beg buffer-end head tail)
      ;; Say that a section of the buffer has changed - GNU Emacs's
      ;; `invalidate_region_cache'. HEAD is the number of characters
      ;; unchanged at the beginning of the buffer and TAIL the number
      ;; unchanged at the end.
      ;;
      ;; Stating it that way rather than as positions is what makes the
      ;; arguments the same before and after an insertion or deletion,
      ;; when the positions they would otherwise be given mean different
      ;; things.
      ;;
      ;; Nothing is repaired here - this runs on every modification, and
      ;; repairing would be expensive. The mess is cleaned up in one go
      ;; by `%revalidate-region-cache!' the next time the cache is read.
      ;;--------------------------------------------------------------
      ;; If cutting the unchanged head and tail back to HEAD and TAIL
      ;; would throw away a lot that could be kept by revalidating first,
      ;; revalidate - losing it may cost more than revalidating now.
      (when (or (> (- (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))
                     (- (%cache-buffer-end c) tail))
                  *preserve-threshold*)
                (> (- (+ (%cache-buffer-beg c) head)
                     (- (%cache-buffer-end c) (%cache-end-unchanged c)))
                   *preserve-threshold*))
        (%revalidate-region-cache! c buffer-beg buffer-end))
      (when (< head (%cache-beg-unchanged c))
        (set!%cache-beg-unchanged c head))
      (when (< tail (%cache-end-unchanged c))
        (set!%cache-end-unchanged c tail)))

    (define (%revalidate-region-cache! c buffer-beg buffer-end)
      ;; Throw away everything the cache knows about the modified region
      ;; and make the positions of what is left accurate again. GNU
      ;; Emacs's `revalidate_region_cache'.
      ;;
      ;; The boundaries in the cache are expressed relative to the
      ;; cache's own idea of the buffer's endpoints, which may no longer
      ;; be the buffer's. So there are two bases to reconcile, and the
      ;; trick is to move the gap to the seam between the unchanged head
      ;; and the unchanged tail and then simply install the new
      ;; endpoints: every boundary before the gap is already
      ;; beginning-relative and every one after it already
      ;; end-relative, so they all come out right at once.
      ;;--------------------------------------------------------------
      (cond
       ;; The whole buffer is still valid: don't waste time. A `>' and
       ;; not a `>=' - think about what the two counters are set to when
       ;; the only change has been an insertion.
       ((> (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))
           (- (%cache-buffer-end c) (%cache-end-unchanged c)))
        #f)

       ;; Everything the cache knew about as of the last revalidation is
       ;; still there, so all of its information is still valid. The
       ;; modified region looks, from the cache's point of view, like a
       ;; null region somewhere in the buffer: the basis has to be
       ;; updated first, which gives that region its true size, and then
       ;; it can be invalidated like any other.
       ((= (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))
           (- (%cache-buffer-end c) (%cache-end-unchanged c)))
        (%move-cache-gap! c
                          (+ 1 (%find-cache-boundary
                                c (+ (%cache-buffer-beg c)
                                     (%cache-beg-unchanged c))))
                          0)
        (set!%cache-buffer-beg c buffer-beg)
        (set!%cache-buffer-end c buffer-end)
        (%set-cache-region! c
                            (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))
                            (- (%cache-buffer-end c) (%cache-end-unchanged c))
                            0))

       (else
        ;; There is a non-empty region in the cache corresponding to the
        ;; modified region of the buffer. These positions are correct
        ;; against both bases.
        (%set-cache-region! c
                            (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))
                            (- (%cache-buffer-end c) (%cache-end-unchanged c))
                            0)
        ;; Now only boundaries in the unchanged head and tail are left.
        ;; Putting the gap between them lets all their positions be
        ;; corrected at once, by installing the new endpoints.
        (let ((modified-ix
               (+ 1 (%find-cache-boundary
                     c (+ (%cache-buffer-beg c) (%cache-beg-unchanged c))))))
          (%move-cache-gap! c modified-ix 0)
          (set!%cache-buffer-beg c buffer-beg)
          (set!%cache-buffer-end c buffer-end)
          ;; Changing the basis may have shrunk the buffer and brought
          ;; the boundaries made for the two ends of the modified region
          ;; together, so that they name the same position. Collapse
          ;; them then - or delete both, if what is either side of them
          ;; is the same.
          (when (and (< modified-ix (%cache-len c))
                     (= (%boundary-pos c (- modified-ix 1))
                        (%boundary-pos c modified-ix)))
            (let ((value-after (%boundary-value c modified-ix)))
              (if (and (> (- modified-ix 1) 0)
                       (= value-after (%boundary-value c (- modified-ix 2))))
                  (%delete-cache-boundaries! c (- modified-ix 1)
                                             (+ modified-ix 1))
                  (begin
                    (%set-boundary-value! c (- modified-ix 1) value-after)
                    (%delete-cache-boundaries! c modified-ix
                                               (+ modified-ix 1)))))))))
      ;; Now the whole cache is valid.
      (let ((len (- (%cache-buffer-end c) (%cache-buffer-beg c))))
        (set!%cache-beg-unchanged c len)
        (set!%cache-end-unchanged c len)))

    ;;----------------------------------------------------------------
    ;; Adding information

    (define (know-region-cache c buffer-beg buffer-end start end)
      ;; Assert that the buffer positions START to END are known for this
      ;; cache - GNU Emacs's `know_region_cache'. For the line cache,
      ;; "known" means "holds no newline".
      ;;--------------------------------------------------------------
      (%revalidate-region-cache! c buffer-beg buffer-end)
      (%set-cache-region! c start end 1))

    ;;----------------------------------------------------------------
    ;; Reading the cache

    (define (region-cache-forward c buffer-beg buffer-end pos)
      ;; Two values: the value for the text immediately after POS, or 0
      ;; for "not known", and the nearest position after POS where the
      ;; knowledge changes - GNU Emacs's `region_cache_forward'. A caller
      ;; scanning forward skips straight to the second when the first
      ;; says the region is known.
      ;;--------------------------------------------------------------
      (%revalidate-region-cache! c buffer-beg buffer-end)
      (let ((i (%find-cache-boundary c pos)))
        (if (>= pos buffer-end)
            ;; beyond the end of the buffer is unknown, by definition
            (values 0 buffer-end)
            (let ((i-value (%boundary-value c i)))
              (let loop ((j (+ i 1)))
                (cond ((>= j (%cache-len c)) (values i-value buffer-end))
                      ((not (= (%boundary-value c j) i-value))
                       (values i-value (%boundary-pos c j)))
                      (else (loop (+ j 1)))))))))

    (define (region-cache-backward c buffer-beg buffer-end pos)
      ;; The same looking back: the value for the text immediately before
      ;; POS, and the nearest position before POS where the knowledge
      ;; changes - GNU Emacs's `region_cache_backward'.
      ;;--------------------------------------------------------------
      (%revalidate-region-cache! c buffer-beg buffer-end)
      (if (<= pos buffer-beg)
          ;; before the beginning of the buffer is unknown, by definition
          (values 0 buffer-beg)
          (let* ((i (%find-cache-boundary c (- pos 1)))
                 (i-value (%boundary-value c i)))
            (let loop ((j (- i 1)))
              (cond ((< j 0) (values i-value buffer-beg))
                    ((not (= (%boundary-value c j) i-value))
                     (values i-value (%boundary-pos c (+ j 1))))
                    (else (loop (- j 1))))))))

    ))
