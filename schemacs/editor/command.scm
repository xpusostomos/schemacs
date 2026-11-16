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
    ;; A `define-command' name keeps its name and docstring in Guile's own
    ;; copy, which `,describe' shows: `procedure-name' and
    ;; `procedure-documentation' read them back for the obarray record.
    (only (guile) current-module procedure-name procedure-documentation
          logand))

  (export
   command-type? make<command> new-command new-count-command
   command-name command-procedure command-doc-string
   command-interactive-spec
   *mark-even-if-inactive*
   *last-command-event*
   current-prefix-arg
   *pending-coding-system*
   *called-interactively*
   *barf-if-buffer-read-only-function*
   called-interactively? funcall-interactively
   uarg->integer
   run-command apply-command show-command
   define-command define-alias *command-table* command? command-record-of
   command-value-of
   command-record-named
   register-command!
   ;; The quit condition and the flag the SIGINT handler sets. They are
   ;; here, not in `keyboard.c`'s library, because `keyboard-quit`
   ;; (`simple.el`) has to signal the one and clear the other and
   ;; `keyboard.scm` is above `simple.scm` - the same reason
   ;; `current-prefix-arg` is here.
   quit-char *quit-flag* *inhibit-quit*
   <quit-condition> quit-condition? signal-quit
   maybe-quit rarely-quit
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Quitting
    ;;
    ;; GNU Emacs's `quit_char` (`keyboard.c:13227`), `Vquit_flag` and
    ;; `Vinhibit_quit` (`keyboard.c`), and the `quit` condition its
    ;; `Fsignal (Qquit, Qnil)` raises (`eval.c`).
    ;;
    ;; **Why they are here and not in `keyboard.c`'s library.** The
    ;; terminal makes C-g the interrupt character (`init_sys_modes`), so a
    ;; C-g arrives as SIGINT and never as a byte; `handle_interrupt` sets
    ;; the flag and the read answers `quit_char` for it. Both ends of that
    ;; are `keyboard.scm`'s, which re-exports these. But `keyboard-quit`
    ;; is `simple.el`'s, and `simple.scm` is *below* `keyboard.scm` - so a
    ;; command that signals quit and clears the flag could reach neither.
    ;; It is the same wall `current-prefix-arg` was moved down for.
    ;;------------------------------------------------------------------

    (define quit-char 7)
    ;; ^ `quit_char = Ctl ('g')' (`keyboard.c:13227`).

    (define *quit-flag* (make-parameter #f))
    ;; ^ `Vquit_flag`. A parameter because the C `let`-binds it -
    ;; `read_char` saves and clears it around the special-event lookup
    ;; (`keyboard.c:3112`), which is what stops a resize or a focus change
    ;; from swallowing a pending quit.

    (define *inhibit-quit* (make-parameter #f))
    ;; ^ `Vinhibit_quit`: while this is true `maybe_quit` does nothing.

    (define-record-type <quit-condition>
      (make-quit-condition) quit-condition?)

    (define (signal-quit)
      ;; Signal that the user quit, the way C-g does: GNU Emacs's
      ;; `(signal 'quit nil)'. The command loop reports it as "Quit"
      ;; (`keyboard.scm`'s `report-command-error!`, which is `cmd_error`).
      ;;--------------------------------------------------------------
      (raise (make-quit-condition)))

    (define (maybe-quit)
      ;; GNU Emacs's `maybe_quit` (`lisp.h:3897') over `probably_quit`
      ;; (`eval.c:1887`): "Every loop that might run for a long time or
      ;; might not exit ought to call maybe_quit at least once, at a safe
      ;; place."
      ;;
      ;; The C also drains `pending_signals` here - the sigusr1/sigusr2
      ;; events and the window-change flag. There are no user-signal events
      ;; in this tree and a resize is applied by the wait, so what is left
      ;; is the quit.
      ;;
      ;; **It lives here, not in `keyboard.c`'s library** (`keyboard.scm`
      ;; re-exports it), because the loops that must call it are C's
      ;; `syntax.c` and `search.c`, which are below `keyboard.scm`. The
      ;; wall is the one `quit-flag` itself was moved down for: with the
      ;; function only in `keyboard.scm`, a C-g could be pressed during a
      ;; long command and nothing would ever look at the flag - the read
      ;; was the only caller, and the read is exactly what a long command
      ;; is not doing.
      ;;--------------------------------------------------------------
      (when (and (*quit-flag*) (not (*inhibit-quit*)))
        (*quit-flag* #f)
        (signal-quit)))

    (define (rarely-quit count)
      ;; GNU Emacs's `rarely_quit` (`lisp.h:3914'): COUNT is an
      ;; `unsigned short' that a long loop increments on every character,
      ;; and the quit is looked at when it wraps - once every 65536
      ;; characters.
      ;;--------------------------------------------------------------
      (when (= 0 (logand count #xffff))
        (maybe-quit)))

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

    (define *last-command-event*
      ;; GNU Emacs's `last-command-event' (`keyboard.c:13763'): "Last
      ;; input event of a key sequence that called a command." The
      ;; command loop sets it once per command to the last event of the
      ;; sequence it just read (`keyboard.c:1449': `last_command_event =
      ;; keybuf[i - 1]'), which is why it is the *last* and not the first:
      ;; `self-insert-command' wants the character that was typed, and in
      ;; `C-x C-f' that is the `f'.
      ;;
      ;; **This was called `*this-event*' here, named from `callint.c'
      ;; instead of from `keyboard.c', and the value is the same one.**
      ;; `callint.c:608' hands `(interactive "e")' `AREF (keys,
      ;; next_event)' - an event of this command's sequence rather than
      ;; necessarily its last - and for the case that reaches a command
      ;; with parameters (a mouse click, a frame event) the sequence is
      ;; one event long, so first and last are the same value: the list
      ;; Emacs's `make_lispy_event' built, `(delete-frame (FRAME))'
      ;; (`keyboard.c:6238') and `(focus-in (FRAME))' (`keyboard.c:6281').
      ;; The command loop binds it around the dispatch, which is where the
      ;; C sets its own; `interactive-proc''s `"e"' case reads it for a
      ;; parameterised spec, and `self-insert-command' and
      ;; `digit-argument' read it for the event.
      ;;
      ;; **It is here, and not in `keyboard.scm' where Emacs declares it**,
      ;; because `cmds.scm' and `simple.scm' are the two readers and the
      ;; command loop is *above* both of them - a variable a command reads
      ;; cannot live in a library that imports the command.
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

    (define *pending-coding-system*
      ;; The coding system the *next* command's I/O should use, or #f -
      ;; GNU Emacs's `mule-cmds--prefixed-command-next-coding-system'
      ;; (`mule-cmds.el:290'), which `universal-coding-system-argument'
      ;; (C-x RET c) sets.
      ;;
      ;; **It lives beside the prefix argument because C-x RET c *is* a
      ;; prefix command** - Emacs's own implementation calls
      ;; `prefix-command-preserve-state' - and this tree's prefix
      ;; argument already has exactly the extent this needs: the loop
      ;; reads it at the top of an iteration and clears it, so the value
      ;; a command leaves is consumed by the command that follows and by
      ;; no other. Emacs instead rewrites `this-command' into a closure
      ;; that *binds* the two coding-system variables around the real
      ;; command; the binding is what this loop's `parameterize' does
      ;; with this value, and it covers the command's own minibuffer read
      ;; as well, which is why a prefix survives a prompt.
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
    ;; ^ **The command procedure `interactive-proc` is invoking**, or #f
    ;; when nothing is - GNU Emacs's `called-interactively-p`
    ;; (`subr.el:6878`), which "return[s] t if the containing function was
    ;; called by `call-interactively`".
    ;;
    ;; The C asks the *stack*: `(backtrace-frame i ...)` walks out until it
    ;; finds the frame that called the function the question is asked in,
    ;; and answers t only if that frame is `funcall-interactively`
    ;; (`:6944`). So a command that calls *another* command - which is what
    ;; every minor mode's `(MODE #t)` is - gets nil there, and the mode
    ;; stays quiet.
    ;;
    ;; **A Scheme binding here cannot ask what function it is in**, and
    ;; this Guile's frames do not carry it either (`frame-procedure` is
    ;; not in this version, and `frame-procedure-name` answers #f for the
    ;; unnamed frame `apply` makes). So the parameter holds the command,
    ;; and the question is *which* command: `(called-interactively? MODE)`
    ;; is Emacs's answer exactly - it is true only while MODE is the
    ;; command being invoked - and the no-argument form is the
    ;; approximation "some command is running". `define-minor-mode` and
    ;; `menu-bar-mode` both pass their own procedure, so nothing a user
    ;; sees depends on the approximation.

    (define (called-interactively? . args)
      ;; GNU Emacs's `called-interactively-p`: "Return t if the function
      ;; it is called from was called with `call-interactively' and thus
      ;; can have been passed an `interactive' specification."
      ;;
      ;; PROC - this tree's addition - names the function the question is
      ;; asked from, which is the only way a Scheme library can pose the
      ;; C's question; with no PROC the answer is "a command is running".
      ;; Emacs's KIND argument (`'interactive', `'any') is not carried.
      ;;--------------------------------------------------------------
      (let ((running (*called-interactively*)))
        (if (pair? args)
            (and running (eq? running (car args)))
            (and running #t))))

    (define *command-table* (make-parameter '()))
    ;; ^ The command obarray: GNU Emacs's `command-obarray', an alist of
    ;; (NAME . COMMAND-RECORD) - the record that `M-x' and the
    ;; description commands will read, ordered most-recently-defined
    ;; first.

    (define (funcall-interactively command args)
      ;; GNU Emacs's `funcall-interactively` (`callint.c`): "Call
      ;; FUNCTION with ARGS. ... Unlike `funcall`, it marks the call as
      ;; interactive", which is the frame `called-interactively-p` looks
      ;; for. It is also the one place a command's arguments are applied,
      ;; so `interactive-proc`'s branches all come through it.
      ;;--------------------------------------------------------------
      (apply command args))

    (define *barf-if-buffer-read-only-function* (make-parameter #f))
    ;; ^ The check the `*' interactive code makes - `barf_if_buffer_read_only'
    ;; (`callint.c:370'). `barf-if-buffer-read-only' is `buffer.c`'s and
    ;; lives in `(schemacs editor buffer)', which cannot import this
    ;; library (this is the leaf everything above it uses), so the check
    ;; arrives through a seam: `(schemacs editor keyboard)' installs it as
    ;; it loads, which is where the command loop that reads an
    ;; interactive specification lives. `#f` means "no check", which is
    ;; what a caller that never loads a command loop gets - the same
    ;; shape as `*record-window-buffer-function*`.

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
                     (parameterize ((*called-interactively* command))
                       (funcall-interactively command '()))))
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
                         (*called-interactively* command))
            (funcall-interactively command (eval spec module)))))
       ;; The invoking event, which the command loop has bound - Emacs's
       ;; `args[i] = AREF (keys, next_event)' (`callint.c:608').
       ((string=? spec "e") (lambda (uarg)
                              (parameterize ((*called-interactively* command))
                                (funcall-interactively
                                 command (list (*last-command-event*))))))
       ((string=? spec "p") (lambda (uarg)
                              (parameterize ((*called-interactively* command))
                                (funcall-interactively
                                 command (list (uarg->integer 1 uarg))))))
       ((string=? spec "P") (lambda (uarg)
                              (parameterize ((*called-interactively* command))
                                (funcall-interactively command (list uarg)))))
       ;; **`*' is a check, not an argument code**: "an error is signaled
       ;; if the buffer is read-only" (`callint.c:98`). The C peels it off
       ;; with `@', `-', `+' and `^' before reading any code
       ;; (`callint.c:362`), so it is stripped from the front and the rest
       ;; is read as it would have been - and what remains of `"*"` alone
       ;; is the empty specification, which takes no arguments.
       ((and (string? spec)
             (> (string-length spec) 0)
             (char=? (string-ref spec 0) #\*))
        ;; One marker per call, and the rest read by the recursion - the
        ;; C's loop over the leading characters. **What remains of the
        ;; specification decides how the entry is called**, not the
        ;; marker: `"*"` alone leaves the empty specification, whose
        ;; entry is a thunk, while `"*p"` leaves one that takes the
        ;; prefix - and the command loop calls either by the record's
        ;; `uarg` flag, which any non-#f specification sets. The check
        ;; itself is read at *call* time, because the seam is installed
        ;; when the command loop loads and these entries are built when
        ;; the library does.
        (let* ((rest (substring spec 1))
               (empty? (string=? rest ""))
               (base (interactive-proc (if empty? #f rest) command module)))
          (lambda (uarg)
            (let ((check (*barf-if-buffer-read-only-function*)))
              (when check (check)))
            (if empty? (base) (base uarg)))))
       ;; **`^' is a marker, not an argument code.** `callint.c` reads it
       ;; as "this command shifts the mark" (`shift-select-mode`) and then
       ;; goes on with the rest of the string - `"^p"` is `"p"` with that
       ;; flag. This tree has no shift-select, so the marker is recognised
       ;; and dropped, and what follows is read as it would have been.
       ((and (string? spec)
             (> (string-length spec) 1)
             (char=? (string-ref spec 0) #\^))
        (interactive-proc (substring spec 1) command module))
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

    (define (register-command-alias! name command)
      ;; File NAME in the obarray against COMMAND's *own* record - the
      ;; step that makes `M-x NAME` find a command that has a second
      ;; name. GNU Emacs needs no such function: `defalias` writes the
      ;; one function object into the second symbol's function cell, and
      ;; `M-x` looks a symbol up in the obarray like anything else. This
      ;; tree's obarray is a table of *name to record*, so the second
      ;; name needs its own entry, and the record is shared - which is
      ;; what keeps `this-command`, `called-interactively-p` and the
      ;; docstring the same for both names.
      ;;
      ;; A target that is not a command registers nothing and answers
      ;; #f, as `defalias` of a non-command is not a command either.
      ;;--------------------------------------------------------------
      (let ((record (command-record-of command)))
        (when record
          (*command-table* (cons (cons (symbol->string name) record)
                                 (*command-table*))))
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

    (define (command-record-named name)
      ;; The command record NAME names, or #f.
      ;;
      ;; GNU Emacs needs no such function: `Fcommand_execute`
      ;; (`keyboard.c:1428`) is handed a *symbol* and finds its function in
      ;; the obarray. This tree's obarray is `*command-table*`, a table of
      ;; name to record, so the same step is a lookup here - and it is
      ;; what makes a keymap or menu item written Emacs's way (a symbol,
      ;; not a procedure) run.
      ;;--------------------------------------------------------------
      ;;
      ;; **The table is keyed by the command's *name string*.** Emacs's
      ;; obarray is keyed by the symbol; this tree's `new-command` takes
      ;; the name from `procedure-name` and keeps it as a string, so a
      ;; symbol - which is how Elisp spells a command - is compared as
      ;; its string.
      ;;--------------------------------------------------------------
      (let ((key (if (symbol? name) (symbol->string name) name)))
        (let loop ((rest (*command-table*)))
          (cond ((null? rest) #f)
                ((equal? (caar rest) key) (cdar rest))
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

    (define-syntax define-alias
      ;; GNU Emacs's `defalias` (`eval.c`): "Set SYMBOL's function
      ;; definition to DEFINITION" - a second *name* for the same
      ;; function. `tab-bar.el` uses it to give every tab command a short
      ;; name for M-x (`(defalias 'tab-new #'tab-bar-new-tab)`,
      ;; `:3179`), and `lisp/` is full of the same.
      ;;
      ;; **A `define` alone would be only half of it here.** The Scheme
      ;; binding makes the name callable, and a key bound to it works
      ;; (dispatch finds a command by its *procedure*, not its name) -
      ;; but `M-x` resolves a name through `*command-table*`, which only
      ;; `define-command` writes to. So the alias is registered too, and
      ;; both names complete in `M-x`, as they do in Emacs.
      ;;
      ;; Emacs's third argument, the DOCSTRING for the alias, is not
      ;; carried: nothing here reads a docstring from a name rather than
      ;; from the procedure (`procedure-documentation` is the one
      ;; reader), and an alias's documentation is the target's.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((define-alias alias target)
         (begin
           (define alias target)
           (register-command-alias! 'alias alias)))))

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
