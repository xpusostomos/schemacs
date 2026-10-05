(define-library (schemacs editor command)
  ;; This library mirrors GNU Emacs's `command.c' and `callint.c': what a
  ;; command is (a procedure with an `interactive' specification), how the
  ;; specification is turned into arguments, and how one is run.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.
  (import
    (scheme base)
    (scheme eval)
    (scheme write)
    (scheme case-lambda)
    (only (schemacs lens) record-unit-lens)
    ;; A `define-command' name keeps its name and docstring in Guile's own
    ;; copy, which `,describe' shows: `procedure-name' and
    ;; `procedure-documentation' read them back for the obarray record.
    (only (guile) current-module procedure-name procedure-documentation))

  (export
   command-type? make<command> new-command new-count-command
   command-name command-procedure command-doc-string
   command-interactive-spec
   *mark-even-if-inactive*
   *this-event*
   current-prefix-arg
   *called-interactively*
   called-interactively?
   uarg->integer
   run-command apply-command show-command
   define-command *command-table* command? command-record-of command-value-of
   register-command!
   =>command-name*!
   =>command-procedure*!
   =>command-doc-string*!
   =>command-interactive-spec*!
   =>command-source-type*!
   =>command-source-location*!
   =>command-source-code*!
   )

  (begin

    (define-record-type <command-type>
      ;; A command is a structure containing a function that responds to
      ;; input events. Every command-procedure receives 2 arguments:
      ;;
      ;;  1. the window in which the event occurred (from this you can
      ;;     obtain the current buffer and the parent frame), and
      ;;
      ;;  2. the event value itself.
      ;;
      ;; If the command is a wrapper around a Scheme procedure, store
      ;; that Scheme procedure into the API field of this data
      ;; structure.
      ;;
      ;; The INTERACTIVE-SPEC field says what the command loop must hand
      ;; to the command-procedure when a user invokes the command from
      ;; the keyboard (GNU Emacs's `interactive' declaration):
      ;;
      ;;  #f      the procedure takes no argument. This is the default,
      ;;          and is the shape of the first argument of every
      ;;          command defined before interactive specs existed.
      ;;
      ;;  'uarg   the procedure takes one argument, the raw universal
      ;;          argument (`UARG'): #f when no prefix was typed, or an
      ;;          integer. The command converts it with `UARG->INTEGER',
      ;;          exactly as GNU Emacs's `(interactive "p")' does.
      ;;
      ;; The spec is consulted only when a command is invoked
      ;; interactively; `APPLY-COMMAND' reaches the command through its
      ;; API procedure and so is unaffected by it.
      ;;--------------------------------------------------------------
      (make<command> name procedure api docstr spec srctype srcloc srcstr)
      command-type?
      (name      command-name            set!command-name)
      (procedure command-procedure       set!command-procedure)
      (api       command-api             set!command-api)
      (docstr    command-doc-string      set!command-doc-string)
      (spec      command-interactive-spec set!command-interactive-spec)
      (srctype   command-source-type     set!command-source-type)
      (srcloc    command-source-location set!command-source-location)
      (srcstr    command-source-code     set!command-source-code)
      )

    (define *mark-even-if-inactive*
      ;; GNU Emacs's `mark-even-if-inactive', which is `callint.c''s -
      ;; the `interactive' machinery's, because that is where an
      ;; `interactive "r"' asks for the region and has to decide what to
      ;; do when the mark is not active. `(mark)' and `region-beginning'
      ;; ask it too.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *this-event*
      ;; Emacs's `this_command_keys' and the event the command was
      ;; invoked by: `callint.c:287' reads the key sequence the command
      ;; loop recorded (`keys = this_command_keys') and the
      ;; `(interactive "e")' spec hands the command `AREF (keys,
      ;; next_event)' (`callint.c:608') - the invoking event itself, which
      ;; for a window-system event is the list Emacs's `make_lispy_event'
      ;; built: `(delete-frame (FRAME))' (`keyboard.c:6238') and
      ;; `(focus-in (FRAME))' (`keyboard.c:6281').
      ;;
      ;; The command loop binds it around the dispatch, and
      ;; `interactive-proc''s `"e"' case is what reads it.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define current-prefix-arg
      ;; Emacs's `current-prefix-arg' - callint.c's `DEFVAR_LISP', the
      ;; raw prefix argument for the *current* command: what
      ;; `(interactive "P")' returns, and the variable
      ;; `split-window-below''s interactive form reads for its size. The
      ;; command loop copies `prefix-arg' - the value
      ;; `universal-argument' left for the next command, `pending-uarg'
      ;; here - into it before the command runs (keyboard.c), and an
      ;; interactive *expression* is evaluated under it, which is where
      ;; the loop's copy is visible. `interactive-proc' binds it around
      ;; the evaluation; a command body that wants the raw prefix asks
      ;; with `(interactive "P")' instead, which is Emacs's "less
      ;; clean" way.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define new-command
      ;; Construct a command. The fifth argument, INTERACTIVE-SPEC, is
      ;; optional and defaults to #f (see the record type above).
      ;;--------------------------------------------------------------
      (case-lambda
       ((name proc api docstr)
        (new-command name proc api docstr #f))
       ((name proc api docstr spec)
        (make<command> name proc api docstr spec 'built-in #f #f))
       ))

    (define (uarg->integer dflt uarg)
      ;; Convert a universal-argument value into the integer a command
      ;; works with: DFLT when no prefix was typed, 4 for a bare
      ;; `C-u' (#t, the Emacs "raw prefix" spelling), the integer
      ;; itself when a prefix was typed, and a rounded number
      ;; otherwise. This is the conversion GNU Emacs's `(interactive
      ;; "p")' performs.
      ;;--------------------------------------------------------------
      (cond
       ((eq? #f uarg) dflt)
       ;; A bare `M--' leaves the raw value `-' - the symbol GNU Emacs
       ;; leaves in `prefix-arg', which `prefix-numeric-value' turns
       ;; into -1 for `(interactive "p")'.
       ((eq? '- uarg) -1)
       ;; A bare `C-u' is the list `(4)' - `(16)' for `C-u C-u' - and the
       ;; number it means is the one in it. That is the C's
       ;; `prefix-numeric-value': "else if (CONSP (raw) && FIXNUMP (XCAR
       ;; (raw))) val = XCAR (raw)".
       ((pair? uarg) (uarg->integer dflt (car uarg)))
       ((eq? #t uarg) 4)
       ((integer? uarg) uarg)
       ((number? uarg) (round uarg))
       (else (error "U-argument cannot be cast to integer" uarg))
       ))

    (define (new-count-command name impl docstr)
      ;; A command whose interactive form takes the universal argument
      ;; as a count, like GNU Emacs's `(interactive "p")': IMPL is the
      ;; command's API procedure and receives an integer, 1 when no
      ;; prefix was typed. It builds both lambdas, so that a command
      ;; cannot forget to consult the prefix argument.
      ;;--------------------------------------------------------------
      (new-command
       name
       (lambda (uarg) (impl (uarg->integer 1 uarg)))
       impl
       docstr
       'uarg))

    ;;----------------------------------------------------------------
    ;; Defining commands with `define-command'
    ;;
    ;; GNU Emacs's `defun' makes the command's name a plain *function*:
    ;; any Lisp can call it with arguments, and the keyboard reaches it
    ;; through the command machinery. `define-command' is the same trick here
    ;; - the NAME it defines is bound to the command's own procedure, so
    ;; `(kill-region 1 5)' is an ordinary call, while everything the
    ;; command machinery wants to know about it (its name, its docstring,
    ;; the interactive specification and the procedure itself) is
    ;; gathered into a `<command-type>' record in the command obarray.
    ;;
    ;; The obarray entry's API is the defined procedure itself, which is
    ;; what makes the two views agree: `apply-command' on the record and
    ;; a direct call on the name run the same code. The keymap stores
    ;; the *procedure* (the value of the name); dispatch finds its
    ;; record in the obarray when it needs the interactive specification.
    ;;
    ;; "One file to shim out later": every piece above lives here - the
    ;; macro, the obarray, the registration. A different Scheme can
    ;; provide the same surface (callable commands + an obarray of
    ;; records, or of whatever it has) by re-implementing this library.
    ;;------------------------------------------------------------------

    (define *called-interactively* (make-parameter #f))
    ;; ^ Whether the command now running was reached through
    ;; `interactive-proc' below - GNU Emacs's `called-interactively-p'
    ;; (`eval.c:470'), which asks whether a `call-interactively' frame is
    ;; on the stack. `define-minor-mode`'s generated command reads it to
    ;; decide whether to echo the "enabled"/"disabled" message: a mode
    ;; switched on by a program must stay quiet, as `(message ...)' is
    ;; inside `(if (called-interactively-p 'any) ...)' there.
    ;;
    ;; `'any' and not the other kind: Emacs's `'any' counts a
    ;; `call-interactively' anywhere up the stack, not only the innermost
    ;; one, which is what a dynamically bound flag gives.

    (define (called-interactively?)
      ;; GNU Emacs's `called-interactively-p': "Return t if the function
      ;; it is called from was called with `call-interactively' and thus
      ;; can have been passed an `interactive' specification."  The
      ;; KIND argument (`'interactive', `'any', `'command') is not
      ;; carried; every caller here wants `'any'.
      ;;--------------------------------------------------------------
      (*called-interactively*))

    (define *command-table* (make-parameter '()))
    ;; ^ The command obarray: GNU Emacs's `command-obarray', an alist of
    ;; (NAME . COMMAND-RECORD) - the record that `M-x' and the
    ;; description commands will read, ordered most-recently-defined
    ;; first.

    (define (interactive-proc spec command module)
      ;; The command's interactive entry: a procedure that reads what a
      ;; keyfinger supplies and calls COMMAND with it - GNU Emacs's
      ;; `call-interactively' reading the arguments once, for the
      ;; specifications `define-command' knows. SPEC is `#f' (no arguments),
      ;; `"p"' (the numeric prefix), `"P"' (the raw prefix), or an
      ;; *expression* - a list, not a string - evaluated at the keypress
      ;; to produce the argument list, which is Emacs's
      ;; `(interactive (list ...))`: `(interactive (list
      ;; (selected-window)))' hands COMMAND the window it is to delete.
      ;; The expression is evaluated in COMMAND's own module - the one
      ;; `register-command!' caught (MODULE) when the command was
      ;; defined, which is where the names it uses are bound. Evaluating
      ;; it where the keypress found `interactive-proc' would be wrong:
      ;; that is the command loop's module, and the command's helpers
      ;; are not all in it.
      ;;--------------------------------------------------------------
      (cond
       ((not spec) (lambda ()
                     (parameterize ((*called-interactively* #t))
                       (command))))
       ;; an expression - a list - is recognised before the strings, so
       ;; that testing a form for `"p"' does not compare a list
       ((pair? spec)
        (lambda (uarg)
          ;; The command loop has copied the pending prefix into
          ;; `current-prefix-arg' before the command's arguments are
          ;; read; an interactive expression, like Emacs's `(interactive
          ;; ...)', can read it for an argument (`split-window-below'
          ;; does).
          (parameterize ((current-prefix-arg uarg)
                         (*called-interactively* #t))
            (apply command (eval spec module)))))
       ;; The invoking event, which the command loop has bound - Emacs's
       ;; `args[i] = AREF (keys, next_event)' (`callint.c:608').
       ((string=? spec "e") (lambda (uarg)
                              (parameterize ((*called-interactively* #t))
                                (command (*this-event*)))))
       ((string=? spec "p") (lambda (uarg)
                              (parameterize ((*called-interactively* #t))
                                (command (uarg->integer 1 uarg)))))
       ((string=? spec "P") (lambda (uarg)
                              (parameterize ((*called-interactively* #t))
                                (command uarg))))
       (else (error "Unsupported interactive specification" spec))))

    (define (register-command! command spec)
      ;; Record COMMAND, a procedure `define-command' has just bound, in the
      ;; command obarray: make its `<command-type>' record - the name
      ;; coming from the procedure itself, the docstring from Guile's
      ;; own copy, the API being the procedure - and push it on
      ;; `*command-table*'. The argument order (command, SPEC) is the
      ;; expansion `define-command' emits; SPEC is `#f', `"p"' or `"P"',
      ;; or an interactive expression, `interactive-proc' knows what
      ;; those mean. The module caught here is the defining module -
      ;; the one the `define-command' expansion runs in - and an
      ;; interactive expression evaluates there. That module is
      ;; `current-module' while this procedure runs, because the
      ;; definition it is recording is still in progress.
      ;;--------------------------------------------------------------
      (let* ((name (symbol->string (procedure-name command)))
             (module (current-module))
             (record (new-command name
                                  (interactive-proc spec command module)
                                  command
                                  (procedure-documentation command)
                                  (and spec 'uarg))))
        (*command-table* (cons (cons name record) (*command-table*)))
        record))

    (define (command-record-of thing)
      ;; The command record whose API is THING, or #f: how a key bound
      ;; to a `define-command' procedure is dispatched like one bound to a
      ;; record. GNU Emacs keeps `commandp' the same question - "is this
      ;; a command?" - and the answer here is "is there an obarray entry
      ;; whose procedure this is".
      ;;--------------------------------------------------------------
      (and (procedure? thing)
           (let loop ((rest (*command-table*)))
             (cond ((null? rest) #f)
                   ((eq? (command-api (cdar rest)) thing) (cdar rest))
                   (else (loop (cdr rest)))))))

    (define (command? thing)
      ;; Whether THING is a command: GNU Emacs's `commandp'.
      ;;--------------------------------------------------------------
      (not (not (command-record-of thing))))

    (define (command-value-of record)
      ;; The value a key slot for the command held, for `*last-command*'
      ;; and its kin: the defined procedure when the record came from a
      ;; `define-command' (its name on the procedure is the command's name),
      ;; the record itself for a legacy one. This is what a comparison
      ;; like `(eq? (*last-command*) kill-line)' sees both sides of.
      ;;--------------------------------------------------------------
      (let ((name (and (procedure? (command-api record))
                       (procedure-name (command-api record)))))
        (if (and name (equal? (symbol->string name) (command-name record)))
            (command-api record)
            record)))

    (define-syntax define-command
      ;; Define a command: a procedure definition, spelled as Scheme
      ;; spells one - the name together with its parameter list,
      ;; `(NAME ARG ...)' - carrying the command's docstring and its
      ;; `interactive' declaration after the parameters, and the body
      ;; last. That is the order `define' expects and the order GNU
      ;; Emacs's `defun' writes them in, so a command transcribed from
      ;; Emacs keeps its shape:
      ;;
      ;;   (define-command (kill-region beg end)
      ;;     "Kill (\"cut\") text between point and mark."
      ;;     (interactive "r")
      ;;     (delete-region beg end))
      ;;
      ;; SPEC is `(interactive)` (the body takes no arguments), `"p"`
      ;; (the numeric prefix), `"P"` (the raw prefix), or an *expression*
      ;; evaluated at the keypress to build the body's arguments - so a
      ;; command whose procedure is a plain function, callable from
      ;; other Scheme code, can fill its arguments from the environment
      ;; when a key reaches it:
      ;;
      ;;   (define-command (delete-window window)
      ;;     "Remove WINDOW from the frame."
      ;;     (interactive (list (selected-window)))
      ;;     ...)
      ;;
      ;; The expansion binds NAME to a plain procedure over the
      ;; parameter list and body - callable from anywhere - and calls
      ;; `register-command!', which files its record in the obarray.
      ;;--------------------------------------------------------------
      (syntax-rules (interactive)
        ((define-command (name . args) (interactive) body ...)
         (begin
           (define (name . args) body ...)
           (register-command! name #f)))
        ((define-command (name . args) docstring (interactive) body ...)
         (begin
           (define (name . args) docstring body ...)
           (register-command! name #f)))
        ((define-command (name . args) (interactive spec) body ...)
         (begin
           (define (name . args) body ...)
           (register-command! name 'spec)))
        ((define-command (name . args) docstring (interactive spec) body ...)
         (begin
           (define (name . args) docstring body ...)
           (register-command! name 'spec)))
        ((define-command (name . args) docstring body ...)
         (begin
           (define (name . args) docstring body ...)
           (register-command! name #f)))
        ((define-command (name . args) body ...)
         (begin
           (define (name . args) body ...)
           (register-command! name #f)))))

    (define =>command-name*!
      (record-unit-lens command-name set!command-name '=>command-name)
      )

    (define =>command-procedure*!
      (record-unit-lens command-procedure set!command-procedure '=>command-procedure)
      )

    (define =>command-api*!
      (record-unit-lens command-api set!command-api '=>command-api)
      )

    (define =>command-doc-string*!
      (record-unit-lens command-doc-string set!command-doc-string '=>command-doc-string)
      )

    (define =>command-interactive-spec*!
      (record-unit-lens command-interactive-spec
                        set!command-interactive-spec
                        '=>command-interactive-spec)
      )

    (define =>command-source-type*!
      (record-unit-lens command-source-type set!command-source-type '=>command-source-type)
      )

    (define =>command-source-location*!
      (record-unit-lens command-source-location set!command-source-location '=>command-source-location)
      )

    (define =>command-source-code*!
      (record-unit-lens command-source-code set!command-source-code '=>command-source-code)
      )

    (define (run-command cmd . args)
      ;; Run the `COMMAND-PROCEDURE` procedure, passing it ARGS. A
      ;; command whose `COMMAND-INTERACTIVE-SPEC` is #f takes no
      ;; arguments, so the usual call passes none; a command that
      ;; declares it consumes the universal argument is passed the raw
      ;; `UARG' value.
      (apply (command-procedure cmd) args)
      )

    (define (apply-command cmd . args)
      ;; Some commands have an "API" (application programming interface)
      ;; which are procedures that take arguments. This is different from
      ;; the `COMMAND-PROCEDURE` which takes no arguments and so typically
      ;; must be paramaterized.  There is a rule that all
      ;; `COMMAND-PROCEDURE`s must call into the API associated with it in
      ;; it's `<COMMAND-TYPE>` structure if the command procedure itself
      ;; is implemented in terms of that API procedure. A command with
      ;; no API procedure cannot be applied to arguments, and calling it
      ;; that way is an error rather than a silent no-op.
      (let ((api (command-api cmd)))
        (if api
            (apply api args)
            (error "command has no API procedure" (command-name cmd)))
        ))

    (define show-command
      (case-lambda
        ((cmd) (show-command cmd (current-output-port)))
        ((cmd port)
         (cond
          ((command-type? cmd)
           (display "(command #:name " port)
           (display (command-name cmd) port)
           (when (command-interactive-spec cmd)
             (display " #:interactive " port)
             (write (command-interactive-spec cmd) port))
           (when (symbol? (command-source-type cmd))
             (display " #:source-type '" port)
             (display (symbol->string (command-source-type cmd)) port))
           (when (command-source-location cmd)
             (display "\n #:source-location " port)
             (write (command-source-location cmd) port)
             (display "\n #:source-code\n " port)
             (write (command-source-code cmd) port))
           (display ")"))
          (else
           (error "not a command-type value" cmd)
           )))))

    ;;----------------------------------------------------------------
    ))
