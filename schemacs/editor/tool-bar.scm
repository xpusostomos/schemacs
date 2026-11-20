(define-library (schemacs editor tool-bar)
  ;; This library mirrors GNU Emacs's `lisp/tool-bar.el': the mode that
  ;; turns the bar on, the keymap its items live in, the cache-built
  ;; keymap the toolkit reads, the helpers that add items, and the
  ;; default set of buttons.
  ;;
  ;; **The widget is the toolkit's.** GNU Emacs's Gtk build creates a
  ;; `GtkToolbar` in `gtkutil.c` (`xg_create_tool_bar`, `:5524`) and
  ;; fills it from the item vector this library's keymap produces; the
  ;; glyph-drawing tool bar in `xdisp.c` is compiled only for builds
  ;; without a toolkit bar (`#ifndef HAVE_EXT_TOOL_BAR`). The Gtk front
  ;; end here does the same (`pgtk.scm`), and the terminal front end has
  ;; no tool bar at all - which is also `emacs -nw`'s behaviour on a Gtk
  ;; build.
  ;;
  ;; **Icons are the same files Emacs ships.** `schemacs/etc/images`
  ;; carries the XPMs `tool-bar-setup` names (`new`, `open`, `diropen`,
  ;; `close`, `save`, `undo`, `cut`, `copy`, `paste`, `search`,
  ;; `separator`), copied from Emacs's `etc/images`; `find-image`
  ;; (`image.scm`) resolves them through `image-load-path`, and the Gtk
  ;; front end hands the file to a `GtkImage` (GdkPixbuf loads XPM
  ;; natively - measured).
  ;;
  ;; Named omissions, each because the thing it serves does not exist
  ;; here: `modifier-bar-mode`, the on-screen-keyboard tool bar (no
  ;; touch input, and no `input-decode-map` entries for its buttons), and
  ;; with it `secondary-tool-bar-map` as an *evaluated* map - the
  ;; variable is carried so a user setting it sees no error, but its
  ;; merge into the bar is not carried: Emacs's merge appends keymap
  ;; *lists*, and a keymap here is a record. `tool-bar-button-margin`
  ;; and `tool-bar-button-relief` likewise: the Gtk widget's own style
  ;; supplies both, and Emacs's default margin already means "the
  ;; toolkit's default". **A buffer-local `tool-bar-map` is read** - it
  ;; is how `isearch-mode` puts its own bar up: the buffer-local store
  ;; is keyed by the symbol, and `%tool-bar-map` asks
  ;; `local-variable-p` first, as Emacs looks up a buffer-local binding
  ;; before the global value.

  (import
    (scheme base)
    (scheme eval)
    (only (guile)
          object-address hashv-ref make-hash-table hash-ref hash-set! hash-remove!
          hash-map->list resolve-module)
    (only (schemacs editor dispnew) current-display)
    (only (srfi srfi-1) filter)
    (only (schemacs editor keymap)
          define-key lookup-key keymapp keymap-type? make-sparse-keymap
          keymap-bindings map-keymap *default-keymap*)
    (only (schemacs editor subr) define-key-after assq-delete-all)
    (only (schemacs editor fns) plist-get plist-put copy-sequence)
    (only (schemacs editor intervals) get)
    (only (schemacs editor easy-mmode) define-minor-mode)
    (only (schemacs editor custom) define-custom custom-initialize-default)
    (only (schemacs editor command) current-prefix-arg uarg->integer
          define-command)
    ;; The buffer-local read `%tool-bar-map` makes: `current-buffer`,
    ;; `local-variable-p` (`data.c:2416`) and `buffer-local-value`.
    (only (schemacs editor buffer)
          current-buffer local-variable-p buffer-local-value)
    ;; `tool-bar--image-expression` is `tool-bar.el`'s and lives in
    ;; `(schemacs editor image)` - see its note there; `isearch.scm`
    ;; needs it too and this library imports that one.
    (only (schemacs editor image)
          find-image image-mask-p display-images-p
          tool-bar--image-expression)
    ;; **These three are not for this library's own code: they are what
    ;; the image *forms* call.** `%tool-bar-eval-image` evaluates each
    ;; item's `:image` expression *in this module* (as Emacs evaluates in
    ;; its one obarray), and that expression is
    ;; `(find-image (cond ((not (display-color-p)) ...)
    ;; ((< (*display-color-cells*) 256) ...) ...))` - so the names must
    ;; be bound here or every icon silently disappears (the evaluator's
    ;; guard answers nil, and the item falls back to its text label).
    ;; Measured the hard way: moving the expression builder to
    ;; `image.scm` and dropping these made the bar text-only.
    (only (schemacs editor faces)
          face-attribute display-color-p *display-color-cells*)
    (only (schemacs editor frame)
          *frame-list* *default-frame-alist* frame-parameter
          set-frame-parameter modify-all-frames-parameters
          *tool-bar-lines-default-function*)
    (only (schemacs editor xdisp) force-mode-line-update
          *tool-bar-keymap-function*)
    (only (schemacs editor keyboard) where-is-internal)
    (only (schemacs editor menu-bar)
          menu-bar-edit-menu menu-bar-separator kill-this-buffer
          menu-find-file-existing)
    (only (schemacs editor simple) undo)
    (only (schemacs editor files) find-file save-buffer)
    (only (schemacs editor dired) dired-from-menubar)
    (only (schemacs editor isearch)
          isearch-forward
          ;; `isearch-tool-bar-image` is what the isearch bar's items
          ;; name in their `:image`; `%tool-bar-eval-image` evaluates
          ;; those forms *in this library's module*, so the name must be
          ;; imported here as well as defined there (Emacs has one
          ;; obarray and needs no such line).
          isearch-tool-bar-image))

  (export
   tool-bar-mode tool-bar-mode-variable set!tool-bar-mode-variable!
   toggle-tool-bar-mode-from-frame
   tool-bar-map
   tool-bar-make-keymap tool-bar-make-keymap-1
   tool-bar-add-item tool-bar-local-item
   tool-bar-add-item-from-menu tool-bar-local-item-from-menu
   tool-bar-setup tool-bar-separator-image-expression
   *tool-bar-position* *tool-bar-always-show-default*
   tool-bar-keymap-cache)

  (begin

    ;; The library's own module, where an image expression is evaluated.
    ;; Emacs's `eval` in `tool-bar-make-keymap-1` runs in the global
    ;; obarray; a Scheme library is the nearest stand-in for "the place
    ;; the expression was written", and it is where `find-image` and the
    ;; display predicates the expression names are imported.
    (define %tool-bar-module (resolve-module '(schemacs editor tool-bar)))

    ;;----------------------------------------------------------------
    ;; tool-bar-mode - `tool-bar.el:37`
    ;;----------------------------------------------------------------

    (define tool-bar-map (make-sparse-keymap))
    ;; ^ GNU Emacs's `tool-bar-map` (a `defvar-keymap`): "Keymap for the
    ;; tool bar. To override the global tool bar, define this variable
    ;; buffer-locally and add the items you want to it..."
    ;;
    ;; **The buffer-local half is read** (`%tool-bar-map`, below): a
    ;; buffer (an isearch's, `isearch.el:1311`) can set its own map.
    ;; The "not yet set up" test below keeps a flag rather than
    ;; Emacs's `(= 1 (length (default-value 'tool-bar-map)))`, because a
    ;; keymap here is a record without a list length.

    (define tool-bar--setup-done #f)

    (define-custom *tool-bar-position* 'top
      "Specify on which side the tool bar shall be.
Possible values are `top' (tool bar on top), `bottom' (tool bar at
bottom), `left' (tool bar on left) and `right' (tool bar on right).
This option takes effect only on graphical frames, the values `left' and
`right' only if Emacs was built with GTK, and `bottom' only on systems
besides Nextstep.  Customize `tool-bar-mode' if you want to show or hide
the tool bar."
      :type '(choice (const top) (const bottom) (const left) (const right))
      :group 'frames
      ;; The procedure itself, not its name: `custom-declare-variable`
      ;; calls whichever it is handed (the `tab-line.scm` clause shape).
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             ((get symbol 'custom-writer) symbol value)
             (modify-all-frames-parameters
              (list (cons 'tool-bar-position value)))))

    (define *tool-bar-always-show-default* (make-parameter #f))
    ;; ^ GNU Emacs's `tool-bar-always-show-default` (a defcustom, "If
    ;; non-nil, `tool-bar-mode' only shows the default tool bar."). With
    ;; one tool-bar map here the two arms name the same map; it is
    ;; carried so a caller that sets it gets the variable it expects.

    (define (tool-bar--default-map)
      ;; Emacs's `(default-value 'tool-bar-map)`: the global map, which
      ;; here is the only one.
      tool-bar-map)

    (define (%tool-bar-map)
      ;; GNU Emacs's read of the (buffer-local-aware) `tool-bar-map`.
      ;; **This is what puts the isearch bar up**: `isearch-mode` sets
      ;; `tool-bar-map` buffer-locally to `isearch-tool-bar-map`
      ;; (`isearch.el:1311`), and this answers that map until the
      ;; search's exit removes the binding. `tool-bar-always-show-
      ;; default` asks for the global map instead - Emacs's
      ;; `tool-bar--cache-key` makes that choice, and it is made in the
      ;; same place here so the cache key and the map built cannot
      ;; disagree.
      ;;--------------------------------------------------------------
      (cond
       ((*tool-bar-always-show-default*) tool-bar-map)
       (else
        (let ((buffer (current-buffer)))
          (if (and buffer (local-variable-p 'tool-bar-map buffer))
              (buffer-local-value buffer 'tool-bar-map)
              tool-bar-map)))))

    (define-minor-mode tool-bar-mode
      "Toggle the tool bar in all graphical frames (Tool Bar mode).

See `tool-bar-add-item' and `tool-bar-add-item-from-menu' for
conveniently adding tool bar items."
      :init-value #t
      :global #t
      ;; "It's defined in C/cus-start, this stops the d-m-m macro
      ;; defining it again" - there is no C variable here, so the
      ;; macro's own variable is the mode's.
      (let ((val (if (tool-bar-mode-variable) 1 0)))
        (for-each (lambda (frame)
                    (set-frame-parameter frame 'tool-bar-lines val))
                  (*frame-list*))
        ;; "If the user has given `default-frame-alist' a
        ;; `tool-bar-lines' parameter, replace it."
        (if (assq 'tool-bar-lines (*default-frame-alist*))
            (*default-frame-alist*
             (cons (cons 'tool-bar-lines val)
                   (assq-delete-all 'tool-bar-lines
                                    (*default-frame-alist*))))))
      ;; "not yet setup"
      (when (and (tool-bar-mode-variable) (not tool-bar--setup-done))
        (tool-bar-setup)))

    (define-command (toggle-tool-bar-mode-from-frame . args)
      ;; GNU Emacs's `toggle-tool-bar-mode-from-frame` (`tool-bar.el:70`):
      ;; "Toggle tool bar on or off, based on the status of the current
      ;; frame." The menu item that calls it passes `toggle`.
      "Toggle tool bar on or off, based on the status of the current frame.
See `tool-bar-mode' for more information."
      (interactive (list (or (current-prefix-arg) 'toggle)))
      (let ((arg (and (pair? args) (car args))))
        (if (eq? arg 'toggle)
            (tool-bar-mode
             (if (> (frame-parameter #f 'tool-bar-lines) 0) 0 1))
            (tool-bar-mode arg))))

    ;;----------------------------------------------------------------
    ;; The cache-built keymap - `tool-bar.el:126`
    ;;----------------------------------------------------------------

    (define tool-bar-keymap-cache (make-hash-table))

    (define (tool-bar--cache-key)
      ;; Emacs's `(cons (frame-terminal) (sxhash-eq ...))`. The terminal
      ;; is the current display object here, and an object's address is
      ;; its identity in Guile - which is what `sxhash-eq` is asked for.
      (cons (current-display)
            (object-address (%tool-bar-map))))

    (define (tool-bar--flush-cache)
      ;; "Remove all cached entries that refer to the current
      ;; `tool-bar-map'." Emacs compares the stored hash with a fresh
      ;; one; the same rule, over the entries this tree's cache holds.
      (let* ((id (object-address (%tool-bar-map)))
             (entries (hash-map->list
                       (lambda (k v) (and (equal? (cdr k) id) k))
                       tool-bar-keymap-cache)))
        (for-each (lambda (k) (hash-remove! tool-bar-keymap-cache k))
                  (filter (lambda (k) k) entries))))

    (define (%nthcdr-safe lst n)
      ;; Elisp's `nthcdr` answers nil past the end; Scheme's `list-tail`
      ;; is an error there. A separator item - `(menu-item "--")` - is
      ;; shorter than the property offsets below.
      ;;--------------------------------------------------------------
      (let loop ((rest lst) (k n))
        (cond ((= k 0) rest)
              ((pair? rest) (loop (cdr rest) (- k 1)))
              (else '()))))

    (define (%tool-bar-plist bind)
      ;; The C's `(nthcdr (if (consp (nth 4 bind)) 5 4) bind)` over a
      ;; *flattened* keymap element `(KEY menu-item CAPTION DEF
      ;; [KEY-CACHE] . PROPS)`. Here `map-keymap` hands the key and the
      ;; binding separately, so BIND is `(menu-item CAPTION DEF
      ;; [KEY-CACHE] . PROPS)` and everything is one index earlier: the
      ;; slot after DEF is 3, and the properties start at 4 when that
      ;; slot holds a cached-key list and at 3 otherwise.
      ;;--------------------------------------------------------------
      (let ((after (%nthcdr-safe bind 3)))
        (%nthcdr-safe bind
                      (if (and (pair? after) (pair? (car after))) 4 3))))

    (define (%tool-bar-eval-image image-exp)
      ;; `(eval image-exp)` with Emacs's `(fboundp (car image-exp))`
      ;; guard: a form whose head names nothing is left alone, and one
      ;; that raises answers nil, as `find-image` does for a spec it
      ;; cannot satisfy.
      ;;--------------------------------------------------------------
      (guard (e (else #f))
        (and (procedure? (eval (car image-exp) %tool-bar-module))
             (eval image-exp %tool-bar-module))))

    (define (%tool-bar-transform-binding bind)
      ;; The loop body of `tool-bar-make-keymap-1`
      ;; (`tool-bar.el:170`): an item whose `:image` is a *form* gets it
      ;; evaluated here, and the result - with `:mask heuristic` when
      ;; the mask is not known - written back over the `:image` slot.
      ;;--------------------------------------------------------------
      ;; The C's `(and (eq (car-safe (cdr-safe bind)) 'menu-item) ...)`
      ;; reads a *flattened* entry `(KEY menu-item ...)`; a binding from
      ;; `map-keymap` here is the item itself, so its car is the test.
      (if (and (pair? bind)
               (eq? (car bind) 'menu-item)
               (let ((image-exp (plist-get (%tool-bar-plist bind) ':image)))
                 (and (pair? image-exp)
                      (not (eq? (car image-exp) 'image))
                      (procedure? (guard (e (else #f))
                                   (eval (car image-exp)
                                         %tool-bar-module))))))
          (let* ((image-exp (plist-get (%tool-bar-plist bind) ':image))
                 (image (and (guard (e (else #f)) (display-images-p))
                             (%tool-bar-eval-image image-exp)))
                 ;; "(unless (and image (image-mask-p image)) (setq image
                 ;; (append image '(:mask heuristic))))": `(append nil
                 ;; ...)` is Elisp's; Scheme's `append` wants the empty
                 ;; list, which is the same value there.
                 (image (if (and image (image-mask-p image))
                            image
                            (append (or image '()) '(:mask heuristic))))
                 ;; `(copy-sequence bind)` - the plist is then a fresh
                 ;; list and `plist-put` can write the slot in place.
                 (copy (copy-sequence bind)))
            (plist-put (%tool-bar-plist copy) ':image image)
            copy)
          bind))

    (define (tool-bar-make-keymap-1 . args)
      ;; GNU Emacs's `tool-bar-make-keymap-1` (`tool-bar.el:166`):
      ;; "Generate an actual keymap from `tool-bar-map', without
      ;; caching. MAP is either a keymap to use as a source for menu
      ;; items, or nil, in which case the value of `tool-bar-map' is
      ;; used instead."
      ;;
      ;; **A keymap record is built, not a list.** Emacs's answer is the
      ;; source keymap's list with its items rewritten, which is still a
      ;; keymap because an Elisp keymap is a list whose car is `keymap`;
      ;; this tree's keymaps are records, so the same items are defined
      ;; into a fresh map in the same order (`define-key` prepends, so
      ;; they are defined back to front).
      ;;--------------------------------------------------------------
      (let* ((source (or (and (pair? args) (car args)) (%tool-bar-map)))
             (map (make-sparse-keymap))
             (entries '()))
        (map-keymap (lambda (key bind)
                      (set! entries (cons (cons key bind) entries)))
                    source)
        ;; ENTRIES is the walk reversed, so defining in this order puts
        ;; them back in the map's own order.
        (for-each (lambda (entry)
                    (define-key map (vector (car entry))
                                (%tool-bar-transform-binding (cdr entry))))
                  entries)
        map))

    (define (tool-bar-make-keymap . args)
      ;; GNU Emacs's `tool-bar-make-keymap` (`tool-bar.el:126`):
      ;; "Generate an actual keymap from `tool-bar-map'."
      ;;
      ;; **The secondary map is not merged** - see the header. The C's
      ;; `[tool-bar]` binding is what this replaces: the tree's keymap
      ;; lookup does not apply `:filter`, the departure `tab-bar.el`'s
      ;; port records, so the built map is bound where the filtered item
      ;; would have been looked up.
      ;;--------------------------------------------------------------
      (let* ((key (tool-bar--cache-key))
             (map (or (hash-ref tool-bar-keymap-cache key)
                      (let ((built (tool-bar-make-keymap-1)))
                        (hash-set! tool-bar-keymap-cache key built)
                        built))))
        (define-key *default-keymap* (vector 'tool-bar) map)
        map))

    ;;----------------------------------------------------------------
    ;; Adding items - `tool-bar.el:219`
    ;;----------------------------------------------------------------

    (define (tool-bar-add-item icon def key . props)
      "Add an item to the tool bar.
ICON names the image, DEF is the key definition and KEY is a symbol
for the fake function key in the menu keymap.  Remaining arguments
PROPS are additional items to add to the menu item specification.  See
Info node `(elisp)Tool Bar'.  Items are added from left to right.

ICON is the base name of a file containing the image to use.  The
function will first try to use low-color/ICON.xpm if `display-color-cells'
is less or equal to 256, then ICON.xpm, then ICON.pbm, and finally
ICON.xbm, using `find-image'.

Use this function only to make bindings in the global value of `tool-bar-map'.
To define items in any other map, use `tool-bar-local-item'."
      (apply tool-bar-local-item
             (append (list icon def key tool-bar-map) props))
      (tool-bar--flush-cache))

    (define (tool-bar-local-item icon def key map . props)
      "Add an item to the tool bar in map MAP.
ICON names the image, DEF is the key definition and KEY is a symbol
for the fake function key in the menu keymap.  Remaining arguments
PROPS are additional items to add to the menu item specification.  See
Info node `(elisp)Tool Bar'.  Items are added from left to right.

ICON is the base name of a file containing the image to use.  The
function will first try to use low-color/ICON.xpm if `display-color-cells'
is less or equal to 256, then ICON.xpm, then ICON.pbm, and finally
ICON.xbm, using `find-image'."
      (let ((image-exp (tool-bar--image-expression icon)))
        ;; `(define-key-after map (vector key) \`(menu-item
        ;; ,(symbol-name key) ,def :image ,image-exp ,@props))'
        (define-key-after map (vector key)
          (append (list 'menu-item (symbol->string key) def
                        ':image image-exp)
                  props))
        (tool-bar--flush-cache)
        (force-mode-line-update)))

    (define (tool-bar-add-item-from-menu command icon . args)
      "Define tool bar binding for COMMAND in keymap MAP using the given ICON.
This makes a binding for COMMAND in `tool-bar-map', copying its
binding from the menu bar in MAP (which defaults to `global-map'), but
modifies the binding by adding an image specification for ICON.  It
finds ICON just like `tool-bar-add-item'.  PROPS are additional
properties to add to the binding.

MAP must contain appropriate binding for `[menu-bar]' which holds a keymap.

Use this function only to make bindings in the global value of `tool-bar-map'.
To define items in any other map, use `tool-bar-local-item-from-menu'."
      (apply tool-bar-local-item-from-menu
             (append (list command icon (tool-bar--default-map)) args)))

    (define (tool-bar-local-item-from-menu command icon in-map . args)
      "Define local tool bar binding for COMMAND using the given ICON.
This makes a binding for COMMAND in IN-MAP, copying its binding from
the menu bar in FROM-MAP (which defaults to `global-map'), but
modifies the binding by adding an image specification for ICON.  It
finds ICON just like `tool-bar-add-item'.  PROPS are additional
properties to add to the binding.

FROM-MAP must contain appropriate binding for `[menu-bar]' which
holds a keymap."
      ;;
      ;; **The C reads the menu entry as an alist cell** - `(assq key
      ;; (cdr submap))` - because an Elisp keymap *is* an alist. This
      ;; tree's keymap is a record, so the same cell is read from its
      ;; bindings hash (`keymap-bindings`), which is where `define-key`
      ;; put it. And the C's `(when (and (symbolp submap) (boundp
      ;; submap)) (setq submap (eval submap)))` arm has no counterpart:
      ;; a keymap here is a value, never a symbol naming one.
      ;;--------------------------------------------------------------
      (let* ((from-map (or (and (pair? args) (car args)) *default-keymap*))
             (props (if (pair? args) (cdr args) '()))
             (menu-bar-map (lookup-key from-map (vector 'menu-bar)))
             (keys (where-is-internal command menu-bar-map #f #f #f))
             (image-exp (tool-bar--image-expression icon))
             (submap #f)
             (key #f))
        ;; "We'll pick up the last valid entry in the list of keys if
        ;; there's more than one."
        (for-each
         (lambda (k)
           (if (and (vector? k) (> (vector-length k) 1))
               (let ((m (lookup-key
                         menu-bar-map
                         (vector-copy k 0 (- (vector-length k) 1))))
                     (kk (vector-ref k (- (vector-length k) 1))))
                 (if (and (keymapp m) (symbol? kk))
                     (begin (set! submap m) (set! key kk))
                     #f))
               #f))
         keys)
        ;; The two branches of the C's `(let ((defn (assq key (cdr
        ;; submap)))) ...)'. Written over the record's bindings hash.
        (when (and (keymap-type? submap) key)
          ;; Emacs's `defn` is `(assq key (cdr submap))` - a `(KEY .
          ;; BINDING)` cell - so its `(car defn)` is the key and its
          ;; cdr is BINDING. The bindings hash answers BINDING, and the
          ;; branches below are the C's over BINDING: `(cadr defn)` is
          ;; `(car BINDING)`, and `(cdr defn)` is BINDING itself.
          (let ((binding (let ((bindings (keymap-bindings submap)))
                           (and (not (eq? bindings #f))
                                (hashv-ref bindings key #f)))))
            (cond
             ((not binding) #f)
             ;; "(eq (cadr defn) 'menu-item)": the structured item,
             ;; copied and given an image.
             ((and (pair? binding) (eq? (car binding) 'menu-item))
              (define-key-after in-map (vector key)
                (append binding (list ':image image-exp) props)))
             (else
              ;; `(setq defn (cdr defn))' makes DEFN the binding, the
              ;; cache list stripped, then `(append \`(menu-item
              ;; ,(car defn) ,rest) ...)' makes an item of it.
              (let* ((rest (and (pair? binding) (cdr binding)))
                     (rest (if (and (pair? rest) (pair? (car rest)))
                               (cdr rest)
                               rest)))
                (define-key-after in-map (vector key)
                  (append (list 'menu-item
                                (and (pair? binding) (car binding))
                                rest)
                          (list ':image image-exp)
                          props)))))))
        (tool-bar--flush-cache)
        (force-mode-line-update)))

    ;;----------------------------------------------------------------
    ;; The standard items - `tool-bar.el:326`
    ;;----------------------------------------------------------------

    (define tool-bar-separator-image-expression #f)

    (define (tool-bar-setup)
      ;; GNU Emacs's `tool-bar-setup` (`tool-bar.el:326`): "Set up some
      ;; global items. Additions/deletions up for grabs."
      ;;
      (set! tool-bar-separator-image-expression
            (tool-bar--image-expression "separator"))
      (tool-bar-add-item-from-menu find-file "new" #f
                                   ':label "New File" ':vert-only #t)
      (tool-bar-add-item-from-menu menu-find-file-existing "open" #f
                                   ':label "Open" ':vert-only #t)
      (tool-bar-add-item-from-menu dired-from-menubar "diropen" #f
                                   ':vert-only #t)
      (tool-bar-add-item-from-menu kill-this-buffer "close" #f
                                   ':vert-only #t)
      (tool-bar-add-item-from-menu save-buffer "save" #f ':label "Save")
      (define-key-after (tool-bar--default-map) (vector 'separator-1)
        menu-bar-separator)
      (tool-bar-add-item-from-menu undo "undo" #f)
      (define-key-after (tool-bar--default-map) (vector 'separator-2)
        menu-bar-separator)
      (tool-bar-add-item-from-menu (lookup-key menu-bar-edit-menu (vector 'cut))
                                   "cut" #f ':vert-only #t)
      (tool-bar-add-item-from-menu (lookup-key menu-bar-edit-menu (vector 'copy))
                                   "copy" #f ':vert-only #t)
      (tool-bar-add-item-from-menu (lookup-key menu-bar-edit-menu (vector 'paste))
                                   "paste" #f ':vert-only #t)
      (define-key-after (tool-bar--default-map) (vector 'separator-3)
        menu-bar-separator)
      (tool-bar-add-item-from-menu isearch-forward "search" #f
                                   ':label "Search" ':vert-only #t)
      (set! tool-bar--setup-done #t)
      (force-mode-line-update))

    ;;----------------------------------------------------------------
    ;; The `[tool-bar]` binding, and the mode's default for a new frame
    ;;----------------------------------------------------------------

    ;; GNU Emacs's `(global-set-key [tool-bar] '(menu-item "tool bar"
    ;; ignore :filter tool-bar-make-keymap))`. The built map is bound
    ;; over it on the first redisplay (`tool-bar-make-keymap`); the
    ;; item is here so the binding exists and reads as Emacs's does.
    (define-key *default-keymap* (vector 'tool-bar)
      (list 'menu-item "tool bar" 'ignore ':filter tool-bar-make-keymap))

    ;; What `pgtkfns.c:1532` reads at frame creation: `NILP
    ;; (Vtool_bar_mode) ? 0 : 1`. A frame made later gets the bar when
    ;; the mode is on; `tool-bar-mode` writes the parameter on every
    ;; frame when it is toggled.
    (*tool-bar-lines-default-function*
     (lambda () (if (tool-bar-mode-variable) 1 0)))

    ;; The redisplay's seam: `tool_bar_items` (`keyboard.c`) walks the
    ;; active maps for `[tool-bar]`, and what it finds there has to be
    ;; the *built* keymap - the C reaches it through the binding's
    ;; `:filter`, which this tree's keymap lookup does not apply (the
    ;; `tab-bar.el` departure). Installing the builder here is what makes
    ;; every item walk rebuild the map first, as `tab-bar-items` does.
    (*tool-bar-keymap-function* tool-bar-make-keymap)))
