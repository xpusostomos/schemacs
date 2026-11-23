;; `menu.c`'s `menu_items` builder. The expectations follow the C
;; (`single_keymap_panes`/`single_menu_item`/`parse_single_submenu`),
;; not `emacs -Q --batch`: `menu_items` is not exposed to Lisp.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (schemacs keymap)
              make-sparse-keymap define-key)
        (only (schemacs character) kbd)
        ;; The graphical branch of `single-menu-item` is chosen by
        ;; `have-boxes`, which is `(display-graphic-p)` - the parameter a
        ;; front end sets.
        (only (schemacs faces) *window-system*)
        (only (schemacs menu)
              *menu-state* menu-items menu-items-used menu-items-n-panes
              init-menu-items finish-menu-items
              menu-items-pane-name menu-items-pane-prefix
              menu-items-pane-length
              menu-items-item-name menu-items-item-enable
              menu-items-item-value menu-items-item-type
              menu-items-item-selected menu-items-item-definition
              menu-items-item-length
              parse-single-submenu keymap-panes list-of-panes
              digest-single-submenu update-submenu-strings
              find-and-call-menu-selection
              widget-value? widget-value-name widget-value-value
              widget-value-lname widget-value-next widget-value-contents
              widget-value-call-data widget-value-button-type
              widget-value-selected?))

(test-begin "schemacs_editor_menu")

;; A readable view of the current `menu_items`: panes, items (name, key,
;; type, selected only), and the three marker slots.
(define (state-list)
  (let loop ((i 0) (out '()))
    (if (>= i (menu-items-used))
        (reverse out)
        (let ((slot (vector-ref (menu-items) i)))
          (cond
           ((eq? slot #t)
            (loop (+ i menu-items-pane-length)
                  (cons (list 'pane
                              (vector-ref (menu-items)
                                          (+ i menu-items-pane-name))
                              (vector-ref (menu-items)
                                          (+ i menu-items-pane-prefix)))
                        out)))
           ((eq? slot #f) (loop (+ i 1) (cons 'submenu-start out)))
           ((eq? slot 'lambda) (loop (+ i 1) (cons 'submenu-end out)))
           ((eq? slot 'quote) (loop (+ i 1) (cons 'boundary out)))
           (else
            (loop (+ i menu-items-item-length)
                  (cons (list 'item
                              (vector-ref (menu-items)
                                          (+ i menu-items-item-name))
                              (vector-ref (menu-items)
                                          (+ i menu-items-item-value))
                              (vector-ref (menu-items)
                                          (+ i menu-items-item-type))
                              (vector-ref (menu-items)
                                          (+ i menu-items-item-selected)))
                        out))))))))

;; `parse_single_submenu` no longer initializes the array - its C caller
;; does, once for the whole bar - so every call here is wrapped the way
;; `set_frame_menubar` wraps it.
(define (parse-submenu key name maps)
  (init-menu-items)
  (let ((answer (parse-single-submenu key name maps)))
    (finish-menu-items)
    answer))

(define (file-map)
  (let ((m (make-sparse-keymap "File"))
        (sub (make-sparse-keymap "Sub")))
    (define-key sub (kbd "x") '(menu-item "X" ignore))
    (define-key m (kbd "n") '(menu-item "New" ignore))
    (define-key m (kbd "s") '(menu-item "Save" ignore))
    (define-key m (kbd "v") (list 'menu-item "Sub" sub))
    m))

(test-equal "a pane and its items, newest-first, with the submenu inline"
  ;; Keys are EVENTS: `(kbd "v")' is 118, and so on.
  '((pane "File" file)
    (item "Sub" 118 #f #f)
    submenu-start
    (pane #f 118)
    (item "X" 120 #f #f)
    submenu-end
    (item "Save" 115 #f #f)
    (item "New" 110 #f #f))
  (begin
    (parameterize ((*window-system* 'pgtk))
      (parse-submenu 'file "File" (list (file-map))))
    (state-list)))

(test-equal "one top-level pane in the bar"
  1
  (begin
    (parse-submenu 'file "File" (list (file-map)))
    (menu-items-n-panes)))

(test-equal "a keymap with no prompt uses the item name as the pane name"
  '((pane "Mine" item) (item "X" 120 #f #f))
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "x") '(menu-item "X" ignore))
    (parse-submenu 'item "Mine" (list m))
    (state-list)))

(test-equal "a command as the bar item is a button, top-level"
  '((pane #f #f) (item "Run" run #f #f))
  (begin
    ;; `parse_single_submenu` pushes a pane with a nil name and an item
    ;; whose VALUE is the key; the def is the command. TYPE/SELECTED nil.
    (parse-submenu 'run "Run" (list 'ignore))
    (state-list)))

(test-assert "parse-single-submenu answers whether a top-level command was there"
  (let ((plain (make-sparse-keymap "M")))
    (define-key plain (kbd "x") '(menu-item "X" ignore))
    (and (not (parse-submenu 'm "M" (list plain)))
         (parse-submenu 'run "Run" (list 'ignore)))))

(test-equal "the `@' item becomes a separate pane after the main one"
  '((pane "File" file)
    (pane "@Tools" 116)
    (item "T" 116 #f #f))
  (let ((m (make-sparse-keymap "File"))
        (tools (make-sparse-keymap "Tools")))
    (define-key tools (kbd "t") '(menu-item "T" ignore))
    (define-key m (kbd "t") (list 'menu-item "@Tools" tools))
    (parse-submenu 'file "File" (list m))
    (state-list)))

(test-equal "keymap-panes makes one pane per keymap"
  '((pane "A" #f) (item "X" 120 #f #f) (pane "B" #f) (item "Y" 121 #f #f))
  (let ((a (make-sparse-keymap "A"))
        (b (make-sparse-keymap "B")))
    (define-key a (kbd "x") '(menu-item "X" ignore))
    (define-key b (kbd "y") '(menu-item "Y" ignore))
    (keymap-panes (list a b))
    (state-list)))

(test-equal "list-of-panes: the popup alist form"
  '((pane "Pane" #f) (item "One" #f #f #f) boundary (item "Two" () #f #f))
  (begin
    ;; A string item is pushed with ENABLE nil and DEF t; a cons item is
    ;; a command (its cdr is the VALUE); anything else is the left/right
    ;; boundary. TYPE/SELECTED are nil, so only name/key are shown.
    (list-of-panes '(("Pane" "One" () ("Two"))))
    (state-list)))

;;------------------------------------------------------------------
;; digest_single_submenu - the widget_value tree
;;
;; The C's tree is built from the menu_items slice: a pane whose name
;; is meaningful becomes a widget_value with VALUE 1 (update_submenu_
;; strings then drops the 1 and any leading `@'); items hang off the
;; pane's CONTENTS as a NEXT chain; a submenu's items hang off the
;; item's own CONTENTS.
;;------------------------------------------------------------------

(define (digest-file-map)
  ;; A single top-level pane: its items hang directly under the root -
  ;; `digest_single_submenu` makes no pane widget when there is one pane.
  (parameterize ((*window-system* 'pgtk))
    (parse-submenu 'file "File" (list (file-map))))
  (digest-single-submenu 0 (menu-items-used) #f))

(test-assert "one pane: its items chain under the root, submenu nested"
  (let* ((root (digest-file-map))
         (sub (widget-value-contents root))
         (save (widget-value-next sub))
         (new (and save (widget-value-next save)))
         (x (and sub (widget-value-contents sub))))
    (and (widget-value? root)
         (string=? (widget-value-name root) "menu")
         (string=? (widget-value-lname sub) "Sub")
         (string=? (widget-value-lname save) "Save")
         (string=? (widget-value-lname new) "New")
         (string=? (widget-value-lname x) "X"))))

(test-assert "call_data is the item's index in menu_items"
  (let* ((root (digest-file-map))
         (sub (widget-value-contents root)))
    (and (eqv? 3 (widget-value-call-data sub))
         (eqv? 15 (widget-value-call-data (widget-value-contents sub))))))

(test-assert "with two panes each is a widget_value with VALUE 1"
  (let ((a (make-sparse-keymap "A"))
        (b (make-sparse-keymap "B")))
    (define-key a (kbd "x") '(menu-item "X" ignore))
    (define-key b (kbd "y") '(menu-item "Y" ignore))
    (keymap-panes (list a b))
    (let* ((root (digest-single-submenu 0 (menu-items-used) #f))
           (pane-a (widget-value-contents root))
           (pane-b (widget-value-next pane-a)))
      (and (string=? (widget-value-lname pane-a) "A")
           (eqv? 1 (widget-value-value pane-a))
           (string=? (widget-value-lname pane-b) "B")
           ;; `update_submenu_strings` moves lname to name and drops
           ;; the 1 that marked a pane.
           (begin (update-submenu-strings root)
                  (and (string=? (widget-value-name pane-a) "A")
                       (not (widget-value-value pane-a))))))))

(test-assert "a single top-level command comes back as the item itself"
  (begin
    (parse-submenu 'run "Run" (list 'ignore))
    (let ((wv (digest-single-submenu 0 (menu-items-used) #t)))
      (and (widget-value? wv)
           (string=? (widget-value-lname wv) "Run")
           (not (widget-value-contents wv))))))

(test-assert "a toggle item is BUTTON_TYPE_TOGGLE and SELECTED"
  (let ((m (make-sparse-keymap "M")))
    (define-key m (kbd "t")
                (list 'menu-item "T" 'ignore ':button (cons ':toggle #t)))
    (parse-submenu 'm "M" (list m))
    (let* ((wv (digest-single-submenu 0 (menu-items-used) #f))
           (item (widget-value-contents wv)))
      (and (eq? (widget-value-button-type item) 'toggle)
           (widget-value-selected? item)))))

;;------------------------------------------------------------------
;; find-and-call-menu-selection - the click back into a key sequence
;;
;; The C stores one MENU_BAR_EVENT per element of the sequence in the
;; keyboard buffer; this hands the same values to EMIT. The indices are
;; the `menu_items` slots the widget's `call_data` holds - 3 for the
;; "Sub" item and 15 for "X" inside it, from the digest test above.
;;------------------------------------------------------------------

(define (selection-keys i)
  (let ((keys '()))
    (find-and-call-menu-selection (menu-items) (menu-items-used) i
                                  (lambda (k) (set! keys (cons k keys))))
    (reverse keys)))

(test-equal "a pane's item gives the menu-bar prefix, the pane's key, the item's"
  '(menu-bar file 118)
  (begin
    (parameterize ((*window-system* 'pgtk))
      (parse-submenu 'file "File" (list (file-map))))
    (selection-keys 3)))

(test-equal "an item inside a submenu carries the submenu's key too"
  '(menu-bar file 118 120)
  (begin
    (parameterize ((*window-system* 'pgtk))
      (parse-submenu 'file "File" (list (file-map))))
    (selection-keys 15)))

(test-equal "a slot that is not an item gives nothing"
  '()
  (begin
    (parameterize ((*window-system* 'pgtk))
      (parse-submenu 'file "File" (list (file-map))))
    (selection-keys 0)))

(test-end "schemacs_editor_menu")
