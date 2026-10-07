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
    (only (schemacs editor pgtk) with-gtk-display
          pgtk-open-window pgtk-title-frame! initialize-pgtk-faces!)
    (only (schemacs editor engine) new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) *current-frame* new-frame new-frame-on
          *frame-creation-function* frame-editor)
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

    (define (gtk-create-frame)
      ;; One more GTK window, and the frame that draws on it - GNU Emacs's
      ;; `frame-creation-function' method for pgtk, which is
      ;; `(x-create-frame-with-faces params)' (`term/pgtk-win.el:117') and
      ;; ends in `x-create-frame': one window per frame, showing the buffer
      ;; the selected window already shows.
      ;;
      ;; The order is display first and then the frame, which is this
      ;; tree's shape - a frame's `output' is a constructor argument - so
      ;; the title has to wait for the frame's name and
      ;; `pgtk-title-frame!' is a second call. Emacs names the frame first
      ;; and titles the window from it inside `x_window (f)'.
      ;;--------------------------------------------------------------
      (let* ((selected (*current-frame*))
             (editor (if selected
                         (frame-editor selected)
                         (get-buffer-create *scratch-buffer-name*)))
             (display (pgtk-open-window 80 24))
             (frame (new-frame-on display editor 24 80)))
        ;; **The new display needs its faces realised**, exactly as the
        ;; first one did in `with-gtk-display'. Each display has its own
        ;; face table - the colours are its window's - so a display opened
        ;; here and not initialised has nothing to draw a face with, and
        ;; the window stays blank.
        (initialize-pgtk-faces! display)
        (pgtk-title-frame! frame)
        frame))

    (define (main-gtk . args)
      ;; Open the editor on a GTK window and run it until it is quit.
      ;;--------------------------------------------------------------
      (let ((scratch (get-buffer-create *scratch-buffer-name*)))
        (with-gtk-display
         (lambda ()
           (let ((frame (new-frame scratch)))
             (pgtk-title-frame! frame)
             ;; **The frame backend, installed before the command loop
             ;; runs** - so `C-x 5 2' makes a window from the first
             ;; keystroke. A parameter rather than a call here, so that
             ;; `frame.sld' never imports a front end - the same
             ;; arrangement that keeps `dispnew.sld' free of both.
             (parameterize ((*current-frame* frame)
                            (*frame-creation-function* gtk-create-frame))
               (command-line-1 args)
               (note-file-read-only! frame)
               (event-loop frame)))))))

    ))
