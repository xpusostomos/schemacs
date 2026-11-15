(define-library (schemacs editor text-mode)
  ;; This library mirrors GNU Emacs's `lisp/textmodes/text-mode.el' - the
  ;; mode most modes for human-readable text derive from, and the syntax
  ;; table that makes `M-c' on 'hello' give 'Hello' rather than 'hello'.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `paragraph-indent-text-mode' and `paragraph-indent-minor-mode' -
  ;;     they need `add-function'/`remove-function' (`nadvice.el') and
  ;;     `indent-to-left-margin'.
  ;;   * `text-mode-context-menu' - the right-button menus.
  ;;   * `text-mode-ispell-word-completion' and the completion-at-point
  ;;     hook: there is no ispell here.
  ;;   * `text-conversion-style' - no input method.

  (import
    (scheme base)
    (scheme char)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer) current-buffer set-buffer-local-value!)
    (only (schemacs editor syntax) modify-syntax-entry)
    (only (schemacs editor subr) make-syntax-table)
    (only (schemacs editor files) *mode-require-final-newline*))

  (export text-mode text-mode-map text-mode-hook text-mode-syntax-table
          text-mode-hook-identify
          text-mode-variant)

  (begin

    (define (setq-local name value)
      ;; What `(setq-local NAME VALUE)' does - see lisp-mode's copy.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (current-buffer) name value))

    (define text-mode-syntax-table
      ;; GNU Emacs's `text-mode-syntax-table' (text-mode.el:50).
      ;;--------------------------------------------------------------
      (let ((st (make-syntax-table)))
        (modify-syntax-entry #\" ".   " st)
        (modify-syntax-entry #\\ ".   " st)
        ;; "We add `p' so that M-c on 'hello' leads to 'Hello' rather
        ;; than 'hello'."
        (modify-syntax-entry #\' "w p" st)
        ;; "UAX #29 says HEBREW PUNCTUATION GERESH behaves like a letter
        ;; for the purposes of finding word boundaries."
        (modify-syntax-entry (integer->char #x5f3) "w   " st) ; GERESH
        (modify-syntax-entry (integer->char #x5f4) "w   " st) ; GERSHAYIM
        (modify-syntax-entry (integer->char #xb7) "w   " st)  ; MIDDLE DOT
        (modify-syntax-entry (integer->char #x2027) "w   " st) ; HYPHENATION
        (modify-syntax-entry (integer->char #xff1a) "w   " st) ; FULLWIDTH :
        st))

    (define text-mode-map (km:keymap '*text-mode-map*))

    (define (text-mode-hook-identify)
      ;; GNU Emacs's `text-mode-hook-identify' (text-mode.el:196): "Mark
      ;; that this mode has run `text-mode-hook'."
      ;;--------------------------------------------------------------
      (setq-local 'text-mode-variant #t))

    (define text-mode-hook
      ;; GNU Emacs's `text-mode-hook' (text-mode.el:34): "Normally
      ;; non-nil defaults for hooks are bad, but since this file is
      ;; preloaded it's ok/better."
      (list text-mode-hook-identify))

    (define-derived-mode (text-mode #f "Text" text-mode-map text-mode-hook
                                    text-mode-syntax-table)
      "Major mode for editing text written for humans to read.
In this mode, paragraphs are delimited only by blank or white lines.
You can thus get the full benefit of adaptive filling
 (see the variable `adaptive-fill-mode').
Turning on Text mode runs the normal hook `text-mode-hook'."
      (setq-local 'text-mode-variant #t)
      (setq-local 'require-final-newline (*mode-require-final-newline*)))

    ))
