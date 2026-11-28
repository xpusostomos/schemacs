(define-library (schemacs help-mode)
  ;; This library mirrors GNU Emacs's `lisp/help-mode.el' - the major
  ;; mode `*Help*' buffers are in.
  ;;
  ;; **What is not carried, and what each waits for**: the whole xref
  ;; machinery (`help-xref-stack`, `help-xref-forward-stack`,
  ;; `help-xref-stack-item`'s stack half, `help-make-xrefs`,
  ;; `make-text-button`, `help-follow`, `help-go-back`/`help-go-forward`,
  ;; `help-view-source`, `help-goto-info`, `help-customize`), and with
  ;; them `help-mode-map`'s keys that name those commands, the
  ;; `:parent`'s `button-buffer-map` half (there are no buttons to move
  ;; between), the context menu and tool bar, bookmark records, and
  ;; `help-mode-revert-buffer` (it re-runs the xref item).
  ;;
  ;; What is here is the mode itself and its map: `special-mode`'s keys
  ;; (`q` closes the window, SPC/DEL scroll, `<`/`>` move, `g` reverts)
  ;; come from the parent map, which `define-derived-mode` installs.

  (import
    (only (schemacs custom) define-custom)
    (scheme base)
    (only (schemacs core derived) define-derived-mode derived-mode-p)
    (only (schemacs buffer) current-buffer set!buffer-read-only)
    ;; `help.el:37'-`:38' adds the two temp-buffer hooks; this library is
    ;; the one that is above `help.scm`, so the additions live here.
    (only (schemacs subr) add-hook
          *temp-buffer-setup-hook* *temp-buffer-show-hook*)
    (only (schemacs simple) special-mode special-mode-map)
    (only (schemacs keymap) make-sparse-keymap)
    (only (schemacs help) *help-mode-function*))

  (export help-mode help-mode-map help-mode-hook
          help-mode-setup help-mode-finish)

  (begin

    (define help-mode-map
      ;; GNU Emacs's `help-mode-map` (`help-mode.el:34`), whose
      ;; `:parent` is `(make-composed-keymap button-buffer-map
      ;; special-mode-map)`. This tree has no composed keymaps; the
      ;; parent `define-derived-mode` installs is `special-mode-map`,
      ;; which is where `q` lives.
      ;;--------------------------------------------------------------
      (make-sparse-keymap '*help-mode-map*))

    (define-custom help-mode-hook '()
      "Hook run by `help-mode'."
      :type 'hook :group 'help)
    ;; ^ `help-mode-hook`, which Emacs's `define-derived-mode` invents.

    (define-derived-mode (help-mode special-mode "Help" help-mode-map
                                    help-mode-hook)
      "Major mode for viewing help text and navigating references in it.
Also see the `help-enable-variable-value-editing' variable.

Commands:
\\{help-mode-map}"
      ;; Emacs's body sets `revert-buffer-function' to
      ;; `help-mode-revert-buffer`, adds the context menu, the tool bar
      ;; map, the bookmark record function and `isearch-fold-quotes-mode'
      ;; - all of them xref, toolkit or search machinery this tree does
      ;; not carry.
      #f)

    (define (help-mode-setup)
      ;; GNU Emacs's `help-mode-setup' (`help-mode.el:430'): "Enter Help
      ;; mode in the current buffer."
      ;;--------------------------------------------------------------
      (help-mode)
      (set!buffer-read-only (current-buffer) #f))

    (define (help-mode-finish)
      ;; GNU Emacs's `help-mode-finish' (`help-mode.el:437'): "Finalize
      ;; Help mode setup in current buffer."
      ;;
      ;; **The xrefs half is not carried**: `help-make-xrefs` is not
      ;; ported (see the header), so the buffer is made read-only and the
      ;; links are not made.
      ;;--------------------------------------------------------------
      (when (derived-mode-p 'help-mode)
        (set!buffer-read-only (current-buffer) #t)))

    ;; `help.el:37'-`:38':
    ;;
    ;;   (add-hook 'temp-buffer-setup-hook 'help-mode-setup)
    ;;   (add-hook 'temp-buffer-show-hook 'help-mode-finish)
    ;;
    ;; Emacs's `help.el` does this; that library is below this one here,
    ;; so the two additions live beside the functions they name.
    (add-hook *temp-buffer-setup-hook* help-mode-setup)
    (add-hook *temp-buffer-show-hook* help-mode-finish)

    ;; The seam `help.scm`'s `with-help-window` calls. Installed here,
    ;; where the mode is - help.el cannot import this library because
    ;; this library is above it, and Emacs reaches the mode the same
    ;; way, through an autoload.
    (*help-mode-function* help-mode)))
