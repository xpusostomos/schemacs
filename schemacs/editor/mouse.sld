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
  ;; **And dragging past the edge of the window scrolls it**, which is
  ;; what makes a selection longer than a screen possible: when a motion
  ;; event has left the window, `mouse-scroll-subr' (`mouse.el:1708')
  ;; scrolls by the rows the pointer is past the edge and repeats every
  ;; `mouse-scroll-delay' until some input arrives. That is Emacs's
  ;; function and Emacs's arithmetic; what it is built on, `vertical-motion'
  ;; (`indent.c:2207'), is in `xdisp.sld' - see the note there.
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
    (only (guile) catch format open-file)   ; TEMPORARY, for draglog
    (only (scheme time) current-jiffy jiffies-per-second) ; TEMPORARY
    ;; `posn-set-point' is `subr.el''s and lives here because it needs
    ;; the two below, and `(schemacs editor subr)' is beneath both of
    ;; them and cannot reach either - see the note on the posn cluster
    ;; there.
    (only (schemacs editor subr) event-start event-end posn-point posn-window
          ;; where the pointer is, which a drag that has left its window
          ;; asks for
          posn-x-y
          ;; where a release lands if the tracking loop did not eat it
          ignore)
    (only (schemacs editor frame)
          frame? frame-selected-window mouse-position select-window
          selected-window set-window-start! window-buffer window-edges
          window-height window-point window-type?)
    (only (schemacs editor editfns) goto-char point)
    ;; The mark a drag sets, and the region it leaves active:
    ;; `push-mark', `pop-mark', `activate-mark' and `region-active-p' are
    ;; simple.el's. `push-mark' and not `set-mark', which is Emacs's own
    ;; call in `mouse-drag-track': the mark that was there goes on the
    ;; ring rather than being lost.
    (only (schemacs editor simple)
          push-mark pop-mark set-mark activate-mark deactivate-mark
          region-active-p use-region-p)
    (only (schemacs editor engine)
          set!text-editor-deactivate-mark! text-editor-mark)
    (only (schemacs editor buffer)
          buffer-auto-hscroll-mode current-buffer set!buffer-auto-hscroll-mode
          set-buffer-local-value! transient-mark-mode)
    ;; a drag repaints as it moves, which is what Emacs's tracking does
    ;; with `redisplay'.
    (only (schemacs editor xdisp)
          redisplay-frames! *mode-line-format* track-mouse vertical-motion
          window-end window-start)
    ;; `mouse-position' - the pointer's own frame row, which is what
    ;; decides whether a drag has left the window - is the display's
    ;; answer, so the display is what is asked.
    (only (schemacs editor dispnew) current-display line-height)
    (only (schemacs editor keymap) define-key *default-keymap*)
    ;; a sparse keymap to hand to `set-transient-map', which is Emacs's
    ;; `(make-sparse-keymap)' in that same place
    (prefix (schemacs keymap) km:)
    (only (schemacs editor character) kbd)
    ;; A command that reads its own keys waits the way the command loop
    ;; does, and `read-key-event' is the read every key comes through -
    ;; the same two calls `isearch' makes. `sit-for' is that same read
    ;; with a deadline, which is how the edge-of-window scrolling knows
    ;; a drag has moved on.
    (only (schemacs editor keyboard)
          set-transient-map sit-for
          *unread-command-events*        ; TEMPORARY, for draglog
          ;; the display's own event value, which is where a motion
          ;; event's *position* is - `read-key-event' answers only the key
          *last-read-event*)
    (only (schemacs editor command)
          *this-event* current-prefix-arg define-command))

  (export posn-set-point mouse-set-point mouse-drag-region mouse-drag-track
          mouse-set-region mouse-start-end mouse--drag-set-mark-and-point
          mouse-scroll-subr mouse-set-region-1
          *mouse-scroll-delay* *mouse-scroll-min-lines*
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
                       down-mouse-1 down-mouse-2 down-mouse-3
                       drag-mouse-1 drag-mouse-2 drag-mouse-3))))


    (define (draglog line)
      ;; TEMPORARY: append a line to a file, from wherever. A file and not
      ;; the echo area, which only ever shows the last message.
      ;;--------------------------------------------------------------
      (catch #t
        (lambda ()
          (let ((out (open-file "/tmp/pgtk-drag.log" "a")))
            (string-for-each
             (lambda (c) (write-u8 (char->integer c) out))
             line)
            (write-u8 10 out)
            (close-port out)))
        (lambda (k . a) #f)))

    (define (car-safe-of object)
      ;; GNU Emacs's `car-safe': the cons's car, or nil for anything that
      ;; is not one.
      ;;--------------------------------------------------------------
      (and (pair? object) (car object)))

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

    ;;----------------------------------------------------------------
    ;; Dragging past the edge of a window
    ;;------------------------------------------------------------------

    (define *mouse-scroll-delay* (make-parameter 0.25))
    ;; ^ GNU Emacs's `mouse-scroll-delay' (`mouse.el:1679'), "The pause
    ;; between scroll steps caused by mouse drags, in seconds. ... Setting
    ;; this to zero causes Emacs to scroll as fast as it can."

    (define *mouse-scroll-min-lines* (make-parameter 1))
    ;; ^ GNU Emacs's `mouse-scroll-min-lines' (`mouse.el:1687'): "The
    ;; minimum number of lines scrolled by dragging mouse out of window."
    ;; The pointer one row past the edge scrolls one line either way, so
    ;; this only matters when it is set higher.

    (define (mouse-scroll-subr window jump overlay start adjust)
      ;; GNU Emacs's `mouse-scroll-subr' (`mouse.el:1708'): "Scroll the
      ;; window WINDOW, JUMP lines at a time, until new input arrives. If
      ;; OVERLAY is an overlay, let it stretch from START to the far edge
      ;; of the newly visible text. ADJUST, if non-nil, is a function,
      ;; without arguments, to call after setting point. Upon exit, point
      ;; is at the far edge of the newly visible text."
      ;;
      ;; **The loop is the function.** One pass scrolls JUMP screen lines
      ;; and leaves point on the far edge of what is now visible; the
      ;; pass *repeats* while `sit-for' says the delay went by with no
      ;; input. That is the whole of "until new input arrives", and it is
      ;; why dragging the pointer out of the bottom and holding it still
      ;; keeps scrolling a step every `mouse-scroll-delay', while moving
      ;; back in or letting the button up - either of which is input - is
      ;; what stops it. A single motion event therefore scrolls one step
      ;; in a test that has already queued the next key, and the whole
      ;; buffer in a drag that is simply held out there.
      ;;
      ;; The odd-looking `(window-end window)' below is Emacs's and has to
      ;; stay: `set-window-start!' does not invalidate the recorded end,
      ;; so `window-end' still answers the *old* end until the next
      ;; redisplay - which is exactly what this wants, because the old end
      ;; is now JUMP rows above the new bottom edge, and walking JUMP - 1
      ;; rows down from it lands on the last row on the screen. (This
      ;; tree's `window-end' behaves the same way and for the same reason:
      ;; `set-window-start!' leaves `%window-end-valid?' alone.)
      ;;
      ;; NOT CARRIED: OVERLAY, which nothing here wants - the drag
      ;; highlights the region itself, and the `SECONDARY' selection
      ;; caller that would is not ported.
      ;;--------------------------------------------------------------
      (let ((jump (cond ((and (> jump 0)
                              (< jump (*mouse-scroll-min-lines*)))
                         (*mouse-scroll-min-lines*))
                        ((and (< jump 0)
                              (> jump (- (*mouse-scroll-min-lines*))))
                         (- (*mouse-scroll-min-lines*)))
                        (else jump))))
        (let ((opoint (point)))
          (let loop ()
            ;; From the window's top, so that the walk is by screen rows
            ;; and not by however far down a line point happens to be.
            (goto-char (window-start window))
            (when (not (= 0 (vertical-motion jump window)))
              (draglog (format #f "  step jump=~a old-start=~a new-start=~a"
                               jump (window-start window) (point)))
              (set-window-start! window (point))
              (if (>= jump 0)
                  (if (window-end window)
                      (begin
                        (goto-char (window-end window))
                        ;; window-end doesn't reflect the window's new
                        ;; start position until the next redisplay
                        (vertical-motion (- jump 1) window)
                        ;; **And then one row further, off the bottom of
                        ;; the window.** The walk above lands point on the
                        ;; window's *last* row, which the redisplay is
                        ;; happy with - the cursor is on the screen, so
                        ;; nothing moves. Leaving it one row lower is
                        ;; "the cursor has been pushed past the bottom",
                        ;; which is the one thing the redisplay's start
                        ;; decision acts on (`redisplay_window''s
                        ;; `recenter:', ported here as
                        ;; `scroll-to-cursor!'): it recentres, so the
                        ;; window moves about half its height rather than
                        ;; one line - the same thing that happens when the
                        ;; *keyboard* cursor is moved off the bottom row.
                        ;; Emacs reaches that state by a different route
                        ;; (`mouse-scroll-subr''s walk ends on the last
                        ;; row, and a GUI frame's last row is only
                        ;; partly visible, so its redisplay recentres
                        ;; too); this tree's rows are exact, so the row
                        ;; has to be stepped onto deliberately.
                        (vertical-motion 1 window))
                      (vertical-motion (- (window-height window) 2) window))
                  (goto-char (window-start window)))
              ;; Now that we have scrolled WINDOW properly, put point back
              ;; where it was for the redisplay so that we don't mess up
              ;; the selected window.
              (unless (eq? window (selected-window))
                (goto-char opoint))
              (when adjust
                (adjust))
              ;; TEMPORARY: the same call, with its answer written down -
              ;; `#t' means the delay went by with nothing typed, which is
              ;; what sends the loop round again.
              (let ((more (sit-for (*mouse-scroll-delay*) #f)))
                (draglog (format #f "  waited more=~a got=~a" more
                                 (if (pair? (*unread-command-events*))
                                     (car (*unread-command-events*))
                                     '())))
                (when more
                  (loop)))))
          (unless (eq? window (selected-window))
            (goto-char opoint)))))

    (define (%mouse-drag-motion start-window start-point top bottom)
      ;; The body of Emacs's `[mouse-movement]' lambda (`mouse.el:1994'),
      ;; which is the command the drag's transient map binds - so this is
      ;; run by the *command loop*, once per motion event, and not from a
      ;; loop of the drag's own.
      ;;
      ;; Inside the window the drag started in - and on a character, which
      ;; is what `integer? END-POINT' asks - point follows the pointer and
      ;; the region grows to meet it. Anywhere else the drag has left the
      ;; window and the window scrolls, by the number of rows the pointer
      ;; is above the top edge or below the bottom one, so that pulling it
      ;; further out scrolls faster.
      ;;
      ;; **The second branch is not an error case.** A motion event
      ;; outside the window has no buffer position - `posn-point' answers
      ;; #f for a mode line and for the frame, and `posn-window' names
      ;; something other than the window dragged in - and Emacs reads that
      ;; as "keep scrolling", which is what makes a selection longer than
      ;; a screen possible at all.
      ;;--------------------------------------------------------------
      (let* ((ev (*last-read-event*))
             (end (and (pair? ev) (event-end ev)))
             (end-window (and end (posn-window end)))
             (end-point (and end (posn-point end))))
        (if (and (eq? end-window start-window) (integer? end-point))
            (begin
              (draglog (format #f "motion t=~a INSIDE point=~a"
                               (quotient (current-jiffy)
                                         (quotient (jiffies-per-second) 1000))
                               end-point))
              (mouse--drag-set-mark-and-point start-point end-point 0))
            ;; **The pointer's row comes from `mouse-position', not from
            ;; the event.** The event's own coordinates are relative to
            ;; whichever window the pointer was over, and are meaningless
            ;; the moment it leaves that window - which is exactly the
            ;; case this branch is for. Emacs asks its display where the
            ;; pointer is (`XQueryPointer', `gdk_window_get_device_position')
            ;; and this is that call; reading `posn-x-y' here instead is
            ;; what made a drag past the edge scroll one line at a time,
            ;; because the row it answered barely differed from the
            ;; window's bottom edge.
            (let ((mouse-row (cdr (cdr (mouse-position)))))
              (draglog (format #f "motion t=~a row=~a top=~a bottom=~a"
                               (quotient (current-jiffy)
                                         (quotient (jiffies-per-second) 1000))
                               mouse-row top bottom))
              (cond
               ((not (integer? mouse-row)) #f)
               ((< mouse-row top)
                (mouse-scroll-subr start-window (- mouse-row top)
                                   #f start-point #f))
               ((>= mouse-row bottom)
                (mouse-scroll-subr start-window (+ 1 (- mouse-row bottom))
                                   #f start-point #f)))))))

    (define-command (mouse-set-region click)
      "Set the region to the text dragged over, and copy to kill ring.
This should be bound to a mouse drag event."
      (interactive "e")
      ;; GNU Emacs's `mouse-set-region' (`mouse.el:1799'). **This is what
      ;; keeps the region after a drag.** The drag's transient map is
      ;; popped by the release - a command the map does not bind - and
      ;; its ON-EXIT deactivates the mark; `[drag-mouse-1]' is what then
      ;; runs, and its `push-mark'/`set-mark'/`mouse-set-region-1' put
      ;; the region back. That is why `mouse.el:3783' binds
      ;; `[drag-mouse-1]' and not `[mouse-1]'.
      ;;
      ;; NOT CARRIED, each named: `mouse-minibuffer-check';
      ;; `mouse-shift-adjust-point' (no shift-adjust machinery here);
      ;; the `mouse-drag-start' terminal parameter and the click count it
      ;; is read for; `mouse-drag-copy-region' (nil in Emacs by default,
      ;; so nothing is copied); and the "(or transient-mark-mode
      ;; (window-system) (sit-for 1))" cursor bounce, which is a text
      ;; terminal's.
      ;;--------------------------------------------------------------
      (select-window (posn-window (event-start click)))
      (let* ((beg (posn-point (event-start click)))
             (end (if (eq? (posn-window (event-end click)) (selected-window))
                      (posn-point (event-end click))
                      ;; "If the mouse ends up in any other window or on
                      ;; the menu bar, use `window-point' of the selected
                      ;; window" (Bug#23707). Emacs's `window-point'
                      ;; defaults to the selected window; this tree's takes
                      ;; it, so it is passed.
                      (window-point (selected-window))))
             (click-count 0))
        (when (and (integer? beg) (integer? end))
          (let ((range (mouse-start-end beg end click-count)))
            (if (< end beg)
                (begin (set! end (car range)) (set! beg (cadr range)))
                (begin (set! beg (car range)) (set! end (cadr range))))))
        (when (integer? beg)
          (goto-char beg))
        (push-mark)
        (set-mark (point))
        (when (integer? end)
          (goto-char end))
        (mouse-set-region-1)))

    (define (mouse-set-region-1)
      ;; GNU Emacs's `mouse-set-region-1' (`mouse.el:1843'): "Set
      ;; transient-mark-mode for a little while" - the `(cons 'only OLD)'
      ;; value, whose `only' is what tells `deactivate-mark' to put the
      ;; old value back rather than to stay off.
      ;;--------------------------------------------------------------
      (unless (eq? (car-safe-of (transient-mark-mode)) 'only)
        (set-buffer-local-value!
         (current-buffer) 'transient-mark-mode
         (cons 'only (if (eq? (transient-mark-mode) 'lambda)
                         #f
                         (transient-mark-mode))))))

    (define (mouse-drag-track start-event)
      ;; GNU Emacs's `mouse-drag-track' (`mouse.el:1919'). Not a command
      ;; in Emacs either - `mouse-drag-region' calls it - so it is a
      ;; plain definition here too.
      ;;
      ;; **There is no read loop, and the shape is the point.** Emacs
      ;; installs a *transient keymap* (`set-transient-map',
      ;; `mouse.el:1996') binding `[mouse-movement]' to a lambda and
      ;; returns. The **command loop** reads the motion events; the map
      ;; answers for them; and the first command the map does not bind -
      ;; the button coming up, or anything else at all - pops the map and
      ;; runs the cleanup. This tree read the events itself for as long as
      ;; it had no transient keymap, and every drag fault had to be
      ;; patched in a place Emacs has no such place: a `<resize>' swallow
      ;; in the loop, an `auto-hscroll-mode' `dynamic-wind' around it.
      ;;
      ;; `#f' for PROMOTE-TO-REGION, which Emacs's call leaves out: a
      ;; `define-command' here takes the arguments its interactive
      ;; expression supplies and has no `&optional' to make one skippable,
      ;; so a programmatic call passes the same two.
      ;;
      ;; NOT CARRIED, each named where Emacs has it: `mouse-minibuffer-
      ;; check' (this tree has no minibuffer-only frame);
      ;; `mouse-selection-click-count' and the click count itself, which
      ;; need a clock; `echo-keystrokes' and `make-cursor-line-fully-
      ;; visible', neither of which exists here; `mouse-shift-adjust-
      ;; point'; and the `terminal-parameter' the drag's start event is
      ;; recorded in for `mouse-drag-and-drop-region'.
      ;;--------------------------------------------------------------
      (deactivate-mark)
      (let* ((start-posn (event-start start-event))
             (start-point (posn-point start-posn))
             (start-window (posn-window start-posn))
             ;; "We've recorded what we needed from the current buffer
             ;; and window" - Emacs clears the buffer's deferred
             ;; `deactivate-mark' flag here, because this drag is about to
             ;; set its own region.
             (_ (set!text-editor-deactivate-mark!
                 (window-buffer start-window) #f))
             ;; "now let's jump to the place of the event, where things
             ;; are happening" - the call that selects the window and
             ;; moves point, and that everything below depends on.
             (_ (mouse-set-point start-event #f))
             (bounds (window-edges start-window))
             (top (list-ref bounds 1))
             ;; "Don't count the mode line": the window's last row is its
             ;; mode line, and a pointer on it is outside the text, which
             ;; is why the scrolling test below is `>= BOTTOM'. Emacs
             ;; takes the whole edge when a window has no mode line.
             (bottom (if *mode-line-format*
                         (- (list-ref bounds 3) 1)
                         (list-ref bounds 3)))
             ;; A single click, which is all this tree makes: the click
             ;; count is what a double or triple click multiplies the
             ;; region by, and counting needs a clock.
             (click-count 0)
             (auto-hscroll-saved
              (buffer-auto-hscroll-mode (window-buffer start-window)))
             ;; `track-mouse' is set for the drag and put back by the
             ;; cleanup - Emacs's `old-track-mouse'. It is *whether the
             ;; display makes an event of pointer motion at all*, so the
             ;; front end reads it; `pgtk.sld''s motion handler does.
             (old-track-mouse track-mouse)
             (cleanup (lambda ()
                        (set! track-mouse old-track-mouse)
                        (set!buffer-auto-hscroll-mode
                         (window-buffer start-window) auto-hscroll-saved))))
        ;; "Cleanup on errors" - Emacs's `condition-case'.
        (guard (ex (else (cleanup) (raise ex)))
          ;; In case the down click is in the middle of some intangible
          ;; text, use the end of that text. Below the `mouse-set-point'
          ;; above, so this is the position the drag really starts from.
          (when (< (point) start-point)
            (goto-char start-point))
          (set! start-point (point))
          ;; **Automatic hscrolling off for the duration**, and restored
          ;; by the cleanup, which is where Emacs turns it off and for the
          ;; reason its own comment gives: it "interferes with the natural
          ;; dragging behavior (point will unexpectedly be moved beneath
          ;; the pointer, making selections in auto-scrolling margins
          ;; impossible)". Emacs zeroes `scroll-margin' beside it; there
          ;; is no `scroll-margin' in this tree to zero.
          (set!buffer-auto-hscroll-mode (window-buffer start-window) #f)
          ;; The region is highlighted for the rest of this drag and no
          ;; longer than that: `(cons 'only ...)' is Emacs's own value
          ;; here, and its `deactivate-mark' half is what turns it back.
          ;;
          ;; **`setq-local`, not `setq`** - Emacs writes the *buffer's*
          ;; Transient Mark mode, and so must this: the mode a buffer sees
          ;; is its own value, so a global set here would be invisible to
          ;; `(transient-mark-mode)` and to `region-active-p`.
          (set-buffer-local-value! (current-buffer) 'transient-mark-mode
                                   (cons 'only (transient-mark-mode)))
          ;; "Activate the region, using `mouse-start-end' to determine
          ;; where to put point and mark".
          (let ((range (mouse-start-end start-point start-point click-count)))
            (push-mark (car range) #t #t)
            (goto-char (cadr range)))
          ;; **Never nil and never t**: Emacs sets this to something that
          ;; is neither, so that mouse events are not reported to have
          ;; happened on the tool bar or the tab bar - which would break a
          ;; drag that started in the window body below them
          ;; (`make_lispy_position', bug#51794). The front end's test is
          ;; the C's `!NILP (track_mouse)'.
          (set! track-mouse 'drag-tracking)
          ;; **The map that makes the loop unnecessary.** It is emptied
          ;; by `set-transient-map' when a command it does not bind runs,
          ;; and that command is normally the button coming up.
          ;;
          ;; `[switch-frame]' and `[select-window]' are bound to `ignore'
          ;; so that a *frame* event cannot end a drag - Emacs's own
          ;; lines. This tree invents no such events, and its frame
          ;; events (`<resize>' and the focus pair) do not need the
          ;; binding: they are *special events*, which
          ;; `dispatch-special-event' handles before any map is consulted
          ;; and without `pre-command-hook', exactly as Emacs's
          ;; `read_char' does (`keyboard.c:3113'). Running them as
          ;; ordinary commands is what used to end a drag on a resize.
          ;;
          ;; The movement command is a plain procedure and not a
          ;; `define-command', which is the one departure from Emacs's
          ;; `(lambda (event) (interactive "e") ...)': a lambda cannot
          ;; carry an interactive specification in this tree, and it does
          ;; not need one - the event it would be handed is where
          ;; `*last-read-event*' already is, which is how every command
          ;; here reads a mouse event's position.
          (set-transient-map
           (let ((map (km:keymap '*mouse-drag-map*)))
             (define-key map (kbd "<switch-frame>") ignore)
             (define-key map (kbd "<select-window>") ignore)
             (define-key map (kbd "<mouse-movement>")
                         (lambda ()
                           (%mouse-drag-motion start-window start-point
                                               top bottom)))
             map)
           #t
           ;; ON-EXIT: Emacs's own, minus the context-menu branch that
           ;; keeps the region when `down-mouse-3' came next - there is no
           ;; context menu here.
           (lambda ()
             (cleanup)
             (deactivate-mark)
             (pop-mark))))))

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

    ;; **`mouse.el:3781'\u2013`:3783', all three of them**, and the
    ;; release's two are not decoration:
    ;;
    ;;   [down-mouse-1]  `mouse-drag-region'   the press starts the drag
    ;;   [mouse-1]       `mouse-set-point'     a release with no movement
    ;;   [drag-mouse-1]  `mouse-set-region'    a release *after* movement
    ;;
    ;; The third is what puts the region back after the drag's own
    ;; cleanup has taken it down, so without it a drag highlights the
    ;; text and then loses it the moment the button comes up.
    (define-key *default-keymap* (kbd "<down-mouse-1>") mouse-drag-region)
    (define-key *default-keymap* (kbd "<mouse-1>") mouse-set-point)
    (define-key *default-keymap* (kbd "<drag-mouse-1>") mouse-set-region)

    ))
