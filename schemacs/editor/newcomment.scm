(define-library (schemacs editor newcomment)
  ;; This library mirrors GNU Emacs's `lisp/newcomment.el', as far as the
  ;; Lisp indentation engine needs it: `comment-indent` - which
  ;; `indent-for-comment` is an alias for (`newcomment.el:75') - and the
  ;; variables and helpers it reads. `lisp-indent-line` and `indent-sexp`
  ;; both call `indent-for-comment`, so a `;` comment line would be
  ;; indented as code without it.
  ;;
  ;; Emacs's file is 1800 lines and this is about a quarter of it: the
  ;; `comment-*` commands that *insert* comments (`comment-dwim`,
  ;; `comment-region`, `comment-or-uncomment-region`, `uncomment-region`),
  ;; the auto-fill half (`comment-indent-new-line`), the quoting machinery
  ;; (`comment-quote-nested`) and `comment-set-column`.
  ;;
  ;; **Departures, all named where they occur:**
  ;;
  ;;   * `comment-normalize-vars`'s `undecided` value of
  ;;     `comment-use-syntax` resolves to "not by syntax" here instead of
  ;;     testing it with `with-temp-buffer` and `forward-comment`. The
  ;;     Lisp modes set `comment-use-syntax` to t, so it does not arise
  ;;     for them.
  ;;   * `comment-string-strip` is `string-trim`: Emacs's regexp is
  ;;     `\\`\\s-*\\(.*?\\)\\s-*\n?\\'' - leading and trailing whitespace -
  ;;     and the two are the same function on any string.
  ;;   * `comment-setup-function` is not carried (it is `ignore` by
  ;;     default), and neither is `comment-padding`/`comment-continue`'s
  ;;     full normalisation: a Lisp comment has no ender and no padding.

  (import
    (scheme base)
    (scheme char)
    (only (guile) string-trim-right)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          buffer-fill-column)
    (only (schemacs editor cmds)
          beginning-of-line backward-char end-of-line forward-char)
    (only (schemacs editor editfns)
          bolp buffer-substring char-before delete-region eolp forward-line
          goto-char insert line-beginning-position line-end-position point
          point-marker point-max save-excursion)
    (only (schemacs editor indent) indent-according-to-mode)
    (only (schemacs editor indentc)
          current-column current-indentation indent-to)
    (only (schemacs editor marker)
          copy-marker marker-position set-marker)
    (only (schemacs editor search)
          looking-at match-beginning match-end match-string re-search-forward
          regexp-quote string-match)
    (only (schemacs editor syntax)
          parse-partial-sexp skip-chars-backward syntax-ppss)
    )

  (export
   comment-start comment-start-skip comment-end comment-end-skip
   comment-column comment-add comment-fill-column comment-inline-offset
   comment-use-syntax comment-use-global-state
   comment-insert-comment-function
   comment-string-strip comment-normalize-vars comment-search-forward
   comment-indent-default comment-choose-indent comment-indent
   indent-for-comment
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The variables (`newcomment.el:91' onwards).
    ;;----------------------------------------------------------------
    (define (comment-use-syntax)
      ;; `comment-use-syntax' (`newcomment.el:91'): "Non-nil means
      ;; `comment-search-forward' should use the syntax-table for
      ;; finding comments." A major mode sets it for its own buffers; a
      ;; Lisp mode's `t' says the syntax table describes comments.
      (buffer-local-value (current-buffer) 'comment-use-syntax 'undecided))

    (define (comment-use-global-state)
      ;; `comment-use-global-state' (`newcomment.el:479'): non-nil means
      ;; `syntax-ppss' is used to tell whether point is in a string.
      (buffer-local-value (current-buffer) 'comment-use-global-state #t))

    (define (comment-fill-column)
      ;; `comment-fill-column' (`newcomment.el:98'): "If non-nil,
      ;; comment-only lines are wrapped to this column."
      (buffer-local-value (current-buffer) 'comment-fill-column #f))

    (define (comment-column)
      ;; `comment-column' (`newcomment.el:104'): "Column to indent
      ;; right-margin comments to."
      (buffer-local-value (current-buffer) 'comment-column 32))

    (define (comment-start)
      ;; `comment-start' (`newcomment.el:117'): "String to insert to
      ;; start a comment, or nil if comments cannot be inserted."
      (buffer-local-value (current-buffer) 'comment-start #f))

    (define (comment-end)
      ;; `comment-end' (`newcomment.el:151'): "String to insert to end a
      ;; comment, or empty if comments extend to the end of the line."
      (buffer-local-value (current-buffer) 'comment-end ""))

    (define (comment-start-skip)
      ;; `comment-start-skip' (`newcomment.el:123'): "Regexp to match
      ;; that begins a comment."
      (buffer-local-value (current-buffer) 'comment-start-skip #f))

    (define (comment-end-skip)
      ;; `comment-end-skip' (`newcomment.el:145').
      (buffer-local-value (current-buffer) 'comment-end-skip #f))

    (define (comment-insert-comment-function)
      ;; `comment-insert-comment-function' (`newcomment.el:167').
      (buffer-local-value (current-buffer) 'comment-insert-comment-function #f))

    (define (comment-add)
      ;; `comment-add' (`newcomment.el:217'): "How many more comment
      ;; chars to insert when calling `comment-region'. This can be
      ;; particularly useful if you add some per-buffer-specific
      ;; comment-region-function setting it from 0 to 1."
      (buffer-local-value (current-buffer) 'comment-add 0))

    (define (comment-inline-offset)
      ;; `comment-inline-offset' (`newcomment.el:309'): "Inline comments
      ;; have to be preceded by this many blank chars."
      (buffer-local-value (current-buffer) 'comment-inline-offset 1))

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does - see lisp-mode's copy.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    ;;----------------------------------------------------------------
    ;; `comment-string-strip' (`newcomment.el:349') and
    ;; `comment-normalize-vars' (`:364').
    ;;----------------------------------------------------------------
    (define (comment-string-strip str beforep afterp)
      ;; "Strip STR of any leading (if BEFOREP) and/or trailing (if
      ;; AFTERP) space."
      ;;
      ;; The C is a regexp, `\\`\\s-*\\(.*?\\)\\s-*\n?\\'', which is
      ;; trimming on both sides; `string-trim' is the same function.
      ;;--------------------------------------------------------------
      (let* ((s (if beforep
                    ;; There is no `string-trim-left' in this Guile.
                    (let loop ((i 0))
                      (if (and (< i (string-length str))
                               (char-whitespace? (string-ref str i)))
                          (loop (+ i 1))
                          (substring str i)))
                    str))
             (s (if afterp (string-trim-right s) s)))
        s))

    (define (comment-normalize-vars . rest)
      ;; `comment-normalize-vars' (`newcomment.el:364'): "Check and set
      ;; up variables needed by other commenting functions."
      ;;
      ;; The `comment-setup-function' hook and the interactive "No
      ;; comment syntax is defined. Use:" prompt are not carried: nothing
      ;; here defines a setup function, and a command that prompts would
      ;; drag the minibuffer into this library.
      ;;--------------------------------------------------------------
      (let ((noerror (and (pair? rest) (car rest))))
        (when (or (comment-start) (not noerror))
          (unless (comment-start)
            (error "No comment syntax defined"))
          ;; `comment-use-syntax': the `undecided' value is resolved by
          ;; trying `forward-comment' in a temp buffer in the C; there is
          ;; no `with-temp-buffer' here, so an undecided mode is taken to
          ;; mean "not by syntax". The Lisp modes set it to t.
          (when (eq? (comment-use-syntax) 'undecided)
            (setq-local 'comment-use-syntax #f))
          ;; The comment markers. `comment-continue' only exists where
          ;; there is a comment *end*, which a Lisp comment has not got.
          (when (and (not (buffer-local-value (current-buffer)
                                              'comment-continue #f))
                     (not (string=? (comment-end) "")))
            (setq-local 'comment-continue
                        (string-append (if (string-match "[^ \t\n][^ \t\n]"
                                                         (comment-start))
                                           " " "|")
                                       (substring (comment-start) 1))))
          ;; `comment-start-skip'
          (unless (and (comment-start-skip)
                       (let ((m (string-match (comment-start-skip)
                                              (comment-start))))
                         m))
            (setq-local 'comment-start-skip
                        (string-append
                         (if (not (eq? (comment-use-syntax) #t))
                             ;; "`syntax-ppss' will detect escaping."
                             "\\(\\(^\\|[^\\\n]\\)\\(\\\\\\\\\\)*\\)"
                             "")
                         "\\(?:\\s<+\\|"
                         (regexp-quote (comment-string-strip (comment-start) #t #t))
                         ;; "Let's not allow any \\s- but only [ \\t] since
                         ;; \\n might be both a comment-end marker and \\s-."
                         "+\\|[ \t]+\\)[ \t]*")))
          ;; `comment-end-skip'
          (unless (and (comment-end-skip)
                       (let ((m (string-match (comment-end-skip)
                                              (if (string=? "" (comment-end))
                                                  "\n"
                                                  (comment-end)))))
                         m))
            (let ((ce (if (string=? "" (comment-end))
                          "\n"
                          (comment-string-strip (comment-end) #t #t))))
              (setq-local 'comment-end-skip
                          (string-append
                           "[ \t]*\\(\\s>"
                           "\\|"
                           (regexp-quote (substring ce 0 1))
                           (regexp-quote (substring ce 1))
                           "\\)")))))
        #f))

    ;;----------------------------------------------------------------
    ;; `comment-search-forward' (`newcomment.el:498').
    ;;----------------------------------------------------------------
    (define (comment-search-forward limit . rest)
      ;; "Find a comment start between point and LIMIT. Moves point to
      ;; inside the comment and returns the position of the
      ;; comment-starter. If no comment is found, moves point to LIMIT
      ;; and raises an error or returns nil if NOERROR is non-nil."
      ;;
      ;; `comment-use-global-state' is ported as the C reads it (the
      ;; `undecided' value is `use-global-state' when nil, which is the
      ;; C's `(if comment-use-global-state (syntax-ppss pt))').
      ;;--------------------------------------------------------------
      (let ((noerror (and (pair? rest) (car rest))))
        (if (not (comment-use-syntax))
            (if (re-search-forward (comment-start-skip) limit noerror)
                (or (match-end 1) (match-beginning 0))
                (begin (goto-char limit)
                       ;; "raises an error or returns nil if NOERROR is
                       ;; non-nil" - Elisp's `unless' answers nil; the
                       ;; Scheme one answers the unspecified value.
                       (if noerror #f (error "No comment"))))
            (let* ((pt (point))
                   ;; "Assume (at first) that pt is outside of any string."
                   (s (parse-partial-sexp pt (or limit (point-max)) #f #f
                                          (if (comment-use-global-state)
                                              (syntax-ppss pt)
                                              #f)
                                          #t)))
              (when (and (list-ref s 8) (list-ref s 3)
                         (not (comment-use-global-state)))
                ;; "The search ended at eol inside a string. Try to see if
                ;; it works better when we assume that pt is inside a
                ;; string."
                (set! s (parse-partial-sexp
                         pt (or limit (point-max)) #f #f
                         (list #f #f #f (list-ref s 3) #f #f #f #f #f)
                         #t)))
              (if (or (not (and (list-ref s 8) (not (list-ref s 3))))
                      ;; "Make sure the comment starts after PT."
                      (< (list-ref s 8) pt))
                  (if noerror #f (error "No comment"))
                  ;; We found the comment.
                  (let ((pos (point))
                        (start (list-ref s 8))
                        (bol (line-beginning-position))
                        (end #f))
                    (let loop ()
                      (when (and (not end) (>= (point) bol))
                        (if (looking-at (comment-start-skip))
                            (set! end (min (or limit (point-max)) (match-end 0)))
                            (backward-char))
                        (loop)))
                    (goto-char (or end pos))
                    start))))))

    ;;----------------------------------------------------------------
    ;; `comment-indent-default' (`newcomment.el:659').
    ;;----------------------------------------------------------------
    (define (comment-indent-default)
      ;; "Default for `comment-indent-function'."
      ;;--------------------------------------------------------------
      (if (and (looking-at "\\s<\\s<\\(\\s<\\)?")
               (or (match-end 1)
                   (not (= (current-column) (current-indentation)))))
          0
          ;; Elisp's `when' answers nil when its test fails; Scheme's
          ;; answers the unspecified value, which is *true* here - and
          ;; `comment-indent' reads this answer as "is there an indent?".
          (if (or (not (= (current-column) (current-indentation)))
                  (and (> (comment-add) 0)
                       (looking-at "\\s<\\(\\S<\\|\\'\\)")))
              (comment-column)
              #f)))

    ;;----------------------------------------------------------------
    ;; `comment-choose-indent' (`newcomment.el:668').
    ;;----------------------------------------------------------------
    (define (comment-choose-indent . rest)
      ;; "Choose the indentation to use for a right-hand-side comment."
      ;;
      ;; **`min' and `max' are `min-col' and `max-col' here.** Elisp is a
      ;; Lisp-2: `(let ((min ...)) ... (max min (min max indent)))' binds
      ;; a *variable* called `min' and calls the *function* `min' from the
      ;; same form. A Scheme binding shadows the procedure, so the C's
      ;; names cannot be kept: `(max min (min max indent))' applied the
      ;; integer `min'. Found by `indent-region' over a file with
      ;; right-hand-side comments; nothing had ever reached this function.
      ;;--------------------------------------------------------------
      (let* ((indent (if (and (pair? rest) (car rest)) (car rest)
                         (comment-column)))
             (fill-column-value (or (comment-fill-column)
                                    (buffer-fill-column (current-buffer))))
             (min-col #f) (max-col #f))
        (if (pair? indent)
            (begin (set! min-col (car indent)) (set! max-col (cdr indent))
                   (set! indent (comment-column)))
            (begin
              ;; "Avoid moving comments past the fill-column."
              (set! max-col (+ (current-column)
                           (- fill-column-value
                              (save-excursion (end-of-line) (current-column)))))
              (set! min-col (save-excursion
                          (skip-chars-backward " \t")
                          ;; "Leave at least `comment-inline-offset' space
                          ;; after other nonwhite text on the line."
                          (if (bolp) 0 (+ (comment-inline-offset)
                                          (current-column)))))))
        ;; "Fix up the range."
        (if (< max-col min-col) (set! max-col min-col))
        ;; "Don't move past the fill column."
        (if (<= max-col indent) (set! indent max-col))
        ;; "We can choose anywhere between min-col..max-col. Let's try to align to
        ;; a comment on the previous line."
        (let ((other (save-excursion
                       (and (= 0 (forward-line -1))
                            (comment-search-forward (line-end-position) #t)))))
          (if other
              (set! other (save-excursion (goto-char other) (current-column))))
          (if (and other (<= other max-col) (>= other min-col))
              ;; "There is a comment and it's in the range: bingo!"
              other
              ;; "Can't align to a previous comment: let's try to align to
              ;; comments on the following lines, then." (Elisp's `if`
              ;; takes several else forms; Scheme's does not, so they are
              ;; a `begin'.)
              (begin
              (save-excursion
                (let loop ()
                  (when (and (= 0 (forward-line 1))
                             ;; `(setq other (comment-search-forward ...))'
                             ;; - and a nil answer must end the loop, so
                             ;; the `when' cannot stand in for the `and'.
                             (let ((o (comment-search-forward
                                       (line-end-position) #t)))
                               (if o (begin (set! other o) #t) #f)))
                    (goto-char other)
                    (let ((omax (+ (current-column)
                                   (- fill-column-value
                                      (save-excursion (end-of-line)
                                                      (current-column)))))
                          (omin (save-excursion (skip-chars-backward " \t")
                                                (+ 1 (current-column)))))
                      (if (and (>= omax min-col) (<= omin max-col))
                          (begin (set! min-col (max omin min-col))
                                 (set! max-col (min omax max-col))
                                 (loop))
                          ;; "Can't align with this anyway, so exit the
                          ;; loop."
                          (goto-char (point-max)))))))
              ;; "Return the closest point to indent within min-col..max-col."
              (max min-col (min max-col indent)))))))

    ;;----------------------------------------------------------------
    ;; `comment-indent' (`newcomment.el:728'), and `indent-for-comment',
    ;; which is `(defalias 'indent-for-comment 'comment-indent)'
    ;; (`:75').
    ;;----------------------------------------------------------------
    (define (comment-indent . rest)
      ;; "Indent this line's comment to `comment-column', or insert an
      ;; empty comment."
      ;;
      ;; The `comment-normalize-vars' call and the "no comment on this
      ;; line" branches are the C's; `comment-insert-comment-function'
      ;; is carried because a mode can set it (a Lisp mode does not).
      ;;--------------------------------------------------------------
      (let ((continue (and (pair? rest) (car rest)))
            (begpos #f)
            (cpos #f)
            (indent #f))
        (comment-normalize-vars)
        (beginning-of-line)
        (let* ((starter (or (and continue
                                 (buffer-local-value (current-buffer)
                                                     'comment-continue #f))
                            (comment-start)
                            (error "No comment syntax defined")))
               (ender (or (and continue
                               (buffer-local-value (current-buffer)
                                                   'comment-continue #f)
                               "")
                          (comment-end)))
               (begpos (comment-search-forward (line-end-position) #t)))
          (cond
           ;; "If we couldn't find a comment *starting* on this line, see
           ;; if we are already within a multiline comment at BOL."
           ((and (not begpos) (not continue)
                 (comment-use-syntax) (comment-use-global-state)
                 (save-excursion (list-ref (syntax-ppss (line-beginning-position))
                                           4)))
            (indent-according-to-mode))
           ((and (not begpos) (comment-insert-comment-function))
            ((comment-insert-comment-function)))
           (else
            ;; "An existing comment?"
            (if begpos
                (begin
                  (if (and (not (looking-at "[\t\n ]"))
                           (looking-at (comment-end-skip)))
                      ;; "The comment is empty and we have skipped all its
                      ;; space and landed right before the comment-ender:
                      ;; Go back to the middle of the space."
                      (forward-char (quotient (skip-chars-backward " \t") -2)))
                  (set! cpos (point-marker)))
                ;; "If none, insert one."
                (save-excursion
                  ;; "Some `comment-indent-function's insist on not moving
                  ;; comments that are in column 0, so we first go to the
                  ;; likely target column."
                  (indent-to (comment-column))
                  ;; "Ensure there's a space before the comment for things
                  ;; like sh where it matters (as well as being neater)."
                  (unless (memv (char-before) (list #f #\newline #\tab #\space))
                    (insert #\space))
                  (set! begpos (point))
                  (insert starter)
                  (set! cpos (point-marker))
                  (insert ender)))
            (goto-char begpos)
            ;; "Compute desired indent."
            (set! indent (save-excursion
                           ;; `(funcall comment-indent-function)' - a
                           ;; buffer-local procedure, whose global value
                           ;; is `comment-indent-default'
                           ;; (`newcomment.el:239').
                           ((buffer-local-value (current-buffer)
                                                'comment-indent-function
                                                comment-indent-default))))
            ;; "If `indent' is nil and there's code before the comment, we
            ;; can't use `indent-according-to-mode', so we default to
            ;; comment-column."
            (unless (or indent
                        (save-excursion (skip-chars-backward " \t") (bolp)))
              (set! indent (comment-column)))
            (if (not indent)
                ;; "comment-indent-function refuses: delegate to
                ;; line-indent."
                (indent-according-to-mode)
                (begin
                  ;; "If the comment is at the right of code, adjust the
                  ;; indentation."
                  (unless (save-excursion (skip-chars-backward " \t") (bolp))
                    (set! indent (comment-choose-indent indent)))
                  ;; "If that's different from comment's current position,
                  ;; change it."
                  (unless (= (current-column) indent)
                    (delete-region (point)
                                   (save-excursion (skip-chars-backward " \t")
                                                   (point)))
                    (indent-to indent))))
            (goto-char (marker-position cpos))
            (set-marker cpos #f))))))

    (define (indent-for-comment . rest)
      ;; `(defalias 'indent-for-comment 'comment-indent)' (`newcomment.el:75').
      ;;--------------------------------------------------------------
      (apply comment-indent rest))

    ))
