(define-library (schemacs editor easy-mmode)
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
  ;;   - `:global', `:set', `:initialize', `:type', the `:group' and
  ;;     `:version' keywords and `customize-mark-as-set': all of that is
  ;;     `defcustom', and there is no customize in this tree. A global
  ;;     mode would also need a variable registry to set and read.
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
    (only (guile) datum->syntax identifier? quasisyntax syntax syntax->datum
          syntax-case unsyntax unsyntax-splicing)
    (only (schemacs editor subr)
          *minor-mode-alist* add-minor-mode run-hooks string-replace)
    (only (schemacs editor buffer)
          buffer-local-value current-buffer set-buffer-local-value!)
    (only (schemacs editor editfns) current-message message)
    (only (schemacs editor command)
          called-interactively? current-prefix-arg define-command
          uarg->integer)
    )

  (export
   define-minor-mode
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
                       :interactive :after-hook))))
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
                        ;; `:variable' is the one clause with two
                        ;; values, so it is the one read as a list.
                        (variable (let ((e (assq ':variable opts)))
                                    (and e (cdr e))))
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
                        (accessors
                         (if variable
                             #f
                             #`(begin
                                 (define (#,getter-id)
                                   (buffer-local-value (current-buffer)
                                                       #,quoted-mode
                                                       #,init))
                                 (define (#,setter-id value)
                                   (set-buffer-local-value! (current-buffer)
                                                            #,quoted-mode
                                                            value)))))
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
                             #`(define-command (#,mode-id arg)
                                 #,(or doc #'"Toggle the minor mode.")
                                 #,interactive-form
                                 (let ((last-message (current-message)))
                                   ;; `(cond ((eq arg 'toggle) (not ,getter))
                                   ;;        (t (not (and (numberp arg)
                                   ;;                     (< arg 1)))))'
                                   (#,set
                                    (if (eq? arg 'toggle)
                                        (not (#,get))
                                        (not (and (number? arg) (< arg 1)))))
                                   #,@body
                                   ;; a hook here is a parameter holding
                                   ;; its list, so what `run-hooks' is
                                   ;; passed is the list
                                   (run-hooks (#,hook-id))
                                   ;; "Avoid overwriting a message shown by
                                   ;; the body, but do overwrite previous
                                   ;; messages."
                                   (when (called-interactively?)
                                     (unless (and (current-message)
                                                  (not (equal? last-message
                                                               (current-message))))
                                       (message "%s %sabled in current buffer"
                                                #,(easy-mmode-pretty-mode-name
                                                   mode-datum
                                                   (and lighter
                                                        (syntax->datum lighter)))
                                                (if (#,get) "en" "dis"))))
                                   #,@(if after (list after) '())
                                   ;; "Return the new setting."
                                   (#,get)))
                             #f)))
                   #`(begin
                       #,accessors
                       ;; The hook the generated function runs. Emacs's
                       ;; `(defvar MODE-hook nil)'; here a hook is a
                       ;; parameter holding its list, which is what this
                       ;; tree's hooks are.
                       (define #,hook-id (make-parameter '()))
                       #,command
                       ;; `(add-minor-mode ',modevar ',lighter ...)' -
                       ;; the lighter goes into `minor-mode-alist', where
                       ;; the mode line reads it.
                       (add-minor-mode #,quoted-mode #,lighter #f #f #,quoted-mode)
                       #,hook-id)))))))))
    ))
