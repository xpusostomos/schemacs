(define-library (schemacs editor menu)
  ;; This library mirrors GNU Emacs's `src/menu.c', the
  ;; *platform-independent* half of menu construction: it turns keymaps
  ;; into the `menu_items` vector, which a front end then walks to build
  ;; its own widgets.
  ;;
  ;; **The state is a parameter, not globals.** Emacs keeps `menu_items`,
  ;; `menu_items_used`, `menu_items_n_panes`, `menu_items_submenu_depth`
  ;; and `menu_items_inuse` as C statics and pushes them onto `specpdl`
  ;; with `save_menu_items`/`restore_menu_items` around a build - because
  ;; evaluating a `:filter` or a `:label` can start another build. That
  ;; is dynamic binding, and this tree's spelling of it is a parameter:
  ;; `(*menu-state*)` holds a `<menu-state>` and a nested build
  ;; `parameterize`s a fresh one. `menu_items_inuse`'s "Trying to use a
  ;; menu from within a menu-entry" error therefore has no counterpart -
  ;; the reentry it forbids is safe here. Named departure.
  ;;
  ;; This is the data half: `menu-bar-items` (`keyboard.scm`) feeds it,
  ;; and it feeds the front end's widget builder. Both of menu.c's other
  ;; halves are here too - `digest_single_submenu`'s `widget_value` tree,
  ;; and `find_and_call_menu_selection`, which turns a click back into
  ;; the key sequence it stands for. What is *not* here is the front
  ;; end's widget builder itself (`gtkutil.c`'s `create_menus` for Gtk),
  ;; which belongs beside the widgets it makes.
  ;;
  ;; `have-boxes` is `(display-graphic-p)`: a toolkit's menus draw real
  ;; checks and radios, a tty's do not. The TTY's `[ ]`/`( )` prefixes
  ;; are carried, but not `skp.notbuttons` - the pass that indents
  ;; earlier items in a pane once a button appears. There is no tty
  ;; menu yet to see it, and the graphical path (the one that exists)
  ;; does not run either branch.

  (import (scheme base)
          ;; `caddr' is not resolved through `(scheme base)' by the
          ;; library compiler, as elsewhere in this tree.
          (only (guile) caddr logior lognot logand)
          (only (scheme write) display)
          (only (schemacs editor keymap)
                keymap-type? keymap-prompt map-keymap)
          (only (schemacs editor subr)
                keymap-canonicalize run-hooks
                event-start posn-window posn-area posn-x-y nth)
          (only (schemacs editor frame)
                display-graphic-p frame? frame-live-p frame-output
                mouse-position selected-window window-frame window-left
                window-top window-type?)
          ;; The `hide` property of a menu's prompt - see
          ;; `x-popup-menu-1`.
          (only (schemacs editor textprop) get-text-property)
          ;; The display method that shows the menu, and the quit that
          ;; cancels it.
          (only (schemacs editor dispnew) menu-show current-display)
          (only (schemacs editor keyboard)
                parse-menu-item *item-properties*
                item-property-name item-property-enable item-property-def
                item-property-map item-property-keyeq item-property-type
                item-property-selected item-property-help))

  (export
   *menu-state* make-menu-state menu-state?
   menu-items menu-items-used menu-items-n-panes set!menu-items-n-panes!
   menu-items-submenu-depth
   init-menu-items finish-menu-items unuse-menu-items discard-menu-items
   push-menu-pane push-menu-item push-submenu-start push-submenu-end
   push-left-right-boundary
   single-keymap-panes single-menu-item keymap-panes
   list-of-items list-of-panes parse-single-submenu
   ;; The front end's tree: menu.c's `digest_single_submenu` and the
   ;; `widget_value` records it builds.
   digest-single-submenu update-submenu-strings
   <widget-value> widget-value? make-widget-value
   widget-value-name set!widget-value-name
   widget-value-value set!widget-value-value
   widget-value-key set!widget-value-key
   widget-value-lname set!widget-value-lname
   widget-value-lkey set!widget-value-lkey
   widget-value-enabled? set!widget-value-enabled!
   widget-value-help set!widget-value-help
   widget-value-contents set!widget-value-contents
   widget-value-next set!widget-value-next
   widget-value-call-data set!widget-value-call-data
   widget-value-button-type set!widget-value-button-type
   widget-value-selected? set!widget-value-selected!
   ;; The slot layout, the C's two enums.
   menu-items-pane-name menu-items-pane-prefix menu-items-pane-length
   menu-items-item-name menu-items-item-enable menu-items-item-value
   menu-items-item-equiv-key menu-items-item-definition
   menu-items-item-type menu-items-item-selected menu-items-item-help
   menu-items-item-length
   ;; What a click means: the key sequence the selected item stands for.
   find-and-call-menu-selection
   ;; `x-popup-menu` and its decoder - `menu.c:1111`, `:1433`.
   x-popup-menu x-popup-menu-1
   MENU-KEYMAPS MENU-FOR-CLICK MENU-KBD-NAVIGATION
   *x-pre-popup-menu-hook*)

  (begin

    ;; `menu_item_pane_idx' and `menu_item_idx' (`keyboard.h:358').
    (define menu-items-pane-name 1)
    (define menu-items-pane-prefix 2)
    (define menu-items-pane-length 3)
    (define menu-items-item-name 0)
    (define menu-items-item-enable 1)
    (define menu-items-item-value 2)
    (define menu-items-item-equiv-key 3)
    (define menu-items-item-definition 4)
    (define menu-items-item-type 5)
    (define menu-items-item-selected 6)
    (define menu-items-item-help 7)
    (define menu-items-item-length 8)

    (define-record-type <menu-state>
      (make-menu-state items allocated used n-panes submenu-depth inuse)
      menu-state?
      (items          menu-state-items          %set!menu-state-items!)
      (allocated      menu-state-allocated      %set!menu-state-allocated!)
      (used           menu-state-used           %set!menu-state-used!)
      (n-panes        menu-state-n-panes        %set!menu-state-n-panes!)
      (submenu-depth  menu-state-submenu-depth  %set!menu-state-submenu-depth!)
      (inuse          menu-state-inuse?         %set!menu-state-inuse!))

    (define *menu-state*
      (make-parameter (make-menu-state (make-vector 60 #f) 60 0 0 0 #f)))
    ;; ^ the C's five statics, as one parameter - see the header.

    (define (menu-items) (menu-state-items (*menu-state*)))
    (define (menu-items-used) (menu-state-used (*menu-state*)))
    (define (menu-items-n-panes) (menu-state-n-panes (*menu-state*)))
    (define (set!menu-items-n-panes! n)
      ;; `menu_items_n_panes = submenu_n_panes[i]` - `set_frame_menubar`
      ;; sets it before every `digest_single_submenu` because the digest
      ;; decides from it whether a single pane's items hang off the root.
      ;;--------------------------------------------------------------
      (%set!menu-state-n-panes! (*menu-state*) n))
    (define (menu-items-submenu-depth)
      (menu-state-submenu-depth (*menu-state*)))

    (define (ensure-menu-items count)
      ;; GNU Emacs's `ensure_menu_items': room for COUNT more slots. The
      ;; C asks `larger_vector` for INT_MAX and lets it choose the new
      ;; size; Guile has no such call, so this copies once, to double the
      ;; allocation or the need, whichever is larger.
      ;;--------------------------------------------------------------
      (let* ((state (*menu-state*))
             (allocated (menu-state-allocated state))
             (used (menu-state-used state))
             (missing (- count (- allocated used))))
        (when (> missing 0)
          (let* ((new-size (max (+ allocated count) (* 2 (max allocated 1))))
                 (new (make-vector new-size #f))
                 (old (menu-state-items state)))
            (let loop ((i 0))
              (when (< i used)
                (vector-set! new i (vector-ref old i))
                (loop (+ i 1))))
            (%set!menu-state-items! state new)
            (%set!menu-state-allocated! state new-size)))))

    (define (init-menu-items)
      (let ((state (*menu-state*)))
        (%set!menu-state-used! state 0)
        (%set!menu-state-n-panes! state 0)
        (%set!menu-state-submenu-depth! state 0)
        (%set!menu-state-inuse! state #t)))

    (define (finish-menu-items) #t)
    (define (unuse-menu-items) (%set!menu-state-inuse! (*menu-state*) #f))

    (define (discard-menu-items)
      ;; The C frees a vector over 200 slots and keeps a smaller one.
      (let ((state (*menu-state*)))
        (when (> (menu-state-allocated state) 200)
          (%set!menu-state-items! state (make-vector 60 #f))
          (%set!menu-state-allocated! state 60))
        (%set!menu-state-inuse! state #f)))

    (define (push-submenu-start)
      (ensure-menu-items 1)
      (let ((state (*menu-state*)))
        (vector-set! (menu-state-items state) (menu-state-used state) #f)
        (%set!menu-state-used! state (+ (menu-state-used state) 1))
        (%set!menu-state-submenu-depth!
         state (+ (menu-state-submenu-depth state) 1))))

    (define (push-submenu-end)
      (ensure-menu-items 1)
      (let ((state (*menu-state*)))
        (vector-set! (menu-state-items state) (menu-state-used state) 'lambda)
        (%set!menu-state-used! state (+ (menu-state-used state) 1))
        (%set!menu-state-submenu-depth!
         state (- (menu-state-submenu-depth state) 1))))

    (define (push-left-right-boundary)
      (ensure-menu-items 1)
      (let ((state (*menu-state*)))
        (vector-set! (menu-state-items state) (menu-state-used state) 'quote)
        (%set!menu-state-used! state (+ (menu-state-used state) 1))))

    (define (push-menu-pane name prefix)
      (ensure-menu-items menu-items-pane-length)
      (let ((state (*menu-state*)))
        (when (= 0 (menu-state-submenu-depth state))
          (%set!menu-state-n-panes! state (+ (menu-state-n-panes state) 1)))
        (vector-set! (menu-state-items state) (menu-state-used state) #t)
        (vector-set! (menu-state-items state) (+ (menu-state-used state) 1) name)
        (vector-set! (menu-state-items state) (+ (menu-state-used state) 2)
                     prefix)
        (%set!menu-state-used!
         state (+ (menu-state-used state) menu-items-pane-length))))

    (define (push-menu-item name enable key def equiv type selected help)
      ;; The C's `push_menu_item', slot for slot - see the enum.
      (ensure-menu-items menu-items-item-length)
      (let* ((state (*menu-state*))
             (i (menu-state-used state))
             (items (menu-state-items state)))
        (vector-set! items (+ i menu-items-item-name) name)
        (vector-set! items (+ i menu-items-item-enable) enable)
        (vector-set! items (+ i menu-items-item-value) key)
        (vector-set! items (+ i menu-items-item-equiv-key) equiv)
        (vector-set! items (+ i menu-items-item-definition) def)
        (vector-set! items (+ i menu-items-item-type) type)
        (vector-set! items (+ i menu-items-item-selected) selected)
        (vector-set! items (+ i menu-items-item-help) help)
        (%set!menu-state-used! state (+ i menu-items-item-length))))

    (define (string-first-char string)
      (if (> (string-length string) 0) (string-ref string 0) #\nul))

    (define (single-keymap-panes keymap pane-name prefix maxdepth)
      ;; GNU Emacs's `single_keymap_panes' (`menu.c:267').
      ;;--------------------------------------------------------------
      (when (> maxdepth 0)
        (push-menu-pane pane-name prefix)
        (let ((pending-maps '()))
          ;; The C passes one `skp` struct to `single_menu_item`; the
          ;; only part of it this path uses is `pending_maps`, so the
          ;; per-map walk closes over it.
          (map-keymap
           (lambda (key item)
             (single-menu-item key item maxdepth
                               (lambda (map name key)
                                 (set! pending-maps
                                       (cons (list map name key) pending-maps)))))
           (keymap-canonicalize keymap))
          ;; Submenus which want to be panes at this level. The C's
          ;; `pending_maps` is built with `Fcons` and walked from its
          ;; head, so the LAST one encountered is made first - the list
          ;; is walked as it stands, not reversed.
          (for-each
           (lambda (entry)
             (single-keymap-panes (car entry) (cadr entry) (caddr entry)
                                  (- maxdepth 1)))
           pending-maps))))

    (define (single-menu-item key item maxdepth pending)
      ;; GNU Emacs's `single_menu_item' (`menu.c:314'). PENDING is the
      ;; caller's `pending_maps` sink, called as
      ;; `(PENDING MAP NAME KEY)` for an enabled `@` pane.
      ;;--------------------------------------------------------------
      (when (parse-menu-item item 0)
        (let* ((map (vector-ref *item-properties* item-property-map))
               (enabled (vector-ref *item-properties* item-property-enable))
               (item-string (vector-ref *item-properties* item-property-name))
               (graphic (display-graphic-p)))
          (cond
           ((and map (char=? (string-first-char item-string) #\@))
            ;; An enabled separate pane, remembered for the caller.
            (when enabled (pending map item-string key)))
           (else
            ;; Simulate radio buttons and toggles as text on a tty; a
            ;; toolkit draws them.
            (unless graphic
              (let ((type (vector-ref *item-properties* item-property-type)))
                (when type
                  (let ((selected (vector-ref *item-properties*
                                              item-property-selected)))
                    (set! item-string
                          (string-append
                           (cond ((eq? type ':toggle)
                                  (if selected "[X] " "[ ] "))
                                 ((eq? type ':radio)
                                  (if selected "(*) " "( ) "))
                                 (else ""))
                           item-string))))))
            ;; A tty marks a submenu with a trailing " >".
            (when (and (not graphic) map)
              (set! item-string (string-append item-string " >")))
            (push-menu-item item-string enabled key
                            (vector-ref *item-properties* item-property-def)
                            (vector-ref *item-properties* item-property-keyeq)
                            (vector-ref *item-properties* item-property-type)
                            (vector-ref *item-properties* item-property-selected)
                            (vector-ref *item-properties* item-property-help))
            ;; A toolkit displays the submenu as a submenu.
            (when (and graphic map enabled)
              (push-submenu-start)
              (single-keymap-panes map #f key (- maxdepth 1))
              (push-submenu-end)))))))

    (define (keymap-panes keymaps)
      ;; GNU Emacs's `keymap_panes' (`menu.c:440'): one pane per keymap,
      ;; MAXDEPTH 10.
      (init-menu-items)
      (for-each (lambda (keymap)
                  (single-keymap-panes keymap (keymap-prompt keymap) #f 10))
                keymaps)
      (finish-menu-items))

    (define (list-of-items pane)
      ;; GNU Emacs's `list_of_items' (`menu.c:461'): the alist form
      ;; `x-popup-menu` takes.
      (for-each
       (lambda (item)
         (cond
          ((string? item)
           (push-menu-item item #f #f #t #f #f #f #f))
          ((pair? item)
           (push-menu-item (car item) #t (cdr item) #t #f #f #f #f))
          (else (push-left-right-boundary))))
       pane))

    (define (list-of-panes menu)
      ;; GNU Emacs's `list_of_panes' (`menu.c:486').
      (init-menu-items)
      (for-each
       (lambda (elt)
         (let ((pane-name (car elt))
               (pane-data (cdr elt)))
           (unless (string? pane-name)
             (error "Wrong type argument: stringp" pane-name))
           (push-menu-pane pane-name #f)
           (unless (pair? pane-data)
             (error "Wrong type argument: consp" pane-data))
           (list-of-items pane-data)))
       menu)
      (finish-menu-items))

    (define (parse-single-submenu item-key item-name maps)
      ;; GNU Emacs's `parse_single_submenu' (`menu.c:521'): the menu bar
      ;; item ITEM-KEY/ITEM-NAME whose contents come from the list of
      ;; keymaps MAPS. Answers whether a top-level *command* was among
      ;; them (which is what makes a one-item menu a button).
      ;;
      ;; **The caller owns `init_menu_items`.** The C's caller
      ;; (`set_frame_menubar`) initializes ONCE and then appends every
      ;; menu bar item's panes into the same array, because the whole
      ;; array is what `find_and_call_menu_selection` later indexes;
      ;; `keymap_panes` and `list_of_panes` are the other two callers and
      ;; each does its own. This used to initialize and finish here,
      ;; which was invisible while it had one caller per array and makes
      ;; the bar impossible - each item's panes would discard the last.
      ;;--------------------------------------------------------------
      (let ((top-level-items #f))
        (for-each
         (lambda (map)
           (if (not (keymap-type? map))
               (begin
                 (set! top-level-items #t)
                 (push-menu-pane #f #f)
                 (push-menu-item item-name #t item-key map #f #f #f #f))
               (single-keymap-panes
                map (or (keymap-prompt map) item-name) item-key 10)))
         maps)
        top-level-items))

    ;;----------------------------------------------------------------
    ;; `widget_value` and `digest_single_submenu`
    ;;
    ;; The C's `struct widget_value' (`lwlib-widget.h', which `menu.h'
    ;; includes) is the front end's tree: a name, the Lisp strings kept
    ;; for GC (`lname'/`lkey'), the C strings derived from them
    ;; (`name'/`key'), a value that is 1 for a pane, the item's index in
    ;; `menu_items' (`call_data'), the button type and its selected flag.
    ;; This tree has no GC-moving strings, so `name' is `lname' - the
    ;; two-string dance exists only because small Lisp strings move.
    ;;----------------------------------------------------------------

    (define-record-type <widget-value>
      (make-widget-value name value enabled help)
      widget-value?
      (name         widget-value-name     set!widget-value-name)
      (value        widget-value-value    set!widget-value-value)
      (key          widget-value-key      set!widget-value-key)
      (lname        widget-value-lname    set!widget-value-lname)
      (lkey         widget-value-lkey     set!widget-value-lkey)
      (enabled      widget-value-enabled? set!widget-value-enabled!)
      (help         widget-value-help     set!widget-value-help)
      (contents     widget-value-contents set!widget-value-contents)
      (next         widget-value-next     set!widget-value-next)
      (call-data    widget-value-call-data set!widget-value-call-data)
      (button-type  widget-value-button-type set!widget-value-button-type)
      (selected     widget-value-selected? set!widget-value-selected!))

    (define (digest-single-submenu start end top-level-items)
      ;; GNU Emacs's `digest_single_submenu' (`menu.c:619'): build the
      ;; `<widget-value>' tree for the `menu_items' slice START..END.
      ;;
      ;; The loop is the C's, marker for marker: #f opens a submenu,
      ;; `lambda' closes it, #t is a pane, `quote' is the left/right
      ;; boundary. Emacs's character-set encoding branches are not
      ;; carried - a Scheme string is already the front end's encoding.
      ;;--------------------------------------------------------------
      (let ((first (make-widget-value "menu" #f #t #f))
            (save-wv #f)
            (prev-wv #f)
            (submenu-stack '())
            (panes-seen #f))
        (set!widget-value-button-type first 'none)
        (let loop ((i start))
          (when (< i end)
            (let ((slot (vector-ref (menu-items) i)))
              (cond
               ((eq? slot #f)
                (set! submenu-stack (cons save-wv submenu-stack))
                (set! save-wv prev-wv)
                (set! prev-wv #f)
                (loop (+ i 1)))
               ((eq? slot 'lambda)
                (set! prev-wv save-wv)
                (set! save-wv (car submenu-stack))
                (set! submenu-stack (cdr submenu-stack))
                (loop (+ i 1)))
               ((and (eq? slot #t) (not (null? submenu-stack)))
                (loop (+ i menu-items-pane-length)))
               ((eq? slot 'quote)
                (loop (+ i 1)))
               ((eq? slot #t)
                ;; A new pane.
                (set! panes-seen #t)
                (let* ((pane-name (vector-ref (menu-items)
                                              (+ i menu-items-pane-name)))
                       (pane-string (or pane-name "")))
                  ;; One top-level pane: its items go straight under
                  ;; the menu.
                  (when (= 1 (menu-items-n-panes))
                    (set! pane-string ""))
                  (if (not (string=? pane-string ""))
                      (let ((wv (make-widget-value #f 1 #t #f)))
                        (if save-wv
                            (set!widget-value-next save-wv wv)
                            (set!widget-value-contents first wv))
                        (set!widget-value-lname wv pane-name)
                        (set!widget-value-button-type wv 'none)
                        (set! save-wv wv))
                      (set! save-wv first)))
                (set! prev-wv #f)
                (loop (+ i menu-items-pane-length)))
               (else
                ;; An item within the current pane.
                (unless panes-seen
                  (error "all menu items should be contained in panes"))
                (let* ((item-name (vector-ref (menu-items)
                                              (+ i menu-items-item-name)))
                       (enable (vector-ref (menu-items)
                                           (+ i menu-items-item-enable)))
                       (descrip (vector-ref (menu-items)
                                            (+ i menu-items-item-equiv-key)))
                       (def (vector-ref (menu-items)
                                        (+ i menu-items-item-definition)))
                       (type (vector-ref (menu-items)
                                         (+ i menu-items-item-type)))
                       (selected (vector-ref (menu-items)
                                             (+ i menu-items-item-selected)))
                       (help (vector-ref (menu-items)
                                         (+ i menu-items-item-help)))
                       (wv (make-widget-value #f #f (not (not enable))
                                              (and (string? help) help))))
                  (if prev-wv
                      (set!widget-value-next prev-wv wv)
                      (set!widget-value-contents save-wv wv))
                  (set!widget-value-lname wv item-name)
                  (when descrip
                    (set!widget-value-lkey wv descrip))
                  (when def
                    (set!widget-value-call-data wv i))
                  (set!widget-value-button-type
                   wv (cond ((not type) 'none)
                            ((eq? type ':radio) 'radio)
                            ((eq? type ':toggle) 'toggle)
                            (else (error "bad button type" type))))
                  (set!widget-value-selected! wv (not (not selected)))
                  (set! prev-wv wv)
                  (loop (+ i menu-items-item-length))))))))
        ;; One "menu item" that was really a button comes back alone.
        (if (and top-level-items
                 (widget-value-contents first)
                 (not (widget-value-next (widget-value-contents first))))
            (widget-value-contents first)
            first)))

    (define (update-submenu-strings first-wv)
      ;; GNU Emacs's `update_submenu_strings' (`menu.c:843'): move the
      ;; Lisp names into `name'/`key', and drop a leading `@' from a
      ;; separate-pane name.
      ;;
      ;; The C does this after the tree is built because GC may move the
      ;; strings while it is built; Scheme strings do not move, so this
      ;; exists for the `@' rule and for shape.
      ;;--------------------------------------------------------------
      (let loop ((wv first-wv))
        (when wv
          (when (string? (widget-value-lname wv))
            (set!widget-value-name wv (widget-value-lname wv))
            (when (eqv? 1 (widget-value-value wv))
              (when (and (> (string-length (widget-value-name wv)) 0)
                         (char=? (string-ref (widget-value-name wv) 0) #\@))
                (set!widget-value-name wv
                      (substring (widget-value-name wv) 1
                                 (string-length (widget-value-name wv)))))
              (set!widget-value-value wv #f)))
          (when (string? (widget-value-lkey wv))
            (set!widget-value-key wv (widget-value-lkey wv)))
          (when (widget-value-contents wv)
            (update-submenu-strings (widget-value-contents wv)))
          (loop (widget-value-next wv)))))

    ;;----------------------------------------------------------------
    ;; The selection - what happens when a menu item is clicked
    ;;----------------------------------------------------------------

    (define (find-and-call-menu-selection items used selected emit)
      ;; GNU Emacs's `find_and_call_menu_selection' (`menu.c:876'): walk
      ;; the `menu_items` array for the item whose index is SELECTED and
      ;; hand the front end the *key sequence* it stands for - the
      ;; `(menu-bar)` prefix, every submenu prefix above it, its own
      ;; pane's prefix, and finally the item's own key.
      ;;
      ;; **EMIT is the keyboard buffer.** The C stores one
      ;; `MENU_BAR_EVENT` per element with `kbd_buffer_store_event`, and
      ;; `make_lispy_event` turns each into `event->arg` - except the
      ;; first, whose argument is the frame, which becomes the symbol
      ;; `menu-bar` (`keyboard.c:7231`). This tree's reader is the front
      ;; end's queue, so the same values are handed to EMIT in the same
      ;; order and the front end queues them; EMIT is called with
      ;; `menu-bar`, then each non-nil subprefix, then the pane's prefix,
      ;; then the item's value. That is a departure in *where* they go
      ;; and none at all in what they are.
      ;;
      ;; **ITEMS is the frame's own snapshot**, not the live array: the
      ;; C's `f->menu_bar_vector`, which `set_frame_menubar` stores
      ;; precisely so that a rebuild later cannot move the indices the
      ;; widgets were made with.
      ;;
      ;; The C walks the array with a prefix stack indexed by depth; so
      ;; does this, and `#f` in the stack is the C's nil.
      ;;--------------------------------------------------------------
      (let ((subprefix-stack (make-vector (max used 1) #f))
            (submenu-depth 0))
        (let loop ((i 0) (prefix #f) (entry #f))
          (when (< i used)
            (let ((slot (vector-ref items i)))
              (cond
               ;; A submenu opens: remember where we were and descend.
               ((not slot)
                (vector-set! subprefix-stack submenu-depth prefix)
                (set! submenu-depth (+ submenu-depth 1))
                (loop (+ i 1) entry entry))
               ;; A submenu closes: back to the prefix it was under.
               ((eq? slot 'lambda)
                (set! submenu-depth (- submenu-depth 1))
                (loop (+ i 1) (vector-ref subprefix-stack submenu-depth)
                      entry))
               ;; A pane: its prefix is what the next items descend from.
               ((eq? slot #t)
                (loop (+ i menu-items-pane-length)
                      (vector-ref items (+ i menu-items-pane-prefix))
                      entry))
               (else
                (set! entry (vector-ref items (+ i menu-items-item-value)))
                (if (not (= selected i))
                    (loop (+ i menu-items-item-length) prefix entry)
                    (begin
                      (emit 'menu-bar)
                      (let loop2 ((j 0))
                        (when (< j submenu-depth)
                          (let ((sub (vector-ref subprefix-stack j)))
                            (when sub (emit sub)))
                          (loop2 (+ j 1))))
                      (when prefix (emit prefix))
                      (emit entry))))))))))


    ;;----------------------------------------------------------------
    ;; `x-popup-menu` - the menu a position names, shown on its display
    ;;----------------------------------------------------------------
    ;;
    ;; GNU Emacs's `x_popup_menu_1` (`menu.c:1111`) and its DEFUN
    ;; (`:1433`). The work is three steps, and each is the C's: decode
    ;; POSITION into a frame and a screen position, parse MENU into
    ;; `menu_items`, and call the display's `menu_show_hook`.
    ;;
    ;; **The menu is `menu_items`, as it is in the C.** `tty_menu_show`
    ;; reads that array, so the port has to build it here rather than
    ;; hand the display a tree - see the note on `menu-show` in
    ;; `dispnew.scm`.
    ;;--------------------------------------------------------------

    ;; The flags of `enum menu_flags` (`menu.h:27`).
    (define MENU-KEYMAPS 1)
    (define MENU-FOR-CLICK 2)
    (define MENU-KBD-NAVIGATION 4)

    (define *x-pre-popup-menu-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `x-pre-popup-menu-hook` (`menu.c`): "Normal hook run
    ;; before a popup menu is displayed for the first time." The C runs
    ;; it with `run_hook (Qx_pre_popup_menu_hook)` after the items are
    ;; parsed and before the display.

    (define (%car-safe x) (and (pair? x) (car x)))
    (define (%cdr-safe x) (and (pair? x) (cdr x)))
    ;; ^ lisp.h's `CAR_SAFE`/`CDR_SAFE` macros, which `x_popup_menu_1`
    ;; is written in. (Lisp's `car-safe`/`cdr-safe` are *data.c*
    ;; functions and a different thing; Emacs's decode also uses the
    ;; unsafe `Fcar`, but on `nil` it answers nil, which is this.)

    (define (menu-position-decode position)
      ;; The first half of `x_popup_menu_1` (`menu.c:1130'): "Decode the
      ;; first argument: find the window and the coordinates." Answers
      ;; `(values WINDOW X Y FLAGS)` - WINDOW a window or a frame, X and
      ;; Y the offsets from its own top left.
      ;;
      ;; **A posn whose part-of-window is `tab-bar` means "the current
      ;; mouse position"** (`menu.c:1135', `(EQ (XCAR (XCDR position)),
      ;; Qtab_bar)`). That is the case a tab-bar click takes: its posn
      ;; names the frame, so `popup-menu-normalize-position` leaves it
      ;; alone (`posnp` answers nil for a frame) and it arrives here
      ;; whole. Before this arm existed the posn was read as an event,
      ;; `event-start` answered its `tab-bar` part, and the menu died
      ;; with "Wrong type argument: windowp (#f)" - the tab bar's
      ;; right-click context menu could never open.
      ;;
      ;; **The keyboard-navigation flag is set for a menu-bar position.**
      ;; The C sets it when the position's part-of-window is `menu-bar`
      ;; and it was not built from the very event being handled - "this
      ;; was made by hand, by F10". With no mouse at all that is every
      ;; menu-bar position, so the test is the part-of-window alone.
      ;;--------------------------------------------------------------
      (cond
       ;; "This is an obsolete call, which wants us to precompute the
       ;; keybinding equivalents" - nil position.
       ((not position)
        (values #f 0 0 0))
       ;; `t`, a position naming the menu bar or the tool bar, or a posn
       ;; whose part-of-window is `tab-bar': the current mouse position.
       ((or (eq? position #t)
            (let ((head (%car-safe position)))
              (or (memq head '(menu-bar tab-bar tool-bar))
                  (eq? (%car-safe (%cdr-safe position)) 'tab-bar))))
        ;; "Use the mouse's current position." The C asks the terminal's
        ;; mouse_position_hook; `mouse-position` is the Lisp-level same
        ;; call. A mouseless terminal answers `(FRAME #f . #f)` and the
        ;; C's fallback for that is x=0, y=0.
        (let ((mp (mouse-position)))
          (values (car mp) (or (cadr mp) 0) (or (cddr mp) 0) 0)))
       ;; `<(XOFFSET YOFFSET) WINDOW>` - the form
       ;; `popup-menu-normalize-position` produces. The C's test is
       ;; `CONSP (Fcar (position))`: a *list* in the car is the offset
       ;; pair, anything else - a symbol, as a menu's position has - is
       ;; an event.
       ;; `((X Y) WINDOW)` - the form `popup-menu-normalize-position`
       ;; produces. The C's test is `CONSP (Fcar (position))` and its
       ;; reads are `x = XCAR (tem); y = Fcar (XCDR (tem))` - a
       ;; *two-element list*, not a dotted pair.
       ((pair? (car position))
        (let ((xy (car position)))
          (values (if (pair? (cdr position)) (cadr position) #f)
                  (car xy)
                  (car (cdr xy))
                  0)))
       (else
        ;; An event, or the position `popup-menu` builds for a menu-bar
        ;; item - `(MENU-SYMBOL (FRAME (menu-bar) (X . Y) 0))` - read
        ;; through `EVENT_START`/`POSN_*`, as the C's macros do.
        (let* ((tem (%car-safe (%cdr-safe position)))        ; EVENT_START
               (window (%car-safe tem))                      ; POSN_WINDOW
               (area (%car-safe (%cdr-safe tem)))            ; POSN_POSN
               (xy (%car-safe (%cdr-safe (%cdr-safe tem))))  ; WINDOW_POSN
               ;; "menuflags |= MENU_FOR_CLICK" - the event path is a
               ;; click as far as `tty_menu_activate` is concerned, and
               ;; the flag is what makes *cancelling* such a menu pop it
               ;; down quietly instead of signalling quit
               ;; (`term.c:4257`: "Make Cancel equivalent to C-g unless
               ;; FOR_CLICK"). That includes the position `popup-menu`
               ;; constructs for F10.
               ;; The C tests `CONSP (tem2) && EQ (XCAR (tem2),
               ;; Qmenu_bar)`: the area of an F10 position is the *list*
               ;; `(menu-bar)` (the `(MENU-SYMBOL (FRAME (menu-bar)
               ;; (X . Y) 0))` `popup-menu` builds), and its car is the
               ;; symbol. Testing the area itself against the symbol was
               ;; wrong and cost the tty menus their arrow-key
               ;; navigation.
               (flags (logior MENU-FOR-CLICK
                              (if (and (pair? area) (eq? (car area) 'menu-bar))
                                  MENU-KBD-NAVIGATION
                                  0))))
          ;; "If a click happens in an external tool bar or a detached
          ;; tool bar, x and y is NIL. In that case, use the current
          ;; mouse position." (`menu.c:1150') - which is also the
          ;; `(menu-bar)` position popup-menu builds for F10.
          (if (not xy)
              (let ((mp (mouse-position)))
                (values (car mp) (or (cadr mp) 0) (or (cddr mp) 0) flags))
              (values window (%car-safe xy) (%cdr-safe xy) flags))))))

    (define (x-popup-menu-1 position menu)
      ;; GNU Emacs's `x_popup_menu_1` (`menu.c:1111`).
      ;;--------------------------------------------------------------
      (if (not position)
          #f
          (call-with-values
              (lambda () (menu-position-decode position))
            (lambda (window x y flags)
              (let* ((frame (cond ((frame? window) window)
                                  ((window-type? window)
                                   (window-frame window))
                                  (else
                                   (error "Wrong type argument: windowp"
                                          window))))
                     ;; "Clicks in the text area ... are relative to the
                     ;; top-left edge of the text area" (`:1242'). A
                     ;; terminal's text area begins at the window's own
                     ;; left and top.
                     (xpos (if (frame? window) 0 (window-left window)))
                     (ypos (if (frame? window) 0 (window-top window))))
                (if (not (frame-live-p frame))
                    #f
                    (let* ((xpos (+ xpos x))
                           (ypos (+ ypos y))
                           (keymap (and (keymap-type? menu) menu))
                           (title #f))
                      ;; "Now parse the lisp menus."
                      (cond
                       (keymap
                        ;; "We were given a keymap. Extract menu info from
                        ;; the keymap."
                        (keymap-panes (list keymap))
                        (let ((prompt (keymap-prompt keymap)))
                          ;; "A prompt whose first character carries the
                          ;; `hide` text property is not a title" on a
                          ;; window system (`menu.c:1305`, USE_GTK/NS) -
                          ;; which is what `(propertize "Context Menu"
                          ;; 'hide t)` on the tab bar's and tab line's
                          ;; context menus is for. The *pane name* keeps
                          ;; it below, as the C's ASET does.
                          (when (and prompt
                                     (not (and (string? prompt)
                                               (> (string-length prompt) 0)
                                               (get-text-property 0 'hide prompt)
                                               (display-graphic-p frame))))
                            (set! title prompt))
                          ;; "Make that be the pane title of the first
                          ;; pane."
                          (when (and prompt (> (menu-items-n-panes) 0))
                            (vector-set! (menu-items)
                                         menu-items-pane-name prompt)))
                        (set! flags (logior flags MENU-KEYMAPS)))
                       ((and (pair? menu)
                             (pair? (car menu))
                             (keymap-type? (car menu)))
                        ;; "We were given a list of keymaps." The first
                        ;; keymap with a prompt supplies the title.
                        (let ((maps menu))
                          (for-each (lambda (m)
                                      (let ((prompt (keymap-prompt m)))
                                        (when (and (not title) prompt)
                                          (set! title prompt))))
                                    maps)
                          (keymap-panes maps)
                          (if (and title (> (menu-items-n-panes) 0))
                              (vector-set! (menu-items)
                                           menu-items-pane-name title)))
                        (set! flags (logior flags MENU-KEYMAPS)))
                       (else
                        ;; "We were given an old-fashioned menu."
                        (if (not (pair? menu))
                            (error "Wrong type argument: consp" menu))
                        (set! title (car menu))
                        (if (not (string? title))
                            (error "Wrong type argument: stringp" title))
                        (list-of-panes (cdr menu))
                        (set! flags (logand flags (lognot MENU-KEYMAPS)))))
                      (run-hooks (*x-pre-popup-menu-hook*))
                      (dynamic-wind
                       (lambda () #t)
                       (lambda ()
                         (menu-show (or (frame-output frame)
                                        (current-display))
                                    frame xpos ypos flags title))
                       (lambda ()
                         (unuse-menu-items)
                         (discard-menu-items))))))))))

    (define (x-popup-menu position menu)
      ;; GNU Emacs's `x-popup-menu` (`menu.c:1433`): "Pop up a
      ;; deck-of-cards menu and return user's selection."
      ;;
      ;; MENU may be a keymap, a list of keymaps, or the old-fashioned
      ;; `(TITLE PANE...)` list; see `x-popup-menu-1`. The answer is the
      ;; `(MENU . EVENT...)` list for a keymap (which `popup-menu` looks
      ;; up) and the item's own value for the list form, exactly as the
      ;; C's docstring says.
      ;;
      ;; `init_raw_keybuf_count` is not carried: it resets the raw
      ;; key-sequence buffer that a menu-bar click is recorded from.
      ;;--------------------------------------------------------------
      (x-popup-menu-1 position menu))
    ))
