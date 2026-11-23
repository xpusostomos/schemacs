(import
 (scheme base)
 (scheme write)
 (only (oop goops) make define-method)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (ice-9 exceptions) exception-message)
 (only (schemacs dispnew) current-display menu-show
       update-mode-lines? set-update-mode-lines!)
 (only (schemacs menu) menu-items menu-items-used MENU-FOR-CLICK)
 ;; The `hide`-prompt rule's display test (`menu.c:1305`).
 (only (schemacs faces) *window-system*)
 (only (schemacs test-display) <test-display>)
 (only (schemacs frame)
       *current-frame* *current-buffer* *default-frame-alist* *frame-list*
       *frame-creation-function*
       new-frame frame-parameter frame-selected-window window-top
       window-height window-list frame-inner-width %frame-tab-bar-lines
       frame-tab-bar-items change-frame-size resize-frame-windows!)
 (only (schemacs window) switch-to-buffer split-window
      run-window-change-functions)
 (only (schemacs command) command-record-named)
 (only (schemacs tab-bar)
       tab-bar-mode tab-bar-mode-variable tab-bar-tabs tab-bar-new-tab
       tab-bar-select-tab tab-bar-close-tab tab-bar-rename-tab
       tab-bar-format-tabs *tab-bar-format* tab-bar-format-list
       tab-bar--key-to-number tab-bar-mouse-down-1 tab-bar-mouse-1 tab-bar-tabs-set
       tab-bar-close-other-tabs *tab-bar-close-last-tab-choice*
       tab-bar-history-mode tab-bar-history-mode-variable
       tab-bar-history-back tab-bar-history-forward
       tab-bar--history-pre-change tab-bar-format-history
       tab-bar-change-tab-group tab-bar-format-tabs-groups
       tab-bar-duplicate-tab tab-bar-switch-to-tab tab-bar-close-tab-by-name
       tab-bar-rename-tab-by-name tab-bar-format-align-right tab-bar-format-global
       tab-bar-format-list tab-bar-format-tabs *tab-bar-format*
       tab-bar-format-menu-bar tab-bar-menu-bar-button
       tab-switcher tab-switcher-noselect tab-switcher-select tab-switcher-mode
       tab-switcher-mode-map
       *tab-bar-auto-width* *tab-bar-auto-width-max* tab-bar-map tab-bar-mouse-move-tab
       tab-bar-mouse-context-menu tab-bar-move-tab-to-frame
       tab-bar-detach-tab tab-bar--alist-get
       tab-bar-tab-group-default *tab-bar-show-inactive-group-tabs*
       *tab-bar-new-tab-choice* tab-bar-split-tab tab-bar-merge-tabs
       tab-bar-move-window-to-tab split-tab merge-tabs tab-new tab-list)
 (only (schemacs buffer)
       get-buffer-create buffer-name current-buffer with-current-buffer
       buffer-read-only?)
 (only (schemacs keyboard) tab-bar-items *last-read-event*)
 (only (schemacs menu-bar) menu-bar-keymap)
 (only (schemacs keymap) keymap-type? keymap-lookup)
 (only (schemacs subr) kbd)
 (only (schemacs xdisp) render! posn-at-x-y)
 (only (schemacs editfns) point buffer-string)
 (only (schemacs textprop) get-text-property)
 (only (schemacs xdisp) *global-mode-string*)
 (only (schemacs editfns) buffer-string)
 (only (schemacs textprop) get-text-property)
 (only (schemacs simple) *this-command*)
 (only (schemacs window) split-window window-state-put window-state-buffers))

;; Regression tests for `(schemacs tab-bar)` - `tab-bar.el`.
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
  ;; What the echo area shows: a condition's message is a `format'
  ;; template and its arguments ride in the irritants, exactly as
  ;; `keyboard.scm`'s `report-command-error!` puts them back together.
  (if (error-object? ex)
      (let ((message (error-object-message ex))
            (irritants (error-object-irritants ex)))
        (if (and (list? irritants) (pair? irritants))
            (apply format #f (or message "") irritants)
            (or message "")))
      (or (exception-message ex) "")))


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
;; binding for a tab (the click finds its tab by the key). **The captions
;; are the un-stretched names here**: `tab-bar-auto-width` is bound off,
;; because what this checks is the item's shape, not the layout.
(test-equal '("|" "tab-one x" "|" " + ")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f)
                   (*tab-bar-auto-width* #f))
      (map (lambda (item) (list-ref item 3)) (tab-bar-items)))))

;; **`tab-bar-auto-width`** (`tab-bar.el:1288`) gives every tab the same
;; width, so the bar does not shuffle when a buffer name changes length:
;; `(frame-inner-width - the non-tab items) / the tab count`, clamped by
;; `tab-bar-auto-width-min`/`-max`. Two tabs of different name lengths
;; come out the same width, and wider than either name.
(test-equal '(#t #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (let* ((items (tab-bar-items))
             (caption-of
              (lambda (key)
                (let loop ((rest items))
                  (cond ((null? rest) #f)
                        ((eq? (car (car rest)) key) (list-ref (car rest) 3))
                        (else (loop (cdr rest)))))))
             (first (caption-of 'tab-1))
             (current (caption-of 'current-tab)))
        (list (= (string-length first) (string-length current))
              (> (string-length first) (string-length "tab-one x")))))))

;; **The close button is the last thing in the caption, and
;; `tab-bar-auto-width` pads *before* it.** `tab-bar-tab-name-format-
;; close-button` (`tab-bar.el:897`) is `(concat name tab-bar-close-button)`,
;; and the button's `close-tab` text property is what tells the padding
;; loop where to insert (`:1431`) and what tells a click on the X to close
;; the tab. Written with `string-append` the property was dropped - the
;; padding went after the X, and a click on it was not a close.
(test-equal '(#t #t #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (let* ((items (tab-bar-items))
             (caption
              (let loop ((rest items))
                (cond ((null? rest) #f)
                      ((eq? (car (car rest)) 'current-tab)
                       (list-ref (car rest) 3))
                      (else (loop (cdr rest))))))
             (len (string-length caption)))
        (list (eq? (get-text-property (- len 1) 'close-tab caption) #t)
              (char=? (string-ref caption (- len 1)) #\x)
              (> len (string-length "two x")))))))

;; ...and the current tab's item is enabled, with the close button inside
;; its caption - `tab-bar-name-format-close-button`.
(test-equal '(current-tab #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((item (list-ref (tab-bar-items) 1)))
        (list (car item) (list-ref item 1))))))

;; **The tab bar's own map** carries the drag and the right button, as
;; `tab-bar-map` does (`tab-bar.el:562`): `<drag-mouse-1>` moves a tab and
;; `<down-mouse-3>` opens the context menu.
(test-equal '(#t #t)
  (list (eq? (keymap-lookup tab-bar-map (kbd "<drag-mouse-1>"))
             tab-bar-mouse-move-tab)
        (eq? (keymap-lookup tab-bar-map (kbd "<down-mouse-3>"))
             tab-bar-mouse-context-menu)))

;; **A tab moves to another frame** - `tab-bar-move-tab-to-frame`
;; (`tab-bar.el:1912`): it leaves the source frame's list and joins the
;; target's, keeping only its window *state*, because a saved
;; configuration holds window objects that belong to the frame it came
;; from (`(assq-delete-all 'wc ...)`).
(test-equal '(1 2 "tab-three")
  (let ((one (new-frame (get-buffer-create "frame-one") 24 80))
        (two (new-frame (get-buffer-create "frame-two") 24 80)))
    (parameterize ((*current-frame* one) (*current-buffer* #f))
      (tab-bar-mode 1)
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "tab-three"))
      (tab-bar-rename-tab "tab-three" #f)
      (tab-bar-move-tab-to-frame #f one 2 two 1)
      (list (length (tab-bar-tabs one))
            (length (tab-bar-tabs two))
            (tab-bar--alist-get 'name (car (tab-bar-tabs two)))))))

;; **`tab-bar-detach-tab`** (`:1949`) puts a tab on a frame of its own:
;; the tab leaves the frame it was on and the new frame carries it.
(test-equal '(1 1 "carried")
  (let ((frame (new-frame (get-buffer-create "detach-one") 24 80)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f)
                   ;; The test display makes no frames of its own; the
                   ;; creation function is what `make-frame` calls.
                   (*frame-creation-function*
                    (lambda () (new-frame (get-buffer-create "detach-two")
                                          24 80))))
      (tab-bar-mode 1)
      (tab-bar-new-tab #f #f)
      (tab-bar-rename-tab "carried" #f)
      (tab-bar-detach-tab 2)
      (let* ((fresh (let loop ((rest (*frame-list*)))
                      (cond ((null? rest) #f)
                            ((eq? (car rest) frame) (loop (cdr rest)))
                            (else (car rest)))))
             (tabs (tab-bar-tabs fresh)))
        (list (length (tab-bar-tabs frame))
              (length tabs)
              (tab-bar--alist-get 'name (car tabs)))))))

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

;; Clicking the **current** tab is a no-op. Its item's key is
;; `current-tab`, `tab-bar--key-to-number` answers nil for it, and
;; `tab-bar-mouse-down-1` runs `tab-bar-select-tab` (`tab-bar.el:402`) -
;; whose nil translation selects the tab it is already on. Calling the
;; internal function with nil instead died with "Wrong type argument in
;; position 1: #f".
(test-equal "two"
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f)
                   (*tab-bar-auto-width* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "two"))
      (render! frame)
      (let* ((x (let loop ((rest (tab-bar-items)) (col 0))
                  (cond ((null? rest) col)
                        ((eq? (caar rest) 'current-tab) col)
                        (else (loop (cdr rest)
                                    (+ col (string-length
                                            (list-ref (car rest) 3))))))))
             (event (list 'down-mouse-1 (posn-at-x-y x 0 frame))))
        (*last-read-event* event)
        (tab-bar-mouse-down-1 event)
        (buffer-name (current-buffer))))))

;; The "+" button adds a tab. The item's command is the *symbol*
;; `tab-bar-new-tab` in the menu-item form, and the command's two
;; arguments come from its interactive specification - so the click must
;; `call-interactively` it, as `tab-bar-mouse-1` does (`tab-bar.el:417`);
;; a bare call was "Wrong number of arguments".
(test-equal '(2 3)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f)
                   (*tab-bar-auto-width* #f))
      (tab-bar-new-tab #f #f)
      (render! frame)
      (let ((before (length (tab-bar-tabs))))
        (let* ((x (let loop ((rest (tab-bar-items)) (col 0))
                    (cond ((null? rest) col)
                          ((eq? (caar rest) 'add-tab) col)
                          (else (loop (cdr rest)
                                      (+ col (string-length
                                              (list-ref (car rest) 3))))))))
               (event (list 'mouse-1 (posn-at-x-y x 0 frame))))
          (*last-read-event* event)
          (tab-bar-mouse-1 event)
          (list before (length (tab-bar-tabs))))))))

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

;; **Tab history** - `tab-bar-history-mode` - remembers the window
;; configuration before each command that changes it. The command loop
;; runs `tab-bar--history-pre-change` before every command; these tests
;; call it the same way, with `this-command` set, and then run the
;; command.
(define (run-command-history! cmd thunk)
  ;; The command loop's three steps, as far as the history cares:
  ;; `pre-command-hook' (which records the configuration before the
  ;; command), the command, and then `run-window-change-functions' before
  ;; the redisplay - which is what runs
  ;; `window-configuration-change-hook` and so pushes the entry. Emacs
  ;; runs that last step inside `redisplay_internal`; this tree calls it
  ;; from the command loop, one statement before `redisplay-frames!`.
  (parameterize ((*this-command* cmd))
    (tab-bar--history-pre-change)
    (thunk)
    (run-window-change-functions)))

(test-equal '(#f #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((before (tab-bar-history-mode-variable)))
        (tab-bar-history-mode 1)
        (list before (tab-bar-history-mode-variable))))))

(test-equal '(3 2)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-mode 1)
      (tab-bar-history-mode 1)
      (run-command-history! 'start (lambda () #f))
      (run-command-history! 'split
                            (lambda ()
                              (split-window (frame-selected-window frame) -12 #f)))
      ;; one more command so the split's change is noticed
      (run-command-history! 'other (lambda () #f))
      (let ((after-split (length (window-list frame #t))))
        (tab-bar-history-back)
        (list after-split (length (window-list frame #t)))))))

;; ...and forward puts the split back.
(test-equal '(2 3)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-mode 1)
      (tab-bar-history-mode 1)
      (run-command-history! 'start (lambda () #f))
      (run-command-history! 'split
                            (lambda ()
                              (split-window (frame-selected-window frame) -12 #f)))
      (run-command-history! 'other (lambda () #f))
      (tab-bar-history-back)
      (let ((after-back (length (window-list frame #t))))
        (tab-bar-history-forward)
        (list after-back (length (window-list frame #t)))))))

;; The format shows the two buttons only while the mode is on - and with
;; it off the answer is the empty list, Emacs's nil.
(test-equal '(() 4)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-mode 1)
      ;; The mode is `:global`, so a previous test may have left it on.
      (tab-bar-history-mode -1)
      (let ((off (tab-bar-format-history)))
        (tab-bar-history-mode 1)
        (list off (length (tab-bar-format-history)))))))

;; **Tab groups** - `C-x t G` puts a tab in a named group, and
;; `tab-bar-format-tabs-groups` shows one label per group with only the
;; current group's tabs beside it.
(test-equal '(#f "work" "work")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-new-tab #f #f)
      (tab-bar-change-tab-group "work" 1)
      (tab-bar-change-tab-group "work" 2)
      ;; **The default hook moves each tab to its group**, so the order
      ;; is no longer the creation order: the ungrouped current tab is
      ;; first and the two "work" tabs follow it.
      (map tab-bar-tab-group-default (tab-bar-tabs)))))

;; An empty name takes the tab out of its group.
(test-equal '(#f #f "work")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-new-tab #f #f)
      (tab-bar-change-tab-group "work" 1)
      (tab-bar-change-tab-group "work" 2)
      (tab-bar-change-tab-group "" 2)
      (map tab-bar-tab-group-default (tab-bar-tabs)))))

;; The grouped format, after the default hook has moved the tabs into
;; their group: the ungrouped tab, then the current group's label and its
;; two tabs. The label is emitted before the first tab of the current
;; group (`tab-bar--format-tab-group`), and the second tab of that group
;; needs no label of its own.
(test-equal '(sep-1 tab-1 sep-2 current-group sep-2 current-tab
              sep-3 tab-3)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-new-tab #f #f)
      (tab-bar-change-tab-group "work" 1)
      (tab-bar-change-tab-group "work" 2)
      (*tab-bar-show-inactive-group-tabs* #f)
      (map (lambda (item) (car item)) (tab-bar-format-tabs-groups)))))

;; The remaining commands: duplicate adds a tab, switch-to-tab by name
;; creates and renames one that does not exist, and close-tab-by-name
;; removes one by its name.
(test-equal '(3 4 "made")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-duplicate-tab #f #f)
      (let ((after-dup (length (tab-bar-tabs))))
        (tab-bar-switch-to-tab "made")
        (list after-dup
              (length (tab-bar-tabs))
              (cdr (assq 'name (cdr (car (last-pair (tab-bar-tabs)))))))))))

;; **A tab records the frame's window state** - `tab-bar.el:1690`'s
;; `(cons 'ws (window-state-get))` - and `tab-bar-new-tab-choice` `clone`
;; rebuilds the split from one: two windows before, two after.
(test-equal '(2 2)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (car (window-list frame)) 10 #f)
      (let ((before (length (window-list frame))))
        (parameterize ((*tab-bar-new-tab-choice* 'clone))
          (tab-bar-new-tab #f #f))
        (list before (length (window-list frame)))))))

;; The recorded `ws` is a window state, not just a placeholder: it names
;; both windows' buffers and can be put back.
(test-equal '(2 2)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (car (window-list frame)) 10 #f)
      (tab-bar-new-tab #f #f)
      (let* ((ws (cdr (assq 'ws (cdr (car (tab-bar-tabs))))))
             (buffers (length (window-state-buffers ws))))
        (window-state-put ws #f 'safe)
        (list buffers (length (window-list frame)))))))

(test-equal 1
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (tab-bar-rename-tab-by-name "tab-one" "gone")
      (tab-bar-close-tab-by-name "gone")
      (length (tab-bar-tabs)))))

;; **`tab-bar-format-align-right`** leaves a marker that
;; `tab-bar-format-list` replaces with one item whose caption is a space
;; carrying a `(space :align-to N)` display property - N being the frame's
;; width less the items after it. With nothing after it, N is the width.
(test-equal (list 'align-right 80)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (*tab-bar-format* (list tab-bar-format-tabs
                              tab-bar-format-align-right))
      (let* ((items (tab-bar-format-list (*tab-bar-format*)))
             (last (car (reverse items)))
             (spec (get-text-property 0 'display (list-ref last 2))))
        (list (car last)
              (if (and (pair? spec) (eq? (cadr spec) ':align-to))
                  (car (cddr spec))
                  #f))))))

;; `tab-bar-format-global` maps `global-mode-string` to `global` items -
;; empty until a mode puts something there, as Emacs's is.
(test-equal '(() 0)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (list (tab-bar-format-global)
            (length (*global-mode-string*))))))

(define (buffer-string-of b)
  (with-current-buffer b (buffer-string)))

;; **`tab-switcher`** - the `*Tabs*` list. `tab-switcher-noselect`
;; writes the *other* tabs into it, most recently used first, and the
;; buffer is read-only. The command makes a new tab for the list, so the
;; list it writes describes the tabs before it.
(test-equal '(#t #t #f)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "s2"))
      ;; The list holds the tabs that are *not* current: here the frame's
      ;; first tab, "tab-one" - the current one was renamed "s2" by the
      ;; buffer switch.
      (let ((b (tab-switcher-noselect)))
        (list (with-current-buffer b (buffer-read-only? (current-buffer)))
              (if (string-contains (buffer-string-of b) "tab-one") #t #f)
              (if (string-contains (buffer-string-of b) "s2") #t #f))))))

;; **`tab-switcher-mode`'s map carries `:suppress t`** (`tab-bar.el:2772`):
;; "Letters do not insert themselves; instead, they are commands." The
;; binding is the *remap* `suppress-keymap` makes (`subr.el:1316`), so a
;; letter resolves through `command-remapping` rather than being bound
;; directly - the end-to-end path the `special-mode-map` test in
;; `tty-editor-tests` walks. The digits and `-` keep their
;; prefix-argument meaning.
(test-equal '(undefined digit-argument negative-argument)
  (list (keymap-lookup tab-switcher-mode-map
                       (vector 'remap 'self-insert-command))
        (keymap-lookup tab-switcher-mode-map (vector (char->integer #\5)))
        (keymap-lookup tab-switcher-mode-map (vector (char->integer #\-)))))

;; Selecting a line of the list switches to that tab and kills the list.
;; The line selected on entry is the second one, which is the most
;; recently used of the other tabs.
(test-equal '("tab-one" 2)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-new-tab #f #f)
      (switch-to-buffer (get-buffer-create "s2"))
      (tab-switcher)
      (tab-switcher-select)
      (list (buffer-name (current-buffer)) (length (tab-bar-tabs))))))

;; **The Menu button** - `tab-bar-format-menu-bar` - and the keymap it
;; pops: `menu-bar-keymap` is the bar's own items, with the final items
;; last.
(test-equal '(menu-bar "Menu" #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((item (car (tab-bar-format-menu-bar))))
        (list (car item) (list-ref item 2)
              (procedure? (list-ref item 3)))))))

(test-equal '(#t #t #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((map (menu-bar-keymap)))
        (list (keymap-type? map)
              (keymap-type? (keymap-lookup map 'file))
              (keymap-type? (keymap-lookup map 'edit)))))))

;; **`tab-bar-split-tab`** - `tab-bar.el:1978`. Three windows in one tab,
;; ARG 1, the selected window the top one: the pivot is the first child
;; and the selected window is on its side, so the *other* side - the
;; last two windows, combined - moves to a new tab. The old tab keeps
;; the one window, the new one gets the other two.
(test-equal '(2 2 3 1)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (split-window (car (window-list)) 8 #f) 6 #f)
      (let ((before (length (window-list))))
        (tab-bar-split-tab #f 1)
        (let ((tabs (length (tab-bar-tabs)))
              (new-windows (length (window-list))))
          (tab-bar-select-tab 1)
          (list tabs new-windows before (length (window-list))))))))

;; `tab-bar-split-tab` with ARG -1 counts the pivot from the *end*: the
;; pivot is the second child, the selected window (the first) is to its
;; left, so the part split off is the one on the right - the last window
;; alone. Emacs's own rule is "the part which does not include TAB's
;; selected window".
(test-equal '(2 2 1)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (split-window (car (window-list)) 8 #f) 6 #f)
      (tab-bar-split-tab #f -1)
      (let ((new-windows (length (window-list))))
        (tab-bar-select-tab 1)
        (list (length (tab-bar-tabs)) (length (window-list)) new-windows)))))

;; Its three refusals, with Emacs's own messages.
(test-equal '("Cannot split tab with only one window"
              "Invalid ARG 0 for splitting tab"
              "ARG 3 exceeds number of windows 1 that can be split off")
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (let ((one (guard (e (#t (condition/report-string e))) (tab-bar-split-tab #f 1))))
        (split-window (car (window-list)) 8 #f)
        (list one
              (guard (e (#t (condition/report-string e))) (tab-bar-split-tab #f 0))
              (guard (e (#t (condition/report-string e))) (tab-bar-split-tab #f 3)))))))

;; **`tab-bar-merge-tabs`** - `tab-bar.el:2014`: the main window of TAB2
;; becomes a window of TAB1, and TAB2 closes. Splitting then merging
;; gets the two tabs back to one, with the merged-in window beside the
;; others.
(test-equal '(1 3)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (split-window (car (window-list)) 8 #f) 6 #f)
      (tab-bar-split-tab #f 1)
      (tab-bar-merge-tabs 2 1 #f)
      (list (length (tab-bar-tabs)) (length (window-list))))))

;; Merging a tab with itself is refused, and with only one tab there is
;; nothing to merge.
(test-equal "Cannot find tab to merge"
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (guard (e (#t (condition/report-string e))) (tab-bar-merge-tabs 1 1 #f)))))

;; **`tab-bar-move-window-to-tab`**: the selected window leaves the
;; current tab for a tab of its own, and the tab it left closes up.
(test-equal '(2 1 1)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (split-window (car (window-list)) 8 #f)
      (tab-bar-move-window-to-tab)
      (let ((new-windows (length (window-list))))
        (tab-bar-select-tab 1)
        (list (length (tab-bar-tabs)) new-windows (length (window-list)))))))

;; **The `defalias` lines are `define-alias` here**, so the short name is
;; in the obarray `M-x` reads as well as the long one - Emacs gives one
;; function object two symbols and `M-x` finds either. Both names share
;; the *same* record, which is what keeps `this-command` and
;; `called-interactively-p` identical through either.
(test-equal '(#t #t #t #t #t)
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (list (eq? (command-record-named "tab-new")
                 (command-record-named "tab-bar-new-tab"))
            (if (command-record-named "split-tab") #t #f)
            (if (command-record-named "merge-tabs") #t #f)
            (eq? split-tab tab-bar-split-tab)
            (eq? tab-list tab-switcher)))))

(test-end "schemacs_editor_tab_bar")

;;----------------------------------------------------------------
;; The tab bar's right-click, end to end (`tab-bar.el:431', `:569')
;;----------------------------------------------------------------
;;
;; `tab-bar-mouse-context-menu` is bound to `[tab-bar down-mouse-3]',
;; and all it does is build the clicked tab's menu and hand it to
;; `popup-menu`. Two things had to be true for that to pop at all: the
;; Gtk front end had to report the right button as `down-mouse-3', and
;; `x-popup-menu` had to accept a posn whose part-of-window is `tab-bar`
;; as "the current mouse position" (`menu.c:1135') - before that arm
;; existed the posn was read as an event and the menu died with
;; "Wrong type argument: windowp (#f)", so the command could never run.
(test-begin "schemacs_editor_tab_bar_context_menu")

(define *shown-menu* #f)

(define (menu-strings items used)
  ;; Every string in the parsed `menu_items`, in order - item names and
  ;; pane names alike. The structure is a vector of fixed-size groups
  ;; (`menu-items-item-length'), so a string scan is the shape-agnostic
  ;; reader; the tests below keep only the names they are about.
  (let loop ((i 0) (acc '()))
    (if (>= i used)
        (reverse acc)
        (let ((v (vector-ref items i)))
          (loop (+ i 1) (if (string? v) (cons v acc) acc))))))

(define-method (menu-show (d <test-display>) frame x y flags title)
  (set! *shown-menu* (list flags title (menu-strings (menu-items)
                                                     (menu-items-used))))
  #f)

(define (only-names names wanted)
  (let loop ((rest names) (acc '()))
    (if (null? rest)
        (reverse acc)
        (loop (cdr rest)
              (if (member (car rest) wanted)
                  (cons (car rest) acc)
                  acc)))))

(let ((frame (fresh-frame)))
  (parameterize ((*current-frame* frame) (*current-buffer* #f))
    (render! frame)
    (set! *shown-menu* #f)
    (tab-bar-mouse-context-menu (list 'down-mouse-3 (posn-at-x-y 4 0 frame)) #f)
    (test-equal "right-click on a tab builds that tab's menu and shows it"
      '("Duplicate" "Detach" "Close" "Close other tabs")
      (only-names (caddr *shown-menu*)
                  '("Duplicate" "Detach" "Close" "Close other tabs")))
    ;; The bar's own contribution is no flag at all; the 1 that
    ;; `x_popup_menu_1` adds is `MENU_KEYMAPS`, because the menu it was
    ;; handed is a keymap. What matters is that `MENU_FOR_CLICK` - which
    ;; the event path sets - is absent.
    (test-equal "the tab bar's position is the current mouse position, not a click"
      0 (logand (car *shown-menu*) MENU-FOR-CLICK))))

;; **A prompt whose first character has the `hide` property is not a
;; title on a window system** (`menu.c:1305`, the USE_GTK/NS arm). That
;; is what `(propertize "Context Menu" 'hide t)` is for: without it the
;; menu shows a title item reading "Context Menu".
(let ((frame (fresh-frame)))
  (parameterize ((*current-frame* frame) (*current-buffer* #f))
    (render! frame)
    (parameterize ((*window-system* 'pgtk))
      (set! *shown-menu* #f)
      (tab-bar-mouse-context-menu (list 'down-mouse-3 (posn-at-x-y 4 0 frame)) #f)
      (test-equal "a hidden prompt is not a menu title on a window system"
        #f (cadr *shown-menu*)))
    ;; ...and on a terminal the prompt *is* the title, as the tty menu
    ;; draws it.
    (set! *shown-menu* #f)
    (tab-bar-mouse-context-menu (list 'down-mouse-3 (posn-at-x-y 4 0 frame)) #f)
    (test-equal "on a terminal the prompt is the title"
      "Context Menu" (cadr *shown-menu*))))

(test-end "schemacs_editor_tab_bar_context_menu")

;;----------------------------------------------------------------
;; A frame resize re-fits the tabs (`tab-bar-auto-width')
;;----------------------------------------------------------------
;;
;; `tab-bar-auto-width` distributes the tabs across
;; `frame-inner-width`, and its docstring says the widths "change only
;; when tabs are added or deleted, or when the frame's dimensions
;; change" (`tab-bar.el:1288`). Our `update-tab-bar` is gated on
;; `update-mode-lines?` (Emacs's `update_tab_bar` is gated the same
;; way), so a resize that does not set the flag leaves the bar drawn at
;; its old width while `tab-bar--event-to-item` recomputes the layout at
;; click time - the bar looks wide, the hit test is narrow, and a click
;; on the second tab lands past the last one.
(test-begin "schemacs_editor_tab_bar_resize")

(define (tab-caption frame)
  (let ((items (frame-tab-bar-items frame)))
    (let loop ((i 0))
      (and (< i (vector-length items))
           (let ((v (vector-ref items i)))
             (if (and (string? v) (>= (string-length v) 7)
                      (string=? (substring v 0 7) "tab-one"))
                 v
                 (loop (+ i 1))))))))

(parameterize ((*tab-bar-auto-width-max* '((10000) 10000)))
  (let ((frame (fresh-frame)))
    (parameterize ((*current-frame* frame) (*current-buffer* #f))
      (tab-bar-mode 1)
      (render! frame)
      (let ((wide (and (tab-caption frame)
                       (string-length (tab-caption frame)))))
        (test-equal "the tab has a caption to resize" #t (and wide #t))
        (set-update-mode-lines! #f)
        (resize-frame-windows! frame 24 80 24 60)
        (test-equal "a frame resize marks the mode lines for update"
          #t (update-mode-lines?))
        (change-frame-size frame 60 24 #f #f)
        ;; **`update-tab-bar` directly, not `render!`.** The test
        ;; display's screen size is a fixed 80x24, and a `render!`
        ;; re-derives the frame's size from it, undoing the resize. The
        ;; real front ends report the window's own size, so this is the
        ;; harness's limit, not the editor's.
        ((@@ (schemacs xdisp) update-tab-bar) frame)
        (test-equal "the tab is rebuilt at the frame's new width"
          #t (< (string-length (tab-caption frame)) wide))))))

(test-end "schemacs_editor_tab_bar_resize")
