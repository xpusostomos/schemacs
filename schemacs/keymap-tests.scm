(import
  (scheme base)
  (only (scheme lazy) force)
  (schemacs keymap)
  (only (schemacs lens) view lens-set)
  ;; `kbd' is the tree's spelling of a *key* - `(kbd "C-x")' is the event
  ;; vector `#(24)' - and it is `character.sld''s, where the C's
  ;; `make_lispy_event' arithmetic lives. `event-convert-list' is
  ;; `keyboard.c''s consumer of a Lucid event type list.
  (only (schemacs editor character) kbd event-convert-list)
  (only (srfi 64) test-begin test-end
        test-assert test-equal test-eq)
  )

(test-begin "schemacs_keymap")

;; -------------------------------------------------------------------------------------------------
;;
;; **A key is a string or a vector of *events*, and nothing else.** In GNU
;; Emacs an event is an integer carrying its own modifier bits - `C-x' is
;; 24 and `(kbd "C-x")' is `#(24)' - or a symbol naming a key that is not
;; a character (`left', `f10', `M-up').
;;
;; A modifier *name* is allowed in exactly one place: the Lucid event type
;; list `(control ?x)', which goes through `event-convert-list'
;; (`keyboard.c:7832') as `Fdefine_key' does (`keymap.c:1156'). A bare
;; list of *modifier symbols* is not a key in Emacs at all, and is what
;; this tree was purged of - `'ctrl' appeared in no Emacs file.
;;
;; `keymap-index' normalises any spelling to the list of events the key
;; is made of, and `keymap-index->events' reads a key back. The two are
;; the same function, because a key IS its events here.

(define (kbd->events s) (keymap-index (kbd s)))

(define C-M-x (kbd->events "C-M-x"))
(define C-c_C-c (kbd->events "C-c C-c"))
(define C-g (kbd->events "C-g"))
(define left-arrow-key (kbd->events "<left>"))
(define C-left-arrow-key (kbd->events "C-<left>"))

(test-equal "the events of a chord" '(24 3) (kbd->events "C-x C-c"))
(test-equal "a named key is a symbol event" '(left) left-arrow-key)
(test-equal "a modifier on a named key is part of its name"
  '(C-left) C-left-arrow-key)

(test-equal "the same key spelled with kbd and as a raw event vector"
  (kbd->events "C-x") (keymap-index #(24)))

(test-equal "a key description string and its events agree"
  (kbd->events "C-x C-c") (keymap-index "C-x C-c"))

(test-equal "a bare character is the event its code point names"
  '(97) (keymap-index #\a))
(test-equal "...and so is a character above the control range"
  '(90) (keymap-index #\Z))

;; `keymap-index' is idempotent, which is what lets every reader in the
;; library call it without asking which spelling it was handed.
(test-equal "a key that is already events comes back as itself"
  '(24 3) (keymap-index (keymap-index (kbd "C-x C-c"))))

(test-equal "no key at all" #f (keymap-index '()))
(test-equal "...and a false key" #f (keymap-index #f))

;; A *Lucid event type list* is one event, and it is an element of a key
;; sequence rather than the sequence itself. `(control #\x)' is C-x, whose
;; event is 24 - the code the control column folds to, not a bit.
(test-equal "a Lucid event type list is one event, and it is C-x"
  (list 24)
  (keymap-index (list (list 'control #\x))))
(test-equal "...and it is what event-convert-list answers"
  (list (event-convert-list '(control #\x)))
  (keymap-index (list (list 'control #\x))))

;; Anything else is an error, and not the unspecified value. #t is not a
;; key.
(test-assert "a value that is not a key is an error"
  (guard (e (#t #t))
    (keymap-index #t)
    #f))

;; `reverse-list->keymap-index' joins a *reversed* list of key sequences,
;; which is the shape the modal lookup state keeps its stack in.
(test-equal "joining key sequences"
  (keymap-index (kbd "C-c C-c C-M-x C-g"))
  (keymap-index-append C-c_C-c C-M-x C-g))

(test-equal "a reversed list of one-event sequences"
  C-c_C-c
  (reverse-list->keymap-index
   (list (keymap-index (kbd "C-c"))
         (keymap-index (kbd "C-c")))))

(test-equal "and of a longer one"
  C-M-x
  (reverse-list->keymap-index (list (keymap-index (kbd "C-M-x")))))

(test-assert "no sequences at all is #f"
  (not (reverse-list->keymap-index '())))

;; -------------------------------------------------------------------------------------------------

(define (el:keyboard-quit) "el:keyboard-quit")
(define (el:self-insert-command) "el:self-insert-command")
(define (el:eval-defun) "el:eval-defun")
(define (el:compile) "el:compile")
(define (el:comint-interrupt-subjob) "el:comint-interrupt-subjob")
(define el:left-char "el:left-char")
(define el:left-word "el:left-word")
(define el:local-command "el:local-command")
(define el:global-command "el:global-command")
(define el:find-file "el:find-file")
(define unassigned-key (keymap-index (kbd "C-u RET")))

;; The `=>keymap-layer-index!' lens, over a key spelled anyway `kbd' can
;; write it.
(define kml (lens-set "c" (keymap-layer) (=>keymap-layer-index! '(#\c))))
(test-equal "c" (view kml (=>keymap-layer-index! '(#\c))))

(set! kml (lens-set "x" #f (=>keymap-layer-index! '(#\x))))
(test-equal "x" (view kml (=>keymap-layer-index! '(#\x))))

(set! kml (lens-set #f kml (=>keymap-layer-index! '(#\x))))
(test-assert (not kml))

(set! kml
  (keymap-layer
   (cons C-M-x   el:eval-defun)
   (cons C-c_C-c el:compile)))

(test-assert (keymap-layer-type? kml))
(test-eq el:eval-defun (keymap-layer-lookup kml C-M-x))
(test-eq el:compile (keymap-layer-lookup kml C-c_C-c))
;; ...and the same lookup by a kbd description string, because the lens
;; normalises whatever it is handed.
(test-eq el:compile (keymap-layer-lookup kml "C-c C-c"))

(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      (lambda (_old new) new)
      kml (list (cons C-c_C-c el:comint-interrupt-subjob)))))

(test-eq el:comint-interrupt-subjob (keymap-layer-lookup kml C-c_C-c))
(test-assert (not (keymap-layer-lookup kml C-g)))
(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      prefer-new-bindings kml
      (list (cons C-g el:keyboard-quit)))))

(test-eq el:keyboard-quit (keymap-layer-lookup kml C-g))
(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      prefer-new-bindings kml
      (list (map-key '(#\a) el:self-insert-command)))))
(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      prefer-new-bindings kml
      (list (map-key '(#\b) el:self-insert-command)))))

(test-eq el:self-insert-command (keymap-layer-lookup kml #\a))
(test-eq el:self-insert-command (keymap-layer-lookup kml #\b))

(keymap-layer-update! prefer-new-bindings kml
                      (list (cons C-left-arrow-key el:left-word)))
(keymap-layer-update! prefer-new-bindings kml
                      (list (cons left-arrow-key el:left-char)))
(test-eq el:left-word (keymap-layer-lookup kml C-left-arrow-key))
(test-eq el:left-char (keymap-layer-lookup kml left-arrow-key))

;; A layer's alist is one association per key, and a prefix is flattened
;; into an association for each key under it. The order `hash-table->alist'
;; answers in is not specified, so this asserts the set.
(test-equal "a layer's alist has one entry per binding"
  7 (length (keymap-layer->alist kml)))
(test-assert "a prefix is flattened into the association for the whole key"
  (and (assoc C-c_C-c (keymap-layer->alist kml))
       (not (assoc (keymap-index (kbd "C-c")) (keymap-layer->alist kml)))))
(test-equal "...and its binding is the one under it"
  el:comint-interrupt-subjob
  (cdr (assoc C-c_C-c (keymap-layer->alist kml))))

;; `keymap-lookup-binding-key' is the reverse lookup `[rebind ...]` wants.
(test-equal "a key found by its binding"
  C-M-x (keymap-lookup-binding-key (keymap kml) el:eval-defun))

;; -------------------------------------------------------------------------------------------------
;; Check if keymap-layer-copy really creates a deep copy

(define kml-copy (keymap-layer-copy kml))
(keymap-layer-update!
 prefer-new-bindings kml-copy
 (list
  (cons left-arrow-key "<-")
  (cons C-left-arrow-key "<==<")
  ))
(test-assert el:left-word (keymap-layer-lookup kml C-left-arrow-key))
(test-assert el:left-char (keymap-layer-lookup kml left-arrow-key))
(test-equal "<==<" (keymap-layer-lookup kml-copy C-left-arrow-key))
(test-equal "<-" (keymap-layer-lookup kml-copy left-arrow-key))

;; -------------------------------------------------------------------------------------------------
;; `keymap-index->ascii' stood here, and is gone: it reconstructed an
;; ASCII *string* from an index - prefixing an ESC for a meta bit and
;; subtracting #x40 for a control bit - which is a reader for the private
;; spelling this tree used to keep its keys in. There is no such reader in
;; Emacs and there is no such spelling left here; a key is an *event*, and
;; `keymap-index->events' plus `key-description' render it.

;; -------------------------------------------------------------------------------------------------
;; testing modal-lookup-state-step!

(define (iden id) id)
(define (const-f) #f)

(define ctrl-char     (new-self-insert-keymap-layer #t iden const-f))
(define app-kmp       apply-keymap-index-predicate)
(define unctrl-char   (new-self-insert-keymap-layer #f iden const-f))

;; `key' reads a key the way the tree spells one - a `kbd' string, which
;; is `read-kbd-macro''s own input in Emacs - and answers the events of
;; it, which is what every reader here takes.
(define (key s) (keymap-index (kbd s)))

;; The predicate is applied to the key's *events*, and answers the
;; character the key names. An unmodified key is a character; a key with
;; a modifier on it is not, and a key of more than one event is a prefix
;; and is not either.
(define (cheq? mk-char val kbd-string)
  (let*((expected-result (if (integer? val) (integer->char val) val))
        (predicate-result
         (apply-keymap-index-predicate mk-char (key kbd-string)))
        )
    (char=? predicate-result expected-result)))

(test-assert (cheq? ctrl-char    #\null    "C-@"))
(test-assert (cheq? ctrl-char    #\return  "C-m"))
(test-assert (cheq? ctrl-char    #\tab     "C-i"))
;; --------------------------------------------------
(test-assert (cheq? unctrl-char  #\@  "@"))
(test-assert (cheq? unctrl-char  #\_  "_"))
(test-assert (cheq? unctrl-char  #\M  "M"))
(test-assert (cheq? unctrl-char  #\i  "i"))
;; --------------------------------------------------
(test-assert (cheq? ctrl-char    #\null    "C-@"))
(test-assert (cheq? ctrl-char    #\x1F     "C-_"))
(test-assert (cheq? ctrl-char    #\return  "C-m"))
(test-assert (cheq? ctrl-char    #\tab     "C-i"))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key "C-@"))))
(test-assert (not (app-kmp unctrl-char (key "C-_"))))
(test-assert (not (app-kmp unctrl-char (key "C-m"))))
(test-assert (not (app-kmp unctrl-char (key "C-t"))))
;; --------------------------------------------------
(test-assert (not (app-kmp ctrl-char   (key "M-@"))))
(test-assert (not (app-kmp ctrl-char   (key "M-_"))))
(test-assert (not (app-kmp ctrl-char   (key "M-m"))))
(test-assert (not (app-kmp ctrl-char   (key "M-t"))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key "M-@"))))
(test-assert (not (app-kmp unctrl-char (key "M-_"))))
(test-assert (not (app-kmp unctrl-char (key "M-m"))))
(test-assert (not (app-kmp unctrl-char (key "M-t"))))
;; --------------------------------------------------
(test-assert (not (app-kmp ctrl-char   (key "C-M-@"))))
(test-assert (not (app-kmp ctrl-char   (key "C-M-_"))))
(test-assert (not (app-kmp ctrl-char   (key "C-M-m"))))
(test-assert (not (app-kmp ctrl-char   (key "C-M-t"))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key "C-M-@"))))
(test-assert (not (app-kmp unctrl-char (key "C-M-_"))))
(test-assert (not (app-kmp unctrl-char (key "C-M-m"))))
(test-assert (not (app-kmp unctrl-char (key "C-M-t"))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key "C-M-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "C-M-m C-c"))))
(test-assert (not (app-kmp unctrl-char (key "M-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "M-m C-c"))))
(test-assert (not (app-kmp unctrl-char (key "C-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "C-m C-c"))))
;; --------------------------------------------------

(define km (keymap '*test-keymap kml unctrl-char))

(test-assert (eq? el:self-insert-command (keymap-lookup km '(#\a))))
(test-assert (eq? el:self-insert-command (keymap-lookup km '(#\b))))
(test-assert (eq? el:comint-interrupt-subjob (keymap-lookup km C-c_C-c)))
(test-assert (char=? #\c (keymap-lookup km (keymap-index '(#\c)))))
(test-assert (char=? #\null (keymap-lookup (keymap ctrl-char km) (kbd "C-@"))))
(test-assert (not (keymap-lookup km unassigned-key)))

(test-equal "hello"
  (let ((km (keymap (keymap-layer))))
    ;; Test the =>keymap-top-layer! lens on a keymap with 1 layer
    (lens-set "hello" km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    (view km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    ))

(test-equal "hello"
  (let ((km (keymap)))
    ;; Test the =>keymap-top-layer! lens on a keymap with no layers,
    ;; should be canonical and add a new layer.
    (lens-set "hello" km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    (view km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    ))

;; The two choke points `keymap.c''s `store_in_keymap' and
;; `access_keymap' are, and that they are keyed by ONE event.
(define store-km (keymap '*store*))
(store-in-keymap store-km 24 el:eval-defun)
(test-eq el:eval-defun (access-keymap store-km 24))
(test-assert (not (access-keymap store-km 25)))
(test-assert "a non-event is refused"
  (guard (e (#t #t))
    (access-keymap store-km "C-x")
    #f))

(define modal #f)

(define (reset-modal! kml)
  (set! modal (new-modal-lookup-state km)))

;; The step takes ONE *event* - what `read_key_sequence' reads at a time -
;; and the chord is accumulated in the state. The stack is a list of
;; events, and the key sequence is that reversed.
(define (lookup-modal! key)
  (let*((event (car (keymap-index key)))
        (result #f)
        (keep
         (modal-lookup-state-step!
          modal event
          (lambda (key-index action) ;; do action
            (set! result
              (list
               'action
               (keymap-index->events (force key-index))
               action)))
          (lambda (key-index next-kml) ;; do wait next
            (set! result
              (list
               'waiting
               (keymap-index->events (force key-index)))))
          (lambda (key-index) ;; do fail lookup
            (set! result
              (list 'fail (keymap-index->events key-index)))))))
    (cons keep result)))

(reset-modal! km)

(test-assert (modal-lookup-state-type? modal))
(test-eq el:comint-interrupt-subjob
  (keymap-lookup (modal-lookup-state-keymap modal) C-c_C-c))

(test-assert (keymap-layer-type? (keymap-layer-ref kml (keymap-index (kbd "C-c")))))

(reset-modal! km)

(test-equal '(#t waiting (3))
  (lookup-modal! (kbd "C-c")))

(test-equal (list #f 'action '(3 3) el:comint-interrupt-subjob)
  (lookup-modal! (kbd "C-c")))

(reset-modal! km)

(test-equal (list #f 'action '(7) el:keyboard-quit)
  (lookup-modal! (kbd "C-g")))

(reset-modal! km)

(test-equal (list #f 'action '(97) el:self-insert-command)
  (lookup-modal! '(#\a)))

(reset-modal! km)

(test-equal '(#f fail (17))
  (lookup-modal! (kbd "C-q")))

(reset-modal! km)

(test-equal '(#t waiting (3))
  (lookup-modal! (kbd "C-c")))

(test-equal '(#f fail (3 0))
  (lookup-modal! (kbd "C-@")))

(reset-modal! km)

(test-equal (list #f 'action '(99) #\c)
  (lookup-modal! '(#\c)))

(test-equal '(#f fail (99 99))
  (lookup-modal! '(#\c)))


;;--------------------------------------------------------------------
;; A list of keymaps: what a key sequence is looked up in, in order.
;;
;; GNU Emacs's `read_key_sequence' searches the buffer's local map and
;; then `global-map'. This library's `new-modal-lookup-state' has always
;; documented that it takes "a <keymap-type> argument or a list of
;; <keymap-type> arguments", and until now it took only the one - the
;; callers that passed a list got an error. These are the four things the
;; list has to do, and the first and last of them were measured from a
;; terminal Emacs with `(key-binding ...)' for the same maps.

(test-begin "schemacs_keymap_precedence")

(define (one-key-map name key command)
  (keymap name (keymap-layer (map-key key command))))

(define precedence-local
  (keymap '*prec-local* (keymap-layer (map-key (kbd "C-a") 'local-command))))
(define precedence-global
  (keymap '*prec-global*
          (keymap-layer (map-key (kbd "C-f") 'global-command)
                        (map-key (kbd "C-x C-f") 'find-file))))

(define (lookup-in keymaps kbd-string)
  (let ((r (keymap-lookup
            (modal-lookup-state-keymap (new-modal-lookup-state keymaps))
            (keymap-index (kbd kbd-string)))))
    (if (keymap-type? r) 'keymap r)))

;; a list is accepted at all
(test-equal #t (modal-lookup-state-type?
                (new-modal-lookup-state (list precedence-local precedence-global))))

;; the first keymap that binds the key wins
(test-equal '(local-command global-command)
  (list (lookup-in (list precedence-local precedence-global) "C-a")
        (lookup-in (list precedence-local precedence-global) "C-f")))

;; a key the first keymap does not bind is found in the next
(test-equal 'global-command
  (lookup-in (list (one-key-map '*empty* (kbd "M-z") 'unused)
                   precedence-global)
             "C-f"))

;; and a *prefix* in the first keymap does not stop the next keymap's
;; longer sequence being found: Emacs answers `find-file' for
;; `(key-binding "\C-x\C-f")' when the local map binds C-x as a prefix
;; and nothing under it
(test-equal 'find-file
  (lookup-in (list (keymap '*prec-prefix*
                           (keymap-layer (map-key (kbd "C-x")
                                                  (keymap-layer))))
                   precedence-global)
             "C-x C-f"))

(test-end "schemacs_keymap_precedence")

(test-end "schemacs_keymap")
