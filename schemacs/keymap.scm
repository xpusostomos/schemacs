(define-library (schemacs keymap)
  (import
    (scheme base)
    (scheme char)
    (scheme lazy)
    (scheme case-lambda)
    (only (schemacs lens)
          lens view update update&view lens-set
          unit-lens record-unit-lens
          =>self  =>hash-key*!  =>hash-key!
          =>canonical  =>head  =>encapsulate
          )
    (only (schemacs lens bin-hash-table) hash-table-copy-with)
    (only (schemacs editor command) command-type? command-procedure)
    ;; The event model, which is what a key *is*. `event-convert-list'
    ;; (`keyboard.c:7832') is the ONE place GNU Emacs consumes a modifier
    ;; *name* - the Lucid event type list `(control ?x)' - and `kbd'
    ;; (`character.sld:644') is `key-parse' (`keymap.el:235'), the reader
    ;; a key description string goes through.
    (only (schemacs editor character)
          event-convert-list kbd
          char-alt char-super char-hyper char-shift char-ctl char-meta)
    (only (srfi 1) filter)
    (only (guile) lognot logand logior)
    (only (schemacs comparator) make-eqv-comparator)
    (only (schemacs hash-table)
          hash-table-empty?
          alist->hash-table hash-table->alist
          hash-table? hash-table-size make-hash-table
          hash-table-fold hash-table-ref/default
          hash-table-copy hash-table-set!
          ))

  (cond-expand
    (guile-3
     (import
       ))
    (else)
    )

  (export
   alist->keymap-layer
   keymap-index
   keymap-index-append
   keymap-index->events
   reverse-list->keymap-index
   =>keymap-layer-index!
   keymap-index-to-char

   keymap-layer-type?
   keymap-layer
   keymap-layer->alist
   keymap-layer-assoc-split
   keymap-layer-copy
   keymap-layer-action
   map-key
   keymap-layer-lookup
   keymap-layer-lookup-binding-key
   keymap-layer-ref
   keymap-layer-update!
   prefer-new-bindings
   prefer-old-bindings

   make<keymap-index-predicate>
   keymap-index-predicate-type?
   new-self-insert-keymap-layer
   apply-keymap-index-predicate

   keymap-type?
   keymap-parent
   set-keymap-parent
   =>keymap-layers*!
   =>keymap-label!
   =>keymap-top-layer!
   keymap keymap-lookup
   ;; `keymap.c''s two choke points - the only functions that touch a
   ;; keymap in Emacs. Both take ONE EVENT; the key sequence is walked
   ;; one event at a time and a keymap value is a prefix.
   store-in-keymap access-keymap
   keymap->layers-list
   keymap-lookup-binding-key

   modal-lookup-state-type?
   new-modal-lookup-state
   modal-lookup-state-key-index
   modal-lookup-state-keymap
   modal-lookup-state-step!
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
    ;; So the record is gone and a key is a **list of events**. A
    ;; `<keymap-layer-type>''s keys are ONE EVENT each - what
    ;; `store_in_keymap' (`keymap.c:730') and `access_keymap'
    ;; (`keymap.c:491') are keyed by - and a *prefix* is a nested layer in
    ;; the binding, which is Emacs's submap.
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
      ;;
      ;; What stood here answered a `<keymap-index-type>' - a record whose
      ;; `modix'/'charix'/'nextix' split one event into a modifier *field*
      ;; and a character *field*, which is a second spelling of what the
      ;; event already says, and a lossy one: the split could not hold the
      ;; shift bit, so `(kbd "S-x")' and `S-<f10>' were stored as their
      ;; unshifted selves and could not be bound at all.
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
      ;;
      ;; It is `keymap-index' itself, because a key IS its events here.
      ;; The function this replaces rebuilt a `<keymap-index-type>' record
      ;; out of a folded reading of each event, which is why it and
      ;; `keymap-index' could disagree.
      ;;------------------------------------------------------------------
      (keymap-index key))

    (define (keymap-index-append . items)
      ;; Join key sequences, end to end. A #f item is nothing and is
      ;; skipped, which is what a caller that may or may not have a key
      ;; finds easiest to hand it.
      ;;------------------------------------------------------------------
      (apply append
             (map keymap-index
                  (filter (lambda (item) item) items))))

    (define (reverse-list->keymap-index nodes)
      ;; Join a *reversed* list of key sequences - the shape the modal
      ;; lookup state keeps its stack in.
      ;;------------------------------------------------------------------
      (if (null? nodes)
          #f
          (apply keymap-index-append (reverse nodes))))

    (define (keymap-index-to-char keyix allow-ctrl on-success on-fail)
      ;; The *character* the key KEYIX names, if it names one:
      ;; `ON-SUCCESS' is applied to it and `ON-FAIL' is applied when it
      ;; does not.
      ;;
      ;; This is the test the catch-all `self-insert' layer is reached by,
      ;; and it is the test Emacs's *keymap* makes by making the binding:
      ;; the range `(cons 128 (max-char))' that
      ;; `international/mule-conf.el:1671' puts on `global-map', and the
      ;; 32..126 `subr.el:1763' fills in a loop. **A range entry in a char
      ;; table is the one thing this tree's keymap cannot hold** - a layer
      ;; here is an event-to-binding table - so the range is kept as the
      ;; *predicate for* an event, which is what makes it a layer.
      ;;
      ;; A *named* key is not one, and without the test every unbound
      ;; named key (`<f13>', `<prior>', `<insert>') reached
      ;; `self-insert-command', which inserted the key's *name* as text -
      ;; and in a read-only buffer said "Buffer is read-only" and
      ;; otherwise did nothing, which is how PgUp and PgDn were lost in
      ;; Dired.
      ;;
      ;; ALLOW-CTRL admits a control character too: whether a control code
      ;; counts as a character is the whole of what its name says.
      ;;
      ;; KEYIX is a key, in any spelling `keymap-index' reads; what is
      ;; walked here is the *events* of it. A key of more than one event
      ;; is a prefix and is not a character.
      ;;------------------------------------------------------------------
      (let* ((events (or (keymap-index keyix) '()))
             ;; The one event, when the key is exactly one - a key of more
             ;; than one event is a prefix and is not a character.
             (event (and (pair? events) (null? (cdr events)) (car events))))
        (cond
         ((not event) (on-fail))
         ;; A named key is not self-inserting.
         ((not (integer? event)) (on-fail))
         ;; Every modifier but control means it is not a plain character.
         ((not (zero? (logand event (logior char-alt char-super char-hyper
                                            char-shift char-meta))))
          (on-fail))
         ((or (< event 32) (not (zero? (logand event char-ctl))))
          (if allow-ctrl (on-success (integer->char event)) (on-fail)))
         ((= event 127) (on-fail))      ; DEL is not self-inserting
         (else (on-success (integer->char event))))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-layer-type>
      (%make<keymap-layer> event-table alt-action)
      keymap-layer-type?
      (event-table keymap-layer-event-table %set!keymap-layer-event-table)
        ;; ^ a hash table - an ordinary `<hash-table-type>', keyed by ONE
        ;; *event* (an integer carrying its modifier bits, or a symbol) -
        ;; containing the bindings of this layer. A value that is itself a
        ;; `<keymap-layer-type>' is a *prefix*, which is Emacs's submap: the
        ;; next event is looked up in it.
        ;;
        ;; It used to be TWO tables - a hash of modifier bits to a
        ;; `<char-table-type>', and that char-table keyed by a character -
        ;; which is the `<keymap-index-type>''s split of one event into two
        ;; fields, made into storage. The event already holds both halves,
        ;; so there is one table and one key.
      (alt-action keymap-layer-alt-action set!keymap-layer-alt-action)
        ;; ^ it is possible to merge keymap-layer tables such that mappings to
        ;; that terminate at the end of one key string (such as "C-c C-c")
        ;; is not a terminal string in the merged mapping (such as when
        ;; merging with "C-c C-c x"). This field keeps the action mapped
        ;; to the shorter string (e.g. "C-c C-c") available should the
        ;; longer string (e.g. "C-c C-c x") be deleted from the table.
      )

    (define (make<keymap-layer> event-table alt-action)
      (%make<keymap-layer>
       (cond
        ((not event-table) #f)
        ((hash-table? event-table) event-table)
        (else (error "not a <hash-table-type>" event-table)))
       alt-action))

    (define (set!keymap-layer-event-table kml event-table)
      (%set!keymap-layer-event-table kml
       (cond
        ((not event-table) #f)
        ((hash-table? event-table) event-table)
        (else (error "not a <hash-table-type>" event-table))
        )))

    (define (keymap-layer-empty? km)
      (or (not km)
          (let ((ht (keymap-layer-event-table km)))
            (and
             (not (keymap-layer-alt-action km))
             (or (not ht) (hash-table-empty? ht))))))

    (define (keymap-layer . assocs) (alist->keymap-layer assocs))

    (define (keymap-layer-action node)
      ;; This procedure checks if the given `LAYER` contains a value in
      ;; `KEYMAP-LAYER-ALT-ACTION` while also checking to make sure that
      ;; the `KEYMAP-LAYER-EVENT-TABLE` is empty. If the action is defined
      ;; and the table is empty, the action is returned. If the table is
      ;; not empty, the table is always returned regardless of whether the
      ;; action is defined. If the table is empty and there is no action,
      ;; #f is returned.
      (let*((alt (keymap-layer-alt-action node))
            (events (keymap-layer-event-table node))
            (empty (or (not events) (hash-table-empty? events)))
            )
        (cond
         ((and empty (not alt)) #f)
         ((and empty alt) alt)
         (else node)
         )))

    (define (alist->keymap-layer assocs)
      ;; Construct a new empty keymap-layer from an association list of
      ;; *keys* - each a key sequence, as `keymap-index' reads one - paired
      ;; with the binding looked up by it. The ALT-ACTION, which is an
      ;; action that may (or may not) be used if a lookup fails, should be
      ;; assigned to the null key, so the association pair
      ;; `('() . some-procedure)` will assign "some-procedure" to the
      ;; `KEYMAP-LAYER-ALT-ACTION` field of the constructed
      ;; `<KEYMAP-LAYER-TYPE>` value.
      ;; ------------------------------------------------------------------
      (keymap-layer-update! (lambda (_old new) new) (make<keymap-layer> #f #f) assocs)
      )

    (define keymap-layer-copy
      ;; Deep-copy the given key map object `KM`. If the object `KM` does
      ;; not satisfy the `KEYMAP-LAYER-TYPE?` predicate it is returned
      ;; as-is.  If two arguments are applied to this procedure, the
      ;; second must be a procedure that deep-copies the
      ;; `KEYMAP-LAYER-ALT-ACTION` fields as well.
      ;; ------------------------------------------------------------------
      (case-lambda
        ((km) (keymap-layer-copy km (lambda (id) id)))
        ((km alt-copy)
         (cond
          ((keymap-layer-type? km)
           (make<keymap-layer>
            (hash-table-copy-with
             (keymap-layer-event-table km)
             (lambda (binding) (keymap-layer-copy binding alt-copy)))
            (alt-copy (keymap-layer-alt-action km))
            ))
          (else km)
          ))))

    (define =>keymap-layer-event-table
      (record-unit-lens keymap-layer-event-table set!keymap-layer-event-table '=>keymap-layer-event-table)
      )

    (define =>keymap-layer-event-table?
      (=>canonical =>keymap-layer-event-table keymap-layer keymap-layer-empty?)
      )

    (define =>keymap-layer-alt-action
      (record-unit-lens keymap-layer-alt-action set!keymap-layer-alt-action '=>keymap-layer-alt-action)
      )

    (define =>keymap-layer-alt-action?
      (=>canonical =>keymap-layer-alt-action keymap-layer keymap-layer-empty?))

    (define (default-make-keymap-layer-event-table)
      ;; The hash table a layer's bindings live in. An `eqv?' comparator
      ;; is the right one for both kinds of key an event can be: an
      ;; integer (`eqv?' on numbers is `=') and a symbol.
      ;;------------------------------------------------------------------
      (make-hash-table (make-eqv-comparator))
      )

    ;; `*keymap-layer-num-char-tables*' stood here: the count of modifier
    ;; combinations a layer's tables were split by. There is one table
    ;; now, so there is nothing to count.

    (define (map-key syms proc)
      ;; Construct an association between a *key* and a binding. A list of
      ;; these values is used to initialize or update a `<KEYMAP-LAYER>`.
      ;;
      ;; The `PROC` argument may be a procedure, or it may be another
      ;; `KEYMAP-LAYER`.
      (cons (keymap-index syms) proc)
      )

    (define (=>event-table-event! event)
      ;; A lens that accesses the binding of ONE EVENT in a layer's event
      ;; table. It is the whole of what used to be two lens groups - one
      ;; through the modifier-bit table and one through its char-table -
      ;; because an event is one key.
      ;;------------------------------------------------------------------
      (=>canonical
       (=>hash-key*! event)
       default-make-keymap-layer-event-table
       hash-table-empty?))

    (define (=>keymap-layer-index! key)
      ;; Construct a lens to access a `<KEYMAP-LAYER-TYPE>` by the given
      ;; KEY - a key sequence in any spelling `keymap-index' reads, so a
      ;; `kbd' description string, an event vector, a list of events, or a
      ;; single event.
      ;;
      ;; It is the C's `access_keymap_1' walk (`keymap.c:327') told as a
      ;; lens: one event per step, and the value at a step is either the
      ;; binding or - when it is itself a layer - the submap the next
      ;; event is looked up in.
      ;;------------------------------------------------------------------
      (let ((events (keymap-index key)))
        (if (not events)
            =>self
            (=>canonical
             (apply lens
                    (map (lambda (event)
                           (lens =>keymap-layer-event-table?
                                 (=>event-table-event! event)))
                         events))
             keymap-layer
             keymap-layer-empty?))))

    (define (prefer-new-bindings old new)
      ;; Use this as the first argument to the KEYMAP-LAYER-MERGE-ACTIONS
      ;; function, that is if you would like key new bindings that
      ;; conflict with old bindings to simply overwrite the old bindings
      ;; when two keymap-layers are merged
      ;;------------------------------------------------------------------
      new)

    (define (prefer-old-bindings old new)
      ;; Use this as the first argument to the KEYMAP-LAYER-MERGE-ACTIONS
      ;; function, that is if you would like key old bindings that
      ;; conflict with new bindings to simply overwrite the old bindings
      ;; when two keymap-layers are merged.
      ;;------------------------------------------------------------------
      old)

    (define (keymap-layer-merge-actions merge-actions km new-action)
      ;; This function evaluates a function MERGE-ACTIONS with two
      ;; arguments: the old value in the KEYMAP-LAYER-ALT-ACTION field of
      ;; the KM argument, and the NEW-ACTION argument given to this
      ;; functino. If the KM argument is not a <KEYMAP-LAYER-TYPE>, a new
      ;; keymap-layer is constructed and the KEYMAP-LAYER-ALT-ACTION of
      ;; this new structure is set to the result of calling MERGE-ACTIONS
      ;; with #f and the NEW-ACTION argument passed to this function.
      ;;------------------------------------------------------------------
      (cond
       ((keymap-layer-type? km)
        (let ((km (update
                   (lambda (old-action)
                     (values (merge-actions old-action new-action) #f))
                   km =>keymap-layer-alt-action?)))
          km))
       (else
        (keymap-layer (cons '() (merge-actions #f new-action))))))

    (define (keymap-layer-update! merge-actions km alist)
      ;; Updates an existing <KEYMAP-LAYER> with an association
      ;; list. Provide a procedure MERGE-ACTIONS to combine an existing
      ;; action with a new action in the case the same key is set twice.
      ;;
      ;; The MERGE-ACTIONS function must take 2 arguments, an OLD-ACTION
      ;; and a NEW-ACTION. The OLD-ACTION may satisfy either the
      ;; PROCEDURE? predicate or the `keymap-layer-type?` predicate. The
      ;; NEW-ACTION will only ever satisfy the PROCEDURE? predicate due to
      ;; the requirements on how ASSOCS are defined.
      ;;
      ;; The MAP-KEY-ALIST argument should be an association list of cons
      ;; cells constructed by the MAP-KEY function.
      ;;------------------------------------------------------------------
      (let loop ((alist alist) (km km))
        (if (null? alist) km
            (let*((assoc  (car alist))
                  (key    (car assoc))
                  (=>key? (=>keymap-layer-index! key)))
              (loop
               (cdr alist)
               (let ((km
                      (update
                       (lambda (km)
                         (values
                          (keymap-layer-merge-actions merge-actions km (cdr assoc))
                          #f))
                       km =>key?)))
                 km))))))

    (define (keymap-layer->alist km)
      ;; Every binding of a layer, as a list of `(KEY . BINDING)`
      ;; associations whose KEY is a *list of events*. A prefix is
      ;; flattened into one association per key under it, so a layer that
      ;; binds `C-c C-c' has an entry whose key is `(3 3)' and not one
      ;; whose key is `C-c'.
      ;;
      ;; **A layer may carry an action of its own** - the `alt-action',
      ;; which is the binding for the key that *reached* the layer, and
      ;; which `alist->keymap-layer' writes as the association
      ;; `('() . action)'. An ordinary leaf binding is stored that way, in
      ;; a layer of its own with no table: that is what
      ;; `keymap-layer-merge-actions' builds, and `keymap-layer-action'
      ;; reads it back. Its entry is written with key **#f**, because
      ;; there is no further event to name - the *parent* supplies the
      ;; event, and the recursion below is where that happens. Reading it
      ;; as one more event spelled `#f' gave every binding a second,
      ;; nonexistent key: `C-M-x' came out as `(134217752 . #f)'.
      ;;--------------------------------------------------------------
      (let*((events (keymap-layer-event-table km))
            (alt  (keymap-layer-alt-action km))
            (ht
             (if (not events)
                 '()
                 (apply append
                        (map
                         (lambda (pair)
                           (let ((event (car pair)) (binding (cdr pair)))
                             (cond
                              ((keymap-layer-type? binding)
                               (map
                                (lambda (sub)
                                  (let ((rest (car sub)))
                                    (cons (if rest (cons event rest) (list event))
                                          (cdr sub))))
                                (keymap-layer->alist binding)))
                              (else (list (cons (list event) binding))))))
                         (hash-table->alist events))))))
        (if alt (cons (cons #f alt) ht) ht)))

    (define (keymap-layer-assoc-split assoc)
      ;; Split an association from a key to a binding. The association
      ;; must be an element from the list produced by
      ;; `keymap-layer->alist`. Returns two values, the key and the
      ;; binding.
      ;;--------------------------------------------------------------
      (cond
       ((null? assoc) (error "not a key->binding association" assoc))
       (else (values (car assoc) (cdr assoc)))))

    (define (keymap-layer-lookup-binding-key layer binding)
      ;; Used by the `[rebind binding]` syntax of `define-key`, looks
      ;; up a key sequence for a given `binding` in the given
      ;; `keymap`.  It is sort-of like a reverse lookup, finding a key
      ;; for a binding in a keymap.
      ;;--------------------------------------------------------------
      (let loop ((assocs (keymap-layer->alist layer)))
        (cond
         ((null? assocs) #f)
         (else
          (let*-values
              (((assoc) (car assocs))
               ((key candidate) (keymap-layer-assoc-split assoc))
               )
            (cond
             ((eq? binding candidate) key)
             (else (loop (cdr assocs)))
             ))))))

    (define (keymap-lookup-binding-key keymap binding)
      (let loop ((layers (keymap->layers-list keymap)))
        (cond
         ((null? layers) #f)
         (else
          (let ((result (keymap-layer-lookup-binding-key (car layers) binding)))
            (or result (loop (cdr layers)))
            )))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-index-predicate-type>
      ;; This is a procedure that can return a value for any key. It is
      ;; used to implement keymaps where the majority of keys all return
      ;; the same value, such as the self-insert-map, among others.
      (make<keymap-index-predicate> proc)
      keymap-index-predicate-type?
      (proc  keymap-index-predicate))

    (define (apply-keymap-index-predicate pred key)
      ;; Apply the predicate PRED to the *key* KEY, which may be written
      ;; in any spelling `keymap-index' reads. The predicate itself is
      ;; applied to the normalised list of events, so it never has to ask
      ;; which spelling it was handed.
      ;;------------------------------------------------------------------
      (cond
       ((not (keymap-index-predicate-type? pred))
        (error "not a <keymap-index-predicate-type>" pred))
       (else
        ((keymap-index-predicate pred) (keymap-index key))))
      )


    (define (new-self-insert-keymap-layer allow-ctrl on-success on-fail)
      ;; The layer that makes a *character* key self-insert when nothing
      ;; above it matched - the tree's spelling of Emacs's two range
      ;; bindings, `subr.el:1763''s loop over 32..126 and
      ;; `international/mule-conf.el:1671''s `(cons 128 (max-char))' on
      ;; `global-map'. `ON-SUCCESS' is applied to a character that
      ;; qualifies, `ON-FAIL' to no arguments when one does not; ALLOW-CTRL
      ;; admits a control code as well. See `keymap-index-to-char' above
      ;; for why this is a predicate rather than a table.
      ;;--------------------------------------------------------------
      (make<keymap-index-predicate>
       (lambda (keyix) (keymap-index-to-char keyix allow-ctrl on-success on-fail))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-type>
      ;; A list of keymap layers, and a *parent* keymap. When looking-up
      ;; a key, all layers are checked, the element nearest the bottom of
      ;; the list (nearer to `car` than to `cdr`) is returned; and when no
      ;; layer has anything for the key, the lookup goes on to the parent,
      ;; and to its parent, and so on. Keymap operations like `KEYMAP-PUSH`
      ;; treat `<KEYMAP-TYPE>`s as immutable and always return newly
      ;; constructed `<KEYMAP-TYPE>` values.
      ;;
      ;; The parent is GNU Emacs's (`keymap.c`): a keymap's bindings are
      ;; those of its own tables plus, for every key they leave
      ;; unbound, its parent's. It is a *link* and not a copy - the
      ;; parent is read when the lookup happens, so a binding made in
      ;; the parent afterwards is still reached. `set-keymap-parent` and
      ;; `keymap-parent` below are the C's functions over it; the field
      ;; accessors are spelled with a `%' so that the pair the C calls
      ;; `keymap-parent' and `set-keymap-parent' can be written on top.
      ;;------------------------------------------------------------------
      (make<keymap> layers label parent)
      keymap-type?
      (layers  keymap->layers-list  set!keymap-layers)
      (label   keymap-label         set!keymap-label)
      (parent  keymap-parent        %set-keymap-parent!)
      )


    (define =>keymap-layers*!
      (record-unit-lens
       keymap->layers-list
       set!keymap-layers
       '=>keymap-layers*!))


    (define (keymap . layers)
      ;; Construct a `<KEYMAP-TYPE>`. If the first argument is a string or
      ;; symbol, it is used as the label for this keymap.
      ;;------------------------------------------------------------------
      (define (to-list layer)
        (cond
         ((not layer) '())
         ((keymap-layer-type? layer) (list layer))
         ((keymap-type? layer) (keymap->layers-list layer))
         ((keymap-index-predicate-type? layer) (list layer))
         (else (error "not a <keymap-type> or <keymap-layer-type>" layer))
         ))
      (cond
       ((null? layers) (make<keymap> '() #f #f))
       ((or (string? (car layers)) (symbol? (car layers)))
        (make<keymap> (apply append (map to-list (cdr layers))) (car layers) #f))
       (else
        (make<keymap> (apply append (map to-list layers)) #f #f))))


    (define (keymap-memberp map maps)
      ;; GNU Emacs's `keymap_memberp' (keymap.c:263): "Check whether MAP
      ;; is one of MAPS's parents" - the walk `set-keymap-parent' uses
      ;; to refuse an inheritance that would be a cycle.
      ;;--------------------------------------------------------------
      (if (not map)
          #f
          (let loop ((maps maps))
            (cond ((not (keymap-type? maps)) #f)
                  ((eq? map maps) #t)
                  (else (loop (keymap-parent maps)))))))

    (define (set-keymap-parent keymap parent)
      ;; GNU Emacs's `set-keymap-parent' (keymap.c:273): "Modify KEYMAP
      ;; to set its parent map to PARENT. Return PARENT. PARENT should be
      ;; nil or another keymap."
      ;;
      ;; The C's cycle check is `keymap_memberp': a keymap may not become
      ;; its own ancestor, or the lookup would never end.
      ;;--------------------------------------------------------------
      (unless (or (not parent) (keymap-type? parent))
        (error "not a keymap" parent))
      (when (and parent (keymap-memberp keymap parent))
        (error "Cyclic keymap inheritance"))
      (%set-keymap-parent! keymap parent)
      parent)

    (define =>keymap-label!
      (record-unit-lens keymap-label set!keymap-label '=>keymap-label!))


    (define (keymap-layer-ref km key)
      ;; This is similar to `KEYMAP-LAYER-LOOKUP` except it always returns
      ;; a `KEYMAP-LAYER` node (or #f), rather than returning the
      ;; `KEYMAP-LAYER-ALT-ACTION` (if any).
      (cond
       ((keymap-layer-type? km)
        (view km (=>keymap-layer-index! key)))
       ((keymap-index-predicate-type? km)
        (apply-keymap-index-predicate km key))
       (else (error "not a <keymap-layer-type> or <keymap-index-predicate-type>" km))
       ))


    (define =>keymap-top-layer!
      ;; A lens that focuses on the top-most layer of a
      ;; `<KEYMAP-TYPE>`. This lens is canonical, so if the keymap has no
      ;; layers, a new layer is created. If the top layer is empty, it is
      ;; removed.
      (=>encapsulate
       (lens
        =>keymap-layers*! =>head
        (=>canonical =>self keymap-layer keymap-layer-empty?)
        )
       '=>keymap-top-layer!
       ))


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
    ;; same conversion in `keymap-event' above, so the two functions below
    ;; are the *only* thing that was missing.
    ;;
    ;; A value that is itself a keymap is a *prefix*: `access_keymap_1'
    ;; recurses into it, and a sequence is walked one event at a time.
    ;; The tree expresses a prefix as a nested `<keymap-layer-type>` value.
    ;;------------------------------------------------------------------

    (define (store-in-keymap keymap event def)
      ;; GNU Emacs's `store_in_keymap' (`keymap.c:730'): "Scan the keymap
      ;; for a binding of IDX" and set it. The tree's layers are what
      ;; Emacs spells as several maps with a parent between them, so the
      ;; binding goes into the top layer - the one a lookup tries first,
      ;; which is what makes a later definition shadow an earlier one.
      ;;
      ;; The C's two errors are kept: `keymap' is reserved for an
      ;; embedded parent map, and a non-keymap is refused outright.
      ;;--------------------------------------------------------------
      (when (eq? event 'keymap)
        (error "`keymap' is reserved for embedded parent maps"))
      (unless (or (integer? event) (symbol? event) (char? event))
        (error "store-in-keymap: not an event" event))
      (update (lambda (layer)
                (values
                 (keymap-layer-update!
                  prefer-new-bindings layer
                  (list (cons (keymap-index event) def)))
                 #f))
              keymap =>keymap-top-layer!)
      def)

    (define (access-keymap keymap event)
      ;; GNU Emacs's `access_keymap' (`keymap.c:491'): the binding of one
      ;; EVENT in KEYMAP, or #f. A *keymap* answer means the event is a
      ;; prefix; the caller reads the next event and calls this again on
      ;; it, which is `Flookup_key''s walk (`keymap.c:1264').
      ;;
      ;; The parent walk inside `keymap-lookup' is
      ;; `access_keymap_1''s inheritance arm (`:399'-`:416'), so this is
      ;; one event of that walk with the layers and the parents both
      ;; still honoured.
      ;;--------------------------------------------------------------
      (unless (or (integer? event) (symbol? event) (char? event))
        (error "access-keymap: not an event" event))
      (keymap-lookup keymap (keymap-index event)))

    (define (keymap-layer-lookup km key)
      ;; Determine if a procedure has been mapped to `KM`, which may be a
      ;; `<KEYMAP-LAYER-TYPE>` in which the KEY is indexed, or a
      ;; `<KEYMAP-INDEX-PREDICATE-TYPE>` to which the KEY is applied. If
      ;; the KEY leads to another non-empty layer or predicate value, that
      ;; value is returned. But if the layer found contains a
      ;; `KEYMAP-LAYER-ALT-ACTION` and nothing else (the
      ;; `KEYMAP-LAYER-EVENT-TABLE` is empty) the alt-action is returned.
      (cond
       ((keymap-layer-type? km)
        (view km (=>keymap-layer-index! key) =>keymap-layer-alt-action?))
       ((keymap-index-predicate-type? km)
        (apply-keymap-index-predicate km key))
       (else (error "not a <keymap-layer-type> or <keymap-index-predicate-type>" km))
       ))


    (define (keymap-lookup km key)
      ;; This procedure performs a lookup in a `<KEYMAP-TYPE>` argument
      ;; `KM` with a key `KEY`, which may be written in any spelling
      ;; `keymap-index' reads. All layers in the keymap are searched in
      ;; order. The first time a lookup in a `<KEYMAP-LAYER-TYPE>` or
      ;; `<KEYMAP-INDEX-PREDICATE-TYPE>` results in a value that is not
      ;; another layer or predicate will cause this procedure to
      ;; immediately return that value. Otherwise, a new <KEYMAP-TYPE> is
      ;; returned containing only layers and predicates that could be
      ;; resolved by the key. If all results are "#f", then "#f" is
      ;; returned.
      (let ((kmix (keymap-index key)))
        (cond
         ((not km) #f)
         ((not kmix) km)
         (else
          (letrec*
              ((found
                (call/cc
                 (lambda (halt)
                   (let loop ((layers (keymap->layers-list km)))
                     (cond
                      ((null? layers) '())
                      (else
                       (let*((head (car layers))
                             (tail (cdr layers))
                             (layer (keymap-layer-ref head kmix))
                             )
                         (cond
                          ((not layer) (loop tail))
                          ((keymap-layer-type? layer)
                           (let ((action (keymap-layer-action layer)))
                             (cond
                              ((keymap-layer-type? action) (cons action (loop tail)))
                              ((keymap-type? action)
                               (error "keymap layer contains keymap" layer action))
                              ((not action) (loop tail))
                              (else (halt action))
                              )))
                          ((keymap-index-predicate-type? layer)
                           (error "keymap-layer-ref returned a <KEYMAP-INDEX-PREDICATE-TYPE>" layer))
                          (else (halt layer))
                          )))
                      )))
                 )))
            (cond
             ((not found) #f)
             ;; Nothing in this keymap's own layers had anything for the
             ;; key, so the parent is asked - and its parent, which is
             ;; what makes the chain work. A keymap that *did* have a
             ;; prefix binding here does not reach its parent for that key,
             ;; which is Emacs's rule too: the binding shadows.
             ((null? found)
              (let ((parent (keymap-parent km)))
                (and parent (keymap-lookup parent kmix))))
             ((pair? found) (make<keymap> found #f (keymap-parent km)))
             (else found)
             ))))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <modal-lookup-state-type>
      ;; This is the state object updated by MODAL-STATE-LOOKUP-STEP!
      ;; function which implements the modal state key lookup
      ;; mechanism. This record type contains 2 fields:
      ;;
      ;;  1. KEYMAP is the current keymap in which the key will
      ;;     lookup the next action or keymap
      ;;
      ;;  2. STACK is a reversed list of *events* that have been read
      ;;     so far, which is the key sequence in progress
      ;;------------------------------------------------------------------
      (make<modal-lookup-state-type> keymap stack)
      modal-lookup-state-type?
      (keymap  modal-lookup-state-keymap       set!modal-lookup-state-keymap)
      (stack   modal-lookup-state-index-stack  set!modal-lookup-state-index-stack))



    (define (new-modal-lookup-state km)
      ;; Construct a new <modal-lookup-state-type> with either a
      ;; <keymap-type> argument or a list of <keymap-type> arguments.
      ;;
      ;; A list is a *precedence order*: the first keymap that binds the
      ;; key wins, and one that does not falls through to the next. It is
      ;; what GNU Emacs's `read_key_sequence' does with the buffer's local
      ;; map and then `global-map', and what this library's docstring has
      ;; always promised - the list case was documented and not
      ;; implemented, so the callers that passed a list (the window frame
      ;; key dispatchers) got an error instead.
      ;;
      ;; The keymaps become the layers of one keymap, in order. That is
      ;; the same lookup - a keymap tries its layers in turn - and it has
      ;; the property a list of separate maps needs: a *prefix* in one map
      ;; does not stop a longer sequence being found in the next. With a
      ;; local map binding C-x as an empty prefix and a global map binding
      ;; C-x C-f, the lookup of C-x C-f is `find-file', which is what a
      ;; terminal Emacs answers to `(key-binding "\C-x\C-f")' for the same
      ;; two maps. A key bound in both is the first map's.
      ;;--------------------------------------------------------------
      (cond
       ((keymap-type? km)
        (make<modal-lookup-state-type> km '()))
       ((or (keymap-layer-type? km)
            (keymap-index-predicate-type? km))
        (make<modal-lookup-state-type> (keymap km) '()))
       ((and (list? km) (pair? km)
             (let all ((rest km))
               (cond ((null? rest) #t)
                     ((keymap-type? (car rest)) (all (cdr rest)))
                     (else #f))))
        (make<modal-lookup-state-type> (apply keymap '*keymaps* km) '()))
       ((null? km)
        (error "no keymap to look a key sequence up in"))
       (else
        (error "argument must be a <keymap-type> or a list of them" km))))

    (define (modal-lookup-state-key-index state)
      ;; The key sequence read so far - a *list of events*, which is what
      ;; GNU Emacs's `this-command-keys' answers with (a vector, there;
      ;; the same events).
      ;;--------------------------------------------------------------
      (reverse (modal-lookup-state-index-stack state)))

    (define (modal-lookup-state-lookup state event)
      ;; Looks-up one EVENT in the <modal-lookup-state-type> object's
      ;; current keymap.
      (keymap-lookup (modal-lookup-state-keymap state) (list event)))

    (define (modal-lookup-state-step! state event do-action do-wait-next do-fail-lookup)
      ;; In Emacs, key lookup is actually a modal operation. Each key
      ;; chord is an index that looks up a keymap node. If the index
      ;; lookup returns another keymap node that is empty but has an
      ;; action, the action is executed. If the keymap node has an action
      ;; but the map is not empty, it displays the key chords that have
      ;; been pressed so far in the echo area and then waits for another
      ;; key chord to be pressed. This function takes the following
      ;; arguments:
      ;;
      ;;  1. an object of record type <MODAL-LOOKUP-STATE-TYPE>
      ;;
      ;;  2. one *event* from a keyboard event that recently occurred,
      ;;     which is used to lookup the next action or keymap in the
      ;;     current keymap (the MODAL-LOOKUP-STATE-KEYMAP field) of the
      ;;     <MODAL-LOOKUP-STATE-TYPE> record. It is ONE event and not a
      ;;     chord, because that is what `read_key_sequence' reads at a
      ;;     time; the chord is accumulated in the state.
      ;;
      ;;  3. DO-ACTION is a procedure called when the key lookup
      ;;     retrieved an action and not a keymap.
      ;;
      ;;  4. DO-WAIT-NEXT is a procedure called when the key lookup
      ;;     retrieved a keymap and not an action.
      ;;
      ;;  5. DO-FAIL-LOOKUP is a procedure called when the key lookup
      ;;     finds neither an action or a keymap.
      ;;
      ;; This function should be called every time a keyboard event
      ;; occurs. On every call the STATE argument is updated and then one
      ;; of three "DO-" procedures is called depending on the state
      ;; transition:
      ;;
      ;;   - If an action procedure was found, evaluate the DO-ACTION
      ;;     procedure, which must take two arguments: 1. a *promise* of
      ;;     the key sequence that triggered it (must be forced in order to
      ;;     be used), and 2. the action to be evaluated. After evaluating
      ;;     DO-ACTION, return #f.
      ;;
      ;;   - If a non-empty keymap is found, evaluate the DO-WAIT-NEXT
      ;;     procedure with a promise of the current key sequence (must be
      ;;     forced in order to be used) and the next keymap being
      ;;     awaited.  After evaluating DO-WAIT-NEXT, return #t.
      ;;
      ;;   - If a completely empty keymap is found, evaluate the
      ;;     DO-FAIL-LOOKUP procedure with a single argument: the key
      ;;     sequence up to this point (not a "promise" object wrapping it,
      ;;     but the value itself). After evaluating DO-FAIL-LOOKUP, return
      ;;     #f.
      (let*((stack (cons event (modal-lookup-state-index-stack state)))
            (full-key (delay (reverse stack)))
            (action-or-map (modal-lookup-state-lookup state event))
            )
        (set!modal-lookup-state-index-stack state stack)
        (cond
         ((and action-or-map (not (keymap-type? action-or-map)))
          (set!modal-lookup-state-keymap state #f)
          (do-action full-key action-or-map)
          #f)
         ((keymap-type? action-or-map)
          (set!modal-lookup-state-keymap state action-or-map)
          (do-wait-next full-key action-or-map) #t)
         (else
          (set!modal-lookup-state-keymap state #f)
          (do-fail-lookup (force full-key)) #f))
        ))

    ;;----------------------------------------------------------------
    ))
