(define-library (schemacs progmodes cc-cmds)
  ;; `lisp/progmodes/cc-cmds.el' - the editing commands: the indentation
  ;; command layer, the defun movements, and the statement/sentence
  ;; movements with the comment-indent and CPP-conditional commands. The
  ;; electric keys and the paragraph-filling half still follow.
  ;;
  ;; Ported, in Emacs's file order: `c-fix-backslashes', `c-indent-line',
  ;; `c-newline-and-indent', `c-show-syntactic-information',
  ;; `c-syntactic-information-on-region', `c-update-modeline', the six
  ;; toggles, `c-indent-command', `c-indent-exp', `c-indent-region',
  ;; `c-fn-region-is-active-p', `c-indent-line-or-region', the
  ;; progress-reporting helpers, the `c-backslash-region' family, and -
  ;; the 2026-11-24 pass - `c-backward-into-nomenclature' (a stub; see
  ;; below), `c-scope-operator', `c-in-function-trailer-p',
  ;; `c-where-wrt-brace-construct', `c-backward-to-nth-BOF-{',
  ;; `c-narrow-to-most-enclosing-decl-block',
  ;; `c-widen-to-enclosing-decl-scope', `c-beginning-of-defun',
  ;; `c-forward-to-nth-EOF-;-or-}', `c-end-of-defun', `c-defun-name-1',
  ;; `c-defun-name', `c-declaration-limits-1', `c-declaration-limits',
  ;; `c-defun-name-and-limits', `c-display-defun-name',
  ;; `c-mark-function' and `c-cpp-define-name', and - the second
  ;; 2026-11-24 pass - `c-in-comment-line-prefix-p',
  ;; `c-narrow-to-comment-innards', the four sentence movers,
  ;; `c-ascertain-preceding-literal'/`-following-literal',
  ;; `c-after-statement-terminator-p', `c-back-over-illiterals',
  ;; `c-forward-over-illiterals', `c-one-line-string-p',
  ;; `c-beginning-of-statement', `c-end-of-statement',
  ;; `c-calc-comment-indent', `c-comment-indent', `c-outline-level',
  ;; `c-scan-conditionals' and the six conditional commands.
  ;;
  ;; **Not carried yet**, each with what it waits for:
  ;;
  ;;   * every `c-electric-*' command and the `c-hanging-*' machinery
  ;;     they drive (`c-point-syntax', `c-brace-newlines',
  ;;     `c-try-one-liner', `c-do-brace-electrics') - the next tranche -
  ;;     and with them the file's `mapc`(`put SYM 'delete-selection ...)
  ;;     block (`cc-cmds.el:3231'), which marks those commands for
  ;;     `delete-selection-mode`/`pending-del`, neither of which exists
  ;;     here;
  ;;   * `c-backward-into-nomenclature' forwards to `subword.el''s
  ;;     `subword-backward' or `cc-subword.el''s `c-backward-subword',
  ;;     and neither library is ported; the command is a stub that
  ;;     names the gap (`c-beginning-of-objc-method-header''s shape);
  ;;   * `c-indent-new-comment-line', `c-context-line-break' and the
  ;;     `c-mask-paragraph' filling half;
  ;;   * `electric-indent-mode' does not exist here, so
  ;;     `c-toggle-electric-state''s `(when (fboundp
  ;;     'electric-indent-local-mode) ...)' sync and
  ;;     `c-basic-common-init''s `electric-indent-inhibit' have nothing
  ;;     to call; Emacs older than 24.4 behaves the same way;
  ;;   * `c-subword-mode' is not ported, so `c-update-modeline''s `w'
  ;;     flag is never set (`(boundp 'c-subword-mode)' is nil in Emacs
  ;;     until that minor mode loads).
  ;;
  ;; **Representation departures**, all this tree's usual ones:
  ;;
  ;;   * `c-fix-backslashes' is `let'-bound (`cc-cmds.el:57'), so it is
  ;;     the parameter `*c-fix-backslashes*';
  ;;   * `c-parsing-error' and `c-indent-region''s inner binding of it
  ;;     are a buffer-local variable's `let', which is
  ;;     `call-with-buffer-local' (`buffer.scm`);
  ;;   * `c-while-widening-to-decl-block' (`cc-cmds.el:1841') is
  ;;     Emacs's macro relying on the caller's *dynamic* bindings of
  ;;     `paren-state', `lim' and `where'. A Scheme macro's template
  ;;     cannot see a caller's lexical ones, so it is a local
  ;;     `letrec-syntax' inside `c-beginning-of-defun',
  ;;     `c-end-of-defun' and `c-defun-name-and-limits' - the
  ;;     `c-bos-*' automaton's shape. Its two clauses are Emacs's
  ;;     optional NO-WHERE;
  ;;   * `c-forward-to-nth-EOF-;-or-}' keeps Emacs's name, spelled
  ;;     `#{c-forward-to-nth-EOF-;-or-\x7d;}#': Guile's reader rejects
  ;;     `\;' in an identifier ("invalid character in escape
  ;;     sequence"), and `#{...}#' is the tree's escape for a symbol a
  ;;     reader would otherwise split;
  ;;   * `(eq (char-before) ?X)' and `(eq (char-after) ?X)' answer nil
  ;;     at the accessible buffer's edges in Emacs, and nil is false;
  ;;     here `char-before'/`char-after' answer #f there and `char=?'
  ;;     would raise, so the two tests are `%c-char-before=?' and
  ;;     `%c-char-after=?';
  ;;   * `this-command' and `last-command' are the parameters
  ;;     `*this-command*' and `*last-command*', whose values are the
  ;;     bound procedures;
  ;;   * Emacs's `(c-save-buffer-state (beginning-of-defun-function
  ;;     end-of-defun-function ... case-fold-search) ...)' binds
  ;;     special variables; the two defun-function parameters and
  ;;     `*case-fold-search*' are `parameterize'd around the macro
  ;;     instead (the plain locals stay in its let*);
  ;;   * the two `paragraph-\(start\|separate\)' bindings in the
  ;;     string sentence movers are `call-with-buffer-local', Emacs
  ;;     `let'-binding a buffer-local variable;
  ;;   * `c-calc-comment-indent''s and `c-scan-conditionals'' `cond's get
  ;;     explicit `(else #f)': a cond with no matching clause answers the
  ;;     unspecified value here, which is true, where Emacs's answers
  ;;     nil. Likewise `c-comment-indent''s
  ;;     `c-indent-comments-syntactically-p' test is `%c-true` - the
  ;;     accessor answers the style's nil as `()`, which is true;
  ;;   * `c-sentence-end' (`cc-defs.el:572') is in `cc-defs', as its
  ;;     macro is, calling paragraphs' `(sentence-end)';
  ;;   * `c-outline-level''s `buffer-invisibility-spec' binding is not
  ;;     carried: there is no invisibility here for `current-column' to
  ;;     ignore;
  ;;   * `(run-hooks 'c-special-indent-hook)' needs the two things the
  ;;     tree's `run-hooks' cannot do - the `t' that marks a
  ;;     buffer-local hook (`subr.el:2317') and the symbol entries the
  ;;     style data holds - so `c-run-special-indent-hook' below is the
  ;;     C's `run_hook_with_args' (`eval.c:2999') for this one hook.
  (import
    (scheme base)
    (only (guile) caddr)
    (only (schemacs core syntax-macros) when-e unless-e while-e setq prog1)
    (only (schemacs progmodes cc-defs)
          c-save-buffer-state c-with-string-fences
          c-put-overlay c-delete-overlay c-font-lock-flush
          c-region-is-active-p c-keep-region-active
          c-forward-sexp c-backward-sexp c-safe c-langelem-pos c-langelem-2nd-pos
          c-down-list-forward c-up-list-forward
          c-looking-at-non-alphnumspace
          c-major-mode-is
          c-go-list-forward c-go-list-backward c-go-up-list-forward
          c-sentence-end c-skip-ws-forward c-skip-ws-backward %c-true)
    (only (schemacs progmodes cc-vars)
          *c-syntactic-indentation* c-syntactic-indentation
          set!c-syntactic-indentation *c-syntactic-context*
          *c-tab-always-indent* *c-insert-tab-function*
          *c-echo-syntactic-information-p* *c-auto-align-backslashes*
          *c-backspace-function* *c-delete-function*
          *c-electric-pound-behavior* *c-progress-interval*
          *c-max-one-liner-length* *c-cpp-indent-to-body-directives*
          *c-mark-wrong-style-of-comment*
          *c-special-indent-hook* c-special-indent-hook
          c-block-comment-flag set!c-block-comment-flag
          c-basic-offset c-backslash-column c-backslash-max-column
          *c-defun-tactic*
          c-indent-comment-alist c-indent-comments-syntactically-p
          c-comment-only-line-offset c-current-comment-prefix
          c-string-par-start c-string-par-separate
          c-sentence-end-with-esc-eol)
    (only (schemacs progmodes cc-engine)
          c-guess-basic-syntax c-get-syntactic-indentation
          c-shift-line-indentation c-parsing-error set!c-parsing-error
          c-echo-parsing-error c-calculate-state
          c-electric-flag set!c-electric-flag
          c-auto-newline set!c-auto-newline
          c-hungry-delete-key set!c-hungry-delete-key
          c-query-macro-start c-query-and-set-macro-start
          c-beginning-of-macro c-end-of-macro c-in-literal
          c-point
          *c-macro-start*
          c-lineup-function %c-langvar
          c-parse-state c-least-enclosing-brace c-most-enclosing-decl-block
          c-safe-position c-pull-open-brace c-whack-state-after
          c-in-knr-argdecl c-end-of-decl-1 c-beginning-of-decl-1
          c-syntactic-re-search-forward c-syntactic-skip-backward
          c-forward-syntactic-ws c-backward-syntactic-ws
          c-forward-decl-or-cast-1 c-forward-declarator
          c-forward-token-2 c-backward-token-2 c-literal-start
          c-forward-comments c-forward-single-comment c-backward-single-comment
          c-literal-type c-literal-limits c-collect-line-comments
          c-looking-at-special-brace-list c-at-vsemi-p
          c-backward-comments
          c-string-limit-regexp c-ws*-string-limit-regexp c-add-syntax)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          call-with-buffer-local local-variable-p mode-name set!mode-name
          *case-fold-search*)
    ;; `beginning-of-line' and `end-of-line' are `cmds.c`'s commands.
    (only (schemacs cmds)
          beginning-of-line end-of-line backward-char forward-char
          delete-char)
    (only (schemacs command)
          define-command current-prefix-arg prefix-numeric-value)
    (only (schemacs editfns)
          bobp bolp eobp eolp char-before char-after point point-min
          point-max point-marker goto-char
          forward-line insert insert-and-inherit
          delete-region save-excursion message format
          line-beginning-position widen region-beginning region-end
          buffer-substring-no-properties
          ;; `narrow-to-region' and `save-restriction' are `editfns.c`'s
          ;; here (`buffer.scm` is below them).
          narrow-to-region save-restriction)
    (only (schemacs indentc)
          current-column current-indentation indent-to move-to-column)
    (only (schemacs character) *tab-width*)
    (only (schemacs indent)
          indent-according-to-mode)
    (only (schemacs simple)
          delete-horizontal-space insert-newline back-to-indentation
          push-mark exchange-point-and-mark kill-new count-lines
          *this-command* *last-command*)
    (only (schemacs core lisp-mode) indent-code-rigidly)
    (only (schemacs core lisp) forward-sexp backward-sexp down-list
          forward-list up-list *beginning-of-defun-function*
          *end-of-defun-function*)
    (only (schemacs textmodes paragraphs)
          forward-paragraph paragraph-start paragraph-separate)
    (only (schemacs intervals) put)
    (only (schemacs marker)
          make-marker set-marker copy-marker markerp marker-position
          set-marker-insertion-type)
    (only (schemacs newcomment)
          comment-start comment-end set!comment-start set!comment-end
          indent-for-comment comment-column)
    (only (schemacs search) looking-at match-end match-beginning match-string
          match-string-no-properties string-match save-match-data
          re-search-backward re-search-forward)
    (only (schemacs syntax)
          skip-chars-forward skip-chars-backward parse-partial-sexp
          scan-sexps char-syntax skip-syntax-forward skip-syntax-backward)
    (only (schemacs subr) run-hooks car-safe cdr-safe)
    (only (schemacs data) aref aset /=)
    ;; `c-progress-*' reads the clock (`(time-convert nil 'integer)').
    (only (schemacs timefns) current-time time-convert)
    (only (schemacs fns) concat)
    (only (schemacs font-lock) font-lock-mode-on?)
    (only (schemacs keyboard) sit-for)
    (only (schemacs xdisp) force-mode-line-update))

  (export
   *c-fix-backslashes*
   c-indent-line c-newline-and-indent
   c-show-syntactic-information c-syntactic-information-on-region
   c-update-modeline
   c-toggle-syntactic-indentation c-toggle-auto-newline
   c-toggle-hungry-state c-toggle-auto-hungry-state
   c-toggle-electric-state c-toggle-comment-style
   c-indent-command c-indent-exp c-indent-region
   c-fn-region-is-active-p c-indent-line-or-region
   c-progress-info c-progress-init c-progress-update c-progress-fini
   c-backslash-region c-append-backslashes-forward
   c-delete-backslashes-forward
   c-backward-into-nomenclature c-scope-operator
   c-in-function-trailer-p c-where-wrt-brace-construct
   c-backward-to-nth-BOF-{ c-narrow-to-most-enclosing-decl-block
   c-widen-to-enclosing-decl-scope c-beginning-of-defun
   #{c-forward-to-nth-EOF-;-or-\x7d;}# c-end-of-defun
   c-defun-name-1 c-defun-name c-declaration-limits-1 c-declaration-limits
   c-defun-name-and-limits c-display-defun-name c-mark-function
   c-cpp-define-name c-indent-defun
   c-in-comment-line-prefix-p c-narrow-to-comment-innards
   c-beginning-of-sentence-in-comment c-end-of-sentence-in-comment
   c-beginning-of-sentence-in-string c-end-of-sentence-in-string
   c-ascertain-preceding-literal c-ascertain-following-literal
   c-after-statement-terminator-p c-back-over-illiterals
   c-forward-over-illiterals c-one-line-string-p
   c-beginning-of-statement c-end-of-statement
   c-calc-comment-indent c-comment-indent c-outline-level
   c-up-conditional c-up-conditional-with-else c-down-conditional
   c-down-conditional-with-else c-backward-conditional
   c-forward-conditional c-scan-conditionals
   c-run-special-indent-hook)

  (begin

    ;; ---------------------------------------------------------------
    ;; `c-fix-backslashes' (`cc-cmds.el:57')
    ;;--------------------------------------------------------------
    ;; "`c-fix-backslashes' is set (to t) whenever the line is fixed
    ;; up (see below), and it is only after the line is fixed up that
    ;; the line continuation backslash can be aligned." It is
    ;; `let'-bound by `c-indent-line', `c-newline-and-indent' and
    ;; `c-indent-region', and set inside those bodies - a parameter is
    ;; the tree's spelling.
    (define *c-fix-backslashes* (make-parameter #t))

    ;; ---------------------------------------------------------------
    ;; `c-indent-line' (`cc-cmds.el:59')
    ;;--------------------------------------------------------------
    (define (c-indent-line . rest)
      ;; "Indent the current line according to the syntactic context,
      ;; if `c-syntactic-indentation' is non-nil. Optional SYNTAX is the
      ;; syntactic information for the current line. Be silent about
      ;; syntactic errors if the optional argument QUIET is non-nil, even
      ;; if `c-report-syntactic-errors' is non-nil. Normally the position
      ;; of point is used to decide where the old indentation is on a
      ;; lines that is otherwise empty (ignoring any line continuation
      ;; backslash), but that's not done if IGNORE-POINT-POS is non-nil.
      ;; Returns the amount of indentation change (in columns)."
      ;;
      ;; A procedure rather than a command: Emacs gives it no
      ;; interactive specification.
      (let ((line-cont-backslash (save-excursion
                                    (end-of-line)
                                    (eq? (char-before) #\\))))
        (parameterize ((*c-fix-backslashes* (*c-fix-backslashes*)))
          (let ((syntax (if (pair? rest) (car rest) #f))
                (quiet (if (and (pair? rest) (pair? (cdr rest)))
                           (car (cdr rest))
                           #f))
                (ignore-point-pos (if (and (pair? rest)
                                           (pair? (cdr rest))
                                           (pair? (cdr (cdr rest))))
                                      (car (cdr (cdr rest)))
                                      #f))
                (bs-col #f)
                (shift-amt #f))
            (when (and (not ignore-point-pos)
                       (save-excursion
                         (beginning-of-line)
                         (looking-at (if line-cont-backslash
                                         ;; Don't use "\\s " - ^L doesn't
                                         ;; count as WS here
                                         "\\([ \t]*\\)\\\\$"
                                         "\\([ \t]*\\)$")))
                       (<= (point) (match-end 1)))
              ;; Delete all whitespace after point if there's only
              ;; whitespace on the line, so that any code that does
              ;; back-to-indentation or similar gets the current column
              ;; in this case. If this removes a line continuation
              ;; backslash it'll be restored at the end.
              (unless (*c-auto-align-backslashes*)
                ;; Should try to keep the backslash alignment in this
                ;; case.
                (save-excursion
                  (goto-char (match-end 0))
                  (set! bs-col (- (current-column) 1))))
              (delete-region (point) (match-end 0))
              (*c-fix-backslashes* #t))
            (if (c-syntactic-indentation)
                (set!c-parsing-error
                 (or (call-with-buffer-local
                      'c-parsing-error #f
                      (lambda ()
                        (parameterize ((*c-syntactic-context*
                                        (or syntax (*c-syntactic-context*))))
                          (c-save-buffer-state ((indent #f))
                            (unless (*c-syntactic-context*)
                              (*c-syntactic-context* (c-guess-basic-syntax)))
                            (set! indent (c-get-syntactic-indentation
                                          (*c-syntactic-context*)))
                            (and (not (c-echo-parsing-error quiet))
                                 (*c-echo-syntactic-information-p*)
                                 (message "syntax: %s, indent: %d"
                                          (*c-syntactic-context*) indent))
                            (set! shift-amt (- indent (current-indentation))))
                          (c-shift-line-indentation shift-amt)
                          (c-run-special-indent-hook)
                          (c-parsing-error))))
                     (c-parsing-error)))
                (let ((indent 0))
                  (save-excursion
                    (while-e (and (= (forward-line -1) 0)
                                  (if (looking-at "\\s *\\\\?$")
                                      #t
                                    (begin
                                      (set! indent (current-indentation))
                                      #f)))))
                  (set! shift-amt (- indent (current-indentation)))
                  (c-shift-line-indentation shift-amt)))
            (when (and (*c-fix-backslashes*) line-cont-backslash)
              (if bs-col
                  (save-excursion
                    (indent-to bs-col)
                    (insert #\\))
                  (when (*c-auto-align-backslashes*)
                    ;; Realign the line continuation backslash.
                    (c-backslash-region (point) (point) #f #t))))
            shift-amt))))

    ;; ---------------------------------------------------------------
    ;; `c-newline-and-indent' (`cc-cmds.el:137')
    ;;--------------------------------------------------------------
    (define (c-newline-and-indent . newline-arg-args)
      ;; "Insert a newline and indent the new line. This function fixes
      ;; line continuation backslashes if inside a macro, and takes care
      ;; to set the indentation before calling `indent-according-to-mode',
      ;; so that lineup functions like `c-lineup-dont-change' works
      ;; better."
      ;;
      ;; TODO: Backslashes before eol in comments and literals aren't
      ;; kept intact.
      (let ((newline-arg (if (pair? newline-arg-args)
                             (car newline-arg-args)
                             #f)))
        (parameterize ((*c-macro-start* (c-query-macro-start))
                       ;; Avoid calling c-backslash-region from
                       ;; c-indent-line if it's called during the newline
                       ;; call, which can happen due to
                       ;; c-electric-continued-statement, for example. We
                       ;; also don't want any backslash alignment from
                       ;; indent-according-to-mode.
                       (*c-fix-backslashes* #f))
          (let ((has-backslash #f) (insert-backslash #f)
                (start #f) (col #f))
            (save-excursion
              (beginning-of-line)
              (set! start (point))
              (while-e (and (looking-at "[ \t]*\\\\?$")
                            (= (forward-line -1) 0)))
              (set! col (current-indentation)))
            (when (*c-macro-start*)
              (if (and (eolp) (eq? (char-before) #\\))
                  (begin (set! insert-backslash #t)
                         (set! has-backslash #t))
                  (set! has-backslash
                        (eq? (char-before (c-point 'eol)) #\\))))
            (insert-newline newline-arg)
            (indent-to col)
            (when (*c-macro-start*)
              (if insert-backslash
                  (begin
                    ;; The backslash stayed on the previous line. Insert
                    ;; one before calling c-backslash-region, so that
                    ;; bs-col-after-end in it works better. Fixup the
                    ;; backslashes on the newly inserted line.
                    (insert #\\)
                    (backward-char 1)
                    (c-backslash-region (point) (point) #f #t))
                  ;; The backslash moved to the new line, if there was
                  ;; any. Let c-backslash-region fix a backslash on the
                  ;; previous line, and the one that might be on the new
                  ;; line. c-auto-align-backslashes is intentionally
                  ;; ignored here; maybe the moved backslash should be
                  ;; left alone if it's set, but we fix both lines on the
                  ;; grounds that the old backslash has been moved anyway
                  ;; and is now in a different context.
                  (c-backslash-region start (if has-backslash (point) start)
                                      #f #t)))
            (when-e (c-syntactic-indentation)
              ;; Reindent syntactically. The indentation done above is
              ;; not wasted, since c-indent-line might look at the
              ;; current indentation.
              (parameterize ((*c-syntactic-context*
                              (c-save-buffer-state ()
                                (c-guess-basic-syntax))))
                ;; We temporarily insert another line break, so that
                ;; the lineup functions will see the line as empty.
                ;; That makes e.g. c-lineup-cpp-define more intuitive
                ;; since it then proceeds to the preceding line in this
                ;; case.
                (insert #\newline)
                (delete-horizontal-space #f)
                (set! start (- (point-max) (point)))
                (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (backward-char 1)
                   (indent-according-to-mode))
                 (lambda ()
                   (goto-char (- (point-max) start))
                   (delete-char -1))))
              (when-e has-backslash
                ;; Must align the backslash again after reindentation.
                ;; The c-backslash-region call above can't be optimized
                ;; to ignore this line, since it then won't align
                ;; correctly with the lines below if the first line in
                ;; the macro is broken.
                (c-backslash-region (point) (point) #f #t)))))))

    ;; ---------------------------------------------------------------
    ;; `c-show-syntactic-information' (`cc-cmds.el:211')
    ;;--------------------------------------------------------------
    (define-command (c-show-syntactic-information arg)
      "Show syntactic information for current line.
With universal argument, inserts the analysis as a comment on that line."
      (interactive "P")
      (c-with-string-fences
       (let* ((c-parsing-error #f)
              (syntax (if (*c-syntactic-context*)
                          ;; Use `c-syntactic-context' in the same way as
                          ;; `c-indent-line', to be consistent.
                          (*c-syntactic-context*)
                          (c-save-buffer-state ()
                            (c-guess-basic-syntax)))))
         (if (not (pair? arg))
             (let ((elem #f) (pos #f) (ols '()))
               (message "Syntactic analysis: %s" syntax)
               (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (while-e (pair? syntax)
                           (set! elem (car syntax))
                           (set! syntax (cdr syntax))
                           (when-e (set! pos (c-langelem-pos elem))
                                    (set! ols (cons (c-put-overlay
                                                     pos (+ pos 1)
                                                     'face 'highlight)
                                                    ols)))
                           (when-e (set! pos (c-langelem-2nd-pos elem))
                                    (set! ols (cons (c-put-overlay
                                                     pos (+ pos 1)
                                                     'face 'secondary-selection)
                                                    ols))))
                  (sit-for 10))
                (lambda ()
                  (while-e (pair? ols)
                           (c-delete-overlay (car ols))
                           (set! ols (cdr ols))))))
             (begin
               (indent-for-comment)
               (insert-and-inherit (format "%s" syntax)))))
       (c-keep-region-active)))

    ;; ---------------------------------------------------------------
    ;; `c-syntactic-information-on-region' (`cc-cmds.el:246')
    ;;--------------------------------------------------------------
    (define-command (c-syntactic-information-on-region from to)
      "Insert a comment with the syntactic analysis on every line in the region."
      (interactive "*r")
      (save-excursion
        (save-restriction
          (narrow-to-region from to)
          (goto-char (point-min))
          (while-e (not (eobp))
                   (c-show-syntactic-information '(0))
                   (forward-line 1)))))

    ;; ---------------------------------------------------------------
    ;; Minor mode functions (`cc-cmds.el:261'-`:403')
    ;;--------------------------------------------------------------
    ;; `c-block-comment-flag' (`cc-cmds.el:261') lives in cc-vars - a
    ;; named placement there, because `cc-fonts' reads it.

    (define-command (c-update-modeline)
      "Update the modeline string for C modes."
      (let* ((fmt (format "/%s%s%s%s%s"
                          (if (c-block-comment-flag) "*" "/")
                          (if (c-electric-flag) "l" "")
                          (if (and (c-electric-flag) (c-auto-newline))
                              "a" "")
                          (if (c-hungry-delete-key) "h" "")
                          ;; `(cc-)subword' might not be loaded.
                          ;; `c-subword-mode' is not ported, so the `w'
                          ;; flag never appears - see the file header.
                          ""))
             ;; FIXME: Derived modes might want to use something else
             ;; than a string for `mode-name'.
             (bare-mode-name (if (string-match "\\(^[^/]*\\)/" (mode-name))
                                 (match-string 1 (mode-name))
                                 (mode-name))))
        (set!mode-name
         (if (> (string-length fmt) 1)
             (concat bare-mode-name fmt)
             bare-mode-name))
        (force-mode-line-update)))

    (define-command (c-toggle-syntactic-indentation arg)
      "Toggle syntactic indentation.
Optional numeric ARG, if supplied, turns on syntactic indentation when
positive, turns it off when negative, and just toggles it when zero or
left out.

When syntactic indentation is turned on (the default), the indentation
functions and the electric keys indent according to the syntactic
context keys, when applicable.

When it's turned off, the electric keys don't reindent, the indentation
functions indents every new line to the same level as the previous
nonempty line, and \\[c-indent-command] adjusts the indentation in steps
specified by `c-basic-offset'.  The indentation style has no effect in
this mode, nor any of the indentation associated variables,
e.g. `c-special-indent-hook'."
      (interactive "P")
      (set!c-syntactic-indentation
       (c-calculate-state arg (c-syntactic-indentation)))
      (c-keep-region-active))

    (define-command (c-toggle-auto-newline arg)
      "Toggle auto-newline feature.
Optional numeric ARG, if supplied, turns on auto-newline when
positive, turns it off when negative, and just toggles it when zero or
left out.

Turning on auto-newline automatically enables electric indentation.

When the auto-newline feature is enabled (indicated by \"/la\" on the
mode line after the mode name) newlines are automatically inserted
after special characters such as brace, comma, semi-colon, and colon."
      (interactive "P")
      (set!c-auto-newline
       (c-calculate-state arg (and (c-auto-newline) (c-electric-flag))))
      (if (c-auto-newline) (set!c-electric-flag #t))
      (c-update-modeline)
      (c-keep-region-active))

    (define-command (c-toggle-hungry-state arg)
      "Toggle hungry-delete-key feature.
Optional numeric ARG, if supplied, turns on hungry-delete when
positive, turns it off when negative, and just toggles it when zero or
left out.

When the hungry-delete-key feature is enabled (indicated by \"/h\" on
the mode line after the mode name) the delete key gobbles all preceding
whitespace in one fell swoop."
      (interactive "P")
      (set!c-hungry-delete-key
       (c-calculate-state arg (c-hungry-delete-key)))
      (c-update-modeline)
      (c-keep-region-active))

    (define-command (c-toggle-auto-hungry-state arg)
      "Toggle auto-newline and hungry-delete-key features.
Optional numeric ARG, if supplied, turns on auto-newline and
hungry-delete when positive, turns them off when negative, and just
toggles them when zero or left out.

See `c-toggle-auto-newline' and `c-toggle-hungry-state' for details."
      (interactive "P")
      (set!c-auto-newline (c-calculate-state arg (c-auto-newline)))
      (set!c-hungry-delete-key (c-calculate-state arg (c-hungry-delete-key)))
      (c-update-modeline)
      (c-keep-region-active))

    (define-command (c-toggle-electric-state arg)
      "Toggle the electric indentation feature.
Optional numeric ARG, if supplied, turns on electric indentation when
positive, turns it off when negative, and just toggles it when zero or
left out."
      (interactive "P")
      (set!c-electric-flag (c-calculate-state arg (c-electric-flag)))
      (c-update-modeline)
      ;; `(when (fboundp 'electric-indent-local-mode)
      ;;    (electric-indent-local-mode (if c-electric-flag 1 0)))' -
      ;; `electric-indent-mode' is not ported, so there is nothing to
      ;; keep in sync; see the file header.
      (c-keep-region-active))

    (define-command (c-toggle-comment-style arg)
      "Toggle the comment style between block and line comments.
Optional numeric ARG, if supplied, switches to block comment
style when positive, to line comment style when negative, and
just toggles it when zero or left out.

This action does nothing when the mode only has one comment style."
      (interactive "P")
      (let ((line-starter (%c-langvar 'c-line-comment-starter))
            (block-starter (%c-langvar 'c-block-comment-starter))
            (block-ender (%c-langvar 'c-block-comment-ender)))
        (set!c-block-comment-flag
         (cond
          ((and line-starter block-starter)
           (c-calculate-state arg (c-block-comment-flag)))
          (line-starter #f)
          (else #t)))
        (set!comment-start
         (concat (if (c-block-comment-flag) block-starter line-starter) " "))
        (set!comment-end
         (if (c-block-comment-flag) (concat " " block-ender) ""))
        ;; If necessary, invert the sense of fontification of wrong
        ;; style comments.
        (when (and (*c-mark-wrong-style-of-comment*)
                   (font-lock-mode-on?)
                   block-starter
                   block-ender)
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (c-font-lock-flush (point-min) (point-max))))))
      (c-update-modeline)
      (c-keep-region-active))

    ;; ---------------------------------------------------------------
    ;; Movement (etc.) by defuns (`cc-cmds.el:1569'-`:2426')
    ;; Emacs's `(eq (char-before) CHAR)' and `(eq (char-after) CHAR)'
    ;; answer nil at the accessible buffer's edges, and nil is false;
    ;; `char-before' here answers #f there and `char=?' would raise.
    ;; These two are those tests, spelled so the edges are false.
    (define (%c-char-before=? char . pos-args)
      (let ((c (apply char-before pos-args)))
        (and c (char=? c char))))

    (define (%c-char-after=? char . pos-args)
      (let ((c (apply char-after pos-args)))
        (and c (char=? c char))))

    ;;--------------------------------------------------------------
    ;; `c-backward-into-nomenclature' (`cc-cmds.el:1569') needs one of
    ;; the two implementations it forwards to - `subword.el''s
    ;; `subword-backward' or `cc-subword.el''s `c-backward-subword' -
    ;; and neither library is ported. It is obsolete in Emacs 31 as
    ;; well; the stub names the gap rather than pretending the
    ;; feature is there.
    (define-command (c-backward-into-nomenclature . arg-args)
      "Compatibility alias for `c-backward-subword'."
      (interactive "p")
      (error "c-backward-into-nomenclature: neither `subword' nor `cc-subword' is ported"))

    ;; `c-scope-operator' (`cc-cmds.el:1582')
    ;;--------------------------------------------------------------
    (define-command (c-scope-operator)
      "Insert a double colon scope operator at point.
No indentation or other \"electric\" behavior is performed."
      (interactive "*")
      (insert-and-inherit "::"))

    ;; ---------------------------------------------------------------
    ;; Movement (etc.) by defuns (`cc-cmds.el:1589')
    ;;--------------------------------------------------------------
    (define (c-in-function-trailer-p . lim-args)
      ;; "Return non-nil if point is between the closing brace and the
      ;; semicolon of a brace construct which needs a semicolon, e.g.
      ;; within the \"variables\" portion of a declaration like \"struct
      ;; foo {...} bar ;\"."
      ;;
      ;; "Return the position of the main declaration.  Otherwise,
      ;; return nil. Point is assumed to be at the top level and outside
      ;; of any macro or literal."
      ;;
      ;; "If LIM is non-nil, it is the bound on a the backward search for
      ;; the beginning of the declaration."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((lim (if (pair? lim-args) (car lim-args) #f))
            (key (%c-langvar 'c-opt-block-decls-with-vars-key)))
        (and key
             (save-excursion
               (c-syntactic-skip-backward "^;}" lim)
               (let ((eo-block (point)) (bod #f))
                 (and (%c-char-before=? #\})
                      (memq (car (c-beginning-of-decl-1 lim)) '(same previous))
                      (setq bod (point))
                      ;; "Look for struct or union or ...  If we find
                      ;; one, it might be the return type of a function,
                      ;; or the like.  Exclude this case."
                      (c-syntactic-re-search-forward
                       (concat "[;=([{]\\|\\(" key "\\)")
                       eo-block #t #t #t)
                      ;; "Is there a \"struct\" etc., somewhere?"
                      (match-beginning 1)
                      (not (%c-char-before=? #\_))
                      (c-syntactic-re-search-forward "[;=([{]" eo-block #t #t #t)
                      (%c-char-before=? #\{)
                      ;; "Exclude the entire \"struct {...}\" being the
                      ;; type of a function being declared."
                      (not
                       (and
                        (c-go-up-list-forward)
                        (%c-char-before=? #\})
                        (begin
                          (c-forward-syntactic-ws)
                          (c-syntactic-re-search-forward "[;=([{]" #f #t #t #t))
                        (%c-char-before=? #\()))
                      bod))))))

    (define (c-where-wrt-brace-construct)
      ;; "Determine where we are with respect to functions (or other
      ;; brace constructs, included in the term \"function\" in the rest
      ;; of this comment). Point is assumed to be outside any macro or
      ;; literal. This is used by c-\(beginning\|end\)-of-defun."
      ;;
      ;; "Return one of these symbols:
      ;; at-header       : we're at the start of a function's header.
      ;; in-header       : we're inside a function's header, this
      ;;                   extending right up to the brace.  This bit
      ;;                   includes any k&r declarations.
      ;; in-block        : we're inside a function's brace block.
      ;; in-trailer      : we're in the area between the \"}\" and \";\"
      ;;                   of something like \"struct foo {...} bar, baz;\".
      ;; at-function-end : we're just after the closing brace (or
      ;;                   semicolon) that terminates the function.
      ;; outwith-function: we're not at or in any function.  Being inside
      ;;                   a non-brace construct also counts as
      ;;                   'outwith-function."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (let* ((knr-start #f) (knr-res #f)
               (decl-result #f)
               (start (point))
               (paren-state (c-parse-state))
               (least-enclosing (c-least-enclosing-brace paren-state)))
          (cond
           ((and least-enclosing
                 (char=? (char-after least-enclosing) #\{))
            'in-block)
           ((c-in-function-trailer-p)
            'in-trailer)
           ((or (and (%c-char-before=? #\;)
                     (save-excursion
                       (backward-char 1)
                       (c-in-function-trailer-p)))
                (and (not least-enclosing)
                     (pair? paren-state)
                     (pair? (car paren-state))
                     (= start (cdar paren-state))
                     (or
                      (save-excursion
                        (c-forward-syntactic-ws)
                        (or (not (looking-at (%c-langvar 'c-symbol-start)))
                            (looking-at (%c-langvar 'c-keywords-regexp))))
                      (save-excursion
                        (goto-char (caar paren-state))
                        (c-beginning-of-decl-1)
                        (not (looking-at
                              (%c-langvar 'c-defun-type-name-decl-key)))))))
            'at-function-end)
           (else
            ;; "Kluge so that c-beginning-of-decl-1 won't go back if
            ;; we're already at a declaration."
            (if (or (and (eolp) (not (eobp))) ; EOL is matched by "\\s>"
                    (not (c-looking-at-non-alphnumspace)))
                (forward-char 1))

            (if (and least-enclosing
                     (char=? (char-after least-enclosing) #\())
                (c-go-list-forward least-enclosing))
            (c-forward-syntactic-ws)
            (set! knr-start (point))
            (if (and (c-syntactic-re-search-forward "[;{]" #f #t #t)
                     (%c-char-before=? #\{))
                (begin
                  (backward-char 1)
                  (cond
                   ((or (begin
                          (c-backward-syntactic-ws)
                          (<= (point) start))
                        (and (%c-langvar 'c-recognize-knr-p)
                             (and (setq knr-res (c-in-knr-argdecl))
                                  (<= knr-res knr-start))))
                    'in-header)
                   ((and knr-res
                         (goto-char knr-res)
                         (c-backward-syntactic-ws))) ; Always returns nil.
                   (else
                    (when-e (%c-char-before=? #\))
                      ;; "The `c-go-list-backward' is a precaution against
                      ;; `c-beginning-of-decl-1' spuriously finding a C++
                      ;; lambda function inside the parentheses."
                      (c-go-list-backward))
                    (set! decl-result
                          (car (c-beginning-of-decl-1
                                (and least-enclosing
                                     (c-safe-position
                                      least-enclosing paren-state)))))
                    (cond
                     ((> (point) start)
                      'outwith-function)
                     ((eq? decl-result 'same)
                      (if (= (point) start)
                          'at-header
                          'in-header))
                     (else
                      (error
                       "c-where-wrt-brace-construct: c-beginning-of-decl-1 returned ~a"
                       decl-result))))))
                'outwith-function))))))

    (define (c-backward-to-nth-BOF-{ n where)
      ;; "Skip to the opening brace of the Nth function before point.
      ;; If point is inside a function, this counts as the first.  Point
      ;; must be outside any comment/string or macro."
      ;;
      ;; "N must be strictly positive. WHERE describes the position of
      ;; point, one of the symbols `at-header', `in-header', `in-block',
      ;; `in-trailer', `at-function-end', `outwith-function' as returned
      ;; by c-where-wrt-brace-construct."
      ;;
      ;; "If we run out of functions, leave point at BOB.  Return zero
      ;; on success, otherwise the number of {s still to go."
      ;;
      ;; "This function may do hidden buffer changes"
      (cond
       ;; "What we do to go back the first defun depends on where we
       ;; start."
       ((bobp))
       ((eq? where 'in-block)
        (goto-char (c-least-enclosing-brace (c-parse-state)))
        (set! n (- n 1)))
       ((eq? where 'in-header)
        (let ((encl-paren (c-least-enclosing-brace (c-parse-state))))
          (if encl-paren (goto-char encl-paren))
          (c-syntactic-re-search-forward "{" #f #t #t)
          (backward-char 1)
          (set! n (- n 1))))
       ((memq where '(at-header outwith-function at-function-end in-trailer))
        (c-syntactic-skip-backward "^}")
        (when-e (%c-char-before=? #\})
          (backward-sexp 1)
          (set! n (- n 1))))
       (else (error "Unknown `where' ~a in c-backward-to-nth-EOF-{" where)))

      ;; "Each time round the loop, go back to a \"{\" at the outermost
      ;; level."
      (while-e (and (> n 0) (not (bobp)))
        ;; "This call speeds up the following one by a factor of ~6.
        ;; Hmmm.  2006/4/5."
        (c-parse-state)
        (c-syntactic-skip-backward "^}")
        (when-e (%c-char-before=? #\})
          (backward-sexp 1)
          (set! n (- n 1))))
      n)

    (define (c-narrow-to-most-enclosing-decl-block . args)
      ;; "If we are inside a decl-block (in the sense of
      ;; c-looking-at-decl-block), i.e. something like namespace{} or
      ;; extern{}, narrow to the insides of that block (NOT including the
      ;; enclosing braces) if INCLUSIVE is nil, otherwise include the
      ;; braces and the declaration which introduces them. If the
      ;; closing brace is missing, (point-max) is used instead.  LEVEL,
      ;; if non-nil, says narrow to the LEVELth decl-block outward,
      ;; default value being 1."
      (let ((inclusive (if (pair? args) (car args) #f))
            (level (if (and (pair? args) (pair? (cdr args)))
                       (cadr args)
                       #f)))
        (let ((paren-state (c-parse-state))
              (encl-decl #f))
          (set! level (or level 1))
          (while-e (> level 0)
            (set! encl-decl (c-most-enclosing-decl-block paren-state))
            (if encl-decl
                (begin
                  (let loop ()
                    (let* ((pull (c-pull-open-brace paren-state))
                           (brace (car pull)))
                      (set! paren-state (cdr pull))
                      (if (> brace encl-decl) (loop) #f)))
                  (set! level (- level 1)))
                (set! level 0)))
          (if encl-decl
              (save-excursion
                (narrow-to-region
                 (if inclusive
                     (begin (goto-char encl-decl)
                            (c-beginning-of-decl-1)
                            (point))
                     (+ encl-decl 1))
                 (begin
                   (goto-char encl-decl)
                   (or (c-safe (forward-list 1)
                               (if inclusive
                                   (point)
                                   (- (point) 1)))
                       (point-max)))))))))

    (define (c-widen-to-enclosing-decl-scope paren-state orig-point-min orig-point-max)
      ;; "Narrow the buffer to the innermost declaration scope (e.g. a
      ;; class, a namespace or the \"whole buffer\") recorded in
      ;; PAREN-STATE, the bounding braces NOT being included in the
      ;; resulting region.  On no account may the final region exceed
      ;; that bounded by ORIG-POINT-MIN, ORIG-POINT-MAX. PAREN-STATE is a
      ;; list of buffer positions in the style of (c-parse-state), one of
      ;; which will be that of the desired opening brace, if there is
      ;; one."
      ;;
      ;; "Return the position of the enclosing opening brace, or nil"
      (let ((encl-decl #f)) ; "putative position of decl-scope's opening brace."
        (save-restriction
          (narrow-to-region orig-point-min orig-point-max)
          (set! encl-decl (and paren-state
                               (c-most-enclosing-decl-block paren-state))))
        (if encl-decl
            (begin
              (widen)
              (narrow-to-region (+ encl-decl 1)
                                (save-excursion
                                  (goto-char encl-decl)
                                  (or (c-safe (forward-list 1)
                                              (- (point) 1))
                                      orig-point-max)))
              encl-decl)
            (begin
              (narrow-to-region orig-point-min orig-point-max)
              #f))))

    (define-command (c-beginning-of-defun . arg-args)
      "Move backward to the beginning of a defun.
Every top level declaration that contains a brace paren block is
considered to be a defun.

With a positive argument, move backward that many defuns.  A negative
argument -N means move forward to the Nth following beginning.  Return
t unless search stops due to beginning or end of buffer.

Unlike the built-in `beginning-of-defun' this tries to be smarter
about finding the char with open-parenthesis syntax that starts the
defun."
      (interactive "p")
      (let ((arg (if (pair? arg-args) (car arg-args) #f)))
        (if (not arg) (set! arg 1))

        (or (not (eq? (*this-command*) c-beginning-of-defun))
            (eq? (*last-command*) c-beginning-of-defun)
            (c-region-is-active-p)
            (push-mark))

        (c-with-string-fences
         (parameterize ((*beginning-of-defun-function* #f)
                        (*end-of-defun-function* #f)
                        (*case-fold-search* #f))
           (c-save-buffer-state ((paren-state (c-parse-state))
                                 (orig-point-min (point-min))
                                 (orig-point-max (point-max))
                                 (lim #f) ; "Position of { which has been widened to."
                                 (where #f) (pos #f))
             (letrec-syntax
                 ((c-while-widening-to-decl-block
                   ;; "Repeatedly evaluate CONDITION until it returns
                   ;; nil.  After each evaluation, if `c-defun-tactic' is
                   ;; set appropriately, widen to inners of the next
                   ;; enclosing declaration block (e.g. namespace,
                   ;; class), or the buffer's original restriction."
                   ;;
                   ;; Emacs's macro (`cc-cmds.el:1841') relies on the
                   ;; caller's dynamic bindings; here it is a local macro
                   ;; closing over the function's lexical ones, the
                   ;; c-bos automaton's shape.
                   (syntax-rules ()
                     ((_ condition)
                      (let loop ()
                        (when-e (and condition
                                     (eq? (*c-defun-tactic*) 'go-outward)
                                     lim)
                          (set! paren-state (c-whack-state-after lim paren-state))
                          (set! lim (c-widen-to-enclosing-decl-scope
                                     paren-state orig-point-min orig-point-max))
                          (set! where 'in-block)
                          (loop))))
                     ((_ condition no-where)
                      (let loop ()
                        (when-e (and condition
                                     (eq? (*c-defun-tactic*) 'go-outward)
                                     lim)
                          (set! paren-state (c-whack-state-after lim paren-state))
                          (set! lim (c-widen-to-enclosing-decl-scope
                                     paren-state orig-point-min orig-point-max))
                          (loop)))))))
               (save-restriction
                 (if (eq? (*c-defun-tactic*) 'go-outward)
                     ;; "e.g. class, namespace."
                     (set! lim (c-widen-to-enclosing-decl-scope
                                paren-state orig-point-min orig-point-max)))

                 ;; "Move back out of any macro/comment/string we happen
                 ;; to be in."
                 (c-beginning-of-macro)
                 (set! pos (c-literal-start))
                 (if pos (goto-char pos))

                 (set! where (c-where-wrt-brace-construct))

                 (if (< arg 0)
                     ;; "Move forward to the closing brace of a function."
                     (begin
                       (if (memq where '(at-function-end outwith-function))
                           (set! arg (+ arg 1)))
                       (if (< arg 0)
                           (c-while-widening-to-decl-block
                            (< (setq arg (- (#{c-forward-to-nth-EOF-;-or-\x7d;}#
                                             (- arg) where)))
                               0)))
                       (prog1
                           (when-e (and (= arg 0)
                                        (begin
                                          (c-while-widening-to-decl-block
                                           (not (c-syntactic-re-search-forward
                                                 "{" #f 'eob)))
                                          (%c-char-before=? #\{)))
                             ;; "Move forward to the next opening
                             ;; brace...."
                             (backward-char 1)
                             ;; "... and backward to the function
                             ;; header."
                             (c-beginning-of-decl-1)
                             #t)
                         (c-keep-region-active)))

                     ;; "Move backward to the opening brace of a
                     ;; function, making successively larger portions of
                     ;; the buffer visible as necessary."
                     (begin
                       (when-e (> arg 0)
                         (c-while-widening-to-decl-block
                          (> (setq arg (c-backward-to-nth-BOF-{ arg where)) 0)))

                       (when-e (= arg 0)
                         ;; "Go backward to this function's header."
                         (c-beginning-of-decl-1)

                         (set! pos (point))
                         ;; "We're now there, modulo comments and
                         ;; whitespace. Try to be line oriented; position
                         ;; point at the closest preceding boi that isn't
                         ;; inside a comment, but if we hit the previous
                         ;; declaration then we use the current point
                         ;; instead."
                         (while-e (and (/= (point) (c-point 'boi))
                                       (c-backward-single-comment))
                           #t)
                         (if (/= (point) (c-point 'boi))
                             (goto-char pos)))

                       (c-keep-region-active)
                       (= arg 0))))))))))

    (define (#{c-forward-to-nth-EOF-;-or-\x7d;}# n where)
      ;; "Skip to the closing brace or semicolon of the Nth function
      ;; after point.  We move to a semicolon only for things like
      ;; structs which don't end at a closing brace.  If point is inside
      ;; a function, this counts as the first. Point must be outside any
      ;; comment/string or macro."
      ;;
      ;; "N must be strictly positive. WHERE describes the position of
      ;; point, one of the symbols `at-header', `in-header', `in-block',
      ;; `in-trailer', `at-function-end', `outwith-function' as returned
      ;; by c-where-wrt-brace-construct."
      ;;
      ;; "If we run out of functions, leave point at EOB.  Return zero
      ;; on success, otherwise the number of }s still to go."
      ;;
      ;; "This function may do hidden buffer changes."
      (cond
       ;; "What we do to go forward over the first defun depends on
       ;; where we start.  We go to the closing brace of that defun,
       ;; even when we go backwards to it (in a \"struct foo {...} bar
       ;; ;\")."
       ((eobp))
       ((eq? where 'in-block)
        (goto-char (c-least-enclosing-brace (c-parse-state)))
        (forward-sexp 1)
        (set! n (- n 1)))
       ((eq? where 'in-trailer)
        ;; "The actual movement is done below."
        (set! n (- n 1)))
       ((memq where '(at-function-end outwith-function at-header in-header))
        (if (eq? where 'in-header)
            (let ((pos (c-least-enclosing-brace (c-parse-state))))
              (if pos (c-go-list-forward pos))))
        (when-e (c-syntactic-re-search-forward "{" #f 'eob #t)
          (backward-char 1)
          (forward-sexp 1)
          (set! n (- n 1))))
       (else (error "c-forward-to-nth-EOF-\\;-or-}: `where' is ~a" where)))

      ;; "Each time round the loop, go forward to a \"}\" at the
      ;; outermost level."
      (while-e (and (> n 0) (not (eobp)))
        (when-e (c-syntactic-re-search-forward "{" #f 'eob)
          (backward-char 1)
          (forward-sexp 1)
          (set! n (- n 1))))

      (when-e (c-in-function-trailer-p)
        (c-syntactic-re-search-forward ";" #f 'eob #t))
      n)

    (define-command (c-end-of-defun . arg-args)
      "Move forward to the end of a top level declaration.
With argument, do it that many times.  Negative argument -N means move
back to Nth preceding end.  Returns t unless search stops due to
beginning or end of buffer.

An end of a defun occurs right after the close-parenthesis that matches
the open-parenthesis that starts a defun; see `beginning-of-defun'."
      (interactive "p")
      (let ((arg (if (pair? arg-args) (car arg-args) #f)))
        (if (not arg) (set! arg 1))

        (or (not (eq? (*this-command*) c-end-of-defun))
            (eq? (*last-command*) c-end-of-defun)
            (c-region-is-active-p)
            (push-mark))

        (c-with-string-fences
         (parameterize ((*beginning-of-defun-function* #f)
                        (*end-of-defun-function* #f)
                        (*case-fold-search* #f))
           (c-save-buffer-state ((paren-state (c-parse-state))
                                 (orig-point-min (point-min))
                                 (orig-point-max (point-max))
                                 (lim #f)
                                 (where #f) (pos #f))
             (letrec-syntax
                 ((c-while-widening-to-decl-block
                   (syntax-rules ()
                     ((_ condition)
                      (let loop ()
                        (when-e (and condition
                                     (eq? (*c-defun-tactic*) 'go-outward)
                                     lim)
                          (set! paren-state (c-whack-state-after lim paren-state))
                          (set! lim (c-widen-to-enclosing-decl-scope
                                     paren-state orig-point-min orig-point-max))
                          (set! where 'in-block)
                          (loop))))
                     ((_ condition no-where)
                      (let loop ()
                        (when-e (and condition
                                     (eq? (*c-defun-tactic*) 'go-outward)
                                     lim)
                          (set! paren-state (c-whack-state-after lim paren-state))
                          (set! lim (c-widen-to-enclosing-decl-scope
                                     paren-state orig-point-min orig-point-max))
                          (loop)))))))
               (save-restriction
                 (if (eq? (*c-defun-tactic*) 'go-outward)
                     ;; "e.g. class, namespace"
                     (set! lim (c-widen-to-enclosing-decl-scope
                                paren-state orig-point-min orig-point-max)))

                 ;; "Move back out of any macro/comment/string we happen
                 ;; to be in."
                 (c-beginning-of-macro)
                 (set! pos (c-literal-start))
                 (if pos (goto-char pos))

                 (set! where (c-where-wrt-brace-construct))

                 (if (< arg 0)
                     ;; "Move backwards to the } of a function"
                     (begin
                       (if (memq where '(at-header outwith-function))
                           (set! arg (+ arg 1)))
                       (if (< arg 0)
                           (c-while-widening-to-decl-block
                            (< (setq arg (- (c-backward-to-nth-BOF-{
                                             (- arg) where)))
                               0)))
                       (if (= arg 0)
                           (c-while-widening-to-decl-block
                            (begin (c-syntactic-skip-backward "^}")
                                  (not (%c-char-before=? #\}))))))

                     ;; "Move forward to the } of a function"
                     (if (> arg 0)
                         (c-while-widening-to-decl-block
                          (> (setq arg (#{c-forward-to-nth-EOF-;-or-\x7d;}#
                                      arg where))
                             0))))

                 ;; "Do we need to move forward from the brace to the
                 ;; semicolon?"
                 (when-e (= arg 0)
                   ;; "after \"}\" of struct/enum, etc."
                   (if (c-in-function-trailer-p)
                       (c-syntactic-re-search-forward ";"))

                   (set! pos (point))
                   ;; "We're there now, modulo comments and whitespace.
                   ;; Try to be line oriented; position point after the
                   ;; next newline that isn't inside a comment, but if we
                   ;; hit the next declaration then we use the current
                   ;; point instead."
                   (while-e (and (not (bolp))
                                 (not (looking-at "\\s *$"))
                                 (c-forward-single-comment))
                     #t)
                   (cond ((bolp))
                         ((looking-at "\\s *$")
                          (forward-line 1))
                         (else
                          (goto-char pos))))

                 (c-keep-region-active)
                 (= arg 0))))))))

    (define (c-defun-name-1)
      "Return name of current defun, at current narrowing, or nil if there isn't one.
\"Defun\" here means a function, or other top level construct
with a brace block."
      (parameterize ((*beginning-of-defun-function* #f)
                     (*end-of-defun-function* #f)
                     (*case-fold-search* #f))
        (c-save-buffer-state ((where #f) (pos #f) (decl0 #f) (decl #f)
                              (type-pos #f) (tag-pos #f))
          (save-excursion
            ;; "Move back out of any macro/comment/string we happen to
            ;; be in."
            (c-beginning-of-macro)
            (set! pos (c-literal-start))
            (if pos (goto-char pos))

            (set! where (c-where-wrt-brace-construct))

            ;; "Move to the beginning of the current defun, if any, if
            ;; we're not already there."
            (if (memq where '(outwith-function at-function-end))
                #f
                (begin
                  (unless (eq? where 'at-header)
                    (c-backward-to-nth-BOF-{ 1 where)
                    (c-beginning-of-decl-1))
                  (when-e (looking-at (%c-langvar 'c-typedef-key))
                    (goto-char (match-end 0))
                    (c-forward-syntactic-ws))
                  (set! type-pos (point))

                  ;; "Pick out the defun name, according to the type of
                  ;; defun."
                  (cond
                   ((looking-at "DEFUN\\_>")
                    ;; "DEFUN (\"file-name-directory\",
                    ;; Ffile_name_directory, Sfile_name_directory, ...)
                    ;; ==> Ffile_name_directory
                    ;; DEFUN(POSIX::STREAM-LOCK, stream lockp &key BLOCK
                    ;; SHARED START LENGTH) ==> POSIX::STREAM-LOCK"
                    (down-list 1)
                    (c-forward-syntactic-ws)
                    (when-e (%c-char-after=? #\")
                      (forward-sexp 1)
                      (c-forward-syntactic-ws)
                      (c-forward-token-2)) ; "over the comma and following WS."
                    (set! pos (point))
                    (and (= (c-forward-token-2) 0)
                         (begin (c-backward-syntactic-ws) #t)
                         (buffer-substring-no-properties pos (point))))

                   ((and (c-major-mode-is 'objc-mode) (looking-at "[-+]\\s-*("))
                    ;; "Objective-C method"
                    (begin
                      ;; "Move to the beginning of the method name."
                      (c-forward-token-2 2 #t)
                      (let* ((class
                              (save-excursion
                                (when-e (re-search-backward
                                         "^\\s-*@\\(implementation\\|class\\|interface\\)\\s-+\\(\\sw+\\)"
                                         #f #t)
                                  (match-string-no-properties 2))))
                             (limit (save-excursion (re-search-forward "[;{]" #f #t)))
                             (method (when-e (re-search-forward "\\(\\sw+:?\\)"
                                                                limit #t)
                                       (match-string-no-properties 1))))
                        (when-e (and class method)
                          ;; "Add the parameter labels onto name.  They
                          ;; always end in ':'."
                          (while-e (re-search-forward "\\(\\sw+:\\)" limit 1)
                            (set! method (concat method
                                                 (match-string-no-properties 1))))
                          (concat "[" class " " method "]")))))

                   (else ; "Normal function or initializer."
                    (when-e (looking-at (%c-langvar 'c-defun-type-name-decl-key))
                      ;; "struct, etc."
                      (goto-char (match-end 0))
                      (c-forward-syntactic-ws)
                      (set! tag-pos (point))
                      (goto-char type-pos))
                    (set! decl0 (c-forward-decl-or-cast-1 (c-point 'bosws) 'top #f))
                    (when-e (pair? decl0)
                      (goto-char (car decl0))
                      (set! decl (c-forward-declarator)))
                    (and decl
                         (car decl) (cadr decl)
                         (buffer-substring-no-properties
                          (if (eq? (car decl) tag-pos)
                              type-pos
                              (car decl))
                          (cadr decl)))))))))))

    (define (c-defun-name)
      "Return the name of the current defun, or NIL if there isn't one.
\"Defun\" here means a function, or other top level construct
with a brace block, at the outermost level of nesting."
      (c-save-buffer-state ()
        (save-restriction
          (widen)
          (c-defun-name-1))))

    (define (c-declaration-limits-1 near)
      ;; "Return a cons of the beginning and end position of the current
      ;; declaration or macro in the current narrowing.  If there is no
      ;; current declaration or macro, return nil, unless NEAR is
      ;; non-nil, in which case the closest following one is chosen
      ;; instead (if there is any).  The end position is at the next
      ;; line, providing there is one before the declaration."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (let ((start (point))
              (paren-state (c-parse-state))
              (lim #f) (pos #f) (end-pos #f) (where #f))
          (or
           ;; "Note: Some code duplication in `c-beginning-of-defun' and
           ;; `c-end-of-defun'."
           (call-with-current-continuation
            (lambda (exit)
              (unless (c-safe
                        (goto-char (c-least-enclosing-brace paren-state))
                        ;; "If we moved to the outermost enclosing paren
                        ;; then we can use c-safe-position to set the
                        ;; limit. Can't do that otherwise since the
                        ;; earlier paren pair on paren-state might very
                        ;; well be part of the declaration we should go
                        ;; to."
                        (set! lim (c-safe-position (point) paren-state))
                        ;; "We might have a struct foo {...} as the type
                        ;; of the function, so set LIM back one further
                        ;; block."
                        (if (eq? (char-before lim) #\})
                            (set! lim
                                  (or
                                   (save-excursion
                                     (and
                                      (c-go-list-backward lim)
                                      (let ((paren-state-1 (c-parse-state)))
                                        (c-safe-position
                                         (point) paren-state-1))))
                                   (point-min))))
                        #t)
                ;; "At top level.  Make sure we aren't inside a literal."
                (set! pos (c-literal-start
                           (c-safe-position (point) paren-state)))
                (if pos (goto-char pos)))

              (when-e (c-beginning-of-macro)
                (exit
                 (cons (point)
                       (save-excursion
                         (c-end-of-macro)
                         (forward-line 1)
                         (point)))))

              (set! pos (point))
              (set! where (and (not (save-excursion (c-beginning-of-macro)))
                               (c-where-wrt-brace-construct)))
              (when-e (and (not (eq? where 'at-header))
                           (or (and near
                                    (memq where
                                          '(at-function-end outwith-function))
                                    ;; "Check we're not inside a
                                    ;; declaration without braces."
                                    (save-excursion
                                      (memq (car (c-beginning-of-decl-1 lim))
                                            '(previous label))))
                               (eq? (car (c-beginning-of-decl-1 lim)) 'previous)
                               (= pos (point))))
                ;; "We moved back over the previous defun.  Skip to the
                ;; next one. Not using c-forward-syntactic-ws here since
                ;; we should not skip a macro.  We can also be directly
                ;; after the block in a `c-opt-block-decls-with-vars-key'
                ;; declaration, but then we won't move significantly far
                ;; here."
                (goto-char pos)
                (c-forward-comments)

                (when-e (and near (c-beginning-of-macro))
                  (exit
                   (cons (point)
                         (save-excursion
                           (c-end-of-macro)
                           (forward-line 1)
                           (point))))))

              (if (eobp) (exit #f))

              ;; "Check if `c-beginning-of-decl-1' put us after the
              ;; block in a declaration that doesn't end there.  We're
              ;; searching back and forth over the block here, which can
              ;; be expensive."
              (set! pos (point))
              (if (and (%c-langvar 'c-opt-block-decls-with-vars-key)
                       (begin
                         (c-backward-syntactic-ws)
                         (%c-char-before=? #\}))
                       (eq? (car (c-beginning-of-decl-1)) 'previous)
                       (save-excursion
                         (c-end-of-decl-1)
                         (and (> (point) pos)
                              (setq end-pos (point)))))
                  #f
                  (goto-char pos))

              (if (or (and (not near) (> (point) start))
                      (not (eq? (c-where-wrt-brace-construct) 'at-header)))
                  #f

                  ;; "Try to be line oriented; position the limits at
                  ;; the closest preceding boi, and after the next
                  ;; newline, that isn't inside a comment, but if we hit
                  ;; a neighboring declaration then we instead use the
                  ;; exact declaration limit in that direction."
                  (cons (begin
                          (set! pos (point))
                          (while-e (and (/= (point) (c-point 'boi))
                                        (c-backward-single-comment))
                            #t)
                          (if (/= (point) (c-point 'boi))
                              pos
                              (point)))
                        (begin
                          (if end-pos
                              (goto-char end-pos)
                              (c-end-of-decl-1))
                          (set! pos (point))
                          (while-e (and (not (bolp))
                                        (not (looking-at "\\s *$"))
                                        (c-forward-single-comment))
                            #t)
                          (cond ((bolp)
                                 (point))
                                ((looking-at "\\s *$")
                                 (forward-line 1)
                                 (point))
                                (else
                                 pos)))))))
           (and (not near)
                (goto-char (point-min))
                (c-forward-decl-or-cast-1 -1 #f #f)
                (eq? (char-after) #\{)
                (cons (point-min) (point-max)))))))

    (define (c-declaration-limits near)
      ;; "Return a cons of the beginning and end positions of the
      ;; current top level declaration or macro.  If point is not inside
      ;; any then nil is returned, unless NEAR is non-nil in which case
      ;; the closest following one is chosen instead (if there is any).
      ;; The end position is at the next line, providing there is one
      ;; before the declaration."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-restriction
        ;; "Narrow enclosing brace blocks out, as required by the values
        ;; of `c-defun-tactic', `near', and the position of point."
        (when-e (eq? (*c-defun-tactic*) 'go-outward)
          (let ((bounds
                 (save-restriction
                   (if (and (not (save-excursion (c-beginning-of-macro)))
                            (save-restriction
                              (c-narrow-to-most-enclosing-decl-block)
                              (memq (c-where-wrt-brace-construct)
                                    '(at-function-end outwith-function)))
                            (not near))
                       (c-narrow-to-most-enclosing-decl-block #f 2)
                       (c-narrow-to-most-enclosing-decl-block))
                   (cons (point-min) (point-max)))))
            (narrow-to-region (car bounds) (cdr bounds))))
        (c-declaration-limits-1 near)))

    (define (c-defun-name-and-limits near)
      ;; "Return a cons of the name and limits (itself a cons) of the
      ;; current top-level declaration or macro, or nil of there is
      ;; none."
      ;;
      ;; "If `c-defun-tactic' is 'go-outward, we return the name and
      ;; limits of the most tightly enclosing declaration or macro.
      ;; Otherwise, we return that at the file level."
      (save-restriction
        (widen)
        (if (eq? (*c-defun-tactic*) 'go-outward)
            (c-save-buffer-state ((paren-state (c-parse-state))
                                  (orig-point-min (point-min))
                                  (orig-point-max (point-max))
                                  (lim #f) (name #f) (limits #f))
              (letrec-syntax
                  ((c-while-widening-to-decl-block
                    (syntax-rules ()
                      ((_ condition no-where)
                       (let loop ()
                         (when-e (and condition
                                      (eq? (*c-defun-tactic*) 'go-outward)
                                      lim)
                           (set! paren-state (c-whack-state-after lim paren-state))
                           (set! lim (c-widen-to-enclosing-decl-scope
                                      paren-state orig-point-min orig-point-max))
                           (loop)))))))
                (set! lim (c-widen-to-enclosing-decl-scope
                           paren-state orig-point-min orig-point-max))
                (and lim (set! lim (- lim 1)))
                (c-while-widening-to-decl-block
                 (not (setq name (c-defun-name-1))) #t)
                (when-e name
                  (set! limits (c-declaration-limits-1 near))
                  (cons name limits))))
            (c-save-buffer-state ((name (c-defun-name))
                                  (limits (c-declaration-limits near)))
              (and name limits (cons name limits))))))

    (define-command (c-display-defun-name . arg-args)
      "Display the name of the current CC mode defun and the position in it.
With a prefix arg, push the name onto the kill ring too."
      (interactive "P")
      (let ((arg (if (pair? arg-args) (car arg-args) #f)))
        (c-with-string-fences
         (save-restriction
           (widen)
           (c-save-buffer-state ((name-and-limits (c-defun-name-and-limits #f))
                                 (name (car-safe name-and-limits))
                                 (limits (cdr-safe name-and-limits))
                                 (point-bol (c-point 'bol)))
             (when-e name
               (message "~a.  Line ~a/~a." name
                        (+ 1 (count-lines (car-safe limits)
                                          (max point-bol (car-safe limits))))
                        (count-lines (car-safe limits) (cdr-safe limits)))
               (if arg (kill-new name))
               (sit-for 3 #t)))))))
    (put 'c-display-defun-name 'isearch-scroll #t)

    (define-command (c-mark-function)
      "Put mark at end of current top-level declaration or macro, point at beginning.
If point is not inside any then the closest following one is
chosen.  Each successive call of this command extends the marked
region by one function.

A mark is left where the command started, unless the region is already active
\\(in Transient Mark mode).

As opposed to \\[c-beginning-of-defun] and \\[c-end-of-defun], this
function does not require the declaration to contain a brace block."
      (interactive)
      (c-with-string-fences
       (let ((decl-limits #f))
         (parameterize ((*case-fold-search* #f))
           (c-save-buffer-state ()
             ;; "We try to be line oriented, unless there are several
             ;; declarations on the same line."
             (if (looking-at (%c-langvar 'c-syntactic-eol))
                 (c-backward-token-2 1 #f (c-point 'bol)))
             (set! decl-limits (c-declaration-limits #t))))

         (if (not decl-limits)
             (error "Cannot find any declaration")
             (let* ((extend-region-p
                     (and (eq? (*this-command*) c-mark-function)
                          (eq? (*last-command*) c-mark-function)))
                    (push-mark-p (and (eq? (*this-command*) c-mark-function)
                                      (not extend-region-p)
                                      (not (c-region-is-active-p)))))
               (if push-mark-p (push-mark))
               (if extend-region-p
                   (begin
                     (exchange-point-and-mark #f)
                     (set! decl-limits (c-declaration-limits #t))
                     (when-e (not decl-limits)
                       (exchange-point-and-mark #f)
                       (error "Cannot find any declaration"))
                     (goto-char (cdr decl-limits))
                     (exchange-point-and-mark #f))
                   (begin
                     (goto-char (car decl-limits))
                     (push-mark (cdr decl-limits) #f #t))))))))

    (define (c-cpp-define-name)
      "Return the name of the current CPP macro, or NIL if we're not in one."
      (parameterize ((*case-fold-search* #f))
        (save-excursion
          (let ((start (%c-langvar 'c-opt-cpp-macro-define-start)))
            (and start
                 (c-beginning-of-macro)
                 (looking-at start)
                 (match-string-no-properties 1))))))


    ;; ---------------------------------------------------------------
    ;; Movement by statements (`cc-cmds.el:2429'-`:3223')
    ;;--------------------------------------------------------------
    ;; Emacs's `c-while-widening-to-decl-block'-style catch/throw is
    ;; `call-with-current-continuation' here (`c-beginning-of-decl-1''s
    ;; shape); every `when' whose value the loop test reads is `when-e'
    ;; (Emacs's nil, not the unspecified value), and `(eq (char-after)
    ;; ?X)' at a buffer edge is the nil-safe `%c-char-after=?' - the two
    ;; helpers the defun movements introduced now take an optional
    ;; position.
    (define (c-in-comment-line-prefix-p)
      ;; "Point is within a comment.  Is it also within a
      ;; comment-prefix? Space at BOL which precedes a comment-prefix
      ;; counts as part of it."
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((here (point)))
        (save-excursion
          (beginning-of-line)
          (skip-chars-forward " \t")
          (and (looking-at (c-current-comment-prefix))
               (/= (match-beginning 0) (match-end 0))
               (< here (match-end 0))))))

    (define (c-narrow-to-comment-innards range)
      ;; "Narrow to the \"inside\" of the comment (block) defined by
      ;; range, as follows:"
      ;;
      ;; "A c-style block comment has its opening \"/*\" and its closing
      ;; \"*/\" (if present) removed.  A c++-style line comment retains
      ;; its opening \"//\" but has any final NL removed.  If POINT is
      ;; currently outwith these innards, move it to the appropriate
      ;; boundary."
      ;;
      ;; "This narrowing simplifies the sentence movement functions,
      ;; since it eliminates awkward things at the boundaries of the
      ;; comment (block)."
      ;;
      ;; "This function might do hidden buffer changes."
      (let* ((lit-type (c-literal-type range))
             (beg (if (eq? lit-type 'c) (+ (car range) 2) (car range)))
             (end (if (eq? lit-type 'c)
                      (if (and (%c-char-before=? #\/ (cdr range))
                               (%c-char-before=? #\* (- (cdr range) 1)))
                          (- (cdr range) 2)
                          (point-max))
                      (if (= (cdr range) (point-max))
                          (point-max)
                          (- (cdr range) 1)))))
        (if (> (point) end)
            (goto-char end)) ; "This would be done automatically by ..."
        (if (< (point) beg)
            (goto-char beg)) ; "... narrow-to-region but is not documented."
        (narrow-to-region beg end)))

    (define (c-beginning-of-sentence-in-comment range)
      ;; "Move backwards to the \"beginning of a sentence\" within the
      ;; comment defined by RANGE, a cons of its starting and ending
      ;; positions.  If we find a BOS, return NIL.  Otherwise, move point
      ;; to just before the start of the comment and return T."
      ;;
      ;; "The BOS is either text which follows a regexp match of
      ;; sentence-end, or text which is a beginning of \"paragraph\".
      ;; Comment-prefixes are treated like WS when calculating BOSes or
      ;; BOPs."
      ;;
      ;; "This code was adapted from GNU Emacs's forward-sentence in
      ;; paragraphs.el. It is not a general function, but is intended
      ;; only for calling from `c-move-over-sentence'.  Not all
      ;; preconditions have been explicitly stated."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-match-data
        (let ((start-point (point)))
          (save-restriction
            (c-narrow-to-comment-innards range) ; "This may move point back."
            (let* ((here (point))
                   (last #f)
                   (here-filler ; "matches WS and comment-prefixes at point."
                    (concat "\\=\\(^[ \t]*\\("
                            (c-current-comment-prefix) "\\)"
                            "\\|[ \t\n\r\f]\\)*"))
                   (prefix-at-bol-here ; "matches WS and prefix at BOL, just before point"
                    (concat "^[ \t]*\\(" (c-current-comment-prefix)
                            "\\)[ \t\n\r\f]*\\="))
                   ;; "First, find the previous paragraph start, if any."
                   (par-beg ; "point where non-WS/non-prefix text of paragraph starts."
                    (save-excursion
                      (forward-paragraph -1) ; "uses cc-mode values of
                                              ; paragraph-\(start\|separate\)"
                      (if (> (re-search-forward here-filler #f #t) here)
                          (goto-char here))
                      (when-e (>= (point) here)
                        (forward-paragraph -2)
                        (if (> (re-search-forward here-filler #f #t) here)
                            (goto-char here)))
                      (point))))

              ;; "Now seek successively earlier sentence ends between PAR-BEG
              ;; and HERE, until the \"start of sentence\" following it is
              ;; earlier than HERE, or we hit PAR-BEG.  Beware of comment
              ;; prefixes!"
              (while-e (and (re-search-backward (c-sentence-end) par-beg 'limit)
                            (setq last (point))
                            (goto-char (match-end 0)) ; "tentative beginning of sentence"
                            (or (>= (point) here)
                                (and (not (bolp)) ; "Found a non-blank comment-prefix?"
                                     (save-excursion
                                       (if (re-search-backward
                                            prefix-at-bol-here #f #t)
                                           (/= (match-beginning 1)
                                               (match-end 1))
                                           #f)))
                                (begin ; "Skip the crud to find a real b-o-s."
                                  (if (c-in-comment-line-prefix-p)
                                      (beginning-of-line))
                                  (re-search-forward here-filler) ; "always succeeds."
                                  (>= (point) here))))
                (goto-char last))
              (re-search-forward here-filler)))

          (if (< (point) start-point)
              #f
              (begin (goto-char (car range))
                     #t)))))

    (define (c-end-of-sentence-in-comment range)
      ;; "Move forward to the \"end of a sentence\" within the comment
      ;; defined by RANGE, a cons of its starting and ending positions
      ;; (enclosing the opening comment delimiter and the terminating */
      ;; or newline).  If we find an EOS, return NIL.  Otherwise, move
      ;; point to just after the end of the comment and return T."
      ;;
      ;; "The EOS is just after the non-WS part of the next match of the
      ;; regexp sentence-end.  Typically, this is just after one of
      ;; [.!?].  If there is no sentence-end match following point, any
      ;; WS before the end of the comment will count as EOS, providing
      ;; we're not already in it."
      ;;
      ;; "This code was adapted from GNU Emacs's forward-sentence in
      ;; paragraphs.el. It is not a general function, but is intended
      ;; only for calling from `c-move-over-sentence'."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-match-data
        (let ((start-point (point)))
          (save-restriction
            (c-narrow-to-comment-innards range) ; "This might move point forwards."
            (let* ((here (point))
                   (par-end ; "EOL position of last text in current/next paragraph."
                    (save-excursion
                      ;; "The cc-mode values of paragraph-\(start\|separate\),
                      ;; set in c-setup-paragraph-variables, are used in
                      ;; the following."
                      (forward-paragraph 1)
                      (if (and (char-before) (char=? (char-before) #\newline))
                          (forward-char -1))
                      (when-e (<= (point) here) ; "can happen, e.g., when HERE is at EOL."
                        (goto-char here)
                        (forward-paragraph 2)
                        (if (and (char-before)
                                 (char=? (char-before) #\newline))
                            (forward-char -1)))
                      (point)))

                   (last #f)
                   (prefix-at-bol-here
                    (concat "^[ \t]*\\(" (c-current-comment-prefix) "\\)\\=")))
              ;; "Go forward one \"comment-prefix which looks like
              ;; sentence-end\" each time round the following:"
              (while-e (and (re-search-forward (c-sentence-end) par-end 'limit)
                            (begin
                              (setq last (point))
                              (skip-chars-backward " \t\n")
                              (or (and (not (bolp))
                                       (re-search-backward prefix-at-bol-here #f #t)
                                       (/= (match-beginning 1) (match-end 1)))
                                  (<= (point) here))))
                (goto-char last))

              ;; "Take special action if we're up against the end of a
              ;; comment (of either sort): Leave point just after the
              ;; last non-ws text."
              (if (= (point) (point-max))
                  (while-e (or (/= (skip-chars-backward " \t\n") 0)
                               (and (re-search-backward prefix-at-bol-here #f #t)
                                    (/= (match-beginning 1) (match-end 1))))
                    #t))))

          (if (> (point) start-point)
              #f
              (begin (goto-char (cdr range))
                     #t)))))

    (define (c-beginning-of-sentence-in-string range)
      ;; "Move backwards to the \"beginning of a sentence\" within the
      ;; string defined by RANGE, a cons of its starting and ending
      ;; positions (enclosing the string quotes).  If we find a BOS,
      ;; return NIL.  Otherwise, move point to just before the start of
      ;; the string and return T."
      ;;
      ;; "The BOS is either the text which follows a regexp match of
      ;; sentence-end or text which is a beginning of \"paragraph\".  For
      ;; the purposes of determining paragraph boundaries, escaped
      ;; newlines are treated as ordinary newlines."
      ;;
      ;; "This code was adapted from GNU Emacs's forward-sentence in
      ;; paragraphs.el. It is not a general function, but is intended
      ;; only for calling from `c-move-over-sentence'."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-match-data
        (call-with-buffer-local
         'paragraph-start c-string-par-start
         (lambda ()
           (call-with-buffer-local
            'paragraph-separate c-string-par-separate
            (lambda ()
              (let* ((here (point)) (last #f)
                     (end (- (cdr range) 1))
                     (here-filler ; "matches WS and escaped newlines at point."
                      "\\=\\([ \t\n\r\f]\\|\\\\[\n\r]\\)*")
                     ;; "Enhance paragraph-start and paragraph-separate
                     ;; also to recognize blank lines terminated by
                     ;; escaped EOLs. ..."
                     (par-beg ; "beginning of current (or previous) paragraph."
                      (save-excursion
                        (save-restriction
                          (narrow-to-region (+ (car range) 1) end)
                          (forward-paragraph -1) ; "uses above values of
                                                  ; paragraph-\(start\|separate\)"
                          (if (> (re-search-forward here-filler #f #t) here)
                              (goto-char here))
                          (when-e (>= (point) here)
                            (forward-paragraph -2)
                            (if (> (re-search-forward here-filler #f #t) here)
                                (goto-char here)))
                          (point)))))
                ;; "Now see if we can find a sentence end after PAR-BEG."
                (while-e (and (re-search-backward
                               c-sentence-end-with-esc-eol par-beg 'limit)
                              (setq last (point))
                              (goto-char (match-end 0))
                              (or (> (point) end)
                                  (begin
                                    (re-search-forward
                                     here-filler end #t) ; "always succeeds.  Use end rather
                                                         ; than here, in case point starts
                                                         ; beyond the closing quote."
                                    (>= (point) here))))
                  (goto-char last))
                (re-search-forward here-filler here #t)
                (if (< (point) here)
                    #f
                    (begin (goto-char (car range))
                           #t)))))))))

    (define (c-end-of-sentence-in-string range)
      ;; "Move forward to the \"end of a sentence\" within the string
      ;; defined by RANGE, a cons of its starting and ending positions.
      ;; If we find an EOS, return NIL.  Otherwise, move point to just
      ;; after the end of the string and return T."
      ;;
      ;; "The EOS is just after the non-WS part of the next match of the
      ;; regexp sentence-end.  Typically, this is just after one of
      ;; [.!?].  If there is no sentence-end match following point, any
      ;; WS before the end of the string will count as EOS, providing
      ;; we're not already in it."
      ;;
      ;; "This code was adapted from GNU Emacs's forward-sentence in
      ;; paragraphs.el. It is not a general function, but is intended
      ;; only for calling from `c-move-over-sentence'."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-match-data
        (call-with-buffer-local
         'paragraph-start c-string-par-start
         (lambda ()
           (call-with-buffer-local
            'paragraph-separate c-string-par-separate
            (lambda ()
              (let* ((here (point))
                     (last #f)
                     ;; "Enhance paragraph-start and paragraph-separate
                     ;; to recognize blank lines terminated by escaped
                     ;; EOLs."
                     (par-end ; "EOL position of last text in current/next paragraph."
                      (save-excursion
                        (save-restriction
                          (narrow-to-region (car range) (- (cdr range) 1))
                          ;; "The above values of paragraph-\(start\|separate\)
                          ;; are used in the following."
                          (forward-paragraph 1)
                          (setq last (point))
                          ;; "(re-search-backward filler-here nil t) would
                          ;; find an empty string.  Therefore we simulate
                          ;; it by the following:"
                          (while-e (or (/= (skip-chars-backward " \t\n\r\f") 0)
                                       (re-search-backward "\\\\\\($\\)\\=" #f #t))
                            #t)
                          (unless (> (point) here)
                            (goto-char last)
                            (forward-paragraph 1)
                            (while-e (or (/= (skip-chars-backward " \t\n\r\f") 0)
                                         (re-search-backward "\\\\\\($\\)\\=" #f #t))
                              #t))
                          (point)))))
                ;; "Try to go forward a sentence."
                (when-e (re-search-forward c-sentence-end-with-esc-eol
                                           par-end 'limit)
                  (setq last (point))
                  (while-e (or (/= (skip-chars-backward " \t\n") 0)
                               (re-search-backward "\\\\\\($\\)\\=" #f #t))
                    #t))
                ;; "Did we move a sentence, or did we hit the end of the
                ;; string?"
                (if (> (point) here)
                    #f
                    (begin (goto-char (cdr range))
                           #t)))))))))

    (define (c-ascertain-preceding-literal)
      ;; "Point is not in a literal (i.e. comment or string (include AWK
      ;; regexp)). If a literal is the next thing (aside from whitespace)
      ;; to be found before point, return a cons of its start.end
      ;; positions (enclosing the delimiters).  Otherwise return NIL."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (c-collect-line-comments
         (let ((here (point))
               (pos #f))
           (if (c-backward-single-comment)
               (cons (point) (begin (c-forward-single-comment) (point)))
               (save-restriction
                 ;; "to prevent `looking-at' seeing a \" at point."
                 (narrow-to-region (point-min) here)
                 (when-e
                     (or
                      ;; "An EOL can act as an \"open string\" terminator
                      ;; in AWK."
                      (looking-at c-ws*-string-limit-regexp)
                      (and (not (bobp))
                           (begin (backward-char 1)
                                  (looking-at c-string-limit-regexp))))
                   (goto-char (match-end 0)) ; "just after the string terminator."
                   (setq pos (point))
                   (c-safe (c-backward-sexp 1) ; "move back over the string."
                           (cons (point) pos)))))))))

    (define (c-ascertain-following-literal)
      ;; "Point is not in a literal (i.e. comment or string (include AWK
      ;; regexp)). If a literal is the next thing (aside from whitespace)
      ;; following point, return a cons of its start.end positions
      ;; (enclosing the delimiters).  Otherwise return NIL."
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (c-collect-line-comments
         (let ((pos #f))
           (c-skip-ws-forward)
           (if (looking-at c-string-limit-regexp) ; "string-delimiter."
               (cons (point) (or (c-safe (begin (c-forward-sexp 1) (point)))
                                 (point-max)))
               (begin
                 (setq pos (point))
                 (if (c-forward-single-comment)
                     (cons pos (point))
                     #f)))))))

    (define (c-after-statement-terminator-p) ; "Should we pass in LIM here?"
      ;; "Does point immediately follow a statement \"terminator\"?  A
      ;; virtual semicolon is regarded here as such.  So is an opening
      ;; brace ;-)"
      ;;
      ;; "This function might do hidden buffer changes."
      (or (save-excursion
            (backward-char 1)
            (and (looking-at "[;{}]")
                 (not (and (%c-langvar 'c-special-brace-lists) ; "Pike special brace lists."
                           (%c-char-after=? #\{)
                           (c-looking-at-special-brace-list)))))
          (c-at-vsemi-p)
          ;; "The following (for macros) is not strict about exactly
          ;; where we are wrt white space at the end of the macro.
          ;; Doesn't seem to matter too much.  ACM 2004/3/29."
          (let ((eom #f))
            (save-excursion
              (if (c-beginning-of-macro)
                  (setq eom (begin (c-end-of-macro) (point)))))
            (when-e eom
              (save-excursion
                (c-forward-comments)
                (>= (point) eom))))))

    (define (c-back-over-illiterals macro-start)
      ;; "Move backwards over code which isn't a literal (i.e. comment
      ;; or string), stopping before reaching BOB or a literal or the
      ;; boundary of a preprocessor statement or the \"beginning of a
      ;; statement\".  MACRO-START is the position of the '#' beginning
      ;; the current preprocessor directive, or NIL if we're not in
      ;; such."
      ;;
      ;; "Return a cons (A.B), where A is NIL if we moved back to a BOS
      ;; (and know it), T otherwise (we didn't move, or we hit a
      ;; literal, or we're not sure about BOS).  B is MACRO-BOUNDARY if
      ;; we are about to cross the boundary out of or into a macro,
      ;; otherwise LITERAL if we've hit a literal, otherwise NIL"
      ;;
      ;; ... (the full comment is Emacs's; see cc-cmds.el)
      ;;
      ;; "This function might do hidden buffer changes."
      (save-match-data
        (let ((here (point))
              (last #f)) ; "marks the position of non-ws code, what'll be BOS if,
                          ; say, a semicolon precedes it."
          (call-with-current-continuation
           (lambda (done)
             (let loop () ; "We go back one \"token\" each iteration of the loop."
               (setq last (point))
               (cond
                ;; "Stop at the token after a comment."
                ((c-backward-single-comment) ; "Also functions as backwards-ws."
                 (goto-char last)
                 (done (cons #t 'literal)))

                ;; "If we've gone back over a LF, we might have moved
                ;; into or out of a preprocessor line."
                ((and (save-excursion
                        (beginning-of-line)
                        (re-search-forward "\\(^\\|[^\\]\\)[\n\r]" last #t))
                      (if macro-start
                          (< (point) macro-start)
                          (c-beginning-of-macro)))
                 (goto-char last)
                 ;; "Return a car of NIL ONLY if we've hit the opening
                 ;; # of a macro."
                 (done (cons (or (= (point) here)
                                 (not macro-start))
                             'macro-boundary)))

                ;; "Have we found a virtual semicolon?  If so, stop,
                ;; unless the next statement is where we started from."
                ((and (c-at-vsemi-p)
                      (< last here)
                      ;; "we've moved back from ) or }"
                      (not (memq (char-after last) (list #\) #\}))))
                 (goto-char last)
                 (done (cons #f '())))

                ;; "Hit the beginning of the buffer/region?"
                ((bobp)
                 (if (/= here last)
                     (goto-char last))
                 (done (cons #f '())))

                ;; "Move back a character."
                ((begin (backward-char 1) #f))

                ;; "Stop at \"{\" (unless it's a PIKE special brace
                ;; list.)"
                ((%c-char-after=? #\{)
                 (if (and (%c-langvar 'c-special-brace-lists)
                          (c-looking-at-special-brace-list))
                     (skip-syntax-backward "w_") ; "Speedup only."
                     (begin
                       (if (/= here last)
                           (goto-char last))
                       (done (cons #f '())))))

                ;; "Have we reached the start of a macro?  This always
                ;; counts as BOS.  (N.B. I don't think (eq (point) here)
                ;; can ever be true here. FIXME!!! ACM 2004/3/29)"
                ((and macro-start (= (point) macro-start))
                 (done (cons (= (point) here) 'macro-boundary)))

                ;; "Stop at token just after \"}\" or \";\"."
                ((looking-at "[;}]")
                 ;; "If we've gone back over ;, {, or }, we're done."
                 (if (or (= here last)
                         (memq (char-after last) (list #\) #\}))) ; "we've moved back from ) or }"
                     (if (and (%c-char-before=? #\}) ; "If };, treat them as a unit."
                              (%c-char-after=? #\;))
                         (backward-char 1))
                     (begin
                       (goto-char last) ; "To the statement starting after the ; or }."
                       (done (cons #f '())))))

                ;; "Stop at the token after a string."
                ((looking-at c-string-limit-regexp) ; "Just gone back over a string terminator?"
                 (goto-char last)
                 (done (cons #t 'literal)))

                ;; "Nothing special: go back word characters."
                (else (skip-syntax-backward "w_"))) ; "Speedup only."
               (loop)))))))

    (define (c-forward-over-illiterals macro-end allow-early-stop)
      ;; "Move forwards over code, stopping before reaching EOB or a
      ;; literal (i.e. a comment/string) or the boundary of a
      ;; preprocessor statement or the \"end of a statement\".  MACRO-END
      ;; is the position of the EOL/EOB which terminates the current
      ;; preprocessor directive, or NIL if we're not in such."
      ;;
      ;; "ALLOW-EARLY-STOP is non-nil if it is permissible to return
      ;; without moving forward at all, should we encounter a `{'. ..."
      ;;
      ;; ... (the full comment is Emacs's; see cc-cmds.el)
      ;;
      ;; "This function might do hidden buffer changes."
      (let ((here (point))
            (last #f))
        (call-with-current-continuation
         (lambda (done)
           (let loop () ; "We go one \"token\" forward each time round this loop."
             (setq last (point))

             ;; "If we've moved forward to a virtual semicolon, we're done."
             (if (and (> last here) ; "Should we check ALLOW-EARLY-STOP, here? 2004/4/3"
                      (c-at-vsemi-p))
                 (done (cons #f '())))

             (c-skip-ws-forward)
             (cond
              ;; "Gone past the end of a macro?"
              ((and macro-end (> (point) macro-end))
               (goto-char last)
               (done (cons (= (point) here) 'macro-boundary)))

              ;; "About to hit a comment?"
              ((save-excursion (c-forward-single-comment))
               (goto-char last)
               (done (cons #t 'literal)))

              ;; "End of buffer?"
              ((eobp)
               (if (/= here last)
                   (goto-char last))
               (done (cons #f '())))

              ;; "If we encounter a '{', stop just after the previous
              ;; token."
              ((and (%c-char-after=? #\{)
                    (not (and (%c-langvar 'c-special-brace-lists)
                              (c-looking-at-special-brace-list)))
                    (or allow-early-stop (/= here last))
                    (save-excursion ; "Is this a check that we're NOT at top level?"
                      (or (not (c-safe (up-list -1) #t))
                          (%c-char-after=? #\{))))
               (goto-char last)
               (done (cons #f '())))

              ;; "End of a PIKE special brace list?  If so, step over it
              ;; and continue."
              ((and (%c-langvar 'c-special-brace-lists)
                    (%c-char-after=? #\})
                    (save-excursion
                      (and (c-safe (up-list -1) #t)
                           (c-looking-at-special-brace-list))))
               (forward-char 1)
               (skip-syntax-forward "w_")) ; "Speedup only."

              ;; "Have we got a '}' after having moved?  If so, stop
              ;; after the previous token."
              ((and (%c-char-after=? #\})
                    (/= here last))
               (goto-char last)
               (done (cons #f '())))

              ;; "Stop if we encounter a preprocessor line.  Continue if
              ;; we hit a naked #"
              ((and (%c-langvar 'c-opt-cpp-prefix)
                    (not macro-end)
                    (%c-char-after=? #\#)
                    (= (point) (c-point 'boi)))
               (if (= (point) here) ; "Not a macro, therefore naked #."
                   (forward-char 1)
                   (done (cons #t 'macro-boundary))))

              ;; "Stop after a ';', '}', or \"};\""
              ((looking-at ";\\|};?")
               (goto-char (match-end 0))
               (done (cons #f '())))

              ;; "Found a string (this subsumes AWK regexps)?"
              ((looking-at c-string-limit-regexp)
               (goto-char last)
               (done (cons #t 'literal)))

              (else
               (forward-char 1) ; "Can't fail - we checked (eobp) earlier on."
               (skip-syntax-forward "w_") ; "Speedup only."
               (when-e (and macro-end (> (point) macro-end))
                 (goto-char last)
                 (done (cons (= (point) here) 'macro-boundary)))))
             (loop))))))

    (define (c-one-line-string-p range)
      ;; "Is the literal defined by RANGE a string contained in a single
      ;; line?"
      ;;
      ;; "This function might do hidden buffer changes."
      (save-excursion
        (goto-char (car range))
        (and (looking-at c-string-limit-regexp)
             (begin (skip-chars-forward "^\n" (cdr range))
                    (= (point) (cdr range))))))

    (define-command (c-beginning-of-statement . rest)
      "Go to the beginning of the innermost C statement.
With prefix arg, go back N - 1 statements.  If already at the
beginning of a statement then go to the beginning of the closest
preceding one, moving into nested blocks if necessary (use
\\[backward-sexp] to skip over a block).  If within or next to a
comment or multiline string, move by sentences instead of statements.

When called from a program, this function takes 3 optional args: the
repetition count, a buffer position limit which is the farthest back
to search for the syntactic context, and a flag saying whether to do
sentence motion in or near comments and multiline strings.

Note that for use in programs, `c-beginning-of-statement-1' is
usually better.  It has much better defined semantics than this one,
which is intended for interactive use, and might therefore change to
be more \"DWIM:ey\"."
      (interactive (list (prefix-numeric-value (current-prefix-arg))
                         #f #t))
      (let ((count (if (pair? rest) (car rest) #f))
            (lim (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (sentence-flag (if (and (pair? rest) (pair? (cdr rest))
                                    (pair? (cddr rest)))
                               (caddr rest)
                               #f)))
        (if (< count 0)
            (c-end-of-statement (- count) lim sentence-flag)
            (c-with-string-fences
             (c-save-buffer-state
                 ((count (or count 1))
                  (last #f) ; "start point for going back ONE chunk.  Updated each chunk movement."
                  (macro-fence
                   (save-excursion (and (not (bobp)) (c-beginning-of-macro)
                                        (point))))
                  (res #f) ; "result from sub-function call"
                  (not-bos #f) ; "\"not beginning-of-statement\""
                  (range (c-collect-line-comments (c-literal-limits lim))))
               ;; "(start.end) of current literal or NIL"

               ;; "Go back one statement at each iteration of the following loop."
               (while-e (and (/= count 0)
                             (or (not lim) (> (point) lim)))
                 ;; "Go back one \"chunk\" each time round the following
                 ;; loop, stopping when we reach a statement boundary, etc."
                 (setq last (point))
                 (while-e
                     (cond ; "Each arm of this cond returns NIL on reaching a
                            ; desired statement boundary, non-NIL otherwise."
                      ((bobp)
                       (setq count 0)
                       #f)

                      ((and range (%c-true range)) ; "point is within or approaching a literal."
                       (cond
                        ;; "Single line string or sentence-flag is null =>
                        ;; skip the entire literal."
                        ((or (not sentence-flag)
                             (c-one-line-string-p range))
                         (goto-char (car range))
                         (setq range (c-ascertain-preceding-literal))
                         ;; "N.B. The following is essentially testing
                         ;; for an AWK regexp at BOS: Was the previous
                         ;; non-ws thing an end of statement?"
                         (save-excursion
                           (if macro-fence
                               (c-backward-comments)
                               (c-backward-syntactic-ws))
                           (not (or (bobp) (c-after-statement-terminator-p)))))

                        ;; "Comment inside a statement or a multi-line string."
                        (else
                         (when-e (setq res ; "returns non-nil when we go out of the literal"
                                       (if (eq? (c-literal-type range) 'string)
                                           (c-beginning-of-sentence-in-string range)
                                           (c-beginning-of-sentence-in-comment range)))
                           (setq range (c-ascertain-preceding-literal)))
                         res)))

                      ;; "Non-literal code."
                      (else
                       (setq res (c-back-over-illiterals macro-fence))
                       (setq not-bos ; "\"not reached beginning-of-statement\"."
                             (or (= (point) last)
                                 (memq (char-after) (list #\) #\}))
                                 (and
                                  (car res)
                                  ;; "We're at a tentative BOS.  The next
                                  ;; form goes back over WS looking for an
                                  ;; end of previous statement."
                                  (not (save-excursion
                                         (if macro-fence
                                             (c-backward-comments)
                                             (c-backward-syntactic-ws))
                                         (or (bobp)
                                             (c-after-statement-terminator-p)))))))
                       ;; "Are we about to move backwards into or out of a
                       ;; preprocessor command?  If so, locate its
                       ;; beginning."
                       (when-e (eq? (cdr res) 'macro-boundary)
                         (save-excursion
                           (beginning-of-line)
                           (setq macro-fence
                                 (and (not (bobp))
                                      (begin (c-skip-ws-backward)
                                             (c-beginning-of-macro))
                                      (point)))))
                       ;; "Are we about to move backwards into a literal?"
                       (when-e (memq (cdr res) '(macro-boundary literal))
                         (setq range (c-ascertain-preceding-literal)))
                       not-bos))
                   (setq last (point)))

                 (if (/= count 0) (setq count (- count 1))))
               (c-keep-region-active))))))

    (define-command (c-end-of-statement . rest)
      "Go to the end of the innermost C statement.
With prefix arg, go forward N - 1 statements.  Move forward to the end
of the next statement if already at end, and move into nested blocks
\\(use \\[forward-sexp] to skip over a block).  If within or next to a
comment or multiline string, move by sentences instead of statements.

When called from a program, this function takes 3 optional args: the
repetition count, a buffer position limit which is the farthest back
to search for the syntactic context, and a flag saying whether to do
sentence motion in or near comments and multiline strings."
      (interactive (list (prefix-numeric-value (current-prefix-arg))
                         #f #t))
      (let ((count (if (pair? rest) (car rest) #f))
            (lim (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (sentence-flag (if (and (pair? rest) (pair? (cdr rest))
                                    (pair? (cddr rest)))
                               (caddr rest)
                               #f)))
        (setq count (or count 1))
        (if (< count 0)
            (c-beginning-of-statement (- count) lim sentence-flag)
            (c-with-string-fences
             (c-save-buffer-state
                 ((here #f) ; "start point for going forward ONE statement.  Updated each statement."
                  (macro-fence
                   (save-excursion
                     (and (not (eobp)) (c-beginning-of-macro)
                          (begin (c-end-of-macro) (point)))))
                  (res #f)
                  (range (c-collect-line-comments (c-literal-limits lim))))
               ;; "(start.end) of current literal or NIL"

               ;; "Go back/forward one statement at each iteration of the
               ;; following loop."
               (while-e (and (/= count 0)
                             (or (not lim) (< (point) lim)))
                 (setq here (point)) ; "ONLY HERE is HERE updated"

                 ;; "Go forward one \"chunk\" each time round the
                 ;; following loop, stopping when we reach a statement
                 ;; boundary, etc."
                 (while-e
                     (cond ; "Each arm of this cond returns NIL on reaching
                            ; a desired statement boundary, non-NIL otherwise."
                      ((eobp)
                       (setq count 0)
                       #f)

                      ((and range (%c-true range)) ; "point is within a literal."
                       (cond
                        ;; "sentence-flag is null => skip the entire
                        ;; literal. or a Single line string."
                        ((or (not sentence-flag)
                             (c-one-line-string-p range))
                         (goto-char (cdr range))
                         (setq range (c-ascertain-following-literal))
                         ;; "Is there a virtual semicolon here (e.g. for AWK)?"
                         (not (c-at-vsemi-p)))

                        ;; "Comment or multi-line string."
                        (else
                         (when-e (setq res ; "gets non-nil when we go out of the literal"
                                       (if (eq? (c-literal-type range) 'string)
                                           (c-end-of-sentence-in-string range)
                                           (c-end-of-sentence-in-comment range)))
                           (setq range (c-ascertain-following-literal)))
                         ;; "If we've just come forward out of a literal,
                         ;; check for vsemi.  (N.B. AWK can't have a
                         ;; vsemi after a comment, but some other language
                         ;; may do in the future)"
                         (and res
                              (not (c-at-vsemi-p))))))

                      ;; "Non-literal code."
                      (else
                       (setq res (c-forward-over-illiterals macro-fence
                                                            (> (point) here)))
                       ;; "Are we about to move forward into or out of a
                       ;; preprocessor command?"
                       (when-e (eq? (cdr res) 'macro-boundary)
                         (setq macro-fence
                               (save-excursion
                                 (if macro-fence
                                     (begin
                                       (end-of-line)
                                       (and (not (eobp))
                                            (begin (c-skip-ws-forward)
                                                   (c-beginning-of-macro))
                                            (begin (c-end-of-macro)
                                                   (point))))
                                     (and (not (eobp))
                                          (c-beginning-of-macro)
                                          (begin (c-end-of-macro)
                                                 (point)))))))
                       ;; "Are we about to move forward into a literal?"
                       (when-e (memq (cdr res) '(macro-boundary literal))
                         (setq range (c-ascertain-following-literal)))
                       (car res)))
                   #t)

                 (if (/= count 0) (setq count (- count 1))))
               (c-keep-region-active))))))

    ;; ---------------------------------------------------------------
    ;; Inserting/indenting comments (`cc-cmds.el:3260'-`:3353')
    ;;--------------------------------------------------------------
    (define (c-calc-comment-indent entry)
      ;; "This function might do hidden buffer changes."
      (if (symbol? entry)
          (setq entry (or (assq entry (c-indent-comment-alist))
                          (assq 'other (c-indent-comment-alist))
                          '(default . (column . #f)))))
      (let ((action (car (cdr entry)))
            (value (cdr (cdr entry)))
            (col (current-column)))
        (cond ((eq? action 'space)
               (+ col value))
              ((eq? action 'column)
               (unless value (setq value (comment-column)))
               (if (bolp)
                   ;; "Do not pad with one space if we're at bol."
                   value
                   (max (+ col 1) value)))
              ((eq? action 'align)
               (or (save-excursion
                     (beginning-of-line)
                     (unless (bobp)
                       (backward-char 1)
                       (let ((lim (c-literal-limits (c-point 'bol) #t)))
                         (when-e (pair? lim)
                           (goto-char (car lim))
                           (when-e (looking-at "/[/*]") ; "FIXME!!!  Adapt for AWK! (ACM, 2005/11/18)"
                             ;; "Found comment to align with."
                             (if (bolp)
                                 ;; "Do not pad with one space if we're at bol."
                                 0
                                 (max (+ col 1) (current-column))))))))
                   ;; "Recurse to handle value as a new spec."
                   (c-calc-comment-indent (cdr entry))))
              (else #f))))

    (define (c-comment-indent)
      "Used by `indent-for-comment' to create and indent comments.
See `c-indent-comment-alist' for a description."
      (save-excursion
        (end-of-line)
        (parameterize ((*case-fold-search* #f))
          (c-save-buffer-state
              ((eot (let ((lim (c-literal-limits (c-point 'bol) #t)))
                      (or (when-e (pair? lim)
                            (goto-char (car lim))
                            (when-e (looking-at "/[/*]")
                              (skip-chars-backward " \t")
                              (point)))
                          (begin
                            (skip-chars-backward " \t")
                            (point)))))
               (line-type
                (cond ((looking-at "^/[/*]")
                       'anchored-comment)
                      ((begin (beginning-of-line)
                              (= (point) eot))
                       'empty-line)
                      ((begin (back-to-indentation)
                              (and (%c-char-after=? #\})
                                   (= (point) (- eot 1))))
                       'end-block)
                      ((and (looking-at "#[ \t]*\\(endif\\|else\\)")
                            (= (match-end 0) eot))
                       'cpp-end-block)
                      (else
                       'other))))
            (if (and (memq line-type '(anchored-comment empty-line))
                     ;; The accessor answers Elisp's nil as `() - true
                     ;; here - so ask `%c-true`, not `if`.
                     (%c-true (c-indent-comments-syntactically-p)))
                (parameterize ((*c-syntactic-context* (c-guess-basic-syntax)))
                  ;; "BOGOSITY ALERT: if we're looking at the eol, its
                  ;; because indent-for-comment hasn't put the
                  ;; comment-start in the buffer yet.  this will screw up
                  ;; the syntactic analysis so we kludge in the necessary
                  ;; info.  Another kludge is that if we're at the bol,
                  ;; then we really want to ignore any anchoring as
                  ;; specified by c-comment-only-line-offset since it
                  ;; doesn't apply here."
                  (if (eolp)
                      (c-add-syntax 'comment-intro))
                  (let ((c-comment-only-line-offset
                         (let ((o (c-comment-only-line-offset)))
                           (if (pair? o)
                               o
                               (cons o o)))))
                    (c-get-syntactic-indentation (*c-syntactic-context*))))
                (begin
                  (goto-char eot)
                  (c-calc-comment-indent line-type)))))))

    (define (c-outline-level)
      ;; "used by outline-minor-mode"
      ;;
      ;; Emacs binds `buffer-invisibility-spec' nil here so
      ;; `current-column' ignores invisible text; there is no
      ;; invisibility in this tree (see `indentc.scm'), so the binding
      ;; has nothing to do.
      (save-excursion
        (skip-chars-forward "\t ")
        (current-column)))

    ;; ---------------------------------------------------------------
    ;; Movement by CPP conditionals (`cc-cmds.el:3357'-`:3531')
    ;;--------------------------------------------------------------
    (define-command (c-up-conditional count)
      "Move back to the containing preprocessor conditional, leaving mark behind.
A prefix argument acts as a repeat count.  With a negative argument,
move forward to the end of the containing preprocessor conditional.

\"#elif\" is treated like \"#else\" followed by \"#if\", so the
function stops at them when going backward, but not when going
forward."
      (interactive "p")
      (let ((new-point (c-scan-conditionals (- count) -1)))
        (push-mark)
        (goto-char new-point))
      (c-keep-region-active))

    (define-command (c-up-conditional-with-else count)
      "Move back to the containing preprocessor conditional, including \"#else\".
Just like `c-up-conditional', except it also stops at \"#else\"
directives."
      (interactive "p")
      (let ((new-point (c-scan-conditionals (- count) -1 #t)))
        (push-mark)
        (goto-char new-point))
      (c-keep-region-active))

    (define-command (c-down-conditional count)
      "Move forward into the next preprocessor conditional, leaving mark behind.
A prefix argument acts as a repeat count.  With a negative argument,
move backward into the previous preprocessor conditional.

\"#elif\" is treated like \"#else\" followed by \"#if\", so the
function stops at them when going forward, but not when going
backward."
      (interactive "p")
      (let ((new-point (c-scan-conditionals count 1)))
        (push-mark)
        (goto-char new-point))
      (c-keep-region-active))

    (define-command (c-down-conditional-with-else count)
      "Move forward into the next preprocessor conditional, including \"#else\".
Just like `c-down-conditional', except it also stops at \"#else\"
directives."
      (interactive "p")
      (let ((new-point (c-scan-conditionals count 1 #t)))
        (push-mark)
        (goto-char new-point))
      (c-keep-region-active))

    (define-command (c-backward-conditional count . rest)
      "Move back across a preprocessor conditional, leaving mark behind.
A prefix argument acts as a repeat COUNT.  With a negative argument,
move forward across a preprocessor conditional.

The optional arguments TARGET-DEPTH and WITH-ELSE are historical,
and have the same meanings as in `c-scan-conditionals'.  If you
are calling `c-forward-conditional' from a program, you might want
to call `c-scan-conditionals' directly instead."
      (interactive "p")
      (let ((target-depth (if (pair? rest) (car rest) #f))
            (with-else (if (and (pair? rest) (pair? (cdr rest)))
                           (cadr rest)
                           #f)))
        (let ((new-point (c-scan-conditionals (- count)
                                              target-depth with-else)))
          (push-mark)
          (goto-char new-point))
        (c-keep-region-active)))

    (define-command (c-forward-conditional count . rest)
      "Move forward across a preprocessor conditional, leaving mark behind.
A prefix argument acts as a repeat count.  With a negative argument,
move backward across a preprocessor conditional.

If there aren't enough conditionals after (or before) point, an
error is signaled.

\"#elif\" is treated like \"#else\" followed by \"#if\", except that
the nesting level isn't changed when tracking subconditionals.

The optional arguments TARGET-DEPTH and WITH-ELSE are historical,
and have the same meanings as in `c-scan-conditionals'.  If you
are calling c-forward-conditional from a program, you might want
to call `c-scan-conditionals' directly instead."
      (interactive "p")
      (let ((target-depth (if (pair? rest) (car rest) #f))
            (with-else (if (and (pair? rest) (pair? (cdr rest)))
                           (cadr rest)
                           #f)))
        (let ((new-point (c-scan-conditionals count target-depth with-else)))
          (push-mark)
          (goto-char new-point))
        (c-keep-region-active)))

    (define (c-scan-conditionals count . rest)
      "Scan forward across COUNT preprocessor conditionals.
With a negative argument, scan backward across preprocessor
conditionals.  Return the end position.  Point is not moved.

If there aren't enough preprocessor conditionals, throw an error.

\"#elif\" is treated like \"#else\" followed by \"#if\", except that
the nesting level isn't changed when tracking subconditionals.

The optional argument TARGET-DEPTH specifies the wanted nesting depth
after each scan.  E.g. if TARGET-DEPTH is -1, the end position will be
outside the enclosing conditional.  A non-integer non-nil TARGET-DEPTH
counts as -1.

If the optional argument WITH-ELSE is non-nil, \"#else\" directives
are treated as conditional clause limits.  Normally they are ignored."
      (let* ((target-depth (if (pair? rest) (car rest) #f))
             (with-else (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest)
                            #f))
             (forward (> count 0))
             (increment (if forward -1 1))
             (search-function (if forward re-search-forward
                                  re-search-backward))
             (new #f))
        (unless (integer? target-depth)
          (setq target-depth (if target-depth -1 0)))
        (save-excursion
          (while-e (/= count 0)
            (let ((depth 0)
                  ;; "subdepth is the depth in \"uninteresting\"
                  ;; subtrees, i.e. those that takes us farther from the
                  ;; target depth instead of closer."
                  (subdepth 0)
                  (found #f))
              (save-excursion
                ;; "Find the \"next\" significant line in the proper
                ;; direction."
                (while-e (and (not found)
                              ;; "Rather than searching for a # sign that
                              ;; comes at the beginning of a line aside
                              ;; from whitespace, search first for a
                              ;; string starting with # sign.  Then
                              ;; verify what precedes it.  This is faster
                              ;; on account of the fastmap feature of the
                              ;; regexp matcher."
                              (search-function
                               "#[ \t]*\\(if\\|elif\\|endif\\|else\\)"
                               #f #t))
                  (beginning-of-line)
                  ;; "Now verify it is really a preproc line."
                  (if (looking-at "^[ \t]*#[ \t]*\\(if\\|elif\\|endif\\|else\\)")
                      (let ((dchange #f)
                            (directive (match-string 1)))
                        (cond ((string=? directive "if")
                               (setq dchange (- increment)))
                              ((string=? directive "endif")
                               (setq dchange increment))
                              ((= subdepth 0)
                               ;; "When we're not in an \"uninteresting\"
                               ;; subtree, we might want to act on
                               ;; \"elif\" and \"else\" too."
                               (if (cond (with-else
                                          ;; "Always move toward the
                                          ;; target depth."
                                          (setq dchange
                                                (if (> target-depth 0) 1 -1)))
                                         ((string=? directive "elif")
                                          (setq dchange (- increment)))
                                         (else #f))
                                   ;; "Ignore the change if it'd take us
                                   ;; into an \"uninteresting\" subtree."
                                   (if (eq? (> dchange 0) (<= target-depth 0))
                                       (setq dchange #f)))))
                        (when-e dchange
                          (when-e (or (/= subdepth 0)
                                      (eq? (> dchange 0) (<= target-depth 0)))
                            (setq subdepth (+ subdepth dchange)))
                          (setq depth (+ depth dchange))
                          ;; "If we are trying to move across, and we find
                          ;; an end before we find a beginning, get an
                          ;; error."
                          (if (and (< depth target-depth) (< dchange 0))
                              (error (if forward
                                         "No following conditional at this level"
                                         "No previous conditional at this level"))))
                        ;; "When searching forward, start from next line
                        ;; so that we don't find the same line again."
                        (if forward (forward-line 1))
                        ;; "We found something if we've arrived at the
                        ;; target depth."
                        (if (and dchange (= depth target-depth))
                            (setq found (point))))
                      ;; "else"
                      (if forward (forward-line 1)))))
              (or found
                  (error "No containing preprocessor conditional"))
              (goto-char (setq new found)))
            (setq count (+ count increment))))
        (c-keep-region-active)
        new))

    ;; ---------------------------------------------------------------
    ;; `c-indent-command' (`cc-cmds.el:3535')
    ;;--------------------------------------------------------------
    (define-command (c-indent-command arg)
      "Indent current line as C code, and/or insert some whitespace.

If `c-tab-always-indent' is t, always just indent the current line.
If nil, indent the current line only if point is at the left margin or
in the line's indentation; otherwise insert some whitespace[*].  If
other than nil or t, then some whitespace[*] is inserted only within
literals (comments and strings), but the line is always reindented.

If `c-syntactic-indentation' is t, indentation is done according to
the syntactic context.  A numeric argument, regardless of its value,
means indent rigidly all the lines of the expression starting after
point so that this line becomes properly indented.  The relative
indentation among the lines of the expression is preserved.

If `c-syntactic-indentation' is nil, the line is just indented one
step according to `c-basic-offset'.  In this mode, a numeric argument
indents a number of such steps, positive or negative, and an empty
prefix argument is equivalent to -1.

  [*] The amount and kind of whitespace inserted is controlled by the
  variable `c-insert-tab-function', which is called to do the actual
  insertion of whitespace.  Normally the function in this variable
  just inserts a tab character, or the equivalent number of spaces,
  depending on the variable `indent-tabs-mode'."
      (interactive "P")
      (c-with-string-fences
       (let ((indent-function
              (if (c-syntactic-indentation)
                  indent-according-to-mode
                  (lambda ()
                    (parameterize ((*c-macro-start* (*c-macro-start*)))
                      (let ((steps (if (equal? arg '(4))
                                       -1
                                       (prefix-numeric-value arg))))
                        (c-shift-line-indentation
                         (* steps (c-basic-offset)))
                        (when (and (*c-auto-align-backslashes*)
                                   (save-excursion
                                     (end-of-line)
                                     (eq? (char-before) #\\))
                                   (c-query-and-set-macro-start))
                          ;; Realign the line continuation backslash if
                          ;; inside a macro.
                          (c-backslash-region (point) (point) #f #t))))))))
         (if (and (c-syntactic-indentation) arg)
             ;; If c-syntactic-indentation and got arg, always indent
             ;; this line as C and shift remaining lines of expression
             ;; the same amount.
             (let ((shift-amt (save-excursion
                                (back-to-indentation)
                                (current-column)))
                   (beg #f) (end #f))
               (c-indent-line)
               (set! shift-amt (- (save-excursion
                                    (back-to-indentation)
                                    (current-column))
                                  shift-amt))
               (save-excursion
                 (if (eq? (*c-tab-always-indent*) #t)
                     (beginning-of-line)) ; FIXME!!! What is this here for?  ACM 2005/10/31
                 (set! beg (point))
                 (c-forward-sexp 1)
                 (set! end (point))
                 (goto-char beg)
                 (forward-line 1)
                 (set! beg (point)))
               (if (> end beg)
                   (indent-code-rigidly beg end shift-amt "#")))
             ;; Else use c-tab-always-indent to determine behavior.
             (cond
              ;; CASE 1: indent when at column zero or in line's
              ;; indentation, otherwise insert a tab
              ((not (*c-tab-always-indent*))
               (if (save-excursion
                     (skip-chars-backward " \t")
                     (not (bolp)))
                   ((*c-insert-tab-function*))
                   (indent-function)))
              ;; CASE 2: just indent the line
              ((eq? (*c-tab-always-indent*) #t)
               (indent-function))
              ;; CASE 3: if in a literal, insert a tab, but always indent
              ;; the line
              (else
               (if (c-save-buffer-state () (c-in-literal))
                   ((*c-insert-tab-function*)))
               (indent-function)))))))

    ;; ---------------------------------------------------------------
    ;; `c-indent-exp' (`cc-cmds.el:3625')
    ;;--------------------------------------------------------------
    (define-command (c-indent-exp shutup-p)
      "Indent each line in the balanced expression following point syntactically.
If optional SHUTUP-P is non-nil, no errors are signaled if no
balanced expression is found."
      (interactive "*P")
      (c-with-string-fences
       (let ((here (point-marker))
             (end #f))
         (set-marker-insertion-type here #t)
         (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let ((start
                   (save-restriction
                     ;; Find the closest following open paren that
                     ;; ends on another line.
                     (narrow-to-region (point-min) (c-point 'eol))
                     (let ((beg #f) (end (point)))
                       ;; The C's `(setq beg ...)' answers the new value,
                       ;; which is the loop's test; Guile's `set!'
                       ;; answers the unspecified value, which is true -
                       ;; so each is followed by its variable.
                       (while-e (and (begin (set! beg (c-down-list-forward end))
                                            beg)
                                     (begin (set! end (c-up-list-forward beg))
                                            end)))
                       (and beg
                            (eqv? (char-syntax (char-before beg)) #\()
                            (- beg 1))))))
              ;; sanity check
              (if (not start)
                  (unless shutup-p
                    (error "Cannot find start of balanced expression to indent"))
                  (begin
                    (goto-char start)
                    (set! end (c-safe (scan-sexps (point) 1)))
                    (if (not end)
                        (unless shutup-p
                          (error "Cannot find end of balanced expression to indent"))
                        (begin
                          (forward-line 1)
                          (if (< (point) end)
                              (c-indent-region (point) end))))))))
          (lambda ()
            (goto-char here)
            (set-marker here #f))))))

    ;; ---------------------------------------------------------------
    ;; `c-indent-defun' (`cc-cmds.el:3660')
    ;;--------------------------------------------------------------
    (define-command (c-indent-defun)
      "Indent the current top-level declaration or macro syntactically.
In the macro case this also has the effect of realigning any line
continuation backslashes, unless `c-auto-align-backslashes' is nil."
      (interactive "*")
      (c-with-string-fences
       (let ((here (point-marker)) (decl-limits #f))
         (parameterize ((*case-fold-search* #f))
           (dynamic-wind
            (lambda () #f)
            (lambda ()
              (c-save-buffer-state ()
                ;; "We try to be line oriented, unless there are several
                ;; declarations on the same line."
                (if (looking-at (%c-langvar 'c-syntactic-eol))
                    (c-backward-token-2 1 #f (c-point 'bol))
                    (c-forward-token-2 0 #f (c-point 'eol)))
                (set! decl-limits (c-declaration-limits #f)))
              (if decl-limits
                  (c-indent-region (car decl-limits)
                                   (cdr decl-limits))
                  #f))
            (lambda ()
              (goto-char here)
              (set-marker here #f)))))))

    ;; ---------------------------------------------------------------
    ;; `c-indent-region' (`cc-cmds.el:3682')
    ;;--------------------------------------------------------------
    (define (c-indent-region start end . quiet-args)
      ;; "Indent syntactically lines whose first char is between START
      ;; and END inclusive. If the optional argument QUIET is non-nil
      ;; then no syntactic errors are reported, even if
      ;; `c-report-syntactic-errors' is non-nil."
      (let ((quiet (if (pair? quiet-args) (car quiet-args) #f)))
        (save-excursion
          (goto-char end)
          (skip-chars-backward " \t\n\r\f\v")
          (set! end (point))
          (goto-char start)
          ;; Advance to first nonblank line.
          (beginning-of-line)
          (skip-chars-forward " \t\n\r\f\v")
          (set! start (point))
          (beginning-of-line)
          (set!c-parsing-error
           (or (call-with-buffer-local
                'c-parsing-error #f
                (lambda ()
                  (parameterize ((*c-echo-syntactic-information-p* #f)
                                 (*c-fix-backslashes* #f))
                    (let ((endmark (copy-marker end))
                          (syntax #f)
                          ;; Start pos of multi-line macro.
                          (ml-macro-start
                           (and (c-save-buffer-state ()
                                  (save-excursion (c-beginning-of-macro)))
                                (eq? (char-before (c-point 'eol)) #\\)
                                start)))
                      (dynamic-wind
                       (lambda () #f)
                       (lambda ()
                         (c-progress-init start end 'c-indent-region)
                         (while-e (and (bolp) ; One line each time round the loop.
                                       (not (eobp))
                                       (< (point) (marker-position endmark)))
                                   ;; update progress
                                   (c-progress-update)
                                   ;; skip empty lines
                                   (unless (or (looking-at "\\s *$")
                                               (and ml-macro-start
                                                    (looking-at "\\s *\\\\$")))
                                     ;; Get syntax and indent.
                                     (c-save-buffer-state ()
                                       (set! syntax (c-guess-basic-syntax)))
                                     (c-indent-line syntax #t #t))
                                   (if ml-macro-start
                                       ;; End of current multi-line macro?
                                       (when (and (*c-auto-align-backslashes*)
                                                  (not (eq? (char-before
                                                             (c-point 'eol))
                                                            #\\)))
                                         ;; Fixup macro backslashes.
                                         (c-backslash-region ml-macro-start
                                                             (c-point 'bonl) #f)
                                         (set! ml-macro-start #f))
                                       ;; New multi-line macro?
                                       (if (and (assq 'cpp-macro syntax)
                                                (eq? (char-before
                                                      (c-point 'eol))
                                                     #\\))
                                           (set! ml-macro-start (point))))
                                   (forward-line 1))
                         (if (and ml-macro-start (*c-auto-align-backslashes*))
                             (c-backslash-region ml-macro-start
                                                 (c-point 'bopl) #f #t)))
                       (lambda ()
                         (set-marker endmark #f)
                         (c-progress-fini 'c-indent-region)))
                      (c-echo-parsing-error quiet)))))
               (c-parsing-error))))))

    ;; ---------------------------------------------------------------
    ;; `c-fn-region-is-active-p' and `c-indent-line-or-region'
    ;; (`cc-cmds.el:3747', `:3752')
    ;;--------------------------------------------------------------
    (define (c-fn-region-is-active-p)
      ;; Function version of the macro for use in places that aren't
      ;; compiled, e.g. in the menus.
      (c-region-is-active-p))

    (define-command (c-indent-line-or-region arg region)
      "Indent active region, current line, or block starting on this line.
In Transient Mark mode, when the region is active, reindent the region.
Otherwise, with a prefix argument, rigidly reindent the expression
starting on the current line.
Otherwise reindent just the current line."
      (interactive (list (current-prefix-arg) (c-region-is-active-p)))
      (c-with-string-fences
       (if region
           (c-indent-region (region-beginning) (region-end))
           (c-indent-command arg))))

    ;; ---------------------------------------------------------------
    ;; Progress reporting (`cc-cmds.el:3766')
    ;;--------------------------------------------------------------
    ;; A plain variable in Emacs (`defvar'), and set only by these three
    ;; functions, so a plain variable here.
    (define c-progress-info #f)

    (define (c-progress-init start end context)
      (cond
       ;; Be silent
       ((not (*c-progress-interval*)) #f)
       ;; Start the progress update messages. If this Emacs doesn't have
       ;; a built-in timer, just be dumb about it.
       ((not (procedure? current-time))
        (message "Indenting region... (this may take a while)"))
       ;; If progress has already been initialized, do nothing. otherwise
       ;; initialize the counter with a vector of:
       ;;     [start end lastsec context]
       (c-progress-info #f)
       (else
        (set! c-progress-info (vector start
                                      (save-excursion
                                        (goto-char end)
                                        (point-marker))
                                      (time-convert #f 'integer)
                                      context))
        (message "Indenting region..."))))

    (define (c-progress-update)
      (if (not (and c-progress-info (*c-progress-interval*)))
          #f
          (let ((now (time-convert #f 'integer))
                (start (aref c-progress-info 0))
                (end (aref c-progress-info 1))
                (lastsecs (aref c-progress-info 2)))
            ;; should we update? currently, update happens every 2
            ;; seconds, what's the right value?
            (if (< (*c-progress-interval*) (- now lastsecs))
                (begin
                  ;; Emacs's `(floor X Y)' (a divisor was added to
                  ;; Emacs's `floor'); Guile's takes one argument.
                  (message "Indenting region... (%d%% complete)"
                           (floor (/ (* 100.0 (- (point) start))
                                     (- (marker-position end) start))))
                  (aset c-progress-info 2 now))))))

    (define (c-progress-fini context)
      (if (not (*c-progress-interval*))
          #f
          (if (or (eq? context (aref c-progress-info 3))
                  (eq? context #t))
              (begin
                (set-marker (aref c-progress-info 1) #f)
                (set! c-progress-info #f)
                (message "Indenting region... done")))))

    ;; ---------------------------------------------------------------
    ;; `c-backslash-region' (`cc-cmds.el:3819') and its two helpers
    ;;--------------------------------------------------------------
    (define-command (c-backslash-region from to delete-flag . line-mode-args)
      "Insert, align, or delete end-of-line backslashes on the lines in the region.
    With no argument, inserts backslashes and aligns existing backslashes.
    With an argument, deletes the backslashes.  The backslash alignment is
    done according to the settings in `(c-backslash-column)',
    `(c-backslash-max-column)' and `(*c-auto-align-backslashes*)'.

    This function does not modify blank lines at the start of the region.
    If the region ends at the start of a line and the macro doesn't
    continue below it, the backslash (if any) at the end of the previous
    line is deleted.

    You can put the region around an entire macro definition and use this
    command to conveniently insert and align the necessary backslashes."
      (interactive "*r\nP")
      (let ((line-mode (if (pair? line-mode-args) (car line-mode-args) #f)))
      (let ((endmark (make-marker))
            ;; Keep the backslash trimming functions from changing the
            ;; whitespace around point, since in this case it's only the
            ;; position of point that tells the indentation of the line.
            (point-pos (if (save-excursion
                             (skip-chars-backward " \t")
                             (and (bolp) (looking-at "[ \t]*\\\\?$")))
                           (point-marker)
                         (point-min)))
            (column #f) (longest-line-col #f) (bs-col-after-end #f))
        (save-excursion
          (goto-char to)
          (if (and (not line-mode) (bobp))
              ;; Nothing to do if to is at bob, since we should back up
              ;; and there's no line to back up to.
              #f
            (begin
            (when (and (not line-mode) (bolp))
              ;; Do not back up the to line if line-mode is set, to make
              ;; e.g. c-newline-and-indent consistent regardless whether
              ;; the (newline) call leaves point at bol or not.
              (backward-char)
              (set! to (point)))
            (if delete-flag
                (begin
                  (set-marker endmark (point))
                  (goto-char from)
                  (c-delete-backslashes-forward endmark point-pos))
              (begin
              ;; Set bs-col-after-end to the column of any backslash
              ;; following the region, or #f if there is none.
              (set! bs-col-after-end
                    (and (begin (end-of-line)
                                (eq? (char-before) #\\))
                         (= (forward-line 1) 0)
                         (begin (end-of-line)
                                (eq? (char-before) #\\))
                         (- (current-column) 1)))
              (when line-mode
                ;; Back up the to line if line-mode is set, since the line
                ;; after the newly inserted line break should not be
                ;; touched in c-newline-and-indent.
                (set! to (max from (or (c-safe (c-point 'eopl)) from)))
                (unless bs-col-after-end
                  ;; Set bs-col-after-end to non-#f in any case, since we
                  ;; do not want to delete the backslash at the last line.
                  (set! bs-col-after-end #t)))
              (if (and line-mode
                       (not (*c-auto-align-backslashes*)))
                  (goto-char from)
                (begin
                ;; Compute the smallest column number past the ends of all
                ;; the lines.
                (set! longest-line-col 0)
                (goto-char to)
                (if bs-col-after-end
                    ;; Include one more line in the max column
                    ;; calculation, since the to line will be backslashed
                    ;; too.
                    (forward-line 1))
                (end-of-line)
                (while-e (and (>= (point) from)
                            (begin
                              (if (eq? (char-before) #\\)
                                  (forward-char -1))
                              (skip-chars-backward " \t")
                              (set! longest-line-col (max longest-line-col
                                                          (+ (current-column) 1)))
                              (beginning-of-line)
                              (not (bobp))))
                  (backward-char))
                ;; Try to align with surrounding backslashes.
                (goto-char from)
                (beginning-of-line)
                (if (and (not (bobp))
                         (begin (backward-char)
                                (eq? (char-before) #\\)))
                    (begin
                      (set! column (- (current-column) 1))
                      (if (number? bs-col-after-end)
                          ;; Both a preceding and a following backslash.
                          ;; Choose the greatest of them.
                          (set! column (max column bs-col-after-end)))
                      (goto-char from))
                  (begin
                  ;; No preceding backslash.  Try to align with one
                  ;; following the region.  Disregard the backslash at the
                  ;; to line since it's likely to be bogus (e.g. when
                  ;; called from c-newline-and-indent).
                  (if (number? bs-col-after-end)
                      (set! column bs-col-after-end))
                  ;; Don't modify blank lines at start of region.
                  (goto-char from)
                  (while-e (and (< (point) to) (bolp) (eolp))
                    (forward-line 1))))
                (if (and column (< column longest-line-col))
                    ;; Don't try to align with surrounding backslashes if
                    ;; any line is too long.
                    (set! column #f))
                (unless column
                  ;; Impose minimum limit and tab width alignment only if
                  ;; we can't align with surrounding backslashes.
                  (if (> (modulo longest-line-col (*tab-width*)) 0)
                      (set! longest-line-col
                            (* (/ (+ longest-line-col (*tab-width*) -1)
                                  (*tab-width*))
                               (*tab-width*))))
                  (set! column (max (c-backslash-column)
                                    longest-line-col)))
                ;; Always impose maximum limit.
                (set! column (min column (c-backslash-max-column)))))
              (if bs-col-after-end
                  ;; Add backslashes on all lines if the macro continues
                  ;; after the to line.
                  (begin
                    (set-marker endmark to)
                    (c-append-backslashes-forward endmark column point-pos))
                ;; Add backslashes on all lines except the last, and
                ;; remove any on the last line.
                (begin
                (if (save-excursion
                      (goto-char to)
                      (beginning-of-line)
                      (if (not (bobp))
                          (set-marker endmark (- (point) 1))))
                    (begin
                      (c-append-backslashes-forward endmark column point-pos)
                      ;; The function above leaves point on the line
                      ;; following endmark.
                      (set-marker endmark (point)))
                  (set-marker endmark to))
                (c-delete-backslashes-forward endmark point-pos))))))))
        (set-marker endmark #f)
        (if (markerp point-pos)
            (set-marker point-pos #f)))))

    (define (c-append-backslashes-forward to-mark column point-pos)
      ;; The tree's markers do no arithmetic; `%pos' is Emacs's coercion
      ;; of a number-or-marker argument.
      (let* ((%pos (lambda (p) (if (markerp p) (marker-position p) p)))
             (state (parse-partial-sexp (c-point 'bol) (point))))
        (if column
            (while-e (and
                      (<= (point) (marker-position to-mark))

                      (let ((start (point)) (inserted #f) (end #f) (col #f))
                        (end-of-line)
                        (unless (eq? (char-before) #\\)
                          (insert #\\)
                          (set! inserted #t))
                        (set! state (parse-partial-sexp start (point)
                                                        #f #f state))
                        (backward-char 1)
                        (set! col (current-column))

                        ;; Avoid unnecessary changes of the buffer.
                        (cond
                         ((and (not inserted) (list-ref state 3))
                          ;; Don't realign backslashes in string literals
                          ;; since that would change them.
                          )
                         ((< col column)
                          (delete-region
                           (point)
                           (begin
                             (skip-chars-backward
                              " \t" (if (>= (point) (%pos point-pos))
                                        point-pos
                                        #f))
                             (point)))
                          (indent-to column))
                         ((and (= col column)
                               (memv (char-before) (list #\space #\tab)))
                          #f)
                         ((begin
                            (set! end (point))
                            (or (not (= (skip-chars-backward
                                         " \t"
                                         (if (>= (point) (%pos point-pos))
                                             point-pos
                                             #f))
                                        -1))
                                (not (eq? (char-after) #\space))))
                          (delete-region (point) end)
                          (indent-to column 1)))
                        (= 0 (forward-line 1)))
                      (bolp)))  ; forward-line has funny behavior at eob.

              ;; Make sure there are backslashes with at least one space in
              ;; front of them.
              (while-e (and
                        (<= (point) (marker-position to-mark))

                        (let ((start (point)))
                          (end-of-line)
                          (set! state (parse-partial-sexp start (point)
                                                          #f #f state))
                          (if (eq? (char-before) #\\)
                              (unless (list-ref state 3)
                                (backward-char 1)
                                (unless (and (memv (char-before)
                                                   (list #\space #\tab))
                                             (not (= (point) (%pos point-pos))))
                                  (insert #\space)))
                              (if (and (memv (char-before) (list #\space #\tab))
                                       (not (= (point) (%pos point-pos))))
                                  (insert #\\)
                                  (insert "\\ ")))
                          (= 0 (forward-line 1)))
                        (bolp))))))  ; forward-line has funny behavior at eob.

    (define (c-delete-backslashes-forward to-mark point-pos)
      (let ((%pos (lambda (p) (if (markerp p) (marker-position p) p))))
        (while-e (and (<= (point) (marker-position to-mark))
                      (begin
                        (end-of-line)
                        (if (eq? (char-before) #\\)
                            (delete-region
                             (point)
                             (begin (backward-char 1)
                                    (skip-chars-backward
                                     " \t"
                                     (if (>= (point) (%pos point-pos))
                                         point-pos
                                         #f))
                                    (point))))
                        (= 0 (forward-line 1)))
                      (bolp)))))

    ;; ---------------------------------------------------------------
    ;; `(run-hooks 'c-special-indent-hook)' for a hook that can hold a
    ;; `t' and function symbols
    ;;--------------------------------------------------------------
    (define (c-run-special-indent-hook)
      ;; GNU Emacs's `(run-hooks 'c-special-indent-hook)' with the two
      ;; things this tree spells differently. `run_hook_with_args'
      ;; (`eval.c:2999') walks the value: a `t' element means "run the
      ;; global value too" (`subr.el:2317', which is what `add-hook' with
      ;; LOCAL leaves at the front), and every other element is
      ;; `funcall'ed - a symbol in Emacs, resolved through the obarray.
      ;; Here an element is either a procedure or the symbol of a line-up
      ;; function (`c-gnu-impose-minimum', from the style's data), which
      ;; `c-lineup-function' resolves.
      (let ((%call (lambda (entry)
                     (cond
                      ((procedure? entry) (entry))
                      ((symbol? entry)
                       (let ((fn (c-lineup-function entry)))
                         (if fn
                             (fn)
                             #f)))
                      (else #f)))))
        (let ((value (c-special-indent-hook)))
          (if (not (pair? value))
              (if (and value (not (eq? value #t)))
                  (%call value)
                  #f)
              (while-e (pair? value)
                       (if (eq? (car value) #t)
                           ;; "t indicates this hook has a local binding;
                           ;; it means to run the global binding too."
                           (let ((global (*c-special-indent-hook*)))
                             (if (pair? global)
                                 (for-each (lambda (entry)
                                             (unless (eq? entry #t)
                                               (%call entry)))
                                           global)
                                 (if (and global (not (eq? global #t)))
                                     (%call global)
                                     #f)))
                           (%call (car value)))
                       (set! value (cdr value)))))))

    ))
