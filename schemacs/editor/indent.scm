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
          current-buffer buffer-local-value set-buffer-local-value!)
    (only (schemacs editor character) *tab-width*)
    (only (schemacs editor cmds) beginning-of-line backward-char)
    (only (schemacs editor command)
          current-prefix-arg define-command uarg->integer)
    (only (schemacs editor editfns)
          bobp bolp delete-region eolp forward-line goto-char point point-marker
          region-beginning region-end line-end-position save-excursion
          ;; `indent-according-to-mode` widens first, so that indenting a
          ;; line in a narrowed buffer sees the text outside it.
          save-restriction widen)
    (only (schemacs editor marker) copy-marker marker-position set-marker)
    (only (schemacs editor indentc)
          current-column current-indentation indent-to move-to-column)
    (only (schemacs editor search) looking-at re-search-backward)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor keymap) define-key)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor syntax)
          skip-chars-forward skip-chars-backward syntax-propertize)
    )

  (export
   indent-rigidly
   indent-line-function indent-line-ignored-functions
   indent-according-to-mode indent-line-to
   indent-region-function indent-region indent-region-line-by-line
   indent-relative indent-relative-first-indent-point indent-relative-maybe
   indent-next-tab-stop tab-to-tab-stop tab-stop-list
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
         ;; The `fill-prefix' arm is not here: `fill.el' is not ported,
         ;; so there is no such variable to consult.
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
