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
    (prefix (schemacs keymap) km:)
    ;; `keymap-parent' and `set-keymap-parent' are keymap.c's; this
    ;; library states them beside the keys, as it does `define-key'.
    (only (schemacs keymap) keymap-parent set-keymap-parent)
    (only (schemacs lens) update)
    )

  (export
   single-key-description
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

    (define (define-key keymap key-path command)
      ;; Bind KEY-PATH to COMMAND in KEYMAP: GNU Emacs's `define-key'. The
      ;; binding goes into the keymap's top layer, which is the one a lookup
      ;; tries first, so a definition here shadows one in a layer below it.
      ;;
      ;; KEY-PATH is a list of keys, each either a character or a list of a
      ;; modifier and a character - `(ctrl #\x)' then `#\f' for C-x C-f -
      ;; which is the form `KM:MAP-KEY' takes.
      ;;--------------------------------------------------------------
      (update (lambda (layer)
                (values
                 (km:keymap-layer-update!
                  km:prefer-new-bindings layer
                  (list (km:map-key key-path command)))
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
      ;; GNU Emacs's `single-key-description' (`keymap.c:2307'), which
      ;; for a character event is `push_key_description'
      ;; (`keymap.c:2192'): "Control characters turn into C-whatever,
      ;; etc." - 9 is `TAB', 13 `RET', 27 `ESC', 32 `SPC', 127 `DEL',
      ;; the other controls `C-' with the letter the 0140 offset makes
      ;; of them, and a printing character is itself. What
      ;; `what-cursor-position' shows the character after point as.
      ;;
      ;; Only the character branch of the C is here: function keys and
      ;; event symbols are strings in a key path here, and `text-char-
      ;; description' - its octal-and-backslashes spelling - is not.
      ;;--------------------------------------------------------------
      (let ((c (char->integer key)))
        (cond
         ((= c 27) "ESC")
         ((= c 9) "TAB")
         ((= c 13) "RET")
         ((= c 127) "DEL")
         ((= c 32) "SPC")
         ((< c 32)
          (string "C-" (integer->char
                        (if (and (> c 0) (<= c 26)) (+ c 96) (+ c 64)))))
         ((< c 128) (string key))
         (else (string key)))))
    ))
