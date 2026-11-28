(define-library (schemacs core subr-x)
  ;; GNU Emacs's `lisp/emacs-lisp/subr-x.el', so far as this tree has
  ;; needed it. The tree had gone without a `subr-x` library at all: the
  ;; subr-x functions it needed before now were placed beside their
  ;; lowest callers, each with a note saying so (`string-pixel-width` in
  ;; `xdisp.scm`, `string-empty-p` in `simple.scm`,
  ;; `with-buffer-unmodified-if-unchanged` in `textmodes/fill.scm`).
  ;;
  ;; What is here now:
  ;;
  ;;   * `string-limit` - `subr-x.el:178`;
  ;;   * `when-let*` and `and-let*` - **they are in `subr.el` in Emacs
  ;;     31** (`subr.el:2893`, `:2907`), and are carried here because
  ;;     this tree has no `subr.el` library with room for macros that
  ;;     expand into `let` forms and the tree's `subr.scm` is below the
  ;;     libraries that would use them. `if-let*` and the obsolete
  ;;     `if-let`/`when-let` are not carried; nothing here calls them.
  ;;     The expansion is Emacs's `internal--build-binding(s)` followed
  ;;     by the one `let*` and `if`/`and` it produces - including the
  ;;     three binding shapes (a plain symbol is a test, `_` binds a
  ;;     gensym, `(VALUE)` is `(_ VALUE)`).
  ;;
  ;; **What is not carried from subr-x.el**: the `string-pad`/`string-
  ;; chop`/`string-fill` family, `string-glyph-split` (composition is
  ;; not ported), `string-replace` (which is `subr.el`'s here),
  ;; `hash-table-*` convenience functions, `named-let`,
  ;; `add-display-text-property`, `read-shell-command` (in
  ;; `minibuffer.scm`), the `internal--` helpers and number-to-roman.
  ;; Nothing here calls them yet.
  ;;
  ;; **`string-limit`'s CODING-SYSTEM arm is not carried**, and it is
  ;; the only branch of the function that is not. That arm binary-
  ;; searches over `string-glyph-split`'s glyphs so that the cut never
  ;; lands inside a multi-byte character or a composed cluster; the
  ;; glyph split asks `find-composition-internal` (`composite.c`), and
  ;; composition is not ported at all. The char-based arm - which is the
  ;; one every caller here uses, including `comint-watch-for-password-
  ;; prompt` - is Emacs's line for line. A call with a CODING-SYSTEM
  ;; signals, naming the missing primitive rather than returning a
  ;; byte-count-limited answer that would be wrong at a character
  ;; boundary.
  ;;------------------------------------------------------------
  (import
    (scheme base)
    (only (guile) syntax-case syntax quasisyntax unsyntax unsyntax-splicing
          syntax->datum datum->syntax gensym)
    (only (schemacs data) natnump)
    (only (schemacs fns) %substring))

  (export string-limit when-let* and-let*)

  (begin

    ;;----------------------------------------------------------------
    ;; `when-let*' and `and-let*' (`subr.el:2893', `:2907')
    ;;
    ;; Emacs builds each clause's value with `internal--build-binding'
    ;; and then one guarded `let*`. That is what this does, and the three
    ;; binding shapes are Emacs's (`subr.el:2827'): a plain symbol tests
    ;; itself, `_` and a one-element `(VALUE)` discard the value into a
    ;; generated name, and `(VAR VALUE)` binds VAR.
    ;;
    ;; **The clauses are examined as data**, which is why the binding
    ;; list is rebuilt from the form's datum rather than matched by a
    ;; `syntax-rules` pattern: a pattern cannot say "this clause is a
    ;; symbol rather than a list", and without that test the bare-symbol
    ;; clause matches every two-element binding. A caller's identifiers
    ;; keep the call site's context (they come back through
    ;; `datum->syntax' on the whole form); the library's own
    ;; `let*`/`if`/`and`/`begin` come from the templates below.
    ;;------------------------------------------------------------

    (define (%build-binding binding prev)
      ;; GNU Emacs's `internal--build-binding' (`subr.el:2827') over
      ;; datums: answers `(VAR (and PREV VALUE))'. PREV is `#t' at the
      ;; start, where Emacs writes the symbol `t' - a symbol would be a
      ;; variable reference here, and `t' is unbound in Scheme.
      ;;--------------------------------------------------------------
      (let ((binding
             (cond
              ((symbol? binding)
               (list binding binding))
              ((and (pair? binding) (null? (cdr binding)))
               (list (gensym "s") (car binding)))
              ((and (pair? binding) (eq? (car binding) '_))
               (list (gensym "s") (cadr binding)))
              (else binding))))
        (when (> (length binding) 2)
          (error "`let' bindings can have only one value-form: ~a" binding))
        (list (car binding) (list 'and prev (cadr binding)))))

    (define (%build-bindings bindings)
      ;; GNU Emacs's `internal--build-bindings' (`subr.el:2847').
      ;;--------------------------------------------------------------
      (let loop ((rest bindings) (prev #t) (acc '()))
        (if (null? rest)
            (reverse acc)
            (let ((b (%build-binding (car rest) prev)))
              (loop (cdr rest) (car b) (cons b acc))))))

    (define-syntax when-let*
      (lambda (stx)
        (syntax-case stx ()
          ((_ bindings . body)
           (let* ((vars (%build-bindings (syntax->datum #'bindings)))
                  (bvars (datum->syntax stx vars))
                  (has-body (pair? (syntax->datum #'body))))
             (cond
              ((null? vars)
               ;; `subr.el:2913': the empty VARLIST case is `(let* ()
               ;; BODY)' - and `when-let*' with an empty body is nil.
               (if has-body #`(begin #,@#'body) #'#f))
              (else
               (let ((lastvar (datum->syntax stx (car (car (reverse vars))))))
                 (if has-body
                     #`(let* #,bvars (if #,lastvar (begin #,@#'body) #f))
                     #`(let* #,bvars #f))))))))))

    (define-syntax and-let*
      (lambda (stx)
        (syntax-case stx ()
          ((_ bindings . body)
           (let* ((vars (%build-bindings (syntax->datum #'bindings)))
                  (bvars (datum->syntax stx vars))
                  (has-body (pair? (syntax->datum #'body))))
             (cond
              ((null? vars)
               ;; `subr.el:2929': the empty VARLIST case is the body, or
               ;; `t' when there is none.
               (if has-body #`(begin #,@#'body) #'#t))
              (else
               (let ((lastvar (datum->syntax stx (car (car (reverse vars))))))
                 (if has-body
                     #`(let* #,bvars (and #,lastvar #,@#'body))
                     #`(let* #,bvars #,lastvar))))))))))
    ;;----------------------------------------------------------------
    ;; `string-limit` (`subr-x.el:178')
    ;;----------------------------------------------------------------

    (define (string-limit string length . rest)
      "Return a substring of STRING that is (up to) LENGTH characters long.
If STRING is shorter than or equal to LENGTH characters, return the
entire string unchanged.

If STRING is longer than LENGTH characters, return a substring
consisting of the first LENGTH characters of STRING.  If END is
non-nil, return the last LENGTH characters instead.

If CODING-SYSTEM is non-nil, STRING will be encoded before
limiting, and LENGTH is interpreted as the number of bytes to
limit the string to.  The result will be a unibyte string that is
shorter than LENGTH, but will not contain \"partial\"
characters (or glyphs), even if CODING-SYSTEM encodes characters
with several bytes per character.  If the coding system specifies
prefix like the byte order mark (aka \"BOM\") or a shift-in sequence,
their bytes will be normally counted as part of LENGTH.  This is
the case, for instance, with `utf-16'.  If this isn't desired, use a
coding system that doesn't specify a BOM, like `utf-16le' or `utf-16be'.

When shortening strings for display purposes,
`truncate-string-to-width' is almost always a better alternative
than this function."
      ;; `subr-x.el:178'. The declaration `(declare (important-return-
      ;; value t))' has no counterpart here. The natnump test is the
      ;; C's `(unless (natnump length) (signal 'wrong-type-argument
      ;; (list 'natnump length)))'; this tree has one error type, so the
      ;; text is Emacs's.
      ;;------------------------------------------------------------
      (let ((end (and (pair? rest) (car rest)))
            (coding-system (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (unless (natnump length)
          (error "Wrong type argument: natnump, ~a" length))
        (if coding-system
            (error "string-limit: CODING-SYSTEM is not supported (needs `string-glyph-split`, and `find-composition-internal` is not ported)")
            ;; The char-based version, the C's last `cond`.
            (cond
             ((<= (string-length string) length) string)
             (end (%substring string (- (string-length string) length)))
             (else (%substring string 0 length))))))

    ))
