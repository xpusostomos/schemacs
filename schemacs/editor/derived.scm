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
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor buffer)
          current-local-map kill-all-local-variables set!major-mode
          set!mode-name use-local-map)
    (only (schemacs editor command) register-command!)
    (only (schemacs editor keymap) keymap-parent set-keymap-parent)
    (only (schemacs editor subr) delay-mode-hooks run-mode-hooks)
    (only (schemacs editor syntax) set-syntax-table)
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
      ;;     (unless (keymap-parent CHILD-map)
      ;;       (set-keymap-parent CHILD-map (current-local-map)))
      ;;     (use-local-map CHILD-map)
      ;;     (set-syntax-table SYNTAX-TABLE)     ; when one is given
      ;;     BODY ...)
      ;;   (run-mode-hooks 'CHILD-hook)
      ;;
      ;; CHILD and PARENT are names, NAME is the string the mode line
      ;; shows, MAP and HOOK are the mode's keymap and its hook, and the
      ;; sixth element - when a mode has one of its own - is its syntax
      ;; table. Emacs's macro *makes* those names from CHILD; this one is
      ;; handed them, for the reason in the library comment above.
      ;;
      ;; PARENT is the parent mode's name, or `#f' for none - which is
      ;; Emacs's nil, and means the mode starts from
      ;; `kill-all-local-variables'.
      ;;
      ;; Not ported: the abbrev table argument (`:abbrev-table'), and
      ;; `:group', `:after-hook', `:interactive', the `mode-class'
      ;; property, and `derived-mode-make-docstring'.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ (child parent name map hook) docstring body ...)
         (begin
           (define (child)
             docstring
             (delay-mode-hooks
              (lambda ()
                (if parent (parent) (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
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
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook syntax) docstring body ...)
         (begin
           (define (child)
             docstring
             (delay-mode-hooks
              (lambda ()
                (if parent (parent) (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                (when syntax (set-syntax-table syntax))
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook syntax) body ...)
         (begin
           (define (child)
             (delay-mode-hooks
              (lambda ()
                (if parent (parent) (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                (when syntax (set-syntax-table syntax))
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))))

    ))