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
 (only (guile) setvbuf usleep)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) define-class define-method make)
 (only (guile) module-ref resolve-module)
 ;; The display the events are read from and the row is measured against:
 ;; `(schemacs editor test-display)'s stub, so this suite needs no front
 ;; end - it borrowed `<pgtk-display>' before, for a display object.
 (prefix (only (schemacs editor test-display) <test-display>) stub:)
 ;; ...and its *script*, which is the stub's own and is read and written
 ;; unprefixed here: the class below inherits it, and `scripted!' sets it.
 ;; Leaving it out is the missing-import class - it is not a load error,
 ;; it is an unbound variable the first time a test runs, which took this
 ;; whole suite out of the battery with "Unbound variable:
 ;; test-display-script" and no test line at all.
 (only (schemacs editor test-display) test-display-script)
 ;; the display's generic - `display-mouse-position', which is the C's
 ;; `mouse_position_hook' field and not the Lisp `mouse-position' - and
 ;; `mouse-position' below is the frame-level function that calls it
 (rename (only (schemacs editor dispnew)
               current-display display-mouse-position key-event->key
               display-define-frame-cursor
               read-input-event)
         (read-input-event display-read-input-event))
 (only (schemacs editor frame)
       *current-frame* *echo-area-buffer* *frame-list* frame? frame-height
       *default-frame-alist*
       frame-minibuffer-window frame-windows minibuffer-window-active-p
       select-window window-live-p
       set-window-buffer! window-height window-top window-list
       frame-message frame-keymap-state
       selected-window
       frame-selected-window mouse-position
       new-frame window-last-mode-line
       set-window-start!
       window-body-height window-body-left window-buffer window-edges
       window-height window-left window-width)
 (only (schemacs editor xdisp)
       posn-at-x-y posn-at-point render! track-mouse vertical-motion
       window-end window-start
       ;; the mouse face - `note_mouse_highlight` and the pieces its
       ;; highlight is made of
       note-mouse-highlight mouse-face-at mouse-highlight
       face-at-buffer-position *drawing-window*)
 ;; the row a highlight is painted into: the current matrix's glyphs
 (only (schemacs editor matrix) window-current-matrix glyph-matrix-row-ref)
 (only (schemacs editor glyph) glyph-row-glyphs glyph-face-id)
 (only (schemacs editor keyboard)
       *last-read-event* *overriding-terminal-local-map*
       *unread-command-events* dispatch-key sit-for
       key-translation-translate)
 (only (schemacs editor mouse) *mouse-scroll-delay* *mouse-scroll-min-lines*
       *mouse-1-click-follows-link*
       mouse-minibuffer-check posn-set-point
       mouse-on-link-p mouse--down-1-maybe-follows-link
       mouse--click-1-maybe-follows-link)
 ;; `follow-link` is a text property, and the click that follows it reads
 ;; it with `get-char-property`.
 (only (schemacs editor textprop) put-text-property remove-text-properties
       get-text-property)
 ;; `mouse-on-link-p` of a *buffer position* (not a posn) reads the
 ;; current buffer's properties.
 (only (schemacs editor buffer) *current-buffer*)
(only (schemacs editor subr) event-start posn-window posn-area posn-string
       posn-point)
 (only (schemacs editor fns) equal-including-properties)
 (only (schemacs editor window) other-window split-window
       adjust-window-trailing-edge)
 (only (schemacs editor keymap) *default-keymap*)
 (only (schemacs editor simple) region-active-p)
 (only (schemacs editor editfns) point insert
)
 
 ;; `%mark-marker` is the buffer's mark slot - `BVAR (b, mark)` - and
 ;; `text-editor-mark`, the read that used to be here, is gone.
 (only (schemacs editor buffer) %mark-marker with-current-buffer
 set-point allocate-buffer buffer-pt buffer-z
 get-buffer-create)
 (only (schemacs editor marker) marker-position))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_mouse")

(define-class <test-display> (stub:<test-display>)
  ;; Only the pointer is this suite's own. The *script* of raw events the
  ;; read answers with, and the read itself, are the stub's: its
  ;; `read-input-event' pops `test-display-script' and answers #f when the
  ;; script runs out, which is what a wait that timed out answers.
  (pointer #:init-value #f #:accessor test-display-pointer)
  ;; The cursor shape the frame last asked for - `set_cursor:`'s
  ;; `define_frame_cursor1`, recorded by the method below so the pointer
  ;; tests can read the decision. Not called `cursor`: the stub's own
  ;; `cursor` slot records the drawn cursor's `(ROW COLUMN TYPE)`, and a
  ;; subclass slot of that name redefines the stub's accessor.
  (frame-cursor #:init-value #f #:accessor test-display-frame-cursor))
;; ^ A display that answers `mouse-position' with a row the test sets.
;; The real one asks Gdk where the pointer is; the question is the same
;; and that is the point - the drag must not be reading the pointer's row
;; off the event, which is what it did and what made a drag past the
;; window edge scroll one line at a time.

(define-method (display-mouse-position (d <test-display>))
  (test-display-pointer d))

(define *resize-code* -1)
;; ^ This display's own value for "the frame was resized", which is
;; `pgtk.sld''s (`(define *resize-code* -1)', and `pgtk-item->event' maps
;; `resize' to it). It is the *test's* here because a resize code is the
;; front end's fact, not a generic one - `term.sld' answers `resize' for
;; ncurses's `KEY_RESIZE' instead. The tests at the bottom of this file
;; feed `-1' and expect it to be a resize and not a key, so the display
;; has to say so; without this method the value went to `keymap-index' as
;; a plain integer event, came out as `(integer->char 4194303)' and died
;; with "Argument 1 out of range" - four tests, and the whole suite was
;; out of the battery before that for the missing `test-display-script'.

(define-method (key-event->key (d <test-display>) ev)
  ;; The one keycode this display names. Everything else is the stub's
  ;; own rule - a character is a byte is an event - via `next-method'.
  ;;--------------------------------------------------------------
  (if (eqv? ev *resize-code*) 'resize (next-method)))

(define d (make <test-display>))
(current-display d)

(define (pointer-at! row)
  ;; Where the pointer is, as the display would answer it.
  ;;--------------------------------------------------------------
  (set! (test-display-pointer d) (cons 0 row)))

;; **The test frames have no menu bar.** A terminal frame shows one by
;; default and the bar takes the frame's first row; these tests measure
;; pointer rows from the top of the text. See `tty-editor-tests.scm` for
;; the same fixture.
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define (numbered-frame lines rows cols)
  ;; A frame on a buffer of LINES numbered lines, drawn once so that the
  ;; window's recorded end is real - `mouse-scroll-subr' reads
  ;; `window-end', and Emacs's own code depends on it being the *old*
  ;; end until the next redisplay, which is what this makes true.
  ;;--------------------------------------------------------------
  (let ((ed (allocate-buffer)))
    (let loop ((i 1))
      (when (<= i lines)
        (with-current-buffer ed (insert (string-append (number->string (+ 1000 i)) "\n")))
        (loop (+ i 1))))
    (set-point ed 1)
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
  ;; rule, and the same arithmetic, as the tty suite's recentring
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
    (list (vertical-motion 5 w) (buffer-pt (window-buffer w))))
  (test-equal "and up a negative number of them"
    (list -1 21)
    (list (vertical-motion -1 w) (buffer-pt (window-buffer w))))
  (test-equal "a move of zero goes nowhere"
    (list 0 21)
    (list (vertical-motion 0 w) (buffer-pt (window-buffer w))))
  ;; The end of the buffer: "the function returns number of screen lines
  ;; moved over; ... may be closer to zero if beginning or end of buffer
  ;; was reached". From the last line there is nowhere to go, and point
  ;; stops at the end of the buffer - which is what makes
  ;; `mouse-scroll-subr''s loop terminate instead of spinning.
  (set-point (window-buffer w)
                          (buffer-z (window-buffer w)))
  (test-equal "at the end of the buffer, nothing moves"
    (list 0 (buffer-z (window-buffer w)))
    (list (vertical-motion 5 w)
          (buffer-pt (window-buffer w)))))

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
      (list (marker-position (%mark-marker ed)) (point) (region-active-p)))
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
      (list (marker-position (%mark-marker ed)) (point) (region-active-p)))))

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
    ;; **The walk leaves point one row past the last row, and the
    ;; redisplay moves it back in.** `mouse-scroll-subr`'s own
    ;; `(set-window-start window (point))` sets `w->force_start`, so the
    ;; redisplay that the loop's next `sit-for` asks for keeps the start
    ;; and moves *point* instead - "Give up and just move to the middle
    ;; of the window" (`xdisp.c:20823`) - which is
    ;; `scroll-to-cursor!`'s `force_start` branch. That is the same
    ;; recentre the assertion above measures, seen from point's side.
    (test-equal "the redisplay moves point into the dragged window"
      (+ (window-start w) (* (quotient (window-body-height w) 2) 5))
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
      (buffer-z ed)
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

;;-------------------------------------------------------------------
;; A click on the echo area row
;;-------------------------------------------------------------------
;;
;; The echo area is a row of the frame, not a minibuffer window, so
;; `posn-at-x-y` answers the *frame* for a click there and `posn-set-point`
;; would hand a frame to `select-window` - "Wrong type argument: #<<frame>".
;; GNU Emacs never reaches that state because `mouse-set-point` calls
;; `mouse-minibuffer-check` first, and this is that guard.
;;
;; Not active: refused, as Emacs refuses a click on an inactive minibuffer.
;; Active (a prompt is up): allowed, because the click is inside that
;; recursive edit already.
(let* ((ed (allocate-buffer))
       (f (new-frame ed 24 80))
       (mini (frame-minibuffer-window f)))
  (with-current-buffer ed (insert "hello\n"))
  ;; a frame of its own: `posn-at-x-y` walks `(window-list frame)`, and
  ;; the minibuffer window is in that list only while it is active
  (parameterize ((*current-frame* f) (*frame-list* (list f))
                 (*echo-area-buffer* #f))
    (render! f)
    (let ((echo-row (- (frame-height f) 1))
          (event (lambda (row) (list 'down-mouse-1 (posn-at-x-y 0 row f)))))
      ;; **with no prompt the echo row is nobody's window**, which is
      ;; Emacs's rule for an inactive minibuffer window: `window-list`
      ;; leaves it out, so the position is the frame's and there is
      ;; nothing to select.
      (test-equal "with no prompt the echo row names the frame"
        #t (frame? (posn-window (event-start (event echo-row)))))
      ;; **with a prompt up it is the minibuffer window**, and that is
      ;; what makes both a click and `C-x o` reach it.
      (parameterize ((*echo-area-buffer* (get-buffer-create "*echo*")))
        (set-window-buffer! mini (*echo-area-buffer*))
        (test-equal "with a prompt the echo row names the minibuffer window"
          #t (eq? mini (posn-window (event-start (event echo-row)))))
        (test-equal "and that window is active"
          #t (minibuffer-window-active-p mini))
        (test-equal "so selecting it works, which is the click"
          #t (begin (posn-set-point (posn-at-x-y 0 echo-row f))
                    (eq? (selected-window) mini)))
        ;; the assertion above left the minibuffer selected, so start
        ;; from an ordinary window
        (select-window (car (frame-windows f)))
        (test-equal "C-x o reaches the prompt"
          #t (begin (other-window 1) (eq? (selected-window) mini)))
        (test-equal "and C-x o comes back out of it"
          #t (begin (other-window 1)
                    (eq? (selected-window) (car (frame-windows f))))))
      ;; and a click in the text area still selects its own window
      (test-equal "a click in the text area selects that window"
        #t
        (let ((p (posn-at-x-y 0 2 f)))
          (posn-set-point p)
          (eq? (posn-window p) (selected-window)))))))

;; **`event-start` for a keyboard key** - `subr.el`'s
;; `event--posn-at-point`: a key event is an integer or a symbol, not a
;; mouse position, and Emacs answers the position of point in the
;; selected window rather than nil. `tab-line-switch-to-next-tab` is
;; bound to `C-x <right>` and reads
;; `(posn-window (tab-line-event-start event))`, so nil here was
;; "Wrong type argument in position 1 (expecting struct): #f" the moment
;; the tab line was on.
(test-equal #t
  (let ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (eq? (posn-window (event-start 32)) (selected-window)))))

;; And `posn-at-point` answers the window for a position that is on
;; screen, and nil for one that is not.
(test-equal '(#t #f)
  (let ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (let ((w (selected-window)))
        (list (eq? (posn-window (posn-at-point 1 w)) w)
              (posn-at-point 10000 w))))))

;;--------------------------------------------------------------------
;; Following links with mouse-1 - `mouse.el:67-206'
;;--------------------------------------------------------------------
;; A mouse-1 release within `mouse-1-click-follows-link` of its press,
;; over text carrying a `follow-link` property, is turned into a mouse-2
;; event *at the same position*. That is how the Occur buffer's lines are
;; clickable: `occur-mode` marks them `follow-link`, `occur-mode-map`
;; binds `[mouse-2]`, and the translation is what makes a left click
;; reach it. The position travelling with the translated event is the
;; whole point of it - without it the command acts on point rather than
;; on the line that was clicked.

(test-equal '(#t #f)
  (let* ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (let ((w (selected-window)))
        (put-text-property 1 6 'follow-link #t (window-buffer w))
        (list (mouse-on-link-p (list w 1 (cons 0 0) 0))
              (mouse-on-link-p (list w 7 (cons 0 0) 0)))))))

;; `(mouse-on-link-p POS)` where POS is *not* a cons is a buffer
;; position in the current buffer, and asks the same question there.
(test-equal '(#t #f)
  (let ((f (numbered-frame 3 24 80)))
    ;; The bindings of one `parameterize` are evaluated outside it, as
    ;; `let`'s are, so the buffer has to be read where the frame is
    ;; already current.
    (parameterize ((*current-frame* f))
      (parameterize ((*current-buffer* (window-buffer (selected-window))))
        (put-text-property 1 6 'follow-link #t)
        (list (mouse-on-link-p 1) (mouse-on-link-p 7))))))

;; The press records, the release translates - and the answer is the
;; *whole* event, `(mouse-2 POSN)`, so `event-start` still names the
;; clicked place. Emacs's `(setf (car last-input-event) newup)`.
(test-equal '(1 mouse-2 #t #t)
  (let* ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (let* ((w (selected-window))
             (posn (list w 1 (cons 0 0) 0))
             (down (list 'down-mouse-1 posn))
             (up (list 'mouse-1 posn)))
        (put-text-property 1 6 'follow-link #t (window-buffer w))
        (mouse--down-1-maybe-follows-link down)
        (let ((answer (mouse--click-1-maybe-follows-link up)))
          (list (vector-length answer)
                (car (vector-ref answer 0))
                (eq? (cadr (vector-ref answer 0)) posn)
                (eq? (event-start (vector-ref answer 0)) posn)))))))

;; And through the command loop's own translation step: the key that
;; comes out is `mouse-2`, and `*last-read-event*` is the translated
;; event - which is where `occur-mode-goto-occurrence`'s
;; `last-nonmenu-event` and every mouse command read the position from.
(test-equal '(mouse-2 mouse-2 #t)
  (let* ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (let* ((w (selected-window))
             (posn (list w 1 (cons 0 0) 0))
             (down (list 'down-mouse-1 posn))
             (up (list 'mouse-1 posn)))
        (put-text-property 1 6 'follow-link #t (window-buffer w))
        (mouse--down-1-maybe-follows-link down)
        (*last-read-event* up)
        (let ((key (key-translation-translate 'mouse-1)))
          (list key (car (*last-read-event*))
                (eq? (cadr (*last-read-event*)) posn)))))))

;; Off the link the release stays a `mouse-1`: it keeps its ordinary
;; binding (`mouse-set-point`), and nothing is mutated.
(test-equal '(mouse-1 mouse-1)
  (let* ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f))
      (let* ((w (selected-window))
             (posn (list w 7 (cons 0 0) 0))
             (down (list 'down-mouse-1 posn))
             (up (list 'mouse-1 posn)))
        (put-text-property 1 6 'follow-link #t (window-buffer w))
        (mouse--down-1-maybe-follows-link down)
        (*last-read-event* up)
        (list (key-translation-translate 'mouse-1) (car (*last-read-event*)))))))

;; The time is the switch: a press held longer than
;; `mouse-1-click-follows-link` is an ordinary mouse-1, so the click sets
;; point and does not follow. 0 milliseconds makes every release too
;; slow. A negative value reverses the rule - only a *long* press
;; follows - and the press here is made 10 ms long so the test does not
;; depend on how fast this machine runs the two calls.
(test-equal '(#f #t)
  (let* ((f (numbered-frame 3 24 80)))
    (parameterize ((*current-frame* f) (*mouse-1-click-follows-link* 0))
      (let* ((w (selected-window))
             (posn (list w 1 (cons 0 0) 0))
             (down (list 'down-mouse-1 posn))
             (up (list 'mouse-1 posn)))
        (put-text-property 1 6 'follow-link #t (window-buffer w))
        (mouse--down-1-maybe-follows-link down)
        ;; The answer is a key *sequence* - a vector whose one element is
        ;; the translated event - and `equal?` over it would walk the
        ;; window record and its frame, so the test reads the event's
        ;; name rather than comparing the vector.
        (list (mouse--click-1-maybe-follows-link up)
              (parameterize ((*mouse-1-click-follows-link* -1))
                (mouse--down-1-maybe-follows-link down)
                (usleep 10000)
                (let ((answer (mouse--click-1-maybe-follows-link up)))
                  (and (vector? answer) (> (vector-length answer) 0)
                       (pair? (vector-ref answer 0))
                       (eq? 'mouse-2 (car (vector-ref answer 0)))))))))))

;;----------------------------------------------------------------
;; The mouse face - `note_mouse_highlight` (`xdisp.c:37061`)
;;----------------------------------------------------------------
;; What Emacs does when the pointer is over a `mouse-face` run: the run
;; is highlighted by painting it with the `highlight` face, which is
;; what Occur's search hits and Dired's file names ask for. The state is
;; the display's, not the buffer's, so this is a redisplay test: the
;; primitive decides, and the row builder is what paints.
(test-begin "schemacs_editor_mouse_face")

(let ((f (numbered-frame 10 10 40)))
  (parameterize ((*current-frame* f))
    (let* ((w (selected-window))
           (b (window-buffer w)))
      ;; Line 3 is positions 11..15 ("1003\n"), and the run is put in
      ;; the *middle* of it: no `face` property changes there, so a
      ;; renderer that split runs only on `face` would paint the whole
      ;; line with one token and the highlight would never appear. That
      ;; is the Dired shape, where the name sits inside a line.
      (put-text-property 13 15 'mouse-face 'highlight b)
      (test-equal "mouse-face-at answers the run" '(highlight 13 15)
                  (mouse-face-at w 13))
      (test-equal "a position with no mouse-face answers #f" #f
                  (mouse-face-at w 6))
      ;; The state machine, by the C's answers: entering highlights,
      ;; a report inside the same run does nothing, leaving clears.
      (test-equal "entering the run highlights" #t
                  (note-mouse-highlight f 3 2))
      (test-equal "a second report on the same run changes nothing" #f
                  (note-mouse-highlight f 3 2))
      ;; With the state set, the run's edges split the face runs: the
      ;; token at 12 (before the run) differs from 13 (inside it) only
      ;; when the window being drawn is the one the pointer is over.
      (let ((bound (lambda (pos) (parameterize ((*drawing-window* w))
                                   (face-at-buffer-position b pos))))
            (plain (lambda (pos) (face-at-buffer-position b pos))))
        (test-assert "the drawing window sees the mouse face"
                     (not (= (bound 12) (bound 13))))
        (test-assert "with no window bound every position is the plain face"
                     (= (plain 12) (plain 13))))
      ;; And the pixels: the glyph at the run's start (position 13, which
      ;; is glyph 2 of row 2) carries the mouse face's token.
      (render! f)
      (let* ((row (glyph-matrix-row-ref (window-current-matrix w) 2))
             (g (vector-ref (glyph-row-glyphs row) 2)))
        (test-equal "the row is painted with the mouse face"
                    (parameterize ((*drawing-window* w))
                      (face-at-buffer-position b 13))
                    (glyph-face-id g)))
      (test-equal "leaving the run clears" #t
                  (note-mouse-highlight f 0 1))
      (test-equal "and the row is painted plain again" #t
                  (begin
                    (render! f)
                    (let* ((row (glyph-matrix-row-ref
                                 (window-current-matrix w) 2))
                           (g (vector-ref (glyph-row-glyphs row) 2)))
                      (= (face-at-buffer-position b 13)
                         (glyph-face-id g)))))
      ;; `mouse-highlight` is Emacs's off switch - a plain variable,
      ;; `setq`-ed by a user, so this binds it by hand and puts it back.
      (test-equal "entering again highlights" #t
                  (note-mouse-highlight f 3 2))
      (let ((saved mouse-highlight))
        (set! mouse-highlight #f)
        (test-equal "mouse-highlight nil clears the run" #t
                    (note-mouse-highlight f 3 2))
        (test-equal "and lights nothing" #f
                    (note-mouse-highlight f 3 2))
        (set! mouse-highlight saved)))))

(test-end "schemacs_editor_mouse_face")

;;----------------------------------------------------------------
;; The mode line as a handle - `mouse.el:871-1180`, `:3818`
;;----------------------------------------------------------------
;; A press on a mode line drags the window's bottom edge; the click
;; selects the window it belongs to, mouse-2 deletes the other windows
;; and mouse-3 deletes that one. The events are the display's own shape -
;; a posn whose AREA is `mode-line` and whose object is the drawn mode
;; line string - delivered through `dispatch-key`, the same call the
;; command loop makes.
(test-begin "schemacs_editor_mouse_mode_line")

;; The mode line's string is the click's object - `store_mode_line_string`
;; - which is what makes the `keymap`/`local-map` properties on it
;; readable at all.
(let ((f (numbered-frame 10 12 40)))
  (parameterize ((*current-frame* f))
    (let* ((w (selected-window))
           (row (+ (window-top w) (window-height w) -1))
           (posn (posn-at-x-y 3 row f))
           (ps (posn-string posn)))
      (test-equal "the mode line posn names the mode-line area" 'mode-line
                  (posn-area posn))
      (test-assert "and carries the drawn string and an offset in it"
                   (and (pair? ps) (string? (car ps))
                        (integer? (cdr ps))
                        (< (cdr ps) (string-length (car ps)))))
      (test-assert "the string is the one drawn"
                   (equal-including-properties
                    (car ps) (car (window-last-mode-line w)))))))

;; `[mode-line mouse-1]` runs `mouse-select-window`: the window whose mode
;; line was clicked becomes the selected one, and point does not move.
(let ((f (numbered-frame 20 12 40)))
  (parameterize ((*current-frame* f))
    (let* ((top (selected-window))
           (bottom (split-window top #f 'below))
           (row (+ (window-top bottom) (window-height bottom) -1)))
      (select-window top)
      (*last-read-event* (list 'mouse-1 (list bottom 'mode-line (cons 1 row) 0)))
      (dispatch-key f 'mouse-1)
      (test-equal "clicking a mode line selects its window"
                  (list #t 1)
                  (list (eq? (selected-window) bottom) (point))))))

;; `[mode-line down-mouse-1]` is `mouse-drag-mode-line`: the press
;; installs the transient map, each `mouse-movement` resizes the window
;; whose mode line it was, and the first key the map does not bind ends
;; the drag (`mouse-drag-line`, `mouse.el:871`).
(let ((f (numbered-frame 20 12 40)))
  (parameterize ((*current-frame* f))
    (let* ((top (selected-window))
           (bottom (split-window top #f 'below))
           (h-top (window-height top))
           (h-bottom (window-height bottom))
           (row (+ (window-top top) (window-height top) -1)))
      (pointer-at! row)
      (*last-read-event* (list 'down-mouse-1
                               (list top 'mode-line (cons 1 row) 0)))
      (dispatch-key f 'down-mouse-1)
      (test-equal "adjust-window-trailing-edge moves the edge directly"
                  (list 2 -2)
                  (let ((f2 (numbered-frame 20 12 40)))
                    (parameterize ((*current-frame* f2))
                      (let* ((t2 (selected-window))
                             (b2 (split-window t2 #f 'below))
                             (a (window-height t2)) (bb (window-height b2)))
                        (adjust-window-trailing-edge t2 2 #f #t)
                        (list (- (window-height t2) a) (- (window-height b2) bb))))))
      (test-equal "the press starts tracking the mouse" 'dragging track-mouse)
      (test-equal "no modal state is left after the press" #f (frame-keymap-state f))
      ;; Two rows down: the window above the dragged mode line grows by
      ;; two rows and the one below gives them up.
      (pointer-at! (+ row 2))
      (*last-read-event* (list 'mouse-movement
                               (list top 'mode-line (cons 1 (+ row 2)) 0)))
      (dispatch-key f 'mouse-movement)
      (test-equal "dragging the mode line down resizes both windows"
                  (list 2 -2)
                  (list (- (window-height top) h-top)
                        (- (window-height bottom) h-bottom)))
      ;; **A `drag-mouse-1` ends the drag** - the release of a real drag,
      ;; which the front end names `drag-mouse-1` once the pointer has
      ;; moved (`mouse.el:3783`), and which `mouse-drag-line`'s transient
      ;; map binds to its own exit. A *no-motion* `mouse-1` release does
      ;; not: `read_key_sequence` disposes of an unbound up click
      ;; (`keyboard.c:12115`) instead of running a command, so neither
      ;; the map nor `track-mouse` is touched by it - the C's own comment
      ;; at the vertical-line binding ("swallow also a mouse-1 event ...
      ;; to allow mouse-1 clicks to get through") assumes exactly that.
      (*last-read-event* (list 'drag-mouse-1
                               (list top 'mode-line (cons 1 row) 0)
                               (list top 'mode-line (cons 1 (+ row 2)) 0)))
      (dispatch-key f 'drag-mouse-1)
      (test-equal "the drag ends and mouse tracking is restored" #f track-mouse))))


(let ((f (numbered-frame 20 12 40)))
  (parameterize ((*current-frame* f))
    (let* ((top (selected-window))
           (bottom (split-window top #f 'below))
           (row (+ (window-top bottom) (window-height bottom) -1)))
      (*last-read-event* (list 'mouse-3 (list bottom 'mode-line (cons 1 row) 0)))
      (dispatch-key f 'mouse-3)
      (test-equal "mouse-3 on a mode line deletes that window"
                  (list 1 #t)
                  (list (length (window-list f))
                        (window-live-p top))))))

(test-end "schemacs_editor_mouse_mode_line")

;;----------------------------------------------------------------
;; The pointer's shape - the `set_cursor:` decision (`xdisp.c:36690`)
;;----------------------------------------------------------------
;; "The mouse cursor should change when you hover the mode line": a
;; mode line that can be dragged by its edge shows the vertical-drag
;; cursor, a `mouse-face` run shows the hand, and a `pointer` text
;; property wins over everything. The decision is
;; `frame-cursor-for-posn`, and what it asks the display for is
;; `display-define-frame-cursor` - so the test display records the
;; answer instead of a toolkit drawing a cursor.
(test-begin "schemacs_editor_frame_cursor")

;; The suite's display takes the cursor the frame asked for.
(define-method (display-define-frame-cursor (d <test-display>) frame cursor)
  (set! (test-display-frame-cursor d) cursor)
  cursor)

(define (cursor-over! frame x y)
  ;; The shape the display was asked for by a pointer report at X, Y.
  ;;--------------------------------------------------------------
  (set! (test-display-frame-cursor d) 'none)
  (note-mouse-highlight frame x y)
  (test-display-frame-cursor d))

;; Over text, over the frame's own last mode line, and over a
;; `mouse-face` run in the text.
(let ((f (numbered-frame 10 10 40)))
  (parameterize ((*current-frame* f))
    (let ((w (selected-window))
          (b (window-buffer (selected-window))))
      (test-equal "over text the pointer is the text cursor" 'text
                  (cursor-over! f 0 0))
      ;; `WINDOW_BOTTOMMOST_P (w)` with `resize-mini-windows` non-nil
      ;; and no prompt up: the frame's last mode line is not a resize
      ;; handle, so it is the nontext cursor (`xdisp.c:36777`).
      (test-equal "the frame's last mode line answers the nontext cursor"
                  'nontext
                  (cursor-over! f (window-body-left w)
                                (+ (window-top w) (window-height w) -1)))
      (put-text-property 2 4 'mouse-face 'highlight b)
      (test-equal "over a mouse-face run the pointer is the hand" 'hand
                  (cursor-over! f 1 0))
      (note-mouse-highlight f -1 -1)     ; the pointer left; clears the run
      ;; A `pointer` text property wins over the area and over the run
      ;; (`set_cursor:` reads it first, `xdisp.c:36736`).
      (put-text-property 2 4 'pointer 'vdrag b)
      (test-equal "a pointer property asks for the scroll-bar cursor"
                  'scrollbar
                  (cursor-over! f 1 0))
      ;; Both properties go: the `mouse-face` run is the hand cursor's
      ;; own trigger, so removing only `pointer` leaves the hand.
      (remove-text-properties 2 4 '(pointer nil) b)
      (note-mouse-highlight f -1 -1)
      (remove-text-properties 2 4 '(mouse-face nil) b)
      (test-equal "with neither property the text cursor is back" 'text
                  (cursor-over! f 1 0))
      ;; Negative coordinates mean the pointer has gone, and the C
      ;; returns before changing anything.
      (set! (test-display-frame-cursor d) 'none)
      (note-mouse-highlight f -1 -1)
      (test-equal "a pointer that left does not change the shape" 'none
                  (test-display-frame-cursor d)))))

;; Two windows: the top one's mode line is a drag handle for its bottom
;; edge, and a `keymap` property on the drawn string keeps it nontext -
;; that is what makes a clickable item on the mode line clickable
;; (`xdisp.c:36802`).
(let ((f (numbered-frame 20 12 40)))
  (parameterize ((*current-frame* f))
    (let* ((top (selected-window))
           (bottom (split-window top #f 'below))
           (row (+ (window-top top) (window-height top) -1)))
      (render! f)
      (test-equal "a non-bottom window's mode line is a vertical drag"
                  'vertical-drag
                  (cursor-over! f (window-body-left top) row))
      (test-equal "...and the bottom window's is not" 'nontext
                  (cursor-over! f (window-body-left bottom)
                                (+ (window-top bottom)
                                   (window-height bottom) -1)))
      (let* ((record (window-last-mode-line top))
             (string (and record (car record))))
        (when (and (string? string) (> (string-length string) 3))
          (put-text-property 2 3 'keymap *default-keymap* string))
        (test-equal "a keymap on the mode-line string keeps it nontext"
                    'nontext
                    (cursor-over! f (+ (window-body-left top) 2) row))
        ;; Restore the drawn string for any later group.
        (when (and (string? string) (> (string-length string) 3))
          (remove-text-properties 2 3 '(keymap nil) string))))))

;; Side by side on a frame with no scroll bars: the shared edge is the
;; `vertical-line` area - `coordinates_in_window` answers
;; `ON_VERTICAL_BORDER` for it (`window.c:1411-1418` on the mode line,
;; `:1448-1453` on a text row), and `note_mouse_highlight` turns that
;; into the horizontal-drag cursor and the "drag-mouse-1: resize" help
;; (`xdisp.c:37257`).
(let ((f (numbered-frame 10 10 40)))
  (parameterize ((*current-frame* f))
    (let* ((left (selected-window))
           (right (split-window left #f 'right))
           (col (- (+ (window-left left) (window-width left)) 1))
           (row (+ (window-top left) (window-height left) -1)))
      (render! f)
      (test-equal "a side-by-side window's mode-line edge is a horizontal drag"
                  'horizontal-drag
                  (cursor-over! f col row))
      (test-equal "and its border column on a text row too"
                  'horizontal-drag
                  (cursor-over! f col 0)))))
(test-end "schemacs_editor_frame_cursor")

(test-end "schemacs_editor_mouse")
