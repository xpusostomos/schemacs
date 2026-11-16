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
       window-height window-list frame-inner-width %frame-tab-bar-lines)
 (only (schemacs editor window) switch-to-buffer)
 (only (schemacs editor tab-bar)
       tab-bar-mode tab-bar-mode-variable tab-bar-tabs tab-bar-new-tab
       tab-bar-select-tab tab-bar-close-tab tab-bar-rename-tab
       tab-bar-format-tabs *tab-bar-format* tab-bar-format-list
       tab-bar--key-to-number tab-bar-mouse-down-1 tab-bar-tabs-set
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
       tab-bar-tab-group-default *tab-bar-show-inactive-group-tabs*
       *tab-bar-new-tab-choice*)
 (only (schemacs editor buffer)
       get-buffer-create buffer-name current-buffer with-current-buffer
       buffer-read-only?)
 (only (schemacs editor keyboard) tab-bar-items *last-read-event*)
 (only (schemacs editor menu-bar) menu-bar-keymap)
 (only (schemacs editor keymap) keymap-type? keymap-lookup)
 (only (schemacs editor xdisp) render! posn-at-x-y)
 (only (schemacs editor editfns) point buffer-string)
 (only (schemacs editor textprop) get-text-property)
 (only (schemacs editor xdisp) *global-mode-string*)
 (only (schemacs editor editfns) buffer-string)
 (only (schemacs editor textprop) get-text-property)
 (only (schemacs editor simple) *this-command*)
 (only (schemacs editor window) split-window window-state-put window-state-buffers))

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

;; **Tab history** - `tab-bar-history-mode` - remembers the window
;; configuration before each command that changes it. The command loop
;; runs `tab-bar--history-pre-change` before every command; these tests
;; call it the same way, with `this-command` set, and then run the
;; command.
(define (run-command-history! cmd thunk)
  (parameterize ((*this-command* cmd))
    (tab-bar--history-pre-change)
    (thunk)))

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

(test-end "schemacs_editor_tab_bar")
