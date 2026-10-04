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
    (only (schemacs editor buffer) buffer-name)
    (only (schemacs editor frame) *current-frame* set!frame-message)
    (only (schemacs editor font-lock)
          font-lock-initial-fontify
          font-lock-mode-internal
          font-lock-mode-on?
          font-lock-specified-p
          set!font-lock-mode!))

  (export *font-lock-function* font-lock-change-mode
          font-lock-default-function font-lock-mode turn-on-font-lock)

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

    (define-command (font-lock-mode arg)
      ;; GNU Emacs's `font-lock-mode' (font-core.el:83): "Toggle syntax
      ;; highlighting in this buffer (Font Lock mode). ... When you turn
      ;; Font Lock mode on/off the buffer is fontified/defontified."
      ;;
      ;; A `define-minor-mode` in Emacs and a command toggling a variable
      ;; here, as `blink-cursor-mode` is: what `define-minor-mode` would
      ;; give it - the lighter in the mode line, the customize group,
      ;; `font-lock-mode-hook` - is named rather than faked. Its
      ;; `:after-hook (font-lock-initial-fontify)` is the one part that
      ;; *is* done, and it is the part that matters: it is what fontifies
      ;; the buffer the moment the mode comes on, rather than waiting for
      ;; the first edit.
      ;;
      ;; The C's `(when (or noninteractive (eq (aref (buffer-name) 0) ?\s))
      ;; (setq font-lock-mode nil))` is the name test alone here - see
      ;; the library comment.
      ;;--------------------------------------------------------------
      "Toggle syntax highlighting in this buffer (Font Lock mode)."
      (interactive (list (current-prefix-arg)))
      (let ((on? (cond ((not arg) (not (font-lock-mode-on?)))
                       ((pair? arg) #t)
                       ((number? arg) (> arg 0))
                       (else #t))))
        ;; "Don't turn on Font Lock mode if ... the buffer is invisible
        ;; (the name starts with a space)."
        (when (and on? (char=? (string-ref (buffer-name) 0) #\space))
          (set! on? #f))
        (set!font-lock-mode! on?)
        ((*font-lock-function*) on?)
        ;; the `:after-hook'
        (when on? (font-lock-initial-fontify))
        ;; "Emacs's `define-minor-mode' would echo this; the mode line
        ;; lighter it would also add is not implemented" - the words
        ;; `blink-cursor-mode' uses.
        (set!frame-message (*current-frame*)
                           (if on?
                               "Font-Lock mode enabled"
                               "Font-Lock mode disabled"))))

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

    ))
