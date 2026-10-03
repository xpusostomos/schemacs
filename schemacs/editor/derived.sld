(define-library (schemacs editor derived)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/derived.el' - the
  ;; macro a major mode is defined with, and the names it makes.
  ;;
  ;; One thing cannot be transcribed and is named rather than faked.
  ;; Emacs's macro builds its names from the mode's *symbol*: it defines
  ;; `CHILD-map', `CHILD-hook', `CHILD-syntax-table' and
  ;; `CHILD-abbrev-table' by concatenating, which is `derived-mode-map-name'
  ;; and its three siblings. There is no variable registry in this tree -
  ;; the same thing `xdisp.sld' notes about `mode-line-format' resolving a
  ;; symbol to nothing - so a symbol cannot be turned back into a
  ;; variable and the macro cannot invent those names. The caller names
  ;; the keymap and the hook instead, and the mode is defined the same
  ;; way otherwise:
  ;;
  ;;   (define-derived-mode (special-mode #f "Special" special-mode-map
  ;;                                      special-mode-hook)
  ;;     (set!buffer-read-only (current-buffer) #t))
  ;;
  ;; The four name helpers are still here, because they are what the
  ;; names *are* - a mode defined with the naming convention spelled out
  ;; gets the names Emacs would have given it.

  (import
    (scheme base)
    (scheme char)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor buffer)
          current-local-map kill-all-local-variables set!major-mode
          set!mode-name use-local-map)
    (only (schemacs editor command) register-command!)
    (only (schemacs editor keymap) keymap-parent set-keymap-parent)
    (only (schemacs editor subr) delay-mode-hooks run-mode-hooks)
    )

  (export
   define-derived-mode
   derived-mode-abbrev-table-name
   derived-mode-hook-name
   derived-mode-map-name
   derived-mode-syntax-table-name
   )

  (begin

    (define (derived-mode-map-name mode)
      ;; GNU Emacs's `derived-mode-map-name' (derived.el): the symbol
      ;; MODE's keymap is named by - `foo-mode' gives `foo-mode-map'.
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-map")))

    (define (derived-mode-hook-name mode)
      ;; GNU Emacs's `derived-mode-hook-name' (derived.el): "The hook
      ;; will be named `foo-mode-hook'" for `foo-mode'.
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-hook")))

    (define (derived-mode-syntax-table-name mode)
      ;; GNU Emacs's `derived-mode-syntax-table-name' (derived.el).
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-syntax-table")))

    (define (derived-mode-abbrev-table-name mode)
      ;; GNU Emacs's `derived-mode-abbrev-table-name' (derived.el).
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-abbrev-table")))

    (define-syntax define-derived-mode
      ;; GNU Emacs's `define-derived-mode' (derived.el:114): "Create a
      ;; new mode CHILD which is a variant of an existing mode PARENT."
      ;; The generated mode does what the C's does, in the C's order:
      ;;
      ;;   (delay-mode-hooks
      ;;     (PARENT)                    ; or `kill-all-local-variables'
      ;;     (setq major-mode 'CHILD)
      ;;     (setq mode-name NAME)
      ;;     ... the keymap's parent, the syntax table, the abbrev table
      ;;     (use-local-map CHILD-map)
      ;;     BODY ...)
      ;;   (run-mode-hooks 'CHILD-hook)
      ;;
      ;; PARENT is the parent mode's name, or `#f' for none - which is
      ;; Emacs's nil, and means the mode starts from
      ;; `kill-all-local-variables'.
      ;;
      ;; The keymap's inheritance is the C's own statement - "if the
      ;; parent mode has a keymap, set it as the child's parent, unless
      ;; it already has one" - and both functions are `keymap.c''s, now
      ;; in `(schemacs keymap)'.
      ;;
      ;; Not ported: the syntax table and abbrev table arguments
      ;; (`:syntax-table', `:abbrev-table') - neither exists here - and
      ;; `:group', `:after-hook' and `:interactive'.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ;; with the docstring Emacs's optional fourth argument allows
        ((_ (child parent name map hook) docstring body ...)
         (begin
           (define (child)
             docstring
             (delay-mode-hooks
              (lambda ()
                (if parent (parent) (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                ;; "Set up maps and tables": the child's keymap takes the
                ;; parent mode's as its *parent*, which is Emacs's
                ;; `(unless (keymap-parent ,map)
                ;;    (set-keymap-parent ,map (current-local-map)))'.
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
             ;; "Run the hooks (and delayed-after-hook-functions), if
             ;; any" - inside the mode, at its end, which is where the C
             ;; puts it: a mode run *outside* a `delay-mode-hooks' runs
             ;; its hook now, and one run inside a parent mode's
             ;; `delay-mode-hooks' has it run when that parent finishes.
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook) body ...)
         (begin
           (define (child)
             (delay-mode-hooks
              (lambda ()
                (if parent (parent) (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                ;; "Set up maps and tables": the child's keymap takes the
                ;; parent mode's as its *parent*, which is Emacs's
                ;; `(unless (keymap-parent ,map)
                ;;    (set-keymap-parent ,map (current-local-map)))'.
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))))

    ))