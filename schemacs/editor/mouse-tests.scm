;; Tests for `(schemacs editor mouse)', which mirrors GNU Emacs's
;; `mouse.el'. What is here is a whole drag as the *command loop* runs
;; it: the press installs a transient keymap, each motion event is
;; dispatched to it, and the first command the map does not bind pops it
;; and runs the cleanup.
;;
;; **Why this is testable at all.** None of it needs a window on a
;; screen. A frame made with `new-frame' has the geometry
;; (`window-edges', `window-height'), the text is the test's own, the
;; events are made by hand, and the dispatch is `dispatch-key' - the same
;; call the command loop and both front ends make for one event. The one
;; piece that needs a display is the *row* a motion event is on
;; (`%mouse-event-row'), and a display answers `line-height' - one cell is
;; one row - without ever being opened. That display is
;; `(schemacs editor test-display)'s stub.
;;
;; **The events are delivered by key, not by coordinate.** Emacs's map
;; binds `[mouse-movement]' and the front end is what says which event
;; arrived; here the test says so directly, and puts the position where
;; the display would have put it - `*last-read-event*', which is where
;; `dispatch-key' reads a mouse event's value from and where every
;; command in this tree reads it.
;;
;; The buffer every case uses is 100 lines of four characters, so one
;; screen row is one line and one line is five characters: line N begins
;; at position (1 + 5(N - 1)). That is what makes the numbers below
;; arithmetic rather than measurements.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) define-class define-method make)
 ;; The display the events are read from and the row is measured against:
 ;; `(schemacs editor test-display)'s stub, so this suite needs no front
 ;; end - it borrowed `<pgtk-display>' before, for a display object.
 (prefix (only (schemacs editor test-display) <test-display>) stub:)
 ;; the display's generic, renamed: the test defines a method on it,
 ;; and `mouse-position' below is the frame-level function that calls it
 (rename (only (schemacs editor dispnew)
               current-display mouse-position read-input-event)
         (mouse-position display-mouse-position)
         (read-input-event display-read-input-event))
 (only (schemacs editor frame)
       *current-frame* frame-message frame-selected-window mouse-position
       new-frame
       set-window-start!
       window-body-height window-buffer window-edges window-height)
 (only (schemacs editor xdisp)
       render! track-mouse vertical-motion window-end window-start)
 (only (schemacs editor keyboard)
       *last-read-event* *overriding-terminal-local-map*
       *unread-command-events* dispatch-key sit-for)
 (only (schemacs editor mouse) *mouse-scroll-delay* *mouse-scroll-min-lines*)
 (only (schemacs editor simple) region-active-p)
 (only (schemacs editor editfns) point)
 (only (schemacs editor engine)
       new-text-editor text-editor-insert text-editor-set-cursor
       text-editor-get-cursor text-editor-point-max text-editor-mark))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_mouse")

(define-class <test-display> (stub:<test-display>)
  ;; Only the pointer is this suite's own. The *script* of raw events the
  ;; read answers with, and the read itself, are the stub's: its
  ;; `read-input-event' pops `test-display-script' and answers #f when the
  ;; script runs out, which is what a wait that timed out answers.
  (pointer #:init-value #f #:accessor test-display-pointer))
;; ^ A display that answers `mouse-position' with a row the test sets.
;; The real one asks Gdk where the pointer is; the question is the same
;; and that is the point - the drag must not be reading the pointer's row
;; off the event, which is what it did and what made a drag past the
;; window edge scroll one line at a time.

(define-method (display-mouse-position (d <test-display>))
  (test-display-pointer d))

(define d (make <test-display>))
(current-display d)

(define (pointer-at! row)
  ;; Where the pointer is, as the display would answer it.
  ;;--------------------------------------------------------------
  (set! (test-display-pointer d) (cons 0 row)))

(define (numbered-frame lines rows cols)
  ;; A frame on a buffer of LINES numbered lines, drawn once so that the
  ;; window's recorded end is real - `mouse-scroll-subr' reads
  ;; `window-end', and Emacs's own code depends on it being the *old*
  ;; end until the next redisplay, which is what this makes true.
  ;;--------------------------------------------------------------
  (let ((ed (new-text-editor)))
    (let loop ((i 1))
      (when (<= i lines)
        (text-editor-insert ed (string-append (number->string (+ 1000 i)) "\n"))
        (loop (+ i 1))))
    (text-editor-set-cursor ed 1)
    (let ((f (new-frame ed rows cols)))
      (parameterize ((*current-frame* f))
        (render! f))
      f)))

(define (mouse-event key window point row)
  ;; One mouse event as the display would have made it: the key, and the
  ;; position list `(WINDOW POS-OR-AREA (X . Y) TIMESTAMP)'. A #f
  ;; *window* makes it an event outside every window - `posn-window' is
  ;; the frame and `posn-point' is #f, which is what
  ;; `buffer_posn_from_coords' answers for a pointer off the text.
  ;;--------------------------------------------------------------
  (list key (list (or window window) (or point #f) (cons 0 row) 0)))

(define *frame* #f)
(define *window* #f)

(define (event! key window point row)
  ;; Deliver one event through the command loop's own entry point.
  ;;--------------------------------------------------------------
  (let ((ev (list key (list window (or point #f) (cons 0 row) 0))))
    (*last-read-event* ev)
    (dispatch-key *frame* key)))

(define (press! point row)
  (parameterize ((*unread-command-events* '()))
    (event! 'down-mouse-1 *window* point row)))

(define (release! point row)
  ;; The release of a *drag*: GNU Emacs's `drag-mouse-1', which carries
  ;; the press's position and the release's. `mouse.el:3783' binds it to
  ;; `mouse-set-region', and that is what puts the region back after the
  ;; drag's own cleanup has taken it down.
  ;;--------------------------------------------------------------
  (*last-read-event* (list 'drag-mouse-1
                           (list *window* 1 (cons 0 0) 0)
                           (list *window* (or point #f) (cons 0 row) 0)))
  (dispatch-key *frame* 'drag-mouse-1))

(define (drag! f)
  (set! *frame* f)
  (set! *window* (frame-selected-window f))
  *window*)

(define (recentred-on-cursor? w)
  ;; When the cursor is off the window the redisplay's start decision
  ;; recentres it - `redisplay_window''s `recenter:' label, ported as
  ;; `scroll-to-cursor!' - so the window's start lands half a body above
  ;; point. That is the rule a drag past the edge is asserting: it moves
  ;; the window by about half its height, not by `jump' rows. (The same
  ;; rule, and the same arithmetic, as the ncurses suite's recentring
  ;; test; the frames here draw 5 characters to a line.)
  ;;--------------------------------------------------------------
  (= (window-start w)
     (- (point) (* (quotient (window-body-height w) 2) 5))))

(define (bottom-row)
  (- (list-ref (window-edges *window*) 3) 1))

;;-------------------------------------------------------------------
;; `vertical-motion' itself
;;-------------------------------------------------------------------

(let* ((f (numbered-frame 100 24 80))
       (w (frame-selected-window f)))
  (test-equal "vertical-motion moves down the screen lines asked for"
    (list 5 26)
    (list (vertical-motion 5 w) (text-editor-get-cursor (window-buffer w))))
  (test-equal "and up a negative number of them"
    (list -1 21)
    (list (vertical-motion -1 w) (text-editor-get-cursor (window-buffer w))))
  (test-equal "a move of zero goes nowhere"
    (list 0 21)
    (list (vertical-motion 0 w) (text-editor-get-cursor (window-buffer w))))
  ;; The end of the buffer: "the function returns number of screen lines
  ;; moved over; ... may be closer to zero if beginning or end of buffer
  ;; was reached". From the last line there is nowhere to go, and point
  ;; stops at the end of the buffer - which is what makes
  ;; `mouse-scroll-subr''s loop terminate instead of spinning.
  (text-editor-set-cursor (window-buffer w)
                          (text-editor-point-max (window-buffer w)))
  (test-equal "at the end of the buffer, nothing moves"
    (list 0 (text-editor-point-max (window-buffer w)))
    (list (vertical-motion 5 w)
          (text-editor-get-cursor (window-buffer w)))))

;;-------------------------------------------------------------------
;; `mouse-position' is the display's answer, dotted as Emacs gives it
;;-------------------------------------------------------------------

(let ((f (numbered-frame 20 24 80)))
  (parameterize ((*current-frame* f))
    (pointer-at! 7)
    (test-equal "mouse-position answers the frame and the pointer's cell"
      (cons f (cons 0 7))
      (mouse-position))))

;;-------------------------------------------------------------------
;; The press installs the map, and it stays installed
;;-------------------------------------------------------------------

(let* ((f (numbered-frame 100 24 80))
       (w (drag! f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f))
    (press! 1 0)
    (test-equal "the press sets `track-mouse' to `drag-tracking'"
      'drag-tracking
      track-mouse)
    (test-assert "and installs a transient map"
      (pair? *overriding-terminal-local-map*))
    (test-equal "with the mark and point of the press in it"
      (list 1 1 #t)
      (list (text-editor-mark ed) (point) (region-active-p)))
    ;; A motion event the map binds: the command loop dispatches it to
    ;; the map's `[mouse-movement]' lambda, and *that lambda is the map's
    ;; own command*, which is what keeps the map alive.
    (event! 'mouse-movement w 12 2)
    (test-equal "a motion event inside the window moves point"
      12
      (point))
    (test-assert "and leaves the map installed"
      (pair? *overriding-terminal-local-map*))
    ;; **And a frame event does not end it.** In Emacs a resize is not a
    ;; key event at all, and the frame events that are go through
    ;; `special-event-map' inside `read_char' - before any map is
    ;; consulted and without `pre-command-hook', where the map's clearfun
    ;; lives. Running them as ordinary commands is what used to pop the
    ;; map and leave every drag dead the moment the compositor resized
    ;; the window.
    (event! 'resize f #f 0)
    (test-assert "a resize does not end the drag"
      (pair? *overriding-terminal-local-map*))
    ;; **And it is still *handled*, not merely ignored.** A special event
    ;; reaches its `special-event-map' handler before any other map is
    ;; consulted; if it did not, `<resize>' would fall through every map,
    ;; find nothing, and be reported as an undefined key - which would
    ;; leave the map alive for the wrong reason and put a complaint in
    ;; the echo area on every window resize.
    (test-equal "and is dispatched to its handler, not read as an undefined key"
      ""
      (frame-message f))
    ;; The button coming up is a command the map does *not* bind, so it
    ;; is what pops the map and runs the cleanup.
    (release! 12 12)
    (test-equal "the release pops the map"
      #f
      *overriding-terminal-local-map*)
    (test-equal "and puts `track-mouse' back"
      #f
      track-mouse)
    ;; **And the region is still there.** The pop's ON-EXIT deactivated
    ;; it, and `[drag-mouse-1]' - the command that ran next - is what put
    ;; it back: `mouse-set-region''s `push-mark'/`set-mark' and
    ;; `mouse-set-region-1''s `(cons 'only ...)'. Without that binding a
    ;; drag highlighted and then lost the highlight the instant the
    ;; button came up.
    (test-equal "and `mouse-set-region' leaves the region active"
      (list 1 12 #t)
      (list (text-editor-mark ed) (point) (region-active-p)))))

;;-------------------------------------------------------------------
;; A click is `mouse-1' and does not leave a region
;;-------------------------------------------------------------------

(let ((f (numbered-frame 100 24 80)))
  (drag! f)
  (parameterize ((*current-frame* f))
    (press! 1 0)
    (test-equal "a click's press leaves the region active"
      #t
      (region-active-p))
    (event! 'mouse-1 *window* 40 3)
    (test-equal "and the click's release pops the drag's map"
      #f
      *overriding-terminal-local-map*)
    ;; `[mouse-1]' is `mouse-set-point' (Emacs's `mouse.el:3782'), so a
    ;; click moves point where it landed - and the map's ON-EXIT took the
    ;; region down, with nothing after it to put one back.
    (test-equal "and moves point to where the click landed"
      40
      (point))
    (test-equal "and leaves no region"
      #f
      (region-active-p))))

;;-------------------------------------------------------------------
;; A drag past the bottom edge scrolls the window
;;-------------------------------------------------------------------

(let* ((f (numbered-frame 100 24 80))
       (w (drag! f))
       (mouse-row 30)
       ;; The number of rows the pointer is below the window's last text
       ;; row - the JUMP Emacs computes as `(1+ (- mouse-row bottom))'
       ;; (`mouse.el:2024').
       (jump (+ 1 (- mouse-row (bottom-row))))
       (start-before (window-start w)))
  (parameterize ((*current-frame* f)
                 (*unread-command-events* (list 'mouse-1)))
    (press! 1 0)
    (pointer-at! mouse-row)
    (event! 'mouse-movement f #f mouse-row)
    ;; The release was queued, so the scroll loop's `sit-for' saw input
    ;; at once and made exactly one step - Emacs's own exit condition
    ;; ("until new input arrives") with the input supplied rather than
    ;; waited for.
    (test-equal "a drag below the window moves it by a recentre, not by jump"
      #t
      (recentred-on-cursor? w))
    ;; **One row past the window's last row**, which is what makes the
    ;; drag scroll by half a page a step: the redisplay's start decision
    ;; (`scroll-to-cursor!') recentres a cursor that is off the bottom,
    ;; and that is the "half a page" a drag past the edge moves by - the
    ;; same thing as moving the keyboard cursor off the bottom row. A
    ;; cursor left *on* the last row leaves the redisplay nothing to do.
    (test-equal "point is left one row past the window's last row"
      (+ 1 (* (+ jump (window-body-height w)) 5))
      (point))
    (test-assert "the window really did move past where it was"
      (> (window-start w) start-before))
    (test-equal "and the region from the press is still active"
      #t
      (region-active-p))
    (release! 1 mouse-row)))

;; **The row is the display's, not the event's.** A motion event whose
;; own coordinates say nothing useful - which is what an event carries
;; once the pointer has left the window - still scrolls by whatever the
;; display answers. This is the regression for a drag that scrolled one
;; line at a time: the event's row and the pointer's row are only the
;; same while the pointer is inside the window.
(let* ((f (numbered-frame 100 24 80))
       (w (drag! f)))
  (parameterize ((*current-frame* f)
                 (*unread-command-events* (list 'mouse-1)))
    (press! 1 0)
    (pointer-at! (+ (bottom-row) 9))
    ;; the event's own coordinates say row 1; the display says nine rows
    ;; past the bottom edge
    (event! 'mouse-movement f #f 1)
    (test-equal "the row comes from `mouse-position', not the event"
      #t
      (recentred-on-cursor? w))
    (release! 1 1)))

;; The pointer *on* the mode line counts as outside the text - which is
;; why Emacs's test is `>= BOTTOM' and not `>': the mode line's row is
;; `bottom', one short of the window's last row.
(let* ((f (numbered-frame 100 24 80))
       (w (drag! f)))
  (parameterize ((*current-frame* f)
                 (*unread-command-events* (list 'mouse-1)))
    (press! 1 0)
    (pointer-at! (bottom-row))
    (event! 'mouse-movement f #f (bottom-row))
    (test-equal "a drag onto the mode line recentres too"
      #t
      (recentred-on-cursor? w))
    (release! 1 (bottom-row))))

;;-------------------------------------------------------------------
;; A drag above the top edge scrolls back
;;-------------------------------------------------------------------

(let* ((f (numbered-frame 100 24 80))
       (w (drag! f)))
  ;; Start well down the buffer, so there is somewhere to scroll back to.
  (set-window-start! w 251)
  (parameterize ((*current-frame* f)
                 (*unread-command-events* (list 'mouse-1)))
    (press! 251 0)
    ;; A pointer *above* the window is a negative frame row, which with
    ;; the window's top at row 0 is the only way to be above it. JUMP is
    ;; `(- mouse-row top)' = -1, clamped by `mouse-scroll-min-lines' to
    ;; -1, so the window moves back one row.
    (pointer-at! -1)
    (event! 'mouse-movement f #f -1)
    (test-equal "a drag above the window scrolls it back"
      246
      (window-start w))
    (release! 1 -1)))

;;-------------------------------------------------------------------
;; Held out of the window with nothing typed, it keeps scrolling
;;-------------------------------------------------------------------

;; "Scroll the window WINDOW, JUMP lines at a time, until new input
;; arrives." With `mouse-scroll-delay' at zero - "causes Emacs to scroll
;; as fast as it can" - and nothing waiting, the loop runs on until the
;; window cannot scroll again, which is the end of the buffer.
(let* ((f (numbered-frame 100 24 80))
       (w (drag! f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f)
                 (*unread-command-events* '())
                 (*mouse-scroll-delay* 0))
    (press! 1 0)
    (pointer-at! 30)
    (event! 'mouse-movement f #f 30)
    (test-equal "held past the bottom, it scrolls to the end of the buffer"
      (text-editor-point-max ed)
      (window-start w))
    (test-assert "and the map survives it"
      (pair? *overriding-terminal-local-map*))
    (event! 'mouse-1 f #f 30)))

;;-------------------------------------------------------------------
;; `sit-for' puts an event back rather than eating it
;;-------------------------------------------------------------------

(let ((f (numbered-frame 20 24 80)))
  (parameterize ((*current-frame* f)
                 (*unread-command-events* (list 'mouse-1)))
    (test-equal "sit-for with input waiting answers nil at once"
      #f
      (sit-for 5 #f))
    (test-equal "and the event is still there to be read"
      (list 'mouse-1)
      (*unread-command-events*))))

;;-------------------------------------------------------------------
;; A frame resize is not input: the read handles it and waits on
;;-------------------------------------------------------------------

;; GNU Emacs's `read_char' (`keyboard.c:3108'): "Process special events
;; within read_char and loop around to read another event." The event is
;; looked up in `special-event-map', its handler runs, and the read goes
;; round again - so whoever asked for a key never learns a resize
;; happened. That is what keeps `mouse-scroll-subr''s loop going while a
;; drag holds the pointer out of a window: the loop ends on any input at
;; all, and a resize is not input. Returning the resize is what made a
;; drag past the edge scroll one step per resize event.
;;
;; `*resize-code*' is the display's own value for it, which is what
;; `pgtk-item->event' maps `resize' to and what `key-event->key' answers
;; `resize' for; `[resize]' is bound to `ignore' in `special-event-map'.

(define (scripted! events)
  (set! (test-display-script d) events))

(let ((f (numbered-frame 20 24 80)))
  (parameterize ((*current-frame* f) (*unread-command-events* '()))
    (scripted! '())
    (test-equal "a timed read with nothing to read waits and answers t"
      #t (sit-for 0.02 #f))
    (scripted! (list -1))               ; a frame resize, and then silence
    (test-equal "a frame resize does not end a timed read"
      #t (sit-for 0.02 #f))
    (scripted! (list -1 -1 -1))
    (test-equal "nor do three of them"
      #t (sit-for 0.02 #f))
    (scripted! (list -1 97))            ; a resize, and then `a'
    (test-equal "and a key after a resize is still read"
      #f (sit-for 0.5 #f))
    (test-equal "the key is the one that arrived, not the resize"
      (list 97) (*unread-command-events*))))

;;-------------------------------------------------------------------
;; `window-end' is *past* the last character displayed
;;-------------------------------------------------------------------

;; GNU Emacs's `window-end' (`window.c'), "the position after the final
;; character in WINDOW", which for a window whose last row ends a line is
;; the position *after* that line's break - the C's row ends at
;; `MATRIX_ROW_END_CHARPOS', and a line break is one of the row's glyphs.
;; Answering the break's own position is one character short, and the
;; consumer that cares is `mouse-scroll-subr': it measures the far edge
;; from here, so being short left point a row above the bottom of the
;; window - the last line never selected by a drag that had scrolled, and
;; the redisplay's recentre decided from a cursor that was still on the
;; screen.
;;
;; A 24-row frame has a 23-row body; the buffer's lines are 5 characters
;; ("1001\n"), so the window shows lines 1..23 and its end is the start of
;; line 24, one past line 23's break.
(let* ((f (numbered-frame 100 24 80))
       (w (frame-selected-window f)))
  (parameterize ((*current-frame* f))
    (render! f)
    (test-equal "window-end is one past the last line displayed"
      (+ 1 (* (window-body-height w) 5))
      (window-end w))))

(test-end "schemacs_editor_mouse")
