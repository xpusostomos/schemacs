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
    (only (guile) cadr call-with-output-string
          exact->inexact string-index)
    (only (schemacs editor buffer) current-buffer set-buffer
          *inhibit-read-only*
          ;; `FETCH_CHAR` (`buffer.h`) - the raw read of a named
          ;; buffer. It has no Lisp name, and it was the engine's
          ;; until 2026-10-13.
          fetch-char
          ;; `SET_PT` (`buffer.h:170`), the write below `goto-char` -
          ;; also the engine's until 2026-10-13, where it was
          ;; `text-editor-set-cursor`.
          set-point buffer-read-only? buffer-beg buffer-z buffer-pt)
    (only (schemacs editor marker)
          build-marker markerp marker-position set-marker)
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
    (only (schemacs editor textprop) add-text-properties)
    ;; The insertion and the deletion themselves are `insdel.c`'s, in its
    ;; own library - `insert_1_both` and `del_range` are that file's, the
    ;; same way `Finsert` and `Fdelete_region` below are this one's.
    (only (schemacs editor insdel) del-range del-range-1 insert-from-string)
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
          *mark-even-if-inactive*)
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
   delete-region
   eobp
   goto-char
   insert
   insert-and-inherit
   line-number-at-pos
   point-max
   point-min
   point
   save-excursion
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
      (del-range start end)
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
      ;; narrowing ... is in effect." Nothing is narrowed here.
      ;;--------------------------------------------------------------
      1)

    (define (point-max)
      ;; GNU Emacs's `point-max' (editfns.c): one past the last
      ;; character of the buffer.
      ;;--------------------------------------------------------------
      (buffer-z (current-buffer)))

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
        (set-point (current-buffer) at)
        at))

    (define (general-insert-function inherit args)
      ;; GNU Emacs's `general_insert_function` (`editfns.c:1298`), the
      ;; body `insert' and `insert-and-inherit' share. The C takes the two
      ;; insert functions as arguments because it has two pairs of them;
      ;; there is one string-insert here - see `insert-from-string-1` on
      ;; why - so the INHERIT flag is the whole of the parameter, and it
      ;; reaches that one call the way the C's reaches its two.
      ;;
      ;; A character is encoded into a one-character string and inserted,
      ;; which is what the C's `CHAR_STRING` does before calling
      ;; `insert_func`. The flag decides whether text that brings no
      ;; properties of its own *keeps* the neighbouring ones or has them
      ;; cleared off it, and it is read inside the graft.
      ;;--------------------------------------------------------------
      (for-each
       (lambda (arg)
         (cond
          ((string? arg) (insert-from-string arg inherit))
          ((char? arg) (insert-from-string (string arg) inherit))
          ((integer? arg)
           (insert-from-string (string (integer->char arg)) inherit))
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
      (general-insert-function #f args))

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
      (general-insert-function #t args))

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

    (define (line-beginning-position . rest)
      ;; GNU Emacs's `line-beginning-position' (`editfns.c:700'), whose
      ;; whole body is
      ;;
      ;;     ptrdiff_t count, charpos = bol (n, &count);
      ;;     return Fconstrain_to_field (make_fixnum (charpos), ...);
      ;;
      ;; - `bol' being `editfns.c:665', which this tree has as the
      ;; engine's `bol'. The field constraint is not carried: there are
      ;; no fields here, and `bol' is what every caller wants.
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
      (bol (current-buffer) (if (pair? rest) (car rest) #f)))

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
      ;;--------------------------------------------------------------
      (eol (current-buffer) (if (pair? rest) (car rest) #f)))

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
      ;;--------------------------------------------------------------
      (make-buffer-string (current-buffer) beg end #t))

    (define (buffer-substring-no-properties beg end)
      ;; GNU Emacs's `buffer-substring-no-properties': "Return the
      ;; characters of part of the current buffer, without text
      ;; properties."
      ;;--------------------------------------------------------------
      (make-buffer-string (current-buffer) beg end))

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

    (define (buffer-size)
      ;; GNU Emacs's `buffer-size' (editfns.c): "Return the number of
      ;; characters in the current buffer" - no narrowing here, so
      ;; nothing is subtracted.
      ;;--------------------------------------------------------------
      (- (buffer-z (current-buffer)) (buffer-beg (current-buffer))))

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


    ))
