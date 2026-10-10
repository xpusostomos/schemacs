(import
  (scheme base)
  (only (scheme lazy) force)
  (schemacs editor keymap)
  ;; `kbd' is the tree's spelling of a *key* - `(kbd "C-x")' is the event
  ;; vector `#(24)' - and it is `character.sld''s, where the C's
  ;; `make_lispy_event' arithmetic lives. `event-convert-list' is
  ;; `keyboard.c''s consumer of a Lucid event type list.
  (only (schemacs editor character) kbd event-convert-list)
  ;; The modal lookup state is `read_key_sequence''s, so it lives in
  ;; `keyboard.sld' beside the loop that calls it; what is tested here is
  ;; that it walks a map and a *list* of maps the way Emacs does.
  (only (schemacs editor keyboard)
        new-modal-lookup-state modal-lookup-state-type?
        modal-lookup-state-step! modal-lookup-state-key-index
        modal-lookup-state-keymaps)
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

;; -------------------------------------------------------------------------------------------------
;; A keymap is Emacs's: bindings, a *parent*, and the char-table slot.
;;
;; There is no list of "layers" any more. The original author's library kept
;; one, with an `alt-action' field and merge policies; Emacs has no such
;; thing, the two jobs it did are `parent' and the char-table range below,
;; and the third it pretended to do - keep a shorter binding when a longer
;; one is defined under it - is a case `Fdefine_key' *refuses*. See the
;; note on `<keymap-type>' in `editor/keymap.sld'.

(test-assert "a new keymap is empty, and has no parent"
  (let ((m (keymap '*empty*)))
    (and (keymap-type? m)
         (not (keymap-parent m))
         (not (keymap-lookup m (kbd "C-x"))))))

;; `make-sparse-keymap' takes a prompt - a string or a symbol - or one
;; keymap; anything else is refused rather than quietly making a map.
(test-assert "an argument that is neither a prompt nor a keymap is refused"
  (guard (e (#t #t)) (keymap 42) #f))
(test-assert "so is a second argument"
  (guard (e (#t #t)) (keymap '*two* (keymap '*one*)) #f))

;; ------------------------------------------------------------------
;; `store_in_keymap' and `access_keymap' - `keymap.c:730' and `:491', the
;; two functions in Emacs that touch a keymap, both keyed by ONE *event*.

(define store-km (keymap '*store*))
(store-in-keymap store-km 24 el:eval-defun)
(test-eq el:eval-defun (access-keymap store-km 24))
(test-assert (not (access-keymap store-km 25)))
(test-assert "a non-event is refused"
  (guard (e (#t #t))
    (access-keymap store-km "C-x")
    #f))
(test-assert "`keymap' is reserved for an embedded parent map"
  (guard (e (#t #t))
    (store-in-keymap store-km 'keymap el:eval-defun)
    #f))

;; ------------------------------------------------------------------
;; `define-key' and the walk a key sequence needs

(define km (keymap '*test-keymap*))
(define-key km C-c_C-c el:comint-interrupt-subjob)
(define-key km C-M-x el:eval-defun)
(define-key km C-g el:keyboard-quit)

(test-eq el:comint-interrupt-subjob (keymap-lookup km C-c_C-c))
(test-eq el:eval-defun (keymap-lookup km C-M-x))
(test-eq el:keyboard-quit (keymap-lookup km C-g))
(test-assert "an unbound sequence answers #f" (not (keymap-lookup km C-left-arrow-key)))

;; A prefix is a *keymap* in the binding, which is Emacs's submap, and
;; `access_keymap_1' recurses into it. `(kbd "C-c")' is a prefix of
;; `C-c C-c' above and is therefore a keymap rather than a command.
(test-assert "a prefix binding is a keymap"
  (keymap-type? (keymap-lookup km (kbd "C-c"))))
(test-eq "and it reaches what is under it"
  el:comint-interrupt-subjob
  (keymap-lookup km (kbd "C-c C-c")))

;; ------------------------------------------------------------------
;; Every event but the last must already be a prefix
;;
;; `Fdefine_key''s loop (`keymap.c:1196') looks up each event but the last,
;; makes a fresh prefix where there was nothing (`define_as_prefix'), and
;; refuses anything that is not a keymap **by name** -
;;
;;   error ("Key sequence %s starts with non-prefix key %s%s", ...)
;;
;; Without that test the walk went ahead and the store *replaced* the
;; command with a prefix, so a binding was silently destroyed. Every string
;; below is Emacs 31.1's own, measured in `emacs -Q --batch'.

(define (define-key-error keymap keys command)
  ;; The message `define-key' signals, or #f when it signals nothing.
  ;; `guard' and not `with-exception-handler': a handler that *returns*
  ;; re-raises the non-continuable exception, so it looks like it did
  ;; nothing.
  (guard (e ((error-object? e) (error-object-message e))
            (else #f))
    (define-key keymap keys command)
    #f))

(define nonprefix-km (keymap '*nonprefix*))
(define-key nonprefix-km (kbd "C-x") 'some-command)

(test-equal "Key sequence C-x f starts with non-prefix key C-x"
  (define-key-error nonprefix-km (kbd "C-x f") 'other-command))

;; ... and the binding that was there is *still* there: the refused
;; definition changed nothing.
(test-eq 'some-command (keymap-lookup nonprefix-km (kbd "C-x")))

;; A sequence whose events really are prefixes is not an error, and the
;; binding lands.
(define prefix-km (keymap '*prefix*))
(test-assert (not (define-key-error prefix-km (kbd "C-x C-f") el:find-file)))
(test-eq el:find-file (keymap-lookup prefix-km (kbd "C-x C-f")))

;; The name in the message is the whole prefix, not just the offending
;; event: here `C-x' is a prefix and `C-x C-f' is not.
(test-equal "Key sequence C-x C-f g starts with non-prefix key C-x C-f"
  (define-key-error prefix-km (kbd "C-x C-f g") 'g))

;; **A parent's binding does not count** - the C looks up with `noinherit'
;; set - so a child is free to define a sequence the parent has bound to a
;; command, and makes its own prefix for it.
(define child-km  (keymap '*child*))
(define parent-km (keymap '*parent*))
(define-key parent-km (kbd "C-x") 'parent-command)
(set-keymap-parent child-km parent-km)
(test-assert (not (define-key-error child-km (kbd "C-x f") 'child-command)))
(test-eq 'child-command (keymap-lookup child-km (kbd "C-x f")))
;; The parent's own binding is untouched.
(test-eq 'parent-command (keymap-lookup parent-km (kbd "C-x")))

;; ------------------------------------------------------------------
;; The parent chain: a child's binding shadows its parent's, and a key the
;; child leaves unbound is found in the parent. This is the whole of what
;; `define-derived-mode''s `(set-keymap-parent CHILD-map ...)' means.

(define shadow-parent (keymap '*shadow-parent*))
(define-key shadow-parent (kbd "C-a") 'parent-a)
(define-key shadow-parent (kbd "C-b") 'parent-b)
(define shadow-child (keymap '*shadow-child*))
(set-keymap-parent shadow-child shadow-parent)
(define-key shadow-child (kbd "C-a") 'child-a)

(test-eq "an unbound key is found in the parent"
  'parent-b (keymap-lookup shadow-child (kbd "C-b")))
(test-eq "a bound key shadows the parent's"
  'child-a (keymap-lookup shadow-child (kbd "C-a")))
(test-eq "...and the parent's own answer is unchanged"
  'parent-a (keymap-lookup shadow-parent (kbd "C-a")))

(test-assert "a parent that is not a keymap is refused"
  (guard (e (#t #t)) (set-keymap-parent shadow-child 'not-a-keymap) #f))

;; `keymap_memberp' (`keymap.c:263'): a keymap may not become its own
;; ancestor, or a lookup would never end.
(test-assert "cyclic inheritance is refused"
  (guard (e (#t #t))
    (set-keymap-parent shadow-parent shadow-child)
    #f))
(test-assert "and a keymap may not be its own parent"
  (guard (e (#t #t))
    (set-keymap-parent shadow-parent shadow-parent)
    #f))

;; ------------------------------------------------------------------
;; The char-table slot - Emacs's `nth 1', which is where the two *range*
;; bindings live that make an unbound printing character self-insert
;;
;; A char table is the one thing this tree has not ported, so the slot
;; holds a *procedure* whose test is the range. Every expectation below is
;; Emacs 31.1's own answer, measured.

(define sil-command 'self-insert)
(define sil-map (keymap '*sil*))
(set-keymap-char-table! sil-map (self-insert-char-table sil-command))

(define (self-inserting? kbd-string)
  (eq? sil-command (keymap-lookup sil-map (kbd kbd-string))))

;; (`(kbd " ")` is the empty key in Emacs too - a lone space is a
;; separator in a `kbd' string, and `SPC' is how the space key is spelled.)
(test-assert (self-inserting? "SPC"))
(test-assert (self-inserting? "!"))
(test-assert (self-inserting? "@"))
(test-assert (self-inserting? "M"))
(test-assert (self-inserting? "_"))
(test-assert (self-inserting? "~"))
;; ... and so does every character from 128 up - `(cons 128 (max-char))'.
(test-assert (eq? sil-command
                 (keymap-lookup sil-map (keymap-index (list 200)))))
(test-assert (eq? sil-command
                 (keymap-lookup sil-map (keymap-index (list 12354)))))
;; --------------------------------------------------
;; A control character is not a plain character.
(test-assert (not (self-inserting? "C-@")))
(test-assert (not (self-inserting? "C-i")))
(test-assert (not (self-inserting? "C-m")))
(test-assert (not (self-inserting? "C-t")))
(test-assert (not (self-inserting? "C-_")))
;; DEL is not self-inserting either - it is `delete-backward-char'.
(test-assert (not (self-inserting? "DEL")))
;; --------------------------------------------------
;; A modified event is not a plain character, and a char table cannot even
;; be indexed by one.
(test-assert (not (self-inserting? "M-@")))
(test-assert (not (self-inserting? "M-m")))
(test-assert (not (self-inserting? "C-M-@")))
(test-assert (not (self-inserting? "C-M-m")))
;; --------------------------------------------------
;; Neither is a key of more than one event: that is a prefix.
(test-assert (not (self-inserting? "M-m C-c")))
(test-assert (not (self-inserting? "C-m C-c")))
;; --------------------------------------------------
;; **A char table is consulted before the parent**, which is where it sits
;; in the map the C builds - so a *bound* key still wins over it, and a key
;; the map does not bind falls to it rather than to the parent.
(define sil-bound (keymap '*sil-bound*))
(set-keymap-char-table! sil-bound (self-insert-char-table sil-command))
(define-key sil-bound (kbd "q") 'quit-command)
(test-eq "a bound key beats the char table"
  'quit-command (keymap-lookup sil-bound (kbd "q")))
(test-eq "an unbound printing character takes the char table"
  sil-command (keymap-lookup sil-bound (kbd "z")))

;; ------------------------------------------------------------------
;; `key-description' and `single-key-description' - `keymap.c:2092' and
;; `:2307', what the `is undefined' message and M-x's help are written
;; with. Emacs 31.1's own answers, measured.

(test-equal "the description of a chord" "C-x C-c" (key-description (kbd "C-x C-c")))
(test-equal "a control character" "C-a" (key-description (kbd "C-a")))
(test-equal "a named key is bracketed" "<left>" (key-description (kbd "<left>")))
(test-equal "RET and TAB and SPC have names" "RET" (key-description (kbd "RET")))
(test-equal "..." "TAB" (key-description (kbd "TAB")))
(test-equal "..." "SPC" (key-description (kbd "SPC")))
(test-equal "and DEL" "DEL" (key-description (kbd "DEL")))
(test-equal "ESC in a sequence is the *meta* prefix for the next event"
  "M-l" (key-description (vector 27 108)))

;; ------------------------------------------------------------------
;; The reverse lookup `M-x''s help asks for

;; `test-equal' and not `test-eq': the answer is a *fresh* list built by
;; the walk, as Emacs's `where-is-internal' builds a fresh sequence - only
;; its contents are the key.
(test-equal "the key a binding is reached by"
  C-c_C-c (keymap-lookup-binding-key km el:comint-interrupt-subjob))
(test-assert "and #f for one that is not there"
  (not (keymap-lookup-binding-key km 'no-such-command)))

;; -------------------------------------------------------------------------------------------------
;; The modal lookup state - `read_key_sequence''s walk, one event at a time
;;
;; It lives in `keyboard.sld' because it is `keyboard.c''s. A step looks one
;; event up in the state's keymaps, in precedence order; a *keymap* answer
;; means the sequence is a prefix and the next event is looked up in it;
;; anything else is the command and the chord ends.

(define modal #f)

(define (reset-modal! m)
  (set! modal (new-modal-lookup-state m)))

(define (lookup-modal! key)
  (let*((event (car (keymap-index key)))
        (result #f)
        (keep
         (modal-lookup-state-step!
          modal event
          (lambda (key-index action)          ; do action
            (set! result (list 'action (force key-index) action)))
          (lambda (key-index next-km)         ; do wait next
            (set! result (list 'waiting (force key-index))))
          (lambda (key-index)                 ; do fail lookup
            (set! result (list 'fail key-index))))))
    (cons keep result)))

(reset-modal! km)
(test-assert (modal-lookup-state-type? modal))

(reset-modal! km)
(test-equal '(#t waiting (3))
  (lookup-modal! (kbd "C-c")))

(test-equal (list #f 'action '(3 3) el:comint-interrupt-subjob)
  (lookup-modal! (kbd "C-c")))

(reset-modal! km)
(test-equal (list #f 'action (list 134217752) el:eval-defun)
  (lookup-modal! (kbd "C-M-x")))

(reset-modal! km)
(test-equal '(#f fail (17))
  (lookup-modal! (kbd "C-q")))

(reset-modal! km)
;; An undefined sequence ends the chord, and the pending prefix goes with
;; it: `C-c' is a prefix, and `C-c z' names nothing.
(test-equal '(#t waiting (3))
  (lookup-modal! (kbd "C-c")))
(test-equal '(#f fail (3 122))
  (lookup-modal! (kbd "z")))

(test-equal "the key sequence read so far is the stack, in order"
  '(3 122)
  (modal-lookup-state-key-index modal))

;; --------------------------------------------------
;; A *list* of keymaps is a precedence order, which is what the command
;; loop builds from the buffer's own map and then `global-map'.
;;
;; The first map that binds the key wins and one that does not falls
;; through to the next.

(define precedence-local  (keymap '*prec-local*))
(define precedence-global (keymap '*prec-global*))
(define-key precedence-local (kbd "C-a") el:local-command)
(define-key precedence-global (kbd "C-a") el:global-command)
(define-key precedence-global (kbd "C-f") el:global-command)

(test-equal "the first map's binding wins"
  el:local-command
  (keymap-lookup (car (modal-lookup-state-keymaps
                       (new-modal-lookup-state
                        (list precedence-local precedence-global))))
                 (kbd "C-a")))

(reset-modal! (list precedence-local precedence-global))
(test-equal (list #f 'action '(1) el:local-command)
  (lookup-modal! (kbd "C-a")))

(reset-modal! (list precedence-local precedence-global))
(test-equal "a key the first map leaves unbound falls to the second"
  (list #f 'action '(6) el:global-command)
  (lookup-modal! (kbd "C-f")))

(test-assert "a list of keymaps makes a state"
  (modal-lookup-state-type?
   (new-modal-lookup-state (list precedence-local precedence-global))))

(test-assert "no keymap at all is refused"
  (guard (e (#t #t)) (new-modal-lookup-state '()) #f))

(test-end "schemacs_keymap")
