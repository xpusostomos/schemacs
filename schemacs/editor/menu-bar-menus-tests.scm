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
        (only (schemacs editor keymap) keymap-lookup *default-keymap*)
        (only (schemacs editor character) kbd)
        (only (schemacs editor keyboard) menu-bar-items *menu-bar-final-items*)
        (only (schemacs editor menu-bar) menu-bar-separator))

(test-begin "schemacs_editor_menu_bar_menus")

(test-equal "the bar has the menus this tree can back, in keymap order"
  '("File" "Edit")
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

(test-end "schemacs_editor_menu_bar_menus")
