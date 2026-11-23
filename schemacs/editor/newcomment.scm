(define-library (schemacs editor newcomment)
  ;; This library mirrors GNU Emacs's `lisp/newcomment.el', as far as the
  ;; Lisp indentation engine needs it: `comment-indent` - which
  ;; `indent-for-comment` is an alias for (`newcomment.el:75') - and the
  ;; variables and helpers it reads. `lisp-indent-line` and `indent-sexp`
  ;; both call `indent-for-comment`, so a `;` comment line would be
  ;; indented as code without it.
  ;;
  ;; Emacs's file is 1800 lines. **The commands are all here now**: the
  ;; `comment-*` commands that insert and remove comments
  ;; (`comment-dwim` M-;, `comment-region`, `uncomment-region`,
  ;; `comment-or-uncomment-region`, `comment-box`, `comment-line`
  ;; C-x C-;, `comment-kill`, `comment-set-column` C-x ;), the padding and
  ;; box helpers under them, and the quoting machinery
  ;; (`comment-quote-nested`). **`comment-indent-new-line` and
  ;; `comment-valid-prefix-p` are `fill.scm`'s** - they read
  ;; `adaptive-fill-mode`, and `fill.scm` imports this library, so their
  ;; Emacs home would be a cycle; see the note where they are.
  ;;
  ;; Not carried, named rather than faked: `comment-combine-change-calls`
  ;; (the variable exists; `combine-change-calls` is `replace.el`'s and is
  ;; not ported, so the region functions do their work directly), and
  ;; `comment-setup-function` (it is `ignore` by default, and nothing here
  ;; sets one).
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
    (only (guile) string-trim-right logand
          datum->syntax quasisyntax syntax syntax-case unsyntax)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          buffer-fill-column)
    ;; `comment-indent' is a command - `(interactive "*")' in the C - and
    ;; `indent-for-comment' is its `defalias', which is `define-alias'.
    (only (schemacs editor command)
          define-command define-alias prefix-numeric-value)
    ;; `concat` and `mapconcat` are `fns.c`'s; `count-lines` is
    ;; `simple.el`'s, called on a narrowed buffer in the box logic.
    (only (schemacs editor fns) concat mapconcat)
    ;; The three commands bind at the end of the file - `bindings.el:1603'
    ;; - and a binding must come after its command.
    (only (schemacs editor keymap) define-key *default-keymap*)
    ;; `kbd` is `subr.el`'s - what a key binding is written with.
    (only (schemacs editor subr) kbd)
    ;; `kill-region` is `simple.el`'s command; `*this-command*` and
    ;; `*last-command*` are the command loop's, which `comment-line`
    ;; reads and sets.
    (only (schemacs editor simple)
          count-lines kill-region use-region-p *last-command* *this-command*)
    (only (schemacs editor character) *tab-width*)
    (only (schemacs editor cmds)
          beginning-of-line backward-char delete-char end-of-line
          forward-char)
    (only (schemacs editor editfns)
          bobp bolp buffer-substring char-after char-before delete-region eobp
          eolp forward-line
          goto-char insert line-beginning-position line-end-position
          message narrow-to-region point point-marker point-max point-min
          region-beginning region-end save-excursion save-restriction)
    (only (schemacs editor indent) back-to-indentation indent-according-to-mode)
    (only (schemacs editor indentc)
          *indent-tabs-mode* current-column current-indentation indent-to
          move-to-column)
    (only (schemacs editor marker)
          copy-marker marker-position set-marker)
    (only (schemacs editor search)
          looking-at match-beginning match-end match-string
          re-search-forward re-search-backward regexp-quote replace-match
          search-forward string-match string-match-p)
    (only (schemacs editor syntax)
          forward-comment parse-partial-sexp skip-chars-backward skip-chars-forward
          skip-syntax-backward skip-syntax-forward string-to-syntax
          syntax-after syntax-ppss)
    (only (schemacs editor textprop) get-text-property)
    )

  (export
   comment-start set!comment-start comment-start-skip
   comment-end set!comment-end comment-end-skip
   comment-column comment-add comment-fill-column comment-inline-offset
   comment-use-syntax *comment-use-global-state*
   comment-insert-comment-function
   comment-string-strip comment-normalize-vars comment-search-forward
   comment-search-backward comment-beginning comment-forward
   comment-enter-backward comment-continue
   comment-styles
   *comment-style* *comment-multi-line*
   comment-indent-default comment-choose-indent comment-indent
   indent-for-comment
   ;; the region commands - `newcomment.el:799' onwards
   *comment-padding* *comment-quote-nested*
   *comment-quote-nested-function* *comment-region-function*
   *uncomment-region-function* *comment-empty-lines*
   *comment-combine-change-calls*
   comment-string-reverse comment-quote-re comment-quote-nested
   comment-quote-nested-default
   comment-set-column comment-kill comment-padright comment-padleft
   comment-with-narrowing comment-make-bol-ws comment-make-extra-lines
   comment-add-count comment-region-internal
   uncomment-region uncomment-region-default-1 uncomment-region-default
   comment-region comment-region-default-1 comment-region-default
   comment-box comment-only-p comment-or-uncomment-region comment-dwim
   comment-line
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

    (define *comment-use-global-state* (make-parameter #t))
    ;; ^ `comment-use-global-state' (`newcomment.el:479'): "Non-nil means
    ;; that the global syntactic context is used. More specifically, it
    ;; means that `syntax-ppss' is used to find out whether point is
    ;; within a string or not." A `defvar`, and **`uncomment-region`
    ;; `let`-binds it to nil** - which is the tree's test for a parameter.
    ;; It was an accessor over a buffer-local, which could not be bound.

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

    (define (set!comment-start value)
      ;; What `(setq comment-start STRING)' does in a buffer - a
      ;; mode's `setq-local' and cc-mode's
      ;; `c-toggle-comment-style' (`cc-cmds.el:396') both do it.
      (set-buffer-local-value! (current-buffer) 'comment-start value))

    (define (comment-end)
      ;; `comment-end' (`newcomment.el:151'): "String to insert to end a
      ;; comment, or empty if comments extend to the end of the line."
      (buffer-local-value (current-buffer) 'comment-end ""))

    (define (set!comment-end value)
      (set-buffer-local-value! (current-buffer) 'comment-end value))

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
                                          (if (*comment-use-global-state*)
                                              (syntax-ppss pt)
                                              #f)
                                          #t)))
              (when (and (list-ref s 8) (list-ref s 3)
                         (not (*comment-use-global-state*)))
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
      (if (and (comment-use-syntax) (*comment-use-global-state*))
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
            ;; **The two arms answer different things**, which is the C's
            ;; `if`: the syntax arm answers `forward-comment`'s own value
            ;; ("non-nil if it moved"), while the regexp arm answers
            ;; `(= n 0)` after its walk. Returning `(= n 0)` for both made
            ;; `comment-forward` answer nil in every mode whose
            ;; `comment-use-syntax` is t - which is every programming mode -
            ;; and `uncomment-region` then said "Can't find the comment
            ;; end" for a comment it could see.
            (if (comment-use-syntax)
                (forward-comment n)
                (begin
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
                      (loop)))
                  (= n 0))))))

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
            ;; `char-after` takes its position here (Emacs's defaults to
            ;; point; this tree's is the required form).
            (skip-chars-backward (string (char-after (point))))
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
                 (comment-use-syntax) (*comment-use-global-state*)
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


    ;;----------------------------------------------------------------
    ;; The variables the region commands read - `newcomment.el:182-350'
    ;;----------------------------------------------------------------
    ;;
    ;; A `defcustom' is a parameter here, as the tree's convention says;
    ;; a `defvar' that is `let'-bound is one too, and a `defvar' that is
    ;; only read is a plain definition. Two defaults are procedures
    ;; defined *below*, so they start as #f and are `set!' where Emacs
    ;; would have written the quoted name - the same shape
    ;; `normal-auto-fill-function' takes in `fill.scm'.
    (define *comment-padding* (make-parameter " "))
    ;; ^ `comment-padding' (`:299'): "String inserted by commenting
    ;; commands after `comment-start' and before `comment-end'."
    ;; `comment-normalize-vars' turns a number into that many spaces.

    (define *comment-quote-nested* (make-parameter #t))
    ;; ^ `comment-quote-nested' (`:198'): "If non-nil, comments can be
    ;; nested and need to be quoted."

    (define *comment-quote-nested-function* (make-parameter #f))
    ;; ^ `comment-quote-nested-function' (`:202'), whose default is
    ;; `comment-quote-nested-default' - `set!' below it.

    (define *comment-region-function* (make-parameter #f))
    ;; ^ `comment-region-function' (`:182'), whose default is
    ;; `comment-region-default' - `set!' below it.

    (define *uncomment-region-function* (make-parameter #f))
    ;; ^ `uncomment-region-function' (`:190'), whose default is
    ;; `uncomment-region-default' - `set!' below it.

    (define *comment-empty-lines* (make-parameter #f))
    ;; ^ `comment-empty-lines' (`:335'): "If non-nil, `comment-region'
    ;; uses comment delimiters on empty lines as well."

    (define *comment-combine-change-calls* (make-parameter #t))
    ;; ^ `comment-combine-change-calls' (`:206'): "If non-nil, the
    ;; commenting functions will call `combine-change-calls'." **Not
    ;; carried**: `combine-change-calls` is `replace.el`'s and is not
    ;; ported, so the region functions below run without it; the variable
    ;; exists so a user setting it sees no error.

    ;;----------------------------------------------------------------
    ;; `comment-string-reverse' (`newcomment.el:356')
    ;;----------------------------------------------------------------
    (define (comment-string-reverse s)
      ;; "Return the mirror image of string S, without any trailing
      ;; space."
      ;;--------------------------------------------------------------
      (comment-string-strip
       (list->string (reverse (string->list s))) #f #t))

    ;;----------------------------------------------------------------
    ;; The quoting machinery - `comment-quote-re' (`:435'),
    ;; `comment-quote-nested' (`:440'), `comment-quote-nested-default'
    ;; (`:449')
    ;;----------------------------------------------------------------
    (define (comment-quote-re str unp)
      ;; "The regexp that matches STR with the character after its first
      ;; escaped" - `comment-quote-re' (`:435').
      ;;--------------------------------------------------------------
      (concat (regexp-quote (substring str 0 1))
              "\\\\" (if unp "+" "*")
              (regexp-quote (substring str 1))))

    (define (comment-quote-nested cs ce unp)
      ;; "Quote or unquote nested comments. If UNP is non-nil, unquote
      ;; nested comment markers." (`:440')
      ;;--------------------------------------------------------------
      (let ((cs (comment-string-strip cs #t #t))
            (ce (comment-string-strip ce #t #t)))
        (when (and (*comment-quote-nested*)
                   (> (string-length ce) 0))
          ((*comment-quote-nested-function*) cs ce unp))))

    (define (comment-quote-nested-default cs ce unp)
      ;; "Quote comment delimiters in the buffer. It expects to be called
      ;; with the buffer narrowed to a single comment." (`:449')
      ;;
      ;; "To quote the delimiters, a \\ is inserted after the first
      ;; character of CS or CE. If CE is a single character it will change
      ;; CE into !CS."
      ;;--------------------------------------------------------------
      (let ((re (concat (comment-quote-re ce unp)
                        "\\|" (comment-quote-re cs unp))))
        (goto-char (point-min))
        (let loop ()
          (when (re-search-forward re #f #t)
            (goto-char (match-beginning 0))
            (forward-char 1)
            (if unp (delete-char 1) (insert "\\"))
            (when (= (string-length ce) 1)
            ;; "If the comment-end is a single char, adding a \ after that
            ;; `first' char won't deactivate it, so we turn such a CE into
            ;; !CS. I.e. for pascal, we turn } into !{"
            (if (not unp)
                (when (string=? (match-string 0) ce)
                  (replace-match (concat "!" cs) #t #t))
                (when (and (< (point-min) (match-beginning 0))
                           (string=? (buffer-substring
                                      (- (match-beginning 0) 1)
                                      (- (match-end 0) 1))
                                     (concat "!" cs)))
                  (backward-char 2)
                  (delete-char (- (match-end 0) (match-beginning 0)))
                  (insert ce))))
            (loop)))))

    (*comment-quote-nested-function* comment-quote-nested-default)

    ;;----------------------------------------------------------------
    ;; `comment-set-column' (`newcomment.el:799') and `comment-kill'
    ;; (`:822')
    ;;----------------------------------------------------------------
    (define-command (comment-set-column arg)
      "Set the comment column based on point.
With no ARG, set the comment column to the current column.
With just minus as arg, kill any comment on this line.
With any other arg, set comment column to indentation of the previous comment
 and then align or create a comment on this line at that column."
      (interactive "P")
      (cond
       ((eq? arg '-) (comment-kill #f))
       (arg
        (comment-normalize-vars)
        (save-excursion
          (beginning-of-line)
          (comment-search-backward)
          (beginning-of-line)
          (goto-char (comment-search-forward (line-end-position)))
          (set-buffer-local-value! (current-buffer) 'comment-column
                                   (current-column))
          (message "Comment column set to ~a" (comment-column)))
        (comment-indent))
       (else
        (set-buffer-local-value! (current-buffer) 'comment-column
                                 (current-column))
        (message "Comment column set to ~a" (comment-column)))))

    (define-command (comment-kill arg)
      "Kill the first comment on this line, if any.
With prefix ARG, kill comments on that many lines starting with this one."
      (interactive "P")
      (comment-normalize-vars)
      (let loop ((i 0) (n (prefix-numeric-value arg)))
        (when (< i n)
          (save-excursion
            (beginning-of-line)
            (let ((cs (comment-search-forward (line-end-position) #t)))
              (when cs
                (goto-char cs)
                (skip-syntax-backward " ")
                (set! cs (point))
                (comment-forward)
                (kill-region cs (if (bolp) (- (point) 1) (point)))
                (indent-according-to-mode))))
          (if arg (forward-line 1))
          (loop (+ i 1) n))))

    ;;----------------------------------------------------------------
    ;; `comment-padright' (`newcomment.el:840') and `comment-padleft'
    ;; (`:887')
    ;;----------------------------------------------------------------
    (define (%char-string c)
      ;; Elisp's `(string c)`: for `comment-padright`'s regexp arm, C
      ;; comes from `mapconcat` over a string, which is a *code point* -
      ;; Scheme's `string` takes characters, so an integer converts.
      ;;--------------------------------------------------------------
      (if (char? c) (string c) (string (integer->char c))))

    (define (comment-padright str . rest)
      ;; "Construct a string composed of STR plus `comment-padding'. It
      ;; also adds N copies of the last non-whitespace chars of STR."
      ;; (`:840')
      ;;
      ;; "Ensure that `comment-normalize-vars' has been called before you
      ;; use this."
      ;;--------------------------------------------------------------
      (let ((n (if (and (pair? rest) (car rest)) (car rest) 0))
            (padding (*comment-padding*)))
        (and (string? str)
             (string-match "\\S-" str)
             (begin
               ;; "Separate the actual string from any leading/trailing
               ;; padding"
               (string-match "\\`\\s-*\\(.*?\\)\\s-*\\'" str)
               (let* ((s (match-string 1 str))
                      (lpad (substring str 0 (match-beginning 1)))
                      (rpad (concat
                             ;; "original right padding"
                             (substring str (match-end 1))
                             (if (number? padding)
                                 (make-string
                                  (min padding (- (match-end 0)
                                                  (match-end 1)))
                                  #\space)
                                 (if (not (string-match-p "\\`\\s-" padding))
                                     ;; "If the padding isn't spaces, then
                                     ;; don't shorten the padding."
                                     padding
                                     (substring padding ; additional right padding
                                                (min (- (match-end 0)
                                                        (match-end 1))
                                                     (string-length padding)))))))
                      ;; **The character to duplicate is taken here**,
                      ;; before the MULTI test: Emacs reads it after that
                      ;; test's `string-match`, which a failed match
                      ;; leaves its previous value in (measured) but this
                      ;; tree's clears, so taking it first is the same
                      ;; answer without depending on which.
                      (last-char (string-ref str (- (match-end 1) 1)))
                      ;; "We can only duplicate C if the comment-end has
                      ;; multiple chars or if comments can be nested, else
                      ;; the comment-end `}' would be turned into `}}}'
                      ;; where only the first ends the comment and the rest
                      ;; becomes bogus junk."
                      (multi (not (and (*comment-quote-nested*)
                                       ;; "comment-end is a single char"
                                       (string-match "\\`\\s-*\\S-\\s-*\\'"
                                                     (comment-end))))))
                 (if (not (symbol? n))
                     (concat lpad s
                             (when multi (make-string n last-char))
                             rpad)
                     ;; "construct a regexp that would match anything from
                     ;; just S to any possible output of this function for
                     ;; any N."
                     (concat
                      (mapconcat (lambda (c)
                                   (concat (regexp-quote (%char-string c)) "?"))
                                 lpad) ; padding is not required
                      (regexp-quote s)
                      (if multi "+" "") ; the last char of S might be repeated
                      (mapconcat (lambda (c)
                                   (concat (regexp-quote (%char-string c)) "?"))
                                 rpad)))))))) ; padding is not required

    (define (comment-padleft str . rest)
      ;; "Construct a string composed of `comment-padding' plus STR."
      ;; (`:887')
      ;;--------------------------------------------------------------
      (let ((n (if (and (pair? rest) (car rest)) (car rest) 0))
            (padding (*comment-padding*))
            (ce (comment-end)))
        (and (string? str)
             (not (string=? "" str))
             (begin
               ;; "Only separate the left pad because we assume there is
               ;; no right pad."
               (string-match "\\`\\s-*" str)
               (let* ((s (substring str (match-end 0)))
                      (pad (concat
                            (if (not (string-match-p "\\`\\s-" padding))
                                ;; "If the padding isn't spaces, then don't
                                ;; shorten the padding."
                                padding
                                (substring padding
                                           (min (- (match-end 0)
                                                   (match-beginning 0))
                                                (string-length padding))))
                            (match-string 0 str)))
                      ;; "the first non-space char of STR"
                      (c (string-ref str (match-end 0)))
                      ;; the same rule as `comment-padright''s
                      (multi (not (and (*comment-quote-nested*)
                                       (string-match "\\`\\s-*\\S-\\s-*\\'"
                                                     ce)))))
                 (if (not (symbol? n))
                     (concat pad (when multi (make-string n c)) s)
                     ;; "Construct a regexp that would match anything from
                     ;; just S to any possible output of this function for
                     ;; any N."
                     ;;
                     ;; "We match any number of leading spaces because this
                     ;; regexp will be used for uncommenting where we might
                     ;; want to remove uncomment markers with arbitrary
                     ;; leading space (because they were aligned)."
                     (concat "\\s-*"
                             (if multi (concat (regexp-quote (string c)) "*")
                                 "")
                             (regexp-quote s))))))))

    ;;----------------------------------------------------------------
    ;; `comment-with-narrowing' (`newcomment.el:1105') - the macro
    ;;----------------------------------------------------------------
    (define-syntax comment-with-narrowing
      ;; "Execute BODY with BEG..END narrowing. Space is added (and then
      ;; removed) at the beginning for the text's indentation to be kept
      ;; as it was before narrowing."
      ;;
      ;; A macro and not a procedure, for the reason the Elisp is one:
      ;; BODY has to run *inside* the narrowing, and a thunk-taking
      ;; procedure would be the same thing spelled differently. Written
      ;; with `syntax-case` because the temporary's name (`bindent`) is
      ;; Emacs's and is built with the caller's context.
      ;;--------------------------------------------------------------
      (lambda (stx)
        (syntax-case stx ()
          ((_ beg end body ...)
           (let ((bindent (datum->syntax (syntax beg) 'bindent)))
             #`(let ((#,bindent (save-excursion (goto-char beg)
                                                (current-column))))
                 (save-restriction
                   (narrow-to-region beg end)
                   (goto-char (point-min))
                   (insert (make-string #,bindent #\space))
                   (let ((result (begin body ...)))
                     ;; "remove the bindent"
                     (save-excursion
                       (goto-char (point-min))
                       (when (looking-at " *")
                         (let ((n (min (- (match-end 0) (match-beginning 0))
                                       #,bindent)))
                           (delete-char n)
                           (set! #,bindent (- #,bindent n))))
                       (end-of-line)
                       (let ((e (point)))
                         (beginning-of-line)
                         (let loop ()
                           (when (and (> #,bindent 0)
                                      (re-search-forward "   *" e #t))
                             (let ((n (min #,bindent
                                           (- (match-end 0)
                                              (match-beginning 0)
                                              1))))
                               (goto-char (match-beginning 0))
                               (delete-char n)
                               (set! #,bindent (- #,bindent n)))
                             (loop)))))
                     result))))))))

    ;;----------------------------------------------------------------
    ;; `comment-make-bol-ws' (`newcomment.el:1067') and
    ;; `comment-make-extra-lines' (`:1075')
    ;;----------------------------------------------------------------
    (define (comment-make-bol-ws len)
      ;; "Make a white-space string of width LEN for use at BOL. When
      ;; `indent-tabs-mode' is non-nil, tab characters will be used."
      ;;--------------------------------------------------------------
      (if (and (*indent-tabs-mode*) (> (*tab-width*) 0))
          (concat (make-string (quotient len (*tab-width*)) #\tab)
                  (make-string (modulo len (*tab-width*)) #\space))
          (make-string len #\space)))

    (define (comment-make-extra-lines cs ce ccs cce min-indent max-indent
                                      . rest)
      ;; "Make the leading and trailing extra lines. This is used for
      ;; `extra-line' style (or `box' style if BLOCK is specified)."
      ;; (`:1075')
      ;;--------------------------------------------------------------
      (let ((block (and (pair? rest) (car rest)))
            (eindent 0))
        (if (not block)
            ;; "Try to match CS and CE's content so they align
            ;; aesthetically."
            (begin
              (set! ce (comment-string-strip ce #t #t))
              (when (string-match "\\(.+\\).*\n\\(.*?\\)\\1"
                                  (concat ce "\n" cs))
                (set! eindent
                      (max (- (match-end 2) (match-beginning 2)
                              (match-beginning 0))
                           0))))
            ;; "box comment"
            (let* ((width (- max-indent min-indent))
                   (s (concat cs "a=m" cce))
                   (e (concat ccs "a=m" ce))
                   (c (if (string-match ".*\\S-\\S-" cs)
                          (string-ref cs (- (match-end 0) 1))
                          (if (and (string=? (comment-end) "")
                                   (string-match ".*\\S-" cs))
                              (string-ref cs (- (match-end 0) 1))
                              #\=)))
                   (re "\\s-*a=m\\s-*")
                   (_ (string-match re s))
                   (lcs (string-length cs))
                   (fill (make-string
                          (+ width (- (match-end 0) (match-beginning 0) lcs 3))
                          c)))
              (set! cs (replace-match fill #t #t s))
              (when (and (not (string-match (comment-start-skip) cs))
                         (string-match "a=m" s))
                ;; "The whitespace around CS cannot be ignored: put it
                ;; back."
                (set! re "a=m")
                (set! fill (make-string (- width lcs) c))
                (set! cs (replace-match fill #t #t s)))
              (string-match re e)
              (set! ce (replace-match fill #t #t e))))
        (cons (concat cs "\n" (comment-make-bol-ws min-indent) ccs)
              (concat cce "\n" (comment-make-bol-ws (+ min-indent eindent)) ce))))

    ;;----------------------------------------------------------------
    ;; `comment-add' the *function* (`newcomment.el:1142')
    ;;----------------------------------------------------------------
    (define (comment-add-count arg)
      ;; "Compute the number of extra comment starter characters. (Extra
      ;; semicolons in Lisp mode, extra stars in C mode, etc.) If ARG is
      ;; non-nil, just follow ARG. If the comment starter is multi-char,
      ;; just follow ARG. Otherwise obey `comment-add'."
      ;;
      ;; **The name is `comment-add-count', not `comment-add'**, because
      ;; Emacs has both a variable and a function called `comment-add' -
      ;; a Lisp-2 - and this tree's accessor for the variable has the name
      ;; (`comment-add', above). The body is the C's.
      ;;--------------------------------------------------------------
      (if (and (not arg) (= (string-match "[ \t]*\\'" (comment-start)) 1))
          (* (comment-add) 1)
          (- (prefix-numeric-value arg) 1)))

    ;;----------------------------------------------------------------
    ;; `comment-region-internal' (`newcomment.el:1152')
    ;;----------------------------------------------------------------
    (define (comment-region-internal beg end cs ce . rest)
      ;; "Comment region BEG .. END. CS and CE are the comment start
      ;; string and comment end string, respectively; CCS and CCE are the
      ;; comment continuation strings for the start and end of lines,
      ;; respectively (default to CS and CE). BLOCK indicates that end of
      ;; lines should be marked with either CCE, CE or CS (if CE is empty)
      ;; and that those markers should be aligned. LINES indicates that an
      ;; extra lines will be used at the beginning and end of the region
      ;; for CE and CS. INDENT indicates to put CS and CCS at the current
      ;; indentation of the region rather than at left margin."
      ;;--------------------------------------------------------------
      (let* ((ccs (if (and (pair? rest) (car rest)) (car rest) #f))
             (cce (if (and (pair? rest) (pair? (cdr rest)) (cadr rest))
                      (cadr rest)
                      #f))
             (block (and (>= (length rest) 3) (list-ref rest 2)))
             (lines (and (>= (length rest) 4) (list-ref rest 3)))
             (indent (and (>= (length rest) 5) (list-ref rest 4)))
             (no-empty (not (or (eq? (*comment-empty-lines*) #t)
                                (and (*comment-empty-lines*)
                                     (= (string-length ce) 0)))))
             ;; Guile's `let*` wants `(VAR VALUE)` for every binding - a
             ;; bare VAR is a syntax error there (measured), where the C
             ;; writes `let*` with an unbound `ce-sanitized`.
             (ce-sanitized #f))
        ;; "Sanitize CE and CCE."
        (if (and (string? ce) (string=? "" ce)) (set! ce #f))
        (set! ce-sanitized ce)
        (if (and (string? cce) (string=? "" cce)) (set! cce #f))
        ;; "If CE is empty, multiline cannot be used."
        (unless ce (set! ccs #f) (set! cce #f))
        ;; "Should we mark empty lines as well?"
        (if (or ccs block lines) (set! no-empty #f))
        ;; "Make sure we have end-markers for BLOCK mode."
        (when block (unless ce (set! ce (comment-string-reverse cs))))
        ;; "If BLOCK is not requested, we don't need CCE."
        (unless block (set! cce #f))
        ;; "Continuation defaults to the same as CS and CE."
        (unless ccs (set! ccs cs) (set! cce ce))
        (save-excursion
          (goto-char end)
          ;; "If the end is not at the end of a line and the comment-end
          ;; is implicit (i.e. a newline), explicitly insert a newline."
          (unless (or ce-sanitized (eolp))
            (insert "\n")
            (indent-according-to-mode))
          (comment-with-narrowing
           beg end
           (let ((min-indent (point-max))
                 (max-indent 0))
             (goto-char (point-min))
             ;; "Quote any nested comment marker"
             (comment-quote-nested (comment-start) (comment-end) #f)
             ;; "Loop over all lines to find the needed indentations."
             (goto-char (point-min))
             (let loop ()
               (unless (looking-at "[ \t]*$")
                 (set! min-indent (min min-indent (current-indentation))))
               (end-of-line)
               (set! max-indent (max max-indent (current-column)))
               (unless (or (eobp) (begin (forward-line) #f))
                 (loop)))
             (set! max-indent
                   (+ max-indent (max (string-length cs) (string-length ccs))
                      ;; "Inserting ccs can change max-indent by (1-
                      ;; tab-width) but only if there are TABs in the
                      ;; boxed text, of course."
                      (if (save-excursion (goto-char beg)
                                          (search-forward "\t" end #t))
                          (- (*tab-width*) 1)
                          0)))
             (unless indent (set! min-indent 0))
             ;; "make the leading and trailing lines if requested"
             (when lines
               ;; "Trim trailing whitespace from cs if there's some."
               (set! cs (string-trim-right cs))
               (let ((csce (comment-make-extra-lines
                            cs ce ccs cce min-indent max-indent block)))
                 (set! cs (car csce))
                 (set! ce (cdr csce))))
             (goto-char (point-min))
             ;; "Loop over all lines from BEG to END."
             (let loop ()
               (unless (and no-empty (looking-at "[ \t]*$"))
                 (move-to-column min-indent #t)
                 (insert cs)
                 ;; "switch to CCS after the first line"
                 (set! cs ccs)
                 (end-of-line)
                 (if (eobp) (set! cce ce))
                 (when cce
                   (when block (move-to-column max-indent #t))
                   (insert cce)))
               (end-of-line)
               (unless (or (eobp) (begin (forward-line) #f))
                 (loop))))))))

    ;;----------------------------------------------------------------
    ;; `uncomment-region' (`newcomment.el:931') and its default
    ;;----------------------------------------------------------------
    (define-command (uncomment-region beg end arg)
      "Uncomment each line in the BEG .. END region.
The numeric prefix ARG can specify a number of chars to remove from the
comment delimiters."
      (interactive "*r\nP")
      (comment-normalize-vars)
      (when (> beg end) (let ((mid beg)) (set! beg end) (set! end mid)))
      ;; "Bind `comment-use-global-state' to nil. While uncommenting a
      ;; region (which works a line at a time), a comment can appear to be
      ;; included in a multi-line string, but it is actually not."
      (parameterize ((*comment-use-global-state* #f))
        (save-excursion
          ((*uncomment-region-function*) beg end arg))))

    (define (uncomment-region-default-1 beg end arg)
      ;; "Uncomment each line in the BEG .. END region. ... This function
      ;; is the default value of `uncomment-region-function'."
      ;; (`newcomment.el:947')
      ;;--------------------------------------------------------------
      (goto-char beg)
      (let ((end (copy-marker end)))
        (let* ((numarg (prefix-numeric-value arg))
               (ccs (comment-continue))
               (srei (or (comment-padright ccs 're)
                         (and (string? (comment-continue)) (comment-continue))))
               (csre (comment-padright (comment-start) 're))
               (sre (and srei (concat "^\\s-*?\\(" srei "\\)")))
               (spt #f))
          (let loop ()
            (when (and (< (point) (marker-position end))
                       (begin (set! spt (comment-search-forward
                                         (marker-position end) #t))
                              spt))
            (let* ((ipt (point))
                   ;; "Find the end of the comment."
                   (ept (begin
                          (goto-char spt)
                          (unless (or (comment-forward)
                                      ;; "Allow non-terminated comments."
                                      (eobp))
                            (error "Can't find the comment end"))
                          (point)))
                   (box #f)
                   (box-equal #f)) ; "Whether we might be using `=' for boxes."
              (save-restriction
                (narrow-to-region spt ept)
                (goto-char (point-max))
                ;; "Find the end-of-content before we mess with the rest
                ;; of the comment (which flushes the syntax-
                ;; propertization, thus impacting the work of
                ;; `comment-enter-backward')."
                (comment-enter-backward)
                (let ((end-of-content (copy-marker (point))))
                  ;; "Remove the comment-start."
                  (goto-char ipt)
                  (skip-syntax-backward " ")
                  ;; "A box-comment starts with a looong comment-start
                  ;; marker."
                  (when (and (or (and (= (- (point) (point-min)) 1)
                                      (set! box-equal #t)
                                      (looking-at "=\\{7\\}")
                                      (not (eqv? (char-before (point-max))
                                                 #\newline))
                                      (skip-chars-forward "="))
                                 (> (- (point) (point-min)
                                       (string-length (comment-start)))
                                    7))
                             (> (count-lines (point-min) (point-max)) 2))
                    (set! box #t))
                  ;; "Skip the padding. Padding can come from
                  ;; comment-padding and/or from comment-start, so we
                  ;; first check comment-start."
                  (if (or (save-excursion (goto-char (point-min))
                                          (looking-at csre))
                          (looking-at (regexp-quote (*comment-padding*))))
                      (goto-char (match-end 0)))
                  (when (and sre (looking-at (concat "\\s-*\n\\s-*" srei)))
                    (goto-char (match-end 0)))
                  (if (not arg)
                      (delete-region (point-min) (point))
                      (let ((opoint (point-marker)))
                        (skip-syntax-backward " ")
                        (delete-char (- numarg))
                        (unless (and (not (bobp))
                                     (save-excursion
                                       (goto-char (point-min))
                                       (looking-at (comment-start-skip))))
                          ;; "If there's something left but it doesn't look
                          ;; like a comment-start any more, just remove it."
                          (delete-region (point-min) opoint))))
                  (goto-char end-of-content)
                  ;; "Remove the end-comment (and leading padding and
                  ;; such)."
                  ;; "Check for special `=' used sometimes in comment-box."
                  (when (and box-equal
                             (not (eqv? (char-before (point-max)) #\newline)))
                    (let ((pos (point)))
                      ;; "skip `=' but only if there are at least 7."
                      (when (> (skip-chars-backward "=") -7)
                        (goto-char pos))))
                  (unless (looking-at "\\(\n\\|\\s-\\)*\\'")
                    (when (and (bolp) (not (bobp))) (backward-char))
                    (if (not arg)
                        (delete-region (point) (point-max))
                        (begin
                          (skip-syntax-forward " ")
                          (delete-char numarg)
                          (unless (or (eobp) (looking-at (comment-end-skip)))
                            ;; "If there's something left but it doesn't
                            ;; look like a comment-end any more, just
                            ;; remove it."
                            (delete-region (point) (point-max))))))
                  ;; "Unquote any nested end-comment."
                  (comment-quote-nested (comment-start) (comment-end) #t)
                  ;; "Eliminate continuation markers as well."
                  (when sre
                    (let* ((cce (comment-string-reverse
                                 (or (comment-continue) (comment-start))))
                           (erei (and box (comment-padleft cce 're)))
                           (ere (and erei (concat "\\(" erei "\\)\\s-*$"))))
                      (goto-char (point-min))
                      (let loop ()
                        (when (begin
                                (if (and ere
                                         (re-search-forward ere
                                                            (line-end-position)
                                                            #t))
                                    (replace-match "" #t #t #f
                                                   (if (match-end 2) 2 1))
                                    (set! ere #f))
                                (forward-line 1)
                                (re-search-forward sre (line-end-position) #t))
                          (replace-match "" #t #t #f (if (match-end 2) 2 1))
                          (loop))))
                  ;; "Go to the end for the next comment."
                  (goto-char (point-max))))
              ;; "Remove any obtrusive spaces left preceding a tab at
              ;; `spt'."
              (when (and (eqv? (char-after spt) #\tab)
                         (eqv? (char-before spt) #\space)
                         (> (*tab-width*) 0))
                (save-excursion
                  (goto-char spt)
                  (let* ((fcol (current-column))
                         (slim (- (point) (modulo fcol (*tab-width*)))))
                    (delete-char (- (skip-chars-backward " " slim)))))))
              (loop)))
        (set-marker end #f)))))

    (define (uncomment-region-default beg end arg)
      ;; "Uncomment each line in the BEG .. END region. ... This function
      ;; is the default value of `uncomment-region-function'."
      ;;
      ;; The C wraps the work in `combine-change-calls' when
      ;; `comment-combine-change-calls' says so; that function is
      ;; `replace.el`'s and is not ported, so the call is direct. The
      ;; variable is carried and read nowhere.
      ;;--------------------------------------------------------------
      (uncomment-region-default-1 beg end arg))

    (*uncomment-region-function* uncomment-region-default)

    ;;----------------------------------------------------------------
    ;; `comment-region' (`newcomment.el:1241') and its default
    ;;----------------------------------------------------------------
    (define-command (comment-region beg end arg)
      "Comment or uncomment each line in the region.
With just \\[universal-argument] prefix arg, uncomment each line in region BEG .. END.
Numeric prefix ARG means use ARG comment characters.
If ARG is negative, delete that many comment characters instead.

The strings used as comment starts are built from `comment-start'
and `comment-padding'; the strings used as comment ends are built
from `comment-end' and `comment-padding'.

By default, the `comment-start' markers are inserted at the
current indentation of the region, and comments are terminated on
each line (even for syntaxes in which newline does not end the
comment and blank lines do not get comments).  This can be
changed with `comment-style'."
      (interactive "*r\nP")
      (comment-normalize-vars)
      (if (> beg end) (let ((mid beg)) (set! beg end) (set! end mid)))
      (save-excursion
        ;; "FIXME: maybe we should call uncomment depending on ARG."
        ((*comment-region-function*) beg end arg)))

    (define (comment-region-default-1 beg end arg)
      ;; "The body of `comment-region-default' (`newcomment.el:1263')."
      ;;--------------------------------------------------------------
      (let* ((numarg (prefix-numeric-value arg))
             (style (cdr (assoc (*comment-style*) comment-styles)))
             (lines (list-ref style 2))
             (block (list-ref style 1))
             (multi (list-ref style 0)))
        ;; "We use `chars' instead of `syntax' because `\n' might be of
        ;; end-comment syntax rather than of whitespace syntax.
        ;; sanitize BEG and END"
        (goto-char beg) (skip-chars-forward " \t\n\r") (beginning-of-line)
        (set! beg (max beg (point)))
        (goto-char end) (skip-chars-backward " \t\n\r") (end-of-line)
        (set! end (min end (point)))
        (if (>= beg end) (error "Nothing to comment"))
        ;; "sanitize LINES"
        (set! lines
              (and lines ;; multi
                   (begin (goto-char beg) (beginning-of-line)
                          (skip-syntax-forward " ")
                          (>= (point) beg))
                   (begin (goto-char end) (end-of-line)
                          (skip-syntax-backward " ")
                          (<= (point) end))
                   (or block (not (string=? "" (comment-end))))
                   (or block (begin (goto-char beg)
                                    (re-search-forward "$" end #t)))))
        ;; "don't add end-markers just because the user asked for `block'"
        (unless (or lines (string=? "" (comment-end))) (set! block #f))
        (cond
         ((pair? arg) (uncomment-region beg end #f))
         ((< numarg 0) (uncomment-region beg end (- numarg)))
         (else
          (let ((multi-char (not (= (string-match "[ \t]*\\'" (comment-start)) 1)))
                (indent #f)
                (triple #f))
            (if (eq? (list-ref style 3) 'multi-char)
                (save-excursion
                  (goto-char beg)
                  (set! indent multi-char)
                  ;; "Triple if we will put the comment starter at the
                  ;; margin and the first line of the region isn't
                  ;; indented at least two spaces."
                  (set! triple (and (not multi-char)
                                    (looking-at "\t\\|  "))))
                (set! indent (list-ref style 3)))
            ;; "In Lisp and similar modes with one-character comment
            ;; starters, double it by default if `comment-add' says so.
            ;; If it isn't indented, triple it."
            (if (and (not arg) (not multi-char))
                (set! numarg (* (comment-add) (if triple 2 1)))
                (set! numarg (- (prefix-numeric-value arg) 1)))
            (comment-region-internal
             beg end
             (let ((s (comment-padright (comment-start) numarg)))
               (if (string-match (comment-start-skip) s) s
                   (comment-padright (comment-start))))
             (let ((s (comment-padleft (comment-end) numarg)))
               (and s (if (string-match (comment-end-skip) s) s
                          (comment-padright (comment-end)))))
             (if multi
                 (or (comment-padright (comment-continue) numarg)
                     ;; "`comment-padright' returns nil when
                     ;; `comment-continue' contains only whitespace"
                     (and (string? (comment-continue)) (comment-continue)))
                 #f)
             (if multi
                 (comment-padleft (comment-string-reverse (comment-continue))
                                  numarg)
                 #f)
             block lines indent))))))

    (define (comment-region-default beg end arg)
      ;; "The default value of `comment-region-function'."
      ;;
      ;; As `uncomment-region-default': `combine-change-calls` is not
      ;; ported, so the C's two arms are one.
      ;;--------------------------------------------------------------
      (comment-region-default-1 beg end arg))

    (*comment-region-function* comment-region-default)

    ;;----------------------------------------------------------------
    ;; `comment-box' (`newcomment.el:1350'), `comment-only-p' (`:1361'),
    ;; `comment-or-uncomment-region' (`:1369'), `comment-dwim' (`:1380')
    ;; and `comment-line' (`:1583')
    ;;----------------------------------------------------------------
    (define-command (comment-box beg end arg)
      "Comment out the BEG .. END region, putting it inside a box.
The numeric prefix ARG specifies how many characters to add to begin- and
end- comment markers additionally to what variable `comment-add' already
specifies."
      (interactive "*r\np")
      (comment-normalize-vars)
      (let ((comment-style (if (cadr (assoc (*comment-style*) comment-styles))
                               'box-multi 'box)))
        (parameterize ((*comment-style* comment-style))
          (comment-region beg end (+ (comment-add) arg)))))

    (define (comment-only-p beg end)
      ;; "Return non-nil if the text between BEG and END is all comments."
      ;;--------------------------------------------------------------
      (save-excursion
        (goto-char beg)
        (comment-forward (point-max))
        (<= end (point))))

    (define-command (comment-or-uncomment-region beg end arg)
      "Call `comment-region', unless the region only consists of comments,
in which case call `uncomment-region'.  If a prefix arg is given, it
is passed on to the respective function."
      (interactive "*r\nP")
      (comment-normalize-vars)
      (if (comment-only-p beg end)
          (uncomment-region beg end arg)
          (comment-region beg end arg)))

    (define-command (comment-dwim arg)
      "Call the comment command you want (Do What I Mean).
If the region is active and `transient-mark-mode' is on, call
`comment-region' (unless it only consists of comments, in which
case it calls `uncomment-region'); in this case, prefix numeric
argument ARG specifies how many characters to remove from each
comment delimiter (so don't specify a prefix argument whose value
is greater than the total length of the comment delimiters).
Else, if the current line is empty, call `comment-insert-comment-function'
if it is defined, otherwise insert a comment and indent it.
Else, if a prefix ARG is specified, call `comment-kill'; in this
case, prefix numeric argument ARG specifies on how many lines to kill
the comments.
Else, call `comment-indent'.
You can configure `comment-style' to change the way regions are commented."
      (interactive "*P")
      (comment-normalize-vars)
      (if (use-region-p)
          (comment-or-uncomment-region (region-beginning) (region-end) arg)
          (if (save-excursion (beginning-of-line)
                              (not (looking-at "\\s-*$")))
              ;; "FIXME: If there's no comment to kill on this line and
              ;; ARG is specified, calling comment-kill is not very
              ;; clever."
              (if arg (comment-kill (and (integer? arg) arg)) (comment-indent))
              ;; "Inserting a comment on a blank line. comment-indent calls
              ;; c-i-c-f if needed in the non-blank case."
              (if (comment-insert-comment-function)
                  ((comment-insert-comment-function))
                  (let ((add (comment-add-count arg)))
                    ;; "Some modes insist on keeping column 0 comment in
                    ;; column 0 so we need to move away from it before
                    ;; inserting the comment."
                    (indent-according-to-mode)
                    (insert (comment-padright (comment-start) add))
                    (save-excursion
                      (unless (string=? "" (comment-end))
                        (insert (comment-padleft (comment-end) add)))
                      (indent-according-to-mode)))))))

    (define-command (comment-line n)
      "Comment or uncomment current line and leave point after it.
With positive prefix, apply to N lines including current one.
With negative prefix, apply to -N lines above.  Also, further
consecutive invocations of this command will inherit the negative
argument.

If region is active, comment lines in active region instead.
Unlike `comment-dwim', this always comments whole lines."
      (interactive "p")
      (if (use-region-p)
          (comment-or-uncomment-region
           (save-excursion
             (goto-char (region-beginning))
             (line-beginning-position))
           (save-excursion
             (goto-char (region-end))
             (line-end-position))
           #f)
          (begin
            (when (and (eq? (*last-command*) 'comment-line-backward)
                       (and (integer? n) (>= n 0))) ; `natnump'
              (set! n (- n)))
            (let ((range (list (line-beginning-position)
                               (begin (goto-char (line-end-position n))
                                      (point)))))
              (comment-or-uncomment-region
               (apply min range)
               (apply max range)
               #f))
            (forward-line 1)
            (back-to-indentation)
            (unless (and (integer? n) (>= n 0)) ; `natnump'
              ;; Emacs's `(setq this-command 'comment-line-backward)': the
              ;; command *is* `comment-line` here, so the symbol is stored
              ;; in `*this-command*` directly - the loop rotates it to
              ;; `last-command` and nothing ever calls it.
              (*this-command* 'comment-line-backward)))))

    ;; `bindings.el:1603', `:1606' and `:1607'.
    (define-key *default-keymap* (kbd "M-;") comment-dwim)
    (define-key *default-keymap* (kbd "C-x ;") comment-set-column)
    (define-key *default-keymap* (kbd "C-x C-;") comment-line)

    (define-custom *comment-auto-fill-only-comments* #f
      "Non-nil means to only auto-fill inside comments.
This has no effect in modes that do not define a comment syntax."
      :type 'boolean
      :group 'fill)

    ))
