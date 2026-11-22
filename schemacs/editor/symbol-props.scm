(define-library (schemacs editor symbol-props)
  ;; `fns.c''s `Fget' and `Fput' - Emacs's symbol property table - in a
  ;; leaf of their own.
  ;;
  ;; **Placement departure, and why the leaf is needed.** Emacs has them
  ;; in `fns.c', and this tree's `fns.scm` is where the mirror rule says
  ;; they go. They cannot: `fns.scm' imports `intervals.scm' (for
  ;; `copy_intervals' and `set_string_intervals'), so `intervals'
  ;; importing `fns' back is a cycle. They lived in `intervals.scm'
  ;; until 2026-11-22, which made `(schemacs editor custom)'
  ;; (`custom.el', which needs them for the `custom-' properties) sit
  ;; above `intervals' and therefore above `buffer-text', `character'
  ;; and `fns'. A C-defined variable in an ancestor of `custom' cannot
  ;; be a `define-custom' - `character.scm''s `tab-width' and
  ;; `fns.scm''s `use-dialog-box' could not - because the library would
  ;; have to import `custom' back. As a leaf, both can, and `custom'
  ;; sits below everything that needs it.
  ;;
  ;; `intervals.scm' imports and re-exports the pair, so every existing
  ;; importer is unchanged; new code should import this library.
  (import
    (scheme base)
    (only (guile) hash-ref hash-set! make-hash-table))
  (export get put)
  (begin
    (define %symbol-properties (make-hash-table))
    ;; ^ Emacs's symbol properties, keyed by `(SYMBOL . PROPERTY)'.
    ;;
    ;; **A plist per symbol in Emacs, one table here**, which is the same
    ;; thing said once: any symbol may be a key and any symbol may be a
    ;; property name, so the pair is what identifies a slot.
    ;;
    ;; **Not Guile's object properties, which look like the right tool
    ;; and are not.** `(symbol-property symbol property)' is what Guile
    ;; offers for this, but its property must be an object made by
    ;; `make-object-property' - a *name* raises - and, worse, **the
    ;; values are held weakly**: measured, `(put 'a 'x (list 1))' then
    ;; `(gc)' with a second property in the table reads back #f.
    ;; Emacs's `put' holds its value for as long as the symbol lives.
    ;; This was found by a `custom-group' that vanished between two reads
    ;; (`custom.scm`'s tests, 2026-10-14); the object-property version is
    ;; gone.
    ;;
    ;; The property name is not `eq?'-hashed on its own: `(cons symbol
    ;; property)' is what a table with the default `equal?' hash takes,
    ;; and `equal?' on two pairs of symbols is what `eq?' on each would
    ;; say.

    (define (get symbol property)
      ;; GNU Emacs's `get': the value of a *symbol* property, or #f when
      ;; there is none. This is not the same thing as a text property -
      ;; it is how a `category' symbol carries the properties its text
      ;; shares.
      ;;--------------------------------------------------------------
      (hash-ref %symbol-properties (cons symbol property)))

    (define (put symbol property value)
      ;; GNU Emacs's `put'. It answers VALUE, as the C does, so that
      ;; `(put ...)' reads as the assignment it is.
      ;;--------------------------------------------------------------
      (hash-set! %symbol-properties (cons symbol property) value)
      value)))
