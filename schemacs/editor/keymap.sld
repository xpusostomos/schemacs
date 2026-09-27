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
    (only (schemacs lens) update))

  (export
   *current-keymap*
   *default-keymap*
   add-keymap-layer!
   define-key
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

    ))
