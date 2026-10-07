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
          pgtk-open-window pgtk-title-frame! initialize-pgtk-faces!
          pgtk-arm-timer! pgtk-main pgtk-main-quit)
    (only (schemacs editor engine) new-text-editor set!text-editor-buffer-name)
    (only (schemacs editor frame) *current-frame* new-frame new-frame-on
          *frame-creation-function* frame-editor)
    (only (schemacs editor buffer) *scratch-buffer-name* get-buffer-create)
    (only (schemacs editor files) note-file-read-only!)
    (only (schemacs editor startup) command-line-1)
    (only (schemacs editor keyboard) event-loop-on timer-check!)
    ;; The timer module is *told* when to come back rather than polled -
    ;; see `*timer-wake*'. `redisplay-frames!' is what draws when one has
    ;; run, which is what makes a cursor blink visible with no keypress.
    (only (schemacs editor xdisp) redisplay-frames!)
    (only (schemacs editor timer) *timer-wake*)
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
    ;; The mouse commands, imported for their *binding*: loading
    ;; `mouse.sld' is what puts `[down-mouse-1]' in the global map,
    ;; as Emacs's own line at the end of `mouse.el' does.
    (only (schemacs editor mouse))
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
      ;;
      ;; **Gtk's own main loop absorbs the keys.** There is no command
      ;; loop here at all: `event-loop-on' installs a handler and returns
      ;; control to `gtk_main', which then calls that handler once per
      ;; event - the handler runs one command and *returns*, so control
      ;; goes back to `gtk_main` every time, and it is `gtk_main` that
      ;; dispatches whatever else is in the frame's window (a menu, a
      ;; popup, a drag).
      ;;
      ;; A prompt or an isearch is still a blocking read and still nests
      ;; - that is the editor being reentrant, and `ptk-enqueue!` tells
      ;; the two cases apart.
      ;;--------------------------------------------------------------
      (let ((scratch (get-buffer-create *scratch-buffer-name*)))
        (with-gtk-display
         (lambda ()
           (let ((frame (new-frame scratch)))
             (pgtk-title-frame! frame)
             ;; **The timer module is told, not polled.** Until now a
             ;; timer could only fire while something was waiting to read
             ;; a key: the command loop armed its read with
             ;; `timer-next-delay' and ran `timer-check!' when the read
             ;; came back. That is enough while the read is the wait, and
             ;; it stops being enough the moment Gtk owns the loop -
             ;; there is then no read to arm, and an idle editor would
             ;; never fire a timer at all.
             ;;
             ;; `*timer-wake*' is the arrangement: the timer module says
             ;; how long it wants, and this arms a one-shot Gtk source to
             ;; come back and run whatever is due.
             (*timer-wake* (lambda (ms)
                             (pgtk-arm-timer!
                              ms
                              (lambda ()
                                (when (timer-check!)
                                  (redisplay-frames!))))))
             ;; **The frame backend, installed before the command loop
             ;; runs** - so `C-x 5 2' makes a window from the first
             ;; keystroke. A parameter rather than a call here, so that
             ;; `frame.sld' never imports a front end - the same
             ;; arrangement that keeps `dispnew.sld' free of both.
             ;;
             ;; The `parameterize' encloses the *loop*: `event-loop-on'
             ;; installs its handler and `gtk_main' calls it from within
             ;; this body, so the fluid values bound here are the ones the
             ;; commands run under.
             (parameterize ((*current-frame* frame)
                            (*frame-creation-function* gtk-create-frame))
               (command-line-1 args)
               (note-file-read-only! frame)
               ;; `event-loop-on' hands control to `gtk_main' and does not
               ;; return until `frame-quit-cont' - which it sets to
               ;; `pgtk-main-quit' - stops it. So the window closes and
               ;; `main-gtk' returns exactly as it did when the loop was
               ;; ours, and `main-gtk.scm' removes the REPL port file.
               (event-loop-on frame pgtk-main pgtk-main-quit)))))))

    ))
