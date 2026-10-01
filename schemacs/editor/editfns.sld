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
    (only (schemacs editor engine)
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
   delete-region
   line-number-at-pos
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
    ))
