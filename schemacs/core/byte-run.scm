(define-library (schemacs core byte-run)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/byte-run.el', so
  ;; far as this tree has needed it: the obsoletion machinery -
  ;; `make-obsolete', `define-obsolete-function-alias' and
  ;; `make-obsolete-variable' - which is what puts the
  ;; `byte-obsolete-info' property that `help-fns--obsolete' reads
  ;; (`help-fns.scm' had the display and no writer until now).
  ;;
  ;; It arrived with `subword.scm' (`lisp/progmodes/subword.el'), whose
  ;; `(define-obsolete-function-alias 'c-subword-mode 'subword-mode
  ;; "23.2")' and `capitalized-words-mode' are part of that package's
  ;; interface - Emacs users call the old names.
  ;;
  ;; **Not carried from byte-run.el**, each named with what it waits
  ;; for, rather than a "faithful subset":
  ;;
  ;;   * `def-edebug-spec' and the edebug specification data: edebug is
  ;;     not ported, and the macro is a declaration that does nothing at
  ;;     run time. `cc-mode.el' calls it once;
  ;;   * `make-obsolete-variable' and `define-obsolete-variable-alias':
  ;;     the variable half needs `defvaralias' and the variable
  ;;     obsoletion warning, and nothing here has a variable to alias
  ;;     yet (a buffer-local variable in this tree is a slot, not a
  ;;     symbol binding, so the alias would have to be invented rather
  ;;     than ported) - `subword.el''s `c-subword-mode' *variable* alias
  ;;     is the one caller, and it is named as a gap in `subword.scm';
  ;;   * the byte-compiler warning and the `byte-obsolete-info' version
  ;;     filtering `M-x' does (`execute-extended-command' omits commands
  ;;     obsoleted after the running version): there is no byte compiler
  ;;     and no Emacs version here;
  ;;   * `byte-run--constant-obsolete-warning''s only use is the
  ;;     `(nil t)' mistake test, which is carried;
  ;;   * the rest of the file - `macro-declarations', the
  ;;     `with-suppressed-warnings' family, `define-backtrace',
  ;;     `byte-run-strip-symbol-positions' and friends - is compiler
  ;;     infrastructure with no reader here.
  (import
    (scheme base)
    (only (guile) format)
    (only (schemacs symbol-props) put)
    ;; `defalias' is `command.scm`'s `define-alias`, whose expansion
    ;; defines the second name in the calling library and files it in
    ;; the command table - the two halves of `defalias` this tree has.
    (only (schemacs command) define-alias))

  (export make-obsolete define-obsolete-function-alias
          defsubst eval-and-compile
          byte-run--constant-obsolete-warning)

  (begin

    (define-syntax defsubst
      ;; GNU Emacs's `defsubst' (`byte-run.el:525'): "Define an inline
      ;; function. The syntax is just like that of `defun'."
      ;;
      ;; The C expands to `(prog1 (defun NAME ARGLIST BODY)
      ;; (eval-and-compile ... (put ',name 'byte-optimizer
      ;; 'byte-compile-inline-expand)))' - the definition plus the
      ;; inlining marker. There is no byte compiler here, so the marker
      ;; is written for fidelity and nothing reads it; the definition is
      ;; the `define' the tree spells a defun with.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ name arglist body ...)
         (begin
           (define (name . arglist) body ...)
           (put 'name 'byte-optimizer 'byte-compile-inline-expand)))))

    (define-syntax eval-and-compile
      ;; GNU Emacs's `eval-and-compile' (`byte-run.el:701'): "Like
      ;; `progn', but evaluates the body at compile time and at load
      ;; time."
      ;;
      ;; **The compile-time half is not carried**, and cannot be: Guile's
      ;; compiler does not evaluate top-level side effects, so the body
      ;; runs when the library loads - which is Emacs's load-time half.
      ;; Nothing ported so far relies on the compile-time half;
      ;; `rx-define` needs it (a later `(rx user-name)` in the same file
      ;; is expanded before the `put` would run) and does its `put` in
      ;; the macro transformer instead - see `rx.scm`.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ body ...) (begin body ...))))

    (define (byte-run--constant-obsolete-warning obsolete-name)
      ;; GNU Emacs's `byte-run--constant-obsolete-warning'
      ;; (`byte-run.el:557'): "Can't make `%s' obsolete; did you forget
      ;; a quote mark?" - the `(nil t)' test, which in Scheme is the
      ;; same two literals an unquoted `nil'/'t' would produce.
      ;;--------------------------------------------------------------
      (if (memq obsolete-name '(nil t))
          (error "Can't make `~a' obsolete; did you forget a quote mark?"
                 obsolete-name)))

    (define (make-obsolete obsolete-name current-name when)
      ;; GNU Emacs's `make-obsolete' (`byte-run.el:562'): "Make the
      ;; byte-compiler warn that function OBSOLETE-NAME is obsolete."
      ;;
      ;; The compiler is not what reads it here - `help-fns--obsolete'
      ;; is, through the same `byte-obsolete-info' property - and the
      ;; property's value is the C's `(list current-name nil when)`: the
      ;; middle slot held the `byte-compile' handler once and is not
      ;; read any more.
      ;;--------------------------------------------------------------
      (byte-run--constant-obsolete-warning obsolete-name)
      (put obsolete-name 'byte-obsolete-info
           (list current-name #f when))
      obsolete-name)

    (define-syntax define-obsolete-function-alias
      ;; GNU Emacs's `define-obsolete-function-alias'
      ;; (`byte-run.el:584'): "Set OBSOLETE-NAME's function definition
      ;; to CURRENT-NAME and mark it obsolete." The C expands to the
      ;; two lines this does - `defalias' then `make-obsolete'.
      ;;
      ;; **The DOCSTRING arm is accepted and dropped**, as
      ;; `define-alias' drops one: an alias's documentation is its
      ;; target's here.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ obsolete-name current-name when)
         (begin
           (define-alias obsolete-name current-name)
           (make-obsolete 'obsolete-name 'current-name when)))
        ((_ obsolete-name current-name when docstring)
         (begin
           (define-alias obsolete-name current-name)
           (make-obsolete 'obsolete-name 'current-name when)))))

    ))
