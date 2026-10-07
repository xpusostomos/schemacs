(define-library (schemacs editor mouse)
  ;; This library mirrors GNU Emacs's `mouse.el': the commands a mouse
  ;; event runs.
  ;;
  ;; **The click and the drag are here.** Pressing `[down-mouse-1]`
  ;; selects the window the press landed in and puts point where it
  ;; landed - Emacs's own order and not a shortcut: `mouse-drag-track'
  ;; calls `mouse-set-point' in its `let*' (`mouse.el:1939', "let's jump
  ;; to the place of the event, where things are happening") *before* it
  ;; reads a single motion event. Dragging then moves the region from
  ;; there: the mark goes down with the press, each motion event moves
  ;; point to where the pointer is (Emacs's `mouse--drag-set-mark-and-
  ;; point', `mouse.el:2044'), and the release leaves the region active.
  ;; The front end delivers motion events for this - `pgtk.sld' asks for
  ;; `GDK_POINTER_MOTION_MASK' beside the button masks.
  ;;
  ;; Still not here, named so that it is not mistaken for done:
  ;;
  ;;   the click count, and so the word a double click is on and the line
  ;;   a triple click is on  - `mouse-start-end''s modes 1 and 2, which
  ;;                       need a clock to count with. Every event this
  ;;                       tree makes is a single click, so only mode 0
  ;;                       is reachable and only mode 0 is ported.
  ;;   `mouse-drag-and-drop-region', `mouse-leave-buffer-hook',
  ;;   `mouse-drag-copy-region' (nil in Emacs anyway)
  ;;   `mouse-face' highlighting
  ;;   the mode-line, scroll-bar and fringe areas - `posn-area''s other
  ;;                       answers, and the bindings in `bindings.el'
  ;;   `mouse-autoselect-window' - the hover half, a different mechanism
  ;;   `mouse-minibuffer-check' - it refuses an event inside a
  ;;                       minibuffer-only frame, and this tree has no
  ;;                       such frame: the echo area is a row
  (import
    (scheme base)
    (only (guile) open-file catch format)   ; TEMPORARY, for clicklog
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
    ;; The mark a drag sets, and the region it leaves active:
    ;; `set-mark', `activate-mark' and `region-active-p' are simple.el's.
    (only (schemacs editor simple)
          set-mark activate-mark deactivate-mark region-active-p)
    (only (schemacs editor engine) text-editor-mark)
    (only (schemacs editor buffer) current-buffer)
    ;; a drag repaints as it moves, which is what Emacs's tracking loop
    ;; does with `redisplay'.
    (only (schemacs editor xdisp) redisplay-frames! *track-mouse*)
    (only (schemacs editor keymap) define-key *default-keymap*)
    (only (schemacs editor character) kbd)
    ;; A command that reads its own keys waits the way the command loop
    ;; does, and `read-key-event' is the read every key comes through -
    ;; the same two calls `isearch' makes.
    (only (schemacs editor keyboard)
          *unread-command-events* read-key-event read-wait-ms
          ;; the display's own event value, which is where a motion
          ;; event's *position* is - `read-key-event' answers only the key
          *last-read-event*)
    (only (schemacs editor command)
          *this-event* current-prefix-arg define-command))

  (export posn-set-point mouse-set-point mouse-drag-region mouse-drag-track
          mouse-set-region mouse-start-end mouse--drag-set-mark-and-point
          mark mouse-key?)

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


    (define (clicklog line)
      ;; TEMPORARY: append a line to a file, from wherever.
      (catch #t
        (lambda ()
          (let ((out (open-file "/tmp/pgtk-click.log" "a")))
            ;; `for-each' is R7RS's and takes a *list*; a string needs
            ;; `string-for-each'. Getting that wrong is what made the
            ;; first version of this log write nothing at all.
            (string-for-each
             (lambda (c) (write-u8 (char->integer c) out))
             line)
            (write-u8 10 out)
            (close-port out)))
        (lambda (k . a) #f)))

    (define (mark)
      ;; The mark as a *position*, which is what GNU Emacs's `(mark)'
      ;; answers and what the comparisons below are made of. This tree
      ;; keeps it as a marker, so the position is read out of it.
      ;;--------------------------------------------------------------
      (text-editor-mark (current-buffer)))

    (define (mouse-start-end start end mode)
      ;; GNU Emacs's `mouse-start-end' (`mouse.el:1832'): the bounds of
      ;; the region a drag from START to END selects, widened by MODE -
      ;; 0 for a single click's drag, 1 for the word a double click is
      ;; on, 2 for its line.
      ;;
      ;; **Mode 0 only**, because a click count needs a clock and the
      ;; double-click machinery, and neither is ported: every event this
      ;; tree produces is a single click. Modes 1 and 2 would be a
      ;; `forward-word' or a `forward-line' from each end, as Emacs's
      ;; are. The ordering is Emacs's and comes first there too.
      ;;--------------------------------------------------------------
      (list (min start end) (max start end)))

    (define (mouse--drag-set-mark-and-point start click click-count)
      ;; GNU Emacs's (`mouse.el:2044'): where the mark and point go as a
      ;; drag from START to CLICK moves. Point follows the pointer and the
      ;; mark holds the other end - whichever end that is, which is what
      ;; the two `eqv?' cases are for: a drag back over its own start
      ;; should not turn the region inside out.
      ;;--------------------------------------------------------------
      (let* ((range (mouse-start-end start click click-count))
             (beg (car range))
             (end (cadr range))
             (m (mark)))
        (cond ((eqv? m beg) (goto-char end))
              ((eqv? m end) (goto-char beg))
              ((and m (< click m)) (set-mark end) (goto-char beg))
              (else (set-mark beg) (goto-char end)))))

    (define-command (mouse-set-region click)
      "Set the region to the text dragged over, and copy to kill ring.
This should be bound to a mouse drag event."
      (interactive "e")
      ;; Emacs's body reads the click count through `mouse-drag-copy-region'
      ;; and `mouse--last-click-count'; what is ported is the end of it -
      ;; the mark and point of the drag - and a count of 0, which is what
      ;; a single click has.
      ;;--------------------------------------------------------------
      (let ((point (posn-point (event-start click))))
        (when point
          (goto-char point)
          (set-mark point)
          (activate-mark))))

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
      (clicklog "track: entered")
      (mouse-set-point start-event #f)
      (clicklog "track: point set")
      ;; The mark goes down with the *press*, so the drag has a far end to
      ;; move from before the pointer has moved at all. Emacs sets it in
      ;; this loop's `let*' the same way.
      (let ((start-point (posn-point (event-start start-event))))
        (clicklog (string-append "track: start-point="
                                 (if start-point
                                     (number->string start-point) "NONE")))
        (when start-point
          (set-mark start-point)
          (activate-mark))
        (clicklog "track: mark set, entering the loop")
        ;; **The tracking loop, under `track-mouse'.** Emacs binds that
        ;; variable around this loop and the *display* is what reads it:
        ;; motion is only an event while it is set. It has to be bound
        ;; before the loop reads anything - a move that arrived before
        ;; the binding was never an event, which is why the front end
        ;; checks it rather than the loop filtering afterwards.
        ;;
        ;; Emacs's loop also reads every event until the button comes up,
        ;; moving the region with each motion; the click count is fixed at
        ;; 0 here - a single click - because there is no clock to count
        ;; with.
        (parameterize ((*track-mouse* #t))
        (clicklog (string-append "track: bound track-mouse, now "
                                 (format #f "~a" (*track-mouse*))))
        (let loop ()
          (clicklog (string-append "loop: reading, wait="
                                   (format #f "~a" (read-wait-ms))))
          (let ((key (read-key-event (read-wait-ms))))
            (clicklog (string-append "loop: key="
                                     (if key (format #f "~a" key) "NONE")))
            (cond
             ((not key) #f)                     ; a read that produced nothing
             ((eq? key 'mouse-1)                ; the release: the region stands
              (clicklog "loop: release")
              (activate-mark)
              #f)
             ((eq? key 'mouse-movement)
              (clicklog (string-append
                         "loop: motion, event has a point? "
                         (let ((ev (*last-read-event*)))
                           (if (and (pair? ev) (posn-point (event-start ev)))
                               "yes" "no"))))
              ;; The position comes from the *event*, which `read-key-event'
              ;; does not answer - it answers the key - so it is read from
              ;; `*last-read-event*', the value `keyboard.sld' keeps for
              ;; exactly this.
              (let* ((ev (*last-read-event*))
                     (click (and (pair? ev)
                                 (posn-point (event-start ev)))))
                (when (and start-point click)
                  (mouse--drag-set-mark-and-point start-point click 0)
                  ;; A drag that does not show itself is a drag nobody can
                  ;; aim: Emacs's loop redisplays here for the same reason.
                  (redisplay-frames!)))
              (loop))
             ((eq? key 'down-mouse-1) (loop))   ; a second press, still tracking
             ;; **Any other mouse key ends the tracking too, and is not
             ;; pushed back.** A release that slipped past the line above
             ;; - read by another reader first - would otherwise be handed
             ;; to the command loop, which has nothing bound for it and
             ;; says "undefined key" in the echo area: a click that
             ;; worked, followed by a complaint about it.
             ;; **A frame event is not input, and must not end the drag.**
             ;; In GNU Emacs a frame's size change is not a key event at
             ;; all - `keyboard.c` has no `RESIZE_EVENT` - so resizing the
             ;; window mid-drag leaves `mouse-drag-track`'s transient map
             ;; untouched and the drag carries on. Emacs is explicit about
             ;; the same principle for the frame events it *does* make:
             ;; its drag map binds `[switch-frame]' and `[select-window]'
             ;; to `ignore' so that a frame event cannot end a drag.
             ;;
             ;; `<resize>' is this tree's invention standing in for that
             ;; size change (`keyboard.sld` binds it in
             ;; `special-event-map`), and a press is followed by one every
             ;; time - measured, three drags out of three. Treating it as
             ;; "an event I do not recognise" is what ended every drag
             ;; before it had moved once.
             ;;
             ;; Swallowed rather than pushed back: the new size is already
             ;; recorded by the `size-allocate' signal, which does not come
             ;; through here, and a pushback would be read straight back
             ;; out by the next iteration and spin.
             ((eq? key 'resize) (loop))
             ((mouse-key? key) #f)
             (else
              ;; Anything else belongs to the command loop, which is where
              ;; Emacs's own readers leave it too.
              (*unread-command-events* (cons key (*unread-command-events*)))
              #f)))))))

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
