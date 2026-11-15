(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor frame) *current-frame* new-frame selected-window)
 (only (schemacs editor buffer)
       allocate-buffer buffer-local-value current-buffer get-buffer-create
       set-buffer set-buffer-local-value! with-current-buffer)
 (only (schemacs editor data)
       default-boundp default-value set-default)
 (only (schemacs editor subr)
       *after-change-major-mode-hook* run-hooks)
 (only (schemacs editor intervals) get)
 (only (schemacs editor easy-mmode)
       define-minor-mode define-globalized-minor-mode
       easy-mmode-pretty-mode-name)
 (only (schemacs editor xdisp) *mode-line-window* mode-line-window-selected-p))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Regression tests for `(schemacs editor easy-mmode)` - the two macros
;; that write a mode's boilerplate - and for the two primitives the
;; second of them rests on: `default-value`/`set-default` (`data.c`'s
;; global value) and `mode-line-window-selected-p` (`bindings.el`'s face
;; picker, which `tab-line.el` asks when it draws a tab).
;;
;; Every expectation is the behaviour of GNU Emacs 31.1's `easy-mmode.el`
;; read against the same definitions, because the macros *are* the
;; specification: what a `define-minor-mode` with `:global t` does is what
;; `(default-value ',mode)` and `(setq-default ,mode ...)` do.

(*current-frame* (new-frame (allocate-buffer) 24 80))

;;----------------------------------------------------------------
;; `default-value`, `set-default` and `default-boundp`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_easy_mmode_data")

(test-equal "an unbound variable answers the caller's default"
            'fallback
            (default-value 'easy-mmode-test-unbound 'fallback))

(test-assert "and is not bound"
             (not (default-boundp 'easy-mmode-test-unbound)))

(set-default 'easy-mmode-test-var 1)

(test-equal "set-default stores the default" 1 (default-value 'easy-mmode-test-var))

(test-assert "which is then bound" (default-boundp 'easy-mmode-test-var))

;; A stored nil is a *value*, and `default-boundp` must tell it from an
;; absent entry - which is why the table is read with
;; `hashq-get-handle` and not `hashq-ref`.
(set-default 'easy-mmode-test-var #f)

(test-assert "a stored nil is still bound" (default-boundp 'easy-mmode-test-var))

(test-equal "and reads back as nil, not as the caller's default"
            #f
            (default-value 'easy-mmode-test-var 'fallback))

(test-end "schemacs_editor_easy_mmode_data")

;;----------------------------------------------------------------
;; `define-minor-mode`, buffer-local and `:global`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_easy_mmode")

(define-minor-mode em-test-local-mode
  "A buffer-local probe."
  :lighter " PL")

(define-minor-mode em-test-global-mode
  "A global probe."
  :global #t)

(set-buffer (get-buffer-create "em-one"))
(set-buffer-local-value! (current-buffer) 'em-test-local-mode #f)

(em-test-local-mode 1)

(test-equal "a buffer-local mode's variable lives in the buffer"
            #t
            (em-test-local-mode-variable))

;; The same variable read from another buffer is its own.
(set-buffer (get-buffer-create "em-two"))

(test-equal "and is not the other buffer's"
            #f
            (em-test-local-mode-variable))

(set-buffer (get-buffer-create "em-one"))

(test-equal "the first buffer still has it"
            #t
            (em-test-local-mode-variable))

(em-test-local-mode -1)

(test-equal "a negative argument disables" #f (em-test-local-mode-variable))

(test-equal "and the command answers the new setting"
            #t
            (em-test-local-mode 'toggle))

;; `:global` keeps one value for every buffer, which is `setq-default` and
;; `(default-value ',mode)` in the C.
(set-buffer (get-buffer-create "em-one"))
(em-test-global-mode 1)

(test-equal "a global mode is on in the buffer that switched it"
            #t
            (em-test-global-mode-variable))

(set-buffer (get-buffer-create "em-two"))

(test-equal "and in one that did not" #t (em-test-global-mode-variable))

(em-test-global-mode -1)

(test-equal "disabling it disables it everywhere" #f (em-test-global-mode-variable))

;; `:init-value` is the answer before anything sets the variable, which is
;; the C's `(default-value ',mode)` straight after the `defcustom`.
(define-minor-mode em-test-init-mode
  "A global probe with an initial value."
  :global #t
  :init-value #t)

(test-equal "a global mode reads its :init-value"
            #t
            (em-test-init-mode-variable))

;; `easy-mmode-pretty-mode-name`, which both macros name their messages
;; with.
(test-equal "a mode name loses its -mode and gains a capital"
            "Overwrite mode"
            (easy-mmode-pretty-mode-name 'overwrite-mode))

(test-equal "Global-Foo gets a space"
            "Global Foo mode"
            (easy-mmode-pretty-mode-name 'global-foo-mode))

(test-end "schemacs_editor_easy_mmode")

;;----------------------------------------------------------------
;; `define-globalized-minor-mode`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_easy_mmode_globalized")

(define-minor-mode em-test-minor-mode
  "The buffer-local half of a globalized pair."
  :lighter " PM")

(define (em-test-turn-on) (em-test-minor-mode 1))

(define-globalized-minor-mode global-em-test-mode
  em-test-minor-mode em-test-turn-on)

(test-assert "the global mode is recorded as globalized"
             (get 'global-em-test-mode 'globalized-minor-mode))

(test-equal "the global command is off to start with"
            #f
            (global-em-test-mode-variable))

(test-equal "and the minor mode is off in the current buffer"
            #f
            (em-test-minor-mode-variable))

(set-buffer (get-buffer-create "em-g-one"))

(global-em-test-mode 1)

(test-equal "switching it on turns the minor mode on in an existing buffer"
            #t
            (em-test-minor-mode-variable))

(test-equal "and installs one after-change-major-mode-hook entry"
            1
            (length (*after-change-major-mode-hook*)))

;; A buffer made after the switch is thrown: the hook is what reaches it.
;; `get-buffer-create` does not run a major mode, so the hook is run the
;; way `set-auto-mode` runs it.
(with-current-buffer (get-buffer-create "em-g-two")
  (run-hooks (*after-change-major-mode-hook*)))

(test-equal "a new buffer gets the minor mode when its major mode is set"
            #t
            (em-test-minor-mode-variable))

;; A buffer whose major mode hook turned the mode off by hand keeps it
;; off: `MODE--set-explicitly`, which the macro puts on the minor mode's
;; hook.
(set-buffer (get-buffer-create "em-g-three"))
(set-buffer-local-value! (current-buffer)
                         'em-test-minor-mode--set-explicitly #t)
(run-hooks (*after-change-major-mode-hook*))

(test-equal "a buffer that refused it keeps it off"
            #f
            (em-test-minor-mode-variable))

(global-em-test-mode -1)

(test-equal "switching it off removes the hook entry"
            0
            (length (*after-change-major-mode-hook*)))

(test-equal "and turns the minor mode off in the buffers it was on in"
            #f
            (with-current-buffer (get-buffer-create "em-g-one")
              (em-test-minor-mode-variable)))

(test-end "schemacs_editor_easy_mmode_globalized")

;;----------------------------------------------------------------
;; `mode-line-window-selected-p`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_easy_mmode_mode_line")

;; The renderer binds `*mode-line-window*' to the window it is formatting,
;; which is the C's rebinding of `selected-window' around
;; `display_mode_lines'.
(test-assert "the selected window's mode line is the selected one"
             (parameterize ((*mode-line-window* (selected-window)))
               (mode-line-window-selected-p)))

(test-assert "an unknown window is not"
             (parameterize ((*mode-line-window* 'some-window))
               (not (mode-line-window-selected-p))))

(test-assert "and neither is no window at all"
             (parameterize ((*mode-line-window* #f))
               (not (mode-line-window-selected-p))))

(test-end "schemacs_editor_easy_mmode_mode_line")
