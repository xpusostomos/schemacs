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
    ;; Only the names used: guile-ncurses exports a `define-key' of its
    ;; own, which would collide with the keymap library's.
    (only (ncurses curses) cols endwin lines refresh stdscr)
    (only (schemacs editor engine)
          copy-marker  marker-position  set-marker!
          text-editor-get-cursor  text-editor-set-cursor)
    ;; `suspend-frame' is a command, so it needs the command substrate,
    ;; and it states its own key as the other command libraries do.
    (only (schemacs editor command) new-command)
    (only (schemacs editor keymap) define-key *default-keymap*)
    ;; `SIGTSTP' is raised through `kill': `(scheme base)''s `raise'
    ;; raises an exception, not a signal.
    (only (guile) kill getpid SIGTSTP)
    ;; The message timeout is a time in seconds.
    (only (scheme time) current-second))

  (export
   %window-point
   *current-frame*
   *minibuffer*
   *echo-area-buffer*
   *echo-area-prompt*
   current-editor
   frame-height
   frame-width
   make-frame-window
   make<ncurses-frame>
   make<ncurses-window>
   ncurses-frame-editor
   ncurses-frame-esc-pending
   ncurses-frame-keymap-state
   ncurses-frame-message
   ncurses-frame-message-expired?
   ncurses-frame-message-expiry
   ncurses-frame-quit-cont
   ncurses-frame-selected-window
   ncurses-frame-type?
   ncurses-frame-windows
   ncurses-window-type?
   new-frame
   select-window
   selected-window
   set!%window-point
   set!frame-height
   set!frame-width
   set!ncurses-frame-editor
   set!ncurses-frame-esc-pending
   set!ncurses-frame-keymap-state
   set-message!
   set!ncurses-frame-message
   set!ncurses-frame-message-expiry
   set!ncurses-frame-quit-cont
   set!ncurses-frame-selected-window
   set!ncurses-frame-windows
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

    (define-record-type <ncurses-window>
      (make<ncurses-window>
       buffer point top-line top height left width parent children)
      ncurses-window-type?
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
        (let walk ((windows (if frame (ncurses-frame-windows frame) '())))
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
                 (eq? window (ncurses-frame-selected-window frame)))
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
      (make<ncurses-window> buffer (copy-marker buffer 0)
                            0 top height left width #f '()))

    ;;----------------------------------------------------------------
    ;; Editor state

    (define-record-type <ncurses-frame>
      (make<ncurses-frame>
       windows selected-window height width
       message message-expiry keymap-state quit-cont esc-pending)
      ncurses-frame-type?
      (windows   ncurses-frame-windows   set!ncurses-frame-windows)
      ;; ^ The frame's windows, top to bottom. Emacs's `window-list'.
      (selected-window ncurses-frame-selected-window
                       set!ncurses-frame-selected-window)
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
      (message    ncurses-frame-message    set!ncurses-frame-message-text)
      ;; ^ A message string drawn in the echo area, or false.
      (message-expiry ncurses-frame-message-expiry
                      set!ncurses-frame-message-expiry)
      ;; ^ When that message should be taken down again, as a time in
      ;; seconds in the sense of `current-second', or false for a
      ;; message that stays until the next key. GNU Emacs arms a timer
      ;; for this (`minibuffer-message-timeout', two seconds) and also
      ;; clears on the next input event, which is what the command loop
      ;; does here by setting the message to "" before every command.
      ;; This editor has no timers, so the time is kept and the command
      ;; loop's read is given a timeout while one is pending.
      (keymap-state ncurses-frame-keymap-state set!ncurses-frame-keymap-state)
      ;; ^ A pending modal keymap lookup state, or false. It persists
      ;; between key events when a key chord (such as C-x C-s) is
      ;; partially entered.
      (quit-cont  ncurses-frame-quit-cont  set!ncurses-frame-quit-cont)
      ;; ^ An escape continuation captured by the event loop, invoked
      ;; by `save-buffers-kill-terminal` to exit the editor.
      (esc-pending ncurses-frame-esc-pending set!ncurses-frame-esc-pending)
      ;; ^ Whether an ESC key was just seen: the next key event is
      ;; dispatched with the `meta` modifier (the Emacs ASCII
      ;; protocol, where ESC prefixes meta keys).
      ;;
      ;; There was a `crlf?' slot here, holding the visited file's
      ;; line-break convention. It is gone: the convention belongs to the
      ;; buffer, not to the frame a buffer happens to be shown in - GNU
      ;; Emacs keeps it in the buffer's `buffer-file-coding-system' - and
      ;; a frame-wide one meant that saving a CRLF file after visiting an
      ;; LF file rewrote it with LF, and the other way round. It is
      ;; buffer-local in `(schemacs editor files)' now.
      )

    (define (set!ncurses-frame-message frame text)
      ;; Put TEXT in FRAME's echo area, taking down any timeout the
      ;; message it replaces had. A timeout belongs to the message it
      ;; was set with (`SET-MESSAGE!'), and a plain `message' - the
      ;; command loop clearing the echo area, or an error being
      ;; reported - is not meant to inherit the previous one's and
      ;; disappear early.
      ;;--------------------------------------------------------------
      (set!ncurses-frame-message-text frame text)
      (set!ncurses-frame-message-expiry frame #f))

    (define (ncurses-frame-message-expired? frame)
      ;; Whether FRAME's message has been up for as long as it was
      ;; given. A message with no expiry - the great majority, which
      ;; stay until the next key - is never expired.
      ;;--------------------------------------------------------------
      (let ((limit (ncurses-frame-message-expiry frame)))
        (and limit (< limit (current-second)))))

    (define (set-message! frame text . args)
      ;; Put TEXT in FRAME's echo area, taking it down again after
      ;; ARGS' first element seconds - or leaving it until the next key
      ;; when there is none. GNU Emacs's `message' pairs a string with
      ;; the timer `minibuffer-message' arms for it; the two are set
      ;; together here so that a message cannot be left with the
      ;; previous message's expiry.
      ;;--------------------------------------------------------------
      (set!ncurses-frame-message frame text)
      (set!ncurses-frame-message-expiry
       frame (and (pair? args) (car args) (+ (current-second) (car args)))))

    ;; The frame currently dispatching a key event. Commands read the
    ;; frame through this parameter.
    (define *current-frame* (make-parameter #f))

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

    (define new-frame
      ;; A frame holding one window that fills the text area and shows
      ;; EDITOR. GNU Emacs's `frame-root-window' is the whole frame, and
      ;; a frame starts with just that one window.
      ;;
      ;; Its size is the terminal's; the three argument form is for
      ;; tests, which have no terminal to ask.
      ;;--------------------------------------------------------------
      (case-lambda
       ((editor) (new-frame editor (lines) (cols)))
       ((editor height width)
        (let ((window (make-frame-window editor 0 (max 1 (- height 1)) 0 width)))
          (make<ncurses-frame> (list window) window height width
                               "" #f #f #f #f)))))

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
      (let ((height (lines)))
        (when (< 0 height)
          (let ((old-height (frame-height frame))
                (old-width (frame-width frame))
                (new-height height)
                (new-width (cols)))
            (unless (and (= old-height new-height)
                         (= old-width new-width))
              (set!frame-height frame new-height)
              (set!frame-width frame new-width)
              (resize-frame-windows! frame old-height old-width
                                     new-height new-width))))))

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
      (scale-window! (car (ncurses-frame-windows frame))
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

    (define suspend-frame
      ;; GNU Emacs's `suspend-frame' (C-z), which is `frame.el''s - "do
      ;; whatever is right to suspend the current frame". On a terminal
      ;; that is stopping the editor with SIGTSTP; the shell gives it back
      ;; with SIGCONT when the job is brought to the foreground.
      ;;
      ;; The terminal is handed back first, so the screen looks the way the
      ;; shell left it, and taken again afterwards - `endwin' and then
      ;; `refresh', which is ncurses's idiom for the same thing. GNU Emacs
      ;; does the same around the `SIGTSTP' it raises in `sysdep.c'.
      ;;
      ;; This is why `(schemacs ui platform ncurses)' puts the terminal in
      ;; `raw' mode rather than `cbreak': in `raw' mode the terminal does
      ;; not generate the stop from the key itself, so the editor decides,
      ;; which is what Emacs does on a terminal too.
      ;;
      ;; Emacs's `SIGTSTP' is raised with `kill' rather than with Scheme's
      ;; `raise' because `(scheme base)''s `raise' raises an *exception*,
      ;; and `(guile)''s raises a signal; the two share a name.
      ;;--------------------------------------------------------------
      (new-command
       "suspend-frame"
       (lambda ()
         (endwin)
         (kill (getpid) SIGTSTP)
         (refresh (stdscr)))
       (lambda () #f)
       "Stop the editor and return to the shell (bound to C-z)."))

    ;; The key GNU Emacs binds it to, beside the command as the other
    ;; libraries state theirs.
    (define-key *default-keymap* (list (list 'ctrl #\z)) suspend-frame)

    (define (selected-window)
      ;; The window commands act on: GNU Emacs's `(selected-window)'.
      ;;--------------------------------------------------------------
      (ncurses-frame-selected-window (*current-frame*)))

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
          (set!ncurses-frame-selected-window frame window)
          ;; ... and the one being selected gives the buffer its point
          (text-editor-set-cursor (window-buffer window)
                                  (marker-position (%window-point window))))
        window))

    ;; The selected window's buffer, scroll position and file, under the
    ;; names the rest of this file already uses. They are what Emacs's
    ;; `current-buffer' and `window-start' are for the selected window,
    ;; and they keep the commands that act on "the buffer" reading as
    ;; such.

    (define (ncurses-frame-editor frame)
      (window-buffer (ncurses-frame-selected-window frame)))

    (define (set!ncurses-frame-editor frame editor)
      (set!window-buffer (ncurses-frame-selected-window frame) editor))

    ))
