(define-library (schemacs editor menu-bar)
  ;; This library mirrors GNU Emacs's `lisp/menu-bar.el' - the bars
  ;; themselves: the `[menu-bar]' keymap every active map contributes to,
  ;; the standard menus, and the commands they are made of.
  ;;
  ;; **What is here is what this tree can back.** `menu-bar.el' is three
  ;; thousand lines and most of its items name commands this editor does
  ;; not have yet; an item that names one would be a menu entry that
  ;; signals when clicked. Each omission is listed below with the thing
  ;; it is waiting for, which is the accounting `AGENTS.md` asks for, and
  ;; the entries that are here are the C's own - same keys in the same
  ;; order, same labels, same `:help` strings - so that adding one later
  ;; is a line, not a rewrite.
  ;;
  ;; **Not here yet, and what each waits for:**
  ;;
  ;;   File: Print (ps-print), Close Tab / New Tab (tab-bar), Undelete
  ;;     Frame (frame.c's deleted-frame ring), New Frame on Monitor /
  ;;     Display Server (frame parameters, the display server),
  ;;     Recover Crashed Session (auto-save), Open ... In Project
  ;;     (project.el), Open File... as `menu-find-file-existing'
  ;;     (`find-file-existing' is `(find-file FILENAME t)', which this
  ;;     tree's `find-file' has no second argument for yet - the entry
  ;;     uses `find-file').
  ;;
  ;;   Edit: Fill (fill.el), Bookmarks (bookmark.el), Go To
  ;;     (menu-bar-goto-menu: imenu, tags), Search (menu-bar-search-menu:
  ;;     the nonincremental search commands and the search ring),
  ;;     Paste from Kill Menu (`yank-menu', which needs a menu built from
  ;;     a list at click time), Clear (`delete-active-region').
  ;;
  ;;   Options, Buffers, Tools, Help: not here at all. Buffers needs
  ;;     `frame-or-buffer-changed-p' (and `next-buffer'/`previous-buffer',
  ;;     which are window.c's buffer history) before its menu can be
  ;;     rebuilt by a hook; Options needs `menu-bar-make-toggle' and the
  ;;     `:button (:toggle . VAR)' machinery; Help names mostly commands
  ;;     from help.el.
  ;;
  ;; `menu-bar-mode' is not here either: it sets the frame parameter
  ;; `menu-bar-lines' on every frame, and this tree has no frame
  ;; parameters. The bar is therefore always on, showing whatever
  ;; `[menu-bar]' holds, which is what a frame with `menu-bar-lines' 1
  ;; shows.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    ;; The key sequence a binding is written with, and the map it is
    ;; written into.
    (only (schemacs editor keymap)
          make-sparse-keymap define-key keymap-lookup *default-keymap*
          keymap-bindings %set!keymap-order! keymap-type? map-keymap)
    ;; `substitute-key-definition` builds `tty-menu-navigation-map`, and
    ;; `event-end` is `popup-menu-normalize-position`'s.
    (only (schemacs editor subr)
          substitute-key-definition event-end posn-x-y posn-window)
    ;; `menu-bar-open` asks which kind of display the frame is on, which
    ;; is what decides whether the toolkit opens the bar.
    (only (schemacs editor dispnew) window-system-display?)
    ;; `popup-menu` is where a menu selection becomes a command.
    (only (schemacs editor command)
          run-command command-record-of command-record-named
          command-interactive-spec command-type?)
    ;; The Buffers menu rebuilds its keymap in place, so the clearing is
    ;; here: `hash-clear!` is Guile's, and the order list is the keymap's
    ;; own export.
    (only (guile) format filter hash-clear! sort)
    ;; the debug guard's report, and `display` (not `(scheme base)`'s)
    (only (scheme write) display)
    (only (schemacs editor character) kbd)
    ;; `menu-bar-final-items` is `keyboard.c`'s variable, which
    ;; `menu-bar.el` sets (`:46`).
    (only (schemacs editor keyboard)
          *menu-bar-final-items* abort-recursive-edit key-binding
          lookup-keymaps)
    (only (schemacs editor seq) seq-position)
    ;; `last-command-event` is `keyboard.c`'s variable by the C's file
    ;; list, and `command.scm`'s by this tree's import graph (the command
    ;; loop sets it, and the loop's library is above both).
    (only (schemacs editor command) *last-command-event* define-command)
    ;; The Edit menu's commands.
    (only (schemacs editor simple)
          kill-region kill-ring-save yank undo undo-redo mark-whole-buffer
          ;; The commands `tty-menu-navigation-map` substitutes for: the
          ;; map takes *their* keys and re-binds them to the `tty-menu-*`
          ;; symbols `term.c` interprets.
          keyboard-quit next-line previous-line insert-newline
          right-char left-char)
    (only (schemacs editor cmds) forward-char backward-char)
    (only (schemacs editor isearch) isearch-forward isearch-backward)
    (only (schemacs editor replace)
          query-replace query-replace-regexp replace-string)
    ;; "Execute Command" is callint.c's prompt, and the prompt is the
    ;; minibuffer's.
    (only (schemacs editor minibuffer) execute-extended-command)
    ;; The File menu's commands. `kill-buffer` is the *command* (the
    ;; mechanism is `%kill-buffer`), which is what a menu item runs.
    (only (schemacs editor files)
          find-file insert-file save-buffer write-file revert-buffer
          kill-buffer save-buffers-kill-terminal)
    (only (schemacs editor window)
          split-window-below split-window-right delete-other-windows
          switch-to-buffer next-buffer previous-buffer)
    ;; "List All Buffers" is `buff-menu.el`'s, which `menu-bar.el` names.
    (only (schemacs editor buff-menu) list-buffers)
    (only (schemacs editor fileio) file-name-directory-part)
    (only (schemacs editor frame) make-frame-command delete-frame
          ;; `posnp`'s windowp test - subr.el's function, placed below
          ;; because windowp lives in `frame.scm`.
          window-type?
          *echo-area-buffer*
          ;; `tty-menu-open-use-tmm` is this file's in Emacs; it lives in
          ;; `frame.scm` so that `display-popup-menus-p` can read it, and
          ;; is re-exported below.
          *tty-menu-open-use-tmm*)
    ;; `popup-menu`'s "we were given a map for the menu-bar item" lookup
    ;; reads the buffer's own map too.
    (only (schemacs editor buffer) buffer-local-keymap)
    ;; The menu itself - `x-popup-menu` (`menu.c:1433`).
    (only (schemacs editor menu) x-popup-menu)
    (only (schemacs editor dired) dired)
    ;; The predicates the `:enable` expressions read. They are evaluated
    ;; by `menu-item-eval-property` when the bar is built, in the
    ;; editor's own environment - so they are the *functions* this tree
    ;; spells Emacs's variables with: `mark-active` is `(mark-active)`,
    ;; and `buffer-read-only` is `(buffer-read-only? (current-buffer))`.
    (only (schemacs editor buffer)
          buffer-list buffer-local-value buffer-name current-buffer
          buffer-read-only? buffer-modified-p buffer-file-name)
    ;; The menu lists frames as well as buffers, which is what
    ;; `frame-or-buffer-changed-p` compares.
    (only (schemacs editor frame) frame-list frame-name)
    ;; The hook that rebuilds the Buffers menu, `xdisp.c`'s.
    (only (schemacs editor xdisp)
          *menu-bar-update-hook* menu-item-width posn-at-x-y
          redisplay-frames!)
    ;; `menu-bar-mode` sets the parameter on every frame, and rewrites
    ;; `default-frame-alist` when it is there.
    (only (schemacs editor frame)
          *frame-list* set-frame-parameter *default-frame-alist*
          selected-frame frame-live-p mouse-position %frame-menu-bar-lines
          frame-output
          frame-menu-bar-items frame-menu-bar-items-used)
    (only (schemacs editor command)
          current-prefix-arg called-interactively? uarg->integer)
    (only (schemacs editor subr) assq-delete-all)
    (only (schemacs editor marker) marker-position)
    ;; "Menu Bar mode disabled ..." - `message` is `editfns.c`'s.
    (only (schemacs editor editfns) message))

  (export
   menu-bar-separator
   menu-bar-file-menu menu-bar-edit-menu
   menu-bar-i-search-menu menu-bar-replace-menu
   kill-this-buffer kill-this-buffer-enabled-p
   delete-frame-enabled-p
   *menu-bar-close-window*
   menu-bar-mode *menu-bar-mode*
   ;; The Buffers menu and what it is built from.
   global-buffers-menu-map menu-bar-update-buffers
   frame-or-buffer-changed-p
   *buffers-menu-max-size* *buffers-menu-buffer-name-length*
   *buffers-menu-show-directories* *buffers-menu-show-status*
   ;; The terminal's menu machinery - `menu-bar.el:2690-3060`.
   *menu-bar-open-function*
   *tty-menu-open-use-tmm* *tty-menu--initial-menu-x*
   tty-menu-navigation-map *tty-menu-navigation-map*
   menu-bar-menu-at-x-y popup-menu popup-menu-normalize-position
   menu-bar-keymap
   menu-bar-open menu-bar-define-mouse-key)

  (begin

    ;;----------------------------------------------------------------
    ;; The bar's own keymap - `menu-bar.el:38-46`
    ;;----------------------------------------------------------------

    ;; "Don't clobber an existing menu-bar keymap, to preserve any menu-bar
    ;; key definitions made in loaddefs.el."
    (unless (keymap-lookup *default-keymap* 'menu-bar)
      (define-key *default-keymap* (kbd "<menu-bar>")
                  (make-sparse-keymap "menu-bar")))

    ;; "Force Help item to come last, after the major mode's own items."
    ;; The Help menu is not ported yet; the variable is still set to what
    ;; `menu-bar.el` sets, because it is `keyboard.c`'s and something else
    ;; reading the bar (a user's own Help menu) expects it.
    (set! *menu-bar-final-items* '(help-menu))

    (define menu-bar-separator
      ;; GNU Emacs's `(defconst menu-bar-separator '(menu-item "--"))'
      ;; (`menu-bar.el`): the item that draws as a separator line. A
      ;; bare `"--"` is *not* one - `parse_menu_item` refuses a binding
      ;; that is not a cons, so a string in a menu is skipped entirely.
      ;;--------------------------------------------------------------
      '(menu-item "--"))

    (define *menu-bar-close-window* (make-parameter #f))
    ;; ^ GNU Emacs's `menu-bar-close-window' (`menu-bar.el:83'), a
    ;; defcustom: "Whether or not to close the current window from the
    ;; menu bar." A parameter, because `kill-this-buffer` reads it. Its
    ;; Customize declaration is not carried yet - `define-custom` would
    ;; put it in a group, and the groups are not ported.

    ;;----------------------------------------------------------------
    ;; `kill-this-buffer` - `menu-bar.el`'s own command
    ;;----------------------------------------------------------------

    (define (delete-frame-enabled-p)
      ;; GNU Emacs's `delete-frame-enabled-p` (`menu-bar.el:2296`):
      ;; "Return non-nil if `delete-frame` should be enabled in the menu
      ;; bar." It counts the *visible* frames and wants more than one, so
      ;; the sole frame's Delete Frame item is greyed out rather than
      ;; signalling "Attempt to delete the sole visible or iconified
      ;; frame" when clicked.
      ;;
      ;; `frame-visible-p` is not ported - nothing here iconifies a frame,
      ;; so every live frame is visible and the count is the list's
      ;; length.
      ;;--------------------------------------------------------------
      (> (length (*frame-list*)) 1))

    (define (kill-this-buffer-enabled-p)
      ;; GNU Emacs's `kill-this-buffer-enabled-p`: enabled when there is a
      ;; buffer that may be killed, or when `menu-bar-close-window` says a
      ;; window may go.
      ;;
      ;; The C's first limb counts non-hidden buffers; the tree has no
      ;; hidden buffers (nothing here makes one), so "there is at least
      ;; one buffer" is the same test.
      ;;--------------------------------------------------------------
      (and (pair? (buffer-list))
           #t))

    (define-command (kill-this-buffer)
      "Kill the current buffer.
When called in the minibuffer, get out of the minibuffer
using `abort-recursive-edit'.

This command can be invoked only from a menu or a tool bar.  If you want
to invoke a similar command with `M-x', use `kill-current-buffer'."
      (interactive)
      ;; **The C's guard, ported as far as this tree's events go.** The
      ;; item's key is the symbol `kill-buffer`, and a menu selection
      ;; leaves that symbol as `last-command-event` - so a call from the
      ;; menu is told from a call typed at M-x by exactly the test Emacs
      ;; makes. The mouse and tool-bar limbs are not carried: this tree
      ;; has no tool bar, and the mouse test is for a click on a toolbar
      ;; icon.
      ;;--------------------------------------------------------------
      (let ((lce (*last-command-event*)))
        (if (eq? (if (pair? lce) (car lce) lce) 'kill-buffer)
            (if (*echo-area-buffer*)
                (abort-recursive-edit)
                (kill-buffer (current-buffer)))
            (error "This command must be called from a menu or a tool bar"))))

    ;;----------------------------------------------------------------
    ;; The File menu
    ;;----------------------------------------------------------------

    (define menu-bar-file-menu
      ;; GNU Emacs's `menu-bar-file-menu` (`menu-bar.el:90`), less the
      ;; entries this tree has no commands for - see the header. The
      ;; definition order is the C's, which is why the menu reads
      ;; backwards: `define-key` prepends, so the last item defined is
      ;; the first shown.
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap "File")))

        (define-key menu (kbd "<exit-emacs>")
          '(menu-item "Quit" save-buffers-kill-terminal
                      :help "Save unsaved buffers, then exit"))

        (define-key menu (kbd "<separator-exit>") menu-bar-separator)

        (define-key menu (kbd "<delete-this-frame>")
          '(menu-item "Delete Frame" delete-frame
                      :visible #t
                      :enable (delete-frame-enabled-p)
                      :help "Delete currently selected frame"))

        (define-key menu (kbd "<make-frame>")
          '(menu-item "New Frame" make-frame-command
                      :visible #t
                      :help "Open a new frame"))

        (define-key menu (kbd "<separator-frame>") menu-bar-separator)

        (define-key menu (kbd "<one-window>")
          '(menu-item "Remove Other Windows" delete-other-windows
                      :enable #t
                      :help "Make selected window fill whole frame"))

        (define-key menu (kbd "<new-window-on-right>")
          '(menu-item "New Window on Right" split-window-right
                      :help "Make new window on right of selected one"))

        (define-key menu (kbd "<new-window-below>")
          '(menu-item "New Window Below" split-window-below
                      :help "Make new window below selected one"))

        (define-key menu (kbd "<separator-window>") menu-bar-separator)

        ;; "Revert Buffer": Emacs's `:enable` is a disjunction over
        ;; `revert-buffer-function`, the visited file's modtime and its
        ;; writeability. The last of those is the one that matters for a
        ;; buffer that visits a file and has not been modified; the
        ;; others need `verify-visited-file-modtime`, which is not
        ;; ported. Enabled for every buffer, as Emacs enables it for a
        ;; buffer whose `revert-buffer-function` is not the default.
        (define-key menu (kbd "<revert-buffer>")
          '(menu-item "Revert Buffer" revert-buffer
                      :enable #t
                      :help "Re-read current buffer from its file"))

        (define-key menu (kbd "<write-file>")
          '(menu-item "Save As..." write-file
                      :help "Write current buffer to another file"))

        (define-key menu (kbd "<save-buffer>")
          '(menu-item "Save" save-buffer
                      :enable (and (buffer-modified-p (current-buffer))
                                   (buffer-file-name (current-buffer)))
                      :help "Save current buffer to its file"))

        (define-key menu (kbd "<separator-save>") menu-bar-separator)

        (define-key menu (kbd "<kill-buffer>")
          '(menu-item "Close" kill-this-buffer
                      :enable (kill-this-buffer-enabled-p)
                      :help "Discard (kill) current buffer"))

        (define-key menu (kbd "<insert-file>")
          '(menu-item "Insert File..." insert-file
                      :help "Insert another file into current buffer"))

        (define-key menu (kbd "<open-directory>")
          '(menu-item "Open Directory..." dired
                      :help "Read a directory, to operate on its files"))

        ;; "Open File..." is `menu-find-file-existing` in the C, which
        ;; reads a name with `find-file-read-args` and then visits it
        ;; with `find-file-existing`. Neither is ported; `find-file` asks
        ;; the same question and visits what it is given, which is what
        ;; this entry does until they are.
        (define-key menu (kbd "<open-file>")
          '(menu-item "Open File..." find-file
                      :help "Read an existing file into an Emacs buffer"))

        (define-key menu (kbd "<new-file>")
          '(menu-item "Visit New File..." find-file
                      :help "Specify a new file's name, to edit the file"))

        menu))

    ;;----------------------------------------------------------------
    ;; The Edit menu's sub-menus
    ;;----------------------------------------------------------------

    (define menu-bar-i-search-menu
      ;; GNU Emacs's `menu-bar-i-search-menu` (`menu-bar.el:331`), less
      ;; the regexp and symbol/word searches: `isearch-forward-regexp`,
      ;; `isearch-backward-regexp`, `isearch-forward-word` and the two
      ;; symbol searches are not ported to `isearch.scm` yet.
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap "Incremental Search")))
        (define-key menu (kbd "<isearch-backward>")
          '(menu-item "Backward String..." isearch-backward
                      :help "Search backwards for a string as you type it"))
        (define-key menu (kbd "<isearch-forward>")
          '(menu-item "Forward String..." isearch-forward
                      :help "Search forward for a string as you type it"))
        menu))

    (define menu-bar-replace-menu
      ;; GNU Emacs's `menu-bar-replace-menu` (`menu-bar.el:410`), less
      ;; the tag and project replacements (`tags-query-replace`,
      ;; `project-query-replace-regexp`) and `fileloop-continue`.
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap "Replace")))
        (define-key menu (kbd "<query-replace-regexp>")
          '(menu-item "Replace Regexp..." query-replace-regexp
                      :enable (not (buffer-read-only? (current-buffer)))
                      :help "Replace regular expression interactively, ask about each occurrence"))
        (define-key menu (kbd "<query-replace>")
          '(menu-item "Replace String..." query-replace
                      :enable (not (buffer-read-only? (current-buffer)))
                      :help "Replace string interactively, ask about each occurrence"))
        menu))

    ;;----------------------------------------------------------------
    ;; The Edit menu
    ;;----------------------------------------------------------------

    (define menu-bar-edit-menu
      ;; GNU Emacs's `menu-bar-edit-menu` (`menu-bar.el:497`), less Fill,
      ;; Bookmarks, Go To and Search - see the header - and with the
      ;; `:keys` properties dropped, because they are functions that
      ;; return a `\\[command]` description, and `help-echo-substitute-
      ;; command-keys` is the identity here (`keyboard.scm` says why).
      ;;
      ;; The C's `:enable` tests are kept where this tree spells them
      ;; with the same meaning: `mark-active` is `(mark-active)`,
      ;; `buffer-read-only` is `(buffer-read-only? (current-buffer))`.
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap "Edit")))

        (define-key menu (kbd "<execute-extended-command>")
          '(menu-item "Execute Command" execute-extended-command
                      :enable #t
                      :help "Read a command name, its arguments, then call it."))

        (define-key menu (kbd "<replace>")
          `(menu-item "Replace" ,menu-bar-replace-menu))

        (define-key menu (kbd "<i-search>")
          `(menu-item "Incremental Search" ,menu-bar-i-search-menu))

        (define-key menu (kbd "<mark-whole-buffer>")
          '(menu-item "Select All" mark-whole-buffer
                      :help "Mark the whole buffer for a subsequent cut/copy"))

        (define-key menu (kbd "<paste>")
          '(menu-item "Paste" yank
                      :enable (not (buffer-read-only? (current-buffer)))
                      :help "Paste (yank) text most recently cut/copied"))

        (define-key menu (kbd "<copy>")
          '(menu-item "Copy" kill-ring-save
                      :enable (mark-active)
                      :help "Copy text in region between mark and current position"))

        (define-key menu (kbd "<cut>")
          '(menu-item "Cut" kill-region
                      :enable (and (mark-active)
                                   (not (buffer-read-only? (current-buffer))))
                      :help "Cut (kill) text in region between mark and current position"))

        (define-key menu (kbd "<undo-redo>")
          '(menu-item "Redo" undo-redo
                      :enable (not (buffer-read-only? (current-buffer)))
                      :help "Redo last undone edits"))

        (define-key menu (kbd "<undo>")
          '(menu-item "Undo" undo
                      :enable (not (buffer-read-only? (current-buffer)))
                      :help "Undo last edits"))

        menu))

    ;;----------------------------------------------------------------
    ;; The Buffers menu - `menu-bar.el:2353-2570`
    ;;----------------------------------------------------------------
    ;;
    ;; The one menu that rebuilds itself while the editor runs: its
    ;; entries are the live buffers, most recently used first, and it is
    ;; rebuilt by `menu-bar-update-hook` (which the gtk front end runs
    ;; before it recomputes the bar) whenever the buffer or frame state
    ;; has changed.
    ;;
    ;; **What is not here**: the "Frames" sub-menu, which needs frame
    ;; parameters (and `raise-frame`) to name and select a frame.

    (define *buffers-menu-max-size* (make-parameter 15))
    ;; ^ GNU Emacs's `buffers-menu-max-size` (`menu-bar.el:2357`):
    ;; "Maximum number of entries which may appear on the Buffers menu."
    ;; A number or nil for all.

    (define *buffers-menu-buffer-name-length* (make-parameter 30))
    ;; ^ GNU Emacs's `buffers-menu-buffer-name-length` (`:2367`): "Maximum
    ;; length of the buffer name on the Buffers menu." A number or nil.

    (define *buffers-menu-show-directories* (make-parameter 'unless-uniquify))
    ;; ^ GNU Emacs's `buffers-menu-show-directories` (`:2376`): whether a
    ;; buffer's directory is shown. `unless-uniquify` means "show it
    ;; unless `uniquify-buffer-name-style` is set" - and that variable is
    ;; not ported, so the answer is always "show it", which is what the C
    ;; answers when the variable is unbound (`(boundp ...)` is nil).

    (define *buffers-menu-show-status* (make-parameter #t))
    ;; ^ GNU Emacs's `buffers-menu-show-status` (`:2394`): "show
    ;; modified/read-only status of buffers in the Buffers menu".

    (define *menu-bar-select-buffer-function* (make-parameter switch-to-buffer))
    ;; ^ GNU Emacs's `menu-bar-select-buffer-function` (`:2476`): "Function
    ;; to select the buffer chosen from the `Buffers` menu-bar menu."
    ;; A parameter holding the procedure, where the C holds the symbol.

    (define *frame-and-buffer-state* (make-parameter #f))
    ;; ^ The C's `frame_and_buffer_state` (`dispnew.c:7030`), the state
    ;; `frame-or-buffer-changed-p` compares and updates.

    (define (frame-or-buffer-changed-p)
      ;; GNU Emacs's `frame-or-buffer-changed-p` (`dispnew.c:7048'):
      ;; "Return non-nil if the frame and buffer state appears to have
      ;; changed. ... This allows a fast check to see whether buffer
      ;; menus might need to be recomputed."
      ;;
      ;; **Placement is a departure**: the C lives in `dispnew.c`, and
      ;; `dispnew.scm` here is the display interface - a leaf that cannot
      ;; see a buffer. The only caller in this tree is the Buffers menu,
      ;; so it lives beside it, as `locate-file-internal` lives in
      ;; `fileio.scm`.
      ;;
      ;; The C keeps the state in one flat vector of frames, buffers and
      ;; their flags, ending with a `lambda`; a list of the same facts
      ;; compares the same way, and `equal?` on the record objects is
      ;; identity, which is what the C's `BASE_EQ` asks.
      ;;--------------------------------------------------------------
      (let* ((frames (map (lambda (f) (list 'frame f (frame-name f)))
                          (frame-list)))
             (buffers (filter (lambda (b)
                                (not (char=? (string-ref (buffer-name b) 0)
                                             #\space)))
                              (buffer-list)))
             (state (append
                     frames
                     (map (lambda (b)
                            (list 'buffer b
                                  (buffer-local-value b 'buffer-read-only #f)
                                  (buffer-modified-p b)))
                          buffers))))
        (if (%same-state? state (*frame-and-buffer-state*))
            #f
            (begin (*frame-and-buffer-state* state) #t))))

    (define (%same-state? a b)
      ;; The C's comparison, element for element - `BASE_EQ` on the frame
      ;; and buffer objects, `EQ` on what hangs off them.
      ;;
      ;; **It has to be shallow, and this is the whole reason it is
      ;; written out.** A frame record holds its windows and each window
      ;; holds its frame, so `equal?` on two *different* frames walks a
      ;; cycle until the stack runs out - measured: creating a second
      ;; frame raised "Stack overflow" the first time the state held a
      ;; frame the old one did not. With one frame the two states are
      ;; `eq?` and `equal?` answers at once, which is why it did not show
      ;; until there were two.
      ;;--------------------------------------------------------------
      (define (entry-equal? x y)
        (cond
         ((and (pair? x) (eq? 'frame (list-ref x 0)))
          (and (eq? (list-ref x 1) (list-ref y 1))
               (equal? (list-ref x 2) (list-ref y 2))))
         ((and (pair? x) (eq? 'buffer (list-ref x 0)))
          (and (eq? (list-ref x 1) (list-ref y 1))
               (equal? (list-ref x 2) (list-ref y 2))
               (equal? (list-ref x 3) (list-ref y 3))))
         (else #f)))
      (cond ((and (null? a) (null? b)) #t)
            ;; #f is the C's nil, "no state recorded yet" - always
            ;; "changed", which is what makes the first call build.
            ((or (not (pair? a)) (not (pair? b))) #f)
            ((not (entry-equal? (car a) (car b))) #f)
            (else (%same-state? (cdr a) (cdr b)))))

    (define (menu-bar-update-buffers-1 elt)
      ;; GNU Emacs's `menu-bar-update-buffers-1` (`menu-bar.el:2426`):
      ;; one buffer's line - its display name, and with
      ;; `buffers-menu-show-status` its `*`/`%` flags and its directory.
      ;;--------------------------------------------------------------
      (let* ((buf (car elt))
             (name (cdr elt))
             (file (and (if (eq? (*buffers-menu-show-directories*) 'unless-uniquify)
                            #t
                            (*buffers-menu-show-directories*))
                        (or (buffer-file-name buf)
                            (buffer-local-value buf 'list-buffers-directory #f)))))
        (when file
          ;; `file-name-directory` answers nil for a bare name; this
          ;; tree's `file-name-directory-part` answers "" - so the
          ;; "no directory" answer is spelled out here.
          (let ((dir (file-name-directory-part file)))
            (set! file (if (string=? dir "") #f dir))))
        (when (and file (> (string-length file) 20))
          (set! file (string-append "..."
                                    (substring file (- (string-length file) 17)
                                               (string-length file)))))
        (cons (if (*buffers-menu-show-status*)
                  (let ((mod (if (buffer-modified-p buf) "*" ""))
                        (ro (if (buffer-local-value buf 'buffer-read-only #f)
                                "%" "")))
                    (if file
                        (format #f "~a  ~a~a  --  ~a" name mod ro file)
                        (format #f "~a  ~a~a" name mod ro)))
                  (if file
                      (format #f "~a  --  ~a" name file)
                      name))
              buf)))

    (define *menu-bar-buffer-commands* (make-parameter '()))
    ;; ^ The one selection command per buffer - see `menu-bar-buffer-vector`.

    (define (menu-bar-buffer-vector alist)
      ;; GNU Emacs's `menu-bar-buffer-vector` (`menu-bar.el:2478`): "Turn
      ;; ((name . buffer) ...) into a menu."
      ;;
      ;; The C makes a *vector* of `(NAME . COMMAND)` pairs - the command
      ;; being a closure that selects the buffer - and the keymap reads
      ;; the vector by event. This tree's keymap is an alist of events, so
      ;; the same pairs are hung off the events 0..n-1, which is exactly
      ;; what a keymap vector is.
      ;;--------------------------------------------------------------
      ;; **The selection command is made once per buffer, not once per
      ;; rebuild.** Emacs makes a fresh closure each time because its
      ;; rebuild runs only when the redisplay is told something changed;
      ;; this tree compares the *built* array to decide - and a vector
      ;; holding a fresh closure every time never compares equal, so the
      ;; bar was rebuilt on every redisplay and each rebuild laid its
      ;; widgets out again. The layout's `size-allocate` came back
      ;; through the front end, which redispatched, which rebuilt: a
      ;; stack overflow the moment a second frame gave the display two
      ;; readers' worth of flushes. The closure depends on the buffer
      ;; alone, so a table keyed by the buffer makes the two builds
      ;; compare equal and the rebuild happen when something really
      ;; changed.
      ;;--------------------------------------------------------------
      (let ((vec (make-vector (length alist) #f))
            (i (length alist)))
        (for-each
         (lambda (pair)
           (set! i (- i 1))
           (let* ((buf (cdr pair))
                  (cached (assq buf (*menu-bar-buffer-commands*))))
             (unless cached
               (set! cached
                     (cons buf (lambda ()
                                 ((*menu-bar-select-buffer-function*) buf))))
               (*menu-bar-buffer-commands* (cons cached (*menu-bar-buffer-commands*))))
             (vector-set! vec i (cons (car pair) (cdr cached)))))
         alist)
        vec))

    (define menu-bar-buffers-menu-command-entries
      ;; GNU Emacs's `menu-bar-buffers-menu-command-entries`
      ;; (`menu-bar.el:2441`), less the two project entries
      ;; (`project-switch-to-buffer`, `project-list-buffers`).
      ;;
      ;; Each entry is `(KEY menu-item NAME COMMAND ...)`, which
      ;; `menu-bar-update-buffers` splits into a binding.
      ;;--------------------------------------------------------------
      (list '(command-separator "--")
            (list 'next-buffer
                  'menu-item
                  "Next Buffer"
                  'next-buffer
                  ':help "Switch to the \"next\" buffer in a cyclic order")
            (list 'previous-buffer
                  'menu-item
                  "Previous Buffer"
                  'previous-buffer
                  ':help "Switch to the \"previous\" buffer in a cyclic order")
            (list 'select-named-buffer
                  'menu-item
                  "Select Named Buffer..."
                  'switch-to-buffer
                  ':help "Prompt for a buffer name, and select that buffer in the current window")
            (list 'list-all-buffers
                  'menu-item
                  "List All Buffers"
                  'list-buffers
                  ':help "Pop up a window listing all Emacs buffers")))

    (define global-buffers-menu-map
      ;; GNU Emacs's `global-buffers-menu-map` (`menu-bar.el:50`), "just
      ;; to show what this looks like. It gets modified in place when
      ;; `menu-bar-update-buffers` is called."
      ;;--------------------------------------------------------------
      (make-sparse-keymap "Buffers"))

    (define (menu-bar-update-buffers . force)
      ;; GNU Emacs's `menu-bar-update-buffers` (`menu-bar.el:2496`):
      ;; rebuild the Buffers menu from the live buffers.
      ;;
      ;; The C tests `(lookup-key (current-global-map) [menu-bar buffer])`
      ;; first - "If user discards the Buffers item, play along" - and
      ;; then `frame-or-buffer-changed-p`, or FORCE. The map is rebuilt in
      ;; place, because the `[menu-bar buffer]` binding holds this object.
      ;;--------------------------------------------------------------
      (when (and (keymap-lookup *default-keymap* (kbd "<menu-bar> <buffer>"))
                 (or (and (pair? force) (car force))
                     (frame-or-buffer-changed-p)))
        (let* ((buffers (buffer-list))
               (limit (and (exact-integer? (*buffers-menu-max-size*))
                           (> (*buffers-menu-max-size*) 1)
                           (*buffers-menu-max-size*)))
               (i 0)
               (alist '()))
          ;; "Put into each element of buffer-list the name for actual
          ;; display, perhaps truncated in the middle."
          (let loop ((rest buffers))
            (when (pair? rest)
              (let* ((buf (car rest))
                     (name (buffer-name buf)))
                (unless (char=? #\space (string-ref name 0))
                  (set! alist
                        (cons (menu-bar-update-buffers-1
                               (cons buf
                                     (if (and (exact-integer?
                                               (*buffers-menu-buffer-name-length*))
                                              (> (string-length name)
                                                 (*buffers-menu-buffer-name-length*)))
                                         (string-append
                                          (substring name 0
                                                     (quotient (*buffers-menu-buffer-name-length*) 2))
                                          "..."
                                          (substring name
                                                     (- (string-length name)
                                                        (quotient (*buffers-menu-buffer-name-length*) 2))
                                                     (string-length name)))
                                         name)))
                              alist))
                  ;; `set!` answers the unspecified value where Emacs's
                  ;; `setq` answers the new one, so the count is taken
                  ;; first and compared from a `let`.
                  (let ((next (+ i 1)))
                    (set! i next)
                    (if (eql? limit next)
                        (set! rest '())
                        (loop (cdr rest))))))))
          (let ((vec (menu-bar-buffer-vector alist)))
            ;; Clear what the last build left, then install the buffer
            ;; entries from the last event down so the keymap's order -
            ;; which prepends - comes out 0, 1, 2, ..., which is the
            ;; display order (`menu-bar-buffer-vector` put the most
            ;; recently used at 0).
            (hash-clear! (keymap-bindings global-buffers-menu-map))
            (%set!keymap-order! global-buffers-menu-map '())
            ;; **Defined from the last display slot backwards**, because
            ;; `define-key` prepends and the keymap's order *is* its
            ;; display order. Emacs's map is a vector followed by an
            ;; alist and shows them in that order; here the two are one
            ;; alist, so the command entries - which show last - are
            ;; defined first, and the buffer entries after them, highest
            ;; index first.
            (for-each (lambda (entry)
                        (define-key global-buffers-menu-map (car entry)
                                    (cdr entry)))
                      (reverse menu-bar-buffers-menu-command-entries))
            (let loop ((n (- (vector-length vec) 1)))
              (when (>= n 0)
                (define-key global-buffers-menu-map n (vector-ref vec n))
                (loop (- n 1))))))))

    (define (eql? a b)
      ;; Emacs's `eql`, which `menu-bar-update-buffers` uses to stop at
      ;; the limit and which the tuple of numbers makes the same as `=`.
      ;;--------------------------------------------------------------
      (and a b (= a b)))

    ;;----------------------------------------------------------------
    ;; `menu-bar-mode` - `menu-bar.el:2627`
    ;;----------------------------------------------------------------

    (define *menu-bar-mode* (make-parameter #t))
    ;; ^ GNU Emacs's `menu-bar-mode` (`menu-bar.el:2635`): the global
    ;; minor mode's variable, `:init-value t`.

    (define-command (menu-bar-mode arg)
      "Toggle display of a menu bar on each frame (Menu Bar mode).

This command applies to all frames that exist and frames to be
created in the future."
      ;; **A plain command, where the C is a `define-minor-mode`.**
      ;; `:global` is one of the keywords this tree's `define-minor-mode`
      ;; does not carry (`easy-mmode.scm` says why: there is no global
      ;; mode machinery), so the macro would generate a buffer-local mode
      ;; for a switch that is about every frame. The C's body is what is
      ;; here, and its interactive form - "toggle" with no prefix - is
      ;; what `define-minor-mode` would have passed.
      ;;--------------------------------------------------------------
      (interactive (list (or (current-prefix-arg) 'toggle)))
      ;; **`define-minor-mode`'s own rule** (`easy-mmode.el:367`):
      ;;
      ;;   (cond ((eq arg 'toggle) (not ,getter))
      ;;         (t (not (and (numberp arg) (< arg 1)))))
      ;;
      ;; so a prefix of 1 or more enables, and 0 or a negative one
      ;; disables - `C-0` is not "on". Measured on Emacs 31.1: 1 -> t,
      ;; 2 -> t, 0 -> nil, -1 -> nil.
      (let ((value (if (eq? arg 'toggle)
                       (not (*menu-bar-mode*))
                       (not (and (number? arg) (< arg 1))))))
        (*menu-bar-mode* value)
        ;; "Turn the menu-bars on all frames on or off."
        (let ((val (if value 1 0)))
          (for-each (lambda (frame)
                      (set-frame-parameter frame 'menu-bar-lines val))
                    (*frame-list*))
          ;; "If the user has given `default-frame-alist` a
          ;; `menu-bar-lines` parameter, replace it."
          (if (assq 'menu-bar-lines (*default-frame-alist*))
              (*default-frame-alist*
               (cons (cons 'menu-bar-lines val)
                     (assq-delete-all 'menu-bar-lines
                                      (*default-frame-alist*))))))
        ;; "Make the message appear when Emacs is idle" - the C defers it
        ;; through `run-with-idle-timer` so the minor mode's own message
        ;; does not overwrite it. There is no minor mode message here, so
        ;; it is said at once.
        (when (and (not value) (called-interactively? menu-bar-mode))
          (message "Menu Bar mode disabled.  Use \\[menu-bar-mode] to make the menu bar appear."))
        value))

    ;;----------------------------------------------------------------
    ;; The entries the bar is given - `menu-bar.el:2204-2217`
    ;;----------------------------------------------------------------

    ;; "We used to `(define-key global-map [menu-bar buffer] ...)` but that
    ;; did not do the right thing when the entry had been moved (e.g. to a
    ;; parent keymap)." The C binds `[menu-bar ITEM]` to `(cons NAME MAP)`
    ;; - a string and the menu's keymap - which is the old-format menu
    ;; item `parse_menu_item` reads for the bar's name and
    ;; `access_keymap` unwraps for the key sequence beneath it.
    ;; **In `menu-bar.el`'s own definition order**: it binds tools, then
    ;; buffer, options, edit, file and help-menu, and `define-key`
    ;; prepends - so the bar shows them reversed, Help last and Tools
    ;; first. With three of the six, defined buffer, edit, file, the bar
    ;; reads File, Edit, Buffers, which is where those three sit in the
    ;; full bar.
    ;;
    ;; `[menu-bar buffer]` holds the *map*, which `menu-bar-update-buffers`
    ;; rebuilds in place - so this binding is made once.
    (define-key *default-keymap* (kbd "<menu-bar> <buffer>")
                (cons "Buffers" global-buffers-menu-map))
    (define-key *default-keymap* (kbd "<menu-bar> <edit>")
                (cons "Edit" menu-bar-edit-menu))
    (define-key *default-keymap* (kbd "<menu-bar> <file>")
                (cons "File" menu-bar-file-menu))
    ;; The hook that rebuilds it, where `menu-bar.el` puts it.
    ;;
    ;; **The parameter is *called*, not `set!`** - `set!` would replace
    ;; the parameter object with a list, and the front end's
    ;; `(*menu-bar-update-hook*)` would then apply a list.
    (*menu-bar-update-hook*
     (cons menu-bar-update-buffers (*menu-bar-update-hook*)))
    (menu-bar-update-buffers #t)


    ;;----------------------------------------------------------------
    ;; The terminal's menu bar - `menu-bar.el:2813-3060`
    ;;----------------------------------------------------------------
    ;;
    ;; A terminal has no toolkit, so its menu bar is a row of text and
    ;; its menus are drawn by `term.c`. What is here is the Lisp half:
    ;; the navigation map `tty_menu_activate` reads commands through,
    ;; `popup-menu` (which is what every menu-bar item runs), and
    ;; `menu-bar-open`, which is F10.
    ;;--------------------------------------------------------------

    (define *menu-bar-open-function* (make-parameter #f))
    ;; ^ The window system's `menu-bar-open`, as a seam: GNU Emacs's
    ;; `menu-bar-open` dispatches on `(framep frame)` to `x-menu-bar-open`,
    ;; `pgtk-menu-bar-open`, `w32-menu-bar-open` and so on, and each of
    ;; those lives with its own terminal. A toolkit's front end is a
    ;; different library here (`ui/gtk'), so it installs its own - the
    ;; same shape as `*frame-creation-function*`.

    ;; **`tty-menu-open-use-tmm` is `frame.scm`'s definition**, imported
    ;; above and re-exported: `display-popup-menus-p` reads it, and that
    ;; is below this library. Defining it here as well made a duplicate
    ;; binding - and the generated `imports.scm` excepted the name twice,
    ;; which `except` refuses.
    ;;
    ;; "If non-nil, \\[menu-bar-open] on a TTY will invoke `tmm-menubar'.
    ;; If nil, it will drop down the menu corresponding to the first
    ;; (leftmost) menu-bar item." **`tmm-menubar` is not ported**, so with
    ;; this set the command says so rather than opening nothing.

    (define *tty-menu--initial-menu-x* 1)
    ;; ^ GNU Emacs's `tty-menu--initial-menu-x` (`menu-bar.el:2824`): "X
    ;; coordinate of the first menu-bar menu dropped by F10."

    (define (menu-bar-define-mouse-key map key def)
      ;; GNU Emacs's `menu-bar-define-mouse-key` (`menu-bar.el:2990`):
      ;; "Like `define-key', but add all possible prefixes for the
      ;; mouse."
      ;;
      ;; **Only the bare key here.** The C's extra prefixes are the
      ;; window areas a TTY can report a mouse position in - `tab-line`,
      ;; `header-line`, `menu-bar`, `mode-line`, ... - and binding an
      ;; area-prefixed sequence would mean a key beginning with an area
      ;; symbol, which the lookup descends into only when the area's own
      ;; binding is a keymap. No terminal mouse report is ported, so the
      ;; prefixed spellings could not be reached anyway.
      ;;--------------------------------------------------------------
      (define-key map (vector key) def))

    (define (tty-menu-navigation-map)
      ;; GNU Emacs's `tty-menu-navigation-map` (`menu-bar.el:3008`): the
      ;; keymap `tty_menu_activate` reads its commands through.
      ;;
      ;; **This is `substitute-key-definition`'s one use in the tree.**
      ;; The map does not bind keys of its own; it takes whatever the
      ;; user's global map has bound to `next-line`, `keyboard-quit` and
      ;; the rest and re-binds those *same keys* to the `tty-menu-*`
      ;; symbols `term.c` interprets. So a user who remaps `next-line`
      ;; navigates menus with their own key without a second table to
      ;; keep in step.
      ;;
      ;; "The tty-menu-* are just symbols interpreted by term.c, they are
      ;; not real commands" - and `read-menu-command` answers the binding
      ;; without running it.
      ;;--------------------------------------------------------------
      (let ((map (make-sparse-keymap)))
        (for-each
         (lambda (bind)
           (substitute-key-definition (car bind) (cdr bind)
                                      map *default-keymap* #()))
         ;; The C's list, with this tree's command *procedures* where it
         ;; names symbols - the global map holds the procedures.
         ;; `menu-bar-open` maps to `tty-menu-exit` as it does there,
         ;; which is what makes F10 while a menu is up put it down again.
         (list (cons keyboard-quit 'tty-menu-exit)
               ;; `keyboard-escape-quit` is not ported; a symbol can
               ;; never `eq?` a map's procedure, so this entry is the
               ;; no-op it is in Emacs for a user with no binding for it.
               (cons 'keyboard-escape-quit 'tty-menu-exit)
               (cons forward-char 'tty-menu-next-menu)
               (cons backward-char 'tty-menu-prev-menu)
               ;; **The arrow keys' commands**, which are what move
               ;; between menus: `[right]` is `right-char` and `[left]`
               ;; is `left-char` in `bindings.el:1412-1415`, so these two
               ;; substitutions are what give the arrows their meaning
               ;; inside a menu.
               (cons right-char 'tty-menu-next-menu)
               (cons left-char 'tty-menu-prev-menu)
               (cons next-line 'tty-menu-next-item)
               (cons previous-line 'tty-menu-prev-item)
               (cons insert-newline 'tty-menu-select)
               ;; `newline-and-indent` (C-j) is `simple.el`'s and needs
               ;; `indent-according-to-mode`, which is not ported; a
               ;; symbol cannot `eq?` a procedure, so the entry does
               ;; nothing rather than being wrong.
               (cons 'newline-and-indent 'tty-menu-select)
               (cons menu-bar-open 'tty-menu-exit)))
        ;; "The bindings of menu-bar items are so that clicking on the
        ;; menu bar when a menu is already shown pops down that menu."
        (define-key map (vector 'menu-bar 't) 'tty-menu-exit)
        ;; The select keys, by their events: `[?\C-r]`, `[?\C-j]`,
        ;; `[return]` and `[linefeed]`. RET and C-m are one event (13),
        ;; LF is 10, and C-r is 18.
        (for-each (lambda (key) (define-key map (vector key) 'tty-menu-select))
                  (list 18 13 10))
        ;; The wheel and the buttons: a terminal with no mouse never
        ;; makes them, and a terminal that one day reports a mouse needs
        ;; them - so they are bound as the C binds them.
        (for-each (lambda (key)
                    (menu-bar-define-mouse-key map key 'tty-menu-select))
                  '(mouse-1 drag-mouse-1 mouse-2 drag-mouse-2
                    mouse-3 drag-mouse-3))
        (menu-bar-define-mouse-key map 'wheel-down 'tty-menu-next-item)
        (menu-bar-define-mouse-key map 'wheel-up 'tty-menu-prev-item)
        (menu-bar-define-mouse-key map 'wheel-left 'tty-menu-prev-menu)
        (menu-bar-define-mouse-key map 'wheel-right 'tty-menu-next-menu)
        ;; "The following 6 bindings are for those whose text-mode mouse
        ;; lack the wheel."
        (for-each (lambda (key)
                    (menu-bar-define-mouse-key map key 'tty-menu-next-item))
                  '(S-mouse-1 S-drag-mouse-1))
        (for-each (lambda (key)
                    (menu-bar-define-mouse-key map key 'tty-menu-prev-item))
                  '(S-mouse-2 S-drag-mouse-2 S-mouse-3 S-drag-mouse-3))
        ;; "The down-mouse events must be bound to `tty-menu-ignore`, so
        ;; that only releasing the mouse button pops up the menu."
        (for-each (lambda (key)
                    (menu-bar-define-mouse-key map key 'tty-menu-ignore))
                  '(down-mouse-1 down-mouse-2 down-mouse-3
                    C-down-mouse-1 C-down-mouse-2 C-down-mouse-3
                    mouse-movement))
        map))

    (define (menu-bar-menu-at-x-y x y frame)
      ;; GNU Emacs's `menu-bar-menu-at-x-y` (`menu.c:1049`): "Return the
      ;; menu-bar menu on FRAME at pixel coordinates X, Y."
      ;;
      ;; **The positions it reads are the ones `display_menu_bar` wrote**
      ;; into `FRAME_MENU_BAR_ITEMS` as it drew the row
      ;; (`xdisp.c:27843`) - which is why the redisplay fills them in and
      ;; this reads them back.
      ;;--------------------------------------------------------------
      (let ((frame (or frame (selected-frame))))
        (if (not (frame-live-p frame))
            #f
            (let ((items (frame-menu-bar-items frame))
                  (used (frame-menu-bar-items-used frame)))
              (if (or (not items) (< y 0) (>= y (%frame-menu-bar-lines frame)))
                  #f
                  ;; "This loop assumes a single menu-bar line".
                  (let loop ((i 0))
                    (if (>= i used)
                        #f
                        (let ((name (vector-ref items (+ i 1)))
                              (pos (vector-ref items (+ i 3))))
                          (if (not name)
                              #f
                              (if (and (<= pos x)
                                       ;; "We use <= so the blank between
                                       ;; 2 items on a TTY is considered
                                       ;; part of the previous item."
                                       (<= x (+ pos
                                                (menu-item-width name))))
                                  (vector-ref items i)
                                  (loop (+ i 4))))))))))))

    (define (menu-bar-keymap . args)
      ;; GNU Emacs's `menu-bar-keymap` (`menu-bar.el:2899`): "Return the
      ;; current menu-bar keymap. The ordering of the return value
      ;; respects `menu-bar-final-items'."
      ;;
      ;; The C's `(lookup-key (menu-bar-current-active-maps) [menu-bar])`
      ;; is the first active map whose `[menu-bar]' is a keymap - Emacs's
      ;; `lookup-key` over a list of maps - and `lookup-keymaps` is this
      ;; tree's `menu-bar-current-active-maps`.
      ;;
      ;; **The map is built with `define-key` rather than written as a
      ;; `(keymap ...)` list**, because a keymap here is a record.
      ;; `define-key` prepends, so the items are defined back to front:
      ;; the final items first, in their reverse order, then the rest
      ;; reversed - which puts the list Emacs builds in the same order.
      ;;--------------------------------------------------------------
      (let ((menu-bar '())
            (menu-end '())
            (source (and (pair? args) (car args))))
        (let loop ((maps (if source (list source) (lookup-keymaps))))
          (unless (null? maps)
            (let ((def (keymap-lookup (car maps) 'menu-bar)))
              (cond ((keymap-type? def)
                     (map-keymap
                      (lambda (key binding)
                        (let ((pos (seq-position *menu-bar-final-items* key)))
                          (if pos
                              (set! menu-end (cons (cons pos (cons key binding))
                                                   menu-end))
                              (set! menu-bar (cons (cons key binding)
                                                   menu-bar)))))
                      def))
                    (else (loop (cdr maps)))))))
        (let ((map (make-sparse-keymap)))
          (for-each (lambda (entry)
                      (define-key map (vector (cdr entry)) (cddr entry)))
                    (sort menu-end (lambda (a b) (> (car a) (car b)))))
          (for-each (lambda (entry)
                      (define-key map (vector (car entry)) (cdr entry)))
                    menu-bar)
          map)))

    (define (posnp obj)
      ;; GNU Emacs's `posnp` (`subr.el:1981`): "Return non-nil if OBJ
      ;; appears to be a valid `posn' object specifying a window. ...
      ;; If OBJ is a valid `posn' object, but specifies a frame rather
      ;; than a window, return nil."
      ;;
      ;; **The frame exclusion is load-bearing here**, and the C's own
      ;; FIXME admits the function is wrong in general: a tab-bar
      ;; click's posn names the frame, so `popup-menu-normalize-
      ;; position` below must leave it alone - `x_popup_menu_1`
      ;; recognizes that posn's `tab-bar' part (`menu.c:1135') to place
      ;; the menu at the mouse.
      ;;
      ;; **Placement**: `subr.el` is this function's file, but its
      ;; `windowp` test is `(schemacs editor window)`'s, which is above
      ;; `subr.scm` - the same named departure `key-valid-p`'s is.
      ;;--------------------------------------------------------------
      (and (window-type? (and (pair? obj) (car obj)))
           (let* ((rest (and (pair? obj) (cdr obj)))
                  (area (and (pair? rest) (car rest))))
             (and (not (pair? area))
                  (let* ((rest2 (and (pair? rest) (cdr rest)))
                         (xy (and (pair? rest2) (car rest2))))
                    (and (integer? (and (pair? xy) (car xy)))
                         (integer? (and (pair? rest2)
                                        (pair? (cdr rest2))
                                        (cadr rest2)))))))))

    (define (popup-menu-normalize-position position)
      ;; GNU Emacs's `popup-menu-normalize-position` (`menu-bar.el:2788`):
      ;; "Convert the POSITION to the form which `popup-menu' expects
      ;; internally. POSITION can be an event, a posn- value, a value
      ;; having the form ((XOFFSET YOFFSET) WINDOW), or nil."
      ;;
      ;; **The posn branch was missing**, and it is the one a tab-line
      ;; click needs: without it a posn fell through to `x-popup-menu`
      ;; as if it were an event. A *frame* posn - the tab bar's - is
      ;; deliberately not normalized (`posnp` answers nil for it); the
      ;; C's tab-bar arm takes it instead.
      ;;--------------------------------------------------------------
      (cond
       ;; nil -> mouse cursor position
       ((not position)
        (let ((mp (mouse-position)))
          (list (list (cadr mp) (cddr mp)) (car mp))))
       ;; Value returned from `event-end` or `posn-at-point`.
       ((posnp position)
        (let ((xy (posn-x-y position)))
          (list (list (car xy) (cdr xy)) (posn-window position))))
       ;; `touchscreen-begin' or `touchscreen-end' event.
       ((memq (and (pair? position) (car position))
              '(touchscreen-begin touchscreen-end))
        position)
       ;; Event.
       ((and (pair? position) (symbol? (car position)))
        (popup-menu-normalize-position (event-end position)))
       ;; Some other value.
       (else position)))

    (define (popup-menu menu position prefix from-menu-bar)
      ;; GNU Emacs's `popup-menu` (`menu-bar.el:2690`): "Popup MENU and
      ;; call the selected option."
      ;;
      ;; **This is what a menu-bar item binds**, so it is where a click
      ;; on the bar becomes a command: `x-popup-menu` shows the menu and
      ;; answers the item's key sequence, the sequence is looked up in
      ;; the map, and the command it names is called. A sequence whose
      ;; binding is itself a keymap means a deeper menu, and the loop
      ;; shows that one next - which is how a nested submenu works on a
      ;; TTY, `tty_menu_show` drawing one menu at a time.
      ;;--------------------------------------------------------------
      (let ((map menu)
            (frame (selected-frame))
            (event #f)
            (cmd #f))
        (if from-menu-bar
            (let* ((xy (posn-x-y position))
                   (menu-symbol (menu-bar-menu-at-x-y (car xy) (cdr xy)
                                                      frame)))
              (set! position (list menu-symbol
                                   (list frame '(menu-bar) xy 0))))
            (set! position (popup-menu-normalize-position position)))
        (let loop ()
          (when map
            (set! event (x-popup-menu position map))
            (when event
              (set! cmd
                    (cond
                     ;; A menu-bar next/previous: the answer is the
                     ;; coordinates of the item to drop instead.
                     ((and from-menu-bar
                           (pair? event)
                           (number? (car event))
                           (number? (cdr event)))
                      (let ((menu-symbol (menu-bar-menu-at-x-y
                                          (car event) (cdr event) frame)))
                        (set! position
                              (list menu-symbol
                                    (list frame '(menu-bar) event 0)))
                        (key-binding (vector 'menu-bar menu-symbol))))
                     ;; "We were given a list of keymaps. Search them all
                     ;; in sequence until a first binding is found."
                     ((and (not (keymap-type? map)) (pair? map))
                      (let ((mouse-click (list->vector event)))
                        (let search ((rest map))
                          (if (null? rest)
                              #f
                              (or (keymap-lookup (car rest) mouse-click)
                                  (search (cdr rest)))))))
                     (else
                      ;; "We were given a single keymap."
                      (keymap-lookup map (list->vector event)))))
              ;; "Clear out echoing, which perhaps shows a prefix arg."
              (message "")
              ;; "Maybe try again but with the submap."
              (set! map (and (keymap-type? cmd) cmd))
              ;; "Maybe try again but with the submap" - and with the same
              ;; POSITION: the C keeps it as it was, which for a menu-bar
              ;; menu is the constructed `(MENU-SYMBOL (FRAME (menu-bar)
              ;; XY 0))`. Normalising it again here was wrong twice over:
              ;; it turned the menu's own position into an event and then
              ;; into a posn whose car is a frame, which `x-popup-menu`
              ;; refused.
              (if map (loop) #f))))
        ;; "If the user did not cancel by refusing to select, and if the
        ;; result is a command, run it."
        ;; "If the user did not cancel by refusing to select, and if the
        ;; result is a command, run it" (`menu-bar.el:2770`).
        ;;
        ;; **A plain procedure is a command here, and Emacs's buffer
        ;; menu is why.** Its entries are anonymous closures - one per
        ;; buffer, `(lambda () (interactive) (switch-to-buffer ...))' in
        ;; the C (`menu-bar-buffer-vector`), and in this tree a closure
        ;; over the buffer with no command record of its own. The
        ;; `dispatch-action` path runs such a procedure directly for the
        ;; same reason; this one did not, so every Buffers entry did
        ;; nothing when clicked from a terminal menu.
        (unless map
          (when cmd
            (parameterize ((current-prefix-arg prefix)
                           (*last-command-event*
                            ;; `(last EVENT)`, which is `(srfi 1)`'s;
                            ;; the last *event* of the sequence, and a
                            ;; menu's answer is never empty here.
                            (and (pair? event) (car (reverse event)))))
              (cond
               ((command-type? cmd)
                (if (command-interactive-spec cmd)
                    (run-command cmd prefix)
                    (run-command cmd)))
               ((symbol? cmd)
                (let ((record (command-record-named cmd)))
                  (when record
                    (if (command-interactive-spec record)
                        (run-command record prefix)
                        (run-command record)))))
               ((procedure? cmd)
                (let ((record (command-record-of cmd)))
                  (if record
                      (if (command-interactive-spec record)
                          (run-command record prefix)
                          (run-command record))
                      ;; A closure with no command record takes no
                      ;; arguments - it is the tree's `(lambda ()
                      ;; (interactive) ...)`
                      (cmd))))))))
        #f))

    (define-command (menu-bar-open . rest)
      "Start key navigation of the menu bar in FRAME.
Optional argument INITIAL-X gives the X coordinate of the first TTY
menu-bar menu to be dropped down."
      ;; **Both arguments are optional**, as Emacs's `(&optional frame
      ;; initial-x)` is: `(menu-bar-open)` from Lisp is an ordinary call,
      ;; and a fixed two-argument definition made it "Wrong number of
      ;; arguments". The interactive form still supplies both.
      (interactive (list #f (uarg->integer 1 (current-prefix-arg))))
      ;; GNU Emacs's `menu-bar-open` (`menu-bar.el:2829`). On a terminal
      ;; with a menu bar it drops the menu at INITIAL-X, "one situation
      ;; where this is important is when this function is invoked by name
      ;; via M-x, in which case the menu bar includes the Minibuf menu
      ;; item" - so the bar is brought up to date before it is read.
      ;;
      ;; **The dispatch is Emacs's `(eq type 'pgtk) (pgtk-menu-bar-open
      ;; frame)' and `(eq type 'x) (x-menu-bar-open frame)'**
      ;; (`menu-bar.el:2859-2866`): a window system's bar belongs to the
      ;; toolkit, so its own library opens it. `*menu-bar-open-function*`
      ;; is what it installs.
      ;;
      ;; **`tmm-menubar` is the branch not carried**: it is the
      ;; text-mode menu, a command of its own in tmm.el.
      ;;--------------------------------------------------------------
      (let* ((frame (if (pair? rest) (car rest) #f))
             (initial-x (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest)
                            1))
             (frame (or frame (selected-frame)))
             (display (and frame (frame-output frame))))
        (cond
         ((and display (window-system-display? display)
               (*menu-bar-open-function*))
          ((*menu-bar-open-function*) frame))
         ((or *tty-menu-open-use-tmm*
              (not (> (%frame-menu-bar-lines frame) 0)))
          (error "tmm-menubar is not ported"))
         (else
          (redisplay-frames!)
          (let* ((x (max initial-x *tty-menu--initial-menu-x*))
                 (menu (menu-bar-menu-at-x-y x 0 frame)))
            (popup-menu
             (or (key-binding (vector 'menu-bar menu))
                 (let ((local (buffer-local-keymap (current-buffer))))
                   (and local
                        (keymap-lookup local (vector 'menu-bar menu)))))
             (posn-at-x-y x 0 frame)
             #f
             #t))))))

    ;; "F10 drops down the menu corresponding to the first (leftmost)
    ;; menu-bar item" (`menu-bar.el:2866`).
    (define-key *default-keymap* (kbd "<f10>") menu-bar-open)

    (define *tty-menu-navigation-map* (make-parameter
                                       (tty-menu-navigation-map)))
    ;; ^ GNU Emacs's `tty-menu-navigation-map` (`menu-bar.el:3008`), as
    ;; the value `tty_menu_activate` binds `overriding-terminal-local-map`
    ;; to for as long as a menu is up (`term.c:4160`,
    ;; `specbind (Qoverriding_terminal_local_map, Fsymbol_value
    ;; (Qtty_menu_navigation_map))`).
    ;;
    ;; **Built here, after the F10 binding**, because the map is made by
    ;; *copying* keys the global map has bound, and F10's own binding is
    ;; one of the keys it copies: built before that line, F10 inside a
    ;; menu would not pop it down.
    ))
