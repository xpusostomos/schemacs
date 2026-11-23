(define-library (schemacs scroll-bar)
  ;; GNU Emacs's `lisp/scroll-bar.el': window-system-independent support
  ;; for scroll bars - the toolkit click handler, the scale arithmetic,
  ;; and the mode that turns the bars on and off.
  ;;
  ;; The bar itself is the front end's: `(schemacs ui gtk pgtk)` makes a
  ;; `GtkScrollbar` per window and sends a `(WINDOW vertical-scroll-bar
  ;; (PORTION . WHOLE) TIME PART)` position list when it is clicked,
  ;; exactly as `pgtkterm.c`'s `xg_scroll_callback` does. The command
  ;; below - `[vertical-scroll-bar mouse-1]`, as `scroll-bar.el:495`
  ;; binds it - is what turns that event into a scroll.
  ;;
  ;; **What is not carried.** Horizontal scroll bars: Gtk has them and
  ;; this tree's layout does not make one (`horizontal-scroll-bar-mode`
  ;; exists only to say so). The non-toolkit emulation
  ;; (`scroll-bar-scroll-up` and its three siblings, which xterm-style
  ;; bars use) is not bound by anything here, because this tree's one
  ;; window system draws toolkit bars; `scroll-bar-drag`,
  ;; `scroll-bar-maybe-set-window-start` and their constructors are
  ;; carried beside the toolkit handler for the same reason Emacs keeps
  ;; them, and they read events the toolkit does not send.
  ;;
  ;; **`scroll-up` and `scroll-down` live here, not in `frame.scm`.**
  ;; They are `window.c`'s DEFUNs (`scroll_command`, `window.c:6975`),
  ;; and this tree's counterpart of that file is `frame.scm` - but the
  ;; page amount is `next-screen-context-lines`'s, which is
  ;; `simple.el`'s and lives above `frame.scm`, and the scroll itself is
  ;; the display's through `*window-scroll-function*`. `scroll-bar.el`
  ;; is the lowest library that has all three. A placement departure,
  ;; named here as the tree's other ones are.

  (import
    (scheme base)
    (scheme cxr)
    ;; `scroll-bar-columns`' `ceiling` and the drag arithmetic's
    ;; `1+`/`1-`, which `(scheme base)` does not export and this Guile
    ;; build's `(scheme inexact)` is not a library.
    (only (guile) ceiling 1+ 1-)
    ;; `define-command`, and the prefix argument the mode's interactive
    ;; form reads.
    (only (schemacs command)
          define-command current-prefix-arg uarg->integer)
    ;; The buffer positions and the point the drag arithmetic moves.
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion)
    (only (schemacs buffer) with-current-buffer)
    ;; `beginning-of-line` is `cmds.c`'s command, which the drag
    ;; arithmetic uses to snap to a line start.
    (only (schemacs cmds) beginning-of-line)
    ;; `define-custom`, which the mode's variable is made with.
    (only (schemacs custom) define-custom custom-initialize-default)
    ;; `next-screen-context-lines`, which `scroll-up`'s near-full-screen
    ;; amount is measured with (`scroll-amount`, `simple.scm:1068`).
    (only (schemacs simple) *next-screen-context-lines*)
    ;; `*window-scroll-function*` and what a window is measured in:
    ;; `window.c`'s scroll primitives are the display's, and the window
    ;; commands' library holds the rest.
    (only (schemacs frame)
          *window-scroll-function* selected-window selected-frame
          window-total-height window-body-height frame-char-width
          frame-parameter set-frame-parameter modify-frame-parameters
          modify-all-frames-parameters default-frame-scroll-bars
          scroll-bar-adjust-thumb-portion
          window-scroll-bars window-buffer window-start
          select-window set-window-start! recenter)
    (only (schemacs window) save-selected-window)
    ;; `vertical-motion 0 WINDOW` puts point on the line start the drag
    ;; arithmetic computed (`scroll-bar-drag-1`).
    (only (schemacs indentc) vertical-motion)
    ;; `sit-for` after a scroll, as the toolkit handler does.
    (only (schemacs keyboard) sit-for)
    ;; The position list accessors a click is read with.
    (only (schemacs subr) event-start event-end posn-x-y nth)
    ;; `kbd`, for the one binding at the end.
    (only (schemacs character) kbd)
    (only (schemacs keymap) define-key *default-keymap*))

  (export
   scroll-bar-event-ratio
   scroll-bar-scale
   scroll-bar-columns
   scroll-bar-lines
   set-scroll-bar-mode
   scroll-bar-mode
   toggle-scroll-bar
   *scroll-bar-mode*
   previous-scroll-bar-mode
   scroll-bar-set-window-start
   scroll-bar-drag-position
   scroll-bar-maybe-set-window-start
   scroll-bar-drag-1
   scroll-bar-drag
   scroll-bar-scroll-down
   scroll-bar-scroll-up
   scroll-bar-toolkit-scroll
   scroll-up
   scroll-down
   point-before-scroll)

  (begin

    ;;----------------------------------------------------------------
    ;; Utilities - `scroll-bar.el:28`
    ;;----------------------------------------------------------------

    (define (scroll-bar-event-ratio event)
      "Given a scroll bar event EVENT, return the scroll bar position as a ratio.
The value is a cons cell (PORTION . WHOLE) containing two integers
whose ratio gives the event's vertical position in the scroll bar, with 0
referring to the top and 1 to the bottom."
      ;; `(nth 2 event)` of the *position*, which is what Emacs's
      ;; docstring means by "event" - the C's list is
      ;; `(WINDOW vertical-scroll-bar (PORTION . WHOLE) TIME PART)`.
      (nth 2 event))

    (define (scroll-bar-scale num-denom whole)
      "Given a pair (NUM . DENOM) and WHOLE, return (/ (* NUM WHOLE) DENOM).
This is handy for scaling a position on a scroll bar into real units,
like buffer positions.  If SCROLL-BAR-POS is the (PORTION . WHOLE) pair
from a scroll bar event, then (scroll-bar-scale SCROLL-BAR-POS
(buffer-size)) is the position in the current buffer corresponding to
that scroll bar position."
      ;; "We multiply before we divide to maintain precision." Scheme's
      ;; `quotient` truncates toward zero, which is `truncate`'s answer
      ;; for the positive operands a scroll bar produces.
      (quotient (* (car num-denom) whole) (cdr num-denom)))

    (define (scroll-bar-columns side)
      "Return the width, measured in columns, of the vertical scrollbar on SIDE.
SIDE must be the symbol `left' or `right'."
      (let* ((wsb (window-scroll-bars))
             (vtype (nth 2 wsb))
             (cols (nth 1 wsb)))
        (cond
         ((not (memq side '(left right)))
          (error "`left' or `right' expected instead of ~s" side))
         ((and (eq? vtype side) cols))
         ((eq? (frame-parameter #f 'vertical-scroll-bars) side)
          ;; nil means it's a non-toolkit scroll bar, and its width in
          ;; columns is 14 pixels rounded up.
          (ceiling (/ (or (frame-parameter #f 'scroll-bar-width) 14)
                      (frame-char-width))))
         (else 0))))

    (define (scroll-bar-lines)
      "Return the height, measured in lines, of the horizontal scrollbar."
      (let* ((wsb (window-scroll-bars))
             (htype (nth 5 wsb))
             (lines (nth 4 wsb)))
        (cond
         (htype lines)
         ((frame-parameter #f 'horizontal-scroll-bars)
          (ceiling (/ (or (frame-parameter #f 'scroll-bar-height) 14)
                      (frame-char-width))))
         (else 0))))

    ;; `window-scroll-bars` is `window.c`'s and lives in `frame.scm`; it
    ;; is reached through the import above by its real name.

    ;;----------------------------------------------------------------
    ;; Enabling and disabling scroll bars - `scroll-bar.el:87`
    ;;----------------------------------------------------------------

    (define previous-scroll-bar-mode #f)
    ;; ^ GNU Emacs's `previous-scroll-bar-mode` (`scroll-bar.el:89`): the
    ;; last non-nil mode, so turning the bars back on restores their side.

    (define scroll-bar-mode-explicit #f)
    ;; ^ GNU Emacs's `scroll-bar-mode-explicit` (`:91`): "Non-nil means
    ;; `set-scroll-bar-mode' should really do something. This is nil
    ;; while loading `scroll-bar.el', and t afterward." It stops the
    ;; defcustom's initializer from touching the frames while this file
    ;; is being loaded.
    (set! scroll-bar-mode-explicit scroll-bar-mode-explicit)

    (define (set-scroll-bar-mode value)
      "Set the scroll bar mode to VALUE and put the new value into effect.
See the `scroll-bar-mode' variable for possible values to use."
      (if (*scroll-bar-mode*)
          (set! previous-scroll-bar-mode (*scroll-bar-mode*)))
      (*scroll-bar-mode* value)
      (when scroll-bar-mode-explicit
        (modify-all-frames-parameters
         (list (cons 'vertical-scroll-bars (*scroll-bar-mode*))))))

    (define-custom *scroll-bar-mode* default-frame-scroll-bars
      "Specify whether to have vertical scroll bars, and on which side.
Possible values are nil (no scroll bars), `left' (scroll bars on left)
and `right' (scroll bars on right).
To set this variable in a Lisp program, use `set-scroll-bar-mode'
to make it take real effect.
Setting the variable with a customization buffer also takes effect."
      :type '(choice (const :tag "none (nil)" nil)
                     (const left)
                     (const right))
      :group 'frames
      ;; The default value for `:initialize` would try to use `:set` when
      ;; processing the file; this is Emacs's own note.
      :initialize custom-initialize-default
      :set (lambda (sym val) (set-scroll-bar-mode val)))

    ;; We just set `scroll-bar-mode', but that was the default. If it is
    ;; set again, that is for real.
    (set! scroll-bar-mode-explicit #t)

    (define (get-scroll-bar-mode)
      "Return the value of `scroll-bar-mode'."
      (*scroll-bar-mode*))

    (define-command (scroll-bar-mode arg)
      "Toggle vertical scroll bars on all frames (Scroll Bar mode).

This command applies to all frames that exist, as well as new
frames to be created in the future.  This is done by altering the
frame parameters, so if you (re-)set `default-frame-alist' after
toggling the scroll bars on or off with this command, the scroll
bars may reappear on new frames."
      ;; `define-minor-mode` with a `:variable` getter/setter pair in
      ;; Emacs (`scroll-bar.el:131`) - which this tree's macro does not
      ;; carry - written out. The toggle rule is the macro's own
      ;; (`easy-mmode.el:367`): a bare call is `toggle`, a number enables
      ;; when it is positive, and the setter maps true to the last side.
      (interactive
       (list (if (current-prefix-arg)
                 (uarg->integer 1 (current-prefix-arg))
                 'toggle)))
      (let ((on (if (eq? arg 'toggle)
                    (not (*scroll-bar-mode*))
                    (and arg (> arg 0)))))
        (set-scroll-bar-mode
         (and on (or previous-scroll-bar-mode default-frame-scroll-bars)))))

    (define-command (toggle-scroll-bar arg)
      "Toggle whether or not the selected frame has vertical scroll bars.
With ARG, turn on vertical scroll bars if and only if ARG is positive.
The variable `scroll-bar-mode' controls which side the scroll bars are on
when they are turned on; if it is nil, they go on the left."
      (interactive (list (current-prefix-arg)))
      (let ((arg (if (not arg)
                     (if (frame-parameter #f 'vertical-scroll-bars) -1 1)
                     (uarg->integer 1 arg))))
        (modify-frame-parameters
         (selected-frame)
         (list (cons 'vertical-scroll-bars
                     (and (> arg 0)
                          (or (*scroll-bar-mode*) default-frame-scroll-bars)))))))

    ;;----------------------------------------------------------------
    ;; Buffer navigation using the scroll bar - `scroll-bar.el:219`
    ;;----------------------------------------------------------------

    (define point-before-scroll #f)
    ;; ^ GNU Emacs's `point-before-scroll` (`scroll-bar.el:213`): "Value
    ;; of point at the beginning of scroll bar drag." A plain variable,
    ;; as the C's is - it is set by one event's handler and read by the
    ;; next.

    (define-command (scroll-bar-set-window-start event)
      "Set the window start according to where the scroll bar is dragged.
EVENT should be a scroll bar click or drag event."
      (let* ((end-position (event-end event))
             (window (nth 0 end-position))
             (portion-whole (nth 2 end-position)))
        (with-current-buffer (window-buffer window)
          (save-excursion
            (goto-char (+ (point-min)
                          (scroll-bar-scale portion-whole
                                            (- (point-max) (point-min)))))
            (beginning-of-line)
            (set-window-start! window (point))))))

    (define (scroll-bar-drag-position portion-whole)
      "Calculate new window start for drag event."
      (save-excursion
        (goto-char (+ (point-min)
                      (scroll-bar-scale portion-whole
                                        (- (point-max) (point-min)))))
        (beginning-of-line)
        (point)))

    (define-command (scroll-bar-maybe-set-window-start event)
      "Set the window start according to where the scroll bar is dragged.
Only change window start if the new start is substantially different.
EVENT should be a scroll bar click or drag event."
      (let* ((end-position (event-end event))
             (window (nth 0 end-position))
             (portion-whole (nth 2 end-position))
             (next-portion-whole (cons (1+ (car portion-whole))
                                       (cdr portion-whole)))
             (current-start (window-start window)))
        (with-current-buffer (window-buffer window)
          (let* ((portion-start (scroll-bar-drag-position portion-whole))
                 (next-portion-start
                  (max (scroll-bar-drag-position next-portion-whole)
                       (1+ portion-start))))
            (if (or (>= current-start next-portion-start)
                    (< current-start portion-start))
                (set-window-start! window portion-start)
                ;; Always set window start, to ensure scroll bar position
                ;; is updated.
                (set-window-start! window current-start))))))

    (define (scroll-bar-drag-1 event)
      "Scroll the window to the proper position for EVENT."
      (let* ((start-position (event-start event))
             (window (nth 0 start-position))
             (portion-whole (nth 2 start-position)))
        ;; With `scroll-bar-adjust-thumb-portion' nil and
        ;; `portion-whole' indicating that the buffer is fully visible,
        ;; do not scroll the window since that might make it impossible
        ;; to scroll it back with GTK's thumb (Bug#32002).
        (when (or scroll-bar-adjust-thumb-portion
                  (not (number? (car portion-whole)))
                  (not (number? (cdr portion-whole)))
                  (not (= (car portion-whole) (cdr portion-whole))))
          (save-excursion
            (with-current-buffer (window-buffer window)
              ;; Calculate position relative to the accessible part of
              ;; the buffer.
              (goto-char (+ (point-min)
                            (scroll-bar-scale portion-whole
                                              (- (point-max) (point-min)))))
              (vertical-motion 0 window)
              (set-window-start! window (point)))))))

    (define-command (scroll-bar-drag event)
      "Scroll the window by dragging the scroll bar slider.
If you click outside the slider, the window scrolls to bring the slider there."
      ;; The event loop below reads with `read-event` in Emacs; this
      ;; tree's toolkit scroll bar sends a `handle` event per movement
      ;; instead (`xg_scroll_callback`), so nothing here loops. The
      ;; command is carried for the non-toolkit path, which no front end
      ;; of this tree takes - named in the library header.
      (scroll-bar-drag-1 event))

    (define-command (scroll-bar-scroll-down event)
      "Scroll the window's top line down to the location of the scroll bar click.
EVENT should be a scroll bar click."
      (let* ((end-position (event-end event))
             (window (nth 0 end-position))
             (before-scroll
              (with-current-buffer (window-buffer window)
                point-before-scroll)))
        (save-selected-window
          (let ((portion-whole (nth 2 end-position)))
            (select-window window)
            (set! before-scroll (or before-scroll (point)))
            (scroll-down
             (scroll-bar-scale portion-whole
                               (1- (window-total-height window))))))
        (with-current-buffer (window-buffer window)
          (set! point-before-scroll before-scroll))))

    (define-command (scroll-bar-scroll-up event)
      "Scroll the line next to the scroll bar click to the top of the window.
EVENT should be a scroll bar click."
      (let* ((end-position (event-end event))
             (window (nth 0 end-position))
             (before-scroll
              (with-current-buffer (window-buffer window)
                point-before-scroll)))
        (save-selected-window
          (let ((portion-whole (nth 2 end-position)))
            (select-window window)
            (set! before-scroll (or before-scroll (point)))
            (scroll-up
             (scroll-bar-scale portion-whole
                               (1- (window-total-height window))))))
        (with-current-buffer (window-buffer window)
          (set! point-before-scroll before-scroll))))

    ;;----------------------------------------------------------------
    ;; `window.c`'s scroll primitives - see the placement note above
    ;;----------------------------------------------------------------

    (define (%scroll-page window)
      ;; `scroll-amount`'s near-full-screen amount (`simple.scm:1068`):
      ;; "a near full screen is `next-screen-context-lines' less than a
      ;; full screen".
      (max 1 (- (window-body-height window) (*next-screen-context-lines*))))

    (define (scroll-command window n direction)
      ;; GNU Emacs's `scroll_command` (`window.c:6975`) for the case the
      ;; toolkit handler is in: the window is selected by the caller
      ;; (`save-selected-window`), so the C's save-the-other-window's-point
      ;; dance has nothing to do. The three argument forms are the C's:
      ;; nil - a whole screen in DIRECTION; the atom `-` - a whole screen
      ;; the other way; a number - that many lines times DIRECTION.
      (let ((scroll (*window-scroll-function*)))
        (when scroll
          (cond ((not n) (scroll window (* direction (%scroll-page window))))
                ((eq? n '-) (scroll window (* (- direction) (%scroll-page window))))
                (else (scroll window (* (uarg->integer 1 n) direction)))))))

    (define-command (scroll-up arg)
      "Scroll text of selected window upward ARG lines.
If ARG is omitted or nil, scroll upward by a near full screen.
A near full screen is `next-screen-context-lines' less than a full screen.
Negative ARG means scroll downward.
If ARG is the atom `-', scroll downward by nearly full screen.
When calling from a program, supply as argument a number, nil, or `-'."
      (interactive "^P")
      (scroll-command (selected-window) arg 1))

    (define-command (scroll-down arg)
      "Scroll text of selected window down ARG lines.
If ARG is omitted or nil, scroll down by a near full screen.
A near full screen is `next-screen-context-lines' less than a full screen.
Negative ARG means scroll upward.
If ARG is the atom `-', scroll upward by nearly full screen.
When calling from a program, supply as argument a number, nil, or `-'."
      (interactive "^P")
      (scroll-command (selected-window) arg -1))

    ;;----------------------------------------------------------------
    ;; Toolkit scroll bars - `scroll-bar.el:394`
    ;;----------------------------------------------------------------

    (define-command (scroll-bar-toolkit-scroll event)
      "Handle event EVENT on vertical scroll bar."
      (interactive "e")
      (let* ((end-position (event-end event))
             (window (nth 0 end-position))
             (part (nth 4 end-position))
             (before-scroll
              (with-current-buffer (window-buffer window)
                point-before-scroll)))
        (cond
         ((eq? part 'end-scroll) #f)
         (else
          (save-selected-window
            (select-window window)
            (set! before-scroll (or before-scroll (point)))
            (cond
             ((eq? part 'above-handle) (scroll-up '-))
             ((eq? part 'below-handle) (scroll-up #f))
             ((eq? part 'ratio)
              (let* ((portion-whole (posn-x-y end-position))
                     (lines (scroll-bar-scale portion-whole
                                              (1- (window-total-height window)))))
                (scroll-up (cond ((not (zero? lines)) lines)
                                 ((< (car portion-whole) 0) -1)
                                 (else 1)))))
             ((eq? part 'up) (scroll-up -1))
             ((eq? part 'down) (scroll-up 1))
             ((eq? part 'top) (set-window-start! window (point-min)))
             ((eq? part 'bottom)
              (goto-char (point-max))
              (recenter #f))
             ((eq? part 'handle)
              ;; The event's *start* position is the pair the drag
              ;; arithmetic reads: `(WINDOW vertical-scroll-bar
              ;; (PORTION . WHOLE) ...)`.
              (scroll-bar-drag-1 event))))
          (sit-for 0 #f)
          (with-current-buffer (window-buffer window)
            (set! point-before-scroll before-scroll))))))

    (define-command (scroll-bar-toolkit-horizontal-scroll event)
      "Handle event EVENT on horizontal scroll bar."
      ;; No horizontal bar is drawn by either front end (see the library
      ;; header); the command exists so a key bound to it reports the
      ;; same nothing Emacs's does on a frame without one.
      (interactive "e")
      event
      #f)

    ;;----------------------------------------------------------------
    ;; Bindings - `scroll-bar.el:486`
    ;;----------------------------------------------------------------
    ;;
    ;; "For now, we'll set things up to work like xterm." This tree's one
    ;; toolkit is Gtk, so it takes the toolkit branch: `mouse-1` on a
    ;; vertical scroll bar is `scroll-bar-toolkit-scroll`. The
    ;; non-toolkit four-way bindings are Emacs's other branch and are not
    ;; made, because no front end here sends `scroll-bar-scroll-up`.
    (define-key *default-keymap* (kbd "<vertical-scroll-bar> <mouse-1>")
      scroll-bar-toolkit-scroll)

    ))