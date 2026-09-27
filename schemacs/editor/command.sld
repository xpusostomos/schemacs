(define-library (schemacs editor command)
  ;; This library mirrors GNU Emacs's `command.c' and `callint.c': what a
  ;; command is (a procedure with an `interactive' specification), how the
  ;; specification is turned into arguments, and how one is run.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.
  (import
    (scheme base)
    (scheme write)
    (scheme case-lambda)
    (only (schemacs lens) record-unit-lens))

  (export
   command-type? make<command> new-command new-count-command
   command-name command-procedure command-doc-string
   command-interactive-spec
   uarg->integer
   run-command apply-command show-command
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
