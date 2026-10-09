;;; pgtk-names.scm -- the guile-gi typelib surface, in a module of its own.
;;;
;;; This is a Guile-native `define-module' rather than an R7RS
;;; `define-library' on purpose: `typelib->module' adds the names it
;;; loads to the module's *public interface*, and an R7RS `export' of
;;; them fails outright. A define-module simply publishes whatever it
;;; ends up holding, which is what a driver wants to `#:select' from.
;;;
;;; It is separate from `pgtk.sld' for a measured reason: a module that
;;; both holds the typelib surface *and* calls the generics segfaults in
;;; guile-gi (the driver crashed at `connect' until the surface was
;;; moved out here). Keeping the surface in its own module is the
;;; arrangement that works.
;;;
;;; Importers must use `only' or `#:select': the surface is thousands of
;;; names, and pulling them in wholesale shadows core bindings.

(define-module (schemacs ui gtk pgtk-names)
  ;; The plain `(gi)' module has to be *loaded* - it initializes the
  ;; girepository runtime, without which typelib->module segfaults - but
  ;; its re-exports of `connect', `equal?', `format', `write', `quit'
  ;; and `shutdown' are hidden, because importing them over the core
  ;; bindings is where the "overrides core binding" warnings at every
  ;; import came from.
  #:use-module ((gi) #:hide (connect equal? format write quit shutdown))
  #:use-module (gi repository)
  #:use-module (gi util)
  #:use-module ((guile) #:select (resolve-module)))

;; GdkPixbuf must be required explicitly: Gdk pulls in its *types*, so a
;; survey looks complete while its functions are missing.
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "Gtk" "3.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "Gdk" "3.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "GLib" "2.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "GdkPixbuf" "2.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "PangoCairo" "1.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "Pango" "1.0")
(typelib->module (resolve-module '(schemacs ui gtk pgtk-names)) "cairo" "1.0")

;; Without these, every typelib generic misresolves and fails with a
;; misleading "Too few \"in\" arguments" error. They are pushed here and
;; again in the driver, because the handler is per-module.
(push-duplicate-handler! 'merge-generics)
(push-duplicate-handler! 'shrug-equals)
