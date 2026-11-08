(define-library (schemacs editor custom)
  ;; This library mirrors GNU Emacs's `custom.el`: the *declaration* half
  ;; of Customize - `defcustom' and the `custom-declare-variable' it calls.
  ;;
  ;; **Why it is worth having without a Customize UI.** What `defcustom'
  ;; gives a variable over `defvar' is not the editing buffer; it is the
  ;; *record*: the value the variable is meant to have (`standard-value'),
  ;; the user's own value when they have set one (`saved-value'), the type,
  ;; the group, and a documented place to hang them. Emacs's own files are
  ;; written with `defcustom' for exactly that reason, so a port of an
  ;; Emacs file keeps its shape only if the form exists here.
  ;;
  ;; The properties live on the *symbol*, through `get' and `put' -
  ;; `fns.c`'s, which this tree keeps in `intervals.scm`.
  ;;
  ;; **Four departures, all named**:
  ;;
  ;;   1. **`custom-declare-variable' is handed the variable's reader and
  ;;      writer.** Emacs reaches a variable's value from its symbol
  ;;      (`symbol-value', `set') and a Scheme binding has no such
  ;;      reflection, so `define-custom' passes the two closures down and
  ;;      everything goes through them. **The variable itself is a
  ;;      parameter** - `(define *foo* (make-parameter standard))', read as
  ;;      `(*foo*)' - because Emacs's `defcustom' makes a *special*
  ;;      variable: ported Elisp `let`-binds options (`(let ((fill-column
  ;;      40)) ...)' is ordinary code), and a plain variable would make
  ;;      that `let` shadow lexically while the callee went on reading the
  ;;      global. The name carries the asterisks every parameter's name
  ;;      carries, per the convention in AGENTS.md.
  ;;
  ;;   2. **Elisp's keyword is written `:type' without a `#'.** In Elisp
  ;;      `:type' is a self-evaluating symbol; in Scheme `:type' is an
  ;;      unbound variable, so the keyword is written the way
  ;;      `define-minor-mode' writes `:lighter' - a bare `:type' in the
  ;;      declaration, which the macro reads as data.
  ;;
  ;;   3. **STANDARD is kept as a thunk.** Emacs stores the *form* in
  ;;      `standard-value' and `eval's it when it wants the standard value
  ;;      again; a `(lambda () standard)' has the same contract - it can be
  ;;      called again for the standard value - without `eval', and it
  ;;      keeps the expression's lexical scope, which Emacs's own
  ;;      `lexical-binding' branch goes to some trouble for.
  ;;
  ;;   4. **The variable is bound before `custom-declare-variable' runs.**
  ;;      Emacs lets `defvar' create it unbound and then initializes it;
  ;;      here the `define' in the macro's expansion has already given it
  ;;      STANDARD, and the initializer then sets it to what it already
  ;;      holds. The observable result is Emacs's: the value is STANDARD, a
  ;;      `:set' function is called with it exactly as
  ;;      `custom-initialize-reset' calls one, and `:get' is consulted
  ;;      first, as that initializer does.
  ;;
  ;; **Ported since 2026-11-08: the themes** - `custom.el''s second half,
  ;; at the bottom of this file: `define-theme', `custom-theme-set-faces'
  ;; and `-variables', `custom-push-theme', `load-theme'/'enable-theme'/
  ;; `disable-theme', and `custom-set-faces' - `custom-set-variables''s
  ;; twin. A theme file is Scheme here and Elisp there, which is the one
  ;; departure of substance; everything else - the properties, the
  ;; precedence, the recalculation - is the C's shape.
  ;;
  ;; **Not ported, each for want of a thing this tree does not have**: the
  ;; Customize buffers themselves (`customize-*', `cus-edit.el', the widget
  ;; library) and `cus-theme.el''s theme *editor*; `setopt'
  ;; (`custom-set-variables' is here, so `setopt' is the spelling apart);
  ;; `custom-initialize-delay' and `custom-initialize-after-file-load'
  ;; (both exist for the dump and for `after-load-functions', neither of
  ;; which this tree has); and `defgroup' (`custom-declare-group') -
  ;; `defface' is faces.scm's, and the group is the Custom UI's one
  ;; missing half.
  ;;
  ;; **Two departures inside the themes, each named where it lives**:
  ;; `custom-theme-load-confirm' (the "Loading a theme can run Lisp code"
  ;; question) is answered "no" rather than asked, `y-or-n-p' being in
  ;; `(schemacs editor files)', a library above this one - so an init
  ;; file passes `#:no-confirm #t' as Emacs's does, and a theme not on
  ;; the safe list is refused; and "Treat this theme as safe in future
  ;; sessions?" is never asked, there being nothing to write the answer
  ;; into (`custom-file' does not exist yet).

  (import
    (scheme base)
    ;; `custom-set-variables' evaluates each saved expression in the
    ;; module that called it - Emacs `eval's it in the init file's
    ;; context, which is the same thing here.
    (scheme eval)
    (only (guile) current-module)
    ;; `syntax-case' and friends, for `define-custom' below - the same
    ;; device `easy-mmode`'s `define-minor-mode' uses, and for the same
    ;; reason: a clause list cannot be walked by `syntax-rules'. `syntax'
    ;; itself is what `#'` reads as, and leaving it out is the "unexpected
    ;; syntax in form ()" the compiler says when it is missing.
    (only (guile) identifier? quasisyntax syntax syntax->datum syntax-case
          unsyntax unsyntax-splicing
          ;; `load-theme' reads its file, and `delq' is srfi-1's spelling
          ;; of the list edit `enable-theme' and `disable-theme' make.
          string->symbol)
    ;; `delq' is Elisp's, and `(schemacs editor subr)' is where
    ;; `assoc-delete-all' beside it lives.
    (only (srfi srfi-1) delete-duplicates find fold)
    ;; `string-suffix?' is srfi-13's - `custom-available-themes' tests
    ;; the "-theme.el" name with it, as the C's `string-match-p' does.
    (only (srfi srfi-13) string-suffix?)
    (only (schemacs editor subr) delq assq-delete-all)
    ;; `get' and `put' are `fns.c`'s symbol properties; see the header.
    (only (schemacs editor intervals) get put)
    ;; The faces a theme sets: `make-face' initialises one whose `defface'
    ;; has not run, `facep' asks whether it has, `face-spec-set' installs
    ;; a theme's spec, and `face-spec-recalc' is what
    ;; `custom-theme-recalc-face' runs. `face-attribute' answers `:extend'
    ;; in `face-spec-recalc'.
    (only (schemacs editor faces)
          face-attribute face-spec-set face-spec-recalc make-face facep)
    ;; The paths a theme file is searched along and the predicates that
    ;; guard it. `y-or-n-p' is the confirmation the safety hash prompts
    ;; with.
    ;; `locate-file-internal' is `lread.c''s, which is fileio's here;
    ;; Emacs's `load-theme' reaches for its own `locate-file', which is
    ;; files.el's and lives in `(schemacs editor files)' - a library that
    ;; cannot be imported here, because `files' imports `simple' and
    ;; `simple' imports this one. The internal search is what Emacs's
    ;; `locate-file' is built on, and it answers the same.
    (only (schemacs editor fileio) file-directory-p locate-file-internal)
    ;; A theme directory's files, which `custom-available-themes' lists.
    (only (schemacs editor diredc) directory-files)
    ;; `%load-path' is where the installed themes directory is
    ;; looked for - `data-directory'/themes being what Emacs searches.
    ;; `%load-path' is where the installed themes directory is
    ;; looked for - `data-directory'/themes being what Emacs searches;
    ;; `call-with-input-file' and `load' are what `load-theme' reads a
    ;; theme file with, and `catch' is what
    ;; `custom-enabled-themes-set' keeps one theme's error from
    ;; stopping the others with.
    ;; `set-module-declarative?!' and `datum->syntax' are for the
    ;; not-declarative declaration at the top of the body, which
    ;; `load-theme''s `load' needs - the same statement
    ;; `(schemacs editor startup)' makes for the same reason.
    (only (guile) getenv %load-path call-with-input-file load catch
          cadar cadddr provide module-variable resolve-module
          set-module-declarative?! datum->syntax))

  (export
   define-custom
   custom-declare-variable
   custom-initialize-default custom-initialize-set custom-initialize-reset
   custom-initialize-changed
   custom-add-to-group custom-add-option custom-add-frequent-value
   custom-add-version custom-add-package-version custom-add-load
   custom-add-link custom-add-dependencies
   custom-handle-keyword
   custom-variable-p custom--standard-value custom--standard-value-p
   custom-set-variables
   *custom-current-group-alist* custom-current-group
   *custom-declare-variable-hook* *custom-dont-initialize*
   ;; The themes: `custom.el''s second half. `define-theme' declares one,
   ;; a theme file's `custom-theme-set-faces' and
   ;; `custom-theme-set-variables' record its settings,
   ;; `load-theme'/'enable-theme'/'disable-theme' apply and unapply them,
   ;; and `custom-set-faces' is `custom-set-variables'' twin for faces.
   *custom-known-themes* *custom-enabled-themes* *custom-safe-themes*
   *custom--inhibit-theme-enable*
   *custom-theme-directory* *custom-theme-load-path*
   custom-theme-p custom-check-theme
   custom-push-theme custom-theme-recalc-variable custom-theme-recalc-face
   enable-theme custom-theme-enabled-p disable-theme
   custom-theme-set-faces custom-set-faces
   custom-theme-set-variables
   custom-theme-reset-faces custom-theme-reset-variables
   custom-declare-theme provide-theme
   custom-theme--load-path custom-available-themes
   load-theme custom-enabled-themes-set define-theme
   )

  (begin

    ;;----------------------------------------------------------------
    ;; This library is not declarative - Guile's `#:declarative? #f'
    ;;----------------------------------------------------------------
    ;; `load' is used below - `load-theme' reads a theme file with it -
    ;; so this module is not a declarative one. The statement is made
    ;; the way `(schemacs editor startup)' makes its own, for the same
    ;; two reasons: the warning is silenced by neither half alone, and
    ;; a *declarative* module lets the compiler fold a definition into
    ;; its callers' code, so a later `set!' stops being seen. The
    ;; definitions at risk here are the theme parameters -
    ;; `*custom-enabled-themes*' and friends, which `load-theme' sets
    ;; and every reader reads - and the fold would leave a compiled
    ;; reader answering the value it was compiled with.
    (define-syntax %not-declarative!
      (lambda (x)
        (set-module-declarative?! (current-module) #f)
        (datum->syntax x '(if #f #f))))
    (%not-declarative!)
    (set-module-declarative?!
     (resolve-module '(schemacs editor custom) #f)
     #f)


    ;;--------------------------------------------------------------
    ;; The groups
    ;;--------------------------------------------------------------

    (define *custom-current-group-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `custom-current-group-alist': "Alist of (FILE . GROUP)
    ;; controlling which group to add new options to by default. FILE
    ;; should be the value of `load-file-name' at the time the group is set
    ;; up." `load-file-name' is what `custom-current-group' consults, and
    ;; this tree has no such variable - a library knows its own file name,
    ;; but nothing publishes it as a dynamic variable the way `load' does -
    ;; so the alist is kept and is empty, and an option lands in the group
    ;; its declaration names. Named rather than faked.

    (define (custom-current-group)
      ;; GNU Emacs's `custom-current-group': the group a new option is
      ;; added to when the declaration does not say.
      ;;--------------------------------------------------------------
      (let ((entry (assq #f (*custom-current-group-alist*))))
        (and entry (cdr entry))))

    (define (custom-add-to-group group option widget)
      ;; GNU Emacs's `custom-add-to-group': "To existing GROUP add a new
      ;; OPTION of type WIDGET. If there already is an entry for OPTION and
      ;; WIDGET, nothing is done."
      ;;
      ;; The entry is `(OPTION WIDGET)' and the test is `member', so it is
      ;; by *value* - which is what keeps a library loaded twice from
      ;; listing its options twice.
      ;;--------------------------------------------------------------
      (let ((members (get group 'custom-group))
            (entry (list option widget)))
        ;; `(or members '())`: Emacs's `(member entry nil)' is nil, and
        ;; a Scheme `member' against #f raises - the elisp-nil trap.
        (unless (member entry (or members '()))
          (put group 'custom-group (append (or members '()) (list entry))))))

    (define (custom-add-version symbol version)
      ;; GNU Emacs's `custom-add-version': "To the custom option SYMBOL add
      ;; the version VERSION."
      ;;--------------------------------------------------------------
      (put symbol 'custom-version version))

    (define (custom-add-package-version symbol version)
      ;; GNU Emacs's `custom-add-package-version'.
      ;;--------------------------------------------------------------
      (put symbol 'custom-package-version version))

    (define (custom-add-load symbol load)
      ;; GNU Emacs's `custom-add-load': "To the custom option SYMBOL add
      ;; the dependency LOAD. LOAD should be either a library file name, or
      ;; a feature name."
      ;;--------------------------------------------------------------
      (let ((loads (get symbol 'custom-loads)))
        (unless (member load (or loads '()))
          (put symbol 'custom-loads (cons load loads)))))

    (define (custom-add-option symbol option)
      ;; GNU Emacs's `custom-add-option': "To the variable SYMBOL add
      ;; OPTION."
      ;;--------------------------------------------------------------
      (let ((options (get symbol 'custom-options)))
        (unless (member option (or options '()))
          (put symbol 'custom-options (cons option options)))))

    (define custom-add-frequent-value custom-add-option)
    ;; ^ GNU Emacs's `(defalias 'custom-add-frequent-value
    ;; #'custom-add-option)'. The older name, kept because the Emacs
    ;; sources still call it.

    (define (custom-add-link symbol widget)
      ;; GNU Emacs's `custom-add-link': "To the custom option SYMBOL add
      ;; the link WIDGET."
      ;;--------------------------------------------------------------
      (let ((links (get symbol 'custom-links)))
        (unless (member widget (or links '()))
          (put symbol 'custom-links (cons widget links)))))

    (define (custom-add-dependencies symbol value)
      ;; GNU Emacs's `custom-add-dependencies': "To the custom option
      ;; SYMBOL, add dependencies specified by VALUE."
      ;;
      ;; The C's two errors are kept word for word: a VALUE that is not a
      ;; list, and a member of it that is not a symbol. "Invalid custom
      ;; dependency `%s'" is `~a' here, as every message in this tree is.
      ;;--------------------------------------------------------------
      (unless (list? value)
        (error "Invalid custom dependency `~a'" value))
      (let ((new-deps (or (get symbol 'custom-dependencies) '())))
        (for-each
         (lambda (dep)
           (unless (symbol? dep)
             (error "Invalid custom dependency `~a'" dep))
           (unless (memq dep new-deps)
             (set! new-deps (cons dep new-deps))))
         value)
        (put symbol 'custom-dependencies new-deps)))

    (define (custom-handle-keyword symbol keyword value type)
      ;; GNU Emacs's `custom-handle-keyword': "For customization option
      ;; SYMBOL, handle KEYWORD with VALUE. Fourth argument TYPE is the
      ;; custom option type."
      ;;
      ;; The last arm is the C's own `(error "Unknown keyword %s")`, which
      ;; is what makes a typo in a declaration say so at load time rather
      ;; than quietly doing nothing.
      ;;--------------------------------------------------------------
      (cond
       ((eq? keyword ':group) (custom-add-to-group value symbol type))
       ((eq? keyword ':version) (custom-add-version symbol value))
       ((eq? keyword ':package-version) (custom-add-package-version symbol value))
       ((eq? keyword ':link) (custom-add-link symbol value))
       ((eq? keyword ':load) (custom-add-load symbol value))
       ((eq? keyword ':tag) (put symbol 'custom-tag value))
       ((eq? keyword ':set-after) (custom-add-dependencies symbol value))
       (else (error "Unknown keyword ~a" keyword))))

    ;;--------------------------------------------------------------
    ;; The variable a symbol names
    ;;--------------------------------------------------------------
    ;;
    ;; **This is where departure 1 lives**, so it is one place and it says
    ;; so. Emacs can evaluate a symbol (`symbol-value') and assign to one
    ;; (`set'); a Scheme binding cannot be reached by name at all. So
    ;; `define-custom' passes the binding's own procedures down and
    ;; everything above goes through them.
    ;;
    ;; They are kept as symbol properties - `custom-reader' and
    ;; `custom-writer' - rather than threaded through every call, for the
    ;; reason Emacs keeps `:get' and `:set' there: a later `setopt' needs
    ;; to find them knowing only the symbol.

    (define (custom--keyword? x)
      ;; Whether X is one of a declaration's keywords - Elisp's
      ;; `(keywordp x)', which for this tree is "a symbol whose name begins
      ;; with `:'". `custom-declare-variable' asks it of the docstring too,
      ;; which is the C's `(if (keywordp doc) (error "Doc string is
      ;; missing"))'.
      ;;--------------------------------------------------------------
      (and (symbol? x)
           (let ((name (symbol->string x)))
             (and (> (string-length name) 1)
                  (char=? (string-ref name 0) #\:)))))

    (define (custom--getter symbol)
      (or (get symbol 'custom-reader)
          (error "Not a customizable variable: ~a" symbol)))

    (define (custom--setter symbol)
      (or (get symbol 'custom-writer)
          (error "Not a customizable variable: ~a" symbol)))

    (define (custom--bound? symbol)
      ;; Whether the variable has a value. A parameter always does - it is
      ;; made with one - which is departure 4 of the header, and the
      ;; reason this is a procedure rather than the `void-variable'
      ;; condition the C's `custom-initialize-default' catches.
      ;;--------------------------------------------------------------
      (procedure? (get symbol 'custom-reader)))

    (define (custom--standard-value variable)
      ;; GNU Emacs's `custom--standard-value': "Return the standard value
      ;; of VARIABLE" - `(eval (car (get variable 'standard-value)) t)'
      ;; there, a call of the thunk here.
      ;;--------------------------------------------------------------
      (let ((sv (get variable 'standard-value)))
        (and sv ((car sv)))))

    (define (custom--standard-value-p variable value)
      ;; GNU Emacs's `custom--standard-value-p' (`custom.el:703'): "Return
      ;; non-nil if VALUE is `equal' to the standard value of VARIABLE."
      ;;--------------------------------------------------------------
      (let ((sv (get variable 'standard-value)))
        (and sv (equal? value ((car sv))))))

    (define (custom-variable-p variable)
      ;; GNU Emacs's `custom-variable-p`: "A customizable variable is
      ;; either (i) a variable whose property list contains a non-nil
      ;; `standard-value' or `custom-autoload' property, or (ii) an alias
      ;; for another customizable variable."
      ;;
      ;; The alias arm is `(indirect-variable variable)'; this tree has no
      ;; variable aliases (`defvaralias' is not ported), so it is not
      ;; carried.
      ;;--------------------------------------------------------------
      (and (symbol? variable)
           (or (get variable 'standard-value)
               (get variable 'custom-autoload))
           #t))

    ;;--------------------------------------------------------------
    ;; Initializing the variable
    ;;--------------------------------------------------------------
    ;;
    ;; Emacs has five of these and a declaration picks one with
    ;; `:initialize'; the default is `custom-initialize-reset'. Three are
    ;; here. The two that are not - `custom-initialize-delay' and
    ;; `custom-initialize-after-file-load' - exist so that a *preloaded*
    ;; file's variables are initialized in the run-time context rather than
    ;; at dump time, and this tree has no dump and no
    ;; `after-load-functions' to hang them on.
    ;;
    ;; **The saved value is what makes them differ.** Each one asks, in its
    ;; own order, for (a) the value the variable has now, (b) the value the
    ;; user saved for it (`saved-value'), or (c) the standard. Nothing in
    ;; this tree writes `saved-value' yet - there is no `setopt' and no
    ;; Customize buffer - so (b) is always absent and the three agree; they
    ;; are written out in their own shapes anyway, because the day one of
    ;; them is reachable is the day the difference matters.

    (define (custom-initialize-default symbol standard)
      ;; GNU Emacs's `custom-initialize-default': "Initialize SYMBOL based
      ;; on EXP. Set the symbol to EXP if the variable has not been set
      ;; already."
      ;;
      ;; The C asks `(default-toplevel-value symbol)' inside a
      ;; `condition-case' for `void-variable' - "is it bound at all" - and
      ;; sets only when it is not. A parameter is always bound, so this
      ;; leaves the value it was made with, which is STANDARD: the same
      ;; answer, arrived at one step earlier.
      ;;--------------------------------------------------------------
      (unless (custom--bound? symbol)
        ((custom--setter symbol) symbol (standard))))

    (define (custom-initialize-set symbol standard)
      ;; GNU Emacs's `custom-initialize-set`: "If the symbol doesn't have a
      ;; default binding already, then set it using its `:set' function (or
      ;; `set-default-toplevel-value' if it has none)."
      ;;--------------------------------------------------------------
      (unless (custom--bound? symbol)
        ((or (get symbol 'custom-set) (custom--setter symbol))
         symbol
         (standard))))

    (define (custom-initialize-reset symbol standard)
      ;; GNU Emacs's `custom-initialize-reset`: "The value is either the
      ;; symbol's current value (as obtained using the `:get' function), if
      ;; any, or the value in the symbol's `saved-value' property if any,
      ;; or (last of all) the value of EXP."
      ;;
      ;; This is the default initializer, and it is the one that runs for
      ;; an ordinary `define-custom'.
      ;;--------------------------------------------------------------
      ((or (get symbol 'custom-set) (custom--setter symbol))
       symbol
       (if (custom--bound? symbol)
           ((or (get symbol 'custom-get) (custom--getter symbol)) symbol)
           (standard))))

    (define (custom-initialize-changed symbol standard)
      ;; GNU Emacs's `custom-initialize-changed`: "Like
      ;; `custom-initialize-reset', but only use the `:set' function if not
      ;; using the standard setting. For the standard setting, use
      ;; `set-default-toplevel-value'."
      ;;--------------------------------------------------------------
      (if (custom--bound? symbol)
          ((custom--setter symbol)
           symbol
           ((or (get symbol 'custom-get) (custom--getter symbol)) symbol))
          ((or (get symbol 'custom-set) (custom--setter symbol))
           symbol
           (standard))))

    ;;--------------------------------------------------------------
    ;; The hook and the switch
    ;;--------------------------------------------------------------

    (define *custom-declare-variable-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `custom-declare-variable-hook' (called
    ;; `custom-define-hook' until 2026, and still run under that name in
    ;; the C): "Hook run after every variable definition." A parameter
    ;; here, the way this tree spells a global variable.

    (define *custom-dont-initialize* (make-parameter #f))
    ;; ^ GNU Emacs's `custom-dont-initialize': "Non-nil means `defcustom'
    ;; should not initialize the variable. That is used to make the load
    ;; sequence more efficient." Emacs binds it around its own dump; it is
    ;; here because `custom-declare-variable' reads it, so a declaration
    ;; that wants the record without the assignment can bind it.

    ;;--------------------------------------------------------------
    ;; One clause
    ;;--------------------------------------------------------------

    (define (custom--apply-clause! symbol clause state)
      ;; Handle one `(KEYWORD VALUE)' of a declaration, and answer STATE
      ;; with whatever the clause changed.
      ;;
      ;; **One clause in one procedure**, rather than the C's `(while args
      ;; ... (cond ((eq keyword :initialize) ...) ...))`: the arms are the
      ;; same arms, but a Scheme `cond` nested inside a walk inside a
      ;; `let` inside a procedure is four levels of parenthesis with
      ;; nothing in the middle of them, and this is that code with the
      ;; middle lifted out where it can be read.
      ;;--------------------------------------------------------------
      (unless (and (pair? clause) (pair? (cdr clause)))
        (error "Keyword ~a is missing an argument" clause))
      (let ((keyword (car clause))
            (value (cadr clause)))
        (unless (custom--keyword? keyword)
          ;; the C's `(unless (symbolp keyword) (error "Junk in args %S"
          ;; args))', where the keywords *are* symbols
          (error "Junk in args ~a" clause))
        (cond
         ((eq? keyword ':initialize)
          (set-cdr! (assq 'initialize state) value))
         ((eq? keyword ':set) (put symbol 'custom-set value))
         ((eq? keyword ':get) (put symbol 'custom-get value))
         ((eq? keyword ':require)
          (set-cdr! (assq 'requests state)
                    (cons value (cdr (assq 'requests state)))))
         ((eq? keyword ':risky) (put symbol 'risky-local-variable value))
         ((eq? keyword ':safe) (put symbol 'safe-local-variable value))
         ((eq? keyword ':local)
          ;; "(when (memq value '(t permanent)) (setq buffer-local t))"
          ;; and the `permanent-local' property beside it.
          ;;
          ;; **Automatic buffer-locality is not carried.** Emacs's
          ;; `make-variable-buffer-local' makes a variable take a
          ;; per-buffer value in every buffer; this tree's buffer-local
          ;; variables are entries in a per-buffer table that code reads
          ;; through `buffer-local-value', and a plain variable has no
          ;; such switch. The properties are put, so a reader can see what
          ;; the declaration asked for.
          (when (memq value '(#t permanent))
            (put symbol 'buffer-local #t))
          (when (memq value '(permanent permanent-only))
            (put symbol 'permanent-local #t)))
         ((eq? keyword ':type) (put symbol 'custom-type value))
         ((eq? keyword ':options)
          (if (get symbol 'custom-options)
              (for-each (lambda (option) (custom-add-option symbol option))
                        value)
              (put symbol 'custom-options (list-copy value))))
         (else
          (custom-handle-keyword symbol keyword value 'custom-variable))))
      state)

    (define (custom--initializer state)
      ;; Which initializer the declaration asked for: the `:initialize'
      ;; clause when there is one, `custom-initialize-reset' otherwise.
      ;;--------------------------------------------------------------
      (let ((asked (assq 'initialize state)))
        (if asked (cdr asked) custom-initialize-reset)))

    (define (custom--requests state)
      ;; The `:require' clauses, as a list of symbols.
      ;;--------------------------------------------------------------
      (let ((asked (assq 'requests state)))
        (if asked (cdr asked) '())))

    ;;--------------------------------------------------------------
    ;; `custom-declare-variable'
    ;;--------------------------------------------------------------

    (define (custom-declare-variable symbol standard doc reader writer . clauses)
      ;; GNU Emacs's `custom-declare-variable' (`custom.el:169'): "Like
      ;; `defcustom', but SYMBOL and DEFAULT are evaluated as normal
      ;; arguments. DEFAULT should be an expression to evaluate to compute
      ;; the default value, not the default value itself."
      ;;
      ;; **Two arguments more than the C's**, and they are departure 1:
      ;; READER and WRITER are the binding's own
      ;; `default-toplevel-value' and `set-default-toplevel-value'. They
      ;; are remembered on the symbol, so a caller holding only the symbol
      ;; can still reach the variable.
      ;;
      ;; CLAUSES is a list of `(KEYWORD VALUE)' lists, which is what
      ;; `define-custom' emits; the C's `&rest args' is one flat list read
      ;; two at a time, and a macro cannot alternate a datum and an
      ;; expression into one list without turning the datum into raw
      ;; syntax. Same contents, grouped.
      ;;--------------------------------------------------------------
      (put symbol 'standard-value (list standard))
      ;; "Maybe this option was rogue in an earlier version. It no longer
      ;; is."
      (when (get symbol 'force-value)
        (put symbol 'force-value #f))
      (when (custom--keyword? doc)
        (error "Doc string is missing"))
      (put symbol 'custom-reader reader)
      (put symbol 'custom-writer writer)
      ;; "Unless `:group' is given, add it to the current group."
      (unless (memq ':group (map car clauses))
        (let ((group (custom-current-group)))
          (when group (custom-add-to-group group symbol 'custom-variable))))
      (let ((state (list (cons 'initialize custom-initialize-reset)
                         (cons 'requests '()))))
        (for-each (lambda (clause)
                    (set! state (custom--apply-clause! symbol clause state)))
                  clauses)
        ;; "Set the docstring, record the var on load-history, as well as
        ;; set the special-variable-p flag" - the docstring is the part
        ;; this tree has a place for.
        (put symbol 'variable-documentation doc)
        (put symbol 'custom-requests (custom--requests state))
        ;; "Do the actual initialization."
        (unless (*custom-dont-initialize*)
          ((custom--initializer state) symbol standard)
          ;; The C's reset of a `saved-value' that a *theme* put there:
          ;; with no themes here it can never be set, and it is written
          ;; anyway so that the day one exists this does not have to be
          ;; remembered.
          ;;
          ;; **`(and (pair? ...) ...)' and not `(car (car ...))'**: in
          ;; Elisp `(caar nil)' is nil, so the C's test is false when the
          ;; property is absent; here `(car #f)' raises - the
          ;; elisp-nil-versus-Scheme trap this tree keeps meeting.
          (let* ((theme-value (get symbol 'theme-value))
                 (theme (and (pair? theme-value)
                             (pair? (car theme-value))
                             (car (car theme-value)))))
            (when (and theme (not (eq? theme 'user)) (get symbol 'saved-value))
              (put symbol 'saved-value #f)))))
      (for-each (lambda (hook) (hook)) (*custom-declare-variable-hook*))
      symbol)

    ;;--------------------------------------------------------------
    ;; `define-custom'
    ;;--------------------------------------------------------------

    (define-syntax define-custom
      ;; Declare a customizable variable: GNU Emacs's `defcustom'
      ;; (`custom.el:269'), spelled the way this tree spells one.
      ;;
      ;;   (define-custom *scroll-step* 0
      ;;     "Number of lines to scroll when point goes off screen."
      ;;     :type 'integer
      ;;     :group 'scrolling)
      ;;
      ;; NAME is the variable, STANDARD an expression for its standard
      ;; value, DOC the documentation string, and the rest Elisp's flat
      ;; `[KEYWORD VALUE]...' with the keywords spelled the way this tree
      ;; spells them (departure 2 of the header).
      ;;
      ;; **The clause list cannot be walked by `syntax-rules'**: the
      ;; keywords have to be recognised and each one's value kept as an
      ;; *expression*, and a pattern cannot say "and now a keyword".
      ;; `define-minor-mode' walks its clauses the same way for the same
      ;; reason, so this is that walk with these keywords in it.
      ;;
      ;; **It defines a parameter** - `(define *name* (make-parameter
      ;; standard))`, read as `(*name*)`, written by calling it - because
      ;; Emacs's `defcustom' makes a *special* variable: ported Elisp
      ;; `let`-binds options (`(let ((fill-column 40)) ...)' is ordinary
      ;; code), and under this tree's convention a dynamically bound
      ;; variable is a parameter whose name carries asterisks (AGENTS.md).
      ;; A plain variable would make that `let` shadow lexically, and the
      ;; callee would go on reading the global without a word.
      ;;
      ;; `custom-declare-variable' is still handed the binding's own reader
      ;; and writer, because a procedure cannot reach a binding by name -
      ;; Emacs's `symbol-value' and `set' have no Scheme equivalent. They
      ;; take the *symbol* and ignore it, which is Emacs's calling
      ;; convention - `(funcall (or (get symbol 'custom-get)
      ;; #'default-toplevel-value) symbol)' - kept so that a `:get' or
      ;; `:set' written from Emacs's documentation has the arguments it
      ;; expects. A `:get' or `:set' clause, given, is consulted first.
      ;;--------------------------------------------------------------
      (lambda (stx)
        (define (keyword? x)
          (and (identifier? x)
               (memq (syntax->datum x)
                     '(:type :group :initialize :set :get :require :risky
                       :safe :local :options :version :package-version
                       :link :load :tag :set-after))))
        ;; The clauses as `(KEYWORD-SYNTAX . VALUE-SYNTAX)' pairs.
        ;;
        ;; **The keyword is kept as *syntax* and not as a datum**:
        ;; unsyntaxing a bare symbol into the expansion is "raw symbol in
        ;; macro output", while an *identifier* unsyntaxed into a `quote'
        ;; form is the ordinary `(quote :type)' and emits the symbol.
        ;; (Found by doing it the other way round first.)
        ;;----------------------------------------------------------
        (define (parse clauses)
          (let loop ((rest clauses) (out '()))
            (cond
             ((null? rest) (reverse out))
             ((keyword? (car rest))
              (unless (pair? (cdr rest))
                (error "Keyword ~a is missing an argument"
                       (syntax->datum (car rest))))
              (loop (cddr rest)
                    (cons (cons (car rest) (cadr rest)) out)))
             (else
              (error "Junk in args ~a" (map syntax->datum rest))))))
        (syntax-case stx ()
          ((_ name standard docstring clause ...)
           (let ((clauses (parse #'(clause ...))))
             #`(begin
                 (define name (make-parameter standard))
                 (custom-declare-variable
                  'name
                  (lambda () standard)
                  docstring
                  (lambda (symbol) (name))
                  (lambda (symbol value) (name value))
                  #,@(map (lambda (clause)
                            ;; `(list ':type <the value expression>)' - the
                            ;; keyword as data and the value as code, which
                            ;; is the clause list `custom-declare-variable'
                            ;; walks.
                            #`(list (quote #,(car clause)) #,(cdr clause)))
                          clauses))))))))


    ;;----------------------------------------------------------------
    ;; Themes
    ;;
    ;; GNU Emacs's `custom.el' second half: `deftheme', the settings a
    ;; theme file makes (`custom-theme-set-faces' and
    ;; `custom-theme-set-variables'), and the enabling that applies them
    ;; (`enable-theme', `disable-theme', `load-theme').
    ;;
    ;; **The model.** A theme is a symbol whose `theme-settings'
    ;; property lists everything it set - one `(PROP SYMBOL THEME
    ;; VALUE)' per setting - and each face or variable it set carries
    ;; the same record on its own `theme-face' or `theme-value'
    ;; property, as `(THEME VALUE)'. `custom-push-theme' is the one
    ;; function that maintains both halves, and it is what makes
    ;; disabling possible: remove the theme's records from every symbol
    ;; and the next theme's, or the standard, is what is left.
    ;;
    ;; `custom-enabled-themes' is the precedence list - most recently
    ;; enabled first, with the `user' theme (what `custom-set-faces'
    ;; and `custom-set-variables' record into) always highest. When a
    ;; face is realized, `face-spec-recalc' walks its `theme-face'
    ;; records from the earliest theme forward and the first branch
    ;; that matches the display wins - which is what makes a later
    ;; theme's whole-face spec beat an earlier one.
    ;;
    ;; `custom--inhibit-theme-enable' is Emacs's dynamic switch: while
    ;; `load-theme' reads a theme file, its settings are *recorded* but
    ;; not *applied*; `enable-theme' applies them by walking the
    ;; records. It is a parameter here, per the convention, and the
    ;; three states the C distinguishes (`t', `apply-only-user', nil)
    ;; are the three this tree's callers need.
    ;;--------------------------------------------------------------

    (define *custom-known-themes* '(user changed))
    ;; ^ GNU Emacs's `custom-known-themes' (`custom.el:915'): "Themes
    ;; that have been defined with `deftheme'. ... The theme `changed'
    ;; is for internal use, for user settings that have been changed
    ;; outside of customize."
    ;;
    ;; **A plain variable, and not a parameter.** It is only ever
    ;; setq'd - by `custom-declare-theme' when a theme file's
    ;; `define-theme' runs, inside the `parameterize' round
    ;; `load-theme''s `(load file)' - and a parameter *set* inside a
    ;; parameterized extent mutates that extent's value, which reverts:
    ;; measured, a theme file loaded through the gate left
    ;; `custom-theme-p' answering #f, and `enable-theme' raised "Unknown
    ;; theme". Emacs's defvar mutation is a global set, and this is the
    ;; tree's convention for a process-global registry (`AGENTS.md':
    ;; "process-global registries ... are a plain define").

    (define *custom-enabled-themes* (make-parameter '()))
    ;; ^ GNU Emacs's `custom-enabled-themes' (`custom.el:1630'). The
    ;; `:set' function there - which disables the themes dropped from
    ;; the list and enables the ones added - is what
    ;; `custom-enabled-themes-set' below is.

    (define *custom-safe-themes* (make-parameter '()))
    ;; ^ GNU Emacs's `custom-safe-themes' (`custom.el:1582'): the SHA-256
    ;; hashes of theme files the user has pronounced safe. `t' means
    ;; every theme is safe; the `default' element means every theme in
    ;; the *installed* themes directory is. A hash not in the list
    ;; prompts - Emacs's `custom-theme-load-confirm', which is a `*Help*'
    ;; question - and here the prompt is `y-or-n-p' with the same words.

    (define *custom-theme-directory* (make-parameter #f))
    ;; ^ GNU Emacs's `custom-theme-directory' (`custom.el:1204'):
    ;; "Default user directory for storing custom theme files."
    ;; `#f' here means "unset", and `custom-theme--load-path' falls back
    ;; to the init file's directory - which is where a user's own theme
    ;; lives, and what Emacs's default of `user-emacs-directory' is.

    (define *custom-theme-load-path* (make-parameter '(custom-theme-directory t)))
    ;; ^ GNU Emacs's `custom-theme-load-path' (`custom.el:1219'): "List
    ;; of directories to search for custom theme files." `t' is the
    ;; installed themes directory - Emacs's `data-directory'/themes.

    (define *custom--inhibit-theme-enable* (make-parameter 'apply-only-user))
    ;; ^ GNU Emacs's `custom--inhibit-theme-enable' (`custom.el:1272').

    (define (custom-theme-p theme)
      ;; GNU Emacs's `custom-theme-p' (`custom.el:921'): "Return non-nil
      ;; if THEME has been defined through `deftheme'."
      ;;--------------------------------------------------------------
      (memq theme *custom-known-themes*))

    (define (custom-check-theme theme)
      ;; GNU Emacs's `custom-check-theme' (`custom.el:928').
      ;;--------------------------------------------------------------
      (unless (custom-theme-p theme)
        (error "Unknown theme `" (symbol->string theme) "'")))

    (define (custom--should-apply-setting theme)
      ;; GNU Emacs's `custom--should-apply-setting' (`custom.el:932'):
      ;; "Non-nil if settings for the theme THEME should apply
      ;; immediately."
      ;;--------------------------------------------------------------
      (or (memq theme (*custom-enabled-themes*))
          (not (*custom--inhibit-theme-enable*))
          (and (eq? (*custom--inhibit-theme-enable*) 'apply-only-user)
               (eq? theme 'user))))

    (define (custom-theme-name-valid-p name)
      ;; GNU Emacs's `custom-theme-name-valid-p' (`custom.el:1505').
      ;;--------------------------------------------------------------
      (and (not (memq name '(#f user changed)))
           (symbol? name)
           (not (string=? "" (symbol->string name)))))

    (define (custom-push-theme prop symbol theme mode . value)
      ;; GNU Emacs's `custom-push-theme' (`custom.el:945'): "Record VALUE
      ;; for face or variable SYMBOL in custom theme THEME. PROP is
      ;; `theme-face' for a face, `theme-value' for a variable. MODE can
      ;; be either the symbol `set' or the symbol `reset'."
      ;;
      ;; SYMBOL's property and THEME's `theme-settings' carry the same
      ;; record, and both are kept in step - which is what makes
      ;; `disable-theme''s removals possible.
      ;;--------------------------------------------------------------
      (unless (memq prop '(theme-face theme-value))
        (error "Unknown theme property"))
      ;; **`(get ...)' answers #f where Emacs's answers nil**, and an
      ;; empty list is what every alist walk below wants - the
      ;; elisp-nil-versus-Scheme trap this file has met before.
      (let* ((old (or (get symbol prop) '()))
             (setting (assq theme old))
             (theme-settings (or (get theme 'theme-settings) '())))
        (cond
         ;; Remove a setting:
         ((eq? mode 'reset)
          (when setting
            (put theme 'theme-settings
                 (let loop ((rest theme-settings))
                   (cond ((null? rest) '())
                         ((and (eq? (car (car rest)) prop)
                               (eq? (cadr (car rest)) symbol))
                          (loop (cdr rest)))
                         (else (cons (car rest) (loop (cdr rest)))))))
            (put symbol prop (assq-delete-all theme old))))
         ;; Alter an existing setting:
         (setting
          (put theme 'theme-settings
               (cons (list prop symbol theme (car value))
                     (let loop ((rest theme-settings))
                       (cond ((null? rest) '())
                             ((and (eq? (car (car rest)) prop)
                                   (eq? (cadr (car rest)) symbol))
                              (loop (cdr rest)))
                             (else (cons (car rest) (loop (cdr rest))))))))
          (put symbol prop
               (cons (list theme (car value)) (assq-delete-all theme old))))
         ;; Add a new setting:
         (else
          (when (custom--should-apply-setting theme)
            (unless old
              ;; "If the user changed a variable outside of Customize,
              ;; save the value to a fake theme, `changed'. If the theme
              ;; is later disabled, we use this to bring back the old
              ;; value." Only for variables, and only when the current
              ;; value is not the standard one and would not be recorded
              ;; twice for `user' - the C's three guards.
              (when (and (eq? prop 'theme-value)
                         (custom--bound? symbol)
                         (not (custom--standard-value-p
                               symbol (custom--getter symbol)))
                         (not (and (eq? theme 'user)
                                   (equal? (car value)
                                          (custom--standard-value symbol)))))
                (put symbol 'theme-value
                     `((changed ,(custom--getter symbol)))))))
          (put symbol prop (cons (list theme (car value)) old))
          (put theme 'theme-settings
               (cons (list prop symbol theme (car value)) theme-settings))))
      #f))

    (define (custom-theme-recalc-variable variable)
      ;; GNU Emacs's `custom-theme-recalc-variable' (`custom.el:1739'):
      ;; "Set VARIABLE according to currently enabled custom themes."
      ;; The value is the *theme stack's* head - `(cdr (car ...))' of the
      ;; property, which `enable-theme' keeps ordered so that the head is
      ;; the highest-precedence enabled theme - or the standard.
      ;;--------------------------------------------------------------
      ;; **The property's record is `(THEME EXP)'**, so the expression is
      ;; its cadr - `(cdar ...)' would take `(cdr EXP)', which for a
      ;; self-evaluating EXP like 5 is the one-element list `(5)', and
      ;; `(eval (5))' calls 5.
      ;;--------------------------------------------------------------
      (let* ((theme-value (get variable 'theme-value))
             (valspec (if (pair? theme-value) (cadar theme-value) #f)))
        (unless valspec
          (set! valspec (car (get variable 'standard-value))))
        (when valspec
          ((or (get variable 'custom-set) (custom--setter variable))
           variable
           ;; The spec is an *expression* - Emacs `eval's it - which is
           ;; what `custom-set-variables' stored.
           (eval valspec (current-module))))))

    (define (custom-theme-recalc-face face)
      ;; GNU Emacs's `custom-theme-recalc-face' (`custom.el:1766'): "Set
      ;; FACE according to currently enabled custom themes." The
      ;; realization is `face-spec-recalc''s, which walks the
      ;; `theme-face' records; here there is one frame's worth of faces,
      ;; where Emacs recalcs per frame.
      ;;--------------------------------------------------------------
      (when (facep face)
        (face-spec-recalc face)))

    (define (enable-theme theme)
      ;; GNU Emacs's `enable-theme' (`custom.el:1569'): "Reenable all
      ;; variable and face settings defined by THEME."
      ;;
      ;; The loop re-orders each symbol's property so that THEME's
      ;; record is at its head - which is what makes the head the
      ;; highest-precedence enabled theme when
      ;; `custom-theme-recalc-variable' and `face-spec-recalc' read it.
      ;;--------------------------------------------------------------
      (custom-check-theme theme)
      (let ((settings (or (get theme 'theme-settings) '())))
        (for-each
         (lambda (s)
           (let* ((prop (car s))
                  (symbol (cadr s))
                  (spec-list (or (get symbol prop) '())))
             ;; "We can't call `custom-push-theme' when enabling the
             ;; theme ... But we might need to save a user setting
             ;; outside of Customize, in order to get back to it when
             ;; disabling the theme." - the C's `changed' stash, whose
             ;; three guards `custom-push-theme' carries. It is needed
             ;; here because `enable-theme' can be called for a theme
             ;; whose records were made while it was inhibited, and the
             ;; user's own setting was never stashed. `custom-push-theme'
             ;; has done it already when the theme was enabled; the
             ;; condition below is the C's.
             (when (and (eq? prop 'theme-value)
                        (custom--bound? symbol)
                        (not (assq 'changed spec-list))
                        (not (assq theme spec-list))
                        (not (custom--standard-value-p symbol
                                                       (custom--getter symbol))))
               (put symbol 'theme-value
                    (cons `(changed ,(custom--getter symbol)) spec-list)))
             ;; The re-order: THEME's record to the head.
             (put symbol prop
                  (cons (cddr s)
                        (assq-delete-all theme spec-list)))
             (cond
              ((eq? prop 'theme-face)
               (custom-theme-recalc-face symbol))
              ((eq? prop 'theme-value)
               ;; "Ignore `custom-enabled-themes' and `custom-safe-themes'."
               (unless (memq symbol '(*custom-enabled-themes*
                                      *custom-safe-themes*))
                 (custom-theme-recalc-variable symbol))))))
         settings))
      (unless (eq? theme 'user)
        (*custom-enabled-themes*
         (cons theme (delq theme (*custom-enabled-themes*))))
        ;; "Give the `user' theme the highest priority."
        (enable-theme 'user))
      #f)

    (define (custom-theme-enabled-p theme)
      ;; GNU Emacs's `custom-theme-enabled-p' (`custom.el:1654').
      ;;--------------------------------------------------------------
      (memq theme (*custom-enabled-themes*)))

    (define (disable-theme theme)
      ;; GNU Emacs's `disable-theme' (`custom.el:1671'): "Disable all
      ;; variable and face settings defined by THEME."
      ;;
      ;; Each symbol loses THEME's record - the C's
      ;; `assq-delete-all' - and what is left is the next theme's or
      ;; none; then every touched face and variable is recalculated from
      ;; what remains. The frame-parameter reset the C does afterwards is
      ;; `face-set-after-frame-default''s, which this tree has no
      ;; counterpart for - the faces are recalculated by the loop below,
      ;; which is the same effect.
      ;;--------------------------------------------------------------
      (when (custom-theme-enabled-p theme)
        (let ((settings (or (get theme 'theme-settings) '())))
          (for-each
           (lambda (s)
             (let* ((prop (car s))
                    (symbol (cadr s))
                    (val (assq-delete-all theme (or (get symbol prop) '()))))
               (put symbol prop val)
               (cond
                ((eq? prop 'theme-value)
                 (custom-theme-recalc-variable symbol)
                 (unless (get symbol 'theme-value)
                   (put symbol 'saved-value #f)))
                ((eq? prop 'theme-face)
                 (when (equal? (cadddr s) (get symbol 'saved-face))
                   (put symbol 'saved-face (cadar val)))))))
           settings)
          (for-each
           (lambda (s)
             (when (eq? (car s) 'theme-face)
               (custom-theme-recalc-face (cadr s))))
           settings))
        (*custom-enabled-themes* (delq theme (*custom-enabled-themes*)))
        #t))

    (define (custom-theme-set-faces theme . args)
      ;; GNU Emacs's `custom-theme-set-faces' (`cus-face.el:343'): "Apply
      ;; a list of face specs associated with theme THEME." Each entry is
      ;; `(FACE SPEC [NOW [COMMENT]])'.
      ;;
      ;; The spec is *data* here - Elisp's backquoted spec evaluates to
      ;; this same list - and NOW matters in Emacs only for a face whose
      ;; `defface' has not run yet; `make-face' is called below for
      ;; exactly that case, which is what the C's `facep' check does.
      ;;--------------------------------------------------------------
      (custom-check-theme theme)
      (for-each
       (lambda (entry)
         (let ((face (car entry))
               (spec (cadr entry)))
           ;; "If FACE is actually an alias, customize the face it is
           ;; aliased to." This tree has no face aliases, so there is
           ;; nothing to resolve - named in the file header.
           (if (not (custom--should-apply-setting theme))
               ;; Just update theme settings.
               (custom-push-theme 'theme-face face theme 'set spec)
             ;; Update theme settings and set the face spec.
             (let ((oldspec (or (get face 'theme-face) '())))
               (when (not (and oldspec (eq? 'user (caar oldspec))))
                 (put face 'saved-face spec))
               (custom-push-theme 'theme-face face theme 'set spec)
               ;; The C's NOW - `face-spec-set face spec t' - is
               ;; `face-spec-recalc' here, there being no
               ;; `face-new-frame-defaults' to defer to. The spec-type
               ;; `t' is "record nothing, define and recalculate" -
               ;; `face-defface-spec' would have *overwritten* the
               ;; face's real defface spec with the theme's, which is
               ;; the double-record and the lost spec the first smoke
               ;; run showed.
               (make-face face)
               (face-spec-set face spec #t)))))
       args)
      #f)

    (define (custom-set-faces . args)
      ;; GNU Emacs's `custom-set-faces' (`cus-face.el:332'): "Apply a
      ;; list of face specs for user customizations. This works by
      ;; calling `custom-theme-set-faces' for the `user' theme, a
      ;; special theme referring to settings made via Customize."
      ;;--------------------------------------------------------------
      (apply custom-theme-set-faces 'user args))

    (define (custom-theme-set-variables theme . args)
      ;; GNU Emacs's `custom-theme-set-variables' (`custom.el:1055'):
      ;; "Initialize variables for theme THEME according to settings in
      ;; ARGS. Each of the arguments in ARGS should be a list of this
      ;; form: (SYMBOL EXP [NOW [REQUEST [COMMENT]]])"
      ;;--------------------------------------------------------------
      (custom-check-theme theme)
      (for-each
       (lambda (entry)
         (let ((symbol (car entry)))
           (custom-push-theme 'theme-value symbol theme 'set (cadr entry))
           (when (custom--should-apply-setting theme)
             (put symbol 'saved-value (list (cadr entry)))
             (custom-theme-recalc-variable symbol))))
       args)
      #f)

    (define (custom-set-variables . args)
      ;; GNU Emacs's `custom-set-variables' (`custom.el:1039'): "Initialize
      ;; variables according to settings specified in the init file.
      ;; ... Each argument should be a list of the form
      ;; (SYMBOL EXP [NOW [REQUEST [COMMENT]]])."
      ;; It works by calling `custom-theme-set-variables' for the `user'
      ;; theme - which is this, whole: EXP stays the *expression* the
      ;; theme stack records and `custom-theme-recalc-variable' evals,
      ;; and `saved-value' is what the initializers read on the next
      ;; load.
      ;;--------------------------------------------------------------
      (apply custom-theme-set-variables 'user args))

    (define (custom-theme-reset-faces theme . args)
      ;; GNU Emacs's `custom-theme-reset-faces' (`cus-face.el:406').
      ;;--------------------------------------------------------------
      (custom-check-theme theme)
      (for-each
       (lambda (arg) (custom-push-theme 'theme-face (car arg) theme 'reset))
       args)
      #f)

    (define (custom-theme-reset-variables theme . args)
      ;; GNU Emacs's `custom-theme-reset-variables' (`custom.el:1778').
      ;;--------------------------------------------------------------
      (custom-check-theme theme)
      (for-each
       (lambda (arg) (custom-push-theme 'theme-value (car arg) theme 'reset))
       args)
      #f)

    (define (custom-declare-theme theme feature doc properties)
      ;; GNU Emacs's `custom-declare-theme' (`custom.el:1213').
      ;;--------------------------------------------------------------
      (unless (custom-theme-name-valid-p theme)
        (error "Custom theme cannot be named" theme))
      (unless (memq theme *custom-known-themes*)
        (set! *custom-known-themes*
              (cons theme *custom-known-themes*)))
      (put theme 'theme-feature feature)
      (when doc
        (put theme 'theme-documentation doc))
      (when properties
        (put theme 'theme-properties properties))
      theme)

    (define (provide-theme theme)
      ;; GNU Emacs's `provide-theme' (`custom.el:1284').
      ;;--------------------------------------------------------------
      (unless (custom-theme-name-valid-p theme)
        (error "Custom theme cannot be named" theme))
      (custom-check-theme theme)
      ;; `provide' is Guile's, and the feature is the one `deftheme'
      ;; made - `custom-make-theme-feature''s `THEME-theme'.
      (provide (get theme 'theme-feature)))

    (define (custom-theme--load-path)
      ;; GNU Emacs's `custom-theme--load-path' (`custom.el:1536'): "Expand
      ;; `custom-theme-load-path' into a list of directories. Members
      ;; that either don't exist or are not directories are omitted."
      ;;
      ;; The two symbols have their own meanings. `custom-theme-directory'
      ;; is the user's - Emacs's default is `user-emacs-directory', and
      ;; this tree's is `$XDG_CONFIG_HOME/schemacs', the directory the
      ;; init file lives in; the search is inlined rather than borrowed
      ;; from `(schemacs editor startup)''s `init-path', because
      ;; `startup' imports `simple' which imports this one. `t' is the
      ;; installed themes - Emacs's `data-directory'/themes, and here
      ;; `schemacs/themes' beside the tree's own libraries, found along
      ;; the load path the way `splash-file' finds `splash.txt'.
      ;;--------------------------------------------------------------
      (reverse
       (fold
        (lambda (f out)
          (let ((dir (cond ((eq? f 'custom-theme-directory)
                            (or (*custom-theme-directory*)
                                (let ((xdg (getenv "XDG_CONFIG_HOME"))
                                      (home (getenv "HOME")))
                                  (cond (xdg (string-append xdg "/schemacs"))
                                        (home (string-append
                                               home "/.config/schemacs"))))))
                           ;; `t' is the installed themes - the first
                           ;; load-path directory that has one. This is
                           ;; a *directory* search, which
                           ;; `locate-file-internal' does not do; the
                           ;; walk below is what it would be.
                           ((eq? f 't)
                            (let find ((rest %load-path))
                              (cond ((null? rest) #f)
                                    (else
                                     (let ((dir (string-append
                                                 (car rest)
                                                 "/schemacs/themes")))
                                       (if (file-directory-p dir)
                                           dir
                                           (find (cdr rest))))))))
                           (else f))))
            (if (and dir (file-directory-p dir))
                (cons dir out)
                out)))
        '()
        (*custom-theme-load-path*))))

    (define (custom-available-themes)
      ;; GNU Emacs's `custom-available-themes' (`custom.el:1512'): "Return
      ;; a list of Custom themes available for loading. Search the
      ;; directories specified by `custom-theme-load-path' for files
      ;; named FOO-theme.scm - `.scm' and not `.el', a theme file here
      ;; being Scheme - and return a list of FOO symbols."
      ;;--------------------------------------------------------------
      (let loop ((dirs (custom-theme--load-path)) (out '()))
        (if (null? dirs)
            (reverse out)
            (let* ((dir (car dirs))
                   (files (directory-files dir)))
              (loop (cdr dirs)
                    (fold
                     (lambda (file out)
                       (if (and (> (string-length file)
                                   (string-length "-theme.scm"))
                                (string-suffix? "-theme.scm" file))
                           (let* ((theme (string->symbol
                                          (substring file 0
                                                     (- (string-length file)
                                                        10)))))
                             (if (and (custom-theme-name-valid-p theme)
                                      (not (memq theme out)))
                                 (cons theme out)
                                 out))
                           out))
                     out
                     files))))))

    (define (load-theme theme . optional)
      ;; GNU Emacs's `load-theme' (`custom.el:1340'): "Load Custom theme
      ;; named THEME from its file and possibly enable it."
      ;; NO-CONFIRM and NO-ENABLE are the two optionals.
      ;;
      ;; **The file is Scheme, and that is the departure.** Emacs evals
      ;; an Elisp file with `load'; a theme here is a Scheme file, and
      ;; `load' is Guile's. The contents are the same shape -
      ;; `define-theme', then `custom-theme-set-faces', then
      ;; `provide-theme' - so a theme file reads the same in both.
      ;;--------------------------------------------------------------
      ;; **Both optionals are guarded on their own existence.** A
      ;; `cdr' of an empty list raises - and the no-argument call,
      ;; `(load-theme 'dusk)', which is what an init file says, died
      ;; here before the file search: measured on the real boot,
      ;; `error: init file ...: cdr', with the theme file's presence
      ;; beside the point. Emacs's `&optional' reads answer nil for
      ;; the missing argument; the guard per argument is what that
      ;; is here.
      (let* ((no-confirm (and (pair? optional) (car optional)))
             (no-enable (if (pair? optional)
                            (and (pair? (cdr optional)) (cadr optional))
                            #f)))
        (unless (symbol? theme)
          (error "Wrong type argument: symbolp"))
        (unless (custom-theme-name-valid-p theme)
          (error "Invalid theme name `" (symbol->string theme) "'"))
        ;; "If THEME is already enabled, re-enable it after loading,
        ;; even if NO-ENABLE is t."
        (if no-enable
            (set! no-enable (not (custom-theme-enabled-p theme))))
        ;; "If reloading, clear out the old theme settings."
        (when (custom-theme-p theme)
          (disable-theme theme)
          (put theme 'theme-settings #f)
          (put theme 'theme-feature #f)
          (put theme 'theme-documentation #f))
        (let ((file (locate-file-internal
                     (string-append (symbol->string theme) "-theme.scm")
                     (custom-theme--load-path))))
          (cond
           ((not file)
            (error "Unable to find theme file for `" (symbol->string theme) "'"))
           (else
            (let ((hash
                   ;; `secure-hash' takes a string; the file is read whole.
                   (call-with-input-file file
                     (lambda (port)
                       (let loop ((out '()))
                         (let ((c (read-char port)))
                           (if (eof-object? c)
                               (list->string (reverse out))
                               (loop (cons c out)))))))))
              ;; Emacs's gate: `custom-safe-themes' first, then
              ;; `custom-theme-load-confirm''s question - which is a
              ;; `y-or-n-p' in a `*Custom Theme*' buffer, and that
              ;; question lives in `(schemacs editor files)', a library
              ;; above this one (see the import note). Until the prompt
              ;; can be reached from here, a theme that is not on the
              ;; safe list and is not confirmed is refused - which is
              ;; that question's "no" answer, and is why an init file
              ;; says `#:no-confirm #t' as Emacs's does.
              ;; "Treat this theme as safe in future sessions?" is not
              ;; asked either: nothing writes the answer anywhere, so
              ;; asking would be a lie. Both are named in the header.
              ;; **The refusal is an error, not a silent fall-through.**
              ;; A `when' whose test fails just continues, and the
              ;; `enable-theme' at the end of this function then raised
              ;; "Unknown theme" - a message about the wrong thing. The
              ;; load was *refused*, and Emacs's own words for it are
              ;; `custom.el:1404''s: "Unable to load theme".
              (if (or no-confirm
                      (eq? (*custom-safe-themes*) #t)
                      (member hash (*custom-safe-themes*)))
                  (parameterize ((*custom--inhibit-theme-enable* #t))
                    (load file))
                  (error "Unable to load theme `" (symbol->string theme) "'"))))))
        ;; "Optimization: if the theme changes the `default' face, put
        ;; that entry first. This avoids some `frame-set-background-mode'
        ;; rigmarole by assigning the new background immediately."
        (let* ((settings (or (get theme 'theme-settings) '()))
               (found (find (lambda (s)
                              (and (eq? (car s) 'theme-face)
                                   (eq? (cadr s) 'default)))
                            settings)))
          (when found
            (put theme 'theme-settings
                 (cons found (delq found settings)))))
        ;; "Finally, enable the theme."
        (unless no-enable
          (enable-theme theme))
        #t))

    (define (custom-enabled-themes-set symbol themes)
      ;; GNU Emacs's `custom-enabled-themes'' `:set' function
      ;; (`custom.el:1648'): "Disable all themes not in THEMES", then
      ;; enable each of THEMES, then the `user' theme.
      ;;--------------------------------------------------------------
      (let ((themes (delq 'user (delete-duplicates themes))))
        (for-each
         (lambda (theme)
           (unless (memq theme themes)
             (disable-theme theme)))
         (*custom-enabled-themes*))
        (for-each
         (lambda (theme)
           (catch #t
             (lambda ()
               (if (custom-theme-p theme)
                   (enable-theme theme)
                   (load-theme theme)))
             (lambda args #f)))
         (reverse themes))
        (enable-theme 'user)
        (*custom-enabled-themes* themes)))

    (define-syntax define-theme
      (lambda (x)
        (syntax-case x ()
          ((_ theme)
           #'(custom-declare-theme 'theme
                (string->symbol
                 (string-append (symbol->string 'theme) "-theme"))
                #f '()))
          ((_ theme doc property ...)
           (string? (syntax->datum #'doc))
           #'(custom-declare-theme 'theme
                (string->symbol
                 (string-append (symbol->string 'theme) "-theme"))
                doc
                (syntax->datum #'(property ...)))))))
    )
)
