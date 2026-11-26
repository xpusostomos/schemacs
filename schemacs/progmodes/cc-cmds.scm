(define-library (schemacs progmodes cc-cmds)
  ;; `lisp/progmodes/cc-cmds.el' - the editing commands: the indentation
  ;; command layer, the defun movements, the statement/sentence
  ;; movements with the comment-indent and CPP-conditional commands, and
  ;; the filling half (`c-guess-fill-prefix', `c-mask-paragraph',
  ;; `c-fill-paragraph', `c-do-auto-fill',
  ;; `c-indent-new-comment-line', `c-context-line-break' and
  ;; `c-context-open-line'), the electric keys with the `c-hanging-*'
  ;; machinery they drive (`c-point-syntax', `c-brace-newlines',
  ;; `c-try-one-liner', `c-do-brace-electrics'), and
  ;; `c-post-text-conversion'.
  ;;
  ;; **Compile this library at optimization level 1.** Guile 3.0.11's
  ;; optimizer miscompiles `c-append-backslashes-forward' at its default
  ;; level (2): the compiled procedure segfaults in
  ;; `vm_regular_engine' when point is on a string literal's
  ;; backslash-continued line. Levels 0 and 1 are correct; the crash
  ;; needs the `(< col column)' branch of the function's `cond' to be
  ;; compiled into it. The Makefile's rule for this file passes
  ;; `#:optimization-level 1', and a hand compile must too; see
  ;; DEPARTURES.md.'s "c-append-backslashes-forward" section. The bug is
  ;; in Guile and is in this tree before the filling work as well.
  ;;
  ;; Ported, in Emacs's file order: `c-fix-backslashes', `c-indent-line',
  ;; `c-newline-and-indent', `c-show-syntactic-information',
  ;; `c-syntactic-information-on-region', `c-update-modeline', the six
  ;; toggles, `c-indent-command', `c-indent-exp', `c-indent-region',
  ;; `c-fn-region-is-active-p', `c-indent-line-or-region', the
  ;; progress-reporting helpers, the `c-backslash-region' family, and -
  ;; the 2026-11-24 pass - `c-backward-into-nomenclature',
  ;; `c-scope-operator', `c-in-function-trailer-p',
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
  ;; `c-scan-conditionals' and the six conditional commands, and - the
  ;; electric pass - `c-electric-backspace' with the two hungry deletes,
  ;; `c-electric-delete-forward', `c-electric-pound', `c-point-syntax',
  ;; `c-brace-newlines', `c-try-one-liner', `c-do-brace-electrics', the
  ;; eight `c-electric-*' insertion commands and
  ;; `c-electric-continued-statement', and `c-post-text-conversion'.
  ;;
  ;; **Not carried yet**, each with what it waits for:
  ;;
  ;;   * `post-text-conversion-hook' (`keyboard.c''s
  ;;     `Vpost_text_conversion_hook'): `c-post-text-conversion' is
  ;;     carried, but the input machinery that would call it is not;
  ;;   * `electric-indent-mode' does not exist here, so
  ;;     `c-toggle-electric-state''s `(when (fboundp
  ;;     'electric-indent-local-mode) ...)' sync and
  ;;     `c-basic-common-init''s `electric-indent-inhibit' have nothing
  ;;     to call; Emacs older than 24.4 behaves the same way;
  ;;   * Emacs's `(define-obsolete-variable-alias 'c-subword-mode
  ;;     'subword-mode "24.3")' (`cc-cmds.el:1559') has nothing to alias
  ;;     here: this tree has no variable aliases, and the variable is a
  ;;     buffer slot (`subword.scm`'s `subword-mode-variable`), which
  ;;     `subword.el:119`'s function alias is what `c-subword-mode`
  ;;     names. The cond it lives in is dead in Emacs 31 too once
  ;;     subword is loaded.
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
          c-sentence-end c-skip-ws-forward c-skip-ws-backward %c-true
          c-delete-and-extract-region
          c-tentative-buffer-changes c-set-region-active
          c-last-command-char c-lookup-lists c-intersect-lists
          c-get-char-property)
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
          c-block-comment-prefix *c-ignore-auto-fill*
          c-string-par-start c-string-par-separate
          c-sentence-end-with-esc-eol
          *c-syntactic-indentation-in-macros*
          c-cleanup-list c-hanging-braces-alist c-hanging-colons-alist
          c-hanging-semi&comma-criteria)
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
          c-string-limit-regexp c-ws*-string-limit-regexp c-add-syntax
          c-most-enclosing-brace c-on-identifier
          c-beginning-of-current-token c-forward-over-cpp-define-id
          *c-auto-newline-analysis*)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          call-with-buffer-local local-variable-p mode-name set!mode-name
          *case-fold-search*)
    ;; `beginning-of-line' and `end-of-line' are `cmds.c`'s commands.
    (only (schemacs cmds)
          beginning-of-line end-of-line backward-char forward-char
          delete-char self-insert-command *post-self-insert-hook*)
    (only (schemacs command)
          define-command define-alias current-prefix-arg prefix-numeric-value)
    ;; `paren.el`'s blink option and the function a closing paren calls
    ;; (`simple.el`'s block, placed in `paren.scm` - see its header) and
    ;; `elec-pair.el`'s pairing, which the electric commands emulate
    ;; around the self-insert (`cc-cmds.el:911`, `:1288`, `:1373`,
    ;; `:1420`).
    ;; `c-backward-into-nomenclature' forwards to `subword.el`'s
    ;; `subword-backward' (`cc-cmds.el:1569'), and `c-update-modeline`'s
    ;; `w' flag reads the `c-subword-mode' *variable*, which is
    ;; `subword-mode`'s - the alias `c-subword-mode` is `subword.el`'s
    ;; (`:119') and this library's cond below only carries Emacs's
    ;; fallback as a comment. Emacs autoloads subword; a library here is
    ;; reachable only by importing it.
    (only (schemacs progmodes subword)
          subword-backward subword-mode-variable)
    ;; `make-obsolete` marks `c-backward-into-nomenclature`, as
    ;; `cc-cmds.el:1580` does.
    (only (schemacs core byte-run) make-obsolete)
    (only (schemacs paren) *blink-paren-function*)
    (only (schemacs elec-pair)
          electric-pair-mode-value electric-pair-post-self-insert-function)
    (only (schemacs dispnew) executing-kbd-macro)
    (only (schemacs editfns)
          bobp bolp eobp eolp char-before char-after point point-min
          point-max point-marker goto-char
          forward-line insert insert-char insert-and-inherit
          delete-region save-excursion message format
          line-beginning-position widen region-beginning region-end
          buffer-substring-no-properties buffer-size
          ;; `narrow-to-region' and `save-restriction' are `editfns.c`'s
          ;; here (`buffer.scm` is below them).
          narrow-to-region save-restriction)
    (only (schemacs indentc)
          current-column current-indentation indent-to move-to-column)
    (only (schemacs character) *tab-width*)
    (only (schemacs indent)
          indent-according-to-mode *fill-prefix*)
    (only (schemacs simple)
          delete-horizontal-space insert-newline back-to-indentation
          push-mark exchange-point-and-mark kill-new count-lines
          *this-command* *last-command*
          backward-delete-char-untabify use-region-p)
    (only (schemacs core lisp-mode) indent-code-rigidly)
    (only (schemacs core lisp) forward-sexp backward-sexp down-list
          forward-list up-list *beginning-of-defun-function*
          *end-of-defun-function* with-defun-functions-nil)
    (only (schemacs textmodes paragraphs)
          forward-paragraph backward-paragraph paragraph-start paragraph-separate
          *sentence-end-double-space*)
    (only (schemacs textmodes fill)
          fill-paragraph fill-context-prefix do-auto-fill
          fill-paragraph-function)
    (only (schemacs intervals) put)
    (only (schemacs marker)
          make-marker set-marker copy-marker markerp marker-position
          set-marker-insertion-type)
    (only (schemacs newcomment)
          comment-start comment-end set!comment-start set!comment-end
          comment-start-skip indent-for-comment comment-column
          comment-multi-line)
    (only (schemacs search) looking-at match-end match-beginning match-string
          match-string-no-properties string-match save-match-data
          re-search-backward re-search-forward regexp-quote)
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
   c-electric-backspace c-hungry-delete-backwards c-hungry-backspace
   c-electric-delete-forward c-hungry-delete-forward
   c-electric-pound c-point-syntax c-brace-newlines c-try-one-liner
   c-do-brace-electrics c-electric-brace c-electric-slash
   c-electric-star c-electric-semi&comma c-electric-colon
   c-electric-lt-gt c-electric-paren c-electric-continued-statement
   c-post-text-conversion
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
   c-run-special-indent-hook
   *c-auto-fill-prefix* *c-lit-limits* *c-lit-type* c-guess-fill-prefix
   c-mask-paragraph
   c-fill-paragraph c-do-auto-fill c-indent-new-comment-line
   c-comment-line-break-function c-context-line-break c-context-open-line)

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
                          ;; `(cc-)subword` might not be loaded -
                          ;; here `subword.scm` always is (this library
                          ;; imports it), and `c-subword-mode` is its
                          ;; alias, so the variable is `subword-mode`'s
                          ;; slot (`cc-cmds.el:271`).
                          (if (subword-mode-variable) "w" "")))
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

    (define (%c-last-command-char=? char)
      ;; Emacs's `(eq (c-last-command-char) ?X)'. A key event is an
      ;; integer - its byte code (`keyboard.c:8301') - and Emacs's `?X'
      ;; names that integer; Guile's `#\X' is a character object, so the
      ;; conversion has to be spelled out. This is the same seam as the
      ;; two helpers above.
      (eqv? (c-last-command-char) (char->integer char)))

    ;; ---------------------------------------------------------------
    ;; Electric keys (`cc-cmds.el:409'-`:1568'')
    ;;
    ;; The commands below insert a character and then do the "electric"
    ;; actions: reindent, auto-newline, and the clean-ups configured in
    ;; `c-cleanup-list'. Emacs's `self-insert-command' call is spelled
    ;; with the event passed explicitly (this tree's command takes
    ;; `(count char)', `cmds.c:263'), and the `let' that disables
    ;; `post-self-insert-hook' is a `parameterize' of
    ;; `*post-self-insert-hook*' (`cmds.c:524').
    ;;
    ;; **The `electric-pair-mode' and blink blocks are carried**, now
    ;; that their primitives are: `elec-pair.scm` provides the mode and
    ;; `electric-pair-post-self-insert-function`, and `paren.scm`
    ;; provides `*blink-paren-function*` (a parameter, because these
    ;; commands `let`-bind it) and `blink-matching-open`. Emacs's
    ;; `(boundp 'electric-pair-mode)` guard is the mode's value here,
    ;; the library being imported.
    ;;
    ;; **Not carried, each with what it waits for**:
    ;;
    ;;   * `c-electric-delete' and `c-hungry-delete' (`:469', `:486'):
    ;;     they are for XEmacs's `delete-forward-p' and are not bound on
    ;;     GNU Emacs.
    ;;   * `c-align-cpp-indent-to-body', `c-electric-pragma', the
    ;;     abbreviation-table helpers and `c-toggle-cpp-indent-to-body'
    ;;     (`:1457'-`:1547'): they need `abbrev.el' (`define-abbrev',
    ;;     `abbrev-symbol', `mapatoms', `local-abbrev-table',
    ;;     `last-abbrev-location'), which is not ported.
    ;;--------------------------------------------------------------

    (define-command (c-electric-backspace arg)
      "Delete the preceding character or whitespace.
If `c-hungry-delete-key' is non-nil (indicated by \"/h\" on the mode
line) then all preceding whitespace is consumed.  If however a prefix
argument is supplied, or `c-hungry-delete-key' is nil, or point is
inside a literal then the function in the variable
`c-backspace-function' is called."
      (interactive "*P")
      (c-with-string-fences
       (if (c-save-buffer-state ()
             (or (not (c-hungry-delete-key))
                 arg
                 (c-in-literal)))
           ((*c-backspace-function*) (prefix-numeric-value arg))
           (c-hungry-delete-backwards))))

    (define-command (c-hungry-delete-backwards)
      "Delete the preceding character or all preceding whitespace
back to the previous non-whitespace character.
See also \\[c-hungry-delete-forward]."
      (interactive)
      (c-with-string-fences
       (let ((here (point)))
         (c-skip-ws-backward)
         (if (/= (point) here)
             (delete-region (point) here)
             ((*c-backspace-function*) 1)))))

    (define-alias c-hungry-backspace c-hungry-delete-backwards)

    (define-command (c-electric-delete-forward arg)
      "Delete the following character or whitespace.
If `c-hungry-delete-key' is non-nil (indicated by \"/h\" on the mode
line) then all following whitespace is consumed.  If however a prefix
argument is supplied, or `c-hungry-delete-key' is nil, or point is
inside a literal then the function in the variable `c-delete-function'
is called."
      (interactive "*P")
      (c-with-string-fences
       (if (c-save-buffer-state ()
             (or (not (c-hungry-delete-key))
                 arg
                 (c-in-literal)))
           ((*c-delete-function*) (prefix-numeric-value arg))
           (c-hungry-delete-forward))))

    (define-command (c-hungry-delete-forward)
      "Delete the following character or all following whitespace
up to the next non-whitespace character.
See also \\[c-hungry-delete-backwards]."
      (interactive)
      (c-with-string-fences
       (let ((here (point)))
         (c-skip-ws-forward)
         (if (/= (point) here)
             (delete-region (point) here)
             ((*c-delete-function*) 1)))))

    ;; `c--unsafe-post-self-insert-hook-functions' (`cc-cmds.el:502')
    (define c--unsafe-post-self-insert-hook-functions
      '(electric-pair-post-self-insert-function))

    (define (c--call-post-self-insert-hook-more-safely-1)
      ;; Call post-self-insert-hook, having removed the functions known
      ;; not to be safe in CC Mode (`cc-cmds.el:506'). Emacs's `t'
      ;; element means "run the global value too"; this tree's hook is
      ;; one parameter, not a buffer-local with a global value, so there
      ;; is no second list to walk and no `t' can be in it - a named
      ;; departure.
      (let ((src (*post-self-insert-hook*))
            (dest '()))
        (let loop ()
          (when (pair? src)
            (cond
             ((memq (car src) c--unsafe-post-self-insert-hook-functions))
             (else (set! dest (cons (car src) dest))))
            (set! src (cdr src))
            (loop)))
        (for-each (lambda (f) (f)) (reverse dest))))

    (define-syntax c--call-post-self-insert-hook-more-safely
      ;; `cc-cmds.el:525': run the hook outside of
      ;; `c-with-string-fences'.
      (syntax-rules ()
        ((_) (c--call-post-self-insert-hook-more-safely-1))))

    (define-command (c-electric-pound arg)
      "Insert a \"#\".
If `c-electric-flag' is set, handle it specially according to the variable
`c-electric-pound-behavior'.  If a numeric ARG is supplied, or if point is
inside a literal or a macro, nothing special happens."
      (interactive "*P")
      (c-with-string-fences
       (if (c-save-buffer-state ()
             (or arg
                 (not (c-electric-flag))
                 (not (memq 'alignleft (or (*c-electric-pound-behavior*) '())))
                 (save-excursion
                   (skip-chars-backward " \t")
                   (not (bolp)))
                 (save-excursion
                   (and (= (forward-line -1) 0)
                        (begin
                          (end-of-line)
                          (%c-char-before=? #\\))))
                 (c-in-literal)))
           ;; do nothing special
           (parameterize ((*post-self-insert-hook* '())) ; Disable random functionality.
             (self-insert-command (prefix-numeric-value arg)
                                  (c-last-command-char)))
           ;; place the pound character at the left edge
           (let ((pos (- (point-max) (point)))
                 (was-bolp (bolp)))
             (beginning-of-line)
             (delete-horizontal-space)
             (insert (integer->char (c-last-command-char)))
             (and (not was-bolp)
                  (goto-char (- (point-max) pos))))))
      (c--call-post-self-insert-hook-more-safely))

    (define (c-point-syntax)
      ;; Return the syntactic context of the construct at point. (This
      ;; is NOT nec. the same as the s.c. of the line point is on.)
      ;; N.B. This won't work between the `#' of a cpp thing and what
      ;; follows (see c-opt-cpp-prefix). (`cc-cmds.el:565')
      (parameterize ((*c-echo-syntactic-information-p* #f))
        (c-save-buffer-state ((syntax #f))
          (set! syntax #f)
          (c-tentative-buffer-changes
           ;; insert a newline to isolate the construct at point for
           ;; syntactic analysis.
           (insert-char #\newline 1)
           ;; In AWK (etc.) or in a macro, make sure this CR hasn't
           ;; changed the syntax. (There might already be an escaped NL
           ;; there.)
           (when (or
                  (save-excursion
                    (c-skip-ws-backward (c-point 'bopl))
                    (c-at-vsemi-p))
                  (let ((pt (point)))
                    (save-excursion
                      (backward-char)
                      (and (c-beginning-of-macro)
                           (begin
                             (c-end-of-macro)
                             (< (point) pt))))))
             (backward-char)
             (insert-char #\\ 1)
             (forward-char))
           (parameterize ((*c-syntactic-indentation-in-macros* #t)
                          (*c-auto-newline-analysis* #t))
             ;; Turn on syntactic macro analysis to help with auto
             ;; newlines only.
             (set! syntax (c-guess-basic-syntax))
             #f))
          syntax)))

    (define (c-brace-newlines syntax)
      ;; A brace stands at point. SYNTAX is the syntactic context of
      ;; this brace (not necessarily the same as the S.C. of the line it
      ;; is on). Return NEWLINES, the list containing some combination
      ;; of the symbols `before' and `after' saying where newlines
      ;; should be inserted. (`cc-cmds.el:599')
      (parameterize ((*c-echo-syntactic-information-p* #f))
        (c-save-buffer-state ((symb-newlines #f))
          (set! symb-newlines #f)
          (let ((syms
                 ;; This is the list of brace syntactic symbols that can
                 ;; hang. If any new ones are added to c-offsets-alist,
                 ;; they should be added here as well.
                 ;;
                 ;; The order of this list is important; if SYNTAX has
                 ;; several elements, the element that "wins" is the
                 ;; earliest in SYMS.
                 '(arglist-cont-nonempty      ; e.g. an array literal.
                   class-open class-close defun-open defun-close
                   inline-open inline-close
                   brace-list-open brace-list-close
                   brace-list-intro brace-entry-open
                   block-open block-close
                   substatement-open statement-case-open
                   extern-lang-open extern-lang-close
                   namespace-open namespace-close
                   module-open module-close
                   composition-open composition-close
                   inexpr-class-open inexpr-class-close
                   ;; `statement-cont' is here for the case with a brace
                   ;; list opener inside a statement. C.f. CASE B.2 in
                   ;; `c-guess-continued-construct'.
                   statement-cont)))
            (set! symb-newlines
                  ;; Do not try to insert newlines around a special
                  ;; (Pike-style) brace list.
                  (if (and (%c-true (%c-langvar 'c-special-brace-lists))
                           (save-excursion
                             (c-safe (if (%c-char-before=? #\{)
                                         (forward-char -1)
                                         (c-forward-sexp -1))
                                     (c-looking-at-special-brace-list))))
                      #f
                      ;; Seek the matching entry in
                      ;; c-hanging-braces-alist.
                      (or (c-lookup-lists
                           syms
                           ;; Substitute inexpr-class and class-open or
                           ;; class-close with inexpr-class-open or
                           ;; inexpr-class-close.
                           (if (assq 'inexpr-class syntax)
                               (cond ((assq 'class-open syntax)
                                      '((inexpr-class-open)))
                                     ((assq 'class-close syntax)
                                      '((inexpr-class-close)))
                                     (else syntax))
                               syntax)
                           (c-hanging-braces-alist))
                          '(ignore before after)))) ; Default, when not in c-h-b-l.

            ;; If syntax is a function symbol, then call it using the
            ;; defined semantics.
            (let ((value (cdr symb-newlines)))
              (let ((fn (if (symbol? value) (c-lineup-function value) value)))
                (if (and (not (pair? value)) (procedure? fn))
                    (parameterize ((*c-syntactic-context* syntax))
                      (fn (car symb-newlines) (point)))
                    value)))))))

    (define %c-one-liner-re
      ;; `c-try-one-liner''s `(cc-eval-when-compile (concat ...))'
      ;; (`cc-cmds.el:696'): a compile-time constant, computed at load.
      (concat
       "\\("                             ; (match-beginning 1)
       "[ \t]*\\([\r\n][ \t]*\\)?"       ; WS with opt. NL
       "\\)"                             ; (match-end 1)
       "[^ \t\r\n]+\\([ \t]+[^ \t\r\n]+\\)*" ; non-WS
       "\\("                             ; (match-beginning 4)
       "[ \t]*\\([\r\n][ \t]*\\)?"       ; WS with opt. NL
       "\\)\\'"))                        ; (match-end 4) at EOB.

    (define (c-try-one-liner)
      ;; Point is just after a newly inserted }. If the non-whitespace
      ;; content of the braces is a single line of code, compact the
      ;; whole construct to a single line, if this line isn't too long.
      ;; The Right Thing is done with comments.
      ;;
      ;; Point will be left after the }, regardless of whether the
      ;; clean-up is done. Return NON-NIL if the clean-up happened, NIL
      ;; if it didn't. (`cc-cmds.el:668')
      (let ((here (point))
            (pos (- (point-max) (point)))
            (mbeg1 #f) (mend1 #f) (mbeg4 #f) (mend4 #f)
            (eol-col #f) (cmnt-pos #f) (cmnt-col #f) (cmnt-gap #f))

        (when
            (save-excursion
              (save-restriction
                ;; Avoid backtracking over a very large block. The one
                ;; we deal with here can never be more than three lines.
                (narrow-to-region (save-excursion
                                    (forward-line -2)
                                    (point))
                                  (point))
                (and (c-safe (c-backward-sexp))
                     (begin
                       (forward-char)
                       (narrow-to-region (point) (- here 1)) ; innards of {.}
                       (looking-at %c-one-liner-re)))))

          (when (c-tentative-buffer-changes
                 (setq mbeg1 (match-beginning 1) mend1 (match-end 1)
                       mbeg4 (match-beginning 4) mend4 (match-end 4))
                 (backward-char)                ; back over the `}'
                 (save-excursion
                   (set! cmnt-pos (and (c-backward-single-comment)
                                       (- (point) (- mend1 mbeg1)))))
                 (delete-region mbeg4 mend4)
                 (delete-region mbeg1 mend1)
                 (set! eol-col (save-excursion (end-of-line) (current-column)))

                 ;; Necessary to put the closing brace before any line
                 ;; oriented comment to keep it syntactically
                 ;; significant. This isn't necessary for block
                 ;; comments, but the result looks nicer anyway.
                 (when cmnt-pos
                   (delete-char 1)      ; the `}' has blundered into a comment
                   (goto-char cmnt-pos)
                   (set! cmnt-col (+ 1 (current-column)))
                   (set! cmnt-pos (+ 1 cmnt-pos)) ; we're inserting a `}'
                   (c-skip-ws-backward)
                   (insert-char #\} 1)  ; reinsert the `}' before the comment.
                   (set! cmnt-gap (- cmnt-col (current-column)))
                   (when (= cmnt-gap 0)
                     (insert-char #\space 1) ; Put a space before a bare comment.
                     (set! cmnt-gap 1)))

                 (or (eq? (*c-max-one-liner-length*) #f)
                     (= (*c-max-one-liner-length*) 0)
                     (<= eol-col (*c-max-one-liner-length*))
                     ;; Can we trim space before comment to make the
                     ;; line fit?
                     (and cmnt-gap
                          (< (- eol-col cmnt-gap) (*c-max-one-liner-length*))
                          (begin
                            (goto-char cmnt-pos)
                            (backward-delete-char-untabify
                             (- eol-col (*c-max-one-liner-length*)))
                            #t))))
            (goto-char (- (point-max) pos))))))

    (define (c-do-brace-electrics before after)
      ;; Point is just after a brace. Indent the various lines, add any
      ;; required auto newlines, and apply pertinent clean ups. It is
      ;; assumed that the caller has checked that point is at EOL if need
      ;; be, and that the brace is not in a comment or string, and
      ;; suchlike. (`cc-cmds.el:745')
      ;;
      ;; BEFORE and AFTER qualify the newlines required before and after
      ;; the brace as follows: nil - insert a newline or not according to
      ;; `c-hanging-braces-alist'; 'ignore - don't insert a newline;
      ;; 'assume - insert a newline.
      (let ((newlines #f)
            (ln-syntax #f) (br-syntax #f) (syntax #f))
                                        ; Syntactic context of the original line,
                                        ; of the brace itself, of the line the
                                        ; brace ends up on.
        (c-save-buffer-state ()
          (parameterize ((*c-syntactic-indentation-in-macros* #t)
                         (*c-auto-newline-analysis* #t))
            (set! ln-syntax (c-guess-basic-syntax))))
        (if (c-syntactic-indentation)
            (c-indent-line ln-syntax))

        (when (c-auto-newline)
          (backward-char)
          (set! br-syntax (c-point-syntax))
          (set! newlines (c-brace-newlines br-syntax))

          ;; Insert the BEFORE newline, if wanted, and reindent the
          ;; newline.
          (if (or (and (not before) (memq 'before (or newlines '()))
                       (> (current-column) (current-indentation)))
                  (eq? before 'assume))
              (if (c-syntactic-indentation)
                  ;; Only a plain newline for now - it's indented after
                  ;; the cleanups when the line has its final
                  ;; appearance.
                  (insert-newline)
                  (c-newline-and-indent)))
          (forward-char)

          ;; `syntax' is the syntactic context of the line which ends up
          ;; with the brace on it.
          (set! syntax (if (memq 'before (or newlines '())) br-syntax ln-syntax))

          ;; Do all appropriate clean ups
          (let ((here (point))
                (pos (- (point-max) (point)))
                (mbeg #f) (mend #f))

            ;; `}': clean up empty defun braces
            (when (c-save-buffer-state ()
                    (and (memq 'empty-defun-braces (or (c-cleanup-list) '()))
                         (%c-last-command-char=? #\})
                         (c-intersect-lists '(defun-close class-close inline-close) syntax)
                         (begin
                           (forward-char -1)
                           (c-skip-ws-backward)
                           (%c-char-before=? #\{))
                         ;; make sure matching open brace isn't in a comment
                         (not (c-in-literal))))
              (delete-region (point) (- here 1))
              (set! here (- (point-max) pos)))
            (goto-char here)

            ;; `}': compact to a one-liner defun?
            (save-match-data
              (when
                  (and (%c-last-command-char=? #\})
                       (memq 'one-liner-defun (or (c-cleanup-list) '()))
                       (c-intersect-lists '(defun-close) syntax)
                       (c-try-one-liner))
                (set! here (- (point-max) pos))))

            ;; `{': clean up brace-else-brace and brace-elseif-brace
            (when (%c-last-command-char=? #\{)
              (cond
               ((and (memq 'brace-else-brace (or (c-cleanup-list) '()))
                     (re-search-backward
                      (concat "}"
                              "\\([ \t\n]\\|\\\\\n\\)*"
                              "else"
                              "\\([ \t\n]\\|\\\\\n\\)*"
                              "{"
                              "\\=")
                      #f #t))
                (delete-region (match-beginning 0) (match-end 0))
                (insert-and-inherit "} else {"))
               ((and (memq 'brace-elseif-brace (or (c-cleanup-list) '()))
                     (begin
                       (goto-char (- here 1))
                       (set! mend (point))
                       (c-skip-ws-backward)
                       (set! mbeg (point))
                       (%c-char-before=? #\)))
                     (= 0 (c-save-buffer-state () (c-backward-token-2 1 #t)))
                     (%c-char-after=? #\()
                     (re-search-backward
                      (concat "}"
                              "\\([ \t\n]\\|\\\\\n\\)*"
                              "else"
                              "\\([ \t\n]\\|\\\\\n\\)+"
                              "if"
                              "\\([ \t\n]\\|\\\\\n\\)*"
                              "\\=")
                      #f #t))
                (delete-region mbeg mend)
                (goto-char mbeg)
                (insert #\space))))

            (goto-char (- (point-max) pos))

            ;; Indent the line after the cleanups since it might very
            ;; well indent differently due to them, e.g. if
            ;; c-indent-one-line-block is used together with the
            ;; one-liner-defun cleanup.
            (when (c-syntactic-indentation)
              (c-indent-line)))

          ;; does a newline go after the brace?
          (if (or (and (not after) (memq 'after (or newlines '())))
                  (eq? after 'assume))
              (c-newline-and-indent)))))

    (define-command (c-electric-brace arg)
      "Insert a brace.

If `c-electric-flag' is non-nil, the brace is not inside a literal and a
numeric ARG hasn't been supplied, the command performs several electric
actions:

\(a) If the auto-newline feature is turned on (indicated by \"/la\" on
the mode line) newlines are inserted before and after the brace as
directed by the settings in `c-hanging-braces-alist'.

\(b) Any auto-newlines are indented.  The original line is also
reindented unless `c-syntactic-indentation' is nil.

\(c) If auto-newline is turned on, various newline cleanups based on the
settings of `c-cleanup-list' are done."
      (interactive "*P")
      (parameterize ((*case-fold-search* #f))
        (let* ((old-blink-paren (*blink-paren-function*))
               (safepos #f) (literal #f)
               (at-eol (looking-at "[ \t]*\\\\?$"))
               (active-region (use-region-p))
               (got-pair-} #f)
               (electric-pair-deletion #f))
          ;; We want to inhibit blinking the paren since this would be
          ;; most disruptive. We'll blink it ourselves later on.
          (parameterize ((*blink-paren-function* #f))
            (c-with-string-fences
             (c-save-buffer-state ()
               (set! safepos (c-safe-position (point) (c-parse-state)))
               (set! literal (c-in-literal safepos)))

             ;; Insert the brace. Note that expand-abbrev might reindent
             ;; the line here if there's a preceding "else" or something.
             (parameterize ((*post-self-insert-hook* '()))
               ;; the only way to get defined functionality from
               ;; `self-insert-command'.
               (self-insert-command (prefix-numeric-value arg)
                                    (c-last-command-char))))

            ;; Emulate `electric-pair-mode', outside of
            ;; `c-with-string-fences'.
            (when (electric-pair-mode-value)
              (let ((size (buffer-size)))
                (parameterize ((*post-self-insert-hook* '()))
                  (electric-pair-post-self-insert-function))
                (set! got-pair-}
                      (and at-eol
                           (%c-last-command-char=? #\{)
                           (let ((c (char-after)))
                             (and c (char=? c #\})))))
                (set! electric-pair-deletion (< (buffer-size) size))))

            (c-with-string-fences
             ;; Perform any required CC Mode electric actions.
             (cond
              ((or literal arg (not (c-electric-flag)) active-region) #f)
              ((not at-eol)
               (c-indent-line))
              (electric-pair-deletion
               (c-indent-line)
               (c-do-brace-electrics 'ignore #f))
              (else
               (c-do-brace-electrics #f #f)
               (when got-pair-}
                 (save-excursion
                   (forward-char)
                   (c-do-brace-electrics 'assume 'ignore))
                 (c-indent-line))))

             ;; blink the paren
             (and (%c-last-command-char=? #\})
                  (not executing-kbd-macro)
                  old-blink-paren
                  (save-excursion
                    (c-save-buffer-state ()
                      (c-backward-syntactic-ws safepos))
                    (old-blink-paren)))))))
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-slash arg)
      "Insert a slash character.

If the slash is inserted immediately after the comment prefix in a c-style
comment, the comment might get closed by removing whitespace and possibly
inserting a \"*\".  See the variable `c-cleanup-list'.

Indent the line as a comment, if:

  1. The slash is second of a \"//\" line oriented comment introducing
     token and we are on a comment-only-line, or

  2. The slash is part of a \"*/\" token that closes a block oriented
     comment.

If a numeric ARG is supplied, point is inside a literal, or
`c-syntactic-indentation' is nil or `c-electric-flag' is nil, indentation
is inhibited."
      (interactive "*P")
      (parameterize ((*c-echo-syntactic-information-p* #f))
        (c-with-string-fences
         (let ((literal (c-save-buffer-state () (c-in-literal)))
               (indentp #f))

           ;; comment-close-slash cleanup? This DOESN'T need
           ;; `c-electric-flag' or `c-syntactic-indentation' set.
           (when (and (not arg)
                      (eq? literal 'c)
                      (memq 'comment-close-slash (or (c-cleanup-list) '()))
                      (%c-last-command-char=? #\/)
                      (looking-at (concat "[ \t]*\\("
                                          (regexp-quote (comment-end)) "\\)?$"))
                                        ; (eq c-block-comment-ender "*/") ; C-style comments ALWAYS end in */
                      (save-excursion
                        (save-restriction
                          (narrow-to-region (point-min) (point))
                          (back-to-indentation)
                          (looking-at (concat (c-current-comment-prefix)
                                              "[ \t]*$")))))
             (delete-region (begin (forward-line 0) (point))
                            (begin (end-of-line) (point)))
             (insert-char #\* 1)) ; the / comes later.

           (set! indentp (and (not arg)
                              (c-syntactic-indentation)
                              (c-electric-flag)
                              (%c-last-command-char=? #\/)
                              (eqv? (char-before) (if literal #\* #\/))))
           (parameterize ((*post-self-insert-hook* '()))
             ;; Disable random functionality.
             (self-insert-command (prefix-numeric-value arg)
                                  (c-last-command-char)))
           (if indentp
               (indent-according-to-mode)))))
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-star arg)
      "Insert a star character.
If `c-electric-flag' and `c-syntactic-indentation' are both non-nil, and
the star is the second character of a C style comment starter on a
comment-only-line, indent the line as a comment.  If a numeric ARG is
supplied, point is inside a literal, or `c-syntactic-indentation' is nil,
this indentation is inhibited."
      (interactive "*P")
      (c-with-string-fences
       (parameterize ((*post-self-insert-hook* '()))
         ;; Disable random functionality.
         (self-insert-command (prefix-numeric-value arg)
                              (c-last-command-char)))
       ;; if we are in a literal, or if arg is given do not reindent the
       ;; current line, unless this star introduces a comment-only line.
       (if (c-save-buffer-state ()
             (and (c-syntactic-indentation)
                  (c-electric-flag)
                  (not arg)
                  (eq? (c-in-literal) 'c)
                  (%c-char-before=? #\*)
                  (save-excursion
                    (forward-char -1)
                    (skip-chars-backward "*")
                    (if (%c-char-before=? #\/)
                        (forward-char -1))
                    (skip-chars-backward " \t")
                    (bolp))))
           (parameterize ((*c-echo-syntactic-information-p* #f))
             (indent-according-to-mode))))
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-semi&comma arg)
      "Insert a comma or semicolon.

If `c-electric-flag' is non-nil, point isn't inside a literal and a
numeric ARG hasn't been supplied, the command performs several electric
actions:

\(a) When the auto-newline feature is turned on (indicated by \"/la\" on
the mode line) a newline might be inserted.  See the variable
`c-hanging-semi&comma-criteria' for how newline insertion is determined.

\(b) Any auto-newlines are indented.  The original line is also
reindented unless `c-syntactic-indentation' is nil.

\(c) If auto-newline is turned on, a comma following a brace list or a
semicolon following a defun might be cleaned up, depending on the
settings of `c-cleanup-list'."
      (interactive "*P")
      (parameterize ((*c-echo-syntactic-information-p* #f)
                     (*c-syntactic-context* #f))
        (c-with-string-fences
         (let ((lim #f) (literal #f) (syntax #f)
               (here (point)))

           (c-save-buffer-state ()
             (set! lim (c-most-enclosing-brace (c-parse-state)))
             (set! literal (c-in-literal lim)))

           (parameterize ((*post-self-insert-hook* '()))
             ;; Disable random functionality.
             (self-insert-command (prefix-numeric-value arg)
                                  (c-last-command-char)))

           (if (and (c-electric-flag) (not literal) (not arg))
               ;; do all cleanups and newline insertions if
               ;; c-auto-newline is on.
               (if (or (not (c-auto-newline))
                       (not (looking-at "[ \t]*\\\\?$")))
                   (if (c-syntactic-indentation)
                       (c-indent-line))
                   ;; clean ups: list-close-comma or defun-close-semi
                   (let ((pos (- (point-max) (point))))
                     (if (c-save-buffer-state ()
                           (and (or (and
                                     (%c-last-command-char=? #\,)
                                     (memq 'list-close-comma (or (c-cleanup-list) '())))
                                    (and
                                     (%c-last-command-char=? #\;)
                                     (memq 'defun-close-semi (or (c-cleanup-list) '()))))
                                (begin
                                  (forward-char -1)
                                  (c-skip-ws-backward)
                                  (%c-char-before=? #\}))
                                ;; make sure matching open brace isn't in a comment
                                (not (c-in-literal lim))))
                         (delete-region (point) here))
                     (goto-char (- (point-max) pos))
                     ;; reindent line
                     (when (c-syntactic-indentation)
                       (set! syntax (c-guess-basic-syntax))
                       (c-indent-line syntax))
                     ;; check to see if a newline should be added
                     (let ((criteria (c-hanging-semi&comma-criteria))
                           (answer #f) (add-newline-p #f))
                       (while-e (pair? criteria)
                         (let ((entry (car criteria)))
                           (set! answer
                                 (let ((fn (if (symbol? entry)
                                               (c-lineup-function entry)
                                               entry)))
                                   (if (procedure? fn) (fn) #f)))
                           (if (not answer)
                               (set! criteria (cdr criteria))
                               (begin
                                 (set! criteria #f)
                                 ;; only 'stop specifically says do not
                                 ;; add a newline
                                 (set! add-newline-p (not (eq? answer 'stop)))))))
                       (if add-newline-p
                           (c-newline-and-indent)))))))))
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-colon arg)
      "Insert a colon.

If `c-electric-flag' is non-nil, the colon is not inside a literal and a
numeric ARG hasn't been supplied, the command performs several electric
actions:

\(a) If the auto-newline feature is turned on (indicated by \"/la\" on
the mode line) newlines are inserted before and after the colon based on
the settings in `c-hanging-colons-alist'.

\(b) Any auto-newlines are indented.  The original line is also
reindented unless `c-syntactic-indentation' is nil.

\(c) If auto-newline is turned on, whitespace between two colons will be
\"cleaned up\" leaving a scope operator, if this action is set in
`c-cleanup-list'."
      (interactive "*P")
      (parameterize ((*c-echo-syntactic-information-p* #f))
        (c-with-string-fences
         (let* ((bod (c-point 'bod))
                (literal (c-save-buffer-state () (c-in-literal bod)))
                (newlines #f) (is-scope-op #f))

           (parameterize ((*post-self-insert-hook* '()))
             ;; Disable random functionality.
             (self-insert-command (prefix-numeric-value arg)
                                  (c-last-command-char)))
           ;; Any electric action?
           (when (and (c-electric-flag) (not literal) (not arg))
             ;; Unless we're at EOL, only re-indentation happens.
             (if (not (looking-at "[ \t]*\\\\?$"))
                 (if (c-syntactic-indentation)
                     (indent-according-to-mode))
                 (begin
                   ;; scope-operator clean-up?
                   (let ((pos (- (point-max) (point)))
                         (here (point)))
                     (if (c-save-buffer-state ()
                           (and (c-auto-newline)
                                (memq 'scope-operator (or (c-cleanup-list) '()))
                                (%c-char-before=? #\:)
                                (begin
                                  (forward-char -1)
                                  (c-skip-ws-backward)
                                  (%c-char-before=? #\:))
                                (not (c-in-literal))
                                (not (eqv? (char-after (- (point) 2)) #\:))))
                         (begin
                           (delete-region (point) (- here 1))
                           (set! is-scope-op #t)))
                     (goto-char (- (point-max) pos)))

                   ;; indent the current line if it's done syntactically.
                   (if (c-syntactic-indentation)
                       ;; Cannot use the same syntax analysis as we find
                       ;; below, since that's made with
                       ;; c-syntactic-indentation-in-macros always set
                       ;; to t.
                       (indent-according-to-mode))

                   ;; Calculate where, if anywhere, we want newlines.
                   (c-save-buffer-state ()
                     (parameterize ((*c-syntactic-indentation-in-macros* #t)
                                    (*c-auto-newline-analysis* #t))
                       (let ((syntax (c-guess-basic-syntax))
                             (elem #f))
                         ;; Turn on syntactic macro analysis to help with
                         ;; auto newlines only.
                         (set! elem syntax)
                         ;; Translate substatement-label to label for
                         ;; this operation.
                         (while-e (pair? elem)
                           (if (eq? (car (car elem)) 'substatement-label)
                               (set-car! (car elem) 'label))
                           (set! elem (cdr elem)))
                         ;; some language elements can only be
                         ;; determined by checking the following line.
                         ;; Let's first look for ones that can be found
                         ;; when looking on the line with the colon
                         (set! newlines
                               (and (c-auto-newline)
                                    (or (c-lookup-lists '(case-label label access-label)
                                                        syntax (c-hanging-colons-alist))
                                        (c-lookup-lists
                                         '(member-init-intro inher-intro)
                                         (begin
                                           (insert #\newline)
                                           (dynamic-wind
                                             (lambda () #f)
                                             (lambda () (c-guess-basic-syntax))
                                             (lambda () (delete-char -1))))
                                         (c-hanging-colons-alist))))))))
                   ;; does a newline go before the colon? Watch out for
                   ;; already non-hung colons. However, we don't unhang
                   ;; them because that would be a cleanup (and
                   ;; anti-social).
                   (if (and (pair? newlines) (memq 'before newlines)
                            (not is-scope-op)
                            (save-excursion
                              (skip-chars-backward ": \t")
                              (not (bolp))))
                       (let ((pos (- (point-max) (point))))
                         (forward-char -1)
                         (c-newline-and-indent)
                         (goto-char (- (point-max) pos))))
                   ;; does a newline go after the colon?
                   (if (and (pair? (cdr-safe newlines))
                            (memq 'after (cdr-safe newlines))
                            (not is-scope-op))
                       (c-newline-and-indent))))))))
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-lt-gt arg)
      "Insert a \"<\" or \">\" character.
If the current language uses angle bracket parens (e.g. template
arguments in C++), try to find out if the inserted character is a
paren and give it paren syntax if appropriate.

If `c-electric-flag' and `c-syntactic-indentation' are both non-nil, the
line will be reindented if the inserted character is a paren or if it
finishes a C++ style stream operator in C++ mode.  Exceptions are when a
numeric argument is supplied, or the point is inside a literal."
      (interactive "*P")
      (parameterize ((*c-echo-syntactic-information-p* #f)
                     (*case-fold-search* #f))
        (let ((template-delim #f) (include-delim #f)
              (final-pos #f) (found-delim #f))
          (c-with-string-fences
           (parameterize ((*post-self-insert-hook* '()))
             ;; Disable random functionality.
             (self-insert-command (prefix-numeric-value arg)
                                  (c-last-command-char)))
           (set! final-pos (point))

           ;; 2010-01-31: There used to be code here to put a
           ;; syntax-table text property on the new < or > and its mate
           ;; (if any) when they are template parens. This is now done
           ;; in an after-change function.

           (when (and (not arg)
                      (not (c-save-buffer-state () (c-in-literal))))
             ;; Have we got a delimiter on a #include directive?
             (beginning-of-line)
             (set! include-delim
                   (and
                    (looking-at (%c-langvar 'c-cpp-include-key))
                    (if (%c-last-command-char=? #\<)
                        (eq? (match-end 0) (- final-pos 1))
                        (begin
                          (goto-char (- final-pos 1))
                          (skip-chars-backward "^<>" (c-point 'bol))
                          (%c-char-before=? #\<)))))
             (goto-char final-pos)

             ;; Indent the line if appropriate.
             (when (and (c-electric-flag) (c-syntactic-indentation)
                        (%c-true (%c-langvar 'c-recognize-<>-arglists)))
               (set! found-delim
                     (if (%c-last-command-char=? #\<)
                         ;; If a <, basically see if it's got
                         ;; "template" before it .....
                         (or (and (begin
                                    (backward-char)
                                    (= (point)
                                       (begin (c-beginning-of-current-token)
                                              (point))))
                                  (begin
                                    (c-backward-token-2)
                                    (looking-at (%c-langvar 'c-opt-<>-sexp-key)))
                                  (set! template-delim #t))
                             ;; ..... or is a C++ << operator.
                             (and (c-major-mode-is 'c++-mode)
                                  (begin
                                    (goto-char (- final-pos 1))
                                    (c-beginning-of-current-token)
                                    (looking-at "<<"))
                                  (>= (match-end 0) final-pos)))

                         ;; It's a >. Either a template/generic
                         ;; terminator ...
                         (or (and (c-get-char-property (- final-pos 1)
                                                        'syntax-table)
                                  (set! template-delim #t))
                             ;; or a C++ >> operator.
                             (and (c-major-mode-is 'c++-mode)
                                  (begin
                                    (goto-char (- final-pos 1))
                                    (c-beginning-of-current-token)
                                    (looking-at ">>"))
                                  (>= (match-end 0) final-pos)))))
               (goto-char final-pos)

               (when found-delim
                 (indent-according-to-mode)))))
        ;; On the off chance that < and > are configured as pairs in
        ;; `electric-pair-mode'.
        (when (and (electric-pair-mode-value)
                   (or template-delim include-delim))
          (parameterize ((*post-self-insert-hook* '()))
            (electric-pair-post-self-insert-function)))

        (when found-delim
          (when (and (%c-last-command-char=? #\>)
                     (not executing-kbd-macro)
                     (*blink-paren-function*))
            ((*blink-paren-function*))))
        )
        )
      (c--call-post-self-insert-hook-more-safely))

    (define-command (c-electric-paren arg)
      "Insert a parenthesis.

If `c-syntactic-indentation' and `c-electric-flag' are both non-nil, the
line is reindented unless a numeric ARG is supplied, or the parenthesis
is inserted inside a literal.

Whitespace between a function name and the parenthesis may get added or
removed; see the variable `c-cleanup-list'.

Also, if `c-electric-flag' and `c-auto-newline' are both non-nil, some
newline cleanups are done if appropriate; see the variable `c-cleanup-list'."
      (interactive "*P")
      (parameterize ((*c-echo-syntactic-information-p* #f)
                     (*case-fold-search* #f))
        (let ((literal (c-save-buffer-state ()
                         (c-with-string-fences (c-in-literal)))))
          (parameterize ((*post-self-insert-hook* '()))
            ;; The only way to get defined functionality from
            ;; `self-insert-command'.
            (self-insert-command (prefix-numeric-value arg)
                                 (c-last-command-char)))

          (if (and (not arg) (not literal))
              ;; We want to inhibit blinking the paren since this will be
              ;; most disruptive. We'll blink it ourselves afterwards.
              (let ((old-blink-paren (*blink-paren-function*)))
                (parameterize ((*blink-paren-function* #f))
                  (c-with-string-fences
                 (if (and (c-syntactic-indentation) (c-electric-flag))
                     (indent-according-to-mode))

                 ;; If we're at EOL, check for new-line clean-ups.
                 (when (and (c-electric-flag) (c-auto-newline)
                            (looking-at "[ \t]*\\\\?$"))

                   ;; clean up brace-elseif-brace
                   (when
                       (and (memq 'brace-elseif-brace (or (c-cleanup-list) '()))
                            (%c-last-command-char=? #\()
                            (re-search-backward
                             (concat "}"
                                     "\\([ \t\n]\\|\\\\\n\\)*"
                                     "else"
                                     "\\([ \t\n]\\|\\\\\n\\)+"
                                     "if"
                                     "\\([ \t\n]\\|\\\\\n\\)*"
                                     "("
                                     "\\=")
                             #f #t)
                            (not (c-save-buffer-state () (c-in-literal))))
                     (delete-region (match-beginning 0) (match-end 0))
                     (insert-and-inherit "} else if ("))

                   ;; clean up brace-catch-brace
                   (when
                       (and (memq 'brace-catch-brace (or (c-cleanup-list) '()))
                            (%c-last-command-char=? #\()
                            (re-search-backward
                             (concat "}"
                                     "\\([ \t\n]\\|\\\\\n\\)*"
                                     "catch"
                                     "\\([ \t\n]\\|\\\\\n\\)*"
                                     "("
                                     "\\=")
                             #f #t)
                            (not (c-save-buffer-state () (c-in-literal))))
                     (delete-region (match-beginning 0) (match-end 0))
                     (insert-and-inherit "} catch ("))))
                  ;; Apply `electric-pair-mode' stuff.
                  (when (electric-pair-mode-value)
                    (parameterize ((*post-self-insert-hook* '()))
                      (electric-pair-post-self-insert-function)))
                 (c-with-string-fences
                  ;; Check for clean-ups at function calls. These two
                  ;; DON'T need `c-electric-flag' or
                  ;; `c-syntactic-indentation' set. Point is currently
                  ;; just after the inserted paren.
                  (let ((beg #f) (end (- (point) 1)))
                    (cond

                     ;; space-before-funcall clean-up?
                     ((and (memq 'space-before-funcall (or (c-cleanup-list) '()))
                           (%c-last-command-char=? #\()
                           (save-excursion
                             (backward-char)
                             (skip-chars-backward " \t")
                             (set! beg (point))
                             (and (c-save-buffer-state () (c-on-identifier))
                                  ;; Don't add a space into #define FOO()....
                                  (not (and (c-beginning-of-macro)
                                            (c-forward-over-cpp-define-id)
                                            (eq? (point) beg))))))
                      (save-excursion
                        (delete-region beg end)
                        (goto-char beg)
                        (insert #\space)))

                     ;; compact-empty-funcall clean-up?
                     ((c-save-buffer-state ()
                        (and (memq 'compact-empty-funcall (or (c-cleanup-list) '()))
                             (%c-last-command-char=? #\))
                             (save-excursion
                               (c-safe (backward-char 2))
                               (when (looking-at "()")
                                 (set! end (point))
                                 (skip-chars-backward " \t")
                                 (set! beg (point))
                                 (c-on-identifier)))))
                      (delete-region beg end)))))
                  (and (%c-last-command-char=? #\))
                       (not executing-kbd-macro)
                       old-blink-paren
                       (old-blink-paren))))
              ;; Apply `electric-pair-mode' stuff inside a string or
              ;; comment.
              (when (electric-pair-mode-value)
                (parameterize ((*post-self-insert-hook* '()))
                  (electric-pair-post-self-insert-function))))))
      (c--call-post-self-insert-hook-more-safely))

    (define (c-electric-continued-statement)
      "Reindent the current line if appropriate.

This function is used to reindent the line after a keyword which
continues an earlier statement is typed, e.g. an \"else\" or the
\"while\" in a do-while block.

The line is reindented if there is nothing but whitespace before the
keyword on the line, the keyword is not inserted inside a literal, and
`c-electric-flag' and `c-syntactic-indentation' are both non-nil."
      (parameterize ((*c-echo-syntactic-information-p* #f))
        (when (c-save-buffer-state ()
                (and (c-electric-flag)
                     (c-syntactic-indentation)
                     (not (%c-last-command-char=? #\_))
                     (= (save-excursion
                          (skip-syntax-backward "w")
                          (point))
                        (c-point 'boi))
                     (not (c-in-literal (c-point 'bod)))))
          ;; Have to temporarily insert a space so that
          ;; c-guess-basic-syntax recognizes the keyword. Follow the
          ;; space with a nonspace to avoid messing up any whitespace
          ;; sensitive meddling that might be done, e.g. by
          ;; `c-backslash-region'.
          (insert-and-inherit " x")
          (dynamic-wind
            (lambda () #f)
            (lambda () (indent-according-to-mode))
            (lambda () (delete-char -2))))))

    ;; set up electric character functions to work with pending-del,
    ;; (a.k.a. delsel) mode. All symbols get the t value except
    ;; the functions which delete, which gets 'supersede, and (from
    ;; Emacs 25) `c-electric-brace' and `c-electric-paren' get special
    ;; handling so as to work gracefully with `electric-pair-mode'.
    ;; `cc-cmds.el:3231' places this block later in the file; it is here
    ;; because this is where the commands it marks are defined.
    (for-each
     (lambda (sym)
       (put sym 'delete-selection #t)       ; for delsel (Emacs)
       (put sym 'pending-delete #t))        ; for pending-del (XEmacs)
     '(c-electric-pound
       c-electric-slash
       c-electric-star
       c-electric-semi&comma
       c-electric-lt-gt
       c-electric-colon))
    (for-each
     (lambda (sym)
       ;; `(fboundp 'delete-selection-uses-region-p)' is false here:
       ;; `delete-selection-mode' is not ported, so the `t' arm is the
       ;; one Emacs takes without it.
       (put sym 'delete-selection #t)
       (put sym 'pending-delete #t))
     '(c-electric-brace
       c-electric-paren))


    ;;--------------------------------------------------------------
    ;; `c-backward-into-nomenclature' (`cc-cmds.el:1569')
    ;;--------------------------------------------------------------
    ;; "Compatibility alias for `c-backward-subword'." ARG is optional
    ;; (`&optional arg'), which the tree spells as a rest parameter,
    ;; and the `(if (fboundp 'subword-mode) ...)` is always the first
    ;; arm here: `subword.scm` is imported, so there is no
    ;; `cc-subword.el` to fall back to (Emacs 31 has no such file
    ;; either).
    (define-command (c-backward-into-nomenclature . rest)
      "Compatibility alias for `c-backward-subword'."
      (interactive "p")
      (subword-backward (if (pair? rest) (car rest) #f)))

    ;; `(make-obsolete 'c-backward-into-nomenclature (if (fboundp
    ;; 'subword-mode) 'subword-backward 'c-backward-subword) "23.2")'
    ;; (`cc-cmds.el:1580') - the `if` is always `subword-backward` here
    ;; for the reason above.
    (make-obsolete 'c-backward-into-nomenclature 'subword-backward "23.2")

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
         (with-defun-functions-nil
          (parameterize ((*case-fold-search* #f))
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
                       (= arg 0)))))))))))

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
         (with-defun-functions-nil
          (parameterize ((*case-fold-search* #f))
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
                 (= arg 0)))))))))

    (define (c-defun-name-1)
      "Return name of current defun, at current narrowing, or nil if there isn't one.
\"Defun\" here means a function, or other top level construct
with a brace block."
      (with-defun-functions-nil
       (parameterize ((*case-fold-search* #f))
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
                          (cadr decl))))))))))))

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
        ;; Emacs's `if' without an else answers nil; Scheme's answers the
        ;; unspecified value, which `c-indent-new-comment-line' returns
        ;; to its caller in the macro branch.
        (if (markerp point-pos)
            (set-marker point-pos #f)
            #f))))

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

    ;; ---------------------------------------------------------------
    ;; The filling half: `c-auto-fill-prefix' and `c-guess-fill-prefix'
    ;; (`cc-cmds.el:4057'-`:4438')
    ;;--------------------------------------------------------------
    ;; "The filling code is based on a simple theory; leave the
    ;; intricacies of the text handling to the currently active mode for
    ;; that (e.g. adaptive-fill-mode or filladapt-mode) and do as little
    ;; as possible to make them work correctly wrt the comment and
    ;; string separators, one-line paragraphs etc. ..."
    ;;
    ;; Emacs's `unwind-protect' is `dynamic-wind' (its cleanup thunk),
    ;; `catch`/`throw` a `call-with-current-continuation' exit, and
    ;; `fill-prefix' the `*fill-prefix*' parameter (`indent.scm').
    ;; Emacs declares these with `defvar' but every use is inside a
    ;; `let' that binds them (`c-do-auto-fill', `c-mask-paragraph',
    ;; `c-indent-new-comment-line', `c-context-line-break'), and that
    ;; binding must be seen several calls down: by the convention they
    ;; are parameters.  `c-auto-fill-prefix' is read by
    ;; `c-indent-new-comment-line' from inside `do-auto-fill', which is
    ;; three frames below the `let' in `c-do-auto-fill'.
    (define *c-auto-fill-prefix* (make-parameter #t))
    (define *c-lit-limits* (make-parameter #f))
    (define *c-lit-type* (make-parameter #f))

    (define (c-guess-fill-prefix lit-limits lit-type)
      ;; "Determine the appropriate comment fill prefix for a block or
      ;; line comment.  Return a cons of the prefix string and the
      ;; column where it ends.  If fill-prefix is set, it'll override.
      ;; Note that this function also uses the value of point in some
      ;; heuristics."
      ;;
      ;; "This function might do hidden buffer changes."
      (let* ((here (point))
             (prefix-regexp (concat "[ \t]*\\("
                                    (c-current-comment-prefix)
                                    "\\)[ \t]*"))
             (comment-start-regexp (if (eq? lit-type 'c++)
                                       prefix-regexp
                                       (comment-start-skip)))
             (prefix-line #f) (comment-prefix #f) (res #f)
             (comment-text-end #f))

        (cond
         ((*fill-prefix*)
          (setq res (cons (*fill-prefix*)
                          ;; "Ugly way of getting the column after the
                          ;; fill prefix; it'd be nice with a
                          ;; current-column that works on strings.."
                          (let ((start (point)))
                            (dynamic-wind
                             (lambda () #f)
                             (lambda ()
                               (insert-and-inherit "\n" (*fill-prefix*))
                               (current-column))
                             (lambda ()
                               (delete-region start (point))))))))

         ((eq? lit-type 'c++)
          (save-excursion
            ;; "Set fallback for comment-prefix if none is found."
            (setq comment-prefix "// "
                  comment-text-end (cdr lit-limits))

            (beginning-of-line)
            (if (> (point) (car lit-limits))
                ;; "The current line is not the comment starter, so the
                ;; comment has more than one line, and it can therefore
                ;; be used to find the comment fill prefix."
                (setq prefix-line (point))

                (begin
                  (goto-char (car lit-limits))
                  (if (and (= (forward-line 1) 0)
                           (< (point) (cdr lit-limits)))
                      ;; "The line after the comment starter is inside the
                      ;; comment, so we can use it."
                      (setq prefix-line (point))

                      (begin
                        ;; "The comment is only one line.  Take the
                        ;; comment prefix from it and keep the
                        ;; indentation."
                        (goto-char (car lit-limits))
                        (if (looking-at prefix-regexp)
                            (goto-char (match-end 0))
                            (begin
                              (forward-char 2)
                              (skip-chars-forward " \t")))

                    (let ((str #f) (col #f))
                      (if (eq? (c-point 'boi) (car lit-limits))
                          ;; "There is only whitespace before the
                          ;; comment starter; take the prefix straight
                          ;; from this line."
                          (setq str (buffer-substring-no-properties
                                     (c-point 'bol) (point))
                                col (current-column))

                          ;; "There is code before the comment starter,
                          ;; so we have to temporarily insert and indent
                          ;; a new line to get the right space/tab mix
                          ;; in the indentation."
                          (let ((prefix-len (- (point) (car lit-limits)))
                                (tmp #f))
                            (dynamic-wind
                             (lambda () #f)
                             (lambda ()
                               (goto-char (car lit-limits))
                               (indent-to (let ((c (current-column)))
                                            (insert #\newline)
                                            c))
                               (setq tmp (point))
                               (forward-char prefix-len)
                               (setq str (buffer-substring-no-properties
                                          (c-point 'bol) (point))
                                     col (current-column)))
                             (lambda ()
                               (delete-region (car lit-limits) tmp)))))

                      (setq res
                            (if (or (string-match "\\s \\'" str)
                                    (not (eolp)))
                                (cons str col)
                                ;; "The prefix ends the line with no
                                ;; whitespace after it.  Default to a
                                ;; single space."
                                (cons (concat str " ") (+ col 1)))))))))))

         (else
          (setq comment-text-end
                (save-excursion
                  (goto-char (- (cdr lit-limits) 2))
                  (if (looking-at "\\*/") (point) (cdr lit-limits))))

          (save-excursion
            (beginning-of-line)
            (if (and (> (point) (car lit-limits))
                     (not (and (looking-at "[ \t]*\\*/")
                               (= (cdr lit-limits) (match-end 0)))))
                ;; "The current line is not the comment starter and
                ;; contains more than just the ender, so it's good
                ;; enough to be used for the comment fill prefix."
                (setq prefix-line (point))
                (begin
                (goto-char (car lit-limits))

                (cond ((or (/= (forward-line 1) 0)
                           (>= (point) (cdr lit-limits))
                           (and (looking-at "[ \t]*\\*/")
                                (= (cdr lit-limits) (match-end 0)))
                           (and (looking-at prefix-regexp)
                                (<= (- (cdr lit-limits) 1) (match-end 0))))
                       ;; "The comment is either one line or the next
                       ;; line contains just the comment ender.  In this
                       ;; case we have no information about a suitable
                       ;; comment prefix, so we resort to
                       ;; c-block-comment-prefix."
                       (setq comment-prefix (or (c-block-comment-prefix) "")))

                      ((< here (point))
                       ;; "The point was on the comment opener line, so
                       ;; we might want to treat this as a not yet
                       ;; closed comment."

                       (if (and (match-beginning 1)
                                (/= (match-beginning 1) (match-end 1)))
                           ;; "Above prefix-regexp matched a nonempty
                           ;; prefix on the second line, so let's use
                           ;; it. ..."
                           (if (= (match-end 0) (c-point 'eol))
                               (setq comment-prefix (match-string 1))
                               (setq prefix-line (point)))

                           ;; "There's no nonempty prefix on the line
                           ;; after the comment opener. ..."
                           (if (<= (save-excursion (back-to-indentation)
                                                   (current-column))
                                   (save-excursion (goto-char (car lit-limits))
                                                   (current-column)))
                               (setq comment-prefix
                                     (or (c-block-comment-prefix) ""))
                               (setq prefix-line (point)))))

                      (else
                       ;; "Otherwise the line after the comment starter
                       ;; is good enough to find the prefix in."
                       (setq prefix-line (point))))

                (when-e comment-prefix
                  ;; "Haven't got the comment prefix on any real line
                  ;; that we can take it from, so we have to temporarily
                  ;; insert comment-prefix on a line and indent it to
                  ;; find the correct column and the correct mix of tabs
                  ;; and spaces."
                  (setq res
                        (let ((tmp-pre #f) (tmp-post #f) (at-close #f))
                          (dynamic-wind
                           (lambda () #f)
                           (lambda ()
                             (goto-char (car lit-limits))
                             (if (looking-at comment-start-regexp)
                                 (begin
                                   (goto-char (min (match-end 0)
                                                   comment-text-end))
                                   (setq
                                    at-close
                                    (looking-at
                                     (%c-langvar
                                      'c-block-comment-ender-regexp))))
                                 (begin
                                   (forward-char 2)
                                   (skip-chars-forward " \t")))

                             (when-e (char=? (char-syntax (char-before))
                                             #\space)
                               ;; "If there's ws on the current line,
                               ;; we'll use it instead of what's ending
                               ;; comment-prefix."
                               (setq comment-prefix
                                     (concat (substring
                                              comment-prefix 0
                                              (string-match
                                               "\\s *\\'" comment-prefix))
                                             (buffer-substring-no-properties
                                              (save-excursion
                                                (skip-chars-backward " \t")
                                                (point))
                                              (point))))
                               ;; "If hard up against the comment ender,
                               ;; the prefix must end in at least two
                               ;; spaces."
                               (when-e at-close
                                 (or (string-match "\\s \\s +\\'"
                                                   comment-prefix)
                                     (setq comment-prefix
                                           (concat comment-prefix " ")))))
                             (setq tmp-pre (point-marker))

                             ;; "We insert an extra non-whitespace
                             ;; character before the line break and
                             ;; after comment-prefix in case it's ""
                             ;; or ends with whitespace."
                             (insert-and-inherit "x\n" comment-prefix "x")
                             (setq tmp-post (point-marker))

                             (indent-according-to-mode)

                             (goto-char (- (marker-position tmp-post) 1))
                             (cons (buffer-substring-no-properties
                                    (c-point 'bol) (point))
                                   (current-column)))
                           (lambda ()
                             (when-e tmp-post
                               (delete-region tmp-pre tmp-post)
                               (set-marker tmp-pre #f)
                               (set-marker tmp-post #f))))))))))))

        (or res ; "Found a good prefix above."

            (save-excursion
              ;; "prefix-line is the bol of a line on which we should
              ;; try to find the prefix."
              (let* ((found #f) ; the `throw 'found' exit, established below
                     (fb-string #f) (fb-endpos #f) ; "Contains any fallback prefix found."
                     (test-line
                      (lambda ()
                        (when-e (and (looking-at prefix-regexp)
                                     (<= (match-end 0) comment-text-end))
                          (unless (eqv? (match-end 0) (c-point 'eol))
                            ;; "The match is fine if there's text after it."
                            (found (cons (buffer-substring-no-properties
                                          (match-beginning 0)
                                          (match-end 0))
                                         (begin (goto-char (match-end 0))
                                                (current-column)))))
                          (unless fb-string
                            ;; "This match is better than nothing, so
                            ;; let's remember it in case nothing better
                            ;; is found on another line."
                            (setq fb-string
                                  (buffer-substring-no-properties
                                   (match-beginning 0) (match-end 0))
                                  fb-endpos (match-end 0)))
                          #t))))

                (or (call-with-current-continuation
                     (lambda (k)
                       (set! found k)
                       ;; "Search for a line which has text after the
                       ;; prefix so that we get the proper amount of
                       ;; whitespace after it.  We start with the current
                       ;; line, then search backwards, then forwards."

                       (goto-char prefix-line)
                       (when-e (and (test-line)
                                    (or (/= (match-end 1) (match-end 0))
                                        ;; "The whitespace is sucked up by
                                        ;; the first [ \t]* glob if the
                                        ;; prefix is empty."
                                        (and (= (match-beginning 1)
                                                (match-end 1))
                                             (/= (match-beginning 0)
                                                 (match-end 0)))))
                         ;; "If the current line doesn't have text but
                         ;; do have whitespace after the prefix, we'll
                         ;; use it."
                         (found (cons fb-string
                                      (begin (goto-char fb-endpos)
                                             (current-column)))))

                       (if (eq? lit-type 'c++)
                           ;; "For line comments we can search up to and
                           ;; including the first line."
                           (while-e (and (= (forward-line -1) 0)
                                         (>= (point) (car lit-limits)))
                             (test-line))
                           ;; "For block comments we must stop before the
                           ;; block starter."
                           (while-e (and (= (forward-line -1) 0)
                                         (> (point) (car lit-limits)))
                             (test-line)))

                       (goto-char prefix-line)
                       (while-e (and (= (forward-line 1) 0)
                                     (< (point) (cdr lit-limits)))
                         (test-line))

                       (goto-char prefix-line)
                       #f))

                    (when-e fb-string
                      ;; "A good line wasn't found, but at least we have
                      ;; a fallback that matches the comment prefix
                      ;; regexp."
                      (cond ((or (string-match "\\s \\'" fb-string)
                                 (begin
                                   (goto-char fb-endpos)
                                   (not (eolp))))
                             ;; "There are ws or text after the prefix,
                             ;; so let's use it."
                             (cons fb-string (current-column)))

                            ((begin
                               ;; "Check if there's any whitespace
                               ;; padding on the comment start line that
                               ;; we can use after the prefix."
                               (goto-char (car lit-limits))
                               (if (looking-at comment-start-regexp)
                                   (goto-char (match-end 0))
                                   (begin
                                     (forward-char 2)
                                     (skip-chars-forward " \t")))
                               (or (not (eolp))
                                   (char=? (char-syntax (char-before))
                                           #\space)))

                             (setq fb-string
                                   (buffer-substring-no-properties
                                    (save-excursion
                                      (skip-chars-backward " \t")
                                      (point))
                                    (point)))
                             (goto-char fb-endpos)
                             (skip-chars-backward " \t")

                             (let ((tmp (point)))
                               ;; "Got to mess in the buffer once again
                               ;; to ensure the column gets correct.  :P"
                               (dynamic-wind
                                (lambda () #f)
                                (lambda ()
                                  (insert-and-inherit fb-string)
                                  (cons (buffer-substring-no-properties
                                         (c-point 'bol)
                                         (point))
                                        (current-column)))
                                (lambda ()
                                  (delete-region tmp (point))))))

                            (else
                             ;; "Last resort: Just add a single space
                             ;; after the prefix."
                             (cons (concat fb-string " ")
                                   (begin (goto-char fb-endpos)
                                          (+ (current-column) 1))))))

                    ;; "The line doesn't match the comment prefix regexp."
                    (if comment-prefix
                        ;; "We have a fallback for line comments that we
                        ;; must use."
                        (cons (concat (buffer-substring-no-properties
                                       prefix-line (c-point 'boi))
                                      comment-prefix)
                              (begin
                                (back-to-indentation)
                                (+ (current-column)
                                   (string-length comment-prefix))))

                        ;; "Assume we are dealing with a \"free text\"
                        ;; block comment where the lines doesn't have
                        ;; any comment prefix at all and we should just
                        ;; fill it as normal text."
                        '("" . 0))))))))

    ;; ---------------------------------------------------------------
    ;; `c-mask-paragraph' (`cc-cmds.el:4440')
    ;;--------------------------------------------------------------
    ;; "Calls FUN with ARGS ar arguments while the current paragraph is
    ;; masked to allow adaptive filling to work correctly.  That
    ;; includes narrowing the buffer and, if point is inside a comment,
    ;; masking the comment starter and ender appropriately."
    ;;
    ;; Emacs's `unwind-protect' is `dynamic-wind'; the `let' of the two
    ;; lit variables is a `parameterize' of their parameters (the
    ;; convention's test: Emacs `let'-binds them), and the `fill-prefix'
    ;; binding that the called function must see is a `parameterize' too.
    ;; `buffer-undo-list' has no point-entry form here - the engine's
    ;; undo list is undo.scm's, and nothing interprets a bare integer -
    ;; so the "restore point on undo" line is not carried; the hidden
    ;; edits below all run under `with-silent-modifications', which is
    ;; what keeps them out of the undo list on both sides.
    ;;
    ;; Markers do no arithmetic here, so `(min end ...)', `(1- end)' and
    ;; the `char-before' of a marker are spelled with `marker-position'.
    (define (c-mask-paragraph fill-paragraph apply-outside-literal fun . args)
      (let ((fill #f)
            (beg #f) (end #f)
            (tmp-pre #f) (tmp-post #f)
            (hang-ender-stuck #f)
            (auto-fill-spaces #f)
            (here (point)))

        ;; "Determine the limits and type of the containing literal (if
        ;; any): C-LIT-LIMITS, C-LIT-TYPE; and the limits of the current
        ;; paragraph: BEG and END."
        (parameterize ((*c-lit-limits* (*c-lit-limits*))
                       (*c-lit-type* (*c-lit-type*)))
          (c-save-buffer-state ()
            (save-restriction
              ;; "Widen to catch comment limits correctly."
              (widen)
              (unless (*c-lit-limits*)
                (*c-lit-limits* (c-literal-limits #f fill-paragraph)))
              (*c-lit-limits* (c-collect-line-comments (*c-lit-limits*)))
              (unless (*c-lit-type*)
                (*c-lit-type* (c-literal-type (*c-lit-limits*)))))

            (save-excursion
              (unless (c-safe (backward-char)
                              (forward-paragraph)
                              (>= (point) here))
                (goto-char here)
                (forward-paragraph))
              (set! end (point-marker)))
            (save-excursion
              (unless (c-safe (forward-char)
                              (backward-paragraph)
                              (<= (point) here))
                (goto-char here)
                (backward-paragraph))
              (set! beg (point))))

          (dynamic-wind
           (lambda () #f)
           (lambda ()
             ;; "For each of the possible types of text (string, C
             ;; comment ...) determine BEG and END, the region we will
             ;; narrow to.  If we're in a literal, constrain BEG and END
             ;; to the limits of this literal."
             (cond

              ((eq? (*c-lit-type*) 'c++)     ; Line comment.
               (save-excursion
                 ;; "Limit to the comment or paragraph end, whichever
                 ;; comes first."
                 (set-marker end (min (marker-position end)
                                      (cdr (*c-lit-limits*))))

                 (when (<= beg (car (*c-lit-limits*)))
                   ;; "The region includes the comment starter, so we
                   ;; must check it."
                   (goto-char (car (*c-lit-limits*)))
                   (back-to-indentation)
                   (if (eq? (point) (car (*c-lit-limits*)))
                       ;; "Include the first line in the region."
                       (set! beg (c-point 'bol))
                       ;; "The first line contains code before the
                       ;; comment.  We must fake a line that doesn't."
                       (set! tmp-pre #t))))

               (set! apply-outside-literal #t))

              ((eq? (*c-lit-type*) 'c)       ; Block comment.
               (when
                   (or (> (marker-position end) (cdr (*c-lit-limits*)))
                       (and (= (marker-position end) (cdr (*c-lit-limits*)))
                            (char=? (char-before (marker-position end)) #\/)
                            (char=? (char-before (- (marker-position end) 1)) #\*)
                            ;; "disallow \"/*/\""
                            (> (- (cdr (*c-lit-limits*))
                                  (car (*c-lit-limits*)))
                               3)))
                 ;; "There is a comment ender, and the region includes
                 ;; it.  If it's on its own line, it stays on its own
                 ;; line.  If it's got company on the line, it keeps (at
                 ;; least one word of) it."
                 (unless
                     (save-excursion
                       (goto-char (cdr (*c-lit-limits*)))
                       (beginning-of-line)
                       (and
                        (re-search-forward
                         (concat "\\=[ \t]*\\("
                                 (c-current-comment-prefix)
                                 "\\)")
                         (- (cdr (*c-lit-limits*)) 2) #t)
                        (not (re-search-forward
                              "\\(\\s \\|\\sw\\)"
                              (- (cdr (*c-lit-limits*)) 2) 'limit))
                        ;; "The comment ender IS on its own line.
                        ;; Exclude this line from the filling."
                        (set-marker end (c-point 'bol))))

                   ;; "The comment ender is hanging.  Replace all space
                   ;; between it and the last word either by one or two
                   ;; 'x's (when FILL-PARAGRAPH is non-nil), or a row of
                   ;; x's the same width as the whitespace (when auto
                   ;; filling), and include it in the region.  We'll
                   ;; change them back to whitespace afterwards.  The
                   ;; effect of this is to glue the comment ender to the
                   ;; last word in the comment during filling."
                   (let* ((ender-start (save-excursion
                                         (goto-char (cdr (*c-lit-limits*)))
                                         (skip-syntax-backward "^w ")
                                         (point)))
                          (ender-column (save-excursion
                                          (goto-char ender-start)
                                          (current-column)))
                          (point-rel (- ender-start here))
                          (sentence-ends-comment
                           (save-excursion
                             (goto-char ender-start)
                             (and (re-search-backward
                                   (c-sentence-end) (c-point 'bol) #t)
                                  (goto-char (match-end 0))
                                  (looking-at "[ \t]*")
                                  (= (match-end 0) ender-start))))
                          (spaces #f))

                     (save-excursion
                       ;; "Insert a CR after the \"*/\", adjust END"
                       (goto-char (cdr (*c-lit-limits*)))
                       (set! tmp-post (point-marker))
                       (insert #\newline)
                       (set-marker end (point))

                       (forward-line -1)  ; last line of the comment
                       (if (and (looking-at (concat "[ \t]*\\(\\("
                                                    (c-current-comment-prefix)
                                                    "\\)[ \t]*\\)"))
                                (eqv? ender-start (match-end 0)))
                           ;; "The comment ender is prefixed by nothing
                           ;; but a comment line prefix.  IS THIS
                           ;; POSSIBLE?  (ACM, 2006/4/28).  Remove it
                           ;; along with surrounding ws."
                           (set! spaces (- (match-end 1) (match-end 2)))
                           (goto-char ender-start))
                       (skip-chars-backward " \t\r\n")
                       ;; "What's being tested here?  2006/4/20.  FIXME!!!"
                       (if (/= (point) ender-start)
                           (begin
                             (if (<= here (point))
                                 ;; "Don't adjust point below if it's
                                 ;; before the string we replace."
                                 (set! point-rel -1))
                             ;; "Keep one or two spaces between the text
                             ;; and the ender, depending on how many
                             ;; there are now."
                             (unless spaces
                               (set! spaces (- ender-column (current-column))))
                             (set! auto-fill-spaces
                                   (c-delete-and-extract-region (point) ender-start))
                             ;; "paragraph filling condenses multiple
                             ;; spaces to single or double spaces.
                             ;; auto-fill doesn't."
                             (if fill-paragraph
                                 (set! spaces
                                       (max
                                        (min spaces
                                             (if (and sentence-ends-comment
                                                      (*sentence-end-double-space*))
                                                 2 1))
                                        1)))
                             ;; "Insert the filler first to keep marks right."
                             (insert-char #\x spaces #t)
                             (set! hang-ender-stuck spaces)
                             (set! point-rel
                                   (and (>= point-rel 0)
                                        (- (point) (min point-rel spaces)))))
                           (set! point-rel #f)))

                     (if point-rel
                         ;; "Point was in the middle of the string we
                         ;; replaced above, so put it back in the same
                         ;; relative position, counting from the end."
                         (goto-char point-rel)))))

               (when (<= beg (car (*c-lit-limits*)))
                 ;; "The region includes the comment starter."
                 (save-excursion
                   (goto-char (car (*c-lit-limits*)))
                   (if (looking-at (concat "\\(" (comment-start-skip) "\\)$"))
                       ;; "Begin with the next line."
                       (set! beg (c-point 'bonl))
                       ;; "Fake the fill prefix in the first line."
                       (set! tmp-pre #t))))

               (set! apply-outside-literal #t))

              ((eq? (*c-lit-type*) 'string)  ; String.
               (save-excursion
                 (when (>= (marker-position end) (cdr (*c-lit-limits*)))
                   (goto-char (- (cdr (*c-lit-limits*)) 1))
                   (set! tmp-post (point-marker))
                   (insert #\newline)
                   (set-marker end (point)))
                 (when (<= beg (car (*c-lit-limits*)))
                   (goto-char (+ (car (*c-lit-limits*)) 1))
                   (set! beg (if (looking-at "\\\\$")
                                 ;; "Leave the start line if it's nothing
                                 ;; but an escaped newline."
                                 (+ (match-end 0) 1)
                                 (point)))))
               (set! apply-outside-literal #t))

              ((eq? (*c-lit-type*) 'pound)   ; Macro
               ;; "Narrow to the macro limits if they are nearer than the
               ;; paragraph limits.  Don't know if this is necessary but
               ;; do it for completeness sake (doing auto filling at all
               ;; inside macros is bogus to begin with since the line
               ;; continuation backslashes aren't handled)."
               (save-excursion
                 (c-save-buffer-state ()
                   (c-beginning-of-macro)
                   (beginning-of-line)
                   (if (> (point) beg)
                       (set! beg (point)))
                   (c-end-of-macro)
                   (forward-line)
                   (if (< (point) (marker-position end))
                       (set-marker end (point))))))

              (else                          ; Other code.
               ;; "Try to avoid comments and macros in the paragraph to
               ;; avoid that the adaptive fill mode gets the prefix from
               ;; them."
               (c-save-buffer-state ()
                 (save-excursion
                   (goto-char beg)
                   (c-forward-syntactic-ws (marker-position end))
                   (beginning-of-line)
                   (set! beg (point))
                   (goto-char (marker-position end))
                   (c-backward-syntactic-ws beg)
                   (forward-line)
                   (set-marker end (point))))))

             (when tmp-pre
               ;; "Temporarily insert the fill prefix after the comment
               ;; starter so that the first line looks like any other
               ;; comment line in the narrowed region."
               (set! fill (c-save-buffer-state ()
                            (c-guess-fill-prefix (*c-lit-limits*) (*c-lit-type*))))
               (unless (string-match (concat "\\`[ \t]*\\("
                                             (c-current-comment-prefix)
                                             "\\)[ \t]*\\'")
                                     (car fill))
                 ;; "Oops, the prefix doesn't match the comment prefix
                 ;; regexp.  This could produce very confusing results
                 ;; with adaptive fill packages together with the insert
                 ;; prefix magic below, since the prefix often doesn't
                 ;; appear at all.  So let's warn about it."
                 (message "Warning: Regexp from `c-comment-prefix-regexp' doesn't match the comment prefix ~s"
                          (car fill)))
               ;; "Find the right spot on the line, break it, insert the
               ;; fill prefix and make sure we're back in the same column
               ;; by temporarily prefixing the first word with a number
               ;; of 'x'."
               (save-excursion
                 (goto-char (car (*c-lit-limits*)))
                 (if (looking-at (if (eq? (*c-lit-type*) 'c++)
                                     (c-current-comment-prefix)
                                     (comment-start-skip)))
                     (goto-char (match-end 0))
                     (begin
                       (forward-char 2)
                       (skip-chars-forward " \t")))
                 (while-e (and (< (current-column) (cdr fill))
                               (not (eolp)))
                   (forward-char 1))
                 (let ((col (current-column)))
                   (set! beg (+ (point) 1))
                   (set! tmp-pre (list (point)))
                   (dynamic-wind
                    (lambda () #f)
                    (lambda ()
                      (insert-and-inherit "\n" (car fill))
                      (insert-char #\x (- col (current-column)) #t))
                    (lambda ()
                      (set-cdr! tmp-pre (point)))))))

             (when apply-outside-literal
               ;; "`apply-outside-literal' is always set to t here if
               ;; we're inside a literal."
               (let ((fill-prefix
                      (or (*fill-prefix*)
                          ;; "Kludge: If the function that adapts the
                          ;; fill prefix doesn't produce the required
                          ;; comment starter for line comments, then
                          ;; force it by setting fill-prefix." (The
                          ;; `filladapt-mode' guard in the C tests a
                          ;; package this tree does not have, and its
                          ;; `boundp' is nil in Emacs' default too.)
                          ;; A `when' whose test fails answers the
                          ;; unspecified value, and this is a value
                          ;; position - it becomes `fill-prefix' - so
                          ;; the explicit `#f' is required.
                          (if (and (eq? (*c-lit-type*) 'c++)
                                   (not (string-match
                                         "\\`[ \t]*//"
                                         (or (fill-context-prefix
                                              beg (marker-position end))
                                             ""))))
                              (c-save-buffer-state ()
                                (car (or fill
                                         (c-guess-fill-prefix
                                          (*c-lit-limits*) (*c-lit-type*)))))
                              #f)))
                     ;; "Save the relative position of point if it's
                     ;; outside the region we're going to narrow.  Want
                     ;; to restore it in that case, but otherwise it
                     ;; should be moved according to the called
                     ;; function."
                     (point-rel (cond ((< (point) beg) (- (point) beg))
                                      ((> (point) (marker-position end))
                                       (- (point) (marker-position end)))
                                      (else #f))))

                 ;; "Preparations finally done!  Now we can call the
                 ;; actual function."
                 (prog1
                     (parameterize ((*fill-prefix* fill-prefix))
                       (save-restriction
                         (narrow-to-region beg (marker-position end))
                         (apply fun args)))
                   (if point-rel
                       ;; "Restore point if it was outside the region."
                       (if (< point-rel 0)
                           (goto-char (+ beg point-rel))
                           (goto-char (+ (marker-position end) point-rel))))))))

           (lambda ()
             ;; The `unwind-protect' cleanup.
             (when (pair? tmp-pre)
               (delete-region (car tmp-pre) (cdr tmp-pre)))

             (when tmp-post
               (save-excursion
                 (goto-char tmp-post)
                 (delete-char 1))
               (when hang-ender-stuck
                 ;; "Preserve point even if it's in the middle of the
                 ;; string we replace; save-excursion doesn't work in that
                 ;; case."
                 (set! here (point))
                 (goto-char tmp-post)
                 (skip-syntax-backward "^w ")
                 (forward-char (- hang-ender-stuck))
                 (if (or fill-paragraph (not auto-fill-spaces))
                     (insert-char #\space hang-ender-stuck #t)
                     (insert auto-fill-spaces))
                 (delete-char hang-ender-stuck)
                 (goto-char here))
               (set-marker tmp-post #f))

             (set-marker end #f))))))

    ;; ---------------------------------------------------------------
    ;; `c-fill-paragraph' (`cc-cmds.el:4829') and the commands over it
    ;;--------------------------------------------------------------
    (define-command (c-fill-paragraph arg)
      "Like \\[fill-paragraph] but handles C and C++ style comments.
If any of the current line is a comment or within a comment, fill the
comment or the paragraph of it that point is in, preserving the
comment indentation or line-starting decorations (see the
`c-comment-prefix-regexp' and `c-block-comment-prefix' variables for
details).

If point is inside multiline string literal, fill it.  This currently
does not respect escaped newlines, except for the special case when it
is the very first thing in the string.  The intended use for this rule
is in situations like the following:

char description[] = \"\\
A very long description of something that you want to fill to make
nicely formatted output.\";

If point is in any other situation, i.e. in normal code, do nothing.

Optional prefix ARG means justify paragraph as well."
      (interactive "*P")
      (c-with-string-fences
       ;; Emacs's `let` of a buffer-local variable: `call-with-buffer-local`,
       ;; not `parameterize` (the variable is a slot store now).
       (call-with-buffer-local
        'fill-paragraph-function
        ;; "Avoid infinite recursion."
        (if (not (eq? (fill-paragraph-function) c-fill-paragraph))
            (fill-paragraph-function)
            #f)
        (lambda ()
          (c-mask-paragraph #t #f fill-paragraph arg)))
       ;; "Always return t.  This has the effect that if filling isn't
       ;; done above, it isn't done at all, and it's therefore
       ;; effectively disabled in normal code."
       #t))

    (define (c-do-auto-fill)
      ;; "Do automatic filling if not inside a context where it should
      ;; be ignored."
      (parameterize ((*c-auto-fill-prefix*
                      ;; "The decision whether the line should be broken
                      ;; is actually done in c-indent-new-comment-line,
                      ;; which do-auto-fill calls to break lines.  We
                      ;; just set this special variable so that we'll
                      ;; know when we're called from there.  It's also
                      ;; used to detect whether fill-prefix is user set
                      ;; or generated automatically by do-auto-fill."
                      (*fill-prefix*)))
        (c-mask-paragraph #f #t do-auto-fill)))

    (define-command (c-indent-new-comment-line . rest)
      "Break line at point and indent, continuing comment or macro if within one.
If inside a comment and `comment-multi-line' is non-nil, the
indentation and line prefix are preserved (see the
`c-comment-prefix-regexp' and `c-block-comment-prefix' variables for
details).  If inside a single line comment and `comment-multi-line' is
nil, a new comment of the same type is started on the next line and
indented as appropriate for comments.  If inside a macro, a line
continuation backslash is inserted and aligned as appropriate, and the
new line is indented according to `c-syntactic-indentation'.

If a fill prefix is specified, it overrides all the above."
      ;; "allow-auto-fill is used from c-context-line-break to allow auto
      ;; filling to break the line more than once.  Since this function
      ;; is used from auto-fill itself, that's normally disabled to
      ;; avoid unnecessary recursion."
      (interactive)
      (let ((soft (and (pair? rest) (car rest)))
            (allow-auto-fill (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (c-with-string-fences
         (parameterize ((*fill-prefix* (*fill-prefix*))
                        (*c-lit-limits* (*c-lit-limits*))
                        (*c-lit-type* (*c-lit-type*))
                        (*c-macro-start* (*c-macro-start*)))
           (let ((do-line-break
                  (lambda ()
                    (delete-horizontal-space)
                    (if soft
                        (insert-and-inherit #\newline)
                        (insert-newline (if allow-auto-fill #f 1))))))

             (c-save-buffer-state ()
               (when (not (eq? (*c-auto-fill-prefix*) #t))
                 ;; "Called from do-auto-fill."
                 (unless (*c-lit-limits*)
                   (*c-lit-limits* (c-literal-limits #f #f #t)))
                 (unless (*c-lit-type*)
                   (*c-lit-type* (c-literal-type (*c-lit-limits*))))
                 (if (memq (cond ((memq (*c-lit-type*) '(c c++ string)) (*c-lit-type*))
                                 ((c-query-and-set-macro-start) 'cpp)
                                 ((not (*c-lit-type*)) 'code)
                                 (else (*c-lit-type*)))
                             (*c-ignore-auto-fill*))
                     (*fill-prefix* #t) ; "Used as flag in the cond."
                     (if (and (not (*c-auto-fill-prefix*))
                              (eq? (*c-lit-type*) 'c)
                              (<= (c-point 'bol) (car (*c-lit-limits*))))
                         ;; "The adaptive fill function has generated a
                         ;; prefix, but we're on the first line in a
                         ;; block comment so it'll be wrong.  Ignore it
                         ;; to guess a better one below."
                         (*fill-prefix* #f)
                         (when (and (eq? (*c-lit-type*) 'c++)
                                    (not (string-match
                                          (concat "\\`[ \t]*"
                                                  (%c-langvar 'c-line-comment-starter))
                                          (or (*fill-prefix*) ""))))
                           ;; "Kludge: If the function that adapted the
                           ;; fill prefix doesn't produce the required
                           ;; comment starter for line comments, then we
                           ;; ignore it."
                           (*fill-prefix* #f))))))

             (cond ((eq? (*fill-prefix*) #t)
                    ;; "A call from do-auto-fill which should be ignored."
                    #f)
                   ((*fill-prefix*)
                    ;; "A fill-prefix overrides anything."
                    (do-line-break)
                    (insert-and-inherit (*fill-prefix*)))
                   ((c-save-buffer-state ()
                      (unless (*c-lit-limits*)
                        (*c-lit-limits* (c-literal-limits)))
                      (unless (*c-lit-type*)
                        (*c-lit-type* (c-literal-type (*c-lit-limits*))))
                      (memq (*c-lit-type*) '(c c++)))
                    ;; "Some sort of comment."
                    (if (or (comment-multi-line)
                            (save-excursion
                              (goto-char (car (*c-lit-limits*)))
                              (end-of-line)
                              (< (point) (cdr (*c-lit-limits*)))))
                        ;; "Inside a comment that should be continued."
                        (let ((fill (c-save-buffer-state ()
                                      (let ((collected
                                             (c-collect-line-comments (*c-lit-limits*))))
                                        (*c-lit-limits* collected)
                                        (c-guess-fill-prefix collected (*c-lit-type*)))))
                              (pos (point))
                              (comment-text-end
                               (or (and (eq? (*c-lit-type*) 'c)
                                        (save-excursion
                                          (goto-char (- (cdr (*c-lit-limits*)) 2))
                                          ;; Elisp's `if' without an else is
                                          ;; nil; Scheme's is the unspecified
                                          ;; value, which `and' takes as true.
                                          (if (looking-at "\\*/") (point) #f)))
                                   (cdr (*c-lit-limits*)))))
                          ;; "Skip forward past the fill prefix in case
                          ;; we're standing in it."
                          (while-e (and (< (current-column) (cdr fill))
                                        (not (eolp)))
                            (forward-char 1))
                          (if (and (> (point) comment-text-end)
                                   (> (c-point 'bol) (car (*c-lit-limits*))))
                              (begin
                                ;; "The skip takes us out of the (block)
                                ;; comment; insert the fill prefix at bol
                                ;; instead and keep the position."
                                (set! pos (copy-marker pos #t))
                                (beginning-of-line)
                                (insert-and-inherit (car fill))
                                (if soft (insert-and-inherit #\newline) (insert-newline 1))
                                (goto-char pos)
                                (set-marker pos #f))
                              (begin
                              ;; "Don't break in the middle of a comment
                              ;; starter or ender."
                              (cond ((> (point) comment-text-end)
                                     (goto-char comment-text-end))
                                    ((< (point) (+ (car (*c-lit-limits*)) 2))
                                     (goto-char (+ (car (*c-lit-limits*)) 2))))
                              (do-line-break)
                              (insert-and-inherit (car fill))
                              (if (and (looking-at (%c-langvar 'c-block-comment-ender-regexp))
                                       (let ((c (char-before)))
                                         (and c (memv c (list #\space #\tab)))))
                                  (backward-char)
                                  ;; Elisp's `if` with no ELSE answers nil;
                                  ;; this is the command's return value
                                  ;; when the test fails.
                                  #f)))) ; "can this hit the middle of a TAB?"
                        ;; "Inside a comment that should be broken."
                        (call-with-buffer-local
                         'comment-start (comment-start)
                         (lambda ()
                           (call-with-buffer-local
                            'comment-end (comment-end)
                            (lambda ()
                              (if (eq? (*c-lit-type*) 'c)
                                  (unless (string-match "[ \t]*/\\*" (comment-start))
                                    (set!comment-start "/* ")
                                    (set!comment-end " */"))
                                  (unless (string-match "[ \t]*//" (comment-start))
                                    (set!comment-start "// ")
                                    (set!comment-end "")))
                              (let ((col (save-excursion
                                           (back-to-indentation)
                                           (current-column))))
                                (do-line-break)
                                (when (and (comment-end)
                                           (not (string=? (comment-end) "")))
                                  (forward-char -1)
                                  (insert-and-inherit (comment-end))
                                  (forward-char 1))
                                ;; "c-comment-indent may look at the
                                ;; current indentation, so let's start
                                ;; out with the same indentation as the
                                ;; previous one."
                                (indent-to col)
                                (insert-and-inherit (comment-start))
                                (indent-for-comment))))))))
                   ((c-query-and-set-macro-start)
                    ;; "In a macro."
                    (unless (looking-at "[ \t]*\\\\$")
                      ;; "Do not clobber the alignment of the line
                      ;; continuation slash; c-backslash-region might
                      ;; look at it."
                      (delete-horizontal-space))
                    ;; "Got an asymmetry here: In normal code this
                    ;; command doesn't indent the next line
                    ;; syntactically, and otoh a normal syntactically
                    ;; indenting newline doesn't continue the macro."
                    (c-newline-and-indent (if allow-auto-fill #f 1)))
                   (else
                    ;; "Somewhere else in the code."
                    (let ((col (save-excursion
                                 (beginning-of-line)
                                 (while-e (and (looking-at "[ \t]*\\\\?$")
                                               (= (forward-line -1) 0)))
                                 (current-indentation))))
                      (do-line-break)
                      (indent-to col)))))))))

    (define-alias c-comment-line-break-function c-indent-new-comment-line)

    (define-command (c-context-line-break)
      "Do a line break suitable to the context.

When point is outside a comment or macro, insert a newline and indent
according to the syntactic context, unless `c-syntactic-indentation'
is nil, in which case the new line is indented as the previous
non-empty line instead.

When point is inside the content of a preprocessor directive, a line
continuation backslash is inserted before the line break and aligned
appropriately.  The end of the cpp directive doesn't count as inside
it.

When point is inside a comment, continue it with the appropriate
comment prefix (see the `c-comment-prefix-regexp' and
`c-block-comment-prefix' variables for details).  The end of a
C++-style line comment doesn't count as inside it.

When point is inside a string, only insert a backslash when it is also
inside a preprocessor directive."
      (interactive "*")
      (c-with-string-fences
       (parameterize ((*c-lit-limits* #f) (*c-lit-type* #f)
                      (*c-macro-start* (*c-macro-start*))
                      (*case-fold-search* #f))

         (c-save-buffer-state ()
           (*c-lit-limits* (c-literal-limits #f #f #t))
           (*c-lit-type* (c-literal-type (*c-lit-limits*)))
           (when (eq? (*c-lit-type*) 'c++)
             (*c-lit-limits* (c-collect-line-comments (*c-lit-limits*))))
           (c-query-and-set-macro-start))

         (cond
          ((or (eq? (*c-lit-type*) 'c)
               (and (eq? (*c-lit-type*) 'c++) ; "C++ comment, but not at the very end of it."
                    (< (save-excursion
                         (skip-chars-forward " \t")
                         (point))
                       (- (cdr (*c-lit-limits*)) 1)))
               (and (number? (*c-macro-start*)) ; "Macro, but not at the very end of it,"
                                                ; "not in a string, and not in the cpp keyword."
                    (not (eq? (*c-lit-type*) 'string))
                    (or (not (looking-at "\\s *$"))
                        (%c-char-before=? #\\))
                    (<= (save-excursion
                          (goto-char (*c-macro-start*))
                          (if (looking-at (%c-langvar 'c-opt-cpp-start))
                              (goto-char (match-end 0)))
                          (point))
                        (point))))
           (call-with-buffer-local
            'comment-multi-line #t
            (lambda ()
              (parameterize ((*fill-prefix* #f))
                (c-indent-new-comment-line #f #t)))))

          ((eq? (*c-lit-type*) 'string)
           (if (and (number? (*c-macro-start*))
                    (not (%c-char-before=? #\\)))
               (insert #\\))
           (insert-newline))

          (else (delete-horizontal-space)
                (insert-newline)
                ;; "c-indent-line may look at the current indentation,
                ;; so let's start out with the same indentation as the
                ;; previous line."
                (let ((col (save-excursion
                             (backward-char)
                             (forward-line 0)
                             (while-e (and (looking-at "[ \t]*\\\\?$")
                                           (= (forward-line -1) 0)))
                             (current-indentation))))
                  (indent-to col))
                (indent-according-to-mode))))))

    (define-command (c-context-open-line)
      "Insert a line break suitable to the context and leave point before it.
This is the `c-context-line-break' equivalent to `open-line'
\\(bound to \\[open-line]).  See `c-context-line-break' for the
details."
      (interactive "*")
      (let ((here (point)))
        (dynamic-wind
         (lambda () #f)
         (lambda ()
           ;; "Temporarily insert a non-whitespace char to keep any
           ;; preceding whitespace intact."
           (insert #\x)
           (c-context-line-break))
         (lambda ()
           (goto-char here)
           (delete-char 1)))))

    ;; ---------------------------------------------------------------
    ;; Text conversion support (`cc-cmds.el:5152'')
    ;;--------------------------------------------------------------
    ;; `post-text-conversion-hook' itself lives in Emacs's C input
    ;; machinery (`keyboard.c''s `Vpost_text_conversion_hook'), which is
    ;; not ported; the function is carried whole because the commands it
    ;; dispatches over are now all here.
    (define (c-post-text-conversion)
      "Notice that the character `last-command-event' has been inserted.
If said character is an electric character such as `*' or `{', delete
it, then call the appropriate CC Mode function to electrically insert
it again."
      (let ((c (c-last-command-char)))
        (cond
         ((eqv? c (char->integer #\#)) (delete-char -1) (c-electric-pound #f) #t)
         ((memv c (list (char->integer #\{) (char->integer #\})))
          (delete-char -1) (c-electric-brace #f) #t)
         ((memv c (list (char->integer #\() (char->integer #\))))
          (delete-char -1) (c-electric-paren #f) #t)
         ((eqv? c (char->integer #\*)) (delete-char -1) (c-electric-star #f) #t)
         ((eqv? c (char->integer #\/)) (delete-char -1) (c-electric-slash #f) #t)
         ((memv c (list (char->integer #\;) (char->integer #\,)))
          (delete-char -1) (c-electric-semi&comma #f) #t)
         ((eqv? c (char->integer #\:)) (delete-char -1) (c-electric-colon #f) #t)
         ((memv c (list (char->integer #\>) (char->integer #\<)))
          (delete-char -1) (c-electric-lt-gt #f) #t)
         (else #f))))

    ))
