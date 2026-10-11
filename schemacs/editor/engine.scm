(define-library (schemacs editor engine)
  ;; This library mirrors GNU Emacs's `buffer.c' + `insdel.c' +
  ;; `marker.c' + `search.c': the buffer and its text (one `buffer-text`,
  ;; which is `struct buffer_text`), inserting into it and deleting from
  ;; it, the markers that follow edits, and searching over it.
  ;;
  ;; It is four Emacs files in one library, which the rule in
  ;; LAYOUT-PLAN.txt does not ask for - the rule is one library per
  ;; mirrored file. It was written before the rule, and this note used to
  ;; promise a split "when markers are next worked on".
  ;;
  ;; **That split is not available, and the reason is Emacs's own data
  ;; layout.** The buffer *record* is the hub:
  ;;
  ;;   * `set_marker` and `copy_marker` write the buffer's `markers`
  ;;     field (`buffer.h`), and `buffer.c`'s overlays are markers - so
  ;;     marker.c and buffer.c call each other;
  ;;   * `adjust_markers_for_insert` (`insdel.c`) walks that same field,
  ;;     so the primitives call marker.c and marker.c's callers call the
  ;;     primitives;
  ;;   * the line scans (`find_newline`, `bol`, `eol`) are read by the
  ;;     line and column arithmetic in this same file - `%line-start`,
  ;;     `%line-end`, `text-editor-cursor-line` - so search.c's scans sit
  ;;     *below* `search.sld`, the file that already mirrors search.c's
  ;;     other half and imports this one;
  ;;   * the undo list is written by the primitives and applied by a
  ;;     command that goes back *through* those primitives.
  ;;
  ;; C may have those files include each other; an R7RS library may not -
  ;; its imports are a directed acyclic graph. So the primitives, the
  ;; markers, the scans and the undo list stay in one library, and this
  ;; header stands for the four files. The same entanglement is why
  ;; `frame.sld` is `frame.c` + `window.c`.
  ;;
  ;; **The record has left, though.** It is `buffer.h`'s `struct buffer`
  ;; and it is `buffer.sld`'s now, which is where `buffer.c` keeps it -
  ;; and this library is built ON that one, so the engine may call the
  ;; buffer's own functions rather than the other way round. It used to
  ;; be the engine's, and the reason it could not move was a cycle: the
  ;; buffer library ran `change-major-mode-hook' through `subr.el`'s
  ;; `run-hooks`, `subr.sld` reaches the engine through `fns.sld` and
  ;; `intervals.sld`, and the engine could not be above a library that
  ;; reached it. That one call is a seam now
  ;; (`*run-hooks-function*`), and the record, its accessors,
  ;; `make_buffer`, `buffer-beg`/`buffer-z` and `inhibit-read-only` moved
  ;; with it. Whatever comes back the other way - `del_range`, the undo
  ;; entry a save records up to, marker.c's constructor - is a seam this
  ;; library installs at the end of its load.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library predates.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme char) char-downcase)  ; for case-folding searches
    (only (scheme write) display) ;;DEBUG
    ;;(only (schemacs lexer) make<source-file-location>)
    ;; The marker chain is held weakly - see the note above
    ;; `MAKE<MARKER>'. There is no Emacs name for the mechanism and no
    ;; wrapper for it any more: this is Guile's own weak table, a key
    ;; held weakly with a constant for its value, which `(schemacs
    ;; weak)' used to spell `new-weak-set'.
    (only (guile)
          make-weak-key-hash-table  hashq-set!  hashq-remove!  hash-for-each
          ;; `make-typed-array' is how a `u32vector' of a given length is
          ;; made - `(scheme base)' has no generic array, and R7RS has no
          ;; `u32vector' constructor at all. `u32vector-set!' takes the value before
          ;; the index, as `array-set!' does.
          make-typed-array  u32vector-set!)
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
    (only (schemacs editor buffer)
          *inhibit-read-only*  current-buffer  with-current-buffer
          allocate-buffer  bufferp  show-text-editor
          text-editor-text
          buffer-pt  set!buffer-pt
          %text-editor-newline-cache  set!%text-editor-newline-cache
          text-editor-text-props  set!text-editor-text-props
          text-editor-undo-list  set!text-editor-undo-list
          text-editor-cache-long-scans  set!text-editor-cache-long-scans
          text-editor-save-token
          text-editor-deactivate-mark  set!text-editor-deactivate-mark!
          %mark-marker
          buffer-markers
          text-editor-buffer-name  set!text-editor-buffer-name
          text-editor-file-name  set!text-editor-file-name
          buffer-beg  buffer-z
          buffer-modified-tick  buffer-chars-modified-tick
          buffer-modified-p  set-buffer-modified-p
          buffer-read-only?  set!buffer-read-only
          %text-editor-incr-modiff!
          ;; the seams this library installs as it loads, at the end of
          ;; the file
          *make-marker-function*  *copy-marker-function*
          *marker-position-function*  *set-marker-function*
          *del-range-function*)
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
   text-editor-deactivate-mark  set!text-editor-deactivate-mark!
   *inhibit-read-only*
   *text-property-offset-function*

   ;; Whether the buffer has changed since it was last saved
   buffer-modified-p  set-buffer-modified-p
   text-editor-save-token

   ;; Whether the buffer refuses to be changed
   buffer-read-only?  set!buffer-read-only

   ;; Searching, and the mark
   text-editor-search-forward  text-editor-search-backward
   string-search-forward
   text-editor-mark  set!text-editor-mark

   ;; The buffer's identity: its name and the file it visits
   text-editor-buffer-name  set!text-editor-buffer-name
   text-editor-file-name    set!text-editor-file-name

   ;; Markers: positions that follow the text
   new-marker  copy-marker  marker-type?
   marker-position  marker-buffer  marker-insertion-type
   set-marker!  set-marker-insertion-type!
   mark-marker
   buffer-markers

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
   ;; `invalidate_buffer_caches' (`insdel.c:2206'). The three writers in
   ;; this file call it themselves; it is exported because anything that
   ;; changes the text by another route has to, and the C's `erase-buffer'
   ;; is the example - `(invalidate_buffer_caches (current_buffer, BEGV,
   ;; ZV))' (buffer.c:2773). `erase-buffer' is the buffer library's now and
   ;; calls back in here through `*del-range-function*', which ends in
   ;; `text-editor-delete-from-cursor', so it is already covered.
   text-editor-invalidate-caches!
   ;; `BEG_UNCHANGED' (`buffer.h:156') and the caches' own "everything is
   ;; current as of now".
   buffer-beg-unchanged  set!buffer-beg-unchanged!
   ;; `buffer-modified-tick' and `buffer-chars-modified-tick' (buffer.c)
   buffer-modified-tick  buffer-chars-modified-tick
   ;; `cache-long-scans' (`buffer.c:5786'), the buffer-local both region
   ;; caches hang on
   text-editor-cache-long-scans  set!text-editor-cache-long-scans
   ;; `modify_text_properties' raises `MODIFF' without touching
   ;; `CHARS_MODIFF' (textprop.c:90); this is that raise
   text-editor-note-property-change!
   )

  (begin

    ;; Cumulative Distribution Function (CDF): since most text editors
    ;; require moving the cursor to a precise index, as though the
    ;; text buffer were an array of characters, and since this editor
    ;; engine buffers variable-length lines and not characters, we
    ;; provide a way to efficiently map arbitrary character indicies
    ;; to line indicies. This is accomplished with a CDF which
    ;; precisely describes how characters are distributed throughout
    ;; the text buffer, that way character lookup by index can be
    ;; performed with a simple binary search in O(log n) time. The CDF
    ;; implementation defined here provides APIs for changing the
    ;; characters and lazily re-computing the distribution whenever
    ;; characters are inserted or removed from somewhere in the middle
    ;; of the text buffer.

    ;; Inserting text


    (define (make-buffer-string ed start end)
      ;; The buffer's text between the positions START and END, as a
      ;; string - GNU Emacs's `buffer-substring' over the whole buffer,
      ;; and the same half-open range (START in, END out). Arguments may
      ;; be given in either order; the empty range returns "".
      ;;--------------------------------------------------------------
      (let ((start (min start end))
            (end (max start end)))
        (buffer-text-substring (text-editor-text ed) start end)))

    ;;----------------------------------------------------------------
    ;; Undo
    ;;
    ;; The buffer's undo list is GNU Emacs's `buffer-undo-list': a list
    ;; of the edits that can be undone, NEWEST ENTRY FIRST. The entry
    ;; formats are Emacs's exactly, and the mnemonic is the reverse of
    ;; the obvious one:
    ;;
    ;;   (BEG . END)   text was INSERTED, and now occupies the
    ;;                 characters BEG up to END. Undoing deletes it.
    ;;
    ;;   (TEXT . POS)  TEXT was DELETED from the buffer. `(abs POS)` is
    ;;                 the position to reinsert it at; POS is positive
    ;;                 when point was at the beginning of the deleted
    ;;                 text, negative when it was at the end, which is
    ;;                 what tells undo where to leave point.
    ;;
    ;;   <integer>     a previous value of point. Undoing moves point
    ;;                 there. (Not recorded yet: this buffer has no
    ;;                 markers, and the sign of a deletion's POS
    ;;                 already puts point where it belongs.)
    ;;
    ;;   ()            a boundary (Emacs's `nil'). The entries between
    ;;                 two boundaries are a "change group", which is
    ;;                 what one undo command undoes.
    ;;
    ;; There is no separate redo list. Undoing is itself an edit: it
    ;; runs the ordinary insert and delete primitives, which push the
    ;; inverse entries onto the front of this same list, and those ARE
    ;; the redo records. mg's `undo.c' does the same thing, and says so
    ;; in its comment: "Only when we undo a deletion, the insertion
    ;; will be recorded just as if it was typed on the keyboard.
    ;; Resulting in the inverse operation being saved in the list."
    ;;
    ;; **What this library does NOT have is `primitive-undo'** - the
    ;; procedure that applies these entries, walking the list and running
    ;; the inverse of each one. That is `simple.el`'s (`simple.el:3650'),
    ;; in the same file as the `undo' command itself, and it is there:
    ;; `undo.c` records the entries and Lisp applies them. It was here,
    ;; which put a `simple.el` function in the engine and gave it a buffer
    ;; argument Emacs's does not have.
    ;;
    ;; Entries are recorded by the two public mutators below, and only
    ;; by them. The internal procedures that shuffle lines when a line
    ;; break is inserted or deleted (the merge helpers, `write-back',
    ;; `load-current-line') re-insert text through
    ;; `text-editor-force-insert-char' or `%text-editor-move-char', not
    ;; through the public API, so they record nothing - which is what we
    ;; want, since they change how the buffer is stored rather than what
    ;; it contains. Those two differ in the `char-count' field and
    ;; nothing else: `text-editor-force-insert-char' counts what it puts
    ;; in, because a character typed really is a new character, and
    ;; `%text-editor-move-char' does not, because a character moved from
    ;; the next line into the line editor is already counted.
    ;;------------------------------------------------------------------

    (define *undo-limit*
      ;; A simplified stand-in for Emacs's `undo-limit': the greatest
      ;; number of entries kept in an undo list. When it is exceeded,
      ;; whole oldest change groups are discarded, never part of a
      ;; group. Emacs's real policy is three-tiered (soft, strong and
      ;; outer limits, measured in bytes) and is not implemented.
      ;;--------------------------------------------------------------
      (make-parameter 5000))

    (define (text-editor-undo-recording? ed)
      ;; Whether edits to ED are being recorded for undo. Emacs calls
      ;; this state `buffer-undo-list' being other than `t'.
      ;;--------------------------------------------------------------
      (list? (text-editor-undo-list ed)))

    (define (text-editor-undo-disable! ed)
      ;; Stop recording undo information for ED (Emacs's
      ;; `buffer-disable-undo', which sets `buffer-undo-list' to `t').
      ;; The list is dropped: there is nothing left to undo.
      ;;--------------------------------------------------------------
      (set!text-editor-undo-list ed #f))

    (define (text-editor-undo-enable! ed)
      ;; Start recording undo information for ED again, discarding any
      ;; undo information already recorded (Emacs's
      ;; `buffer-enable-undo', which sets `buffer-undo-list' to `nil').
      ;;--------------------------------------------------------------
      (set!text-editor-undo-list ed '()))

    (define (text-editor-undo-boundary! ed)
      ;; Place a boundary in ED's undo list (Emacs's `undo-boundary').
      ;; The undo command stops at a boundary, so the entries between
      ;; two boundaries are undone together. A boundary is never
      ;; recorded twice in a row, and never at the very front of an
      ;; empty list, the way mg's `undo_add_boundary' refuses to.
      ;;--------------------------------------------------------------
      (let ((list (text-editor-undo-list ed)))
        (when (and (list? list)
                   (pair? list)
                   (not (null? (car list))))
          (set!text-editor-undo-list ed (cons '() list)))))

    (define (undo-modified-entry? entry)
      ;; Whether ENTRY is the mark of where the buffer was last in sync
      ;; with its file - GNU Emacs's `(t . TIME-FLAG)'.
      ;;--------------------------------------------------------------
      (and (pair? entry) (eq? (car entry) 't)))

    ;;----------------------------------------------------------------
    ;; Markers
    ;;
    ;; A marker is a position in a buffer that follows the text: insert
    ;; or delete anywhere and the marker goes on pointing at the same
    ;; character, because its index is adjusted by the change. It is
    ;; GNU Emacs's marker (marker.c), and it is what a position that
    ;; must not go stale has to be - the mark, a window's point, and
    ;; (later) the bounds of an overlay.
    ;;
    ;; Positions that must NOT move are plain integers, and that is not
    ;; an accident: Emacs's `region-beginning' returns an integer, so
    ;; code that binds it gets a fixed anchor, while the mark and
    ;; window points are markers and do follow the text. The engine
    ;; supplies both kinds; a buffer's own cursor is the integer kind,
    ;; because it is the current position and the insert and delete
    ;; procedures move it themselves.
    ;;
    ;; Each buffer holds its markers in a chain (`buffer-markers')
    ;; that the insert and delete procedures walk. GNU Emacs's chain
    ;; does not keep its markers alive - its collector prunes the chain
    ;; while sweeping, so an unreachable marker is collected and its
    ;; place in the chain goes with it. A Scheme implementation cannot
    ;; hook its collector's sweep, so the chain holds its markers
    ;; weakly instead - `MAKE-WEAK-KEY-HASH-TABLE', whose key is held
    ;; weakly and whose value is the constant `#t' - which comes to the
    ;; same thing: a marker that nothing else refers to is collected,
    ;; and it stops being adjusted.

    (define-record-type <marker-type>
      (make<marker> buffer index insertion-type)
      marker-type?
      (buffer     marker-buffer           set!marker-buffer)
      ;; ^ The <buffer> this marker points into, or false
      ;; when it points nowhere - GNU Emacs's "marker points nowhere",
      ;; which is what a marker made by `MAKE-MARKER' is, and what one
      ;; is left as when its buffer is killed or its position is set to
      ;; false.
      (index      %marker-index           set!%marker-index)
      ;; ^ The character index within that buffer. Only meaningful
      ;; while the marker has one.
      (insertion-type marker-insertion-type set!marker-insertion-type)
      ;; ^ GNU Emacs's marker insertion type: whether the marker
      ;; advances past text inserted exactly at it. False - the default,
      ;; and what Emacs gives a marker made by `MAKE-MARKER' - leaves
      ;; the marker where it is and lets the inserted text follow it;
      ;; true moves the marker past the insertion. Text inserted on
      ;; either side of the marker moves it whichever way the text went,
      ;; whatever the type.
      )

    (define (marker-position marker)
      ;; Where MARKER points, as a character index, or false when it
      ;; points nowhere. GNU Emacs's `marker-position'.
      ;;--------------------------------------------------------------
      (and (marker-buffer marker) (%marker-index marker)))

    (define (new-marker)
      ;; A marker that points nowhere, GNU Emacs's `make-marker'.
      ;;--------------------------------------------------------------
      (make<marker> #f 0 #f))

    (define (copy-marker ed index . insertion-type)
      ;; A new marker at character index INDEX of ED, GNU Emacs's
      ;; `copy-marker'. It is added to ED's chain, so it follows the
      ;; text from here on.
      ;;--------------------------------------------------------------
      (let ((marker (make<marker> ed index
                                (and (pair? insertion-type) (car insertion-type)))))
        (hashq-set! (buffer-markers ed) marker #t)
        marker))

    (define (set-marker! marker position . buffer)
      ;; Point MARKER at POSITION, or nowhere when POSITION is false:
      ;; GNU Emacs's `set-marker'. A marker that points nowhere is in no
      ;; buffer's chain and follows nothing, and one that is set
      ;; nowhere loses its buffer; a marker being given a position it
      ;; has no buffer for needs one, as in Emacs.
      ;;--------------------------------------------------------------
      (let ((ed (cond ((pair? buffer) (car buffer))
                      (else (marker-buffer marker)))))
        (cond
         (position
          (unless ed
            (error "set-marker! needs a buffer for a marker that points nowhere"))
          (set!marker-buffer marker ed)
          (set!%marker-index marker position)
          (hashq-set! (buffer-markers ed) marker #t))
         (else
          (when ed
            (hashq-remove! (buffer-markers ed) marker))
          (set!marker-buffer marker #f)
          (set!%marker-index marker 0)))
        marker))

    (define (set-marker-insertion-type! marker type)
      (set!marker-insertion-type marker (and type #t))
      type)

    (define (for-each-marker ed proc)
      ;; Apply PROC to every marker in ED's chain. A marker that has
      ;; been collected is simply no longer in it.
      ;;--------------------------------------------------------------
      (hash-for-each (lambda (marker _) (proc marker))
                     (buffer-markers ed)))

    (define (adjust-markers-for-insertion! ed position delta)
      ;; Move the markers of ED for DELTA characters inserted at
      ;; POSITION: GNU Emacs's `adjust_markers_for_insert'. A marker
      ;; after the insertion moves with the text that follows it; one
      ;; exactly at POSITION moves only if its insertion type says so
      ;; (see the type's note above).
      ;;--------------------------------------------------------------
      (for-each-marker
       ed
       (lambda (marker)
         (let ((index (%marker-index marker)))
           (when (or (> index position)
                     (and (= index position) (marker-insertion-type marker)))
             (set!%marker-index marker (+ index delta)))))))

    (define (adjust-markers-for-deletion! ed start end)
      ;; Move the markers of ED for the characters in [START, END)
      ;; having been deleted: GNU Emacs's `adjust_markers_for_delete'.
      ;; Markers after the deleted text move back by its length; the
      ;; ones inside it - whose character is gone - are left at its
      ;; start, which is where Emacs leaves them.
      ;;--------------------------------------------------------------
      (for-each-marker
       ed
       (lambda (marker)
         (let ((index (%marker-index marker)))
           (cond
            ((>= index end) (set!%marker-index marker (- index (- end start))))
            ((> index start) (set!%marker-index marker start)))))))

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
      (set-marker! (%mark-marker ed) (and position position) ed))

    (define (text-editor-note-property-change! ed start end)
      ;; A change to the buffer's *text properties* rather than to its
      ;; characters - GNU Emacs's `modify_text_properties'
      ;; (`textprop.c:80'), which wraps every property write. It raises
      ;; `modiff' by one and does **not** touch `chars_modiff', which is
      ;; the whole reason the two counters exist apart: a cache of
      ;; something computed from the characters need not be thrown away
      ;; because a face changed.
      ;;--------------------------------------------------------------
      (text-editor-invalidate-caches! ed start end)
      (%text-editor-incr-modiff! ed 0))

    (define (%text-editor-note-change! ed)
      ;; Note that ED is about to be changed. This goes BEFORE the
      ;; change is recorded, so that the mark of the last save sits
      ;; below the change's own entry in the list and is reached after
      ;; the change has been undone.
      ;;
      ;; A modification also asks for the mark to be deactivated, which
      ;; is what GNU Emacs's `prepare_to_modify_buffer' does with
      ;; `(setq deactivate-mark t)' - `insdel.c''s, where this is.
      ;;--------------------------------------------------------------
      ;;
      ;; The mark is recorded here because this is the C's
      ;; `record_first_change' (`undo.c:210'), which `record_insert' calls
      ;; before the modification counter rises - so the test "have we
      ;; changed since the save?" is still answered by the *old* counter.
      ;; It is not a call to `set-buffer-modified-p': with the counter
      ;; moved, `buffer-modified-p' is true on its own.
      (when (not (buffer-modified-p ed))
        (%undo-record! ed (cons 't (text-editor-save-token ed))))
      (set!text-editor-deactivate-mark! ed #t))

    (define *after-change-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-functions' (`buffer.c'): "List of
    ;; functions to call after a change in the buffer.  Each function
    ;; is called with three arguments: the beginning and end of the text
    ;; that was changed, and the length of the old text." The positions
    ;; are one-based, as every position of the Emacs-named layer is.
    ;; `minibuffer-lazy-highlight-setup' hangs its highlighting on this.

    (define (signal-after-change beg end old-length)
      ;; GNU Emacs's `signal_after_change' (`insdel.c':2381): run
      ;; `after-change-functions' over a change that has just been made.
      ;; The C's `(charpos, lendel, lenins)' are BEG, END and
      ;; OLD-LENGTH here: `(charpos + lenins)' is where the changed text
      ;; now ends, and LENDEL is what was there before it - zero for an
      ;; insertion, which is what makes a hook able to tell an insertion
      ;; from a deletion.
      ;;--------------------------------------------------------------
      (for-each (lambda (f) (f beg end old-length))
                (*after-change-functions*)))

    (define (undo-insertion-entry? entry)
      ;; Whether ENTRY records an insertion, that is, whether it is a
      ;; pair of two integers - Emacs's `(BEG . END)'.
      ;;--------------------------------------------------------------
      (and (pair? entry)
           (integer? (car entry))
           (integer? (cdr entry))))

    (define (undo-deletion-entry? entry)
      ;; Whether ENTRY records a deletion, that is, whether it is a
      ;; pair of a string and an integer - Emacs's `(TEXT . POS)'.
      ;;--------------------------------------------------------------
      (and (pair? entry)
           (string? (car entry))
           (integer? (cdr entry))))

    (define (%undo-record! ed entry)
      ;; Add ENTRY to the front of ED's undo list.
      ;;--------------------------------------------------------------
      (when (text-editor-undo-recording? ed)
        (set!text-editor-undo-list ed (cons entry (text-editor-undo-list ed)))
        (%undo-truncate! ed)))

    (define (%undo-record-insertion! ed beg end)
      ;; Record that the characters BEG up to END were just inserted.
      ;; An insertion that abuts the previous one extends it rather
      ;; than adding an entry, so a run of adjacent insertions is one
      ;; entry - Emacs's `record_insert', and mg's rule that "if the
      ;; newest record is an INSERT whose end exactly abuts the new
      ;; insertion, just grow it".
      ;;--------------------------------------------------------------
      (when (and (text-editor-undo-recording? ed) (< beg end))
        (let ((list (text-editor-undo-list ed)))
          (if (and (pair? list)
                   (undo-insertion-entry? (car list))
                   (= (cdr (car list)) beg))
              (set-cdr! (car list) end)
              (set!text-editor-undo-list ed (cons (cons beg end) list))))
        (%undo-truncate! ed)))

    (define (%undo-record-deletion! ed text pos)
      ;; Record that TEXT was just deleted. POS is positive when point
      ;; was at the beginning of the deleted text and negative when it
      ;; was at the end, which is what `text-editor-undo' needs in
      ;; order to put point back where it was.
      ;;--------------------------------------------------------------
      (when (and (text-editor-undo-recording? ed)
                 (< 0 (string-length text)))
        (%undo-record! ed (cons text pos))))

    (define (%undo-truncate! ed)
      ;; Keep the undo list within `*undo-limit*' by discarding whole
      ;; oldest change groups.
      ;;--------------------------------------------------------------
      (let loop ((list (text-editor-undo-list ed)) (guard 0))
        (when (and (list? list)
                   (< (*undo-limit*) (length list))
                   ;; the guard bounds the work if dropping ever failed
                   ;; to shorten the list
                   (< guard 1000))
          (let ((kept (%undo-drop-oldest-group list)))
            (if (eq? kept list)
                ;; The list is one change group too big to keep, and a
                ;; group cannot be split. Drop it, but keep recording:
                ;; an empty list is Emacs's `nil' (nothing to undo yet),
                ;; not `t' (undo disabled).
                (set!text-editor-undo-list ed '())
                (begin
                  (set!text-editor-undo-list ed kept)
                  (loop kept (+ guard 1))))))))

    (define (%undo-drop-oldest-group list)
      ;; LIST with its oldest change group removed. The list is newest
      ;; first, so the oldest group is the run of entries after the LAST
      ;; boundary; that run, and the boundary that opens it, are what
      ;; goes. Returns LIST unchanged when it holds a single group,
      ;; which cannot be dropped without dropping everything.
      ;;--------------------------------------------------------------
      (let ((len (length list)))
        (let loop ((i 0) (node list) (last-boundary #f))
          (if (or (>= i len) (not (pair? node)))
              (if last-boundary
                  (let take ((k 0) (node list) (acc '()))
                    (if (>= k last-boundary)
                        (reverse acc)
                        (take (+ k 1) (cdr node) (cons (car node) acc))))
                  list)
              (if (null? (car node))
                  (loop (+ i 1) (cdr node) i)   ; remember this boundary
                  (loop (+ i 1) (cdr node) last-boundary))))))

    ;;----------------------------------------------------------------
    ;; Searching
    ;;
    ;; GNU Emacs's `search-forward' and `search-backward' (mg's
    ;; forwsrch/backsrch): a literal search over the buffer's
    ;; characters, in which a line break counts as a single #\newline.
    ;; Both references
    ;; leave point at the far end of the match - past it when searching
    ;; forward, at its start when searching backward - and these
    ;; procedures return that position, so a caller can put its cursor
    ;; where Emacs would have left point.
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

    (define *text-property-offset-function*
      ;; The procedure that shifts a buffer's text-property intervals when
      ;; text is inserted or deleted at a position - GNU Emacs's
      ;; `offset_intervals', which lives in `intervals.c' and is called
      ;; from `insdel.c' on every edit.
      ;;
      ;; It is a parameter because of how the halves are split *here*.
      ;; The engine is `buffer.c' + `insdel.c' + `marker.c' + `search.c'
      ;; and holds the tree's root; the tree and its operations are
      ;; `(schemacs editor intervals)', which reaches that root through
      ;; this engine's accessors - so this engine cannot import it, and
      ;; the call has to come in sideways. In C there is no such problem
      ;; and this seam is what stands in for the direct call. It is #f
      ;; until that library is loaded, which is why the callers check.
      ;;--------------------------------------------------------------
      (make-parameter #f))


    (define (text-editor-insert ed thing)
      ;; Insert THING at the cursor. The insertion is recorded in the
      ;; buffer's undo list as the range of characters it now occupies,
      ;; and marks the buffer modified. Nothing is inserted into a
      ;; read-only buffer; that is an error, as it is in GNU Emacs -
      ;; unless `inhibit-read-only' says otherwise, which is the same
      ;; test the C's `prepare_to_modify_buffer_1' makes.
      ;;--------------------------------------------------------------
      (when (and (buffer-read-only? ed)
                 (not (*inhibit-read-only*)))
        (error "Buffer is read-only"))
      (let ((beg (buffer-pt ed)))
        (%text-editor-insert ed thing)
        (let ((end (buffer-pt ed)))
          ;; Inserting nothing is not a change, so it marks the buffer
          ;; modified only if the cursor actually moved. The mark of the
          ;; last save is recorded first, so that it lies under the
          ;; insertion's own entry.
          (when (< beg end)
            ;; The text is in, so the markers after it move with it.
            ;; Doing it here - once for the whole insertion, from where
            ;; the cursor ended up - covers every way text gets in:
            ;; characters, strings, a whole file, and an insertion
            ;; replayed by undo, which comes back through here.
            (adjust-markers-for-insertion! ed beg (- end beg))
            ;; The intervals move with the text for the same reason the
            ;; markers do, and from the same place: once for the whole
            ;; insertion, so that every way text gets in is covered.
            (let ((offset (*text-property-offset-function*)))
              (when offset (offset ed beg (- end beg))))
            (%text-editor-note-change! ed)
            ;; The modification counter rises once for the whole
            ;; insertion, sized by how much went in - the C's
            ;; `insert_from_string_1' does one
            ;; `modiff_incr (&MODIFF, nchars)' for a string, however many
            ;; characters that is (`insdel.c:1069'), where counting each
            ;; character separately would race the counter away on a
            ;; large insertion. It is here rather than beside the
            ;; character writer because `force-insert-char' is called
            ;; once per character, and the operation is what the C
            ;; counts.
            ;;
            ;; It comes *after* `note-change!', which is where the C
            ;; puts it too: `record_insert' runs before `modiff_incr'
            ;; (`insdel.c:926-928'), and `record_insert' is what asks
            ;; "is this the first change since the save?".
            (%text-editor-incr-modiff! ed (- end beg))
            (%undo-record-insertion! ed beg end)
            ;; and the after-change hooks, once the text is really in.
            ;; BEG and END are positions, one-based like Emacs's, so
            ;; they are what `signal_after_change' is given as they
            ;; stand.
            (signal-after-change beg end 0)))))

    (define (%text-editor-insert ed thing)
      (cond
       ((string? thing)
        (string-for-each
         (lambda (c) (text-editor-force-insert-char ed c))
         thing
         ))
       ((char? thing)
        (text-editor-force-insert-char ed thing)
        )
       ((list? thing)
        ;; **The code-point door, and a file has to come in this way.**
        ;; What a decoder produces is code points, and the one value a
        ;; Scheme string cannot hold is a *byte character* - `#x3FFFE9' is
        ;; above Guile's `#x10FFFF' - so `text-editor-insert' cannot be
        ;; handed the text of a file whose bytes no charset can read.
        ;; Emacs needs no second door: its strings hold its characters,
        ;; so `insert_from_string_1' is one function and the string form
        ;; is the special case here rather than there.
        ;;
        ;; A character is taken as well as an integer: a caller with a
        ;; plain list of characters means the same thing by it.
        (for-each
         (lambda (cp)
           (text-editor-force-insert-code-point
            ed (if (char? cp) (char->integer cp) cp)))
         thing
         ))
       (else (error "editor cannot insert text from" thing))
       ))

    (define (text-editor-force-insert-char ed ch)
      ;; **The one place a character enters the text.** Everything else
      ;; arrives here: typing, a string, a whole file, a line break, and
      ;; an insertion replayed by undo. There used to be two more
      ;; writers - `%text-editor-move-char' and `load-current-line' -
      ;; and they existed only because the text had two levels, a line
      ;; editor over a buffer of lines. It has one level now, so the
      ;; writers are one, and this is it.
      ;;
      ;; A line break is no longer special: it is a character like any
      ;; other, and it goes in the same way. The freeze-and-write-back
      ;; dance it used to trigger went with the line editor.
      ;;--------------------------------------------------------------
      (let ((text  (text-editor-text ed))
            (point (buffer-pt ed))
            )
        (text-editor-invalidate-caches! ed point point)
        (buffer-text-insert! text point (string ch))
        (set!buffer-pt ed (+ 1 point))
        ch
        ))

    (define %one-code-point (make-typed-array 'u32 0 1))
    ;; ^ The scratch a single code point goes through. `array-set!' takes
    ;; the *value before the index*, and this is a module-level value
    ;; rather than a fresh vector per character because this is the
    ;; per-character path of reading a whole file.

    (define (text-editor-force-insert-code-point ed cp)
      ;; `text-editor-force-insert-char' for a *code point*, which is what
      ;; a decoder answers and what the store holds. It exists for the one
      ;; value a character cannot be: a byte character. Emacs has one
      ;; function here - `insert_1_both' - because its characters and its
      ;; store's elements are the same thing.
      ;;--------------------------------------------------------------
      (let ((text  (text-editor-text ed))
            (point (buffer-pt ed))
            )
        (text-editor-invalidate-caches! ed point point)
        (u32vector-set! %one-code-point 0 cp)
        (buffer-text-insert-code-points! text point %one-code-point)
        (set!buffer-pt ed (+ 1 point))
        cp
        ))

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

    (define (text-editor-invalidate-caches! ed start end)
      ;; Tell the buffer's caches that the region START to END is about to
      ;; change - GNU Emacs's `invalidate_buffer_caches' (`insdel.c:2206'),
      ;; which `prepare_to_modify_buffer' calls before every modification.
      ;; The line-break cache is the only one this tree keeps; the C's
      ;; `bidi_paragraph_cache' and `width_run_cache' cache things - bidi
      ;; paragraph starts, and the display widths of a stretch of text -
      ;; that nothing here asks for.
      ;;
      ;; The cache is told in the HEAD/TAIL form - "this many characters
      ;; unchanged at the beginning of the buffer, this many at the end" -
      ;; rather than with positions, because an insertion or a deletion
      ;; moves everything after it and that form reads the same before and
      ;; after the change. For an insertion at POINT the tail is
      ;; `Z - POINT`, which is the same count either side of it.
      ;;--------------------------------------------------------------
      (let ((beg (buffer-beg ed))
            (text (text-editor-text ed)))
        ;; Nothing before the change is known to be unchanged any more -
        ;; the C's `if (GPT - BEG < BEG_UNCHANGED) BEG_UNCHANGED =
        ;; GPT - BEG' (`insdel.c:1608'). The `%l' cache reads this to
        ;; decide whether the line number it remembers is still true.
        (let ((prefix (- start beg)))
          (when (< prefix (buffer-text-beg-unchanged text))
            (set!buffer-text-beg-unchanged text prefix)))
        (let ((cache (%text-editor-newline-cache ed)))
          (when cache
            (invalidate-region-cache cache beg (buffer-z ed)
                                     (- start beg)
                                     (- (buffer-z ed) end))))))

    (define (buffer-beg-unchanged ed)
      ;; GNU Emacs's `BEG_UNCHANGED' (`buffer.h:156'): how many characters
      ;; at the beginning of the buffer are known not to have changed
      ;; since `set!buffer-beg-unchanged!' was last called. The `%l'
      ;; cache is only good while this still reaches past the line it
      ;; remembers - `BASE_LINE_NUMBER_VALID_P' (`xdisp.c:19393').
      ;;--------------------------------------------------------------
      (buffer-text-beg-unchanged (text-editor-text ed)))

    (define (set!buffer-beg-unchanged! ed)
      ;; Say that everything the buffer holds is current as of now, so
      ;; that `buffer-beg-unchanged' counts from here. The C does
      ;; this from `mark_window_display_accurate_1', once per redisplay
      ;; (`xdisp.c:22732'); here the only reader is the `%l' cache, so it
      ;; is done when that cache is written - the same statement, made at
      ;; the one moment it is needed.
      ;;--------------------------------------------------------------
      (set!buffer-text-beg-unchanged
       (text-editor-text ed)
       (- (buffer-z ed) (buffer-beg ed))))

    (define (%text-editor-delete-forward ed n)
      ;; Delete up to N characters after point, clamped at `point-max'.
      ;; GNU Emacs's `Fdelete_char' (`cmds.c:221') with a positive N
      ;; deletes the range `(PT, PT + n)'; where the C signals
      ;; `end-of-buffer' this engine's public delete clamps instead,
      ;; which is its documented behaviour.
      ;;--------------------------------------------------------------
      (let* ((point (buffer-pt ed))
             (avail (- (buffer-z ed) point))
             (n     (min n avail))
             )
        (text-editor-invalidate-caches! ed point (+ point n))
        (buffer-text-delete! (text-editor-text ed) point (+ point n))
        n))

    (define (%text-editor-delete-backward ed n)
      ;; Delete up to N characters before point, clamped at `point-min',
      ;; and leave point at the start of what went.
      ;;--------------------------------------------------------------
      (let* ((point (buffer-pt ed))
             (avail (- point (buffer-beg ed)))
             (n     (min n avail))
             )
        (text-editor-invalidate-caches! ed (- point n) point)
        (buffer-text-delete! (text-editor-text ed) (- point n) point)
        (set!buffer-pt ed (- point n))
        n))

    (define (%del-range from to)
      ;; GNU Emacs's `del_range' (`insdel.c'): "Delete the characters
      ;; between FROM and TO, moving all markers that point into the
      ;; deleted range." This is the buffer library calling back into the
      ;; engine, through `*del-range-function*'.
      ;;
      ;; **Our delete primitive is cursor-relative and this one is not**,
      ;; which is the one difference: `text-editor-delete-from-cursor'
      ;; deletes N characters from point, so the range is made by putting
      ;; point at FROM first. `del_range' leaves point where it was; this
      ;; moves it to FROM. For the one caller - `erase-buffer', which
      ;; deletes the whole buffer, so that point must end at `BEG` either
      ;; way - the two agree. They would not for a range in the middle,
      ;; which is why the difference is written down.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (text-editor-set-cursor ed from)
        (text-editor-delete-from-cursor ed (- to from))))

    (define (text-editor-delete-from-cursor ed n)
      ;; Delete N characters at the text editor cursor. Positive N
      ;; deletes characters after the cursor (forward), negative N
      ;; deletes characters before the cursor. Deletion is clamped to
      ;; the bounds of the buffer. Returns the number of characters
      ;; deleted.
      ;;
      ;; This is GNU Emacs's `delete-char' (`cmds.c:221') over
      ;; `del_range', with its two endpoint errors (`end-of-buffer',
      ;; `beginning-of-buffer') replaced by that clamp.
      ;;
      ;; The deleted text is captured first and recorded in the
      ;; buffer's undo list as `record_delete' (`undo.c:163') records
      ;; it: the text, and the position it went back to - POSITIVE when
      ;; point was at the beginning of it, NEGATIVE when point was at
      ;; the end.
      ;;
      ;; Nothing is deleted from a read-only buffer; that is an error,
      ;; as it is in GNU Emacs - and as with insertion, not when
      ;; `inhibit-read-only' says otherwise.
      ;;--------------------------------------------------------------
      (when (and (not (= n 0))
                 (buffer-read-only? ed)
                 (not (*inhibit-read-only*)))
        (error "Buffer is read-only"))
      (cond
       ((= n 0) 0)
       (else
        (let* ((cursor (buffer-pt ed))
               (target (max (buffer-beg ed)
                            (min (buffer-z ed) (+ cursor n))))
               (text   (make-buffer-string ed cursor target))
               (deleted (cond
                         ((< n 0) (%text-editor-delete-backward ed (- n)))
                         (else (%text-editor-delete-forward ed n)))))
          (when (< 0 deleted)
            ;; The markers in what was deleted are left at its start,
            ;; and the ones after it move back. A backward delete took
            ;; the text before the cursor, so the deleted range began
            ;; DELETED characters before it; a forward delete took the
            ;; text after it, so the range began at it.
            (let ((beg (if (< n 0) (- cursor deleted) cursor)))
              (adjust-markers-for-deletion! ed beg (+ beg deleted))
              (let ((offset (*text-property-offset-function*)))
                (when offset (offset ed beg (- deleted))))
              ;; and the after-change hooks, while BEG is in hand: a
              ;; deletion inserts nothing, so the changed range is empty
              ;; and OLD-LENGTH is what went
              (signal-after-change beg beg deleted))
            (%text-editor-note-change! ed)
            ;; One rise for the whole deletion, sized by how much went,
            ;; and again *after* the first-change mark - the C's
            ;; `record_delete' then `modiff_incr (&MODIFF, nchars_del)'
            ;; (`insdel.c:2030', `:2036').
            (%text-editor-incr-modiff! ed deleted)
            ;; The sign of the recorded position is Emacs's rule in
            ;; `record_delete': `-beg' when point was at the end of the
            ;; deleted text (a backward delete leaves it there), `beg'
            ;; when it was at the beginning (a forward delete). In both
            ;; cases `(abs POS)' is where the text has to go back, and
            ;; the sign is what tells the undo which side of it to leave
            ;; point on.
            (%undo-record-deletion! ed text (if (< n 0) (- deleted cursor) cursor)))
          deleted))))

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

    (define (count-lines ed from to)
      ;; The number of line boundaries between the positions FROM and TO
      ;; - GNU Emacs's `count_lines' (`xdisp.c:29892'), which is
      ;; `display_count_lines (FROM, TO, ZV)'. The C's display version
      ;; also honours `selective-display'; that is not ported.
      ;;
      ;; NOTE: `count_lines' is `xdisp.c''s in Emacs and this is the
      ;; engine, but `line-number-at-pos' - which is what wants it - is
      ;; `fns.c''s and reads the buffer through exactly this scan.
      ;; `(schemacs editor xdisp)' imports the engine, so the name lives
      ;; here and can be re-exported there.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((pos from) (n 0))
          (cond
           ((>= pos to) n)
           ((= (buffer-text-ref text pos) #x0a) (loop (+ pos 1) (+ n 1)))
           (else (loop (+ pos 1) n))))))

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
    ;; `marker.c`'s four (`copy-marker`'s family, and the constructor
    ;; `allocate_buffer` calls), and `insdel.c`'s `del_range` - which is
    ;; what `Ferase_buffer` calls to empty a buffer.
    (*make-marker-function* make<marker>)
    (*copy-marker-function* copy-marker)
    (*marker-position-function* marker-position)
    (*set-marker-function* set-marker!)
    (*del-range-function* %del-range)

    )
  )
