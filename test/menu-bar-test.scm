;; `keyboard.c`'s menu-bar half: `parse_menu_item` and
;; `menu_bar_items`. The expectations are the C's algorithm (read at
;; `keyboard.c:8641` and `:8899`), not a measurement: Emacs exposes
;; neither function to Lisp, so there is nothing `emacs -Q --batch`
;; can be asked. What CAN be measured - the keymap order and
;; `define-key-after` - is in `keymap-tests.scm` and `subr-tests.scm`.

(import (scheme base) (scheme write)
        (only (srfi 64) test-assert test-equal test-begin test-end)
        (only (guile) module-set!)
        (only (schemacs keymap)
              make-sparse-keymap define-key *current-keymap*)
        (only (schemacs buffer)
              get-buffer-create *current-buffer*)
        (only (schemacs intervals) put)
        (only (schemacs keyboard)
              parse-menu-item menu-bar-items menu-separator-name?
              *item-properties* item-property-name item-property-def
              item-property-map item-property-enable item-property-keyeq
              item-property-type item-property-selected
              *menu-bar-final-items* *enable-disabled-menus-and-buttons*
              *overriding-local-map-menu-flag*
              *overriding-terminal-local-map*))

(test-begin "schemacs_editor_menu_bar")

(define (prop slot) (vector-ref *item-properties* slot))

;;------------------------------------------------------------------
;; parse-menu-item - the menu-bar arm (INMENUBAR = 1)
;;------------------------------------------------------------------

(test-assert "a new-format item parses, and fills the properties"
  (and (parse-menu-item '(menu-item "File" ignore) 1)
       (string=? (prop item-property-name) "File")
       (eq? (prop item-property-def) 'ignore)
       (eq? (prop item-property-enable) #t)
       (not (prop item-property-map))))

(test-assert "the old format parses, its DEF being the cdr"
  (and (parse-menu-item '("File" . ignore) 1)
       (string=? (prop item-property-name) "File")
       (eq? (prop item-property-def) 'ignore)))

(test-equal "a :visible form that evaluates to nil hides the item"
  #f
  (parse-menu-item '(menu-item "File" ignore :visible #f) 1))

(test-equal "a :visible form that is true keeps it"
  #t
  (parse-menu-item '(menu-item "File" ignore :visible #t) 1))

(test-equal "a disabled item is dropped from the menu bar"
  #f
  (parse-menu-item '(menu-item "File" ignore :enable #f) 1))

(test-assert "a disabled item is KEPT in an ordinary menu"
  (and (parse-menu-item '(menu-item "File" ignore :enable #f) 0)
       (not (prop item-property-enable))))

(test-assert "enable-disabled-menus-and-buttons keeps it enabled"
  ;; A plain `defvar`, `setq`ed, so `module-set!` is how a test moves it.
  (begin
    (module-set! (resolve-module '(schemacs keyboard))
                 '*enable-disabled-menus-and-buttons* #t)
    (let ((parsed (parse-menu-item '(menu-item "File" ignore :enable #f) 1)))
      (module-set! (resolve-module '(schemacs keyboard))
                   '*enable-disabled-menus-and-buttons* #f)
      (and parsed (eq? (prop item-property-enable) #t)))))

(test-assert "a form as the name is evaluated"
  (and (parse-menu-item (list 'menu-item (list 'if #t "Computed" "no") 'ignore) 1)
       (string=? (prop item-property-name) "Computed")))

(test-assert "a name that evaluates to a non-string is not an item"
  (not (parse-menu-item (list 'menu-item (list 'if #t 42 "no") 'ignore) 1)))

(test-assert "a keymap as the definition is ITEM_PROPERTY_MAP"
  (let ((sub (make-sparse-keymap)))
    (and (parse-menu-item (list 'menu-item "Sub" sub) 1)
         (eq? (prop item-property-map) sub)
         (eq? (prop item-property-def) sub))))

(test-assert "a text-only item is fine in a submenu, not in the bar"
  (and (parse-menu-item '(menu-item "Just text") 0)
       (not (parse-menu-item '(menu-item "Just text") 1))))

(test-assert ":filter is applied to the definition"
  (and (parse-menu-item
        (list 'menu-item "F" 'ignore ':filter (lambda (def) 'filtered)) 1)
       (eq? (prop item-property-def) 'filtered)))

(test-assert ":keys with a function is called for the key description"
  (and (parse-menu-item
        (list 'menu-item "K" 'ignore ':keys (lambda () "C-x k")) 1)
       (string=? (prop item-property-keyeq) "C-x k")))

(test-assert ":button fills TYPE and SELECTED"
  (and (parse-menu-item
        (list 'menu-item "R" 'ignore ':button (cons ':radio #t)) 1)
       (eq? (prop item-property-type) ':radio)
       (eq? (prop item-property-selected) #t)))

(test-assert "the old format's `menu-enable` property disables the item"
  ;; The property is a FORM, evaluated: a nil VALUE means "no property",
  ;; as Emacs's `Fget`-returns-nil test does.
  (begin
    (put 'menu-bar-test-command 'menu-enable '(and #t #f))
    (not (parse-menu-item '("Cmd" . menu-bar-test-command) 1))))

(test-equal "an item that is not a menu item at all answers #f"
  #f
  (parse-menu-item 'ignore 1))

;;------------------------------------------------------------------
;; menu-bar-items - the `[menu-bar]' binding of the active maps
;;
;; The current keymap (`*current-keymap*`) stands in for the active
;; maps; `lookup-keymaps` also reads the buffer's own map and the
;; global one, and the buffer here has neither.
;;------------------------------------------------------------------

(define (menu-bar-quads maps-proc)
  (parameterize ((*current-buffer* (get-buffer-create "*menu-bar-test*"))
                 (*current-keymap* (maps-proc)))
    (menu-bar-items)))

(test-equal "a top-level binding is a (KEY NAME DEFS UNUSED) quad"
  '((file "File" (ignore) 0))
  (menu-bar-quads
   (lambda ()
     (let ((m (make-sparse-keymap)))
       (define-key m '#(menu-bar file) '(menu-item "File" ignore))
       m))))

(test-equal "items come out newest-first, as the keymap order is"
  '((edit "Edit" (ignore) 0) (file "File" (ignore) 0))
  (menu-bar-quads
   (lambda ()
     (let ((m (make-sparse-keymap)))
       (define-key m '#(menu-bar file) '(menu-item "File" ignore))
       (define-key m '#(menu-bar edit) '(menu-item "Edit" ignore))
       m))))

(test-equal "menu-bar-final-items moves the named item to the end"
  '((file "File" (ignore) 0) (edit "Edit" (ignore) 0))
  (begin
    (module-set! (resolve-module '(schemacs keyboard))
                 '*menu-bar-final-items* '(edit))
    (let ((result
           (menu-bar-quads
            (lambda ()
              (let ((m (make-sparse-keymap)))
                (define-key m '#(menu-bar file) '(menu-item "File" ignore))
                (define-key m '#(menu-bar edit) '(menu-item "Edit" ignore))
                m)))))
      (module-set! (resolve-module '(schemacs keyboard))
                   '*menu-bar-final-items* '())
      result)))

(test-equal "a disabled item is not in the bar"
  '()
  (menu-bar-quads
   (lambda ()
     (let ((m (make-sparse-keymap)))
       (define-key m '#(menu-bar edit)
                   '(menu-item "Edit" ignore :enable #f))
       m))))

(test-equal "an invisible item is not in the bar"
  '()
  (menu-bar-quads
   (lambda ()
     (let ((m (make-sparse-keymap)))
       (define-key m '#(menu-bar edit)
                   '(menu-item "Edit" ignore :visible (and #f #t)))
       m))))

(test-equal "an `undefined' binding removes an item"
  '((file "File" (ignore) 0))
  (menu-bar-quads
   (lambda ()
     (let ((m (make-sparse-keymap)))
       (define-key m '#(menu-bar file) '(menu-item "File" ignore))
       (define-key m '#(menu-bar edit) '(menu-item "Edit" ignore))
       (define-key m '#(menu-bar edit) 'undefined)
       m))))

;;------------------------------------------------------------------
;; `overriding-local-map-menu-flag' - nil by default, so an overriding
;; map's menu items are NOT in the bar until it is set (`keyboard.c:14147').
;;------------------------------------------------------------------

(define (set-overriding-map! maps)
  ;; The tree keeps this as a LIST of maps (the transient-map stack),
  ;; where Emacs's is one keymap.
  (module-set! (resolve-module '(schemacs keyboard))
               '*overriding-terminal-local-map* maps))

(define (set-menu-flag! value)
  (module-set! (resolve-module '(schemacs keyboard))
               '*overriding-local-map-menu-flag* value))

(test-equal "an overriding map puts no item in the bar by default"
  '()
  (begin
    (set-overriding-map!
     (list (let ((m (make-sparse-keymap)))
             (define-key m '#(menu-bar over) '(menu-item "Over" ignore))
             m)))
    (let ((result (menu-bar-quads (lambda () (make-sparse-keymap)))))
      (set-overriding-map! #f)
      result)))

(test-equal "with the flag set, the overriding map's item is in the bar"
  '((over "Over" (ignore) 0))
  (begin
    (set-menu-flag! #t)
    (set-overriding-map!
     (list (let ((m (make-sparse-keymap)))
             (define-key m '#(menu-bar over) '(menu-item "Over" ignore))
             m)))
    (let ((result (menu-bar-quads (lambda () (make-sparse-keymap)))))
      (set-menu-flag! #f)
      (set-overriding-map! #f)
      result)))

;;------------------------------------------------------------------
;; menu-separator-name? - `menu_separator_name_p` (`keyboard.c:8608`)
;;------------------------------------------------------------------

(test-equal "a name of nothing but dashes is a separator"
  '(#t #t #t #t)
  (map menu-separator-name? '("--" "---" "-" "")))

(test-equal "the toolkit's own separator names, after the two dashes"
  '(#t #t #t)
  (map menu-separator-name? '("--space" "--double-line" "--shadow-etched-in")))

(test-equal "anything else is an item"
  '(#f #f #f #f)
  (map menu-separator-name? '("-x" "a-" "File" "--not-a-name")))

(test-assert "a label that is not a string is not a separator"
  (and (not (menu-separator-name? #f))
       (not (menu-separator-name? 'symbol))))

(test-end "schemacs_editor_menu_bar")
