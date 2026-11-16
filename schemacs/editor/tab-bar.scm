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
  ;; keyboard and mouse commands make, close and reorder them. A tab
  ;; also carries the frame's **window state** (`ws`, `window-state-get`,
  ;; `tab-bar.el:1690`), which is what restores a tab that has no live
  ;; configuration (`:1771`); live tabs keep the `wc`, which is the
  ;; branch Emacs takes for tabs of the same session - "During the same
  ;; session, use window-configuration to switch tabs, because
  ;; window-configurations are more reliable (they keep references to
  ;; live buffers) than window-states".
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
  ;;   * `frameset-*` persistence (`tab-bar--tab`'s `ws` source) and
  ;;     `tab-bar-select-restore-context` (`window-point-context-*`).
  ;;   * **tab groups** (`tab-bar-tab-group-*`, `tab-bar-format-tabs-groups`):
  ;;     the display they need is a group label with its own face and a
  ;;     `tab-bar-auto-width` measurement between groups.
  ;;   * **`tab-bar-history-mode`** is ported, with one departure: Emacs
  ;;     notices a window change through `f->change_stamp` and
  ;;     `window-configuration-change-hook`, which this tree has
  ;;     neither of, so a *fingerprint* of the frame's window tree is
  ;;     compared at the next command's `pre-command-hook` instead. The
  ;;     same four events move it and nothing else does; only the moment
  ;;     of the push differs, and the history a reader sees is the same.
  ;;   * **`tab-bar-auto-width`**: it lays tabs out with a `display`
  ;;     space specification measured in pixels, and this renderer draws
  ;;     character cells. The variable is carried so a user setting it
  ;;     sees no error; the bar simply is not stretched.
  ;;   * **touch input, tab drag and detach** (`tab-bar-mouse-move-tab`,
  ;;     `tab-bar-detach-tab`): no touch events, and detaching needs a
  ;;     new frame built *from* a window configuration, which
  ;;     `new-frame` does not take.
  ;;   * `tab-bar-menu-bar` (the menu bar is a row, not a popup).
  ;;   * **`tab-switcher-mode`'s `:suppress t`** and its `?` binding:
  ;;     a letter typed in the `*Tabs*` list inserts itself, and `?`
  ;;     does nothing, because `describe-mode` is not ported and a
  ;;     buffer's own map cannot suppress the self-insert fallback (the
  ;;     same gap `special-mode-map` names).
  ;;   * **The Gtk tab bar is a row of the drawing area, not a widget.**
  ;;     GNU Emacs's Gtk build builds one with `xg_create_frame_widgets`;
  ;;     this tree draws the same `display-tab-bar` row there, so the bar
  ;;     is one row of the frame's text area and the windows start below
  ;;     it (`frame-top-margin` counts `tab-bar-lines` on both kinds of
  ;;     display). It looks like the terminal's bar rather than like a
  ;;     toolkit's, and a click reaches it through the same
  ;;     `posn-at-x-y` path.

  (import
    (scheme base)
    (scheme char)
    (only (guile) sort make-hash-table hashq-set! hashq-ref
           get-internal-real-time internal-time-units-per-second
           exact->inexact 1+ 1-)
    (only (schemacs editor command) define-command uarg->integer
          current-prefix-arg)
    (only (schemacs editor subr) kbd)
    (only (schemacs editor custom) define-custom custom-initialize-default)
    (only (schemacs editor easy-mmode) define-minor-mode)
    (only (schemacs editor keymap) define-key make-sparse-keymap
          *default-keymap* keymap-type? keymap-lookup map-keymap)
    (only (schemacs editor subr) define-key-after)
    (only (schemacs editor frame)
          *current-frame* *frame-list* *default-frame-alist* delete-frame
          frame-parameter set-frame-parameter frame-list selected-frame
          select-frame frame-live-p frame-width
          frame-selected-window selected-window window-list window-buffer
          window-minibuffer-p window-parameter set-window-parameter
          window-internal? window-parent window-height window-top
          window-left window-width resize-frame-windows!
          frame-height frame-width frame-inner-width *pre-command-hook*)
    (only (schemacs editor window)
          current-window-configuration set-window-configuration
          window-configuration-p window-configuration-frame
          *window-restore-killed-buffer-windows*
          ;; A tab carries the frame's window state and is restored from
          ;; it - `window-state-get`/`window-state-put`.
          window-state-get window-state-put
          delete-other-windows split-window delete-window
          switch-to-buffer other-window quit-window
          ;; `tab-bar-split-tab` derives the combination it moves from
          ;; the frame's main window, which is `window.el`'s walk.
          window-main-window window-child-count window-live-p)
    ;; "Return window combination suitable for `split-frame`" -
    ;; `window-x.el`'s, the one function of that file the tab bar needs.
    (only (schemacs editor window-x) window-get-split-combination)
    (only (schemacs editor buffer)
          buffer-name buffer-live-p current-buffer get-buffer
          set-buffer-local-value! buffer-local-value
          *inhibit-read-only* erase-buffer set!buffer-read-only
          set-buffer-modified-p set-buffer with-current-buffer
          default-directory get-buffer-create)
    (only (schemacs editor subr) run-hook-with-args
          run-hook-with-args-until-success run-hooks add-hook remove-hook
          assq-delete-all delq posn-string posn-x-y event-start event-end
          posn-window posn-point)
    (only (schemacs editor editfns) goto-char point point-marker propertize
          message insert insert-char *inhibit-message* save-excursion
          delete-region point-min eobp forward-line)
    (only (schemacs editor cmds) beginning-of-line delete-char forward-char)
    (only (schemacs editor indentc) move-to-column)
    (only (schemacs editor search) re-search-forward)
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor files) kill-buffer)
    (only (schemacs editor marker) copy-marker markerp marker-buffer
          marker-position)
    (only (schemacs editor mule-util) truncate-string-to-width
          truncate-string-ellipsis)
    (only (schemacs editor character) string-width)
    (only (schemacs editor textprop) get-text-property add-face-text-property
          put-text-property next-single-property-change)
    (only (schemacs editor seq) seq-position seq-filter seq-remove seq-sort-by
          seq-take)
    (only (schemacs editor xdisp) force-mode-line-update format-mode-line
          *tab-bar-keymap-function* *global-mode-string*
          *activate-menubar-hook* *menu-bar-update-hook*)
    (only (schemacs editor faces) *window-system*)
    (only (schemacs editor menu-bar) popup-menu menu-bar-keymap)
    (only (schemacs editor minibuffer) read-from-minibuffer format-prompt
          minibufferp)
    (only (schemacs editor simple) *last-command* *this-command*)
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
   tab-bar-split-tab tab-bar-merge-tabs tab-bar-move-window-to-tab
   split-tab merge-tabs tab-window-detach
   ;; the name and face of one tab
   tab-bar-tab-name-current tab-bar-tab-name-current-with-count
   tab-bar-tab-name-all tab-bar-tab-name-truncated
   tab-bar-tab-name-format-truncated tab-bar-tab-name-format-hints
   tab-bar-tab-name-format-close-button tab-bar-tab-name-format-default
   tab-bar-tab-name-format-face tab-bar-tab-name-format-mouse-face
   tab-bar-tab-face-default
   ;; the format and the keymap it becomes
   tab-bar-format-list tab-bar-make-keymap tab-bar-make-keymap-1
   tab-bar-format-tabs tab-bar-format-tabs-groups tab-bar-format-add-tab
   tab-bar-format-history tab-bar-format-align-right tab-bar-format-global
   tab-bar-format-menu-bar tab-bar-menu-bar-button tab-bar-menu-bar
   ;; tab groups - `tab-bar.el:1084`
   tab-bar-change-tab-group tab-bar-close-group-tabs
   tab-bar-duplicate-tab tab-bar-move-tab-backward tab-bar-switch-to-tab
   tab-bar-close-tab-by-name tab-bar-rename-tab-by-name
   tab-bar-move-tab-to-group
   ;; the tab list - `tab-switcher`
   tab-switcher tab-switcher-noselect tab-switcher-mode
   tab-switcher-mode-map tab-switcher-column
   tab-switcher-select tab-switcher-delete tab-switcher-delete-backwards
   tab-switcher-execute tab-switcher-unmark tab-switcher-backup-unmark
   tab-switcher-next-line tab-switcher-prev-line
   tab-switcher-mouse-select tab-switcher-current-tab
   *tab-switcher-mode-hook*
   tab-bar-tab-group-default tab-bar-tab-group-format-default
   tab-bar-tab-group-face-default tab-bar--format-tab-group
   *tab-bar-tab-group-function* *tab-bar-tab-group-format-function*
   *tab-bar-tab-group-face-function* *tab-bar-show-inactive-group-tabs*
   *tab-bar-tab-post-change-group-functions*
   tab-bar--format-tab
   ;; the mouse
   tab-bar-mouse-down-1 tab-bar-mouse-1 tab-bar-mouse-close-tab
   tab-bar--event-to-item tab-bar--key-to-number
   ;; tab history - `tab-bar.el:2566`
   tab-bar-history-mode tab-bar-history-mode-variable
   tab-bar-history-back tab-bar-history-forward tab-bar-history-limit
   tab-bar--history-pre-change tab-bar--history-change
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
    (define tab-bar-closed-tabs (make-parameter '()))
    ;; ^ A parameter because a ported caller `let`-binds it -
    ;; `tab-switcher-select` binds it to nil around the close so the tab
    ;; does not go onto the undo list.

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
        (cond ((or (null? rest) (not (pair? rest))) #f)
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
      ;; **`ws` is the frame's window state** - `(window-state-get)`,
      ;; `tab-bar.el:1690`'s own line. A tab of this session is restored
      ;; from `wc` (`tab-bar-select-tab-internal` prefers a
      ;; window-configuration), and `ws` is what a tab written to a file
      ;; would carry; `window-state-put` can restore either.
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
               (cons 'ws (window-state-get))
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
      ;; will be shown when `tab-bar-history-mode' is enabled. You can
      ;; hide these buttons by customizing `tab-bar-format' and removing
      ;; `tab-bar-format-history' from it."
      ;;--------------------------------------------------------------
      ;; `(when ...)` answers the *unspecified* value when the test fails,
      ;; which is what this tree's `append` would splice into a format -
      ;; Emacs's nil is the empty list.
      (if (tab-bar-history-mode-variable)
          (list (list 'sep-history-back 'menu-item (tab-bar-separator) 'ignore)
              (list 'history-back 'menu-item tab-bar-back-button
                    tab-bar-history-back
                    ':help "Click to go back in tab history")
              (list 'sep-history-forward 'menu-item (tab-bar-separator) 'ignore)
                (list 'history-forward 'menu-item tab-bar-forward-button
                      tab-bar-history-forward
                      ':help "Click to go forward in tab history"))
          '()))

    (define tab-bar-menu-bar-button
      ;; "Button for the menu bar."
      (propertize "Menu" 'face 'tab-bar-tab-inactive))

    (define (tab-bar-format-menu-bar)
      ;; "Produce the Menu button for the tab bar that shows the menu
      ;; bar."
      ;;--------------------------------------------------------------
      (list (list 'menu-bar 'menu-item tab-bar-menu-bar-button
                  tab-bar-menu-bar
                  ':help "Menu bar")))

    (define (tab-bar-format-add-tab)
      ;; "Button to add a new tab."
      ;;--------------------------------------------------------------
      (when (and (*tab-bar-new-button-show*) tab-bar-new-button)
        (list (list 'add-tab 'menu-item tab-bar-new-button 'tab-bar-new-tab
                    ':help "New tab"))))

    (define (tab-bar-format-align-right . args)
      ;; "Align the rest of tab bar items to the right. The argument
      ;; `rest' is used for special handling of this item by
      ;; `tab-bar-format-list` that collects the rest of formatted items.
      ;; This prevents calling other non-idempotent items like
      ;; `tab-bar-format-global` twice."
      ;;
      ;; The C measures the rest in pixels and pads with a `display`
      ;; `(space :align-to ...)`; here the unit is a cell, so `hpos` is
      ;; `string-width` and the target is `frame-inner-width` (which is
      ;; columns in this tree - see `frame.scm`).
      ;;--------------------------------------------------------------
      (let* ((rest (if (pair? args)
                       (car args)
                       (tab-bar-format-list
                        (cdr (memq tab-bar-format-align-right
                                    (*tab-bar-format*))))))
             ;; `(string-append)` with no arguments is an error in this
             ;; Guile, where Elisp's `mapconcat` over nil answers "".
             (joined (if (null? rest)
                         ""
                         (apply string-append
                                (map (lambda (item) (or (list-ref item 2) ""))
                                     rest))))
             (hpos (string-width joined)))
        (list (list 'align-right 'menu-item
                    (propertize " " 'display
                                (list 'space ':align-to
                                      (- (frame-inner-width (*current-frame*))
                                         hpos)))
                    'ignore))))

    (define (tab-bar-format-global)
      ;; "Produce display of `global-mode-string' in the tab bar. When
      ;; `tab-bar-format-global' is added to `tab-bar-format' (possibly
      ;; appended after `tab-bar-format-align-right'), then modes that
      ;; display information on the mode line using `global-mode-string'
      ;; will display the same text on the tab bar instead."
      ;;--------------------------------------------------------------
      (map (lambda (string)
             (list 'global 'menu-item (format-mode-line string) 'ignore))
           (*global-mode-string*)))

    (define (tab-bar-format-list format-list)
      ;; "Return a list of items formatted from `format-list'." The item
      ;; `tab-bar-format-align-right` "has special formatting": it stays
      ;; in the result as a marker, everything after it is collected into
      ;; REST, and at the end the marker is replaced by
      ;; `(tab-bar-format-align-right REST)` - the C's `align-right-p`
      ;; and `rest` variables, exactly.
      ;;
      ;; A function's answer is normalised to a list: this tree's
      ;; formatters answer `'()` or a list of items, but a `when` in one
      ;; of them can answer the *unspecified* value, which `append` would
      ;; choke on.
      ;;--------------------------------------------------------------
      (let ((i 0) (align-right-p #f) (rest-items '()))
        (let* ((res (let loop ((rest format-list) (acc '()))
                      (if (null? rest)
                          acc
                          (let ((format (car rest)))
                            (set! i (+ i 1))
                            (cond
                             ((eq? format tab-bar-format-align-right)
                              (set! align-right-p #t)
                              (loop (cdr rest) (append acc (list format))))
                             ((procedure? format)
                              (let ((ret (format)))
                                (let ((ret (if (string? ret)
                                               (list (list (string->symbol
                                                            (string-append
                                                             "str-"
                                                             (number->string i)))
                                                           'menu-item ret 'ignore))
                                               (if (pair? ret) ret '()))))
                                  (when align-right-p
                                    (set! rest-items (append rest-items ret)))
                                  (loop (cdr rest) (append acc ret)))))
                             (else (loop (cdr rest) acc))))))))
          (if align-right-p
              (let loop ((rest res) (acc '()))
                (if (null? rest)
                    acc
                    (loop (cdr rest)
                          (if (eq? (car rest) tab-bar-format-align-right)
                              (append acc (tab-bar-format-align-right rest-items))
                              (append acc (list (car rest)))))))
              res))))

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
               ;; A tab restored from a window state - `tab-bar.el:1771`.
               ;; "`window-state-put' fails when called in the minibuffer"
               ;; is not carried: there is no minibuffer *window* to be
               ;; selected here (the echo area is an ordinary window whose
               ;; buffer is the prompt), so `window-state-put` always has
               ;; a usable window.
               (ws
                (window-state-put ws #f 'safe)
                (when tab-bar-history-mode-variable
                  (hashq-set! tab-bar-history-back (selected-frame) '())
                  (hashq-set! tab-bar-history-forward (selected-frame) '())))))
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
            ;; `tab-bar.el:2085`'s shape: `clone` first, then - for
            ;; every other choice - the old layout is cleared, and then
            ;; `window` re-puts a one-window state where the rest split a
            ;; fresh window. A string or a function is a *buffer* to
            ;; show, after that same clearing.
            (if (eq? choice 'clone)
                ;; "Create new unique windows with the same layout"
                (window-state-put (window-state-get))
                (begin
                  ;; "Remove window parameters that can cause problems
                  ;; with `delete-other-windows' and `split-window'."
                  (set-window-parameter (selected-window) 'window-atom #f)
                  (delete-other-windows (selected-window))
                  (if (eq? choice 'window)
                      ;; "Create new unique window from remaining window"
                      (begin
                        (set-window-parameter (selected-window) 'window-side #f)
                        (window-state-put (window-state-get)))
                      ;; "Create a new window to get rid of old window
                      ;; parameters (e.g. prev/next buffers) of old
                      ;; window."
                      (begin
                        (split-window (selected-window) #f #t)
                        (delete-window (selected-window))))))
            (let ((buffer (cond ((and (procedure? choice)
                                      (not (memq choice '(clone window))))
                                 (choice))
                                ((string? choice) (get-buffer choice))
                                (else #f))))
              (when (and buffer (buffer-live-p buffer))
                (switch-to-buffer buffer)))))
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
                (tab-bar-closed-tabs
                      (cons (list (cons 'frame (selected-frame))
                                  (cons 'index close-index)
                                  (cons 'tab (if (eq? (car close-tab) 'current-tab)
                                                 (tab-bar--tab)
                                                 close-tab)))
                            (tab-bar-closed-tabs)))
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
                  (tab-bar-closed-tabs
                        (cons (list (cons 'frame (selected-frame))
                                    (cons 'index i)
                                    (cons 'tab tab))
                              (tab-bar-closed-tabs)))
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
        (when (and (pair? (tab-bar-closed-tabs))
                   (not (frame-live-p (tab-bar--alist-get
                                       'frame (car (tab-bar-closed-tabs))))))
          (tab-bar-closed-tabs (cdr (tab-bar-closed-tabs)))
          (loop)))
      (if (pair? (tab-bar-closed-tabs))
          (let* ((closed (car (tab-bar-closed-tabs)))
                 (frame (tab-bar--alist-get 'frame closed))
                 (index (tab-bar--alist-get 'index closed))
                 (tab (tab-bar--alist-get 'tab closed)))
            (tab-bar-closed-tabs (cdr (tab-bar-closed-tabs)))
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

    (define-command (tab-bar-menu-bar event)
      "Pop up the same menu as displayed by the menu bar.
Used by `tab-bar-format-menu-bar'."
      (interactive "e")
      (let ((menu (make-sparse-keymap)))
        (run-hooks (*activate-menubar-hook*))
        (run-hooks (*menu-bar-update-hook*))
        (map-keymap (lambda (key binding)
                      (when (pair? binding)
                        (define-key-after menu (vector key) binding)))
                    (menu-bar-keymap))
        (popup-menu menu event #f #f)))

    (define-command (tab-bar-mouse-close-tab event)
      "Close the tab you click on."
      (interactive "e")
      (let* ((item (tab-bar--event-to-item (event-start event)))
             (tab-number (tab-bar--key-to-number (if item (car item) #f))))
        (unless (eq? tab-number #t)
          (tab-bar-close-tab tab-number #f))))

    ;;--------------------------------------------------------------
    ;; Tab groups - `tab-bar.el:1084`
    ;;--------------------------------------------------------------

    (define (tab-bar-tab-group-default tab)
      ;; "Function to get a tab group name."
      ;;--------------------------------------------------------------
      (tab-bar--alist-get 'group tab))

    (define-custom *tab-bar-tab-group-function* tab-bar-tab-group-default
      "Function to get a tab group name.
Function gets one argument: a tab."
      :type 'function
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define (tab-bar-tab-group-format-default tab i . rest)
      ;; "Function to format a tab group name. Function gets three
      ;; arguments, a tab with a group name, its number, and an optional
      ;; value that is non-nil when the tab is from the current group."
      ;;--------------------------------------------------------------
      (let ((current-p (and (pair? rest) (car rest))))
        (propertize
         (string-append
          (if (and (*tab-bar-tab-hints*)
                   (not current-p)
                   (not (*tab-bar-show-inactive-group-tabs*)))
              (string-append (number->string i) " ")
              "")
          (let ((group ((*tab-bar-tab-group-function*) tab)))
            (or group "")))
         'face (if current-p
                   'tab-bar-tab-group-current
                   'tab-bar-tab-group-inactive))))

    (define-custom *tab-bar-tab-group-format-function*
      tab-bar-tab-group-format-default
      "Function to format a tab group name.
Function gets three arguments, a tab with a group name, its number, and
an optional value that is non-nil when the tab is from the current group."
      :type 'function
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define (tab-bar-tab-group-face-default tab)
      ;; "Function to define a tab group face."
      ;;--------------------------------------------------------------
      (if (not (or (eq? (car tab) 'current-tab)
                   ((*tab-bar-tab-group-function*) tab)))
          'tab-bar-tab-ungrouped
          (tab-bar-tab-face-default tab)))

    (define-custom *tab-bar-tab-group-face-function*
      tab-bar-tab-group-face-default
      "Function to define a tab group face.
Function gets one argument: a tab."
      :type 'function
      :group 'tab-bar)

    (define (tab-bar--format-tab-group tab i . rest)
      ;; "Format TAB as a tab that represents a group of tabs. The
      ;; argument I is the tab index, and CURRENT-P is non-nil when the
      ;; tab is current. Return the result as a keymap."
      ;;
      ;; The non-current group's binding is `(tab-bar-select-tab I)` as a
      ;; closure - "Click to visit group".
      ;;--------------------------------------------------------------
      (let ((current-p (and (pair? rest) (car rest))))
        (append
         (list (list (string->symbol (string-append "sep-" (number->string i)))
                     'menu-item (tab-bar-separator) 'ignore))
         (list
          (list (string->symbol
                 (if current-p
                     "current-group"
                     (string-append "group-" (number->string i))))
                'menu-item
                (if current-p
                    ((*tab-bar-tab-group-format-function*) tab i current-p)
                    ((*tab-bar-tab-group-format-function*) tab i))
                (if current-p
                    'ignore
                    (or (tab-bar--alist-get 'binding tab)
                        ;; A closure: `(lambda () (interactive)
                        ;; (tab-bar-select-tab i))'.
                        (let ((n i))
                          (lambda () (tab-bar-select-tab-internal n)))))
                ':help "Click to visit group")))))

    (define-custom *tab-bar-show-inactive-group-tabs* #f
      "Show tabs even if they are in inactive groups."
      :type 'boolean
      :initialize custom-initialize-default
      :group 'tab-bar)

    (define (tab-bar-format-tabs-groups)
      ;; "Produce tabs for the tab bar grouped according to their
      ;; groups."
      ;;
      ;; The C's `mapcan` with a `prog1` is a loop that appends and
      ;; records the group it has just emitted.
      ;;--------------------------------------------------------------
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (current-group ((*tab-bar-tab-group-function*)
                             (tab-bar--current-tab-find tabs))))
        (let loop ((rest tabs) (i 0) (acc '()) (previous-group #f))
          (cond ((null? rest) acc)
                (else
                 (let* ((tab (car rest))
                        (tab-group ((*tab-bar-tab-group-function*) tab))
                        (i (+ i 1))
                        (out
                         (cond
                          ;; "Show current group tabs and ungrouped tabs"
                          ((or (equal? tab-group current-group) (not tab-group))
                           (append
                            ;; "Prepend current group name before first tab"
                            (if (and (not (equal? previous-group tab-group))
                                     tab-group)
                                (tab-bar--format-tab-group tab i #t)
                                '())
                            ;; "Override default tab faces to use group faces"
                            (parameterize ((*tab-bar-tab-face-function*
                                            (*tab-bar-tab-group-face-function*)))
                              (tab-bar--format-tab tab i))))
                          ;; "Show first tab of other groups with a group name"
                          ((not (equal? previous-group tab-group))
                           (append
                            (tab-bar--format-tab-group tab i)
                            (if (*tab-bar-show-inactive-group-tabs*)
                                (parameterize
                                    ((*tab-bar-tab-face-function*
                                      (*tab-bar-tab-group-face-function*)))
                                  (tab-bar--format-tab tab i))
                                '())))
                          ;; "Hide other group tabs"
                          (else
                           (if (*tab-bar-show-inactive-group-tabs*)
                               (parameterize
                                   ((*tab-bar-tab-face-function*
                                     (*tab-bar-tab-group-face-function*)))
                                 (tab-bar--format-tab tab i))
                               '())))))
                   (loop (cdr rest) i (append acc out) tab-group)))))))

    (define *tab-bar-tab-post-change-group-functions* (make-parameter '()))
    ;; ^ `tab-bar-tab-post-change-group-functions`, a `defvar` read as a
    ;; hook list.

    (define-command (tab-bar-change-tab-group group-name tab-number)
      "Add the tab specified by its absolute position TAB-NUMBER to GROUP-NAME.
If no TAB-NUMBER is specified, then set the GROUP-NAME for the current tab.
If GROUP-NAME is the empty string, then remove the tab from any group."
      (interactive
       (let* ((tabs ((*tab-bar-tabs-function*)))
              (tab-number (or (current-prefix-arg)
                              (1+ (tab-bar--current-tab-index tabs))))
              (group-name ((*tab-bar-tab-group-function*)
                           (list-ref tabs (1- tab-number)))))
         (list (read-from-minibuffer
                "Group name for tab (leave blank to remove group): "
                #f #f #f (or group-name ""))
               (current-prefix-arg))))
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (tab-index (if tab-number
                            (1- (max 0 (min tab-number (length tabs))))
                            (tab-bar--current-tab-index tabs)))
             (tab (list-ref tabs tab-index))
             (group (tab-bar--assq 'group tab))
             (group-new-name (and (> (string-length group-name) 0)
                                  group-name)))
        (if group
            (set-cdr! group group-new-name)
            (set-cdr! (last-pair tab) (list (cons 'group group-new-name))))
        (run-hook-with-args (*tab-bar-tab-post-change-group-functions*) tab)
        (force-mode-line-update)
        (unless (tab-bar-mode-variable)
          (message "Set tab group to '%s'" group-new-name))))

    (define-command (tab-bar-close-group-tabs group-name)
      "Close all tabs that belong to GROUP-NAME on the selected frame."
      (interactive
       (let* ((current ((*tab-bar-tab-group-function*)
                        (tab-bar--current-tab-find)))
              (names (map (lambda (tab) ((*tab-bar-tab-group-function*) tab))
                          ((*tab-bar-tabs-function*))))
              (names (delete-duplicates (cons current names))))
         (list (read-from-minibuffer "Close all tabs with group name: "
                                     #f #f #f (or current "")))))
      (let* ((close-group (and (> (string-length group-name) 0) group-name)))
        (parameterize
            ((*tab-bar-tab-prevent-close-functions*
              (cons (lambda (tab last-tab-p)
                      (not (equal? ((*tab-bar-tab-group-function*) tab)
                                   close-group)))
                    (*tab-bar-tab-prevent-close-functions*))))
          (tab-bar-close-other-tabs #f))
        (when (equal? ((*tab-bar-tab-group-function*)
                       (tab-bar--current-tab-find))
                      close-group)
          (tab-bar-close-tab #f #f))))

    (define (delete-duplicates lst)
      ;; `delete-dups`: one copy of each element, first occurrences kept.
      ;; `member` compares with `equal?`; the names are strings.
      (let loop ((rest lst) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((member (car rest) acc) (loop (cdr rest) acc))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    ;;--------------------------------------------------------------
    ;; The rest of the tab commands - `tab-bar.el:1849`-`:1910` and
    ;; `:2402`-`:2436`
    ;;--------------------------------------------------------------

    (define-command (tab-bar-duplicate-tab arg from-number)
      "Clone the current tab to ARG positions to the right.
ARG and FROM-NUMBER have the same meaning as in `tab-bar-new-tab'."
      (interactive (list (current-prefix-arg) #f))
      (parameterize ((*tab-bar-new-tab-choice* 'clone)
                     (*tab-bar-new-tab-group* #t))
        (tab-bar-new-tab arg from-number)))

    (define-command (tab-bar-move-tab-backward arg)
      "Move the current tab ARG positions to the left.
Like `tab-bar-move-tab', but moves in the opposite direction."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (tab-bar-move-tab (- (or arg 1))))

    (define-command (tab-bar-switch-to-tab name)
      "Switch to the tab by NAME.
Default values are tab names sorted by recency, so you can use
\\<minibuffer-local-map>\\[next-history-element]
to get the name of the most recently visited tab, the second
most recent, and so on.
When the tab with that NAME doesn't exist, create a new tab
and rename it to NAME."
      (interactive
       (let* ((recent-tabs (map (lambda (tab) (tab-bar--alist-get 'name tab))
                                (tab-bar--tabs-recent))))
         (list (read-from-minibuffer
                (format-prompt "Switch to tab by name" (car recent-tabs))
                #f #f #f (car recent-tabs)))))
      (let ((tab-index (tab-bar--tab-index-by-name name)))
        (if tab-index
            (tab-bar-select-tab-internal (1+ tab-index))
            (begin
              (tab-bar-new-tab-to #f)
              (tab-bar-rename-tab name #f)))))

    (define-command (tab-bar-close-tab-by-name name)
      "Close the tab given its NAME.
Interactively, prompt for NAME."
      (interactive
       (list (read-from-minibuffer
              "Close tab by name: " #f #f #f
              (tab-bar--alist-get 'name (tab-bar--current-tab-find)))))
      (tab-bar-close-tab (1+ (tab-bar--tab-index-by-name name)) #f))

    (define-command (tab-bar-rename-tab-by-name tab-name new-name)
      "Rename the tab named TAB-NAME to NEW-NAME.
If NEW-NAME is the empty string, then use the automatic name
function `tab-bar-tab-name-function'."
      (interactive
       (let ((tab-name (read-from-minibuffer
                        "Rename tab by name: " #f #f #f
                        (tab-bar--alist-get 'name (tab-bar--current-tab-find)))))
         (list tab-name
               (read-from-minibuffer
                "New name for tab (leave blank for automatic naming): "
                #f #f #f tab-name))))
      (tab-bar-rename-tab new-name (1+ (tab-bar--tab-index-by-name tab-name))))

    (define (tab-bar-move-tab-to-group . args)
      ;; "Relocate TAB (by default, the current tab) closer to its
      ;; group."
      ;;
      ;; The C's two `seq-position` calls are the group's first tab and
      ;; its length; the arithmetic after them is Emacs's.
      ;;--------------------------------------------------------------
      (let* ((tabs ((*tab-bar-tabs-function*)))
             (tab (or (and (pair? args) (car args))
                      (tab-bar--current-tab-find tabs)))
             (tab-index (tab-bar--tab-index tab))
             (group (tab-bar--alist-get 'group tab))
             (beg (seq-position tabs group
                                (lambda (tb gr)
                                  (and (not (eq? tb tab))
                                       (equal? (tab-bar--alist-get 'group tb)
                                               gr)))))
             (len (and beg
                       (seq-position (list-tail tabs beg) group
                                     (lambda (tb gr)
                                       (not (equal? (tab-bar--alist-get 'group tb)
                                                    gr))))))
             (pos (if beg
                      (cond
                       ;; "Don't move tab when it's already inside group
                       ;; bounds"
                       ((and len (>= tab-index beg) (<= tab-index (+ beg len)))
                        #f)
                       ;; "Move tab from the right to the group end"
                       ((and len (> tab-index (+ beg len))) (+ beg len 1))
                       ;; "Move tab from the left to the group beginning"
                       ((< tab-index beg) beg))
                      ;; "Move tab with a new group to the end"
                      -1)))
        (when pos
          (tab-bar-move-tab-to pos (1+ tab-index)))))

    ;; "List of functions to call after changing a tab group. ... By
    ;; default it enables the function `tab-bar-move-tab-to-group' that
    ;; moves the tab closer to its group." The C's value names the
    ;; function before it is defined; the parameter is set here, after.
    (*tab-bar-tab-post-change-group-functions*
     (list tab-bar-move-tab-to-group))

    ;;--------------------------------------------------------------
    ;; Tab history mode - `tab-bar.el:2566`
    ;;
    ;; **The one departure of this section is how a change is noticed.**
    ;; Emacs bumps `f->change_stamp` in `Fset_window_buffer`,
    ;; `Fdelete_window`, `Fsplit_window_internal` and
    ;; `Fset_window_configuration` (`window.c:3715`, `:5681`, `:5828`,
    ;; `:8082`) and `run_window_change_functions` runs
    ;; `window-configuration-change-hook` when the stamp moved or the
    ;; selected window or frame did. This tree has neither the stamp nor
    ;; that hook, so the same facts are captured as a *fingerprint* of
    ;; the frame's window tree - the selected window, and each window
    ;; with its buffer and rectangle - and compared at the next
    ;; command's `pre-command-hook`. The same four causes move it and
    ;; nothing else does; what differs is only *when* the push happens
    ;; (one command later), and the history a reader sees is the same.
    ;;--------------------------------------------------------------

    (define tab-bar-history-limit 10)
    ;; ^ "The number of history elements to keep." A `defvar` in Emacs,
    ;; not a defcustom, so a plain variable here too.

    (define tab-bar-history-omit #f)
    ;; ^ "When non-nil, omit window-configuration changes from the
    ;; current command." A plain `defvar`: read and `setq`-ed here only.
    (define tab-bar-history-back-table (make-hash-table))
    ;; ^ "History of back changes in every tab per frame."
    (define tab-bar-history-forward-table (make-hash-table))
    ;; ^ "History of forward changes in every tab per frame."
    (define tab-bar-history-old #f)
    ;; ^ "Window configuration before the current command."
    (define tab-bar-history-pre-command #f)
    ;; ^ "Command set to `this-command' by `pre-command-hook'."
    (define tab-bar-history-done-command #f)
    ;; ^ "Command handled by `window-configuration-change-hook'."
    (define tab-bar-history-fingerprint #f)
    ;; ^ This tree's stand-in for `f->change_stamp`, see the note above.

    (define (tab-bar--window-fingerprint frame)
      ;; What `FRAME_WINDOW_CHANGE` reports: the selected window, and the
      ;; window tree with each window's buffer and rectangle. A list of
      ;; records and numbers, compared by `tab-bar--same-fingerprint?` -
      ;; `equal?` would walk a window's frame and a frame's windows for
      ;; ever.
      ;;--------------------------------------------------------------
      (list (frame-selected-window frame)
            (map (lambda (w)
                   (list w (window-buffer w) (window-top w)
                         (window-height w) (window-left w) (window-width w)))
                 (window-list frame #t))))

    (define (tab-bar--same-fingerprint? a b)
      (define (same-row? x y)
        (and (eq? (list-ref x 0) (list-ref y 0))
             (eq? (list-ref x 1) (list-ref y 1))
             (equal? (cddr x) (cddr y))))
      (and (eq? (car a) (car b))
           (let loop ((x (cadr a)) (y (cadr b)))
             (cond ((and (null? x) (null? y)) #t)
                   ((or (null? x) (null? y)) #f)
                   ((not (same-row? (car x) (car y))) #f)
                   (else (loop (cdr x) (cdr y)))))))

    (define (tab-bar--minibuffer-depth-zero?)
      ;; `(zerop (minibuffer-depth))` - no prompt is being read. This
      ;; tree's answer is `minibufferp`, which is "a minibuffer buffer is
      ;; active".
      ;;--------------------------------------------------------------
      (not (minibufferp)))

    (define (tab-bar--history-change)
      ;; GNU Emacs's `tab-bar--history-change` (`tab-bar.el:2596`),
      ;; called from `window-configuration-change-hook` there and from
      ;; the pre-change below here.
      ;;--------------------------------------------------------------
      (when (and (not tab-bar-history-omit) tab-bar-history-old
                 ;; "Don't register changes performed by the same command
                 ;; repeated in sequence, such as incremental window
                 ;; resizing."
                 (not (eq? tab-bar-history-done-command
                           tab-bar-history-pre-command))
                 (tab-bar--minibuffer-depth-zero?)
                 (not (tab-bar--same-fingerprint?
                       tab-bar-history-fingerprint
                       (tab-bar--window-fingerprint (*current-frame*)))))
        (hashq-set! tab-bar-history-back-table (selected-frame)
                    (seq-take (cons tab-bar-history-old
                                    (or (hashq-ref tab-bar-history-back-table
                                                   (selected-frame))
                                        '()))
                              tab-bar-history-limit))
        (set! tab-bar-history-old #f))
      (set! tab-bar-history-done-command tab-bar-history-pre-command))

    (define (tab-bar--history-pre-change)
      ;; GNU Emacs's `tab-bar--history-pre-change` (`:2590`), plus the
      ;; `window-configuration-change-hook` call this tree has no hook
      ;; for - see this section's note.
      ;;--------------------------------------------------------------
      (tab-bar--history-change)
      ;; "Reset before the command could set it"
      (set! tab-bar-history-omit #f)
      (set! tab-bar-history-pre-command (*this-command*))
      (when (tab-bar--minibuffer-depth-zero?)
        (set! tab-bar-history-old
              (list (cons 'wc (current-window-configuration))
                    (cons 'wc-point (point-marker))))
        (set! tab-bar-history-fingerprint
              (tab-bar--window-fingerprint (*current-frame*)))))

    (define-command (tab-bar-history-back)
      "Restore a previous window configuration used in the current tab.
This navigates back in the history of window configurations."
      (interactive '())
      (set! tab-bar-history-omit #t)
      (let* ((history (let ((h (hashq-ref tab-bar-history-back-table
                                          (selected-frame))))
                        (hashq-set! tab-bar-history-back-table (selected-frame)
                                    (and (pair? h) (cdr h)))
                        (and (pair? h) (car h))))
             (wc (tab-bar--alist-get 'wc history))
             (wc-point (tab-bar--alist-get 'wc-point history)))
        (if (window-configuration-p wc)
            (begin
              (hashq-set! tab-bar-history-forward-table (selected-frame)
                          (cons tab-bar-history-old
                                (or (hashq-ref tab-bar-history-forward-table
                                               (selected-frame))
                                    '())))
              (set-window-configuration wc #f #t)
              (when (and (markerp wc-point) (marker-buffer wc-point))
                (goto-char (marker-position wc-point))))
            (message "No more tab back history"))))

    (define-command (tab-bar-history-forward)
      "Cancel restoration of the previous window configuration.
This navigates forward in the history of window configurations."
      (interactive '())
      (set! tab-bar-history-omit #t)
      (let* ((history (let ((h (hashq-ref tab-bar-history-forward-table
                                          (selected-frame))))
                        (hashq-set! tab-bar-history-forward-table (selected-frame)
                                    (and (pair? h) (cdr h)))
                        (and (pair? h) (car h))))
             (wc (tab-bar--alist-get 'wc history))
             (wc-point (tab-bar--alist-get 'wc-point history)))
        (if (window-configuration-p wc)
            (begin
              (hashq-set! tab-bar-history-back-table (selected-frame)
                          (cons tab-bar-history-old
                                (or (hashq-ref tab-bar-history-back-table
                                               (selected-frame))
                                    '())))
              (set-window-configuration wc #f #t)
              (when (and (markerp wc-point) (marker-buffer wc-point))
                (goto-char (marker-position wc-point))))
            (message "No more tab forward history"))))

    (define-key *default-keymap* (kbd "C-c <left>") tab-bar-history-back)
    (define-key *default-keymap* (kbd "C-c <right>") tab-bar-history-forward)

    (define-minor-mode tab-bar-history-mode
      "Toggle tab history mode for the tab bar.
Tab history mode remembers window configurations used in every tab,
and can restore them."
      :global #t
      (if tab-bar-history-mode-variable
          (begin
            (add-hook *pre-command-hook* tab-bar--history-pre-change)
            (force-mode-line-update))
          (remove-hook *pre-command-hook* tab-bar--history-pre-change)))

    ;;--------------------------------------------------------------
    ;; The tab list - `tab-switcher` (`tab-bar.el:2700`)
    ;;--------------------------------------------------------------

    (define tab-switcher-column 3)
    ;; ^ "`tab-switcher-column`" - a `defvar-local` in Emacs, and a plain
    ;; variable here: the buffer's own value is this one until the list
    ;; buffer sets it, which is the same answer while there is one list.

    (define tab-switcher-mode-map (make-sparse-keymap))

    (define (tab-switcher-current-tab error-if-non-existent-p)
      ;; "Return window configuration described by this line of the
      ;; list."
      ;;--------------------------------------------------------------
      (let* ((where (save-excursion
                      (beginning-of-line)
                      (+ 2 (point) tab-switcher-column)))
             (tab (and (not (eobp)) (get-text-property where 'tab))))
        (or tab
            (if error-if-non-existent-p
                (error "No window configuration on this line")
                #f))))

    (define-command (tab-switcher-next-line arg)
      "Move to ARGth next line in the list of tabs."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (forward-line arg)
      (beginning-of-line)
      (move-to-column tab-switcher-column))

    (define-command (tab-switcher-prev-line arg)
      "Move to ARGth previous line in the list of tabs."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (forward-line (- arg))
      (beginning-of-line)
      (move-to-column tab-switcher-column))

    (define-command (tab-switcher-unmark backup)
      "Cancel operations on window configuration on this line and move down.
With prefix arg BACKUP, move up instead."
      (interactive (list (current-prefix-arg)))
      (beginning-of-line)
      (move-to-column tab-switcher-column)
      (parameterize ((*inhibit-read-only* #t))
        (delete-char 1)
        (insert " "))
      (forward-line (if backup -1 1))
      (move-to-column tab-switcher-column))

    (define-command (tab-switcher-backup-unmark)
      "Move up a line and cancel operations on the window configuration."
      (interactive '())
      (forward-line -1)
      (tab-switcher-unmark #f))

    (define-command (tab-switcher-delete arg)
      "Mark window configuration on this line to be deleted.
Prefix arg says how many window configurations to delete.
Negative arg means delete backwards.
The deletion will be done by the \\<tab-switcher-mode-map>\\[tab-switcher-execute] command."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (parameterize ((*inhibit-read-only* #t))
        (let ((arg (if (or (not arg) (= arg 0)) 1 arg)))
          (let loop ()
            (when (> arg 0)
              (delete-char 1)
              (insert "D")
              (forward-line 1)
              (set! arg (- arg 1))
              (loop)))
          (let loop ()
            (when (< arg 0)
              (delete-char 1)
              (insert "D")
              (forward-line -1)
              (set! arg (+ arg 1))
              (loop))))
        (move-to-column tab-switcher-column)))

    (define-command (tab-switcher-delete-backwards arg)
      "Mark window configuration on this line to be deleted.
Then move up one line.  Prefix arg means move that many lines."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (tab-switcher-delete (- (or arg 1))))

    (define (tab-switcher-delete-from-list tab)
      ;; "Delete the window configuration from the list of tabs."
      ;;--------------------------------------------------------------
      (tab-bar-closed-tabs
            (cons (list (cons 'frame (selected-frame))
                        (cons 'index (tab-bar--tab-index tab))
                        (cons 'tab tab))
                  tab-bar-closed-tabs))
      (tab-bar-tabs-set (delq tab ((*tab-bar-tabs-function*)))))

    (define-command (tab-switcher-execute)
      "Delete the marked window configurations.
Use the \\<tab-switcher-mode-map>\\[tab-switcher-delete] commands
to set those marks."
      (interactive '())
      (save-excursion
        (goto-char (point-min))
        (parameterize ((*inhibit-read-only* #t))
          (let loop ()
            (when (re-search-forward
                   (string-append "^" (make-string tab-switcher-column #\space)
                                  "D")
                   #f 'noerror)
              (forward-char -1)
              (let ((tab (tab-switcher-current-tab #f)))
                (when tab
                  (tab-switcher-delete-from-list tab)
                  (beginning-of-line)
                  (delete-region (point) (begin (forward-line 1) (point)))))
              (loop)))))
      (beginning-of-line)
      (move-to-column tab-switcher-column)
      (force-mode-line-update))

    (define-command (tab-switcher-select)
      "Select this line's window configuration.
This command replaces all the existing windows in the selected frame
with those specified by the selected window configuration."
      (interactive '())
      (let* ((to-tab (tab-switcher-current-tab #t)))
        (kill-buffer (current-buffer))
        ;; "Delete the current window configuration of tab list without
        ;; storing it in the undo list of closed tabs"
        (parameterize ((*inhibit-message* #t)
                       (tab-bar-closed-tabs '()))
          (tab-bar-close-tab #f (+ 1 (tab-bar--tab-index to-tab))))))

    (define-command (tab-switcher-mouse-select event)
      "Select the window configuration whose line you click on."
      (interactive "e")
      (set-buffer (window-buffer (posn-window (event-end event))))
      (goto-char (posn-point (event-end event)))
      (tab-switcher-select))

    (define *tab-switcher-mode-hook* (make-parameter '()))

    (define-derived-mode
      (tab-switcher-mode #f "Window Configurations" tab-switcher-mode-map
                         *tab-switcher-mode-hook*)
      "Major mode for selecting a window configuration.
Each line describes one window configuration in Emacs."
      (set-buffer-local-value! (current-buffer) 'truncate-lines #t))

    (define (tab-switcher-noselect)
      ;; "Create and return a buffer with a list of window
      ;; configurations. The list is displayed in a buffer named
      ;; `*Tabs*'."
      ;;--------------------------------------------------------------
      (let* ((tabs (seq-remove (lambda (tab) (eq? (car tab) 'current-tab))
                               ((*tab-bar-tabs-function*))))
             ;; "Sort by recency"
             (tabs (sort tabs (lambda (a b)
                                (< (tab-bar--alist-get 'time b)
                                   (tab-bar--alist-get 'time a)))))
             (name (string-append
                    " *Tabs*<"
                    (let ((id (frame-parameter (selected-frame) 'window-id)))
                      (if id
                          (if (string? id) id (number->string id))
                          (or (frame-parameter (selected-frame) 'name) "F")))))
             (buffer (get-buffer-create name)))
        (with-current-buffer buffer
          (set!buffer-read-only buffer #f)
          (erase-buffer)
          (tab-switcher-mode)
          ;; "Vertical alignment to the center of the frame"
          (insert-char #\newline
                       (max 0 (quotient (- (frame-height (selected-frame))
                                           (length tabs) 1)
                                        2)))
          ;; "Horizontal alignment to the center of the frame"
          (set! tab-switcher-column
                (- (quotient (frame-width (selected-frame)) 2) 15))
          (for-each
           (lambda (tab)
             (insert (propertize
                      (string-append
                       (make-string tab-switcher-column #\space)
                       (propertize (or (tab-bar--alist-get 'name tab) "")
                                   'mouse-face 'highlight
                                   'help-echo
                                   "mouse-2: select this window configuration")
                       "\n")
                      'tab tab)))
           tabs)
          (goto-char (point-min))
          (goto-char (or (next-single-property-change (point) 'tab)
                         (point-min)))
          (when (> (length tabs) 1)
            (tab-switcher-next-line 1))
          (move-to-column tab-switcher-column)
          (set-buffer-modified-p #f)
          (set!buffer-read-only buffer #t)
          buffer)))

    (define-command (tab-switcher)
      "Display a list of named window configurations.
The list is displayed in the buffer `*Tabs*'.
It's placed in the center of the frame to resemble a window list
displayed by a window switcher in some window managers on Alt+Tab.

In this list of window configurations you can delete or select them.
Type ? after invocation to get help on commands available.
Type q to remove the list of window configurations from the display.

The first column shows `D' for a window configuration you have
marked for deletion."
      (interactive '())
      (let ((dir (default-directory)))
        (parameterize ((*tab-bar-new-tab-choice* #t)
                       ;; "Don't enable tab-bar-mode if it's disabled"
                       (*tab-bar-show* #f))
          (tab-bar-new-tab #f #f))
        (switch-to-buffer (tab-switcher-noselect))
        (set-buffer-local-value! (current-buffer) 'default-directory dir))
      (message "Commands: d, x; RET; q to quit; ? for help."))

    (define-key tab-switcher-mode-map (kbd "q") quit-window)
    (define-key tab-switcher-mode-map (kbd "RET") tab-switcher-select)
    (define-key tab-switcher-mode-map (kbd "d") tab-switcher-delete)
    (define-key tab-switcher-mode-map (kbd "k") tab-switcher-delete)
    (define-key tab-switcher-mode-map (kbd "C-d") tab-switcher-delete-backwards)
    (define-key tab-switcher-mode-map (kbd "C-k") tab-switcher-delete)
    (define-key tab-switcher-mode-map (kbd "x") tab-switcher-execute)
    (define-key tab-switcher-mode-map (kbd "SPC") tab-switcher-next-line)
    (define-key tab-switcher-mode-map (kbd "n") tab-switcher-next-line)
    (define-key tab-switcher-mode-map (kbd "p") tab-switcher-prev-line)
    (define-key tab-switcher-mode-map (kbd "DEL") tab-switcher-backup-unmark)
    (define-key tab-switcher-mode-map (kbd "u") tab-switcher-unmark)
    (define-key tab-switcher-mode-map (kbd "<mouse-2>")
      tab-switcher-mouse-select)

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

    (define-command (tab-bar-move-window-to-tab)
      "Move the selected window to a new tab.
This command removes the selected window from the configuration stored
on the current tab, and makes a new tab with that window in its
configuration."
      (interactive '())
      (parameterize ((*tab-bar-new-tab-choice* 'window))
        (tab-bar-new-tab #f #f))
      (tab-bar-switch-to-recent-tab #f)
      ;; Emacs binds `ignore-window-parameters' around the delete so that
      ;; a window's own parameters cannot stop `delete-window'. Nothing
      ;; in this tree's `delete-window` consults a window parameter - it
      ;; has no side windows to be told about - so there is nothing to
      ;; bind.
      (delete-window (selected-window))
      (tab-bar-switch-to-recent-tab #f))

    (define-command (tab-bar-split-tab tab arg)
      "Split windows of specified TAB into two separate tabs.
TAB defaults to the selected tab.  ARG specifies the number
of windows to consider for splitting and defaults to 1.
Interactively, ARG is the prefix argument.

First divide the child windows of TAB's main window into two parts.
The first part includes the first ARG child windows if ARG is positive,
or -ARG last windows if it's negative.  The second part includes the
remaining child windows of TAB's main window.  Then clone into a
newly-created tab each of the windows of the part which does not
include TAB's selected window and delete those windows from TAB."
      (interactive (list #f (current-prefix-arg)))
      (let* ((tab (or tab (1+ (tab-bar--current-tab-index))))
             ;; "Make sure the tab we are splitting is selected", which
             ;; is what its `_` binding does.
             (_ (unless (eq? tab (1+ (tab-bar--current-tab-index)))
                  (tab-bar-select-tab tab)))
             (main (window-main-window))
             (total-window-count (window-child-count main))
             (arg (or arg 1)))
        (cond
         ((window-live-p main)
          (error "Cannot split tab with only one window"))
         ((or (not (number? arg)) (= arg 0))
          (error "Invalid ARG ~a for splitting tab" arg))
         ((>= (abs arg) total-window-count)
          (error "ARG ~a exceeds number of windows ~a that can be split off"
                 (abs arg) (1- total-window-count)))
         (else
          (let* ((comb (window-get-split-combination main arg))
                 (ws (window-state-get comb)))
            (delete-window comb)
            (tab-bar-new-tab #f #f)
            (window-state-put ws (window-main-window)))))))

    (define split-tab tab-bar-split-tab)

    (define-command (tab-bar-merge-tabs tab1 tab2 vertical)
      "Merge the main window of TAB2 into TAB1.
Split the main window of TAB1 and make the new window display
the main window of TAB2.  Both TAB1 and TAB2 must be tab numbers.
If VERTICAL is non-nil, make the new window below the old main window
of TAB1.  Otherwise, make the new window on the right of TAB1's main
window.  Interactively, VERTICAL is the prefix argument, TAB1 is the
selected tab and TAB2 is the recent tab.  Close TAB2 if the merge
completed successfully and return TAB1."
      (interactive (list #f #f (current-prefix-arg)))
      (let ((tab1 (or tab1 (1+ (tab-bar--current-tab-index))))
            (tab2 (or tab2 (1+ (or (tab-bar--tab-index-recent 1) 0))))
            (ws2 #f))
        (when (eq? tab1 tab2)
          (error "Cannot find tab to merge"))
        (tab-bar-select-tab tab2)
        (set! ws2 (window-state-get (window-main-window)))
        ;; The C's dynamic binding of the two variables around the close:
        ;; the tab closed is the one just read, and it must not be
        ;; recorded for `tab-bar-undo-close-tab` - the merge is one
        ;; operation, not a close followed by an insert.
        (parameterize ((*tab-bar-close-tab-select* 'recent)
                       (tab-bar-closed-tabs '()))
          (tab-bar-close-tab #f #f))
        (unless (eq? tab1 (1+ (tab-bar--current-tab-index)))
          (tab-bar-select-tab tab1))
        (window-state-put
         ws2
         ;; "Make new window on tab1."
         (split-window (window-main-window) #f (not vertical)))
        tab1))

    (define merge-tabs tab-bar-merge-tabs)

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
    (define tab-group tab-bar-change-tab-group)
    (define tab-close-group tab-bar-close-group-tabs)
    (define tab-new tab-bar-new-tab)
    (define tab-new-to tab-bar-new-tab-to)
    (define tab-duplicate tab-bar-duplicate-tab)
    (define tab-switch tab-bar-switch-to-tab)
    (define tab-select-tab-by-name tab-bar-switch-to-tab)
    (define tab-close-by-name tab-bar-close-tab-by-name)
    (define tab-rename-by-name tab-bar-rename-tab-by-name)
    (define tab-move-backward tab-bar-move-tab-backward)
    (define tab-window-detach tab-bar-move-window-to-tab)

    (define-key *default-keymap* (kbd "C-x t 2") tab-new)
    (define-key *default-keymap* (kbd "C-x t 0") tab-close)
    (define-key *default-keymap* (kbd "C-x t 1") tab-close-other)
    (define-key *default-keymap* (kbd "C-x t u") tab-undo)
    (define-key *default-keymap* (kbd "C-x t o") tab-next)
    (define-key *default-keymap* (kbd "C-x t O") tab-previous)
    (define-key *default-keymap* (kbd "C-x t m") tab-move)
    (define-key *default-keymap* (kbd "C-x t M") tab-move-to)
    (define-key *default-keymap* (kbd "C-x t r") tab-rename)
    (define-key *default-keymap* (kbd "C-x t G") tab-group)
    (define-key *default-keymap* (kbd "C-x t RET") tab-switch)
    (define-key *default-keymap* (kbd "C-x t n") tab-duplicate)

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
