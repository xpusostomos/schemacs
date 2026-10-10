(define-library (schemacs editor keymap)
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
    (only (guile) string-join logand logior lognot)
    ;; The event model: the modifier bits `push-key-description' tests,
    ;; and `event-convert-list' for the Lucid form `single-key-description'
    ;; converts first. `kbd' is `read-kbd-macro''s own input, and the reader
    ;; `key-description' takes a *string* key through.
    (only (schemacs editor character)
          char-alt char-ctl char-hyper char-meta char-shift char-super
          event-convert-list kbd)
    ;; The bindings themselves. An `eqv?' comparator is the right one for
    ;; both kinds of key an event can be: an integer (`eqv?' on numbers is
    ;; `=') and a symbol.
    (only (schemacs comparator) make-eqv-comparator)
    (only (schemacs hash-table)
          make-hash-table hash-table?
          hash-table-ref/default hash-table-set! hash-table->alist
          )
    )

  (export
   ;; The key model - what a key *is*, and the one normalisation every
   ;; reader here takes its input through.
   keymap-index keymap-index->events

   ;; `keymap.c''s own names. `store-in-keymap' (`:730') and
   ;; `access-keymap' (`:491') are its two choke points - the only
   ;; functions in Emacs that touch a keymap - and both are keyed by ONE
   ;; *event*.
   keymap make-sparse-keymap keymap-type? keymap-lookup
   define-key
   store-in-keymap access-keymap
   keymap-parent set-keymap-parent
   keymap-char-table set-keymap-char-table!
   self-insert-char-table
   keymap-bindings
   keymap-lookup-binding-key

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
      (make<keymap> bindings char-table parent label)
      keymap-type?
      (bindings  keymap-bindings  %set!keymap-bindings!)
      (char-table keymap-char-table %set!keymap-char-table!)
      (parent    keymap-parent    %set-keymap-parent!)
      (label     keymap-label     set!keymap-label))

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
       ((null? rest) (make<keymap> (make-hash-table (make-eqv-comparator)) #f #f #f))
       ;; a prompt, and nothing else: `make-sparse-keymap' takes the
       ;; prompt and stops, so a second argument is an error rather than
       ;; something quietly ignored.
       ((and (or (string? (car rest)) (symbol? (car rest)))
             (null? (cdr rest)))
        (make<keymap> (make-hash-table (make-eqv-comparator)) #f #f (car rest)))
       ((and (keymap-type? (car rest)) (null? (cdr rest)))
        ;; `(keymap MAP)' is MAP - what `(keymap kml)' meant before, when
        ;; a keymap argument stood for its layers.
        (car rest))
       (else
        (error "make-sparse-keymap takes one prompt" rest))))

    (define keymap make-sparse-keymap)

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
      (let loop ((alist (hash-table->alist (keymap-bindings keymap))))
        (cond
         ((null? alist) #f)
         (else
          (let ((event (caar alist))
                (def   (cdar alist)))
            (cond
             ((eq? binding def) (list event))
             ((keymap-type? def)
              (let ((under (keymap-lookup-binding-key def binding)))
                (if under (cons event under) (loop (cdr alist)))))
             (else (loop (cdr alist)))))))))

    ;; -------------------------------------------------------------------------------------------------

    (define (set-keymap-parent keymap parent)
      ;; GNU Emacs's `set-keymap-parent' (`keymap.c:273'): "Modify KEYMAP
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
        (hash-table-set! (keymap-bindings keymap) event def)
        def))

    (define (access-keymap keymap event)
      ;; GNU Emacs's `access_keymap' (`keymap.c:491'): the binding of one
      ;; EVENT in KEYMAP, or #f. A *keymap* answer means the event is a
      ;; prefix; the caller reads the next event and calls this again on
      ;; it, which is `Flookup_key''s walk (`keymap.c:1264').
      ;;
      ;; This is the C's `noinherit' half: it asks KEYMAP's own bindings
      ;; and its char-table and stops - it does *not* walk the parent,
      ;; which `access_keymap_1' does only when it is asked to. That is
      ;; what `define-key' needs when it walks a sequence looking for the
      ;; prefix to descend through (`Fdefine_key' calls it with
      ;; `noinherit' set).
      ;;--------------------------------------------------------------
      (let ((event (if (char? event) (char->integer event) event)))
        (unless (or (integer? event) (symbol? event))
          (error "access-keymap: not an event" event))
        (let ((own (hash-table-ref/default (keymap-bindings keymap) event #f)))
          (cond
           (own own)
           (else
            (let ((ct (keymap-char-table keymap)))
              (and ct (ct event))))))))

    (define (keymap-lookup keymap key)
      ;; GNU Emacs's `Flookup_key' (`keymap.c:1264'): "Look up the
      ;; definition of KEY in KEYMAP... If KEY is a prefix, return the
      ;; keymap it leads to." KEY may be written in any spelling
      ;; `keymap-index' reads, which here includes a whole sequence.
      ;;
      ;; The walk is `access_keymap_1''s: KEYMAP's own bindings, then its
      ;; char-table, then its *parent*, and the keymap a step answers with
      ;; is where the next event is looked up.
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
                 ((keymap-type? cmd) (loop (cdr rest) cmd))
                 ;; a command before the end of the sequence: the C
                 ;; answers it and stops (`Flookup_key', the `!CONSP
                 ;; (keymap)' arm), which is what makes a bound prefix of
                 ;; a longer sequence reachable.
                 (cmd cmd)
                 ;; nothing here: the C asks the parent before it gives
                 ;; up (`access_keymap_1', the `Qkeymap' arm), and answers
                 ;; nil if there is none.
                 (else
                  (let ((parent (keymap-parent map)))
                    (if parent (loop rest parent) #f))))))))))))

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
            (let ((cmd (access-keymap map (car rest))))
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
