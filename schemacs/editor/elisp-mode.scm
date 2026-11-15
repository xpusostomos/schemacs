(define-library (schemacs editor elisp-mode)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/elisp-mode.el' -
  ;; `emacs-lisp-mode' and `lisp-interaction-mode', their syntax table
  ;; and keymaps, and the syntax-propertize function the mode installs.
  ;;
  ;; Emacs 31 keeps `emacs-lisp-mode' in `elisp-mode.el' and the keyword
  ;; tables it uses in `lisp-mode.el'; both files have a library here,
  ;; and this one is the mode.
  ;;
  ;; Not carried, each named against what it waits for:
  ;;
  ;;   * `elisp-mode-syntax-propertize' and its rules - `syntax-
  ;;     propertize-rules', the macro, is not ported.
  ;;   * the eldoc, xref, flymake, completion-at-point, electric-pair and
  ;;     context-menu entries the mode adds to their hooks: none of those
  ;;     subsystems exists here.
  ;;   * the `lexical-binding' mode-line construct
  ;;     (`elisp-enable-lexical-binding' and its mouse map): the mode line
  ;;     is a list of `mode-line-format' constructs here and this one is
  ;;     a `:propertize' form, which the renderer does not read.
  ;;   * `eval-defun', `elisp-eval-region-or-buffer' and the byte/native
  ;;     compilation commands - `eval-region' exists, `eval-defun' does
  ;;     not.

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor buffer) current-buffer)
    (only (schemacs editor syntax) modify-syntax-entry)
    (only (schemacs editor subr) make-syntax-table)
    (only (schemacs editor lisp-mode) lisp-data-mode lisp-data-mode-syntax-table
          lisp-mode-shared-map lisp-mode-variables)
    (only (schemacs editor custom) define-custom))

  (export emacs-lisp-mode emacs-lisp-mode-map emacs-lisp-mode-hook
          emacs-lisp-mode-syntax-table
          lisp-interaction-mode lisp-interaction-mode-map
          lisp-interaction-mode-hook)

  (begin

    (define emacs-lisp-mode-syntax-table
      ;; GNU Emacs's `emacs-lisp-mode-syntax-table' (elisp-mode.el:41):
      ;; `lisp-data-mode-syntax-table' with the "p" flag taken off `@',
      ;; because `,@' is handled precisely by `syntax-propertize' there.
      ;; (That function is not ported here; the flag is still off, which
      ;; is the table Emacs's mode has.)
      ;;--------------------------------------------------------------
      (let ((table (make-syntax-table lisp-data-mode-syntax-table)))
        (modify-syntax-entry #\@ "_" table)
        table))

    (define emacs-lisp-mode-map
      ;; GNU Emacs's `emacs-lisp-mode-map' (elisp-mode.el:50). The keys
      ;; whose commands exist here are bound; the rest are named in this
      ;; library's header.
      ;;--------------------------------------------------------------
      (km:keymap '*emacs-lisp-mode-map*))

    (define emacs-lisp-mode-hook '())

    (define-custom *emacs-lisp-mode-hook* '()
      "Hook run when entering Emacs Lisp mode."
      :type 'hook
      :group 'lisp)

    (define-derived-mode (emacs-lisp-mode lisp-data-mode "Elisp"
                                          emacs-lisp-mode-map
                                          emacs-lisp-mode-hook
                                          emacs-lisp-mode-syntax-table)
      "Major mode for editing Lisp code to run in Emacs."
      ;; "(lisp-mode-variables nil nil t)" - LISP-SYNTAX nil keeps the
      ;; table the parent mode set, KEYWORDS-CASE-INSENSITIVE nil (Elisp
      ;; keywords are case sensitive), ELISP t.
      (lisp-mode-variables #f #f #t))

    (define lisp-interaction-mode-map
      ;; GNU Emacs's `lisp-interaction-mode-map' (elisp-mode.el:1756).
      ;;--------------------------------------------------------------
      (km:keymap '*lisp-interaction-mode-map*))

    (define lisp-interaction-mode-hook '())

    (define-derived-mode (lisp-interaction-mode emacs-lisp-mode
                                                "Lisp Interaction"
                                                lisp-interaction-mode-map
                                                lisp-interaction-mode-hook)
      "Major mode for typing and evaluating Lisp forms.
Like Lisp mode except that \\[eval-print-last-sexp] evals the Lisp
expression before point, inserting the value into the buffer as text."
      #t)

    ))
