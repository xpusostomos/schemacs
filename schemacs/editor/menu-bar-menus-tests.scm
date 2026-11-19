;; `menu-bar.el`'s standard menus, as far as this tree backs them.
;;
;; **A suite of its own, and a process of its own, because the library
;; has side effects**: loading `(schemacs editor menu-bar)` defines
;; `[menu-bar file]` and `[menu-bar edit]` in `global-map`, so every
;; test in the other suite that builds its own bar would see them too.
;; (`menu-bar-tests.scm` is `keyboard.c`'s half and must stay free of
;; them.)
;;
;; What is checked here is the part a click depends on: the bar reaches
;; the item, and the item's key sequence reaches its command - which is
;; `access_keymap`'s `get_keyelt` coercion, the thing that makes a mouse
;; click and a typed chord arrive at the same command.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (guile) string-contains)
        (only (schemacs editor buffer) allocate-buffer *current-buffer*
              with-current-buffer get-buffer-create)
        (only (schemacs editor frame) *current-frame* new-frame)
        (only (schemacs editor editfns) insert buffer-string)
        (only (schemacs editor help-fns)
              describe-function help-fns--insert-menu-bindings)
        (only (schemacs editor keymap) keymap-lookup keymap-order
              keymap-bindings *default-keymap*)
        (only (guile) hashv-ref)
        (only (schemacs editor character) kbd)
        (only (schemacs editor keyboard) menu-bar-items *menu-bar-final-items*)
        (only (schemacs editor buffer) get-buffer-create buffer-list)
        (only (schemacs editor menu-bar)
              menu-bar-separator global-buffers-menu-map
              menu-bar-update-buffers frame-or-buffer-changed-p))

(test-begin "schemacs_editor_menu_bar_menus")

(test-equal "the bar has the menus this tree can back, in display order"
  '("File" "Edit" "Buffers")
  (map cadr (menu-bar-items)))

(test-equal "an item's key sequence reaches its command"
  '(save-buffer save-buffers-kill-terminal
                 undo mark-whole-buffer query-replace)
  (list (keymap-lookup *default-keymap*
                       (kbd "<menu-bar> <file> <save-buffer>"))
        (keymap-lookup *default-keymap*
                       (kbd "<menu-bar> <file> <exit-emacs>"))
        (keymap-lookup *default-keymap*
                       (kbd "<menu-bar> <edit> <undo>"))
        (keymap-lookup *default-keymap*
                       (kbd "<menu-bar> <edit> <mark-whole-buffer>"))
        (keymap-lookup *default-keymap*
                       (kbd "<menu-bar> <edit> <replace> <query-replace>"))))

(test-equal "a separator is a menu item, not a bare string"
  (list 'menu-item "--")
  menu-bar-separator)

(test-equal "`menu-bar-final-items` is what `menu-bar.el` sets"
  '(help-menu)
  *menu-bar-final-items*)

;;------------------------------------------------------------------
;; The Buffers menu - the one that rebuilds itself
;;------------------------------------------------------------------

(test-equal "frame-or-buffer-changed-p answers only when the state moved"
  '(#f #t #f)
  (begin
    ;; The first call settles the state; the ones after it compare.
    (frame-or-buffer-changed-p)
    (let* ((same (frame-or-buffer-changed-p))
           (created (get-buffer-create "menu-bar-buffers-test"))
           (changed (frame-or-buffer-changed-p))
           (settled (frame-or-buffer-changed-p)))
      (list same changed settled))))

(test-assert "the Buffers menu lists a live buffer and the command entries"
  (begin
    (get-buffer-create "menu-bar-buffers-test")
    (menu-bar-update-buffers #t)
    (let ((order (keymap-order global-buffers-menu-map)))
      (and ;; the buffer entries come first, under events 0..n-1 ...
           (memv 0 order)
           ;; ... and the command entries after them, in Emacs's order.
           (let ((rest (memq 'command-separator order)))
             (and rest
                  (memq 'select-named-buffer (cdr rest))
                  (memq 'list-all-buffers
                        (cddr rest))))))))

(test-assert "a buffer entry is a name and a command"
  (begin
    (get-buffer-create "menu-bar-buffers-test")
    (menu-bar-update-buffers #t)
    (let ((raw (hashv-ref (keymap-bindings global-buffers-menu-map) 0 #f)))
      (and (pair? raw)
           (string? (car raw))
           (procedure? (cdr raw))
           ;; ...and the lookup answers the *command*, because a
           ;; `(STRING . DEFN)` binding is unwrapped by `access_keymap` -
           ;; which is what makes a click and a typed chord agree.
           (eq? (keymap-lookup global-buffers-menu-map 0) (cdr raw))))))

(test-equal "a command's menu path is what describe-function prints"
  "File → Save"
  (let ((ed (allocate-buffer)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (help-fns--insert-menu-bindings
       (list (kbd "<menu-bar> <file> <save-buffer>")) "")
      (buffer-string))))

;; The sentence, whole - it is `help-fns--key-bindings`' menu arm, which
;; had been a placeholder until `help-fns--insert-menu-bindings` was
;; ported. Emacs 31.1 prints exactly this line after "It is bound to C-x
;; C-s." with no blank line between (measured).
(test-assert "describe-function lists the menu a command is on"
  (let ((ed (allocate-buffer)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (describe-function 'save-buffer)
      (with-current-buffer (get-buffer-create "*Help*")
        (and (string-contains
              (buffer-string)
              "It can also be invoked from the menu: File → Save.")
             #t)))))

(test-end "schemacs_editor_menu_bar_menus")
