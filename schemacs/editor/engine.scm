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
    ;; `(scheme case-lambda)` stood here for `text-editor-set-cursor`'s
    ;; two-argument form, which is gone (2026-10-12) - nothing in this
    ;; library is a `case-lambda` any more.
    ;; `(only (scheme char) char-downcase)` stood here for the
    ;; case-folding of the literal search, which left with it for
    ;; `search.scm` on 2026-10-12.
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
    ;; `make-buffer-string` was imported here for
    ;; `text-editor-to-string`, which is deleted; nothing in this library
    ;; calls it now. (`intervals.scm` still owns it - see the note on its
    ;; definition there.)
    (only (schemacs editor buffer-text)
          ;; `buffer-text-base` and `buffer-text-z` were imported for
          ;; `text-editor-to-code-points`, which is `buffer-text.scm`'s
          ;; now - the walk is there and it uses its own accessors.
          buffer-text-ref
          buffer-text-insert! buffer-text-insert-code-points!
          buffer-text-delete!
          buffer-text-substring
          buffer-text-beg-unchanged set!buffer-text-beg-unchanged)
    ;; **`(only (schemacs editor region-cache) ...)` stood here** for the
    ;; line-break cache `find_newline` keeps - a stretch already searched
    ;; and found free of line breaks is skipped whole rather than scanned
    ;; again, which is what makes a buffer with very long lines
    ;; affordable. The scans are `search.scm`'s now and took the import
    ;; with them.
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

   ;; **`text-editor-to-string` is deleted** (2026-10-13). It had no
   ;; Emacs function to be - see the note where it stood - and its 85
   ;; callers write the composition out now.
   ;; **`text-editor-to-code-points` has left for `buffer-text.scm`**
   ;; (2026-10-13), as `buffer-text-to-code-points`, taking the
   ;; buffer-text rather than the buffer. The walk was over the class's
   ;; own store and there was nothing else in the function; the one
   ;; caller - `files.scm`'s save path - names the text it means.
   text-editor-insert
   text-editor-delete-from-cursor
   ;; **`make-buffer-string` has left for `intervals.scm`** (2026-10-13).
   ;; It is `editfns.c:1561`'s - the docstring here said `insdel.c`, the
   ;; wrong file - and the DAG forces it below `search.scm`: search.scm
   ;; calls it twelve times and cannot import `editfns.scm`. See the
   ;; note on its definition there.
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

   ;; **`text-editor-mark` and `set!text-editor-mark` have left too**
   ;; (2026-10-12), and neither had an Emacs function to move to: they
   ;; are the C's own spelling of a `BVAR` read and write, and that is
   ;; what their callers say now - `(marker-position (mark-marker))` for
   ;; the current buffer (`mark-marker` being `editfns.c:265`'s, in that
   ;; library), and `(marker-position (%mark-marker BUF))` for a buffer
   ;; named outright, which is redisplay's `BVAR (b, mark)`. The write
   ;; is `(set-marker (mark-marker) POS (current-buffer))`, which is
   ;; `set_mark`.
   ;;
   ;; The literal search that stood here is `search.scm`'s now:
   ;; `text-editor-search-forward`, `text-editor-search-backward` and
   ;; `string-search-forward` are `search.c`'s, and both consumers -
   ;; `search.scm` and `isearch.scm` - import that library.

   ;; The buffer's identity: its name and the file it visits
   text-editor-buffer-name  set!text-editor-buffer-name
   text-editor-file-name    set!text-editor-file-name

   ;; The buffer's mark. The markers themselves are `marker.scm`'s now -
   ;; `MARKERP`, `marker-position`, `set-marker` and the rest come from
   ;; there, where marker.c's functions live.
   ;;
   ;; **`mark-marker` has left for `editfns.scm`** (2026-10-12). It is
   ;; `editfns.c:265`'s - not `buffer.c`'s, as the note that stood here
   ;; said - and the C's takes no buffer at all: it is `BVAR
   ;; (current_buffer, mark)`. The ED argument the version here had was
   ;; an invention, and every caller passed the current buffer.

   ;; Getting and setting the cursor index. Every *position* the engine
   ;; answers is one-based, as Emacs's are: `point-min' is 1 and
   ;; `point-max' is one past the last character. Line numbers count
   ;; from 1 (`line-number-at-pos'); columns from 0 (`current-column').

   buffer-beg
   buffer-z
   fetch-char
   text-editor-set-cursor
   text-editor-move-cursor
   buffer-pt
   ;; The scans the line arithmetic is built on - GNU Emacs's
   ;; `find_newline' (`search.c:675'), `scan_newline_from_point'
   ;; (:986) and `find_before_next_newline' (`search.c':997). The two
   ;; ends that are `editfns.c`'s, `bol' (`:665') and `eol' (`:723'), and
   ;; the arithmetic they carry - `line-beginning-position',
   ;; `line-end-position', `line-number-at-pos', `current-column' - have
   ;; moved up to `editfns.scm'; `count_lines' (`xdisp.c:29892') is
   ;; re-exported from `fns.scm', where it lives.
   ;;
   ;; **`find-newline`, `scan-newline-from-point` and
   ;; `find-before-next-newline` have left for `search.scm`** (their own
   ;; file, `search.c`) now that nothing here or below reads a line scan.
   count-lines
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


    ;; **The marker adjusters are `insdel.scm`'s now.** They are
    ;; `insdel.c`'s - `adjust_markers_for_insert` and
    ;; `adjust_markers_for_delete` - and that library exists, so there is
    ;; one copy of each rather than two. They act on the current buffer,
    ;; as the C's do, which is why the call sites below say what buffer
    ;; they mean by making it current.

    ;; **`text-editor-note-property-change!' has left, and it never had
    ;; the right name.** It was this tree's spelling of `textprop.c`'s
    ;; `modify_text_properties`, and it was a thin one: it invalidated the
    ;; region caches - which the C does *not* do for a property write,
    ;; the characters not having changed - and skipped both
    ;; `prepare_to_modify_buffer_1` and `record_first_change`. It is in
    ;; `(schemacs editor textprop)' now, under its own name and with its
    ;; own body.

    ;;----------------------------------------------------------------
    ;; Searching: **moved to `(schemacs editor search)` on 2026-10-12.**
    ;;
    ;; The literal search - `string-search-forward` and its case-folding
    ;; helpers, and the two buffer walks built on it - is `search.c`'s
    ;; (`simple_search`, which `search_buffer` calls for every kind of
    ;; search it makes). It lived here while this library was the only
    ;; place both `search.scm` and `isearch.scm` could reach, and both
    ;; now import `(schemacs editor search)` instead.
    ;;------------------------------------------------------------------


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

    ;; **`text-editor-to-string` stood here and is deleted**
    ;; (2026-10-13). It had no Emacs function to be: `buffer-string` is
    ;; `make_buffer_string_both (BEGV, ..., ZV, ..., 1)`
    ;; (`editfns.c:1707') and copies the interval tree, and this passed
    ;; no PROPS - so it was `buffer-substring-no-properties` over the
    ;; whole buffer, which is a *composition* and not a DEFUN, which is
    ;; why there was nowhere for it to move to. Its 85 callers write that
    ;; composition out now, as Emacs's callers do.
    ;;
    ;; The other half of its docstring is worth keeping, because it is
    ;; about the text and not about the function: it was the *raw* text,
    ;; with `\n' for every line break and no coding-system translation,
    ;; because that is what a buffer holds in Emacs. The buffer's
    ;; line-break convention is applied once, by whoever writes the
    ;; buffer out - `(schemacs editor files)'s `encode-line-breaks',
    ;; which mirrors `coding.c'. It used to route through
    ;; `text-dump-port', which applies the line break, and `save-buffer'
    ;; then applied it a second time, so a CRLF file was written as
    ;; `\r\r\n'.

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
    ;; Newlines: **the scans moved to `(schemacs editor search)` on
    ;; 2026-10-12.**
    ;;
    ;; `find_newline`, `scan_newline_from_point` and
    ;; `find_before_next_newline` are `search.c`'s, and this library held
    ;; them only because the line arithmetic above used to read them.
    ;; That arithmetic is `editfns.scm`'s now and so are its readers, so
    ;; nothing here or below needs a line scan any more - which is what
    ;; finally lets them go to their own file. `editfns.scm` imports them
    ;; from there.
    ;;------------------------------------------------------------------


    ;; **`count-lines' has left, for `(schemacs editor fns)'.** It is
    ;; `xdisp.c:29892' and it wants to be low, because `fns.c''s
    ;; `line-number-at-pos' is its only real caller; this library is not
    ;; low enough for that, having been reached *from* `xdisp.scm' all
    ;; along. The name is still exported below, imported from there, so
    ;; that this library's own readers - and its tests - do not move with
    ;; it.

    ;;----------------------------------------------------------------
    ;; Lines, by scanning
    ;;
    ;; **`%line-start`, `%line-end` and `%text-editor-position` are
    ;; gone**, with the two-argument `text-editor-set-cursor` below that
    ;; was their only caller. That form - "line N, column C" - had no
    ;; Emacs counterpart; it was an invented cursor, and the two places
    ;; that used it (`find-file-noselect` going to `point-min`, and
    ;; `goto-line`) are now written as what Emacs actually runs. See the
    ;; two call sites for the reasoning at each.
    ;;
    ;; With them went this library's last reader of `find-newline`, which
    ;; is what leaves the scans free to move to `(schemacs editor
    ;; search)` - their own file.

    ;; **`text-editor-get-start-of-line', `text-editor-get-end-of-line',
    ;; `text-editor-cursor-line' and `text-editor-cursor-column' have all
    ;; left, for `(schemacs editor editfns)'.**
    ;;
    ;; They are the facade spellings of `editfns.c`'s
    ;; `line-beginning-position' (`:700'), `line-end-position' (`:736'),
    ;; `fns.c`'s `line-number-at-pos' (`:6688') and `indent.c`'s
    ;; `current-column' (`:298') - all arithmetic, all above the scans -
    ;; and they moved with `bol' and `eol' for the reason given there.
    ;; What is left here is the scan side they were built on.

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

    (define (text-editor-set-cursor ed index)
      ;; Put the cursor at INDEX, a position - one-based as every position
      ;; here is - clamped to the buffer. Answers nothing.
      ;;
      ;; **This was a `case-lambda` with a second form - `(ed line col)` -
      ;; and that form is gone.** It had no Emacs counterpart: Emacs
      ;; addresses text by *character position*, and a line-and-column
      ;; cursor is `goto-line` followed by `move-to-column`, two
      ;; functions each with its own definition. The two places that used
      ;; it are now written as what Emacs runs - `find-file-noselect`
      ;; going to `point-min` (`files.scm`) and `goto-line`'s
      ;; `(goto-char (point-min)) (forward-line (1- n))`
      ;; (`minibuffer.scm`) - which is what removed this library's last
      ;; dependency on the line scans.
      ;;--------------------------------------------------------------
      (if (integer? index)
          (set!buffer-pt ed
             (max (buffer-beg ed)
                  (min (buffer-z ed) index)))
          (error "text editor index must be set with an integer" index)))

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
