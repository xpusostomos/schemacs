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
  ;; (`text-editor-get-cursor' is `point', `text-editor-insert' is
  ;; `insert', `text-editor-copy-string' is `buffer-substring'), because
  ;; the engine is `buffer.c' and `insdel.c' and the position arithmetic
  ;; had to live somewhere; they come here, under Emacs's names, when
  ;; something needs them by those names.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of, and
  ;; REGION-PLAN.txt for what it is part of.

  (import
    (scheme base)
    ;; `current-buffer' and `set-buffer', which `save-excursion' saves
    ;; and restores beside point.
    (only (guile) cadr caddr cddr cdddr cadddr)
    (only (schemacs editor buffer) current-buffer set-buffer
          *case-fold-search* *inhibit-read-only*)
    (only (schemacs editor engine)
          copy-marker marker-position marker-type? set-marker!
          text-editor-get-start-of-line text-editor-get-end-of-line
          text-editor-get-char-index text-editor-copy-string
          text-editor-search-forward text-editor-search-backward
          text-editor-read-only?
          text-editor-char-count text-editor-insert
          text-editor-cursor-line text-editor-delete-from-cursor
          text-editor-get-cursor text-editor-get-line-column
          text-editor-mark text-editor-set-cursor
          text-editor-undo-boundary!)
    ;; `mark-active' and `transient-mark-mode' are `buffer.c''s
    ;; variables, and `mark-even-if-inactive' is `callint.c''s, which is
    ;; where `region_limit' reads them from - the same three the C's
    ;; `region_limit' reads.
    (only (schemacs editor buffer)
          mark-active transient-mark-mode)
    ;; `barf-if-buffer-read-only' asks whether the text at a position
    ;; carries the `inhibit-read-only' property.
    (only (schemacs editor textprop)
          add-text-properties get-text-property)
    ;; `propertize' and the two string paths are intervals.c's and
    ;; fns.c's: `propertize' copies through `copy-sequence', and `insert'
    ;; and `buffer-substring' are the two ways text properties cross
    ;; between a string and a buffer.
    (only (schemacs editor fns) copy-sequence)
    (only (schemacs editor intervals)
          copy-intervals-to-string graft-intervals-into-buffer
          string-intervals)
    (only (schemacs editor command)
          *mark-even-if-inactive*)
    (only (schemacs ui text-buffer-impl) text-location-line)
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
   buffer-substring
point-marker
   buffer-size
   insert-char
   buffer-string
   buffer-substring-no-properties
   propertize
   delete-and-extract-region
   barf-if-buffer-read-only
   forward-line
   delete-region
   eobp
   goto-char
   insert
   line-number-at-pos
   point-max
   point-min
   point
   save-excursion
   region-beginning
   region-end
   region-limit
   )

  (begin

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
      (let ((m (text-editor-mark (current-buffer))))
        (unless m (error "The mark is not set now, so there is no region"))
        (let ((point (text-editor-get-cursor (current-buffer))))
          (if (eq? (< point m) beginning?) point m))))

    (define (delete-region start end)
      ;; GNU Emacs's `delete-region' (`editfns.c'): "delete the text
      ;; between START and END ... without modifying the kill ring". It
      ;; is the command `yank-pop' uses to take back what `yank'
      ;; inserted, and the one `kill-region' uses once the text is safely
      ;; in the ring.
      ;;
      ;; Emacs's `validate_region' puts the two in order and checks them
      ;; against the buffer; the engine's cursor-and-delete does the same
      ;; clamping.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (when (> start end)
          (let ((swap start)) (set! start end) (set! end swap)))
        (text-editor-set-cursor ed start)
        (text-editor-delete-from-cursor ed (- end start))))

    (define (region-beginning)
      ;; GNU Emacs's `region-beginning' (editfns.c): "the integer value
      ;; of point or mark, whichever is smaller" - ONE-based, which is
      ;; the engine's answer plus one, the way every position answer
      ;; of this library is.
      ;;--------------------------------------------------------------
      (+ 1 (region-limit #t)))

    (define (region-end)
      ;; GNU Emacs's `region-end' (editfns.c): "the integer value of
      ;; point or mark, whichever is larger" - one-based, as
      ;; `region-beginning' is.
      ;;--------------------------------------------------------------
      (+ 1 (region-limit #f)))


    (define (line-number-at-pos . args)
      ;; GNU Emacs's `line-number-at-pos' (`editfns.c'): "Return current
      ;; line number in the current buffer", counting from 1 at
      ;; `point-min'. With a POSITION, the line that position is on.
      ;; Emacs's also narrows-independent `what-line' does its own count
      ;; with the narrowing kept; nothing is narrowed here.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (if (pair? args)
            ;; the line POSITION is on: the engine's
            ;; `text-editor-get-line-column' answers the one-based line
            ;; and column of a character index
            (text-location-line
             (text-editor-get-line-column ed (car args)))
            (+ 1 (text-editor-cursor-line ed)))))

    ;;----------------------------------------------------------------
    ;; Point, its questions, and its preservation - the `editfns.c'
    ;; primitives under their own names. The engine has had them under
    ;; its own (`text-editor-get-cursor' is `point') since before this
    ;; library existed; these are the Emacs spellings the ports of the
    ;; .el files read as, so that a port can read like its source.
    ;;----------------------------------------------------------------

    (define (point)
      ;; GNU Emacs's `point' (editfns.c): the character position of the
      ;; cursor, one-based as Emacs counts. The engine's cursor is
      ;; zero-based, so the answer is one more than it - and everything
      ;; here that takes an Emacs position converts the same way.
      ;;--------------------------------------------------------------
      (+ 1 (text-editor-get-cursor (current-buffer))))

    (define (point-min)
      ;; GNU Emacs's `point-min' (editfns.c): "the minimum permissible
      ;; value of point in the current buffer. This is 1, unless
      ;; narrowing ... is in effect." Nothing is narrowed here.
      ;;--------------------------------------------------------------
      1)

    (define (point-max)
      ;; GNU Emacs's `point-max' (editfns.c): one past the last
      ;; character of the buffer - the engine's character count, plus
      ;; the one Emacs's zero-based cursor does not have.
      ;;--------------------------------------------------------------
      (+ 1 (text-editor-char-count (current-buffer))))

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
      ;; returns its property branch's value outright. The engine's
      ;; `text-editor-set-cursor' answers something else entirely.
      ;;--------------------------------------------------------------
      (let ((at (cond
                 ((marker-type? position) (marker-position position))
                 (else position))))
        (text-editor-set-cursor (current-buffer) (- at 1))
        at))

    (define (insert . args)
      ;; GNU Emacs's `insert' (editfns.c:1354): "Insert the arguments,
      ;; either strings or characters, at point. Point and
      ;; after-insertion markers move forward to end up after the
      ;; inserted text." The engine's `text-editor-insert' takes one
      ;; character or one string, so each argument is inserted in
      ;; turn; `general_insert_function', which the C's is, does the
      ;; same loop.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (for-each
         (lambda (arg)
           (cond
            ((string? arg)
             ;; `general_insert_function' hands a string to
             ;; `insert_from_string', which is `insert_from_string_1':
             ;; the text goes in, and then the properties it *carries*
             ;; are grafted in after it (`graft_intervals_into_buffer'
             ;; with the string's own tree, and `inherit' false).
             (let ((at (text-editor-get-cursor ed)))
               (text-editor-insert ed arg)
               (graft-intervals-into-buffer (string-intervals arg) at
                                            (string-length arg) ed #f)))
            ((char? arg) (text-editor-insert ed arg))
            ((integer? arg) (text-editor-insert ed (integer->char arg)))
            (else (error "Wrong type argument" arg))))
         args)
        #f))

    (define (bobp)
      ;; GNU Emacs's `bobp' (editfns.c): "Return t if point is at the
      ;; beginning of the buffer."
      ;;--------------------------------------------------------------
      (= (text-editor-get-cursor (current-buffer)) 0))

    (define (eobp)
      ;; GNU Emacs's `eobp' (editfns.c): "Return t if point is at the
      ;; end of the buffer."
      ;;--------------------------------------------------------------
      (= (text-editor-get-cursor (current-buffer))
         (text-editor-char-count (current-buffer))))

    (define (bolp)
      ;; GNU Emacs's `bolp' (editfns.c): "Return t if point is at the
      ;; beginning of a line."
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (or (= (text-editor-get-cursor ed) 0)
            (eqv? (text-editor-get-char-index ed (- (text-editor-get-cursor ed) 1))
                  #\newline))))

    (define (eolp)
      ;; GNU Emacs's `eolp' (editfns.c): "Return t if point is at the
      ;; end of a line. `End of a line' includes point being at the end
      ;; of the buffer."
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (= (text-editor-get-cursor ed)
           (text-editor-get-end-of-line ed))))

    (define (%char-at-index ed index)
      ;; The character at the ENGINE index INDEX, or #f - the reader
      ;; the C's `FETCH_BYTE' is here.
      ;;--------------------------------------------------------------
      (text-editor-get-char-index ed index))

    (define (char-after position)
      ;; GNU Emacs's `char-after' (editfns.c): "Return character in
      ;; current buffer at position POSITION" - nil, this tree's #f,
      ;; when POSITION is past the end. A POSITION of nil means point,
      ;; as Emacs's docstring keeps out of the synopsis; the one-based
      ;; position becomes the engine's zero-based index here.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (count (text-editor-char-count ed))
             (index (- (if position position (point)) 1)))
        (and (>= index 0) (< index count)
             (%char-at-index ed index))))

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
             (count (text-editor-char-count ed))
             (index (- (if position position (point)) 1)))
        (and (> index 0)
             (<= index count)
             (%char-at-index ed (- index 1)))))

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

    (define (line-beginning-position . rest)
      ;; GNU Emacs's `line-beginning-position' (editfns.c): "Return the
      ;; character position of the beginning of the current line. With
      ;; argument N, forward N lines first" - the N-line walk being
      ;; `line-move''s, which is `save-excursion''s to keep point off.
      ;; The answer is one-based, as every position answer here is.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             ;; an optional argument explicitly given as nil - Elisp's
             ;; `(line-beginning-position (and arg 2))' with ARG nil -
             ;; behaves as absent, as it does in Emacs
             ;;
             ;; The absent value is 1, which is the C's `count = 1'
             ;; (`Fline_beginning_position', editfns.c:727) and not 0:
             ;; `(forward-line (- n 1))' below is then `(forward-line 0)',
             ;; no move at all. With a 0 here it was `(forward-line -1)',
             ;; so every call without an N answered the *previous* line's
             ;; beginning - measured, `emacs -Q --batch' answers 5 for
             ;; position 5 of "aaa\nbbb\nccc\n" and this answered 1.
             (n (if (and (pair? rest) (car rest)) (car rest) 1)))
        (save-excursion
          ;; "With argument N not nil or 1, move forward N - 1 lines
          ;; first" - so N moves N - 1, and the binding above has already
          ;; turned an absent N into 1, which is no move. The line
          ;; arithmetic that used to be here added
          ;; `text-editor-cursor-line' - a *line number* - to N and passed
          ;; the sum as a *character position* to `text-editor-set-cursor',
          ;; so every line but the first answered the first line's
          ;; boundary.
          (forward-line (- n 1))
          (+ 1 (text-editor-get-start-of-line ed)))))

    (define (line-end-position . rest)
      ;; GNU Emacs's `line-end-position' (editfns.c): "Return the
      ;; character position of the end of the current line" - with a N,
      ;; of the end of the line N lines away. One-based, as
      ;; `line-beginning-position' is.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             ;; "N not nil or 1" - an absent N is 1, which moves no
             ;; lines; see the note below.
             (n (if (and (pair? rest) (car rest)) (car rest) 1)))
        (save-excursion
          ;; `forward-line' and then the line's end - the C's shape, and
          ;; N - 1 lines as `line-beginning-position' explains.
          (forward-line (- n 1))
          (+ 1 (text-editor-get-end-of-line ed)))))

    (define (buffer-substring beg end)
      ;; GNU Emacs's `buffer-substring' (editfns.c): "Return the contents
      ;; of part of the current buffer, as a string" - the engine's copy,
      ;; and then the properties of that range, which is the C's
      ;; `copy_intervals_to_string'.
      ;;
      ;; The one-based positions are this layer's and the tree's are
      ;; zero-based, which is the conversion every answer here makes.
      ;;--------------------------------------------------------------
      (let ((result (text-editor-copy-string (current-buffer)
                                             (- beg 1) (- end 1))))
        ;; The C's `copy_intervals_to_string (result, current_buffer,
        ;; start, end - start)': the fourth argument is a *length*, not
        ;; an end position, and passing the end position walks the tree
        ;; off its last interval.
        (copy-intervals-to-string result (current-buffer)
                                  (- beg 1) (- end beg))
        result))

    (define (buffer-substring-no-properties beg end)
      ;; GNU Emacs's `buffer-substring-no-properties': "Return the
      ;; characters of part of the current buffer, without text
      ;; properties."
      ;;--------------------------------------------------------------
      (text-editor-copy-string (current-buffer) (- beg 1) (- end 1)))

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
      (text-editor-char-count (current-buffer)))

    (define (buffer-string)
      ;; GNU Emacs's `buffer-string' (editfns.c): "Return the contents
      ;; of the current buffer as a string."
      ;;--------------------------------------------------------------
      (buffer-substring (point-min) (point-max)))

    (define (delete-and-extract-region beg end)
      ;; GNU Emacs's `delete-and-extract-region' (editfns.c): "Delete
      ;; the text between START and END and return it" - `transpose-
      ;; subr-1' is what uses it. The positions are one-based here and
      ;; converted for the engine's delete, as everywhere in this
      ;; library.
      ;;--------------------------------------------------------------
      (let ((text (buffer-substring beg end)))
        (delete-region (- beg 1) (- end 1))
        text))

    (define (barf-if-buffer-read-only . rest)
      ;; GNU Emacs's `barf-if-buffer-read-only' (buffer.c:2453): "Signal a
      ;; `buffer-read-only' error if the current buffer is read-only. If
      ;; the text under POSITION (which defaults to point) has the
      ;; `inhibit-read-only' text property set, the error will not be
      ;; raised."
      ;;
      ;; The C's test is three parts: the buffer is read-only, *and*
      ;; `inhibit-read-only' is nil - the global a command let-binds to
      ;; write into a read-only buffer - *and* the text property is nil
      ;; where the change is.
      ;;
      ;; The message is the error's text here, there being no condition
      ;; symbols yet.
      ;;
      ;; Not ported: the `read-only' *text* property, which makes a piece
      ;; of an otherwise writable buffer read-only. Nothing consults it
      ;; yet, and the engine's insert and delete do not know about text
      ;; properties at all.
      ;;--------------------------------------------------------------
      (when (and (text-editor-read-only? (current-buffer))
                 (not (*inhibit-read-only*))
                 (not (get-text-property
                       (if (pair? rest) (car rest) (point))
                       'inhibit-read-only)))
        (error "Buffer is read-only")))

    (define (forward-line . rest)
      ;; GNU Emacs's `forward-line' (simple.el via the C's
      ;; `FORWARD_LINE'): "Move N lines forward (backwards if N is
      ;; negative)." To the START of each line, not keeping the column
      ;; - which is what distinguishes it from `next-line' - and it
      ;; answers the count of lines it could NOT move, negative for a
      ;; backward request that was cut short. `paragraphs.sld''s walks
      ;; were spelling this privately.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (n (if (pair? rest) (car rest) 1))
             (moved
              (let loop ((left (abs n)) (moved 0))
                (cond
                 ((= left 0) moved)
                 ((> n 0)
                  (let ((eol (text-editor-get-end-of-line ed))
                        (count (text-editor-char-count ed)))
                    (if (< eol count)
                        (begin
                          (text-editor-set-cursor ed (+ eol 1))
                          (loop (- left 1) moved))
                        moved)))
                 (else
                  (let ((start (text-editor-get-start-of-line ed)))
                    (if (> start 0)
                        (begin
                          (text-editor-set-cursor ed (- start 1))
                          (text-editor-set-cursor
                           ed (text-editor-get-start-of-line ed))
                          (loop (- left 1) moved))
                        moved)))))))
        (if (< n 0) (- moved) moved)))

(define (point-marker)
      ;; GNU Emacs's `point-marker' (editfns.c): "Return value of point
      ;; as a marker object" - the bookkeeping `save-excursion''s
      ;; `save_excursion_save' does.
      ;;--------------------------------------------------------------
      (copy-marker (current-buffer)
                   (text-editor-get-cursor (current-buffer))))

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
         (let ((marker (copy-marker (current-buffer)
                                    (text-editor-get-cursor
                                     (current-buffer))))
               (saved-buffer (current-buffer)))
           (dynamic-wind
             (lambda () #f)
             (lambda () body ...)
             (lambda ()
               (set-buffer saved-buffer)
               ;; `Fgoto_char (marker)' - where the marker ended up
               ;; after BODY's edits, unchained once read
               (text-editor-set-cursor
                saved-buffer (marker-position marker))
               (set-marker! marker #f)))))))

    ))
