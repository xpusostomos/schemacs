(define-library (schemacs json)
  ;; GNU Emacs's `lisp/json.el', the **read** half only: `json-read',
  ;; `json-read-from-string', `json-read-file' and the four variables
  ;; that say what shape the answer takes.
  ;;
  ;; **The parser is Guile's `(json)`** - `json-string->scm' - which is
  ;; the "integrate core guile functions" rule: json.el's tokenizer,
  ;; its readtable and its `json--` helpers are the part of the file a
  ;; host library replaces without changing the answer. What is ported
  ;; is Emacs's *data shape*, which is not the same as Guile's:
  ;;
  ;;   * an object is an alist whose keys are symbols (Emacs's
  ;;     `json-object-type' `alist' with `json-key-type' nil);
  ;;   * an array is a vector (`json-array-type' `vector');
  ;;   * `true' is `t', `false' is `:json-false', `null' is nil;
  ;;   * strings and numbers are themselves.
  ;;
  ;; Guile answers objects with *string* keys, `false' as #f and
  ;; `null' as `#nil' (the empty list), so every value is walked once.
  ;;
  ;; Not carried: the encoder (`json-encode' and the whole `json--print'
  ;; family), `json-object-type'/`json-array-type' other than
  ;; `alist'/`vector', `json-key-type' other than nil/symbol, the
  ;; `json-pre-element-read-function'/`json-post-element-read-function'
  ;; hooks, `json-parse-string'/`json-parse-buffer' (they are C in
  ;; Emacs 30+), `json-sexp', `json-readtable' and the
  ;; `json-error'-condition family (Guile's parser signals its own).
  ;;------------------------------------------------------------
  (import (scheme base)
          (only (json) json-string->scm)
          (only (guile) string->symbol list->vector)
          (only (schemacs editfns) buffer-string goto-char point-max)
          (only (schemacs files) insert-file-contents)
          (only (schemacs subr) with-temp-buffer))

  (export json-false json-null json-array-type json-object-type json-key-type
          json-read json-read-from-string json-read-file)

  (begin

    (define json-false ':json-false)
    ;; ^ GNU Emacs's `json-false' (`json.el:64'): "Value to use for JSON
    ;; false. It is a symbol so that it is distinct from nil (which is
    ;; used for JSON null)."

    (define json-null #f)
    ;; ^ GNU Emacs's `json-null' (`json.el:69'): "Value to use for JSON
    ;; null." Emacs's value is nil; this tree's nil is #f.

    (define json-array-type 'vector)
    ;; ^ GNU Emacs's `json-array-type' (`json.el:79'): "Type to convert
    ;; JSON arrays to. Must be one of `vector' or `list'."

    (define json-object-type 'alist)
    ;; ^ GNU Emacs's `json-object-type' (`json.el:93'): "Type to convert
    ;; JSON objects to."

    (define json-key-type #f)
    ;; ^ GNU Emacs's `json-key-type' (`json.el:84'): "Type to convert
    ;; JSON keys to. Must be one of `string', `symbol', `keyword', or
    ;; nil." Nil means symbols for the alist object type, which is what
    ;; `auth-source-json-search' needs.

    (define (%json-convert value)
      ;; One value from Guile's shape to Emacs's.
      ;;--------------------------------------------------------------
      (cond
       ;; Guile's `null' is `#nil' - the empty list, which is also what
       ;; its parser answers for `{}' (an empty object is an empty
       ;; alist). Emacs answers nil for both, so the two need no
       ;; distinction.
       ((null? value) json-null)
       ((eq? value #f) json-false)
       ((eq? value #t) #t)
       ((vector? value)
        (let ((converted (map %json-convert (vector->list value))))
          (if (eq? json-array-type 'list)
              converted
              (list->vector converted))))
       ((pair? value)
        ;; Guile conses the pairs as it reads them, so its alist is the
        ;; file's order reversed; Emacs's `json-add-to-object' prepends
        ;; too but `json-read-object' reverses at the end, so Emacs
        ;; answers file order. Reversing here matches that.
        (map (lambda (pair)
               (cons (string->symbol (car pair)) (%json-convert (cdr pair))))
             (reverse value)))
       (else value)))

    (define (json-read)
      ;; GNU Emacs's `json-read' (`json.el:722'): "Parse and return the
      ;; JSON object following point. Advances point just past JSON
      ;; object."
      ;;
      ;; The whole buffer is handed to Guile's parser; point then moves
      ;; to its end, which is where Emacs's leaves it for an object that
      ;; fills the buffer.
      ;;--------------------------------------------------------------
      (let ((value (json-string->scm (buffer-string))))
        (goto-char (point-max))
        (%json-convert value)))

    (define (json-read-from-string string)
      ;; GNU Emacs's `json-read-from-string' (`json.el:742'): "Read the
      ;; JSON object contained in STRING and return it."
      ;;--------------------------------------------------------------
      (%json-convert (json-string->scm string)))

    (define (json-read-file file)
      ;; GNU Emacs's `json-read-file' (`json.el:749'): "Read the first
      ;; JSON object contained in FILE and return it."
      ;;--------------------------------------------------------------
      (with-temp-buffer
        (insert-file-contents file)
        (json-read)))

    ))
