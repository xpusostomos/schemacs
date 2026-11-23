(define-library (schemacs editor cc-cmds)
  ;; `lisp/progmodes/cc-cmds.el' - the editing commands: the indentation
  ;; command layer, this pass, with the electric keys, the motions and
  ;; the paragraph-filling machinery to follow.
  ;;
  ;; Ported in this pass, in Emacs's file order: `c-fix-backslashes',
  ;; `c-indent-line', `c-newline-and-indent',
  ;; `c-show-syntactic-information', `c-syntactic-information-on-region',
  ;; `c-update-modeline', the six toggles, `c-indent-command',
  ;; `c-indent-exp', `c-indent-region', `c-fn-region-is-active-p',
  ;; `c-indent-line-or-region', the progress-reporting helpers and the
  ;; `c-backslash-region' family.
  ;;
  ;; **Not carried yet**, each with what it waits for:
  ;;
  ;;   * every `c-electric-*' command and the `c-hanging-*' machinery
  ;;     they drive (`c-point-syntax', `c-brace-newlines',
  ;;     `c-try-one-liner', `c-do-brace-electrics') - the next tranche;
  ;;   * the motions from `c-backward-into-nomenclature' to
  ;;     `c-mark-function' (`c-where-wrt-brace-construct',
  ;;     `c-beginning-of-defun', `c-end-of-defun', `c-defun-name',
  ;;     `c-declaration-limits'), and with them `c-indent-defun',
  ;;     which calls `c-declaration-limits';
  ;;   * the sentence motions in comments and strings;
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
  ;;   * `(run-hooks 'c-special-indent-hook)' needs the two things the
  ;;     tree's `run-hooks' cannot do - the `t' that marks a
  ;;     buffer-local hook (`subr.el:2317') and the symbol entries the
  ;;     style data holds - so `c-run-special-indent-hook' below is the
  ;;     C's `run_hook_with_args' (`eval.c:2999') for this one hook.
  (import
    (scheme base)
    (only (schemacs syntax) when-e unless-e while-e setq)
    (only (schemacs editor cc-defs)
          c-save-buffer-state c-with-string-fences
          c-put-overlay c-delete-overlay c-font-lock-flush
          c-region-is-active-p c-keep-region-active
          c-forward-sexp c-safe c-langelem-pos c-langelem-2nd-pos
          c-down-list-forward c-up-list-forward)
    (only (schemacs editor cc-vars)
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
          c-basic-offset c-backslash-column c-backslash-max-column)
    (only (schemacs editor cc-engine)
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
          c-lineup-function %c-langvar)
    (only (schemacs editor buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          call-with-buffer-local local-variable-p mode-name set!mode-name)
    ;; `beginning-of-line' and `end-of-line' are `cmds.c`'s commands.
    (only (schemacs editor cmds)
          beginning-of-line end-of-line backward-char forward-char
          delete-char)
    (only (schemacs editor command)
          define-command current-prefix-arg prefix-numeric-value)
    (only (schemacs editor editfns)
          bobp bolp eobp eolp char-before char-after point point-min
          point-max point-marker goto-char
          forward-line insert insert-and-inherit
          delete-region save-excursion message format
          line-beginning-position widen region-beginning region-end
          ;; `narrow-to-region' and `save-restriction' are `editfns.c`'s
          ;; here (`buffer.scm` is below them).
          narrow-to-region save-restriction)
    (only (schemacs editor indentc)
          current-column current-indentation indent-to move-to-column)
    (only (schemacs editor character) *tab-width*)
    (only (schemacs editor indent)
          indent-according-to-mode)
    (only (schemacs editor simple)
          delete-horizontal-space insert-newline back-to-indentation)
    (only (schemacs editor lisp-mode) indent-code-rigidly)
    (only (schemacs editor marker)
          make-marker set-marker copy-marker markerp marker-position
          set-marker-insertion-type)
    (only (schemacs editor newcomment)
          comment-start comment-end set!comment-start set!comment-end
          indent-for-comment)
    (only (schemacs editor search) looking-at match-end match-string
          string-match)
    (only (schemacs editor syntax)
          skip-chars-forward skip-chars-backward parse-partial-sexp
          scan-sexps char-syntax)
    (only (schemacs editor subr) run-hooks)
    (only (schemacs editor data) aref aset)
    ;; `c-progress-*' reads the clock (`(time-convert nil 'integer)').
    (only (schemacs editor timefns) current-time time-convert)
    (only (schemacs editor fns) concat)
    (only (schemacs editor font-lock) font-lock-mode-on?)
    (only (schemacs editor keyboard) sit-for)
    (only (schemacs editor xdisp) force-mode-line-update))

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
