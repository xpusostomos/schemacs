(define-library (schemacs electric)
  ;; This library mirrors GNU Emacs's `lisp/electric.el': the
  ;; electric-indentation machinery (`electric-indent-mode' and its
  ;; local variant), `electric-layout-mode' and `electric-quote-mode'
  ;; with theirs, and the C-j binding. Every mode has its defgroup
  ;; (`electricity') and the defcustoms Emacs declares.
  ;;
  ;; **Not carried**, each with what it waits for:
  ;;
  ;;   * `Electric-command-loop' and `Electric-pop-up-window' - the
  ;;     obsolete pre-command-loop helpers. `ding` and `sit-for` exist
  ;;     now, so the loop's own needs are met; what is missing is
  ;;     `command-execute` (this tree's equivalent is the command
  ;;     loop's `dispatch-action`, which takes a frame) and, for
  ;;     `Electric-pop-up-window`, `fit-window-to-buffer` and
  ;;     `window-text-pixel-size`. Nothing this tree ports calls
  ;;     either function.
  ;;
  ;;   * `electric-indent--yank-advice' - `advice.el' is not ported.
  ;;     `electric-indent-actions' accepts `yank', but with this
  ;;     absence a `yank' entry has no effect; the `before-save' entry
  ;;     works, because it is a hook.
  ;;
  ;;   * The two `define-widget' forms `electric-quote-mode' declares
  ;;     (`electric-char-pair', `electric-quote-chars-pairs') and
  ;;     `electric--print-list-of-chars': they need the widget library
  ;;     and `print-integers-as-characters', which are the Customize
  ;;     tranche's. The defcustom's `:type' is carried as data and a
  ;;     simplified type; its Customize rendering waits for that tranche.
  ;;
  ;; **`electric-layout-allow-duplicate-newlines' is a parameter**
  ;; (the tree's test for one is whether ported Elisp `let`-binds it);
  ;; `elec-pair.scm` binds it to t around its own insert.
  ;;
  ;; **`real-this-command' is `*real-this-command*'** (`simple.scm',
  ;; set by the command loop), and the save command list names
  ;; `save-buffer' alone: Emacs's second entry, `basic-save-buffer', is
  ;; a function this tree folds into `save-buffer'.
  ;;
  ;; **The `electric-indent-actions' `:set' reaches the function that
  ;; takes effect through a forward variable**, because the defcustom
  ;; comes before that function in Emacs's file order and a Scheme
  ;; procedure must exist when the clause is read. The variable is set
  ;; to the procedure at the end of that function's definition.

  (import
    (scheme base)
    (only (guile) catch throw)
    (only (ice-9 control) let/ec)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p kill-local-variable buffer-read-only?
          buffer-list with-current-buffer call-with-buffer-local)
    (only (schemacs character) kbd)
    (only (schemacs command)
          define-command *last-command-event* current-prefix-arg
          uarg->integer quit-condition?)
    (only (schemacs core derived) derived-mode-p)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs core pcase) pcase)
    (only (schemacs custom) define-custom defgroup)
    (only (schemacs cmds) *post-self-insert-hook* backward-char delete-char)
    (only (schemacs data) default-value default-boundp set-default)
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion line-beginning-position
          char-before char-after bobp bolp eolp message)
    (only (schemacs files)
          save-buffer *before-save-hook* *after-save-hook*)
    (only (schemacs fns) nth)
    (only (schemacs intervals) get)
    (only (schemacs keymap) define-key *default-keymap*)
    (only (schemacs indent)
          indent-according-to-mode indent-region indent-line-function
          indent-relative indent-relative-maybe
          indent-relative-first-indent-point indent-to-left-margin)
    (only (schemacs marker) copy-marker)
    (only (schemacs newcomment) comment-start comment-use-syntax)
    (only (schemacs search) search-backward replace-match)
    (only (schemacs simple)
          *real-this-command* insert-newline newline-and-indent
          delete-horizontal-space)
    (only (schemacs subr)
          add-hook remove-hook run-hooks run-hook-with-args-until-success)
    (only (schemacs syntax)
          skip-chars-backward skip-syntax-backward char-syntax syntax-ppss))

  (export
   electric--after-char-pos
   *electric-indent-actions* *electric-quote-chars*
   *electric-indent-chars* electric-indent-chars set!electric-indent-chars
   *electric-layout-allow-duplicate-newlines*
   *electric-layout-allow-in-comment-or-string*
   electric-layout-rules set!electric-layout-rules
   *electric-layout-rules* electric-layout-mode-value
   electric-layout-post-self-insert-function
   electric-layout-post-self-insert-function-1
   electric-layout-mode electric-layout-mode-hook
   electric-layout-local-mode electric-layout-local-mode-hook
   *electric-pair-text-pairs-function* *electric-pair-newline-binder*
   *electric-quote-comment* *electric-quote-string*
   *electric-quote-paragraph* *electric-quote-context-sensitive*
   *electric-quote-replace-double* *electric-quote-replace-consecutive*
   *electric-quote-inhibit-functions*
   electric-quote-mode-value electric-quote-post-self-insert-function
   electric-quote-mode electric-quote-mode-hook
   electric-quote-local-mode electric-quote-local-mode-hook
   *electric-indent-functions*
   electric-indent-inhibit set!electric-indent-inhibit
   *electric-indent-functions-without-reindent*
   electric-indent-can-reindent-p
   electric-indent--activate-indent-actions
   electric-indent-save-hook
   electric-indent-post-self-insert-function
   electric-indent-just-newline
   electric-newline-and-maybe-indent
   electric-indent-mode electric-indent-mode-hook
   electric-indent-mode-value
   electric-indent-local-mode electric-indent-local-mode-hook)

  (begin

    (defgroup electricity ()
      "Electric behavior for self inserting keys."
      :group 'editing)

    (define (electric--after-char-pos)
      ;; Return the position after the char we just inserted.
      ;; Returns nil when we can't find this char.
      ;;
      ;; `last-command-event' is an integer and `char-before' a
      ;; character, so the C's `eq' is an integer comparison here.
      ;;--------------------------------------------------------------
      (let ((pos (point))
            (event (*last-command-event*)))
        (if (or (and (char-before) (= (char->integer (char-before)) event))
                (save-excursion
                  (or (begin
                        (skip-chars-backward " \t")
                        (set! pos (point))
                        (and (char-before)
                             (= (char->integer (char-before)) event)))
                      (begin
                        (skip-chars-backward " \n\t")
                        (set! pos (point))
                        (and (char-before)
                             (= (char->integer (char-before)) event))))))
            pos
            #f)))

    ;; The value of `electric-indent-mode' in the current buffer: a
    ;; buffer-local binding wins over the global default, which is what
    ;; Emacs's `(bound-and-true-p electric-indent-mode)' reads once the
    ;; mode's variable exists (the defcustom below is declared before
    ;; the mode, so it can be unbound).
    (define (electric-indent-mode-value)
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'electric-indent-mode buffer))
            (buffer-local-value buffer 'electric-indent-mode)
            (default-value 'electric-indent-mode #f))))

    ;; `electric-indent--activate-indent-actions' is defined below, in
    ;; the file's order; a `:set' clause is an expression.
    (define %electric-indent--activate-actions #f)

    ;;--------------------------------------------------------------
    ;; Electric indentation.
    ;;--------------------------------------------------------------

    (define-custom *electric-indent-actions* '()
      "List of `electric-indent-mode' actions that can reindent.

The valid elements of this list can be:
 - `yank': Indent the yanked text only if point is not in a string or
         comment and yanked region is longer than 1 line.
 - `before-save': Indent the whole buffer before saving it.

The indentation will not happen when the major mode is unable to
reindent code reliably, such as in buffers where indentation is
significant."
      :type '(repeat (choice (const :tag "After yanking" yank)
                             (const :tag "Before saving" before-save)))
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (when (and %electric-indent--activate-actions
                        (electric-indent-mode-value))
               (%electric-indent--activate-actions #t)))
      :version "31.1" :group 'electricity)

    ;; `electric-indent-chars' is a plain `defvar' in Emacs, but major
    ;; modes `setq-local' it (groovy-mode appends its braces and commas,
    ;; cc-mode adds `;' and `{'), so the reader must consult the buffer.
    ;; The tree's spelling for that is the parameter + buffer-local pair:
    ;; `(electric-indent-chars)' reads, `set!electric-indent-chars'
    ;; writes. The default's one element is `?\n' - the integer 10, which
    ;; is what `last-command-event' holds here too.
    (define *electric-indent-chars* (make-parameter (list 10)))
    (define (electric-indent-chars)
      (buffer-local-value (current-buffer) *electric-indent-chars*
                          (*electric-indent-chars*)))
    (define (set!electric-indent-chars value)
      (set-buffer-local-value! (current-buffer) *electric-indent-chars* value))

    (define *electric-indent-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `electric-indent-functions' (`electric.el:230'):
    ;; "Special hook run to decide whether to auto-indent. ... Each
    ;; function is called with one argument (the inserted char), with
    ;; point right after that char, and it should return t to cause
    ;; indentation, `no-indent' to prevent indentation or nil to let
    ;; other functions decide."

    (define *electric-indent-inhibit* (make-parameter #f))
    (define (electric-indent-inhibit)
      ;; GNU Emacs's `electric-indent-inhibit' (`electric.el:236'), a
      ;; `defvar-local`: the buffer's slot first, the default second.
      (buffer-local-value (current-buffer) *electric-indent-inhibit*
                          (*electric-indent-inhibit*)))
    (define (set!electric-indent-inhibit value)
      (set-buffer-local-value! (current-buffer) *electric-indent-inhibit* value))

    ;; `electric-quote-chars' is `electric.el:641''s defcustom - the
    ;; curved quote pairs `electric-pair-pairs' and
    ;; `electric-pair-text-pairs' are built from, which is why it is
    ;; here even though `electric-quote-mode' itself is not carried.
    ;; The widget-based `:type' is simplified: the values are characters.
    (define-custom *electric-quote-chars* (list #\‘ #\’ #\“ #\”)
      "Curved quote characters for `electric-quote-mode'.
This list's members correspond to left single quote, right single
quote, left double quote, and right double quote, respectively.

When `electric-quote-mode' is enabled, as you type it replaces \\=` with
the first element of this list, \\=' with the second element, \\=`\\=`
with the third, and \\='\\=' with the fourth.  This occurs only in
comments, strings, and text paragraphs, and these are selectively
controlled with `electric-quote-comment', `electric-quote-string', and
`electric-quote-paragraph'."
      :version "26.1" :type '(repeat character) :group 'electricity)

    (define electric-layout-allow-duplicate-newlines #f)
    ;; ^ GNU Emacs's `electric-layout-allow-duplicate-newlines'
    ;; (`electric.el:453'), a plain `defvar'. Emacs's
    ;; `electric-pair--insert' `let'-binds it to t so that adding a
    ;; closer does not munch the newlines; **that binding is omitted
    ;; here** because a plain variable has no dynamic binding this tree
    ;; can make. **`electric-layout-mode' itself is not ported** (it is
    ;; the third of electric.el's modes, after indent and pair), so the
    ;; variable is carried for shape and has no reader.

    (define-custom *electric-indent-functions-without-reindent*
      (list indent-relative indent-to-left-margin indent-relative-maybe
            indent-relative-first-indent-point)
      "List of indent functions that can't reindent.
If `indent-line-function' is one of those, then `electric-indent-mode' will
not try to reindent lines.  It is normally better to make the major
mode set `electric-indent-inhibit', but this can be used as a workaround."
      :type '(repeat function)
      :group 'electricity)
    ;; ^ GNU Emacs's `electric-indent-functions-without-reindent'
    ;; (`electric.el:237') is a plain `defvar`; it is user-settable, so
    ;; it is a define-custom here (the same category departure as
    ;; `electric-layout-rules`). Emacs's list holds symbols, because
    ;; Emacs resolves a function through an obarray; here
    ;; `indent-line-function' holds the procedures themselves.
    ;; `yaml-indent-line' has no counterpart (there is no yaml mode),
    ;; which is the one name Emacs's list has that this one does not.

    (define (electric-indent-can-reindent-p)
      ;; Return t if `electric-indent-mode' can perform reindentation.
      ;;--------------------------------------------------------------
      (not (or (memq (indent-line-function)
                     (*electric-indent-functions-without-reindent*))
               (electric-indent-inhibit))))

    (define (electric-indent-save-hook)
      (when (and (electric-indent-mode-value)
                 ;; Ensure this hook is called interactively
                 (memq (*real-this-command*) (list save-buffer))
                 (memq 'before-save (*electric-indent-actions*))
                 (not (buffer-read-only? (current-buffer)))
                 (electric-indent-can-reindent-p))
        (save-excursion
          (guard (ex
                  ((quit-condition? ex) (raise ex))
                  (else (message "Error reindenting: %s" ex)))
            (indent-region (point-min) (point-max))))))

    (define (electric-indent--activate-indent-actions enable)
      ;; If ENABLE is non-nil, enable the actions in
      ;; `electric-indent-actions'. If ENABLE is nil, disable them.
      ;;
      ;; `(advice-remove 'yank #'electric-indent--yank-advice)' and the
      ;; matching `advice-add' are not carried: advice.el is not
      ;; ported, so the `yank' action does nothing here (named in the
      ;; library header).
      ;;--------------------------------------------------------------
      (remove-hook *before-save-hook* electric-indent-save-hook)
      (when enable
        (when (memq 'before-save (*electric-indent-actions*))
          (add-hook *before-save-hook* electric-indent-save-hook))))

    (set! %electric-indent--activate-actions
          electric-indent--activate-indent-actions)

    (define (electric-indent-post-self-insert-function)
      ;; Function that `electric-indent-mode' adds to
      ;; `post-self-insert-hook'. This indents if the hook
      ;; `electric-indent-functions' returns non-nil, or if a member of
      ;; `electric-indent-chars' was typed; but not in a string or
      ;; comment.
      ;;--------------------------------------------------------------
      (let ((pos #f))
        (when (and (electric-indent-mode-value)
                   ;; Don't reindent while inserting spaces at beginning
                   ;; of line.
                   (or (not (memv (*last-command-event*) (list 32 9)))
                       (save-excursion (skip-chars-backward " \t") (not (bolp))))
                   (begin (set! pos (electric--after-char-pos)) pos)
                   (save-excursion
                     (goto-char pos)
                     (let ((act (or (run-hook-with-args-until-success
                                     (*electric-indent-functions*)
                                     (*last-command-event*))
                                    (memv (*last-command-event*)
                                          (electric-indent-chars)))))
                       (not (or (not act) (eq? act 'no-indent))))))
          ;; If we error during indent, silently give up since this is
          ;; an automatic action that the user didn't explicitly
          ;; request. But we don't want to suppress errors from
          ;; elsewhere in *this* function, hence the `condition-case'
          ;; and `throw' (Bug#18764).
          (catch 'indent-error
            (lambda ()
              ;; For newline, we want to reindent both lines and
              ;; basically behave like
              ;; reindent-then-newline-and-indent (whose code we hence
              ;; copied).
              (let ((at-newline (<= pos (line-beginning-position))))
                (when at-newline
                  (let ((before (copy-marker (- pos 1) #t)))
                    (save-excursion
                      (when (electric-indent-can-reindent-p)
                        ;; Don't reindent the previous line if the
                        ;; indentation function is not a real one.
                        (goto-char before)
                        (guard (ex
                                ((quit-condition? ex) (raise ex))
                                (else (throw 'indent-error #f)))
                          (indent-according-to-mode)))
                      (unless (eq? (electric-indent-inhibit)
                                   'electric-layout-mode)
                        ;; Unless we're operating under
                        ;; `electric-layout-mode' (Bug#35254), the goal
                        ;; here will be to remove the trailing
                        ;; whitespace after reindentation of the
                        ;; previous line because that may have
                        ;; (re)introduced it.
                        (goto-char before)
                        ;; We were at EOL in marker `before' before the
                        ;; call to `indent-according-to-mode' but after
                        ;; we may not be (Bug#15767).
                        (when (eolp)
                          (delete-horizontal-space #t))))))
                (unless (and (electric-indent-inhibit) (not at-newline))
                  (guard (ex
                          ((quit-condition? ex) (raise ex))
                          (else (throw 'indent-error #f)))
                    (indent-according-to-mode)))))
            (lambda (key . args) #f)))))

    (define-command (electric-indent-just-newline arg)
      "Insert just a newline, without any auto-indentation."
      (interactive "*P")
      ;; `(let ((electric-indent-mode nil)) ...)': the mode's variable
      ;; is the buffer's (local or global) value, so the dynamic
      ;; binding is the buffer-local one `call-with-buffer-local' makes
      ;; and takes away.
      (call-with-buffer-local
       'electric-indent-mode #f
       (lambda ()
         (insert-newline arg 'interactive))))

    (define-command (electric-newline-and-maybe-indent)
      "Insert a newline.
If `electric-indent-mode' is enabled, that's that, but if it
is *disabled* then additionally indent according to major mode.
Indentation is done using the value of `indent-line-function'.
In programming language modes, this is the same as TAB.
In some text modes, where TAB inserts a tab, this command indents to the
column specified by the function `current-left-margin'."
      (interactive "*")
      (if (electric-indent-mode-value)
          (electric-indent-just-newline #f)
          (newline-and-indent)))

    ;; `(define-key global-map "\C-j" 'electric-newline-and-maybe-indent)'
    ;; (`electric.el:389'). `simple.scm' binds C-j to `insert-newline'
    ;; as a default; this binding is the loading of electric.el, which
    ;; is what turns it into Emacs's command.
    (define-key *default-keymap* (kbd "C-j")
      electric-newline-and-maybe-indent)

    (define-minor-mode electric-indent-mode
      "Toggle on-the-fly reindentation of text lines (Electric Indent mode).

When enabled, this reindents whenever the hook `electric-indent-functions'
returns non-nil, or if you insert one of the \"electric characters\".
The electric characters normally include the newline, but can
also include other characters as needed by the major mode; see
`electric-indent-chars' for the actual list.

By \"reindent\" we mean remove any existing indentation, and then
indent the line according to context and rules of the major mode.

This is a global minor mode.  To toggle the mode in a single buffer,
use `electric-indent-local-mode'."
      :global #t
      :init-value #t
      :variable (lambda () (electric-indent-mode-value))
                (lambda (value) (set-default 'electric-indent-mode value))
      (if (not (electric-indent-mode-value))
          (unless (catch 'found
                    (lambda ()
                      (for-each
                       (lambda (buf)
                         (with-current-buffer buf
                           (if (electric-indent-mode-value)
                               (throw 'found #t))))
                       (buffer-list))
                      #f)
                    (lambda (key . args)
                      (and (pair? args) (car args))))
            (remove-hook *post-self-insert-hook*
                         electric-indent-post-self-insert-function))
          (add-hook *post-self-insert-hook*
                    electric-indent-post-self-insert-function
                    60))
      ;; Toggle the reindentation on actions
      (electric-indent--activate-indent-actions (electric-indent-mode-value)))

    (define-minor-mode electric-indent-local-mode
      "Toggle `electric-indent-mode' only in this buffer."
      :variable (lambda () (electric-indent-mode-value))
                (lambda (value)
                  (set-buffer-local-value! (current-buffer)
                                           'electric-indent-mode
                                           value))
      (cond
       ((eq? (electric-indent-mode-value)
             (default-value 'electric-indent-mode #f))
        (kill-local-variable 'electric-indent-mode))
       ((not (default-value 'electric-indent-mode #f))
        ;; Locally enabled, but globally disabled.
        (electric-indent-mode 1)                 ; Setup the hooks.
        (set-default 'electric-indent-mode #f))  ; But keep it globally disabled.
       (else #f)))


    ;;----------------------------------------------------------------
    ;; Electric newlines after/before/around some chars
    ;; (`electric.el:422').
    ;;----------------------------------------------------------------

    (define-custom *electric-layout-rules* #f
      "List of rules saying where to automatically insert newlines.

These rules control the behavior of `electric-layout-mode'.

Each rule has the form (CHAR . WHERE), the rule matching if the
character just inserted was CHAR.  WHERE specifies where to
insert newlines, and can be:

* one of the symbols `before', `after', `around', `after-stay',
  or nil.

* a list of the preceding symbols, processed in order of
  appearance to insert multiple newlines;

* a function of no arguments that returns one of the previous
  values.

Each symbol specifies where, in relation to the position POS of
the character inserted, the newline character(s) should be
inserted.  `after-stay' means insert a newline after POS but stay
in the same place.

Instead of the (CHAR . WHERE) form, a rule can also be just a
function of a single argument, the character just inserted.  It
is called at that position, and should return a value compatible with
WHERE if the rule matches, or nil if it doesn't match.

If multiple rules match, only the first one is executed."
      :type '(repeat (cons character sexp))
      :group 'electricity)
    ;; ^ GNU Emacs's `electric-layout-rules' (`electric.el:422') is a
    ;; `defvar' with its own "TODO: Make this a defcustom?" - and major
    ;; modes `setq-local' it (js, typescript, php, octave), so a plain
    ;; global would be wrong twice over. **A define-custom with
    ;; buffer-local accessors**, the `page-delimiter' pattern: the
    ;; parameter is the default and the buffer's slot wins when a mode
    ;; sets one.
    ;;
    ;; Making it a defcustom is a departure from Emacs's *category*
    ;; (`custom-variable-p` answers t here where Emacs says nil), taken
    ;; because a user-configurable variable has to be a parameter: a
    ;; plain define is folded by the compiler and a user's `set!` is
    ;; then invisible in a compiled build.

    (define (electric-layout-rules)
      (buffer-local-value (current-buffer) *electric-layout-rules*
                          (*electric-layout-rules*)))
    (define (set!electric-layout-rules value)
      (set-buffer-local-value! (current-buffer) *electric-layout-rules* value))

    (define *electric-layout-allow-duplicate-newlines* (make-parameter #f))
    ;; ^ GNU Emacs's `electric-layout-allow-duplicate-newlines'
    ;; (`electric.el:453'). **A parameter**, because `electric-pair--insert`
    ;; `let`-binds it to t; the convention's test for a parameter is
    ;; exactly whether ported Elisp `let`-binds it.

    (define-custom *electric-layout-allow-in-comment-or-string* #f
      "Non-nil means `electric-layout-mode' works inside comments and strings.
Otherwise the mode leaves comments and strings alone."
      :type 'boolean
      :group 'electricity)
    ;; ^ Emacs's `electric-layout-allow-in-comment-or-string'
    ;; (`electric.el:457') is a plain `defvar'; it is a user option, so
    ;; here it is a define-custom (the same category departure as
    ;; `electric-layout-rules` above).

    (define (electric-layout-mode-value)
      ;; The value of the global minor mode in the current buffer: the
      ;; buffer-local slot wins over the default store (the same shape
      ;; `elec-pair.scm`'s `electric-pair-mode-value` has).
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'electric-layout-mode buffer))
            (buffer-local-value buffer 'electric-layout-mode #f)
            (default-value 'electric-layout-mode #f))))

    (define *electric-pair-newline-binder* (make-parameter (lambda (thunk) (thunk))))
    ;; ^ The seam for `electric-pair-open-newline-between-pairs' - a
    ;; variable `elec-pair.el` owns and `electric.el` `let`-binds
    ;; (`electric.el:482`). `elec-pair.scm` installs a thunk that binds
    ;; its parameter; this library, which that one imports, cannot.

    (define (electric-layout-post-self-insert-function)
      ;; `electric.el:461'.
      ;;--------------------------------------------------------------
      (when (electric-layout-mode-value)
        (electric-layout-post-self-insert-function-1)))

    (define (electric-layout-post-self-insert-function-1)
      ;; `electric.el:468': insert newlines around the character just
      ;; inserted, according to `electric-layout-rules'.
      ;;--------------------------------------------------------------
      (let* ((pos (electric--after-char-pos))
             (rule
              ;; **The `#f` after the walk is load-bearing**: Emacs's
              ;; `catch` answers nil when nothing throws, and a Scheme
              ;; `when`/`let` that falls through answers the
              ;; *unspecified* value - which is true. Without it every
              ;; ordinary character found a "rule".
              (let/ec done
                (when pos
                  (let loop ((rest (electric-layout-rules)))
                    (when (pair? rest)
                      (let ((probe (car rest)))
                        (cond
                         ((and (pair? probe)
                               (= (car probe) (*last-command-event*)))
                          (done (cdr probe)))
                         ((procedure? probe)
                          (let ((res (save-excursion
                                       (goto-char pos)
                                       (probe (*last-command-event*)))))
                            (when res (done res))))))
                      (loop (cdr rest)))))
                #f)))
        (when (and rule
                   (or (*electric-layout-allow-in-comment-or-string*)
                       ;; Not in a comment or string.
                       (not (nth 8 (save-excursion (syntax-ppss pos))))))
          (goto-char pos)
          (when (procedure? rule) (set! rule (rule)))
          (let* ((nl-after
                 (lambda ()
                   ;; `electric.el:481`: the `newline` here re-runs
                   ;; `post-self-insert-hook`, so `electric-layout-mode`
                   ;; and `electric-pair-open-newline-between-pairs` are
                   ;; bound off around it - this tree's dynamic binding
                   ;; for a global mode and a seam for the pair variable.
                   (call-with-buffer-local
                    'electric-layout-mode #f
                    (lambda ()
                      ((*electric-pair-newline-binder*)
                       (lambda () (insert-newline 1 #t)))))))
                (nl-before
                 (lambda ()
                   (save-excursion
                     (goto-char (- pos 1))
                     ;; Normally, we don't duplicate newlines, but when
                     ;; we're being called for i.e. a closer brace for
                     ;; `electric-pair-mode' generally make sense.
                     (unless (and (not (*electric-layout-allow-duplicate-newlines*))
                                  (begin
                                    (skip-chars-backward " \t")
                                    (bolp)))
                       ;; `electric.el:536`: `electric-indent-inhibit`
                       ;; is bound to `electric-layout-mode` so the new
                       ;; line is not re-indented. The variable is the
                       ;; buffer-local accessor pair, so the binding is
                       ;; the buffer-local one, keyed by its parameter.
                       (call-with-buffer-local
                        *electric-indent-inhibit* 'electric-layout-mode
                        nl-after))))))
            (for-each
             (lambda (sym)
               (case sym
                 ((before) (nl-before))
                 ((after) (nl-after))
                 ((after-stay) (save-excursion (nl-after)))
                 ((around) (nl-before) (nl-after))
                 (else #f)))
             (if (symbol? rule) (list rule) rule))))))

    (define-minor-mode electric-layout-mode
      "Automatically insert newlines around some chars.

The variable `electric-layout-rules' says when and how to insert newlines."
      :global #t
      :variable (lambda () (electric-layout-mode-value))
                (lambda (value) (set-default 'electric-layout-mode value))
      (if (electric-layout-mode-value)
          (add-hook *post-self-insert-hook*
                    electric-layout-post-self-insert-function
                    40)
          (remove-hook *post-self-insert-hook*
                       electric-layout-post-self-insert-function)))

    (define-minor-mode electric-layout-local-mode
      "Toggle `electric-layout-mode' only in this buffer."
      :variable (lambda () (electric-layout-mode-value))
                (lambda (value)
                  (set-buffer-local-value! (current-buffer)
                                           'electric-layout-mode value))
      (cond
       ((eq? (electric-layout-mode-value)
             (default-value 'electric-layout-mode #f))
        (kill-local-variable 'electric-layout-mode))
       ((not (default-value 'electric-layout-mode #f))
        ;; Locally enabled, but globally disabled.
        (electric-layout-mode 1)               ; Setup the hooks.
        (set-default 'electric-layout-mode #f)) ; But keep it globally disabled.
       (else #f)))

    ;;----------------------------------------------------------------
    ;; Electric quoting (`electric.el:575').
    ;;----------------------------------------------------------------

    (define-custom *electric-quote-comment* #t
      "Non-nil means `electric-quote-mode' acts in program comments.
Otherwise, the mode leaves program comments alone."
      :version "25.1" :type 'boolean :group 'electricity)

    (define-custom *electric-quote-string* #f
      "Non-nil means `electric-quote-mode' acts in program strings.
Otherwise, the mode leaves program strings alone."
      :version "25.1" :type 'boolean :group 'electricity)

    (define *electric-quote-inhibit-functions* (make-parameter '()))
    ;; ^ `electric-quote-inhibit-functions' (`electric.el:707') is a
    ;; `defvar' run as a hook; a hook users `add-hook' to is a parameter
    ;; here (the convention: `add-hook` takes the hook object).

    (define-custom *electric-quote-paragraph* #t
      "Non-nil means `electric-quote-mode' acts in text paragraphs.
Otherwise, the mode leaves text paragraphs alone."
      :version "25.1" :type 'boolean :group 'electricity)

    (define-custom *electric-quote-context-sensitive* #f
      "Non-nil means to replace \\=' with an electric quote depending on context.
If `electric-quote-context-sensitive' is non-nil and `electric-quote-mode'
is enabled, as you type Emacs replaces \\=' and \\='\\=' with an opening
quote after a line break, whitespace, opening parenthesis, or quote and
leaves \\=` alone.

The replacing quote character is defined by `electric-quote-chars'."
      :version "26.1" :type 'boolean :group 'electricity)

    (define-custom *electric-quote-replace-double* #f
      "Non-nil means to replace \" with an electric double quote.
If `electric-quote-replace-double' is non-nil and `electric-quote-mode'
is enabled, as you type Emacs replaces \" with an opening double quote
after a line break, whitespace, opening parenthesis, or quote, and with
a closing double quote otherwise.

The replacing double quote characters are defined by
`electric-quote-chars'."
      :version "26.1" :type 'boolean :group 'electricity)

    (define-custom *electric-quote-replace-consecutive* #t
      "Non-nil means to replace a pair of single quotes with a double quote."
      :version "29.1" :type 'boolean :group 'electricity)

    ;; `electric-pair-text-pairs' is `elec-pair.el`'s, and that library
    ;; imports this one (for `electric--after-char-pos` and the quote
    ;; pairs), so this library cannot import it back. The seam: a thunk
    ;; returning the alist, installed by `elec-pair.scm` as it loads.
    (define *electric-pair-text-pairs-function*
      (make-parameter (lambda () '())))

    (define (%electric-pair-mode-value)
      ;; `electric-pair-mode`'s value, read the way its own accessor in
      ;; `elec-pair.scm` reads it: the buffer-local slot wins over the
      ;; global default. **No import is needed** - the value lives in the
      ;; default/buffer-local store, which is this tree's spelling of
      ;; Emacs's special variable.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'electric-pair-mode buffer))
            (buffer-local-value buffer 'electric-pair-mode #f)
            (default-value 'electric-pair-mode #f))))

    (define (electric-quote-mode-value)
      ;; The value of the global mode in the current buffer.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'electric-quote-mode buffer))
            (buffer-local-value buffer 'electric-quote-mode #f)
            (default-value 'electric-quote-mode #f))))

    (define (electric-quote-post-self-insert-function)
      "Function that `electric-quote-mode' adds to `post-self-insert-hook'.
This requotes when a quoting key is typed."
      ;; `electric.el:719'.
      ;;--------------------------------------------------------------
      (when (and (electric-quote-mode-value)
                 (or (= (*last-command-event*) 39)      ; ?\'
                     (and (not (*electric-quote-context-sensitive*))
                          (= (*last-command-event*) 96)) ; ?\`
                     (and (*electric-quote-replace-double*)
                          (= (*last-command-event*) 34))) ; ?\"
                 (not (run-hook-with-args-until-success
                       (*electric-quote-inhibit-functions*)))
                 (if (derived-mode-p 'text-mode)
                     (*electric-quote-paragraph*)
                     (and (comment-start) (comment-use-syntax)
                          (or (*electric-quote-comment*)
                              (*electric-quote-string*))
                          (let* ((syntax (syntax-ppss))
                                 (beg (nth 8 syntax)))
                            (and beg
                                 (or (and (*electric-quote-comment*)
                                          (nth 4 syntax))
                                     (and (*electric-quote-string*)
                                          (nth 3 syntax)))
                                 ;; Do not requote a quote that starts or
                                 ;; ends a comment or string.
                                 (eq? beg (nth 8 (save-excursion
                                                   (syntax-ppss (- (point) 1))))))))))
        (pcase (*electric-quote-chars*)
          (`(,q< ,q> ,q<< ,q>>)
           (save-excursion
             (let ((backtick #\`))
               (if (or (= (*last-command-event*) 96)
                       (and (or (*electric-quote-context-sensitive*)
                                (and (*electric-quote-replace-double*)
                                     (= (*last-command-event*) 34)))
                            (save-excursion
                              (backward-char)
                              (skip-syntax-backward "\\")
                              (or (bobp) (bolp)
                                  (memv (char-before) (list q< q<<))
                                  (memv (char-syntax (char-before))
                                        (list #\space #\())))
                            (begin (set! backtick #\') #t)))
                   (cond
                    ((and (*electric-quote-replace-consecutive*)
                          (search-backward (string q< backtick)
                                           (- (point) 2) #t))
                     (replace-match (string q<<))
                     (when (and (%electric-pair-mode-value)
                                (let ((cell (assq (char->integer q<)
                                                  ((*electric-pair-text-pairs-function*)))))
                                  (and cell
                                       (eqv? (cdr cell)
                                             (and (char-after)
                                                  (char->integer (char-after)))))))
                       (delete-char 1))
                     (*last-command-event* (char->integer q<<)))
                    ((search-backward (string backtick) (- (point) 1) #t)
                     (replace-match (string q<))
                     (*last-command-event* (char->integer q<)))
                    ((search-backward "\"" (- (point) 1) #t)
                     (replace-match (string q<<))
                     (*last-command-event* (char->integer q<<))))
                   (cond
                    ((and (*electric-quote-replace-consecutive*)
                          (search-backward (string q> #\') (- (point) 2) #t))
                     (replace-match (string q>>))
                     (*last-command-event* (char->integer q>>)))
                    ((search-backward "'" (- (point) 1) #t)
                     (replace-match (string q>))
                     (*last-command-event* (char->integer q>)))
                    ((search-backward "\"" (- (point) 1) #t)
                     (replace-match (string q>>))
                     (*last-command-event* (char->integer q>>)))))))
           (*last-command-event*))
          (_ #f))))

    (define-minor-mode electric-quote-mode
      "Toggle on-the-fly requoting (Electric Quote mode).

When enabled, as you type this replaces \\=` with \\=‘, \\=' with \\=’,
\\=`\\=` with “, and \\='\\=' with ”.  This occurs only in comments, strings,
and text paragraphs, and these are selectively controlled with
`electric-quote-comment', `electric-quote-string', and
`electric-quote-paragraph'.

This is a global minor mode.  To toggle the mode in a single buffer,
use `electric-quote-local-mode'."
      :global #t
      :init-value #f
      :variable (lambda () (electric-quote-mode-value))
                (lambda (value) (set-default 'electric-quote-mode value))
      (if (not (electric-quote-mode-value))
          (unless (let/ec found
                    (for-each
                     (lambda (buf)
                       (with-current-buffer buf
                         (if (electric-quote-mode-value) (found #t))))
                     (buffer-list))
                    #f)
            (remove-hook *post-self-insert-hook*
                         electric-quote-post-self-insert-function))
          (add-hook *post-self-insert-hook*
                    electric-quote-post-self-insert-function
                    10)))

    (define-minor-mode electric-quote-local-mode
      "Toggle `electric-quote-mode' only in this buffer."
      :variable (lambda () (electric-quote-mode-value))
                (lambda (value)
                  (set-buffer-local-value! (current-buffer)
                                           'electric-quote-mode value))
      (cond
       ((eq? (electric-quote-mode-value)
             (default-value 'electric-quote-mode #f))
        (kill-local-variable 'electric-quote-mode))
       ((not (default-value 'electric-quote-mode #f))
        ;; Locally enabled, but globally disabled.
        (electric-quote-mode 1)               ; Setup the hooks.
        (set-default 'electric-quote-mode #f)) ; But keep it globally disabled.
       (else #f)))

    ;; Emacs is dumped with the mode on and its `post-self-insert-hook'
    ;; entry in place (`electric-indent-mode`'s `:init-value t`; in a
    ;; `-Q --batch' Emacs the entry is already there before the file is
    ;; required). This tree has no dump, so loading the library is where
    ;; the same state is made. A non-interactive call echoes nothing.
    (electric-indent-mode 1)))
