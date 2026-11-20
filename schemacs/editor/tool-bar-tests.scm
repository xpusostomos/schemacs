(import
 (scheme base)
 (scheme write)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor dispnew) current-display)
 (only (schemacs editor test-display) <test-display>)
 (only (schemacs editor frame)
       *current-frame* *current-buffer* new-frame frame-parameter
       %frame-tool-bar-lines)
 (only (schemacs editor buffer) get-buffer-create set-buffer-local-value!)
 (only (schemacs editor tool-bar)
       tool-bar-mode tool-bar-mode-variable tool-bar-setup tool-bar-map
       tool-bar-make-keymap tool-bar-make-keymap-1
       tool-bar-add-item tool-bar-local-item tool-bar-add-item-from-menu
       tool-bar-local-item-from-menu toggle-tool-bar-mode-from-frame)
 ;; The bar a search puts up, which is a buffer-local `tool-bar-map`.
 (only (schemacs editor isearch) isearch-tool-bar-map isearch-string)
 ;; The names the item's `:visible` form resolves beside the variable:
 ;; the editor's environment has them (it is the obarray stand-in), and
 ;; a test module must import them for the same reason.
 (only (schemacs editor fns) string-equal)
 (only (schemacs editor keyboard)
       tool-bar-items parse-tool-bar-item
       tool-bar-item-key tool-bar-item-enabled-p tool-bar-item-selected-p
       tool-bar-item-caption tool-bar-item-images tool-bar-item-binding
       tool-bar-item-type tool-bar-item-help tool-bar-item-label
       tool-bar-item-vert-only tool-bar-item-nslots)
 (only (schemacs editor keymap) map-keymap lookup-key keymapp
       make-sparse-keymap keymap-bindings)
 (only (schemacs editor subr) kbd)
 (only (schemacs editor image) find-image image-property
       image-search-load-path)
 (only (schemacs editor fns) plist-get))

;; Regression tests for `(schemacs editor tool-bar)` - `tool-bar.el` and
;; `keyboard.c`'s tool bar half.
;;
;; Every expectation that has an Emacs value is Emacs 31.1's: the item
;; order `tool-bar-setup` builds, the labels its caption-and-key rule
;; makes, the twelve-slot item layout, and `find-image`'s answer for an
;; XPM the tree ships. The image slot's fallback - `(:mask heuristic)` -
;; is the C's own answer when `display-images-p` is nil, which is what
;; a non-graphic test display is.

(setvbuf (current-output-port) 'none)

(define *test-display* (make <test-display>))
(current-display *test-display*)

(define frame (new-frame (get-buffer-create "tool-bar-one") 24 80))

(define (items) (tool-bar-items))

(define (item-named key)
  (let loop ((rest (items)))
    (cond ((null? rest) #f)
          ((eq? (list-ref (car rest) tool-bar-item-key) key) (car rest))
          (else (loop (cdr rest))))))

(define (map-keys map)
  (let ((keys '()))
    (map-keymap (lambda (key binding) (set! keys (cons key keys))) map)
    (reverse keys)))

(parameterize ((*current-frame* frame) (*current-buffer* #f))
  (tool-bar-setup)

  (test-begin "schemacs_editor_tool_bar_setup")

  (test-assert "the mode is on by default (its :init-value)"
               (eq? (tool-bar-mode-variable) #t))

  (test-equal "the standard items, in tool-bar-setup's order"
    '(new-file open-file open-directory kill-buffer save-buffer
      separator-1 undo separator-2 cut copy paste separator-3
      isearch-forward)
    (map-keys tool-bar-map))

  (test-equal "each item's caption is its menu item's"
    '("Visit New File..." "Open File..." "Open Directory..." "Close"
      "Save" "--" "Undo" "--" "Cut" "Copy" "Paste" "--"
      "Forward String...")
    (map (lambda (quad) (list-ref quad tool-bar-item-caption)) (items)))

  ;; `tool-bar-max-label-size` is 14 (`dispextern.h:3510'), so "Open
  ;; Directory" - the caption with its trailing dots off, exactly 14
  ;; characters - survives. Under the 10 this tree had it was dropped,
  ;; which is the same mistake that emptied every isearch label.
  (test-equal "the labels: :label where given, the caption/key rule elsewhere"
    '("New File" "Open" "Open Directory" "Close" "Save" #f "Undo" #f
      "Cut" "Copy" "Paste" #f "Search")
    (map (lambda (quad) (list-ref quad tool-bar-item-label)) (items)))

  (test-equal "a separator is a type, not a command"
    '(#t #t #t)
    (map (lambda (key)
           (list-ref (item-named key) tool-bar-item-type))
         '(separator-1 separator-2 separator-3)))

  (test-equal "the twelve slots"
    12 tool-bar-item-nslots)

  (test-equal "a twelve-element item"
    12 (length (item-named 'save-buffer)))

  ;; The menu items name their commands as symbols, which is what the C's
  ;; keymaps hold; `dispatch-action` is what runs one.
  (test-equal "the item's binding is the menu item's command"
    'save-buffer
    (list-ref (item-named 'save-buffer) tool-bar-item-binding))

  (test-equal "a non-graphic display has no image to show: the C's fallback"
    '(:mask heuristic)
    (list-ref (item-named 'save-buffer) tool-bar-item-images))

  (test-assert "the help carries the key binding the C appends"
               (let ((help (list-ref (item-named 'save-buffer)
                                     tool-bar-item-help)))
                 (and (string? help)
                      (string-contains help "C-x C-s"))))

  (test-end "schemacs_editor_tool_bar_setup")

  (test-begin "schemacs_editor_tool_bar_parse")

  ;; `parse-tool-bar-item` leaves its answer in a shared vector; each
  ;; call below is read straight after the call that made it.

  (test-equal "an old-style separator is an item of type t"
    #t
    (list-ref (begin
                (test-assert "separator parses"
                             (parse-tool-bar-item 'sep '("--")))
                (vector->list
                 (@@ (schemacs editor keyboard) *tool-bar-item-properties*)))
              tool-bar-item-type))

  (test-equal ":visible nil drops the item"
    #f
    (parse-tool-bar-item 'gone
                         '(menu-item "Gone" ignore :visible #f)))

  (test-equal ":wrap is refused by an external-tool-bar build"
    #f
    (parse-tool-bar-item 'wrapped
                         '(menu-item "Wrapped" ignore :wrap #t)))

  (test-equal ":label is taken as given"
    "My Label"
    (list-ref (begin
                (test-assert "labeled item parses"
                             (parse-tool-bar-item
                              'labeled
                              '(menu-item "Caption" ignore :label "My Label")))
                (vector->list
                 (@@ (schemacs editor keyboard) *tool-bar-item-properties*)))
              tool-bar-item-label))

  (test-equal ":enable is kept as a form and evaluated at the end"
    #t
    (list-ref (begin
                (test-assert "enabled item parses"
                             (parse-tool-bar-item
                              'enabled
                              '(menu-item "E" ignore :enable #t)))
                (vector->list
                 (@@ (schemacs editor keyboard) *tool-bar-item-properties*)))
              tool-bar-item-enabled-p))

  (test-equal ":button makes a toggle and carries SELECTED"
    '(#t :toggle)
    (let ()
      (test-assert "button item parses"
                   (parse-tool-bar-item
                    'toggle
                    '(menu-item "T" ignore :button (:toggle . #t))))
      (let ((props (vector->list
                    (@@ (schemacs editor keyboard) *tool-bar-item-properties*))))
        (list (list-ref props tool-bar-item-selected-p)
              (list-ref props tool-bar-item-type)))))

  (test-end "schemacs_editor_tool_bar_parse")

  (test-begin "schemacs_editor_tool_bar_keymap")

  (test-equal "find-image resolves the XPM the tree ships"
    "new.xpm"
    (let ((image (find-image '((:type xpm :file "new.xpm")))))
      (and image
           (let ((file (image-property image ':file)))
             (and file (substring file (- (string-length file) 7)))))))

  (test-equal "image-property skips the image symbol"
    'xpm
    (image-property (find-image '((:type xpm :file "new.xpm"))) ':type))

  (test-equal "the file is the one on the image search path"
    (image-search-load-path "new.xpm")
    (image-property (find-image '((:type xpm :file "new.xpm"))) ':file))

  (tool-bar-make-keymap)

  (test-assert "the built map is bound at [tool-bar]"
               (keymapp (lookup-key
                         (@@ (schemacs editor keymap) *default-keymap*)
                         (vector 'tool-bar))))

  (test-equal "an item's key reaches its command through the built map"
    'find-file
    (lookup-key (tool-bar-make-keymap) (vector 'new-file)))

  (test-equal "a local item goes into the map it is given"
    '(menu-item "test-item")
    (let ((m (make-sparse-keymap)))
      (tool-bar-local-item "new" 'ignore 'test-item m)
      (let ((raw (hashv-ref (keymap-bindings m) 'test-item #f)))
        (and (pair? raw) (list (car raw) (car (cdr raw)))))))

  (test-assert "a local item carries an :image form"
               (let ((m (make-sparse-keymap)))
                 (tool-bar-local-item "new" 'ignore 'with-image m)
                 (let ((raw (hashv-ref (keymap-bindings m) 'with-image #f)))
                   (and (pair? raw)
                        (pair? (plist-get (list-tail raw 3) ':image))))))

  (test-end "schemacs_editor_tool_bar_keymap")

  (test-begin "schemacs_editor_tool_bar_mode")

  (test-equal "tool-bar-mode 0 puts tool-bar-lines 0 on every frame"
    0
    (begin (tool-bar-mode 0)
           (frame-parameter frame 'tool-bar-lines)))

  (test-equal "tool-bar-mode 1 puts it back"
    1
    (begin (tool-bar-mode 1)
           (frame-parameter frame 'tool-bar-lines)))

  (test-equal "the frame's line count follows the parameter"
    1
    (begin (tool-bar-mode 1)
           (%frame-tool-bar-lines frame)))

  (test-equal "toggle-tool-bar-mode-from-frame flips the frame's parameter"
    '(0 1)
    (let ((first (begin (toggle-tool-bar-mode-from-frame 'toggle)
                        (frame-parameter frame 'tool-bar-lines))))
      (list first
            (begin (toggle-tool-bar-mode-from-frame 'toggle)
                   (frame-parameter frame 'tool-bar-lines)))))

  (test-end "schemacs_editor_tool_bar_mode"))


;;--------------------------------------------------------------------
;; The isearch bar - `isearch.el:807`
;;
;; **`tool-bar-map` is read buffer-locally**: `isearch-mode` sets it to
;; `isearch-tool-bar-map` for the duration of a search, and this is the
;; mechanism that puts the search's buttons up. `tool-bar-make-keymap`
;; reads the current buffer's value through `%tool-bar-map`.
;;--------------------------------------------------------------------

(test-begin "schemacs_editor_tool_bar_isearch")

(define isearch-bar-buffer (get-buffer-create "tool-bar-isearch"))

(test-equal "the search bar's items, in Emacs's order"
  '(isearch-repeat-backward isearch-repeat-forward isearch-cancel
    isearch-exit isearch-delete-char isearch-query-replace
    isearch-occur isearch-describe-mode)
  (let ((acc '()))
    (map-keymap (lambda (key binding)
                  (set! acc (cons key acc)))
                (tool-bar-make-keymap-1 isearch-tool-bar-map))
    (reverse acc)))

(set-buffer-local-value! isearch-bar-buffer 'tool-bar-map
                         isearch-tool-bar-map)

;; `isearch-string` is what the Finish button's `:visible` form reads
;; (`isearch.el:829`); it is a plain variable, set the way a running
;; search leaves it - with something typed, so Finish is on the bar.
(set! isearch-string "abc")
(parameterize ((*current-frame* frame) (*current-buffer* isearch-bar-buffer))
  ;; Emacs's label rule cut at `tool-bar-max-label-size' (14,
  ;; `dispextern.h:3510'): "Repeat Forward" is exactly 14 characters and
  ;; is shown; "Repeat Backward" is 15 and is not; the rest fit.
  (test-equal "the search bar's labels, cut at 14 characters"
    '("" "Repeat Forward" "Abort" "Finish" "Undo" "Replace" "Show Hits"
      "Help")
    (map (lambda (quad) (list-ref quad tool-bar-item-label)) (items)))

  (test-equal "a buffer-local tool-bar-map is what the bar is built from"
    '(isearch-repeat-backward isearch-repeat-forward isearch-cancel
      isearch-exit isearch-delete-char isearch-query-replace
      isearch-occur isearch-describe-mode)
    (map (lambda (quad) (list-ref quad tool-bar-item-key)) (items)))

  ;; Emacs's `:visible` on Finish (`isearch.el:829`): "Finish" is on the
  ;; bar only once the search string has something in it, and Undo is the
  ;; fourth button until then. Evaluated when the bar is built, in the
  ;; editor's environment, which is where `string-equal` and
  ;; `isearch-string` both resolve.
  (test-equal "with nothing typed, Finish is off the bar"
    '(isearch-repeat-backward isearch-repeat-forward isearch-cancel
      isearch-delete-char isearch-query-replace isearch-occur
      isearch-describe-mode)
    (let ((saved isearch-string))
      (set! isearch-string "")
      (let ((keys (map (lambda (quad) (list-ref quad tool-bar-item-key))
                       (items))))
        (set! isearch-string saved)
        keys)))

  ;; **The icons are built, not left as forms.** The item's `:image` is
  ;; `(isearch-tool-bar-image "help")`, evaluated in tool-bar.scm's
  ;; module; a non-graphic display answers the C's fallback. If the
  ;; evaluator cannot resolve the names the expression uses - it needs
  ;; `display-color-p` and `*display-color-cells*` imported *there*,
  ;; even though tool-bar.scm's own code does not call them - the guard
  ;; answers nil and every icon silently disappears, leaving the text
  ;; labels.
  (test-equal "the search bar's icons are evaluated, and fall back on a tty"
    '((:mask heuristic) (:mask heuristic) (:mask heuristic)
      (:mask heuristic) (:mask heuristic) (:mask heuristic)
      (:mask heuristic) (:mask heuristic))
    (map (lambda (quad) (list-ref quad tool-bar-item-images)) (items))))

(set-buffer-local-value! isearch-bar-buffer 'tool-bar-map tool-bar-map)

(test-end "schemacs_editor_tool_bar_isearch")
