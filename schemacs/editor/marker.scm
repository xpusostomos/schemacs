(define-library (schemacs editor marker)
  ;; This library mirrors GNU Emacs's `marker.c': the positions that
  ;; follow the text. Insert or delete anywhere and a marker goes on
  ;; pointing at the same character, because its index is adjusted by the
  ;; change - which is what makes it different from a plain integer, and
  ;; why the mark, a window's point and an overlay's bounds are markers
  ;; while `region-beginning' answers an integer.
  ;;
  ;; **Two of the functions are not marker.c's.** `make-marker' and
  ;; `build-marker' are `alloc.c`'s (`:3782', `:3801') - they are the
  ;; allocation, which in C sits beside the collector. There is no
  ;; `alloc.scm' here and there will not be one: a Scheme program's
  ;; allocation *is* Guile's, which is the case the project's own rule
  ;; names ("we don't want to fully port code that exists in guile
  ;; itself"). So the two land in the library whose data type they make,
  ;; with this note. The same seam explains why `locate-file-internal'
  ;; (`lread.c`) is in `fileio.scm'.
  ;;
  ;; **The byte half of marker.c is not ported, and cannot be.** About
  ;; two thirds of the file is `buf_charpos_to_bytepos' and
  ;; `buf_bytepos_to_charpos': converting between the character position
  ;; a marker publishes and the byte offset it caches, which exist
  ;; because Emacs's buffer holds *bytes* while positions count
  ;; *characters*. `buffer-text' holds one element per character, so a
  ;; position *is* an offset and there is nothing to convert -
  ;; `PT_BYTE', `BUF_GPT_BYTE', `Z_BYTE` and the rest of that family
  ;; have no counterpart, as `buffer-text.scm` already records. With them
  ;; go `clear_charpos_cache', the four `cached_*` file globals,
  ;; `attach_marker`'s bytepos, `set_marker_both',
  ;; `set_marker_restricted_both`, `marker_byte_position', and
  ;; `build_marker`'s third argument.
  ;;
  ;; **One field of `struct Lisp_Marker` is not carried**:
  ;; `need_adjustment` (`lisp.h`), which `adjust_markers_for_delete`
  ;; sets so that `record_marker_adjustments` (`undo.c`) can tell which
  ;; markers moved and record the inverse for undo. Nothing here records
  ;; marker adjustments yet, so the field would be state nothing reads.
  ;;
  ;; What is left of the file - the record, the accessors, `set-marker`
  ;; and the chain - is all here, ported to Emacs's names.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    ;; The chain is held weakly - see the note on it below. This is
    ;; Guile's own weak table; there is no Emacs name for the mechanism.
    (only (guile) hashq-set! hashq-remove! hash-for-each)
    ;; `(current-buffer)` is what `set-marker` takes a nil BUFFER to
    ;; mean, and the bounds are what a position is clipped to. The four
    ;; parameters after them are the seams this library fills: the
    ;; record's `markers` field is a field of `struct buffer`, so
    ;; `buffer.scm` owns the chain and cannot reach the constructor or
    ;; the setters that walk it - it declares them, this installs them.
    (only (schemacs editor buffer)
          current-buffer buffer-beg buffer-z buffer-markers
          *make-marker-function* *build-marker-function*
          *marker-position-function* *set-marker-function*
          *set-marker-insertion-type-function*)
    )

  (export
   <marker>  markerp  make<marker>
   make-marker  build-marker
   marker-buffer  %marker-charpos  set!%marker-charpos
   marker-position  marker-last-position
   set-marker  set-marker-restricted  copy-marker
   detach-marker  unchain-marker
   marker-insertion-type  set-marker-insertion-type
   markers-in
   ;; the chain walk, which Emacs spells as the `BUF_MARKERS` loop
   ;; every place it wants one
   %for-each-marker
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The marker record - GNU Emacs's `struct Lisp_Marker`
    ;;------------------------------------------------------------------
    ;;
    ;; **`buffer` is a field, and that is what "points nowhere" means.**
    ;; A marker with no buffer is not in any chain and follows nothing;
    ;; `make-marker` makes one, and `set-marker` with a nil position
    ;; makes one out of a marker that had a buffer. Emacs keeps the
    ;; buffer as a raw pointer and has to unlink a marker when its buffer
    ;; is killed, because that pointer does not keep the buffer alive.
    ;; Here it is the buffer object itself, so the same discipline is
    ;; needed for the same reason - and it is why a killed buffer's
    ;; markers are detached.
    (define-record-type <marker>
      (make<marker> buffer charpos insertion-type)
      markerp
      (buffer     marker-buffer        set!marker-buffer)
      ;; ^ The <buffer> this marker points into, or false when it points
      ;; nowhere - GNU Emacs's "marker points nowhere", which is what a
      ;; marker made by `make-marker` is.
      (charpos    %marker-charpos      set!%marker-charpos)
      ;; ^ The character position within that buffer - GNU Emacs's
      ;; `m->charpos`. It is a `buffer-text` position: one-based, the
      ;; convention the class speaks and Emacs's own. Only meaningful
      ;; while the marker has a buffer, but always a number: Emacs does
      ;; not reset it when a marker is unlinked either, which is what
      ;; `marker-last-position` answers with.
      (insertion-type marker-insertion-type set!marker-insertion-type)
      ;; ^ GNU Emacs's `m->insertion_type`: whether the marker advances
      ;; past text inserted exactly at it. False - the default, and what
      ;; `make-marker` gives - leaves the marker where it is and lets the
      ;; inserted text follow it; true moves the marker past the
      ;; insertion. Text inserted on either side of the marker moves it
      ;; whichever way the text went, whatever the type.
      )

    ;; The chain. Every buffer holds its markers in one, and the insert
    ;; and delete procedures walk it (that walk is `insdel.c`'s
    ;; `adjust_markers_for_insert` and its neighbours, which are the
    ;; engine's until they move).
    ;;
    ;; **GNU Emacs's chain does not keep its markers alive**: the
    ;; collector prunes it while sweeping, so an unreachable marker is
    ;; collected and its place in the chain goes with it. A Scheme
    ;; implementation cannot hook its collector's sweep, so the chain
    ;; holds them weakly instead - a key held weakly with a constant for
    ;; its value - which comes to the same thing: a marker that nothing
    ;; else refers to is collected, and it stops being adjusted. The
    ;; table itself is `buffer.scm`'s, because it is a field of
    ;; `struct buffer`.

    (define (%for-each-marker buffer proc)
      ;; Apply PROC to every marker in BUFFER's chain. A marker that has
      ;; been collected is simply no longer in it.
      ;;
      ;; **There is no Emacs function this mirrors** - the C writes
      ;; `for (tail = BUF_MARKERS (b); tail; tail = tail->next)` at each
      ;; of the eight places it wants one. It is a function here because
      ;; the chain is a weak table rather than a linked list, and that
      ;; detail belongs in one place. The `%` is this tree's mark for a
      ;; helper with no Emacs name.
      ;;--------------------------------------------------------------
      (hash-for-each (lambda (marker _) (proc marker))
                     (buffer-markers buffer)))

    (define (markers-in . rest)
      ;; GNU Emacs's `markers-in' (`marker.c:797'): "Return the list of
      ;; markers in region BEG..END. The list includes markers at BEG and
      ;; at END." It is always the *current* buffer, as the C's
      ;; `BUF_MARKERS (current_buffer)' is.
      ;;
      ;; Not carried: the C's `CHECK_FIXNUM_COERCE_MARKER', which lets
      ;; BEG or END be a marker as well as an integer. Ours takes the
      ;; integer, which is what every caller of it here passes.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (beg (if (and (pair? rest) (car rest))
                      (%clip-to-bounds buffer (car rest))
                      (buffer-beg buffer)))
             (end (if (and (pair? rest) (pair? (cdr rest)) (cadr rest))
                      (%clip-to-bounds buffer (cadr rest))
                      (buffer-z buffer)))
             (out '()))
        (%for-each-marker
         buffer
         (lambda (marker)
           (let ((at (%marker-charpos marker)))
             (when (<= beg at end) (set! out (cons marker out))))))
        out))

    ;;----------------------------------------------------------------
    ;; Making and attaching
    ;;------------------------------------------------------------------

    (define (make-marker)
      ;; GNU Emacs's `make-marker' (`alloc.c:3782'): "Return a newly
      ;; allocated marker which does not point at any place." It is in
      ;; the buffer list of nothing and follows nothing until it is set.
      ;;--------------------------------------------------------------
      (make<marker> #f 0 #f))

    (define (build-marker buffer charpos)
      ;; GNU Emacs's `build_marker' (`alloc.c:3801'): a marker pointing
      ;; into BUFFER at CHARPOS, already in BUFFER's chain, with the
      ;; default insertion type.
      ;;
      ;; **This is the C's way to make a marker when it has a buffer in
      ;; hand.** `copy-marker` is the *Lisp* door, and it acts on the
      ;; current buffer because Lisp has nothing else to pass; code that
      ;; already knows which buffer it means calls this one - a buffer's
      ;; own `pt_marker`/`begv_marker`/`zv_marker` (`buffer.c:933-935'),
      ;; an indirect buffer's (`:916-924'), and `point-marker`
      ;; (`editfns.c:202').
      ;;--------------------------------------------------------------
      (let ((marker (make<marker> buffer charpos #f)))
        (hashq-set! (buffer-markers buffer) marker #t)
        marker))

    (define (unchain-marker marker)
      ;; GNU Emacs's `unchain_marker' (`marker.c:683'): "Remove MARKER
      ;; from the chain of whatever buffer it is in. Set its buffer
      ;; NULL." It does not free the marker - "a change function could
      ;; have inserted it into an undo list" - and it does not move
      ;; `charpos` either, which is what makes `marker-last-position`
      ;; answerable after the fact.
      ;;--------------------------------------------------------------
      (let ((buffer (marker-buffer marker)))
        (when buffer
          (hashq-remove! (buffer-markers buffer) marker)
          (set!marker-buffer marker #f)))
      marker)

    (define (detach-marker marker)
      ;; GNU Emacs's `detach_marker' (`marker.c:674'): "Detach a marker
      ;; so that it no longer points anywhere and no longer slows down
      ;; editing in any buffer." The whole of it is `set-marker` with
      ;; nowhere and no buffer.
      ;;--------------------------------------------------------------
      (set-marker marker #f))

    (define (%clip-to-bounds buffer position)
      ;; GNU Emacs's `clip_to_bounds` (`lisp.h`): `(min (max position
      ;; lower) upper)` - a position outside the buffer is brought to the
      ;; nearer end rather than refused. The `BEGV`/`ZV` pair the C can
      ;; clip to instead is `BEG`/`Z` here, there being no narrowing, and
      ;; the buffer is passed rather than taken from the current one
      ;; because the C's two callers here clip to *their own* buffer.
      ;;--------------------------------------------------------------
      (min (max position (buffer-beg buffer)) (buffer-z buffer)))

    (define (%set-marker-internal marker position buffer restricted)
      ;; GNU Emacs's `set_marker_internal' (`marker.c:509'), the body
      ;; `set-marker` and `set-marker-restricted` share.
      ;;
      ;; Its three cases, in the C's order and for the C's reasons:
      ;;
      ;;   * a nil POSITION, a POSITION that is a marker pointing
      ;;     nowhere, or a buffer that is not live - the marker is
      ;;     *unchained* and points nowhere. That "a marker pointing
      ;;     nowhere" counts as nil is not an oddity: it is how
      ;;     `(set-marker a (set-marker b nil))` reads as "b is nowhere,
      ;;     so a is too".
      ;;   * a POSITION that is a marker already in the *same* buffer as
      ;;     MARKER - the position is copied across directly. That is
      ;;     `copy-marker`'s fast path and it is why `copy-marker` does
      ;;     not have to know a character count.
      ;;   * otherwise the position is read out of POSITION (an integer
      ;;     or a marker), clipped to the buffer, and the marker attached
      ;;     to BUFFER there.
      ;;
      ;; `RESTRICTED` is the C's flag for `BEGV`/`ZV` clipping; there is
      ;; no narrowing here, so it changes nothing and exists so that
      ;; `set-marker-restricted` reads as Emacs's does.
      ;;--------------------------------------------------------------
      (let ((b (or buffer (current-buffer))))
        (if (or (not position)
                (and (markerp position) (not (marker-buffer position)))
                (not b))
            (unchain-marker marker)
            (if (and (markerp position)
                     (eq? b (marker-buffer position))
                     (eq? b (marker-buffer marker)))
                (set!%marker-charpos marker (%marker-charpos position))
                (let ((charpos (cond ((integer? position) position)
                                     ((markerp position) (%marker-charpos position))
                                     (else (error "Invalid position" position)))))
                  (set!marker-buffer marker b)
                  (set!%marker-charpos marker (%clip-to-bounds b charpos))
                  (hashq-set! (buffer-markers b) marker #t))))
        marker))

    (define (set-marker marker position . rest)
      ;; GNU Emacs's `set-marker' (`marker.c:607'): "Position MARKER
      ;; before character number POSITION in BUFFER. If BUFFER is omitted
      ;; or nil, it defaults to the current buffer. If POSITION is nil,
      ;; makes marker point nowhere so it no longer slows down editing in
      ;; any buffer. Returns MARKER."
      ;;
      ;; **BUFFER defaults to the *current* buffer and not to the
      ;; marker's own**, which is what Emacs says and what its
      ;; `decode_buffer` does (`nil` is `current_buffer`). That reads
      ;; oddly for a marker already in some other buffer, and it is still
      ;; the rule: a caller that means the marker's own buffer passes it.
      ;;--------------------------------------------------------------
      (%set-marker-internal marker position
                            (if (pair? rest) (car rest) #f)
                            #f))

    (define (set-marker-restricted marker position . rest)
      ;; GNU Emacs's `set_marker_restricted' (`marker.c:619'): "Like the
      ;; above, but won't let the position be outside the visible part" -
      ;; that is, it clips to `BEGV`/`ZV` rather than `BEG`/`Z`.
      ;;
      ;; **There is no narrowing in this tree**, so `BEGV`/`ZV` are
      ;; `BEG`/`Z` and this is `set-marker`. It exists because the C's
      ;; callers name it and a port of one of them should be able to name
      ;; it too; the day narrowing arrives it becomes the other clip.
      ;;--------------------------------------------------------------
      (%set-marker-internal marker position
                            (if (pair? rest) (car rest) #f)
                            #t))

    (define (copy-marker . rest)
      ;; GNU Emacs's `copy-marker' (`marker.c:753'): "Return a new marker
      ;; pointing at the same place as MARKER. If argument is a number,
      ;; makes a new marker pointing at that position in the current
      ;; buffer. If MARKER is not specified, the new marker does not
      ;; point anywhere. The optional argument TYPE specifies the
      ;; insertion type of the new marker."
      ;;
      ;; The C is `new = Fmake_marker (); Fset_marker (new, marker, ...);
      ;; XMARKER (new)->insertion_type = !NILP (type);` - so the *setting*
      ;; is the whole of it, and the buffer argument is the marker's own
      ;; buffer when given a marker and nil (the current buffer) when
      ;; given a number.
      ;;--------------------------------------------------------------
      (let ((marker (if (pair? rest) (car rest) #f))
            (type (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (let ((new (make-marker)))
          (set-marker new marker (and (markerp marker) (marker-buffer marker)))
          (set!marker-insertion-type new (and type #t))
          new)))

    ;;----------------------------------------------------------------
    ;; Asking
    ;;------------------------------------------------------------------

    (define (marker-position marker)
      ;; GNU Emacs's `marker-position' (`marker.c:447'): "Return the
      ;; position of MARKER, or nil if it points nowhere." False is this
      ;; tree's nil.
      ;;--------------------------------------------------------------
      (and (marker-buffer marker) (%marker-charpos marker)))

    (define (marker-last-position marker)
      ;; GNU Emacs's `marker-last-position' (`marker.c:458'): "Return
      ;; last position of MARKER in its buffer. This is like
      ;; `marker-position' with one exception: If the buffer of MARKER is
      ;; dead, it returns the last position of MARKER in that buffer
      ;; before it was killed." Since unlinking does not clear the
      ;; position, the exception costs nothing here.
      ;;--------------------------------------------------------------
      (%marker-charpos marker))

    (define (set-marker-insertion-type marker type)
      ;; GNU Emacs's `set-marker-insertion-type' (`marker.c:784'): "Set
      ;; the insertion-type of MARKER to TYPE. If TYPE is t, it means the
      ;; marker advances when you insert text at it. If TYPE is nil, it
      ;; means the marker stays behind when you insert text at it." It
      ;; returns TYPE, not the marker.
      ;;--------------------------------------------------------------
      (set!marker-insertion-type marker (and type #t))
      type)

    ;;----------------------------------------------------------------
    ;; The seams into this library, installed as it loads
    ;;------------------------------------------------------------------
    ;;
    ;; `buffer.scm` cannot reach any of these: `struct buffer`'s
    ;; `markers` field is a field of the record it owns, so the chain
    ;; lives there while everything that walks it lives here. The
    ;; parameters are declared there and filled in here, as the file
    ;; that has the functions.
    (*make-marker-function* make-marker)
    (*build-marker-function* build-marker)
    (*marker-position-function* marker-position)
    (*set-marker-function* set-marker)
    (*set-marker-insertion-type-function* set-marker-insertion-type)

    ))
