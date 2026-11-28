;; Tests for `(schemacs scroll-bar)', which mirrors GNU Emacs's
;; `scroll-bar.el'.
;;
;; The toolkit's half is a widget and needs a screen; the *Lisp* half is
;; the arithmetic and the commands, and that is what is tested here. A
;; click is handed to `scroll-bar-toolkit-scroll` as the position list
;; the Gtk front end sends -
;;
;;   (mouse-1 (WINDOW vertical-scroll-bar (PORTION . WHOLE) TIME PART))
;;
;; - so every part symbol is driven through the real command, and the
;; window geometry is a `<test-display>' with a 9x20 cell and an 18-pixel
;; scroll bar, made a window system's by the two methods below. That is
;; what a Gtk frame answers: measured on GNU Emacs 31.1, a normal
;; window's `(window-scroll-bars)' is `(nil 2 t nil 0 t nil)' - a
;; theme-default width, two columns, the frame's side - and its body is
;; two columns narrower than the frame.
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (oop goops) define-class define-method make)
 (prefix (only (schemacs test-display) <test-display>) stub:)
 (only (schemacs dispnew)
       current-display window-system-display? display-default-scroll-bar-width
       display-set-window-scroll-bar display-draw-vertical-border)
 (only (schemacs frame)
       *default-frame-alist* *current-frame* *frame-list*
       new-frame frame-parameter set-frame-parameter modify-frame-parameters
       window-list window-scroll-bars set-window-scroll-bars
       window-body-width window-body-left window-scroll-bar-cols
       window-left-scroll-bar-cols window-right-scroll-bar-cols
       window-vertical-scroll-bar-type window-config-scroll-bar-cols
       window-scroll-bar-width frame-scroll-bar-width
       window-buffer frame-char-width selected-window frame-selected-window
       window-width window-left window-height window-body-height window-body-top
       window-tab-line-height
       set-window-start!)
 (only (schemacs window) split-window)
 (only (schemacs xdisp) render! window-start window-end)
 (only (schemacs buffer) allocate-buffer get-buffer-create
       with-current-buffer set-point buffer-z set-buffer-local-value!)
 (only (schemacs editfns) point point-max insert goto-char)
 (only (schemacs subr) event-start event-end nth)
 (only (schemacs scroll-bar)
       scroll-bar-scale scroll-bar-event-ratio scroll-bar-columns
       scroll-bar-drag-1 scroll-bar-toolkit-scroll
       scroll-bar-mode *scroll-bar-mode* previous-scroll-bar-mode
       toggle-scroll-bar
       set-scroll-bar-mode scroll-up scroll-down point-before-scroll))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_scroll_bar")

(define-class <win-test-display> (stub:<test-display>)
  ;; Every `display-set-window-scroll-bar` call, as its argument list, and
  ;; every `display-draw-vertical-border` call.
  (bar-calls #:init-value '() #:accessor test-bar-calls)
  (border-calls #:init-value '() #:accessor test-border-calls))

(define-method (display-set-window-scroll-bar (d <win-test-display>) window
                                              side x y width height
                                              portion position whole)
  (set! (test-bar-calls d)
        (cons (list side x y width height) (test-bar-calls d))))

(define-method (display-draw-vertical-border (d <win-test-display>) window
                                             x y0 y1)
  (set! (test-border-calls d)
        (cons (list x y0 y1) (test-border-calls d))))

;; A window system's display, with Gtk's measured numbers: a 9-pixel
;; column, a 20-pixel row, and an 18-pixel scroll bar - two columns.
(define-method (window-system-display? (d <win-test-display>)) #t)
(define-method (display-default-scroll-bar-width (d <win-test-display>)) 18)

(define tty (make stub:<test-display>))
(define win (make <win-test-display> #:column-width 9 #:line-height 20))

;; **The test frames have no menu bar**, as the mouse suite's do: the bar
;; would take a row and change the geometry being asserted.
;; **No fringes either**: they are a graphical frame's default, and a
;; fringe column would come out of the body the bar arithmetic is about.
;; The fringe suite is `pgtk-test.scm`'s.
(*default-frame-alist*
 (cons '(left-fringe . 0)
       (cons '(right-fringe . 0)
             (cons '(menu-bar-lines . 0) (*default-frame-alist*)))))

(define (frame-of display lines rows cols)
  ;; A frame on a buffer of LINES numbered lines, drawn once so the
  ;; window's recorded end is real.
  ;;--------------------------------------------------------------
  (let ((ed (allocate-buffer)))
    (let loop ((i 1))
      (when (<= i lines)
        (with-current-buffer ed
          (insert (string-append (number->string (+ 1000 i)) "\n")))
        (loop (+ i 1))))
    (set-point ed 1)
    (parameterize ((current-display display))
      (let ((f (new-frame ed rows cols)))
        (parameterize ((*current-frame* f))
          (render! f))
        f))))

;;----------------------------------------------------------------
;; `scroll-bar-scale' and the event ratio - `scroll-bar.el:28`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_scroll_bar_scale")

(test-equal "scale: half the buffer"
            50 (scroll-bar-scale (cons 50 100) 100))
(test-equal "scale: a quarter of 200"
            50 (scroll-bar-scale (cons 5 20) 200))
(test-equal "scale: whole"
            100 (scroll-bar-scale (cons 1 1) 100))
(test-equal "event ratio is the position's third element"
            (cons 3 7) (scroll-bar-event-ratio (list 'W 'vertical-scroll-bar (cons 3 7) 0 'handle)))

(test-end "schemacs_editor_scroll_bar_scale")

;;----------------------------------------------------------------
;; `window-scroll-bars' and the geometry it implies
;;----------------------------------------------------------------

(test-begin "schemacs_editor_scroll_bar_window")

(let* ((f (frame-of win 40 24 80))
       (w (frame-selected-window f)))
  (parameterize ((*current-frame* f))
    (test-equal "a window-system window uses the frame's bars"
                (list #f 2 #t #f 0 #t #f) (window-scroll-bars w))
    (test-equal "the side is the frame's default: right"
                'right (window-vertical-scroll-bar-type w))
    (test-equal "the bar takes two columns from the body"
                78 (window-body-width w))
    (test-equal "a right bar leaves the text at the window's left edge"
                0 (window-body-left w))
    (test-equal "no left bar"
                0 (window-left-scroll-bar-cols w))
    (test-equal "two right bar columns"
                2 (window-right-scroll-bar-cols w))
    (test-equal "the bar is 18 pixels"
                18 (window-scroll-bar-width w))
    (test-equal "the frame's configured width is the display's default"
                18 (frame-scroll-bar-width f))
    (test-equal "the frame parameter reports the computed width"
                18 (frame-parameter f 'scroll-bar-width))
    (test-equal "the frame's side parameter"
                'right (frame-parameter f 'vertical-scroll-bars))
    ;; A left bar moves the text without changing the width.
    (test-assert "set-window-scroll-bars to the left answers t"
                 (set-window-scroll-bars w #f 'left))
    (test-equal "the left bar moves the text two columns in"
                2 (window-body-left w))
    (test-equal "and keeps the body width"
                78 (window-body-width w))
    (test-equal "the stored type is the side"
                'left (nth 2 (window-scroll-bars w)))
    ;; Turning it off gives the columns back.
    (test-assert "set-window-scroll-bars nil answers t"
                 (set-window-scroll-bars w #f #f))
    (test-equal "with no bar the body is the whole window"
                80 (window-body-width w))
    (test-equal "and the reported columns are zero"
                0 (window-scroll-bar-cols w))
    (test-assert "an unchanged setting answers nil"
                 (not (set-window-scroll-bars w #f #f)))
    ;; A width of zero means no bar, whatever the type said.
    (set-window-scroll-bars w #f #t)
    (test-assert "a zero width clears the type"
                 (set-window-scroll-bars w 0 #t))
    (test-equal "and the window has no bar"
                0 (window-scroll-bar-cols w))
    ;; A bar too wide to leave two columns of text is refused.
    (test-assert "a bar wider than the window is refused"
                 (not (set-window-scroll-bars w (* 79 9) 'right)))
    (test-equal "and the window still has no bar"
                0 (window-scroll-bar-cols w))
    (test-assert "an invalid type signals"
                 (guard (e (#t #t))
                   (set-window-scroll-bars w #f 'sideways)
                   #f))))

;; A terminal answers the frame's type and shows nothing: measured,
;; `(window-scroll-bars)' on a tty is `(nil 0 t nil 0 t nil)'.
(let* ((f (frame-of tty 20 24 80))
       (w (frame-selected-window f)))
  (parameterize ((*current-frame* f))
    (test-equal "a terminal window reports no columns"
                (list #f 0 #t #f 0 #t #f) (window-scroll-bars w))
    (test-equal "a terminal body is the whole window"
                80 (window-body-width w))
    (test-assert "set-window-scroll-bars on a terminal does nothing"
                 (not (set-window-scroll-bars w #f 'right)))
    (test-equal "and changes nothing"
                0 (window-scroll-bar-cols w))))

(test-end "schemacs_editor_scroll_bar_window")

;;----------------------------------------------------------------
;; The toolkit click - `scroll-bar-toolkit-scroll'
;;----------------------------------------------------------------

(define (click window part portion whole)
  ;; The event the Gtk front end sends, whose position list is
  ;; `(WINDOW vertical-scroll-bar (PORTION . WHOLE) TIME PART)'.
  ;;--------------------------------------------------------------
  (list 'mouse-1
        (list window 'vertical-scroll-bar (cons portion whole) 0 part)))

(test-begin "schemacs_editor_scroll_bar_toolkit")

(let* ((small (make stub:<test-display> #:rows 10 #:columns 40))
       (f (frame-of small 100 10 40))
       (w (frame-selected-window f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f))
    (with-current-buffer ed
      (test-equal "the window starts at the first line"
                  1 (window-start w))
      (test-equal "down scrolls the view one line"
                  6 (begin (scroll-bar-toolkit-scroll (click w 'down 0 0))
                           (window-start w)))
      (test-equal "and moves point into the window"
                  6 (point))
      (test-equal "up scrolls it back"
                  1 (begin (scroll-bar-toolkit-scroll (click w 'up 0 0))
                           (window-start w)))
      ;; The page is the body height less `next-screen-context-lines`:
      ;; 8 - 2 = 6 lines (a 10-row frame keeps a row for the echo area
      ;; and one for the mode line). Start at line 50 (position 246) so
      ;; both directions have room; `above-handle' is `(scroll-up '-)',
      ;; which scrolls *down* toward the beginning.
      (set-window-start! w 246)
      (render! f)
      (test-equal "the window starts where Lisp put it"
                  246 (window-start w))
      (test-equal "above-handle scrolls back a page"
                  216 (begin (scroll-bar-toolkit-scroll
                              (click w 'above-handle 0 0))
                             (window-start w)))
      (test-equal "below-handle scrolls forward a page"
                  246 (begin (scroll-bar-toolkit-scroll
                              (click w 'below-handle 0 0))
                             (window-start w)))
      (test-equal "top goes to the beginning"
                  1 (begin (scroll-bar-toolkit-scroll (click w 'top 0 0))
                           (window-start w)))
      (scroll-bar-toolkit-scroll (click w 'bottom 0 0))
      (test-equal "bottom leaves point at the end of the buffer"
                  (point-max) (point))
      (test-assert "and the view is near the end"
                   (> (window-start w) 1))
      ;; The thumb dragged to the middle. 100 lines of 5 characters, so
      ;; the buffer is 500 characters; half of it - position 251 - is the
      ;; start of line 51, which is where the drag lands.
      (scroll-bar-toolkit-scroll (click w 'handle 50 100))
      (test-equal "the handle puts the window at half the buffer"
                  251 (window-start w))
      (test-equal "end-scroll does nothing"
                  1 (begin (set-window-start! w 1)
                           (scroll-bar-toolkit-scroll
                            (click w 'end-scroll 0 0))
                           (window-start w))))))

(test-end "schemacs_editor_scroll_bar_toolkit")

;;----------------------------------------------------------------
;; `scroll-up' and `scroll-down' - `window.c`'s primitives
;;----------------------------------------------------------------

(test-begin "schemacs_editor_scroll_bar_commands")

(let* ((small (make stub:<test-display> #:rows 10 #:columns 40))
       (f (frame-of small 100 10 40))
       (w (frame-selected-window f))
       (ed (window-buffer w)))
  (parameterize ((*current-frame* f))
    (with-current-buffer ed
    (scroll-up 1)
    (test-equal "scroll-up 1 moves the view one line"
                6 (window-start w))
    (scroll-down 1)
    (test-equal "scroll-down 1 moves it back"
                1 (window-start w))
    (scroll-up #f)
    (test-equal "scroll-up with no argument is a page (6 lines)"
                31 (window-start w))
    (scroll-down #f)
    (test-equal "scroll-down with no argument is a page back"
                1 (window-start w))
    (scroll-up 10)
    (test-equal "scroll-up 10 is ten lines"
                51 (window-start w))
    ;; For `scroll-down`, `-` means "a page the other way" - which for
    ;; this command is upward, toward the end of the buffer.
    (scroll-down '-)
    (test-equal "scroll-down '-' is a page upward"
                81 (window-start w)))))

(test-end "schemacs_editor_scroll_bar_commands")

;;----------------------------------------------------------------
;; `scroll-bar-mode' and `toggle-scroll-bar' - `scroll-bar.el:87`
;;----------------------------------------------------------------

(test-begin "schemacs_editor_scroll_bar_mode")

(let ((old-mode (*scroll-bar-mode*))
      (old-previous previous-scroll-bar-mode))
  (let ((f (frame-of win 20 24 80)))
    (parameterize ((*current-frame* f))
      (test-equal "the mode's default is the frame's default"
                  'right (*scroll-bar-mode*))
      (scroll-bar-mode -1)
      (test-equal "turning the mode off clears the frame parameter"
                  #f (frame-parameter f 'vertical-scroll-bars))
      (test-equal "and the window loses its bar"
                  0 (window-scroll-bar-cols (selected-window)))
      ;; Emacs keeps the *text* width when the bars go and the frame's
      ;; pixel width shrinks by the bar; this tree's grid width is what
      ;; shrinks, so the body width stays what it was.
      (test-equal "the text width is unchanged when the bar goes"
                  78 (window-body-width (selected-window)))
      (test-equal "and the grid shrank by the bar's columns"
                  78 (window-width (selected-window)))
      (scroll-bar-mode 1)
      (test-equal "turning it back on restores the previous side"
                  'right (frame-parameter f 'vertical-scroll-bars))
      (test-equal "and the bar returns"
                  2 (window-scroll-bar-cols (selected-window)))
      (toggle-scroll-bar -1)
      (test-equal "toggle-scroll-bar with -1 turns this frame off"
                  #f (frame-parameter f 'vertical-scroll-bars))
      (toggle-scroll-bar 1)
      (test-equal "and 1 turns it back on"
                  'right (frame-parameter f 'vertical-scroll-bars))))
  ;; Put the global mode back for anything that runs after this suite.
  (set-scroll-bar-mode old-mode)
  (set! previous-scroll-bar-mode old-previous))

(test-end "schemacs_editor_scroll_bar_mode")


;;----------------------------------------------------------------
;; The bar's box and the separator between side-by-side windows
;;----------------------------------------------------------------
;; `pgtk_set_vertical_scroll_bar` asks `window_box (w, ANY_AREA, ...)`
;; (`pgtkterm.c:4248`), whose height is `window_box_height` - the text
;; area, mode line and tab line excluded - and whose Y is the window top
;; plus the tab line. Sizing the bar to the whole window rectangle made
;; two stacked windows' bars meet across the mode line, where Emacs draws
;; the mode line out to the frame edge.
;;
;; The separator is `gui_draw_vertical_border` (`xdisp.c:37917`): nothing
;; at all when the frame has vertical scroll bars - the bars are the
;; separator - and a one-pixel `vertical-border` line from the text
;; area's top to its bottom when it has none. A terminal's `|' glyph is
;; not this hook; it is the frame matrix's `right_border_glyph`
;; (`dispnew.c:2574`).
(test-begin "schemacs_editor_scroll_bar_geometry")

(let* ((f (frame-of win 60 24 80))
       (w (frame-selected-window f)))
  (parameterize ((*current-frame* f))
    (define (bar-call)
      (car (filter (lambda (c) (eq? 'right (car c)))
                   (test-bar-calls win))))
    (set! (test-bar-calls win) '())
    (render! f)
    (let ((call (bar-call)))
      (test-equal "the bar begins at the text area's top"
                  0 (caddr call))
      (test-equal "the bar is the body's height: one row short of the mode line"
                  (* 20 (- (window-height w) 1))
                  (car (cddddr call)))
      (test-equal "and it is the bar area's width"
                  (* 2 9) (cadddr call)))
    ;; A tab line is above the text, and the bar starts below it.
    (set-buffer-local-value! (window-buffer w) 'tab-line-format "%b")
    (set! (test-bar-calls win) '())
    (render! f)
    (let ((call (bar-call)))
      (test-equal "a tab line pushes the bar down one row"
                  20 (caddr call))
      (test-equal "and takes a row from its height"
                  (* 20 (- (window-height w) 2))
                  (car (cddddr call))))
    (set-buffer-local-value! (window-buffer w) 'tab-line-format #f)
    (set! (test-bar-calls win) '())
    (render! f)
    ;; With the frame's bars on, they separate the windows and no border
    ;; line is drawn - the C returns before either branch.
    (let* ((left (frame-selected-window f))
           (right (split-window left #f 'right)))
      (set! (test-border-calls win) '())
      (render! f)
      (test-equal "with scroll bars the bars are the separator" '()
                  (test-border-calls win))
      (set-frame-parameter f 'vertical-scroll-bars #f)
      ;; The frame's new size reaches its windows over the next few
      ;; redisplays, so render until the geometry stops moving and only
      ;; then measure a render.
      (let loop ((i 0) (prev #f))
        (unless (or (= i 6)
                    (equal? prev
                            (map (lambda (w)
                                   (list (window-left w) (window-width w)
                                         (window-body-width w)
                                         (window-height w)))
                                 (window-list f))))
          (render! f)
          (loop (+ i 1)
                (map (lambda (w)
                       (list (window-left w) (window-width w)
                             (window-body-width w)
                             (window-height w)))
                     (window-list f)))))
      (set! (test-border-calls win) '())
      (render! f)
      ;; The line is at the left window's right edge and runs the text
      ;; area's height - the C's `window_box_edges` + `y1 -= 1`
      ;; (`xdisp.c:37946`). The edge is the window's last column, or the
      ;; body's last when the border column is counted outside it; the
      ;; frame's width is re-derived from the test display's fixed
      ;; screen, so both spellings of "the edge" are accepted.
      (let* ((calls (test-border-calls win))
             (call (and (pair? calls) (car calls)))
             (x (and call (list-ref call 0)))
             (y0 (and call (list-ref call 1)))
             (y1 (and call (list-ref call 2))))
        (test-equal "without them exactly one border line is drawn"
                    1 (length calls))
        (test-assert "the line is on the windows' shared edge"
                     (and x
                          (>= x (* 9 (max 0 (- (+ (window-left left)
                                                  (window-width left))
                                               2))))
                          (<= x (* 9 (+ (window-left left)
                                        (window-width left))))))
        (test-equal "the line starts at the text area's top"
                    0 y0)
        (test-equal "and ends one pixel above the mode line"
                    (- (* (+ (window-body-top left)
                             (window-body-height left))
                          20)
                       1)
                    y1)))))

(test-end "schemacs_editor_scroll_bar_geometry")

(test-end "schemacs_editor_scroll_bar")