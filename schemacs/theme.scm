(define-library (schemacs theme)
  ;; GNU Emacs's theme engine - the second half of `custom.el', which
  ;; carries two unrelated things: the `defcustom' machinery, and the
  ;; themes this file is named for. Emacs keeps both in `custom.el'
  ;; under its own ";;; Custom Themes" divider (`custom.el:870'); this
  ;; tree gives the second half its own module, because the theme
  ;; commands are `M-x' commands whose interactive forms prompt with
  ;; `completing-read' and register with the command loop - and this
  ;; library sits ABOVE the minibuffer and the keyboard, which the
  ;; defcustom half cannot: `minibuffer' imports `simple', `simple'
  ;; imports `custom', so an edge `custom -> minibuffer' is a cycle
  ;; (measured, a compile of `custom.scm' with that edge raised "no
  ;; binding `completing-read'" from inside the minibuffer interface
  ;; build, and with it gone every library in the tree compiled again).
  ;; The mirror-the-file rule gives way here - a deliberate break, the
  ;; module named for what it is rather than for an Emacs file, as
  ;; `derived.sld' is for `easy-mmode.el'.
  ;;
  ;; The defcustom half stays in `(schemacs custom)': the
  ;; `define-custom' machinery, the initializers, the groups. The two
  ;; halves share the `user' theme - `custom-set-faces' and
  ;; `custom-set-variables' are here because they record into it - and
  ;; the properties they read and write (`theme-face', `theme-value',
  ;; `saved-value', `standard-value') are the seam between them, which
  ;; is the C's own seam: `custom.el:1418''s comment says the theme
  ;; settings and the saved values are the same records.
  ;;
  ;; The four `custom--' helpers this library reads are
  ;; `(schemacs custom)''s, exported for it.
  ;;
  ;; **Departures, all named where they are made**:
  ;;
  ;;   * A theme file is Scheme (`.scm'), not Elisp (`.el'), and is read
  ;;     with Guile's `load'. Its contents are the same shape -
  ;;     `define-theme', `custom-theme-set-faces', `provide-theme'.
  ;;   * `custom-safe-themes' holds a theme file's *text* rather than its
  ;;     SHA-256, because this Guile has no `sha256' binding (checked:
  ;;     `(gcrypt hash)' is not installed). The membership test and the
  ;;     `default' element work as Emacs's do; a hash copied from an
  ;;     Emacs `custom-file' will not match.
  ;;   * `custom-theme-load-confirm' asks the same question but does not
  ;;     first show the theme in a `*Custom Theme*' buffer: that is
  ;;     `with-temp-buffer' and `save-window-excursion', neither ported.
  ;;     The "Treat this theme as safe in future sessions?" half is not
  ;;     asked, since there is no `custom-file' to record the answer in.
  ;;   * `enable-theme' completes over the known themes that have
  ;;     settings where Emacs completes over `obarray' with that as the
  ;;     predicate - the same set, there being no obarrays here.
  ;;   * `custom-theme--installed-directory' is Emacs's inline
  ;;     `(expand-file-name "themes/" data-directory)' given a name: this
  ;;     tree has no `data-directory', and its installed themes are
  ;;     `schemacs/themes' on the load path.

  (import
    (scheme base)
    (scheme eval)
    ;; `custom-set-variables' evaluates each saved expression in the
    ;; module that called it - Emacs `eval's it in the init file's
    ;; context, which is the same thing here.
    (only (guile) current-module string->symbol
          ;; `%load-path' is where the installed themes directory is
          ;; looked for - `data-directory'/themes being what Emacs
          ;; searches. `call-with-input-file' and `load' are what
          ;; `load-theme' reads a theme file with, and `catch' is what
          ;; `custom-enabled-themes-set' keeps one theme's error from
          ;; stopping the others with. `cadar'/`caddr'/`cadddr' the walks
          ;; read (`caddr' was missing and the compiler said "possibly
          ;; unbound" - it is `custom-theme-set-variables'' NOW value);
          ;; `provide' is `provide-theme''s.
          %load-path call-with-input-file load catch
          cadar caddr cadddr provide getenv
          ;; `custom-theme--installed-directory' resolves a *relative*
          ;; load-path entry (`-L .' puts one there) against the
          ;; process directory, which is what `getcwd' is for.
          getcwd
          ;; Guile's `format' (destination first) for the error messages,
          ;; which Emacs spells `(error "..." THEME)' and Guile would
          ;; print as a message plus an irritant. The C's `format' is
          ;; editfns's and is not wanted here.
          format
          ;; `set-module-declarative?!' and `datum->syntax' are for the
          ;; not-declarative declaration at the top of the body, which
          ;; `load-theme''s `load' needs - the same statement
          ;; `(schemacs custom)' makes for the same reason.
          set-module-declarative?! datum->syntax module-variable resolve-module
          ;; `define-theme' is a `syntax-case' macro, as `easy-mmode''s
          ;; `define-minor-mode' is: it needs `syntax->datum' to read the
          ;; docstring and the property list it is handed. These are
          ;; Guile's, not `(scheme base)`'s.
          syntax-case syntax syntax->datum)
    (only (srfi srfi-1) delete-duplicates filter find fold)
    ;; `string-suffix?' is srfi-13's - `custom-available-themes' tests
    ;; the "-theme.scm" name with it, as the C's `string-match-p' does.
    (only (srfi srfi-13) string-suffix?)
    ;; `delq' is Elisp's, and `(schemacs subr)' is where
    ;; `assq-delete-all' beside it lives.
    (only (schemacs subr) delq assq-delete-all)
    ;; The four `custom--' helpers the theme machinery reads:
    ;; `custom--bound?' asks whether a variable has a binding to set,
    ;; `custom--getter'/`custom--setter' are that binding's two halves,
    ;; `custom--standard-value' the `defcustom''s own default, and
    ;; `custom--standard-value-p' compares a value against it. They are
    ;; the defcustom half's, exported for this one - the two halves
    ;; share `custom.el' and nothing else. There is no cycle: this
    ;; library imports `custom', and `custom' imports no theme.
    (only (schemacs custom)
          define-custom
          custom--bound? custom--getter custom--setter
          custom--standard-value custom--standard-value-p)
    ;; `get' and `put' are `fns.c`'s symbol properties - the theme
    ;; records live on them.
    (only (schemacs intervals) get put)
    ;; The faces a theme sets: `make-face' initialises one whose
    ;; `defface' has not run, `facep' asks whether it has,
    ;; `face-spec-set' installs a theme's spec, and `face-spec-recalc'
    ;; is what `custom-theme-recalc-face' runs. `face-attribute' answers
    ;; `:extend' in `face-spec-recalc'.
    (only (schemacs faces)
          face-attribute face-spec-set face-spec-recalc make-face facep
          face-list
          ;; the theme parameters the specs test, and the mode recomputed
          *frame-background-mode* *frame-background-mode-function*
          face-attribute-merged-with
          ;; `custom--frame-color-default' asks whether the frame is on a
          ;; window system, which is `(window-system FRAME)' - and the
          ;; only frame's answer is this parameter.
          *window-system*)
    ;; The paths a theme file is searched along and the predicates that
    ;; guard it.
    (only (schemacs fileio) file-directory-p locate-file-internal
          ;; `load-theme''s safety gate compares a theme file's directory
          ;; against the installed themes directory, as Emacs does with
          ;; `file-name-directory' and `expand-file-name'.
          file-name-directory-part file-name-as-directory expand-file-name)
    ;; `y-or-n-p' is `subr.el''s - the confirmation the safety gate
    ;; asks, which `load-theme' reaches from here because this library
    ;; is above `(schemacs files)'... no: `files' imports this
    ;; library's neighbours, not this one. The import edge is checked
    ;; below, where `y-or-n-p' is imported.
    (only (schemacs files) locate-file y-or-n-p)
    ;; A theme directory's files, which `custom-available-themes' lists.
    (only (schemacs diredc) directory-files)
    ;; The command seam: `M-x' registration and the completing reader.
    ;; This library is ABOVE both, which is the whole point of the
    ;; module.
    (only (schemacs command) define-command)
    (only (schemacs minibuffer) completing-read)
    ;; `disable-theme''s last act is Emacs's own: put the frame's colours
    ;; back and recalculate every face for it - `face-set-after-frame-default'
    ;; (`faces.el:2274'), which lives in `frame.scm' because it reads
    ;; frame parameters.
    (only (schemacs frame)
          *frame-list* set-frame-parameter face-set-after-frame-default))

  (export
   ;; The theme commands - `M-x load-theme' and its neighbours.
   load-theme enable-theme disable-theme
   *custom-known-themes* *custom-enabled-themes* *custom-safe-themes*
   *custom--inhibit-theme-enable*
   *custom-theme-directory* *custom-theme-load-path*
   custom-theme-p custom-check-theme custom-theme-enabled-p
   custom-push-theme custom-theme-recalc-variable custom-theme-recalc-face
   custom-theme-set-faces custom-set-faces
   custom-theme-set-variables custom-set-variables
   custom-theme-reset-faces custom-theme-reset-variables
   custom-declare-theme provide-theme
   custom-theme--load-path custom-available-themes
   custom-enabled-themes-set define-theme)

  (begin

    ;;----------------------------------------------------------------
    ;; This library is not declarative - Guile's `#:declarative? #f'
    ;;----------------------------------------------------------------
    ;; `load-theme' reads a theme file with `load', so this module is
    ;; not a declarative one. The statement is made the way
    ;; `(schemacs custom)' makes its own, for the same two
    ;; reasons: the warning is silenced by neither half alone, and a
    ;; *declarative* module lets the compiler fold a definition into
    ;; its callers' code, so a later `set!' stops being seen. The
    ;; definitions at risk here are the theme parameters -
    ;; `*custom-enabled-themes*' and friends, which `enable-theme',
    ;; `disable-theme' and `load-theme' set and every reader reads -
    ;; and the fold would leave a compiled reader answering the value
    ;; it was compiled with.
    (define-syntax %not-declarative!
      (lambda (x)
        (set-module-declarative?! (current-module) #f)
        (datum->syntax x '(if #f #f))))
    (%not-declarative!)
    ;; The macro alone is not enough: `library' expands to `(define-module
    ;; ...)' *followed by* the body, and that `define-module' is evaluated
    ;; when the library loads, re-declaring the module with the default
    ;; declarative flag after the expansion-time flip has worn off. The
    ;; second statement runs after it. `(schemacs startup)' and
    ;; `(schemacs custom)' each carry the same pair.
    (set-module-declarative?!
     (resolve-module '(schemacs theme) #f)
     #f)

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

    (define-custom *custom-enabled-themes* '()
      "List of enabled Custom Themes, highest precedence first.
This list does not include the `user' theme, which is set by
Customize and always takes precedence over other Custom Themes.

This variable cannot be defined inside a Custom theme; there, it
is simply ignored.

Setting this variable through Customize calls `enable-theme' or
`load-theme' for each theme in the list."
      :type '(repeat symbol) :group 'customize)
    ;; ^ GNU Emacs's `custom-enabled-themes' (`custom.el:1630'). The
    ;; `:set' function there - which disables the themes dropped from
    ;; the list and enables the ones added - is what
    ;; `custom-enabled-themes-set' below is.

    (define-custom *custom-safe-themes* '(default)
      "Themes that are considered safe to load.
If the value is a list, each element should be either the SHA-256
hash of a safe theme file, or the symbol `default', which stands
for any theme in the built-in Emacs theme directory (a directory
named \"themes\" in `data-directory').

If the value is t, Emacs treats all themes as safe.

This variable cannot be set in a Custom theme."
      :type '(choice (repeat :tag "List of safe themes" (choice string (const :tag "Built-in themes" default))) (const :tag "All themes" t)) :group 'customize :version "24.1")
    ;; ^ GNU Emacs's `custom-safe-themes' (`custom.el:1582'): the SHA-256
    ;; hashes of theme files the user has pronounced safe. `t' means
    ;; every theme is safe; the symbol `default' means every theme in the
    ;; *installed* themes directory is - and that is Emacs's own default
    ;; value, `'(default)', which is why the stock themes load without a
    ;; question. ours defaulted to `\'()' and there was no `default'
    ;; branch in `load-theme''s gate, so a stock theme was refused: the
    ;; "Unable to load theme" a `M-x load-theme wombat' answered with.
    ;; A hash not in the list prompts - Emacs's
    ;; `custom-theme-load-confirm', which is a `y-or-n-p' question - and
    ;; that prompt is ported below.

    (define-custom *custom-theme-directory* #f
      "Default user directory for storing custom theme files.
The command `customize-create-theme' writes theme files into this
directory.  By default, Emacs searches for custom themes in this
directory first---see `custom-theme-load-path'."
      :type 'directory :group 'customize :version "22.1")
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
        (error (format #f "Unknown theme `~a'" theme))))

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
          ;; Emacs's `(setq valspec (get variable 'standard-value))` and
          ;; then `(car valspec)` - where `(car nil)` is nil. A variable
          ;; this tree never declared has no `standard-value` at all, so
          ;; the `car` is guarded rather than applied to `#f`.
          (let ((standard (get variable 'standard-value)))
            (set! valspec (and (pair? standard) (car standard)))))
        (when valspec
          (let ((setter (or (get variable 'custom-set)
                            (get variable 'custom-writer))))
            (if setter
                (setter variable
                        ;; The spec is an *expression* - Emacs `eval's
                        ;; it - which is what `custom-set-variables'
                        ;; stored.
                        (eval valspec (current-module)))
                ;; **A variable this tree does not have.** Emacs's
                ;; `set-default` would make the global binding; a Scheme
                ;; binding cannot be created from a symbol, so the
                ;; setting stays on the theme's stack and is not
                ;; applied - a named departure. `frame-background-mode`
                ;; is registered for theme data in `faces.sld`.
                #f)))))

    (define (custom-theme-recalc-face face)
      ;; GNU Emacs's `custom-theme-recalc-face' (`custom.el:1766'): "Set
      ;; FACE according to currently enabled custom themes." The
      ;; realization is `face-spec-recalc''s, which walks the
      ;; `theme-face' records; here there is one frame's worth of faces,
      ;; where Emacs recalcs per frame.
      ;;--------------------------------------------------------------
      (when (facep face)
        (face-spec-recalc face)))

    (define-command (enable-theme theme)
      ;; GNU Emacs's `enable-theme' (`custom.el:1569'): "Reenable all
      ;; variable and face settings defined by THEME."
      ;;
      ;; The loop re-orders each symbol's property so that THEME's
      ;; record is at its head - which is what makes the head the
      ;; highest-precedence enabled theme when
      ;; `custom-theme-recalc-variable' and `face-spec-recalc' read it.
      ;;
      ;; **The interactive spec is Emacs's** (`custom.el:1580'): it asks
      ;; for a theme whose `theme-settings' property exists, requiring a
      ;; match. Emacs completes against `obarray' with that as the
      ;; predicate; this tree has no obarray, so the collection is the
      ;; names of the known themes that have settings - the same set the
      ;; predicate selects, since `theme-settings' is only ever put on a
      ;; theme that has been declared.
      ;;--------------------------------------------------------------
      "Reenable all variable and face settings defined by THEME.

After this function completes, THEME will have the highest
precedence (after `user') among enabled themes.

Note that any already-enabled themes remain enabled after this
function runs.  To disable other themes, use `disable-theme'."
      (interactive
       (list (string->symbol
              (completing-read
               "Enable custom theme: "
               (map (lambda (s) (symbol->string s))
                    (filter (lambda (s) (get s 'theme-settings))
                            *custom-known-themes*))
               #f #t))))
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

    (define-command (disable-theme theme)
      ;; GNU Emacs's `disable-theme' (`custom.el:1671'): "Disable all
      ;; variable and face settings defined by THEME."
      ;;
      ;; Each symbol loses THEME's record - the C's
      ;; `assq-delete-all' - and what is left is the next theme's or
      ;; none; then the frame's two colours are put back and every face
      ;; recalculated for it. **The frame-parameter reset is not
      ;; optional**: since `face-spec-reset-face' stopped wiping the
      ;; `default' face's colours on a graphic frame - which is what
      ;; keeps its font `:height' alive, see `faces.scm' - the theme's
      ;; colour would otherwise outlive the theme.
      ;;
      ;; **The interactive spec is Emacs's** (`custom.el:1683'): the
      ;; enabled themes only, and a match is required.
      ;;--------------------------------------------------------------
      "Disable all variable and face settings defined by THEME.
See `custom-enabled-themes' for a list of enabled themes."
      (interactive
       (list (string->symbol
              (completing-read
               "Disable custom theme: "
               (map (lambda (s) (symbol->string s))
                    (*custom-enabled-themes*))
               #f #t))))
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
          ;; "We must reset the fg and bg color frame parameters, or
          ;; `face-set-after-frame-default' will use the existing
          ;; parameters, which could be from the disabled theme."
          (for-each
           (lambda (frame)
             (set-frame-parameter
              frame 'background-color
              (custom--frame-color-default frame ':background
                                           "unspecified-bg" "white"))
             (set-frame-parameter
              frame 'foreground-color
              (custom--frame-color-default frame ':foreground
                                           "unspecified-fg" "black")))
           (*frame-list*))
          ;; "Recompute faces on all frames."
          (if (null? (*frame-list*))
              ;; **Not a case Emacs can be in** - `(frame-list)' always
              ;; has a frame at runtime, even in batch - while this tree
              ;; can be: faces exist before a front end opens a display,
              ;; and the test suites run exactly there. The one set of
              ;; realized attributes still holds the theme's values, so
              ;; it is recalculated all the same; that is `faces.scm''s
              ;; one-set model, not a second code path.
              (for-each face-spec-recalc (face-list))
              (for-each face-set-after-frame-default (*frame-list*))))
        (*custom-enabled-themes* (delq theme (*custom-enabled-themes*)))
        #t))

    (define (custom--frame-color-default frame attribute tty-default x-default)
      ;; GNU Emacs's `custom--frame-color-default' (`custom.el:1727'):
      ;;
      ;;   (let ((col (face-attribute 'default attribute t)))
      ;;     (cond
      ;;      ((and col (not (eq col 'unspecified))) col)
      ;;      ((null (window-system frame)) tty-default)
      ;;      ((setq col (x-get-resource nil nil)) col)
      ;;      (t x-default)))
      ;;
      ;; **The first test answers nothing here, and that is the honest
      ;; answer rather than a shortcut.** Emacs's FRAME `t' is "the
      ;; defaults for FACE (for new frames)" (`faces.el:466') - a set it
      ;; keeps apart from a frame's realized faces. This tree has one set
      ;; and no frame defaults (`faces.scm''s header says so), so asking
      ;; `face-attribute' would report the *realized* colour, which is
      ;; the very thing being replaced. Measured on Emacs 31.1:
      ;; `(face-attribute 'default :background t)' is `unspecified' both
      ;; with a theme loaded and after it is disabled, so the Elisp falls
      ;; through to these defaults too. `x-get-resource' has no
      ;; counterpart - there is no X resource database here - which is
      ;; the same answer Emacs gives on a machine with none.
      ;;--------------------------------------------------------------
      (if (*window-system*) x-default tty-default))

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
             (let ((now (and (pair? (cddr entry)) (caddr entry)))
                   (oldspec (or (get face 'theme-face) '())))
               (when (not (and oldspec (eq? 'user (caar oldspec))))
                 (put face 'saved-face spec))
               (custom-push-theme 'theme-face face theme 'set spec)
               ;; **The C's `(when (or now immediate (facep face)) ...)**
               ;; (`cus-face.el`): a face the theme names but this tree
               ;; has never defined is *recorded* and not applied.
               ;; Emacs has a `cursor` face (and `fringe`, `tool-bar`, …)
               ;; from `faces.el`; a theme ported from Modus names many
               ;; faces this editor does not define, and recalculating
               ;; one raised "Invalid face" and killed the whole load.
               ;; When the face is defined later its `face-spec-recalc`
               ;; picks the record up, which is the same deferred effect.
               (when (or now (facep face))
                 ;; The C's NOW is `face-spec-set face spec t' - the
                 ;; spec-type `t' is "record nothing, define and
                 ;; recalculate"; `face-defface-spec` would have
                 ;; *overwritten* the face's real defface spec.
                 (make-face face)
                 (face-spec-set face spec #t))))))
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
        (error (format #f "Custom theme cannot be named ~s" theme)))
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
        (error (format #f "Custom theme cannot be named ~s" theme)))
      (custom-check-theme theme)
      ;; `provide' is Guile's, and the feature is the one `deftheme'
      ;; made - `custom-make-theme-feature''s `THEME-theme'.
      (provide (get theme 'theme-feature)))

    (define (custom-theme--installed-directory)
      ;; The installed themes directory - GNU Emacs's
      ;; `(expand-file-name "themes/" data-directory)' (`custom.el:1541'),
      ;; whose answer `load-theme''s safety gate compares a theme file's
      ;; directory against when `custom-safe-themes' holds `default'.
      ;;
      ;; This tree has no `data-directory': the installed themes are
      ;; `schemacs/themes' beside the tree's own libraries, and the first
      ;; load-path directory that has one is where they are. This is a
      ;; *directory* search, which `locate-file-internal' does not do;
      ;; the walk is what it would be.
      ;;--------------------------------------------------------------
      (let find ((rest %load-path))
        (cond ((null? rest) #f)
              (else
               ;; Expanded, as Emacs's `(expand-file-name "themes"
               ;; data-directory)' is: a load-path entry may be
               ;; relative (`-L .' puts one there), and the gate compares
               ;; this string against a located file's directory, which
               ;; is absolute.
               (let ((dir (expand-file-name "schemacs/themes"
                                             (file-name-as-directory
                                              (getcwd)))))
                 (if (file-directory-p dir)
                     dir
                     (find (cdr rest))))))))

    (define (custom-theme--load-path)
      ;; GNU Emacs's `custom-theme--load-path' (`custom.el:1536'): "Expand
      ;; `custom-theme-load-path' into a list of directories. Members
      ;; that either don't exist or are not directories are omitted."
      ;;
      ;; The two symbols have their own meanings. `custom-theme-directory'
      ;; is the user's - Emacs's default is `user-emacs-directory', and
      ;; this tree's is `$XDG_CONFIG_HOME/schemacs', the directory the
      ;; init file lives in; the search is inlined rather than borrowed
      ;; from `(schemacs startup)''s `init-path', because
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
                           ;; load-path directory that has one.
                           ((eq? f 't)
                            (custom-theme--installed-directory))
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

    (define (custom-theme-load-confirm hash)
      ;; GNU Emacs's `custom-theme-load-confirm' (`custom.el:1486'):
      ;; "Query the user about loading a Custom theme that may not be
      ;; safe. The theme should be in the current buffer. If the user
      ;; agrees, query also about adding HASH to `custom-safe-themes'."
      ;;
      ;; **The question is the same; the buffer before it is not.** In
      ;; Emacs the theme file is put in a `*Custom Theme*' buffer by the
      ;; caller's `with-temp-buffer' and shown before the question, so
      ;; the user can read the code they are agreeing to run. Neither
      ;; `with-temp-buffer' nor `save-window-excursion' is ported yet -
      ;; they would be `subr.el`'s and `window.el`'s - so this asks
      ;; without the display. The answer is the same, and so is the
      ;; second question's *condition*: Emacs asks "Treat this theme as
      ;; safe in future sessions?" only when there is a `custom-file' or
      ;; `user-init-file' to write it into, and this tree has neither.
      ;;--------------------------------------------------------------
      ;; `customize-push-and-save' needs `custom-file'; until there is
      ;; one the answer cannot be recorded, so the second question is
      ;; not asked - Emacs's own `(or custom-file user-init-file)' is
      ;; false here.
      (y-or-n-p "Loading a theme can run Lisp code.  Really load? "))

    (define-command (load-theme theme . optional)
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
      "Load Custom theme named THEME from its file and possibly enable it.
The theme file is named THEME-theme.scm, in one of the directories
specified by `custom-theme-load-path'.

If the theme is not considered safe by `custom-safe-themes',
refuse to load it.  But if optional arg NO-CONFIRM is non-nil,
load the theme without checking.

Normally, this function also enables THEME.  If optional arg
NO-ENABLE is non-nil, load the theme but don't enable it, unless
the theme was already enabled.

Note that enabling THEME does not disable any other
already-enabled themes.  If THEME is enabled, it has the highest
precedence (after `user') among enabled themes.  To disable other
themes, use `disable-theme'.

This function is normally called through Customize when setting
`custom-enabled-themes'.  If used directly in your init file, it
should be called with a non-nil NO-CONFIRM argument, or after
`custom-safe-themes' has been loaded.

Return t if THEME was successfully loaded, nil otherwise."
      (interactive
       (list (string->symbol
              (completing-read
               "Load custom theme: "
               (map (lambda (s) (symbol->string s))
                    (custom-available-themes))))
             #f #f))
      (let* ((no-confirm (and (pair? optional) (car optional)))
             (no-enable (if (pair? optional)
                            (and (pair? (cdr optional)) (cadr optional))
                            #f)))
        (unless (symbol? theme)
          (error "Wrong type argument: symbolp"))
        (unless (custom-theme-name-valid-p theme)
          (error (format #f "Invalid theme name `~a'" theme)))
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
            (error (format #f "Unable to find theme file for `~a'" theme)))
           ;; Emacs's safety gate (`custom.el:1391'): a theme is safe
           ;; without a question when NO-CONFIRM says so, when
           ;; `custom-safe-themes' is `t', or when it is in the
           ;; *installed* themes directory and `custom-safe-themes' holds
           ;; `default' - which is its default value, and is what makes
           ;; the stock themes load. Otherwise the file's hash is checked
           ;; against the list, and failing that the user is asked.
           ((or no-confirm
                (eq? (*custom-safe-themes*) #t)
                (and (memq 'default (*custom-safe-themes*))
                     (let ((installed (custom-theme--installed-directory)))
                       (and installed
                            (equal? (file-name-directory-part file)
                                   (file-name-as-directory installed))))))
            (parameterize ((*custom--inhibit-theme-enable* #t))
              (load file)))
           (else
            (let ((hash
                   ;; Emacs's `secure-hash' of the file's contents, with
                   ;; one departure named in the header: no `sha256' is
                   ;; available in this Guile (`(gcrypt hash)' is not
                   ;; installed), so what is compared is the file's
                   ;; *text*. Membership works the same for a value put
                   ;; in `custom-safe-themes' here; a SHA-256 copied
                   ;; from an Emacs `custom-file' would never match.
                   (call-with-input-file file
                     (lambda (port)
                       (let loop ((out '()))
                         (let ((c (read-char port)))
                           (if (eof-object? c)
                               (list->string (reverse out))
                               (loop (cons c out)))))))))
              ;; **The refusal is an error, not a silent fall-through.**
              ;; A `when' whose test fails just continues, and the
              ;; `enable-theme' at the end of this function then raised
              ;; "Unknown theme" - a message about the wrong thing. The
              ;; load was *refused*, and Emacs's own words for it are
              ;; `custom.el:1409''s: "Unable to load theme".
              (if (or (member hash (*custom-safe-themes*))
                      (custom-theme-load-confirm hash))
                  (parameterize ((*custom--inhibit-theme-enable* #t))
                    (load file))
                  (error (format #f "Unable to load theme `~a'" theme)))))))
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
