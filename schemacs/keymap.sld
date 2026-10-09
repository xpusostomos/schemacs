(define-library (schemacs keymap)
  (import
    (scheme base)
    (scheme char)
    (scheme write)
    (scheme lazy)
    (scheme case-lambda)
    (only (schemacs lens)
          lens view update update&view lens-set
          unit-lens record-unit-lens
          =>self  =>trace  =>hash-key!
          =>on-update  =>canonical
          =>head  =>encapsulate
          =>trace
          )
    (only (schemacs lens vector) vector-copy-with)
    (only (schemacs lens bin-hash-table)
          make<bin-hash-table>
          empty-bin-hash-table
          bin-hash-table-size
          bin-hash-table-empty?
          =>bin-hash-table-store-size!
          =>bin-hash-table-hash*!
          =>bin-hash-table-hash!
          =>bin-hash-key!
          hash-table-copy-with
          bin-hash-table-copy
          bin-hash-table->alist)
    (only (schemacs editor command) command-type? command-procedure)
    ;; The event model, which is what a key *is*: `event-modifiers' and
    ;; `event-basic-type' take an event apart into the modifiers and the
    ;; basic type this keymap indexes by. They are `character.sld''s, the
    ;; lowest editor library - see its export note.
    (only (schemacs editor character)
          event-modifiers event-basic-type event-convert-list
          apply-modifiers kbd
          char-alt char-super char-hyper char-shift char-ctl char-meta)
    (only (srfi 1) fold concatenate find)
    (only (schemacs string) string-fold)
    (only (schemacs bitwise) bitwise-ior bitwise-and)
    ;; `lognot' is the C's, and srfi 60's `(schemacs bitwise)' does
    ;; not re-export it - `(guile)' is where the rest of the tree takes
    ;; it from too (`character.sld' imports it the same way).
    (only (guile) lognot logand logior)
    (only (schemacs comparator)
          make-eq-comparator  make-eqv-comparator
          make-equal-comparator
          )
    (only (schemacs hash-table)
          hash-table-empty?
          string-hash alist->hash-table hash-table->alist
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
   char-table
   char-table-type?
   empty-char-table
   char-table-empty?
   char-table-size
   char-table-view
   char-table-set!
   char-table-update!
   char-table->alist
   =>char-table-char!
   char-table-copy

   alist->keymap-layer
   keymap-index-type?
   keymap-index
   keymap-index-append
   keymap-index->events
   reverse-list->keymap-index
   =>keymap-layer-index!
   keymap-index-to-char
   mod-index char-index next-index
   modifier-bit
   ctrl-bit meta-bit super-bit hyper-bit alt-bit

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

    (define (*->expr thing)
      (cond
       ((char-table-type? thing) (char-table->expr thing))
       ((keymap-layer-type? thing) (keymap-layer->expr thing))
       ((keymap-index-type? thing) (keymap-index->expr thing))
       ((hash-table? thing) (hash-table->expr *->expr thing))
       (else thing)))

    (define (hash-table->expr *->expr thing)
      (hash-table-fold
       thing
       (lambda (key val head)
         (cons (cons (*->expr key) (*->expr val)) head)
         )
       '()
       ))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <char-table-type>
      ;; A char-table maps characters to values. The keys are split across
      ;; two tables. The first table handles all characters in the range
      ;; of ASCII code in the inclusive range ~#x20~ (~#\space~) to ~#x7F~
      ;; (~#\delete~), what is called the ASCII map. All other characters
      ;; (including ASCII control characters below code point ~#x20~) go
      ;; in the upper table, also called the UTF table. This is done
      ;; because most character keys are expected to be set in the ASCII
      ;; map.
      ;;------------------------------------------------------------------
      (make<char-table-type> ascii-map utf-map)
      char-table-type?
      (ascii-map  char-table-ascii-map  set!char-table-ascii-map)
      (utf-map    char-table-utf-map    set!char-table-utf-map)
      )

    (define (empty-char-table)
      ;; Construct a completely key table.
      ;;------------------------------------------------------------------
      (make<char-table-type> #f #f)
      )

    (define (char-table-size kt)
      (if (not kt) 0
          (let ((size-of (lambda (bhm) (if bhm (bin-hash-table-size bhm) 0))))
            (+ (size-of (char-table-ascii-map kt))
               (size-of (char-table-utf-map kt))
               ))))

    (define char-table-copy
      ;; Deep-copy the given key table, that is, allocate a new key table
      ;; and copy the contents of the given key table `KT` into the new
      ;; key table. If the value of `KT` does not satisfy the
      ;; `CHAR-TABLE-TYPE?` predicate, the value of `KT` is returned as-is.
      ;;------------------------------------------------------------------
      (case-lambda
        ((kt) (char-table-copy kt (lambda (id) id)))
        ((kt copy-leaves)
         (cond
          ((char-table-type? kt)
           (let ((ascii-map (char-table-ascii-map kt))
                 (utf-map   (char-table-utf-map kt))
                 )
             (make<char-table-type>
              (if ascii-map (bin-hash-table-copy ascii-map copy-leaves) #f)
              (if utf-map (bin-hash-table-copy utf-map copy-leaves) #f)
              )))
          (else kt)
          ))))

    (define (char-table-empty? kt)
      (let ((empty? (lambda (bht) (or (not bht) (bin-hash-table-empty? bht)))))
        (or (not kt)
            (and (empty? (char-table-ascii-map kt))
                 (empty? (char-table-utf-map kt))
                 ))))

    (define (char-table-hash key table-size)
      ;; The hash function used to map characters to integers for key table indicies.
      ;;------------------------------------------------------------------
      (modulo
       (cond
        ((string? key) (string-hash key))
        ((char?   key) (char->integer key))
        (else (error "key must be a char or string value" key))
        )
       table-size
       ))

    (define =>ascii-map
      (record-unit-lens
       char-table-ascii-map
       set!char-table-ascii-map
       '=>ascii-map
       ))

    (define =>ascii-map?
      (=>canonical =>ascii-map empty-char-table char-table-empty?)
      )

    (define =>utf-map
      (record-unit-lens
       char-table-utf-map
       set!char-table-utf-map
       '=>utf-map
       ))

    (define =>utf-map?
      (=>canonical =>utf-map empty-char-table char-table-empty?)
      )

    (define *char-table-ascii-min-code-point* (char->integer #\space))
    (define *char-table-ascii-max-code-point* (char->integer #\delete))

    (define *lower-table-max-size*
      ;; It is expected that there will be a lot of character maps loaded
      ;; into memory at any given time, and so care is taken to minimize
      ;; the size of these objects.
      ;;
      ;; When creating a lower character table, initially the size is set
      ;; to 11 (a reasonable prime number, choosen by heuristic). However
      ;; if the weight of the table increases to roughly double this
      ;; size, the table is resized to this maximum size
      ;; *LOWER-TABLE-MAX-SIZE* which guarantees O(1) access to elements.
      ;;
      ;; See the "char-table-rebalance!" function.
      ;;------------------------------------------------------------------
      (+ 1 (- *char-table-ascii-max-code-point* *char-table-ascii-min-code-point*))
      )

    (define (lower-char? char)
      ;; Pass a character, if the character is within the range of
      ;; printable ASCII characters, #t is returned.
      ;;------------------------------------------------------------------
      (<= *char-table-ascii-min-code-point*
          (char->integer char)
          *char-table-ascii-max-code-point*
          ))

    (define (char-table-weight kt)
      (+ (hash-table-size (char-table-ascii-map kt))
         (hash-table-size (char-table-utf-map kt))
         ))

    (define (char-table-hash->expr head hmap)
      (hash-table-fold
       hmap
       (lambda (key elem head)
         (cons (cons key (*->expr elem)) head)
         )
       head
       ))

    (define (char-table->expr kt)
      (list
       'char-table
       (char-table-hash->expr
        (char-table-hash->expr '() (char-table-utf-map kt))
        (char-table-ascii-map kt)
        )))

    (define (char-table alist)
      ;; Construct a new key table. Returns a cons with the minimum
      ;; (lowest) and maximum (highest) key found.
      ;;------------------------------------------------------------------
      (let ((kt (empty-char-table)))
        (char-table-rebalance!
         (fold
          (lambda (pair kt)
            (char-table-set! #f (cdr pair) kt (car pair))
            )
          kt alist
          ))))

    (define (char-table-bin-rebalance! bin-hash-table)
      ;; This function rebalances a single hash table. Two values are
      ;; returned: the new BIN-COUNT and the updated hash table. Since
      ;; neither SRFI-69 nor SRFI-125 provide any way to retrieve the bin
      ;; count from the hash-table object, we need to track it ourselves
      ;; in our own data structure <BIN-HASH-TABLE-TYPE>.
      ;;------------------------------------------------------------------
      (if (not bin-hash-table) #f
          (let*((ht (view bin-hash-table =>bin-hash-table-hash*!))
                (bin-count (view bin-hash-table =>bin-hash-table-store-size!))
                (size (hash-table-size ht)))
            (if (<= (/ 1 2) (/ size bin-count) (/ 17 11))
                bin-hash-table
                (make<bin-hash-table>
                 size
                 (alist->hash-table
                  (hash-table->alist ht)
                  (make-equal-comparator)
                  ))))))

    (define (char-table-rebalance! kt)
      ;; It is expected that there will be a lot of character maps loaded
      ;; into memory at any given time, and so care is taken to minimize
      ;; the size of these objects.
      ;; 
      ;; When creating character tables, initially the size is set to 11
      ;; (a reasonable prime number, choosen by heuristic). However if the
      ;; weight of the table increases to roughly double this size, the
      ;; table is resized to to improve access time to all elements.
      ;; 
      ;; The rebalancing function is fairly simple: the HASH-TABLE-SIZE is
      ;; divided by the BIN-COUNT, if the resulting fraction is less than
      ;; 1/2 or approximately greater than 2, the table is 'unbalanced'
      ;; and so a new hash table is allocated with a bin count of exactly
      ;; the HASH-TABLE-SIZE, and then the elements are transferred to the
      ;; new table. If the table is not unbalanced, the given hash table
      ;; is returned unmodified.
      ;;------------------------------------------------------------------
      (let ((rebalance!
             (lambda (bin-hash-char-table)
               (char-table-bin-rebalance! bin-hash-char-table)
               )))
        (let*((kt (update rebalance! kt =>ascii-map?))
              (kt (update rebalance! kt   =>utf-map?))
              )
          kt
          )))

    ;; (define kt (char-table #f '((#\a . "A") (#\b . "B") (#\c . "C") (#\d . "D"))))

    (define *char-table-hash-init-size* (make-parameter 11))

    (define (make-char-table-inner-hash-table size)
      ;; Constructs a new, correctly tuned SRFI-69 or SRFI-125 hash-table
      ;; for use within the <BIN-HASH-TABLE-TYPE> for either of the forks
      ;; of a <CHAR-TABLE-TYPE>, with the given number of bins.
      ;;------------------------------------------------------------------
      ;; TODO: make use of the `SIZE` parameter
      (make-hash-table (make-equal-comparator))
      )

    (define (=>char-table-char do-rebalance char)
      ;; Define a lens that selects an entry by the key CHAR from within a
      ;; <CHAR-TABLE-TYPE>. The \"CHAR\" argument may also be a string
      ;; representing a keyboard key such as an arrow key or function key.
      ;;------------------------------------------------------------------
      (let*((=>fork
             (cond
              ((string? char) =>utf-map?)
              ((char?   char)
               (cond
                ((char<=? char #\delete) =>ascii-map?)
                (else =>utf-map?)))
              (else (error "char argument is neither a character nor a string" char))))
            (=>key (=>bin-hash-key! char (*char-table-hash-init-size*) make-char-table-inner-hash-table)))
        (=>encapsulate
         (lens
          =>fork
          (if do-rebalance
              (=>on-update =>key char-table-bin-rebalance!)
              =>key))
         (list '=>char-table-char do-rebalance char))))

    (define (=>char-table-char! do-rebalance char)
      (=>canonical (=>char-table-char do-rebalance char) empty-char-table char-table-empty?))

    (define (char-table-set! do-rebalance elem kt char)
      (lens-set elem kt (=>char-table-char! do-rebalance char)))

    (define (char-table-view kt char)
      ;; Lookup an element associated with a character from within a <char-table>.
      (view kt (=>char-table-char! #f char)))

    (define (char-table-update! up kt char)
      (update up kt (=>char-table-char! #f char)))

    (define (char-table->alist kt)
      (let ((ascii (char-table-ascii-map kt))
            (utf   (char-table-utf-map kt))
            )
        (apply append
         (map bin-hash-table->alist
              (cond
               ((and (not ascii) (not utf)) '())
               ((not utf) (cons ascii '()))
               ((not ascii) (cons utf '()))
               (else (list ascii utf))
               )))))

        ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-index-type>
      ;; One position in a key sequence: the modifiers held while a key
      ;; was pressed, and the key itself. `NEXTIX` is the rest of the
      ;; sequence, which is what a *prefix* is here - Emacs puts a submap
      ;; in the binding and reads the next event from the input, and this
      ;; is the same thing held in one value.
      ;;
      ;; **The bits in `MODIX` are GNU Emacs's own** -
      ;; `character.sld`'s `char-ctl`/`char-meta`/`char-shift`/`char-super`/
      ;; `char-hyper`/`char-alt` (`lisp.h`'s `CHAR_*`) - so an index and
      ;; an *event* speak the same language and
      ;; `event-convert-list'/'event-modifiers' read and write both. The
      ;; five private bits that stood here (`ctrl-bit #x01' and its four
      ;; neighbours) were a layout of this library's own, and they are
      ;; what `modifier->integer' and its name table existed to parse:
      ;; a `ctrl' this tree invented, accepted by no Emacs file, in place
      ;; of the `control' every Emacs file writes.
      (make<keymap-index> modix charix nextix)
      keymap-index-type?
      (modix  mod-index) ; the modifier bits held while the key was pressed
      (charix char-index) ; the key: a character, or a string naming one
      (nextix next-index) ; the rest of the key sequence, or #f
      )

    (define ctrl-bit char-ctl)
    (define meta-bit char-meta)
    (define super-bit char-super)
    (define hyper-bit char-hyper)
    (define alt-bit char-alt)
    ;; ^ GNU Emacs's own bits, under the names this library has always
    ;; used for them - so `mod-index' answers an *event's* modifier field
    ;; and needs no translation to become one again.

    ;; `ascii-modifier?' and `keymap-index->ascii' stood here. The latter
    ;; reconstructed an ASCII *string* from an index - an ESC prefixed for
    ;; a meta bit and #x40 subtracted for a control bit - which is a reader
    ;; for the private key spelling this tree used to keep. There is no
    ;; such reader in Emacs, no such spelling is left here, and nothing
    ;; called either function (checked). A key is an *event*, and
    ;; `keymap-index->events' plus `key-description' render it.

    (define (keymap-index-head kmix)
      ;; Return just the head of a keymap index
      (make<keymap-index> (mod-index kmix) (char-index kmix) #f))

    ;;----------------------------------------------------------------------
    ;; Unfortunately, the `ALIST->HASH-TABLE` procedure is one of those APIs
    ;; that none of the Scheme implementations seem to be able to agree on.
    ;; There are a few `COND-EXPAND` statments here to take care of this
    ;; diversity of opinion.

    (define (modifier-bit sym)
      ;; The bit GNU Emacs's `event-modifiers' (`subr.el:1825') names with
      ;; SYM, or #f. **The names are Emacs's own** - `control', `meta',
      ;; `shift', `super', `hyper', `alt' - which is exactly the list that
      ;; function's docstring gives; there is no `ctrl' among them, and
      ;; this tree used to have one of its own here.
      ;;
      ;; **`shift' deliberately answers #f**, as the table this replaces
      ;; did: a shifted *character* carries its shift in its own case, and
      ;; `keymap-index` takes the character below as the event spells it,
      ;; so `X' and `x' stay two keys. A shifted *function* key (`S-up')
      ;; therefore still cannot be told from the unshifted one, which is
      ;; a gap this keymap has always had and which closing would change
      ;; what every bound capital does.
      ;;--------------------------------------------------------------
      (cond ((eq? sym 'control) char-ctl)
            ((eq? sym 'meta) char-meta)
            ((eq? sym 'super) char-super)
            ((eq? sym 'hyper) char-hyper)
            ((eq? sym 'alt) char-alt)
            (else #f)))

    ;; `modifier->integer' and its `sym-lookup-table' stood here: a table
    ;; of the twelve ways this library spelled a modifier - `C', `ctrl',
    ;; `control', `M', `meta', `s', `super', `H', `hyper', `A', `alt' -
    ;; hand-hashed into fourteen bins. `ctrl' and `s'-for-super were this
    ;; tree's own spellings, written by no Emacs file; the C's
    ;; `parse_solitary_modifier' (`keyboard.c:7920') accepts `ctrl' as an
    ;; alias but every `define-key' in Emacs writes `control'. The names
    ;; are Emacs's now, and `modifier-bit' above is the whole of it.

    (define (keymap-index syms)
      ;; Construct a ~<KEYMAP-INDEX>~ from a symbolic representation.
      ;; index is a sequence of keyboard key elements. Each element must
      ;; be symbolized by a typeable and printable UTF character (such as
      ;; a letter or number) or a string representing a keyboard key (such
      ;; as \"LEFT\" or \"RIGHT\" arrows), and may be preceded by zero or
      ;; more modifier symbols such as ~C~ or ~ctrl~, ~M~ or ~meta~, and
      ;; ~S~ or ~super~. The character or string terminates a key chord
      ;; with zero or more modifiers.  The keymap index may contain zero
      ;; or more keyboard key elements.  If there are zero elements ~#f~
      ;; is returned, otherwise a ~<KEYMAP-INDEX>~ is returned.
      ;; 
      ;; Use the ~MAP-KEY~ function to construct a list of associations
      ;; between a ~<KEYMAP-INDEX>~ structure and a procedure.
      ;;------------------------------------------------------------------
      (cond
       ;; A *key sequence* - a vector of events, which is what `kbd'
       ;; answers with and what Emacs's `define-key' takes. It is walked
       ;; as the list it is.
       ((vector? syms)
        (keymap-index (vector->list syms)))
       ((string? syms)
        ;; A *string*, which is what `(kbd "C-x C-c")' is written as and
        ;; what `read-kbd-macro' reads. `kbd' (`character.sld:644') is
        ;; Emacs's parser for it and answers a vector of events, so this
        ;; is the same walk as the vector branch above. It replaces
        ;; `string->keymap-index', this library's own parser, which was
        ;; the *other* place that built `ctrland the rest' by hand.
        (keymap-index (kbd syms)))
       ;; An Emacs *event*: an integer whose low bits are the character and
       ;; whose high bits are the modifiers, or a symbol for a key that is
       ;; not a character (`up', `f1'). It is one key, not a sequence, so it
       ;; is decomposed straight into an index - `event-modifiers' and
       ;; `event-basic-type' being the two halves that take it apart.
       ;;
       ;; The modifiers are mapped to *this* keymap's bits, which are ctrl,
       ;; meta, super, hyper and alt. Emacs's `shift' has no bit here: a
       ;; shifted character is carried by the character's own case - the
       ;; character below is taken *as the event spells it*, which is the
       ;; whole of the shift in that case - and a shifted *function* key
       ;; (`S-up') cannot be told from the unshifted one, which is a gap
       ;; this keymap has always had.
       ;;
       ;; The character of a *character* event is `event-basic-type''s
       ;; first half only. That function answers the C's basic type and
       ;; does two things: it unfolds the control range - `(logior base
       ;; 64)', so `C-x' is the character `x' - and then it *downcases*
       ;; (`subr.el:1876'). The unfolding is wanted: the index for `C-x'
       ;; is the control-range character `x', which is what every binding
       ;; in this tree spells. The downcasing is not - Emacs's
       ;; `define-key' never asks `event-basic-type' anything, and
       ;; `(kbd "X")' is
       ;; `[88]' there, a key of its own beside `[120]'. Folding `X' onto
       ;; `x' meant a capital could not be inserted at all.
       ((char? syms)
        ;; **A bare character is the event its code point names.** GNU
        ;; Emacs has no character type - `?a' *is* 97 - so a character
        ;; here is one event and nothing else, and the event branch below
        ;; is where it is decomposed. The nested-list branch further down
        ;; has always accepted `'(#\a)'; this is the same key spelled
        ;; without its list, and until it was here `(keymap-index #\a)'
        ;; fell off the end of this `cond' and answered the *unspecified*
        ;; value - which is **true in Scheme**, so the caller went on with
        ;; it as if it were a key. Three frames away that surfaced as an
        ;; `Argument 1 out of range' from `integer->char' on a nonsense
        ;; event.
        (keymap-index (char->integer syms)))
       ((or (integer? syms) (symbol? syms))
        (let ((base (event-basic-type syms)))
          (make<keymap-index>
           (let loop ((mods (event-modifiers syms)) (mod 0))
             (if (null? mods)
                 mod
                 (loop (cdr mods)
                       (bitwise-ior mod
                                    (or (modifier-bit (car mods)) 0)))))
           (if (symbol? base)
               (symbol->string base)
               ;; The event's character: the modifier bits masked off,
               ;; and the control range unfolded - `event-basic-type'
               ;; as far as `uncontrolled' (`subr.el:1875'). The
               ;; folding of the control range *is* a case fold - `C-x'
               ;; arrives as 24 and unfolds to `X' - so the unfolded
               ;; character is downcased here, to the `x' every binding
               ;; in the tree spells it with. A character *above* the
               ;; control range keeps its case: it came from the key
               ;; itself, and `X' and `x' are two keys.
               (let ((code (bitwise-and
                            syms
                            (lognot (bitwise-ior char-alt char-super
                                                 char-hyper char-shift
                                                 char-ctl char-meta)))))
                 (if (< code 32)
                     (char-downcase (integer->char (bitwise-ior code 64)))
                     (integer->char code))))
           #f)))
       ;; **Anything that is not one of the above is not a key at all**,
       ;; and the clause that says so is written as this `cond`'s final
       ;; `else` because that is where a `cond`'s default belongs. Without
       ;; it the `cond` fell off its own end and answered the *unspecified*
       ;; value, which is **true in Scheme** - so a caller that asked for
       ;; an index it could not get went on with something that was not
       ;; one. That is how a character event reached `keymap-lookup` as "a
       ;; key", and the failure surfaced three frames away as `Argument 1
       ;; out of range` from `integer->char` on a nonsense event.
       ;; **A key sequence: a list of *events*.** Each element is one
       ;; key - an integer carrying its own modifier bits, a symbol
       ;; naming a key that is not a character (`up', `f1'), or a
       ;; character, which is the same thing as its code point. An
       ;; element that is itself a list is Emacs's *Lucid event type
       ;; list* - `(control ?x)', `(meta f10)', `(control meta ?0)' - and
       ;; goes through `event-convert-list' (`keyboard.c:7832'), which is
       ;; where Emacs consumes a modifier *name* and which is therefore
       ;; the only place one may appear. `define-key' makes exactly this
       ;; conversion before it touches a map (`Fdefine_key',
       ;; `keymap.c:1156', guarded by `lucid_event_type_list_p'), and
       ;; `Flookup_key' does the same (`:1264').
       ;;
       ;; It used to be the *modifier symbols themselves* that were the
       ;; currency here - a list of `control', `meta' and a character,
       ;; accumulated into the index by a name table of this library's
       ;; own. Emacs writes no such thing: `(kbd "C-x")' is `#(24)' and a
       ;; Lucid element is the only list that means a key.
       (else
        (unless (pair? syms)
          (error "keymap index must be composed of events" syms))
        ;; NOTE: the field accessors of <keymap-index-type> are
        ;; shadowed by the loop variables below, so aliases are bound
        ;; here, outside of the named let.
        ;;--------------------------------------------------------------
        (let* ((%keymod mod-index)
               (%keychar char-index)
               (one-event
                (lambda (sym)
                  (cond
                   ;; An event already: an integer, a character (the same
                   ;; thing), or a named key as a string.
                   ((or (integer? sym) (char? sym) (string? sym)) sym)
                   ;; A Lucid event type list - the one list that is a key.
                   ((pair? sym) (event-convert-list sym))
                   ((symbol? sym) sym)
                   (else
                    (error "keymap index must be composed of events" sym))))))
        (let loop
            ((mod-index 0)
             (syms syms))
          (cond
           ((null? syms) #f)
           (else
            (let* ((sym (car syms))
                   (event (one-event sym))
                   (next (cdr syms)))
              (if (or (integer? event) (char? event))
                  (let ((sub (keymap-index event)))
                    (make<keymap-index>
                     (%keymod sub) (%keychar sub)
                     (loop 0 next)))
                  ;; **A named key is an *event*, so it goes back to
                  ;; the event branch - not to the string branch.** The
                  ;; string branch parses a `kbd' description, and
                  ;; `(kbd "up")' answers the very vector this loop is
                  ;; walking, so turning the symbol into a string here
                  ;; recursed for ever: the editor hung before it drew
                  ;; anything, with no error to see, because every
                  ;; `define-key' in the tree runs through this at load.
                  (let ((sub (keymap-index event)))
                    (make<keymap-index>
                     (%keymod sub) (%keychar sub)
                     (loop 0 next))))))))))))

    (define (keymap-index-append . items)
      ;; Join key sequences: the same walk `reverse-list->keymap-index`
      ;; does, from the other end. **It was deleted by accident** in the
      ;; pass that took the modifier vocabulary out - it sat between
      ;; `*mod-bit-alist*' and `keymap-index->list', and the surgery
      ;; removed the range - which showed up as "Unbound variable:
      ;; keymap-index-append" the moment the editor suite ran.
      ;;--------------------------------------------------------------
      (cond
       ((null? items) #f)
       (else
        (let ((head (car items))
              (tail (cdr items)))
          (cond
           ((not head)
            (apply keymap-index-append tail))
           ((keymap-index-type? head)
            (make<keymap-index>
             (mod-index head)
             (char-index head)
             (apply keymap-index-append (next-index head) tail)))
           (else
            (error "all arguments must be of <keymap-index-type>" head)))))))

    (define (modifier-names modix)
      ;; The modifier *names* a bit field holds, in Emacs's spelling -
      ;; `control', `meta', `super', `hyper', `alt' - which is what
      ;; `event-modifiers' answers with and what `event-convert-list'
      ;; takes. The inverse of `modifier-bit' above, and the only other
      ;; place a modifier name appears.
      ;;--------------------------------------------------------------
      (append (if (not (zero? (logand modix char-ctl))) '(control) '())
              (if (not (zero? (logand modix char-meta))) '(meta) '())
              (if (not (zero? (logand modix char-super))) '(super) '())
              (if (not (zero? (logand modix char-hyper))) '(hyper) '())
              (if (not (zero? (logand modix char-alt))) '(alt) '())))

    (define (keymap-index->events km)
      ;; The *events* of the key sequence KM stands for: an integer with
      ;; its modifier bits, or a symbol naming a key that is not a
      ;; character. This is Emacs's reader of a key - `(aref KEY i)' for
      ;; a vector key - and what `key-description' renders.
      ;;
      ;; **The conversion is `event-convert-list', run backwards.** An
      ;; index holds its modifiers as bits and its key as the letter the
      ;; control range was unfolded to, so rebuilding the event means
      ;; asking `event-convert-list' for `(control #\\x)' - which is the
      ;; C's "Turn (control a) into C-a", and which is what turns the
      ;; stored `#\\x' back into the event 24. Doing the bit arithmetic by
      ;; hand here gave `char-ctl | 120', an event Emacs never makes for
      ;; that key.
      ;;
      ;; It replaces `keymap-index->list', which answered a list of
      ;; modifier *symbols* and a character - this library's private
      ;; spelling, in which the modifier names were the *data*. There is
      ;; no such reader in Emacs because there is no such spelling.
      ;;--------------------------------------------------------------
      (if (not km)
          '()
          (let ((modix (mod-index km))
                (charix (char-index km)))
            (cons (if (char? charix)
                      (event-convert-list
                       (append (modifier-names modix) (list charix)))
                      ;; A string names a key that is not a character
                      ;; (`up', `f1'); `apply-modifiers' is the C's
                      ;; `apply_modifiers_uncached', which spells the
                      ;; modifier prefixes into the name - `M-up'.
                      (apply-modifiers modix (string->symbol charix)))
                  (keymap-index->events (next-index km))))))

    (define (reverse-list->keymap-index nodes)
      (let loop
          ((nodes nodes)
           (key #f))
        (cond
         ((null? nodes) key)
         ((pair? nodes)
          (let ((head (car nodes))
                (tail (cdr nodes)))
            (cond
             ((not head)
              (loop tail key))
             ((keymap-index-type? head)
              (loop
               tail
               (make<keymap-index>
                (mod-index head)
                (char-index head)
                (keymap-index-append (next-index head) key))))
             (else
              (error "all list items must be of type <keymap-index-type>" head)))))
         (else
          (error "expecting list of <keymap-index-type> elements" nodes)))))


    (define at-char (integer->char 64))
    (define underscore (integer->char 95))

    (define (keymap-index-to-char keyix allow-ctrl on-success on-fail)
      ;; Convert a keymap-index to a character, evaluate `ON-SUCCESS` with
      ;; the character if conversion succeeded, evaluate `ON-FAIL` if
      ;; conversion failed.
      ;;------------------------------------------------------------------
      (cond
       ((next-index keyix) (on-fail)) ;; if there is a next-index, return #f
       ((and allow-ctrl (= ctrl-bit (mod-index keyix)))
        (let ((char (char-upcase (char-index keyix))))
          (cond
           ((and (char>=? char at-char) (char<=? char underscore))
            ;; this equation is defined by ASCII standard for how to
            ;; convert letters to control characters.
            (on-success (integer->char (bitwise-and #x1F (char->integer char)))))
           (else (on-fail)))))
       ((not (= 0 (mod-index keyix)))
        (on-fail)) ;; ctrl chars not allows and mod-index is not zero
       ;; A *character* key is self-inserting; a *named* one is not. Emacs
       ;; makes the same test in `keyboard.c' - the catch-all that runs
       ;; `self-insert-command' is reached only when the key is a
       ;; character event - and without it every unbound named key
       ;; (`<f13>', `<prior>', `<insert>') reached `self-insert-command',
       ;; which inserted the key's *name* as text. In a read-only buffer
       ;; the same keys said "Buffer is read-only" and otherwise did
       ;; nothing, which is how PgUp and PgDn were lost in Dired.
       (else (if (char? (char-index keyix))
                 (on-success (char-index keyix))
                 (on-fail)))
       ))

    (define keymap-index->expr keymap-index->events)

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-layer-type>
      (%make<keymap-layer> mod-table alt-action)
      keymap-layer-type?
      (mod-table keymap-layer-mod-table %set!keymap-layer-mod-table)
        ;; ^ an ordinary hash table (not a <bin-hash-table-type>)
        ;; containing keymaps selected by modifier key
      (alt-action keymap-layer-alt-action set!keymap-layer-alt-action)
        ;; ^ it is possible to merge keymap-layer tables such that mappings to
        ;; that terminate at the end of one key string (such as "C-c C-c")
        ;; is not a terminal string in the merged mapping (such as when
        ;; merging with "C-c C-c x"). This field keeps the action mapped
        ;; to the shorter string (e.g. "C-c C-c") available should the
        ;; longer string (e.g. "C-c C-c x") be deleted from the table.
      )

    (define (make<keymap-layer> mod-table alt-action)
      (%make<keymap-layer>
       (cond
        ((not mod-table) #f)
        ((hash-table? mod-table) mod-table)
        (else (error "not a <hash-table-type>" mod-table)))
       alt-action))

    (define (set!keymap-layer-mod-table kml mod-table)
      (%set!keymap-layer-mod-table kml
       (cond
        ((not mod-table) #f)
        ((hash-table? mod-table) mod-table)
        (else (error "not a <hash-table-type>" mod-table))
        )))

    (define get-keymap-layer-mod-table keymap-layer-mod-table)

    (define (keymap-layer-empty? km)
      (or (not km)
          (let ((ht (keymap-layer-mod-table km)))
            (and
             (not (keymap-layer-alt-action km))
             (or (not ht) (hash-table-empty? ht))))))

    (define (keymap-layer . assocs) (alist->keymap-layer assocs))

    (define (keymap-layer-action node)
      ;; This procedure checks if the given `LAYER` contains a value in
      ;; `KEYMAP-LAYER-ALT-ACTION` while also checking to make sure that
      ;; the `KEYMAP-LAYER-MOD-TABLE` is empty. If the action is defined
      ;; and the table is empty, the action is returned. If the table is
      ;; not empty, the table is always returned regardless of whether the
      ;; action is defined. If the table is empty and there is no action,
      ;; #f is returned.
      (let*((alt (keymap-layer-alt-action node))
            (mods (keymap-layer-mod-table node))
            (empty (or (not mods) (hash-table-empty? mods)))
            )
        (cond
         ((and empty (not alt)) #f)
         ((and empty alt) alt)
         (else node)
         )))

    (define (alist->keymap-layer assocs)
      ;; Construct a new empty keymap-layer from an association list of
      ;; <KEYMAP-INDEX-TYPE> indicies paired with procedures to be
      ;; executed when the keymap index lookup occurs. The ALT-ACTION,
      ;; which is an action that may (or may not) be used if a lookup
      ;; fails, should be assigned to the null key, so the association
      ;; pair `('() . some-procedure)` will assign "some-procedure" to the
      ;; `KEYMAP-LAYER-ALT-ACTION` field of the constructed `<KEYMAP-LAYER-TYPE>`
      ;; value.
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
             (keymap-layer-mod-table km)
             (lambda (ct) (char-table-copy ct keymap-layer-copy)))
            (alt-copy (keymap-layer-alt-action km))
            ))
          (else km)
          ))))

    (define =>keymap-layer-mod-table
      (record-unit-lens keymap-layer-mod-table set!keymap-layer-mod-table '=>keymap-layer-mod-table)
      )

    (define =>keymap-layer-mod-table?
      (=>canonical =>keymap-layer-mod-table keymap-layer keymap-layer-empty?)
      )

    (define =>keymap-layer-alt-action
      (record-unit-lens keymap-layer-alt-action set!keymap-layer-alt-action '=>keymap-layer-alt-action)
      )

    (define =>keymap-layer-alt-action?
      (=>canonical =>keymap-layer-alt-action keymap-layer keymap-layer-empty?))

    (define *keymap-layer-num-char-tables* 32
      ;; The number of key tables in a keymap-layer is defined by the number of
      ;; possible modifiers combinations that can be applied. There are
      ;; five modifiers: Control, Meta/Alt, Super, Hyper, and SC-Alt
      ;; ("Space-cadet Alt", different from IBM-PC "Alt"). Since these any
      ;; one of modifiers can be either on or off, we have 5 bits or 32
      ;; possible modifier values, each needing its own lookup table.
      )


    (define (keymap-layer->expr km)
      (list
       'keymap-layer
       (*->expr (keymap-layer-alt-action km))
       (hash-table-fold
        (keymap-layer-mod-table km)
        (lambda (kmix kt head)
          (cons
           (keymap-index->expr (keymap-index-head kmix))
           (char-table->expr kt)
           ))
        '()
        )))

    (define (map-key syms proc)
      ;; Construct an association between a list of symbols passed to
      ;; ~KEYMAP-INDEX~ to construct a keymap index, and a procedure. A list of
      ;; these values is used to initialize or update a ~<KEYMAP-LAYER>~.
      ;; 
      ;; The ~PROC~ argument may be a procedure, or it may be another
      ;; ~<KEYMAP-LAYER>~.
      (cons (keymap-index syms) proc)
      )

    (define (default-make-keymap-layer-mod-table)
      ;; This hash table has a size of 7. Any combination of the control
      ;; and meta bits (or none) exist tables in lower 4 bins (0, 1, 2, or
      ;; 3). All other modifiers are shoved up into upper 3 bins. I do
      ;; this because the use of super, hyper and alt modifiers are so
      ;; unusual in normal Emacs usage that I expect these upper 3 bins
      ;; will almost never be used.
      (make-hash-table (make-eqv-comparator))
      )


    (define (=>keymap-layer-mod-table-key? key)
      ;; Define a lens accessing a key in the hash table of a
      ;; KEYMAP-LAYER-MOD-TABLE.
      (lens
       =>keymap-layer-mod-table?
       (=>canonical (=>hash-key! key) default-make-keymap-layer-mod-table hash-table-empty?)
       ))


    (define (=>keymap-layer-index! key)
      ;; Construct a lens to access a KEYMAP-LAYER-TYPE by the given
      ;; INDEX. The INDEX is of type <KEYMAP-INDEX-TYPE> or a list of
      ;; symbols and characters that can be passed to the KEYMAP-INDEX
      ;; function.
      ;;------------------------------------------------------------------
      (cond
       ((string? key)
        (=>keymap-layer-index! (keymap-index key)))
       ((keymap-index-type? key)
        (=>canonical
         (apply lens
          (let loop ((key key))
            (if (not key) '()
                (cons
                 (=>keymap-layer-mod-table-key? (mod-index key))
                 (cons
                  (=>char-table-char! #t (char-index key))
                  (loop (next-index key)))))))
         keymap-layer
         keymap-layer-empty?))
       ((pair? key) (=>keymap-layer-index! (keymap-index key)))
       ;; A *key sequence*, which is what `kbd' answers with and what
       ;; Emacs's `define-key' takes - the same thing `keymap-index'
       ;; accepts, so it is taken the same way.
       ((vector? key) (=>keymap-layer-index! (keymap-index key)))
       ((null? key) =>self)
       (else
        (error "=>keymap-layer-index! lens, key not a list or a <KEYMAP-INDEX-TYPE>."
               key))
       ))


;; `=>kbd!' stood here: a lens over a binding named by a varargs list of
    ;; modifier and character symbols - the private key spelling this tree
    ;; used to keep, wrapped in a lens. Nothing called it (checked), and
    ;; the spelling it was named after is gone; `=>keymap-layer-index!'
    ;; takes a key sequence, `(kbd "C-x")' or an event vector.

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
      (let*((mods (keymap-layer-mod-table km))
            (alt  (keymap-layer-alt-action km))
            (ht
             (concatenate
              (map
               (lambda (pair)
                 (let ((mod (car pair)) (ct (cdr pair)))
                   (concatenate
                    (map
                     (lambda (pair)
                       (let ((c (car pair)) (km (cdr pair)))
                         (cond
                          ((keymap-layer-type? km)
                           (map
                            (lambda (pair)
                              (let ((key (car pair)) (alt (cdr pair)))
                                (cons (make<keymap-index> mod c key) alt)))
                            (keymap-layer->alist km)))
                          (else (cons (make<keymap-index> mod c #f) km)))))
                     (char-table->alist ct)))))
               (if mods (hash-table->alist mods) '()))))
            )
        (if alt (cons (cons #f alt) ht) ht)))

    (define (keymap-layer-assoc-split assoc)
      ;; Split an association from a key to a binding. The association
      ;; must be and element from a list of the elements produced by
      ;; `keymap-layer->alist` Returns two values, the key and the binding.
      (cond
       ((null? assoc) (error "not a key->binding association" assoc))
       (else
        (let loop ((head (car assoc)) (tail (cdr assoc)) (stack '()))
          (cond
           ((null? tail) (values (reverse stack) head))
           ((not (pair? tail)) (values (reverse (cons head stack)) tail))
           (else (loop (car tail) (cdr tail) (cons head stack)))
           )))))

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
      ;; This is a procedure that can return a value for any
      ;; `<keymap-index-type>`. It is used to implement keymaps where the
      ;; majority of indicies all return the same value, such as the
      ;; self-insert-map, among others.
      (make<keymap-index-predicate> proc)
      keymap-index-predicate-type?
      (proc  keymap-index-predicate))

    ;;(cond-expand
    ;;  (guile-3
    ;;   (set-record-type-printer!
    ;;    <keymap-index-predicate-type>
    ;;    (lambda (km port)
    ;;      (pretty port
    ;;       "(make<keymap-index-predicate> "
    ;;       (keymap-index-predicate km) ")"))))
    ;;  (else))

    (define (apply-keymap-index-predicate pred keyix)
      (cond
       ((not (keymap-index-type? keyix))
        (error "not a <keymap-index-type>" keyix))
       ((not (keymap-index-predicate-type? pred))
        (error "not a <keymap-index-predicate-type>" pred))
       (else
        ((keymap-index-predicate pred) keyix))
       ))


    (define (new-self-insert-keymap-layer allow-ctrl on-success on-fail)
      ;; Construct a `<KEYMAP-INDEX-PREDICATE-TYPE>` that checks a given
      ;; `<KEYMAP-INDEX-TYPE>` value if it is any unmodified key (or, only
      ;; modified by a CTRL modifier if `ALLOW-CTRL` is #t), and also not
      ;; followed by any other key (`NEXT-INDEX` is #f), then the
      ;; `ON-SUCCESS` procedure is applied to the `CHAR-INDEX` of the
      ;; `<KEYMAP-INDEX-TYPE>` value. If lookup fails, the `ON-FAIL`
      ;; procedure is appled no arguments.
      (make<keymap-index-predicate>
       (lambda (keyix) (keymap-index-to-char keyix allow-ctrl on-success on-fail))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <keymap-type>
      ;; A list of keymap layers, and a *parent* keymap. When looking-up
      ;; an element with a `<keymap-index-type>`, all layers are checked,
      ;; the element nearest the bottom of the list (nearer to `car` than
      ;; to `cdr`) is returned; and when no layer has anything for the
      ;; index, the lookup goes on to the parent, and to its parent, and
      ;; so on. Keymap operations like `KEYMAP-PUSH` treat
      ;; `<KEYMAP-TYPE>`s as immutable and always return newly constructed
      ;; `<KEYMAP-TYPE>` values.
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
    ;; same conversion already - `(schemacs editor character)''s
    ;; `event-convert-list', with `parse-solitary-modifier' beside it -
    ;; so the two functions below are the *only* thing that was missing.
    ;;
    ;; A value that is itself a keymap is a *prefix*: `access_keymap_1'
    ;; recurses into it, and a sequence is walked one event at a time.
    ;; The tree expresses a prefix as a layer or keymap *value* (its
    ;; `<keymap-index>''s `nextix' chain does the same job inside a single
    ;; index, and goes when the callers have moved here).
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
      ;; Take a KEY-PATH that has been constructed by the KEYMAP-INDEX
      ;; procedure from a sequence of keyboard characters and keyboard
      ;; modifier symbols such as 'Control or 'Alt (see
      ;; MODIFIER->INTEGER), and determine if a procedure has been mapped
      ;; to `KM`, which may be a `<KEYMAP-LAYER-TYPE>` in which the
      ;; `KEY-PATH` is indexed, or a `<KEYMAP-INDEX-PREDICATE-TYPE>` to
      ;; which the `KEY-PATH` is applied. If the `KEY-PATH` leads to
      ;; another non-empty layer or predicate value, that value is
      ;; returned. But if the layer found contains a
      ;; `KEYMAP-LAYER-ALT-ACTION` and nothing else (the
      ;; `KEYMAP-LAYER-MOD-TABLE` is empty) the alt-action is returned.
      (cond
       ((keymap-layer-type? km)
        (view km (=>keymap-layer-index! key) =>keymap-layer-alt-action?))
       ((keymap-index-predicate-type? km)
        (apply-keymap-index-predicate km key))
       (else (error "not a <keymap-layer-type> or <keymap-index-predicate-type>" km))
       ))


    (define (keymap-lookup km kmix)
      ;; This procedure performs a lookup in a `<KEYMAP-TYPE>` argument
      ;; `KM` with a `<KEYMAP-INDEX-TYPE>` argument `KMIX`. All layers in
      ;; the keymap are searched in order. The first time a lookup in a
      ;; `<KEYMAP-LAYER-TYPE>` or `<KEYMAP-INDEX-PREDICATE-TYPE>` results
      ;; in a value that is not another layer or predicate will cause this
      ;; procedure to immediately return that value. Otherwise, a new
      ;; <KEYMAP-TYPE> is returned containing only layers and predicates
      ;; that could be resolved by the key index. If all results are "#f",
      ;; then "#f" is returned.
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
           ;; index, so the parent is asked - and its parent, which is
           ;; what makes the chain work. A keymap that *did* have a
           ;; prefix binding here does not reach its parent for that key,
           ;; which is Emacs's rule too: the binding shadows.
           ((null? found)
            (let ((parent (keymap-parent km)))
              (and parent (keymap-lookup parent kmix))))
           ((pair? found) (make<keymap> found #f (keymap-parent km)))
           (else found)
           )))))

    ;; -------------------------------------------------------------------------------------------------

    (define-record-type <modal-lookup-state-type>
      ;; This is the state object updated by MODAL-STATE-LOOKUP-STEP!
      ;; function which implements the modal state key lookup
      ;; mechanism. This record type contains 2 fields:
      ;;
      ;;  1. KEYMAP is the current keymap in which the key will
      ;;     lookup the next action or keymap
      ;;
      ;;  2. STACK is a reversed list of key values that have been
      ;;     looked-up so far
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
      (reverse-list->keymap-index (modal-lookup-state-index-stack state)))

    (define (modal-lookup-state-lookup state key)
      ;; Looks-up a key in <modal-lookup-state-type> object, which
      ;; might contain a single keymap or a list of keymaps.
      (keymap-lookup (modal-lookup-state-keymap state) key))

    (define (modal-lookup-state-step! state key do-action do-wait-next do-fail-lookup)
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
      ;;  2. a key from a keyboard event that recently occurred,
      ;;     which is used to lookup the next action or keymap in the the
      ;;     current keymap (the MODAL-LOOKUP-STATE-KEYMAP field) of the
      ;;     <MODAL-LOOKUP-STATE-TYPE> record.
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
      ;;   - If an alt-action procedure was found and there are no other
      ;;     possible lookups to be performed, evaluate the DO-ACTION
      ;;     procedure, which must take two arguments: 1. a key index that
      ;;     triggered it wrapped in a promise (must be forced in order to
      ;;     be used), and 2. a procedure to be evaluated. After
      ;;     evaluating DO-ACTION, return #f.
      ;;
      ;;   - If non-empty keymap is found, regardless of whether an
      ;;     alt-action is present, evaluate the DO-WAIT-NEXT procedure
      ;;     with a promise to the current key index (must be forced in
      ;;     order to be used) and the next keymap being awaited.  After
      ;;     evaluating DO-WAIT-NEXT, return #t.
      ;;
      ;;   - If an completely empty keymap is found, evaluate the
      ;;     DO-FAIL-LOOKUP procedure with a single argument: the key
      ;;     index up to this point (not a "promise" object wrapping the
      ;;     key index value, but the key index value itself). After
      ;;     evaluating DO-FAIL-LOOKUP, return #f.
      (let*((step (make<keymap-index> (mod-index key) (char-index key) #f))
            (next (next-index key))
            (stack (cons step (modal-lookup-state-index-stack state)))
            (full-key (delay (reverse-list->keymap-index stack)))
            (action-or-map (modal-lookup-state-lookup state step))
            )
        (set!modal-lookup-state-index-stack state stack)
        (cond
         ((and (not next) action-or-map (not (keymap-type? action-or-map)))
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
