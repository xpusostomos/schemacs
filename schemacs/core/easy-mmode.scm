(define-library (schemacs core easy-mmode)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/easy-mmode.el':
  ;; the macros that write a major or minor mode's boilerplate. What is
  ;; here is `define-minor-mode' and the `easy-mmode-pretty-mode-name'
  ;; it names its modes with.
  ;;
  ;; It is a *macro* and not a function, and that matters: a minor mode
  ;; is a command, a variable, a hook and a mode-line entry, and the
  ;; names of three of those are made from the mode's name. Written out
  ;; by hand at each mode - which is what this tree did until
  ;; 2026-10-06, `overwrite-mode' and `binary-overwrite-mode' being two
  ;; copies of it - a mode that forgot a piece of the boilerplate looked
  ;; exactly like one that had it, which is how the lighter came out
  ;; empty and the message came out wrong.
  ;;
  ;; **How the names are made, and why this is not `syntax-rules'.** A
  ;; `syntax-rules' template can only reuse identifiers it is given, so
  ;; `(define-derived-mode ...)' in this tree is handed its keymap's and
  ;; hook's names by the caller (see the note there). `define-minor-mode'
  ;; makes *three* - the hook, and the variable's two accessors when no
  ;; `:variable' is given - and it can, because this Guile has
  ;; `syntax-case' and `datum->syntax': a name can be built from the
  ;; mode's own identifier, with the *call site's* lexical context, which
  ;; is what keeps it hygienic and makes the binding visible where the
  ;; mode was defined. `(define-minor-mode overwrite-mode ...)' leaves a
  ;; real binding named `overwrite-mode-hook' in the defining library.
  ;;
  ;; Not ported from easy-mmode.el, each with what it would need:
  ;;
  ;;   - `:set', `:initialize', `:type', the `:group' and `:version'
  ;;     keywords and `customize-mark-as-set': all of that is
  ;;     `defcustom`, and a minor mode's variable is a buffer-local slot
  ;;     here, which `define-custom` - a parameter - cannot be. The
  ;;     keywords are *accepted and dropped* rather than refused, because
  ;;     `define-globalized-minor-mode` passes `:group` and `:version`
  ;;     through.
  ;;
  ;; `:global` **is** carried: it is the difference between a value in
  ;; each buffer's slot table and one shared default, which is
  ;; `default-value`/`set-default` (`data.scm`).
  ;;   - `:keymap' and `minor-mode-map-alist': per-mode keymaps are not
  ;;     ported, so a mode's map has nowhere to be consulted from.
  ;;   - `easy-mmode--mode-docstring', which invents a docstring when
  ;;     none is given or when the given one does not mention ARG.
  ;;   - `force-mode-line-update', which the generated function ends
  ;;     with: this redisplay redraws unconditionally, so it has no
  ;;     reader (the same note `dired.sld:1948' carries).
  ;;   - the obsolete positional INIT-VALUE/LIGHTER/KEYMAP triplet, and
  ;;     `:extra-args'.

  (import
    (scheme base)
    (scheme char)
    ;; `datum->syntax' is how a name is built from the mode's identifier,
    ;; and `syntax->datum' how a clause's keyword is read.
    ;; `quasisyntax' and `unsyntax' are what the templates below are
    ;; written with - `#`' and `#,' - and `(scheme base)' has neither.
    (only (guile) datum->syntax delq format identifier? quasisyntax syntax
          syntax->datum syntax-case unsyntax unsyntax-splicing)
    (only (schemacs subr)
          add-hook add-minor-mode remove-hook run-hooks string-replace
          *after-change-major-mode-hook* *global-minor-modes*)
    (only (schemacs buffer)
          buffer-list buffer-local-value current-buffer
          set-buffer-local-value! with-current-buffer)
    ;; `put` records `globalized-minor-mode` on the mode's symbol, which
    ;; is `fns.c`'s symbol plist.
    (only (schemacs intervals) put)
    ;; `default-value` and `set-default` are what a `:global` mode's state
    ;; is stored in - `data.c`'s, as `buffer-local-value` is `buffer.c`'s.
    (only (schemacs data) default-value set-default default-boundp)
    (only (schemacs editfns) current-message message)
    (only (schemacs command)
          called-interactively? current-prefix-arg define-command
          uarg->integer)
    )

  (export
   define-minor-mode
   define-globalized-minor-mode
   easy-mmode-pretty-mode-name
   )

  (begin

    (define (%syntax->list stx)
      ;; A syntax object that is a proper list, as a list of syntax
      ;; objects. Guile has this function but does not export it from
      ;; `(guile)', so it is written out here.
      ;;--------------------------------------------------------------
      (let loop ((s stx) (out '()))
        (syntax-case s ()
          (() (reverse out))
          ((a . d) (loop (syntax d) (cons (syntax a) out)))
          (_ (reverse out)))))

    (define (%list-head lst n)
      ;; The first N elements of LST. R7RS has `list-tail' and not this.
      ;;--------------------------------------------------------------
      (if (or (= n 0) (null? lst))
          '()
          (cons (car lst) (%list-head (cdr lst) (- n 1)))))

    (define (%drop-suffix suffix string)
      ;; SUFFIX only at the *end* of STRING - Elisp's `"-mode\\'"'.
      ;;--------------------------------------------------------------
      (let ((n (string-length suffix)))
        (if (and (>= (string-length string) n)
                 (string=? suffix (substring string (- (string-length string) n))))
            (substring string 0 (- (string-length string) n))
            string)))

    (define (%pretty-capitalize string)
      ;; Elisp's `(capitalize STRING)' for a mode name: the first
      ;; character of each word up, the rest down, "word" being a run of
      ;; letters - which is what makes "binary-overwrite" into
      ;; "Binary-Overwrite".
      ;;--------------------------------------------------------------
      (let loop ((i 0) (word-start #t) (out '()))
        (if (>= i (string-length string))
            (list->string (reverse out))
            (let ((c (string-ref string i)))
              (if (char-alphabetic? c)
                  (loop (+ i 1) #f
                        (cons (if word-start (char-upcase c) (char-downcase c))
                              out))
                  (loop (+ i 1) #t (cons c out)))))))

    (define (easy-mmode-pretty-mode-name mode . rest)
      ;; GNU Emacs's `easy-mmode-pretty-mode-name' (`easy-mmode.el:54'):
      ;; "Turn the symbol MODE into a string intended for the user."
      ;; `overwrite-mode' becomes "Overwrite mode" and
      ;; `binary-overwrite-mode' "Binary-Overwrite mode", which is what
      ;; the toggle messages say.
      ;;
      ;; The LIGHTER argument's second half - replacing the lighter's
      ;; text in the name so the name borrows its capitalization - is
      ;; not carried; nothing here passes a lighter.
      ;;--------------------------------------------------------------
      (let ((name (string-append
                   (string-replace "-Minor" " minor"
                                   (%pretty-capitalize
                                    (string-replace "toggle-" ""
                                                    (%drop-suffix "-mode"
                                                                  (symbol->string mode)))))
                   " mode")))
        (if (and (>= (string-length name) 7)
                 (string=? "Global-" (substring name 0 7)))
            (string-append "Global " (substring name 7))
            name)))

    (define-syntax define-minor-mode
      ;; GNU Emacs's `define-minor-mode' (`easy-mmode.el:148'): "Define a
      ;; new minor mode MODE. This defines the toggle command MODE and
      ;; (by default) a control variable MODE."
      ;;
      ;; The clause list is Emacs's, in Emacs's order-anywhere form:
      ;; an optional docstring, then any of `:lighter', `:variable',
      ;; `:init-value', `:interactive' and `:after-hook' as KEYWORD
      ;; VALUE pairs, then the body. Everything after the keywords is
      ;; body, exactly as in the Elisp.
      ;;
      ;;   :lighter SPEC       text for the mode line, registered through
      ;;                       `add-minor-mode' - or #f, which adds no
      ;;                       entry because the entry is already there
      ;;                       (`overwrite-mode' takes its lighter that
      ;;                       way, from `bindings.el:979').
      ;;   :variable GET SET   where the state is kept. GET is a thunk
      ;;                       and SET a one-argument procedure, which is
      ;;                       Emacs's `(GET . SET)' PLACE form with the
      ;;                       two expressions made callable - Elisp
      ;;                       evaluates them as forms, Scheme has no
      ;;                       form to hand around but a procedure.
      ;;   :init-value VAL     the accessors' answer before anything is
      ;;                       set, when no `:variable' is given.
      ;;   :interactive VAL    #f to define no command, as Emacs's nil is
      ;;                       "use nil to avoid that".
      ;;   :after-hook FORM    evaluated after the mode's hook has run.
      ;;--------------------------------------------------------------
      (lambda (stx)
        (define (keyword? x)
          (and (identifier? x)
               (memq (syntax->datum x)
                     '(:lighter :variable :global :init-value :keymap
                       :interactive :after-hook
                       ;; Accepted and dropped - `defcustom`'s, see the
                       ;; library comment.
                       :group :version :set :initialize :type
                       :extra-args))))
        ;; Parse the clauses into a list of (KEYWORD . VALUE-LIST) plus
        ;; the body, in one walk. The docstring is the first clause when
        ;; it is a string, which is Emacs's own reading.
        ;;----------------------------------------------------------
        (define (parse clauses)
          (let loop ((rest clauses) (opts '()) (body '()))
            (cond
             ((null? rest) (values (reverse opts) (reverse body)))
             ((and (string? (syntax->datum (car rest)))
                   (null? opts) (null? body))
              (loop (cdr rest) (list (cons ':docstring (list (car rest)))) body))
             ((keyword? (car rest))
              (let* ((k (syntax->datum (car rest)))
                     (n (case k ((:variable) 2) (else 1))))
                (loop (list-tail rest (+ n 1))
                      (cons (cons k (%list-head (cdr rest) n)) opts)
                      body)))
             (else (loop (cdr rest) opts (cons (car rest) body))))))
        (define (opt opts key) (let ((e (assq key opts))) (and e (cadr e))))
        (syntax-case stx ()
          ((_ mode clause ...)
           (let* ((mode-datum (syntax->datum #'mode))
                  (name (symbol->string mode-datum))
                  (named (lambda (suffix)
                           (datum->syntax #'mode
                                          (string->symbol
                                           (string-append name suffix)))))
                  (hook-id (named "-hook"))
                  (getter-id (named "-variable"))
                  (setter-id (datum->syntax
                              #'mode
                              (string->symbol
                               (string-append "set!" name "-variable!"))))
                  ;; `'overwrite-mode', built rather than written: a
                  ;; quoted form inside a template cannot hold an
                  ;; unsyntax - `'#,x' reads as `(quote (unsyntax x))',
                  ;; which is not what is meant.
                  (quoted-mode (datum->syntax #'mode (list 'quote mode-datum)))
                  (mode-id #'mode))
             (call-with-values (lambda () (parse (%syntax->list #'(clause ...))))
               (lambda (opts body)
                 (let* ((doc (opt opts ':docstring))
                        (lighter (opt opts ':lighter))
                        ;; `',lighter' - a mode-line *construct*, quoted:
                        ;; `text-scale-mode`'s is `(" " text-scale-mode-lighter)`,
                        ;; which unquoted would be a call of the string " "
                        ;; as a procedure.
                        (quoted-lighter
                         (if lighter
                             (datum->syntax
                              #'mode (list 'quote (syntax->datum lighter)))
                             #'#f))
                        ;; The mode's own keymap, registered against the
                        ;; mode's variable so that `lookup-keymaps' finds
                        ;; it while the mode is on - `subr.el''s
                        ;; `(add-minor-mode mode lighter keymap ...)'.
                        (keymap (opt opts ':keymap))
                        ;; `:variable' is the one clause with two
                        ;; values, so it is the one read as a list.
                        (variable (let ((e (assq ':variable opts)))
                                    (and e (cdr e))))
                        ;; "`:global GLOBAL' If non-nil specifies that the
                        ;; minor mode is not meant to be buffer-local, so
                        ;; don't make the variable MODE buffer-local."
                        ;; The clause is an *expression* in the C and only
                        ;; its non-nil-ness is read, at macro time; here
                        ;; the datum is what is read, which is the same
                        ;; question for every literal a caller writes.
                        (globalp (let ((e (assq ':global opts)))
                                   (and e
                                        (not (eq? (syntax->datum (cadr e))
                                                  #f)))))
                        (init (opt opts ':init-value))
                        ;; Emacs's `:interactive' defaults to making the
                        ;; mode a command; only an explicit nil stops it.
                        (interactive-entry (assq ':interactive opts))
                        (interactive (if interactive-entry
                                         (cadr interactive-entry)
                                         #t))
                        (after (opt opts ':after-hook))
                        ;; GET and SET are both *expressions for a
                        ;; procedure*: a thunk and a one-argument
                        ;; procedure. That is Emacs's `(GET . SET)' PLACE
                        ;; form with its two expressions kept as
                        ;; expressions - and when `:variable' is absent
                        ;; the macro makes a pair of its own, over the
                        ;; buffer-local it also declares.
                        ;; "If :variable is specified, then the var will
                        ;; be declared elsewhere" - Emacs declares the
                        ;; buffer-local only when it is not.
                        ;;
                        ;; A `:global` mode's PLACE is the variable's
                        ;; *default*, which is `(setq-default ,mode)` and
                        ;; `(default-value ',mode)` in the C: one value
                        ;; shared by every buffer instead of a slot in
                        ;; each buffer's own table.
                        (accessors
                         (cond
                          (variable #f)
                          (globalp
                           #`(begin
                               (define (#,getter-id)
                                 (default-value #,quoted-mode #,(or init #'#f)))
                               (define (#,setter-id value)
                                 (set-default #,quoted-mode value))))
                          (else
                           #`(begin
                               (define (#,getter-id)
                                 (buffer-local-value (current-buffer)
                                                     #,quoted-mode
                                                     #,init))
                               (define (#,setter-id value)
                                 (set-buffer-local-value! (current-buffer)
                                                          #,quoted-mode
                                                          value))))))
                        ;; The `interactive' declaration, built rather
                        ;; than written in the template. It is a
                        ;; *literal* of `define-command`'s `syntax-rules'
                        ;; and not a binding anywhere, so an
                        ;; `interactive' written into a template here
                        ;; resolves in *this* library, where it is
                        ;; unbound, and psyntax refuses it - "reference
                        ;; to identifier outside its scope". Given the
                        ;; call site's context it is the same
                        ;; unbound-but-named identifier a hand-written
                        ;; `(interactive ...)' is, which is what matches.
                        ;;
                        ;; Emacs's `(list (if current-prefix-arg
                        ;; (prefix-numeric-value current-prefix-arg)
                        ;; 'toggle))'. "Use `toggle' rather than (if
                        ;; ,mode 0 1) so that using repeat-command still
                        ;; does the toggling correctly." The expression
                        ;; is `eval'ed in the command's module when a key
                        ;; reaches it, so its contents are plain data.
                        ;;
                        ;; **It is `eval'ed in the *caller's* module**, so
                        ;; a library that calls `define-minor-mode' must
                        ;; import `current-prefix-arg' and `uarg->integer'
                        ;; from `(schemacs command)' - Emacs gets
                        ;; both from its one obarray and needs nothing.
                        ;; Without them the command works when called as a
                        ;; procedure and raises `Unbound variable' when a
                        ;; key reaches it, which the command loop's guard
                        ;; swallows into "the key did nothing".
                        (interactive-form
                         (datum->syntax #'mode
                                        (list 'interactive
                                              (list 'list
                                                    (list 'if
                                                          ;; a *call* of the
                                                          ;; parameter, not the
                                                          ;; parameter itself -
                                                          ;; an uncalled one is a
                                                          ;; procedure, and so
                                                          ;; always true
                                                          (list 'current-prefix-arg)
                                                          (list 'uarg->integer
                                                                1
                                                                (list 'current-prefix-arg))
                                                          (list 'quote 'toggle))))))
                        (get (if variable
                                 (car variable)
                                 #`(lambda () (#,getter-id))))
                        (set (if variable
                                 (cadr variable)
                                 #`(lambda (v) (#,setter-id v))))
                        (command
                         (if interactive
                             ;; ARG is *optional* - `(defun ,mode
                             ;; (&optional arg ...)' - so a bare
                             ;; `(auto-fill-mode)' is a call Emacs
                             ;; accepts, and a nil ARG takes the
                             ;; enabled branch (only `'toggle', which
                             ;; the interactive form supplies when no
                             ;; prefix is given, toggles).
                             #`(define-command (#,mode-id . rest)
                                 #,(or doc #'"Toggle the minor mode.")
                                 #,interactive-form
                                 (let* ((arg (and (pair? rest) (car rest)))
                                        (last-message (current-message)))
                                   ;; `(cond ((eq arg 'toggle) (not ,getter))
                                   ;;        (t (not (and (numberp arg)
                                   ;;                     (< arg 1)))))'
                                   (#,set
                                    (if (eq? arg 'toggle)
                                        (not (#,get))
                                        (not (and (number? arg) (< arg 1)))))
                                   ;; "Keep minor modes list up to date."
                                   ;; (`easy-mmode.el:371`): the enabled
                                   ;; local modes go in the buffer's
                                   ;; `local-minor-modes`, the `:global`
                                   ;; ones in `global-minor-modes`, and
                                   ;; off is a `delq`. The list holds the
                                   ;; mode's *symbol* here - what
                                   ;; `minor-mode-alist` is keyed by and
                                   ;; what `documentation` finds the
                                   ;; mode's command record from.
                                   #,(if globalp
                                         #`(if (#,get)
                                               (unless (memq #,quoted-mode
                                                             (*global-minor-modes*))
                                                 (*global-minor-modes*
                                                  (cons #,quoted-mode
                                                        (*global-minor-modes*))))
                                               (*global-minor-modes*
                                                (delq #,quoted-mode
                                                      (*global-minor-modes*))))
                                         #`(if (#,get)
                                               (unless (memq #,quoted-mode
                                                             (buffer-local-value
                                                              (current-buffer)
                                                              'local-minor-modes
                                                              '()))
                                                 (set-buffer-local-value!
                                                  (current-buffer)
                                                  'local-minor-modes
                                                  (cons #,quoted-mode
                                                        (buffer-local-value
                                                         (current-buffer)
                                                         'local-minor-modes
                                                         '()))))
                                               (set-buffer-local-value!
                                                (current-buffer)
                                                'local-minor-modes
                                                (delq #,quoted-mode
                                                      (buffer-local-value
                                                       (current-buffer)
                                                       'local-minor-modes
                                                       '())))))
                                   #,@body
                                   ;; a hook here is a parameter holding
                                   ;; its list, so what `run-hooks' is
                                   ;; passed is the list
                                   (run-hooks (#,hook-id))
                                   ;; "Avoid overwriting a message shown by
                                   ;; the body, but do overwrite previous
                                   ;; messages."
                                   ;; **The mode's own command**, so
                                   ;; that a mode switched on by another
                                   ;; command - `dired-mode` turning on
                                   ;; `font-lock-mode` - stays quiet.
                                   ;; Emacs gets the same answer from the
                                   ;; stack (`called-interactively-p`
                                   ;; walks it for the frame that called
                                   ;; *this* function); a Scheme binding
                                   ;; cannot, so the question names the
                                   ;; function.
                                   (when (called-interactively? #,mode-id)
                                     (unless (and (current-message)
                                                  (not (equal? last-message
                                                               (current-message))))
                                       ;; "`(let ((local ,(if globalp ""
                                       ;; " in current buffer"))) (message
                                       ;; "%s %sabled%s" ...))'" - a global
                                       ;; mode is not in *this* buffer.
                                       (message "%s %sabled%s"
                                                #,(easy-mmode-pretty-mode-name
                                                   mode-datum
                                                   (and lighter
                                                        (syntax->datum lighter)))
                                                (if (#,get) "en" "dis")
                                                #,(if globalp #'""
                                                      #'" in current buffer"))))
                                   #,@(if after (list after) '())
                                   ;; "Return the new setting."
                                   (#,get)))
                             #f)))
                   #`(begin
                       #,accessors
                       ;; GNU Emacs's `(defvar MODE INIT)` for a
                       ;; `:global` mode: the `defvar` also *binds* the
                       ;; variable, and only when it is not already
                       ;; bound - a reload must not overwrite what the
                       ;; user set. The generated accessors' fallback is
                       ;; not enough on its own: `default-boundp` is
                       ;; false until something writes the default, and
                       ;; `mode-line-symbol-value` (which resolves a
                       ;; construct's symbol) asks `default-boundp`
                       ;; before it can use any fallback.
                       #,@(if globalp
                              (list #`(unless (default-boundp #,quoted-mode)
                                        (set-default #,quoted-mode #,init)))
                              '())
                       ;; The hook the generated function runs. Emacs's
                       ;; `(defvar MODE-hook nil)'; here a hook is a
                       ;; parameter holding its list, which is what this
                       ;; tree's hooks are.
                       (define #,hook-id (make-parameter '()))
                       #,command
                       ;; `(add-minor-mode ',modevar ',lighter ...)' -
                       ;; the lighter goes into `minor-mode-alist', where
                       ;; the mode line reads it.
                       ;;
                       ;; **The lighter is quoted.** It is a *mode-line
                       ;; construct*, not code: `text-scale-mode`'s is
                       ;; `(" " text-scale-mode-lighter)`, which spliced
                       ;; in unquoted would be a call of the string " "
                       ;; as a procedure. Emacs quotes it too - `',lighter`
                       ;; - and a string literal quoted is itself, so
                       ;; every lighter written before this still works.
                       (add-minor-mode #,quoted-mode #,quoted-lighter
                                       #,(or keymap #'#f) #f #,quoted-mode)
                       #,hook-id)))))))))

    (define-syntax define-globalized-minor-mode
      ;; GNU Emacs's `define-globalized-minor-mode' (`easy-mmode.el:447'):
      ;; "Make a global mode GLOBAL-MODE corresponding to buffer-local
      ;; minor MODE. TURN-ON is a function that will be called with no
      ;; args in every buffer and that should try to turn MODE on if
      ;; applicable for that buffer."
      ;;
      ;; It is `define-minor-mode` with `:global t` - one shared variable
      ;; instead of a slot per buffer - plus the three pieces that make
      ;; the shared switch reach buffers that do not exist yet: an
      ;; `after-change-major-mode-hook` entry, a pass over `buffer-list`
      ;; when the switch is thrown, and the `MODE--set-explicitly` flag
      ;; that lets a major mode's hook have the last word.
      ;;
      ;; **What is generated, and where each name resolves.** Four names
      ;; are built from the two mode symbols - `GLOBAL-MODE-variable`,
      ;; `GLOBAL-MODE-enable-in-buffer`, `MODE--set-explicitly`,
      ;; `MODE--suppress-set-explicitly` - and they are spliced into the
      ;; template with the *call site's* lexical context
      ;; (`datum->syntax #'global-mode`), because they are definitions in
      ;; the library the macro is used from, as `ghook-id` is for
      ;; `define-minor-mode`. Everything else written literally in the
      ;; template resolves here, in easy-mmode, which is what keeps a
      ;; caller from importing `add-hook`, `buffer-list` and the rest.
      ;;
      ;; `MODE--suppress-set-explicitly` is a parameter without the
      ;; asterisks, like `MODE-hook`: it is a name the macro generates
      ;; from Emacs's own, not one a user reads.
      ;;
      ;; Not carried, named rather than faked:
      ;;
      ;;   - `:predicate` and the `MODE-modes` defcustom it makes. It
      ;;     needs `defcustom`, and its turn-on is a closure over
      ;;     `easy-mmode--globalized-predicate-p`; a mode that wants one
      ;;     can test `derived-mode-p` in its own TURN-ON.
      ;;   - `custom-initialize-after-file-load` and the
      ;;     `customize-mark-as-set` in the generated command - no
      ;;     customize for a variable that is not a parameter.
      ;;   - `:variable` as a `(GET . SET)` place; a symbol is taken.
      ;;   - `bound-and-true-p`, which needs a variable registry: the
      ;;     test is `buffer-local-value`'s, which is this tree's
      ;;     spelling of "is the mode's variable true in this buffer".
      ;;--------------------------------------------------------------
      (lambda (stx)
        (define (keyword-datum? datum)
          (and (symbol? datum)
               (> (string-length (symbol->string datum)) 0)
               (char=? #\: (string-ref (symbol->string datum) 0))))
        (define (named base suffix)
          ;; The generated name, with BASE's lexical context.
          (datum->syntax base
                         (string->symbol
                          (string-append (symbol->string (syntax->datum base))
                                         suffix))))
        (define (quoted id)
          (datum->syntax id (list 'quote (syntax->datum id))))
        (syntax-case stx ()
          ((_ global-mode mode turn-on clause ...)
           (let* ((global-id #'global-mode)
                  (mode-id #'mode)
                  (turn-on-id #'turn-on)
                  (global-name (symbol->string (syntax->datum global-id)))
                  (mode-name (symbol->string (syntax->datum mode-id)))
                  (global-getter (named global-id "-variable"))
                  (enable-in-buffer (named global-id "-enable-in-buffer"))
                  (set-explicitly (named mode-id "--set-explicitly"))
                  (suppress (named mode-id "--suppress-set-explicitly"))
                  (minor-mode-hook (named mode-id "-hook"))
                  (quoted-global (quoted global-id))
                  (quoted-set-explicitly (quoted set-explicitly))
                  (quoted-enable-in-buffer (quoted enable-in-buffer))
                  ;; "`:variable'" may name the place the minor mode's
                  ;; state lives in; the default is the mode's own symbol.
                  (mode-variable (quoted mode-id))
                  (extra '()))
             ;; Read the keyword clauses. `:global' is implied, the
             ;; defcustom keywords are passed through, and everything
             ;; else becomes body.
             (define mode-body '())
             (let loop ((rest (%syntax->list #'(clause ...))))
               (cond
                ((null? rest) #t)
                ((and (identifier? (car rest))
                      (keyword-datum? (syntax->datum (car rest))))
                 (let ((k (syntax->datum (car rest)))
                       (value (and (pair? (cdr rest)) (cadr rest))))
                   (case k
                     ((:global) (loop (cddr rest)))
                     ((:group :version)
                      (set! extra (append extra (list (car rest) value)))
                      (loop (cddr rest)))
                     ((:variable)
                      (set! mode-variable (quoted value))
                      (loop (cddr rest)))
                     ((:predicate)
                      (error "define-globalized-minor-mode: :predicate is not carried"))
                     (else (loop (cddr rest))))))
                (else
                 (set! mode-body (cons (car rest) mode-body))
                 (loop (cdr rest)))))
             (set! mode-body (reverse mode-body))
             (let* ((pretty-name
                     (easy-mmode-pretty-mode-name (syntax->datum mode-id)))
                    (pretty-global
                     (easy-mmode-pretty-mode-name (syntax->datum global-id)))
                    (doc
                     (string-append
                      (format #f "Toggle ~a in many buffers.~%" pretty-name)
                      (format #f "Specifically, ~a is enabled in all buffers where `~a' would do it."
                              pretty-name mode-name)
                      "\n\n"
                      (format #f "With prefix ARG, enable ~a if ARG is positive; otherwise, disable it."
                              pretty-global)
                      "\n\n"
                      "If called from Lisp, toggle the mode if ARG is `toggle'.
Enable the mode if ARG is nil, omitted, or is a positive number.
Disable the mode if ARG is a negative number.\n\n"
                      (format #f "See `~a' for more information on ~a."
                              mode-name pretty-name))))
               #`(begin
                   ;; "Don't bother the user with a hook for this."
                   (put #,quoted-global 'globalized-minor-mode #t)
                   ;; "The actual global minor-mode."
                   (define-minor-mode #,global-id
                     #,doc
                     :global #t
                     #,@extra
                     ;; "Setup hook to handle future mode changes and new
                     ;; buffers."
                     (if (#,global-getter)
                         (add-hook *after-change-major-mode-hook*
                                   #,enable-in-buffer)
                         (remove-hook *after-change-major-mode-hook*
                                      #,enable-in-buffer))
                     ;; "Go through existing buffers."
                     (for-each
                      (lambda (buf)
                        (with-current-buffer
                            buf
                          (if (#,global-getter)
                              (#,turn-on-id)
                              (when (buffer-local-value (current-buffer)
                                                        #,mode-variable
                                                        #f)
                                (#,mode-id -1)))))
                      (buffer-list))
                     #,@mode-body)
                   ;; "MODE-set-explicitly is set in MODE-set-explicitly
                   ;; and cleared by kill-all-local-variables." The
                   ;; clearing is the buffer slot's: a slot that is not
                   ;; there reads the default, which is nil.
                   (define #,suppress (make-parameter #f))
                   (define (#,set-explicitly)
                     (unless (#,suppress)
                       (set-buffer-local-value! (current-buffer)
                                                #,quoted-set-explicitly
                                                #t)))
                   (put #,quoted-set-explicitly
                        'definition-name
                        #,quoted-global)
                   ;; "A function which checks whether MODE has been
                   ;; disabled in the major mode hook which has just been
                   ;; run."
                   (add-hook #,minor-mode-hook #,set-explicitly)
                   ;; "The function that calls TURN-ON in the current
                   ;; buffer."
                   (define (#,enable-in-buffer)
                     (unless (buffer-local-value
                              (current-buffer)
                              #,quoted-set-explicitly
                              #f)
                       ;; "We are not part of the major mode hook so we
                       ;; don't want to set MODE-set-explicitly to t. In
                       ;; particular this is necessary when there are
                       ;; multiple globalized versions of a single minor
                       ;; mode. If one of them declines to turn the minor
                       ;; mode on, that should not mean the others can't."
                       (parameterize ((#,suppress #t))
                         (#,turn-on-id))))
                   (put #,quoted-enable-in-buffer
                        'definition-name
                        #,quoted-global))))))))
    ))
