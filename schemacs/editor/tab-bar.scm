(define-library (schemacs editor tab-bar)
  ;; This library mirrors GNU Emacs's `lisp/tab-bar.el`: the frame's tab
  ;; bar - a row of tabs above each frame's text, each one a *named
  ;; persistent window configuration*.
  ;;
  ;; The display half is `xdisp.scm`'s and was ported first: the row is
  ;; reserved by `(%frame-tab-bar-lines frame)` (`FRAME_TAB_BAR_LINES`),
  ;; `update-tab-bar`/`display-tab-bar` draw it under the menu bar, and
  ;; `tab-bar-items` (`keyboard.c`'s `tab_bar_items`) parses what this
  ;; file's `tab-bar-make-keymap` produces. What is here is the Lisp
  ;; half.
  ;;
  ;; **A tab is a window configuration**, and `(schemacs editor window)`
  ;; ports `current-window-configuration`/`set-window-configuration` for
  ;; exactly this. Switching tabs restores the configuration; the
  ;; keyboard and mouse commands make, close and reorder them.
  ;;
  ;; **The departures, all of them the tree's rather than this file's:**
  ;;
  ;;   * `defcustom` is `define-custom`, so an option is a *parameter*
  ;;     and is read `(*tab-bar-show*)` where Emacs writes
  ;;     `tab-bar-show`.
  ;;   * a tab alist has no head symbol: Emacs writes
  ;;     `(tab (name . "x") ...)` and Guile's `assq` raises on a
  ;;     non-pair element. `tab-bar.el` itself already tolerates both
  ;;     heads - nothing reads the car - so `(current-tab (name . ...))`
  ;;     and `((name . ...))` are the same tab to every function here.
  ;;   * **functions first, tables second**: a keymap here holds
  ;;     *procedures*, so `define-key` cannot run before its command is
  ;;     defined.
  ;;   * `last-nonmenu-event` is `*last-read-event*`; `window-system` is
  ;;     `(*window-system*)`; `frame-parameter nil` is the selected
  ;;     frame's; `seq-position`/`seq-filter` are over lists.
  ;;   * `(prefix-numeric-value arg)` is `(uarg->integer 1 arg)`.
  ;;   * `cl-pushnew x (nthcdr i list)` is `tab-bar--insert-at` below:
  ;;     a list here is not a mutable chain.
  ;;   * **`[tab-bar]`'s `:filter`** is applied by `update-tab-bar`
  ;;     (`xdisp.scm`) rather than by `get_keyelt`, whose evaluating
  ;;     half is `keyboard.c`'s and `keymap.scm` is below it.
  ;;
  ;; **Not carried, with what each waits for:**
  ;;
  ;;   * the tab's **window state** (`ws`, `window-state-get`): window
  ;;     states are not ported, so a tab saved by one session and read
  ;;     by another cannot be restored. Live tabs use `wc` (a window
  ;;     configuration), which is the branch Emacs takes for tabs of the
  ;;     same session - "During the same session, use window-configuration
  ;;     to switch tabs, because window-configurations are more reliable
  ;;     (they keep references to live buffers) than window-states".
  ;;   * `frameset-*` persistence (`tab-bar--tab`'s `ws` source) and
  ;;     `tab-bar-select-restore-context` (`window-point-context-*`).
  ;;   * **tab groups** (`tab-bar-tab-group-*`, `tab-bar-format-tabs-groups`):
  ;;     the display they need is a group label with its own face and a
  ;;     `tab-bar-auto-width` measurement between groups.
  ;;   * **`tab-bar-history-mode`** and its back/forward buttons: it
  ;;     saves a window configuration before every command, which needs
  ;;     `pre-command-hook` bookkeeping the tab line does not have.
  ;;   * **`tab-bar-auto-width`**: it lays tabs out with a `display`
  ;;     space specification measured in pixels, and this renderer draws
  ;;     character cells. The variable is carried so a user setting it
  ;;     sees no error; the bar simply is not stretched.
  ;;   * **touch input, tab drag and detach** (`tab-bar-mouse-move-tab`,
  ;;     `tab-bar-detach-tab`): no touch events, and detaching needs a
  ;;     new frame built *from* a window configuration, which
  ;;     `new-frame` does not take.
  ;;   * `tab-bar-format-align-right`/`-global` (a `display` space
  ;;     specification and `string-pixel-width`), `tab-bar-menu-bar`
  ;;     (the menu bar is a row, not a popup) and `tab-bar-rename-tab-by-name`.

  (import
    (scheme base)
    (scheme char)
    (only (guile) make-hash-table hashq-set! hashq-ref
           get-internal-real-time internal-time-units-per-second
           exact->inexact 1+ 1-)
    (only (schemacs editor command) define-command uarg->integer
          current-prefix-arg)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor custom) define-custom custom-initialize-default)
    (only (schemacs editor easy-mmode) define-minor-mode)
    (only (schemacs editor keymap) define-key make-sparse-keymap
          *default-keymap* keymap-type? keymap-lookup map-keymap)
    (only (schemacs editor frame)
          *current-frame* *frame-list* *default-frame-alist* delete-frame
          frame-parameter set-frame-parameter frame-list selected-frame
          select-frame frame-live-p frame-width
          frame-selected-window selected-window window-list window-buffer
          window-minibuffer-p window-parameter set-window-parameter
          window-internal? window-parent window-height
          resize-frame-windows! frame-height frame-width)
    (only (schemacs editor window)
          current-window-configuration set-window-configuration
          window-configuration-p window-configuration-frame
          *window-restore-killed-buffer-windows*
          delete-other-windows split-window delete-window
          switch-to-buffer other-window)
    (only (schemacs editor buffer)
          buffer-name buffer-live-p current-buffer get-buffer
          set-buffer-local-value! buffer-local-value)
    (only (schemacs editor subr) run-hook-with-args
          run-hook-with-args-until-success add-hook remove-hook
          assq-delete-all delq posn-string posn-x-y event-start)
    (only (schemacs editor editfns) goto-char point propertize message)
    (only (schemacs editor marker) copy-marker markerp marker-buffer
          marker-position)
    (only (schemacs editor mule-util) truncate-string-to-width
          truncate-string-ellipsis)
    (only (schemacs editor textprop) get-text-property add-face-text-property
          put-text-property)
    (only (schemacs editor seq) seq-position seq-filter seq-remove seq-sort-by)
    (only (schemacs editor xdisp) force-mode-line-update
          *tab-bar-keymap-function*)
    (only (schemacs editor faces) *window-system*)
    (only (schemacs editor menu-bar) popup-menu)
    (only (schemacs editor minibuffer) read-from-minibuffer format-prompt)
    (only (schemacs editor simple) *last-command*)
    (only (schemacs editor keyboard) *last-read-event*)
    (only (schemacs editor dispnew) current-display column-width))

  (export
   ;; the mode and its frames
   tab-bar-mode tab-bar-mode-variable tab-bar--update-tab-bar-lines
   tab-bar--tab-bar-lines-for-frame toggle-frame-tab-bar
   ;; the tab list
   tab-bar-tabs tab-bar-tabs-set *tab-bar-tabs-function*
   tab-bar--tab tab-bar--current-tab tab-bar--current-tab-make
   tab-bar--current-tab-find tab-bar--current-tab-index
   tab-bar--tab-index tab-bar--tab-index-by-name tab-bar--tabs-recent
   ;; the commands
   tab-bar-new-tab tab-bar-new-tab-to tab-bar-close-tab
   tab-bar-close-other-tabs tab-bar-undo-close-tab
   tab-bar-select-tab tab-bar-switch-to-next-tab
   tab-bar-switch-to-prev-tab tab-bar-switch-to-last-tab
   tab-bar-switch-to-recent-tab tab-bar-rename-tab
   tab-bar-move-tab tab-bar-move-tab-to
   ;; the name and face of one tab
   tab-bar-tab-name-current tab-bar-tab-name-current-with-count
   tab-bar-tab-name-all tab-bar-tab-name-truncated
   tab-bar-tab-name-format-truncated tab-bar-tab-name-format-hints
   tab-bar-tab-name-format-close-button tab-bar-tab-name-format-default
   tab-bar-tab-name-format-face tab-bar-tab-name-format-mouse-face
   tab-bar-tab-face-default
   ;; the format and the keymap it becomes
   tab-bar-format-list tab-bar-make-keymap tab-bar-make-keymap-1
   tab-bar-format-tabs tab-bar-format-add-tab tab-bar-format-history
   tab-bar--format-tab
   ;; the mouse
   tab-bar-mouse-down-1 tab-bar-mouse-1 tab-bar-mouse-close-tab
   tab-bar--event-to-item tab-bar--key-to-number
   ;; the options and the keymaps
   *tab-bar-show* *tab-bar-new-tab-choice* *tab-bar-new-tab-group*
   *tab-bar-new-tab-to* *tab-bar-close-tab-select*
   *tab-bar-close-last-tab-choice* *tab-bar-tab-name-function*
   *tab-bar-tab-name-truncated-max* *tab-bar-tab-name-ellipsis*
   *tab-bar-tab-format-functions* *tab-bar-tab-name-format-function*
   *tab-bar-format* *tab-bar-define-keys* *tab-bar-select-tab-modifiers*
   *tab-bar-tab-hints* *tab-bar-close-button-show* *tab-bar-new-button-show*
   *tab-bar-auto-width* *tab-bar-tab-prevent-close-functions*
   *tab-bar-tab-pre-close-functions*
   *tab-bar-post-undo-close-tab-functions*
   *tab-bar-tabs-function*
   tab-bar-map tab-bar-mode-map tab-bar-new-button tab-bar-close-button
   tab-bar-back-button tab-bar-forward-button tab-bar-separator
   tab-bar-closed-tabs)

  (begin

    ;;--------------------------------------------------------------
    ;; The options that do not name a function - `defcustom`s of the
    ;; file, in the C's order, and each a parameter because a ported
    ;; caller `let`-binds some of them (`tab-bar-duplicate-tab` binds
    ;; `tab-bar-new-tab-choice` and `tab-bar-new-tab-group`).
    ;;--------------------------------------------------------------

    (define-custom *tab-bar-show* #t
      "Defines when to show the tab bar.
If t, the default, enable `tab-bar-mode' automatically upon using
the commands that create new window configurations (e.g., `tab-new').
If a non-negative integer, show the tab bar only if the number of
the tabs exceeds the value of this variable.
If 0, always keep the tab bar shown.
If nil, always keep the tab bar hidden."
      :type '(choice (const :tag "On creating a new tab" #t)
                     (const :tag "Always" 0)
                     (const :tag "When more than one tab" 1)
                     (const :tag "Never" #f))
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-new-tab-choice* #t
      "Defines what to show in a new tab.
If t, start a new tab with the current buffer.
If the value is the symbol `window', then keep the selected window
as a single window on the new tab.
If the value is a string, use it as a buffer name to switch to.
If the value is a function, call it with no arguments and switch
to the buffer that it returns.
If `clone', duplicate the contents of the tab that was active."
      :type '(choice (const :tag "Current buffer" #t)
                     (const :tag "Current window" window)
                     (string :tag "Buffer" "*scratch*")
                     (function :tag "Function")
                     (const :tag "Duplicate tab" clone))
      :group 'tab-bar)

    (define-custom *tab-bar-new-tab-group* #t
      "Defines what group to assign to a new tab.
If nil, don't set a default group automatically.
If t, inherit the group name from the previous tab."
      :type '(choice (const :tag "No group" #f)
                     (const :tag "Inherit group from previous tab" #t)
                     (string :tag "Fixed group name")
                     (function :tag "Function that returns group name"))
      :group 'tab-bar)

    (define-custom *tab-bar-new-tab-to* 'rightmost
      "Defines where to create a new tab.
If `leftmost', create as the first tab.
If `rightmost', create as the last tab.
If `left', create to the left of the current tab.
If `right', create to the right of the current tab.
If the value is a function, call it with no arguments and use the
number it returns."
      :type '(choice (const :tag "Rightmost" rightmost)
                     (const :tag "Leftmost" leftmost)
                     (const :tag "Right of the current tab" right)
                     (const :tag "Left of the current tab" left)
                     (function :tag "Function"))
      :group 'tab-bar)

    (define-custom *tab-bar-close-tab-select* 'recent
      "Which tab to make current after closing the specified tab.
If `left', select the adjacent left tab.
If `right', select the adjacent right tab.
If `recent', select the most recently visited tab."
      :type '(choice (const :tag "Select left tab" left)
                     (const :tag "Select right tab" right)
                     (const :tag "Select recent tab" recent))
      :group 'tab-bar)

    (define-custom *tab-bar-close-last-tab-choice* #f
      "What to do when the last tab is closed.
If nil, do nothing and show a message.
If `delete-frame', delete the containing frame.
If `tab-bar-mode-disable', disable `tab-bar-mode'.
If the value is a function, call that function with the tab to be
closed as an argument."
      :type '(choice (const :tag "Do nothing and show message" #f)
                     (const :tag "Close the containing frame" delete-frame)
                     (const :tag "Disable tab-bar-mode" tab-bar-mode-disable)
                     (function :tag "Function"))
      :group 'tab-bar)

    (define-custom *tab-bar-tab-hints* #f
      "Show absolute numbers on tabs in the tab bar before the tab name."
      :type 'boolean
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-new-button-show* #t
      "If non-nil, show the \"New tab\" button in the tab bar."
      :type 'boolean
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-close-button-show* #t
      "Defines where to show the close tab button.
If t, show the close tab button on all tabs.
If `selected', show it only on the selected tab.
If `non-selected', show it only on non-selected tab.
If nil, don't show it at all."
      :type '(choice (const :tag "On all tabs" #t)
                     (const :tag "On selected tab" selected)
                     (const :tag "On non-selected tabs" non-selected)
                     (const :tag "None" #f))
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-auto-width* #t
      "Automatically resize width of tabs on tab bar.
**Carried as a variable only**: the layout it does is a `display`
space specification measured in pixels, and this renderer draws
character cells. Setting it has no effect here."
      :type 'boolean
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-define-keys* #t
      "Define specified tab-bar key bindings.
If t, the default, all key mappings are defined.
If `numeric', define only numeric select-tab key mappings.
If `tab', define only TAB and SHIFT-TAB tab-selection key mappings.
If nil, define no additional key mappings."
      :type '(choice (const :tag "All" #t)
                     (const :tag "Numeric" numeric)
                     (const :tag "TAB keys" tab)
                     (const :tag "None" #f))
      :group 'tab-bar)

    (define-custom *tab-bar-select-tab-modifiers* '()
      "If non-nil, a list of modifier keys for selecting tab by its index."
      :type '(repeat (choice (const :tag "Meta" meta)
                             (const :tag "Ctrl" control)
                             (const :tag "Shift" shift)
                             (const :tag "Super" super)
                             (const :tag "Hyper" hyper)
                             (const :tag "Alt" alt)))
      :group 'tab-bar)

    (define-custom *tab-bar-tab-prevent-close-functions* '()
      "List of functions to call to determine whether to close a tab.
The tab to be closed and a boolean indicating whether or not it
is the only tab in the frame are supplied as arguments."
      :type '(repeat function)
      :group 'tab-bar)

    (define-custom *tab-bar-tab-pre-close-functions* '()
      "List of functions to call before closing a tab."
      :type '(repeat function)
      :group 'tab-bar)

    (define-custom *tab-bar-post-undo-close-tab-functions* '()
      "List of functions to call after a closed tab is restored."
      :type '(repeat function)
      :group 'tab-bar)

    ;; The buttons - `defvar`s, read and `setq`-ed but not `let`-bound,
    ;; so plain names like Emacs's.
    (define tab-bar-new-button " + ")
    (define tab-bar-close-button
      (propertize " x" 'close-tab #t ':help "Click to close tab"))
    (define tab-bar-back-button " < ")
    (define tab-bar-forward-button " > ")
    ;; GNU Emacs has a *variable* and a *function* both called
    ;; `tab-bar-separator`; Scheme is a Lisp-1, so the variable is
    ;; `tab-bar-separator-string` here - the same `-string` suffix
    ;; `mule-util.scm` uses for `truncate-string-ellipsis`. The function
    ;; keeps the name, because the format list names it.
    (define tab-bar-separator-string #f)

    (define (tab-bar-separator)
      ;; "Separator between tabs." The C's `(if (window-system) " " "|")`
      ;; is this tree's `(*window-system*)`, which is the selected
      ;; frame's display.
      ;;--------------------------------------------------------------
      (or tab-bar-separator-string (if (*window-system*) " " "|")))

    ;; `tab-bar-closed-tabs`: "A list of closed tabs to be able to undo
    ;; their closing." `push` is a `set!` here.
    (define tab-bar-closed-tabs '())

    ;; The hooks the commands run - `defvar`s in the C, plain (nothing
    ;; `let`-binds them) and read as lists.
    (define *tab-bar-tab-post-open-functions* (make-parameter '()))
    (define *tab-bar-tab-post-select-functions* (make-parameter '()))

    (define-custom *tab-bar-select-restore-windows* #t
      "Function called when selecting a tab to handle windows whose
buffer was killed. If nil, `set-window-configuration' decides."
      :type '(choice (const :tag "Restore" #t)
                     (function :tag "Function"))
      :group 'tab-bar)

    ;;--------------------------------------------------------------
    ;; The tab list - `tab-bar-tabs` and what walks it
    ;;--------------------------------------------------------------

    (define *tab-bar-tabs-function* (make-parameter #f))
    ;; ^ `tab-bar-tabs-function`, the `defvar` that holds a *procedure*.
    ;; It is a parameter because `tab-bar-tabs` reads it through a
    ;; `funcall` in Emacs and a user `setq`s it; and because a parameter
    ;; holding a procedure must be called twice - `((*x*))` - which is
    ;; what every reader below does.
    ;;
    ;; It is set at the end of this library to `tab-bar-tabs`, once that
    ;; is defined - Emacs sets it in its `defvar` with `#'tab-bar-tabs`,
    ;; which a Scheme file can only do after the definition.

    (define (tab-bar--assq key alist)
      ;; `assq` over a *tab*: a tab is `(current-tab (name . "x") ...)` or
      ;; `(tab (name . "x") ...)` - the C's head symbol, which
      ;; `(eq (car tab) 'current-tab)` reads - and Guile's `assq` raises on
      ;; a non-pair element where Emacs's `Fassq` steps over it. The head
      ;; is stepped over here, and the pair is answered so a caller can
      ;; write it (`tab-bar-rename-tab` does).
      ;;--------------------------------------------------------------
      (let loop ((rest alist))
        (cond ((null? rest) #f)
              ((not (pair? (car rest))) (loop (cdr rest)))
              ((eq? (car (car rest)) key) (car rest))
              (else (loop (cdr rest))))))

    (define (tab-bar--alist-get key alist)
      ;; `alist-get` for a tab: the cdr of the pair whose car is KEY, or
      ;; #f - Emacs's nil, which is what every caller tests.
      ;;--------------------------------------------------------------
      (let ((pair (tab-bar--assq key alist)))
        (and pair (cdr pair))))

    (define (tab-bar--insert-at lst index value)
      ;; `(cl-pushnew VALUE (nthcdr INDEX LIST))`: put VALUE at INDEX of
      ;; LIST, in place of the C's `setcdr` on a list this tree rebuilds.
      ;;
      ;; **LST, not LIST**: a parameter called `list` hides the
      ;; constructor, and `(list value)` then calls the sequence - the
      ;; same Lisp-1 trap as `string` in `search.scm`.
      ;;--------------------------------------------------------------
      (let loop ((rest lst) (i index) (acc '()))
        (cond ((= i 0) (append (reverse acc) (list value) rest))
              ((null? rest) (append (reverse acc) (list value)))
              (else (loop (cdr rest) (- i 1) (cons (car rest) acc))))))

    (define (tab-bar--current-tab-find . args)
      ;; "Find the current tab as a pointer to its data structure."
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame))))
        (assq 'current-tab tabs)))

    (define (tab-bar--current-tab-index . args)
      ;; "Return the index of the current tab."
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame))))
        (seq-position tabs 'current-tab (lambda (a b) (eq? (car a) b)))))

    (define (tab-bar--tab-index tab . args)
      ;; "Return the index of TAB."
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame))))
        (seq-position tabs tab eq?)))

    (define (tab-bar--tab-index-by-name name . args)
      ;; "Return the index of TAB by its NAME."
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame))))
        (seq-position tabs name
                      (lambda (a b) (equal? (tab-bar--alist-get 'name a) b)))))

    (define (tab-bar--tabs-recent . args)
      ;; "Return the list of tabs sorted by recency." `seq-remove` drops
      ;; the current tab - the C's own `(lambda (tab) (eq (car tab)
      ;; 'current-tab))` - and `>` on `time` sorts newest first.
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame))))
        (seq-sort-by (lambda (tab) (tab-bar--alist-get 'time tab))
                     >
                     (seq-remove (lambda (tab) (eq? (car tab) 'current-tab))
                                 tabs))))

    (define (tab-bar--tab-index-recent nth . args)
      ;; "Return the index of NTH recent tab."
      ;;--------------------------------------------------------------
      (let* ((tabs (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (tabs (or tabs ((*tab-bar-tabs-function*) frame)))
             (sorted-tabs (tab-bar--tabs-recent tabs frame))
             (tab (list-ref sorted-tabs (- nth 1))))
        (tab-bar--tab-index tab tabs)))

    (define (tab-bar-tabs . args)
      ;; "Return a list of tabs belonging to the FRAME. Ensure the frame
      ;; parameter `tabs' is pre-populated. Update the current tab name
      ;; when it exists. Return its existing value or a new value."
      ;;
      ;; The `setf (cdr current-tab-name)` is a `set-cdr!`: the pair is
      ;; in the frame parameter's structure and every reader sees the
      ;; new name, which is the point of updating it in place.
      ;;--------------------------------------------------------------
      (let* ((frame (or (and (pair? args) (car args)) (selected-frame)))
             (tabs (frame-parameter frame 'tabs)))
        (if (and tabs (pair? tabs))
            (let* ((current-tab (tab-bar--current-tab-find tabs))
                   (current-tab-name (and current-tab
                                          (tab-bar--assq 'name current-tab)))
                   (current-tab-explicit-name
                    (and current-tab (tab-bar--assq 'explicit-name current-tab))))
              (when (and current-tab-name
                         current-tab-explicit-name
                         (not (cdr current-tab-explicit-name)))
                (set-cdr! current-tab-name
                          ((*tab-bar-tab-name-function*))))
              tabs)
            ;; "Create default tabs"
            (let ((tabs (list (tab-bar--current-tab-make))))
              (tab-bar-tabs-set tabs frame)
              (run-hook-with-args (*tab-bar-tab-post-open-functions*)
                                  (car tabs))
              tabs))))

    (define (tab-bar-tabs-set tabs . args)
      ;; "Set a list of TABS on the FRAME."
      ;;--------------------------------------------------------------
      (let ((frame (or (and (pair? args) (car args)) (selected-frame))))
        (set-frame-parameter frame 'tabs tabs)))

    (define (tab-bar--current-tab-make . args)
      ;; "Make the current tab data structure from TAB. TAB here is an
      ;; argument meaning \"use tab as template\" ... This is necessary
      ;; when switching tabs, otherwise the destination tab inherits the
      ;; current tab's `explicit-name' parameter."
      ;;--------------------------------------------------------------
      (let* ((tab (if (pair? args) (car args) #f))
             (tab-explicit-name (and tab (tab-bar--alist-get 'explicit-name tab)))
             (tab-group (if tab
                            (tab-bar--alist-get 'group tab)
                            (let ((choice (*tab-bar-new-tab-group*)))
                              (cond ((string? choice) choice)
                                    ((procedure? choice) (choice))
                                    (else #f))))))
        (append
         (list 'current-tab
               (cons 'name (if tab-explicit-name
                               (tab-bar--alist-get 'name tab)
                               ((*tab-bar-tab-name-function*))))
               (cons 'explicit-name tab-explicit-name))
         (if tab-group (list (cons 'group tab-group)) '())
         ;; "Copy other possible parameters"
         (let loop ((rest (if tab (cdr tab) '())) (acc '()))
           (cond ((null? rest) (reverse acc))
                 ((memq (car (car rest))
                        '(name explicit-name group time
                          ws wc wc-point wc-bl wc-bbl
                          wc-history-back wc-history-forward))
                  (loop (cdr rest) acc))
                 (else (loop (cdr rest) (cons (car rest) acc))))))))

    (define (tab-bar--tab . args)
      ;; "Make a new tab data structure that can be added to tabs on the
      ;; FRAME."
      ;;
      ;; **`ws` is nil here**: `window-state-get` is not ported, and a
      ;; window state no reader could restore is worse than a field that
      ;; says so. `wc` is the branch `tab-bar-select-tab` takes for a
      ;; tab of this session, which is every tab this build makes.
      ;;--------------------------------------------------------------
      (let* ((frame (or (and (pair? args) (car args)) (selected-frame)))
             (tab (tab-bar--current-tab-find #f frame))
             (tab-explicit-name (and tab
                                     (tab-bar--alist-get 'explicit-name tab)))
             (tab-group (and tab (tab-bar--alist-get 'group tab)))
             (frame-buffers (frame-parameter frame 'buffer-list))
             (frame-buried (frame-parameter frame 'buried-buffer-list)))
        (append
         (list 'tab
               (cons 'name (if tab-explicit-name
                               (tab-bar--alist-get 'name tab)
                               ((*tab-bar-tab-name-function*))))
               (cons 'explicit-name tab-explicit-name))
         (if tab-group (list (cons 'group tab-group)) '())
         (list (cons 'time (current-time-float))
               (cons 'ws #f)
               (cons 'wc (current-window-configuration))
               (cons 'wc-point (copy-marker (point)))
               (cons 'wc-bl (seq-filter buffer-live-p
                                        (or frame-buffers '())))
               (cons 'wc-bbl (seq-filter buffer-live-p
                                         (or frame-buried '()))))
         ;; "Copy other possible parameters" - spliced, not nested: the
         ;; C's `,@(mapcan ...)`.
         (let loop ((rest (if tab (cdr tab) '())) (acc '()))
           (cond ((null? rest) (reverse acc))
                 ((and (pair? (car rest))
                       (memq (car (car rest))
                             '(name explicit-name group time
                               ws wc wc-point wc-bl wc-bbl
                               wc-history-back wc-history-forward)))
                  (loop (cdr rest) acc))
                 ((pair? (car rest))
                  (loop (cdr rest) (cons (car rest) acc)))
                 (else (loop (cdr rest) acc)))))))

    (define (tab-bar--current-tab . args)
      ;; "Make the current tab data structure from TAB on FRAME."
      ;;--------------------------------------------------------------
      (let* ((tab (if (pair? args) (car args) #f))
             (frame (if (and (pair? args) (pair? (cdr args))) (cadr args) #f)))
        (tab-bar--current-tab-make
         (or tab (tab-bar--current-tab-find #f frame)))))

    (define (current-time-float)
      ;; `(float-time)`, which `tab-bar--tab` stores as the tab's `time`
      ;; and `tab-bar--tabs-recent` sorts by. A monotonic-in-seconds
      ;; value is all either needs; `(get-internal-real-time)` is that.
      ;;--------------------------------------------------------------
      (exact->inexact
       (/ (get-internal-real-time) internal-time-units-per-second)))

    ;;--------------------------------------------------------------
    ;; `tab-bar-mode` and the frame parameter it maintains
    ;;--------------------------------------------------------------

    (define (tab-bar--tab-bar-lines-for-frame frame)
      ;; "Determine and return the value of `tab-bar-lines' for FRAME."
      ;;--------------------------------------------------------------
      (let ((show (*tab-bar-show*)))
        (cond ((not (tab-bar-mode-variable)) 0)
              ((not show) 0)
              ((eq? show #t) 1)
              ((and (number? show) (>= show 0))
               (if (> (length ((*tab-bar-tabs-function*) frame)) show) 1 0))
              (else 0))))

    (define (tab-bar--update-tab-bar-lines . args)
      ;; "Update the `tab-bar-lines' frame parameter in FRAMES. If the
      ;; optional parameter FRAMES is omitted, update only the currently
      ;; selected frame. If it is t, update all frames as well as the
      ;; default for new frames."
      ;;--------------------------------------------------------------
      (let* ((frames (if (pair? args) (car args) #f))
             (frame-list (cond ((not frames) (list (selected-frame)))
                               ((eq? frames #t) (frame-list))
                               (else frames))))
        (for-each
         (lambda (frame)
           (unless (or (frame-parameter frame 'tab-bar-lines-keep-state)
                       (and (eq? (*tab-bar-auto-width*) 'grow-only)
                            (> (or (frame-parameter frame 'tab-bar-lines) 0)
                               1)))
             (let ((old (or (frame-parameter frame 'tab-bar-lines) 0))
                   (new (tab-bar--tab-bar-lines-for-frame frame)))
               (set-frame-parameter frame 'tab-bar-lines new)
               ;; **The windows move when the bar appears or goes.**
               ;; Emacs reaches the same place through
               ;; `adjust_frame_size`, which the parameter's handler
               ;; calls; here the frame's own resize walk is asked for
               ;; the size it already has, and its `frame-top-margin`
               ;; read is what re-seats the text area under the bar.
               (when (not (eqv? old new))
                 (resize-frame-windows! frame (frame-height frame)
                                        (frame-width frame)
                                        (frame-height frame)
                                        (frame-width frame))))))
         frame-list)
        ;; "Update `default-frame-alist'"
        (when (eq? frames #t)
          (let ((rest (assq-delete-all
                       'tab-bar-lines (or (*default-frame-alist*) '()))))
            (*default-frame-alist*
             (cons (cons 'tab-bar-lines
                         (if (and (tab-bar-mode-variable)
                                  (eq? (*tab-bar-show*) #t))
                             1 0))
                   rest))))))

    (define (toggle-frame-tab-bar . args)
      ;; "Toggle tab bar of the selected frame."
      ;;--------------------------------------------------------------
      (let ((frame (or (and (pair? args) (car args)) (selected-frame))))
        (set-frame-parameter
         frame 'tab-bar-lines
         (if (> (or (frame-parameter frame 'tab-bar-lines) 0) 0) 0 1))
        (set-frame-parameter
         frame 'tab-bar-lines-keep-state
         (not (frame-parameter frame 'tab-bar-lines-keep-state)))))

    ;;--------------------------------------------------------------
    ;; The tab's name - `tab-bar-tab-name-*`
    ;;--------------------------------------------------------------

    (define (tab-bar-tab-name-current)
      ;; "Generate tab name from the buffer of the selected window."
      ;; `minibuffer-selected-window` is this tree's
      ;; `window-minibuffer-p` question: with no minibuffer window, a
      ;; prompt's read leaves the window as it was, so the selected
      ;; window is the answer.
      ;;--------------------------------------------------------------
      (buffer-name (window-buffer (selected-window))))

    (define (tab-bar-tab-name-current-with-count)
      ;; "Generate tab name from the buffer of the selected window. Also
      ;; add the number of windows in the window configuration."
      ;;--------------------------------------------------------------
      (let ((count (length (window-list (selected-frame) 'nomini)))
            (name (tab-bar-tab-name-current)))
        (if (> count 1)
            (string-append name " (" (number->string count) ")")
            name)))

    (define (tab-bar-tab-name-all)
      ;; "Generate tab name from buffers of all windows."
      ;;--------------------------------------------------------------
      (let loop ((wins (window-list (selected-frame) 'nomini)) (acc '()))
        (cond ((null? wins) (string-join (reverse acc) ", "))
              (else
               (let ((name (buffer-name (window-buffer (car wins)))))
                 (if (member name acc)
                     (loop (cdr wins) acc)
                     (loop (cdr wins) (cons name acc))))))))

    (define (string-join lst sep)
      ;; `mapconcat` for strings - `(scheme base)` has no `string-join`
      ;; and this is the one place the file needs one.
      ;;--------------------------------------------------------------
      (if (null? lst)
          ""
          (let loop ((rest (cdr lst)) (acc (car lst)))
            (if (null? rest)
                acc
                (loop (cdr rest) (string-append acc sep (car rest)))))))

    (define (tab-bar-tab-name-truncated)
      ;; "Generate tab name from the buffer of the selected window.
      ;; Truncate it to the length specified by
      ;; `tab-bar-tab-name-truncated-max'."
      ;;--------------------------------------------------------------
      (let ((tab-name (tab-bar-tab-name-current))
            (max (*tab-bar-tab-name-truncated-max*)))
        (if (< (string-length tab-name) max)
            tab-name
            (propertize (truncate-string-to-width
                         tab-name max #f #f
                         (if (*tab-bar-tab-name-ellipsis*)
                             (truncate-string-ellipsis)
                             ""))
                        'help-echo tab-name))))

    (define-custom *tab-bar-tab-name-function* tab-bar-tab-name-current
      "Function to get a tab name.
Function gets no arguments."
      :type '(choice (const :tag "Selected window buffer"
                            tab-bar-tab-name-current)
                     (const :tag "Selected window buffer with window count"
                            tab-bar-tab-name-current-with-count)
                     (const :tag "Truncated buffer name"
                            tab-bar-tab-name-truncated)
                     (const :tag "All window buffers" tab-bar-tab-name-all)
                     (function :tag "Function"))
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-tab-name-truncated-max* 20
      "Maximum length of the tab name from the current buffer."
      :type 'integer
      :group 'tab-bar)

    (define *tab-bar-tab-name-ellipsis* (make-parameter #t))
    ;; ^ `tab-bar-tab-name-ellipsis` - `#t` or a string, `let`-bound by
    ;; nobody, but a parameter for the tree's rule that a bare `set!` of
    ;; a plain variable from an init file would not be seen by a compiled
    ;; reader. It is read with `(if ...)` below.

    ;;--------------------------------------------------------------
    ;; The format of one tab - `tab-bar-tab-name-format-*`
    ;;--------------------------------------------------------------

    (define (tab-bar-tab-name-format-truncated name tab i)
      ;; "Truncate the tab name."
      ;;--------------------------------------------------------------
      (let ((max (*tab-bar-tab-name-truncated-max*)))
        (if (< (string-length name) max)
            name
            (truncate-string-to-width
             name max #f #f (truncate-string-ellipsis)))))

    (define (tab-bar-tab-name-format-hints name tab i)
      ;; "Show absolute numbers on tabs in the tab bar before the tab
      ;; name."
      ;;--------------------------------------------------------------
      (if (*tab-bar-tab-hints*)
          (string-append (number->string i) " " name)
          name))

    (define (tab-bar-tab-name-format-close-button name tab i)
      ;; "Show the tab close button."
      ;;--------------------------------------------------------------
      (if (and (*tab-bar-close-button-show*)
               (not (eq? (*tab-bar-close-button-show*)
                         (if (eq? (car tab) 'current-tab)
                             'non-selected
                             'selected)))
               tab-bar-close-button)
          (string-append name tab-bar-close-button)
          name))

    (define (tab-bar-tab-face-default tab)
      ;; "Function to define a tab face."
      ;;--------------------------------------------------------------
      (if (eq? (car tab) 'current-tab) 'tab-bar-tab 'tab-bar-tab-inactive))

    (define (tab-bar-tab-name-format-face name tab i)
      ;; "Apply the face to the tab name."
      ;;--------------------------------------------------------------
      (add-face-text-property 0 (string-length name)
                              ((*tab-bar-tab-face-function*) tab) #t name)
      name)

    (define (tab-bar-tab-name-format-mouse-face name tab i)
      ;; "Apply the `mouse-face' `tab-bar-tab-highlight' to the tab name."
      ;;--------------------------------------------------------------
      (propertize name 'mouse-face 'tab-bar-tab-highlight))

    (define (tab-bar-tab-name-format-default tab i)
      ;; "Run `tab-bar-tab-name-format-functions` over the name."
      ;; `run-hook-wrapped` stops when a function returns non-nil and
      ;; threads NAME through - here, `set!` and continue.
      ;;--------------------------------------------------------------
      (let ((name (substring (tab-bar--alist-get 'name tab) 0)))
        (for-each (lambda (fun)
                    (set! name (fun name tab i)))
                  (*tab-bar-tab-format-functions*))
        name))

    (define-custom *tab-bar-tab-format-functions*
      (list tab-bar-tab-name-format-hints
            tab-bar-tab-name-format-close-button
            tab-bar-tab-name-format-face
            tab-bar-tab-name-format-mouse-face)
      "Functions called to modify the tab name.
Each function is called with three arguments: the name returned
by the previously called modifier, the tab and its number."
      :type '(repeat function)
      :group 'tab-bar)

    (define-custom *tab-bar-tab-name-format-function*
      tab-bar-tab-name-format-default
      "Function to format a tab name.
Function gets two arguments, the tab and its number."
      :type 'function
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define-custom *tab-bar-tab-face-function* tab-bar-tab-face-default
      "Function to define a tab face."
      :type 'function
      :group 'tab-bar)

    ;;--------------------------------------------------------------
    ;; `tab-bar-format` and the items it makes
    ;;--------------------------------------------------------------

    (define (tab-bar--format-tab tab i)
      ;; "Format TAB using its index I and return the result as a
      ;; keymap."
      ;;
      ;; The C's `(intern (format "sep-%i" i))` and `(intern (format
      ;; "tab-%i" i))` name the items the click machinery looks up.
      ;;--------------------------------------------------------------
      (append
       (list (list (string->symbol (string-append "sep-" (number->string i)))
                   'menu-item (tab-bar-separator) 'ignore))
       (if (eq? (car tab) 'current-tab)
           (list (list 'current-tab
                       'menu-item
                       ((*tab-bar-tab-name-format-function*) tab i)
                       'ignore
                       ':help ((*tab-bar-format-tab-help-text-function*) tab i)))
           (list (list (string->symbol (string-append "tab-" (number->string i)))
                       'menu-item
                       ((*tab-bar-tab-name-format-function*) tab i)
                       (tab-bar--alist-get 'binding tab)
                       ':help ((*tab-bar-format-tab-help-text-function*) tab i))))
       (let ((close (tab-bar--alist-get 'close-binding tab)))
         (if close
             (list (list (if (eq? (car tab) 'current-tab)
                             'C-current-tab
                             (string->symbol (string-append "C-tab-"
                                                            (number->string i))))
                         'menu-item "" close))
             '()))))

    (define (tab-bar-format-tab-help-text-default tab i)
      (tab-bar--alist-get 'name tab))

    (define-custom *tab-bar-format-tab-help-text-function*
      tab-bar-format-tab-help-text-default
      "Function to produce help text for tabs displayed in the tab bar."
      :type 'function
      :group 'tab-bar)

    (define (tab-bar-format-tabs)
      ;; "Produce all the tabs for the tab bar."
      ;;--------------------------------------------------------------
      (let ((i 0))
        (let loop ((rest ((*tab-bar-tabs-function*))) (acc '()))
          (if (null? rest)
              acc
              (begin
                (set! i (+ i 1))
                (loop (cdr rest)
                      (append acc (tab-bar--format-tab (car rest) i))))))))

    (define (tab-bar-format-history)
      ;; "Produce back and forward buttons for the tab bar. These buttons
      ;; will be shown when `tab-bar-history-mode' is enabled." Not
      ;; carried, so nothing is produced - which is what the C produces
      ;; with the mode off.
      ;;--------------------------------------------------------------
      '())

    (define (tab-bar-format-add-tab)
      ;; "Button to add a new tab."
      ;;--------------------------------------------------------------
      (when (and (*tab-bar-new-button-show*) tab-bar-new-button)
        (list (list 'add-tab 'menu-item tab-bar-new-button 'tab-bar-new-tab
                    ':help "New tab"))))

    (define (tab-bar-format-list format-list)
      ;; "Return a list of items formatted from `format-list'." The C's
      ;; `align-right` arm is not carried (it needs a `display` space
      ;; specification), so a string a function returns becomes an
      ;; `str-N` item and nothing else is special-cased.
      ;;--------------------------------------------------------------
      (let ((i 0))
        (let loop ((rest format-list) (acc '()))
          (if (null? rest)
              acc
              (let ((format (car rest)))
                (set! i (+ i 1))
                (cond
                 ((eq? format 'tab-bar-format-align-right)
                  ;; named in the header: laid out as an empty item
                  (loop (cdr rest) acc))
                 ((procedure? format)
                  (let ((ret (format)))
                    (cond ((string? ret)
                           (loop (cdr rest)
                                 (append acc
                                         (list (list (string->symbol
                                                      (string-append
                                                       "str-" (number->string i)))
                                                     'menu-item ret 'ignore)))))
                          ((pair? ret) (loop (cdr rest) (append acc ret)))
                          (else (loop (cdr rest) acc)))))
                 (else (loop (cdr rest) acc))))))))

    (define (tab-bar-make-keymap . args)
      ;; "Generate an actual keymap from `tab-bar-map'. Its main job is
      ;; to show tabs in the tab bar and to bind mouse events to the
      ;; commands." The C's optional `_ignore` is the `:filter` call's
      ;; argument and is not used; not a command - nothing invokes it.
      ;;--------------------------------------------------------------
      (tab-bar-make-keymap-1))

    (define (tab-bar-make-keymap-1)
      ;; "Generate an actual keymap from `tab-bar-map', without caching."
      ;; `append` of a keymap and an alist is the C's `(append tab-bar-map
      ;; items)`: a keymap here is a record whose bindings are alist
      ;; entries too, so the items are defined into a copy instead.
      ;;--------------------------------------------------------------
      (let ((map (make-sparse-keymap))
            (items (tab-bar-format-list (*tab-bar-format*))))
        (map-keymap (lambda (key binding)
                      (define-key map (vector key) binding))
                    tab-bar-map)
        ;; **`tab-bar-auto-width` is not carried** - the header says why.
        ;; **An item IS a keymap alist entry**: `(current-tab menu-item
        ;; "name" ignore ...)` means key `current-tab`, binding
        ;; `(menu-item "name" ignore ...)` - the car and the cdr, not the
        ;; whole list. Binding the whole list makes `parse-menu-item` read
        ;; the *key* as the symbol `menu-item`, and the bar comes out
        ;; empty.
        ;; **Back to front**: `define-key` prepends, and the bar is drawn
        ;; in the keymap's own order - the same rule the Buffers menu
        ;; lives by (`menu-bar.scm`).
        (for-each
         (lambda (item)
           (when (and (pair? item) (pair? (cdr item)))
             (define-key map (vector (car item)) (cdr item))))
         (reverse items))
        ;; ...and the same map is what `[tab-bar]` is bound to, so that
        ;; `tab-bar-items` (`keyboard.c`'s walk) finds the items.
        (define-key *default-keymap* (vector 'tab-bar) map)
        map))

    (define-custom *tab-bar-format*
      (list tab-bar-format-history tab-bar-format-tabs
            tab-bar-separator tab-bar-format-add-tab)
      "Template for displaying tab bar items.
Every item in the list is a function that returns a string, or a
list of menu-item elements, or nil."
      :type 'hook
      :initialize custom-initialize-default
      :group 'tab-bar)

    ;; The C's default `tab-bar-format` is the list of *symbols* the
    ;; functions are named by; here a hook holds procedures, so the
    ;; `:options` the C lists become this list of the ones defined.

    ;;--------------------------------------------------------------
    ;; The commands
    ;;--------------------------------------------------------------

    (define (tab-bar-select-tab-internal tab-number)
      ;; The body of `tab-bar-select-tab`, split out because
      ;; `tab-bar-new-tab` and `tab-bar-move-tab-to` select tabs too and
      ;; the interactive spec's numeric-key translation belongs to the
      ;; command only.
      ;;--------------------------------------------------------------
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (from-index (tab-bar--current-tab-index tabs))
             (to-number (cond ((< tab-number 0)
                               (+ (length tabs) (1+ tab-number)))
                              ((= tab-number 0) (+ from-index 1))
                              (else tab-number)))
             (to-index (- (max 1 (min to-number (length tabs))) 1)))
        (unless (eq? from-index to-index)
          (let* ((from-tab (tab-bar--tab))
                 (to-tab (list-ref tabs to-index))
                 (wc (tab-bar--alist-get 'wc to-tab))
                 (ws (tab-bar--alist-get 'ws to-tab)))
            (parameterize ((*window-restore-killed-buffer-windows*
                            (or (*tab-bar-select-restore-windows*)
                                (*window-restore-killed-buffer-windows*))))
              (cond
               ;; "During the same session, use window-configuration to
               ;; switch tabs".
               ((and (window-configuration-p wc)
                     (eq? (window-configuration-frame wc) (selected-frame)))
                (let ((wc-point (tab-bar--alist-get 'wc-point to-tab)))
                  (set-window-configuration wc #f #t)
                  ;; "set-window-configuration does not restore the value
                  ;; of point in the current buffer, so restore it
                  ;; separately."
                  (when (and wc-point (markerp wc-point)
                             (marker-buffer wc-point))
                    (goto-char (marker-position wc-point)))
                  (set-frame-parameter #f 'buffer-list
                                       (seq-filter buffer-live-p
                                                   (tab-bar--alist-get 'wc-bl to-tab)))
                  (set-frame-parameter #f 'buried-buffer-list
                                       (seq-filter buffer-live-p
                                                   (tab-bar--alist-get
                                                    'wc-bbl to-tab)))))
               ;; `ws` is nil for every tab this build makes; a tab from
               ;; a saved session would take this branch, which the
               ;; header names as not carried.
               (ws #f)))
            (let ((tabs ((*tab-bar-tabs-function*))))
              (when from-index
                (set-car! (list-tail tabs from-index) from-tab))
              (if (list-tail-or-empty tabs to-index)
                  (set-car! (list-tail tabs to-index)
                            (tab-bar--current-tab-make
                             (list-ref tabs to-index)))
                  #f))
            (unless (tab-bar-mode-variable)
              (message "Selected tab '%s'" (tab-bar--alist-get 'name to-tab)))
            (run-hook-with-args (*tab-bar-tab-post-select-functions*)
                                from-tab to-tab)))
        (force-mode-line-update)))

    (define (list-tail-or-empty list i)
      ;; `(nth i list)` as a *pair*, which is what `set-car!` needs.
      (if (< i (length list)) (list-tail list i) #f))

    (define-command (tab-bar-select-tab tab-number)
      "Switch to the tab by its absolute position TAB-NUMBER in the tab bar.
When this command is bound to a numeric key, calling it without an
argument will translate its bound numeric key to the numeric argument.
TAB-NUMBER counts from 1.
Negative TAB-NUMBER counts tabs from the end of the tab bar."
      (interactive (list (if (integer? (current-prefix-arg))
                             (current-prefix-arg)
                             #f)))
      (let ((number (or tab-number
                        (let ((event (*last-read-event*)))
                          (if (and (integer? event) (>= event (char->integer #\1))
                                   (<= event (char->integer #\9)))
                              (- event (char->integer #\0))
                              0)))))
        (tab-bar-select-tab-internal number)))

    (define-command (tab-bar-switch-to-next-tab arg)
      "Switch to ARGth next tab."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let* ((arg (if (integer? arg) arg 1))
             (tabs ((*tab-bar-tabs-function*)))
             (from-index (or (tab-bar--current-tab-index tabs) 0))
             (to-index (modulo (+ from-index arg) (length tabs))))
        (tab-bar-select-tab-internal (1+ to-index))))

    (define-command (tab-bar-switch-to-prev-tab arg)
      "Switch to ARGth previous tab."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (tab-bar-switch-to-next-tab (- (if (integer? arg) arg 1))))

    (define-command (tab-bar-switch-to-last-tab arg)
      "Switch to the last tab or ARGth tab from the end of the tab bar."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (tab-bar-select-tab-internal
       (- (length ((*tab-bar-tabs-function*)))
          (1- (abs (or arg 1))))))

    (define-command (tab-bar-switch-to-recent-tab arg)
      "Switch to ARGth most recently visited tab."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let ((tab-index (tab-bar--tab-index-recent (if (integer? arg) arg 1))))
        (if tab-index
            (tab-bar-select-tab-internal (1+ tab-index))
            (message "No more recent tabs"))))

    (define-command (tab-bar-new-tab-to tab-number)
      "Add a new tab at the absolute position TAB-NUMBER.
TAB-NUMBER counts from 1.  Negative TAB-NUMBER counts tabs from
the end of the tab bar, and -1 means the new tab will become the
last one."
      (interactive (list (current-prefix-arg)))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (from-index (tab-bar--current-tab-index tabs))
             (from-tab (tab-bar--tab)))
        (when (*tab-bar-new-tab-choice*)
          (let ((choice (*tab-bar-new-tab-choice*)))
            (cond
             ((eq? choice 'clone) #f)
             ((string? choice)
              (let ((buffer (or (get-buffer choice) #f)))
                (when (and buffer (buffer-live-p buffer))
                  (switch-to-buffer buffer))))
             ((procedure? choice)
              (let ((buffer (choice)))
                (when (and buffer (buffer-live-p buffer))
                  (switch-to-buffer buffer))))
             (else
              ;; "Create a new window to get rid of old window parameters
              ;; (e.g. prev/next buffers) of old window."
              (delete-other-windows (selected-window))
              (split-window (selected-window) #f #t)
              (delete-window (selected-window))))))
        (when from-index
          (let ((tabs ((*tab-bar-tabs-function*))))
            (set-car! (list-tail tabs from-index) from-tab)))
        (let* ((to-tab (tab-bar--current-tab-make
                        (and (eq? (*tab-bar-new-tab-group*) #t)
                             (list (cons 'group
                                         (tab-bar--alist-get 'group from-tab))))))
               (to-number (if tab-number (uarg->integer 1 tab-number) #f))
               (to-index (or (if to-number
                                 (if (< to-number 0)
                                     (+ (length tabs) (1+ to-number))
                                     (- to-number 1))
                                 (let ((where (*tab-bar-new-tab-to*)))
                                   (cond ((eq? where 'leftmost) 0)
                                         ((eq? where 'rightmost) (length tabs))
                                         ((eq? where 'left) (or from-index 1))
                                         ((eq? where 'right) (1+ (or from-index 0)))
                                         ((procedure? where) (where))
                                         (else #f))))
                           #f))
               (to-index (max 0 (min (or to-index 0) (length tabs))))
               (tabs (tab-bar--insert-at ((*tab-bar-tabs-function*))
                                         to-index to-tab)))
          (tab-bar-tabs-set tabs)
          (when (eq? to-index 0)
            (tab-bar-tabs-set tabs))
          (run-hook-with-args (*tab-bar-tab-post-open-functions*)
                              (list-ref tabs to-index)))
        (when (*tab-bar-show*)
          (if (not (tab-bar-mode-variable))
              (tab-bar-mode 1)
              (tab-bar--update-tab-bar-lines)))
        (force-mode-line-update)
        (unless (tab-bar-mode-variable)
          (message "Added new tab at %s" (*tab-bar-new-tab-to*)))))

    (define-command (tab-bar-new-tab arg from-number)
      "Create a new tab ARG positions to the right.
If a negative ARG, create a new tab ARG positions to the left."
      (interactive (list (current-prefix-arg) #f))
      (when from-number
        (tab-bar-select-tab-internal from-number))
      (if arg
          (let* ((tabs ((*tab-bar-tabs-function*)))
                 (from-index (or (tab-bar--current-tab-index tabs) 0))
                 (to-index (+ from-index (uarg->integer 1 arg))))
            (tab-bar-new-tab-to (1+ to-index)))
          (tab-bar-new-tab-to #f)))

    (define-command (tab-bar-close-tab tab-number to-number)
      "Close the tab specified by its absolute position TAB-NUMBER.
If no TAB-NUMBER is specified, then close the current tab and switch
to the tab specified by `tab-bar-close-tab-select'."
      (interactive (list (current-prefix-arg) #f))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (current-index (tab-bar--current-tab-index tabs))
             (close-index (if (integer? tab-number) (1- tab-number)
                              current-index))
             (last-tab-p (= 1 (length tabs)))
             (prevent-close (run-hook-with-args-until-success
                             (*tab-bar-tab-prevent-close-functions*)
                             (list-ref tabs close-index)
                             last-tab-p)))
        (unless prevent-close
          (run-hook-with-args (*tab-bar-tab-pre-close-functions*)
                              (list-ref tabs close-index)
                              last-tab-p)
          (if last-tab-p
              (let ((choice (*tab-bar-close-last-tab-choice*)))
                (cond ((not choice)
                       (error "Attempt to delete the sole tab in a frame"))
                      ((eq? choice 'delete-frame)
                       (delete-frame (selected-frame)))
                      ((eq? choice 'tab-bar-mode-disable)
                       (tab-bar-mode -1))
                      ((procedure? choice)
                       (choice (tab-bar--tab)))))
              (begin
              ;; "More than one tab still open"
              (when (eq? current-index close-index)
                ;; "Select another tab before deleting the current tab"
                (let* ((choice (*tab-bar-close-tab-select*))
                       (to-index (or (if to-number (- to-number 1) #f)
                                     (cond ((eq? choice 'left)
                                            (- (if (< current-index 1) 2
                                                   current-index) 1))
                                           ((eq? choice 'right)
                                            (if (> (length tabs)
                                                   (1+ current-index))
                                                (1+ current-index)
                                                (1- current-index)))
                                           ((eq? choice 'recent)
                                            (tab-bar--tab-index-recent 1 tabs))
                                           (else #f)))))
                  (set! to-index (max 0 (min (or to-index 0)
                                             (1- (length tabs)))))
                  (tab-bar-select-tab-internal (1+ to-index))
                  ;; "Re-read tabs after selecting another tab"
                  (set! tabs ((*tab-bar-tabs-function*)))))
              (let ((close-tab (list-ref tabs close-index)))
                (set! tab-bar-closed-tabs
                      (cons (list (cons 'frame (selected-frame))
                                  (cons 'index close-index)
                                  (cons 'tab (if (eq? (car close-tab) 'current-tab)
                                                 (tab-bar--tab)
                                                 close-tab)))
                            tab-bar-closed-tabs))
                (tab-bar-tabs-set (delq close-tab tabs)))
              (tab-bar--update-tab-bar-lines)
              (force-mode-line-update)
              (unless (tab-bar-mode-variable)
                (message "Deleted tab and switched to %s"
                         (*tab-bar-close-tab-select*))))))))

    (define-command (tab-bar-close-other-tabs tab-number)
      "Close all tabs on the selected frame, except the tab TAB-NUMBER."
      (interactive (list #f))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (current-index (tab-bar--current-tab-index tabs))
             (keep-index (if (integer? tab-number)
                             (1- (max 1 (min tab-number (length tabs))))
                             current-index))
             (index 0))
        (when (list-tail-or-empty tabs keep-index)
          (unless (eq? keep-index current-index)
            (tab-bar-select-tab-internal (1+ keep-index))
            (set! tabs ((*tab-bar-tabs-function*))))
          (let loop ((rest tabs) (i 0))
            (unless (null? rest)
              (let ((tab (car rest)))
                (unless (or (eq? i keep-index)
                            (run-hook-with-args-until-success
                             (*tab-bar-tab-prevent-close-functions*) tab #f))
                  (set! tab-bar-closed-tabs
                        (cons (list (cons 'frame (selected-frame))
                                    (cons 'index i)
                                    (cons 'tab tab))
                              tab-bar-closed-tabs))
                  (run-hook-with-args (*tab-bar-tab-pre-close-functions*) tab #f)
                  (set! tabs (delq tab tabs))))
              (loop (cdr rest) (+ i 1))))
          (tab-bar-tabs-set tabs)
          (tab-bar--update-tab-bar-lines)
          (force-mode-line-update)
          (unless (tab-bar-mode-variable)
            (message "Deleted all other tabs")))))

    (define-command (tab-bar-undo-close-tab)
      "Restore the most recently closed tab."
      (interactive '())
      ;; "Pop out closed tabs that were on already deleted frames"
      (let loop ()
        (when (and (pair? tab-bar-closed-tabs)
                   (not (frame-live-p (tab-bar--alist-get
                                       'frame (car tab-bar-closed-tabs)))))
          (set! tab-bar-closed-tabs (cdr tab-bar-closed-tabs))
          (loop)))
      (if (pair? tab-bar-closed-tabs)
          (let* ((closed (car tab-bar-closed-tabs))
                 (frame (tab-bar--alist-get 'frame closed))
                 (index (tab-bar--alist-get 'index closed))
                 (tab (tab-bar--alist-get 'tab closed)))
            (set! tab-bar-closed-tabs (cdr tab-bar-closed-tabs))
            (unless (eq? frame (selected-frame))
              (select-frame frame))
            (let* ((tabs ((*tab-bar-tabs-function*)))
                   (index (max 0 (min index (length tabs))))
                   (tabs (tab-bar--insert-at tabs index tab)))
              (tab-bar-tabs-set tabs)
              (tab-bar-select-tab-internal (1+ index)))
            (run-hook-with-args (*tab-bar-post-undo-close-tab-functions*) tab)
            (tab-bar--update-tab-bar-lines))
          (message "No more closed tabs to undo")))

    (define-command (tab-bar-rename-tab name tab-number)
      "Give the tab specified by its absolute position TAB-NUMBER a new NAME.
If NAME is the empty string, then use the automatic name function."
      (interactive
       (list (read-from-minibuffer
              "New name for tab (leave blank for automatic naming): "
              #f #f #f #f
              (tab-bar--alist-get 'name
                                  (list-ref ((*tab-bar-tabs-function*))
                                            (tab-bar--current-tab-index))))
             (current-prefix-arg)))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (tab-index (if (integer? tab-number) (1- tab-number)
                            (tab-bar--current-tab-index tabs)))
             (tab (list-ref tabs tab-index))
             (explicit-name-entry (tab-bar--assq 'explicit-name tab))
             (name-entry (tab-bar--assq 'name tab)))
        (if (string=? name "")
            (begin
              (when explicit-name-entry (set-cdr! explicit-name-entry #f))
              (set-cdr! name-entry ((*tab-bar-tab-name-function*))))
            (begin
              (if explicit-name-entry
                  (set-cdr! explicit-name-entry #t)
                  (set-cdr! (last-pair tab) (list (cons 'explicit-name #t))))
              (set-cdr! name-entry name)))
        (force-mode-line-update)
        ;; Renaming the current tab re-makes it, so its `wc` follows.
        (when (eq? tab-index (tab-bar--current-tab-index tabs))
          (tab-bar-tabs-set tabs))))

    (define (last-pair lst)
      (if (pair? (cdr lst)) (last-pair (cdr lst)) lst))

    (define-command (tab-bar-move-tab-to to-number from-number)
      "Move tab from FROM-NUMBER position to new position at TO-NUMBER.
FROM-NUMBER defaults to the current tab number.
Negative TO-NUMBER counts tabs from the end of the tab bar."
      (interactive (list (current-prefix-arg) #f))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (from-number (or from-number
                              (1+ (tab-bar--current-tab-index tabs))))
             (from-tab (list-ref tabs (1- from-number)))
             (to-number (if to-number (uarg->integer 1 to-number) 1))
             (to-number (if (< to-number 0)
                            (+ (length tabs) (1+ to-number))
                            to-number))
             (to-index (max 0 (min (- to-number 1) (1- (length tabs)))))
             (tabs (delq from-tab (copy-list tabs))))
        (tab-bar-tabs-set (tab-bar--insert-at tabs to-index from-tab))
        (force-mode-line-update)))

    (define (tab-bar-move-tab arg)
      ;; "Move the current tab ARG positions to the right."
      ;;--------------------------------------------------------------
      (let* ((arg (if (integer? arg) arg 1))
             (tabs ((*tab-bar-tabs-function*)))
             (from-index (tab-bar--current-tab-index tabs))
             (to-index (max 0 (min (+ from-index arg) (1- (length tabs))))))
        (tab-bar-move-tab-to (1+ to-index) (+ from-index 1))))

    (define (copy-list lst)
      (if (pair? lst) (cons (car lst) (copy-list (cdr lst))) '()))

    ;;--------------------------------------------------------------
    ;; The mouse - `tab-bar--event-to-item` and its commands
    ;;--------------------------------------------------------------

    (define *last-nonmenu-event* (make-parameter #f))
    ;; ^ `last-nonmenu-event`, a `defvar` the mouse commands read. It is
    ;; bound here to `*last-read-event*`'s value by `tab-bar--event-to-item`
    ;; itself, which is as far as this tree carries it.

    (define (tab-bar--key-to-number key)
      ;; "Return the tab number represented by KEY."
      ;;--------------------------------------------------------------
      (cond ((not key) #t)
            ((eq? key 'current-tab) #f)
            ((and (symbol? key)
                  (let ((name (symbol->string key)))
                    (and (> (string-length name) 4)
                         (string=? (substring name 0 4) "tab-"))))
             (string->number (substring (symbol->string key) 4)))
            (else #t)))

    (define (tab-bar--event-to-item posn)
      ;; "Extract extra info from the mouse event at position POSN."
      ;;
      ;; **The text-mode emulation is the branch this build takes**, and
      ;; the GUI branch needs a posn that names a drawn string. The C's
      ;; own test is `(posn-window posn)`, which is the frame for a
      ;; console position - truthy - so its GUI arm answers nil there;
      ;; here the arm is taken only when there is a string, which is
      ;; what the arm actually reads.
      ;;--------------------------------------------------------------
      (let ((string (posn-string posn)))
        (if string
            (let* ((caption (car string))
                   (menu-item (and caption
                                   (get-text-property 0 'menu-item caption))))
              menu-item)
            ;; "Text-mode emulation of switching tabs on the tab bar."
            (let* ((x-pixels (car (posn-x-y posn)))
                   ;; The C's text-mode emulation compares the caption
                   ;; *length* against the pixel X, which is only right
                   ;; when a cell is a pixel. The column is the honest
                   ;; answer and the same one at that cell size.
                   (x-position (and (integer? x-pixels)
                                    (quotient x-pixels
                                              (column-width (current-display)))))
                   (keymap (tab-bar-make-keymap-1)))
              (when x-position
                ;; The C's `(catch 'done (map-keymap ...))`: a callback
                ;; cannot return early, so the answer escapes instead.
                (call-with-current-continuation
                 (lambda (done)
                   (let ((column 0))
                     (map-keymap
                      (lambda (key binding)
                        (when (and (pair? binding) (eq? (car binding) 'menu-item))
                          (let ((caption (list-ref binding 1)))
                            (if (> (+ column (string-length caption)) x-position)
                                (done (list key (list-ref binding 2)
                                            (get-text-property
                                             (- x-position column)
                                             'close-tab caption)))
                                (set! column (+ column (string-length caption)))))))
                      keymap)
                     #f))))))))


    (define-command (tab-bar-mouse-down-1 event)
      "Select the tab at mouse click, or add a new tab on the tab bar."
      (interactive "e")
      (let* ((item (tab-bar--event-to-item (event-start event)))
             (tab-number (tab-bar--key-to-number (if item (car item) #f))))
        (unless (or (and item (memq (car item)
                                    '(add-tab history-back history-forward global)))
                    (and item (list-ref-or-false item 2)))
          (if (and item (procedure? (list-ref-or-false item 1)))
              ((list-ref-or-false item 1))
              (unless (eq? tab-number #t)
                (tab-bar-select-tab-internal tab-number))))))

    (define (list-ref-or-false list i)
      (if (< i (length list)) (list-ref list i) #f))

    (define-command (tab-bar-mouse-1 event)
      "Close the tab whose \"x\" close button you click."
      (interactive "e")
      (let* ((item (tab-bar--event-to-item (event-start event)))
             (tab-number (tab-bar--key-to-number (if item (car item) #f))))
        (cond
         ((and item
               (memq (car item) '(add-tab history-back history-forward global))
               (not (eq? (list-ref-or-false item 1) 'tab-bar-mouse-1))
               (procedure? (list-ref-or-false item 1)))
          ((list-ref-or-false item 1)))
         ((and item (list-ref-or-false item 2) (not (eq? tab-number #t)))
          (tab-bar-close-tab tab-number #f)))))

    (define-command (tab-bar-mouse-close-tab event)
      "Close the tab you click on."
      (interactive "e")
      (let* ((item (tab-bar--event-to-item (event-start event)))
             (tab-number (tab-bar--key-to-number (if item (car item) #f))))
        (unless (eq? tab-number #t)
          (tab-bar-close-tab tab-number #f))))

    ;;--------------------------------------------------------------
    ;; The keymaps - after the commands, because a keymap holds them
    ;;--------------------------------------------------------------

    (define tab-bar-map (make-sparse-keymap))
    (define tab-bar-mode-map (make-sparse-keymap))

    (define-key tab-bar-map (kbd "<down-mouse-1>") tab-bar-mouse-down-1)
    (define-key tab-bar-map (kbd "<mouse-1>") tab-bar-mouse-1)
    (define-key tab-bar-map (kbd "<mouse-2>") tab-bar-mouse-close-tab)

    (define (tab-bar--define-keys)
      ;; "Install key bindings to switch between tabs if so configured."
      ;;
      ;; The modifier pairs of the C's numeric arm need `tab-bar-select-tab`
      ;; on a *digit* event with modifiers; nothing here defines one, so
      ;; that arm is not carried and the TAB pair is.
      ;;--------------------------------------------------------------
      (when (memq (*tab-bar-define-keys*) '(#t tab))
        (unless (keymap-lookup *default-keymap* (kbd "C-<tab>"))
          (define-key tab-bar-mode-map (kbd "C-<tab>") tab-bar-switch-to-next-tab))
        (unless (keymap-lookup *default-keymap* (kbd "C-S-<tab>"))
          (define-key tab-bar-mode-map (kbd "C-S-<tab>")
            tab-bar-switch-to-prev-tab))))

    (define (tab-bar--undefine-keys)
      ;; "Uninstall key bindings previously bound by
      ;; `tab-bar--define-keys'."
      ;;--------------------------------------------------------------
      (define-key tab-bar-mode-map (kbd "C-<tab>") #f)
      (define-key tab-bar-mode-map (kbd "C-S-<tab>") #f))

    ;; `C-x t` - `tab-prefix-map` in `bindings.el`, which `tab-bar.el`
    ;; fills at its end. Every binding is a whole key sequence here, as
    ;; the tab line's own keys are. The aliases are the C's `defalias`
    ;; lines (`:3180`): one command, two names.
    (define tab-next tab-bar-switch-to-next-tab)
    (define tab-previous tab-bar-switch-to-prev-tab)
    (define tab-last tab-bar-switch-to-last-tab)
    (define tab-recent tab-bar-switch-to-recent-tab)
    (define tab-close tab-bar-close-tab)
    (define tab-close-other tab-bar-close-other-tabs)
    (define tab-undo tab-bar-undo-close-tab)
    (define tab-select tab-bar-select-tab)
    (define tab-move tab-bar-move-tab)
    (define tab-move-to tab-bar-move-tab-to)
    (define tab-rename tab-bar-rename-tab)
    (define tab-new tab-bar-new-tab)
    (define tab-new-to tab-bar-new-tab-to)

    (define-key *default-keymap* (kbd "C-x t 2") tab-new)
    (define-key *default-keymap* (kbd "C-x t 0") tab-close)
    (define-key *default-keymap* (kbd "C-x t 1") tab-close-other)
    (define-key *default-keymap* (kbd "C-x t u") tab-undo)
    (define-key *default-keymap* (kbd "C-x t o") tab-next)
    (define-key *default-keymap* (kbd "C-x t O") tab-previous)
    (define-key *default-keymap* (kbd "C-x t m") tab-move)
    (define-key *default-keymap* (kbd "C-x t M") tab-move-to)
    (define-key *default-keymap* (kbd "C-x t r") tab-rename)

    ;; `global-set-key [tab-bar] ...` - the filter is applied by
    ;; `update-tab-bar`, not by the lookup; see this file's header.
    (define-key *default-keymap* (vector 'tab-bar) tab-bar-map)

    ;;--------------------------------------------------------------
    ;; The minor mode
    ;;--------------------------------------------------------------

    (define-minor-mode tab-bar-mode
      "Toggle the tab bar in all graphical frames (Tab Bar mode).

When this mode is enabled, Emacs displays a tab bar on top of each frame.
The tab bar is a row of tabs -- buttons that you can click
to switch the frame between different window configurations."
      :global #t
      (tab-bar--update-tab-bar-lines #t)
      (if (tab-bar-mode-variable)
          (tab-bar--define-keys)
          (tab-bar--undefine-keys)))

    ;;--------------------------------------------------------------
    ;; The seams and the names `tab-bar-tabs-function` finally gets
    ;;--------------------------------------------------------------

    (*tab-bar-tabs-function* tab-bar-tabs)
    (*tab-bar-keymap-function* tab-bar-make-keymap-1)

    ))
