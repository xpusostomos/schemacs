(define-library (schemacs keymap)
  ;; This library mirrors GNU Emacs's `src/keymap.c': a keymap and how a
  ;; binding goes into it. It is a leaf - it knows no commands at all.
  ;;
  ;; That is the point of it, and it is why this library is where the layout
  ;; plan cuts its fourth knot. `*default-keymap*' used to be built in one
  ;; piece by the frontend, which meant it had to come after every command
  ;; it binds, while the command loop and the minibuffer both needed it
  ;; first. GNU Emacs has no such problem because `global-map' is created
  ;; *empty* in keymap.c and each library adds its own bindings as it loads:
  ;; `simple.el' does `(define-key global-map "\C-f" 'forward-char)', and so
  ;; on. This is the same arrangement, so a command's keys are stated beside
  ;; the command.
  ;;
  ;; Two consequences, both of them Emacs's own and both worth knowing:
  ;;
  ;;  * A binding exists once the library that makes it has been loaded.
  ;;    Importing this library alone leaves `*default-keymap*' empty, just
  ;;    as `global-map' is empty before simple.el is read.
  ;;  * A library is loaded once however many times it is imported, so a
  ;;    binding cannot be installed twice by importing twice.
  ;;
  ;; **A keymap is Emacs's keymap.** `struct keymap' here is what it is
  ;; there - a set of bindings, a *parent* to fall back on, and one more
  ;; place a binding can come from that the C spells as a char-table. There
  ;; is no list of "layers": an earlier library of this tree kept one, and
  ;; it was the original author's idea with no counterpart in Emacs, doing
  ;; two jobs Emacs does with a parent and with a char-table range. See the
  ;; note on `<keymap-type>' below for what each of those jobs became.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (guile)
          string-join logand logior lognot last-pair
          hash-for-each
          ;; The bindings themselves. Guile's `hashv' family compares its
          ;; keys with `eqv?' - which is the right comparison for both
          ;; kinds of key an event can be: an integer (`eqv?' on numbers is
          ;; `=') and a symbol. This was `(schemacs comparator)' and
          ;; `(schemacs hash-table)', two ports of what Guile already has;
          ;; `hashv-set!' and `hashv-ref' are the whole of what the `eqv?'
          ;; comparator was for, and `hash-map->list' is the alist walk
          ;; (`hash-table->alist' is not a binding in any module here -
          ;; `(ice-9 hash-table)' exports only the alist *converters*).
          make-hash-table hashv-ref hashv-set! hashv-remove! hash-map->list
          hashq-ref hashq-set!)
    ;; The event model: the modifier bits `push-key-description' tests,
    ;; and `event-convert-list' for the Lucid form `single-key-description'
    ;; converts first. `kbd' is `read-kbd-macro''s own input, and the reader
    ;; `key-description' takes a *string* key through.
    ;; `append-key` is `(Fvconcat key_sequence (list key))`, and `vconcat`
    ;; is `fns.c:750`'s - ported in `fns.sld`, which this library can
    ;; import because `fns.sld` reaches down to `buffer.sld` and takes no
    ;; keymap from it.
    (only (schemacs fns) vconcat)
    (only (schemacs character)
          char-alt char-ctl char-hyper char-meta char-shift char-super
          event-convert-list kbd)
    )

  (export
   ;; The key model - what a key *is*, and the one normalisation every
   ;; reader here takes its input through.
   keymap-index keymap-index->events

   ;; `keymap.c''s own names. `store-in-keymap' (`:730') and
   ;; `access-keymap' (`:491') are its two choke points - the only
   ;; functions in Emacs that touch a keymap - and both are keyed by ONE
   ;; *event*.
   keymap make-sparse-keymap copy-keymap keymap-type? keymap-lookup
   keymapp lookup-key keymap-by-name current-global-map
   define-key %keymap-remove-binding!
   store-in-keymap access-keymap
   keymap-parent set-keymap-parent keymap-prompt
   keymap-char-table set-keymap-char-table!
   self-insert-char-table
   keymap-bindings
   keymap-order %set!keymap-order!
   keymap-lookup-binding-key
   ;; The reverse lookup a menu's key hint is made of, and the
   ;; two pieces `where-is-internal' is built on.
   get-keyelt append-key accessible-keymaps
   ;; The evaluator a `menu-item`'s `:filter` runs through - a seam,
   ;; because `menu_item_eval_property` is `keyboard.c`'s and this
   ;; library is below it. `keyboard.scm` installs it as it loads.
   *menu-item-eval-property-function*
   ;; `map_keymap' and its DEFUN: menu construction is their first caller
   ;; (`keyboard.c''s `menu_bar_items' walks each active map with
   ;; `map_keymap_canonical'), and `define-key-after' (subr.el) reads the
   ;; order they expose.
   map-keymap map-keymap-internal

   single-key-description key-description

   *current-keymap*
   *default-keymap*
   *special-event-map*
   )

  (begin
    ;; =================================================================================================
    ;;
    ;; A **key** here is what it is in GNU Emacs: a string or a vector of
    ;; *events*. An event is an integer carrying its own modifier bits -
    ;; `C-x' is 24, `(kbd "C-x")' is `#(24)' - or a symbol naming a key
    ;; that is not a character (`up', `f10', `M-up').
    ;;
    ;; That is the whole of this file's data model, and it is what the
    ;; `<keymap-index-type>' record this library used to keep got wrong.
    ;; That record held a whole chord - a modifier-bit field, a character,
    ;; and a link to the rest of the sequence - and each of its three
    ;; fields was a *second* spelling of something an event already says.
    ;; It could not represent `(kbd "S-x")' at all, because the shift had
    ;; no bit in it; it made a control-bit `x' and the code 24 the same
    ;; key; and it left a key sequence as a linked list of records rather
    ;; than the list of events Emacs walks.
    ;;
    ;; So the record is gone and a key is a **list of events**.
    ;;
    ;; The one place a modifier *name* is allowed is the Lucid event type
    ;; list - `(control ?x)', `(meta f10)' - which `event-convert-list'
    ;; consumes; `define-key' makes exactly that conversion before it
    ;; touches a map (`Fdefine_key', `keymap.c:1156', guarded by
    ;; `lucid_event_type_list_p').
    ;; =================================================================================================

    (define (keymap-event sym)
      ;; One element of a key sequence taken to the *event* it names.
      ;;
      ;; A character is the event its code point names - GNU Emacs has no
      ;; character type, `?a' there *is* 97 - and a Lucid event type list
      ;; is the one list that is a key rather than a sequence of them, so
      ;; it goes through `event-convert-list' (`keyboard.c:7832'), which is
      ;; where Emacs consumes a modifier name.
      ;;------------------------------------------------------------------
      (cond
       ((integer? sym) sym)
       ((char? sym) (char->integer sym))
       ((symbol? sym) sym)
       ((pair? sym) (event-convert-list sym))
       (else
        (error "a key is a sequence of events" sym))))

    (define (keymap-index keys)
      ;; Normalise KEYS to **the events it is made of** - a list of
      ;; integers and symbols - or #f for no key at all.
      ;;
      ;; This is Emacs's own normalisation, and it is idempotent: a key
      ;; that is already a list of events comes back as itself, so every
      ;; reader in this file can call it without asking which spelling it
      ;; was handed.
      ;;
      ;; KEYS may be:
      ;;
      ;;   * a *string*, which is what `(kbd "C-x C-c")' is written as and
      ;;     what `read-kbd-macro' reads. `kbd' is Emacs's parser for it;
      ;;   * a *vector* of events, which is what `define-key' takes
      ;;     ("a string or a vector of symbols and characters,
      ;;     representing a sequence of keystrokes and events",
      ;;     `keymap.c':1084');
      ;;   * a *list* of events, each of which may itself be a Lucid event
      ;;     type list;
      ;;   * a *single* event - an integer, a character, or a symbol;
      ;;   * #f or `()', which is no key.
      ;;------------------------------------------------------------------
      (cond
       ((not keys) #f)
       ((null? keys) #f)
       ((vector? keys) (keymap-index (vector->list keys)))
       ((string? keys) (keymap-index (kbd keys)))
       ((pair? keys) (map keymap-event keys))
       ((or (integer? keys) (symbol? keys)) (list keys))
       ((char? keys) (list (char->integer keys)))
       (else
        (error "a key is a string or a vector of events" keys))))

    (define (keymap-index->events key)
      ;; The *events* of KEY: an integer with its modifier bits, or a
      ;; symbol naming a key that is not a character. This is Emacs's
      ;; reader of a key - `(aref KEY i)' for a vector key - and what
      ;; `key-description' renders.
      ;;------------------------------------------------------------------
      (keymap-index key))

    ;; -------------------------------------------------------------------------------------------------
    ;; The keymap
    ;;
    ;; `struct keymap' (`keymap.h:18') is a struct with a `parent' and,
    ;; for a full keymap, a *char-table* at `nth 1'. A keymap here is the
    ;; same three things plus a label:
    ;;
    ;;   bindings   a hash table from ONE *event* to its binding. This is
    ;;              Emacs's sparse-keymap alist - a list of `(EVENT . DEF)`
    ;;              conses - in the collection that makes a lookup one
    ;;              step rather than a walk.
    ;;   parent     Emacs's `keymap-parent'. A lookup that finds nothing
    ;;              here asks the parent, and its parent, and so on.
    ;;   char-table **a procedure, standing in for the char-table**, or
    ;;              `#f'. Emacs's full keymap carries a char-table indexed
    ;;              by character, with *ranges* - and a range entry is what
    ;;              `subr.el:1763''s 32..126 loop and
    ;;              `international/mule-conf.el:1671''s
    ;;              `(cons 128 (max-char))' put in `global-map' so that an
    ;;              unbound printing character self-inserts. This tree has
    ;;              no char tables, so the slot holds a procedure of one
    ;;              event that answers a binding or `#f', and the range
    ;;              test lives inside it (`self-insert-char-table' below).
    ;;              It is consulted for this keymap's own events, before
    ;;              the parent, which is where the char-table sits in the C.
    ;;   label      the C's `keymap->prompt' - the name `define-key' and
    ;;              the mode machinery use to tell one map from another.
    ;;
    ;; What is deliberately *not* here: the original author's list of
    ;; "layers", each with a table and an `alt-action'. Emacs has no such
    ;; thing. The two jobs that machinery did are the two fields above -
    ;; precedence between maps is `parent', and the global map's
    ;; self-insert fallback is the char-table slot - and the third job it
    ;; pretended to do, `alt-action' ("keep the shorter binding when a
    ;; longer one is defined under it") is a case Emacs *forbids*:
    ;; `Fdefine_key' signals "Key sequence X starts with non-prefix key Y".
    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-type>
      (make<keymap> bindings order char-table parent label)
      keymap-type?
      (bindings  keymap-bindings  %set!keymap-bindings!)
      ;; `order' is the *sequence* of events as Emacs's sparse-keymap
      ;; alist has it. The hash `bindings' is this tree's one-step
      ;; lookup, and it has no order at all - which a menu needs, since
      ;; a menu bar is the keymap in its written order. A newly defined
      ;; event goes to the FRONT, which is `store_in_keymap`'s own
      ;; insertion point (`keymap.c:795'), and `define-key-after'
      ;; (subr.el) is what places one anywhere else. A binding made
      ;; again keeps its place, as `XSETCDR (elt, def)' keeps the cons.
      (order     keymap-order     %set!keymap-order!)
      (char-table keymap-char-table %set!keymap-char-table!)
      (parent    %keymap-record-parent %set-keymap-parent!)
      (label     keymap-label     set!keymap-label))

    (define *keymap-name-table* (make-hash-table))
    ;; ^ The tree's answer to `(symbol-value NAME)` for
    ;; `substitute-command-keys`' `\{NAME}` form: a keymap remembers the
    ;; name it was made with - its label - because a Scheme binding
    ;; cannot be reached from a symbol. Emacs's docstrings name the
    ;; *variable* (`\{help-mode-map}') while this tree's labels carry the
    ;; parameter convention's stars, so a `*name*' label is registered
    ;; under `name' as well. Built where the map is (a label is a
    ;; `make-sparse-keymap` argument); nothing sets a label afterwards.

    (define (register-keymap-name! label map)
      ;; LABEL, and its star-stripped spelling when it has one, name MAP.
      ;;--------------------------------------------------------------
      (when (symbol? label)
        (hashq-set! *keymap-name-table* label map)
        (let* ((s (symbol->string label))
               (n (string-length s)))
          (when (and (> n 2)
                     (char=? (string-ref s 0) #\*)
                     (char=? (string-ref s (- n 1)) #\*))
            (hashq-set! *keymap-name-table*
                        (string->symbol (substring s 1 (- n 1)))
                        map))))
      map)

    (define (keymap-by-name name)
      ;; The keymap NAME was made with, or #f - what `\{NAME}` asks
      ;; where Emacs asks `(symbol-value NAME)`.
      ;;--------------------------------------------------------------
      (and (symbol? name) (hashq-ref *keymap-name-table* name #f)))

    (define (make-sparse-keymap . rest)
      ;; GNU Emacs's `make-sparse-keymap' (`keymap.c:1122'): "Return a
      ;; newly created, empty, sparse keymap. ... The argument PROMPT is a
      ;; string to use as a prompt (or a list of a prompt and a menu
      ;; name)."
      ;;
      ;; This function used to take keymap *layers* and fold them into one
      ;; map; it takes a prompt and nothing else now, because a keymap that
      ;; needs a fallback has a `parent' or a char-table for it.
      ;;
      ;; **It is spelled `make-sparse-keymap' and not `keymap' because
      ;; `keymap' is a parameter name all over this file** - in `define-key',
      ;; in `keymap-lookup', in `define-as-prefix' - and a function that
      ;; calls `(keymap)' from inside one of those would call the *parameter*.
      ;; That is not hypothetical: `define-as-prefix' did exactly that and
      ;; every `define-key' on a key sequence answered "Wrong type to apply:
      ;; #<keymap-type ...>". `keymap' below is this function under the name
      ;; the tree uses.
      ;;--------------------------------------------------------------
      (cond
       ((null? rest) (make<keymap> (make-hash-table) '() #f #f #f))
       ;; `(make-sparse-keymap nil)' is Emacs's: "nil" is a prompt-less
       ;; map, which `keymap-canonicalize' builds.
       ((and (not (car rest)) (null? (cdr rest)))
        (make<keymap> (make-hash-table) '() #f #f #f))
       ;; a prompt, and nothing else: `make-sparse-keymap' takes the
       ;; prompt and stops, so a second argument is an error rather than
       ;; something quietly ignored.
       ((and (or (string? (car rest)) (symbol? (car rest)))
             (null? (cdr rest)))
        (register-keymap-name!
         (car rest)
         (make<keymap> (make-hash-table) '() #f #f (car rest))))
       ((and (keymap-type? (car rest)) (null? (cdr rest)))
        ;; `(keymap MAP)' is MAP - what `(keymap kml)' meant before, when
        ;; a keymap argument stood for its layers.
        (car rest))
       (else
        (error "make-sparse-keymap takes one prompt" rest))))

    (define (copy-keymap keymap)
      ;; GNU Emacs's `copy-keymap` (`keymap.c:1018`): "Return a copy of
      ;; the keymap KEYMAP. ... After performing `copy-keymap', the copy
      ;; starts out with the same definitions of KEYMAP, but changing
      ;; either the copy or KEYMAP does not affect the other.  Any key
      ;; definitions that are subkeymaps are recursively copied.
      ;; However, a key definition which is a symbol whose definition is
      ;; a keymap is not copied."
      ;;
      ;; The C copies the keymap *list*, so a `(menu-item ...)` or an
      ;; old-style `(STRING . DEF)` binding has its leading cells copied
      ;; and a keymap in its definition cell copied recursively
      ;; (`copy_keymap_item`, `keymap.c:906`).  This tree's keymap is a
      ;; record, and three of its fields need the same treatment: the
      ;; binding table, the parent (the C's `(t . PARENT)` entry - a
      ;; keymap there, so copied), and the label (the C's prompt, which
      ;; it keeps).  The char-table slot here is a *procedure* standing
      ;; in for the char-table (see the record's comment); a procedure
      ;; has no contents to copy, so it is shared.
      ;;
      ;; A name-to-keymap alias - Emacs's "symbol whose definition is a
      ;; keymap" - is not a thing this tree can have: a keymap is the
      ;; object, and `register-keymap-name!` records it beside the map,
      ;; not in a symbol.
      ;;--------------------------------------------------------------
      (%copy-keymap-1 keymap 0))

    (define (%copy-keymap-1 keymap depth)
      ;; The C's static recursion, with its own guard.
      ;;--------------------------------------------------------------
      (when (> depth 100)
        (error "Possible infinite recursion when copying keymap"))
      (unless (keymap-type? keymap)
        (error "Invalid keymap" keymap))
      (let* ((order (append (keymap-order keymap) '()))
             (copy (make<keymap> (make-hash-table) order
                                 (keymap-char-table keymap)
                                 (let ((parent (keymap-parent keymap)))
                                   (and parent
                                        (%copy-keymap-1 parent (+ depth 1))))
                                 (keymap-label keymap))))
        (for-each
         (lambda (event)
           (hashv-set! (keymap-bindings copy) event
                       (%copy-keymap-binding
                        (hashv-ref (keymap-bindings keymap) event)
                        depth)))
         order)
        ;; A map built by a direct hash write can hold an event its order
        ;; list does not - keep it, so the copy really has every binding.
        (hash-for-each
         (lambda (event def)
           (unless (memv event order)
             (%set!keymap-order! copy (cons event (keymap-order copy)))
             (hashv-set! (keymap-bindings copy) event
                         (%copy-keymap-binding def depth))))
         (keymap-bindings keymap))
        copy))

    (define (%copy-keymap-binding def depth)
      ;; The C's `copy_keymap_item` (`keymap.c:906`) over one binding
      ;; value: a subkeymap is copied, a menu item's leading cells are
      ;; copied and its definition recursed, and anything else is shared.
      ;;--------------------------------------------------------------
      (cond
       ((keymap-type? def) (%copy-keymap-1 def (+ depth 1)))
       ((not (pair? def)) def)
       ((eq? (car def) 'menu-item)
        (let* ((rest (cdr def))
               (name (if (pair? rest) (car rest) #f))
               (rest (if (pair? rest) (cdr rest) '()))
               (bind (if (pair? rest) (car rest) #f))
               (props (if (pair? rest) (cdr rest) '())))
          (append (list 'menu-item name
                        (%copy-keymap-binding bind (+ depth 1)))
                  props)))
       ((string? (car def))
        ;; The old-style `(STRING . DEF)` menu item, and its
        ;; `(STRING HELP . DEF)` form.
        (let ((rest (cdr def)))
          (if (and (pair? rest) (string? (car rest)))
              (cons (car def)
                    (cons (car rest)
                          (%copy-keymap-binding (cdr rest) (+ depth 1))))
              (cons (car def) (%copy-keymap-binding rest (+ depth 1))))))
       (else def)))

    (define keymap make-sparse-keymap)

    (define (keymap-prompt keymap)
      ;; GNU Emacs's `keymap-prompt' (`keymap.c:146'): "Return the prompt
      ;; which is usually a string, but could be a list, associated with
      ;; KEYMAP, or nil if it doesn't have one." Here the prompt is the
      ;; record's label - `define-as-prefix' puts "Prefix Command" there
      ;; in Emacs, and `make-sparse-keymap' takes it as PROMPT - and for
      ;; a *list* keymap the C's own scan: the first string element, or
      ;; the prompt of the first keymap element.
      ;;--------------------------------------------------------------
      (cond
       ((keymap-type? keymap) (keymap-label keymap))
       ((and (pair? keymap) (eq? (car keymap) 'keymap))
        (let loop ((rest (cdr keymap)))
          (cond
           ((not (pair? rest)) #f)
           ((string? (car rest)) (car rest))
           ((keymapp (car rest))
            (let ((prompt (keymap-prompt (car rest))))
              (if prompt prompt (loop (cdr rest)))))
           (else (loop (cdr rest))))))
       (else #f)))

    (define (keymap-parent keymap)
      ;; GNU Emacs's `keymap-parent' (`keymap.c:236', `keymap_parent`):
      ;; "Return the parent keymap of KEYMAP." For a record that is the
      ;; stored parent; for a list keymap the C's scan - the first
      ;; `KEYMAPP' element - and a tail that is itself a keymap.
      ;;--------------------------------------------------------------
      (cond
       ((keymap-type? keymap) (%keymap-record-parent keymap))
       ((pair? keymap)
        (let loop ((rest (cdr keymap)))
          (cond ((not (pair? rest))
                 (and (keymapp rest) rest))
                ((keymapp (car rest)) (car rest))
                (else (loop (cdr rest))))))
       (else #f)))

    (define (keymap-lookup-binding-key keymap binding)
      ;; The key sequence a BINDING is reached by in KEYMAP, or #f. It is
      ;; a reverse lookup, and it is GNU Emacs's `where-is-internal'
      ;; (`keymap.c:1889') reduced to the one question this tree asks of
      ;; it: the first key that runs BINDING.
      ;;
      ;; **It descends into a prefix**, because a binding under one is not
      ;; in this keymap's own table: `C-c C-c' is the event `3' bound to a
      ;; *keymap*, and the command is the event `3' inside that. The
      ;; sequence is the two events joined, which is what the caller needs
      ;; to be able to press.
      ;;--------------------------------------------------------------
      ;; In `keymap-order`, Emacs's alist order, so "the first key that
      ;; runs BINDING" is the first one *in the map's own order* - the
      ;; hash alone had no order to answer that question with.
      (let loop ((events (keymap-order keymap)))
        (cond
         ((null? events) #f)
         (else
          (let ((event (car events))
                (def (hashv-ref (keymap-bindings keymap) (car events) #f)))
            (cond
             ((eq? binding def) (list event))
             ((keymap-type? def)
              (let ((under (keymap-lookup-binding-key def binding)))
                (if under (cons event under) (loop (cdr events)))))
             (else (loop (cdr events)))))))))

    (define *menu-item-eval-property-function* (make-parameter #f))
    ;; ^ GNU Emacs's `menu_item_eval_property` (`keyboard.c:8843'),
    ;; which `keymap.c` reaches because the two live in one C program.
    ;; Here the evaluator is `keyboard.scm`'s, so it arrives through this
    ;; parameter and `keyboard.scm` installs it as it loads. When it is
    ;; unset - a library that imports `keymap` alone - a filter written
    ;; as a *procedure* still works (the common case), and one written as
    ;; a form is answered unevaluated.
    ;;--------------------------------------------------------------

    (define (%menu-item-filter rest)
      ;; The `:filter` property in a menu item's property list, or #f.
      ;; This is the C's walk at `keymap.c:700`: step one cons at a time
      ;; through TEM = (CDDR OBJECT), so both `(:filter F :enable E)` and
      ;; `(:enable E :filter F)` find it.
      ;;--------------------------------------------------------------
      (let loop ((tem rest))
        (cond ((and (pair? tem) (pair? (cdr tem)))
               (if (eq? (car tem) ':filter)
                   (cadr tem)
                   (loop (cdr tem))))
              (else #f))))

    (define (%menu-item-filter-answer def rest)
      ;; Apply a menu item's `:filter` to DEF, exactly as
      ;; `get_keyelt`'s `QCfilter` arm does: the filter is a function of
      ;; one argument (the definition) and its answer is the definition
      ;; to use. A *procedure* is this tree's lambda - the data a menu
      ;; item is written with evaluates to one - so it is called
      ;; directly; a form or symbol goes through the evaluator seam, as
      ;; the C builds `(FILTER 'DEF)` and evaluates it.
      ;;--------------------------------------------------------------
      (let ((filter (%menu-item-filter rest)))
        (cond
         ((not filter) def)
         ((procedure? filter) (filter def))
         (else
          (let ((evaluate (*menu-item-eval-property-function*)))
            (if evaluate
                (evaluate (list filter (list 'quote def)))
                def))))))

    (define (get-keyelt object autoload)
      ;; GNU Emacs's `get_keyelt` (`keymap.c:681`): "Given OBJECT which
      ;; was found in a slot in a keymap, trace indirect definitions to
      ;; get the actual definition of that slot. ... Also if OBJECT has a
      ;; menu string as the first element, remove that."
      ;;
      ;; **This is a function of its own in the C**, and it used to be
      ;; inline in `access-keymap` here. Two coercions live in it: a
      ;; `(STRING . DEFN)` binding - how `menu-bar.el` stores
      ;; `[menu-bar file]`, the string being the name the bar shows - and
      ;; a `(menu-item NAME DEF ...)` binding, whose command is DEF. The
      ;; C's `where_is_internal_1` and `accessible_keymaps_1` both call
      ;; it directly, which is why it is out here now.
      ;;
      ;; AUTOLOAD is the C's flag for applying a `:filter` property
      ;; through `menu_item_eval_property`; every caller here passes #f,
      ;; so a filtered item answers the form rather than its result.
      ;;--------------------------------------------------------------
      (let loop ((object object))
        (cond
         ((not (pair? object)) object)
         ((eq? (car object) 'menu-item)
          (if (pair? (cdr object))
              (let* ((rest (cddr object))
                     (def (if (pair? rest) (car rest) rest)))
                (loop (if autoload
                          (%menu-item-filter-answer def rest)
                          def)))
              object))
         ((string? (car object)) (loop (cdr object)))
         (else object))))

    (define (append-key key-sequence key)
      ;; GNU Emacs's `append_key` (`keymap.c:1456`): "AUTO_LIST1 (key_list,
      ;; key); return CALLN (Fvconcat, key_sequence, key_list)" - the
      ;; sequence with one more event on the end.
      ;;--------------------------------------------------------------
      (vconcat key-sequence (list key)))

    (define (%accessible-cycle? cmd maps thisseq)
      ;; `accessible_keymaps_1`'s "Look for and break cycles" loop
      ;; (`keymap.c:1958`): #t when CMD is already in MAPS under a prefix
      ;; of THISSEQ - which is a cycle, because that map would reach
      ;; itself the same way round. `set-keymap-parent` refuses to make
      ;; one, but a key bound to its own map makes one all the same.
      ;;--------------------------------------------------------------
      (let loop ((rest maps))
        (cond
         ((null? rest) #f)
         ((not (eq? (cdr (car rest)) cmd)) (loop (cdr rest)))
         (else
          (let ((prefix (car (car rest))))
            (if (<= (vector-length prefix) (vector-length thisseq))
                (let scan ((i 0))
                  (cond ((>= i (vector-length prefix)) #t)
                        ((eqv? (vector-ref prefix i)
                               (vector-ref thisseq i))
                         (scan (+ i 1)))
                        (else (loop (cdr rest)))))
                (loop (cdr rest))))))))

    (define (accessible-keymaps keymap prefix)
      ;; GNU Emacs's `accessible-keymaps` (`keymap.c:2010`): "Find all
      ;; keymaps accessible via prefix characters from KEYMAP. Returns a
      ;; list of elements of the form (KEYS . MAP) ... ordered so that the
      ;; KEYS increase in length."
      ;;
      ;; **The breadth-first order is what `where-is-internal` relies
      ;; on**: "the first key that runs the command" is the first in this
      ;; list. The C grows the list in place - `tail` is the cons it is
      ;; standing on and new entries are nconc'd onto its end, except a
      ;; metized one, which goes straight after `tail` - and that is what
      ;; this does, with `set-cdr!`, so the answer is the C's list and not
      ;; merely the same set.
      ;;--------------------------------------------------------------
      (let* ((prefix (cond ((vector? prefix) prefix)
                           ((pair? prefix) (list->vector prefix))
                           (else '#())))
             (prefixlen (vector-length prefix))
             (maps (if (> prefixlen 0)
                       (let ((tem (keymap-lookup keymap prefix)))
                         (if (keymap-type? tem)
                             (list (cons prefix tem))
                             '()))
                       (list (cons '#() keymap))))
             (end (if (null? maps) '() (last-pair maps))))
        (let loop ((tail maps))
          (if (null? tail)
              maps
              (let* ((entry (car tail))
                     (thisseq (car entry))
                     (thismap (cdr entry))
                     (events (vector->list thisseq))
                     (last (- (length events) 1))
                     ;; "Does the current sequence end in the
                     ;; meta-prefix-char?" - and "Don't metize the last
                     ;; char of PREFIX."
                     (is-metized (and (>= last 0)
                                      (>= last prefixlen)
                                      (eqv? (list-ref events last) 27))))
                ;; `map_keymap` rather than the internal one: a parent's
                ;; bindings are reached through this map, as the C's
                ;; `map_keymap` reaches them.
                (map-keymap
                 (lambda (key cmd)
                   ;; `cmd = get_keymap (get_keyelt (cmd, 0), 0, 0)`: only
                   ;; a keymap carries on. A symbol whose function is a
                   ;; keymap is resolved in the C; this tree's keymaps are
                   ;; values (`access-keymap`'s note says the same).
                   (let ((cmd (get-keyelt cmd #f)))
                     (when (and (keymap-type? cmd)
                                (not (%accessible-cycle? cmd maps thisseq)))
                       (if is-metized
                           ;; "This new sequence is the same length as
                           ;; thisseq, so stick it in the list right
                           ;; after this one."
                           (let* ((tem (vector-copy thisseq))
                                  (idx (- (vector-length tem) 1)))
                             (vector-set! tem idx (logior key char-meta))
                             (set-cdr! tail (cons (cons tem cmd) (cdr tail)))
                             ;; TAIL may have been the last cons, in which
                             ;; case the end moved with the insert.
                             (set! end (last-pair maps)))
                           (let ((tem (append-key thisseq key)))
                             (set-cdr! end (list (cons tem cmd)))
                             (set! end (cdr end))))
                       #f))
                   #f)
                 thismap)
                (loop (cdr tail)))))))

    (define (%map-keymap-list-item function binding)
      ;; `map_keymap_item' (`keymap.c:500') over one element of a list
      ;; keymap: a `(EVENT . DEF)' cons calls FUNCTION, and a binding of
      ;; `t' - the marker for an explicitly unbound key - is passed as
      ;; nil. **A char-table element is not walked** (Emacs maps its
      ;; ranges with `map_char_table'); a list keymap this tree builds
      ;; has none, and this library does not import the char-table
      ;; library.
      ;;--------------------------------------------------------------
      (cond
       ((pair? binding)
        (let ((val (cdr binding)))
          (function (car binding) (if (eq? val #t) #f val))))
       ((vector? binding)
        (let loop ((i 0))
          (when (< i (vector-length binding))
            (let ((val (vector-ref binding i)))
              (function i (if (eq? val #t) #f val)))
            (loop (+ i 1)))))
       (else #f)))

    (define (%map-keymap-list-internal function map)
      ;; `map_keymap_internal` (`keymap.c:535`) over a list keymap: call
      ;; FUNCTION with each binding until an embedded parent map, and
      ;; return the tail that starts at it (the C returns that tail too).
      ;;--------------------------------------------------------------
      (let loop ((rest map))
        (cond
         ((not (pair? rest)) '())
         ((keymapp (car rest)) rest)
         (else
          (%map-keymap-list-item function (car rest))
          (loop (cdr rest))))))

    (define (map-keymap-internal function keymap)
      ;; GNU Emacs's `map_keymap_internal' (`keymap.c:535`): call
      ;; FUNCTION with each event bound in KEYMAP's own table and its
      ;; definition, and return the parent map without processing it.
      ;;
      ;; **The char-table is not walked, and that is the one deviation.**
      ;; Emacs's full keymap keeps a char-table whose *ranges* this
      ;; function enumerates (`map_char_table'); this tree's slot holds a
      ;; single procedure (see the record's note), so there is nothing to
      ;; enumerate. Nothing that uses this yet needs it - the menu-bar
      ;; walk reads sparse bindings.
      ;;
      ;; `map_keymap_item's one rule is kept: a binding of `t' (the
      ;; marker the C stores for an explicitly unbound key) is passed as
      ;; nil.
      ;;--------------------------------------------------------------
      (cond
       ((keymap-type? keymap)
        (for-each
         (lambda (event)
           (let ((def (hashv-ref (keymap-bindings keymap) event #f)))
             (function event (if (eq? def #t) #f def))))
         (keymap-order keymap))
        (keymap-parent keymap))
       ((and (pair? keymap) (eq? (car keymap) 'keymap))
        (%map-keymap-list-internal function (cdr keymap)))
       (else
        (error "map-keymap-internal: not a keymap" keymap))))

    (define (map-keymap function keymap)
      ;; GNU Emacs's `map-keymap' (`keymap.c:625'): "Call FUNCTION once
      ;; for each event binding in KEYMAP. ... If KEYMAP has a parent,
      ;; the parent's bindings are included as well."
      ;;
      ;; Emacs accepts a symbol whose function is a keymap, and autoloads
      ;; one; this tree's keymaps are values - `access-keymap's note says
      ;; the same - so a symbol is an error rather than being resolved.
      ;; The third Emacs argument, SORT-FIRST, belongs to
      ;; `map-keymap-sorted', which is not ported.
      ;;
      ;; **A list keymap is walked the way `map_keymap' walks one**
      ;; (`keymap.c:589`): every binding in order, with an embedded
      ;; parent map searched recursively where it stands.
      ;;--------------------------------------------------------------
      (unless (or (keymap-type? keymap)
                  (and (pair? keymap) (eq? (car keymap) 'keymap)))
        (error "map-keymap: not a keymap" keymap))
      (cond
       ((keymap-type? keymap)
        (let loop ((map keymap))
          (when map
            (map-keymap-internal function map)
            (loop (keymap-parent map)))))
       (else
        (let loop ((rest (cdr keymap)))
          (cond ((not (pair? rest)) #f)
                ((keymapp (car rest))
                 (map-keymap function (car rest))
                 (loop (cdr rest)))
                (else
                 (%map-keymap-list-item function (car rest))
                 (loop (cdr rest)))))))
      #f)

    ;; -------------------------------------------------------------------------------------------------

    (define (set-keymap-parent keymap parent)
      ;; GNU Emacs's `set-keymap-parent' (`keymap.c:273'): "Modify KEYMAP
      ;; to set its parent map to PARENT. Return PARENT. PARENT should be
      ;; nil or another keymap."
      ;;
      ;; The C's cycle check is `keymap_memberp': a keymap may not become
      ;; its own ancestor, or the lookup would never end.
      ;;
      ;; **A list keymap's parent is stored in the list itself** - the
      ;; C's scan (`keymap.c:291') replaces the improper tail (or appends
      ;; one when there is none), which is what makes
      ;; `(keymap "Title" (a . b) . PARENT)' a keymap that inherits.
      ;;--------------------------------------------------------------
      (unless (or (not parent) (keymapp parent))
        (error "not a keymap" parent))
      (unless (or (keymap-type? keymap)
                  (and (pair? keymap) (eq? (car keymap) 'keymap)))
        (error "not a keymap" keymap))
      (when (and parent (keymap-memberp keymap parent))
        (error "Cyclic keymap inheritance"))
      (cond
       ((keymap-type? keymap)
        (%set-keymap-parent! keymap parent)
        parent)
       (else
        (let loop ((prev keymap))
          (let ((rest (cdr prev)))
            (if (or (not (pair? rest)) (keymapp rest))
                (set-cdr! prev parent)
                (loop rest))))
        parent)))

    (define (keymap-memberp map maps)
      ;; GNU Emacs's `keymap_memberp' (`keymap.c:263'): "Check whether MAP
      ;; is one of MAPS's parents" - the walk `set-keymap-parent' uses to
      ;; refuse an inheritance that would be a cycle.
      ;;--------------------------------------------------------------
      (if (not map)
          #f
          (let loop ((maps maps))
            (cond ((not (keymap-type? maps)) #f)
                  ((eq? map maps) #t)
                  (else (loop (keymap-parent maps)))))))

    (define (set-keymap-char-table! keymap proc)
      ;; The char-table slot: PROC is a procedure of one *event* answering
      ;; a binding or `#f', and #f clears it. See the note on
      ;; `<keymap-type>' for why this is a procedure and not a table.
      ;;--------------------------------------------------------------
      (unless (or (not proc) (procedure? proc))
        (error "not a procedure" proc))
      (%set!keymap-char-table! keymap proc)
      proc)

    (define (self-insert-char-table command)
      ;; The char-table slot of a map that should self-insert - the tree's
      ;; spelling of Emacs's two *range* bindings, `subr.el:1763''s loop
      ;; over 32..126 and `international/mule-conf.el:1671''s
      ;; `(cons 128 (max-char))' on `global-map'.
      ;;
      ;; The event must be a plain character: no modifier at all, at least
      ;; a space, and not DEL - that is 32..126 and 128 upward, which is
      ;; exactly Emacs's two ranges. A *named* key is not one, and a key
      ;; of more than one event is a prefix and is not either.
      ;;
      ;; Without the test every unbound named key (`<f13>', `<prior>',
      ;; `<insert>') reached `self-insert-command', which inserted the
      ;; key's *name* as text - and in a read-only buffer said "Buffer is
      ;; read-only" and otherwise did nothing, which is how PgUp and PgDn
      ;; were lost in Dired.
      ;;--------------------------------------------------------------
      (lambda (event)
        (and (integer? event)
             (zero? (logand event (logior char-alt char-super char-hyper
                                          char-shift char-meta)))
             (not (< event 32))
             (zero? (logand event char-ctl))
             (not (= event 127))
             command)))

    ;;------------------------------------------------------------------
    ;; The two choke points - `keymap.c''s `store_in_keymap' and
    ;; `access_keymap'
    ;;
    ;; Emacs writes EVERY binding through `store_in_keymap'
    ;; (`keymap.c:730') - from `Fdefine_key' (`:1187'), from the autoload
    ;; seeding (`:131') and from `:1448' - and reads every one through
    ;; `access_keymap' -> `access_keymap_1' (`:491', `:327'). Nothing else
    ;; in Emacs touches a keymap.
    ;;
    ;; **Both are keyed by ONE EVENT** - an integer carrying its modifier
    ;; bits, or a symbol - and that is the point of them. Emacs reaches
    ;; that state by normalising the key sequence one level up, in
    ;; `Fdefine_key'/`Flookup_key' (`keymap.c:1156', `:1264'), where an
    ;; element that is a list goes through `Fevent_convert_list'
    ;; (`keyboard.c:7832') and comes back an event. This tree has the
    ;; same conversion in `keymap-event' above.
    ;;
    ;; A value that is itself a keymap is a *prefix*: `access_keymap_1'
    ;; recurses into it, and a sequence is walked one event at a time.
    ;;------------------------------------------------------------------

    (define (%keymap-remove-binding! keymap event)
      ;; Remove EVENT's binding from KEYMAP, entrance from the order
      ;; vector included. **No Emacs counterpart**: the C keeps its
      ;; bindings in an alist, so `easy-menu-define-key' removes one by
      ;; splicing the list (`(setcdr menu (cddr menu))') - there is
      ;; nothing to splice in this tree's hash, so the removal is a
      ;; function of its own. `easy-menu-remove-item' is its caller.
      ;;--------------------------------------------------------------
      (let ((event (if (char? event) (char->integer event) event)))
        ;; `hashv-remove!`, not `hash-remove!`: the bindings table is
        ;; written with the `hashv` family, and a generic removal looks
        ;; in a bucket the generic hash function computes - a different
        ;; bucket, so the binding survives (found by the easymenu port).
        (hashv-remove! (keymap-bindings keymap) event)
        (%set!keymap-order!
         keymap
         (let drop ((l (keymap-order keymap)))
           (cond ((not (pair? l)) '())
                 ((eqv? (car l) event) (cdr l))
                 (else (cons (car l) (drop (cdr l)))))))
        #f))

    (define (store-in-keymap keymap event def)
      ;; GNU Emacs's `store_in_keymap' (`keymap.c:730'): "Scan the keymap
      ;; for a binding of IDX" and set it.
      ;;
      ;; The C's two errors are kept: `keymap' is reserved for an
      ;; embedded parent map, and a non-keymap is refused outright when
      ;; there is a parent and the key is already bound in it.
      ;;--------------------------------------------------------------
      (when (eq? event 'keymap)
        (error "`keymap' is reserved for embedded parent maps"))
      (let ((event (if (char? event) (char->integer event) event)))
        (unless (or (integer? event) (symbol? event))
          (error "store-in-keymap: not an event" event))
        ;; **The first binding of an event decides its place.** The C
        ;; inserts a new cons at the map's front (`keymap.c:795') and
        ;; rewrites an existing cons's cdr in place, so a redefinition
        ;; keeps its position. The hash has no order; `order' carries
        ;; Emacs's.
        (unless (memv event (keymap-order keymap))
          (%set!keymap-order! keymap (cons event (keymap-order keymap))))
        (hashv-set! (keymap-bindings keymap) event def)
        def))

    (define (%keymap-coerce-binding own)
      ;; `get_keyelt' (`keymap.c:685') over a binding value: the two
      ;; shapes that are not the definition itself are rewritten to the
      ;; definition, and nothing else changes.
      ;;
      ;; **"If the keymap contents looks like (STRING . DEFN), use
      ;; DEFN."** - the C's own words (`keymap.c:719`). It is how a
      ;; menu bar item is stored: `menu-bar.el' binds
      ;; `[menu-bar file]' to `(cons "File" menu-bar-file-menu)',
      ;; the string being the name the bar shows and the cdr the
      ;; keymap the next event of the sequence is looked up in.
      ;; Without this `[menu-bar file save-buffer]' has no binding
      ;; at all, and `parse_menu_item' - which *wants* that cons -
      ;; is the one reader that never goes through here.
      ;;
      ;; **"If the keymap contents looks like (menu-item name .
      ;; DEFN) or (menu-item name DEFN ...) then use DEFN."** The
      ;; other half of `get_keyelt` (`keymap.c:685`). A menu item
      ;; is a *binding*, and the thing it runs is inside it - so a
      ;; menu clicked with the mouse and the same item typed as
      ;; `[menu-bar file save-buffer]` both have to reach the
      ;; command itself, not the list describing it.
      ;;--------------------------------------------------------------
      (cond
       ((and (pair? own) (string? (car own))) (cdr own))
       ((and (pair? own) (eq? (car own) 'menu-item) (pair? (cdr own)))
        ;; **`access_keymap_1` always asks `get_keyelt (val, true)`**
        ;; (`keymap.c:468`), so a `:filter` is applied on every lookup
        ;; - that is how `electric-pair-mode-map`'s DEL decides whether
        ;; to delete a pair or fall through to the global binding.
        (let ((rest (cddr own)))
          (%menu-item-filter-answer
           (if (pair? rest) (car rest) rest) rest)))
       (else own)))

    (define (%keymap-own-binding keymap event)
      ;; `access_keymap_1''s own-map half (`keymap.c:377-474'): one event
      ;; in one map's own bindings, its char-table and nothing else -
      ;; what is found before any inheritance is consulted.
      ;;--------------------------------------------------------------
      (let ((own (hashv-ref (keymap-bindings keymap) event #f)))
        (if own
            (%keymap-coerce-binding own)
            (let ((ct (keymap-char-table keymap)))
              (and ct (ct event))))))

    (define %keymap-unbound (list 'keymap-unbound))
    ;; ^ The C's `Qunbound`: "we have found no binding" has to be told
    ;; from a binding of nil, which *is* an answer (an explicitly unbound
    ;; key). A unique pair, so nothing a caller stores can equal it.

    (define (%keymap-list-access tail event noinherit)
      ;; `access_keymap_1`'s walk over a *list* keymap
      ;; (`keymap.c:389-490`) - `(keymap [TITLE] [PARENT] . ALIST)`, and
      ;; equally a list of keymaps, which the C treats the same way: each
      ;; element is tried in order and keymap elements are searched with
      ;; their own bindings. TAIL is the list's elements (already past the
      ;; `keymap' symbol, if there was one).
      ;;
      ;; The C's `retval`/`retval_tail` accumulate *prefix* keymaps into
      ;; `(keymap PREFIX...)`, so an event that is a prefix in two maps
      ;; answers both; `t_binding` is the `(t . DEF)` default, which is
      ;; consulted only when nothing specific was found. Both are here.
      ;;--------------------------------------------------------------
      (let loop ((rest tail)
                 (t-binding %keymap-unbound)
                 (t-ok #t)
                 (retval %keymap-unbound)
                 (retval-tail #f))
        (let ((finish
               (lambda (retval)
                 (if (eq? retval %keymap-unbound)
                     (if (eq? t-binding %keymap-unbound)
                         #f
                         (%keymap-coerce-binding t-binding))
                     retval))))
          (cond
           ((not (pair? rest))
            ;; The C's loop condition turns a non-cons tail into a keymap
            ;; and searches it as the rest of the same map
            ;; (`keymap.c:389`: `tail = get_keymap (tail, 0, true)').
            ;; That is how a list keymap's parent - the improper tail
            ;; `(keymap ... . PARENT)' - is inherited.
            (if (keymapp rest)
                (let ((val (access-keymap rest event noinherit)))
                  (cond
                   ((or (eq? retval %keymap-unbound) (not retval))
                    (finish (if val val retval)))
                   ((keymapp val)
                    (finish (if retval-tail
                                (begin (set-cdr! retval-tail (list val))
                                       retval)
                                (cons 'keymap (cons retval (list val))))))
                   (else (finish retval))))
                (finish retval)))
           (else
            (let ((binding (car rest)))
              (cond
               ;; The symbol `keymap` inside the list marks where the
               ;; inherited part begins; with NOINHERIT the walk stops
               ;; there, otherwise the rest is searched as a parent and
               ;; its prefix answer is appended to this one
               ;; (`keymap.c:399`).
               ((eq? binding 'keymap)
                (if (or noinherit (not retval))
                    (finish retval)
                    (let ((parent-entry
                           (%keymap-and-own
                            (%keymap-list-access rest event noinherit))))
                      (cond
                       ((not (keymapp parent-entry)) (finish retval))
                       (retval-tail
                        (set-cdr! retval-tail parent-entry)
                        (finish retval))
                       (else
                        (finish (cons 'keymap
                                      (cons retval (list parent-entry)))))))))
               (else
                (let ((val
                       (cond
                        ;; An embedded keymap: searched exactly as the
                        ;; C's `access_keymap_1 (submap, idx, t_ok,
                        ;; noinherit)`.
                        ((keymapp binding)
                         (access-keymap binding event noinherit))
                        ((pair? binding)
                         (let ((key (car binding)))
                           (cond
                            ((eqv? key event)
                             (%keymap-coerce-binding (cdr binding)))
                            ((and t-ok (eq? key 't))
                             ;; `(t . DEF)' is the default: remembered,
                             ;; and the first one found wins.
                             (set! t-ok #f)
                             (set! t-binding (cdr binding))
                             %keymap-unbound)
                            (else %keymap-unbound))))
                        ;; A dense table: the C reads AREF (binding, idx).
                        ((vector? binding)
                         (if (and (integer? event)
                                  (>= event 0)
                                  (< event (vector-length binding)))
                             (vector-ref binding event)
                             %keymap-unbound))
                        (else %keymap-unbound))))
                  (cond
                   ((eq? val %keymap-unbound)
                    (loop (cdr rest) t-binding t-ok retval retval-tail))
                   ;; A binding of nil is an *answer* (the key is
                   ;; explicitly unbound) but it does not shadow what
                   ;; follows; a non-nil one does.
                   ((keymapp val)
                    (cond
                     ((or (eq? retval %keymap-unbound) (not retval))
                      (loop (cdr rest) t-binding t-ok val #f))
                     (retval-tail
                      (set-cdr! retval-tail (list val))
                      (loop (cdr rest) t-binding t-ok retval
                            (cdr retval-tail)))
                     (else
                      (let ((new-tail (list val)))
                        (loop (cdr rest) t-binding t-ok
                              (cons 'keymap (cons retval new-tail))
                              new-tail)))))
                   (else
                    (let ((retval (if (or (eq? retval %keymap-unbound)
                                          (not retval))
                                      val
                                      retval)))
                      (if val
                          (finish retval)
                          (loop (cdr rest) t-binding t-ok retval
                                retval-tail))))))))))))))

    (define (%keymap-and-own value)
      ;; `get_keymap (VALUE, 0, true)`: VALUE itself when it is a keymap,
      ;; and nil otherwise. This tree's keymaps are values, so it is the
      ;; `keymapp` test.
      ;;--------------------------------------------------------------
      (and (keymapp value) value))

    (define (access-keymap keymap event . rest)
      ;; GNU Emacs's `access_keymap' (`keymap.c:491'): the binding of one
      ;; EVENT in KEYMAP, or #f. A *keymap* answer means the event is a
      ;; prefix; the caller reads the next event and calls this again on
      ;; it, which is `Flookup_key''s walk (`keymap.c:1264').
      ;;
      ;; **NOINHERIT is the C's fourth argument**, and it is what tells
      ;; the two callers apart: `lookup-key' passes nothing and so
      ;; follows the map's parent, while `define-key' passes #t because
      ;; a *parent's* `C-x' does not count there - a child is free to
      ;; make its own (`Fdefine_key' walks with `access_keymap (..., 0,
      ;; 1)').
      ;;
      ;; **And the answer can be a *keymap list*.** When the event is a
      ;; prefix both in a map and in its parent, `access_keymap_1'
      ;; answers `(keymap CHILD-PREFIX PARENT-PREFIX)' rather than one
      ;; of them (`keymap.c:416-420'), so a key only the parent's
      ;; prefix goes on to define is still reachable. Measured on Emacs
      ;; 31.1: a child defining `C-c x' and a parent `C-c y' answers
      ;; `C-c y' as the parent's command through `lookup-key'.
      ;;
      ;; A KEYMAP that is a pair is a *list keymap* - Emacs's
      ;; `(keymap [TITLE] . ALIST)' - or a list of keymaps, which the C
      ;; walks with the same loop: each element in order, embedded
      ;; keymaps searched, conses compared as bindings, and the prefix
      ;; answers accumulated the same way. `imenu--create-keymap' is
      ;; what builds such a map (`(keymap "Index" ("name" lambda))'),
      ;; and the menu bar reads it back through here.
      ;;--------------------------------------------------------------
      (let ((noinherit (and (pair? rest) (car rest)))
            (event (if (char? event) (char->integer event) event)))
        (unless (or (integer? event) (symbol? event))
          (error "access-keymap: not an event" event))
        (cond
         ((not keymap) #f)
         ((pair? keymap)
          (%keymap-list-access
           (if (eq? (car keymap) 'keymap) (cdr keymap) keymap)
           event noinherit))
         (else
          (let* ((own (%keymap-own-binding keymap event))
                 (parent (and (not noinherit)
                              (keymap-type? keymap)
                              (keymap-parent keymap)))
                 (inherited (and parent (access-keymap parent event #f))))
            (cond
             ((not own) inherited)
             ((and (keymap-type? own) (keymap-type? inherited))
              (list 'keymap own inherited))
             (else own)))))))

    (define (keymapp object)
      ;; GNU Emacs's `keymapp' (`keymap.c:3012'): "Return t if OBJECT is
      ;; a keymap."
      ;;
      ;; `KEYMAPP' is `(!NILP (get_keymap (m, false, false)))'
      ;; (`keymap.h:34'), and `get_keymap' answers a *keymap list*
      ;; `(keymap MAP...)' as one (`keymap.c:197') - which is what
      ;; `access-keymap' builds when a key is a prefix in two maps. The
      ;; C also answers t for a symbol whose function definition is a
      ;; keymap; this tree's keymaps are values and a symbol has no
      ;; function here, so that arm is not carried.
      ;;--------------------------------------------------------------
      (or (keymap-type? object)
          (and (pair? object) (eq? (car object) 'keymap))))

    (define (%keymap-t-default keymap)
      ;; The `(t . DEF)' default binding of one keymap - what the C's
      ;; `access_keymap_1' remembers in `t_binding'.  Nothing in this tree
      ;; stores one; the rule exists because `lookup-key''s
      ;; ACCEPT-DEFAULT is defined in terms of it, and `describe-map'
      ;; calls with ACCEPT-DEFAULT set.
      ;;--------------------------------------------------------------
      (hashv-ref (keymap-bindings keymap) 't #f))

    (define (%keymap-t-default-chain keymap)
      ;; The nearest `(t . DEF)' in KEYMAP or one of its parents. The C
      ;; records the first default and clears `t_ok' as it walks
      ;; (`keymap.c:411-414'), so a nearer map's default beats a
      ;; farther one's, and any specific binding anywhere in the chain
      ;; beats them all - which the caller has already tested.
      ;;--------------------------------------------------------------
      (let loop ((map keymap))
        (cond ((not (keymap-type? map)) #f)
              ((%keymap-t-default map))
              (else (let ((parent (keymap-parent map)))
                      (and parent (loop parent)))))))

    (define (%keymap-event-binding keymap event accept-default)
      ;; One event's binding in KEYMAP with the C's ACCEPT-DEFAULT rule.
      ;; A specific binding wins - and the `(t . DEF)' entry is the
      ;; *specific* binding when the event asked for IS `t'; accept-default
      ;; is what lets a lookup of some *other* event fall back to it
      ;; (`access_keymap_1''s `(EQ (key, idx))' before its `(t_ok && EQ
      ;; (key, Qt))').
      ;;--------------------------------------------------------------
      (cond
       ((not (keymap-type? keymap)) #f)
       ((access-keymap keymap event))
       (accept-default (%keymap-t-default-chain keymap))
       (else #f)))

    (define (%maps-event-binding maps event accept-default)
      ;; The binding of EVENT in a *list of keymaps* (Emacs's "KEYMAP can
      ;; also be a list of keymaps"). **This is `access-keymap`'s own
      ;; list walk** - `access_keymap_1`'s loop over the list - and the
      ;; reason it must be that one and not a first-match search: when
      ;; the event is a *prefix* in more than one map the C accumulates
      ;; them into `(keymap PREFIX...)` and the rest of the sequence is
      ;; looked up in all of them (`keymap.c:416-420`). A buffer whose
      ;; mode map adds `[menu-bar MODE]` therefore still finds the
      ;; global `[menu-bar file]`; the first-match version stopped at
      ;; the mode's `menu-bar` prefix and answered nil, which is why F10
      ;; did nothing in a C buffer.
      ;;
      ;; The `(t . DEF)' default is the fallback when nothing specific is
      ;; found, and the *earliest* map's default wins - the C's `t_ok =
      ;; 0' after the first one found.
      ;;--------------------------------------------------------------
      (or (access-keymap maps event)
          (and accept-default
               (let default ((rest maps))
                 (cond ((null? rest) #f)
                       ((not (keymap-type? (car rest)))
                        (default (cdr rest)))
                       ((%keymap-t-default-chain (car rest)))
                       (else (default (cdr rest))))))))

    (define (lookup-key keymap key . rest)
      ;; GNU Emacs's `lookup-key' (`keymap.c:1264'): "Look up key
      ;; sequence KEY in KEYMAP.  Return the definition. ... A number as
      ;; value means KEY is \"too long\"; that is, characters or symbols in
      ;; it except for the last one fail to be a valid sequence of prefix
      ;; characters in KEYMAP.  The number is how many characters at the
      ;; front of KEY it takes to reach a non-prefix key.  KEYMAP can also
      ;; be a list of keymaps.
      ;;
      ;; Normally, `lookup-key' ignores bindings for t, which act as
      ;; default bindings, used when nothing else in the keymap applies
      ;; ... However, if the third optional argument ACCEPT-DEFAULT is
      ;; non-nil, `lookup-key' will recognize the default bindings, just
      ;; as `read-key-sequence' does."
      ;;
      ;; This is `lookup_key_1''s walk (`keymap.c:1210'); the C's
      ;; `possibly_translate_key_sequence' and the menu-bar case-folding
      ;; compatibility below the DEFUN are not carried.
      ;;--------------------------------------------------------------
      (let ((accept-default (and (pair? rest) (car rest))))
        (let ((events (keymap-index key)))
          (cond
           ;; `if (length == 0) return keymap;'
           ((not events) keymap)
           (else
            (let loop ((rest events) (map keymap) (n 0))
              (let* ((event (car rest))
                     (cmd (cond ((keymap-type? map)
                                 (%keymap-event-binding map event accept-default))
                                ((pair? map)
                                 (%maps-event-binding map event accept-default))
                                (else #f))))
                (cond
                 ;; `if (idx == length) return cmd;'
                 ((null? (cdr rest)) cmd)
                 ;; `keymap = get_keymap (cmd, 0, 1); if (!CONSP (keymap))
                 ;; return make_fixnum (idx);' - and `get_keymap' takes a
                 ;; keymap *list* too, which is what `access-keymap' can
                 ;; answer when the key is a prefix in two maps.
                 ((not (keymapp cmd)) (+ n 1))
                 (else (loop (cdr rest) cmd (+ n 1)))))))))))

    (define (keymap-lookup keymap key)
      ;; GNU Emacs's `Flookup_key' (`keymap.c:1264'): "Look up the
      ;; definition of KEY in KEYMAP... If KEY is a prefix, return the
      ;; keymap it leads to." KEY may be written in any spelling
      ;; `keymap-index' reads, which here includes a whole sequence.
      ;;
      ;; The walk is `access_keymap_1''s: KEYMAP's own bindings, its
      ;; char-table, then its *parent* - which `access-keymap' asks when
      ;; NOINHERIT is not set, the way `Flookup_key' calls it - and the
      ;; keymap (or keymap list) a step answers with is where the next
      ;; event is looked up.
      ;;--------------------------------------------------------------
      (let ((events (keymap-index key)))
        (cond
         ((not keymap) #f)
         ((not events) keymap)
         (else
          (let loop ((rest events) (map keymap))
            (cond
             ((not map) #f)
             ((null? rest) map)
             (else
              (let ((cmd (access-keymap map (car rest))))
                (cond
                 ((keymapp cmd) (loop (cdr rest) cmd))
                 ;; **A command before the end of the sequence.** The C
                 ;; answers `idx' - "key is too long" (`Flookup_key',
                 ;; `keymap.c:1289') - and this answers the command
                 ;; instead. It is reachable only for a key sequence
                 ;; longer than its binding, and the one caller that
                 ;; cares, `%shadow-lookup' in keyboard.scm, is written
                 ;; around it; `lookup-key' has the C's answer. Named as
                 ;; a departure in DEPARTURES.md.
                 (cmd cmd)
                 (else #f))))))))))

    (define (define-as-prefix keymap event)
      ;; GNU Emacs's `define_as_prefix' (`keymap.c:1445'): "Make KEYMAP
      ;; define event C as a keymap (i.e., as a prefix). Assume that
      ;; currently it does not define C at all. Return the keymap."
      ;;--------------------------------------------------------------
      (let ((cmd (make-sparse-keymap)))
        (store-in-keymap keymap event cmd)
        cmd))

    (define *current-keymap* (make-parameter #f))
    ;; ^ The keymap the command loop looks in: GNU Emacs's current local
    ;; map. A minibuffer `parameterize`s it to its own, and so would any
    ;; other mode that wants its own bindings; when it is false the global
    ;; map is used.

    (define *default-keymap* (keymap '*default-keymap*))
    (define *special-event-map* (keymap '*special-event-map*))

    (define (current-global-map)
      ;; GNU Emacs's `current-global-map' (`keymap.c:1921'): "Return the
      ;; current global keymap." The C's `current_global_map` is the
      ;; `global-map' variable, which this tree holds as
      ;; `*default-keymap*'.
      ;;--------------------------------------------------------------
      *default-keymap*)

    (define (define-key keymap keys command)
      ;; Bind KEYS to COMMAND in KEYMAP: GNU Emacs's `define-key'.
      ;;
      ;; KEYS is a *key sequence* - what `(kbd "C-x C-f")' answers with,
      ;; a vector of events, which is what Emacs's `define-key' takes
      ;; ("a string or a vector of symbols and characters,
      ;; representing a sequence of keystrokes and events",
      ;; `keymap.c':1084'). The tree's own spelling, a list of modifier
      ;; symbols and characters, still converts too.
      ;;
      ;; **The walk is `Fdefine_key''s loop** (`keymap.c:1187-1206'): every
      ;; event but the last is looked up with `access_keymap (keymap, c,
      ;; 0, 1)' - the `1' is `noinherit', so a *parent's* binding does not
      ;; count, and `access-keymap' above is that half - a nil answer
      ;; becomes a fresh prefix (`define_as_prefix'), and an answer that is
      ;; not a keymap is refused by name:
      ;;
      ;;   error ("Key sequence %s starts with non-prefix key %s%s", ...)
      ;;
      ;; The last event is the one `store_in_keymap' takes. Emacs 31.1's
      ;; own answers, measured: `C-x' then `C-x f' signals "Key sequence
      ;; C-x f starts with non-prefix key C-x", three deep it names the
      ;; whole prefix, and a *parent's* `C-x' does not count - a child is
      ;; free to make its own.
      ;;--------------------------------------------------------------
      (let ((events (keymap-index keys)))
        (unless events
          (error "Empty key is invalid"))
        (let loop ((rest events) (map keymap) (seen '()))
          (cond
           ((null? (cdr rest))
            (store-in-keymap map (car rest) command))
           (else
            (let ((cmd (access-keymap map (car rest) #t)))
              (cond
               ((not cmd) (loop (cdr rest) (define-as-prefix map (car rest))
                                (cons (car rest) seen)))
               ((keymap-type? cmd)
                (loop (cdr rest) cmd (cons (car rest) seen)))
               (else
                (error (string-append
                        "Key sequence " (key-description events)
                        " starts with non-prefix key "
                        (key-description
                         (reverse (cons (car rest) seen)))))))))))
        command))

    ;; -------------------------------------------------------------------------------------------------

    (define (single-key-description key . rest)
      ;; GNU Emacs's `single-key-description' (`keymap.c:2307'): "Return a
      ;; pretty description of a character event KEY. Control characters
      ;; turn into C-whatever, etc."
      ;;
      ;; **KEY is an *event*** - an integer carrying its modifier bits, a
      ;; character (the same thing), or a symbol naming a key that is not
      ;; one - and this is the function the whole tree prints a key with:
      ;; the `; undefined key: ...' message and `key-description' below
      ;; both end here. It used to take a bare character and stop, which
      ;; is why the keymap had to print its keys itself, in a private
      ;; modifier-symbol spelling.
      ;;
      ;; Three of the C's four branches, in its order:
      ;;
      ;;   * a Lucid *event type list* - `(control ?x)' - is converted
      ;;     first (`lucid_event_type_list_p' then `event-convert-list',
      ;;     `:2319');
      ;;   * an integer goes to `push_key_description' (`:2192'), whose
      ;;     modifier-prefix order is **A- C- H- M- S- s-** and whose
      ;;     character part is what this function already had;
      ;;   * a symbol is its *name*, with `<...>' around the part after
      ;;     the modifier prefixes (`:2343'-`:2356') unless NO-ANGLES.
      ;;
      ;; Not ported: the interval case - a cons of two integers, which is
      ;; what a `map-char-table' produces and which nothing here builds.
      ;;--------------------------------------------------------------
      (let* ((no-angles (and (pair? rest) (car rest)))
             (key (if (and (pair? key) (pair? (cdr key)))
                      (event-convert-list key)
                      key)))
        (cond
         ((or (integer? key) (char? key))
          (push-key-description (if (char? key) (char->integer key) key)))
         ((symbol? key)
          (let ((name (symbol->string key)))
            (if no-angles
                name
                (let ((i (let loop ((i 0))
                           (if (and (< i (- (string-length name) 3))
                                    (char=? #\- (string-ref name (+ i 1)))
                                    (memv (string-ref name i)
                                          (list #\A #\C #\H #\M #\S #\s)))
                               (loop (+ i 2))
                               i))))
                  (string-append (substring name 0 i) "<"
                                 (substring name i (string-length name)) ">")))))
         ((string? key) key)
         (else (error "KEY must be an integer, cons, symbol, or string")))))

    (define (push-key-description ch)
      ;; GNU Emacs's `push_key_description' (`keymap.c:2192'): the
      ;; description of one character *event*, as `single-key-description'
      ;; answers it. The C's own shape is kept exactly - "Clear all the
      ;; meaningless bits above the meta bit", C is *decremented* as each
      ;; modifier prefix is emitted, and the character part is then read
      ;; off what remains. Reading it off the original event instead was
      ;; the first version here and it died in `integer->char' on a meta
      ;; event, which is the C's own reason for subtracting.
      ;;
      ;; The prefix order is the C's: **A- C- H- M- S- s-**. `C-' is
      ;; emitted when the control bit is set *or* when the character is
      ;; one of the controls that has no separate RET/TAB/ESC name.
      ;;--------------------------------------------------------------
      (let* ((raw (logand ch (logior char-meta (lognot (- char-meta)))))
             (c2 (logand raw (lognot (logior char-alt char-ctl char-hyper
                                             char-meta char-shift char-super))))
             (tab-as-ci (and (= c2 9) (not (zero? (logand raw char-meta)))))
             (c raw)
             (prefix ""))
        (when (not (zero? (logand c char-alt)))
          (set! prefix (string-append prefix "A-"))
          (set! c (- c char-alt)))
        (when (or (not (zero? (logand c char-ctl)))
                  (and (< c2 32) (not (= c2 27)) (not (= c2 9)) (not (= c2 13)))
                  tab-as-ci)
          (set! prefix (string-append prefix "C-"))
          (set! c (logand c (lognot char-ctl))))
        (when (not (zero? (logand c char-hyper)))
          (set! prefix (string-append prefix "H-"))
          (set! c (- c char-hyper)))
        (when (not (zero? (logand c char-meta)))
          (set! prefix (string-append prefix "M-"))
          (set! c (- c char-meta)))
        (when (not (zero? (logand c char-shift)))
          (set! prefix (string-append prefix "S-"))
          (set! c (- c char-shift)))
        (when (not (zero? (logand c char-super)))
          (set! prefix (string-append prefix "s-"))
          (set! c (- c char-super)))
        (string-append
         prefix
         (cond
          ((>= c #x110000) (string-append "[" (number->string c) "]"))
          ((< c 32)
           (cond
            ((= c 27) "ESC")
            (tab-as-ci "i")
            ((= c 9) "TAB")
            ((= c 13) "RET")
            (else (string (integer->char (if (and (> c 0) (<= c 26))
                                             (+ c 96) (+ c 64)))))))
          ((= c 127) "DEL")
          ((= c 32) "SPC")
          (else (string (integer->char c)))))))

    (define (key-description keys . rest)
      ;; GNU Emacs's `key-description' (`keymap.c:2092'): "Return a pretty
      ;; description of key-sequence KEYS. For example, `[?\\C-x ?l]' is
      ;; converted into the string \"C-x l\"."
      ;;
      ;; KEYS is what a key *is* - a string or a vector of events - and
      ;; the C's answer is `(mapconcat #'single-key-description keys "
      ;; ")' with one extra rule: an ESC in the sequence is not an event
      ;; but the *meta prefix* for the next one (`meta_prefix_char'), so
      ;; `[27 108]' is "M-l" and not "ESC l". Two ESCs in a row are
      ;; "ESC ESC", because the second cannot prefix anything.
      ;;--------------------------------------------------------------
      (let* ((prefix (if (pair? rest) (car rest) '()))
             (events (append (if (vector? prefix)
                                 (vector->list prefix)
                                 (if (pair? prefix) prefix '()))
                             (cond ((vector? keys) (vector->list keys))
                                   ((string? keys) (vector->list (kbd keys)))
                                   ((pair? keys) keys)
                                   (else '())))))
        (let loop ((rest events) (acc '()) (add-meta #f))
          (if (null? rest)
              (string-join
               (map single-key-description
                    (reverse (if add-meta (cons 27 acc) acc)))
               " ")
              (let ((key (car rest)))
                (cond
                 ;; The previous event was an ESC, so this one is the key
                 ;; it prefixes. It can only take the prefix if it *is*
                 ;; an event integer and has no meta bit already; an ESC
                 ;; of its own is emitted as an ESC and the prefix is
                 ;; spent on nothing.
                 (add-meta
                  (if (or (not (integer? key))
                          (= key 27)
                          (not (zero? (logand key char-meta))))
                      (loop (cdr rest) (cons 27 acc) #f)
                      (loop (cdr rest) (cons (logior key char-meta) acc) #f)))
                 ((and (integer? key) (= key 27))
                  (loop (cdr rest) acc #t))
                 (else (loop (cdr rest) (cons key acc) #f))))))))
	))
