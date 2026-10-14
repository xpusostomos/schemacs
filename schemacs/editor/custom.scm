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
  ;;      everything goes through them. **The variable itself is an
  ;;      ordinary `(define …)', read as its name**, exactly as `defcustom`
  ;;      makes one - *not* a parameter, which would have made every use of
  ;;      a user option read `(foo)' instead of `foo'.
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
  ;; **Not ported, each for want of a thing this tree does not have**: the
  ;; Customize buffers themselves (`customize-*', `cus-edit.el', the widget
  ;; library), themes, `setopt' and `custom-set-variables' (there is no
  ;; `custom-file' to save into and nothing writes `saved-value' yet - the
  ;; initializers read the property, so the day something does, they honour
  ;; it), `custom-initialize-delay' and `custom-initialize-after-file-load'
  ;; (both exist for the dump and for `after-load-functions', neither of
  ;; which this tree has), and `defface'/'defgroup'
  ;; (`custom-declare-face', `custom-declare-group') - `defface' is the
  ;; next piece, and it is a face library's.

  (import
    (scheme base)
    ;; `syntax-case' and friends, for `define-custom' below - the same
    ;; device `easy-mmode`'s `define-minor-mode' uses, and for the same
    ;; reason: a clause list cannot be walked by `syntax-rules'. `syntax'
    ;; itself is what `#'` reads as, and leaving it out is the "unexpected
    ;; syntax in form ()" the compiler says when it is missing.
    (only (guile) identifier? quasisyntax syntax syntax->datum syntax-case
          unsyntax unsyntax-splicing)
    ;; `get' and `put' are `fns.c`'s symbol properties; see the header.
    (only (schemacs editor intervals) get put))

  (export
   define-custom
   custom-declare-variable
   custom-initialize-default custom-initialize-set custom-initialize-reset
   custom-initialize-changed
   custom-add-to-group custom-add-option custom-add-frequent-value
   custom-add-version custom-add-package-version custom-add-load
   custom-add-link custom-add-dependencies
   custom-handle-keyword
   custom-variable-p custom--standard-value
   *custom-current-group-alist* custom-current-group
   *custom-declare-variable-hook* *custom-dont-initialize*
   )

  (begin

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
      ;; **It defines an ordinary variable** - `(define name standard)`,
      ;; read as `name`, written with `set!` - which is what Emacs's
      ;; `defcustom' makes: a variable that is read by naming it. It is
      ;; *not* a parameter, and that was a deliberate undoing (2026-10-14):
      ;; a parameter reads as `(name)', so every use of a user option would
      ;; have departed from Emacs's spelling, and the thing that bought -
      ;; `parameterize' - is a save/set!/restore that a macro over a plain
      ;; variable does just as well (`save-current-buffer` in `buffer.scm`
      ;; already does it by hand with `dynamic-wind').
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
                 (define name standard)
                 (custom-declare-variable
                  'name
                  (lambda () standard)
                  docstring
                  (lambda (symbol) name)
                  (lambda (symbol value) (set! name value))
                  #,@(map (lambda (clause)
                            ;; `(list ':type <the value expression>)' - the
                            ;; keyword as data and the value as code, which
                            ;; is the clause list `custom-declare-variable'
                            ;; walks.
                            #`(list (quote #,(car clause)) #,(cdr clause)))
                          clauses))))))))

    )
)