(define-library (schemacs editor keymap)
  ;; This library mirrors GNU Emacs's `keymap.c': the global keymap and how
  ;; a binding goes into it. It is a leaf - it knows no commands at all.
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
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (only (guile) string-join logand logior lognot)
    ;; The event model: the modifier bits `push-key-description' tests,
    ;; and `event-convert-list' for the Lucid form `single-key-description'
    ;; converts first. `kbd' is the reader `key-description' takes a
    ;; *string* key through, as `read-kbd-macro' does in Emacs.
    (only (schemacs editor character)
          char-alt char-ctl char-hyper char-meta char-shift char-super
          event-convert-list kbd)
    (prefix (schemacs keymap) km:)
    ;; `keymap-parent' and `set-keymap-parent' are keymap.c's; this
    ;; library states them beside the keys, as it does `define-key'.
    (only (schemacs keymap) keymap-parent set-keymap-parent)
    (only (schemacs lens) update)
    )

  (export
   single-key-description key-description
   *current-keymap*
   *default-keymap*
   *special-event-map*
   add-keymap-layer!
   define-key
   keymap-parent
   set-keymap-parent
   )

  (begin

    (define *default-keymap*
      ;; GNU Emacs's `global-map': the keymap every buffer's local map
      ;; inherits from, and the one the command loop looks in when a buffer
      ;; has no local map of its own. It starts empty and the libraries that
      ;; define commands fill it, which is what `(define-key global-map ...)`
      ;; does in every Emacs Lisp file that binds a key.
      ;;--------------------------------------------------------------
      (km:keymap '*default-keymap*))

    (define *special-event-map* (km:keymap '*special-event-map*))
    ;; ^ GNU Emacs's `special-event-map', which `keyboard.c:14153' declares
    ;; and `keyboard.c:3113' consults *before* the ordinary lookup: the
    ;; keymap the window system's events are looked up in. `keyboard.c'
    ;; binds the named keys there - `delete-frame' to `handle-delete-frame'
    ;; (`keyboard.c:14550') and `focus-in'/`focus-out' to their handlers
    ;; (`keyboard.c:14620') - and the libraries that own those commands make
    ;; the bindings, as they do for every other key. It is beside
    ;; `*default-keymap*' - which Emacs also creates in `keymap.c', and
    ;; which this tree put in this leaf for the same reason: the libraries
    ;; that own the commands bind into it and cannot import the command
    ;; loop.

    (define *current-keymap*
      ;; The keymap the command loop looks in: GNU Emacs's current local
      ;; map. A minibuffer `parameterize`s it to its own, and so would any
      ;; other mode that wants its own bindings; when it is false the global
      ;; map is used.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (define-key keymap keys command)
      ;; Bind KEYS to COMMAND in KEYMAP: GNU Emacs's `define-key'. The
      ;; binding goes into the keymap's top layer, which is the one a lookup
      ;; tries first, so a definition here shadows one in a layer below it.
      ;;
      ;; KEYS is a *key sequence* - what `(kbd "C-x C-f")' answers with,
      ;; a vector of events, which is what Emacs's `define-key' takes
      ;; ("a string or a vector of symbols and characters,
      ;; representing a sequence of keystrokes and events",
      ;; `keymap.c':1084'). The tree's own spelling, a list of modifier
      ;; symbols and characters, still converts too.
      ;;--------------------------------------------------------------
      (update (lambda (layer)
                (values
                 (km:keymap-layer-update!
                  km:prefer-new-bindings layer
                  (list (km:map-key keys command)))
                 #f))
              keymap km:=>keymap-top-layer!)
      command)

    (define (add-keymap-layer! keymap layer)
      ;; Put LAYER at the *end* of KEYMAP's layers, where a lookup reaches it
      ;; only when no layer above it matched. It is for a keymap's fallback:
      ;; the global map's catch-all layer, which gives an unbound printing
      ;; character `self-insert-command'. GNU Emacs's equivalent is the
      ;; fallback in `keyboard.c' that runs `self-insert-command' for a
      ;; self-inserting character with no binding of its own.
      ;;--------------------------------------------------------------
      (update (lambda (layers) (values (append layers (list layer)) #f))
              keymap km:=>keymap-layers*!)
      keymap)


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
      ;; is why the keymap had to print its keys itself, as the private
      ;; `(ctrl #\\x)' list.
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
