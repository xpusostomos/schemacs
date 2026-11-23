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
              current-buffer with-current-buffer get-buffer-create
              buffer-read-only? text-editor-undo-list)
        ;; The Paste form asks the selection backend, as Emacs's does.
        (only (schemacs editor select) gui-backend-selection-exists-p)
        ;; The undo state the Undo/Redo `:enable` forms read.
        (only (schemacs editor simple) undo undo--last-change-was-undo-p
              *last-command* *pending-undo-list* *kill-ring*)
        (only (guile) eval)
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
              menu-bar-update-buffers frame-or-buffer-changed-p
              popup-menu))

(test-begin "schemacs_editor_menu_bar_menus")

(test-equal "the bar has the menus this tree can back, in display order"
  '("File" "Edit" "Buffers")
  (map cadr (menu-bar-items)))

;; GNU Emacs's `popup-menu` (`menu-bar.el:2682`) takes
;; `(menu &optional position prefix from-menu-bar)`, so a Lisp caller
;; passes one or two arguments. It was defined with all four *required*
;; here, and the mode-line menus - whose seam calls `(popup-menu menu
;; event)` - raised "Wrong number of arguments" on every press. A #f map
;; short-circuits before `x-popup-menu`, so these calls reach only the
;; arity and the position normalisation.
(test-assert "popup-menu's three optional arguments are optional"
  (and (eq? (popup-menu #f) #f)
       (eq? (popup-menu #f #f) #f)))
(test-assert "popup-menu accepts the prefix and menu-bar arguments"
  (eq? (popup-menu #f #f #f #f) #f))

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

;; Emacs 31.1: `(require 'easymenu)' then `menu-bar-separator' answers
;; `("--")' - `subr.el:7700`'s defconst, the old-style `(STRING . DEFN)'
;; binding whose `--' caption `parse_menu_item' draws as a rule. This was
;; written as `(menu-item "--")' from a memory of an older Emacs; the
;; easymenu differential caught it.
(test-equal "a separator is Emacs's old-style binding of two dashes"
  '("--")
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

;;------------------------------------------------------------------
;; The Edit menu's `:enable` forms
;;
;; Undo, Redo and Paste are greyed exactly when Emacs greys them, and the
;; *same* forms drive the tool bar's buttons (`tool-bar-add-item-from-menu`
;; copies the menu item, `:enable` included). Undo and Redo are Emacs 31's
;; own tests (`menu-bar.el:600`, `:611`) over the buffer's undo list; the
;; states below are the ones a user moves through: nothing to undo in a
;; fresh buffer, Undo live after an edit, Redo live and Undo spent once
;; the run ends, and Undo live again (the redo records are what it would
;; undo further) while the run is not the last command.
;;------------------------------------------------------------------

(define (edit-menu-enable-form key)
  ;; The raw `:enable` form of KEY's item in the Edit menu, as the menu
  ;; and the tool bar hold it.
  ;;--------------------------------------------------------------
  (let* ((map (keymap-lookup *default-keymap* (kbd "<menu-bar> <edit>")))
         (item (hashv-ref (keymap-bindings map) (vector-ref (kbd key) 0))))
    ;; The binding is `(menu-item NAME CMD PROPS...)`: walk from the
    ;; command, one element at a time, and the `:enable` keyword is found
    ;; in the car position with its form in the cadr.
    (let loop ((rest (cddr item)))
      (cond ((or (not (pair? rest)) (not (pair? (cdr rest)))) #f)
            ((eq? (car rest) ':enable) (cadr rest))
            (else (loop (cdr rest)))))))

(define (edit-menu-enable key)
  ;; The form evaluated where the menu evaluates it - the editor's own
  ;; environment, which for this suite's purposes is the module the
  ;; formulas' names are imported into.
  ;;--------------------------------------------------------------
  (eval (edit-menu-enable-form key) (current-module)))

;; A fresh buffer, then an edit, then that edit undone - the same steps
;; `emacs -Q --batch` answers for (measured: `#f #f`, `#t #f`, then
;; `#f #t` with `last-command` still `undo`, and `#t #t` once it is not).
(test-equal '(#f #f  #t #f  #f #t  #t #t)
  (let* ((ed (allocate-buffer))
         (frame (new-frame ed 24 80)))
    (parameterize ((*current-frame* frame)
                   (*current-buffer* ed)
                   (*last-command* #f)
                   (*pending-undo-list* #f))
      (let ((fresh (list (edit-menu-enable "<undo>")
                         (edit-menu-enable "<undo-redo>"))))
        (with-current-buffer ed (insert "abc"))
        (let ((edited (list (edit-menu-enable "<undo>")
                            (edit-menu-enable "<undo-redo>"))))
          ;; The undo command as the menu would run it, with the command
          ;; loop's `last-command` promotion after it.
          (with-current-buffer ed (undo 1))
          (*last-command* undo)
          (let ((undone (list (edit-menu-enable "<undo>")
                              (edit-menu-enable "<undo-redo>"))))
            (*last-command* #f)
            (let ((settled (list (edit-menu-enable "<undo>")
                                 (edit-menu-enable "<undo-redo>"))))
              (append fresh edited undone settled))))))))

;; Paste: Emacs's form is "read-only off, and either the clipboard has an
;; owner or the kill ring is not empty" (`menu-bar.el:556`). The kill
;; ring here is `()` when empty - true in Scheme - so the form tests
;; `pair?`; a test display has no selection owner.
(test-equal '(#f #t)
  (let* ((ed (allocate-buffer))
         (frame (new-frame ed 24 80)))
    (parameterize ((*current-frame* frame)
                   (*current-buffer* ed)
                   (*kill-ring* '()))
      (let ((empty-ring (edit-menu-enable "<paste>")))
        (*kill-ring* (list "abc"))
        (list empty-ring (edit-menu-enable "<paste>"))))))

(test-end "schemacs_editor_menu_bar_menus")
