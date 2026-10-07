(define-library (schemacs editor mouse)
  ;; This library mirrors GNU Emacs's `mouse.el': the commands a mouse
  ;; event runs.
  ;;
  ;; **What is here is the click.** Pressing `[down-mouse-1]` selects the
  ;; window the press landed in and puts point where it landed. That is
  ;; Emacs's own order and not a shortcut: `mouse-drag-track' calls
  ;; `mouse-set-point' in its `let*' - `mouse.el:1939', under the comment
  ;; "let's jump to the place of the event, where things are happening" -
  ;; *before* it reads a single motion event, and everything that follows
  ;; only extends the region from there.
  ;;
  ;; **What is not here is the drag.** The front ends do not deliver
  ;; motion events yet, so the loop below reads the button's release and
  ;; stops, and no region is set. Named, so that it is not mistaken for
  ;; done, with where each would go:
  ;;
  ;;   `mouse-set-region' and the click count that drives double and
  ;;   triple clicks       - `mouse-drag-track''s region half
  ;;   `mouse-drag-and-drop-region', `mouse-leave-buffer-hook'
  ;;   `mouse-face' highlighting
  ;;   the mode-line, scroll-bar and fringe areas - `posn-area''s other
  ;;                       answers, and the bindings in `bindings.el'
  ;;   `mouse-autoselect-window' - the hover half, a different mechanism
  ;;   `mouse-minibuffer-check' - it refuses an event inside a
  ;;                       minibuffer-only frame, and this tree has no
  ;;                       such frame: the echo area is a row
  (import
    (scheme base)
    ;; `posn-set-point' is `subr.el''s and lives here because it needs
    ;; the two below, and `(schemacs editor subr)' is beneath both of
    ;; them and cannot reach either - see the note on the posn cluster
    ;; there.
    (only (schemacs editor subr) event-start event-end posn-point posn-window
          ;; where a release lands if the tracking loop did not eat it
          ignore)
    (only (schemacs editor frame)
          frame? frame-selected-window select-window window-type?)
    (only (schemacs editor editfns) goto-char)
    (only (schemacs editor keymap) define-key *default-keymap*)
    (only (schemacs editor character) kbd)
    ;; A command that reads its own keys waits the way the command loop
    ;; does, and `read-key-event' is the read every key comes through -
    ;; the same two calls `isearch' makes.
    (only (schemacs editor keyboard)
          *unread-command-events* read-key-event read-wait-ms)
    (only (schemacs editor command)
          *this-event* current-prefix-arg define-command))

  (export posn-set-point mouse-set-point mouse-drag-region mouse-drag-track)

  (begin

    ;;----------------------------------------------------------------
    ;; Where a mouse event happened
    ;;------------------------------------------------------------------

    (define (posn-set-point position)
      ;; GNU Emacs's `posn-set-point' (`subr.el:2013'): move point to
      ;; POSITION, selecting the corresponding window as well.
      ;;
      ;; **This is the whole of "clicking in a window activates it".**
      ;; The press carries the window it happened in and a buffer
      ;; position inside it, and the two steps below are what Emacs does
      ;; with them - `select-window', then `goto-char'.
      ;;
      ;; Which window is selected matters twice over here: `select-window'
      ;; is this tree's `select_window_1' and it makes the window's
      ;; buffer current as well (`Fselect_window''s first line,
      ;; `window.c:534'), so the *buffer* follows the click too.
      ;;--------------------------------------------------------------
      (if (frame? (posn-window position))
          ;; The press was outside every window - on the frame's own
          ;; area - so Emacs means the frame's selected window, and
          ;; refuses a frame whose selected window is not one.
          (let ((window (frame-selected-window (posn-window position))))
            (unless (window-type? window)
              (error "Position not in text area of window"))
            (select-window window))
          (let ((window (posn-window position)))
            (unless (window-type? window)
              (error "Position not in text area of window"))
            (select-window window)))
      ;; A position that names no buffer location - a press on the mode
      ;; line - selects the window and stops there, as Emacs's does.
      (let ((point (posn-point position)))
        (when (integer? point)
          (goto-char point))))

    ;;----------------------------------------------------------------
    ;; The commands
    ;;------------------------------------------------------------------

    (define-command (mouse-set-point event promote-to-region)
      "Move point to the position clicked on with the mouse.
This should be bound to a mouse click event type.
If PROMOTE-TO-REGION is non-nil and event is a multiple-click, select
the corresponding element around point, with the resulting position of
point determined by `mouse-select-region-move-to-beginning'."
      (interactive (list (*this-event*) (current-prefix-arg)))
      ;; Emacs's body is
      ;;
      ;;   (and promote-to-region (> (event-click-count event) 1))
      ;;   -> the multi-click branch, else (posn-set-point (event-end event))
      ;;
      ;; **The multi-click branch is not carried**: it needs the click
      ;; count and the region, and neither is here yet. A single press
      ;; reports a click count of 1, which is the branch below.
      ;;--------------------------------------------------------------
      (posn-set-point (event-end event)))

    (define (mouse-key? key)
      ;; Whether KEY names one of the mouse buttons this front end makes
      ;; events for. GNU Emacs's `mouse-event-p' is the same question
      ;; (`subr.el'), asked of `event-basic-type'; it answers the same
      ;; here, because `down-mouse-1''s basic type is itself - this
      ;; tree's `event-basic-type' does not strip the `down-' the way
      ;; Emacs's does, which is a departure of its own and one this
      ;; predicate is written to work under either way.
      ;;--------------------------------------------------------------
      (and (symbol? key)
           (memq key '(mouse-1 mouse-2 mouse-3
                       down-mouse-1 down-mouse-2 down-mouse-3))))

    (define (mouse-drag-track start-event)
      ;; GNU Emacs's `mouse-drag-track' (`mouse.el:1919'), as far as the
      ;; click goes. Not a command in Emacs either - `mouse-drag-region'
      ;; calls it - so it is a plain definition here too.
      ;;
      ;; **The `let*' is the event.** Emacs records the position, the
      ;; point and the window the press happened in, then jumps to it:
      ;;
      ;;   (_ (mouse-set-point start-event))
      ;;
      ;; and that call is what selects the window and moves point. The
      ;; tracking after it exists to grow a region, which is the part
      ;; this tree does not have yet.
      ;;
      ;; `#f' for PROMOTE-TO-REGION, which Emacs's call leaves out: a
      ;; `define-command' here takes the arguments its interactive
      ;; expression supplies and has no `&optional' to make one skippable,
      ;; so a programmatic call passes the same two.
      ;;--------------------------------------------------------------
      (mouse-set-point start-event #f)
      ;; Emacs's tracking loop, in the shape the missing half leaves it:
      ;; it runs while the mouse moves and ends at the release, and with
      ;; no motion events to read it ends at the release. A key pressed
      ;; with the button down is put back for the command loop and ends
      ;; the tracking - Emacs reads the same events and has the region to
      ;; move with them, which is a real difference and is named above
      ;; rather than faked here.
      (let loop ()
        (let ((key (read-key-event (read-wait-ms))))
          (cond
           ((not key) #f)                        ; a read that produced nothing
           ((eq? key 'mouse-1) #f)               ; the release: the click is done
           ((eq? key 'down-mouse-1) (loop))      ; a second press, still tracking
           ;; **Any other mouse key ends the tracking too, and is not
           ;; pushed back.** A release that slipped past the line above -
           ;; read by another reader first, or arriving as the `mouse-2'
           ;; this tree does not bind - would otherwise be handed to the
           ;; command loop, which has nothing bound for it and says
           ;; "undefined key" in the echo area: a click that worked,
           ;; followed by a complaint about it.
           ((mouse-key? key) #f)
           (else
            ;; Anything else belongs to the command loop, which is where
            ;; Emacs's own readers leave it too.
            (*unread-command-events* (cons key (*unread-command-events*)))
            #f)))))

    (define-command (mouse-drag-region start-event)
      "Set the region to the text that the mouse is dragged over.
Highlight the drag area as you move the mouse.
This must be bound to a button-down mouse event.
In Transient Mark mode, the highlighting remains as long as the mark
remains active.  Otherwise, it remains until the next input event.

When the region already exists and `mouse-drag-and-drop-region'
is non-nil, this moves the entire region of text to where mouse
is dragged over to."
      (interactive "e")
      ;; Emacs's body is the drag-and-drop branch, then
      ;; `mouse-leave-buffer-hook', then `mouse-drag-track'. The hook and
      ;; the drag-and-drop branch are not carried - see the note at the
      ;; top of this library - and what is left is the call.
      ;;--------------------------------------------------------------
      (mouse-drag-track start-event))

    ;; `mouse.el:3781''s own line. The *press* starts a drag, which is why
    ;; the binding is on `down-mouse-1' and not on the click; `mouse-1' is
    ;; what `mouse-drag-track' reads to learn the press is over, so it is
    ;; deliberately bound to nothing.
    (define-key *default-keymap* (kbd "<down-mouse-1>") mouse-drag-region)

    ;; The *release*, which no command wants: `mouse-drag-track' reads it
    ;; to learn the click is over, and this is what it lands on if some
    ;; other reader got to it first. Without it the echo area reports
    ;; "undefined key" after an otherwise successful click, which reads
    ;; as a failure and is not one.
    (define-key *default-keymap* (kbd "<mouse-1>") ignore)

    ))
