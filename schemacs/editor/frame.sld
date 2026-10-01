(define-library (schemacs editor frame)
  ;; This library mirrors GNU Emacs's frame and window state: `frame.c`
  ;; and the part of `window.c` that holds a window - which buffer it
  ;; shows, where its display starts, where point is in it, where it was
  ;; left, and the rectangle of the screen it occupies - together with
  ;; the window commands' own view of the selection.
  ;;
  ;; The two arrive in one library because they are entangled and this
  ;; project keeps one directory for both sides of Emacs's tree: a
  ;; window's point has to know whether its window is the selected one,
  ;; and the border query has to look at the frame's list of windows. In
  ;; GNU Emacs the same entanglement is spread across frame.c and
  ;; window.c (a single library per file is not available to C either).
  ;; The window *commands* - `split-window-below`, `delete-window`,
  ;; `other-window` and the rest of `window.el` - are in
  ;; `(schemacs editor window)`, which is where the tree they walk is
  ;; kept in shape. The tree itself is here, with the window record it is
  ;; made of.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is the first step of.

  (import
    (scheme base)
    ;; `new-frame' takes an optional size, which is a `case-lambda': it
    ;; is not exported by `(scheme base)' and a missing import for it
    ;; reports as an unbound variable at run time rather than a
    ;; syntax error at the definition (see ENGINE-FINDINGS.txt).
    (scheme case-lambda)
    ;; The frame is a display-neutral thing: its size is the size its
    ;; display reports (`sync-frame-size!' asks the interface), and
    ;; stopping and resuming the terminal on C-z is the display's
    ;; business too (`suspend-display!' / `resume-display!', which
    ;; `suspend-frame' asks through the interface).
    (only (schemacs editor dispnew)
          column-width current-display display-selections-supported?
          line-height resume-display!
          screen-size suspend-display!)
    (only (schemacs editor engine)
          copy-marker  marker-position  set-marker!
          text-editor-get-cursor  text-editor-set-cursor)
    ;; `suspend-frame' is a command and states its own key as the other
    ;; command libraries do.
    (only (schemacs editor command) define-command uarg->integer)
    ;; `special-event-map' is where the window system's events are
    ;; bound, as Emacs's is (`keyboard.c:14550').
    (only (schemacs editor keymap)
          define-key *default-keymap* *special-event-map*)
    ;; `SIGTSTP' is raised through `kill': `(scheme base)''s `raise'
    ;; raises an exception, not a signal.
    (only (guile) kill getpid SIGTSTP)
    ;; The message timeout is a time in seconds, and so is a timer's.
    (only (scheme time) current-second)
    ;; `w->cursor_off_p' and the blink's timers are kept beside the
    ;; window and the frame rather than in the window, for the reason
    ;; `buffer.sld' gives for its own slots: the record is shared and
    ;; changing it touches every library that makes a window.
    (only (schemacs weak) new-weak-table weak-table-ref weak-table-set!)
    ;; `display-graphic-p' is a question about the window system the frame
    ;; is on, which is what the face machinery records.
    (only (schemacs editor faces) *window-system*)
    (only (schemacs editor timer)
          cancel-timer run-with-idle-timer run-with-timer))

  (export
   %window-point
   *current-frame*
   *blink-cursor-blinks*
   *blink-cursor-delay*
   *blink-cursor-interval*
   *blink-cursor-mode*
   *frame-cursor-type*
   *frame-focus*
   *pre-command-hook*
   blink-cursor-check
   blink-cursor-idle-timer
   blink-cursor-timer
   blink-cursor--rescan-frames
   blink-cursor--should-blink
   blink-cursor-end
   blink-cursor-mode
   blink-cursor-suspend
   internal-show-cursor
   internal-show-cursor-p
   run-pre-command-hook!
   set!window-cursor-off?
   window-cursor-off?
   *minibuffer*
   *echo-area-buffer*
   *echo-area-prompt*
   current-editor
   display-selections-p
   *tty-select-active-regions*
   frame-height
   frame-width
   make-frame-window
   make<frame>
   make<window>
   frame-editor
   frame-keymap-state
   frame-message
   frame-message-expired?
   frame-message-expiry
   frame-quit-cont
   frame-output
   frame-selected-window
   frame-type?
   frame-windows
   window-type?
   new-frame
   select-window
   selected-window
   set!%window-point
   set!frame-height
   set!frame-width
   set!frame-editor
   set!frame-keymap-state
   set-message!
   set!frame-message
   set!frame-message-expiry
   set!frame-quit-cont
   set!frame-selected-window
   set!frame-windows
   set!window-buffer
   set!window-height
   set!window-left
   set!window-top
   set!window-top-line
   set!window-width
   resize-frame-windows!
   suspend-frame
   set-window-point!
   sync-frame-size!
   window-body-height
   window-children
   window-internal?
   window-parent
   set!window-children
   set!window-parent
   ;; the hscroll fields of the window record, which `xdisp' and
   ;; `window' read and write
   %window-hscroll set!%window-hscroll
   %window-min-hscroll set!%window-min-hscroll
   %window-suspend-auto-hscroll? set!%window-suspend-auto-hscroll?
   %window-old-point set!%window-old-point
   window-body-width
   window-buffer
   window-edges
   window-height
   window-left
   window-list
   window-point
   window-right-border?
   window-top
   window-top-line
   window-width
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Windows
    ;;
    ;; GNU Emacs's window: a view of a buffer - which buffer, where its
    ;; display starts, where point is in it, and the rectangle of the
    ;; screen it occupies. Windows are not buffers: the same buffer can
    ;; be shown in more than one window, and each of those windows has
    ;; its own point and its own scroll position. A frame holds its
    ;; windows in a *tree*, one of them selected; commands act on the
    ;; selected window's buffer and the cursor is drawn in the selected
    ;; window.
    ;;
    ;; The tree is Emacs's: a window is either a *leaf*, which shows a
    ;; buffer, or an *internal* window, which holds two or more children
    ;; and shows nothing itself. `SPLIT-WINDOW' turns a leaf into an
    ;; internal window with two children, of which one is the leaf it was
    ;; - so a window a command had hold of stays valid across a split -
    ;; and `DELETE-WINDOW' removes a leaf and promotes its sibling. A
    ;; lookup that walks the tree in order therefore visits the leaves in
    ;; the order they are arranged on the screen, which is what
    ;; `WINDOW-LIST' answers and what makes `OTHER-WINDOW' cyclic in the
    ;; order Emacs makes it cyclic in.
    ;;
    ;; Each window keeps its own rectangle, rather than deriving it from
    ;; the tree: a leaf's is the rectangle it occupies, and an internal
    ;; window's is the union of its children's. That is a convenience for
    ;; the renderer (`WINDOW-EDGES' on a leaf is the whole answer) and it
    ;; is what the window commands maintain - split divides a rectangle
    ;; between two children, delete gives a removed leaf's rectangle to
    ;; its sibling.

    (define-record-type <window>
      (make<window>
       buffer point top-line top height left width parent children
       hscroll min-hscroll suspend-auto-hscroll? old-point)
      window-type?
      (buffer    window-buffer      set!window-buffer)
      ;; ^ The <text-editor-type> this window shows. Emacs's
      ;; `window-buffer'.
      (point     %window-point      set!%window-point)
      ;; ^ The <marker-type> this window is holding, which is point for
      ;; a window that is not selected: where point would be if it were.
      ;; A marker, and not a character index, because the text of the
      ;; buffer can change while this window is not selected - edit
      ;; above this window's point in another window showing the same
      ;; buffer, and the point this one comes back to is still on the
      ;; character it was left on. It is private because `WINDOW-POINT'
      ;; is the function that settles which point a window has - GNU
      ;; Emacs's `window-point', which answers with the buffer's own
      ;; point for the selected window.
      (top-line  window-top-line    set!window-top-line)
      ;; ^ The zero-based index of the buffer line drawn on the window's
      ;; first row: Emacs's `window-start', which is a buffer position
      ;; there, kept here as a line index because that is the unit the
      ;; renderer walks lines in.
      (top       window-top         set!window-top)
      ;; ^ The zero-based screen row of the window's first row.
      (height    window-height      set!window-height)
      ;; ^ The window's height in screen rows, including the row its
      ;; mode line is drawn on, as Emacs's `window-total-height' does.
      ;; `WINDOW-BODY-HEIGHT' is what the text gets.
      (left      window-left        set!window-left)
      ;; ^ The zero-based screen column of the window's first column.
      (width     window-width       set!window-width)
      ;; ^ The window's width in screen columns.
      (parent    window-parent      set!window-parent)
      ;; ^ The window holding this one, or false when the frame does.
      ;; Emacs's `window-parent'. A leaf's parent may be an internal
      ;; window or, when the frame holds it directly, nothing.
      (children  window-children    set!window-children)
      ;; ^ This window's children, in the order they are arranged on the
      ;; screen: empty for a leaf. Emacs's `window-child' and
      ;; `window-next-sibling', kept as a list because that is the order a
      ;; command wants them in.
      (hscroll   %window-hscroll    set!%window-hscroll)
      ;; ^ How many display columns the window's lines are scrolled left
      ;; by: a line's column is drawn at its display column less this.
      ;; Emacs's `w->hscroll', a window-local variable - `window-hscroll'
      ;; and `set-window-hscroll' are its Elisp face, in `window.c'.
      (min-hscroll %window-min-hscroll set!%window-min-hscroll)
      ;; ^ The least amount the window may be left scrolled by, which an
      ;; interactive `scroll-left'/`scroll-right' raises to the new
      ;; amount: Emacs's `w->min_hscroll', set at `window.c:7113' - "the
      ;; new scroll amount becomes the lower bound for automatic
      ;; scrolling".
      (suspend-auto-hscroll? %window-suspend-auto-hscroll?
                             set!%window-suspend-auto-hscroll?)
      ;; ^ Whether auto hscrolling is suspended for this window, which
      ;; `scroll-left'/`scroll-right' set and which clears when the
      ;; window's point moves: Emacs's `w->suspend_auto_hscroll'
      ;; (`xdisp.c:16756' clears it when `Fwindow_point' differs from
      ;; `old_pointm').
      (old-point %window-old-point  set!%window-old-point)
      ;; ^ The window point the last redisplay saw, for that comparison.
      ;; Emacs's `w->old_pointm', a marker there and the integer it
      ;; holds here - the comparison is `Fequal' either way.
      )

    (define (window-internal? window)
      ;; Whether WINDOW is an internal window rather than one showing a
      ;; buffer: it has children. Emacs's `window-combination-p'.
      ;;--------------------------------------------------------------
      (pair? (window-children window)))

    (define (window-list . args)
      ;; The frame's windows that show a buffer, in the order they are
      ;; arranged on the screen: GNU Emacs's `(window-list)'. The tree's
      ;; internal windows are not among them - nothing can be shown in
      ;; one and no command can select one.
      ;;
      ;; With no frame argument the current frame's windows are walked.
      ;;--------------------------------------------------------------
      (let ((frame (if (pair? args) (car args) (*current-frame*))))
        (let walk ((windows (if frame (frame-windows frame) '())))
          (cond ((null? windows) '())
                ((window-internal? (car windows))
                 (append (walk (window-children (car windows)))
                         (walk (cdr windows))))
                (else (cons (car windows) (walk (cdr windows))))))))

    (define (window-point window)
      ;; The character index point is at in WINDOW: GNU Emacs's
      ;; `window-point'. For the selected window that is the buffer's
      ;; own point - a buffer has one point, and the selected window is
      ;; where it is. For any other window it is the point the window is
      ;; holding, which is where point would be if that window were
      ;; selected.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (if (and frame
                 (eq? window (frame-selected-window frame)))
            (text-editor-get-cursor (window-buffer window))
            (marker-position (%window-point window)))))

    (define (set-window-point! window index)
      ;; Make point in WINDOW be at INDEX: GNU Emacs's
      ;; `set-window-point', which moves point itself when the window is
      ;; the selected one.
      ;;--------------------------------------------------------------
      (set-marker! (%window-point window) index (window-buffer window))
      (when (eq? window (selected-window))
        (text-editor-set-cursor (window-buffer window) index))
      index)

    (define (window-body-height window)
      ;; The rows of the window available to text: everything above its
      ;; mode line. GNU Emacs's `window-body-height'.
      ;;--------------------------------------------------------------
      (max 1 (- (window-height window) 1)))

    (define (window-right-border? window)
      ;; Whether the last column of WINDOW is the vertical border that
      ;; separates it from a window to its right. Side by side windows
      ;; are divided by one column - GNU Emacs's frame vertical border,
      ;; drawn down a text terminal as `|' - and the column belongs to
      ;; the window on its left, which is why that window's width is one
      ;; more than the text it can show.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (and frame
             (let ((right (+ (window-left window) (window-width window)))
                   (top (window-top window))
                   (bottom (+ (window-top window) (window-height window))))
               ;; the frame's *leaves*, not the frame's list: a split puts
               ;; an internal window where a leaf stood, and an internal
               ;; window is not beside anything on the screen
               (let loop ((rest (window-list frame)))
                 (cond
                  ((null? rest) #f)
                  ((eq? (car rest) window) (loop (cdr rest)))
                  ((and (= (window-left (car rest)) right)
                        (< (window-top (car rest)) bottom)
                        (< top (+ (window-top (car rest))
                                  (window-height (car rest)))))
                   #t)
                  (else (loop (cdr rest)))))))))

    (define (window-body-width window)
      ;; The columns of the window available to text: GNU Emacs's
      ;; `window-body-width', which is the window's width less the
      ;; vertical border when it has a window to its right.
      ;;--------------------------------------------------------------
      (let ((width (window-width window)))
        (if (window-right-border? window) (- width 1) width)))

    (define (window-edges window)
      ;; The window's rectangle as (LEFT TOP RIGHT BOTTOM), Emacs's
      ;; `window-edges'. RIGHT and BOTTOM are one past the last row and
      ;; column the window draws on.
      ;;--------------------------------------------------------------
      (list (window-left window)
            (window-top window)
            (+ (window-left window) (window-width window))
            (+ (window-top window) (window-height window))))

    (define (make-frame-window buffer top height left width)
      ;; A window filling the given rectangle, showing BUFFER with point
      ;; at its beginning: a leaf the frame holds directly.
      ;;--------------------------------------------------------------
      (make<window> buffer (copy-marker buffer 0)
                            0 top height left width #f '()
                            0 0 #f 0))

    ;;----------------------------------------------------------------
    ;; Editor state

    (define-record-type <frame>
      (make<frame>
       windows selected-window height width
       message message-expiry keymap-state quit-cont output)
      frame-type?
      (windows   frame-windows   set!frame-windows)
      ;; ^ The frame's windows, top to bottom. Emacs's `window-list'.
      (selected-window frame-selected-window
                       set!frame-selected-window)
      ;; ^ The window commands act on and the cursor is drawn in, Emacs's
      ;; `selected-window'. #f only before the first window is made.
      (height    frame-height             set!frame-height)
      ;; ^ The frame's height in rows, GNU Emacs's `frame-height': the
      ;; rows the terminal gives the editor, which is what a window made
      ;; to fill the frame is measured against. It is taken from the
      ;; terminal when the frame is made and refreshed on each redisplay,
      ;; so that a window that gets resized is noticed.
      (width     frame-width              set!frame-width)
      ;; ^ The frame's width in columns, GNU Emacs's `frame-width'.
      (message    frame-message    set!frame-message-text)
      ;; ^ A message string drawn in the echo area, or false.
      (message-expiry frame-message-expiry
                      set!frame-message-expiry)
      ;; ^ When that message should be taken down again, as a time in
      ;; seconds in the sense of `current-second', or false for a
      ;; message that stays until the next key. GNU Emacs arms a timer
      ;; for this (`minibuffer-message-timeout', two seconds) and also
      ;; clears on the next input event, which is what the command loop
      ;; does here by setting the message to "" before every command.
      ;; This editor has no timers, so the time is kept and the command
      ;; loop's read is given a timeout while one is pending.
      (keymap-state frame-keymap-state set!frame-keymap-state)
      ;; ^ A pending modal keymap lookup state, or false. It persists
      ;; between key events when a key chord (such as C-x C-s) is
      ;; partially entered.
      (quit-cont  frame-quit-cont  set!frame-quit-cont)
      ;; ^ An escape continuation captured by the event loop, invoked
      ;; by `save-buffers-kill-terminal` to exit the editor.
      (output     frame-output     set!frame-output)
      ;; ^ The display this frame is drawn on: Emacs's `output_data',
      ;; which points a frame at its terminal's output data. Set when
      ;; the frame is made (the display is the one the platform
      ;; opened), and #f for a frame made with no display - a test.
      ;;
      ;; There was a `crlf?' slot here, holding the visited file's
      ;; line-break convention. It is gone: the convention belongs to the
      ;; buffer, not to the frame a buffer happens to be shown in - GNU
      ;; Emacs keeps it in the buffer's `buffer-file-coding-system' - and
      ;; a frame-wide one meant that saving a CRLF file after visiting an
      ;; LF file rewrote it with LF, and the other way round. It is
      ;; buffer-local in `(schemacs editor files)' now.
      )

    (define (set!frame-message frame text)
      ;; Put TEXT in FRAME's echo area, taking down any timeout the
      ;; message it replaces had. A timeout belongs to the message it
      ;; was set with (`SET-MESSAGE!'), and a plain `message' - the
      ;; command loop clearing the echo area, or an error being
      ;; reported - is not meant to inherit the previous one's and
      ;; disappear early.
      ;;--------------------------------------------------------------
      (set!frame-message-text frame text)
      (set!frame-message-expiry frame #f))

    (define (frame-message-expired? frame)
      ;; Whether FRAME's message has been up for as long as it was
      ;; given. A message with no expiry - the great majority, which
      ;; stay until the next key - is never expired.
      ;;--------------------------------------------------------------
      (let ((limit (frame-message-expiry frame)))
        (and limit (< limit (current-second)))))

    (define (set-message! frame text . args)
      ;; Put TEXT in FRAME's echo area, taking it down again after
      ;; ARGS' first element seconds - or leaving it until the next key
      ;; when there is none. GNU Emacs's `message' pairs a string with
      ;; the timer `minibuffer-message' arms for it; the two are set
      ;; together here so that a message cannot be left with the
      ;; previous message's expiry.
      ;;--------------------------------------------------------------
      (set!frame-message frame text)
      (set!frame-message-expiry
       frame (and (pair? args) (car args) (+ (current-second) (car args)))))

    ;; The frame currently dispatching a key event. Commands read the
    ;; frame through this parameter.
    (define *current-frame* (make-parameter #f))

    (define *frame-cursor-type* (make-parameter (cons 'filled-box-cursor 1)))
    ;; ^ The cursor the *frame* wants, as `(TYPE . WIDTH)', which is what
    ;; a buffer whose `cursor-type' is `t' is asking for. GNU Emacs keeps
    ;; it in two fields of `struct frame' - `desired_cursor' and
    ;; `cursor_width' (`frame.h') - filled in by the frame parameter
    ;; handler `x_set_cursor_type' from the frame's `cursor-type'
    ;; parameter, whose default is `t' and so a filled box.
    ;;
    ;; This tree has no frame parameters yet, so it is a parameter - one
    ;; frame, one value, like `*transient-mark-mode*'. It is here rather
    ;; than in a backend because it is the frame's, as those two fields
    ;; are: a terminal and a window system ask the same question of it.
    ;; `(schemacs editor xdisp)''s `get-window-cursor-type' is what reads
    ;; it.
    ;;
    ;; The type symbols are the C's own enum values (`text_cursor_kinds'
    ;; in `dispextern.h') rather than the Lisp spellings a `cursor-type'
    ;; value uses, because this is the resolved answer.

    ;;----------------------------------------------------------------
    ;; The cursor's visibility, and the blinking that turns it off and on
    ;;
    ;; GNU Emacs keeps the flag on the window (`w->cursor_off_p') and the
    ;; blinking in `frame.el'. Both are here, next to the window record
    ;; they are about, because of the import graph: `internal-show-cursor'
    ;; is `dispnew.c''s, and it cannot live in `dispnew.sld' - that sets a
    ;; field of a *window*, and `frame.sld' imports `dispnew.sld', so the
    ;; other direction is a cycle. It is where a reader looking for the
    ;; window's fields will look, which is the point.
    ;;------------------------------------------------------------------

    (define window-cursor-table (new-weak-table))
    ;; ^ The windows whose cursor has been blinked off, standing in for
    ;; the `bool_bf cursor_off_p : 1' that `struct window' has in Emacs.
    ;; Beside the window rather than in it so that adding it does not
    ;; change a record every library makes windows with.

    (define (window-cursor-off? window)
      ;; Whether WINDOW's cursor has been blinked off. GNU Emacs's
      ;; `w->cursor_off_p', which `get_window_cursor_type' reads as "use
      ;; normal cursor if not blinked off".
      ;;--------------------------------------------------------------
      (weak-table-ref window-cursor-table window #f))

    (define (set!window-cursor-off? window off?)
      (weak-table-set! window-cursor-table window (and off? #t)))

    (define (internal-show-cursor window show)
      ;; GNU Emacs's `internal-show-cursor': set WINDOW's cursor-visibility
      ;; flag, so that the next redisplay draws a cursor there or not.
      ;; WINDOW false means the selected window. SHOW false means do not
      ;; show a cursor, which is how a blink hides one.
      ;;
      ;; Emacs also does nothing here "while redisplaying", so that a
      ;; blink cannot change the cursor out from under the output
      ;; routines. This editor has no such flag: the redisplay runs to
      ;; completion between keys, and the only caller is the blink timer,
      ;; which runs between keys too.
      ;;--------------------------------------------------------------
      (set!window-cursor-off? (or window (selected-window)) (not show))
      ;; Emacs redraws when this has changed; here the caller redraws -
      ;; the command loop redraws after a timer ran, which is what makes
      ;; a blink visible.
      #f)

    (define (internal-show-cursor-p window)
      ;; GNU Emacs's `internal-show-cursor-p': whether the next redisplay
      ;; will draw a cursor in WINDOW, which false or omitted means the
      ;; selected window. `blink-cursor-timer-function' is its caller.
      ;;--------------------------------------------------------------
      (not (window-cursor-off? (or window (selected-window)))))

    (define *pre-command-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `pre-command-hook', which `keyboard.c' declares and
    ;; its command loop runs before each command. It is here rather than
    ;; in `keyboard.sld' for the same reason as the flag above: the blink
    ;; below *writes* it and the command loop *reads* it, and
    ;; `keyboard.sld' already imports this library - so the other
    ;; direction would be a cycle. It is with the other frame state.

    (define (run-pre-command-hook!)
      ;; Run the hook, as the command loop does before each command.
      ;; Emacs removes a hook function that signals, "since otherwise the
      ;; error might happen repeatedly and make Emacs nonfunctional";
      ;; this reports and carries on, which is what the command loop does
      ;; with a command's own errors.
      ;;--------------------------------------------------------------
      (for-each (lambda (function) (function)) (*pre-command-hook*)))

    ;;----------------------------------------------------------------
    ;; blink-cursor-mode (frame.el)
    ;;
    ;; Emacs's is a global minor mode, on by default in an interactive
    ;; session, and its docstring names the thing that decides where it
    ;; belongs: "This command is effective only on graphical frames. On
    ;; text-only terminals, cursor blinking is controlled by the
    ;; terminal." So on a terminal this does nothing at all, which is
    ;; right - a terminal blinks its own cursor, and there is one cursor
    ;; for it to blink.
    ;;
    ;; `define-minor-mode' does not exist in this tree yet, so the mode is
    ;; a command that toggles a variable, as `read-only-mode' is. What
    ;; `define-minor-mode' would give it - the customize group, the
    ;; lighter in the mode line - is named here rather than faked.
    ;;------------------------------------------------------------------

    (define *blink-cursor-mode* (make-parameter #t))
    ;; ^ on, as Emacs has it interactively: its `:init-value' is
    ;; `(not (or noninteractive no-blinking-cursor ...))'

    (define *blink-cursor-delay* (make-parameter 0.5))
    (define *blink-cursor-interval* (make-parameter 0.5))
    (define *blink-cursor-blinks* (make-parameter 10))

    (define blink-cursor-idle-timer #f)
    ;; ^ started after `blink-cursor-delay' seconds of idleness

    (define blink-cursor-timer #f)
    ;; ^ the repeating one that does the blinking

    (define blink-cursor-blinks-done 1)

    (define *frame-focus* (make-parameter #t))
    ;; ^ Whether the frame has the window system's focus: GNU Emacs's
    ;; `frame-focus-state', which its backends maintain. It is a
    ;; parameter here for the reason `*frame-cursor-type*' is - one frame,
    ;; one value - and `pgtk.sld' sets it from Gtk's focus events.
    ;;
    ;; Emacs asks, and it is worth asking: "with real emacs it only blinks
    ;; when the window has focus" (Chris). It also decides the cursor's
    ;; *shape*: `get_window_cursor_type' treats a frame that is not the
    ;; display's highlight frame as a non-selected one, which is a hollow
    ;; box rather than a filled one.

    (define (blink-cursor--should-blink)
      ;; GNU Emacs's `blink-cursor--should-blink': "Returns whether we
      ;; have any focused non-TTY frame." This editor has one frame, so
      ;; the two questions are the kind of display it is on - which is
      ;; what `*window-system*' records, Emacs's `display-graphic-p'
      ;; exactly - and whether it has the focus.
      ;;--------------------------------------------------------------
      (and (*blink-cursor-mode*) (*window-system*) (*frame-focus*) #t))

    (define (blink-cursor--rescan-frames)
      ;; GNU Emacs's `blink-cursor--rescan-frames', which its backends
      ;; call from `after-focus-change-function': look again, and stop
      ;; blinking if the answer is now no. When the frame regains the
      ;; focus, `blink-cursor-check' - which the command loop calls - is
      ;; what starts it again.
      ;;--------------------------------------------------------------
      (unless (blink-cursor-check)
        (blink-cursor-suspend)))

    (define (blink-cursor--start-idle-timer)
      ;; The 0.2 second floor is Emacs's, not a convenience: "to avoid
      ;; erratic behavior (or downright failure to display the cursor
      ;; during command execution) if they set blink-cursor-delay to a
      ;; very small or even zero value".
      ;;--------------------------------------------------------------
      (when blink-cursor-idle-timer (cancel-timer blink-cursor-idle-timer))
      (set! blink-cursor-idle-timer
            (run-with-idle-timer (max 0.2 (*blink-cursor-delay*))
                                 #t blink-cursor-start)))

    (define (blink-cursor--start-timer)
      (when blink-cursor-timer (cancel-timer blink-cursor-timer))
      (set! blink-cursor-timer
            (run-with-timer (*blink-cursor-interval*)
                            (*blink-cursor-interval*)
                            blink-cursor-timer-function)))

    (define (blink-cursor-start)
      ;; The idle timer's function: the editor has stopped being typed at,
      ;; so start blinking. The repeating timer is set up first, "so that
      ;; if this signals an error, blink-cursor-end is not added to
      ;; pre-command-hook".
      ;;--------------------------------------------------------------
      (when (not blink-cursor-timer)
        (set! blink-cursor-blinks-done 1)
        (blink-cursor--start-timer)
        (*pre-command-hook* (cons blink-cursor-end (*pre-command-hook*)))
        (internal-show-cursor #f #f)))

    (define (blink-cursor-timer-function)
      ;; Each call is one half of a blink. Emacs stops blinking after
      ;; `blink-cursor-blinks' of them - the cursor stays solid rather
      ;; than blinking for ever while you read.
      ;;--------------------------------------------------------------
      (internal-show-cursor #f (not (internal-show-cursor-p #f)))
      (set! blink-cursor-blinks-done (+ 1 blink-cursor-blinks-done))
      (when (and (> (*blink-cursor-blinks*) 0)
                 (<= (* 2 (*blink-cursor-blinks*)) blink-cursor-blinks-done))
        (blink-cursor-end)))

    (define (blink-cursor-end)
      ;; Stop blinking, and show the cursor: installed on
      ;; `pre-command-hook', so the first key you press after a pause
      ;; gives you a solid cursor to type at.
      ;;--------------------------------------------------------------
      (*pre-command-hook*
       (let loop ((rest (*pre-command-hook*)))
         (cond ((null? rest) '())
               ((eq? (car rest) blink-cursor-end) (cdr rest))
               (else (cons (car rest) (loop (cdr rest)))))))
      (internal-show-cursor #f #t)
      (when blink-cursor-timer
        (cancel-timer blink-cursor-timer)
        (set! blink-cursor-timer #f)))

    (define (blink-cursor-suspend)
      (blink-cursor-end)
      (when blink-cursor-idle-timer
        (cancel-timer blink-cursor-idle-timer)
        (set! blink-cursor-idle-timer #f)))

    (define (blink-cursor-check)
      ;; Start the idle timer if the mode is on and the frame can blink.
      ;; Idempotent, so the command loop can call it as often as it likes:
      ;; Emacs calls it from its focus-change and delete-frame hooks, and
      ;; this editor has neither, so the loop is where it is called.
      ;;--------------------------------------------------------------
      (when (and (blink-cursor--should-blink)
                 (not blink-cursor-idle-timer))
        (blink-cursor--start-idle-timer))
      (blink-cursor--should-blink))

    (define-command (handle-focus-in event)
      ;; GNU Emacs's `handle-focus-in' (`frame.el:353'): the frame has
      ;; received the window system's focus. Emacs sets the frame
      ;; parameter `last-focus-update' to t and runs `focus-in-hook'; this
      ;; tree's `*frame-focus*' is what `blink-cursor--should-blink' reads
      ;; and what `get-window-cursor-type' treats an unfocused frame by.
      ;;
      ;; Emacs's takes the EVENT as its argument - `(interactive "e")' -
      ;; and reads the frame from it: `(nth 1 event)' is the frame list
      ;; `make_lispy_focus_in' built. This tree's event is the same shape
      ;; (`keyboard.sld' builds it), so the frame is read from it too.
      ;;
      ;; Emacs's takes the EVENT as its argument - `(interactive "e")' -
      ;; and reads the frame from it. This tree has one frame, so the
      ;; command reads `*current-frame*', which is what `interactive'
      ;; would have to hand it: the event-argument spec is not ported.
      ;;--------------------------------------------------------------
      "Handle a focus-in event."
      (interactive "e")
      (*frame-focus* #t))

    (define-command (handle-focus-out event)
      ;; GNU Emacs's `handle-focus-out' (`frame.el:369'): the frame has
      ;; lost the window system's focus - and like `handle-focus-in', it
      ;; reads the frame from `*current-frame*' rather than from an event.
      ;;--------------------------------------------------------------
      "Handle a focus-out event."
      (interactive "e")
      (*frame-focus* #f))

    (define-command (blink-cursor-mode arg)
      "Toggle cursor blinking (Blink Cursor mode)."
      (interactive "P")
      (let ((on? (if arg
                     (< 0 (uarg->integer 1 arg))
                     (not (*blink-cursor-mode*)))))
        (*blink-cursor-mode* on?)
        (blink-cursor-suspend)
        (when on? (blink-cursor-check))
        ;; Emacs's `define-minor-mode' would echo this; the mode line
        ;; lighter it would also add is not implemented
        (set!frame-message (*current-frame*)
                           (if on?
                               "Blink Cursor mode enabled"
                               "Blink Cursor mode disabled"))))

    ;; the window system's events, bound where Emacs binds them - in the
    ;; library that owns the command (`bindings.el' has
    ;; `(define-key special-event-map ...)' and `keyboard.c:14550' does the
    ;; same in C)
    (define-key *special-event-map* (list "focus-in") handle-focus-in)
    (define-key *special-event-map* (list "focus-out") handle-focus-out)

    (define *minibuffer* (make-parameter #f))
    ;; ^ The minibuffer being read, or false: GNU Emacs's
    ;; `active-minibuffer-window', which is a fact about the selected
    ;; frame rather than about the minibuffer. `CURRENT-EDITOR' and
    ;; `MINIBUFFERP' read it, so it lives here with the frame state
    ;; rather than with the minibuffer's own code, which is in
    ;; `(schemacs editor minibuffer)'.

    (define *echo-area-buffer* (make-parameter #f))
    ;; ^ The buffer the echo area is showing, or false when it is showing
    ;; no buffer: GNU Emacs's `echo_area_buffer[0]'. While a minibuffer is
    ;; being read that buffer is the minibuffer's - Emacs gets there by
    ;; another route, because the minibuffer's *window* is the selected
    ;; window while it is read, so `current-buffer' is its buffer and
    ;; nothing has to say so. This project has no minibuffer window yet,
    ;; so the buffer that window would be showing is kept here, and
    ;; `read-from-minibuffer' binds it while it reads.
    ;;
    ;; It is here with the frame's other state because three things need
    ;; it and none of them may depend on the minibuffer's own code: the
    ;; display layer draws it (`X-DISPLAY' reads `echo_area_buffer' in GNU
    ;; Emacs too), and `CURRENT-EDITOR' answers with it, which is what
    ;; makes every editing command work in the prompt with no code of its
    ;; own.

    (define *echo-area-prompt* (make-parameter #f))
    ;; ^ The prompt drawn at the start of the echo area while a minibuffer
    ;; is being read, or false: what the display layer puts before the
    ;; buffer's text. GNU Emacs keeps the prompt *in* the buffer as the
    ;; `minibuffer-prompt' text property, which is why it needs no such
    ;; variable and why `minibuffer-prompt-end' can tell where the typed
    ;; text begins. This editor has neither text properties nor a
    ;; restriction on how far back point may go, so the prompt is beside
    ;; the buffer rather than in it, and this is where the display layer
    ;; finds it.

    (define (current-editor)
      ;; The buffer commands operate on: GNU Emacs's `current-buffer',
      ;; which is the selected window's buffer - except while a
      ;; minibuffer is being read, when it is the minibuffer's. That one
      ;; exception is what makes every editing command work in the
      ;; prompt with no code of its own: C-f, C-a, C-k, M-f, C-y and DEL
      ;; there are the ordinary commands over an ordinary buffer.
      ;;--------------------------------------------------------------
      (or (*echo-area-buffer*)
          (window-buffer (selected-window))))

    (define *tty-select-active-regions*
      ;; GNU Emacs's `tty-select-active-regions' (frame.el:2759): "If
      ;; non-nil, active regions automatically set the primary selection
      ;; on text terminals, if the terminal supports this" - the OSC 52
      ;; path, whose support `xterm--set-selection' records. Off, as
      ;; Emacs's is; xterm.sld's version handler turns the terminal's
      ;; parameter on.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (display-selections-p . args)
      ;; GNU Emacs's `display-selections-p' (frame.el:2770): whether
      ;; DISPLAY - nil meaning the selected frame's - supports
      ;; selections, "a way to transfer text or other data between
      ;; programs via special system buffers called `selection' or
      ;; `clipboard'".
      ;;
      ;; Emacs's frame-type cond has a branch for each kind of frame:
      ;; `pc' is MS-DOS's, of which there is none here, and the tty
      ;; branch is `tty-select-active-regions' together with the
      ;; terminal parameter `xterm--set-selection' - the OSC 52 path.
      ;; The question about the terminal is a method on the display
      ;; (`display-selections-supported?'), because importing xterm.sld
      ;; here would pull ncurses into the GTK build. What remains is
      ;; the window-system branch, `(memq frame-type '(x w32 ns pgtk))',
      ;; which answers t: and `framep-on-display' is this tree's one
      ;; window system at a time, which `*window-system*' is.
      ;;--------------------------------------------------------------
      (or (and (memq (*window-system*) '(x w32 ns pgtk)) #t)
          (and (not (*window-system*))
               (let ((d (current-display)))
                 (and d (display-selections-supported? d))))))

    (define (display-rows-cols display)
      ;; The display's size in character units, as `(ROWS . COLUMNS)': its
      ;; pixel size divided by the size of one character unit. This is
      ;; Emacs deriving `FRAME_COLS'/`FRAME_LINES' from
      ;; `FRAME_PIXEL_WIDTH'/`FRAME_PIXEL_HEIGHT' through
      ;; `FRAME_COLUMN_WIDTH'/`FRAME_LINE_HEIGHT'.
      ;;
      ;; On a terminal a character unit is one pixel, so these come out as
      ;; the terminal's own rows and columns. They are derived rather than
      ;; asked for so that a display whose unit is a real font - a
      ;; windowed one - answers the same question the same way.
      ;;--------------------------------------------------------------
      (let* ((size (screen-size display))
             (unit-width (max 1 (column-width display)))
             (unit-height (max 1 (line-height display))))
        (cons (quotient (cdr size) unit-height)
              (quotient (car size) unit-width))))

    (define new-frame
      ;; A frame holding one window that fills the text area and shows
      ;; EDITOR. GNU Emacs's `frame-root-window' is the whole frame, and
      ;; a frame starts with just that one window.
      ;;
      ;; Its size is the terminal's; the three argument form is for
      ;; tests, which have no terminal to ask.
      ;;--------------------------------------------------------------
      (case-lambda
       ((editor)
        ;; With no size asked for, the display's size is the answer - a
        ;; frame is a display of a terminal, and knows how big that is.
        (let ((size (display-rows-cols (current-display))))
          (new-frame editor (car size) (cdr size))))
       ((editor height width)
        (let ((window (make-frame-window editor 0 (max 1 (- height 1)) 0 width)))
          (make<frame> (list window) window height width
                       "" #f #f #f (current-display))))))

    (define min-safe-window-height 1)
    (define min-safe-window-width 2)
    ;; ^ The smallest a window may be left by a frame resize: GNU Emacs's
    ;; `MIN_SAFE_WINDOW_HEIGHT' and `MIN_SAFE_WINDOW_WIDTH' in `window.h',
    ;; which its `resize_frame_windows' respects. The Lisp variables
    ;; `window-min-height' and `window-min-width' - which the *split*
    ;; commands use, and which live in `window.el' - default to larger
    ;; numbers; Emacs has both, and so does this.

    (define (sync-frame-size! frame)
      ;; Take the frame's size from the terminal it is drawn on, if one
      ;; is open. A terminal that has been resized gives new numbers, so
      ;; this is what keeps `frame-height' and `frame-width' true; with
      ;; no terminal open (a test) there is nothing to ask and the frame
      ;; keeps the size it was made with.
      ;;
      ;; When the size has *changed*, the windows are re-tiled: GNU Emacs
      ;; does the same thing from `change_frame_size', which calls
      ;; `resize_frame_windows' in `window.c'. Without it a window keeps
      ;; the rectangle it was made with, and a terminal made smaller
      ;; draws its mode line off the bottom row.
      ;;--------------------------------------------------------------
      (let ((display (current-display)))
        (when display
          (let* ((size (display-rows-cols display))
                 (old-height (frame-height frame))
                 (old-width (frame-width frame))
                 (new-height (car size))
                 (new-width (cdr size)))
            (when (< 0 new-height)
              (unless (and (= old-height new-height)
                           (= old-width new-width))
                (set!frame-height frame new-height)
                (set!frame-width frame new-width)
                (resize-frame-windows! frame old-height old-width
                                       new-height new-width)))))))

    (define (resize-frame-windows! frame old-height old-width new-height
                                   new-width)
      ;; Give the frame's windows the frame's new size, in proportion to
      ;; the size they had: GNU Emacs's `resize_frame_windows', of which
      ;; this is the result rather than the mechanism. Emacs hands the
      ;; root window the *difference* and lets `window_resize_apply'
      ;; distribute it among the children - machinery that also serves
      ;; `enlarge-window' and `window-combination-resize'. What it
      ;; produces, for a frame that has simply changed size, is each
      ;; window scaled to the new frame with the remainder kept whole at
      ;; the end, and that is what this computes.
      ;;
      ;; The row above the echo area is the text area: the echo area has
      ;; the frame's last row, as GNU Emacs's minibuffer window does.
      ;;--------------------------------------------------------------
      (scale-window! (car (frame-windows frame))
                     0 0 old-width (max 1 (- old-height 1))
                     0 0 new-width (max 1 (- new-height 1))))

    (define (scale-window! window old-top old-left old-width old-height
                           new-top new-left new-width new-height)
      ;; WINDOW's rectangle goes from OL? to NEW?, and its children - if
      ;; it holds them - divide the new rectangle in proportion to the old
      ;; one, along the axis they are arranged on.
      ;;--------------------------------------------------------------
      (let ((children (window-children window)))
        (cond
         ((null? children)
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height))
         ((windows-stacked? children)
          ;; every node carries its own rectangle, as Emacs's
          ;; `window_resize_apply' leaves them: a *parent* that kept the
          ;; size it was made with would poison every later geometry
          ;; decision (an absorb that followed a stale bottom edge).
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height)
          (let ((old-total (let loop ((rest children) (sum 0))
                             (if (null? rest)
                                 sum
                                 (loop (cdr rest)
                                       (+ sum (window-height (car rest)))))))
                (new-total (max (* min-safe-window-height (length children))
                                new-height)))
            (let loop ((rest children) (offset 0))
              (unless (null? rest)
                (let* ((child (car rest))
                       (last? (null? (cdr rest)))
                       (old (window-height child))
                       (want (if last?
                                 (- new-total offset)
                                 (max min-safe-window-height
                                      (round (/ (* old new-total)
                                                old-total))))))
                  (scale-window! child
                                 (window-top child) (window-left child)
                                 old-width (window-height child)
                                 (+ new-top offset) new-left
                                 new-width want)
                  (loop (cdr rest) (+ offset want)))))))
         (else
          (set!window-top window new-top)
          (set!window-left window new-left)
          (set!window-width window new-width)
          (set!window-height window new-height)
          (let ((old-total (let loop ((rest children) (sum 0))
                             (if (null? rest)
                                 sum
                                 (loop (cdr rest)
                                       (+ sum (window-width (car rest)))))))
                (new-total (max (* min-safe-window-width (length children))
                                new-width)))
            (let loop ((rest children) (offset 0))
              (unless (null? rest)
                (let* ((child (car rest))
                       (last? (null? (cdr rest)))
                       (old (window-width child))
                       (want (if last?
                                 (- new-total offset)
                                 (max min-safe-window-width
                                      (round (/ (* old new-total)
                                                old-total))))))
                  (scale-window! child
                                 (window-top child) (window-left child)
                                 (window-width child) old-height
                                 new-top (+ new-left offset)
                                 want new-height)
                  (loop (cdr rest) (+ offset want))))))))))

    (define (windows-stacked? children)
      ;; Whether these sibling windows are arranged one above the other
      ;; rather than side by side: the axis their parent divided. Two
      ;; children that begin at the same column and the same width were
      ;; divided vertically, which is how `split-window-below' makes them.
      ;;--------------------------------------------------------------
      (and (pair? children)
           (pair? (cdr children))
           (= (window-left (car children)) (window-left (cadr children)))
           (= (window-width (car children)) (window-width (cadr children)))))

    (define-command (suspend-frame)
      ;; GNU Emacs's `suspend-frame' (C-z), which is `frame.el''s - "do
      ;; whatever is right to suspend the current frame". On a terminal
      ;; that is stopping the editor with SIGTSTP; the shell gives it back
      ;; with SIGCONT when the job is brought to the foreground.
      ;;
      ;; The display is asked to hand the terminal back first, so the
      ;; screen looks the way the shell left it, and to take it again
      ;; afterwards. GNU Emacs does the same around the `SIGTSTP' it
      ;; raises in `sysdep.c', through `Fsuspend_tty' / `Fresume_tty'.
      ;;
      ;; This is why the platform puts the terminal in `raw' mode rather
      ;; than `cbreak': in `raw' mode the terminal does not generate the
      ;; stop from the key itself, so the editor decides, which is what
      ;; Emacs does on a terminal too.
      ;;
      ;; Emacs's `SIGTSTP' is raised with `kill' rather than with Scheme's
      ;; `raise' because `(scheme base)''s `raise' raises an *exception*,
      ;; and `(guile)''s raises a signal; the two share a name.
      ;;--------------------------------------------------------------
      "Stop the editor and return to the shell (bound to C-z)."
      (interactive)
      (suspend-display! (current-display))
      (kill (getpid) SIGTSTP)
      (resume-display! (current-display)))

    ;; The key GNU Emacs binds it to, beside the command as the other
    ;; libraries state theirs.
    (define-key *default-keymap* (list (list 'ctrl #\z)) suspend-frame)

    (define (selected-window)
      ;; The window commands act on: GNU Emacs's `(selected-window)'.
      ;;--------------------------------------------------------------
      (frame-selected-window (*current-frame*)))

    (define (select-window window)
      ;; Make WINDOW the selected window, the way GNU Emacs's
      ;; `select-window' does: the buffer's point is left in the window
      ;; being left, and WINDOW's point becomes the buffer's. Selecting
      ;; the window that is already selected changes nothing.
      ;;--------------------------------------------------------------
      (when (window-internal? window)
        (error "Attempt to select an internal window"))
      (let ((frame (*current-frame*))
            (old (selected-window)))
        (when (and old (not (eq? old window)))
          ;; the window being left keeps the point it had ...
          (set-marker! (%window-point old)
                       (text-editor-get-cursor (window-buffer old))
                       (window-buffer old))
          (set!frame-selected-window frame window)
          ;; ... and the one being selected gives the buffer its point
          (text-editor-set-cursor (window-buffer window)
                                  (marker-position (%window-point window))))
        window))

    ;; The selected window's buffer, scroll position and file, under the
    ;; names the rest of this file already uses. They are what Emacs's
    ;; `current-buffer' and `window-start' are for the selected window,
    ;; and they keep the commands that act on "the buffer" reading as
    ;; such.

    (define (frame-editor frame)
      (window-buffer (frame-selected-window frame)))

    (define (set!frame-editor frame editor)
      (set!window-buffer (frame-selected-window frame) editor))

    ))
