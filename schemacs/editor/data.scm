(define-library (schemacs editor data)
  ;; This library mirrors GNU Emacs's `src/data.c', of which the piece
  ;; the mode machinery needs is `make-local-variable'.
  ;;
  ;; One thing about the model here has to be said, because it is what
  ;; the function means in this tree: Emacs keeps a *default* value for
  ;; a variable beside the buffer-local one, and `make-local-variable'
  ;; copies the default into the buffer so that later changes to the
  ;; default stop reaching it. A buffer's slots here hold only the local
  ;; values, and the default is the caller's - `buffer-local-value'
  ;; takes it as its third argument. So "the value it previously had" is
  ;; the default the caller names, and that is what is copied in.

  (import
    (scheme base)
    ;; The global value table is a Guile hash table, as the coding system
    ;; registry is - `hashq-get-handle` is the one that tells a stored
    ;; nil from an absent entry, which `hashq-ref` cannot.
    (only (guile) hashq-get-handle hashq-set! make-hash-table)
    (only (schemacs editor buffer)
          buffer-local-value set-buffer-local-value! current-buffer)
    )

  (export
   make-local-variable
   default-value set-default default-boundp
   keywordp
   )

  (begin

    (define (keywordp object)
      ;; GNU Emacs's `keywordp' (`data.c:207'): "Return t if OBJECT is a
      ;; keyword. Keywords are symbols whose names start with `:' and do
      ;; not start with `::'."
      ;;
      ;; **This is how the tree spells `:version', `:type' and the other
      ;; keywords `define-icon' and `define-custom' read as data** - a
      ;; Scheme symbol whose name starts with a colon.
      ;;--------------------------------------------------------------
      (and (symbol? object)
           (let ((name (symbol->string object)))
             (and (> (string-length name) 1)
                  (char=? #\: (string-ref name 0))
                  (not (char=? #\: (string-ref name 1)))))))

    (define (make-local-variable key . args)
      ;; GNU Emacs's `make-local-variable' (`data.c':2245): "Make
      ;; VARIABLE have a separate value in the current buffer. Other
      ;; buffers will continue to share a common default value. (The
      ;; buffer-local value of VARIABLE starts out as the same value
      ;; VARIABLE previously had.) ... Return VARIABLE."
      ;;
      ;; KEY is the variable - a symbol for a ported Elisp variable, as
      ;; everything else in this tree's buffer-local store is. The
      ;; optional argument after it is the default to copy in, and the
      ;; one after that the buffer, which is the current one by default.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) #f))
             (buffer (if (and (pair? args) (pair? (cdr args)))
                         (cadr args)
                         (current-buffer))))
        (set-buffer-local-value! buffer key
                                 (buffer-local-value buffer key default))
        key))

    (define *default-values* (make-hash-table 64))
    ;; ^ The global value of every variable a ported Elisp gives one - GNU
    ;; Emacs's symbol value cell, as much of it as a tree with no obarray
    ;; can have. A *symbol* keys it, because that is what Emacs's `setq`
    ;; on an undeclared variable keys the same cell by, and the
    ;; process-global table is a plain define by the convention (a
    ;; registry, not a dynamically bound value).
    ;;
    ;; It exists because a *global* minor mode's variable is not
    ;; per-buffer: `define-minor-mode`'s `:global` sets the default and
    ;; reads `default-value`, which is what tells one shared value from
    ;; a slot in each buffer's own table (`buffer-local-value`).

    (define (default-value symbol . args)
      ;; GNU Emacs's `default-value` (`data.c:2198`): "Return the default
      ;; value of SYMBOL. This is the value that is seen in buffers that
      ;; do not have their own values for this variable."
      ;;
      ;; **The optional argument is this tree's**, and it is the same one
      ;; `buffer-local-value` takes: the answer for a symbol that has no
      ;; default yet. Emacs signals `void-variable` there, which needs a
      ;; variable registry to name the symbol in the message; a caller
      ;; that has a default to offer - which is every caller here - gets
      ;; it, and the difference is named rather than faked.
      ;;--------------------------------------------------------------
      (let ((entry (hashq-get-handle *default-values* symbol)))
        (cond (entry (cdr entry))
              ((pair? args) (car args))
              (else #f))))

    (define (set-default symbol value)
      ;; GNU Emacs's `set-default` (`data.c:2213`): "Set the default
      ;; value of SYMBOL to be VALUE. ... This is the value seen in
      ;; buffers that do not have their own values for this variable."
      ;; It answers VALUE.
      ;;
      ;; A buffer's own value is left alone, as the C leaves it - the
      ;; default is what a buffer without a local value reads
      ;; (`buffer-local-value`'s third argument, at every call site).
      ;;--------------------------------------------------------------
      (hashq-set! *default-values* symbol value))

    (define (default-boundp symbol)
      ;; GNU Emacs's `default-boundp` (`data.c:2232`): "Return t if
      ;; SYMBOL has a non-void default value. ... A variable may have a
      ;; buffer-local value in a buffer, and a different default value."
      ;;--------------------------------------------------------------
      (and (hashq-get-handle *default-values* symbol) #t))

    ))