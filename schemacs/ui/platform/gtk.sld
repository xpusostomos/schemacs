(define-library (schemacs ui platform gtk)
  ;; The GTK platform: open the editor on a GTK window. This mirrors
  ;; `(schemacs ui platform ncurses)' exactly - the same buffers, the
  ;; same frame, the same command loop - with the display opened by
  ;; `with-gtk-display' instead of `with-terminal'. Nothing here knows
  ;; what the editor does; nothing in the editor knows this exists.
  ;;
  ;; See GTK-PLAN.md.

  (import
    (scheme base)
    ;; The display, and the editor that runs on it.
    (only (schemacs editor pgtk) with-gtk-display)
    (only (schemacs editor engine) new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) *current-frame* new-frame)
    (only (schemacs editor buffer) *scratch-buffer-name* get-buffer-create)
    (only (schemacs editor files) note-file-read-only!)
    (only (schemacs editor startup) command-line-1)
    (only (schemacs editor keyboard) event-loop)
    ;; Imported only so their `define-key' forms run at load time, which
    ;; is what installs C-x C-f, C-s, C-x 2 and C-x C-b: a binding is
    ;; made by the library that owns the command, so the library has to
    ;; be loaded even though nothing here calls it. `ncurses.sld' does
    ;; the same, for the same reason.
    (only (schemacs editor simple) self-insert-layer)
    (only (schemacs editor isearch) isearch-forward)
    (only (schemacs editor window) split-window-below)
    (only (schemacs editor buff-menu) list-buffers)
    ;; `casefiddle.c' and `paragraphs.el' - the ncurses.sld note says
    ;; why.
    (only (schemacs editor casefiddle))
    (only (schemacs editor paragraphs))
    ;; `replace.el' - the ncurses.sld note says why.
    (only (schemacs editor replace))
    ;; The multilingual commands (`C-x RET ...`), which install their own
    ;; keys - `mule-cmds.el`. Not for a name: for the load.
    (only (schemacs editor mule-cmds))
    ;; `dired.el': C-x d binds at load, the same reason again.
    (only (schemacs editor dired)))

  (export main-gtk)

  (begin

    (define (main-gtk . args)
      ;; Open the editor on a GTK window and run it until it is quit.
      ;;--------------------------------------------------------------
      (let ((scratch (get-buffer-create *scratch-buffer-name*)))
        (with-gtk-display
         (lambda ()
           (let ((frame (new-frame scratch)))
             (parameterize ((*current-frame* frame))
               (command-line-1 args)
               (note-file-read-only! frame)
               (event-loop frame)))))))

    ))
