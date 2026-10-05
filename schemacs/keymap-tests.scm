(import
  (scheme base)
  (only (scheme lazy) force)
  (schemacs keymap)
  (only (schemacs lens) view update lens-set)
  (only (schemacs pretty)
        pretty print qstr repeat join-by bracketed
        indent-by newline-indent line-break)
  (schemacs test)
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

(define C-M-x '(ctrl meta #\x))
(define kmix_C-M-x (keymap-index C-M-x))
(define C-c_C-c '(ctrl #\c ctrl #\c))
(define kmix_C-c_C-c (keymap-index C-c_C-c))
(define C-g '(ctrl #\g))
(define kmix_C-g (keymap-index C-g))
(define left-arrow-key '("left"))
(define C-left-arrow-key '(ctrl "left"))
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
(define unassigned-key (keymap-index '(ctrl #\u #\return)))

(define kml (lens-set "c" (keymap-layer) (=>keymap-layer-index! '(#\c))))
(test-equal "c" (view kml (=>keymap-layer-index! '(#\c))))

(test-equal C-c_C-c (string->keymap-index (list->string (map integer->char '(3 3)))))

(set! kml (lens-set "x" #f (=>keymap-layer-index! '(#\x))))
(test-equal "x" (view kml (=>keymap-layer-index! '(#\x))))

(set! kml (lens-set #f kml (=>keymap-layer-index! '(#\x))))
(test-assert (not kml))

(set! kml
  (keymap-layer
   (cons kmix_C-M-x   el:eval-defun)
   (cons kmix_C-c_C-c el:compile)))

(test-equal "(ctrl meta #\\x)" (pretty #f (keymap-index-print kmix_C-M-x)))
(test-equal "(ctrl #\\c ctrl #\\c)" (pretty #f (keymap-index-print kmix_C-c_C-c)))
(test-equal "(\"left\")" (pretty #f (keymap-index-print kmix_left-arrow-key)))
(test-equal
    (string-append
     "(alist->keymap-layer\n"
     "  '((ctrl meta #\\x) #<procedure el:eval-defun ()>)\n"
     "  '((ctrl #\\c ctrl #\\c) #<procedure el:compile ()>))")
  (pretty #f (keymap-layer-print kml))
  )
(test-assert (keymap-layer-type? kml))
(test-assert (keymap-index-type? kmix_C-M-x))
(test-assert (keymap-index-type? kmix_C-c_C-c))
(test-assert (equal? C-M-x (keymap-index->list kmix_C-M-x)))
(test-assert (equal? C-c_C-c (keymap-index->list kmix_C-c_C-c)))
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
;; testing keymap-index->ascii

(test-equal (list->string '(#\esc #\null))
  (keymap-index->ascii (keymap-index '(ctrl meta #\@))))

(test-equal (list->string '(#\null))
  (keymap-index->ascii (keymap-index '(ctrl #\@))))

(test-equal (list->string '(#\a #\b #\c #\newline))
  (keymap-index->ascii (keymap-index '(#\a #\b #\c ctrl #\J))))

(test-equal (list->string '(#\null))
  (keymap-index->ascii (keymap-index '(ctrl #\@))))

;; -------------------------------------------------------------------------------------------------
;; testing modal-lookup-state-step!

(test-equal (keymap-index '(ctrl #\c ctrl #\c ctrl meta #\x ctrl #\g))
  (keymap-index-append kmix_C-c_C-c kmix_C-M-x kmix_C-g))

(test-equal kmix_C-c_C-c
  (reverse-list->keymap-index
   (list (keymap-index '(ctrl #\c))
         (keymap-index '(ctrl #\c)))))

(test-equal kmix_C-M-x
  (reverse-list->keymap-index
   (list (keymap-index '(ctrl meta #\x)))))

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

(define ctrl-alt-bits (bitwise-ior meta-bit ctrl-bit))
(define ctrl-char     (new-self-insert-keymap-layer #t iden const-f))
(define app-kmp       apply-keymap-index-predicate)
(define unctrl-char   (new-self-insert-keymap-layer #f iden const-f))

(define (key . args) (keymap-index args))

(test-equal (list ctrl-alt-bits #\@ #f)
  (let ((kix (key 'ctrl 'meta #\@)))
    (list (mod-index kix) (char-index kix) (next-index kix))
    ))

(test-equal (list ctrl-alt-bits #\M ctrl-bit #\c #f)
  (let*((kix (key 'ctrl 'meta #\M 'ctrl #\c))
        (kix2 (next-index kix))
        )
    (list (mod-index kix) (char-index kix)
          (mod-index kix2) (char-index kix2)
          (next-index kix2))
    ))

(define (cheq? mk-char val . key-index-expr)
  (let*((expected-result (if (integer? val) (integer->char val) val))
        (predicate-result
         (apply-keymap-index-predicate mk-char (keymap-index key-index-expr)))
        )
    (char=? predicate-result expected-result)))

(test-assert (cheq? ctrl-char    #\null    'ctrl  #\@))
;;(test-assert (cheq? ctrl-char    #\space   'ctrl  #\_))
(test-assert (cheq? ctrl-char    #\return  'ctrl  #\M))
(test-assert (cheq? ctrl-char    #\tab     'ctrl  #\i))
;; --------------------------------------------------
(test-assert (cheq? unctrl-char  #\@  #\@))
(test-assert (cheq? unctrl-char  #\_  #\_))
(test-assert (cheq? unctrl-char  #\M  #\M))
(test-assert (cheq? unctrl-char  #\i  #\i))
;; --------------------------------------------------
(test-assert (cheq? ctrl-char    #\null    'ctrl  #\@))
(test-assert (cheq? ctrl-char    #\x1F     'ctrl  #\_))
(test-assert (cheq? ctrl-char    #\return  'ctrl  #\M))
(test-assert (cheq? ctrl-char    #\tab     'ctrl  #\i))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key 'ctrl #\@))))
(test-assert (not (app-kmp unctrl-char (key 'ctrl #\_))))
(test-assert (not (app-kmp unctrl-char (key 'ctrl #\M))))
(test-assert (not (app-kmp unctrl-char (key 'ctrl #\t))))
;; --------------------------------------------------
(test-assert (not (app-kmp ctrl-char   (key 'meta #\@))))
(test-assert (not (app-kmp ctrl-char   (key 'meta #\_))))
(test-assert (not (app-kmp ctrl-char   (key 'meta #\M))))
(test-assert (not (app-kmp ctrl-char   (key 'meta #\t))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key 'meta #\@))))
(test-assert (not (app-kmp unctrl-char (key 'meta #\_))))
(test-assert (not (app-kmp unctrl-char (key 'meta #\M))))
(test-assert (not (app-kmp unctrl-char (key 'meta #\t))))
;; --------------------------------------------------
(test-assert (not (app-kmp ctrl-char   (key  'ctrl 'meta  #\@))))
(test-assert (not (app-kmp ctrl-char   (key  'ctrl 'meta  #\_))))
(test-assert (not (app-kmp ctrl-char   (key  'ctrl 'meta  #\M))))
(test-assert (not (app-kmp ctrl-char   (key  'ctrl 'meta  #\t))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key  'ctrl 'meta  #\@))))
(test-assert (not (app-kmp unctrl-char (key  'ctrl 'meta  #\_))))
(test-assert (not (app-kmp unctrl-char (key  'ctrl 'meta  #\M))))
(test-assert (not (app-kmp unctrl-char (key  'ctrl 'meta  #\t))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key 'ctrl 'meta #\M #\c))))
(test-assert (not (app-kmp ctrl-char   (key 'ctrl 'meta #\M #\c))))
(test-assert (not (app-kmp unctrl-char (key 'meta #\M #\c))))
(test-assert (not (app-kmp ctrl-char   (key 'meta #\M #\c))))
(test-assert (not (app-kmp unctrl-char (key 'ctrl #\M #\c))))
(test-assert (not (app-kmp ctrl-char   (key 'ctrl #\M #\c))))
;; --------------------------------------------------
(test-assert (not (app-kmp unctrl-char (key 'ctrl 'meta #\M 'ctrl #\c))))
(test-assert (not (app-kmp ctrl-char   (key 'ctrl 'meta #\M 'ctrl #\c))))
(test-assert (not (app-kmp unctrl-char (key       'meta #\M 'ctrl #\c))))
(test-assert (not (app-kmp ctrl-char   (key       'meta #\M 'ctrl #\c))))
(test-assert (not (app-kmp unctrl-char (key 'ctrl       #\M 'ctrl #\c))))
(test-assert (not (app-kmp ctrl-char   (key 'ctrl       #\M 'ctrl #\c))))
;; --------------------------------------------------

(define km (keymap '*test-keymap kml unctrl-char))

(test-assert (eq? el:self-insert-command (keymap-lookup km (keymap-index '(#\a)))))
(test-assert (eq? el:self-insert-command (keymap-lookup km (keymap-index '(#\b)))))
(test-assert (eq? el:comint-interrupt-subjob (keymap-lookup km kmix_C-c_C-c)))
(test-assert (char=? #\c (keymap-lookup km (keymap-index '(#\c)))))
(test-assert (char=? #\null (keymap-lookup (keymap ctrl-char km) (keymap-index '(ctrl #\@)))))
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
               (keymap-index->list (force key-index))
               action)))
          (lambda (key-index next-kml) ;; do wait next
            (set! result
              (list
               'waiting
               (keymap-index->list (force key-index)))))
          (lambda (key-index) ;; do fail lookup
            (set! result
              (list 'fail (keymap-index->list key-index)))))))
    (cons keep result)))

(define (show-modal-state-map)
  (pretty (keymap-print (modal-lookup-state-keymap modal)))
  (newline))

(reset-modal! km)

(test-assert (modal-lookup-state-type? modal))
(test-eq el:comint-interrupt-subjob
  (keymap-lookup (modal-lookup-state-keymap modal) kmix_C-c_C-c))

(test-assert (keymap-layer-type? (keymap-layer-ref kml (keymap-index '(ctrl #\c)))))

(reset-modal! km)

(test-equal '(#t waiting (ctrl #\c))
  (lookup-modal! '(ctrl #\c)))

(test-equal (list #f 'action '(ctrl #\c ctrl #\c) el:comint-interrupt-subjob)
  (lookup-modal! '(ctrl #\c)))

(reset-modal! km)

(test-equal (list #f 'action '(ctrl #\g) el:keyboard-quit)
  (lookup-modal! '(ctrl #\g)))

(reset-modal! km)

(test-equal (list #f 'action '(#\a) el:self-insert-command)
  (lookup-modal! '(#\a)))

(reset-modal! km)

(test-equal '(#f fail (ctrl #\q))
  (lookup-modal! '(ctrl #\q)))

(reset-modal! km)

(test-equal '(#t waiting (ctrl #\c))
  (lookup-modal! '(ctrl #\c)))

(test-equal '(#f fail (ctrl #\c ctrl #\space))
  (lookup-modal! '(ctrl #\space)))

(reset-modal! km)

(test-equal '(#f action (#\c) #\c)
  (lookup-modal! '(#\c)))

(test-equal '(#f fail (#\c #\c))
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
  (keymap name (keymap-layer (map-key (list key) command))))

(define precedence-local
  (keymap '*prec-local* (keymap-layer (map-key (list (list 'ctrl #\a)) 'local-command))))
(define precedence-global
  (keymap '*prec-global*
          (keymap-layer (map-key (list (list 'ctrl #\f)) 'global-command)
                        (map-key (list (list 'ctrl #\x) (list 'ctrl #\f)) 'find-file))))

(define (lookup-in keymaps keys)
  (let ((r (keymap-lookup
            (modal-lookup-state-keymap (new-modal-lookup-state keymaps))
            (keymap-index keys))))
    (if (keymap-type? r) 'keymap r)))

;; a list is accepted at all
(test-equal #t (modal-lookup-state-type?
                (new-modal-lookup-state (list precedence-local precedence-global))))

;; the first keymap that binds the key wins
(test-equal '(local-command global-command)
  (list (lookup-in (list precedence-local precedence-global)
                   (list (list 'ctrl #\a)))
        (lookup-in (list precedence-local precedence-global)
                   (list (list 'ctrl #\f)))))

;; a key the first keymap does not bind is found in the next
(test-equal 'global-command
  (lookup-in (list (one-key-map '*empty* (list 'meta #\z) 'unused)
                   precedence-global)
             (list (list 'ctrl #\f))))

;; and a *prefix* in the first keymap does not stop the next keymap's
;; longer sequence being found: Emacs answers `find-file' for
;; `(key-binding "\C-x\C-f")' when the local map binds C-x as a prefix
;; and nothing under it
(test-equal 'find-file
  (lookup-in (list (keymap '*prec-prefix*
                           (keymap-layer (map-key (list (list 'ctrl #\x))
                                                  (keymap-layer))))
                   precedence-global)
             (list (list 'ctrl #\x) (list 'ctrl #\f))))

(test-end "schemacs_keymap_precedence")

(test-end "schemacs_keymap")
