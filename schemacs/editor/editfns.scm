(define-library (schemacs editor editfns)
  ;; This library mirrors GNU Emacs's `editfns.c': the primitives that
  ;; read and write *positions* in the buffer and the text between them -
  ;; `point', `point-min', `point-max', `goto-char', `insert',
  ;; `delete-region', `buffer-substring', `buffer-string', `char-after',
  ;; `bolp', `eolp', `save-excursion' - and the two that give the region
  ;; its edges.
  ;;
  ;; What is here so far is the region, because that is what is needed
  ;; now. The rest are the engine's under its own names for the moment
  ;; (`buffer-pt' is `point', `text-editor-insert' is
  ;; `insert', `make-buffer-string' is `buffer-substring'), because
  ;; the engine is `buffer.c' and `insdel.c' and the position arithmetic
  ;; had to live somewhere; they come here, under Emacs's names, when
  ;; something needs them by those names.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of, and
  ;; REGION-PLAN.txt for what it is part of.

  (import
    (scheme base)
    ;; `string-upcase' is `%format-integer''s - `%X' and `%B' write the
    ;; digits upper case, as the C's sprintf does.
    (scheme char)
    ;; `format', `format-message' and `message' are this library's (they
    ;; are editfns.c's in Emacs 31), so the object printer they use is
    ;; spelled `%printf' here: it is Guile's `format', and it is *not*
    ;; exported - a name collision with Emacs's `format' would make the
    ;; whole library ambiguous.
    (rename (only (ice-9 format) format) (format %printf))
    ;; `princ'/`prin1' of an object, which `%s' and `%S' substitute, are
    ;; `display'/`write' on a string port.
    (only (scheme write) display write)
    ;; `current-buffer' and `set-buffer', which `save-excursion' saves
    ;; and restores beside point.
    (only (guile) caddr cadddr cadr cdddr call-with-output-string
          exact->inexact string-index)
    (only (schemacs editor buffer) bufferp current-buffer set-buffer
          *inhibit-read-only*
          ;; `get-pos-property` asks the overlays whether one would cover
          ;; a character inserted at POSITION.
          overlay-front-advance overlay-get overlay-rear-advance
          overlay-start overlay-end overlays-at
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char
          ;; `SET_PT` (`buffer.h:170`), the write below `goto-char` -
          ;; also the engine's until 2026-10-13, where it was
          ;; `text-editor-set-cursor`.
          set-point buffer-read-only? buffer-beg buffer-z buffer-pt
          ;; `BEGV' and `ZV' - what `narrow-to-region' sets and
          ;; `point-min'/`point-max' answer.
          buffer-begv set!buffer-begv buffer-zv set!buffer-zv
          ;; `BEG`/`Z` themselves, for `widen`, `narrow-to-region`'s
          ;; range check and `buffer-size`
          text-editor-text
          ;; `validate_region` (`buffer.c:2504`), which `delete-region`
          ;; and both `buffer-substring`s open with
          validate-region
          ;; "does not record this change for undo" - the C binds the
          ;; buffer's undo list to `t' (`editfns.c:2352`)
          text-editor-undo-list set!text-editor-undo-list
          ;; the C's `if (SAVE_MODIFF == m - 1) SAVE_MODIFF = m`
          buffer-modified-tick text-editor-save-modiff
          set!text-editor-save-modiff
          ;; `char-equal`'s case folding reads it (`editfns.c:4437`)
          *case-fold-search*)
    (only (schemacs editor buffer-text)
          buffer-text-base buffer-text-z buffer-text-ref buffer-text-set!)
    ;; `narrow-to-region` is a redisplay event (`clip_changed`), which is
    ;; the flag `dispnew.scm` carries.
    (only (schemacs editor dispnew) set-windows-or-buffers-changed!)
    (only (schemacs editor marker)
          build-marker markerp marker-position set-marker
          set-marker-insertion-type marker-buffer)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs editor intervals) make-buffer-string)
    
    ;; The scans `bol', `eol' and the line arithmetic below are built on -
    ;; `find_newline`, `scan_newline_from_point` and
    ;; `find_before_next_newline`. **They are `search.c`'s and this file
    ;; imports them from `search.scm`** (2026-10-12), which is the C's own
    ;; direction: `editfns.c` calls into `search.c`, so the scans sit
    ;; below this library. That is why `search.scm` must not import this
    ;; one, and why `editfns.scm` gave up its `search`-blocking imports.
    (only (schemacs editor search)
          scan-newline-from-point
          find-newline find-before-next-newline)
    ;; `mark-active' and `transient-mark-mode' are `buffer.c''s
    ;; variables, and `mark-even-if-inactive' is `callint.c''s, which is
    ;; where `region_limit' reads them from - the same three the C's
    ;; `region_limit' reads.
    (only (schemacs editor buffer)
          mark-active transient-mark-mode
          ;; `structure buffer''s own `mark' slot, which `mark-marker'
          ;; below hands out as the marker it is (`editfns.c:265').
          %mark-marker)
    (only (schemacs editor textprop) add-text-properties
          get-char-property get-text-property
          next-single-char-property-change previous-single-char-property-change
          text-property-stickiness)
    ;; The insertion and the deletion themselves are `insdel.c`'s, in its
    ;; own library - `insert_1_both` and `del_range` are that file's, the
    ;; same way `Finsert` and `Fdelete_region` below are this one's.
    (only (schemacs editor insdel) del-range del-range-1 insert-from-string
          modify-text signal-after-change)
    ;; `record_change` is what a *replacement* records, and
    ;; `subst-char-in-region` is its one caller here as it is in the C.
    ;; Its two halves are `undo.scm`'s; the function itself is below.
    (only (schemacs editor undo) record-insert record-delete)
    ;; `propertize' and the string paths: `propertize' copies through
    ;; `copy-sequence', and `buffer-substring' is the way text properties
    ;; cross from a buffer to a string. The other direction - a string
    ;; into a buffer - is `insert_from_string_1`'s graft and is no longer
    ;; called from here: it belongs where the C has it, inside the
    ;; insertion, before the after-change hooks run.
    ;; `line-number-at-pos' is `fns.c''s DEFUN (`fns.c:6688') and lives in
    ;; that library now, with the `count_lines' it calls; it is imported
    ;; and re-exported below so that this library's readers do not move.
    (only (schemacs editor fns) copy-sequence line-number-at-pos count-lines)
    ;; `(only (schemacs editor intervals) copy-intervals-to-string)` stood
    ;; here for `buffer-substring`'s hand-copied properties; the copy is
    ;; `make_buffer_string_both`'s body and moved into `engine.scm` with
    ;; the PROPS argument (2026-10-12).
    (only (schemacs editor command)
          *mark-even-if-inactive*
          *point-marker-function* *mark-marker-function*
          *format-message-function* *message-clear-function*
          ;; `narrow-to-region' and `widen' are commands in `editfns.c'
          ;; - their interactive specs are in the DEFUNs - so they are
          ;; `define-command`s here.
          define-command)
    ;; `narrow-map' is `bindings.el`'s and is made here, beside the two
    ;; commands it binds; `goto-line-relative` - its third key - is
    ;; `minibuffer.scm`'s, which adds it to this map.
    (only (schemacs editor keymap)
          make-sparse-keymap define-key *default-keymap*)
    ;; `kbd` is `character.scm`'s (`subr.scm` is above this library).
    (only (schemacs editor character) kbd)
    ;; **This library no longer imports `frame.scm'.**
    ;;
    ;; `message' puts its text in the echo area, which is the frame's -
    ;; Emacs's `message3' reaches the display the same way. That import
    ;; was here, and it pinned the frame *below* this library: every
    ;; library that must read a line position from above (`frame.scm`
    ;; itself, whose `window.c` code walks lines) then could not reach
    ;; one, because the arithmetic it needs is `editfns.c`'s and this is
    ;; where it belongs.
    ;;
    ;; The house seam instead, the arrangement `*current-editor-function*'
    ;; (`buffer.scm'), `*replace-buffer-in-windows-function*' and
    ;; `*adjust-suspend-auto-hscroll-function*' already use: the echo
    ;; area is reached through a parameter declared here and installed by
    ;; `frame.scm' as it loads, so the dependency runs frame -> editfns
    ;; and not both ways.
    )

  (export
bobp
   bolp
   eolp
   char-after
   char-before
   following-char
   preceding-char
   line-beginning-position
   line-end-position
   ;; The internal pair the two above are built on (`editfns.c:665', `:723'),
   ;; exported as the C's are non-static, and the facade spellings of the
   ;; line arithmetic - all moved here from the engine 2026-10-12.
   bol
   eol
   text-editor-get-start-of-line
   text-editor-get-end-of-line
   text-editor-cursor-line
   text-editor-cursor-column
   buffer-substring
point-marker
   mark-marker
   buffer-size
   insert-char
   buffer-string
   buffer-substring-no-properties
   propertize
   delete-and-extract-region
   forward-line
   *inhibit-field-text-motion*
   constrain-to-field field-beginning field-end
   get-pos-property
   delete-region
   eobp
   goto-char
   insert
   insert-and-inherit
   insert-before-markers
   insert-before-markers-and-inherit
   fix-position
   subst-char-in-region
   char-equal
   line-number-at-pos
   point-max
   point-min
   point
   save-excursion
   ;; the restriction, `narrow-to-region` and its friends
   narrow-to-region widen narrow-map save-restriction buffer-narrowed-p
   region-beginning
   region-end
   region-limit
   insert-buffer-substring
   *inhibit-message*
   *message-log-function*
   *message-function*
   *current-message-function*
   *standard-display-table*
   *text-quoting-style*
   default-to-grave-quoting-style
   current-message
   format
   format-message
   message
   message-clear
   text-quoting-style
   )

  (begin

    (define (insert-buffer-substring buffer . rest)
      ;; GNU Emacs's `insert-buffer-substring' (editfns.c): "Insert
      ;; before point the contents of BUFFER." START and END are
      ;; one-based positions of the Emacs-named layer, and END is
      ;; exclusive, as in `buffer-substring'.
      ;;--------------------------------------------------------------
      (let* ((start (if (pair? rest) (car rest) #f))
             (end (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
             (text (make-buffer-string
                    buffer
                    (or start (buffer-beg buffer))
                    (or end (buffer-z buffer)))))
        (insert text)))

    (define (region-limit beginning?)
      ;; GNU Emacs's `region_limit' (`editfns.c'): the start or the end
      ;; of the region, whichever of point and mark that is.
      ;;
      ;; It signals when there is no region to speak of - `mark-inactive'
      ;; ("The mark is not active now") when Transient Mark mode is on
      ;; and the mark is not active, and "The mark is not set now, so
      ;; there is no region" when it has never been set - which is why
      ;; the commands that act on the region ask `use-region-p' first.
      ;; (`mark-inactive' is `data.c''s condition symbol; there are no
      ;; condition symbols here yet, so it is the message alone.)
      ;;
      ;; The C clips the answer to the buffer's narrowing; nothing is
      ;; narrowed here, so there is nothing to clip to.
      ;;--------------------------------------------------------------
      (when (and (transient-mark-mode)
                 (not (*mark-even-if-inactive*))
                 (not (mark-active)))
        (error "The mark is not active now"))
      (let ((m (marker-position (mark-marker))))
        (unless m (error "The mark is not set now, so there is no region"))
        (let ((point (buffer-pt (current-buffer))))
          (if (eq? (< point m) beginning?) point m))))

    (define (delete-region start end)
      ;; GNU Emacs's `delete-region' (`editfns.c:2681'): "Delete the text
      ;; between START and END. This command deletes buffer text without
      ;; modifying the kill ring." It is the command `yank-pop' uses to
      ;; take back what `yank' inserted, and the one `kill-region' uses
      ;; once the text is safely in the ring.
      ;;
      ;; The whole of the C is three lines - `validate_region`, one
      ;; `del_range`, and `return Qnil` - and that is the whole of this
      ;; now. **It used to put the cursor at START and delete from
      ;; there**, because the only deleter was cursor-relative; `del_range`
      ;; leaves point where it was, moving it only when it was inside the
      ;; deleted text, which is not the same thing at all.
      ;;
      ;; `validate_region' (`editfns.c`) puts the two in order and checks
      ;; them against the buffer; `del_range_1` clips them to it, which
      ;; covers the second half - the raising is not ported.
      ;;--------------------------------------------------------------
      (when (> start end)
        (let ((swap start)) (set! start end) (set! end swap)))
      ;; `validate_region` (`buffer.c:2504') sorts the two ends and
      ;; **signals** when either is outside the accessible portion:
      ;; `if (! (BEGV <= beg && end <= ZV)) args_out_of_range_3 (...)`. It
      ;; does not clip: `(delete-region 1 12)' in a buffer narrowed to
      ;; 3..5 is "Args out of range", measured on Emacs 31.1.
      (let-values (((start end) (validate-region start end)))
        (del-range start end))
      #f)

    (define (region-beginning)
      ;; GNU Emacs's `region-beginning' (editfns.c): "the integer value
      ;; of point or mark, whichever is smaller" - one-based, which is
      ;; what the engine answers as well.
      ;;--------------------------------------------------------------
      (region-limit #t))

    (define (region-end)
      ;; GNU Emacs's `region-end' (editfns.c): "the integer value of
      ;; point or mark, whichever is larger" - one-based, as
      ;; `region-beginning' is.
      ;;--------------------------------------------------------------
      (region-limit #f))


    ;; **`line-number-at-pos' has left, for `(schemacs editor fns)'.**
    ;; It is `fns.c''s DEFUN and this library had it under a comment
    ;; citing `editfns.c', which is where it is not. It is imported above
    ;; and still exported below, so this library's readers - and its
    ;; tests - do not move with it. What moved with it is the `count_lines'
    ;; it counts with, which is `xdisp.c''s and now sits beside it.

    ;;----------------------------------------------------------------
    ;; Point, its questions, and its preservation - the `editfns.c'
    ;; primitives under their own names. The engine has had them under
    ;; its own (`buffer-pt' is `point') since before this
    ;; library existed; these are the Emacs spellings the ports of the
    ;; .el files read as, so that a port can read like its source.
    ;;----------------------------------------------------------------

    (define (point)
      ;; GNU Emacs's `point' (editfns.c): the character position of the
      ;; cursor. It is the engine's cursor as it stands: both count
      ;; from one, so nothing stands between them.
      ;;--------------------------------------------------------------
      (buffer-pt (current-buffer)))

    (define (point-min)
      ;; GNU Emacs's `point-min' (editfns.c): "the minimum permissible
      ;; value of point in the current buffer. This is 1, unless
      ;; narrowing ... is in effect." It is `BEGV', which `narrow-to-region'
      ;; sets and `widen' puts back to `BEG'.
      ;;--------------------------------------------------------------
      (buffer-begv (current-buffer)))

    (define (point-max)
      ;; GNU Emacs's `point-max' (editfns.c): one past the last character
      ;; of the buffer - `ZV', which is the end of the *accessible*
      ;; portion. `buffer-size' is the one that answers the whole buffer.
      ;;--------------------------------------------------------------
      (buffer-zv (current-buffer)))

    (define (goto-char position)
      ;; GNU Emacs's `goto-char' (editfns.c): "Set point to POSITION,
      ;; a number or marker." A marker's position is the engine's
      ;; zero-based index; the number is one-based, as every position
      ;; answer of this library is.
      ;;--------------------------------------------------------------
      ;;
      ;; It *returns* the position, which the C's does - "Return
      ;; POSITION" - and which callers depend on: `(goto-char
      ;; (match-end 0))' and `(goto-char (next-single-property-change
      ;; ...))' read the answer, and `dired-move-to-end-of-filename'
      ;; returns its property branch's value outright.
      ;;--------------------------------------------------------------
      (let ((at (cond
                 ((markerp position) (marker-position position))
                 (else position))))
        ;; `clip_to_bounds (BEGV, XFIXNUM (position), ZV)' - the C's
        ;; first statement. A position outside the accessible portion is
        ;; pulled to its edge rather than refused.
        (let ((at (min (max at (point-min)) (point-max))))
          (set-point (current-buffer) at)
          at)))

    (define (general-insert-function inherit before-markers args)
      ;; GNU Emacs's `general_insert_function` (`editfns.c:1298`), the
      ;; body `insert', `insert-and-inherit', `insert-before-markers' and
      ;; `insert-before-markers-and-inherit' share. The C takes the two
      ;; insert functions as arguments because it has two pairs of them;
      ;; there is one string-insert here - see `insert-from-string-1` on
      ;; why - so the INHERIT and BEFORE-MARKERS flags are the whole of
      ;; the parameters, and they reach that one call the way the C's
      ;; choice of function reaches its two.
      ;;
      ;; A character is encoded into a one-character string and inserted,
      ;; which is what the C's `CHAR_STRING` does before calling
      ;; `insert_func`. INHERIT decides whether text that brings no
      ;; properties of its own *keeps* the neighbouring ones or has them
      ;; cleared off it, and it is read inside the graft;
      ;; BEFORE-MARKERS decides whether a marker sitting at the insertion
      ;; point ends up before the new text or after it (`advanced' in
      ;; `adjust_markers_for_insert`).
      ;;--------------------------------------------------------------
      (for-each
       (lambda (arg)
         (cond
          ((string? arg) (insert-from-string arg inherit before-markers))
          ((char? arg)
           (insert-from-string (string arg) inherit before-markers))
          ((integer? arg)
           (insert-from-string (string (integer->char arg)) inherit
                               before-markers))
          (else (error "Wrong type argument" arg))))
       args)
      #f)

    (define (insert . args)
      ;; GNU Emacs's `insert' (`editfns.c:1354`): "Insert the arguments,
      ;; either strings or characters, at point. Point and
      ;; after-insertion markers move forward to end up after the
      ;; inserted text.
      ;;
      ;; If the current buffer is multibyte, unibyte strings are converted
      ;; to multibyte for insertion (see `unibyte-char-to-multibyte').
      ;; If the current buffer is unibyte, multibyte strings are converted
      ;; to unibyte for insertion."
      ;;
      ;; The C's call is `general_insert_function (insert,
      ;; insert_from_string, **0**, ...)' - that false is the whole of
      ;; what makes this `insert' and not `insert-and-inherit'.
      ;;--------------------------------------------------------------
      ;; The graft used to be done here, after `insert-from-string'
      ;; returned and therefore after the after-change hooks had run.
      ;; `insert_from_string_1` does it now, which is where the C has it.
      (general-insert-function #f #f args))

    (define (insert-and-inherit . args)
      ;; GNU Emacs's `insert-and-inherit' (`editfns.c:1377`): "Insert the
      ;; arguments at point, inheriting properties from adjoining text."
      ;; The C's call is `general_insert_function (insert_and_inherit,
      ;; insert_from_string, **1**, ...)'.
      ;;
      ;; What it is for is the case `insert' handles by taking the
      ;; properties *off*: text inserted next to a propertized run keeps
      ;; the run's properties instead of coming in bare.
      ;; `internal_self_insert` is Emacs's caller - a typed character
      ;; inherits, which is why typing at the end of a propertized run
      ;; extends it - and so is `newline'.
      ;;--------------------------------------------------------------
      (general-insert-function #t #f args))

    (define (insert-before-markers . args)
      ;; GNU Emacs's `insert-before-markers' (`editfns.c:1388`): "Insert
      ;; text at point, relocating markers and inheriting properties" -
      ;; except that it does *not* inherit: the C's call is
      ;; `general_insert_function (insert_before_markers,
      ;; insert_from_string_before_markers, 0, ...)'. What it does do is
      ;; move the markers at the insertion point to *after* the new text,
      ;; where plain `insert' leaves them before it.
      ;;--------------------------------------------------------------
      (general-insert-function #f #t args))

    (define (insert-before-markers-and-inherit . args)
      ;; GNU Emacs's `insert-before-markers-and-inherit' (`editfns.c:1422`):
      ;; "Insert text at point, relocating markers and inheriting
      ;; properties. Point and all markers at or after the insertion
      ;; point move forward to end up after the inserted text."
      ;;
      ;; `fill-newline' is its caller in `fill.el' - "Markers that were
      ;; after the whitespace are now at point: insert before them so
      ;; they don't get stuck before the prefix."
      ;;--------------------------------------------------------------
      (general-insert-function #t #t args))

    (define (bobp)
      ;; GNU Emacs's `bobp' (editfns.c): "Return t if point is at the
      ;; beginning of the buffer."
      ;;--------------------------------------------------------------
      (= (point) (point-min)))

    (define (eobp)
      ;; GNU Emacs's `eobp' (editfns.c): "Return t if point is at the
      ;; end of the buffer."
      ;;--------------------------------------------------------------
      (= (point) (point-max)))

    (define (bolp)
      ;; GNU Emacs's `bolp' (editfns.c): "Return t if point is at the
      ;; beginning of a line."
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (or (= (point) (point-min))
            (eqv? (fetch-char ed (- (point) 1))
                  #\newline))))

    (define (eolp)
      ;; GNU Emacs's `eolp' (editfns.c): "Return t if point is at the
      ;; end of a line. `End of a line' includes point being at the end
      ;; of the buffer."
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (= (point) (text-editor-get-end-of-line ed))))

    (define (char-after position)
      ;; GNU Emacs's `char-after' (editfns.c): "Return character in
      ;; current buffer at position POSITION" - nil, this tree's #f,
      ;; when POSITION is past the end. A POSITION of nil means point,
      ;; as Emacs's docstring keeps out of the synopsis.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (pos (if position position (point))))
        (and (<= (point-min) pos) (< pos (point-max))
             (fetch-char ed pos))))

    (define (char-before . rest)
      ;; GNU Emacs's `char-before' (editfns.c:1070): "Return character in
      ;; current buffer preceding position POS. POS is an integer or a
      ;; marker and defaults to point. If POS is out of range, the value
      ;; is nil."
      ;;
      ;; POS is *optional* - the C's DEFUN is `0, 1, 0' - and
      ;; `(char-before)' is how the .el code this tree ports spells it.
      ;; A required POS answered "Wrong number of arguments" instead,
      ;; which `dired-move-to-end-of-filename''s symlink path - the
      ;; C's `(preceding-char)' - ran straight into the day that path
      ;; became reachable.
      ;;
      ;; "If POS is out of range, the value is nil": the C clips through
      ;; `BUF_BEGV' and `BUF_ZV', so POS may be 1 through ZV (= COUNT + 1)
      ;; and no further. `(char-before 100)' on a three-character buffer
      ;; is nil in Emacs and ran off the engine here, the upper bound
      ;; having no test at all.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (position (if (pair? rest) (car rest) #f))
             (pos (if position position (point))))
        (and (<= (+ (point-min) 1) pos)
             (<= pos (point-max))
             (fetch-char ed (- pos 1)))))

    (define (following-char)
      ;; GNU Emacs's `following-char' (editfns.c): "Return the
      ;; character following point, or nil if point is at the end."
      ;;--------------------------------------------------------------
      (char-after (point)))

    (define (preceding-char)
      ;; GNU Emacs's `preceding-char' (editfns.c): "Return the
      ;; character preceding point, or nil if point is at the
      ;; beginning."
      ;;--------------------------------------------------------------
      (char-before (point)))

    ;;----------------------------------------------------------------
    ;; Lines, by scanning: `bol', `eol', and the arithmetic on them
    ;;------------------------------------------------------------------
    ;; **This block moved here from the engine on 2026-10-12.** Every
    ;; name in it is `editfns.c`'s - `bol` (`:665'), `eol` (`:723'),
    ;; `line-beginning-position` (`:700'), `line-end-position` (`:755') -
    ;; or the facade spelling of one, and the engine had them only because
    ;; the scans they read were there too. The scans stay in the engine
    ;; (they are `search.c`'s, and `editfns.c` calls *into* `search.c`,
    ;; so they sit below this file); the arithmetic moved up to the file
    ;; that owns it.
    ;;
    ;; The direction is the point. Moving the scans up instead would have
    ;; put them above their only readers, and this tree's imports are a
    ;; directed acyclic graph.

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

    (define (text-editor-get-start-of-line ed . rest)
      ;; The position of the first character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-beginning-position' (`editfns.c:700'), which is
      ;; `(bol nil)'; with a POSITION the C reaches the same place with
      ;; `save-excursion' around `goto-char', the scan here simply starts
      ;; where it is told to. It does not move point.
      ;;--------------------------------------------------------------
      (if (pair? rest) (%bol-at ed (car rest)) (bol ed #f)))

    (define (text-editor-get-end-of-line ed . rest)
      ;; The position of the last character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-end-position' (`editfns.c:736'), which is `(eol nil)'; the
      ;; POSITION form is the same scan started where it is told to
      ;; rather than at point. At the end of the buffer it is `point-max',
      ;; as the C's is. It does not move point.
      ;;--------------------------------------------------------------
      (if (pair? rest)
          (find-before-next-newline ed (car rest) 1)
          (eol ed #f)))

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
    ;; Fields - `editfns.c`'s `find_field` and the motion it constrains
    ;;----------------------------------------------------------------

    (define *inhibit-field-text-motion* (make-parameter #f))
    ;; ^ GNU Emacs's `inhibit-field-text-motion' (`editfns.c`):
    ;; "Non-nil means text motion commands don't notice fields."
    ;; Nil, so `C-a` and `C-e` stop at a field's edge.

    (define (get-pos-property position prop . args)
      ;; GNU Emacs's `get-pos-property' (`editfns.c:275`): "Return the
      ;; value of POSITION's property PROP ... the property that a char
      ;; would inherit if it were inserted at POSITION."
      ;;
      ;; It is `get-char-property' with the *stickiness* rules applied:
      ;; an overlay answers only if it would cover a character inserted
      ;; here, and a text property answers from the character after
      ;; POSITION, the one before, or neither, by
      ;; `text-property-stickiness`.
      ;;
      ;; **This is the property `find_field` asks about a boundary**:
      ;; the minibuffer prompt is `rear-nonsticky`, so at its end the
      ;; `field` property an insertion would inherit is nil - the prompt
      ;; is the field *before* that position, and the text typed after
      ;; it is another field.
      ;;--------------------------------------------------------------
      (let ((object (if (pair? args) (car args) (current-buffer))))
        ;; "pos-property only makes sense in buffers right now, since
        ;; strings have no overlays and no notion of insertion for which
        ;; stickiness could be obeyed" - so a string is
        ;; `get-text-property` and nothing else, which is the C's early
        ;; return.
        (if (not (bufferp object))
            (get-text-property position prop object)
        (let ((overlay-value
               (and (bufferp object)
                    (let loop ((ovs (overlays-at position #t)))
                      (cond ((null? ovs) #f)
                            ((and (overlay-get (car ovs) prop)
                                  ;; the C's "will not cover a char
                                  ;; inserted at point" test
                                  (let ((start (overlay-start (car ovs)))
                                        (end (overlay-end (car ovs))))
                                    (not (or (> start position)
                                             (< end position)
                                             (and (= start position)
                                                  (overlay-front-advance
                                                   (car ovs)))
                                             (and (= end position)
                                                  (not (overlay-rear-advance
                                                        (car ovs))))))))
                             (overlay-get (car ovs) prop))
                            (else (loop (cdr ovs))))))))
          (if overlay-value
              overlay-value
              (let ((stickiness (text-property-stickiness prop position object)))
                (cond ((> stickiness 0)
                       (get-text-property position prop object))
                      ((and (< stickiness 0)
                            (> position (buffer-beg (current-buffer))))
                       (get-text-property (- position 1) prop object))
                      (else #f))))))))

    (define (find-field pos merge-at-boundary beg-limit end-limit)
      ;; GNU Emacs's `find_field' (`editfns.c:374'): "Find the field
      ;; surrounding POS in *BEG and *END." Answers the two as values.
      ;;
      ;; BEG-LIMIT and END-LIMIT bound the search without changing what
      ;; counts as a boundary, and MERGE-AT-BOUNDARY makes a POS at the
      ;; very start of a field belong to the *previous* one - and makes a
      ;; `boundary'-valued `field' between two fields be skipped, which is
      ;; how comint joins a prompt to what follows it.
      ;;--------------------------------------------------------------
      (let* ((pos (or pos (point)))
             (after-field (get-char-property pos 'field))
             (before-field (if (> pos (point-min))
                               (get-char-property (- pos 1) 'field)
                               ;; "Using nil here would be a more obvious
                               ;; choice, but it would fail when the
                               ;; buffer starts with a non-sticky field."
                               after-field))
             (at-field-start #f)
             (at-field-end #f))
        (unless merge-at-boundary
          (let ((field (get-pos-property pos 'field)))
            (unless (eq? field after-field) (set! at-field-end #t))
            (unless (eq? field before-field) (set! at-field-start #t))
            (when (and (not field) at-field-start at-field-end)
              ;; "If an inserted char would have a nil field while the
              ;; surrounding text is non-nil, we're probably not looking
              ;; at a zero-length field, but instead at a non-nil field
              ;; that's not intended for editing (such as comint's
              ;; prompts)."
              (set! at-field-start #f)
              (set! at-field-end #f))))
        (let ((beg
               (if at-field-start
                   ;; "POS is at the edge of a field, and we should
                   ;; consider it as the beginning of the following field."
                   pos
                   ;; "Find the previous field boundary."
                   (let ((p (if (and merge-at-boundary (eq? before-field 'boundary))
                                (previous-single-char-property-change
                                 pos 'field #f beg-limit)
                                pos)))
                     (let ((q (previous-single-char-property-change
                               p 'field #f beg-limit)))
                       (or q (point-min))))))
              (end
               (if at-field-end
                   pos
                   (let ((p (if (and merge-at-boundary (eq? after-field 'boundary))
                                (next-single-char-property-change
                                 pos 'field #f end-limit)
                                pos)))
                     (or (next-single-char-property-change p 'field #f end-limit)
                         (point-max))))))
          (values beg end))))

    (define (field-beginning . args)
      ;; GNU Emacs's `field-beginning' (`editfns.c`): "Return the
      ;; beginning of the field surrounding POS." ESCAPE-FROM-EDGE makes a
      ;; POS at the start of its field answer the *previous* field's
      ;; beginning; LIMIT caps the answer.
      ;;--------------------------------------------------------------
      (let ((pos (if (pair? args) (car args) #f))
            (escape (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
            (limit (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                       (caddr args)
                       #f)))
        (call-with-values (lambda () (find-field pos escape limit #f))
          (lambda (beg _end) beg))))

    (define (field-end . args)
      ;; GNU Emacs's `field-end' (`editfns.c`): "Return the end of the
      ;; field surrounding POS." The mirror of `field-beginning`.
      ;;--------------------------------------------------------------
      (let ((pos (if (pair? args) (car args) #f))
            (escape (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
            (limit (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                       (caddr args)
                       #f)))
        (call-with-values (lambda () (find-field pos escape #f limit))
          (lambda (_beg end) end))))

    (define (constrain-to-field new-pos old-pos . args)
      ;; GNU Emacs's `constrain-to-field' (`editfns.c:551'): "Return the
      ;; position closest to NEW-POS that is in the same field as
      ;; OLD-POS." NEW-POS nil means "use and set point".
      ;;
      ;; **This is what makes `C-a` a prompt-aware command.** A line
      ;; motion computes a position and hands it here; if that position
      ;; is in another field, it is pulled back to the boundary between
      ;; them. ONLY-IN-LINE (which `line-beginning-position` passes) says
      ;; a constraint that would move to another *line* is no constraint
      ;; at all, so a field edge part way along a line does not stop a
      ;; vertical motion.
      ;;--------------------------------------------------------------
      ;; ESCAPE-FROM-EDGE, ONLY-IN-LINE and INHIBIT-CAPTURE-PROPERTY -
      ;; the first three of the arguments after the two positions
      (let* ((escape (and (pair? args) (car args)))
             (only-in-line (and (pair? args) (pair? (cdr args)) (cadr args)))
             (inhibit-capture (and (pair? args) (pair? (cdr args))
                                   (pair? (cddr args))
                                   (caddr args)))
             (orig-point (and (not new-pos) (point)))
             (new-pos (or new-pos (point)))
             (fwd (> new-pos old-pos))
             (prev-old (- old-pos 1))
             (prev-new (- new-pos 1))
             (fielded?
              (and (not (*inhibit-field-text-motion*))
                   (not (= new-pos old-pos))
                   (or (get-char-property new-pos 'field)
                       (get-char-property old-pos 'field)
                       (and (> new-pos (point-min))
                            (get-char-property prev-new 'field))
                       (and (> old-pos (point-min))
                            (get-char-property prev-old 'field)))
                   (or (not inhibit-capture)
                       (and (not (get-pos-property old-pos inhibit-capture))
                            (or (<= old-pos (point-min))
                                (not (get-char-property old-pos inhibit-capture))
                                (not (get-char-property prev-old
                                                        inhibit-capture))))))))
        (if fielded?
            (let* ((field-bound (if fwd
                                    (field-end old-pos escape new-pos)
                                    (field-beginning old-pos escape new-pos)))
                   (constrain?
                    (and (if (< field-bound new-pos) fwd (not fwd))
                         (or (not only-in-line)
                             ;; the C's ONLY-IN-LINE test: scan from
                             ;; NEW-POS to FIELD-BOUND and ask whether
                             ;; any line boundary was crossed
                             (call-with-values
                                 (lambda ()
                                   (find-newline (current-buffer) new-pos
                                                 (if fwd -1 1) field-bound))
                               (lambda (_pos counted) (= counted 0)))))))
              (when constrain? (set! new-pos field-bound))
              (when (and orig-point (not (= new-pos orig-point)))
                (goto-char new-pos))
              new-pos)
            (begin
              (when (and orig-point (not (= new-pos orig-point)))
                (goto-char new-pos))
              new-pos))))

    (define (line-beginning-position . rest)
      ;; GNU Emacs's `line-beginning-position' (`editfns.c:700'), whose
      ;; whole body is
      ;;
      ;;     ptrdiff_t count, charpos = bol (n, &count);
      ;;     return Fconstrain_to_field (make_fixnum (charpos), ...);
      ;;
      ;; - `bol' being `editfns.c:665', which this tree has as the
      ;; engine's `bol'. **The field constraint is carried now**: with
      ;; the minibuffer's prompt in the buffer (`read_minibuf',
      ;; `minibuf.c:858`) the prompt *is* a field, and without this
      ;; `C-a` in a prompt went to the start of the line, which is the
      ;; start of the prompt - where `C-k` then killed the prompt.
      ;;
      ;; What stood here was `forward-line' and then the line's start. It
      ;; answers the same for the Ns anyone passes and is a *second*
      ;; implementation of the walk `bol' already is - the shape that has
      ;; gone wrong twice in this tree (see `scan_for_column').
      ;;
      ;; "With argument N not nil or 1, move forward N - 1 lines first":
      ;; an absent N is the C's `count = 1', and 0 and negatives move
      ;; *back*, which is `bol''s `count - 1' scan.
      ;; The answer is one-based, as every position answer here is.
      ;;--------------------------------------------------------------
      (constrain-to-field
       (bol (current-buffer) (if (pair? rest) (car rest) #f))
       (point)
       ;; "(count != 0 ? Qt : Qnil)" - and COUNT is `bol`'s, which is
       ;; `n - 1` for a number and 0 for a nil N (`editfns.c:665`), so
       ;; ESCAPE-FROM-EDGE says "the scan crossed a line". **It is not
       ;; "N is non-zero"**: `(beginning-of-line 1)` is the ordinary key
       ;; and passes count 0, which is what makes `C-a` in a prompt stop
       ;; at the end of the prompt - measured on Emacs 31.1,
       ;; `(line-beginning-position)` at position 12 of a buffer whose
       ;; prompt is 1..11 answers 12 and not 1.
       (let ((n (if (pair? rest) (car rest) #f)))
         (and (number? n) (not (= n 1))))
       #t
       #f))

    (define (line-end-position . rest)
      ;; GNU Emacs's `line-end-position' (`editfns.c:755'), whose whole
      ;; body is `(make_fixnum (eol (n)))' - `eol' being `editfns.c:723',
      ;; which this tree has as the engine's `eol' and which is where the
      ;; `count - (count <= 0)' adjustment lives.
      ;;
      ;; It was `forward-line (- n 1)' and then the line's end until
      ;; 2026-10-06, and that is *not* the same answer below N = 1:
      ;; `(line-end-position 0)' at the first line is position 1 in Emacs
      ;; - the backward scan runs off the beginning of the buffer and
      ;; stops there - and was the end of line 1, position 4, here.
      ;; Measured on Emacs 31.1. Nothing could see it while
      ;; `end-of-line' took no argument at all, which is why giving it one
      ;; is what found this.
      ;;
      ;; **Constrained to the field**, which is the C's
      ;; `Fconstrain_to_field (make_fixnum (eol (n)), make_fixnum (PT),
      ;; Qnil, Qt, Qnil)' (`editfns.c:772'): `C-e` in a prompt goes to
      ;; the end of what has been typed, not to the end of the line the
      ;; prompt is on.
      ;;--------------------------------------------------------------
      (constrain-to-field
       (eol (current-buffer) (if (pair? rest) (car rest) #f))
       (point) #f #t #f))

    (define (buffer-substring beg end)
      ;; GNU Emacs's `buffer-substring' (editfns.c:507), whose whole body
      ;; is `make_buffer_string (beg, end, 1)': "Return the contents of
      ;; part of the current buffer, as a string", properties included.
      ;;
      ;; The properties used to be copied here by hand, because
      ;; `make-buffer-string` had no PROPS argument - the C's fourth one,
      ;; which `buffer-substring-no-properties` below passes false. It has
      ;; it now (`engine.scm`), so this is the C's line.
      ;;
      ;; The positions are this layer's and the engine's alike - both
      ;; count from one - so nothing is converted.
      ;;
      ;; **`validate_region`** (`editfns.c:1674`) comes first, so a range
      ;; that reaches outside a narrowing is "Args out of range" -
      ;; measured on Emacs 31.1, in a buffer narrowed to 3..5,
      ;; `(buffer-substring 1 12)` signals and `(buffer-substring 3 5)` is
      ;; the text.
      ;;--------------------------------------------------------------
      (let-values (((beg end) (validate-region beg end)))
        (make-buffer-string (current-buffer) beg end #t)))

    (define (buffer-substring-no-properties beg end)
      ;; GNU Emacs's `buffer-substring-no-properties': "Return the
      ;; characters of part of the current buffer, without text
      ;; properties." Same `validate_region` as `buffer-substring`.
      ;;--------------------------------------------------------------
      (let-values (((beg end) (validate-region beg end)))
        (make-buffer-string (current-buffer) beg end)))

    (define (propertize string . properties)
      ;; GNU Emacs's `propertize' (editfns.c:3296): "Return a copy of
      ;; STRING with text properties added. First argument is the string
      ;; to copy. Remaining arguments form a sequence of PROPERTY VALUE
      ;; pairs for text properties to add to the result."
      ;;
      ;; "Number of args must be odd" - the count includes the string, so
      ;; what must be odd is the *properties*, which are name/value pairs
      ;; and so must be even. The copy is `copy-sequence', so a string
      ;; that already had properties keeps them, and then
      ;; `add_text_properties' over the whole of it.
      ;;--------------------------------------------------------------
      (if (odd? (length properties))
          (error "Wrong number of arguments" 'propertize))
      (let ((result (copy-sequence string)))
        (add-text-properties 0 (string-length result) properties result)
        result))

    (define (insert-char character count . rest)
      ;; GNU Emacs's `insert-char' (editfns.c): "Insert COUNT copies of
      ;; CHARACTER. Point, and before-insertion markers, are relocated
      ;; as usual."
      ;;
      ;; "Optional second arg INHERIT, if non-nil, means to inherit text
      ;; properties from the surrounding text" - the third argument here,
      ;; and insert-with-inherit is not ported, so only the plain arm is,
      ;; which is the one `indent-to' takes.
      ;;--------------------------------------------------------------
      (let ((count (if count count 1)))
        (if (<= count 0)
            #f
            (let loop ((left count))
              (when (> left 0)
                (insert (string character))
                (loop (- left 1)))))))

    (define (fix-position pos)
      ;; GNU Emacs's `fix_position` (`editfns.c:2281', static): "If POS is
      ;; a marker, return its position; otherwise, check that it is a
      ;; fixnum and return it." The C's `Fsubst_char_in_region` runs the
      ;; two arguments through `validate_region`, which does the same, and
      ;; this tree's `validate_region` cannot: `marker.scm` is above
      ;; `buffer.scm`. So the coercion lives here, where the C's own
      ;; `fix_position` is, and the callers that take an arbitrary object
      ;; call it.
      ;;--------------------------------------------------------------
      (if (markerp pos)
          (marker-position pos)
          pos))

    (define (%char-code character)
      ;; A character or a code point as a code point - the `CHECK_CHARACTER'
      ;; of the two DEFUNs below, and the same tolerance `syntax.scm''s
      ;; `%char-code` has: this tree's readers answer characters where the
      ;; C's answer integers, and both spellings reach these.
      ;;--------------------------------------------------------------
      (if (char? character) (char->integer character) character))

    (define (record-change beg length)
      ;; GNU Emacs's `record_change` (`undo.c:199`): "Record a change in
      ;; which characters from BEG to BEG+LENGTH are being replaced by
      ;; the same number of characters." It is exactly the C's two calls,
      ;; in the C's order - the deletion carrying the text that is about
      ;; to go, then the insertion of what replaces it.
      ;;
      ;; **It is `undo.c`'s and it lives here**, because the C's
      ;; `make_buffer_string` is what a deletion entry carries and
      ;; `undo.scm` sits *below* `intervals.scm` in this tree's graph -
      ;; `intervals` imports `insdel`, which imports `undo`, so the
      ;; direction that would put `make-buffer-string` in `undo.scm` is a
      ;; cycle. Both of the C's callers (`editfns.c:2417`, `:2626`) are
      ;; in this file, and the text properties on the entry matter for
      ;; exactly this operation: `subst-char-in-region` writes in place
      ;; and must undo back to the same propertized text.
      ;;--------------------------------------------------------------
      (record-delete beg (make-buffer-string (current-buffer) beg
                                             (+ beg length) #t))
      (record-insert beg length))

    (define (%character-length code)
      ;; The byte length of CHAR_STRING for CODE - Emacs's internal
      ;; `utf-8-emacs' encoding, where a raw byte (`CHAR_BYTE8_P') is two
      ;; bytes and everything else is one to five. Only the *length* is
      ;; wanted: `subst-char-in-region' refuses a replacement whose
      ;; character would change the text's byte length, and this tree's
      ;; store has one element per character, so nothing else of the
      ;; encoding is observable here.
      ;;--------------------------------------------------------------
      (cond ((< code #x3FFF00)
             (cond ((< code #x80) 1)
                   ((< code #x800) 2)
                   ((< code #x10000) 3)
                   ((< code #x200000) 4)
                   (else 5)))
            ((<= code #x3FFFFF) 2)
            (else 5)))

    (define (subst-char-in-region start end fromchar tochar . rest)
      ;; GNU Emacs's `subst-char-in-region' (`editfns.c:2294'): "From
      ;; START to END, replace FROMCHAR with TOCHAR each time it occurs.
      ;; If optional arg NOUNDO is non-nil, don't record this change for
      ;; undo and don't mark the buffer as really changed.
      ;; Both characters must have the same length of multi-byte form."
      ;;
      ;; **The hooks go around the whole region**: `modify_text' at the
      ;; first character that changes, `record_change' per character, and
      ;; one `signal_after_change' at the end - which is `casify_region''s
      ;; division too. The C `goto restart's after `modify_text' because
      ;; a before-change function may have moved the text; this does not,
      ;; which is the same departure the rest of the tree's writers carry.
      ;;--------------------------------------------------------------
      (let ((noundo (and (pair? rest) (car rest))))
        (let ((from (%char-code fromchar))
              (to (%char-code tochar))
              (buffer (current-buffer)))
          (if (not (and (exact-integer? from) (exact-integer? to)
                        (<= 0 from) (<= 0 to)))
              (error "Wrong type argument" fromchar))
          (if (not (= (%character-length from) (%character-length to)))
              (error "Characters in `subst-char-in-region' have different byte-lengths"))
          (let-values (((start end) (validate-region (fix-position start)
                                                     (fix-position end))))
            (if (= start end)
                #f
                (let ((saved-undo (text-editor-undo-list buffer)))
                  (if noundo (set!text-editor-undo-list buffer #t))
                  (let ((text (text-editor-text buffer))
                        (changed 0)
                        (last-changed 0))
                    (let loop ((pos start))
                      (if (< pos end)
                          (begin
                            (if (= (buffer-text-ref text pos) from)
                                (begin
                                  (if (= changed 0)
                                      (begin
                                        (set! changed pos)
                                        (modify-text pos end)
                                        (when noundo
                                          ;; "don't mark the buffer as
                                          ;; really changed" - the C's
                                          ;; `SAVE_MODIFF' nudge after
                                          ;; `modify_text' raised MODIFF.
                                          (let ((m (buffer-modified-tick
                                                    buffer)))
                                            (if (= (text-editor-save-modiff
                                                    buffer)
                                                   (- m 1))
                                                (set!text-editor-save-modiff
                                                 buffer m))))))
                                  (if (not noundo)
                                      (record-change pos 1))
                                  (buffer-text-set! text pos to)
                                  (set! last-changed (+ pos 1))))
                            (loop (+ pos 1)))))
                    (when (> changed 0)
                      (signal-after-change changed
                                           (- last-changed changed)
                                           (- last-changed changed)))
                    (if noundo
                        (set!text-editor-undo-list buffer saved-undo))
                    #f)))))))

    (define (buffer-size)
      ;; GNU Emacs's `buffer-size' (editfns.c): "Return the number of
      ;; characters in the current buffer. In the presence of multibyte
      ;; characters, this is not the same as the size of the buffer in
      ;; bytes. Narrowing is in effect, this returns the size of the
      ;; accessible portion." - `Z - BEG`, **not** `ZV - BEGV`: the whole
      ;; text, narrowing or not.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text (current-buffer))))
        (- (buffer-text-z text) (buffer-text-base text))))

    (define (buffer-narrowed-p)
      ;; GNU Emacs's `buffer-narrowed-p` (`subr.el:4566', a `defsubst`):
      ;; "Return non-nil if the current buffer is narrowed."
      ;; `(/= (- (point-max) (point-min)) (buffer-size))' - the accessible
      ;; length against the whole one.
      ;;
      ;; **`subr.el`'s, and it lives here** because `subr.scm` is below
      ;; this library and the three answers it compares are this one's.
      ;; The same seam `locate-file-internal` took into `fileio.scm`.
      ;;--------------------------------------------------------------
      (not (= (- (point-max) (point-min)) (buffer-size))))

    (define (buffer-string)
      ;; GNU Emacs's `buffer-string' (editfns.c): "Return the contents
      ;; of the current buffer as a string."
      ;;--------------------------------------------------------------
      (buffer-substring (point-min) (point-max)))

    (define (delete-and-extract-region beg end)
      ;; GNU Emacs's `delete-and-extract-region' (editfns.c): "Delete
      ;; the text between START and END and return it" - `transpose-
      ;; subr-1' is what uses it.
      ;;--------------------------------------------------------------
      ;; The C is `del_range_1 (start, end, 1, 1)` - prepare the change,
      ;; and answer the text. The `1, 1` is why this is not
      ;; `delete-region`: that one discards what it deleted, and the
      ;; capture is what `del_range_2` does with its RET_STRING.
      ;;--------------------------------------------------------------
      (when (> beg end)
        (let ((swap beg)) (set! beg end) (set! end swap)))
      (del-range-1 beg end #t #t))

        (define (forward-line . rest)
      ;; GNU Emacs's `forward-line`, whose DEFUN is `(0, 1, "^p")`. Its C
      ;; is in `cmds.c:97`, and this is a **placement departure**: it lives
      ;; here, not there, because `indent.scm` and `indentc.scm` use it and
      ;; sit *below* `cmds.scm`, so moving it up would be an import cycle.
      ;; The body below is the C's, though:
      ;;
      ;;     counted = scan_newline_from_point (count, &pos, &pos_byte);
      ;;     SET_PT_BOTH (pos, pos_byte);
      ;;     shortage = count - (count <= 0) - counted;
      ;;     if (shortage != 0)
      ;;       shortage -= (count <= 0 ? -1
      ;;                    : (BEGV < ZV && PT != opoint
      ;;                       && FETCH_BYTE (PT_BYTE - 1) != '\n'));
      ;;     return shortage;
      ;;
      ;; **Two things were wrong with the version this replaced, and this
      ;; rewrite is both.** It scanned line by line with
      ;; `text-editor-get-end-of-line` where the C scans with
      ;; `scan_newline_from_point` - the one the `region_cache` backs, so a
      ;; long line is not walked a character at a time. And **its answer
      ;; was always zero**: the loop passed `moved` to itself unchanged
      ;; instead of counting, so a caller that tests the answer for "did I
      ;; run out of buffer" - `kill-line`'s `(unless (= 0 fail) (error
      ;; "End of buffer"))`, `paragraphs.scm`'s walks - was told every move
      ;; had succeeded. The C's answer is the **shortage**, "the count of
      ;; lines left to move": a move that ran out of buffer answers
      ;; non-zero.
      ;;
      ;; The `FETCH_BYTE (PT_BYTE - 1) != '\n'` clause is the docstring's
      ;; exception - "a non-empty line at the end of the buffer counts as
      ;; one line successfully moved" - which is why `(forward-line 1)` on
      ;; the last line of a buffer with no final newline still answers 0
      ;; while the same call at `point-max` answers 1.
      ;;
      ;; **Not carried**: the `excessive` branch, for a bignum N
      ;; (`BUF_BYTES_MAX` and the `Fnatnump` test); N here is a fixnum or
      ;; false, as it is everywhere else in this tree.
      "Move N lines forward (backward if N is negative).
Precisely, if point is on line I, move to the start of line I + N
(\"start of line\" in the logical order).
If there isn't room, go as far as possible (no error).

Returns the count of lines left to move.  If moving forward,
that is N minus number of lines moved; if backward, N plus number
moved."
      (let* ((ed (current-buffer))
             (n (if (and (pair? rest) (car rest)) (car rest) 1))
             (opoint (buffer-pt ed)))
        (call-with-values
            (lambda () (scan-newline-from-point ed n))
          (lambda (pos counted)
            (set-point ed pos)
            (let ((shortage (- n (if (<= n 0) 1 0) counted)))
              (if (= shortage 0)
                  shortage
                  (- shortage
                     (if (<= n 0)
                         -1
                         (let ((c (char-before)))
                           (if (and (< (buffer-beg ed) (buffer-z ed))
                                    (not (= (buffer-pt ed) opoint))
                                    (not (and c (char=? c #\newline))))
                               1
                               0))))))))))

(define (mark-marker)
      ;; GNU Emacs's `mark-marker' (`editfns.c:265'): "Return this
      ;; buffer's mark, as a marker object. Watch out! Moving this
      ;; marker changes the mark position. If you set the marker not to
      ;; point anywhere, the buffer will have no mark."
      ;;
      ;; **It takes no buffer, as the C's takes none** - the C is
      ;; `BVAR (current_buffer, mark)' and nothing else. It lived in
      ;; `engine.scm' until 2026-10-12, spelled with an ED argument; the
      ;; argument was an invention, and every caller passed the current
      ;; buffer.
      ;;
      ;; It is here rather than in `buffer.scm' because `editfns.c' is
      ;; where Emacs puts it, and `buffer.scm' is where the *slot* is
      ;; (`%mark-marker'). This file is above that one, which is the
      ;; direction the C's own data layout runs too.
      ;;--------------------------------------------------------------
      (%mark-marker (current-buffer)))

(define (point-marker)
      ;; GNU Emacs's `point-marker' (editfns.c): "Return value of point
      ;; as a marker object" - the bookkeeping `save-excursion''s
      ;; `save_excursion_save' does.
      ;;--------------------------------------------------------------
      (build-marker (current-buffer)
                   (buffer-pt (current-buffer))))

    (define (%whole-beg buffer)
      ;; `BEG' - the start of the buffer text, which narrowing does not
      ;; move. `buffer-beg' answers `BEGV'.
      ;;--------------------------------------------------------------
      (buffer-text-base (text-editor-text buffer)))

    (define (%whole-z buffer)
      ;; `Z' - the end of the buffer text, which narrowing does not move.
      ;;--------------------------------------------------------------
      (buffer-text-z (text-editor-text buffer)))

    (define-command (widen)
      ;; GNU Emacs's `widen' (`editfns.c:2901'): "Remove restrictions
      ;; (narrowing) from current buffer. ... This allows the buffer's
      ;; full text to be seen and edited."
      ;;
      ;; **Not carried**: labeled restrictions (`with-restriction' /
      ;; `without-restriction', `editfns.c:3190'), which need a stack of
      ;; labeled markers per buffer. `narrow-to-region' here has no label
      ;; to limit it to.
      ;;
      ;; The C's interactive spec is `(interactive)', so it is a command:
      ;; `C-x n w' (`bindings.el:1214', `narrow-map') reaches it.
      ;;--------------------------------------------------------------
      "Remove restrictions (narrowing) from current buffer.
This allows the buffer's full text to be seen and edited."
      (interactive)
      (let ((buffer (current-buffer)))
        (unless (and (= (buffer-begv buffer) (%whole-beg buffer))
                     (= (buffer-zv buffer) (%whole-z buffer)))
          (set!buffer-begv buffer (%whole-beg buffer))
          (set!buffer-zv buffer (%whole-z buffer))
          ;; `buf->clip_changed = 1': "Changing the buffer bounds
          ;; invalidates any recorded current column" and tells the
          ;; redisplay the window's start position may now be invisible.
          (%clip-changed! buffer)))
      #f)

    (define-command (narrow-to-region start end)
      ;; GNU Emacs's `narrow-to-region' (`editfns.c:2948'): "Restrict
      ;; editing in this buffer to the current region. The rest of the
      ;; text becomes temporarily invisible and untouchable but is not
      ;; deleted; if you save the buffer in a file, the invisible text is
      ;; included in the file."
      ;;
      ;; The C: sort the two ends, refuse anything outside `BEG..Z',
      ;; store them as BEGV and ZV, and pull point inside.
      ;;
      ;; Its interactive spec is `"r"' (`editfns.c:2948'), so it is a
      ;; command: `C-x n n' (`narrow-map', `bindings.el:1214') reaches it.
      ;; Emacs also puts `(put 'narrow-to-region 'disabled t)'
      ;; (`bindings.el:1111') on it, so a key asks before narrowing; the
      ;; disabled-command machinery is not carried - see DEPARTURES.md.
      ;;--------------------------------------------------------------
      "Restrict editing in this buffer to the current region.
The rest of the text becomes temporarily invisible and untouchable
but is not deleted; if you save the buffer in a file, the invisible
text is included in the file.  \\[widen] makes all visible again.
See also `save-restriction'.

When calling from Lisp, pass two arguments START and END:
positions (integers or markers) bounding the text that should
remain visible."
      (interactive "r")
      (let* ((buffer (current-buffer))
             (s (cond ((markerp start) (marker-position start)) (else start)))
             (e (cond ((markerp end) (marker-position end)) (else end))))
        (when (> s e)
          (let ((tem s)) (set! s e) (set! e tem)))
        ;; `if (!(BEG <= s && s <= e && e <= Z)) args_out_of_range'
        (unless (and (<= (%whole-beg buffer) s)
                     (<= s e)
                     (<= e (%whole-z buffer)))
          (error "Args out of range" start end))
        (unless (and (= (buffer-begv buffer) s) (= (buffer-zv buffer) e))
          (set!buffer-begv buffer s)
          (set!buffer-zv buffer e)
          (%clip-changed! buffer))
        (let ((pt (buffer-pt buffer)))
          (when (< pt s) (set-point buffer s)))
        (let ((pt (buffer-pt buffer)))
          (when (> pt e) (set-point buffer e)))
        #f))

    (define narrow-map
      ;; GNU Emacs's `narrow-map' (`bindings.el:1214'): "Keymap for
      ;; narrowing commands." `n`, `w` and `g` - `goto-line-relative`,
      ;; which `simple.el` has and `minibuffer.scm` carries.
      ;;
      ;; Emacs puts the map in `ctl-x-map` as one event
      ;; (`(define-key ctl-x-map "n" narrow-map)') and lets the reader
      ;; descend into it. This tree's lookup walks a map's layers and the
      ;; maps beside it, not a submap (`lookup-keymaps`), which is the
      ;; `mule-keymap` departure the 2026-10-06 handoff records - so the
      ;; sequences are bound flat as well, and the map exists for
      ;; `where-is-internal` the way Emacs's does.
      ;;--------------------------------------------------------------
      (make-sparse-keymap))

    (define-key narrow-map (kbd "n") narrow-to-region)
    (define-key narrow-map (kbd "w") widen)

    ;; `C-x n n` and `C-x n w` - `narrow-map`, flat (see above).
    (define-key *default-keymap* (kbd "C-x n n") narrow-to-region)
    (define-key *default-keymap* (kbd "C-x n w") widen)

    (define (%clip-changed! buffer)
      ;; `current_buffer->clip_changed = 1' (`editfns.c:2989'): "Changing
      ;; the buffer bounds invalidates any recorded current column" and
      ;; tells the redisplay that the window's start may no longer be in
      ;; the accessible portion. This tree computes columns on demand, so
      ;; what is left is the renderer's "something changed" flag - the
      ;; same one `force-mode-line-update` sets.
      ;;--------------------------------------------------------------
      (set-windows-or-buffers-changed! #t))

    (define-syntax save-restriction
      ;; GNU Emacs's `save-restriction' (`editfns.c:3150'): "Execute
      ;; BODY, saving and restoring current buffer's restrictions. ...
      ;; The old restrictions settings are restored even in case of
      ;; abnormal exit (throw or error)."
      ;;
      ;; The C saves a pair of *markers* (`save_restriction_save_1'),
      ;; the end one with an insertion type of 1 so that text inserted
      ;; exactly at the end is inside the restored restriction; the
      ;; restore puts them back only if BEGV/ZV have moved, and pulls
      ;; point inside (`save_restriction_restore_1').
      ;;
      ;; A macro as it is in Emacs, because the body is several forms.
      ;; `(%save-restriction-save)' is a procedure so that the markers
      ;; are made once, where the C makes them.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((save-restriction body ...)
         (let ((saved (%save-restriction-save)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda () (%save-restriction-restore saved)))))))

    (define (%save-restriction-save)
      ;; `save_restriction_save_1' (`editfns.c:3043'): a pair of markers
      ;; bounding the accessible portion - the end one advancing on an
      ;; insertion at its own position.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (list (build-marker buffer (buffer-begv buffer))
              (let ((end (build-marker buffer (buffer-zv buffer))))
                (set-marker-insertion-type end #t)
                end))))

    (define (%save-restriction-restore saved)
      ;; `save_restriction_restore_1' (`editfns.c:3067'), less the
      ;; labeled-restriction stack.
      ;;--------------------------------------------------------------
      (let* ((start (car saved))
             (end (cadr saved))
             (buffer (marker-buffer start)))
        (when buffer
          (let ((s (marker-position start))
                (e (marker-position end)))
            (unless (and (= (buffer-begv buffer) s) (= (buffer-zv buffer) e))
              (set!buffer-begv buffer s)
              (set!buffer-zv buffer e)
              (let ((pt (buffer-pt buffer)))
                (when (or (< pt s) (> pt e))
                  (set-point buffer (min (max pt s) e))))
              (%clip-changed! buffer))))
        ;; "Detach the markers, and free the cons"
        (set-marker start #f)
        (set-marker end #f))
      #f)

(define-syntax save-excursion
      ;; GNU Emacs's `save-excursion' (editfns.c:818): "Save point, and
      ;; current buffer; execute BODY; restore those things. Executes
      ;; BODY just like `progn'. The values of point and the current
      ;; buffer are restored even in case of abnormal exit (throw or
      ;; error)."
      ;;
      ;; The C's `save_excursion_save' saves a POINT MARKER - which
      ;; moves with insertions and deletions, not a bare position -
      ;; and the selected window when it shows the current buffer;
      ;; `save_excursion_restore' goes back to the buffer, goes to
      ;; where the marker ended up, and sets that window's point if a
      ;; different window is selected now. This is that, as a macro
      ;; over `dynamic-wind' - the unwind-protect the C's specpdl is -
      ;; with the marker doing the following, and the buffer and
      ;; window-point restore beside it. What is not ported is
      ;; `Fset_window_point' for a *non-selected* window, there being
      ;; no per-window point yet that a different selected window
      ;; would show the buffer through.
      ;;
      ;; It is a macro as it is in Emacs - a special form there, and
      ;; `with-current-buffer''s precedent here - because the body is
      ;; several forms.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((save-excursion body ...)
         (let ((marker (point-marker))
               (saved-buffer (current-buffer)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda ()
               (set-buffer saved-buffer)
               ;; `Fgoto_char (marker)' - where the marker ended up
               ;; after BODY's edits, unchained once read
               (set-point
                saved-buffer (marker-position marker))
               (set-marker marker #f)))))))

    ;;----------------------------------------------------------------
    ;; `format', `format-message' and `message'
    ;;
    ;; GNU Emacs 31 has all three in `src/editfns.c': `Fformat_message'
    ;; (editfns.c:3422, over the static `styled_format') and `Fmessage'
    ;; (editfns.c:3197). Emacs 28 had `message' in `src/xdisp.c', which
    ;; is where the rest of this tree's echo-area code was read from;
    ;; the version ported here is the one in the Emacs in `../emacs'.
    ;;------------------------------------------------------------------

    (define *text-quoting-style* (make-parameter #f))
    ;; ^ GNU Emacs's `text-quoting-style' (doc.c:652). Its default is
    ;; nil: "grave if curved quotes cannot be displayed, otherwise
    ;; curve", which `text-quoting-style' below resolves through
    ;; `default-to-grave-quoting-style'.

    (define *standard-display-table* (make-parameter #f))
    ;; ^ GNU Emacs's `standard-display-table' (C, xdisp.c), which is nil
    ;; by default and which `default-to-grave-quoting-style' asks whether
    ;; `‘' has been made to display as a `\`'. Nothing in this tree sets
    ;; it, so the answer is what the C gives when the table is not a
    ;; display table: curve - the same style `emacs -Q' answers in a
    ;; UTF-8 terminal or a window frame.

    (define *inhibit-message* (make-parameter #f))
    ;; ^ GNU Emacs's `inhibit-message': "Non-nil means `message' should
    ;; not display a message, only log it in the `*Messages*' buffer."

    (define *message-log-function* (make-parameter (lambda (text) #f)))
    ;; ^ The seam to `message_dolog' (`xdisp.c:12340'), which is
    ;; `xdisp.scm`'s - the same device as `*message-function*' below and
    ;; for the same reason: `message' is `editfns.c`'s (`Fmessage`,
    ;; `:3197') and the log is `xdisp.c`'s, a library built on this one.
    ;;
    ;; **`message-log-max' and `messages-buffer-name' went with it.** They
    ;; were `*message-log-max*' here until 2026-10-14, "the variable
    ;; waiting for the buffer"; both are `xdisp.c`'s DEFVARs (`:38859',
    ;; `:38597') and `Fmessage' reads neither - `message_dolog' does.

    (define *message-function* (make-parameter (lambda (text) #f)))
    ;; ^ How a message reaches the echo area: `FRAME_MESSAGE_BUF' and the
    ;; `set-message!' that writes it are the frame's, and that is the
    ;; library built *on* this one, so the seam runs this way round.
    ;; `frame.scm' installs `(lambda (text) (set-message! (*current-frame*)
    ;; text))' as it loads, and the echo area is the frame's own - the
    ;; same place Emacs's `message3' puts it (`xdisp.c:11016').
    ;;
    ;; The default does nothing, which is the honest answer when there is
    ;; no frame: a script or a test may `message' with nothing on screen,
    ;; and the text is still returned to the caller.

    (define *current-message-function* (make-parameter (lambda () #f)))
    ;; ^ GNU Emacs's `current-message' (`xdisp.c'): the string the echo
    ;; area is showing, or nil when none. Read off the frame through this
    ;; seam for the reason above; with no frame installed the answer is
    ;; nil, as the C answers when the echo area is empty.

    (define (default-to-grave-quoting-style)
      ;; GNU Emacs's `default_to_grave_quoting_style' (doc.c:640):
      ;; whether `‘' has been given a display table entry that draws it
      ;; as a plain `\`' - which is what a terminal that cannot show the
      ;; curved quote is given. With no such table the answer is false,
      ;; and the style is `curve'. (The C's first test, a compile-time
      ;; `text_quoting_flag', is what a build with the feature left out
      ;; answers, and is not a run-time question.)
      ;;--------------------------------------------------------------
      (and (*standard-display-table*)
           ;; The non-nil arm is the C's `DISP_CHAR_VECTOR' of
           ;; `LEFT_SINGLE_QUOTATION_MARK': whether the table draws `‘'
           ;; as a bare `` ` ''. A display table is a C char-table of
           ;; glyph vectors and this tree has no such object - the
           ;; library called `disp-table' here is `disp-table.el''s
           ;; character-width table - so a non-nil value cannot arise,
           ;; and the answer that can is the C's for a nil variable:
           ;; false, which makes the style `curve'.
           #f))

    (define (text-quoting-style)
      ;; GNU Emacs's `text-quoting-style' (doc.c:652): "Return the
      ;; current effective text quoting style. If the variable
      ;; `text-quoting-style' is `grave', `straight' or `curve', just
      ;; return that value. If it is nil (the default), return `grave'
      ;; if curved quotes cannot be displayed ... otherwise `curve'.
      ;; Any other value is treated as `curve'."
      ;;--------------------------------------------------------------
      (cond ((not (*text-quoting-style*))
             (if (default-to-grave-quoting-style) 'grave 'curve))
            ((eq? (*text-quoting-style*) 'grave) 'grave)
            ((eq? (*text-quoting-style*) 'straight) 'straight)
            (else 'curve)))

    (define (%requote text)
      ;; The grave-accent/apostrophe substitution `format-message' makes:
      ;; under `curve' each ` becomes a left quote and each ' a right
      ;; quote; under `straight' each ` becomes '; under `grave' nothing
      ;; changes, the text already carrying the quotes it meant.
      ;; (editfns.c:3440 takes `quoting_style' from `Ftext_quoting_style'
      ;; only when MESSAGE is true, and the re-quoting is done by the walk
      ;; over the `discarded' table at the end of `styled_format'.)
      ;;--------------------------------------------------------------
      (case (text-quoting-style)
        ((curve)
         (string-map (lambda (c)
                       (case c ((#\`) #\‘) ((#\') #\’) (else c)))
                     text))
        ((straight)
         (string-map (lambda (c) (if (char=? c #\`) #\' c)) text))
        (else text)))

    (define (%object->string obj readable?)
      ;; The object OBJ as `%s' (READABLE? false) or `%S' (true) writes
      ;; it: `styled_format' sends a `%S' argument through `prin1' and a
      ;; `%s' argument through `princ' (editfns.c:3687). Guile's `write'
      ;; is `prin1' and its `display' is `princ' - both print a string
      ;; inside a list without its quotes, which is what princ does and
      ;; what makes `%s' of a list differ from its printed form.
      ;;--------------------------------------------------------------
      (if (and (not readable?) (string? obj))
          obj
          (call-with-output-string
           (lambda (port)
             (if readable? (write obj port) (display obj port))))))

    (define (%format-digits text i len)
      ;; The run of digits at I as a number, and the index after it:
      ;; the C's `str2num' as `styled_format' uses it.
      ;;--------------------------------------------------------------
      (let loop ((j i) (n 0))
        (if (and (< j len) (char-numeric? (string-ref text j)))
            (loop (+ j 1)
                  (+ (* n 10) (- (char->integer (string-ref text j)) 48)))
            (values n j))))

    (define (%format-flags text i len)
      ;; The flag run at I. `styled_format' collects the five flags and
      ;; then applies two C rules to them (editfns.c:3639): "Ignore flags
      ;; when sprintf ignores them" - `space' is dropped when `plus' is
      ;; there, and `zero' when `minus' is.
      ;;--------------------------------------------------------------
      (let loop ((j i) (minus #f) (plus #f) (space #f) (sharp #f) (zero #f))
        (if (>= j len)
            (values j minus plus (and space (not plus))
                    sharp (and zero (not minus)))
            (case (string-ref text j)
              ((#\-) (loop (+ j 1) #t plus space sharp zero))
              ((#\+) (loop (+ j 1) minus #t space sharp zero))
              ((#\space) (loop (+ j 1) minus plus #t sharp zero))
              ((#\#) (loop (+ j 1) minus plus space #t zero))
              ((#\0) (loop (+ j 1) minus plus space sharp #t))
              (else
               (values j minus plus (and space (not plus))
                       sharp (and zero (not minus))))))))

    (define (%format-pad text width minus zero prefix-length)
      ;; TEXT widened to WIDTH the way the C's sprintf does it: on the
      ;; right when `-' was given, with zeroes after the sign or radix
      ;; prefix when `0' was, and with spaces otherwise. PREFIX-LENGTH
      ;; says how many leading characters the zeroes must come after.
      ;;--------------------------------------------------------------
      (if (or (not width) (<= width (string-length text)))
          text
          (let ((pad (- width (string-length text))))
            (cond (minus
                   (string-append text (make-string pad #\space)))
                  (zero
                   (string-append (substring text 0 prefix-length)
                                  (make-string pad #\0)
                                  (substring text prefix-length
                                             (string-length text))))
                  (else
                   (string-append (make-string pad #\space) text))))))

    (define (%format-integer arg conversion minus plus space sharp zero
                             width precision)
      ;; ARG under a `%d', `%i', `%o', `%x', `%X', `%b' or `%B'
      ;; conversion. `%b' and `%B' are Emacs's own - C's printf has no
      ;; binary conversion - and are the reason this is not a call to
      ;; Guile's.
      ;;
      ;; The C hands all of this to sprintf, so the rules are sprintf's:
      ;; a precision is a minimum number of digits (and turns off the
      ;; `0' flag), `#' asks for the radix prefix, and the sign is the
      ;; `-' of a negative number, or `+' or a space where those flags
      ;; asked for it.
      ;;--------------------------------------------------------------
      (let* ((base (case conversion
                     ((#\d #\i) 10) ((#\o) 8) ((#\x #\X) 16)
                     ((#\b #\B) 2) (else 10)))
             (negative (and (< arg 0) (memv conversion '(#\d #\i))))
             (magnitude (abs arg))
             (digits (number->string magnitude base))
             (digits (if (and precision (< (string-length digits) precision))
                         (string-append
                          (make-string (- precision (string-length digits)) #\0)
                          digits)
                         digits))
             (digits (if (memv conversion '(#\X #\B))
                         (string-upcase digits)
                         digits))
             (radix (case conversion
                      ((#\o) (if sharp "0" ""))
                      ((#\x) (if sharp "0x" ""))
                      ((#\X) (if sharp "0X" ""))
                      ((#\b) (if sharp "0b" ""))
                      ((#\B) (if sharp "0B" ""))
                      (else "")))
             (sign (cond (negative "-") (plus "+") (space " ") (else "")))
             (body (string-append sign radix digits)))
        (%format-pad body width minus (and zero (not precision))
                     (+ (string-length sign) (string-length radix)))))

    (define (%parse-spec format-string start n)
      ;; The conversion specification at START, which is its `%'.
      ;; Answers: the index just after it, the argument count to carry
      ;; into the next specification, the conversion character, the
      ;; argument index it takes (or #f for `%%'), the five flags,
      ;; the field width and the precision - each of the last two #f
      ;; when it was not given.
      ;;
      ;; The grammar is the C's own comment (editfns.c:3610):
      ;;   '%' [field-number] [flags] [field-width] [precision] conversion
      ;; with field-number `N$', and a field number overriding the
      ;; count-to-next-argument the plain form uses (editfns.c:3624).
      ;;--------------------------------------------------------------
      (let* ((len (string-length format-string))
             (j (+ start 1))
             (numbered
              (and (< j len) (char-numeric? (string-ref format-string j))
                   (let-values (((num end)
                                 (%format-digits format-string j len)))
                     (and (< end len)
                          (char=? (string-ref format-string end) #\$)
                          (cons num (+ end 1))))))
             (j (if numbered (cdr numbered) j))
             (numbered-arg (and numbered (- (car numbered) 1)))
             (n (if numbered-arg numbered-arg n)))
        (let*-values (((j minus plus space sharp zero)
                       (%format-flags format-string j len))
                      ((width j)
                       (if (and (< j len)
                                (char-numeric? (string-ref format-string j)))
                           (let-values (((num end)
                                         (%format-digits format-string j len)))
                             (values num end))
                           (values #f j)))
                      ((precision j)
                       (if (and (< j len)
                                (char=? (string-ref format-string j) #\.))
                           (let-values (((num end)
                                         (%format-digits format-string
                                                         (+ j 1) len)))
                             (values num end))
                           (values #f j))))
          (when (>= j len)
            (error "Format string ends in middle of format specifier"))
          (let ((conversion (string-ref format-string j)))
            (values (+ j 1)
                    (cond (numbered-arg (+ numbered-arg 1))
                          ((char=? conversion #\%) n)
                          (else (+ n 1)))
                    conversion
                    (cond (numbered-arg numbered-arg)
                          ((char=? conversion #\%) #f)
                          (else n))
                    (list minus plus space sharp zero)
                    width precision)))))

    (define (%truncate-to-precision text precision)
      ;; A `%s' or `%c' argument cut to PRECISION characters, which for a
      ;; string conversion is what C's "%.3s" means.
      ;;--------------------------------------------------------------
      (if (and precision (< precision (string-length text)))
          (substring text 0 precision)
          text))

    (define (%float-no-bare-point text)
      ;; C's printf writes no `.` when the precision is zero - `%.0f' of
      ;; 3.7 is "4" - and Guile's `~f'/`~e' write the point anyway ("4.",
      ;; "0.E+0"). A point with no fraction is exactly what has to go.
      ;;--------------------------------------------------------------
      (let ((e-at (string-index text (lambda (c) (char=? c #\e)))))
        (cond ((and e-at (> e-at 0)
                    (char=? (string-ref text (- e-at 1)) #\.))
               (string-append (substring text 0 (- e-at 1))
                              (substring text e-at (string-length text))))
              ((and (not e-at) (< 0 (string-length text))
                    (char=? (string-ref text (- (string-length text) 1)) #\.))
               (substring text 0 (- (string-length text) 1)))
              (else text))))

    (define (%float-exponent text)
      ;; The decimal exponent in a `~e'-written TEXT, e.g. the 3 of
      ;; "1.234500E+3". `%g' needs it to choose between C's two styles.
      ;;--------------------------------------------------------------
      (let ((at (string-index text (lambda (c) (char=? c #\E)))))
        (string->number (substring text (+ at 1) (string-length text)))))

    (define (%float-exponent-text exponent)
      ;; An exponent the way C's printf writes it, which is not the way
      ;; Guile's does: at least two digits, lower-case `e', and a sign.
      ;;--------------------------------------------------------------
      (let* ((digits (number->string (abs exponent)))
             (digits (if (< (string-length digits) 2)
                         (string-append "0" digits)
                         digits)))
        (string-append (if (< exponent 0) "e-" "e+") digits)))

    (define (%float-strip-zeros text)
      ;; C's `%g' rule: "trailing zeros are removed from the fractional
      ;; portion of the result unless the `#' flag is used". The point
      ;; goes with them when nothing is left after it.
      ;;--------------------------------------------------------------
      (let* ((e-at (string-index text (lambda (c) (char=? c #\e))))
             (head (if e-at (substring text 0 e-at) text))
             (tail (if e-at (substring text e-at (string-length text)) ""))
             (dot (string-index head (lambda (c) (char=? c #\.)))))
        (if (not dot)
            text
            (let loop ((end (string-length head)))
              (cond ((and (< (+ dot 1) end)
                          (char=? (string-ref head (- end 1)) #\0))
                     (loop (- end 1)))
                    ((= end (+ dot 1)) (string-append (substring head 0 dot) tail))
                    (else (string-append (substring head 0 end) tail)))))))

    (define (%format-float arg conversion minus plus space sharp zero
                           width precision)
      ;; ARG under `%e', `%f' or `%g', the way the C's sprintf does it,
      ;; since that is what `styled_format' hands the specification to
      ;; (editfns.c:3865). The work is Guile's `~f'/`~e' at a given
      ;; precision - there is no C printf here to call - and the
      ;; adaptation around it is C's: `%e' and `%g' write a lower-case
      ;; `e' and at least two exponent digits, where Guile writes an
      ;; upper-case `E' and as few as one; and `%g' chooses between the
      ;; exponential and the decimal-point style by the decimal exponent
      ;; and then strips the trailing zeros (C's `%g' step 4).
      ;;--------------------------------------------------------------
      (let* ((p (if (and precision (= precision 0) (char=? conversion #\g))
                    1
                    (or precision 6)))
             (magnitude (abs arg))
             (sign (cond ((negative? arg) "-")
                         (plus "+")
                         (space " ")
                         (else "")))
             (body
              (case conversion
                ((#\f)
                 (%printf #f "~,vf" p magnitude))
                ((#\e)
                 (let* ((raw (%printf #f "~,ve" p magnitude))
                        (at (string-index raw (lambda (c) (char=? c #\E)))))
                   (string-append
                    (substring raw 0 at)
                    (%float-exponent-text
                     (string->number
                      (substring raw (+ at 1) (string-length raw)))))))
                (else
                 ;; `%g': the C's rule is "use the `%e' style if the
                 ;; exponent is less than -4 or greater than or equal to
                 ;; the precision, and the `%f' style otherwise", with
                 ;; one fewer digit after the point either way.
                 (let* ((raw (%printf #f "~,ve" (max 0 (- p 1)) magnitude))
                        (at (string-index raw (lambda (c) (char=? c #\E))))
                        (x (string->number
                            (substring raw (+ at 1) (string-length raw)))))
                   (let ((text (if (or (< x -4) (<= p x))
                                   (string-append (substring raw 0 at)
                                                  (%float-exponent-text x))
                                   (%printf #f "~,vf" (max 0 (- p 1 x))
                                            magnitude))))
                     (if sharp text (%float-strip-zeros text))))))))
        (%format-pad (string-append sign (%float-no-bare-point body))
                     width minus zero (string-length sign))))

    (define (%format-one conversion arg minus plus space sharp zero
                         width precision)
      ;; The text one conversion substitutes: the body of the C's
      ;; `styled_format' loop, with the parsing already done by
      ;; `%parse-spec'. Emacs keeps this in the one function; it is
      ;; separate here only so that the parse, the dispatch and the
      ;; assembly can each be read - the arms are the C's arms in the
      ;; C's order (editfns.c:3855).
      ;;--------------------------------------------------------------
      (case conversion
        ((#\s #\S)
         (%format-pad (%truncate-to-precision
                       (%object->string arg (char=? conversion #\S))
                       precision)
                      width minus #f 0))
        ((#\c)
         ;; "For 'c' ... if ARG is a fixnum that is not an ASCII
         ;; character, convert it to a string and treat it like 's'"
         ;; (editfns.c:3698) - so `%c' of 65 is `A'.
         (%format-pad (%truncate-to-precision
                       (if (integer? arg)
                           (string (integer->char arg))
                           (%object->string arg #f))
                       precision)
                      width minus #f 0))
        ((#\d #\i #\o #\x #\X #\b #\B)
         (if (integer? arg)
             (%format-integer arg conversion minus plus space sharp zero
                              width precision)
             (error "Format specifier doesn't match argument type")))
        ((#\e #\f #\g)
         (if (not (number? arg))
             (error "Format specifier doesn't match argument type")
             (%format-float (exact->inexact arg) conversion minus plus space
                            sharp zero width precision)))
        (else
         (error (string-append "Invalid format operation %"
                               (string conversion))))))

    (define (%styled-format format-string args message?)
      ;; GNU Emacs's `styled_format' (editfns.c:3440): FORMAT-STRING
      ;; with ARGS substituted into it, and - when MESSAGE? - the grave
      ;; accents and apostrophes requoted by `%requote'.
      ;;
      ;; The conversions are the C's list (editfns.c:3855): s S c d i o
      ;; x X b B e f g, and `%%'. Two named departures from the C: the
      ;; float conversions are Guile's `~f'/`~e'/`~g' at a fixed
      ;; precision, so `%e' writes an upper-case `E' and a one-or-more
      ;; digit exponent where C writes a lower-case `e' and at least two;
      ;; and `%s' carries none of the argument's text properties into
      ;; the result, where the C carries the argument's intervals.
      ;;--------------------------------------------------------------
      (let ((len (string-length format-string))
            (nargs (length args))
            (parts '()))
        (define (emit text) (set! parts (cons text parts)))
        (let loop ((i 0) (n 0))
          (if (>= i len)
              (apply string-append (reverse parts))
              (let ((ch (string-ref format-string i)))
                (if (not (char=? ch #\%))
                    (begin (emit (string ch))
                           (loop (+ i 1) n))
                    (let*-values (((next n conversion argn flags width precision)
                                   (%parse-spec format-string i n)))
                      (if (char=? conversion #\%)
                          (begin (emit "%")
                                 (loop next n))
                          (begin
                            (when (>= argn nargs)
                              (error "Not enough arguments for format string"))
                            (emit (%format-one conversion (list-ref args argn)
                                               (list-ref flags 0) (list-ref flags 1)
                                               (list-ref flags 2) (list-ref flags 3)
                                               (list-ref flags 4)
                                               width precision))
                            (loop next n))))))))))

    (define (format format-string . args)
      ;; GNU Emacs's `format' (editfns.c, `Fformat' over the static
      ;; `styled_format' with MESSAGE false): "Format a string out of a
      ;; format-string and arguments. The first argument is a format
      ;; control string."
      ;;--------------------------------------------------------------
      (%styled-format format-string args #f))

    (define (format-message format-string . args)
      ;; GNU Emacs's `format-message' (editfns.c:3422): "This acts like
      ;; `format', except it also replaces each grave accent (`) by a
      ;; left quote, and each apostrophe (') by a right quote."
      ;;--------------------------------------------------------------
      (%requote (%styled-format format-string args #t)))

    (define (message format-string . args)
      ;; GNU Emacs's `message' (editfns.c:3197): "Display a message at
      ;; the bottom of the screen. The message also goes into the
      ;; `*Messages*' buffer, if `message-log-max' is non-nil. ... If
      ;; the first argument is nil or the empty string, the function
      ;; clears any existing message."
      ;;
      ;; The C's `message3' hands the text to the echo area and to
      ;; `message_dolog', which appends it to `*Messages*'. There is no
      ;; `*Messages*' buffer in this tree yet, so only the echo area end
      ;; is here, and `message-log-max' is the variable waiting for it.
      ;;--------------------------------------------------------------
      (if (or (not format-string)
              (and (string? format-string) (= 0 (string-length format-string))))
          (begin (message-clear) format-string)
          (let ((text (%requote (%styled-format format-string args #t))))
            ;; `message3' (`xdisp.c:12592') is `log_message' and *then* the
            ;; display, in that order - so a message the echo area will not
            ;; show still reaches `*Messages*', and one that is shown gets
            ;; its line into the log first.
            ((*message-log-function*) text)
            (unless (*inhibit-message*)
              ((*message-function*) text))
            text)))

    (define (message-clear)
      ;; The `message1 (0)' arm of `Fmessage' (editfns.c:3229): take any
      ;; message down, letting the minibuffer's own contents show.
      ;;--------------------------------------------------------------
      ((*message-function*) ""))

    (define (current-message)
      ;; GNU Emacs's `current-message' (xdisp.c): "Return the string
      ;; currently displayed in the echo area, or nil if none." The
      ;; echo area is the frame's message when it has not expired.
      ;;--------------------------------------------------------------
      ((*current-message-function*)))

    (define (char-equal c1 c2)
      ;; GNU Emacs's `char-equal' (`editfns.c:4418`): "Return t if two
      ;; characters match, optionally ignoring case.
      ;; Both arguments must be characters (i.e. integers).
      ;; Case is ignored if `case-fold-search' is non-nil in the current
      ;; buffer."
      ;;
      ;; The C's `CHECK_CHARACTER` runs first - a non-character is a
      ;; wrong-type-argument, not a nil - and the equality test comes
      ;; before the case-folding one, which is what makes the answer `t'
      ;; for two equal characters even with folding off.
      ;;
      ;; The C folds with `downcase', its case table's; here that is
      ;; `char-downcase' over the code point, which is the same table for
      ;; every character either can name - the tree's case tables are
      ;; `(ice-9 unicode)`'s (`casefiddle.scm`).
      ;;--------------------------------------------------------------
      (let ((i1 (%char-code c1))
            (i2 (%char-code c2)))
        (if (not (and (exact-integer? i1) (exact-integer? i2)
                      (<= 0 i1 #x3FFFFF) (<= 0 i2 #x3FFFFF)))
            (error "Wrong type argument" (if (exact-integer? i1) c2 c1)))
        (cond ((= i1 i2) #t)
              ((not (*case-fold-search*)) #f)
              ;; A byte character has no case, and `char-downcase` refuses
              ;; it by refusing the character: `integer->char` above
              ;; `#x10ffff` is outside Scheme's range, so both are
              ;; compared as they stand.
              ((or (> i1 #x10ffff) (> i2 #x10ffff)) #f)
              (else (= (char->integer
                        (char-downcase (integer->char i1)))
                       (char->integer
                        (char-downcase (integer->char i2))))))))


    (*point-marker-function* point-marker)
    (*mark-marker-function* mark-marker)
    ;; ^ The `d' and `m' interactive codes' readers (`callint.c:502',
    ;; `:623'). `command.scm` is below this library, so they arrive as
    ;; seams - the way `*barf-if-buffer-read-only-function*` arrives from
    ;; `keyboard.scm`. Both functions are the C's own, defined above.
    (*format-message-function* format-message)
    (*message-clear-function* message-clear)
    ;; ^ `callint.c:492`'s `message1_nolog (0)`, the echo clear the `c'
    ;; code does straight after reading its character. `message-clear` is
    ;; this file's; it does not log, as `message1_nolog` does not.
    ;; ^ `callint.c:448`'s `Fformat_message`, which turns a
    ;; specification's prompt into the string a code reads with - "the
    ;; arguments read so far" substituted into it.

    ))
