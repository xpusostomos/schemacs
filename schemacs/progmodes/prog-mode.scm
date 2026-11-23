(define-library (schemacs progmodes prog-mode)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/prog-mode.el' - the
  ;; generic major mode every programming mode derives from, so that a
  ;; user can hang generic customisation on `prog-mode-hook'.
  ;;
  ;; What is *not* here, each named against the thing it waits for, rather
  ;; than a "faithful subset" that stops the next person asking:
  ;;
  ;;   * `prog-context-menu' and its `context-menu-functions' entry - the
  ;;     right-button menus, the `xref' commands they are built from, and
  ;;     `thing-at-mouse'; none of those exists here.
  ;;   * `prog-indent-sexp' (C-M-q) and `prog-fill-reindent-defun' (M-q)
  ;;     **are carried** (2026-11-17), with `prog--text-at-point-p' and
  ;;     `prog-fill-reindent-defun-function'. That is why this library
  ;;     sits *above* `fill`, `lisp`, `indent` and `newcomment` here,
  ;;     where Emacs's `prog-mode.el` needs nothing at load time: the
  ;;     commands call `fill-paragraph', `forward-sexp' and
  ;;     `indent-region', and a binding must come after the command it
  ;;     binds. `lisp-mode` and `scheme` import this library and are
  ;;     unaffected - neither is imported by anything named here.
  ;;   * `prettify-symbols-mode' and everything under it - `compose-region'
  ;;     and the display engine's composition table.
  ;;   * `text-conversion-style' and `bidi-paragraph-direction': there is no
  ;;     input method and no bidirectional display here, so the two
  ;;     buffer-locals would be read by nothing. `parse-sexp-ignore-comments'
  ;;     is stored for the same reason `setq-local' stores it in Emacs -
  ;;     the scanner that reads it (`back_comment') is not ported yet.

  (import
    (scheme base)
    (prefix (schemacs keymap) km:)
    (only (schemacs core derived) define-derived-mode)
    (only (schemacs buffer) current-buffer set-buffer-local-value!)
    ;; `fundamental-mode' is simple.el's, and it is the parent
    (only (schemacs simple) fundamental-mode use-region-p mark)
    (only (schemacs files) *mode-require-final-newline*)
    (only (schemacs custom) define-custom)
    ;; The two commands, and what they call.
    (only (schemacs command)
          define-command current-prefix-arg uarg->integer)
    (only (schemacs subr) nth kbd)
    (only (schemacs editfns)
          goto-char line-end-position point pos-eol save-excursion)
    (only (schemacs cmds) beginning-of-line end-of-line)
    (only (schemacs syntax) syntax-ppss)
    (only (schemacs search) re-search-forward)
    (only (schemacs newcomment) comment-start-skip)
    (only (schemacs core lisp)
          beginning-of-defun end-of-defun forward-sexp)
    (only (schemacs indent) indent-region)
    (only (schemacs textmodes fill) fill-paragraph))

  (export prog-mode prog-mode-map prog-mode-hook
          *prog-indentation-context* prog-first-column
          prog-indent-sexp prog-fill-reindent-defun
          prog-fill-reindent-defun-default prog-fill-reindent-defun-function
          ;; Emacs spells these with the `--` internal prefix, and they
          ;; are exported here so the suite can ask them directly - the
          ;; same reason `M-x prog--text-at-point-p` works in Emacs.
          prog--text-at-point-p prog--text-at-point-or-region-p)

  (begin

    (define prog-mode-map
      ;; GNU Emacs's `prog-mode-map', which `define-derived-mode' makes for
      ;; the mode below. Its two keys are defined at the bottom of this
      ;; file, after the commands they bind - a `define-key` holds the
      ;; command's *value*, and Emacs's `defvar-keymap` here can name
      ;; functions it has not defined yet.
      ;;--------------------------------------------------------------
      (km:keymap '*prog-mode-map*))

    (define prog-mode-hook '())
    ;; ^ GNU Emacs's `prog-mode-hook', made by `define-derived-mode'.

    (define-custom *prog-indentation-context* #f
      "When non-nil, provides context for indenting embedded code chunks."
      :type 'list
      :group 'prog-mode)
    ;; ^ GNU Emacs's `prog-indentation-context'.

    (define-command (prog-indent-sexp . rest)
      ;; GNU Emacs's `prog-indent-sexp' (`prog-mode.el:131').
      ;;--------------------------------------------------------------
      "Indent the expression after point.
When interactively called with prefix, indent the enclosing defun
instead."
      (interactive "P")
      (let ((defun (and (pair? rest) (car rest))))
        (save-excursion
          (when defun
            (end-of-line)
            (beginning-of-defun))
          (let ((start (point))
                (end (begin (forward-sexp 1) (point))))
            (indent-region start end #f)))))

    (define (prog--text-at-point-p)
      ;; GNU Emacs's `prog--text-at-point-p' (`prog-mode.el:144'):
      ;; "Return non-nil if point is in text (comment or string)."
      ;;
      ;; The C's own comment on the middle arm: "If point is at the
      ;; beginning of a comment delimiter, `syntax-ppss' doesn't consider
      ;; point as being inside a comment."
      ;;--------------------------------------------------------------
      (or (nth 8 (syntax-ppss))
          (save-excursion
            (beginning-of-line)
            (and (comment-start-skip)
                 (re-search-forward (comment-start-skip) (pos-eol) #t)
                 (nth 8 (syntax-ppss))))
          (save-excursion
            (beginning-of-line)
            (and (re-search-forward "\\s-*\\s<" (line-end-position) #t)
                 (nth 8 (syntax-ppss))))))

    (define (prog--text-at-point-or-region-p)
      ;; GNU Emacs's `prog--text-at-point-or-region-p'
      ;; (`prog-mode.el:169'): "Return non-nil if point or region's
      ;; other end are in text."
      ;;--------------------------------------------------------------
      (or (prog--text-at-point-p)
          (and (use-region-p)
               (save-excursion
                 (goto-char (mark))
                 (prog--text-at-point-p)))))

    (define prog-fill-reindent-defun-function #f)
    ;; ^ GNU Emacs's `prog-fill-reindent-defun-function'
    ;; (`prog-mode.el:177'): "Function called by
    ;; `prog-fill-reindent-defun' to do the actual work." Its `defvar'
    ;; default is `#'prog-fill-reindent-defun-default' - a forward
    ;; reference here, exactly as `normal-auto-fill-function' was in
    ;; `fill.scm', so it is set below the definition - after the
    ;; docstring, which is where a `set!` naming it can first resolve.

    (define-command (prog-fill-reindent-defun-default . rest)
      ;; GNU Emacs's `prog-fill-reindent-defun-default'
      ;; (`prog-mode.el:182').
      ;;--------------------------------------------------------------
      "Default implementation of `prog-fill-reindent-defun'.
JUSTIFY is the same as in `fill-paragraph'."
      (interactive "P")
      (let ((justify (and (pair? rest) (car rest))))
        (save-excursion
          (if (prog--text-at-point-or-region-p)
              (fill-paragraph justify (use-region-p))
              ;; Elisp's `if' takes several ELSE forms; this is one.
              (begin
                (beginning-of-defun)
                (let ((start (point)))
                  (end-of-defun)
                  (indent-region start (point) #f)))))))

    ;; The `defvar`'s initial value, now that its function exists.
    (set! prog-fill-reindent-defun-function prog-fill-reindent-defun-default)

    (define-command (prog-fill-reindent-defun . rest)
      ;; GNU Emacs's `prog-fill-reindent-defun' (`prog-mode.el:194').
      ;;--------------------------------------------------------------
      "Refill or reindent the paragraph or defun that contains point.

If the point is in a string or a comment, fill the paragraph that
contains point or follows point.

Otherwise, reindent the function definition that contains point
or follows point.

If JUSTIFY is non-nil (interactively, with prefix argument), justify as
well."
      (interactive "P")
      (let ((justify (and (pair? rest) (car rest))))
        (prog-fill-reindent-defun-function justify)))

    ;; The two keys, defined *after* their commands: a `define-key' here
    ;; holds the command's value, and Emacs's `defvar-keymap' could name
    ;; functions it had not defined yet.
    (km:define-key prog-mode-map (kbd "C-M-q") prog-indent-sexp)
    (km:define-key prog-mode-map (kbd "M-q") prog-fill-reindent-defun)

    (define (prog-first-column)
      ;; GNU Emacs's `prog-first-column': "Return the indentation column
      ;; normally used for top-level constructs."
      ;;--------------------------------------------------------------
      (or (car (*prog-indentation-context*)) 0))

    (define-derived-mode (prog-mode fundamental-mode "Prog" prog-mode-map
                                    prog-mode-hook)
      "Major mode for editing programming language source code."
      ;; "(setq-local require-final-newline mode-require-final-newline)"
      (set-buffer-local-value! (current-buffer) 'require-final-newline
                               (*mode-require-final-newline*))
      ;; "(setq-local parse-sexp-ignore-comments t)"
      (set-buffer-local-value! (current-buffer) 'parse-sexp-ignore-comments
                               #t))

    ))
