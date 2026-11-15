(import
 (scheme base)
 (scheme write)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (ice-9 exceptions) exception-message)
 (only (schemacs editor dispnew) current-display)
 (only (schemacs editor test-display) <test-display>)
 (only (schemacs editor frame)
       *current-frame* *current-buffer* *default-frame-alist*
       new-frame frame-parameter frame-selected-window window-top
       window-height %frame-tab-bar-lines)
 (only (schemacs editor window) switch-to-buffer)
 (only (schemacs editor tab-bar)
       tab-bar-mode tab-bar-mode-variable tab-bar-tabs tab-bar-new-tab
       tab-bar-select-tab tab-bar-close-tab tab-bar-rename-tab
       tab-bar-format-tabs *tab-bar-format* tab-bar-format-list
       tab-bar--key-to-number tab-bar-mouse-down-1 tab-bar-tabs-set
       tab-bar-close-other-tabs *tab-bar-close-last-tab-choice*)
 (only (schemacs editor buffer)
       get-buffer-create buffer-name current-buffer)
 (only (schemacs editor keyboard) tab-bar-items *last-read-event*)
 (only (schemacs editor xdisp) render! posn-at-x-y)
 (only (schemacs editor editfns) point))

;; Regression tests for `(schemacs editor tab-bar)` - `tab-bar.el`.
;; Each one drives the commands the way a user does, and the expectations
;; are Emacs 31.1's: a new tab starts on the current buffer, switching to
;; a tab restores its window configuration, the current tab's name
;; follows the buffer until it is renamed, and the last tab cannot be
;; closed.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))

(define (names)
  (map (lambda (tab) (cdr (assq 'name (cdr tab)))) (tab-bar-tabs)))

(define (fresh-frame)
  (let ((frame (new-frame (get-buffer-create "tab-one") 24 80)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-mode 1)
      frame)))

(test-begin "schemacs_editor_tab_bar")

(define (condition/report-string ex)
  (or (exception-message ex) ""))


;; The mode puts `tab-bar-lines` on the frame - the parameter
;; `FRAME_TAB_BAR_LINES` reads - and takes it off again.
(test-equal '(1 0)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((on (%frame-tab-bar-lines frame)))
        (tab-bar-mode -1)
        (list on (%frame-tab-bar-lines frame))))))

;; A frame starts with one tab, the current one, named after its buffer.
(test-equal '("tab-one")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (names))))

;; A new tab is added to the right and the old tab is kept.
(test-equal '("tab-one" "tab-one")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (names))))

;; The current tab's name follows its buffer until it is renamed; the
;; other tab's does not.
(test-equal '("tab-one" "two")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (names))))

;; Switching to a tab restores the window configuration it recorded, so
;; the buffer of that tab is current again.
(test-equal "tab-one"
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (tab-bar-select-tab 1)
      (buffer-name (current-buffer)))))

;; Closing a tab leaves the other one.
(test-equal '("tab-one")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-close-tab 2 #f)
      (names))))

;; "Attempt to delete the sole tab in a frame" - the default
;; `tab-bar-close-last-tab-choice`.
(test-equal "Attempt to delete the sole tab in a frame"
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (guard (ex (else (condition/report-string ex)))
        (tab-bar-close-tab 1 #f)
        #f))))

;; Renaming the current tab gives it an explicit name, and the name then
;; stops following the buffer - it stays "mine" as the buffer changes to
;; "three".
(test-equal '("mine")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-rename-tab "mine" #f)
      (switch-to-buffer (get-buffer-create "three"))
      (names))))

;; `tab-bar--key-to-number` - "If KEY is a symbol `tab-N' ... the value is
;; N. If KEY is `current-tab', the value is nil. For any other value of
;; KEY, the value is t."
(test-equal '(1 3 #f #t #t)
  (list (tab-bar--key-to-number 'tab-1)
        (tab-bar--key-to-number 'tab-3)
        (tab-bar--key-to-number 'current-tab)
        (tab-bar--key-to-number 'something)
        (tab-bar--key-to-number #f)))

;; The format: a separator and a tab per tab, then the "+" button - the
;; default `tab-bar-format` minus the history buttons the mode does not
;; have.
(test-equal '(sep-1 tab-1 sep-2 current-tab str-3 add-tab)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (map (lambda (item) (car item)) (tab-bar-format-list (*tab-bar-format*))))))

;; The parsed items carry the tab's caption, its six slots, and a nil
;; binding for a tab (the click finds its tab by the key).
(test-equal '("|" "tab-one x" "|" " + ")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (map (lambda (item) (list-ref item 3)) (tab-bar-items)))))

;; ...and the current tab's item is enabled, with the close button inside
;; its caption - `tab-bar-name-format-close-button`.
(test-equal '(current-tab #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((item (list-ref (tab-bar-items) 1)))
        (list (car item) (list-ref item 1))))))

;; A click in the tab bar selects the tab under it. The click is built the
;; way the display reports one - `posn-at-x-y` on the bar's row - and run
;; through the command the binding dispatches to.
(test-equal "tab-one"
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (render! frame)
      (let* ((posn (posn-at-x-y 4 0 frame))
             (event (list 'down-mouse-1 posn)))
        (*last-read-event* event)
        (tab-bar-mouse-down-1 event)
        (buffer-name (current-buffer))))))

;; The window starts below the bar: `FRAME_TOP_MARGIN` is the menu bar's
;; row plus the tab bar's.
(test-equal '(1 22)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (list (window-top (frame-selected-window frame))
            (window-height (frame-selected-window frame))))))

;; "Close all tabs except the tab" - `C-x t 1`.
(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-new-tab #f #f)
      (tab-bar-close-other-tabs #f)
      (length (tab-bar-tabs)))))

(test-end "schemacs_editor_tab_bar")
