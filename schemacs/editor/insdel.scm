(define-library (schemacs editor insdel)
  ;; This library mirrors GNU Emacs's `insdel.c': inserting text into a
  ;; buffer and deleting text from it. It is the file that owns the words
  ;; *change* and *modification* - `prepare_to_modify_buffer`,
  ;; `signal_before_change`, `signal_after_change`, `invalidate_buffer_caches`
  ;; - and the two writers everything else goes through.
  ;;
  ;; **It is `insdel.c` and not "the engine".** The engine this tree grew
  ;; from put the whole *operation* in one function per user action -
  ;; `text-editor-insert`, `text-editor-delete-from-cursor` - and hoisted
  ;; the bookkeeping out to it. The C does the opposite: `del_range` and
  ;; `insert_1_both` each do the work and call the hooks and the undo
  ;; recorder themselves, so every caller gets the same bookkeeping
  ;; without asking for it. This library is that shape; the callers above
  ;; it become Emacs's callers.
  ;;
  ;; **What it needs from above arrives through seams**, because those
  ;; things are other Emacs files that sit higher in this tree's graph:
  ;;
  ;;   * `record_insert` / `record_delete` are `undo.c`'s and are called
  ;;     directly now: `undo.scm` exists and sits *below* this library, so
  ;;     the three `*record-*-function*` seams this file used to declare
  ;;     are gone;
  ;;   * `offset_intervals` is `intervals.c`'s
  ;;     (`*text-property-offset-function*`, which used to be declared in
  ;;     the engine - it moved down here because this library is below
  ;;     it).
  ;;
  ;; **What `insdel.c` reaches *up* for, checked by listing the calls it
  ;; makes that it does not define.** Emacs's C files include each other,
  ;; so the list is longer than one would guess, and an earlier draft of
  ;; this note claimed "exactly one upward dependency" - which was wrong.
  ;; The list, and what each becomes here:
  ;;
  ;;   * `find_newline_no_quit` (search.c) - **twice**, both inside
  ;;     `invalidate_buffer_caches`, both only for the
  ;;     `bidi_paragraph_cache`, which is not ported (`region-cache.scm`).
  ;;   * `update_search_regs` (search.c) - **once**, inside
  ;;     `replace_range` and only when `adjust_match_data`; `replace_range`
  ;;     is not carried, so this comes with it.
  ;;   * `make_buffer_string_both` (**editfns.c**:1585) - `del_range_2`
  ;;     uses it to capture the text it is about to delete, because
  ;;     `record_delete` needs it. Here that is `buffer-text-substring`,
  ;;     the store read, which is *below* this library. The C helper is in
  ;;     editfns.c because a string with text properties is an editfns
  ;;     idea; a read of the characters is the store's.
  ;;   * the interval machinery - `offset_intervals`, `verify_interval_modification`,
  ;;     `report_interval_modification`, `buffer_intervals`, `copy_intervals`,
  ;;     `graft_intervals_into_buffer`, `set_text_properties`,
  ;;     `string_intervals` (intervals.c, textprop.c). One of them is the
  ;;     seam below; the rest are the overlays-and-properties work Emacs
  ;;     does around a change, which this tree does from the
  ;;     `*text-property-offset-function*` seam and from
  ;;     `after-change-functions`.
  ;;   * `adjust_overlays_for_insert`/`_delete`, `buffer_has_overlays`,
  ;;     `report_overlay_modification` (buffer.c) - overlays here are a
  ;;     plain list of markers, so there is nothing to adjust and nothing
  ;;     to report.
  ;;   * `bset_redisplay`, `bset_point_before_scroll` (xdisp.c);
  ;;     `update_compositions` (syntax.c); `enlarge_buffer_text` (alloc.c);
  ;;     `pdumper_object_p`, `internal_catch_all`, `run_hook`,
  ;;     `set_buffer_internal`, `maybe_quit` - **not carried**, each named
  ;;     at the place it would go.
  ;;
  ;; So the only reach into `search.scm` is `update_search_regs`, and it
  ;; arrives with `replace_range`. The dependency graph stays acyclic
  ;; because everything else on that list is a seam or an absence.
  ;;
  ;; **STATUS: WIRED. What is left of the stage is the callers.**
  ;;
  ;; `engine.scm` imports this library's `*after-change-functions*`,
  ;; `signal-after-change`, `*text-property-offset-function*`,
  ;; `invalidate-buffer-caches`, `adjust-markers-for-insert`,
  ;; `del-range`, `prepare-to-modify-buffer` and the two record seams,
  ;; and re-exports what other libraries were already reading. There is
  ;; exactly one copy of each of those in the tree.
  ;;
  ;; `engine.scm`'s own `text-editor-invalidate-caches!`,
  ;; `adjust-markers-for-insertion!`, `adjust-markers-for-deletion!` and
  ;; `%del-range` are **deleted**; the first three were these functions
  ;; under invented names, and `%del-range` was `del_range` with a wart
  ;; its own comment confessed - it moved point to FROM and deleted from
  ;; there, where the C leaves point alone.
  ;;
  ;; `%text-editor-note-change!` is split the way the C splits it: the
  ;; `deactivate-mark` flag is `prepare_to_modify_buffer_1`'s last line
  ;; and is set here; undo.c's `record_point` - the mark of the last save
  ;; - is `record_insert`/`record_delete`'s, in the engine until
  ;; `undo.scm` exists, and reaches `del_range_2` through the two seams
  ;; below.
  ;;
  ;; **What is left of stage 3** is the callers' rewrite, which is the
  ;; bulk of it: `text-editor-insert` (19 files) and
  ;; `text-editor-delete-from-cursor` (12 files) are invented names for
  ;; editfns.c's `insert` and cmds.c's `delete-char`. `editfns.scm` and
  ;; `cmds.scm` already wrap both, so the rewrite is the call sites - and
  ;; each must say which buffer it means by making it current, because
  ;; the C's primitives act on `current_buffer` and ours now do too.
  ;;
  ;; **The insertion is now the C's composition too**, and this is the
  ;; part that used to be wrong in a way no test could see. The engine's
  ;; store writer advanced point *per character* as the text went in,
  ;; where the C writes the whole thing into the gap in one go and then
  ;; calls `adjust_point (nchars)` **once**, at the end. `adjust-point`
  ;; had no caller at all here, which was the tell. Now:
  ;;
  ;;   * `insert-from-string` (`insdel.c:981`) - the wrapper that
  ;;     captures `opoint` and signals the after-change hooks with it;
  ;;   * `insert-from-string-1` (`insdel.c:1017`) - the work, in the C's
  ;;     order: prepare, one write into the store, `record_insert`,
  ;;     `modiff_incr`, the markers, `offset_intervals`, `adjust_point`.
  ;;
  ;; The engine's `text-editor-force-insert-char`,
  ;; `text-editor-force-insert-code-point` and `%text-editor-insert` are
  ;; **deleted**; they existed only because the writer moved point one
  ;; character at a time. What is left in the engine is
  ;; `text-editor-insert`, which is `Finsert`'s one-argument reading plus
  ;; this tree's code-point door, wrapped in `with-current-buffer` for
  ;; the callers that pass a buffer the C would have had current.
  ;;
  ;; **One behavioural consequence, and it is the C's**: an insertion of
  ;; nothing is now a complete no-op, *including* not barring a read-only
  ;; buffer - `insert_from_string` returns before `insert_from_string_1`
  ;; when the string is empty. The old code barred first, whatever the
  ;; text.
  ;;
  ;; The two hooks' own notes are worth re-reading before relying on
  ;; them: `*before-change-functions*` has no listener anywhere in the
  ;; tree, and `signal-after-change` carries none of the C's deferral,
  ;; overlay or interval reports.
  ;;
  ;; **Not carried**, each named where it would go: `insert_from_buffer`,
  ;; `replace_range_3` (which takes a buffer or a `(buffer beg end)`
  ;; vector where `replace_range` takes a string), the byte/char position
  ;; juggling
  ;; (`from_byte`, `to_byte`, `adjust_markers_bytepos`, `count_bytes`,
  ;; `count_combining_*`) which exist only because Emacs's buffer holds
  ;; bytes, `buffer_overflow`, the pdumper COW check, the tty text
  ;; conversion, `update_compositions` (syntax.c), `run_undoable_change`
  ;; (undo.c), `adjust_overlays_for_insert`/`_delete` (overlays are
  ;; markers here), and `record_marker_adjustments`, which is why undoing
  ;; a deletion does not put the markers inside it back.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    ;; `list->u32vector` is Guile's, and is only here to turn the
    ;; code-point list `find-file-noselect` hands over into the
    ;; `u32vector` the store takes - Emacs has no such step, its strings
    ;; holding its characters. `u32vector-length` is `(scheme base)`'s
    ;; `string-length` for the same store, and is asked the same way.
    (only (guile) list->u32vector u32vector-length)
    ;; `BEG_UNCHANGED`/`END_UNCHANGED` are fields of `struct buffer_text`,
    ;; so they are read and written where the text is.
    (only (schemacs editor buffer-text)
          buffer-text-beg-unchanged set!buffer-text-beg-unchanged
          buffer-text-modiff set!buffer-text-chars-modiff
          buffer-text-substring buffer-text-delete!
          buffer-text-insert! buffer-text-insert-code-points!)
    ;; The line-break cache is the one cache this tree keeps. The C's
    ;; `bidi_paragraph_cache` and `width_run_cache` cache things nothing
    ;; here asks for.
    (only (schemacs editor region-cache) invalidate-region-cache)
    (only (schemacs editor buffer)
          current-buffer buffer-beg buffer-z buffer-pt set!buffer-pt
          barf-if-buffer-read-only text-editor-text text-editor-undo-list
          %text-editor-newline-cache
          ;; `Ferase_buffer` (`buffer.c`) empties a buffer by calling
          ;; `del_range`, which is this library's - so the seam it reaches
          ;; it through is declared down there and installed at the foot
          ;; of this file. (It was the engine that installed it, because
          ;; the engine was the only thing that had both; the engine is
          ;; gone and the seam belongs with `del_range`.)
          *del-range-function*
          ;; `deactivate-mark' is a buffer-local variable and `buffer.c`
          ;; owns the table, so `prepare-to-modify-buffer-1` writes it
          ;; through the slot accessor; there is no seam to install and no
          ;; named accessor to ask keyboard.scm for.
          set-buffer-local-value!
          %text-editor-incr-modiff!)
    (only (schemacs editor marker)
          %for-each-marker %marker-charpos set!%marker-charpos
          marker-insertion-type)
    ;; undo.c's recorders are *below* this library now - `undo.scm` exists
    ;; and sits between the buffer and this one - so `record_insert` and
    ;; `record_delete` are called directly, as `insdel.c` calls them, and
    ;; the three `*record-*-function*` seams are gone.
    (only (schemacs editor undo)
          record-insert  record-delete  record-first-change
          ;; `replace_range` asks whether undo is recording before it
          ;; captures the text it is about to delete - the C's
          ;; `!EQ (BUF_UNDO_LIST (current_buffer), Qt)`. It was a truth
          ;; test of the list until 2026-10-14, when the sentinel became
          ;; Emacs's `t'.
          text-editor-undo-recording?)
    )

  (export
   ;; the change hooks
   *before-change-functions*  *after-change-functions*
   signal-before-change  signal-after-change
   ;; the caches
   invalidate-buffer-caches
   ;; the read-only gate and the preparation
   prepare-to-modify-buffer-1  prepare-to-modify-buffer
   ;; the markers
   adjust-markers-for-insert  adjust-markers-for-delete
   adjust-markers-for-replace  adjust-point
   ;; the insertion
   insert-from-string  insert-from-string-1
   ;; the deletion
   del-range  del-range-1  del-range-2
   ;; replacing, which is neither: `replace_range` deletes and inserts in
   ;; one operation so that the markers and the intervals see one change
   replace-range
   ;; ... and the loop's own, which neither prepares nor signals nor
   ;; records - its caller does all three once around the whole region
   replace-range-2
   ;; the other entry for a change, for the ones no insert/delete
   ;; primitive makes: prepare, and raise the counter over the region
   modify-text
   *text-property-offset-function*
   *graft-intervals-function*  *adjust-suspend-auto-hscroll-function*
   *update-search-regs-function*
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The change hooks
    ;;------------------------------------------------------------------
    ;;
    ;; `before-change-functions` and `after-change-functions` are
    ;; `insdel.c`'s own variables (`Vbefore_change_functions`,
    ;; `Vafter_change_functions`), which is why they are here and not in
    ;; `xdisp.scm` with the other display hooks. They are parameters, as
    ;; this tree keeps the flags Elisp let-binds, so a caller writes
    ;; `(parameterize ((*after-change-functions* (list f))) ...)`.

    (define *after-change-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-functions`: "List of functions to call
    ;; after a change in the buffer. Each function is called with three
    ;; arguments: the beginning and end of the text that was changed, and
    ;; the length of the old text." The positions are one-based, as every
    ;; position of the Emacs-named layer is. `font-lock-mode` hangs its
    ;; incremental fontification on this.

    (define *before-change-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `before-change-functions`: "List of functions to call
    ;; before a buffer is modified. Each function gets two arguments, the
    ;; beginning and end of the region to be modified." **It did not exist
    ;; here at all** until this library was written: the C signals before
    ;; every change and nothing here listened. Nothing has a listener yet
    ;; either, so this is the hook with no callers - but the signal is
    ;; part of `prepare_to_modify_buffer`'s contract and a port that
    ;; omitted it would have to be re-opened the first time a caller
    ;; wanted one.

    (define (signal-before-change start end)
      ;; GNU Emacs's `signal_before_change` (`insdel.c:2310`): run the
      ;; before-change hooks over a change about to be made.
      ;;
      ;; **Not carried**: `first-change-hook`, which the C runs first when
      ;; the buffer is unmodified
      ;; (`SAVE_MODIFF >= MODIFF && !NILP (Vfirst_change_hook)`), and the
      ;; two reports `report_overlay_modification` makes. The C's
      ;; `PRESERVE_VALUE`/`PRESERVE_START_END` dance around each hook
      ;; exists so that a hook which edits the buffer cannot move the
      ;; arguments out from under the ones that follow; with one hook list
      ;; and no overlays the args are read once, here.
      ;;--------------------------------------------------------------
      (for-each (lambda (f) (f start end))
                (*before-change-functions*)))

    (define (signal-after-change charpos lendel lenins)
      ;; GNU Emacs's `signal_after_change` (`insdel.c:2381`): run
      ;; `after-change-functions` over a change that has just been made.
      ;; The C's `(charpos, lendel, lenins)` are the three arguments in
      ;; this order: `(charpos + lenins)` is where the changed text now
      ;; ends, and LENDEL is what was there before it - zero for an
      ;; insertion, which is what lets a hook tell an insertion from a
      ;; deletion.
      ;;
      ;; **Not carried**: `combine-after-change-calls` (the C's deferral
      ;; of the calls into `combine_after_change_list`), the reset of the
      ;; hook variable if a hook errors, and the `insert-behind-hooks` /
      ;; `insert-in-front-hooks` that the C runs after an insertion
      ;; (`report_interval_modification`).
      ;;--------------------------------------------------------------
      (for-each (lambda (f) (f charpos (+ charpos lenins) lendel))
                (*after-change-functions*)))

    ;;----------------------------------------------------------------
    ;; The caches
    ;;------------------------------------------------------------------

    (define (invalidate-buffer-caches buffer start end)
      ;; GNU Emacs's `invalidate_buffer_caches` (`insdel.c:2206`): "Tell
      ;; the buffer's caches that the region START to END is about to
      ;; change", which `prepare_to_modify_buffer` calls before every
      ;; modification.
      ;;
      ;; The cache is told in the HEAD/TAIL form - "this many characters
      ;; unchanged at the beginning of the buffer, this many at the end" -
      ;; rather than with positions, because an insertion or a deletion
      ;; moves everything after it and that form reads the same before and
      ;; after the change.
      ;;
      ;; The C's first half is the `bidi_paragraph_cache`, which is not
      ;; ported - and that half is the whole reason it calls
      ;; `find_newline_no_quit`. What is left is the `BEG_UNCHANGED`
      ;; update and the newline cache.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg buffer))
            (text (text-editor-text buffer)))
        ;; Nothing before the change is known to be unchanged any more -
        ;; the C's `if (GPT - BEG < BEG_UNCHANGED) BEG_UNCHANGED = GPT -
        ;; BEG` (`insdel.c:1608'). The `%l` cache reads this to decide
        ;; whether the line number it remembers is still true.
        (let ((prefix (- start beg)))
          (when (< prefix (buffer-text-beg-unchanged text))
            (set!buffer-text-beg-unchanged text prefix)))
        (let ((cache (%text-editor-newline-cache buffer)))
          (when cache
            (invalidate-region-cache cache beg (buffer-z buffer)
                                     (- start beg)
                                     (- (buffer-z buffer) end))))))

    ;;----------------------------------------------------------------
    ;; Preparing a change
    ;;------------------------------------------------------------------

    (define (prepare-to-modify-buffer-1 start end)
      ;; GNU Emacs's `prepare_to_modify_buffer_1` (`insdel.c:2125`), the
      ;; half that does not touch the caches.
      ;;
      ;; **The read-only gate is the first thing**, and it is
      ;; `barf-if-buffer-read-only` (`buffer.c:2453`) rather than a test
      ;; written out here: the C calls it, it is `buffer.c`'s, and the
      ;; same function is what `erase-buffer`'s interactive spec asks.
      ;; What it does *not* do is check `inhibit-read-only` itself - that
      ;; flag is inside `barf-if-buffer-read-only`, one library down.
      ;;
      ;; **The deactivate-mark flag is set here**, at the C's last line
      ;; `(Fset (Qdeactivate_mark, Qt))`. It used to be set from
      ;; `%text-editor-note-change!` in the engine, bundled with the
      ;; `record_first_change` that is `undo.c`'s - two things from two
      ;; different C files in one function, set at the wrong moment.
      ;;
      ;; **Not carried**: `run_undoable_change` (undo.c), `bset_redisplay`,
      ;; the pdumper COW check, `verify_interval_modification` and its
      ;; preserving marker (so START is returned unchanged rather than
      ;; possibly moved), `Flock_file`, and the `saved_region_selection`
      ;; save for `select-active-regions` - which `keyboard.scm` does
      ;; itself after each command.
      ;;
      ;; The C takes `preserve_ptr` so that the interval verification can
      ;; *move* the start, and `del_range_1` re-derives the end from it.
      ;; Nothing here moves it, so this returns START and the caller is
      ;; written the C's way anyway, ready for the day something does.
      ;;--------------------------------------------------------------
      (barf-if-buffer-read-only start)
      (signal-before-change start end)
      ;; The C's last line is `Fset (Qdeactivate_mark, Qt)' - "Buffer
      ;; modifications store t in this variable", and it is a buffer-local
      ;; one, so it is the *current buffer's* value that is set.
      (set-buffer-local-value! (current-buffer) 'deactivate-mark #t)
      start)

    (define (prepare-to-modify-buffer start end)
      ;; GNU Emacs's `prepare_to_modify_buffer` (`insdel.c:2196`): "Like
      ;; above, but called when we know that the buffer text will be
      ;; modified and region caches should be invalidated." The whole of
      ;; the difference is the second call.
      ;;--------------------------------------------------------------
      (let ((start (prepare-to-modify-buffer-1 start end)))
        (invalidate-buffer-caches (current-buffer) start end)
        start))

    ;;----------------------------------------------------------------
    ;; Adjusting the markers
    ;;------------------------------------------------------------------
    ;;
    ;; These are the calls that make a marker follow the text. They live
    ;; in `insdel.c`, not `marker.c`: setting and reading a marker is
    ;; marker.c's, and moving one when the text around it changes is the
    ;; business of whoever changed the text.

    (define (adjust-markers-for-delete from to)
      ;; GNU Emacs's `adjust_markers_for_delete` (`insdel.c:249'): "If
      ;; the marker is after the deletion, relocate by number of chars /
      ;; bytes deleted. Here's the case where a marker is inside text
      ;; being deleted" - which is left at the *start* of what went.
      ;;
      ;; The C's `charpos > to` and `charpos > from` are strict: a marker
      ;; exactly at TO moves back with everything after it, and one
      ;; exactly at FROM does not move at all.
      ;;--------------------------------------------------------------
      (%for-each-marker
       (current-buffer)
       (lambda (marker)
         (let ((charpos (%marker-charpos marker)))
           (cond ((> charpos to) (set!%marker-charpos marker (- charpos (- to from))))
                 ((> charpos from) (set!%marker-charpos marker from)))))))

    (define (adjust-markers-for-insert from to before-markers)
      ;; GNU Emacs's `adjust_markers_for_insert` (`insdel.c:288`):
      ;; "Relocate the charpos of every marker that points after the
      ;; insertion (but not their bytepos). When a marker points at the
      ;; insertion point, we advance it if either its insertion-type is t
      ;; or BEFORE_MARKERS is true."
      ;;
      ;; The C compares *byte* positions - `m->bytepos == from_byte` and
      ;; `m->bytepos > from_byte` - because that is what its markers
      ;; cache. A marker's bytepos is the byte offset of its charpos, so
      ;; `bytepos == from_byte` is `charpos == from` and the two agree;
      ;; there is no byte half here to compare.
      ;;--------------------------------------------------------------
      (let ((nchars (- to from)))
        (%for-each-marker
         (current-buffer)
         (lambda (marker)
           (let ((charpos (%marker-charpos marker)))
             (cond ((and (= charpos from)
                         (or (marker-insertion-type marker) before-markers))
                    (set!%marker-charpos marker to))
                   ((> charpos from)
                    (set!%marker-charpos marker (+ charpos nchars)))))))))

    (define (adjust-markers-for-replace from old-chars new-chars)
      ;; GNU Emacs's `adjust_markers_for_replace` (`insdel.c:342`):
      ;; "Adjust markers for a replacement of a text at FROM of length
      ;; OLD_CHARS to a new text of length NEW_CHARS."
      ;;
      ;; The two ends are strict in opposite directions, and that is the
      ;; whole of the rule: a marker at or after the END of the old text
      ;; moves with everything after it (by the *difference* in length,
      ;; since the text after it has not gone anywhere), and a marker
      ;; strictly inside the old text is left at FROM - there is nothing
      ;; of it left to point at.
      ;;
      ;; A pure insertion is delegated, as the C delegates it, so that
      ;; the loop below need not know about insertion types.
      ;;
      ;; Not carried: `adjust_overlays_for_insert`/`_delete` at the end
      ;; (`buffer.c`). Ours are markers, and the marker walk above has
      ;; already moved them.
      ;;--------------------------------------------------------------
      (if (= old-chars 0)
          (adjust-markers-for-insert from (+ from new-chars) #f)
          (let ((prev-to (+ from old-chars))
                (diff (- new-chars old-chars)))
            ;; "If the selected window's old pointm is adjacent or covered
            ;; by the region from FROM to TO, unsuspend auto hscroll in
            ;; that window" (`insdel.c:222`) - the C's own call, one line
            ;; before its loop. It reads the *window*, which sits above
            ;; this library, so it is a seam.
            ((*adjust-suspend-auto-hscroll-function*) from prev-to)
            (%for-each-marker
             (current-buffer)
             (lambda (marker)
               (let ((charpos (%marker-charpos marker)))
                 (cond ((>= charpos prev-to)
                        (set!%marker-charpos marker (+ charpos diff)))
                       ((> charpos from)
                        (set!%marker-charpos marker from)))))))))

    (define (adjust-point nchars)
      ;; GNU Emacs's `adjust_point` (`insdel.c:328'): "Move point for an
      ;; insertion of NCHARS characters. This is used only when the value
      ;; of point changes due to an insert or delete; it does not
      ;; represent a conceptual change in point as a marker."
      ;;
      ;; The C's comment is the reason this is a plain field write and not
      ;; `goto-char`: "point is not crossing any interval boundaries, so
      ;; there's no need to use the usual SET_PT macro. In fact it would
      ;; be incorrect to do so, because either the old or the new value of
      ;; point is out of sync with the current set of intervals." Our
      ;; `set!buffer-pt` is the same field write.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (set!buffer-pt buffer (+ (buffer-pt buffer) nchars))))

    ;;----------------------------------------------------------------
    ;; Inserting text
    ;;------------------------------------------------------------------

    (define (insert-from-string-1 text inherit before-markers)
      ;; GNU Emacs's `insert_from_string_1` (`insdel.c:1017`), the work.
      ;; Answers the number of characters inserted, or false for none.
      ;;
      ;; **TEXT is a string, or this tree's one addition, a list or
      ;; `u32vector` of code points.** Emacs needs no second form - its
      ;; strings hold its characters - but the one value a Scheme string
      ;; cannot hold is a *byte character* (`#x3FFFE9' is above Guile's
      ;; `#x10FFFF'), so a file whose bytes no charset can read has to
      ;; come in this way. It is the only reason the parameter is not
      ;; simply a string, and it is why `buffer_text' has the matching
      ;; `buffer-text-insert-code-points!`.
      ;;
      ;; The C's steps in the C's order. Two of them are easy to get
      ;; wrong and are called out below: where `record_insert` goes
      ;; relative to the copy, and the single `adjust_point` at the end.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (store (text-editor-text buffer))
             (pt (buffer-pt buffer))
             (nchars (cond ((string? text) (string-length text))
                           ((list? text) (length text))
                           (else (u32vector-length text)))))
        (if (= nchars 0)
            #f
            (begin
              ;; `insert_from_string_1` prepares *unconditionally* - the
              ;; PREPARE flag is `insert_1_both`'s, which a caller may
              ;; turn off. This is what bars a read-only buffer, runs the
              ;; before-change hooks, sets the deactivate-mark flag and
              ;; invalidates the caches.
              (prepare-to-modify-buffer pt pt)
              ;; The C's "copy the text into the buffer". **Point does
              ;; not move here**, and the old writer did move it, once
              ;; per character: the C moves the *gap* (`GPT += nchars')
              ;; and moves point once, at the end.
              (if (string? text)
                  (buffer-text-insert! store pt text)
                  (buffer-text-insert-code-points!
                   store pt (if (list? text) (list->u32vector text) text)))
              ;; `record_insert (PT, nchars)`. In this C function it is
              ;; *after* the copy, where `insert_1_both` has it before;
              ;; either way it precedes `modiff_incr`, which is the part
              ;; that matters - `record_point` asks "is this the first
              ;; change since the save?" and the counter is what answers.
              (record-insert pt nchars)
              ;; `modiff_incr (&MODIFF, nchars); CHARS_MODIFF = MODIFF'
              (%text-editor-incr-modiff! buffer nchars)
              ;; `adjust_markers_for_insert (PT, PT_BYTE, PT + nchars, ..)'
              (adjust-markers-for-insert pt (+ pt nchars) before-markers)
              ;; `offset_intervals (current_buffer, PT, nchars)'
              (let ((offset (*text-property-offset-function*)))
                (when offset (offset buffer pt nchars)))
              ;; `graft_intervals_into_buffer (string_intervals (string),
              ;; PT, nchars, current_buffer, inherit)'. **It belongs
              ;; here**, before point moves and before the after-change
              ;; hooks: the C has it between `offset_intervals` and
              ;; `adjust_point`, so the properties are on the text by the
              ;; time `signal_after_change` runs. This tree called it from
              ;; `editfns.scm`'s `insert` *after* this function returned -
              ;; a font-lock listener therefore saw the new text without
              ;; its properties.
              ;;
              ;; **INHERIT is the whole of what separates `insert' from
              ;; `insert-and-inherit'**, and it is read inside the graft:
              ;; text that brings no intervals has its properties
              ;; *cleared* when inherit is false, and keeps whatever it
              ;; was inserted into when it is true.
              (let ((graft (*graft-intervals-function*)))
                (when graft (graft text pt nchars buffer inherit)))
              ;; and `adjust_point (nchars, outgoing_nbytes)' - **the one
              ;; place point moves**.
              (adjust-point nchars)
              nchars))))

    (define (insert-from-string text . rest)
      ;; GNU Emacs's `insert_from_string` (`insdel.c:981`): "the public
      ;; wrapper. It is what captures the position the change starts at -
      ;; the C's `opoint` - and signals the after-change hooks with it,
      ;; which is why the private half above does not signal.
      ;;
      ;; `(charpos, lendel, lenins)` is `(opoint, 0, PT - opoint)`: a
      ;; pure insertion deletes nothing, and what it inserted is how far
      ;; point moved.
      ;;--------------------------------------------------------------
      (let ((opoint (buffer-pt (current-buffer))))
        (let ((nchars (insert-from-string-1
                       text
                       (and (pair? rest) (car rest))
                       (and (pair? rest) (pair? (cdr rest)) (cadr rest)))))
          (when nchars
            (signal-after-change opoint 0 nchars))
          nchars)))

    ;;----------------------------------------------------------------
    ;; Deleting text
    ;;------------------------------------------------------------------

    (define (del-range from to)
      ;; GNU Emacs's `del_range` (`insdel.c`): "Delete the characters
      ;; between FROM and TO." It is `del_range_1` with both flags on:
      ;; prepare the change, and do not answer the text.
      ;;
      ;; **It leaves point where it was**, except that point inside the
      ;; deleted text is carried to the start of it - `del_range_2` does
      ;; that with `adjust_point`. This tree's `%del-range` moved point to
      ;; FROM first and deleted from there, which its own comment
      ;; confessed: "For the one caller - `erase-buffer` - the two agree.
      ;; They would not for a range in the middle."
      ;;--------------------------------------------------------------
      (del-range-1 from to #t #f))

    (define (del-range-1 from to prepare ret-string)
      ;; GNU Emacs's `del_range_1` (`insdel.c`), the C's four steps in the
      ;; C's order.
      ;;
      ;; Note the re-derivation of TO after the preparation: the C takes
      ;; `&from` so that `verify_interval_modification` can move it, and
      ;; then restores the *length* against the buffer's new end -
      ;; `to = min (ZV, from + range_length)`. Nothing here moves it, so
      ;; this is the identity today, but it is the C's line.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (let ((from (max from (buffer-beg buffer)))
              (to (min to (buffer-z buffer))))
          (if (<= to from)
              #f
              (begin
                (if prepare
                    (let ((range-length (- to from)))
                      (set! from (prepare-to-modify-buffer from to))
                      (set! to (min (buffer-z buffer) (+ from range-length)))))
                (let ((deletion (del-range-2 from to ret-string)))
                  (signal-after-change from (- to from) 0)
                  deletion))))))

    (define (del-range-2 from to ret-string)
      ;; GNU Emacs's `del_range_2` (`insdel.c`), the deletion itself.
      ;;
      ;; The C's order, and the reason for each step being where it is:
      ;;
      ;;   1. the gap is moved to the deletion, so the characters are
      ;;      contiguous - `buffer-text` does that inside its own delete;
      ;;   2. the text is captured *before* it goes, because `record_delete`
      ;;      needs it and `ret_string` may want it;
      ;;   3. `record_delete` - undo.c's, through the seam - which is also
      ;;      where `record_first_change` runs, so the mark of the last
      ;;      save is still under this entry;
      ;;   4. the markers, because a marker inside the deleted text is
      ;;      left at its start;
      ;;   5. `modiff_incr`, and `CHARS_MODIFF = MODIFF` - which our
      ;;      `%text-editor-incr-modiff!` does itself for a character
      ;;      change;
      ;;   6. point, only if it was inside or after what went: "Relocate
      ;;      point as if it were a marker";
      ;;   7. the intervals;
      ;;   8. the store and the buffer's end.
      ;;
      ;; **The text is captured here and not by the store**, which is why
      ;; `buffer-text-delete!` cannot be the whole of this: the C has to
      ;; hand the string to undo before the characters are gone.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (text (text-editor-text buffer))
             (nchars-del (- to from))
             ;; the C's `make_buffer_string_both (from, from_byte, to,
             ;; to_byte, 1)' - **`editfns.c:1585`**, not insdel.c's - is
             ;; a read of the store without the byte half
             ;; the C's `! EQ (BVAR (current_buffer, undo_list), Qt)' -
             ;; the field itself, since `text-editor-undo-recording?' is
             ;; the engine's and the engine is above this library
             (deletion (if (or ret-string (text-editor-undo-list buffer))
                           (buffer-text-substring (text-editor-text buffer)
                                                  from to)
                           #f)))
        (record-delete from deletion)
        (adjust-markers-for-delete from to)
        (%text-editor-incr-modiff! buffer nchars-del)
        (let ((pt (buffer-pt buffer)))
          (when (< from pt)
            (adjust-point (- from (min pt to)))))
        (let ((offset (*text-property-offset-function*)))
          (when offset (offset buffer from (- nchars-del))))
        (buffer-text-delete! text from to)
        ;; The C also shrinks `BEG_UNCHANGED` here, after the gap has
        ;; moved (`insdel.c`, `if (GPT - BEG < BEG_UNCHANGED) ...`).
        ;; `invalidate_buffer_caches` has already done it for this same
        ;; range, so repeating it would be the same write twice.
        deletion))

    (define (replace-range from to new run-mod-hooks inherit adjust-match-data)
      ;; GNU Emacs's `replace_range` (`insdel.c:1463`): "Replace the text
      ;; from character positions FROM to TO with the text in NEW."
      ;;
      ;; **Why this is not `del-range` followed by an insert**, which is
      ;; what the two callers here used to spell: the C does both against
      ;; one gap, so the markers see **one** change
      ;; (`adjust_markers_for_replace` moves a marker by the *difference*
      ;; in length rather than twice, once each way), the intervals are
      ;; offset once, point is relocated once, and `signal_after_change`
      ;; is called **once** - with the number of characters inserted as
      ;; its third argument, where the delete-then-insert pair gives two
      ;; calls, the second with 0. A font-lock listener sees that.
      ;;
      ;; `run-mod-hooks` is the C's PREPARE and its `signal_after_change`:
      ;; callers that replace one character at a time in a loop turn it
      ;; off and do both around the whole region once (`replace_range_2`,
      ;; called from `casify_region`). `inherit` is passed on to
      ;; `graft_intervals_into_buffer`; `adjust-match-data` is
      ;; `update_search_regs`, which `replace-match` asks for.
      ;;
      ;; The C's NEW may also be a buffer or a `(buffer beg end)` vector -
      ;; `replace-region-contents`' way of saying "this stretch of that
      ;; buffer". Only the string case is carried, because it is the only
      ;; one anything here asks for.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (text (text-editor-text buffer))
             (inschars (string-length new)))
        (if run-mod-hooks
            (let ((range-length (- to from)))
              (set! from (prepare-to-modify-buffer from to))
              (set! to (+ from range-length))))
        ;; "Make args be valid."
        (set! from (max from (buffer-beg buffer)))
        (set! to (min to (buffer-z buffer)))
        (let ((nchars-del (- to from)))
          (if (and (<= nchars-del 0) (= inschars 0))
              #f
              ;; The C's `!EQ (BUF_UNDO_LIST (current_buffer), Qt)' - the
              ;; text is captured only when undo is recording. **Written
              ;; as a truth test of the list until 2026-10-14**, which
              ;; worked while the disabled sentinel was `#f' and reads
              ;; backwards now that it is Emacs's `t' (`#t' is true).
              (let ((deletion (if (text-editor-undo-recording? buffer)
                                  (buffer-text-substring text from to)
                                  #f)))
                (buffer-text-delete! text from to)
                (buffer-text-insert! text from new)
                ;; "Record the insertion first, so that when we undo, the
                ;; deletion will be undone first. Thus, undo will insert
                ;; before deleting, and thus will keep the markers before
                ;; and after this text separate." - the C's comment, and
                ;; the reason the insertion is recorded at TO and not FROM.
                (when deletion
                  (record-insert (+ from nchars-del) inschars)
                  (record-delete from deletion))
                ;; ^ the C's `record_insert (from + nchars_del, inschars)`
                ;; - a position and a *length*.
                (adjust-markers-for-replace from nchars-del inschars)
                (let ((offset (*text-property-offset-function*)))
                  (when offset (offset buffer from (- inschars nchars-del))))
                (let ((graft (*graft-intervals-function*)))
                  (when graft (graft new from inschars buffer inherit)))
                ;; "Relocate point as if it were a marker." The C's
                ;; expression has PT on both sides - it is a *delta* the
                ;; `adjust_point` below adds - which is why it reads as a
                ;; position: inside the range it works out to `from +
                ;; inschars`, `to` exactly gives the same, and past TO it
                ;; gives the difference in length.
                (let ((pt (buffer-pt buffer)))
                  (when (or (< from pt) (= pt to))
                    (adjust-point (+ from inschars (- (min pt to))))))
                (%text-editor-incr-modiff! buffer (+ nchars-del inschars))
                (when adjust-match-data
                  ((*update-search-regs-function*) from to (+ from inschars)))
                (when run-mod-hooks
                  (signal-after-change from nchars-del inschars))
                #f)))))

    (define (modify-text start end)
      ;; GNU Emacs's `modify_text` (`insdel.c:2084`): "Modify text in
      ;; current buffer from character positions START to END. This checks
      ;; the read-only properties of the region, calls the necessary
      ;; modification hooks, and warns the next redisplay that it should
      ;; pay attention to that area."
      ;;
      ;; **This is the entry for a change that no insert/delete primitive
      ;; makes** - `casify_region`'s in-place case conversions,
      ;; `subst-char-in-region`, `transpose-regions`. Those write into the
      ;; store directly, so nothing else would raise the modification
      ;; counter or leave the `(t . TOKEN)` mark that says where the file
      ;; was last saved, and the C does both here, over the whole region,
      ;; once.
      ;;
      ;; It is **not** `prepare_to_modify_buffer`, which is its first
      ;; line: an insertion calls that and then raises the counter itself
      ;; (`insert_1_both`). Keeping the two apart is what stops a change
      ;; raising the counter twice.
      ;;
      ;; **Not carried**: `BUF_COMPUTE_UNCHANGED` (this tree keeps
      ;; `beg_unchanged` but not its sibling `end_unchanged`, whose only
      ;; readers are a redisplay that recomputes - and
      ;; `invalidate-buffer-caches` has already shrunk `beg_unchanged` for
      ;; this same range) and `bset_point_before_scroll`, which is the
      ;; redisplay's own bookkeeping.
      ;;--------------------------------------------------------------
      (prepare-to-modify-buffer start end)
      (record-first-change)
      (let ((text (text-editor-text (current-buffer))))
        (%text-editor-incr-modiff! (current-buffer) (- end start))
        ;; The C's `CHARS_MODIFF = MODIFF` is unconditional where
        ;; `%text-editor-incr-modiff!` writes it only for a non-zero
        ;; length; an empty region is the one case they part, and no
        ;; caller here passes one.
        (when (= start end)
          (set!buffer-text-chars-modiff text (buffer-text-modiff text))))
      #f)

    (define (replace-range-2 from to ins inschars markers)
      ;; GNU Emacs's `replace_range_2` (`insdel.c:1714`): replace the text
      ;; from character positions FROM to TO with the text in INS.
      ;;
      ;; **Why it is not `replace-range`**: it is the *loop's* version,
      ;; called once per character by `do_casify_multibyte_region` - "Note
      ;; that this does not yet handle markers quite right ... Because
      ;; this function is called in a loop, one character at a time. The
      ;; caller of 'replace_range_2' calls these hooks for the entire
      ;; region once. Apart from signal_after_change, any caller of this
      ;; function should also call treesit_record_change." So it does
      ;; **no** `prepare_to_modify_buffer`, **no** `record_insert` /
      ;; `record_delete` and **no** `signal_after_change`; the caller,
      ;; `casify_region`, does all three around the whole region.
      ;;
      ;; The C's MARKERS argument picks between relocating the markers and
      ;; only fixing their *byte* positions. There are no byte positions
      ;; here, so MARKERS false is nothing to do and true is
      ;; `adjust_markers_for_replace`. The C also skips the relocation
      ;; entirely when one character became one character, guarding that
      ;; with `nbytes_del == insbytes` beside the two counts - and with no
      ;; byte positions that clause is the same test, so one character in
      ;; and one character out is the guard.
      ;;
      ;; **Not carried**: `check_markers` (an `ENABLE_CHECKING`-only walk),
      ;; the byte lengths and anchors, `BUF_COMPUTE_UNCHANGED`, and
      ;; `treesit_record_change`, which the C's own comment says is the
      ;; caller's.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (text (text-editor-text buffer))
             (nchars-del (- to from)))
        (if (and (<= nchars-del 0) (= inschars 0))
            #f
            (begin
              (buffer-text-delete! text from to)
              (buffer-text-insert! text from ins)
              ;; "Adjust markers for the deletion and the insertion."
              (unless (and (= nchars-del 1) (= inschars 1))
                (when markers
                  (adjust-markers-for-replace from nchars-del inschars)))
              (let ((offset (*text-property-offset-function*)))
                (when offset (offset buffer from (- inschars nchars-del))))
              ;; "Relocate point as if it were a marker."
              (let ((pt (buffer-pt buffer)))
                (when (and (< from pt) (not (= nchars-del inschars)))
                  (if (< pt to)
                      ;; "PT was within the deleted text. Move it to FROM."
                      (adjust-point (- from pt))
                      (adjust-point (- inschars nchars-del)))))
              (%text-editor-incr-modiff! buffer (+ nchars-del inschars))
              #f))))

    ;;----------------------------------------------------------------
    ;; The seams, installed by the libraries that own the functions
    ;;------------------------------------------------------------------

    (define *graft-intervals-function*
      ;; GNU Emacs's `graft_intervals_into_buffer` (`intervals.c:1529`),
      ;; which `replace_range` calls once with the new text's own tree -
      ;; `(graft_intervals_into_buffer (string_intervals (new)), from,
      ;; inschars, current_buffer, inherit)`. In Emacs's own build order
      ;; `intervals.c` is *below* `insdel.c`; here the interval library is
      ;; above it, so the call arrives through a seam - the same reason
      ;; `*text-property-offset-function*` below is one. The argument is
      ;; the new *text*, not its tree, so the library that owns the tree
      ;; reads it: `(string-intervals string)` is intervals.c's too. A
      ;; text that is a code-point list rather than a string brings no
      ;; intervals - there is nowhere on it to hang one - and the
      ;; installer reads that as the C's null tree, which is the branch
      ;; that *clears* the properties when INHERIT is false.
      ;;
      ;; Both callers go through it now: `replace_range` once with the
      ;; replacement's own tree, and `insert_from_string_1` once with the
      ;; inserted string's - which is where the C has it, between
      ;; `offset_intervals` and `adjust_point`.
      (make-parameter #f))

    (define *adjust-suspend-auto-hscroll-function*
      ;; GNU Emacs's `adjust_suspend_auto_hscroll` (`insdel.c:226`): "If
      ;; the selected window's old pointm is adjacent or covered by the
      ;; region from FROM to TO, unsuspend auto hscroll in that window."
      ;; It reads the *selected window* - and the window is `frame.scm`'s,
      ;; which sits far above this library - so it is a seam. The default
      ;; answers nothing, which is what the C's `if (WINDOWP
      ;; (selected_window))` does when there is no window to ask.
      (make-parameter (lambda (from to) #f)))

    (define *update-search-regs-function*
      ;; GNU Emacs's `update_search_regs` (`search.c:3113`), which
      ;; `replace_range` calls only when `adjust_match_data` is true -
      ;; `replace-match` is the caller that asks for it, so that a match
      ;; still names the same text after the replacement. `search.scm` is
      ;; above this library and installs it.
      (make-parameter (lambda (from to new-to) #f)))

    (define *text-property-offset-function*
      ;; GNU Emacs's `offset_intervals` (`intervals.c`), which shifts the
      ;; text-property tree when text is inserted before it or removed
      ;; from it. It is `intervals.c`'s and that library is above this
      ;; one, so the call arrives through a seam - the same seam the
      ;; engine used to declare, moved down here because this is where the
      ;; shifting now happens.
      (make-parameter #f))

    ;; `Ferase_buffer` (`buffer.c:2472`) empties the current buffer by
    ;; calling `del_range (BEGV, ZV)` - which is `del-range` here - so the
    ;; seam `buffer.scm` declares is installed where the function is, the
    ;; house idiom. **`engine.scm` used to install it**, being the one
    ;; library that held both ends; with the engine's last importers
    ;; repointed at their real homes (2026-10-13) nothing loaded it any
    ;; more, and `erase-buffer` silently emptied nothing.
    (*del-range-function* del-range)

    ))
