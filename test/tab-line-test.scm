(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (oop goops) make define-method)
 (only (schemacs test-display) <test-display>)
 (only (schemacs dispnew) current-display menu-show)
 (only (schemacs menu) menu-items menu-items-used MENU-FOR-CLICK)
 (only (schemacs frame) *current-frame* *current-buffer* *default-frame-alist*
       new-frame selected-window set-window-buffer! window-list window-buffer
       window-last-tab-line
       window-parameter set-window-parameter)
 (only (schemacs buffer)
       allocate-buffer buffer-local-value buffer-name current-buffer
       get-buffer get-buffer-create set-buffer set-buffer-local-value!
       with-current-buffer)
 (only (schemacs window) switch-to-buffer window-prev-buffers)
 (only (schemacs editfns) insert)
 (only (schemacs textprop) get-text-property)
 (only (schemacs subr) *after-change-major-mode-hook* run-hooks
       posn-area posn-point posn-string)
 (only (schemacs keyboard) *last-read-event* dispatch-key)
 (only (schemacs simple) *last-command*)
 (only (schemacs frame) frame-message set!frame-keymap-state)
 (only (schemacs xdisp) posn-at-x-y render!)
 (only (schemacs tab-line)
       tab-line-mode tab-line-mode-variable global-tab-line-mode
       global-tab-line-mode-variable tab-line-format
       tab-line-tabs-window-buffers tab-line-tabs-fixed-window-buffers
       tab-line-select-tab tab-line-hscroll tab-line--get-tab-property
       tab-line-tab-map tab-line-tab-close-map tab-line-close-tab
       tab-line-mode--turn-on tab-line-tabs-non-excluded
       tab-line-force-update
       *tab-line-tabs-buffer-groups* tab-line-tabs-buffer-group-by-mode
       *tab-line-auto-hscroll* tab-line-tab-context-menu))

;; Unbuffered output, so a run that hangs shows where it got to.
(setvbuf (current-output-port) 'none)

;; Tests for `(schemacs tab-line)` - the Lisp half of
;; `tab-line.el`. The display half (the reserved row and the drawing) is
;; `xdisp.scm`'s and `frame.scm`'s, and is checked by the geometry probe
;; in AGENTS.md and by `tools/pty-check.py`; what is here is the format
;; the redisplay reads and the commands that act on it.
;;
;; Every expectation is Emacs 31.1's behaviour for the same sequence,
;; read off `tab-line.el` where it is a rule (the tab string's `tab` and
;; `keymap` properties, the fixed ordering) and off a real Emacs where it
;; is an answer.

;; **The frame is built on the first tab's buffer.** A frame given a
;; bare `allocate-buffer` shows a buffer that is live (it has a name) and
;; that `switch-to-buffer` therefore records in the window's buffer
;; history - so the first `fresh` would leave an `Untitled` tab at the
;; front, exactly as GNU Emacs leaves the buffer you switched away from.
(define tab-buffer (get-buffer-create "tab-one"))
(with-current-buffer tab-buffer (insert "one"))

(*current-frame* (new-frame tab-buffer 24 80))

;; A display object, so that a position's *row* can be measured - `one
;; cell is one row'. Nothing is opened; the stub answers the generics.
(current-display (make <test-display>))

(define (fresh name text)
  ;; A buffer called NAME, shown in the selected window, holding TEXT.
  ;;
  ;; `switch-to-buffer` is what a tab line is about: it is the *window's*
  ;; buffer history that `tab-line-tabs-window-buffers` walks, and
  ;; `set-buffer` does not touch it.
  (let ((b (get-buffer-create name)))
    (switch-to-buffer b)
    (insert text)
    b))

;;----------------------------------------------------------------
;; The mode, and the format it installs
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_mode")

(test-equal "the mode is off to begin with" #f (tab-line-mode-variable))

(tab-line-mode 1)

(test-equal "turning it on installs the default format"
            #t
            (let ((format (buffer-local-value (current-buffer)
                                              'tab-line-format #f)))
              (and (pair? format)
                   (eq? (car format) ':eval)
                   (procedure? (cadr format))
                   #t)))

(tab-line-mode -1)

(test-equal "turning it off takes the format away"
            #f
            (buffer-local-value (current-buffer) 'tab-line-format #f))

(tab-line-mode 1)

(test-end "schemacs_editor_tab_line_mode")

;;----------------------------------------------------------------
;; The format
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_format")

(test-equal "the tab line names the window's buffer"
            "tab-one"
            (buffer-name (get-text-property 1 'tab
                                           (car (tab-line-format)))))

(test-equal "the tab carries its keymap, which is how a click reaches a command"
            tab-line-tab-map
            (get-text-property 1 'keymap (car (tab-line-format))))

(test-assert "and a face"
             (get-text-property 1 'face (car (tab-line-format))))

;; `tab-line--get-tab-property` looks at 1, then 0, then the first
;; position the property changes at - which is how a separator of any
;; length is skipped.
(test-equal "the tab property is found through the separator"
            tab-buffer
            (tab-line--get-tab-property 'tab (car (tab-line-format))))

(test-end "schemacs_editor_tab_line_format")

;;----------------------------------------------------------------
;; The tab list, and switching to a tab
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_tabs")

(define tab-two (fresh "tab-two" "two"))
(define tab-three (fresh "tab-three" "three"))

(test-equal "the fixed ordering keeps the order the tabs were added in"
            (list tab-buffer tab-two tab-three)
            (tab-line-tabs-fixed-window-buffers))

;; Switching back to a buffer already on the tab line must not move it.
(switch-to-buffer tab-buffer)

(test-equal "switching back does not reorder the fixed tabs"
            (list tab-buffer tab-two tab-three)
            (tab-line-tabs-fixed-window-buffers))

;; The *window* ordering, which is what `tab-line-tabs-window-buffers`
;; answers, is the window's own history: the current buffer, then the
;; ones it showed before, most recent first.
(test-equal "the window ordering is the window's own history"
            (list tab-two tab-three tab-buffer)
            (tab-line-tabs-window-buffers))

;; A click on a tab: the event is `(down-mouse-1 POSN)` and the posn
;; carries the *string* the click landed on - `(nth 4 posn)` - which is
;; what `posn-string` answers.
(define (tab-event string window)
  (list 'down-mouse-1
        (list window 'tab-line (cons 0 0) 0 (cons string 0) 0)))

(define (tab-string-for buffer)
  ;; The piece of the tab line that stands for BUFFER: the first string
  ;; whose `tab` property is it. A piece is the separator plus the tab,
  ;; so the property starts at position 1.
  (let loop ((pieces (tab-line-format)))
    (cond ((null? pieces) #f)
          ((and (string? (car pieces))
                (eq? (get-text-property 1 'tab (car pieces)) buffer))
           (car pieces))
          (else (loop (cdr pieces))))))

(tab-line-select-tab (tab-event (tab-string-for tab-two) (selected-window)))

(test-equal "clicking a tab selects its buffer"
            "tab-two"
            (buffer-name (current-buffer)))

(test-end "schemacs_editor_tab_line_tabs")

;;----------------------------------------------------------------
;; Scrolling
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_hscroll")

(tab-line-hscroll 1)
(tab-line-force-update #t)
(tab-line-hscroll 1)

(test-equal "scrolling right is stored as the window parameter"
            2
            (window-parameter (selected-window) 'tab-line-hscroll))

(tab-line-hscroll 100)

(test-equal "and is clamped to the last tab"
            2
            (window-parameter (selected-window) 'tab-line-hscroll))

(tab-line-hscroll -100)

(test-equal "and to the first"
            0
            (window-parameter (selected-window) 'tab-line-hscroll))

(test-end "schemacs_editor_tab_line_hscroll")

;;----------------------------------------------------------------
;; The globalized mode
;;----------------------------------------------------------------

(test-begin "schemacs_editor_tab_line_global")

(test-equal "the global mode is off to start with"
            #f
            (global-tab-line-mode-variable))

;; A buffer whose tab line was turned off by hand keeps it off.
(set-buffer (get-buffer-create "tab-excluded"))
(set-buffer-local-value! (current-buffer) 'tab-line-exclude #t)
(tab-line-mode--turn-on)

(test-equal "`tab-line-exclude' keeps a buffer out of the global mode"
            #f
            (tab-line-mode-variable))

(set-buffer tab-buffer)
(global-tab-line-mode 1)

(test-equal "switching the global mode on turns the local one on"
            #t
            (tab-line-mode-variable))

(test-equal "and installs one after-change-major-mode-hook entry"
            1
            (length (*after-change-major-mode-hook*)))

(set-buffer (get-buffer-create "tab-new"))
(run-hooks (*after-change-major-mode-hook*))

(test-equal "a new buffer gets the tab line when its major mode is set"
            #t
            (tab-line-mode-variable))

(global-tab-line-mode -1)

(test-equal "switching it off removes the hook entry"
            0
            (length (*after-change-major-mode-hook*)))

(test-equal "and turns the tab line off in the buffers that had it"
            #f
            (with-current-buffer
                tab-buffer
              (tab-line-mode-variable)))

;; `tab-line-tabs-non-excluded` is the filter Emacs 31 offers for the
;; window-buffer list; a buffer whose `tab-line-exclude` is set drops out
;; of it.
(set-buffer tab-two)

(test-equal "the non-excluded filter keeps a buffer that is not excluded"
            (list tab-two)
            (tab-line-tabs-non-excluded (list tab-two)))

(set-buffer-local-value! tab-two 'tab-line-exclude #t)

(test-equal "and drops one that is"
            '()
            (tab-line-tabs-non-excluded (list tab-two)))

(test-end "schemacs_editor_tab_line_global")

;;----------------------------------------------------------------
;; The position list a click on the tab line carries
;;----------------------------------------------------------------
;;
;; `posn-at-x-y` is what turns a screen coordinate into the
;; `(WINDOW AREA (X . Y) TIME OBJECT)` a mouse event carries, and the
;; tab line's answer has to name `tab-line` and the *string* drawn there -
;; that string's `keymap` property is how a click reaches
;; `tab-line-select-tab`. The scratch display below is
;; `(schemacs test-display)`'s stub, so this needs no front end.

(test-begin "schemacs_editor_tab_line_posn")

;; **The test frame has no menu bar**: a terminal frame shows one by
;; default and the bar takes the frame's first row, which is the row this
;; group measures. The same fixture `mouse-tests.scm` uses.
(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define tab-posn-frame
  (new-frame (get-buffer-create "tab-posn") 24 80))

;; The buffer the frame shows is the one with the format on it.
(set-window-buffer! (car (window-list tab-posn-frame))
                    (get-buffer-create "tab-posn"))
(with-current-buffer
    (get-buffer-create "tab-posn")
  (insert "body\n")
  (tab-line-mode 1))

(render! tab-posn-frame)

(test-equal "a click on the tab row is in the tab-line area"
            'tab-line
            (posn-area (posn-at-x-y 5 0 tab-posn-frame)))

(test-assert "and it carries the string drawn there"
             (let ((string (posn-string (posn-at-x-y 1 0 tab-posn-frame))))
               (and string (string? (car string)))))

(test-equal "the row below it is the text"
            1
            (posn-point (posn-at-x-y 0 1 tab-posn-frame)))

(test-end "schemacs_editor_tab_line_posn")

;;----------------------------------------------------------------
;; Clicking a tab: the keymap property, and Emacs's fake prefix
;;----------------------------------------------------------------
;;
;; GNU Emacs makes two events out of a click in a named area - the area
;; symbol and the click - and looks the pair up in the active maps, one
;; of which is the `keymap` *text property* of the string the click
;; landed on (`keyboard.c:11947`, `keymap.c:1649`). These tests drive
;; that path: `dispatch-key` with the position a mouse event carries.

(test-begin "schemacs_editor_tab_line_click")

(define click-frame
  (new-frame (get-buffer-create "click-one") 24 80))

(parameterize ((*current-frame* click-frame))
  (switch-to-buffer (get-buffer-create "click-one"))
  (tab-line-mode 1)
  (let ((two (get-buffer-create "click-two")))
    (switch-to-buffer two)
    (tab-line-mode 1)
    (switch-to-buffer (get-buffer-create "click-one"))))

(render! click-frame)

(define (click-tab! buffer)
  ;; A click at the start of BUFFER's tab, as the display would report
  ;; it: `(down-mouse-1 (WINDOW tab-line (X . Y) TIME (STRING . POS)))'.
  ;; The position is built rather than measured - `posn-at-x-y`'s own
  ;; half is pinned by the `posn` group - so what this drives is the
  ;; dispatch.
  (parameterize ((*current-frame* click-frame))
    (let* ((string (tab-string-for buffer))
           (event (list 'down-mouse-1
                        (list (selected-window) 'tab-line (cons 1 0) 0
                              (cons string 1) 0))))
      (*last-read-event* event)
      (set!frame-keymap-state click-frame #f)
      (dispatch-key click-frame 'down-mouse-1))))

(click-tab! (get-buffer "click-two"))

(test-equal "a click on a tab runs tab-line-select-tab through its keymap"
            "click-two"
            (buffer-name (current-buffer)))

;; A click in an area with no binding is the click alone - Emacs's "last
;; event alone" rule - so the click still reaches `mouse-drag-region` and
;; no "tab-line is undefined" is said about it.
(parameterize ((*current-frame* click-frame))
  (set!frame-keymap-state click-frame #f)
  (*last-read-event*
   (list 'down-mouse-1
         (list (selected-window) 'mode-line (cons 1 0) 0)))
  (dispatch-key click-frame 'down-mouse-1))

(test-assert "an unbound area does not report itself undefined"
             (let ((message (frame-message click-frame)))
               (or (not message)
                   (not (string-contains message "mode-line is undefined")))))

;; The `x` on a tab carries its *own* keymap, so a click there closes the
;; tab where a click on the name selects it - two bindings in one string.
(define (close-position string)
  (let loop ((i 0))
    (cond ((>= i (string-length string)) #f)
          ((eq? (get-text-property i 'keymap string) tab-line-tab-close-map) i)
          (else (loop (+ i 1))))))

(test-assert "the close button carries the close map"
             (parameterize ((*current-frame* click-frame))
               (let ((string (tab-string-for (get-buffer "click-two"))))
                 (and string (close-position string) #t))))

;; **A release, not a press.** `tab-line-tab-close-map` binds
;; `[tab-line mouse-1]` and the tab map binds `[tab-line down-mouse-1]`:
;; the press selects and the *release* closes, which is Emacs's own split
;; and the reason a drag off a tab does not close it.
(parameterize ((*current-frame* click-frame))
  (let* ((string (tab-string-for (get-buffer "click-two")))
         (pos (close-position string))
         (event (list 'mouse-1
                      (list (selected-window) 'tab-line (cons 1 0) 0
                            (cons string pos) 0))))
    (*last-read-event* event)
    (set!frame-keymap-state click-frame #f)
    (dispatch-key click-frame 'mouse-1)))

(test-equal "a click on the close button runs tab-line-close-tab"
            tab-line-close-tab
            (*last-command*))

(test-end "schemacs_editor_tab_line_click")

(test-begin "schemacs_editor_tab_line_groups")

;; **The group table is a parameter** (`tab-line.el:499`): Emacs's
;; defvar holds `mouse-buffer-menu-mode-groups`' value, and
;; `tab-line-new-tab` `let`-binds it. It was exported and never defined,
;; so turning the tab line on and letting `tab-line-tabs-buffer-groups`
;; group the buffers died with "unbound variable:
;; *tab-line-tabs-buffer-groups*" the first time a group was asked for.
(test-equal '(#t "Fundamental")
  (list (procedure? *tab-line-tabs-buffer-groups*)
        (with-current-buffer (get-buffer-create "tab-line-group-probe")
          (tab-line-tabs-buffer-group-by-mode))))

(test-end "schemacs_editor_tab_line_groups")

;;----------------------------------------------------------------
;; A click resolves against the tab it landed on
;;----------------------------------------------------------------
;;
;; **The position's object is the *tab's own* string**, which is what GNU
;; Emacs's redisplay stores per string (`store_mode_line_string`) and what
;; `tab-line--get-tab-property` reads the `tab` property at position 1 of.
;; While the position carried the whole row, position 1 was always the
;; first tab: every click selected the first tab, and every close button
;; closed it. The rows here go through `posn-at-x-y`, so this is the
;; half the `click` group above builds by hand.

(test-begin "schemacs_editor_tab_line_posn_click")

(define posn-click-frame (new-frame (get-buffer-create "posn-a") 24 80))

(parameterize ((*current-frame* posn-click-frame) (*current-buffer* #f))
  (switch-to-buffer (get-buffer-create "posn-a"))
  (tab-line-mode 1)
  (switch-to-buffer (get-buffer-create "posn-b"))
  (tab-line-mode 1)
  (switch-to-buffer (get-buffer-create "posn-a"))
  (render! posn-click-frame))

;; **The columns are measured off the row that was drawn**, not guessed:
;; which tab comes first depends on the window's buffer history (the row
;; here reads "|posn-b x|posn-a x| +", because the window left posn-a for
;; posn-b and came back). `column-of` finds a tab's name in the record of
;; the last tab line, and the close button is the "x" after it.
(define (column-of text)
  (let loop ((i 0))
    (cond ((> (+ i (string-length text))
              (string-length (car (window-last-tab-line (selected-window)))))
           #f)
          ((string=? text
                     (substring (car (window-last-tab-line (selected-window)))
                                i (+ i (string-length text))))
           i)
          (else (loop (+ i 1))))))

;; **The tab clicked is the one that is not the window's buffer** - the
;; row here is "|posn-b x|posn-a x| +" and the window shows posn-b, so a
;; click on posn-a's name must leave posn-b. (Clicking the *first* tab
;; cannot tell the bug from the fix: position 1 of the whole row is the
;; first tab either way.)
(test-equal "a click on a tab's name selects that tab's buffer"
            "posn-a"
            (parameterize ((*current-frame* posn-click-frame))
              (tab-line-select-tab
               (list 'down-mouse-1
                     (posn-at-x-y (column-of "posn-a") 0 posn-click-frame)))
              (buffer-name (current-buffer))))

(test-equal '(#t #t)
  (parameterize ((*current-frame* posn-click-frame))
    (switch-to-buffer (get-buffer "posn-b"))
    (render! posn-click-frame)
    (let ((w (selected-window))
          (x (+ (column-of "posn-a") 7))) ; "posn-a" then " x"
      (tab-line-close-tab
       (list 'mouse-1 (posn-at-x-y x 0 posn-click-frame)))
      (list (not (memq (get-buffer "posn-a") (map car (window-prev-buffers w))))
            (eq? (window-buffer w) (get-buffer "posn-b"))))))

;; **A stale `tab-line-hscroll` is the empty tail, not an error.** Elisp's
;; `nthcdr` answers nil past the end; Scheme's `list-tail` raises, and the
;; tab count shrinks under a scroll position whenever a buffer leaves the
;; window - which is what selecting a buffer from the buffer menu did
;; (`ERROR: In procedure list-tail` out of `tab-line-format-template`,
;; taking the redisplay with it).
(test-assert "a tab-line-hscroll past the last tab is the empty tail"
  (parameterize ((*current-frame* posn-click-frame)
                 (*tab-line-auto-hscroll* #f))
    (set-window-parameter (selected-window) 'tab-line-hscroll 9)
    (let ((formatted (tab-line-format)))
      (set-window-parameter (selected-window) 'tab-line-hscroll #f)
      (pair? formatted))))

(test-end "schemacs_editor_tab_line_posn_click")

;;----------------------------------------------------------------
;; The tab line's right-click (`tab-line.el:1231', `:1442')
;;----------------------------------------------------------------
;;
;; A tab-line click's posn names the *window* and the drawn string, so
;; `popup-menu-normalize-position`'s `posnp` branch is what turns it into
;; `((X . Y) WINDOW)` for `x-popup-menu`; without it the posn reached the
;; C-shaped decode as an event-nil and the menu died. The click is a
;; click, so the flags carry `MENU-FOR-CLICK`.
(test-begin "schemacs_editor_tab_line_context_menu")

(define *shown-tab-line-menu* #f)

(define (menu-strings items used)
  (let loop ((i 0) (acc '()))
    (if (>= i used)
        (reverse acc)
        (let ((v (vector-ref items i)))
          (loop (+ i 1) (if (string? v) (cons v acc) acc))))))

(define-method (menu-show (d <test-display>) frame x y flags title)
  (set! *shown-tab-line-menu*
        (list flags title (menu-strings (menu-items) (menu-items-used))))
  #f)

(set! *shown-tab-line-menu* #f)
(tab-line-tab-context-menu (list 'down-mouse-3 (posn-at-x-y 5 0 tab-posn-frame)))
(test-equal "right-click on the tab line builds its menu"
  '(#t #t)
  (list (and (member "Close" (caddr *shown-tab-line-menu*)) #t)
        (and (member "Close other tabs" (caddr *shown-tab-line-menu*)) #t)))
;; A posn normalized to `((X Y) WINDOW)` carries no click flag - that
;; is the C's own `((X Y) WINDOW)` branch, which sets `window`, `x` and
;; `y` and nothing else (`menu.c:1145`). `MENU_KEYMAPS` (1) is added by
;; `x_popup_menu_1` for the keymap menu itself; `MENU_FOR_CLICK` (2) is
;; not, and must not be: it is the *event* path's flag.
(test-equal "and the click's own flags are clear"
  0 (logand (car *shown-tab-line-menu*) MENU-FOR-CLICK))

(test-end "schemacs_editor_tab_line_context_menu")
