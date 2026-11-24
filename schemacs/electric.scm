(define-library (schemacs electric)
  ;; This library mirrors GNU Emacs's `lisp/electric.el'. What is here
  ;; is the part CC Mode and the modes that use it connect to: the
  ;; electric-indentation machinery - `electric-indent-mode' and its
  ;; local variant, the two hooks, `electric-indent-inhibit' and the
  ;; post-self-insert function - and the C-j binding.
  ;;
  ;; **Not carried**, each with what it waits for:
  ;;
  ;;   * `Electric-command-loop' and `Electric-pop-up-window' - the
  ;;     obsolete pre-command-loop helpers. They need `ding',
  ;;     `sit-for' and `fit-window-to-buffer', none of which this tree
  ;;     has, and nothing in the modes this tree ports calls them.
  ;;
  ;;   * `electric-layout-mode' and its local variant - they need
  ;;     `pcase', which is not ported (the tree's ports have rewritten
  ;;     Emacs's `pcase' sites by hand so far; porting the pattern
  ;;     matcher is a tranche of its own).
  ;;
  ;;   * `electric-quote-mode' and its local variant - `pcase' again,
  ;;     and `define-widget' for the two widgets its defcustom uses.
  ;;
  ;;   * `electric-indent--yank-advice' - `advice.el' is not ported.
  ;;     `electric-indent-actions' accepts `yank', but with this
  ;;     absence a `yank' entry has no effect; the `before-save' entry
  ;;     works, because it is a hook.
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
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p kill-local-variable buffer-read-only?
          buffer-list with-current-buffer call-with-buffer-local)
    (only (schemacs character) kbd)
    (only (schemacs command)
          define-command *last-command-event* current-prefix-arg
          uarg->integer quit-condition?)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs custom) define-custom)
    (only (schemacs cmds) *post-self-insert-hook*)
    (only (schemacs data) default-value default-boundp set-default)
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion line-beginning-position
          char-before bolp eolp message)
    (only (schemacs files)
          save-buffer *before-save-hook* *after-save-hook*)
    (only (schemacs intervals) get)
    (only (schemacs keymap) define-key *default-keymap*)
    (only (schemacs indent)
          indent-according-to-mode indent-region indent-line-function
          indent-relative indent-relative-maybe
          indent-relative-first-indent-point indent-to-left-margin)
    (only (schemacs marker) copy-marker)
    (only (schemacs simple)
          *real-this-command* insert-newline newline-and-indent
          delete-horizontal-space)
    (only (schemacs subr)
          add-hook remove-hook run-hooks run-hook-with-args-until-success)
    (only (schemacs syntax) skip-chars-backward))

  (export
   electric--after-char-pos
   *electric-indent-actions* electric-indent-chars
   *electric-indent-functions*
   electric-indent-inhibit set!electric-indent-inhibit
   electric-indent-functions-without-reindent
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

    ;; `electric-indent-chars' is a `defvar' (a plain variable), and
    ;; Emacs writes its one element `?\n' - the integer 10, which is
    ;; what `last-command-event' holds here too.
    (define electric-indent-chars (list 10))

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

    (define electric-indent-functions-without-reindent
      ;; GNU Emacs's list holds symbols, because Emacs resolves a
      ;; function through an obarray; here `indent-line-function' holds
      ;; the procedures themselves. `yaml-indent-line' has no
      ;; counterpart (there is no yaml mode), which is the one name
      ;; Emacs's list has that this one does not.
      (list indent-relative indent-to-left-margin indent-relative-maybe
            indent-relative-first-indent-point))

    (define (electric-indent-can-reindent-p)
      ;; Return t if `electric-indent-mode' can perform reindentation.
      ;;--------------------------------------------------------------
      (not (or (memq (indent-line-function)
                     electric-indent-functions-without-reindent)
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
                                          electric-indent-chars))))
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

    ;; Emacs is dumped with the mode on and its `post-self-insert-hook'
    ;; entry in place (`electric-indent-mode`'s `:init-value t`; in a
    ;; `-Q --batch' Emacs the entry is already there before the file is
    ;; required). This tree has no dump, so loading the library is where
    ;; the same state is made. A non-interactive call echoes nothing.
    (electric-indent-mode 1)))
