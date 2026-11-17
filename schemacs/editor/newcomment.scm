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
  ;; the quoting machinery (`comment-quote-nested`) and
  ;; `comment-set-column`. **`comment-indent-new-line` and
  ;; `comment-valid-prefix-p` are `fill.scm`'s** - they read
  ;; `adaptive-fill-mode`, and `fill.scm` imports this library, so their
  ;; Emacs home would be a cycle; see the note where they are.
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
  ;;     default), and `comment-padding`'s normalisation is not either -
  ;;     a Lisp comment has no ender and no padding. `comment-continue`'s
  ;;     is, in `comment-normalize-vars` (`newcomment.el:406`).

  (import
    (scheme base)
    (only (schemacs editor custom) define-custom)
    (scheme char)
    (only (guile) string-trim-right)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          buffer-fill-column)
    ;; `comment-indent' is a command - `(interactive "*")' in the C - and
    ;; `indent-for-comment' is its `defalias', which is `define-alias'.
    (only (schemacs editor command) define-command define-alias)
    (only (schemacs editor cmds)
          beginning-of-line backward-char end-of-line forward-char)
    (only (schemacs editor editfns)
          bolp buffer-substring char-after char-before delete-region eobp
          eolp forward-line
          goto-char insert line-beginning-position line-end-position
          narrow-to-region point point-marker point-max point-min
          save-excursion save-restriction)
    (only (schemacs editor indent) indent-according-to-mode)
    (only (schemacs editor indentc)
          current-column current-indentation indent-to)
    (only (schemacs editor marker)
          copy-marker marker-position set-marker)
    (only (schemacs editor search)
          looking-at match-beginning match-end match-string
          re-search-forward re-search-backward
          regexp-quote string-match)
    (only (schemacs editor syntax)
          forward-comment parse-partial-sexp skip-chars-backward
          skip-syntax-backward string-to-syntax syntax-after syntax-ppss)
    (only (schemacs editor textprop) get-text-property)
    )

  (export
   comment-start comment-start-skip comment-end comment-end-skip
   comment-column comment-add comment-fill-column comment-inline-offset
   comment-use-syntax comment-use-global-state
   comment-insert-comment-function
   comment-string-strip comment-normalize-vars comment-search-forward
   comment-search-backward comment-beginning comment-forward
   comment-enter-backward comment-continue
   comment-styles
   *comment-style* *comment-multi-line*
   comment-indent-default comment-choose-indent comment-indent
   indent-for-comment
   *comment-auto-fill-only-comments*
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
    ;; `comment-styles' (`newcomment.el:226'), `comment-style'
    ;; (`:285') and `comment-multi-line' (`:313').
    ;;----------------------------------------------------------------
    (define comment-styles
      ;; "Comment region style definitions. Each style is defined with a
      ;; form (STYLE . (MULTI ALIGN EXTRA INDENT DOC))."
      ;;
      ;; A `defconst', so a plain variable. Only `comment-indent-new-line`
      ;; reads it here, for its ALIGN slot, which `continuep' takes.
      ;;--------------------------------------------------------------
      '((plain           #f #f #f #f
         "Start in column 0 (do not indent), as in Emacs-20")
        (indent-or-triple #f #f #f multi-char
         "Start in column 0, but only for single-char starters")
        (indent          #f #f #f #t
         "Full comment per line, ends not aligned")
        (aligned         #f #t #f #t
         "Full comment per line, ends aligned")
        (box             #f #t #t #t
         "Full comment per line, ends aligned, + top and bottom")
        (extra-line      #t #f #t #t
         "One comment for all lines, end on a line by itself")
        (multi-line      #t #f #f #t
         "One comment for all lines, end on last commented line")
        (box-multi       #t #t #t #t
         "One comment for all lines, + top and bottom")))

    (define-custom *comment-style* 'indent
      "Style to be used for `comment-region'.
See `comment-styles' for a list of available styles."
      :type 'symbol
      :group 'comment)

    (define-custom *comment-multi-line* #f
      "Non-nil means `comment-indent-new-line' continues comments.
That is, it inserts no new terminator or starter.
This affects `auto-fill-mode', which is the main reason to
customize this variable.

It also affects \\[indent-new-comment-line].  However, if you want this
behavior for explicit filling, you might as well use \\[newline-and-indent]."
      :type 'boolean
      :group 'comment)

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
    ;; `comment-search-backward' (`newcomment.el:537'),
    ;; `comment-beginning' (`:567'), `comment-forward' (`:606') and
    ;; `comment-enter-backward' (`:622').
    ;;----------------------------------------------------------------
    ;; These four are what `comment-indent-new-line` is built on - the
    ;; work of finding the comment around point and of stepping to its
    ;; end - and they are the general ones, not that command's private
    ;; helpers: `comment-dwim` and `comment-region` want them too.

    (define (comment-continue)
      ;; `comment-continue' (`newcomment.el:170'): "String to insert to
      ;; continue an existing comment." A buffer-local that
      ;; `comment-normalize-vars` fills in when the comment has an end.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'comment-continue #f))

    (define (comment-search-backward . rest)
      ;; "Find a comment start between LIMIT and point. Moves point to
      ;; inside the comment and returns the position of the
      ;; comment-starter. If no comment is found, moves point to LIMIT
      ;; and raises an error or returns nil if NOERROR is non-nil."
      ;;--------------------------------------------------------------
      (let ((limit (and (pair? rest) (car rest)))
            (noerror (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (if (not (re-search-backward (comment-start-skip) limit 'move))
            (if noerror #f (error "No comment"))
            (begin
              (beginning-of-line)
              (let* ((end (match-end 0))
                     (cs (comment-search-forward end #t))
                     (pt (point)))
                (if (not cs)
                    (begin (beginning-of-line)
                           (comment-search-backward limit noerror))
                    (begin
                      ;; `(while (progn (goto-char cs) (comment-forward)
                      ;; (and (< (point) end) (setq cs ...))) (setq pt
                      ;; (point)))' - the test is the whole `progn'.
                      (let loop ()
                        (when (and (begin (goto-char cs)
                                          (comment-forward)
                                          (< (point) end))
                                   (begin (set! cs (comment-search-forward end #t))
                                          cs))
                          (set! pt (point))
                          (loop)))
                      (goto-char pt)
                      cs)))))))

    (define (comment-beginning)
      ;; "Find the beginning of the enclosing comment. Returns nil if not
      ;; inside a comment, else moves point and returns the same as
      ;; `comment-search-backward'."
      ;;
      ;; Elisp's `when` answers nil when its test fails; every branch
      ;; that is read as a value is an explicit `if` here.
      ;;--------------------------------------------------------------
      (if (and (comment-use-syntax) (comment-use-global-state))
          (let ((state (syntax-ppss)))
            (if (not (list-ref state 4))
                #f
                (begin
                  (goto-char (list-ref state 8))
                  (let ((start (point)))
                    (when (save-restriction
                            ;; "`comment-start-skip' sometimes checks that
                            ;; the comment char is not escaped."
                            (narrow-to-region (point) (point-max))
                            (looking-at (comment-start-skip)))
                      (goto-char (match-end 0)))
                    start))))
          ;; "Can't rely on the syntax table, let's guess based on
          ;; font-lock."
          (if (eq? (get-text-property (point) 'face) 'font-lock-string-face)
              #f
              (let ((pt (point))
                    (cs (comment-search-backward #f #t)))
                (if cs
                    (if (save-excursion
                          (goto-char cs)
                          (and
                           ;; "For modes where comment-start and comment-end
                           ;; are the same, the search above may have found
                           ;; a `ce' rather than a `cs'."
                           (if (comment-end-skip)
                               (not (looking-at (comment-end-skip)))
                               ;; "Maybe font-lock knows that it's a `cs'?"
                               (if (eq? (get-text-property (match-end 0) 'face)
                                        'font-lock-comment-face)
                                   #t
                                   ;; "Let's assume it's a `cs' if we're on
                                   ;; the same line."
                                   (if (not (eq? (get-text-property (point) 'face)
                                                 'font-lock-comment-face))
                                       (>= (line-end-position) pt)
                                       #f)))
                           ;; "Make sure that PT is not past the end of the
                           ;; comment."
                           (if (comment-forward 1) (> (point) pt) (eobp))))
                        cs
                        (begin (goto-char pt) #f))
                    #f)))))

    (define (comment-forward . rest)
      ;; "Skip forward over N comments. Just like `forward-comment' but
      ;; only for positive N and can use regexps instead of syntax."
      ;;--------------------------------------------------------------
      (let ((n (if (and (pair? rest) (car rest)) (car rest) 1)))
        (if (< n 0)
            (error "No comment-backward")
            (begin
              (if (comment-use-syntax)
                  (forward-comment n)
                  (let loop ()
                    (when (> n 0)
                      (set! n
                            (if (or (forward-comment 1)
                                    (and (looking-at (comment-start-skip))
                                         (begin (goto-char (match-end 0))
                                                (re-search-forward
                                                 (comment-end-skip) #f 'move))))
                                (- n 1)
                                -1))
                      (loop))))
              (= n 0)))))

    (define (%syntax-code-or-0 pos)
      ;; Elisp's `(car (syntax-after POS))' where SYNTAX-AFTER may answer
      ;; nil - `(car nil)' is nil and `logand' reads nil as zero, which is
      ;; what makes `comment-enter-backward`'s test take its "no clue"
      ;; branch at the start of the buffer. `(car #f)` is an error here.
      ;;--------------------------------------------------------------
      (let ((s (syntax-after pos)))
        (if s (car s) 0)))

    (define (comment-enter-backward)
      ;; "Move from the end of a comment to the end of its content.
      ;; Point is assumed to be just at the end of a comment."
      ;;--------------------------------------------------------------
      (if (bolp)
          ;; "comment-end = \"\""
          (begin (backward-char) (skip-syntax-backward " "))
          (cond
           ((save-excursion
              (save-restriction
                (narrow-to-region (line-beginning-position) (point))
                (goto-char (point-min))
                (re-search-forward (string-append (comment-end-skip) "\\'")
                                   #f #t)))
            (goto-char (match-beginning 0)))
           ;; "comment-end-skip not found probably because it was not set
           ;; right. Since \\s> should catch the single-char case, let's
           ;; check that we're looking at a two-char comment ender."
           ((not (or (<= (- (point-max) (line-beginning-position)) 1)
                     ;; "Here we take advantage of the fact that the syntax
                     ;; class \" \" is encoded to 0, so \"  4\" gives us
                     ;; just the 4 bit."
                     (= 0 (logand (%syntax-code-or-0 (- (point) 1))
                                  (car (string-to-syntax "  4"))))
                     (= 0 (logand (%syntax-code-or-0 (- (point) 2))
                                  (car (string-to-syntax "  3"))))))
            (backward-char 2)
            (skip-chars-backward (string (char-after)))
            (skip-syntax-backward " "))
           ;; "No clue what's going on: maybe we're really not right after
           ;; the end of a comment."
           (else (skip-syntax-backward " ")))))

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
    (define-command (comment-indent . rest)
      ;; The `comment-normalize-vars' call and the "no comment on this
      ;; line" branches are the C's; `comment-insert-comment-function'
      ;; is carried because a mode can set it (a Lisp mode does not).
      ;;
      ;; **`(interactive "*")'** (`newcomment.el:731`): no arguments, and
      ;; an error if the buffer is read-only - the `*' marker
      ;; `command.scm`'s `interactive-proc` reads. The body keeps the C's
      ;; `&optional continue` shape as a rest list, because it is called
      ;; with no argument from `indent-for-comment` and from Lisp modes,
      ;; and because a Scheme procedure that took a required one could
      ;; not be called that way.
      "Indent this line's comment to `comment-column', or insert an empty comment.
If CONTINUE is non-nil, use the `comment-continue' markers if any."
      (interactive "*")
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

    (define-alias indent-for-comment comment-indent)
    ;; ^ `(defalias 'indent-for-comment 'comment-indent)'
    ;; (`newcomment.el:75') - one procedure, two names, and `M-x'
    ;; reaches both.


    (define-custom *comment-auto-fill-only-comments* #f
      "Non-nil means to only auto-fill inside comments.
This has no effect in modes that do not define a comment syntax."
      :type 'boolean
      :group 'fill)

    ))
