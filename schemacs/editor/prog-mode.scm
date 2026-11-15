(define-library (schemacs editor prog-mode)
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
  ;;   * `prog-indent-sexp' (C-M-q) and `prog-fill-reindent-defun' (M-q) -
  ;;     they are `forward-sexp', `beginning-of-defun'/`end-of-defun' and
  ;;     `fill-paragraph', and the first of those is syntax.c's
  ;;     `scan_sexps_forward' half this tree has not ported. The mode's
  ;;     keymap is therefore empty, and is defined so the names exist.
  ;;   * `prettify-symbols-mode' and everything under it - `compose-region'
  ;;     and the display engine's composition table.
  ;;   * `text-conversion-style' and `bidi-paragraph-direction': there is no
  ;;     input method and no bidirectional display here, so the two
  ;;     buffer-locals would be read by nothing. `parse-sexp-ignore-comments'
  ;;     is stored for the same reason `setq-local' stores it in Emacs -
  ;;     the scanner that reads it (`back_comment') is not ported yet.

  (import
    (scheme base)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer) current-buffer set-buffer-local-value!)
    ;; `fundamental-mode' is simple.el's, and it is the parent
    (only (schemacs editor simple) fundamental-mode)
    (only (schemacs editor files) *mode-require-final-newline*)
    (only (schemacs editor custom) define-custom))

  (export prog-mode prog-mode-map prog-mode-hook
          *prog-indentation-context* prog-first-column)

  (begin

    (define prog-mode-map
      ;; GNU Emacs's `prog-mode-map', which `define-derived-mode' makes for
      ;; the mode below. Emacs binds C-M-q and M-q in it; neither command
      ;; can be carried yet (see this library's header), so it carries no
      ;; keys - and is still the map the mode is defined with.
      ;;--------------------------------------------------------------
      (km:keymap '*prog-mode-map*))

    (define prog-mode-hook '())
    ;; ^ GNU Emacs's `prog-mode-hook', made by `define-derived-mode'.

    (define-custom *prog-indentation-context* #f
      "When non-nil, provides context for indenting embedded code chunks."
      :type 'list
      :group 'prog-mode)
    ;; ^ GNU Emacs's `prog-indentation-context'.

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
