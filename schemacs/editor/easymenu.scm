(define-library (schemacs editor easymenu)
  ;; A port of GNU Emacs's `lisp/emacs-lisp/easymenu.el': the
  ;; `easy-menu-define' interface cc-mode (and much else) builds its
  ;; menus with, in the file's own order with its docstrings.
  ;;
  ;; **The one representation change: `menu-prop' is a record.** Emacs
  ;; makes each menu a sparse keymap, and when keywords (`:filter',
  ;; `:enable', `:label', ...) ride on the menu itself it wraps the
  ;; keymap in an *uninterned symbol* holding the keymap as its function
  ;; value and the plist as its `menu-prop' property. A Lisp-1 has
  ;; neither `fset' nor a symbol-to-value indirection, so the wrapper is
  ;; `<easy-menu-box>', with the keymap and the props as fields. Every
  ;; place Emacs asks `symbolp' and looks through becomes a box test.
  ;;
  ;; **The one API change: the command easy-menu-define makes.** Emacs
  ;; `defvar's SYMBOL (the menu) and `defalias'es SYMBOL (a command that
  ;; pops the menu up) - one name, two namespaces. A Lisp-1 cannot: the
  ;; Scheme binding SYMBOL is the menu, and the popup command is created
  ;; by `easy-menu-do-define' as a procedure registered in the command
  ;; table under SYMBOL's *name*, so `M-x c-c-menu' and
  ;; `call-interactively' reach it while `easy-menu-add-item' and
  ;; friends take the binding. (Emacs hides these commands from M-x with
  ;; a `completion-predicate'; this tree's command table has no such
  ;; flag, so they appear there - a named departure.)
  ;;
  ;; The other Emacs idioms the port spells out:
  ;;   * `menu-bar-separator' is `subr.el:7700`'s `("--")', imported
  ;;     through `subr.scm';
  ;;   * `''nil' (the form that evaluates to nil) is `(quote #f)' here,
  ;;     compared with `equal?';
  ;;   * `easy-menu-avoid-duplicate-keys' is `let'-bound by
  ;;     `easy-menu-create-menu', so it is a parameter;
  ;;   * a callback that is an *expression* becomes a thunk that
  ;;     `eval's it in the module the menu is defined in (Emacs wraps it
  ;;     in a lambda and `eval's that), since a Scheme form is data.
  (import
    (scheme base)
    (scheme char)
    (only (guile) 1+ 1- eval current-module make-hash-table hash-ref hash-set!
                  hashv-ref catch throw while set-procedure-property! format)
    (only (schemacs syntax) setq push when-e unless-e cond-e)
    (only (schemacs editor data) keywordp aref)
    (only (schemacs editor fns) concat nth delete string-equal)
    (only (schemacs editor subr) intern member-ignore-case delq
          car-safe cdr-safe menu-bar-separator)
    (only (schemacs editor buffer) current-local-map current-buffer)
    (only (schemacs editor keyboard) lookup-keymaps)
    (only (schemacs editor intervals) get)
    (only (schemacs editor keymap)
          make-sparse-keymap keymap-prompt keymapp lookup-key define-key
          store-in-keymap map-keymap keymap-order %set!keymap-order!
          keymap-bindings keymap-index current-global-map
          %keymap-remove-binding! keymap-type? keymap-by-name
          *default-keymap*)
    (only (schemacs editor menu) x-popup-menu)
    (only (schemacs editor command) register-command!)
    (only (schemacs editor casefiddle) downcase)
    (only (schemacs editor search) string-match match-string
          match-beginning match-end))

  (export
   easy-menu-define easy-menu-binding easy-menu-do-define
   easy-menu-filter-return *easy-menu-avoid-duplicate-keys*
   easy-menu-create-menu easy-menu-button-prefix
   easy-menu-converted-items-table easy-menu-convert-item
   easy-menu-convert-item-1 easy-menu-define-key easy-menu-name-match
   easy-menu-always-true-p easy-menu-item-count easy-menu-make-symbol
   easy-menu-change easy-menu-remove easy-menu-add add-submenu
   easy-menu-add-item easy-menu-item-present-p easy-menu-remove-item
   easy-menu-return-item easy-menu-lookup-name easy-menu-get-map
   easy-menu-box? easy-menu-box-keymap easy-menu-box-props
   make-easy-menu-box easy-menu-resolve-menu)

  (begin

    (define-record-type <easy-menu-box>
      (make-easy-menu-box keymap props)
      easy-menu-box?
      ;; Emacs's stand-in: an uninterned symbol whose function value is
      ;; the keymap (`symbol-function') and whose `menu-prop' property
      ;; is PROPS (`(get SYMBOL 'menu-prop)').
      (keymap easy-menu-box-keymap)
      (props  easy-menu-box-props))

    (define (easy-menu-intern s)
      ;; `easymenu.el:35': "Return the symbol named S, or S itself."
      (if (string? s) (intern s) s))

    ;;------------------------------------------------------------------
    ;; `easy-menu-define' (`easymenu.el:38')
    ;;------------------------------------------------------------------
    ;; `define-syntax' takes no docstring here (Guile refuses it in a
    ;; library), so Emacs's docstring is this comment:
    ;;
    ;; "Define a pop-up menu and/or menu bar menu specified by MENU. If
    ;; SYMBOL is non-nil, define SYMBOL as a function to pop up the
    ;; submenu defined by MENU, with DOC as its doc string. Also define
    ;; SYMBOL as a variable whose value is the menu. MAPS, if non-nil,
    ;; should be a keymap or a list of keymaps; add the submenu defined
    ;; by MENU to the keymap or each of the keymaps, as a top-level menu
    ;; bar item. The rest of the elements in MENU are menu items, as
    ;; described in `easy-menu-do-define'."
    (define-syntax easy-menu-define
      (syntax-rules ()
        ((_ #f maps doc menu)
         (easy-menu-do-define #f #f #f maps doc
                              ;; **The menu expression is quoted for
                              ;; the caller when it is a literal list.**
                              ;; Emacs evaluates MENU (a literal list
                              ;; quote itself); a Scheme call site must
                              ;; write `'(...)', so the datum arrives
                              ;; here already evaluated. Nothing to do.
                              menu))
        ((_ symbol maps doc menu)
         (begin
           ;; Emacs's `(defvar ,symbol nil ,doc)'. A Scheme binding has
           ;; no docstring; the popup command carries it.
           (define symbol #f)
           (easy-menu-do-define (quote symbol)
                                (lambda () symbol)
                                (lambda (v) (set! symbol v))
                                maps doc menu)))))

    (define (easy-menu-binding menu . rest)
      ;; `easymenu.el:151': "Return a binding suitable to pass to
      ;; `define-key'. This is expected to be bound to a mouse event."
      ;;
      ;; The `symbolp' arm is the box: its props are peeled for a
      ;; leading `:label' and the rest travel with the item.
      ;;--------------------------------------------------------------
      (let ((item-name (if (pair? rest) (car rest) #f)))
        (let ((props #f))
          (when (easy-menu-box? menu)
            (setq props (easy-menu-box-props menu))
            (setq menu (easy-menu-box-keymap menu)))
          (let ((label (if (eq? (car-safe props) ':label)
                           (let ((l (car (cdr-safe props))))
                             (setq props (cddr-safe props))
                             l)
                           (or item-name
                               (and (keymapp menu) (keymap-prompt menu))
                               ""))))
            (append (list 'menu-item label menu)
                    (if props props '()))))))

    (define (cddr-safe x) (if (pair? x) (cdr-safe (cdr-safe x)) #f))

    (define (easy-menu-do-define symbol getter setter maps doc menu)
      ;; `easymenu.el:169': "We can't do anything that might differ
      ;; between Emacs dialects in `easy-menu-define' in order to make
      ;; byte compiled files compatible. Therefore everything
      ;; interesting is done in this function."
      ;;
      ;; GETTER and SETTER are the Scheme binding SYMBOL - the tree's
      ;; stand-in for `(symbol-value SYMBOL)'/`(set SYMBOL ...)', which
      ;; has no reflection.
      ;;--------------------------------------------------------------
      (let ((keymap (easy-menu-create-menu (car menu) (cdr menu))))
        (when symbol
          (setter keymap)
          ;; Emacs defaliases SYMBOL to a command that pops the menu up.
          ;; One name cannot hold both here (see the header), so the
          ;; command is registered under SYMBOL's name and the binding
          ;; holds the menu.
          (let ((command (lambda (event)
                           (x-popup-menu
                            event
                            (easy-menu-resolve-menu (getter))))))
            (set-procedure-property! command 'name symbol)
            (set-procedure-property! command 'documentation doc)
            (register-command! command "e")))
        (for-each
         (lambda (map)
           (define-key map
             (vector 'menu-bar (if (symbol? (car menu))
                                   (car menu)
                                   ;; "If a string, then use the
                                   ;; downcased version for greater
                                   ;; backwards compatibility."
                                   (intern (downcase (car menu)))))
             (easy-menu-binding keymap (car menu))))
         (if (keymapp maps) (list maps) maps))))

    (define (easy-menu-resolve-menu menu)
      ;; Emacs's `(or (and (symbolp keymap) (funcall (or (plist-get (get
      ;; keymap 'menu-prop) :filter) #'identity) (symbol-function keymap)))
      ;; keymap)' from the popup command: the box's filter decides what
      ;; to show; with no filter the keymap is the menu.
      ;;--------------------------------------------------------------
      (if (easy-menu-box? menu)
          (let ((props (easy-menu-box-props menu))
                (km (easy-menu-box-keymap menu)))
            (let ((f (let loop ((p props))
                       (cond ((not (pair? p)) #f)
                             ((eq? (car p) ':filter) (car (cdr-safe p)))
                             (else (loop (cdr-safe p)))))))
              (if f (f km) km)))
          menu))

    (define (easy-menu-filter-return menu . rest)
      ;; `easymenu.el:199': "Convert MENU to the right thing to return
      ;; from a menu filter. ... In Emacs a menu filter must return a
      ;; menu (a keymap) ... If NAME is provided, it is used for the
      ;; keymap."
      (let ((name (if (pair? rest) (car rest) #f)))
        (cond
         ((and (not (keymapp menu)) (pair? menu))
          ;; "If it's a cons but not a keymap, then it can't be right
          ;; unless it's an XEmacs menu."
          (setq menu (easy-menu-create-menu (or name "") menu)))
         ((vector? menu)
          ;; "It's just a menu entry."
          (setq menu (cdr (easy-menu-convert-item menu)))))
        menu))

    (define *easy-menu-avoid-duplicate-keys* (make-parameter #t))
    ;; ^ `easymenu.el:217': "Dynamically scoped var to register already
    ;;   used keys in a menu. If it holds a list, this is expected to be
    ;;   a list of keys already seen in the menu we're processing. Else
    ;;   it means we're not processing a menu." Emacs `let'-binds it in
    ;;   `easy-menu-create-menu', so it is a parameter (the stars are the
    ;;   tree's).

    (define (easy-menu-create-menu menu-name menu-items)
      ;; `easymenu.el:222': "Create a menu called MENU-NAME with items
      ;; described in MENU-ITEMS. ..."
      ;;--------------------------------------------------------------
      (let ((menu (make-sparse-keymap menu-name))
            (prop '()) (keyword #f) (label #f) (enable #f) (filter #f)
            (visible #f) (help #f))
        ;; Emacs `let'-binds `easy-menu-avoid-duplicate-keys'; the
        ;; parameter is the same binding.
        (parameterize ((*easy-menu-avoid-duplicate-keys* #f))
        ;; "Look for keywords."
        (let loop ()
          (when (and (pair? menu-items) (pair? (cdr menu-items))
                     (keywordp (setq keyword (car menu-items))))
            (let ((arg (car (cdr menu-items))))
              (setq menu-items (cddr menu-items))
              (cond
               ((eq? keyword ':filter)
                (let ((name menu-name))
                  (setq filter (lambda (m)
                                 (easy-menu-filter-return (arg m) name)))))
               ((or (eq? keyword ':enable) (eq? keyword ':active))
                (setq enable (if arg arg (list 'quote #f))))
               ((eq? keyword ':label) (setq label arg))
               ((eq? keyword ':help) (setq help arg))
               ((or (eq? keyword ':included) (eq? keyword ':visible))
                (setq visible (if arg arg (list 'quote #f)))))
              (loop))))
        (if (equal? visible (list 'quote #f))
            #f                          ; "Invisible menu entry, return nil."
            (begin
              (when (and visible (not (easy-menu-always-true-p visible)))
                (setq prop (cons ':visible (cons visible prop))))
              (when (and enable (not (easy-menu-always-true-p enable)))
                (setq prop (cons ':enable (cons enable prop))))
              (when filter (setq prop (cons ':filter (cons filter prop))))
              (when help (setq prop (cons ':help (cons help prop))))
              (when label (setq prop (cons ':label (cons label prop))))
              (setq menu
                    (if filter
                        ;; "The filter expects the menu in its XEmacs
                        ;; form and the pre-filter form will only be
                        ;; passed to the filter anyway, so we'd better
                        ;; not convert it at all (it will be converted
                        ;; on the fly by `easy-menu-filter-return')."
                        menu-items
                        ;; Emacs `append's the converted `(KEY . DEF)'
                        ;; pairs onto the keymap list; this tree's
                        ;; keymaps are records, so the pairs are stored
                        ;; one by one - **back to front**, because
                        ;; `store-in-keymap' prepends and the display
                        ;; order must be the written order.
                        (begin
                          (for-each
                           (lambda (item)
                             (easy-menu-store-item!
                              menu (easy-menu-convert-item item)))
                           (reverse menu-items))
                          menu)))
              (when (pair? prop)
                (setq menu (make-easy-menu-box menu prop)))
              menu))))
        )

    ;; "Known button types."
    (define easy-menu-button-prefix
      '((radio . :radio) (toggle . :toggle)))

    (define easy-menu-converted-items-table (make-hash-table))

    (define (easy-menu-convert-item item)
      ;; `easymenu.el:272': "Memoize the value returned by
      ;; `easy-menu-convert-item-1' called on ITEM. ..."
      ;;--------------------------------------------------------------
      (let* ((cache (hash-ref easy-menu-converted-items-table item #f))
             (result (or cache (easy-menu-convert-item-1 item)))
             (key (car-safe result)))
        (when (and (listp (*easy-menu-avoid-duplicate-keys*)) (symbol? key))
          ;; "Merging multiple entries with the same name is sometimes
          ;; what we want, but not when the entries are actually
          ;; different ..."
          (while (memq key (*easy-menu-avoid-duplicate-keys*))
            (setq key (intern (format #f "~a-~a" (symbol->string key)
                                      (length (*easy-menu-avoid-duplicate-keys*)))))
            (setq result (cons key (cdr result))))
          (setq *easy-menu-avoid-duplicate-keys*
                (cons key (*easy-menu-avoid-duplicate-keys*))))
        (unless cache
          (hash-set! easy-menu-converted-items-table item result))
        result))

    (define %easy-menu-separator-count 0)
    (define (easy-menu-store-item! menu item)
      ;; Store one converted `(KEY . DEF)' pair in MENU. **A nil KEY -
      ;; a separator's, `(nil . ("--"))' - becomes a generated symbol
      ;; event**, because this tree's keymaps are keyed by one event and
      ;; `#f` is not one; Emacs's alist can hold the nil in its car and
      ;; its menu walk ignores it. The `("--")' definition is what
      ;; `parse_menu_item' draws as the separator either way.
      ;;--------------------------------------------------------------
      (let ((key (car item)) (def (cdr item)))
        (if key
            (store-in-keymap menu (easy-menu-intern key) def)
            (begin
              (set! %easy-menu-separator-count
                    (+ 1 %easy-menu-separator-count))
              (store-in-keymap
               menu
               (intern (format #f "separator-~a" %easy-menu-separator-count))
               def)))))

    (define (listp x) (or (null? x) (pair? x)))

    (define (easy-menu-convert-item-1 item)
      ;; `easymenu.el:299': "Parse an item description and convert it
      ;; to a menu keymap element."
      ;;--------------------------------------------------------------
      (let ((name #f) (command #f) (label #f) (prop '()) (remove #f))
        (cond
         ((string? item)                ; "An item or separator."
          (setq label item))
         ((pair? item)                  ; "A sub-menu."
          (setq label (setq name (car item)))
          (setq command (cdr item))
          (if (not (keymapp command))
              (setq command (easy-menu-create-menu name command)))
          (if (not command)
              ;; "Invisible menu item. Don't insert into keymap."
              (setq remove #t)
              (when (easy-menu-box? command)
                (let ((bp (easy-menu-box-props command)))
                  (when (eq? ':label (car-safe bp))
                    (setq label (car (cdr-safe bp)))
                    (setq bp (cddr-safe bp)))
                  (setq prop bp)
                  (setq command (easy-menu-box-keymap command))))))
         ((vector? item)                ; "An item."
          (let* ((ilen (vector-length item))
                 (active (if (> ilen 2) (or (aref item 2) (list 'quote #f)) #t))
                 (no-name (not (symbol? (setq command (aref item 1)))))
                 (cache #f) (cache-specified #f))
            (setq label (setq name (aref item 0)))
            (when no-name (setq command (easy-menu-make-symbol command)))
            (when (keywordp active)
              (let ((count 2)
                    (keyword #f) (arg #f) (suffix #f) (visible #f)
                    (style #f) (selected #f) (keys #f))
                (setq active #f)
                (while (> ilen count)
                  (setq keyword (aref item count))
                  (setq arg (aref item (1+ count)))
                  (setq count (+ 2 count))
                  (cond
                   ((or (eq? keyword ':included) (eq? keyword ':visible))
                    (setq visible (if arg arg (list 'quote #f))))
                   ((eq? keyword ':key-sequence)
                    (setq cache arg) (setq cache-specified #t))
                   ((eq? keyword ':keys) (setq keys arg) (setq no-name #f))
                   ((eq? keyword ':label) (setq label arg))
                   ((or (eq? keyword ':active) (eq? keyword ':enable))
                    (setq active (if arg arg (list 'quote #f))))
                   ((eq? keyword ':help)
                    (setq prop (cons ':help (cons arg prop))))
                   ((eq? keyword ':suffix) (setq suffix arg))
                   ((eq? keyword ':style) (setq style arg))
                   ((eq? keyword ':selected)
                    (setq selected (if arg arg (list 'quote #f))))))
                (when suffix
                  (setq label
                        (if (string? suffix)
                            (if (string? label)
                                (concat label " " suffix)
                                (list 'concat label (concat " " suffix)))
                            (if (string? label)
                                (list 'concat (concat label " ") suffix)
                                (list 'concat label " " suffix)))))
                (cond
                 ((eq? style 'button)
                  (setq label (if (string? label)
                                  (concat "[" label "]")
                                  (list 'concat "[" label "]"))))
                 ((and selected
                       (setq style (assq style easy-menu-button-prefix)))
                  (setq prop (cons ':button
                                   (cons (cons (cdr style) selected) prop)))))
                (when (string? keys)
                  (if (string-match "^[^\\]*\\(\\\\\\[\\([^]]+\\)]\\)[^\\]*$"
                                    keys)
                      ;; Emacs's `if's here have no else; a Scheme `if'
                      ;; with none answers the unspecified value, which
                      ;; is true - so both branches say `#f' explicitly.
                      (let ((prefix
                             (if (< (match-beginning 0) (match-beginning 1))
                                 (substring keys 0 (match-beginning 1))
                                 #f))
                            (postfix
                             (if (< (match-end 1) (match-end 0))
                                 (substring keys (match-end 1))
                                 #f))
                            (cmd (intern (match-string 2 keys))))
                        (setq keys (and (or prefix postfix)
                                        ;; Emacs conses its nil; a
                                        ;; list tail here is `'()'.
                                        (cons prefix (or postfix '()))))
                        (setq keys
                              (and (or keys (not (eq? command cmd)))
                                   (cons cmd keys))))
                      (setq cache-specified #f))
                  (if keys (setq prop (cons ':keys (cons keys prop)))))
                (when (and visible (not (easy-menu-always-true-p visible)))
                  (if (equal? visible (list 'quote #f))
                      ;; "Invisible menu item. Don't insert into keymap."
                      (setq remove #t)
                      (setq prop (cons ':visible (cons visible prop)))))))
            (when (and active (not (easy-menu-always-true-p active)))
              (setq prop (cons ':enable (cons active prop))))
            (when (and (or no-name cache-specified)
                       (or (not cache) (string? cache) (vector? cache)))
              (setq prop (cons ':key-sequence (cons cache prop))))))
         (else (error "Invalid menu item in easymenu")))
        ;; "`intern' the name so as to merge multiple entries with the
        ;; same name. ..."
        (let ((key (easy-menu-intern name)))
          (cons key
                (and (not remove)
                     (if (and (string? label)
                              (every-char? (lambda (c) (char=? c #\-)) label))
                         menu-bar-separator
                         (cons 'menu-item
                               (cons label
                                     (and name
                                          (cons command prop))))))))))

    (define (every-char? pred s)
      ;; `seq-every-p' over a string, which is how Emacs tests the
      ;; separator's dashes.
      (let loop ((i 0))
        (or (>= i (string-length s))
            (and (pred (string-ref s i)) (loop (+ i 1))))))

    (define (easy-menu-define-key menu key item . rest)
      ;; `easymenu.el:402': "Add binding in MENU for KEY => ITEM.
      ;; Similar to `define-key-after'. If KEY is not nil then delete
      ;; any duplications. If ITEM is nil, then delete the definition
      ;; of KEY. ... Optional argument BEFORE ... put binding before the
      ;; item in MENU named BEFORE; otherwise, if a binding for KEY is
      ;; already present in MENU, just change it; otherwise put the new
      ;; binding last in MENU."
      ;;
      ;; **Written over the keymap record, not an alist.** Emacs walks
      ;; the `(EVENT . ITEM)' conses of a sparse keymap with `setcdr';
      ;; this tree's bindings are a hash with an order list beside it,
      ;; so the same rules are spelled as: an existing binding keeps its
      ;; place (`store-in-keymap'), a new one goes to the display END
      ;; (the end of the order list), or immediately before BEFORE's
      ;; event. A nil KEY (insert without a key) cannot arise from this
      ;; file's own callers and is refused rather than half-carried.
      ;;--------------------------------------------------------------
      (let ((before (if (pair? rest) (car rest) #f)))
        (setq menu (cond ((easy-menu-box? menu) (easy-menu-box-keymap menu))
                         ((symbol? menu)
                          (or (keymap-by-name menu) menu))
                         (else menu)))
        (if (not key)
            (error "easy-menu-define-key: a nil key is not carried")
            (let ((event (easy-menu-intern key))
                  (order (keymap-order menu)))
              (cond
               ((not item)
                (%keymap-remove-binding! menu event))
               ((memv event order)
                ;; Present. Emacs keeps it in place unless BEFORE says
                ;; it belongs immediately before another item.
                (if (and before (not (immediately-before? menu event before)))
                    (begin
                      (%keymap-remove-binding! menu event)
                      (easy-menu-insert! menu event item before))
                    (define-key menu (vector event) item)))
               (else
                (easy-menu-insert! menu event item before)))))))

    (define (immediately-before? menu event before)
      ;; Is EVENT the binding immediately above BEFORE's (its successor
      ;; in the order list is BEFORE's event)?
      (let loop ((order (keymap-order menu)))
        (cond ((not (pair? order)) #f)
              ((eqv? (car order) event)
               (let ((next (car (cdr-safe order))))
                 (and next (easy-menu-name-match before (cons next (lookup-key menu (vector next)))))))
              (else (loop (cdr order))))))

    (define (easy-menu-insert! menu event item before)
      ;; Put ITEM in at the display END, or immediately before BEFORE's
      ;; event; the binding is stored with `define-key' first so that
      ;; the order rewrite below is the whole placement.
      (let ((order (keymap-order menu)))  ; before `define-key' prepends
        (define-key menu (vector event) item)
        (if (not before)
            ;; The display end is the tail: the old order with the event
            ;; appended. (The whole order is rewritten below, so the
            ;; copy `define-key' just prepended is replaced.)
            (%set!keymap-order! menu (append order (list event)))
            (let loop ((l order) (acc '()))
              (cond
               ((not (pair? l))
                (%set!keymap-order! menu (append (reverse acc) (list event))))
               ((easy-menu-name-match before
                                      (cons (car l)
                                            (lookup-key menu (vector (car l)))))
                (%set!keymap-order! menu
                                    (append (reverse acc) (list event) l)))
               (else (loop (cdr l) (cons (car l) acc))))))))

    (define (easy-menu-name-match name item)
      ;; `easymenu.el:443': "Return t if NAME is the name of menu item
      ;; ITEM. ..."
      (if (pair? item)
          (if (symbol? name)
              (eq? (car-safe item) name)
              (if (string? name)
                  ;; "Match against the text that is displayed to the
                  ;; user."
                  (or (guard (e (else #f))
                        (member-ignore-case name item))
                      ;; "Also check the string version of the symbol
                      ;; name, for backwards compatibility."
                      (eq? (car-safe item) (intern name)))
                  ;; A name that is neither a symbol nor a string can
                  ;; match nothing; Emacs's `if' falls through to nil.
                  #f))
          #f))

    (define (easy-menu-always-true-p x)
      ;; `easymenu.el:458': "Return true if form X never evaluates to
      ;; nil."
      ;; Emacs's nil is a *symbol*, so the symbol test is not-true for
      ;; it; here nil is `#f` (or the empty list), which a bare
      ;; `(not (symbol? x))' would call true.
      (if (pair? x)
          (and (eq? (car x) 'quote) (car (cdr-safe x)))
          (or (eq? x #t)
              (and (not (null? x)) (not (eq? x #f)) (not (symbol? x))))))

    (define easy-menu-item-count 0)

    (define (easy-menu-make-symbol callback . rest)
      ;; `easymenu.el:465': "Return a unique symbol with CALLBACK as
      ;; function value. When non-nil, NOEXP indicates that CALLBACK
      ;; cannot be an expression (i.e. does not need to be turned into a
      ;; function)."
      ;;
      ;; **No symbol is made**: an item's command slot holds the
      ;; procedure here. A keymap or procedure is kept as it is; an
      ;; *expression* becomes a thunk that `eval's it in the module the
      ;; menu is being defined in - Emacs's `(eval `(lambda ()
      ;; (interactive) ,callback) t)' - which is where its free
      ;; variables live.
      ;;--------------------------------------------------------------
      (let ((noexp (and (pair? rest) (car rest))))
        (cond
         ((or (keymap-type? callback) (procedure? callback) noexp)
          callback)
         (else
          (let ((form callback) (module (current-module)))
            (lambda () (eval form module)))))))

    (define (easy-menu-change path name items . rest)
      ;; `easymenu.el:480': "Change menu found at PATH as item NAME to
      ;; contain ITEMS. ..."
      (let ((before (and (pair? rest) (car rest)))
            (map (and (pair? rest) (pair? (cdr rest)) (car (cdr rest)))))
        (easy-menu-add-item map path (easy-menu-create-menu name items) before)))

    (define (easy-menu-remove . args)
      ;; `easymenu.el:499': `(defalias 'easy-menu-remove #'ignore)',
      ;; obsolete since 28.1.
      #f)

    (define (easy-menu-add . args)
      ;; `easymenu.el:503': `(defalias 'easy-menu-add #'ignore)` - the
      ;; call each mode makes after `easy-menu-define`.
      #f)

    (define (add-submenu menu-path submenu . rest)
      ;; `easymenu.el:507': "Add submenu SUBMENU in the menu at
      ;; MENU-PATH. ... This is a compatibility function; use
      ;; `easy-menu-add-item'."
      (let ((before (and (pair? rest) (car rest)))
            (in-menu (and (pair? rest) (pair? (cdr rest)) (car (cdr rest)))))
        (easy-menu-add-item (or in-menu (current-global-map))
                            (cons 'menu-bar menu-path)
                            submenu before)))

    (define (easy-menu-add-item map path item . rest)
      ;; `easymenu.el:517': "To the submenu of MAP with path PATH, add
      ;; ITEM. ..."
      (let ((before (and (pair? rest) (car rest))))
        (setq map (easy-menu-get-map map path
                                     (and (not map)
                                          ;; Emacs's nil for PATH; here
                                          ;; it is `#f` or `'()`.
                                          (or (not path) (null? path))
                                          (string? (car-safe item))
                                          (car item))))
        (if (and (pair? item) (pair? (cdr item)) (eq? (car (cdr item)) 'menu-item))
            ;; "This is a value returned by
            ;; `easy-menu-item-present-p' or `easy-menu-remove-item'."
            (easy-menu-define-key map (easy-menu-intern (car item))
                                  (cdr item) before)
            (begin
              (if (or (keymapp item)
                      (and (symbol? item)
                           (keymapp (keymap-by-name item))
                           (begin (setq item (keymap-by-name item)) #t)))
                  ;; "Item is a keymap, find the prompt string and use
                  ;; as item name."
                  (setq item (cons (keymap-prompt item) item)))
              (setq item (easy-menu-convert-item item))
              (easy-menu-define-key
               map
               (or (easy-menu-intern (car item))
                   ;; A separator's converted key is nil; this tree's
                   ;; keymaps need a real event (see
                   ;; `easy-menu-store-item!').
                   (begin
                     (set! %easy-menu-separator-count
                           (+ 1 %easy-menu-separator-count))
                     (intern (format #f "separator-~a"
                                     %easy-menu-separator-count))))
               (cdr item) before)))))

    (define (easy-menu-item-present-p map path name)
      ;; `easymenu.el:555': "In submenu of MAP with path PATH, return
      ;; non-nil if item NAME is present. ..."
      (easy-menu-return-item (easy-menu-get-map map path) name))

    (define (easy-menu-remove-item map path name)
      ;; `easymenu.el:561': "From submenu of MAP with path PATH remove
      ;; item NAME. ..."
      (setq map (easy-menu-get-map map path))
      (let ((ret (easy-menu-return-item map name)))
        (if ret (easy-menu-define-key map (easy-menu-intern name) #f))
        ret))

    (define (easy-menu-return-item menu name)
      ;; `easymenu.el:570': "In menu MENU try to look for menu item with
      ;; name NAME. If a menu item is found, return (NAME . item),
      ;; otherwise return nil. If item is an old format item, a new
      ;; format item is returned."
      ;;
      ;; Emacs's `assq' arm is the order walk here (the tree's alist is
      ;; the order list plus the hash); `lookup-key' is the fallback,
      ;; as in Emacs.
      ;;--------------------------------------------------------------
      (let ((item (or (let loop ((order (keymap-order menu)))
                        (cond ((not (pair? order)) #f)
                              ((eq? (car order) (easy-menu-intern name))
                               (keymap-lookup-own menu (car order)))
                              (else (loop (cdr order)))))
                      (lookup-key menu (vector (easy-menu-intern name)))))
            (ret #f) (enable #f) (cache #f) (label #f))
        (cond
         ((string? (car-safe item))
          ;; "This is the old menu format. Convert it to new format."
          (setq label (car item))
          (when (string? (car (setq item (cdr item)))) ; "Got help string"
            (setq ret (list ':help (car item)))
            (setq item (cdr item)))
          (when (and (pair? item) (pair? (car item))
                     (or (not (car (car item))) (number? (car (car item)))))
            (setq cache (car item))     ; "Got cache"
            (setq item (cdr item)))
          (and (symbol? item) (setq enable (get-menu-enable item)) ; "Got enable"
               (setq ret (cons ':enable (cons enable ret))))
          (if cache (setq ret (cons cache ret)))
          (cons name (cons 'menu-enable (cons label (cons item ret)))))
         (item                          ; "Keymap or new menu format"
          (cons name item))
         (else #f))))

    (define (keymap-lookup-own keymap event)
      ;; The binding for EVENT in KEYMAP's own hash, as `(car menu)` is
      ;; in Emacs's `assq' walk.
      ;; `hashv-ref`: the bindings table is written with the `hashv`
      ;; family (see `store-in-keymap`), and a generic `hash-ref` looks
      ;; in the bucket its own hash function computes.
      (let ((own (hashv-ref (keymap-bindings keymap)
                            (if (char? event) (char->integer event) event)
                            #f)))
        (if (and (pair? own) (string? (car own))) (cdr own) own)))

    (define (get-menu-enable symbol)
      ;; Emacs's `(get item 'menu-enable)' - the old menu format's way
      ;; of saying whether a command is enabled. Symbol properties are
      ;; `intervals.scm''s `get'; imported here through a small wrapper
      ;; so the property name stays Emacs's.
      (get symbol 'menu-enable))

    (define (easy-menu-lookup-name map name)
      ;; `easymenu.el:602': "Lookup menu item NAME in keymap MAP. ...
      ;; NAME can be a string representing the menu item's name."
      (or (lookup-key map (vector (easy-menu-intern name)))
          (when (string? name)
            ;; "`lookup-key' failed and we have a menu item name: look
            ;; at the actual menu entries's names."
            (catch 'found
              (lambda ()
                (map-keymap
                 (lambda (key item)
                   (if (guard (e (else #f)) (member name item))
                       ;; "Found it!! Look for it again with
                       ;; `lookup-key' so as to handle inheritance and
                       ;; to extract the actual command/keymap bound to
                       ;; `name' from the item (via get_keyelt)."
                       (throw 'found (lookup-key map (vector key)))))
                 map)
                #f)
              (lambda (key . args) (car args))))))

    (define (easy-menu-get-map map path . rest)
      ;; `easymenu.el:621': "Return a sparse keymap in which to add or
      ;; remove an item. ... TO-MODIFY ... is the name of the item the
      ;; caller wants to modify in the map that we return. ..."
      ;;
      ;; `(current-active-maps)' is this tree's `lookup-keymaps';
      ;; `(symbolp map)' resolves through the keymap-name registry,
      ;; the tree's stand-in for `symbol-value`. PATH may be nil, which
      ;; is `#f` or `'()` here; both become the empty list.
      ;;--------------------------------------------------------------
      (setq path (if (pair? path) path '()))
      (let ((to-modify (and (pair? rest) (car rest))))
        (setq map
              (catch 'found
                (lambda ()
                  (when (and map (symbol? map) (not (keymapp map)))
                    (setq map (keymap-by-name map)))
                  (let ((maps (if map (if (keymapp map) (list map) map)
                                  (lookup-keymaps))))
                    ;; "Look for PATH in each map."
                    (unless map (push 'menu-bar path))
                    (for-each
                     (lambda (name)
                       (setq maps
                             (let loop ((l maps) (acc '()))
                               (cond
                                ((not (pair? l)) (reverse acc))
                                (else
                                 (let ((m (easy-menu-lookup-name (car l) name)))
                                   (loop (cdr l)
                                         (if (keymapp m) (cons m acc) acc))))))))
                     path)

                    ;; "Prefer a map that already contains the
                    ;; to-be-modified entry."
                    (when to-modify
                      (for-each
                       (lambda (m)
                         (when (easy-menu-lookup-name m to-modify)
                           (throw 'found m)))
                       maps))
                    ;; "Use the first valid map."
                    (when (pair? maps) (throw 'found (car maps)))

                    ;; "Otherwise, make one up. ..."
                    (let* ((name (if (pair? path)
                                     (format #f "~a" (car (reverse path)))
                                     #f))
                           (newmap (make-sparse-keymap name)))
                      (define-key (or map (current-local-map))
                        (let ((v (make-vector (length path) #f)))
                          (let loop ((l path) (i 0))
                            (unless (null? l)
                              (vector-set! v i (easy-menu-intern (car l)))
                              (loop (cdr l) (+ i 1))))
                          v)
                        (if name (cons name newmap) newmap))
                      newmap)))
                (lambda (key . args) (car args))))
        (or (keymapp map) (error "Malformed menu in easy-menu: (~a)" map))
        map))

    ))
