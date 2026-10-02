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
    (only (schemacs editor buffer) current-buffer set-buffer
          *case-fold-search*)
    (only (schemacs editor engine)
          copy-marker marker-position set-marker!
          text-editor-char-count text-editor-insert
          text-editor-cursor-line text-editor-delete-from-cursor
          text-editor-get-cursor text-editor-get-line-column
          text-editor-mark text-editor-set-cursor)
    ;; `mark-active' and `transient-mark-mode' are `buffer.c''s
    ;; variables, and `mark-even-if-inactive' is `callint.c''s, which is
    ;; where `region_limit' reads them from - the same three the C's
    ;; `region_limit' reads.
    (only (schemacs editor buffer)
          mark-active transient-mark-mode)
    (only (schemacs editor command)
          *mark-even-if-inactive*)
    (only (schemacs ui text-buffer-impl) text-location-line)
    (only (schemacs editor frame) current-editor)
    )

  (export
   bobp
   delete-region
   eobp
   goto-char
   insert
   line-number-at-pos
   point-max
   point-min
   point
   save-excursion
   search-forward
   search-backward
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
      (let ((m (text-editor-mark (current-editor))))
        (unless m (error "The mark is not set now, so there is no region"))
        (let ((point (text-editor-get-cursor (current-editor))))
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
      (let ((ed (current-editor)))
        (when (> start end)
          (let ((swap start)) (set! start end) (set! end swap)))
        (text-editor-set-cursor ed start)
        (text-editor-delete-from-cursor ed (- end start))))

    (define (region-beginning)
      ;; GNU Emacs's `region-beginning': "the integer value of point or
      ;; mark, whichever is smaller".
      ;;--------------------------------------------------------------
      (region-limit #t))

    (define (region-end)
      ;; GNU Emacs's `region-end': "the integer value of point or mark,
      ;; whichever is larger".
      ;;--------------------------------------------------------------
      (region-limit #f))


    (define (line-number-at-pos . args)
      ;; GNU Emacs's `line-number-at-pos' (`editfns.c'): "Return current
      ;; line number in the current buffer", counting from 1 at
      ;; `point-min'. With a POSITION, the line that position is on.
      ;; Emacs's also narrows-independent `what-line' does its own count
      ;; with the narrowing kept; nothing is narrowed here.
      ;;--------------------------------------------------------------
      (let ((ed (current-editor)))
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
      (+ 1 (text-editor-get-cursor (current-editor))))

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
      (+ 1 (text-editor-char-count (current-editor))))

    (define (goto-char position)
      ;; GNU Emacs's `goto-char' (editfns.c): "Set point to POSITION,
      ;; a number or marker."
      ;;--------------------------------------------------------------
      (text-editor-set-cursor (current-editor) (- position 1)))

    (define (search-forward string . args)
      ;; GNU Emacs's `search-forward' (`search.c', which the engine
      ;; carries): "Search forward from point for STRING. Set point to
      ;; the end of the occurrence found, and return point." BOUND
      ;; limits the search, NOERROR keeps a failed search from
      ;; signalling, COUNT - which is what `zap-to-char''s ARGth
      ;; occurrence passes - finds the COUNTth match. The case folding
      ;; is `case-fold-search''s, which the caller may override: the
      ;; optional fourth argument is this tree's, for the
      ;; upper-case-char rule `zap-to-char' applies.
      ;;--------------------------------------------------------------
      (let* ((ed (current-editor))
             (bound (if (pair? args) (car args) #f))
             (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
             (count (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args)
                        1))
             (fold (if (and (pair? args) (pair? (cdr args))
                            (pair? (cddr args)) (pair? (cdddr args)))
                       (cadddr args)
                       (*case-fold-search*)))
             (limit (or bound (text-editor-char-count ed))))
        (let loop ((left (max 1 count)) (from (text-editor-get-cursor ed)))
          (let ((found (text-editor-search-forward
                        ed string (min from limit) fold)))
            (cond
             ((not found)
              (if noerror
                  #f
                  (error "Search failed" string)))
             ((> found limit)
              (if noerror #f (error "Search failed" string)))
             ((> left 1) (loop (- left 1) found))
             (else
              (text-editor-set-cursor ed found)
              (+ 1 found)))))))

    (define (search-backward string . args)
      ;; GNU Emacs's `search-backward' (`search.c'): the backward mirror
      ;; of `search-forward', which answers the START of the match.
      ;;--------------------------------------------------------------
      (let* ((ed (current-editor))
             (bound (if (pair? args) (car args) #f))
             (noerror (and (pair? args) (pair? (cdr args)) (cadr args)))
             (count (if (and (pair? args) (pair? (cdr args))
                             (pair? (cddr args)))
                        (caddr args)
                        1))
             (fold (if (and (pair? args) (pair? (cdr args))
                            (pair? (cddr args)) (pair? (cdddr args)))
                       (cadddr args)
                       (*case-fold-search*)))
             (limit (or bound 0)))
        (let loop ((left (max 1 count)) (from (text-editor-get-cursor ed)))
          (let ((found (text-editor-search-backward
                        ed string (max from limit) fold)))
            (cond
             ((not found)
              (if noerror #f (error "Search failed" string)))
             ((< found limit)
              (if noerror #f (error "Search failed" string)))
             ((> left 1) (loop (- left 1) found))
             (else
              (text-editor-set-cursor ed found)
              found))))))

    (define (insert . args)
      ;; GNU Emacs's `insert' (editfns.c:1354): "Insert the arguments,
      ;; either strings or characters, at point. Point and
      ;; after-insertion markers move forward to end up after the
      ;; inserted text." The engine's `text-editor-insert' takes one
      ;; character or one string, so each argument is inserted in
      ;; turn; `general_insert_function', which the C's is, does the
      ;; same loop.
      ;;--------------------------------------------------------------
      (let ((ed (current-editor)))
        (for-each
         (lambda (arg)
           (cond ((string? arg) (text-editor-insert ed arg))
                 ((char? arg) (text-editor-insert ed arg))
                 ((integer? arg) (text-editor-insert ed (integer->char arg)))
                 (else (error "Wrong type argument" arg))))
         args)
        #f))

    (define (bobp)
      ;; GNU Emacs's `bobp' (editfns.c): "Return t if point is at the
      ;; beginning of the buffer."
      ;;--------------------------------------------------------------
      (= (text-editor-get-cursor (current-editor)) 0))

    (define (eobp)
      ;; GNU Emacs's `eobp' (editfns.c): "Return t if point is at the
      ;; end of the buffer."
      ;;--------------------------------------------------------------
      (= (text-editor-get-cursor (current-editor))
         (text-editor-char-count (current-editor))))

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
                                     (current-editor))))
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
