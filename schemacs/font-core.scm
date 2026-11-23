(define-library (schemacs font-core)
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
    ;; `*inhibit-quit*` is `turn-on-font-lock-if-desired`'s, whose C is a
    ;; `let` binding of it around the turn-on.
    ;; `current-prefix-arg` and `uarg->integer` are `define-minor-mode`'s:
    ;; the interactive form it generates reads them, and an interactive
    ;; expression is evaluated in the *defining* library's module.
    (only (schemacs command) *inhibit-quit*
          current-prefix-arg uarg->integer)
    (only (schemacs buffer) buffer-name current-buffer major-mode
          buffer-local-value set-buffer-local-value!)
    (only (schemacs custom) define-custom)
    ;; `char-property-alias-alist`'s edit is `copy-tree`/`nconc`/`remq`/
    ;; `delq` (`subr.el`) over `%assq` (`fns.c`), and its global default
    ;; is `textprop.c`'s variable, which `intervals` holds.
    (only (schemacs subr) copy-tree remq delq)
    (only (schemacs fns) %assq nconc)
    (only (schemacs intervals) *char-property-alias-alist*)
    (only (schemacs frame) *current-frame* set!frame-message)
    ;; `font-lock-mode` is a `define-minor-mode` and
    ;; `global-font-lock-mode` a `define-globalized-minor-mode`, both
    ;; `easy-mmode.el`'s.
    (only (schemacs core easy-mmode)
          define-minor-mode define-globalized-minor-mode)
    (only (schemacs font-lock)
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
      ;; The C's first act is the `char-property-alias-alist` edit, and
      ;; it is why `font-lock-face` is drawn at all: the buffer gets its
      ;; own `copy-tree` of the alist - the update below is destructive
      ;; and the global value must not move - and `font-lock-face` is
      ;; made a second name for `face`. `lookup-char-property` consults
      ;; the alist after a direct miss, so every mode that fontifies with
      ;; `font-lock-face` (dired, and every `font-lock-defaults` mode)
      ;; now draws those faces.
      ;;--------------------------------------------------------------
      (when mode
        (set-buffer-local-value!
         (current-buffer) 'char-property-alias-alist
         (copy-tree (buffer-local-value (current-buffer)
                                        'char-property-alias-alist
                                        (*char-property-alias-alist*))))
        ;; Add `font-lock-face' as an alias for the `face' property.
        (let ((elt (%assq 'face (buffer-local-value
                                 (current-buffer)
                                 'char-property-alias-alist))))
          (if elt
              (unless (memq 'font-lock-face (cdr elt))
                (set-cdr! elt (nconc (cdr elt) (list 'font-lock-face))))
              (set-buffer-local-value!
               (current-buffer) 'char-property-alias-alist
               (cons (list 'face 'font-lock-face)
                     (buffer-local-value (current-buffer)
                                         'char-property-alias-alist))))))
      ;; Turn off Font Lock mode: remove `font-lock-face' as an alias.
      (unless mode
        (set-buffer-local-value!
         (current-buffer) 'char-property-alias-alist
         (copy-tree (buffer-local-value (current-buffer)
                                        'char-property-alias-alist
                                        (*char-property-alias-alist*))))
        (let ((elt (%assq 'face (buffer-local-value
                                 (current-buffer)
                                 'char-property-alias-alist))))
          (when elt
            (set-cdr! elt (remq 'font-lock-face (cdr elt)))
            (when (null? (cdr elt))
              (set-buffer-local-value!
               (current-buffer) 'char-property-alias-alist
               (delq elt (buffer-local-value (current-buffer)
                                             'char-property-alias-alist)))))))
      ;; Only do hard work if the mode has specified stuff in
      ;; `font-lock-defaults'.
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
        ;; "(let (inhibit-quit) (turn-on-font-lock))" - a *binding* of nil,
        ;; so quitting is allowed while the fontification runs. Written as
        ;; a `let` over a parameter's name it would have been a new local
        ;; variable and not a binding at all, which is what it was here
        ;; until this pass; `parameterize` is the spelling that rebinds.
        (parameterize ((*inhibit-quit* #f))
          (turn-on-font-lock))))

    ;; **The macro, now that it is ported.** This was the hand-written
    ;; copy of its expansion - command, variable, hook, buffer walk - and
    ;; the file said so. What it bought by being hand-written was three
    ;; names nothing else wanted and a lighter-less command that said
    ;; nothing when a user switched it; what it costs is the five names
    ;; the macro generates under Emacs's own spelling
    ;; (`global-font-lock-mode-variable`, `font-lock-mode--set-explicitly`,
    ;; `font-lock-mode-enable-in-buffer`, ...), which is what Emacs has.
    ;;
    ;; `:init-value (not (or noninteractive emacs-basic-display))` - there
    ;; is no batch mode here and no basic display, so it is `#t`;
    ;; `startup.scm` still calls `(global-font-lock-mode 1)` where Emacs's
    ;; boot does, because the initial value alone does not install the
    ;; `after-change-major-mode-hook` entry.
    (define-globalized-minor-mode global-font-lock-mode
      font-lock-mode turn-on-font-lock-if-desired
      :init-value #t
      :group 'font-lock
      :version "22.1")

    ))
