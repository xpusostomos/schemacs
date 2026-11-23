(define-library (schemacs editor indent)
  ;; This library mirrors GNU Emacs's `lisp/indent.el': the commands that
  ;; indent text.
  ;;
  ;; The name is `indent' and not `indentc' because Emacs has *both*
  ;; `src/indent.c' and `lisp/indent.el', which would want the same file
  ;; name here; the elisp half keeps the plain one, as `dired.sld' keeps
  ;; it against `diredc.sld'. The C half - `current-column',
  ;; `indent-to`, `indent-tabs-mode` - is `(schemacs editor indentc)`.
  ;;
  ;; What is here: `indent-rigidly' (which `dired-insert-directory'
  ;; needs), and the rest of the file's non-interactive core -
  ;; `indent-line-to`, `indent-according-to-mode`, `indent-region' and
  ;; its two helpers, and the `indent-relative`/`tab-to-tab-stop` pair.
  ;; `current-indentation` and `indent-to` are `indent.c`'s and are in
  ;; `indentc.sld` with the rest of the column arithmetic.
  ;;
  ;; Not ported: `indent-for-tab-command` and the tab-stop *editing*
  ;; commands (`edit-tab-stops` and its map), the whole of the
  ;; interactive `indent-rigidly` map (`indent-rigidly-left' and its
  ;; siblings, a transient-map feature this display does not have), the
  ;; left-margin family (`current-left-margin`, `move-to-left-margin`,
  ;; `indent-to-left-margin` - they need `left-margin` and
  ;; `indent-to-left-margin` is for `indented-text-mode`), and the
  ;; `fill-prefix` arm of `indent-region` (no `fill.el`).

  (import
    (scheme base)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          ;; `left-margin`, the buffer-local the two margin functions
          ;; below are about (`indent.el:70')
          buffer-left-margin)
    ;; `current-left-margin` reads the `left-margin` text property at the
    ;; start of the line (`indent.el:63`)
    (only (schemacs editor textprop) get-text-property)
    ;; `define-custom` (`custom.el') - `*fill-prefix*` below is a
    ;; defcustom and is spelled the way this tree spells one
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor character) *tab-width*)
    (only (schemacs editor cmds) beginning-of-line backward-char)
    (only (schemacs editor command)
          current-prefix-arg define-command prefix-numeric-value uarg->integer)
    (only (schemacs editor editfns)
          bobp bolp delete-region eobp eolp forward-line goto-char
          insert insert-char
          point point-marker
          region-beginning region-end line-end-position save-excursion
          ;; `indent-according-to-mode` widens first, so that indenting a
          ;; line in a narrowed buffer sees the text outside it.
          save-restriction widen)
    (only (schemacs editor marker) copy-marker marker-position set-marker)
    (only (schemacs editor indentc)
          *indent-tabs-mode*
          current-column current-indentation indent-to move-to-column)
    (only (schemacs editor search) looking-at regexp-quote
          re-search-backward)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor keymap) define-key)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor syntax)
          backward-prefix-chars skip-chars-forward skip-chars-backward
          skip-syntax-forward syntax-propertize)
    )

  (export
   indent-rigidly
   indent-line-function indent-line-ignored-functions
   indent-according-to-mode indent-line-to
   indent-region-function indent-region indent-region-line-by-line
   back-to-indentation current-left-margin move-to-left-margin
   indent-to-left-margin *fill-prefix*
   indent-relative indent-relative-first-indent-point indent-relative-maybe
   indent-next-tab-stop tab-to-tab-stop tab-stop-list
   insert-tab
   *delete-horizontal-space-function*
   )

  (begin

    ;; ---------------------------------------------------------------
    ;; `indent-line-function' (`indent.el:39'), and the two functions
    ;; that read it.
    ;;--------------------------------------------------------------
    (define (indent-line-function)
      ;; GNU Emacs's `indent-line-function' (`indent.el:39'): "Function
      ;; to indent the current line. ... The default value is
      ;; `indent-relative'." A mode puts its own in; here it is the
      ;; *procedure*, because a symbol is not callable in Scheme.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'indent-line-function
                          indent-relative))

    (define (indent-line-ignored-functions)
      ;; `indent-line-ignored-functions' (`indent.el:87'): "Values that
      ;; are ignored by `indent-according-to-mode'."
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'indent-line-ignored-functions
                          (list indent-relative indent-relative-maybe
                                indent-relative-first-indent-point)))

    (define-command (indent-according-to-mode . rest)
      "Indent line in proper way for current major mode.
Normally, this is done by calling the function specified by the
variable `indent-line-function'.  However, if the value of that
variable is present in the `indent-line-ignored-functions' variable,
handle it specially (since those functions are used for tabbing);
in that case, indent by aligning to the previous non-blank line.

Ignore restriction, unless the optional argument INHIBIT-WIDEN is
non-nil."
      (interactive (list (current-prefix-arg)))
      ;; **The whole body is narrowed off first**: "Ignore restriction,
      ;; unless the optional argument INHIBIT-WIDEN is non-nil"
      ;; (`indent.el`): `(save-restriction (unless inhibit-widen
      ;; (widen)) ...)` - so indenting a line in a narrowed buffer sees
      ;; the text outside the restriction.
      (save-restriction
        ;; `(&optional inhibit-widen)` in Emacs, and a caller here passes
        ;; nothing - `indent-according-to-mode` is called from
        ;; `indent-for-tab-command` and from modes.
        (unless (and (pair? rest) (car rest)) (widen))
        (syntax-propertize (line-end-position))
        (let ((fn (indent-line-function)))
          (if (memq fn (indent-line-ignored-functions))
              ;; These functions are used for tabbing, but can't be used
              ;; for indenting.  Replace with something ad-hoc.
              (let ((column (save-excursion
                              (beginning-of-line)
                              (if (bobp)
                                  0
                                  (begin
                                    (beginning-of-line 0)
                                    (if (looking-at "[ \t]*$")
                                        0
                                        (current-indentation)))))))
                (if (<= (current-column) (current-indentation))
                    (indent-line-to column)
                    (save-excursion (indent-line-to column))))
              ;; The normal case.
              (fn)))))

    (define-command (insert-tab . rest)
      ;; GNU Emacs's `insert-tab' (`indent.el:215'), which cc-mode's
      ;; `c-insert-tab-function' names as its default. It sits here
      ;; rather than beside `indent-rigidly` because
      ;; `indent--default-inside-comment`, `indent-for-tab-command` and
      ;; `indent--funcall-widened` - the three functions Emacs has
      ;; between `indent-according-to-mode` and it - are not ported.
      ;;
      ;; **One departure**: `(and abbrev-mode ... (expand-abbrev))` is
      ;; dropped, because `abbrev.el` is not ported and `abbrev-mode` is
      ;; unbound here; Emacs's branch is a no-op in a tree with no
      ;; abbrevs.
      "Insert a tab character.
If `indent-tabs-mode' is nil, insert spaces instead of a tab, up to the
next tab stop."
      (interactive "P")
      (let ((count (prefix-numeric-value (if (pair? rest) (car rest) #f))))
        (if (*indent-tabs-mode*)
            (insert-char #\tab count)
            (indent-to (* *tab-width*
                          (+ count (/ (current-column) (*tab-width*))))))))

    (define-command (indent-rigidly start end arg)
      "Indent all lines starting in the region forward by ARG columns.
If called from a program, START and END specify the beginning and end
of the text to act on, in place of the region. Negative values of ARG
indent backward, so you can remove all indentation by specifying a
large negative ARG."
      (interactive (list (point) (point) (current-prefix-arg)))
      (let ((end-marker #f))
        (save-excursion
          (goto-char end)
          (set! end-marker (point-marker))
          (goto-char start)
          ;; "Indent all lines *starting* in the region", so a region that
          ;; begins part-way down a line leaves that line alone.
          (if (not (bolp)) (forward-line 1))
          ;; `(marker-position end-marker)' and not the marker itself:
          ;; Emacs compares a position with a marker directly - its
          ;; arithmetic converts one - and this tree's does not.
          (let loop ()
            (when (< (point) (marker-position end-marker))
              (let ((indent (current-indentation))
                    (eol-flag #f))
                (save-excursion
                  (skip-chars-forward " \t")
                  (set! eol-flag (eolp)))
                (if (not eol-flag)
                    (indent-to (max 0 (+ indent arg)) 0))
                ;; Emacs's `(delete-region (point) (progn
                ;; (skip-chars-forward " \t") (point)))' - the indentation
                ;; just inserted stays, and the run that was there goes.
                ;; These two carried a `(- ... 1)' each until 2026-10-06,
                ;; from the note in `editfns.sld' that `delete-region'
                ;; took engine positions. It does not, and never did after
                ;; the one-based conversion; the shift was benign only
                ;; because `indent-to' above had moved point to the far
                ;; side of the run.
                (delete-region (point)
                               (save-excursion
                                 (skip-chars-forward " \t")
                                 (point))))
              (forward-line 1)
              (loop)))
          (set-marker end-marker #f))))

    (define *delete-horizontal-space-function* (make-parameter #f))
    ;; ^ `delete-horizontal-space' is `simple.el`'s, and `simple.scm` is
    ;; above this library - it holds `newline-and-indent`, which calls
    ;; `indent-according-to-mode`. `tab-to-tab-stop` is the one caller
    ;; here, and it arrives through this seam, which `simple.scm` fills
    ;; at load time. (The C has no such problem: `tab-to-tab-stop` and
    ;; `delete-horizontal-space` are in the same dump.)
    (define (indent-line-to column)
      ;; GNU Emacs's `indent-line-to' (`indent.el:331'): "Indent current
      ;; line to COLUMN. This function removes or adds spaces and tabs at
      ;; beginning of line only if necessary. It leaves point at end of
      ;; indentation."
      ;;--------------------------------------------------------------
      (beginning-of-line 1)
      (skip-chars-forward " \t")
      (let ((cur-col (current-column)))
        (cond ((< cur-col column)
               (if (>= (- column (* (quotient cur-col (*tab-width*))
                                    (*tab-width*)))
                       (*tab-width*))
                   (delete-region (point)
                                  (save-excursion (skip-chars-backward " ")
                                                  (point))))
               (indent-to column))
              ((> cur-col column)              ; too far right (after tab?)
               (delete-region (save-excursion (move-to-column column #t)
                                              (point))
                              ;; "The `move-to-column' call may replace tabs
                              ;; with spaces, so we can't reuse the previous
                              ;; start point."
                              (save-excursion
                                (beginning-of-line 1)
                                (skip-chars-forward " \t")
                                (point)))))))

    (define-custom *fill-prefix* #f
      "String to insert at beginning of each line of a paragraph.
Used when filling paragraphs by `fill-paragraph' and friends.
If you change this without using \\[set-fill-prefix], it is not
automatically cleared."
      :type '(choice (const :tag "None" nil) string)
      :group 'fill)
    ;; ^ GNU Emacs's `fill-prefix' (`fill.el:55') - a defcustom that
    ;; `fill-region-as-paragraph-default' let-binds around a paragraph, so
    ;; it is a parameter here.
    ;;
    ;; **Placement departure**: `fill.el`'s, and it lives in
    ;; `indent.scm`. Three libraries read it - `indent-region`'s first
    ;; branch (`indent.el:552`), `forward-paragraph` (`paragraphs.el:229`)
    ;; and `beginning-of-line-text` (`indent.el:531`) - and the C's graph
    ;; would need `paragraphs.scm` to import `indent.scm` (it does, for
    ;; the margins) *and* `indent.scm` to import `paragraphs.scm` (for
    ;; this), which a DAG cannot hold. `indent.scm` is the lowest of the
    ;; three, so the variable comes down to it, as `*minor-mode-alist*`
    ;; came down to `subr.scm`.

    (define-command (back-to-indentation)
      ;; GNU Emacs's `back-to-indentation' (`simple.el:7093'): "Move point
      ;; to the first non-whitespace character on this line."
      ;;
      ;; **`simple.el`'s, and it moved down here** because
      ;; `current-left-margin` below is `indent.el`'s first caller and
      ;; `indent.scm` sits *below* `simple.scm` - the same downward move
      ;; `beginning-of-line` took into `cmds.scm`. `simple.scm` imports
      ;; and re-exports it, so `M-x` and every caller reach it where Emacs
      ;; has it.
      ;;--------------------------------------------------------------
      "Move point to the first non-whitespace character on this line."
      (interactive '())
      (beginning-of-line 1)
      (skip-syntax-forward " " (line-end-position))
      ;; "Move back over chars that have whitespace syntax but have the p
      ;; flag."
      (backward-prefix-chars))

    (define (current-left-margin)
      ;; GNU Emacs's `current-left-margin' (`indent.el:52'): "Return the
      ;; left margin to use for this line. This is the value of the
      ;; buffer-local variable `left-margin' plus the value of the
      ;; `left-margin' text-property at the start of the line."
      ;;
      ;; The C's `(if (and (eobp) (not (bobp))) (1- (point)) (point))'
      ;; is the position the property is read at: at end of buffer the
      ;; property is the one on the last character, because there is no
      ;; character at point.
      ;;--------------------------------------------------------------
      (save-excursion
        (back-to-indentation)
        (max 0
             (+ (buffer-left-margin (current-buffer))
                (or (get-text-property
                     (if (and (eobp) (not (bobp)))
                         (- (point) 1)
                         (point))
                     'left-margin)
                    0)))))

    (define (move-to-left-margin . args)
      ;; GNU Emacs's `move-to-left-margin' (`indent.el:70'): "Move to the
      ;; left margin of the current line. With optional argument, move
      ;; forward N-1 lines first. The column moved to is the one given by
      ;; the `current-left-margin' function. If the line's indentation
      ;; appears to be wrong, and this command is called interactively or
      ;; with optional argument FORCE, it will be fixed."
      ;;
      ;; **Not carried: the `minibufferp` branch.** Emacs sends the
      ;; minibuffer either to the prompt end or to the line beginning, so
      ;; that a margin never eats the prompt. This tree's prompt is buffer
      ;; text and `beginning-of-line` already constrains to the prompt's
      ;; `field` (2026-11-15), which is what that branch was for;
      ;; `fill-minibuffer-function` narrows to the prompt end before it
      ;; fills, so the margin below is measured inside the input.
      ;;--------------------------------------------------------------
      (let ((n (and (pair? args) (car args)))
            (force (and (pair? args) (pair? (cdr args)) (cadr args))))
        (let ((n (if n n 1))
              (force (if force #t #f)))
          (beginning-of-line n)
          (skip-chars-forward " \t")
          (let ((lm (current-left-margin))
                (cc (current-column)))
            (cond ((> cc lm)
                   (if (> (move-to-column lm force) lm)
                       ;; "If lm is in a tab and we are not forcing, move
                       ;; before tab"
                       (backward-char 1)))
                  ((and force (< cc lm))
                   (indent-to-left-margin))))
            #f)))

    (define (indent-to-left-margin)
      ;; GNU Emacs's `indent-to-left-margin' (`indent.el:101'): "Indent
      ;; current line to the column given by `current-left-margin'." The
      ;; second half moves point past the indentation when point is
      ;; inside it.
      ;;--------------------------------------------------------------
      (save-excursion (indent-line-to (current-left-margin)))
      (if (save-excursion
            (skip-chars-backward " \t")
            (bolp))
          (skip-chars-forward " \t"))
      #f)

    (define (indent-region-function)
      ;; `indent-region-function' (`indent.el:546'): "Short cut function
      ;; to indent region using `indent-according-to-mode'."
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'indent-region-function #f))

    (define-command (indent-region start end . rest)
      "Indent each nonblank line in the region.
A numeric prefix argument specifies a column: indent each line to that column.

With no prefix argument, the command chooses one of these methods and
indents all the lines with it:

  1) If `fill-prefix' is non-nil, insert `fill-prefix' at the
     beginning of each line in the region that does not already begin
     with it.
  2) If `indent-region-function' is non-nil, call that function
     to indent the region.
  3) Indent each line via `indent-according-to-mode'.

Called from a program, START and END specify the region to indent.
If the third argument COLUMN is an integer, it specifies the
column to indent to; if it is nil, use one of the three methods above."
      ;; `(interactive "r\nP")' (`indent.el:567') - the region, then the
      ;; raw prefix, with the newline separating the two codes.
      (interactive "r\nP")
      (let ((column (if (pair? rest) (car rest) #f)))
        (cond
         ;; If a numeric prefix is given, indent to that column.
         (column
          (let ((column (uarg->integer 1 column)))
            (save-excursion
              (goto-char end)
              (let ((end (point-marker)))
                (goto-char start)
                (or (bolp) (forward-line 1))
                (let loop ()
                  (when (< (point) (marker-position end))
                    (delete-region (point)
                                   (save-excursion (skip-chars-forward " \t")
                                                   (point)))
                    (or (eolp) (indent-to column 0))
                    (forward-line 1)
                    (loop)))
                (set-marker end #f)))))
         ;; "If a fill-prefix is specified, use it." - insert it on every
         ;; line that does not already begin with it, and leave a blank
         ;; line alone.
         ((*fill-prefix*)
          (save-excursion
            (goto-char end)
            (let ((end (point-marker))
                  (regexp (regexp-quote (*fill-prefix*))))
              (goto-char start)
              (let loop ()
                (when (< (point) (marker-position end))
                  (or (looking-at regexp)
                      (and (bolp) (eolp))
                      (insert (*fill-prefix*)))
                  (forward-line 1)
                  (loop)))
              (set-marker end #f))))
         ;;
         ;; Use `indent-region-function' if available. The C's
         ;; `save-restriction'/'widen' have nothing to do here.
         ((indent-region-function)
          ((indent-region-function) start end))
         ;; Else, use a default implementation that calls
         ;; `indent-line-function' on each line.
         (else (indent-region-line-by-line start end)))
        ;; "In most cases, reindenting modifies the buffer, but it may
        ;; also leave it unmodified, in which case we have to deactivate
        ;; the mark by hand." - `deactivate-mark' is a *variable* in
        ;; Emacs and the command loop reads it here.
        (set-buffer-local-value! (current-buffer) 'deactivate-mark #t)
        #t))

    (define (indent-region-line-by-line start end)
      ;; GNU Emacs's `indent-region-line-by-line' (`indent.el:611').
      ;; The C's `make-progress-reporter' is not here (there is no
      ;; progress reporter), and neither is its `widen'.
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((end (copy-marker end)))
          (goto-char start)
          (let loop ()
            ;; "Emacs compares a position with a marker directly - its
            ;; arithmetic converts one - and this tree's does not."
            (when (< (point) (marker-position end))
              (or (and (bolp) (eolp))
                  (indent-according-to-mode #t))
              (forward-line 1)
              (loop)))
          (set-marker end #f))))

    (define-command (indent-relative-first-indent-point)
      "Indent the current line like the previous nonblank line.
Indent to the first indentation position in the previous nonblank
line if that position is greater than the current column.

See also `indent-relative'."
      (interactive '())
      (indent-relative #t))

    (define (indent-relative-maybe)
      ;; `(define-obsolete-function-alias 'indent-relative-maybe
      ;; 'indent-relative-first-indent-point "26.1")' (`indent.el:626').
      ;;--------------------------------------------------------------
      (indent-relative-first-indent-point))

    (define-command (indent-relative . rest)
      "Space out to under next indent point in previous nonblank line.
An indent point is a non-whitespace character following whitespace.
The following line shows the indentation points in this line.
    ^         ^    ^     ^   ^           ^      ^  ^    ^
If FIRST-ONLY is non-nil, then only the first indent point is
considered.

If the previous nonblank line has no indent points beyond the
column point starts at, then `tab-to-tab-stop' is done, if both
FIRST-ONLY and UNINDENTED-OK are nil, otherwise nothing is done.
If there isn't a previous nonblank line and UNINDENTED-OK is nil,
call `tab-to-tab-stop'.

See also `indent-relative-first-indent-point'."
      (interactive (list (current-prefix-arg)))
      (let ((first-only (if (pair? rest) (car rest) #f))
            (unindented-ok (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        ;; The C opens with `(and abbrev-mode (eq (char-syntax
        ;; (preceding-char)) ?w) (expand-abbrev))'; `abbrev.el' is not
        ;; ported, so there is no abbrev to expand.
        (let ((start-column (current-column))
              (indent #f))
          (save-excursion
            (beginning-of-line)
            (if (re-search-backward "^[^\n]" #f #t)
                (let ((end (save-excursion (forward-line 1) (point))))
                  (move-to-column start-column)
                  ;; Is start-column inside a tab on this line?
                  (if (> (current-column) start-column)
                      (backward-char 1))
                  (or (looking-at "[ \t]")
                      first-only
                      (skip-chars-forward "^ \t" end))
                  (skip-chars-forward " \t" end)
                  (or (= (point) end) (set! indent (current-column))))))
          (cond (indent
                 (let ((opoint (point-marker)))
                   (indent-to indent 0)
                   (if (> (marker-position opoint) (point))
                       (goto-char (marker-position opoint)))
                   (set-marker opoint #f)))
                (unindented-ok #f)
                (else (tab-to-tab-stop))))))

    (define (indent-next-tab-stop column . rest)
      ;; GNU Emacs's `indent-next-tab-stop' (`indent.el:748'): "Return
      ;; the next tab stop after COLUMN. If PREV is non-nil, return the
      ;; previous one instead."
      ;;--------------------------------------------------------------
      (let ((prev (and (pair? rest) (car rest)))
            (tabs (tab-stop-list)))
        (let loop ((tabs tabs))
          (cond
           ((and (pair? tabs) (>= column (car tabs)))
            (loop (cdr tabs)))
           ((pair? tabs)
            (if (not prev)
                (car tabs)
                (let ((prevtabs (cdr (memq (car tabs)
                                           (reverse (tab-stop-list))))))
                  (if (null? prevtabs)
                      0
                      (if (= column (car prevtabs))
                          (or (and (pair? (cdr prevtabs)) (cadr prevtabs)) 0)
                          (car prevtabs))))))
           (else
            ;; "We passed the end of tab-stop-list: guess a continuation."
            (let* ((rev (reverse (tab-stop-list)))
                   ;; `(last TAB-STOP-LIST 2)': the last two elements.
                   (last2 (if (pair? (cdr rev))
                              (list (cadr rev) (car rev))
                              rev))
                   (step (if (pair? (cdr last2))
                             (- (cadr last2) (car last2))
                             (*tab-width*)))
                   (last (if (pair? (cdr last2))
                             (cadr last2)
                             (if (pair? last2) (car last2) 0))))
              ;; "Repeat the last tab's length."
              (+ last (* step (if prev
                                  (if (<= column last)
                                      -1
                                      (quotient (- column last 1) step))
                                  (+ 1 (quotient (- column last) step)))))))))))

    (define (tab-stop-list)
      ;; `tab-stop-list' (`indent.el:678'): "List of tab stop positions
      ;; used by `tab-to-tab-stop'. ... A value of nil means a tab stop
      ;; every `tab-width' columns."
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'tab-stop-list '()))

    (define-command (tab-to-tab-stop)
      "Insert spaces or tabs to next defined tab-stop column.
The variable `tab-stop-list' is a list of columns at which there are tab stops.
Use \\[edit-tab-stops] to edit them interactively.
Whether this inserts tabs or spaces depends on `indent-tabs-mode'."
      (interactive '())
      ;; The C's `(and abbrev-mode ... (expand-abbrev))' is not here -
      ;; no `abbrev.el'.
      (let ((nexttab (indent-next-tab-stop (current-column))))
        ;; `delete-horizontal-space' is `simple.el''s and `simple.scm' is
        ;; above this library; it arrives through the seam below.
        ((*delete-horizontal-space-function*) #t)
        (indent-to nexttab)))

    ;; `(define-key esc-map "\C-\\" 'indent-region)' (`indent.el:811').
    (define-key km:*default-keymap* (kbd "C-M-\\") indent-region)

    ))
