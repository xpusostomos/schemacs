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
          make-sparse-keymap define-key keymap-lookup *default-keymap*)
    (only (schemacs editor character) kbd)
    ;; `menu-bar-final-items` is `keyboard.c`'s variable, which
    ;; `menu-bar.el` sets (`:46`).
    (only (schemacs editor keyboard)
          *menu-bar-final-items* abort-recursive-edit)
    ;; `last-command-event` is `keyboard.c`'s variable by the C's file
    ;; list, and `command.scm`'s by this tree's import graph (the command
    ;; loop sets it, and the loop's library is above both).
    (only (schemacs editor command) *last-command-event* define-command)
    ;; The Edit menu's commands.
    (only (schemacs editor simple)
          kill-region kill-ring-save yank undo undo-redo mark-whole-buffer)
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
          split-window-below split-window-right delete-other-windows)
    (only (schemacs editor frame) make-frame-command delete-frame
          *echo-area-buffer*)
    (only (schemacs editor dired) dired)
    ;; The predicates the `:enable` expressions read. They are evaluated
    ;; by `menu-item-eval-property` when the bar is built, in the
    ;; editor's own environment - so they are the *functions* this tree
    ;; spells Emacs's variables with: `mark-active` is `(mark-active)`,
    ;; and `buffer-read-only` is `(buffer-read-only? (current-buffer))`.
    (only (schemacs editor buffer)
          buffer-list current-buffer buffer-read-only? buffer-modified-p
          buffer-file-name)
    (only (schemacs editor marker) marker-position))

  (export
   menu-bar-separator
   menu-bar-file-menu menu-bar-edit-menu
   menu-bar-i-search-menu menu-bar-replace-menu
   kill-this-buffer kill-this-buffer-enabled-p
   *menu-bar-close-window*)

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
                      :enable #t
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
    ;; The entries the bar is given - `menu-bar.el:2204-2217`
    ;;----------------------------------------------------------------

    ;; "We used to `(define-key global-map [menu-bar buffer] ...)` but that
    ;; did not do the right thing when the entry had been moved (e.g. to a
    ;; parent keymap)." The C binds `[menu-bar ITEM]` to `(cons NAME MAP)`
    ;; - a string and the menu's keymap - which is the old-format menu
    ;; item `parse_menu_item` reads for the bar's name and
    ;; `access_keymap` unwraps for the key sequence beneath it.
    (define-key *default-keymap* (kbd "<menu-bar> <edit>")
                (cons "Edit" menu-bar-edit-menu))
    (define-key *default-keymap* (kbd "<menu-bar> <file>")
                (cons "File" menu-bar-file-menu))

    ))
