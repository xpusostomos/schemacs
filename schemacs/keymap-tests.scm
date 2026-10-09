(import
  (scheme base)
  (only (scheme lazy) force)
  (schemacs keymap)
  (only (schemacs lens) view update lens-set)
  ;; `kbd' is the tree's spelling of a *key* - `(kbd "C-x")' is the event
  ;; vector `#(24)' - and it is `character.sld''s, where the C's
  ;; `make_lispy_event' arithmetic lives.
  (only (schemacs editor character) kbd char-meta char-ctl char-shift)
  (only (srfi 64) test-begin test-end test-skip test-error
        test-assert test-equal test-eqv test-eq)
  (schemacs hash-table)
  )

(cond-expand
  (guile
   ;; This conditional clause exists because the (library (srfi 60))
   ;; condition causes a bug in Guile.
   (import
     (only (srfi 60) ; Integers as Bits
           bitwise-ior
           bitwise-and))
   )
  (gambit
   ;; do nothing: Gambit provides the SRFI-60 APIs
   ;; but not the (SRFI 60) library.
   )
  ((library (srfi 60))
   (import
     (only (srfi 60) ; Integers as Bits
           bitwise-ior
           bitwise-and)))
  ((library (srfi 151))
   (import
     (only (srfi 151) ; Integers as Bits
           bitwise-ior
           bitwise-and)))
  (else
   (error "SRFI-60 bitwise operators are not provided"))
  )

(test-begin "schemacs_keymap")

(define empty-kt (char-table '()))
(test-assert (not empty-kt))
(test-assert (not (char-table-type? empty-kt))) ;; should be #f, not an empty table
(test-assert (char-table-empty? empty-kt))

(define kt
  (char-table
   '((#\a . "A")
     (#\b . "B")
     (#\c . "C"))))

(test-assert (char-table-type? kt))
(test-assert (not (char-table-empty? kt)))

(test-assert (equal? "A" (char-table-view kt #\a)))
(test-assert (equal? "B" (char-table-view kt #\b)))
(test-assert (equal? "C" (char-table-view kt #\c)))

(char-table-set! #t "D" kt #\d)
(test-equal "D" (char-table-view kt #\d))

(char-table-set! #t "AAA" kt #\a)
(test-equal "AAA" (char-table-view kt #\a))

(char-table-set! #f "zzz" kt #\Z)
(test-equal "zzz" (char-table-view kt #\Z))

(test-assert (not (char-table-view kt #\X)))
(test-assert (not (char-table-view kt #\null)))

(char-table-update! (lambda (_) (values "[Z]" #f)) kt #\Z)
(test-equal "[Z]" (char-table-view kt #\Z))

(char-table-update! (lambda (_) (values #f #f)) kt #\Z)
(test-assert (not (char-table-view kt #\Z)))

(update (lambda (_) (values "X" #f)) kt (=>char-table-char! #t #\x))
(test-equal "X" (view kt (=>char-table-char! #t #\x)))

;; Test if char tables are canonical, i.e. you can assign to #f to
;; create a char table, and a char table becomes #f when they become empty.

(define kt1 (lens-set "Y" #f (=>char-table-char! #t #\y)))
(test-equal "Y" (view kt1 (=>char-table-char! #t #\y)))

(set! kt1 (lens-set #f kt1 (=>char-table-char! #t #\y)))
(test-assert (not kt1))

;; -------------------------------------------------------------------------------------------------

;; **A key is written with `kbd', and never as a list of modifier
;; symbols.** In GNU Emacs a key is a *string or a vector of events* -
;; `(kbd "C-x C-c")' is `#(24 3)' - and an event is an integer carrying
;; its own modifier bits, or a symbol naming a key that is not a
;; character (`left', `f10'). A modifier *name* is allowed in exactly one
;; place: the Lucid event type list `(control ?x)', which `keymap-index'
;; routes through `event-convert-list' (`keyboard.c:7832') as
;; `Fdefine_key' does (`keymap.c:1156'). A bare list of *modifier symbols*
;; is not a key in Emacs at all, and is what this tree was purged of; the
;; same sequence of *events* `(kbd ...)' answers with is what
;; `keymap-index->events' reads back, so the two are compared directly.
(define (kbd->events s) (vector->list (kbd s)))
(define C-M-x (kbd->events "C-M-x"))
(define kmix_C-M-x (keymap-index C-M-x))
(define C-c_C-c (kbd->events "C-c C-c"))
(define kmix_C-c_C-c (keymap-index C-c_C-c))
(define C-g (kbd->events "C-g"))
(define kmix_C-g (keymap-index C-g))
(define left-arrow-key (kbd->events "<left>"))
(define C-left-arrow-key (kbd->events "C-<left>"))
(define kmix_C-left-arrow-key (keymap-index C-left-arrow-key))
(define kmix_left-arrow-key   (keymap-index left-arrow-key))

(define (el:keyboard-quit) "el:keyboard-quit")
(define (el:self-insert-command) "el:self-insert-command")
(define (el:eval-defun) "el:eval-defun")
(define (el:compile) "el:compile")
(define (el:comint-interrupt-subjob) "el:comint-interrupt-subjob")
(define el:left-char "el:left-char")
(define el:left-word "el:left-word")
(define el:minibuffer-cancel "el:minibuffer-cancel")
(define unassigned-key (keymap-index (kbd "C-u RET")))

(define kml (lens-set "c" (keymap-layer) (=>keymap-layer-index! '(#\c))))
(test-equal "c" (view kml (=>keymap-layer-index! '(#\c))))

;; A key may be spelled as the *string* `(kbd ...)' reads - `read-kbd-macro'
;; is what Emacs's `define-key' takes such a string through - and that is
;; the string branch of `keymap-index'. The library's own string parser,
;; which built a modifier-symbol list by hand, was deleted in the purge;
;; `kbd' is the one parser and this is the one seam.
(test-equal kmix_C-c_C-c (keymap-index "C-c C-c"))

(set! kml (lens-set "x" #f (=>keymap-layer-index! '(#\x))))
(test-equal "x" (view kml (=>keymap-layer-index! '(#\x))))

(set! kml (lens-set #f kml (=>keymap-layer-index! '(#\x))))
(test-assert (not kml))

(set! kml
  (keymap-layer
   (cons kmix_C-M-x   el:eval-defun)
   (cons kmix_C-c_C-c el:compile)))

(test-assert (keymap-layer-type? kml))
(test-assert (keymap-index-type? kmix_C-M-x))
(test-assert (keymap-index-type? kmix_C-c_C-c))
(test-assert (equal? C-M-x (keymap-index->events kmix_C-M-x)))
(test-assert (equal? C-c_C-c (keymap-index->events kmix_C-c_C-c)))
(test-eq el:eval-defun (keymap-layer-lookup kml kmix_C-M-x))
(test-eq el:compile (keymap-layer-lookup kml kmix_C-c_C-c))
(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      (lambda (_old new) new)
      kml (list (cons kmix_C-c_C-c el:comint-interrupt-subjob)))))

(test-eq el:comint-interrupt-subjob (keymap-layer-lookup kml kmix_C-c_C-c))
(test-assert (not (keymap-layer-lookup kml kmix_C-g)))
(test-assert
    (keymap-layer-type?
     (keymap-layer-update!
      prefer-new-bindings kml
      (list (cons kmix_C-g el:keyboard-quit)))))

(test-eq el:keyboard-quit (keymap-layer-lookup kml kmix_C-g))
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

(test-eq el:self-insert-command (keymap-layer-lookup kml (keymap-index '(#\a))))
(test-eq el:self-insert-command (keymap-layer-lookup kml (keymap-index '(#\b))))

(keymap-layer-update! prefer-new-bindings kml
                      (list (cons kmix_C-left-arrow-key el:left-word)))
(keymap-layer-update! prefer-new-bindings kml
                      (list (cons kmix_left-arrow-key el:left-char)))
(test-eq el:left-word (keymap-layer-lookup kml kmix_C-left-arrow-key))
(test-eq el:left-char (keymap-layer-lookup kml kmix_left-arrow-key))

;; -------------------------------------------------------------------------------------------------
;; Check if keymap-layer-copy really creates a deep copy

(define kml-copy (keymap-layer-copy kml))
(keymap-layer-update!
 prefer-new-bindings kml-copy
 (list
  (cons kmix_left-arrow-key "<-")
  (cons kmix_C-left-arrow-key "<==<")
  ))
(test-assert el:left-word (keymap-layer-lookup kml kmix_C-left-arrow-key))
(test-assert el:left-char (keymap-layer-lookup kml kmix_left-arrow-key))
(test-equal "<==<" (keymap-layer-lookup kml-copy kmix_C-left-arrow-key))
(test-equal "<-" (keymap-layer-lookup kml-copy kmix_left-arrow-key))

;; -------------------------------------------------------------------------------------------------
;; `keymap-index->ascii' stood here, and is gone: it reconstructed an
;; ASCII *string* from an index - prefixing an ESC for a meta bit and
;; subtracting #x40 for a control bit - which is a reader for the private
;; spelling this tree used to keep its keys in. There is no such reader in
;; Emacs and there is no such spelling left here; a key is an *event*, and
;; `keymap-index->events' plus `key-description' render it.

;; -------------------------------------------------------------------------------------------------
;; testing modal-lookup-state-step!

(test-equal (keymap-index (kbd "C-c C-c C-M-x C-g"))
  (keymap-index-append kmix_C-c_C-c kmix_C-M-x kmix_C-g))

(test-equal kmix_C-c_C-c
  (reverse-list->keymap-index
   (list (keymap-index (kbd "C-c"))
         (keymap-index (kbd "C-c")))))

(test-equal kmix_C-M-x
  (reverse-list->keymap-index
   (list (keymap-index (kbd "C-M-x")))))

(test-assert (not (reverse-list->keymap-index '())))

(set! kml
  (keymap-layer
   (cons kmix_C-M-x   el:eval-defun)
   (cons kmix_C-c_C-c el:compile)))

(keymap-layer-update!
 (lambda (_old new) new)
 kml (list (cons kmix_C-c_C-c el:comint-interrupt-subjob)))

(keymap-layer-update!
 prefer-new-bindings kml
 (list (cons kmix_C-g el:keyboard-quit)))

(keymap-layer-update!
 prefer-new-bindings kml
 (list (map-key '(#\a) el:self-insert-command)))

(keymap-layer-update!
 prefer-new-bindings kml
 (list (map-key '(#\b) el:self-insert-command)))

(define (iden id) id)
(define (const-f) #f)

(define ctrl-char     (new-self-insert-keymap-layer #t iden const-f))
(define app-kmp       apply-keymap-index-predicate)
(define unctrl-char   (new-self-insert-keymap-layer #f iden const-f))

;; `key' reads a key the way the tree spells one - a `kbd' string, which
;; is `read-kbd-macro''s own input in Emacs - and answers the index
;; `keymap-index' makes of it. It used to take varargs of modifier
;; symbols and characters, which is the vocabulary this tree was purged of.
(define (key s) (keymap-index (kbd s)))

;; **The two fields are the event's own split.** `mod-index' is the
;; `CHAR_*' bits the event carries - and only those, so `C-M-@' has meta
;; and no control bit, because the *code* 0 is what says control for that
;; key - and `char-index' is the code below the bits, as a character.
;; What stood here was a *folded* reading: control was unfolded
;; (`C-x' became the letter `x') and the letter downcased, which is
;; exactly what made the index lossy.
(test-equal (list char-meta #\nul #f)
  (let ((kix (key "C-M-@")))
    (list (mod-index kix) (char-index kix) (next-index kix))
    ))

(test-equal (list char-meta #\return 0 (integer->char 3) #f)
  (let*((kix (key "C-M-m C-c"))
        (kix2 (next-index kix))
        )
    (list (mod-index kix) (char-index kix)
          (mod-index kix2) (char-index kix2)
          (next-index kix2))
    ))

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
(test-assert (not (app-kmp unctrl-char (key "C-M-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "C-M-m C-c"))))
(test-assert (not (app-kmp unctrl-char (key "M-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "M-m C-c"))))
(test-assert (not (app-kmp unctrl-char (key "C-m C-c"))))
(test-assert (not (app-kmp ctrl-char   (key "C-m C-c"))))
;; --------------------------------------------------

(define km (keymap '*test-keymap kml unctrl-char))

(test-assert (eq? el:self-insert-command (keymap-lookup km (keymap-index '(#\a)))))
(test-assert (eq? el:self-insert-command (keymap-lookup km (keymap-index '(#\b)))))
(test-assert (eq? el:comint-interrupt-subjob (keymap-lookup km kmix_C-c_C-c)))
(test-assert (char=? #\c (keymap-lookup km (keymap-index '(#\c)))))
(test-assert (char=? #\null (keymap-lookup (keymap ctrl-char km) (keymap-index (kbd "C-@")))))
(test-assert (not (keymap-lookup km unassigned-key)))

(test-equal "hello"
  (let ((km (keymap (keymap-layer))))
    ;; Test the =>keymap-top-layer! lens on a keymap with 1 layer
    (lens-set "hello" km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    (view km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    ))

(test-equal "hello"
  (let ((km (keymap)))
    ;; Test the =>keymap-top-layer! lens on a keymap with 1 no layers,
    ;; should be canonical and add a new layer.
    (lens-set "hello" km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    (view km =>keymap-top-layer! (=>keymap-layer-index! C-c_C-c))
    ))

(define modal #f)

(define (reset-modal! kml)
  (set! modal (new-modal-lookup-state km)))

(define (lookup-modal! key-index)
    (let*((key-index
           (if (keymap-index-type? key-index)
               key-index
               (keymap-index key-index)))
        (result #f)
        (keep
         (modal-lookup-state-step!
          modal key-index
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
  (keymap-lookup (modal-lookup-state-keymap modal) kmix_C-c_C-c))

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

;; A bare *character* is an event, and it is the event its code point
;; names: GNU Emacs has no character type, so `?a` there is 97 and `#\a`
;; here is the same key. It used to fall off the end of `keymap-index`'s
;; `cond` and come back as the unspecified value, which is true in
;; Scheme - see that function's final `else`.
(test-equal "a bare character is the event its code point names"
  (list 97)
  (keymap-index->events (keymap-index #\a)))

(test-equal "...and so is a character above the control range"
  (list 90) (keymap-index->events (keymap-index #\Z)))

;; **`(kbd ...)` is the spelling to compare against**, and never a
;; hand-written list of modifier symbols: a key in this tree is `kbd`'s
;; event vector - `(kbd "C-x")` is `#(24)`, which is exactly what the C's
;; `buf.code = cbuf[i]` produces - and `keymap-index` walks the vector
;; itself. Writing the key out by hand as a symbol list is how a test
;; comes to assert on the keymap library's *private* representation
;; instead of on the key, and the two spellings of one character - as a
;; character and as a bare symbol - print identically under `test-equal`
;; (which is `equal?`), which is a mistake that has already been made once
;; in this file's tests.
;;
;; So each of these says what a *key* is and that the index agrees, with
;; no modifier-symbol list anywhere.
(test-equal "the same key spelled with kbd and with the raw event"
  (keymap-index->events (keymap-index (kbd "C-x")))
  (keymap-index->events (keymap-index 24)))

(test-equal "a character and its kbd spelling are one key"
  (keymap-index->events (keymap-index (kbd "a")))
  (keymap-index->events (keymap-index #\a)))

(test-equal "and a chord is the two events of its kbd spelling"
  (keymap-index->events (keymap-index (kbd "C-x C-c")))
  (append (keymap-index->events (keymap-index (kbd "C-x")))
          (keymap-index->events (keymap-index (kbd "C-c")))))

;; **Anything else is an error, and not the unspecified value.** #t is
;; not a key.
(test-assert "a value that is not a key is an error"
  (guard (e (#t #t))
    (keymap-index #t)
    #f))

(test-end "schemacs_keymap")
