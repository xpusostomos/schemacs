(define-library (schemacs editor font-core)
  ;; This library mirrors GNU Emacs's `lisp/font-core.el' - the *mode*
  ;; half of font-lock: `font-lock-mode` itself, the
  ;; `font-lock-function' it dispatches to, and the global mode. Emacs
  ;; split this out of `font-lock.el' so that a buffer could be fontified
  ;; without the engine being loaded; the split is why `font-lock-mode'
  ;; is *not* in `font-lock.sld', and why a mode's `font-lock-defaults'
  ;; can be read by the engine without the mode being defined yet.
  ;;
  ;; One thing about the split has to be said, because it decides where
  ;; the state lives. `font-lock-mode` is the minor mode *variable* and
  ;; the command here, and `*font-lock-mode*` - the variable - lives in
  ;; `font-lock.sld` instead, because `font-lock-after-change-function`
  ;; reads it and that library is *below* this one: `font-lock.el` cannot
  ;; import the half that imports it. The same goes for
  ;; `font-lock-defaults`, declared in this file in Emacs and read by
  ;; `font-lock-set-defaults` in the other. A library below holds the
  ;; state both halves share, which is the resolution
  ;; `*find-directory-functions*` gets in `files.sld`.
  ;;
  ;; Not ported, named rather than faked:
  ;;
  ;;   * **`char-property-alias-alist`** - `font-lock-default-function`
  ;;     makes `font-lock-face` an alias of the `face` property around
  ;;     every fontification, and `textprop.c` holds that alist
  ;;     (`Vchar_property_alias_alist`). This tree's text-property layer
  ;;     has no alias list, so the step is left out: a mode that
  ;;     fontifies with `font-lock-face` rather than `face` would draw
  ;;     nothing, and nothing here does.
  ;;   * **global Font Lock** - `font-lock-global-modes`,
  ;;     `global-font-lock-mode` and `turn-on-font-lock-if-desired`, the
  ;;     hook that turns the mode on as buffers are made.
  ;;   * **`font-lock-defontify`** - it clears every `font-lock-face`
  ;;     property in the buffer, which is the property the alias list
  ;;     above introduces.
  ;;   * **`noninteractive`** - the C's first act in `font-lock-mode` is
  ;;     to turn itself off in batch, and in a buffer whose name starts
  ;;     with a space. The name test is ported; there is no batch flag to
  ;;     read (the editor is always interactive).

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor buffer) buffer-name current-buffer buffer-list
          buffer-local-value set-buffer-local-value! with-current-buffer major-mode)
    (only (schemacs editor subr) add-hook remove-hook
          *after-change-major-mode-hook*)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor frame) *current-frame* set!frame-message)
    ;; `font-lock-mode` is a `define-minor-mode`, which is `easy-mmode.el`'s.
    (only (schemacs editor easy-mmode) define-minor-mode)
    (only (schemacs editor font-lock)
          font-lock-initial-fontify
          font-lock-mode-internal
          font-lock-mode-on?
          font-lock-specified-p
          set!font-lock-mode!))

  (export *font-lock-function* font-lock-change-mode
          font-lock-default-function font-lock-mode turn-on-font-lock
          global-font-lock-mode *font-lock-global-modes*
          turn-on-font-lock-if-desired font-lock-mode-enable-in-buffer)

  (begin

    (define *font-lock-function* (make-parameter #f))
    ;; ^ GNU Emacs's `font-lock-function', whose value is
    ;; `font-lock-default-function' - "you may specify your own function
    ;; which is called when `font-lock-mode' is toggled via
    ;; `font-lock-function'". It starts false and is filled below,
    ;; because the function it names is defined below.

    (define (font-lock-default-function mode)
      ;; GNU Emacs's `font-lock-default-function' (font-core.el:162):
      ;; what `font-lock-function''s default does when the mode is
      ;; toggled.
      ;;
      ;; The C's first act, on each branch, is the
      ;; `char-property-alias-alist` edit - left out here and named in
      ;; the library comment.
      ;;--------------------------------------------------------------
      (when (font-lock-specified-p mode)
        (font-lock-mode-internal mode)))

    (define (font-lock-change-mode)
      ;; GNU Emacs's `font-lock-change-mode' (font-core.el:146): "Get
      ;; rid of fontification for the old major mode." It is put on
      ;; `change-major-mode-hook' while the mode is on, which is the
      ;; hook's job and not this function's.
      ;;--------------------------------------------------------------
      (font-lock-mode -1))

    ;; **A `define-minor-mode`, as it is in Emacs** (`font-core.el:83`).
    ;; It used to be a hand-written command that echoed "Font-Lock mode
    ;; enabled" on *every* call, which is how opening a directory came to
    ;; say it: `dired-mode` ends with `(font-lock-mode #t)` and that is
    ;; not an interactive call, so Emacs's generated command - which
    ;; asks `called-interactively-p` - says nothing. The lighter, the
    ;; hook and the toggle rule now come from the macro rather than being
    ;; named as missing.
    ;;
    ;; Not carried, both because they need primitives this tree has not
    ;; got: `noninteractive` (the C's `(or noninteractive ...)` guard,
    ;; so only the invisible-name test is left) and the
    ;; `change-major-mode-hook` add/remove at the end of the body, which
    ;; is `add-hook`/`remove-hook` - there are none here.
    (define-minor-mode font-lock-mode
      "Toggle syntax highlighting in this buffer (Font Lock mode).

When Font Lock mode is enabled, text is fontified as you type it."
      :lighter " FL"
      :variable
      (lambda () (font-lock-mode-on?))
      (lambda (value) (set!font-lock-mode! (and value #t)))
      :after-hook (font-lock-initial-fontify)
      ;; "(when (or noninteractive (eq (aref (buffer-name) 0) ?\s))
      ;;    (setq font-lock-mode nil))" - "Don't turn on Font Lock mode
      ;; if ... the buffer is invisible (the name starts with a space)."
      (when (char=? (string-ref (buffer-name) 0) #\space)
        (set!font-lock-mode! #f))
      ;; "(funcall font-lock-function font-lock-mode)"
      ((*font-lock-function*) (font-lock-mode-on?)))

    (define (turn-on-font-lock)
      ;; GNU Emacs's `turn-on-font-lock' (font-core.el:190): "Turn on
      ;; Font Lock mode (only if the terminal can display it)."
      ;;
      ;; The C's `(unless font-lock-mode (font-lock-mode))' turns the mode
      ;; *on* when it is off - with no argument, `font-lock-mode` toggles,
      ;; and it has just established that the toggle is from off.
      ;;--------------------------------------------------------------
      (unless (font-lock-mode-on?)
        (font-lock-mode #t)))

    ;; `font-lock-function`'s default, which the C's `defvar` reaches
    ;; back for after `font-lock-default-function` is defined.
    (*font-lock-function* font-lock-default-function)

    ;;----------------------------------------------------------------
    ;; Global Font Lock mode
    ;;------------------------------------------------------------------

    (define-custom *font-lock-global-modes* #t
      "Modes for which Font Lock mode is automagically turned on.
Global Font Lock mode is controlled by the command
`global-font-lock-mode'."
      :type 'sexp
      :group 'font-lock)

    (define (turn-on-font-lock-if-desired)
      ;; GNU Emacs's `turn-on-font-lock-if-desired' (font-core.el:262).
      ;; `font-lock-global-modes` is t, `(not ...)` or a list of modes.
      ;;--------------------------------------------------------------
      (when (cond ((eq? (*font-lock-global-modes*) #t) #t)
                  ((and (pair? (*font-lock-global-modes*))
                        (eq? (car (*font-lock-global-modes*)) 'not))
                   (not (memq (major-mode) (cdr (*font-lock-global-modes*)))))
                  (else (memq (major-mode) (*font-lock-global-modes*))))
        (let ((*inhibit-quit* #t))
          (turn-on-font-lock))))

    (define *font-lock-mode--suppress-set-explicitly* (make-parameter #f))
    ;; ^ The macro's `MODE-suppress-set-explicitly`.

    (define (font-lock-mode--set-explicitly)
      ;; What `define-globalized-minor-mode` puts on `font-lock-mode-hook`:
      ;; a buffer whose mode hook turned the mode on or off by hand is
      ;; marked, and the global mode then leaves it alone.
      ;;--------------------------------------------------------------
      (unless (*font-lock-mode--suppress-set-explicitly*)
        (set-buffer-local-value! (current-buffer)
                                 'font-lock-mode--set-explicitly #t)))

    (define (font-lock-mode-enable-in-buffer)
      ;; GNU Emacs's `font-lock-mode-enable-in-buffer`, from the macro's
      ;; expansion (easy-mmode.el:624): "The function that calls TURN-ON
      ;; in the current buffer."
      ;;--------------------------------------------------------------
      (unless (buffer-local-value (current-buffer)
                                  'font-lock-mode--set-explicitly #f)
        (parameterize ((*font-lock-mode--suppress-set-explicitly* #t))
          (turn-on-font-lock-if-desired))))

    (define *global-font-lock-mode* (make-parameter #f))

    (define-command (global-font-lock-mode arg)
      "Toggle Font Lock mode in many buffers (Global Font Lock mode).

With a prefix argument ARG, enable Global Font Lock mode if ARG is
positive, and disable it otherwise."
      ;; **A plain command, where the C is a `define-globalized-minor-mode`.**
      ;; That macro is not ported (it builds five names from one symbol
      ;; and hangs its turn-on on `after-change-major-mode-hook`); what is
      ;; here is its expansion's body, and the interactive rule is
      ;; `define-minor-mode`'s - see `menu-bar-mode` for the same spelling.
      ;;--------------------------------------------------------------
      (interactive (list (or (current-prefix-arg) 'toggle)))
      (let ((value (if (eq? arg 'toggle)
                       (not (*global-font-lock-mode*))
                       (not (and (number? arg) (< arg 1))))))
        (*global-font-lock-mode* value)
        ;; "Setup hook to handle future mode changes and new buffers."
        (if value
            (add-hook *after-change-major-mode-hook*
                      font-lock-mode-enable-in-buffer)
            (remove-hook *after-change-major-mode-hook*
                         font-lock-mode-enable-in-buffer))
        ;; "Go through existing buffers."
        (for-each
         (lambda (buf)
           (with-current-buffer buf
             (if value
                 (turn-on-font-lock-if-desired)
                 (when (font-lock-mode-on?) (font-lock-mode -1)))))
         (buffer-list))
        #t))

    ;; The mode hook's marker: a buffer whose `font-lock-mode-hook` sets
    ;; the mode is not overridden by the global mode. The hook is the
    ;; parameter `define-minor-mode` made, so it is set by calling it.
    (font-lock-mode-hook
     (cons font-lock-mode--set-explicitly (font-lock-mode-hook)))

    ))
