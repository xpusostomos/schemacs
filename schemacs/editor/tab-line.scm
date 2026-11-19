(define-library (schemacs editor tab-line)
  ;; This library mirrors GNU Emacs's `lisp/tab-line.el`: a window's tab
  ;; line - a row of tabs above its text, each one a button that shows a
  ;; buffer, with a close button, a "+" button, and scrolling when the
  ;; tabs do not fit.
  ;;
  ;; The *display* half is not here and was done first: the row is
  ;; reserved and drawn by `(schemacs editor xdisp)' from the window's
  ;; `tab-line-format`, `window_wants_tab_line` and
  ;; `window-tab-line-height` are `window.c`'s in `frame.scm`, and the
  ;; faces are `faces.scm`'s. This file is the Lisp half - what the
  ;; format string *is*, and the commands that act on it.
  ;;
  ;; **The departures, all of them the tree's rather than this file's:**
  ;;
  ;;   * `defcustom` is `define-custom` (`custom.el`), so an option is a
  ;;     *parameter* and is read `(*tab-line-tabs-function*)` where Emacs
  ;;     writes `tab-line-tabs-function`. A `:set` is the tree's
  ;;     spelling too: `(lambda (symbol value) ((get symbol 'custom-writer)
  ;;     symbol value) ...)`, which is what `set-default` is here. A
  ;;     plain `defvar` - read and never bound - keeps its name and is
  ;;     not a parameter.
  ;;   * **The file's order is functions first, tables second.** Emacs
  ;;     puts its `defvar-keymap`s at the top; a keymap here holds
  ;;     *procedures*, so a binding cannot be made before the command is
  ;;     defined. Same reason a `defcustom` that names a function comes
  ;;     after it.
  ;;   * `ctl-x-map` does not exist here - every `C-x` binding goes into
  ;;     the one global map as a whole key sequence - so
  ;;     `tab-line--define-keys` binds `C-x <left>` flat and asks the
  ;;     same question of the global map.
  ;;   * `seq.el` here is over lists (`seq.scm`'s own departure);
  ;;     `cl-position` and `evenp` are `seq-position` and `even?`.
  ;;   * `window-parameter` and `set-window-parameter` require their
  ;;     WINDOW argument here where the C makes it optional, so `nil`
  ;;     becomes `(selected-window)`.
  ;;   * `buffer-local-value` takes the buffer *first* here.
  ;;   * `last-nonmenu-event` is `*last-read-event*` (`keyboard.c`'s
  ;;     `last-input-event`, which is what the tree carries).
  ;;   * `window-system` is `(*window-system*)` (`frame.c`'s variable).
  ;;   * `force-mode-line-update`'s ALL argument marks the same flag
  ;;     here, so the per-window walk `walk-windows` would make is not
  ;;     needed and `walk-windows` itself is not carried: the ALL branch
  ;;     walks each frame's `window-list` instead.
  ;;   * **a tab is an alist with no head symbol.** Emacs writes
  ;;     `(tab (name . G) (select . F))`; `assq` there tolerates the
  ;;     leading symbol because `Fassq` compares a non-cons element with
  ;;     the key and moves on, and Guile's `assq` raises instead. The head
  ;;     is decorative - every reader is an `assq` or an `alist-get` - so
  ;;     it is dropped rather than teaching `assq` Emacs's tolerance.
  ;;   * a tab's `keymap` text property holds the *keymap value* here, as
  ;;     it does in Emacs - a map is an object in this tree, not a symbol.
  ;;   * `(:eval (tab-line-format))` is `(:eval tab-line-format)`: this
  ;;     tree's `:eval` construct holds a procedure to call, not a form
  ;;     to evaluate (`xdisp.scm`'s `format-mode-line`), which is a
  ;;     pre-existing departure of the mode-line formatter.
  ;;
  ;; **Not carried, with what each waits for:**
  ;;
  ;;   * **`tmm-prompt`**, the tty half of `tab-line-new-tab-choice`'s
  ;;     `t` branch. `mouse-buffer-menu` *is* here (`mouse.scm`), so the
  ;;     window-system arm works and opens the buffer menu; the terminal
  ;;     arm says `tmm-prompt` is not ported.
  ;;   * **touch input**: there is none, so `tab-line-track-tap` answers
  ;;     t for every event and the `touchscreen-begin` arms are dead.
  ;;   * **`tab-line-tabs-buffer-group-by-project`**: `project.el` is not
  ;;     ported. The group *function* is a defcustom, so a user's own
  ;;     grouping works.
  ;;   * `switch-to-buffer-obey-display-actions` (there are no display
  ;;     actions) and `repeat-mode` (`tab-line-switch-repeat-map` is
  ;;     defined but nothing reads it).
  ;;
  ;; **Carried since the first draft**: `tab-line-tab-name-truncated-buffer`
  ;; over `truncate-string-to-width` (`mule-util.scm`),
  ;; `mouse-buffer-menu-mode-groups` as the default group table
  ;; (`mouse.scm`), and `window-persistent-parameters` (`frame.scm`),
  ;; which is what `add-to-list` in this file extends.
  ;;
  ;; **And the context menus**, which an earlier version of this header
  ;; called not carried: `tab-line-tab-context-menu` and
  ;; `tab-line-context-menu` are implemented below over `popup-menu`,
  ;; which lives in `menu-bar.scm`.

  (import
    (scheme base)
    (scheme char)
    (only (guile) exact->inexact format hashq-ref hashq-set! identity
          make-hash-table string<)
    (only (schemacs editor command)
          define-command current-prefix-arg uarg->integer)
    (only (schemacs editor keyboard) *last-read-event*)
    (only (schemacs editor custom) define-custom custom-initialize-default)
    (only (schemacs editor intervals) get)
    (only (schemacs editor easy-mmode)
          define-minor-mode define-globalized-minor-mode)
    (only (schemacs editor icons) define-icon icon-string)
    (only (schemacs editor keymap)
          define-key keymap-lookup *default-keymap* make-sparse-keymap)
    (only (schemacs editor subr) define-key-after)
    ;; `popup-menu` is `menu-bar.el`'s, and it is where a click on a menu
    ;; item becomes a command.
    (only (schemacs editor menu-bar) popup-menu)
    (only (schemacs editor subr)
          assq-delete-all delq kbd nth nthcdr posn-window posn-string
          event-start event-end string-replace)
    (only (schemacs editor search) string-match-p)
    ;; The `kill-buffer` *command*, which is `files.scm`'s: the
    ;; mechanism that leaves the buffer list is `buffer.scm`'s
    ;; `%kill-buffer`, and the command that may prompt about a modified
    ;; buffer is the one Emacs's `tab-line-close-tab-function` names.
    (only (schemacs editor files) kill-buffer)
    (only (schemacs editor buffer)
          bury-buffer buffer-list buffer-live-p buffer-file-name
          buffer-local-value buffer-modified-p buffer-name bufferp
          current-buffer erase-buffer generate-new-buffer major-mode
          mode-name set-buffer-local-value! with-current-buffer)
    (only (schemacs editor minibuffer) minibufferp)
    (only (schemacs editor editfns)
          goto-char insert message point point-min point-max propertize
          get-pos-property)
    ;; `truncate-string-to-width` is `international/mule-util.el`'s.
    (only (schemacs editor mule-util) truncate-string-to-width)
    ;; The default group table, `mouse.el`'s.
    (only (schemacs editor mouse) *mouse-buffer-menu-mode-groups*
          mouse-buffer-menu)
    ;; `display-popup-menus-p` is `frame.el`'s; `tty-menu-open-use-tmm`
    ;; is `menu-bar.el`'s.
    (only (schemacs editor frame) display-popup-menus-p)
    (only (schemacs editor menu-bar) *tty-menu-open-use-tmm*)
    ;; `add-to-list` and the variable it extends.
    (only (schemacs editor subr) add-to-list)
    (only (schemacs editor frame) *window-persistent-parameters*)
    (only (schemacs editor fns) concat copy-sequence)
    (only (schemacs editor frame)
          *frame-list* set-window-parameter window-buffer window-list
          window-parameter selected-window)
    ;; The display type, for the separator: `frame.c`'s `window-system`
    ;; is `faces.scm`'s parameter here, beside the face machinery that
    ;; reads it.
    (only (schemacs editor faces) *window-system*)
    (only (schemacs editor window)
          next-buffer previous-buffer
          set-window-next-buffers set-window-prev-buffers switch-to-buffer
          switch-to-next-buffer switch-to-prev-buffer window-next-buffers
          window-prev-buffers with-selected-window)
    (only (schemacs editor xdisp)
          force-mode-line-update format-mode-line mode-line-window-selected-p)
    (only (schemacs editor indentc) vertical-motion)
    (only (schemacs editor textprop)
          add-face-text-property add-text-properties
          next-single-property-change previous-single-property-change)
    (only (schemacs editor seq)
          seq-do-indexed seq-drop seq-difference seq-filter seq-find
          seq-group-by seq-keep seq-position seq-remove seq-sort
          seq-sort-by seq-subseq seq-take seq-uniq)
    (only (schemacs editor derived) buffer-match-p derived-mode-p))

  (export
   ;; the commands
   tab-line-select-tab tab-line-new-tab tab-line-close-tab
   tab-line-close-other-tabs tab-line-hscroll-left tab-line-hscroll-right
   tab-line-switch-to-prev-tab tab-line-switch-to-next-tab
   tab-line-move-tab-backward tab-line-move-tab-forward
   tab-line-mouse-move-tab tab-line-select-tab-buffer
   tab-line-tab-context-menu tab-line-context-menu
   ;; the format the redisplay reads
   tab-line-format tab-line-format-template tab-line-force-update
   tab-line-cache-key-default tab-line-cache-key-function
   tab-line--get-tab-property tab-line-auto-hscroll tab-line-hscroll
   tab-line-event-start tab-line-track-tap
   ;; how the tabs are chosen
   tab-line-tabs-window-buffers tab-line-tabs-fixed-window-buffers
   tab-line-tabs-mode-buffers tab-line-tabs-buffer-list
   tab-line-tabs-buffer-groups tab-line-tabs-buffer-group-by-mode
   tab-line-tabs-buffer-group-name tab-line-tabs-buffer-group-sort-by-name
   tab-line-tabs-non-excluded tab-line-tabs-buffer-list-function
   tab-line-tab-name-buffer tab-line-tab-name-format-default
   tab-line-tab-face-inactive-alternating tab-line-tab-face-special
   tab-line-tab-face-modified tab-line-tab-face-group
   tab-line-tab-modified-p tab-line--current-tab
   ;; the modes and their keys
   tab-line-mode tab-line-mode-variable
   global-tab-line-mode global-tab-line-mode-variable
   tab-line-mode--turn-on
   tab-line--define-keys tab-line--undefine-keys
   tab-line-mode-map tab-line-switch-repeat-map
   tab-line-tab-map tab-line-add-map tab-line-tab-close-map
   tab-line-left-map tab-line-right-map
   ;; the buttons
   tab-line-new-button tab-line-close-button tab-line-close-modified-button
   tab-line-left-button tab-line-right-button tab-line-separator
   tab-line-new-button-functions *tab-line-tabs-buffer-groups*
   tab-line-exclude tab-line-tab-name-ellipsis tab-line-auto-hscroll-buffer
   ;; the options
   *tab-line-tab-face-functions* *tab-line-new-tab-choice*
   *tab-line-new-button-show* *tab-line-close-button-show*
   *tab-line-close-modified-button-show*
   *tab-line-tab-name-function* *tab-line-tab-name-truncated-max*
   *tab-line-tabs-function* *tab-line-tabs-buffer-group-function*
   *tab-line-tabs-buffer-group-sort-function*
   *tab-line-tabs-buffer-groups-sort-function*
   *tab-line-tabs-window-buffers-filter-function*
   *tab-line-tab-name-format-function* *tab-line-auto-hscroll*
   *tab-line-switch-cycling* *tab-line-close-tab-function*
   *tab-line-define-keys* *tab-line-exclude-modes*
   *tab-line-exclude-buffers*)

  (begin

    ;;--------------------------------------------------------------
    ;; The options that do not name a function
    ;;--------------------------------------------------------------

    (define-custom *tab-line-new-tab-choice* #t
      "Defines what to show in a new tab.
If t, display a selection menu with all available buffers.
If the value is a function, call it with no arguments."
      :type '(choice (const :tag "Buffer menu" #t)
                     (function :tag "Function"))
      :group 'tab-line)

    (define-custom *tab-line-new-button-show* #t
      "If non-nil, show the \"New tab\" button in the tab line."
      :type 'boolean
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (force-mode-line-update #t))
      :group 'tab-line)

    (define-custom *tab-line-close-button-show* #t
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
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (force-mode-line-update #t))
      :group 'tab-line)

    (define-custom *tab-line-close-modified-button-show* #t
      "If non-nil, the close button appearance will change when its buffer is modified."
      :type 'boolean
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (force-mode-line-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tab-name-truncated-max* 20
      "Maximum length of the tab name from the current buffer."
      :type 'natnum
      :group 'tab-line)

    (define-custom *tab-line-auto-hscroll* #t
      "Allow or disallow automatic horizontal scrolling of the tab line.
Non-nil means the tab lines are automatically scrolled horizontally to make
the selected tab visible."
      :type 'boolean
      :group 'tab-line)

    (define-custom *tab-line-switch-cycling* #t
      "Wrap tabs on tab switch while cycling.
If non-nil, `tab-line-switch-to-prev-tab' in the first tab
switches to the last tab and `tab-line-switch-to-next-tab' in the
last tab switches to the first tab."
      :type 'boolean
      :group 'tab-line)

    (define-custom *tab-line-exclude-modes* '(completion-list-mode)
      "List of major modes for which the tab-line display is not enabled.
Buffers under any of these major modes will not show the tab line in
their windows, even if `global-tab-line-mode' is enabled."
      :type '(repeat symbol)
      :group 'tab-line)

    (define-custom *tab-line-exclude-buffers* #f
      "Whether tab-line should not be enabled in a buffer.

The value must be a condition which is passed to `buffer-match-p' (which
see).  If the condition yields a non-nil value, tab line will not be
enabled in those buffers."
      :type 'sexp
      :group 'tab-line)

    (define-custom *tab-line-close-tab-function* bury-buffer
      "What to do upon closing a tab on the tab line.
If `bury-buffer', put the tab's buffer at the end of the list of all
buffers, which effectively hides the buffer's tab from the tab line.
If `kill-buffer', kills the tab's buffer.
When a function, it is called with the tab as its argument."
      :type '(choice (const :tag "Bury buffer" bury-buffer)
                     (const :tag "Kill buffer" kill-buffer)
                     (function :tag "Function"))
      :group 'tab-line)

    (define tab-line-tab-name-ellipsis #t)
    ;; ^ GNU Emacs's `tab-line-tab-name-ellipsis', a plain `defvar`.

    (define tab-line-exclude #f)
    ;; ^ GNU Emacs's `(defvar-local tab-line-exclude nil)' - a buffer
    ;; slot, read below with `buffer-local-value`, so this is only the
    ;; default the reader is given.

    (define tab-line-auto-hscroll-buffer
      (generate-new-buffer " *tab-line-hscroll*"))
    ;; ^ `(defvar tab-line-auto-hscroll-buffer (generate-new-buffer ...))':
    ;; the scratch buffer the hscroll measurement is made in.

    ;;--------------------------------------------------------------
    ;; The tab list functions
    ;;--------------------------------------------------------------

    (define (tab-line-tabs-buffer-list)
      ;; GNU Emacs's `tab-line-tabs-buffer-list` (`tab-line.el:424`):
      ;; "Function to return a global list of buffers. Used only for
      ;; `tab-line-tabs-mode-buffers' and `tab-line-tabs-buffer-groups'."
      ;;--------------------------------------------------------------
      (seq-filter (lambda (b)
                    (and (buffer-live-p b)
                         (not (char=? (string-ref (buffer-name b) 0) #\space))))
                  (seq-uniq (append (list (current-buffer))
                                    (map car (window-prev-buffers
                                              (selected-window)))
                                    (buffer-list)))))

    (define tab-line-tabs-buffer-list-function tab-line-tabs-buffer-list)
    ;; ^ `(defvar tab-line-tabs-buffer-list-function
    ;; #'tab-line-tabs-buffer-list ...)'.

    (define (tab-line-tabs-mode-buffers)
      ;; GNU Emacs's `tab-line-tabs-mode-buffers` (`:431`): "Return a
      ;; list of buffers with the same major mode as the current buffer."
      ;;--------------------------------------------------------------
      (let ((mode (major-mode)))
        (seq-sort-by buffer-name string<
                     (seq-filter
                      (lambda (b)
                        (with-current-buffer
                            b
                          (derived-mode-p mode)))
                      (tab-line-tabs-buffer-list-function)))))

    (define (tab-line-tab-modified-p tab buffer-p)
      ;; GNU Emacs's `tab-line-tab-modified-p` (`:440`): "Return t if
      ;; TAB's buffer is modified."
      ;;--------------------------------------------------------------
      (let ((buffer (if buffer-p tab (alist-get 'buffer tab))))
        (and buffer
             (buffer-file-name buffer)
             (buffer-modified-p buffer)
             #t)))

    (define (tab-line-tabs-buffer-group-sort-by-name a b)
      ;; GNU Emacs's `tab-line-tabs-buffer-group-sort-by-name` (`:476`).
      ;;--------------------------------------------------------------
      (string< (buffer-name a) (buffer-name b)))

    ;; **The group table is `*tab-line-tabs-buffer-groups*`**, a
    ;; parameter at the top of this section: Emacs's variable of the same
    ;; name is `let`-bound by `tab-line-new-tab`, which in this tree means
    ;; a parameter, and the asterisks are what tell it from the *function*
    ;; of the same name - the collision that a Lisp-2 has and a Lisp-1
    ;; does not.
    (define *tab-line-tabs-buffer-groups*
      ;; The default is the group *table*: `*mouse-buffer-menu-mode-groups*`
      ;; is a plain variable in `mouse.scm` (Emacs `defvar`s it), so it is
      ;; read by name here, not called - `(*mouse-buffer-menu-mode-groups*)`
      ;; applied the alist and died with "Wrong type to apply".
      (make-parameter *mouse-buffer-menu-mode-groups*))
    ;; ^ GNU Emacs's `(defvar tab-line-tabs-buffer-groups
    ;; mouse-buffer-menu-mode-groups ...)' (`tab-line.el:499`): "How to
    ;; group various major modes together in the tab line. Each element
    ;; has the form (REGEXP . GROUPNAME). If the major mode's name
    ;; matches REGEXP, it belongs to GROUPNAME. ..." Its default is the
    ;; *value* of `mouse-buffer-menu-mode-groups` at load time, which is
    ;; what the call here gives it.
    ;;
    ;; **It was exported and never defined**, so turning the tab line on
    ;; and letting `tab-line-tabs-buffer-groups` group the buffers died
    ;; with `unbound variable: *tab-line-tabs-buffer-groups*` the first
    ;; time a group was asked for. Every other name in this section had
    ;; its definition; this one only had its uses, and nothing exercised
    ;; them until a user enabled the mode.

    (define (tab-line-tabs-buffer-group-by-mode . args)
      ;; GNU Emacs's `tab-line-tabs-buffer-group-by-mode` (`:487`):
      ;; "Group tab buffers by major mode."
      ;;
      ;; `format-mode-line` of `mode-name` is how the C names a mode,
      ;; rather than `symbol-name` of it, so a mode with a custom
      ;; `mode-name` groups under that.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) #f)))
        ;; **`mode-name` is read, not passed**: it is a *procedure* in
        ;; this tree (Emacs's is a variable), so `(format-mode-line
        ;; mode-name)` handed the accessor to the formatter and every
        ;; mode grouped under the empty string.
        (let ((mode (if buffer
                        (with-current-buffer
                            buffer
                          (format-mode-line (mode-name)))
                        (format-mode-line (mode-name)))))
          ;; `(cdr nil)` is nil in Elisp, so a group table with no match
          ;; answers MODE; here `seq-find` answers #f and `cdr` would
          ;; raise.
          (or (let ((group (seq-find (lambda (entry)
                                       (string-match-p (car entry) mode))
                                     (*tab-line-tabs-buffer-groups*))))
                (and group (cdr group)))
              mode))))

    (define (tab-line-tabs-buffer-group-name . args)
      ;; GNU Emacs's `tab-line-tabs-buffer-group-name` (`:502`).
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) #f)))
        (if (procedure? (*tab-line-tabs-buffer-group-function*))
            ((*tab-line-tabs-buffer-group-function*) buffer)
            (tab-line-tabs-buffer-group-by-mode buffer))))

    (define (tab-line-tabs-buffer-groups)
      ;; GNU Emacs's `tab-line-tabs-buffer-groups` (`:507`): "Return a
      ;; list of tabs that should be displayed in the tab line. By
      ;; default return a list of buffers grouped by major mode."
      ;;
      ;; The tabs are association lists here as they are in Emacs (less
      ;; the head symbol - see the header), with a `select` that is a
      ;; *closure* - which is the point of the `name`/`selected`/`buffer`
      ;; keys: `tab-line-select-tab` calls `select` for a group tab and
      ;; switches to `buffer` for a buffer's.
      ;;--------------------------------------------------------------
      (if (window-parameter (selected-window) 'tab-line-groups)
          (let* ((buffers (tab-line-tabs-buffer-list-function))
                 (groups (seq-keep car
                                   (seq-group-by tab-line-tabs-buffer-group-name
                                                 buffers)))
                 (sorted-groups
                  (if (procedure? (*tab-line-tabs-buffer-groups-sort-function*))
                      (seq-sort (*tab-line-tabs-buffer-groups-sort-function*)
                                groups)
                      groups))
                 (selected-group (window-parameter (selected-window)
                                                   'tab-line-group)))
            (map (lambda (group)
                   (list (cons 'name group)
                         (cons 'selected (equal? group selected-group))
                         (cons 'select
                               (lambda ()
                                 (set-window-parameter (selected-window)
                                                       'tab-line-groups #f)
                                 (set-window-parameter (selected-window)
                                                       'tab-line-group group)
                                 (set-window-parameter (selected-window)
                                                       'tab-line-hscroll #f)))))
                 sorted-groups))
          (let* ((window-parameter (window-parameter (selected-window)
                                                     'tab-line-group))
                 (group-name (tab-line-tabs-buffer-group-name
                              (current-buffer)))
                 (group (let ((g (or window-parameter group-name "No group")))
                          (when (equal? window-parameter group-name)
                            (set-window-parameter (selected-window)
                                                  'tab-line-group #f))
                          g))
                 (group-tab
                  (list (cons 'name group)
                        (cons 'group-tab #t)
                        (cons 'select
                              (lambda ()
                                (set-window-parameter (selected-window)
                                                      'tab-line-groups #t)
                                (set-window-parameter (selected-window)
                                                      'tab-line-group group)
                                (set-window-parameter (selected-window)
                                                      'tab-line-hscroll #f)))))
                 (buffers (seq-filter
                           (lambda (b)
                             (equal? (tab-line-tabs-buffer-group-name b) group))
                           (tab-line-tabs-buffer-list-function)))
                 (sorted-buffers
                  (if (procedure? (*tab-line-tabs-buffer-group-sort-function*))
                      (seq-sort (*tab-line-tabs-buffer-group-sort-function*)
                                buffers)
                      buffers))
                 (tabs (map (lambda (buffer)
                              (list (cons 'name
                                          ((*tab-line-tab-name-function*)
                                           buffer))
                                    (cons 'selected
                                          (eq? buffer (current-buffer)))
                                    (cons 'buffer buffer)
                                    (cons 'close
                                          ;; "kill-buffer because
                                          ;; bury-buffer won't remove the
                                          ;; buffer from tab-line"
                                          (lambda rest
                                            (kill-buffer
                                             (if (pair? rest) (car rest)
                                                 buffer))))))
                            sorted-buffers)))
            (cons group-tab tabs))))

    (define (tab-line-tabs-non-excluded buffers)
      ;; GNU Emacs's `tab-line-tabs-non-excluded` (`:601`): "Filter
      ;; BUFFERS to remove excluded buffers from the list."
      ;;--------------------------------------------------------------
      (seq-remove
       (lambda (b)
         (or (memq (buffer-local-value b 'major-mode #f)
                   (*tab-line-exclude-modes*))
             (buffer-match-p (*tab-line-exclude-buffers*) b)
             (get (buffer-local-value b 'major-mode #f) 'tab-line-exclude)
             (buffer-local-value b 'tab-line-exclude #f)))
       buffers))

    (define (tab-line-tabs-window-buffers)
      ;; GNU Emacs's `tab-line-tabs-window-buffers` (`:615`): "By default
      ;; returns a list of window buffers, i.e. buffers previously shown
      ;; in the same window where the tab line is displayed."
      ;;--------------------------------------------------------------
      (let* ((window (selected-window))
             (buffer (window-buffer window))
             (next-buffers (seq-remove (lambda (b) (eq? b buffer))
                                       (window-next-buffers window)))
             (next-buffers (seq-filter buffer-live-p next-buffers))
             (prev-buffers (seq-remove (lambda (b) (eq? b buffer))
                                       (map car (window-prev-buffers window))))
             (prev-buffers (seq-filter buffer-live-p prev-buffers))
             ;; "Remove next-buffers from prev-buffers"
             (prev-buffers (seq-difference prev-buffers next-buffers)))
        ((*tab-line-tabs-window-buffers-filter-function*)
         (append (reverse prev-buffers)
                 (list buffer)
                 next-buffers))))

    (define (tab-line-tabs-fixed-window-buffers)
      ;; GNU Emacs's `tab-line-tabs-fixed-window-buffers` (`:637`): "Like
      ;; `tab-line-tabs-window-buffers' but keep stable sorting order.
      ;; ... newly displayed buffers are added to the end of the tab
      ;; line."
      ;;
      ;; The index table is `puthash`/`gethash` in the C - "the index of
      ;; a buffer in the old list, or `most-positive-fixnum` for one that
      ;; is new". A `hashq` table keys buffers by identity, which is what
      ;; the C's `:test #'eq` does.
      ;;--------------------------------------------------------------
      (let* ((window (selected-window))
             ;; A window parameter that was never set reads nil; the C's
             ;; `(length nil)` is 0 and its `seq-do-indexed` does nothing,
             ;; which is the empty list here.
             (old-buffers (or (window-parameter window 'tab-line-buffers)
                              '()))
             (buffer-positions (make-hash-table 64))
             (new-buffers #f))
        (seq-do-indexed (lambda (buf idx) (hashq-set! buffer-positions buf idx))
                        old-buffers)
        (set! new-buffers
              (seq-sort-by (lambda (buffer)
                             (hashq-ref buffer-positions buffer +inf.0))
                           <
                           (tab-line-tabs-window-buffers)))
        (set-window-parameter window 'tab-line-buffers new-buffers)
        new-buffers))

    ;;--------------------------------------------------------------
    ;; The name and face of one tab
    ;;--------------------------------------------------------------

    (define (tab-line-tab-name-buffer buffer . args)
      ;; GNU Emacs's `tab-line-tab-name-buffer` (`:348`): "Generate tab
      ;; name from BUFFER."
      ;;--------------------------------------------------------------
      (buffer-name buffer))

    (define (tab-line-tab-name-truncated-buffer buffer . args)
      ;; GNU Emacs's `tab-line-tab-name-truncated-buffer` (`tab-line.el:363`):
      ;; "Generate tab name from BUFFER, truncating as needed. Truncate it
      ;; to the length specified by `tab-line-tab-name-truncated-max`. If
      ;; truncated, append ellipsis per `tab-line-tab-name-ellipsis`."
      ;;
      ;; `(length tab-name)` over a string is its character count, as
      ;; Elisp's is; `truncate-string-to-width` is what cuts it, the
      ;; ellipsis is `truncate-string-ellipsis`'s (U+2026 here, which
      ;; every display draws), and the full name goes into `help-echo` so
      ;; a hovered tab still says what it is.
      ;;--------------------------------------------------------------
      (let ((tab-name (buffer-name buffer)))
        (if (< (string-length tab-name) (*tab-line-tab-name-truncated-max*))
            tab-name
            (propertize (truncate-string-to-width
                         tab-name (*tab-line-tab-name-truncated-max*) #f #f
                         tab-line-tab-name-ellipsis)
                        'help-echo tab-name))))

    (define (tab-line-tab-name-format-default tab tabs)
      ;; GNU Emacs's `tab-line-tab-name-format-default` (`:679`): "Default
      ;; function to use as `tab-line-tab-name-format-function', which
      ;; see."
      ;;
      ;; The C ends with `(apply 'propertize (concat NAME CLOSE) props)`;
      ;; that is a `concat` of two propertized strings here, the second
      ;; carrying the tab's own properties.
      ;;--------------------------------------------------------------
      (let* ((buffer-p (bufferp tab))
             (selected-p (if buffer-p
                             (eq? tab (window-buffer (selected-window)))
                             (alist-get 'selected tab)))
             (name (if buffer-p
                       ((*tab-line-tab-name-function*) tab tabs)
                       (alist-get 'name tab)))
             (face (if selected-p
                       (if (mode-line-window-selected-p)
                           'tab-line-tab-current
                           'tab-line-tab)
                       'tab-line-tab-inactive)))
        (for-each
         (lambda (fn)
           (set! face (fn tab tabs face buffer-p selected-p)))
         (*tab-line-tab-face-functions*))
        (let ((result
               (concat
         (propertize (string-replace "%" "%%" name)
                     'face face
                     'keymap tab-line-tab-map
                     'help-echo (if selected-p
                                    "Current tab"
                                    "Click to select tab")
                     ;; "Don't turn mouse-1 into mouse-2 (bug#49247)"
                     'follow-link 'ignore)
         (let ((close (or (and (or buffer-p
                                   (assq 'buffer tab)
                                   (assq 'close tab))
                               (*tab-line-close-button-show*)
                               (not (eq? (*tab-line-close-button-show*)
                                         (if selected-p
                                             'non-selected
                                             'selected)))
                               (if (and (*tab-line-close-modified-button-show*)
                                        (tab-line-tab-modified-p tab buffer-p))
                                   tab-line-close-modified-button
                                   tab-line-close-button))
                          "")))
           (set! close (copy-sequence close))
           ;; "Don't overwrite the icon face"
           (add-face-text-property 0 (string-length close) face #t close)
           close)
         (propertize "" 'mouse-face 'tab-line-highlight))))
          ;; The C is `(apply 'propertize (concat NAME CLOSE) props)`, so
          ;; the properties go on the whole string - a property on a
          ;; zero-length piece would not survive the `concat`.
          (add-text-properties 0 (string-length result)
                               (list 'tab tab
                                     'selected (and selected-p #t))
                               result)
          result)))

    (define (alist-get key alist . args)
      ;; GNU Emacs's `alist-get` (`subr.el`): the cdr of the first entry
      ;; whose car is KEY. `subr.scm` has no `alist-get` because nothing
      ;; there needed one; it is here for this file's four uses, which is
      ;; a placement departure named in the header.
      ;;--------------------------------------------------------------
      (let ((cell (assq key alist)))
        (if cell (cdr cell) (if (pair? args) (car args) #f))))

    (define (tab-line-tab-face-inactive-alternating tab tabs face buffer-p selected-p)
      ;; GNU Emacs's `tab-line-tab-face-inactive-alternating` (`:749`):
      ;; "When TAB is not selected and is even-numbered, make FACE inherit
      ;; from `tab-line-tab-inactive-alternate'."
      ;;--------------------------------------------------------------
      (when (and (not selected-p)
                 (let ((pos (seq-position tab tabs)))
                   (and pos (even? pos))))
        (set! face (list ':inherit
                         (list 'tab-line-tab-inactive-alternate face))))
      face)

    (define (tab-line-tab-face-special tab tabs face buffer-p selected-p)
      ;; GNU Emacs's `tab-line-tab-face-special` (`:759`): "When TAB
      ;; specifies a non-file-visiting buffer, make FACE inherit from
      ;; `tab-line-tab-special'."
      ;;--------------------------------------------------------------
      (let ((buffer (if buffer-p tab (alist-get 'buffer tab))))
        (when (and buffer (not (buffer-file-name buffer)))
          (set! face (list ':inherit (list 'tab-line-tab-special face)))))
      face)

    (define (tab-line-tab-face-modified tab tabs face buffer-p selected-p)
      ;; GNU Emacs's `tab-line-tab-face-modified` (`:772`): "When TAB's
      ;; buffer is a modified, file-backed buffer, make FACE inherit from
      ;; `tab-line-tab-modified'."
      ;;--------------------------------------------------------------
      (when (tab-line-tab-modified-p tab buffer-p)
        (set! face (list ':inherit (list 'tab-line-tab-modified face))))
      face)

    (define (tab-line-tab-face-group tab tabs face buffer-p selected-p)
      ;; GNU Emacs's `tab-line-tab-face-group` (`:785`): "When TAB is a
      ;; group tab, make FACE inherit from `tab-line-tab-group'."
      ;;--------------------------------------------------------------
      (when (alist-get 'group-tab tab)
        (set! face (list ':inherit (list 'tab-line-tab-group face))))
      face)

    ;;--------------------------------------------------------------
    ;; The format
    ;;--------------------------------------------------------------

    (define (tab-line-format-template tabs)
      ;; GNU Emacs's `tab-line-format-template` (`:718`): "Template of
      ;; the format for displaying tab line for selected window."
      ;;
      ;; `(if (window-system) " " "|")` is `(*window-system*)` here. The
      ;; hscroll is the window parameter: a float when auto-hscroll chose
      ;; it and an integer when the user scrolled by hand, and the two
      ;; are told apart by `number?` and `integer?` exactly as the C does.
      ;;--------------------------------------------------------------
      (let* ((window (selected-window))
             (separator (or tab-line-separator
                            (if (*window-system*) " " "|")))
             (hscroll (window-parameter window 'tab-line-hscroll))
             (strings
              (map (lambda (tab)
                     (concat separator
                             ((*tab-line-tab-name-format-function*) tab tabs)))
                   tabs))
             (hscroll-data (tab-line-auto-hscroll strings hscroll)))
        (set! hscroll (nth 1 hscroll-data))
        (append
         ;; "`(if (null (nth 0 hscroll-data)) ...)'" - the test is
         ;; whether SHOW-ARROWS is nil, and nil here may be `#f`, which
         ;; `null?` would answer no to. The arms produce *lists*, which
         ;; is what Elisp's nil-as-the-empty-list gives the C for free.
         (if (not (nth 0 hscroll-data))
             (begin
               (when hscroll
                 (set! hscroll #f)
                 (set-window-parameter window 'tab-line-hscroll hscroll))
               '())
             (append
              (list separator)
              (if (and (number? hscroll) (not (zero? hscroll)))
                  (list tab-line-left-button)
                  '())
              (if (if (number? hscroll)
                      (< (truncate hscroll) (- (length strings) 1))
                      (> (length strings) 1))
                  (list tab-line-right-button)
                  '())))
         ;; **`nthcdr`, not `list-tail`.** Elisp's `nthcdr` answers nil
         ;; when the list is shorter than N; Scheme's `list-tail` is an
         ;; error there, and `tab-line-hscroll` can name a column the
         ;; *new* tab list no longer reaches - which is what selecting a
         ;; buffer from the buffer menu did while the tab line was being
         ;; reformatted (`list-tail` died and took the redisplay with it).
         (if hscroll (nthcdr (truncate hscroll) strings) strings)
         (list separator)
         ;; Emacs's `(when ... (list tab-line-new-button))', whose nil
         ;; `append` drops - here a `when` that fails answers the
         ;; unspecified value, which `append` would splice in as a
         ;; dotted tail.
         (if (and (memq (*tab-line-tabs-function*)
                        tab-line-new-button-functions)
                  (*tab-line-new-button-show*)
                  tab-line-new-button)
             (list tab-line-new-button)
             '()))))

    (define (tab-line-force-update all)
      ;; GNU Emacs's `tab-line-force-update` (`:798`): "Force redisplay
      ;; of the current buffer's tab line. This function also clears the
      ;; tab-line cache."
      ;;
      ;; **The ALL branch does not use `walk-windows`**, which is
      ;; `window.el`'s and needs `next-window`; a walk over each frame's
      ;; window list is the same set for ALL = t with MINIBUF 'no-mini.
      ;;--------------------------------------------------------------
      (if all
          (for-each
           (lambda (frame)
             (for-each
              (lambda (window)
                (set-window-parameter window 'tab-line-cache #f))
              (window-list frame 'nomini)))
           (*frame-list*))
          (set-window-parameter (selected-window) 'tab-line-cache #f))
      (force-mode-line-update all))

    (define (tab-line-cache-key-default tabs)
      ;; GNU Emacs's `tab-line-cache-key-default` (`:812`): "Return
      ;; default list of cache keys."
      ;;--------------------------------------------------------------
      (let ((window (selected-window)))
        (list
         tabs
         ;; "handle buffer renames"
         (buffer-name (window-buffer window))
         ;; "handle tab-line scrolling"
         (window-parameter window 'tab-line-hscroll)
         ;; "for setting face 'tab-line-tab-current'"
         (mode-line-window-selected-p)
         ;; "for `tab-line-tab-face-modified'"
         (and (or (*tab-line-close-modified-button-show*)
                  (memq 'tab-line-tab-face-modified
                        (*tab-line-tab-face-functions*)))
              (buffer-file-name)
              (buffer-modified-p)))))

    (define tab-line-cache-key-function tab-line-cache-key-default)
    ;; ^ `(defvar tab-line-cache-key-function #'tab-line-cache-key-default
    ;; ...)'. A plain variable: Emacs invites `add-function` on it, which
    ;; this tree has not got, so a user `set!`s it.

    (define (tab-line-format)
      ;; GNU Emacs's `tab-line-format` (`:833`): "Format for displaying
      ;; the tab line of the selected window."
      ;;
      ;; "Enable auto-hscroll again after it was disabled on manual
      ;; scrolling. The moment to enable it is when the window-buffer was
      ;; updated."
      ;;--------------------------------------------------------------
      (let* ((window (selected-window))
             (tabs ((*tab-line-tabs-function*)))
             (cache-key (tab-line-cache-key-function tabs))
             (cache (window-parameter window 'tab-line-cache)))
        (when (and (*tab-line-auto-hscroll*)
                   (integer? (nth 2 cache-key))
                   cache
                   (not (equal? (nth 1 (car cache)) (nth 1 cache-key))))
          (set-window-parameter window 'tab-line-hscroll
                                (exact->inexact (nth 2 cache-key))))
        (or (and cache (equal? (car cache) cache-key) (cdr cache))
            (cdr (set-window-parameter
                  window 'tab-line-cache
                  (cons cache-key (tab-line-format-template tabs)))))))

    (define (tab-line--get-tab-property prop string)
      ;; GNU Emacs's `tab-line--get-tab-property` (`:854`): the `tab`
      ;; property of a separator - at 1 for a one-character separator, at
      ;; 0 for an empty one, and at the position it changes at for a
      ;; longer one.
      ;;--------------------------------------------------------------
      (or (get-pos-property 1 prop string)
          (get-pos-property 0 prop string)
          (let ((pos (next-single-property-change 0 prop string)))
            (and pos (get-pos-property pos prop string)))))

    (define (tab-line-auto-hscroll strings hscroll)
      ;; GNU Emacs's `tab-line-auto-hscroll` (`:861`): measure the tabs
      ;; in a scratch buffer, decide whether the arrows are needed, and
      ;; where to scroll to so the selected tab is visible.
      ;;
      ;; The measurement is `vertical-motion` in a buffer whose
      ;; `truncate-lines` is nil: if moving down one screen line leaves
      ;; the start of the buffer, the tabs wrapped and do not fit - which
      ;; is what `show-arrows` is.
      ;;--------------------------------------------------------------
      (with-current-buffer
          tab-line-auto-hscroll-buffer
        (let ((truncate-partial-width-windows #f)
              (inhibit-modification-hooks #t)
              (face (if (mode-line-window-selected-p)
                        'tab-line-active
                        'tab-line-inactive))
              (show-arrows #f))
          (set-buffer-local-value! (current-buffer) 'truncate-lines #f)
          (set-buffer-local-value! (current-buffer) 'word-wrap #f)
          (erase-buffer)
          (apply insert strings)
          (goto-char (point-min))
          (add-face-text-property (point-min) (point-max) face #t)
          (set! show-arrows (> (vertical-motion 1) 0))
          ;; "Try to auto-hscroll only when scrolling is needed, but no
          ;; manual scrolling was performed before."
          (when (and (*tab-line-auto-hscroll*)
                     show-arrows
                     ;; "Do nothing when scrolled manually"
                     (not (integer? hscroll)))
            (let ((selected
                   (seq-position
                    strings 'selected
                    (lambda (str prop)
                      (tab-line--get-tab-property prop str)))))
              (cond
               ((not selected)
                ;; "Do nothing if no tab is selected"
                #f)
               ((or (not (number? hscroll))
                    (< selected (truncate hscroll)))
                ;; "Selected is scrolled to the left, or no scrolling yet"
                (erase-buffer)
                (apply insert (reverse (seq-subseq strings 0 (+ selected 1))))
                (goto-char (point-min))
                (add-face-text-property (point-min) (point-max) face #t)
                (if (> (vertical-motion 1) 0)
                    (let* ((point (previous-single-property-change
                                   (point) 'tab))
                           (tab-prop (and point
                                          (or (get-pos-property point 'tab)
                                              (and (set! point
                                                         (previous-single-property-change
                                                          point 'tab))
                                                   (get-pos-property point 'tab)))))
                           (new-hscroll
                            (and tab-prop
                                 (seq-position
                                  strings tab-prop
                                  (lambda (str tab)
                                    (eq? (tab-line--get-tab-property 'tab str)
                                         tab))))))
                      (when new-hscroll
                        (set! hscroll (exact->inexact new-hscroll))
                        (set-window-parameter (selected-window)
                                              'tab-line-hscroll hscroll)))
                    (begin
                      (set! hscroll #f)
                      (set-window-parameter (selected-window)
                                            'tab-line-hscroll hscroll))))
               (else
                ;; "Check if the selected tab is already visible"
                (erase-buffer)
                (apply insert (seq-subseq strings (truncate hscroll)
                                         (+ selected 1)))
                (goto-char (point-min))
                (add-face-text-property (point-min) (point-max) face #t)
                (when (> (vertical-motion 1) 0)
                  ;; "Not visible already"
                  (erase-buffer)
                  (apply insert (reverse (seq-subseq strings 0 (+ selected 1))))
                  (goto-char (point-min))
                  (add-face-text-property (point-min) (point-max) face #t)
                  (when (> (vertical-motion 1) 0)
                    (let* ((point (previous-single-property-change
                                   (point) 'tab))
                           (tab-prop (and point
                                          (or (get-pos-property point 'tab)
                                              (and (set! point
                                                         (previous-single-property-change
                                                          point 'tab))
                                                   (get-pos-property point 'tab)))))
                           (new-hscroll
                            (and tab-prop
                                 (seq-position
                                  strings tab-prop
                                  (lambda (str tab)
                                    (eq? (tab-line--get-tab-property 'tab str)
                                         tab))))))
                      (when new-hscroll
                        (set! hscroll (exact->inexact new-hscroll))
                        (set-window-parameter (selected-window)
                                              'tab-line-hscroll hscroll)))))))))
          (list show-arrows hscroll))))

    (define (tab-line-hscroll . args)
      ;; GNU Emacs's `tab-line-hscroll` (`:947`): scroll the tab line ARG
      ;; positions, in WINDOW.
      ;;--------------------------------------------------------------
      (let* ((arg (if (pair? args) (car args) #f))
             (window (if (and (pair? args) (pair? (cdr args)))
                         (cadr args)
                         #f))
             (hscroll (window-parameter (or window (selected-window))
                                        'tab-line-hscroll))
             (tabs (if window
                       (with-selected-window
                           window
                         ((*tab-line-tabs-function*)))
                       ((*tab-line-tabs-function*)))))
        (set-window-parameter
         (or window (selected-window)) 'tab-line-hscroll
         (max 0 (min (+ (if (number? hscroll) (truncate hscroll) 0)
                       (or arg 1))
                     (- (length tabs) 1))))
        (when window
          (force-mode-line-update #t))))

    (define (tab-line-event-start event)
      ;; GNU Emacs's `tab-line-event-start` (`:1291`): "Like
      ;; `event-start'. However, return the correct mouse position list if
      ;; EVENT is a `touchscreen-begin' event."
      ;;
      ;; There is no touch input here, so this is `event-start` and the
      ;; touch arm is named in the header.
      ;;--------------------------------------------------------------
      (event-start event))

    (define (tab-line-track-tap event . args)
      ;; GNU Emacs's `tab-line-track-tap` (`:1244`): "Track a tap
      ;; starting from EVENT. If EVENT is not a `touchscreen-begin'
      ;; event, return t."
      ;;
      ;; Every event here is not a touch event, so the answer is t and
      ;; the timer/context-menu machinery is not carried.
      ;;--------------------------------------------------------------
      #t)

    ;;--------------------------------------------------------------
    ;; The commands
    ;;--------------------------------------------------------------

    (define-command (tab-line-hscroll-right arg event)
      "Scroll the tab line ARG positions to the right.
Interactively, ARG is the prefix numeric argument and defaults to 1."
      (interactive (list (and (current-prefix-arg)
                              (uarg->integer 1 (current-prefix-arg)))
                         (*last-read-event*)))
      (when (tab-line-track-tap event)
        (let ((window (posn-window (tab-line-event-start event))))
          (tab-line-hscroll (or arg 1) window)
          (force-mode-line-update window))))

    (define-command (tab-line-hscroll-left arg event)
      "Scroll the tab line ARG positions to the left.
Interactively, ARG is the prefix numeric argument and defaults to 1."
      (interactive (list (and (current-prefix-arg)
                              (uarg->integer 1 (current-prefix-arg)))
                         (*last-read-event*)))
      (when (tab-line-track-tap event)
        (let ((window (posn-window (tab-line-event-start event))))
          (tab-line-hscroll (- (or arg 1)) window)
          (force-mode-line-update window))))

    (define-command (tab-line-new-tab event)
      "Add a new tab to the selected-window's tab line.
This command is usually invoked by clicking on the plus-shaped button
on the tab line.  Switching to another buffer also adds a new tab
corresponding to the new buffer shown in the window."
      (interactive (list (*last-read-event*)))
      (when (tab-line-track-tap event)
        (if (procedure? (*tab-line-new-tab-choice*))
            ((*tab-line-new-tab-choice*))
            ;; "`(let ((tab-line-tabs-buffer-groups
            ;; mouse-buffer-menu-mode-groups)) ...)'" - the buffers menu
            ;; groups by the same table the tab line does.
            (parameterize ((*tab-line-tabs-buffer-groups*
                            *mouse-buffer-menu-mode-groups*))
              (if (and (pair? event)
                       (display-popup-menus-p)
                       (not *tty-menu-open-use-tmm*))
                  (mouse-buffer-menu event) ; "like (buffer-menu-open)"
                  ;; "tty menu doesn't support mouse clicks, so use tmm" -
                  ;; and `tmm-prompt` is not ported; see the header.
                  (error "tab-line-new-tab: tmm-prompt is not ported"))))))

    (define-command (tab-line-select-tab event)
      "Switch to the buffer specified by the tab on which you click.
This command maintains the original order of prev/next buffers.
So, for example, switching to a previous tab is equivalent to
using the `previous-buffer' command."
      (interactive (list (*last-read-event*)))
      (when (tab-line-track-tap event)
        (let* ((posnp (tab-line-event-start event))
               (string (car (posn-string posnp)))
               (tab (and string (tab-line--get-tab-property 'tab string)))
               (buffer (if (bufferp tab) tab (alist-get 'buffer tab))))
          (if buffer
              (tab-line-select-tab-buffer buffer (posn-window posnp))
              (let ((select (alist-get 'select tab)))
                (when (procedure? select)
                  (with-selected-window
                      (posn-window posnp)
                    (select)
                    (force-mode-line-update))))))))

    (define (tab-line-select-tab-buffer buffer . args)
      ;; GNU Emacs's `tab-line-select-tab-buffer` (`:1006`).
      ;;--------------------------------------------------------------
      (let ((window (if (pair? args) (car args) (selected-window))))
        (if (eq? (*tab-line-tabs-function*) tab-line-tabs-window-buffers)
            (let* ((window-buffer (window-buffer window))
                   (next-buffers (seq-remove (lambda (b) (eq? b window-buffer))
                                             (window-next-buffers window)))
                   (prev-buffers (seq-remove (lambda (b) (eq? b window-buffer))
                                             (map car (window-prev-buffers window))))
                   ;; "Remove next-buffers from prev-buffers"
                   (prev-buffers (seq-difference prev-buffers next-buffers)))
              (cond
               ((memq buffer next-buffers)
                (do ((i 0 (+ i 1))
                     (n (+ 1 (seq-position next-buffers buffer))))
                    ((>= i n) #f)
                  (switch-to-next-buffer window)))
               ((memq buffer prev-buffers)
                (do ((i 0 (+ i 1))
                     (n (+ 1 (seq-position prev-buffers buffer))))
                    ((>= i n) #f)
                  (switch-to-prev-buffer window)))))
            (with-selected-window
                window
              (switch-to-buffer buffer)))))

    (define-command (tab-line-switch-to-prev-tab event arg)
      "Switch to the ARGth previous tab's buffer.
When `tab-line-tabs-function' is `tab-line-tabs-window-buffers',
its effect is the same as using the `previous-buffer' command."
      (interactive (list (*last-read-event*)
                         (uarg->integer 1 (current-prefix-arg))))
      (with-selected-window
          (posn-window (tab-line-event-start event))
        (if (eq? (*tab-line-tabs-function*) tab-line-tabs-window-buffers)
            (previous-buffer arg #t)
            (let* ((buffers (seq-keep
                             (lambda (tab)
                               (or (and (bufferp tab) tab)
                                   (alist-get 'buffer tab)))
                             ((*tab-line-tabs-function*))))
                   (old-pos (seq-position buffers (current-buffer)))
                   (new-pos (and old-pos (- old-pos (or arg 1))))
                   (new-pos (and new-pos
                                 (if (*tab-line-switch-cycling*)
                                     (modulo new-pos (length buffers))
                                     (max new-pos 0))))
                   (buffer (and new-pos (list-ref buffers new-pos))))
              (when (bufferp buffer)
                (switch-to-buffer buffer))))))

    (define-command (tab-line-switch-to-next-tab event arg)
      "Switch to the next ARGth tab's buffer.
When `tab-line-tabs-function' is `tab-line-tabs-window-buffers',
its effect is the same as using the `next-buffer' command."
      (interactive (list (*last-read-event*)
                         (uarg->integer 1 (current-prefix-arg))))
      (with-selected-window
          (posn-window (tab-line-event-start event))
        (if (eq? (*tab-line-tabs-function*) tab-line-tabs-window-buffers)
            (next-buffer arg #t)
            (let* ((buffers (seq-keep
                             (lambda (tab)
                               (or (and (bufferp tab) tab)
                                   (alist-get 'buffer tab)))
                             ((*tab-line-tabs-function*))))
                   (old-pos (seq-position buffers (current-buffer)))
                   (new-pos (and old-pos (+ old-pos (or arg 1))))
                   (new-pos (and new-pos
                                 (if (*tab-line-switch-cycling*)
                                     (modulo new-pos (length buffers))
                                     (min new-pos (- (length buffers) 1)))))
                   (buffer (and new-pos (list-ref buffers new-pos))))
              (when (bufferp buffer)
                (switch-to-buffer buffer))))))

    (define-command (tab-line-mouse-move-tab event)
      "Move a tab to a different position on the tab line using mouse.
This command should be bound to a drag event."
      (interactive (list (*last-read-event*)))
      ;; GNU Emacs's `tab-line-mouse-move-tab` (`:1098`).
      ;;
      ;; `cl-pushnew` on `(nthcdr pos2 buffers)` inserts at POS2, which
      ;; is what the `append` does here.
      ;;--------------------------------------------------------------
      (when (eq? (*tab-line-tabs-function*)
                 tab-line-tabs-fixed-window-buffers)
        (let* ((posnp1 (tab-line-event-start event))
               (posnp2 (event-end event))
               (string1 (car (posn-string posnp1)))
               (string2 (car (posn-string posnp2)))
               (buffer1 (and string1 (tab-line--get-tab-property 'tab string1)))
               (buffer2 (and string2 (tab-line--get-tab-property 'tab string2)))
               (window1 (posn-window posnp1))
               (window2 (posn-window posnp2))
               (buffers (window-parameter window1 'tab-line-buffers))
               (pos2 (and buffer2 (seq-position buffers buffer2))))
          (when (and (eq? window1 window2) buffer1 pos2)
            (set! buffers (delq buffer1 buffers))
            (set! buffers (append (seq-take buffers pos2)
                                  (list buffer1)
                                  (seq-drop buffers pos2)))
            (set-window-parameter window1 'tab-line-buffers buffers)
            (set-window-parameter window1 'tab-line-cache #f)
            (with-selected-window
                window1
              (force-mode-line-update))))))

    (define-command (tab-line-move-tab-forward arg)
      "Move a tab to a different position on the tab line.
ARG specifies the number of positions to move."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; GNU Emacs's `tab-line-move-tab-forward` (`:1127`).
      ;;--------------------------------------------------------------
      (when (eq? (*tab-line-tabs-function*)
                 tab-line-tabs-fixed-window-buffers)
        (let* ((window (selected-window))
               (buffers (window-parameter window 'tab-line-buffers))
               (buffer (current-buffer))
               (pos (seq-position buffers buffer))
               (len (length buffers))
               (new-pos (and pos (+ pos (or arg 1)))))
          (when (and pos (> len 1))
            (set! new-pos (if (*tab-line-switch-cycling*)
                              (modulo new-pos len)
                              (max 0 (min new-pos (- len 1)))))
            (set! buffers (delq buffer buffers))
            (set! buffers (append (seq-take buffers new-pos)
                                  (list buffer)
                                  (seq-drop buffers new-pos)))
            (set-window-parameter window 'tab-line-buffers buffers)
            (set-window-parameter window 'tab-line-cache #f)
            (force-mode-line-update)))))

    (define-command (tab-line-move-tab-backward arg)
      "Move a tab to a different position on the tab line.
ARG specifies the number of positions to move."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; GNU Emacs's `tab-line-move-tab-backward` (`:1161`).
      ;;--------------------------------------------------------------
      (tab-line-move-tab-forward (- (or arg 1))))

    (define (tab-line--current-tab)
      ;; GNU Emacs's `tab-line--current-tab` (`:1183`): "Return the
      ;; current tab in the tab line."
      ;;--------------------------------------------------------------
      (seq-find (lambda (tab)
                  (eq? (if (bufferp tab) tab (alist-get 'buffer tab))
                       (current-buffer)))
                ((*tab-line-tabs-function*))))

    (define-command (tab-line-close-tab event)
      "Close the selected tab.
This command is usually invoked by clicking on the close button on the
right side of the tab.  This command buries the buffer, so it goes out of
sight of the tab line."
      (interactive (list (*last-read-event*)))
      (when (tab-line-track-tap event)
        (let* ((posnp (tab-line-event-start event))
               (string (and (pair? event) (car (posn-string posnp))))
               (tab (if (pair? event)
                        (and string
                             (tab-line--get-tab-property 'tab string))
                        (tab-line--current-tab)))
               (buffer (if (bufferp tab) tab (alist-get 'buffer tab)))
               (close-function (if (bufferp tab) #f (alist-get 'close tab))))
          (with-selected-window
              (posn-window posnp)
            (cond
             ((procedure? close-function)
              (close-function))
             ((eq? (*tab-line-close-tab-function*) kill-buffer)
              (kill-buffer buffer))
             ((eq? (*tab-line-close-tab-function*) bury-buffer)
              (if (eq? buffer (current-buffer))
                  (bury-buffer)
                  (begin
                    (set-window-prev-buffers
                     (selected-window)
                     (assq-delete-all buffer (window-prev-buffers
                                              (selected-window))))
                    (set-window-next-buffers
                     (selected-window)
                     (delq buffer (window-next-buffers
                                   (selected-window)))))))
             ((procedure? (*tab-line-close-tab-function*))
              ((*tab-line-close-tab-function*) tab)))
            (force-mode-line-update)))))

    (define-command (tab-line-close-other-tabs event)
      "Close all tabs on the selected window, except the tab on EVENT."
      (interactive (list (*last-read-event*)))
      (when (tab-line-track-tap event)
        (let* ((posnp (tab-line-event-start event))
               (string (and (pair? event) (car (posn-string posnp))))
               (keep-tab (if (pair? event)
                             (and string
                                  (tab-line--get-tab-property 'tab string))
                             (tab-line--current-tab))))
          (with-selected-window
              (posn-window posnp)
            (for-each
             (lambda (tab)
               (let ((buffer (if (bufferp tab) tab (alist-get 'buffer tab)))
                     (close-function
                      (if (bufferp tab) #f (alist-get 'close tab))))
                 (cond
                  ((procedure? close-function)
                   (close-function))
                  ((eq? (*tab-line-close-tab-function*) kill-buffer)
                   (kill-buffer buffer))
                  ((eq? (*tab-line-close-tab-function*) bury-buffer)
                   (if (eq? buffer (current-buffer))
                       (bury-buffer)
                       (begin
                         (set-window-prev-buffers
                          (selected-window)
                          (assq-delete-all buffer (window-prev-buffers
                                                   (selected-window))))
                         (set-window-next-buffers
                          (selected-window)
                          (delq buffer (window-next-buffers
                                        (selected-window)))))))
                  ((procedure? (*tab-line-close-tab-function*))
                   ((*tab-line-close-tab-function*) tab)))))
             (delq keep-tab ((*tab-line-tabs-function*))))
            (force-mode-line-update)))))

    ;;--------------------------------------------------------------
    ;; The keys the mode adds to C-x
    ;;--------------------------------------------------------------

    (define-command (tab-line-tab-context-menu event)
      "Pop up the context menu for a tab-line tab."
      (interactive (list (*last-read-event*)))
      ;; GNU Emacs's `tab-line-tab-context-menu` (`tab-line.el:1231`):
      ;; two items, "Close" and "Close other tabs". `'(propertize
      ;; "Context Menu" 'hide t)' is the menu's name, which `hide` keeps
      ;; off a tty menu's title row.
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap (propertize "Context Menu" 'hide #t))))
        (define-key-after menu (vector 'close)
          '(menu-item "Close" tab-line-close-tab :help "Close the tab"))
        (define-key-after menu (vector 'close-other)
          '(menu-item "Close other tabs" tab-line-close-other-tabs
                      :help "Close all other tabs"))
        (popup-menu menu event #f #f)))

    (define-command (tab-line-context-menu event)
      "Pop up the context menu for the tab line."
      (interactive (list (*last-read-event*)))
      ;; GNU Emacs's `tab-line-context-menu` (`tab-line.el:1241`).
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap (propertize "Context Menu" 'hide #t))))
        (define-key-after menu (vector 'close)
          '(menu-item "New tab" tab-line-new-tab :help "Create a new tab"))
        (popup-menu menu event #f #f)))

    (define (tab-line--define-keys)
      ;; GNU Emacs's `tab-line--define-keys` (`:1322`): "Install key
      ;; bindings to switch between tabs if so configured."
      ;;
      ;; Emacs asks `ctl-x-map` for each key; this tree has no such map
      ;; and binds the whole `C-x <left>` sequence in the global map, so
      ;; the question is asked of that map and the same sequence.
      ;;--------------------------------------------------------------
      (when (*tab-line-define-keys*)
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x <left>"))
                   previous-buffer)
          (define-key *default-keymap* (kbd "C-x <left>")
            tab-line-switch-to-prev-tab))
        (unless (keymap-lookup *default-keymap* (kbd "C-x M-<left>"))
          (define-key *default-keymap* (kbd "C-x M-<left>")
            tab-line-move-tab-backward))
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x <right>"))
                   next-buffer)
          (define-key *default-keymap* (kbd "C-x <right>")
            tab-line-switch-to-next-tab))
        (unless (keymap-lookup *default-keymap* (kbd "C-x M-<right>"))
          (define-key *default-keymap* (kbd "C-x M-<right>")
            tab-line-move-tab-forward))))

    (define (tab-line--undefine-keys)
      ;; GNU Emacs's `tab-line--undefine-keys` (`:1339`).
      ;;--------------------------------------------------------------
      (when (*tab-line-define-keys*)
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x <left>"))
                   tab-line-switch-to-prev-tab)
          (define-key *default-keymap* (kbd "C-x <left>") previous-buffer))
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x M-<left>"))
                   tab-line-move-tab-backward)
          (define-key *default-keymap* (kbd "C-x M-<left>") #f))
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x <right>"))
                   tab-line-switch-to-next-tab)
          (define-key *default-keymap* (kbd "C-x <right>") next-buffer))
        (when (eq? (keymap-lookup *default-keymap* (kbd "C-x M-<right>"))
                   tab-line-move-tab-forward)
          (define-key *default-keymap* (kbd "C-x M-<right>") #f))))

    ;;--------------------------------------------------------------
    ;; The variables that name a function - see the ordering note
    ;;--------------------------------------------------------------

    (define-custom *tab-line-tab-face-functions*
      (list tab-line-tab-face-modified tab-line-tab-face-special)
      "Functions called to modify tab faces.
Each function is called with five arguments: the tab, a list of
all tabs, the face returned by the previously called modifier,
whether the tab is a buffer (when nil, the buffer is extracted from
the association list using the key `buffer'), and whether the tab
is selected."
      :type '(repeat function)
      :group 'tab-line)

    (define tab-line-new-button-functions
      (list tab-line-tabs-window-buffers tab-line-tabs-fixed-window-buffers))
    ;; ^ `(defvar tab-line-new-button-functions '(tab-line-tabs-window-buffers
    ;; tab-line-tabs-fixed-window-buffers) ...)' - the tab functions that
    ;; get a "+" button.

    (define-custom *tab-line-tab-name-function* tab-line-tab-name-buffer
      "Function to get a tab name.
The function is called with one or two arguments: the buffer or
another object whose tab's name is requested, and, optionally,
the list of all tabs."
      :type '(choice (const :tag "Buffer name" tab-line-tab-name-buffer)
                     (function :tag "Function"))
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tabs-function* tab-line-tabs-fixed-window-buffers
      "Function to get a list of tabs to display in the tab line.
This function should return either a list of buffers whose names will
be displayed, or just a list of strings to display in the tab line."
      :type '(choice (const :tag "Window buffers"
                            tab-line-tabs-window-buffers)
                     (const :tag "Window buffers with fixed order"
                            tab-line-tabs-fixed-window-buffers)
                     (const :tag "Same mode buffers"
                            tab-line-tabs-mode-buffers)
                     (const :tag "Grouped buffers"
                            tab-line-tabs-buffer-groups)
                     (function :tag "Function"))
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tabs-buffer-group-function*
      tab-line-tabs-buffer-group-by-mode
      "Function to add a buffer to the appropriate group of tabs.
Takes a buffer as argument and should return a group name as a string.
If the return value is nil, the buffer has no group."
      :type '(choice (const :tag "Group by mode"
                            tab-line-tabs-buffer-group-by-mode)
                     (function :tag "Custom function"))
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tabs-buffer-group-sort-function*
      tab-line-tabs-buffer-group-sort-by-name
      "Function to sort buffers in a group."
      :type '(choice (const :tag "Don't sort" #f)
                     (const :tag "Sort by name alphabetically"
                            tab-line-tabs-buffer-group-sort-by-name)
                     (function :tag "Custom function"))
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tabs-buffer-groups-sort-function* string<
      "Function to sort group names."
      :type '(choice (const :tag "Don't sort" #f)
                     (const :tag "Sort alphabetically" string<)
                     (function :tag "Custom function"))
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tab-name-format-function*
      tab-line-tab-name-format-default
      "Function to format a tab name.
The function will be called with two arguments: the tab whose name to
format, and the list of all the tabs."
      :type 'function
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (tab-line-force-update #t))
      :group 'tab-line)

    (define-custom *tab-line-tabs-window-buffers-filter-function* identity
      "Filter which buffers should be displayed in the tab line."
      :type '(choice function
                     (const :tag "Show all buffers" identity)
                     (const :tag "Omit excluded buffers"
                            tab-line-tabs-non-excluded))
      :group 'tab-line)

    (define-custom *tab-line-define-keys* #t
      "Define specific tab-line key bindings.
If t, the default, key mappings for switching and moving tabs
are defined.  If nil, do not define any key mappings."
      :type 'boolean
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             (tab-line--undefine-keys)
             ((get symbol 'custom-writer) symbol value)
             ;; "Enable the new keybindings"
             (tab-line--define-keys))
      :group 'tab-line)

    ;;--------------------------------------------------------------
    ;; The buttons and the keymaps
    ;;--------------------------------------------------------------

    ;; The maps are made before the buttons, because a button carries its
    ;; map in a text property and a keymap is a value here, not a symbol.
    ;; "`(add-to-list 'window-persistent-parameters '(tab-line-buffers . t))'"
    ;; - `window-state-get` keeps the tab order when it saves a window.
    (add-to-list *window-persistent-parameters* '(tab-line-buffers . t))

    (define tab-line-tab-map (make-sparse-keymap))
    (define tab-line-add-map (make-sparse-keymap))
    (define tab-line-tab-close-map (make-sparse-keymap))
    (define tab-line-left-map (make-sparse-keymap))
    (define tab-line-right-map (make-sparse-keymap))
    (define tab-line-mode-map (make-sparse-keymap))
    (define tab-line-switch-repeat-map (make-sparse-keymap))

    (define-icon tab-line-new #f
      `((image "symbols/plus_16.svg" "tabs/new.xpm"
               :face shadow
               :height (1 . em)
               :margin (2 . 0)
               :ascent center)
        (text " + "))
      "Icon for creating a new tab."
      :version "30.1"
      :help-echo "New tab")

    (define tab-line-new-button
      (propertize (icon-string 'tab-line-new)
                  'rear-nonsticky #f
                  'keymap tab-line-add-map
                  'mouse-face 'tab-line-highlight
                  'help-echo "Click to add tab"))
    ;; ^ `(defvar tab-line-new-button (propertize ...))'. The `keymap`
    ;; property holds the map itself, as it does in Emacs; a map is an
    ;; object here, not a symbol.

    (define-icon tab-line-close #f
      `((image "symbols/cross_16.svg" "tabs/close.xpm"
               :face shadow
               :height (1 . em)
               :margin (2 . 0)
               :ascent center)
        (text " x"))
      "Icon for closing the clicked tab."
      :version "30.1"
      :help-echo "Click to close tab")

    (define tab-line-close-button
      (propertize (icon-string 'tab-line-close)
                  ;; "important to not break auto-scroll"
                  'rear-nonsticky #f
                  'keymap tab-line-tab-close-map
                  'mouse-face 'tab-line-close-highlight
                  'help-echo "Click to close tab"))

    (define-icon tab-line-close-modified #f
      `((image "symbols/dot_medium_16.svg" "tabs/close-modified.xpm"
               :face shadow
               :height (1 . em)
               :margin (2 . 0)
               :ascent center)
        (symbol ,(concat " " (string (integer->char #x2022)))) ; bullet
        (text " *"))
      "Icon for closing the clicked tab when tab is modified."
      :version "31.1"
      :help-echo "Click to close tab")

    (define tab-line-close-modified-button
      (propertize (icon-string 'tab-line-close-modified)
                  'rear-nonsticky #f
                  'keymap tab-line-tab-close-map
                  'mouse-face 'tab-line-close-highlight
                  'help-echo "Click to close tab"))

    (define-icon tab-line-left #f
      `((image "symbols/chevron_left_16.svg" "tabs/left-arrow.xpm"
               :face shadow
               :height (1 . em)
               :margin (2 . 0)
               :ascent center)
        (text " <"))
      "Icon for scrolling horizontally to the left."
      :version "30.1")

    (define tab-line-left-button
      (propertize (icon-string 'tab-line-left)
                  'rear-nonsticky #f
                  'keymap tab-line-left-map
                  'mouse-face 'tab-line-highlight
                  'help-echo "Click to scroll left"))

    (define-icon tab-line-right #f
      `((image "symbols/chevron_right_16.svg" "tabs/right-arrow.xpm"
               :face shadow
               :height (1 . em)
               :margin (2 . 0)
               :ascent center)
        (text "> "))
      "Icon for scrolling horizontally to the right."
      :version "30.1")

    (define tab-line-right-button
      (propertize (icon-string 'tab-line-right)
                  'rear-nonsticky #f
                  'keymap tab-line-right-map
                  'mouse-face 'tab-line-highlight
                  'help-echo "Click to scroll right"))

    (define tab-line-separator #f)
    ;; ^ `(defvar tab-line-separator nil "String that delimits tabs.")'

    (define-key tab-line-tab-map (kbd "<tab-line> <down-mouse-1>")
      tab-line-select-tab)
    (define-key tab-line-tab-map (kbd "<tab-line> <mouse-2>")
      tab-line-close-tab)
    (define-key tab-line-tab-map (kbd "<tab-line> <down-mouse-3>")
      tab-line-tab-context-menu)
    (define-key tab-line-tab-map (kbd "<tab-line> <touchscreen-begin>")
      tab-line-select-tab)
    (define-key tab-line-tab-map (kbd "RET") tab-line-select-tab)

    (define-key tab-line-add-map (kbd "<tab-line> <down-mouse-1>")
      tab-line-new-tab)
    (define-key tab-line-add-map (kbd "<tab-line> <down-mouse-2>")
      tab-line-new-tab)
    (define-key tab-line-add-map (kbd "<tab-line> <touchscreen-begin>")
      tab-line-new-tab)
    (define-key tab-line-add-map (kbd "RET") tab-line-new-tab)

    (define-key tab-line-tab-close-map (kbd "<tab-line> <mouse-1>")
      tab-line-close-tab)
    (define-key tab-line-tab-close-map (kbd "<tab-line> <mouse-2>")
      tab-line-close-tab)
    (define-key tab-line-tab-close-map (kbd "<tab-line> <touchscreen-begin>")
      tab-line-close-tab)

    (define-key tab-line-left-map (kbd "<tab-line> <down-mouse-1>")
      tab-line-hscroll-left)
    (define-key tab-line-left-map (kbd "<tab-line> <down-mouse-2>")
      tab-line-hscroll-left)
    (define-key tab-line-left-map (kbd "<tab-line> <touchscreen-begin>")
      tab-line-hscroll-left)
    (define-key tab-line-left-map (kbd "RET") tab-line-new-tab)

    (define-key tab-line-right-map (kbd "<tab-line> <down-mouse-1>")
      tab-line-hscroll-right)
    (define-key tab-line-right-map (kbd "<tab-line> <down-mouse-2>")
      tab-line-hscroll-right)
    (define-key tab-line-right-map (kbd "<tab-line> <touchscreen-begin>")
      tab-line-hscroll-right)
    (define-key tab-line-right-map (kbd "RET") tab-line-new-tab)

    (define-key tab-line-switch-repeat-map (kbd "<left>")
      tab-line-switch-to-prev-tab)
    (define-key tab-line-switch-repeat-map (kbd "M-<left>")
      tab-line-move-tab-backward)
    (define-key tab-line-switch-repeat-map (kbd "<right>")
      tab-line-switch-to-next-tab)
    (define-key tab-line-switch-repeat-map (kbd "M-<right>")
      tab-line-move-tab-forward)

    ;;--------------------------------------------------------------
    ;; The mode
    ;;--------------------------------------------------------------

    (define-minor-mode tab-line-mode
      "Toggle display of tab line in the windows displaying the current buffer.

When this mode is enabled, each window displays a tab line on its
top screen line.  The tab line is a row of tabs -- buttons which
you can click to have the window display the buffer whose name is
shown on the button.  Clicking on the \"x\" icon of the button
removes the button (but does not kill the corresponding buffer).
In addition, the tab line shows a \"+\" button which adds a new
button, so you could have one more buffer shown on the tab line."
      :lighter #f
      ;; "`(let ((default-value '(:eval (tab-line-format))))'": this
      ;; tree's `:eval` holds the *procedure to call*, not a form to
      ;; evaluate (`xdisp.scm`'s `format-mode-line`), so the default is
      ;; the procedure itself. Named in the header.
      (let ((default-value (list ':eval tab-line-format)))
        ;; "Preserve the existing tab-line set outside of this mode"
        (let ((current (buffer-local-value (current-buffer)
                                           'tab-line-format #f)))
          (if (or (not current) (equal? current default-value))
              (if (tab-line-mode-variable)
                  (set-buffer-local-value! (current-buffer)
                                           'tab-line-format default-value)
                  (set-buffer-local-value! (current-buffer)
                                           'tab-line-format #f))
              (message "tab-line-format set outside of tab-line-mode, currently `~a'"
                       current)))))

    (define (tab-line-mode--turn-on)
      ;; GNU Emacs's `tab-line-mode--turn-on` (`:1408`): "Turn on
      ;; `tab-line-mode' in all pertinent buffers."
      ;;--------------------------------------------------------------
      (unless (or (minibufferp)
                  (string-match-p "\\` " (buffer-name))
                  (memq (major-mode) (*tab-line-exclude-modes*))
                  (buffer-match-p (*tab-line-exclude-buffers*)
                                  (buffer-name))
                  (get (major-mode) 'tab-line-exclude)
                  (buffer-local-value (current-buffer) 'tab-line-exclude #f))
        (tab-line-mode 1)))

    ;; `tab-line.el:1447`'s own `global-set-key`s - the line's context
    ;; menu, dragging a tab to move it, and the wheel. The wheel events
    ;; are bound for fidelity: no front end here produces one yet
    ;; (`keyboard.scm` names them the same gap `mouse-movement` had).
    (define-key *default-keymap* (kbd "<tab-line> <down-mouse-3>")
      tab-line-context-menu)
    (define-key *default-keymap* (kbd "<tab-line> <drag-mouse-1>")
      tab-line-mouse-move-tab)
    (define-key *default-keymap* (kbd "<tab-line> <mouse-4>")
      tab-line-hscroll-left)
    (define-key *default-keymap* (kbd "<tab-line> <mouse-5>")
      tab-line-hscroll-right)
    (define-key *default-keymap* (kbd "<tab-line> <wheel-up>")
      tab-line-hscroll-left)
    (define-key *default-keymap* (kbd "<tab-line> <wheel-down>")
      tab-line-hscroll-right)
    (define-key *default-keymap* (kbd "<tab-line> <wheel-left>")
      tab-line-hscroll-left)
    (define-key *default-keymap* (kbd "<tab-line> <wheel-right>")
      tab-line-hscroll-right)
    (define-key *default-keymap* (kbd "<tab-line> <S-mouse-4>")
      tab-line-switch-to-prev-tab)
    (define-key *default-keymap* (kbd "<tab-line> <S-mouse-5>")
      tab-line-switch-to-next-tab)
    (define-key *default-keymap* (kbd "<tab-line> <S-wheel-up>")
      tab-line-switch-to-prev-tab)
    (define-key *default-keymap* (kbd "<tab-line> <S-wheel-down>")
      tab-line-switch-to-next-tab)
    (define-key *default-keymap* (kbd "<tab-line> <S-wheel-left>")
      tab-line-switch-to-prev-tab)
    (define-key *default-keymap* (kbd "<tab-line> <S-wheel-right>")
      tab-line-switch-to-next-tab)

    (define-globalized-minor-mode global-tab-line-mode
      tab-line-mode tab-line-mode--turn-on
      :group 'tab-line
      :version "27.1"
      (if (global-tab-line-mode-variable)
          (tab-line--define-keys)
          (tab-line--undefine-keys)))
    ))