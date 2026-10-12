(define-library (schemacs editor engine)
  ;; This library mirrors GNU Emacs's `buffer.c' + `insdel.c' +
  ;; `search.c': the buffer and its text (one `buffer-text`, which is
  ;; `struct buffer_text`), inserting into it and deleting from it, the
  ;; undo list those record, and searching over it.
  ;;
  ;; It is three Emacs files in one library, which the rule in
  ;; LAYOUT-PLAN.txt does not ask for - the rule is one library per
  ;; mirrored file. It was written before the rule, and this note used to
  ;; promise a split "when markers are next worked on".
  ;;
  ;; **Two of the four have left.** `marker.c` is `marker.scm' - the
  ;; smallest piece, and the one with nothing pointing back into this
  ;; file, because `marker.c` never calls `insdel.c`. Grep the C and the
  ;; only edge runs the other way: `insdel.c` walks the chain with
  ;; `adjust_markers_for_insert`. The record left before it - it is
  ;; `buffer.h`'s `struct buffer`, and it is `buffer.scm`'s now, which is
  ;; where `buffer.c` keeps it. This library is built ON that one, so it
  ;; may call the buffer's own functions rather than the reverse.
  ;;
  ;; **What holds the remaining three together is a cycle in Emacs's own
  ;; data layout**, and an R7RS library's imports are a directed acyclic
  ;; graph:
  ;;
  ;;   * the line scans (`find_newline`, `bol`, `eol`) are read by the
  ;;     line and column arithmetic in this same file - `%line-start`,
  ;;     `%line-end`, `text-editor-cursor-line` - so search.c's scans sit
  ;;     *below* `search.scm`, the file that already mirrors search.c's
  ;;     other half and imports this one;
  ;;   * the undo list is written by the insert and delete primitives and
  ;;     applied by a command that goes back *through* those primitives;
  ;;   * and the insert and delete primitives *are* this library, so
  ;;     `insdel.c` cannot be taken out of what is left of `buffer.c`.
  ;;
  ;; What comes the other way - `del_range`, the undo entry a save
  ;; records up to, the visited file's modification time - is a seam this
  ;; library installs at the end of its load, or one declared in
  ;; `buffer.scm` and filled in by the library that owns the function.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library predates.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme char) char-downcase)  ; for case-folding searches
    ;;(only (schemacs lexer) make<source-file-location>)
    ;; **The marker chain's weak table is not imported here any more** -
    ;; the chain moved to `marker.scm' with `marker.c`, and with it the
    ;; four `hashq` functions that used to be imported for it. The
    ;; `(only (scheme write) display)` that stood here was a `;;DEBUG`
    ;; leftover: nothing called it.
    (only (guile)
          ;; `make-typed-array' is how a `u32vector' of a given length is
          ;; made - `(scheme base)' has no generic array, and R7RS has no
          ;; `u32vector' constructor at all. `u32vector-set!' takes the value before
          ;; the index, as `array-set!' does. `u32vector?' is the predicate
          ;; that tells a decoded file's code points from a string's.
          make-typed-array  u32vector-set!  u32vector?)
    ;; The buffer's text. Emacs's `struct buffer_text' as an object -
    ;; the characters, the gap and where the gap is - so the four
    ;; structures this file used to keep (a gap buffer of `<text-line>'
    ;; records, a separate line editor, a CDF indexing the lines, and a
    ;; hand-maintained character count) are one sequence of characters,
    ;; as they are in Emacs.
    (only (schemacs editor buffer-text)
          buffer-text-base buffer-text-z
          buffer-text-ref
          buffer-text-insert! buffer-text-insert-code-points!
          buffer-text-delete!
          buffer-text-substring
          buffer-text-beg-unchanged set!buffer-text-beg-unchanged)
    ;; The line-break cache `find-newline' keeps - GNU Emacs's
    ;; `region-cache.c', which is `buf->newline_cache' there. It is what
    ;; makes searching a buffer with very long lines affordable: a
    ;; stretch already searched and found free of line breaks is skipped
    ;; whole rather than scanned again.
    (only (schemacs editor region-cache)
          new-region-cache  know-region-cache  invalidate-region-cache
          region-cache-forward  region-cache-backward)
    ;; **The buffer record is the buffer library's now** - `buffer.h`'s
    ;; struct, which `buffer.c` owns - so the record, its accessors,
    ;; `make_buffer` (`NEW-TEXT-EDITOR`), `buffer-beg' and `buffer-z'
    ;; (the `BEG'/`Z' macros) and `inhibit-read-only' (`buffer.c:5885')
    ;; all come from there. The engine is built ON that library, which is
    ;; what lets `buffer.c`'s own functions work on the record; the
    ;; alternative - the engine below it - is what kept the record out of
    ;; its home until now.
    ;;
    ;; `count-lines' comes back *up* from `fns', where it now lives: it is
    ;; `xdisp.c'`s and it wants to be low, so it sits beside `fns.c`'s
    ;; `line-number-at-pos', and this library - which is above `fns', not
    ;; below it - imports it for its own line arithmetic and re-exports
    ;; it below.
    (only (schemacs editor fns) count-lines)
    (only (schemacs editor buffer)
          *inhibit-read-only*  current-buffer  with-current-buffer
          allocate-buffer  bufferp  show-text-editor
          text-editor-text
          buffer-pt  set!buffer-pt
          %text-editor-newline-cache  set!%text-editor-newline-cache
          text-editor-text-props  set!text-editor-text-props
          text-editor-undo-list  set!text-editor-undo-list
          text-editor-cache-long-scans  set!text-editor-cache-long-scans
          %mark-marker
          buffer-markers
          text-editor-buffer-name  set!text-editor-buffer-name
          text-editor-file-name  set!text-editor-file-name
          buffer-beg  buffer-z
          buffer-modified-tick  buffer-chars-modified-tick
          buffer-modified-p  set-buffer-modified-p
          buffer-read-only?  set!buffer-read-only
          ;; `%text-editor-incr-modiff!' is not imported any more: its only
          ;; caller here was the property-change raise, which is
          ;; `modify-text-properties' in `textprop.scm' now.
          ;; the seams this library installs as it loads, at the end of
          ;; the file
          *buffer-visited-file-modtime-function*
          *del-range-function*)
    ;; The markers that follow the text. `marker.scm` is built on the
    ;; buffer library - a marker is added to a buffer's chain, and that
    ;; chain is a field of the record - and this library is built on the
    ;; same one, so the two are siblings and this is where the engine gets
    ;; them from.
    ;;
    ;; **`adjust_markers_for_insert` and `adjust_markers_for_delete` are
    ;; `insdel.c`'s, not `marker.c`'s**, which is why the two adjusters
    ;; below are still here: they walk the chain and write `m->charpos`,
    ;; and that is what the C does from the other file.
    (only (schemacs editor marker)
          %for-each-marker %marker-charpos set!%marker-charpos
          marker-position marker-insertion-type set-marker)
    ;; The change hooks and the caches: `insdel.c`'s, in its own library.
    (only (schemacs editor insdel)
          *after-change-functions* signal-after-change
          *text-property-offset-function*
          invalidate-buffer-caches
          adjust-markers-for-insert
          insert-from-string
          del-range prepare-to-modify-buffer)
    ;; `undo.c`'s recording half, which is its own library now and sits
    ;; *below* `insdel.scm` - so the three `*record-*-function*` seams the
    ;; engine used to install are gone, and this library re-exports the
    ;; names its importers still ask it for.
    (only (schemacs editor undo)
          record-insert  record-delete
          text-editor-undo-boundary!
          text-editor-undo-disable!  text-editor-undo-enable!
          text-editor-undo-recording?
          *undo-limit*
          undo-insertion-entry?  undo-deletion-entry?  undo-modified-entry?
          *point-before-last-command-or-undo*
          *buffer-before-last-command-or-undo*)
    )
  (export
   ;; The buffer data type - `buffer.h`'s struct, which `buffer.sld`
   ;; owns now; these are re-exported for the libraries that still ask
   ;; the engine for them.
   allocate-buffer  bufferp  buffer-pt

   text-editor-to-string
   text-editor-to-code-points
   text-editor-insert
   text-editor-delete-from-cursor
   make-buffer-string
   *after-change-functions*
   signal-after-change

   ;; Undo
   ;;
   ;; `record_insert` and `record_delete` are undo.c's, and `casify_region`
   ;; calls them **directly** - `casefiddle.c` records the whole region
   ;; once around its per-character loop, exactly as `undo.c`'s own callers
   ;; do, rather than through the seams `insdel.c` reaches them by. They
   ;; move to `(schemacs editor undo)` the day `undo.scm` exists.
   record-insert  record-delete
   text-editor-undo-list  set!text-editor-undo-list
   text-editor-undo-boundary!
   text-editor-undo-disable!  text-editor-undo-enable!
   text-editor-undo-recording?
   *undo-limit*
   undo-insertion-entry?  undo-deletion-entry?  undo-modified-entry?

   ;; The root of the buffer's text-property interval tree, and the
   ;; procedure that shifts it on an edit. GNU Emacs keeps the root on the
   ;; buffer too (`BVAR (buf, intervals)') and shifts it from `insdel.c';
   ;; the tree and the operations on it are `(schemacs editor intervals)',
   ;; which mirrors `intervals.c'.
   text-editor-text-props  set!text-editor-text-props
   ;; `text-editor-deactivate-mark' and its setter are gone as names:
   ;; `deactivate-mark' is a buffer-local *variable* (`keyboard.c:14030`)
   ;; keyed by the symbol, read and written through `buffer-local-value'
   ;; and `set-buffer-local-value!' - it was never a slot of the record.
   *inhibit-read-only*
   *text-property-offset-function*

   ;; Whether the buffer has changed since it was last saved
   buffer-modified-p  set-buffer-modified-p
   *point-before-last-command-or-undo*  *buffer-before-last-command-or-undo*
   *buffer-visited-file-modtime-function*

   ;; Whether the buffer refuses to be changed
   buffer-read-only?  set!buffer-read-only

   ;; Searching, and the mark
   text-editor-search-forward  text-editor-search-backward
   string-search-forward
   text-editor-mark  set!text-editor-mark

   ;; The buffer's identity: its name and the file it visits
   text-editor-buffer-name  set!text-editor-buffer-name
   text-editor-file-name    set!text-editor-file-name

   ;; The buffer's mark. The markers themselves are `marker.scm`'s now -
   ;; `MARKERP`, `marker-position`, `set-marker` and the rest come from
   ;; there, where marker.c's functions live - and `mark-marker` is
   ;; `buffer.c`'s, which is why it is still here.
   mark-marker

   ;; Getting and setting the cursor index. Every *position* the engine
   ;; answers is one-based, as Emacs's are: `point-min' is 1 and
   ;; `point-max' is one past the last character. Line numbers count
   ;; from 1 (`line-number-at-pos'); columns from 0 (`current-column').

   buffer-beg
   buffer-z
   fetch-char
   text-editor-cursor-line
   text-editor-cursor-column
   text-editor-get-start-of-line
   text-editor-get-end-of-line
   text-editor-set-cursor
   text-editor-move-cursor
   buffer-pt
   ;; The scans the line arithmetic is built on - GNU Emacs's
   ;; `find_newline' (`search.c:675'), `scan_newline_from_point'
   ;; (:986), `bol' (`editfns.c:665'), `eol' (:723),
   ;; `find_before_next_newline' (`search.c':997) and `count_lines'
   ;; (`xdisp.c:29892').
   find-newline  scan-newline-from-point
   bol  eol  find-before-next-newline  count-lines
   show-text-editor
   ;; `invalidate_buffer_caches' (`insdel.c:2206'), which is `insdel.scm`'s
   ;; now and re-exported here so its readers do not have to know. The
   ;; writers in this file call it; the C's `erase-buffer' is the other
   ;; caller - `(invalidate_buffer_caches (current_buffer, BEGV, ZV))'
   ;; (buffer.c:2773) - and that is covered, since `erase-buffer' reaches
   ;; `del_range` through `*del-range-function*`, and `del_range` runs
   ;; `prepare_to_modify_buffer` itself.
   invalidate-buffer-caches
   ;; `BEG_UNCHANGED' (`buffer.h:156') and its setter are not exported any
   ;; more: they are `xdisp.scm`'s own accessors now, which is where both
   ;; the C's read and the C's write of that field are.
   ;; `buffer-modified-tick' and `buffer-chars-modified-tick' (buffer.c)
   buffer-modified-tick  buffer-chars-modified-tick
   ;; `cache-long-scans' (`buffer.c:5786'), the buffer-local both region
   ;; caches hang on
   text-editor-cache-long-scans  set!text-editor-cache-long-scans
   ;; `text-editor-note-property-change!' is not exported any more: it was
   ;; `textprop.c`'s `modify_text_properties` under an invented name, and
   ;; it is that function, in that file, now.
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Inserting text
    ;;------------------------------------------------------------------
    ;;
    ;; **A Cumulative Distribution Function used to be described here** -
    ;; "since this editor engine buffers variable-length lines and not
    ;; characters, we provide a way to efficiently map arbitrary
    ;; character indices to line indices ... with a CDF". It described
    ;; machinery that no longer exists: the line buffer, the gap buffer
    ;; of `<text-line>' records and the CDF over them were all replaced
    ;; by one `buffer-text`, a sequence of *characters* with a gap, as
    ;; `struct buffer_text' is. A position is an offset into it, so there
    ;; is no character-to-line mapping to compute.


    (define (make-buffer-string ed start end)
      ;; The buffer's text between the positions START and END, as a
      ;; string - GNU Emacs's `buffer-substring' over the whole buffer,
      ;; and the same half-open range (START in, END out). Arguments may
      ;; be given in either order; the empty range returns "".
      ;;--------------------------------------------------------------
      (let ((start (min start end))
            (end (max start end)))
        (buffer-text-substring (text-editor-text ed) start end)))

    ;; **The marker adjusters are `insdel.scm`'s now.** They are
    ;; `insdel.c`'s - `adjust_markers_for_insert` and
    ;; `adjust_markers_for_delete` - and that library exists, so there is
    ;; one copy of each rather than two. They act on the current buffer,
    ;; as the C's do, which is why the call sites below say what buffer
    ;; they mean by making it current.

    (define (mark-marker ed)
      ;; The buffer's mark as the marker it is, GNU Emacs's
      ;; `mark-marker': the same marker object every time, so that
      ;; setting the mark moves it rather than replacing it.
      ;;--------------------------------------------------------------
      (%mark-marker ed))

    (define (text-editor-mark ed)
      ;; Where the buffer's mark is, as a character index, or false when
      ;; it has not been set: GNU Emacs's `(mark)'. The mark is a marker
      ;; (see `MARK-MARKER'), so it follows the text: set it, edit
      ;; before it, and it is still on the character it was put on.
      ;;--------------------------------------------------------------
      (marker-position (%mark-marker ed)))

    (define (set!text-editor-mark ed position)
      ;; Put the buffer's mark at POSITION, or leave it unset when
      ;; POSITION is false.
      ;;--------------------------------------------------------------
      (set-marker (%mark-marker ed) (and position position) ed))

    ;; **`text-editor-note-property-change!' has left, and it never had
    ;; the right name.** It was this tree's spelling of `textprop.c`'s
    ;; `modify_text_properties`, and it was a thin one: it invalidated the
    ;; region caches - which the C does *not* do for a property write,
    ;; the characters not having changed - and skipped both
    ;; `prepare_to_modify_buffer_1` and `record_first_change`. It is in
    ;; `(schemacs editor textprop)' now, under its own name and with its
    ;; own body.

    ;;----------------------------------------------------------------
    ;; Searching
    ;;
    ;; GNU Emacs's `search-forward' and `search-backward' (mg's
    ;; forwsrch/backsrch): a literal search over the buffer's
    ;; characters, in which a line break counts as a single #\newline.
    ;; Both leave point at the far end of the match - past it when
    ;; searching forward, at its start when searching backward - and
    ;; these procedures return that position, so a caller can put its
    ;; cursor where Emacs would have left point.
    ;;
    ;; Case folding is the caller's decision, passed in: in Emacs the
    ;; rule that an upper-case letter in the search string turns folding
    ;; off (`search-upper-case') belongs to isearch, not to
    ;; `search-forward', which only obeys `case-fold-search'.
    ;;------------------------------------------------------------------

    (define (string-search-forward haystack needle from case-fold?)
      ;; The index of the first occurrence of NEEDLE in the string
      ;; HAYSTACK at or after FROM, or #f. With CASE-FOLD? the comparison
      ;; ignores case, the way mg's `eq' macro does with its `xcase'
      ;; argument. This is the rule the buffer searches below use, and it
      ;; is exported so that a caller which already holds the text - the
      ;; renderer drawing search matches, say - can apply the same rule
      ;; without asking the buffer for it again.
      ;; The index of the first occurrence of NEEDLE in HAYSTACK at or
      ;; after FROM, or #f. With CASE-FOLD? the comparison ignores case,
      ;; the way mg's `eq' macro does with its `xcase' argument.
      ;;--------------------------------------------------------------
      (let ((n (string-length haystack))
            (m (string-length needle)))
        (let loop ((i from))
          (cond
           ((> (+ i m) n) #f)
           ((%string-match-at? haystack needle i case-fold?)
            i)
           (else (loop (+ 1 i)))))))

    (define (%string-search-backward haystack needle from case-fold?)
      ;; The index of the last occurrence of NEEDLE in HAYSTACK that
      ;; begins at or before FROM, or #f.
      ;;--------------------------------------------------------------
      (let ((m (string-length needle)))
        (let loop ((i (min from (- (string-length haystack) m))))
          (cond
           ((< i 0) #f)
           ((%string-match-at? haystack needle i case-fold?) i)
           (else (loop (- i 1)))))))

    (define (%string-match-at? haystack needle at case-fold?)
      ;; Whether NEEDLE occurs in HAYSTACK at index AT.
      ;;--------------------------------------------------------------
      (let ((m (string-length needle)))
        (let loop ((j 0))
          (cond
           ((>= j m) #t)
           ((char=? (%fold (string-ref haystack (+ at j)) case-fold?)
                    (%fold (string-ref needle j) case-fold?))
            (loop (+ 1 j)))
           (else #f)))))

    (define (%fold c case-fold?)
      (if case-fold? (char-downcase c) c))

    (define (text-editor-search-forward ed string start case-fold?)
      ;; Search forward from the position START for STRING. Returns the
      ;; position just past the match, which is where GNU Emacs's
      ;; `search-forward' leaves point, or #f when STRING does not
      ;; occur there. An empty STRING finds nothing, as it does for
      ;; mg's `is_find', rather than matching everywhere as Emacs's
      ;; `search-forward' does - an empty search string means "no search
      ;; yet" to the incremental search that wants this.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let ((found (string-search-forward
                         (make-buffer-string
                          ed start (buffer-z ed))
                         string 0 case-fold?)))
             (and found (+ start found (string-length string))))))

    (define (text-editor-search-backward ed string start case-fold?)
      ;; Search backward from the position START for STRING. Returns the
      ;; position of the start of the match, which is where GNU Emacs's
      ;; `search-backward' leaves point, or #f when STRING does not
      ;; occur before START. An empty STRING finds nothing.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let* ((text (make-buffer-string ed (buffer-beg ed)
                                                    start))
                  (found (%string-search-backward
                          text string (- (string-length text)
                                         (string-length string))
                          case-fold?)))
             ;; FOUND is an offset into TEXT, whose first character is
             ;; at `point-min'
             (and found (+ found (buffer-beg ed))))))

    ;; **`*text-property-offset-function*` has moved down to
    ;; `insdel.scm`**, because that is where the interval shifting now
    ;; happens and a parameter can only be read by the libraries below
    ;; the one that declares it. `intervals.scm` installs it there now.
    ;; It is re-exported from here so its readers do not have to know.



    (define (%insert-argument thing)
      ;; **The C's `Finsert` (`editfns.c`) takes any number of arguments,
      ;; each a string or a character**, and hands each to
      ;; `insert_from_string`; this is the one-argument reading of that,
      ;; and `editfns.scm`'s `insert` is the variadic one that loops with
      ;; it. A list (or a `u32vector`) of code points is this tree's
      ;; addition and is not `Finsert`'s: it is the door a decoded file
      ;; comes through, because a byte character has no string form.
      ;;--------------------------------------------------------------
      (cond ((string? thing) thing)
            ((char? thing) (string thing))
            ((integer? thing) (string (integer->char thing)))
            ((or (list? thing) (u32vector? thing)) thing)
            (else (error "editor cannot insert text from" thing))))

    (define (text-editor-insert ed thing)
      ;; Insert THING at the cursor of ED.
      ;;
      ;; **The insertion is `insdel.scm`'s now**, and with it the whole
      ;; composition: the read-only gate and the caches
      ;; (`prepare_to_modify_buffer`), the undo entry and the mark of the
      ;; last save (`record_insert`), the modification counter, the
      ;; markers, the intervals, the after-change hooks - and point,
      ;; which moves **once**, at the end, with `adjust_point`.
      ;;
      ;; This function used to do all of that itself, in its own order,
      ;; over a store writer that advanced point one character at a time.
      ;; The C moves point once because its insert writes the whole
      ;; string into the gap in one go and then calls
      ;; `adjust_point (nchars)`; ours now does the same, which is what
      ;; `insert-from-string-1` is.
      ;;
      ;; What is left here is the shape this tree's callers want: ED is
      ;; passed explicitly, where the C's primitives act on
      ;; `current_buffer` - so it is made current around the call, and
      ;; the day the callers are rewritten to Emacs's `insert` they will
      ;; do that themselves.
      ;;--------------------------------------------------------------
      (with-current-buffer ed (insert-from-string (%insert-argument thing))))

    (define (text-editor-to-code-points ed)
      ;; The buffer's characters, as a list of code points - the answer
      ;; `text-editor-to-string' gives, without the one conversion that
      ;; can fail. A buffer holding a byte character has no string form,
      ;; which is why writing a file cannot go through a string either.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((pos (buffer-text-base text)) (acc '()))
          (if (>= pos (buffer-text-z text))
              (reverse acc)
              (loop (+ pos 1) (cons (buffer-text-ref text pos) acc))))))

    ;; Deleting text
    ;;
    ;; GNU Emacs's `del_range' (`insdel.c'): take the characters of a
    ;; range out of the buffer. With one store and no line objects there
    ;; is nothing else to it - a line break is a character like any
    ;; other, so joining two lines is deleting the break between them.
    ;; The merge helpers this section used to carry, which walked a line
    ;; editor, a gap buffer of `<text-line>' records and a CDF, have no
    ;; counterpart in Emacs and are gone with those three structures.

    ;; `text-editor-invalidate-caches!` is gone: it was
    ;; `invalidate_buffer_caches` under an invented name, and it is
    ;; `insdel.scm`'s now.
    ;;
    ;; **`%del-range`, `%text-editor-delete-forward` and
    ;; `%text-editor-delete-backward` are gone too.** The first was
    ;; `del_range` under an invented name, and it had a wart its own
    ;; comment confessed - it moved point to FROM and deleted from there,
    ;; where the C leaves point alone; `erase-buffer` runs the real
    ;; `del-range` through the `*del-range-function*` seam now. The other
    ;; two were the clamped halves of one delete, split apart because the
    ;; old writer wanted to know *how much* went before it recorded it.
    ;; The C has no such split: `del_range` takes the two ends.

    (define (text-editor-delete-from-cursor ed n)
      ;; Delete N characters at the cursor of ED. Positive N deletes
      ;; characters after the cursor, negative N deletes characters
      ;; before it, and either is clamped at the buffer's end. Returns the
      ;; number of characters deleted.
      ;;
      ;; **This is GNU Emacs's `delete-char` (`cmds.c:221`) with the C's
      ;; two endpoint errors replaced by a clamp**, which is this
      ;; function's documented behaviour and the reason it still exists
      ;; under an invented name: the C's version signals
      ;; `end-of-buffer`/`beginning-of-buffer`, so it cannot stand in for
      ;; the callers here until each of them is rewritten to the Lisp
      ;; door it should have used - `delete-region` (`editfns.c`) or
      ;; `delete-char` the command (`cmds.c`), both of which already wrap
      ;; this.
      ;;
      ;; **The deletion itself is `del_range`'s**, and with it the
      ;; read-only gate (`barf-if-buffer-read-only`, through
      ;; `prepare_to_modify_buffer`), the undo entry, the marker
      ;; adjustment, the modification counter, point's own move and the
      ;; after-change hooks. Nothing of that is repeated here, which is
      ;; the point: it used to be, in a different order, in this file.
      ;;
      ;; The buffer is made current around the call because `del_range`
      ;; acts on the current buffer, as the C's does; ED was passed
      ;; explicitly by every caller of this wrapper, and the day they are
      ;; rewritten they run inside `with-current-buffer` themselves.
      ;;--------------------------------------------------------------
      (if (= n 0)
          ;; deletion of nothing is not a change: no barf, no boundary
          0
          (with-current-buffer ed
            (let* ((cursor (buffer-pt ed))
                   (from (if (< n 0) (max (buffer-beg ed) (+ cursor n)) cursor))
                   (to   (if (< n 0) cursor (min (buffer-z ed) (+ cursor n)))))
              (del-range from to)
              ;; `del-range` answers the text it took, and undo's entry
              ;; holds it; the caller here wants the count
              (- to from)))))

    ;; **`buffer-beg-unchanged' and its setter have left, for `(schemacs
    ;; editor xdisp)'.** `BEG_UNCHANGED' is `buffer.h:156''s field, but
    ;; the *write* - "the buffer is current as of now" - is `xdisp.c''s
    ;; own line (`:18327', `BUF_BEG_UNCHANGED (b) = BUF_GPT (b) -
    ;; BUF_BEG (b)'), and the read is `BASE_LINE_NUMBER_VALID_P'
    ;; (`:19393'), which is the `%l' cache's rule. `xdisp.scm' was the
    ;; only user of both, so they are its own accessors now, reading the
    ;; field through `buffer-text'.

    (define (text-editor-to-string ed)
      ;; The buffer's characters as a string - GNU Emacs's
      ;; `buffer-string' (`editfns.c'): "Return the contents of the
      ;; current buffer as a string."
      ;;
      ;; It is the *raw* text, with `\n' for every line break and no
      ;; coding-system translation, because that is what a buffer holds
      ;; in Emacs. The buffer's line-break convention is applied once,
      ;; by whoever writes the buffer out - `(schemacs editor files)'s
      ;; `encode-line-breaks', which mirrors `coding.c' - and not here:
      ;; this used to route through `text-dump-port', which applies the
      ;; line break, and `save-buffer' then applied it a second time, so
      ;; a CRLF file was written as `\r\r\n'.
      ;;--------------------------------------------------------------
      (make-buffer-string ed
                               (buffer-beg ed)
                               (buffer-z ed)))

    ;;----------------------------------------------------------------
    ;; The cursor, lines and columns
    ;;
    ;; GNU Emacs stores no line index. It *scans*: `find_newline'
    ;; (`search.c:675') walks the buffer counting newlines, and
    ;; everything that wants a line or a column is built on it - `bol'
    ;; and `eol' (`editfns.c:665', :723), `line-beginning-position',
    ;; `line-end-position', `line-number-at-pos' (`fns.c:6688').
    ;;
    ;; The engine used to keep an index instead: a CDF over a gap buffer
    ;; of lines, so a character index could be turned into a line with a
    ;; binary search. That was a departure, and an expensive one - the
    ;; index had to be invalidated on every edit, and where it went stale
    ;; showed up three screens from where it mattered. There is one
    ;; sequence of characters now and no index; the scans below are
    ;; Emacs's, ported over `buffer-text'.
    ;;
    ;; Positions are one-based, as Emacs's are: `point-min' is 1 and
    ;; `point-max' is one past the last character. Line numbers count
    ;; from 1; columns count from 0.
    ;;
    ;; A knowing deviation: `find_newline' in the C exists largely to
    ;; cope with a byte store that a gap splits in two, and it keeps a
    ;; `region_cache' of where newlines are known to be, so that
    ;; repeated scans do not walk the whole buffer. `buffer-text-ref'
    ;; already copes with the gap, so the gap half of the C is gone;
    ;; the *cache* half is not ported, so a scan here really is O(n).
    ;; That is what the renderer pays for a line it reads by scanning to
    ;; it, and the cache is the Emacs answer when that stops being good
    ;; enough.

    ;;----------------------------------------------------------------
    ;; Positions


    (define (fetch-char ed pos)
      ;; The character at position POS, or false when there is none
      ;; there - GNU Emacs's `char-after' (`editfns.c'), which answers
      ;; nil at or past the end of the buffer.
      ;;--------------------------------------------------------------
      (and (<= (buffer-beg ed) pos)
           (< pos (buffer-z ed))
           (integer->char (buffer-text-ref (text-editor-text ed) pos))
           ))

    ;;----------------------------------------------------------------
    ;; Newlines

    (define (find-newline ed start count end)
      ;; GNU Emacs's `find_newline' (`search.c:675'): scan COUNT line
      ;; boundaries from START, forward for a positive COUNT and
      ;; backward for a negative one, and stop at END if COUNT of them
      ;; are not there.
      ;;
      ;; Two values come back: where the scan stopped, and how many
      ;; boundaries it found, counted the way COUNT is - positive going
      ;; forward, negative going backward. Where it found them all, the
      ;; position is just past the COUNTth one; where it ran out of
      ;; text, it is END. Both conventions are the C's, whose caller
      ;; reads the pair out of `*counted' and `*bytepos'.
      ;;
      ;; Scanning backward looks at the character *before* the position
      ;; it is at, so a COUNT of -1 from the middle of a line lands on
      ;; the line's first character when there is a newline just behind
      ;; it - which is what `bol' is.
      ;;
      ;; END false means what the C's zero means: "the end of the buffer
      ;; in the direction of travel" - `ZV' going forward, `BEGV' going
      ;; backward (`search.c:681').
      ;;
      ;; The line-break cache (`buf->newline_cache', which is
      ;; `(schemacs editor region-cache)') is consulted on the way, as
      ;; the C consults it: a stretch already searched and found to hold
      ;; no line break is skipped whole, and a stretch this scan crosses
      ;; without finding one is recorded as known. That is what makes a
      ;; buffer with very long lines affordable - see `region-cache.sld'
      ;; for why the C has it at all.
      ;;--------------------------------------------------------------
      (let* ((end  (or end (if (< 0 count)
                               (buffer-z ed)
                               (buffer-beg ed))))
             ;; The cache is made here on first use, as the C makes it
             ;; (`if (!cache_buffer->newline_cache) cache_buffer->
             ;; newline_cache = new_region_cache ()', `search.c:640') - a
             ;; buffer whose lines are never searched never pays for one.
             (cache (and (text-editor-cache-long-scans ed)
                         (or (%text-editor-newline-cache ed)
                             (let ((c (new-region-cache
                                       (buffer-beg ed))))
                               (set!%text-editor-newline-cache ed c)
                               c)))))
        (if (< 0 count)
            (find-newline-forward ed start count end cache)
            (find-newline-backward ed start count end cache))))

    (define (%newline-in ed pos lim)
      ;; The first line break in [POS, LIM), or false when there is none -
      ;; the C's "dumb loop", the innermost scan that knows nothing about
      ;; the cache or the buffer's ends. It carries one variable, because
      ;; it runs once per character.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((>= p lim) #f)
                ((= (buffer-text-ref text p) #x0a) p)
                (else (loop (+ p 1)))))))

    (define (%newline-before ed pos lim)
      ;; The first line break strictly before POS and at or after LIM,
      ;; answering the position just *after* it, or false when there is
      ;; none. Scanning backward looks at the character before the
      ;; position it is at, which is why the answer is a position past the
      ;; break rather than on it.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((<= p lim) #f)
                ((= (buffer-text-ref text (- p 1)) #x0a) p)
                (else (loop (- p 1)))))))

    (define (find-newline-forward ed start count end cache)
      ;; The forward half of `find-newline'. Each round asks the cache
      ;; where the knowledge runs out, scans that far for a line break,
      ;; and records what it crossed - which is the C's structure: consult,
      ;; dumb-loop, `know_region_cache', repeat.
      ;;
      ;; A stretch the cache calls known holds no line break, so it is
      ;; stepped over rather than looked at. That is the whole saving.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg ed))
            (z (buffer-z ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (>= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-forward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    ;; known: no break in here at all - step over it
                    (let ((skip (min next-change end)))
                      (if (<= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    ;; unknown as far as NEXT-CHANGE, or as far as the
                    ;; caller asked
                    (let ((lim (min (if (> next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-in ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (> lim pos))
                            (know-region-cache cache beg z pos lim))
                          (outer lim left found))
                         (else
                          (when (and cache (> nl pos))
                            (know-region-cache cache beg z pos nl))
                          (if (= left 1)
                              (values (+ nl 1) (+ found 1))
                              (outer (+ nl 1) (- left 1) (+ found 1)))))))))))))))

    (define (find-newline-backward ed start count end cache)
      ;; The backward half of `find-newline', the mirror of the forward
      ;; one: consult, scan down to where the knowledge runs out, record
      ;; what was crossed, repeat.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg ed))
            (z (buffer-z ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (<= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-backward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    (let ((skip (max next-change end)))
                      (if (>= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    (let ((lim (max (if (< next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-before ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (< lim pos))
                            (know-region-cache cache beg z lim pos))
                          (outer lim left found))
                         (else
                          (when (and cache (< nl pos))
                            (know-region-cache cache beg z nl pos))
                          ;; The count of boundaries found is
                          ;; `found - 1' here, and it was a hardcoded
                          ;; `-1' until 2026-10-06 - so every backward
                          ;; scan answered "one found" however many it
                          ;; had crossed. That is what the C's
                          ;; `counted' is, and `find_before_next_newline'
                          ;; reads it to decide whether to step back
                          ;; onto the newline. A COUNT of -2 found two
                          ;; breaks and said one, and nothing saw it
                          ;; until `line-end-position' was given the
                          ;; optional N that reaches a count below -1.
                          (if (= left -1)
                              (values nl (- found 1))
                              (outer (- nl 1) (+ left 1) (- found 1)))))))))))))))

    (define (scan-newline-from-point ed count)
      ;; GNU Emacs's `scan_newline_from_point' (`search.c':986'): scan
      ;; COUNT line boundaries from point. It does not move point.
      ;;
      ;; Two values come back - where the scan stopped, and how many
      ;; boundaries it found - which is the C's two out-parameters
      ;; (`*charpos' and the returned `counted'). A COUNT at or below
      ;; zero scans backward, one boundary further back than COUNT asks
      ;; for; that difference is what makes `bol' land on the *start* of
      ;; a line where `forward-line' would land on the one before it.
      ;;--------------------------------------------------------------
      (if (<= count 0)
          (find-newline ed (buffer-pt ed) (- count 1)
                        (buffer-beg ed))
          (find-newline ed (buffer-pt ed) count
                        (buffer-z ed))))

    (define (bol ed n)
      ;; The position of the first character of the line N - 1 lines
      ;; forward - the internal `bol' (`editfns.c:665') that
      ;; `line-beginning-position', `beginning-of-line' and
      ;; `forward-line' are all built on. N false means the current
      ;; line. It does not move point.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (scan-newline-from-point ed (if n (- n 1) 0)))
        (lambda (pos _found) pos)))

    (define (eol ed n)
      ;; The position of the last character of the line N - 1 lines
      ;; forward - the internal `eol' (`editfns.c:723') that
      ;; `line-end-position', `end-of-line' and `forward-line' are built
      ;; on. N false means the current line. It does not move point.
      ;;--------------------------------------------------------------
      (let ((count (if n n 1)))
        (find-before-next-newline ed (buffer-pt ed)
                                  (- count (if (<= count 0) 1 0)))))

    (define (find-before-next-newline ed from cnt)
      ;; GNU Emacs's `find_before_next_newline' (`search.c':997'): where
      ;; the line boundary CNT boundaries away from FROM begins. With a
      ;; positive CNT the scan lands just *after* the newline, so it
      ;; steps back one, to the newline's own position - which is what
      ;; an end-of-line wants.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (find-newline ed from cnt #f))
        (lambda (pos found)
          (if (= found cnt) (- pos 1) pos))))

    ;; **`count-lines' has left, for `(schemacs editor fns)'.** It is
    ;; `xdisp.c:29892' and it wants to be low, because `fns.c''s
    ;; `line-number-at-pos' is its only real caller; this library is not
    ;; low enough for that, having been reached *from* `xdisp.scm' all
    ;; along. The name is still exported below, imported from there, so
    ;; that this library's own readers - and its tests - do not move with
    ;; it.

    ;;----------------------------------------------------------------
    ;; Lines, by scanning

    (define (%line-start ed line)
      ;; The position of the first character of line LINE, counting from
      ;; 1; false when the buffer has no such line. This is the `bol'
      ;; scan started from the buffer's beginning rather than from
      ;; point: `find_newline' from `point-min' for LINE - 1 boundaries.
      ;;--------------------------------------------------------------
      (and (integer? line)
           (<= (buffer-beg ed) line)
           (call-with-values
               (lambda ()
                 (find-newline ed (buffer-beg ed) (- line 1) #f))
             (lambda (pos found) (and (= found (- line 1)) pos)))))

    (define (%bol-at ed pos)
      ;; The position of the first character of the line POSITION is on.
      ;; Emacs reaches this with `save-excursion' around
      ;; `line-beginning-position'; here the scan simply starts where it
      ;; is told to.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda ()
            (find-newline ed pos -1 (buffer-beg ed)))
        (lambda (found-pos _found) found-pos)))

    (define (%line-end ed from)
      ;; The position of the newline that ends the line containing FROM, or
      ;; `point-max' when there is none. It is the forward half of `eol'
      ;; with the scan started where it is told to rather than at point.
      ;;
      ;; It goes through `find-before-next-newline', and so through
      ;; `find-newline' and the line-break cache, as the C's does. It used
      ;; to be a private character-at-a-time loop, which not only
      ;; duplicated a scan Emacs already has but missed the cache
      ;; entirely - a long line was re-walked by every caller, which is
      ;; what `region-cache.c' exists to prevent.
      ;;--------------------------------------------------------------
      (find-before-next-newline ed from 1))

    (define (%text-editor-position ed line col)
      ;; The position of column COL - counting from 0 - on line LINE -
      ;; counting from 1 - clamped to the line. False when the buffer
      ;; has no such line. This is what `goto-line' and `move-to-column'
      ;; between them do, `line-beginning-position' then an offset.
      ;;--------------------------------------------------------------
      (let ((start (%line-start ed line)))
        (and start
             (min (%line-end ed start) (+ start (max 0 col))))))

    (define text-editor-get-start-of-line
      ;; The position of the first character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-beginning-position' (`editfns.c:700'), which is
      ;; `(bol nil)'; with a POSITION the C reaches the same place with
      ;; `save-excursion' around `goto-char', the scan here simply starts
      ;; where it is told to. It does not move point.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (bol ed #f))
       ((ed pos) (%bol-at ed pos))))

    (define text-editor-get-end-of-line
      ;; The position of the last character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-end-position' (`editfns.c:736'), which is `(eol nil)'; the
      ;; POSITION form is the same scan started where it is told to
      ;; rather than at point. At the end of the buffer it is `point-max',
      ;; as the C's is. It does not move point.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (eol ed #f))
       ((ed pos) (%line-end ed pos))))

    (define (text-editor-cursor-line ed)
      ;; The line number point is on, counting from 1 - GNU Emacs's
      ;; `line-number-at-pos' (`fns.c:6688'), which is
      ;; `(count_lines BEGV PT) + 1'.
      ;;--------------------------------------------------------------
      (+ 1 (count-lines ed (buffer-beg ed) (buffer-pt ed))))

    (define (text-editor-cursor-column ed)
      ;; How many characters point is from the start of its line,
      ;; counting from 0 - what the C's `current-column' (`indent.c:298')
      ;; answers for a line with no tab and no multi-column character in
      ;; it. The *display* column, which is what `current-column' really
      ;; answers, is `(schemacs editor indentc)''s
      ;; `current-line-display-column', and every caller that wants one
      ;; goes through it.
      ;;--------------------------------------------------------------
      (- (buffer-pt ed) (text-editor-get-start-of-line ed)))

    ;;----------------------------------------------------------------
    ;; Moving the cursor

    (define (text-editor-move-cursor ed move-by)
      ;; Move the cursor MOVE-BY characters, clamped to the buffer -
      ;; GNU Emacs's `forward-char' (`cmds.c') with its two endpoint
      ;; errors replaced by that clamp. Answers the new position.
      ;;--------------------------------------------------------------
      (text-editor-set-cursor
       ed (max (buffer-beg ed)
               (min (buffer-z ed)
                    (+ (buffer-pt ed) move-by)))))

    (define text-editor-set-cursor
      (case-lambda
       ((ed index)
        (if (integer? index)
            ;; A position, one-based as every position here is.
            (set!buffer-pt ed
               (max (buffer-beg ed)
                    (min (buffer-z ed) index)))
            (error "text editor index must be set with an integer" index)))
       ((ed line-num column-num)
        ;; Move the cursor to the given line - counting from 1, as
        ;; `line-number-at-pos' does - and column, counting from 0 as
        ;; `current-column' does, clamped to the line. This is
        ;; `goto-line' followed by `move-to-column', both built on the
        ;; scans.
        ;;
        ;; The new empty line past the end of the buffer is only
        ;; addressable when the buffer's last line ends in a line break
        ;; - that break is what starts it. Without one, the last line
        ;; the buffer holds is the last line there is, and the end of
        ;; the buffer is the end of that line, which is where GNU Emacs
        ;; puts `point-max'.
        (set!buffer-pt
         ed (max (buffer-beg ed)
                 (min (buffer-z ed)
                      (or (%text-editor-position
                           ed (max 1 line-num) (max 0 column-num))
                          (buffer-z ed)))))))

      )

    ;;----------------------------------------------------------------
    ;; The seams into this library, installed as it loads
    ;;------------------------------------------------------------------
    ;; **These used to be installed by `frame.sld', because the engine
    ;; was BELOW the buffer library and could not reach the parameters it
    ;; defines.** The record is the buffer library's now, the engine is
    ;; built on it, and so these are installed where the functions are.
    ;;
    ;; **`marker.scm`'s five seams are installed where marker.c's
    ;; functions are**, which is the point of that library, and so are
    ;; `insdel.scm`'s change hooks and `invalidate-buffer-caches`.
    ;;
    ;; What is left is `insdel.c`'s `del_range`, which is what
    ;; `Ferase_buffer` calls to empty a buffer.
    ;;
    ;; **undo.c's two recorders used to be installed here too**, as
    ;; *upward* seams: `insdel.scm` called `record-insert`/`record-delete`
    ;; from `del_range_2` and `insert_1_both`, and undo.c had no library.
    ;; `undo.scm` exists now and sits below `insdel.scm`, so `insdel.scm`
    ;; calls the recorders directly and the three seams are gone.
    (*del-range-function* del-range)

    )
  )
