(define-library (schemacs editor doc)
  ;; This library mirrors GNU Emacs's `src/doc.c', of which this tree can
  ;; back the two user-facing readers: `documentation' and
  ;; `documentation-property'. The rest of doc.c is the DOC file - the
  ;; dumped table of docstrings a built Emacs reads at run time - which
  ;; has no counterpart here: a docstring lives on its procedure, and a
  ;; variable's lives on the symbol's `variable-documentation' property.
  ;;
  ;; **What `documentation' accepts, and what Emacs's accepts.** Emacs
  ;; takes a function designator - a symbol or a function - and resolves
  ;; it through `Findirect_function' and the obarray. This tree's
  ;; commands are procedures in `*command-table*` under their name
  ;; string, so a symbol is looked up there; a procedure is asked
  ;; directly. `Fdocumentation` runs its answer through
  ;; `substitute-command-keys' unless RAW is given, and so does this.
  ;;
  ;; Named gaps, each because the thing it reads does not exist here:
  ;; the `function-documentation' *function* arm for autoloads and
  ;; macros (Scheme has no `symbol-function' to inspect), C subrs, and
  ;; `Snarf-documentation' / `get_doc_string' (the DOC file).

  (import (scheme base)
          ;; a docstring lives on its procedure here.
          (only (guile) procedure-documentation)
          (only (schemacs editor intervals) get)
          (only (schemacs editor command)
                command-record-named command-procedure command-doc-string)
          (only (schemacs editor help) substitute-command-keys))

  (export documentation documentation-property)

  (begin

    (define (documentation function . rest)
      ;; GNU Emacs's `documentation' (`doc.c:333'): "Return the
      ;; documentation string of FUNCTION. Unless a non-nil second
      ;; argument RAW is given, the string is passed through
      ;; `substitute-command-keys'."
      ;;
      ;; The C's order: a symbol's `function-documentation' property
      ;; first, then the function it resolves to. A symbol that resolves
      ;; to nothing is `void-function'; here it is an error naming the
      ;; symbol, which is the same report with this tree's one error
      ;; condition.
      ;;--------------------------------------------------------------
      (let ((raw (and (pair? rest) (car rest))))
        (let ((doc
               (cond
                ((procedure? function)
                 (procedure-documentation function))
                ((symbol? function)
                 (or (get function 'function-documentation)
                     ;; `define-command` keeps the docstring on the
                     ;; record (`command.scm:983` stores it from the
                     ;; procedure), which is the tree's store for it.
                     ;; A symbol that names nothing is `void-function`,
                     ;; as `Findirect_function` signals.
                     (let ((record (command-record-named function)))
                       (if record
                           (command-doc-string record)
                           (error "Void function" function)))))
                (else (error "Invalid function" function)))))
          (cond
           ((not doc) #f)
           (raw doc)
           (else (substitute-command-keys doc))))))

    (define (documentation-property symbol prop . rest)
      ;; GNU Emacs's `documentation-property' (`doc.c:430'): "Return the
      ;; documentation property PROPERTY of SYMBOL. ... The value is
      ;; passed through `substitute-command-keys' unless a non-nil third
      ;; argument RAW is given."
      ;;--------------------------------------------------------------
      (let ((raw (and (pair? rest) (car rest))))
        (let ((doc (get symbol prop)))
          (if (or raw (not doc))
              doc
              (substitute-command-keys doc)))))))
