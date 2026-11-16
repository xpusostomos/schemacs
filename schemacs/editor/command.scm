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
   *check-mark-function* *region-beginning-function* *region-end-function*
   *use-region-p-function*
   *point-marker-function* *mark-marker-function*
   *format-message-function* *read-string-function* *read-number-function*
   *read-char-event-function* *message-clear-function*
   *read-command-function* *read-variable-function*
   *read-minibuffer-function* *eval-minibuffer-function*
   *read-coding-system-function* *read-non-nil-coding-system-function*
   *interactive-read-existing-buffer-function*
   *interactive-read-buffer-function*
   *interactive-read-file-name-function*
   *interactive-read-directory-name-function*
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

    ;; The seams the argument codes need. `callint.c` is a leaf here -
    ;; everything above it defines commands - while the functions its
    ;; codes call are `editfns.c`'s and `simple.el`'s. So each arrives the
    ;; way `barf-if-buffer-read-only` does, installed by the library that
    ;; has it (`simple.scm` installs all four as it loads).
    (define *check-mark-function* (make-parameter #f))
    ;; ^ `callint.c:156`'s `check_mark`: signals when the mark is not set
    ;; ("The mark is not set now, so there is no region" for a region),
    ;; and when Transient Mark mode is on, the mark is not active and
    ;; `mark-even-if-inactive` is nil. Answers the mark's position.
    (define *region-beginning-function* (make-parameter #f))
    (define *region-end-function* (make-parameter #f))
    ;; ^ `editfns.c`'s `region-beginning` and `region-end`.
    (define *use-region-p-function* (make-parameter #f))
    ;; ^ `simple.el`'s `use-region-p`, which the `R` code asks.
    (define *point-marker-function* (make-parameter #f))
    (define *mark-marker-function* (make-parameter #f))
    ;; ^ `editfns.c`'s `point-marker` and `mark-marker`, for the `d` and
    ;; `m` codes. A *marker* is what the C hands the command, not a
    ;; position - `d` is `set_marker_both (point_marker, ...)` and `m` is
    ;; `BVAR (current_buffer, mark)`, which is the buffer's own mark
    ;; marker.
    ;;
    ;; Not in the C: `d`'s marker is a *bufferless* static that is
    ;; repositioned on the next call, where `point-marker` builds one
    ;; attached to the buffer. Same position, and a marker a command may
    ;; keep; `(marker-buffer ARG)` is the one answer that differs.
    (define (%interactive-seam seam name)
      ;; Read SEAM, which an interactive code cannot work without. `#f'
      ;; here is a *missing install*, not a value - so it is an error
      ;; naming the function, where a silently skipped check would make
      ;; the code answer nil and then fail inside the command.
      ;;--------------------------------------------------------------
      (or (seam)
          (error "Interactive specification needs `~a', which is not installed"
                 name)))

    (define (%interactive-markers spec)
      ;; The leading markers of a specification, in order, and the rest of
      ;; the string: `callint.c:362`'s "Handle special starting chars
      ;; `*' and `@'. Also `-'" loop, which peels them before any code is
      ;; read. Answers a pair (MARKERS . CODES).
      ;;--------------------------------------------------------------
      (let loop ((i 0) (markers '()))
        (if (= i (string-length spec))
            (cons (reverse markers) "")
            (let ((ch (string-ref spec i)))
              (if (memv ch '(#\* #\@ #\- #\+ #\^))
                  (loop (+ i 1) (cons ch markers))
                  (cons (reverse markers) (substring spec i)))))))

    (define *format-message-function* (make-parameter #f))
    (define *read-string-function* (make-parameter #f))
    (define *read-number-function* (make-parameter #f))
    ;; ^ The readers the minibuffer codes need. `format-message` is
    ;; `editfns.c`'s and the other two are `minibuf.c`'s and `subr.el`'s;
    ;; all three are above this library, so they arrive as seams -
    ;; `editfns.scm` installs the first and `minibuffer.scm` the other
    ;; two.
    ;;
    ;; `format-message` is here because a specification's *prompt* is
    ;; formatted with the arguments read so far
    ;; (`callint_message = Fformat_message (i - 1, visargs + 1)'), which
    ;; is how `"sQuery replace %s with: "' shows what the `s' before it
    ;; read.

    (define *interactive-read-file-name-function* (make-parameter #f))
    (define *interactive-read-directory-name-function* (make-parameter #f))
    (define *read-char-event-function* (make-parameter #f))
    (define *message-clear-function* (make-parameter #f))
    ;; ^ The `c' code's reader (`keyboard.c:11240`, spelled
    ;; `read-char-event` here because Guile's `read-char` reads a port)
    ;; and the echo-area
    ;; clear the C does straight after it (`message1_nolog (0)',
    ;; `callint.c:492'). Both names are free as Emacs variables.
    (define *read-command-function* (make-parameter #f))
    (define *read-variable-function* (make-parameter #f))
    (define *read-minibuffer-function* (make-parameter #f))
    (define *eval-minibuffer-function* (make-parameter #f))
    ;; ^ The `C', `x' and `X' readers. All three names are free as Emacs
    ;; variables, so they keep the plain spelling. `read-command' is
    ;; `minibuf.c'`s and the other two are `simple.el`'s; all three
    ;; prompt, so all three live in `minibuffer.scm'.
    (define *read-coding-system-function* (make-parameter #f))
    (define *read-non-nil-coding-system-function* (make-parameter #f))
    ;; ^ The `z' and `Z' readers. Both names are free as Emacs variables,
    ;; so they keep the plain spelling. `read-coding-system' is
    ;; `coding.c:8625' and `read-non-nil-coding-system' is `:8646'; both
    ;; prompt, so both live in `mule-cmds.scm'.
    (define *interactive-read-existing-buffer-function* (make-parameter #f))
    (define *interactive-read-buffer-function* (make-parameter #f))
    ;; ^ The file and buffer codes' readers, and the rule their names
    ;; follow: a seam takes the plain `<function>-function` name unless
    ;; Emacs has a *variable* of that name, in which case it is
    ;; `interactive-`-prefixed. `read-file-name-function` (a defcustom
    ;; that replaces `read-file-name`) and `read-buffer-function`
    ;; (`minibuf.c:2544`, `*read-buffer-function*` in `minibuf.scm`) are
    ;; such variables; `read-string` and `read-number` are nothing in
    ;; Emacs, which is why those two keep the plain spelling.
    ;;
    ;; Where a code's *arguments* are state this library cannot see, the
    ;; whole call is the seam and it takes the prompt alone:
    ;;
    ;;   `D' - DEFAULT is `BVAR (current_buffer, directory)` and
    ;;         PREDICATE is `Qfile_directory_p`;
    ;;   `b' - DEFAULT is the current buffer unless the minibuffer
    ;;         window is selected, and MUSTMATCH is `Qt';
    ;;   `B' - DEFAULT is `(other-buffer (current-buffer))`.
    ;;
    ;; `f', `F' and `G' differ only in constants this library *can* name,
    ;; so they share one seam and the constants are at the call sites.

    (define (%interactive-segments codes)
      ;; The specification split into codes and their prompts, in order,
      ;; the way `Fcall_interactively`'s loop walks it (`callint.c:441'):
      ;; the code is one character, and `visargs[1] = make_string (tem +
      ;; 1, sz)' is everything after it up to the next newline (`pnl') -
      ;; so `"sSearch: \nrRegion: "' gives `s' the prompt "Search: " and
      ;; `r' the prompt "Region: ". Answers a list of (CODE . PROMPT).
      ;;
      ;; The newline is the *separator* and also where the prompt ends,
      ;; which is why the C searches from `tem + 1' and not from `tem'.
      ;; A trailing newline simply ends the walk: the next code would be
      ;; at `pnl + 1', which is the end of the string.
      ;;--------------------------------------------------------------
      (let ((end (string-length codes)))
        (let loop ((i 0) (segments '()))
          (if (>= i end)
              (reverse segments)
              (let* ((code (string-ref codes i))
                     (pnl (let scan ((j (+ i 1)))
                            (cond ((>= j end) end)
                                  ((char=? (string-ref codes j) #\newline) j)
                                  (else (scan (+ j 1)))))))
                (loop (+ pnl 1)
                      (cons (cons code (substring codes (+ i 1) pnl))
                            segments)))))))

    (define (%interactive-message prompt visible)
      ;; The prompt the code at this position reads with: the C's
      ;; `Fformat_message (i - 1, visargs + 1)`, which formats PROMPT with
      ;; the arguments read so far. With none, it is
      ;; `(format-message PROMPT)' - and a `%' in the *first* code's
      ;; prompt is therefore "Not enough arguments for format string",
      ;; measured on Emacs 31.1 rather than assumed.
      ;;--------------------------------------------------------------
      (apply (%interactive-seam *format-message-function* 'format-message)
             prompt visible))

    (define (%zero-pad string width)
      ;; STRING padded on the left with zeroes to WIDTH - the C's `%03o'
      ;; and `%04x' for the invalid-code message. A number too wide for
      ;; the field is left alone, as `printf' leaves it.
      ;;--------------------------------------------------------------
      (string-append (make-string (max 0 (- width (string-length string))) #\0)
                     string))

    (define (%interactive-args segments uarg)
      ;; The argument list SEGMENTS build, in the C's order: each code
      ;; contributes no argument, one, or (for `r' and `R') two. A code
      ;; this tree does not read is an error naming the character.
      ;;
      ;; Two accumulators, the C's `args' and `visargs': ARGS is the
      ;; command's arguments as `funcall-interactively' will receive
      ;; them, and VISIBLE is the same arguments *as a prompt shows
      ;; them*, one entry per argument - a string for the codes that
      ;; read one, nil for the rest, which is the C's closing
      ;; "if visargs[i] is nil and args[i] is a string, use it" applied
      ;; as each argument is pushed. Only a later code's prompt can see
      ;; it.
      ;;--------------------------------------------------------------
      (let loop ((rest segments) (args '()) (visible '()))
        (if (null? rest)
            (reverse args)
            (let ((code (car (car rest)))
                  (prompt (cdr (car rest))))
              (cond
               ;; "Prefix arg converted to number" (`callint.c:668').
               ((char=? code #\p)
                (loop (cdr rest) (cons (uarg->integer 1 uarg) args)
                      (cons #f visible)))
               ;; "Prefix arg in raw form."
               ((char=? code #\P)
                (loop (cdr rest) (cons uarg args) (cons #f visible)))
               ;; "The invoking event" (`:600'): the event the command
               ;; loop bound for this command. The C walks to the next
               ;; *parameterized* event for a repeated `e'; this tree's
               ;; events are already one value, so it repeats that one.
               ((char=? code #\e)
                (loop (cdr rest) (cons (*last-command-event*) args)
                      (cons #f visible)))
               ;; "Ignore an argument" (`:525'): nil, and no I/O.
               ((char=? code #\i)
                (loop (cdr rest) (cons #f args) (cons #f visible)))
               ;; "Region, point and mark as 2 args" (`:681'): the C's
               ;; `check_mark (true)` and then the two positions, smaller
               ;; first - which is what `region-beginning'/`region-end'
               ;; answer once the mark has been checked.
               ((char=? code #\r)
                (let ((check (*check-mark-function*)))
                  (when check (check #t)))
                (let ((beg (let ((f (*region-beginning-function*))) (and f (f))))
                      (end (let ((f (*region-end-function*))) (and f (f)))))
                  (loop (cdr rest) (cons end (cons beg args))
                        (cons #f (cons #f visible)))))
               ;; "Active region, point and mark as 2 args" (`:676'):
               ;; the same, but *both* nil unless `use-region-p` - and
               ;; no mark check, because the C returns before the
               ;; fall-through to `r`.
               ((char=? code #\R)
                (let ((use? (let ((f (*use-region-p-function*))) (and f (f)))))
                  (if use?
                      (let ((beg (let ((f (*region-beginning-function*))) (and f (f))))
                            (end (let ((f (*region-end-function*))) (and f (f)))))
                        (loop (cdr rest) (cons end (cons beg args))
                              (cons #f (cons #f visible))))
                      (loop (cdr rest) (cons #f (cons #f args))
                            (cons #f (cons #f visible))))))
               ;; "Value of point. Does not do I/O" (`callint.c:502'):
               ;; a marker at point, which the command may keep.
               ((char=? code #\d)
                (let ((mark-at-point (%interactive-seam *point-marker-function*
                                                        'point-marker)))
                  (loop (cdr rest) (cons (mark-at-point) args)
                        (cons #f visible))))
               ;; "Value of mark. Does not do I/O" (`:623'): the mark
               ;; *checked* first - "The mark is not set now", not the
               ;; region's message - and then the buffer's own mark
               ;; marker.
               ((char=? code #\m)
                (let ((check (*check-mark-function*)))
                  (when check (check #f)))
                (let ((mark (%interactive-seam *mark-marker-function*
                                               'mark-marker)))
                  (loop (cdr rest) (cons (mark) args) (cons #f visible))))
               ;; "Existing file name" (`callint.c:514'): `read_file_name
               ;; (Qnil, Qlambda, Qnil, Qnil)'. `Qlambda' is what the C
               ;; passes for MUSTMATCH, not `t', and the two differ:
               ;; `completing-read' binds `minibuffer-completion-confirm'
               ;; to anything that is not `t', so `lambda' is the C's.
               ((char=? code #\f)
                (let ((read (%interactive-seam
                             *interactive-read-file-name-function*
                             'read-file-name)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible))
                                    'lambda #f)
                              args)
                        (cons #f visible))))
               ;; "Possibly nonexistent file name" (`:518'): MUSTMATCH nil.
               ((char=? code #\F)
                (let ((read (%interactive-seam
                             *interactive-read-file-name-function*
                             'read-file-name)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible))
                                    #f #f)
                              args)
                        (cons #f visible))))
               ;; "Possibly nonexistent file name, default to directory
               ;; alone" (`:522'): the same read with INITIAL "", which is
               ;; what makes the minibuffer hold just the directory.
               ((char=? code #\G)
                (let ((read (%interactive-seam
                             *interactive-read-file-name-function*
                             'read-file-name)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible))
                                    #f "")
                              args)
                        (cons #f visible))))
               ;; "Directory name" (`:509'): the buffer's directory as
               ;; DEFAULT and `file-directory-p' as the predicate - both
               ;; the installing library's, so the whole call is its.
               ((char=? code #\D)
                (let ((read (%interactive-seam
                             *interactive-read-directory-name-function*
                             'read-file-name)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible)))
                              args)
                        (cons #f visible))))
               ;; "Character" (`callint.c:482'). The prompt is shown as
               ;; a message (`message_with_string'), the event is read,
               ;; the echo area is cleared, and a read that is not a
               ;; character is an error - all four are the C's.
               ((char=? code #\c)
                (let* ((read (%interactive-seam *read-char-event-function*
                                                'read-char-event))
                       (answer (read (%interactive-message prompt (reverse visible)))))
                  (let ((clear (*message-clear-function*)))
                    (when clear (clear)))
                  (unless (and answer (integer? answer))
                    (error "Non-character input-event"))
                  (loop (cdr rest) (cons answer args)
                        (cons (string (integer->char answer)) visible))))
               ;; "Command: symbol with interactive function"
               ;; (`callint.c:495'): `Fcompleting_read (prompt, Vobarray,
               ;; Qcommandp, Qt, ...)' and then interned, which is
               ;; `read-command' whole. The visible form is the name
               ;; string, as the C's `visargs[i]' is.
               ((char=? code #\C)
                (let* ((read (%interactive-seam *read-command-function*
                                                'read-command))
                       (answer (read (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args)
                        (cons (and answer (symbol->string answer)) visible))))
               ;; "Variable name: symbol that is custom-variable-p"
               ;; (`callint.c:693'): `Fread_variable (prompt, Qnil)', which
               ;; is `minibuf.c'`s `read-variable'. The C's `visargs[i]` is
               ;; `last_minibuf_string`, so the visible form is the name.
               ((char=? code #\v)
                (let* ((read (%interactive-seam *read-variable-function*
                                                'read-variable))
                       (answer (read (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args)
                        (cons (and answer (symbol->string answer)) visible))))
               ;; "Lisp expression read but not evaluated" (`:699').
               ;;
               ;; **Departure**: the C's `visargs[i]` is
               ;; `last_minibuf_string` - the text typed. The reader here
               ;; answers the *form*, so a later prompt's `%s` shows nil
               ;; where Emacs would show the expression.
               ((char=? code #\x)
                (let ((read (%interactive-seam *read-minibuffer-function*
                                               'read-minibuffer)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible)))
                              args)
                        (cons #f visible))))
               ;; "Lisp expression read and evaluated" (`:704').
               ((char=? code #\X)
                (let ((read (%interactive-seam *eval-minibuffer-function*
                                               'eval-minibuffer)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible)))
                              args)
                        (cons #f visible))))
               ;; "Coding-system symbol or nil" (`callint.c:724'): the
               ;; read answers a symbol, and the C's `visargs[i]' is the
               ;; string that was read (`last_minibuf_string').
               ((char=? code #\z)
                (let* ((read (%interactive-seam *read-coding-system-function*
                                                'read-coding-system))
                       (answer (read (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args)
                        (cons (and answer (symbol->string answer)) visible))))
               ;; "Coding-system symbol, or ignore the argument if no
               ;; prefix" (`:709'): with no prefix there is no read at
               ;; all, and the argument is nil.
               ((char=? code #\Z)
                (if (and uarg (not (null? uarg)))
                    (let* ((read (%interactive-seam
                                  *read-non-nil-coding-system-function*
                                  'read-non-nil-coding-system))
                           (answer (read (%interactive-message prompt (reverse visible)))))
                      (loop (cdr rest) (cons answer args)
                            (cons (and answer (symbol->string answer)) visible)))
                    (loop (cdr rest) (cons #f args) (cons #f visible))))
               ;; "Name of existing buffer" (`callint.c:468'): the C's
               ;; default - the current buffer, or `other-buffer' when
               ;; the selected window is the minibuffer window - and
               ;; MUSTMATCH `Qt'. Both are the installing library's.
               ((char=? code #\b)
                (let ((read (%interactive-seam
                             *interactive-read-existing-buffer-function*
                             'read-buffer)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible)))
                              args)
                        (cons #f visible))))
               ;; "Name of buffer, possibly nonexistent" (`:475'): the
               ;; `other-buffer' default, and MUSTMATCH nil.
               ((char=? code #\B)
                (let ((read (%interactive-seam *interactive-read-buffer-function*
                                               'read-buffer)))
                  (loop (cdr rest)
                        (cons (read (%interactive-message prompt (reverse visible)))
                              args)
                        (cons #f visible))))
               ;; "String read via minibuffer without inheriting the
               ;; current input method" (`callint.c:681').
               ((char=? code #\s)
                (let ((answer ((%interactive-seam *read-string-function*
                                                  'read-string)
                               (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args) (cons answer visible))))
               ;; "String read via minibuffer with inheriting the current
               ;; input method" (`:630'): the same read here, because
               ;; `read-string`'s fifth argument is not carried - there is
               ;; no input method.
               ((char=? code #\M)
                (let ((answer ((%interactive-seam *read-string-function*
                                                  'read-string)
                               (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args) (cons answer visible))))
               ;; "Any symbol" (`:687'): the string read, then interned -
               ;; and the *string* is what a later prompt shows.
               ((char=? code #\S)
                (let ((answer ((%interactive-seam *read-string-function*
                                                  'read-string)
                               (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons (string->symbol answer) args)
                        (cons answer visible))))
               ;; "Read number from minibuffer" (`:640').
               ((char=? code #\n)
                (let ((answer ((%interactive-seam *read-number-function*
                                                  'read-number)
                               (%interactive-message prompt (reverse visible)))))
                  (loop (cdr rest) (cons answer args)
                        (cons (number->string answer) visible))))
               ;; "Prefix arg as number, else number from minibuffer"
               ;; (`:636'): the prefix is the *whole* answer when there
               ;; is one, and the `p' code's value when there is - so
               ;; "goto have_prefix_arg" is this branch, and it answers
               ;; nothing visible, as `p' does not.
               ((char=? code #\N)
                ;; The C's `!NILP (prefix_arg)' - and Elisp's nil is the
                ;; empty list as well as #f, so the *pair* has to be
                ;; tested: `()' is true in Scheme.
                (if (and uarg (not (null? uarg)))
                    (loop (cdr rest) (cons (uarg->integer 1 uarg) args)
                          (cons #f visible))
                    (let ((answer ((%interactive-seam *read-number-function*
                                                      'read-number)
                                   (%interactive-message prompt (reverse visible)))))
                      (loop (cdr rest) (cons answer args)
                            (cons (number->string answer) visible)))))
               (else
                ;; "Invalid control letter `%c' (#o%03o, #x%04x) in
                ;; interactive calling string" (`callint.c:744'). The
                ;; two numbers are zero-padded to the field widths the
                ;; C's `%03o' and `%04x' give - done here rather than by
                ;; a format directive because an error in this tree
                ;; carries a template and irritants, and it is the
                ;; *receiver* that formats them.
                (let ((n (char->integer code)))
                  (error "Invalid control letter `~a' (#o~a, #x~a) in interactive calling string"
                         code
                         (%zero-pad (number->string n 8) 3)
                         (%zero-pad (number->string n 16) 4)))))))))

    (define (interactive-proc spec command module)
      ;; The command's interactive entry: a procedure that reads what a
      ;; keyfinger supplies and calls COMMAND with it - GNU Emacs's
      ;; `call-interactively' reading the arguments once. SPEC is `#f'
      ;; (no arguments), a *string* of `callint.c`'s codes, or an
      ;; *expression* - a list, not a string - evaluated at the keypress
      ;; to produce the argument list, which is Emacs's
      ;; `(interactive (list ...))': `(interactive (list
      ;; (selected-window)))' hands COMMAND the window it is to delete.
      ;; The expression is evaluated in COMMAND's own module - the one
      ;; `register-command!' caught (MODULE) when the command was
      ;; defined, which is where the names it uses are bound. Evaluating
      ;; it where the keypress found `interactive-proc' would be wrong:
      ;; that is the command loop's module, and the command's helpers
      ;; are not all in it.
      ;;
      ;; The codes read are `p', `P', `e', `i', `r', `R', `d', `m', `s',
      ;; `S', `M', `n' and `N'. Each code owns the text after it up to
      ;; the next newline, which is its *prompt*. The rest of
      ;; `callint.c`'s alphabet is not carried, each because what it
      ;; needs is not here: `b'/`B' (a buffer name), `f'/`F'/`G'/`D' (a
      ;; file or directory), `c' (a character), `k'/`K'/`U' (a key
      ;; sequence), `x'/`X' (a Lisp expression), `z'/`Z' (a coding
      ;; system) and `a'/`C'/`v' (a function, command or variable name).
      ;; A specification with one of them answers "Invalid control
      ;; letter ... in interactive calling string" when the command
      ;; runs, which is Emacs's own message.
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
       ((string? spec)
        (let* ((peeled (%interactive-markers spec))
               (markers (car peeled))
               (segments (%interactive-segments (cdr peeled))))
          (lambda (uarg)
            (parameterize ((current-prefix-arg uarg)
                           (*called-interactively* command))
              ;; The markers are processed in the order they appear,
              ;; before any argument is read (`callint.c:362`).
              (for-each
               (lambda (marker)
                 (case marker
                   ;; "an error is signaled if the buffer is read-only".
                   ((#\*) (let ((check (*barf-if-buffer-read-only-function*)))
                             (when check (check))))
                   ;; "`+' is not used in `interactive' for ordinary
                   ;; commands" (`:367').
                   ((#\+) (error "`+' is not used in `interactive' for ordinary commands"))
                   ;; `^' asks `handle-shift-selection' when
                   ;; `shift-select-mode' is on, and this tree has no
                   ;; shift-select; `@' selects the window of the first
                   ;; mouse event, and this tree's events are not lists
                   ;; of window events. Both are recognised and do
                   ;; nothing, which is what `-' asks for anyway.
                   (else #f)))
               markers)
              (funcall-interactively command (%interactive-args segments uarg))))))
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
        (%file-command-name! name record)))

    (define (%file-command-name! name record)
      ;; Put NAME against RECORD in the command table, and answer
      ;; RECORD. **There is one way into the table, and this is it.**
      ;; `*command-table*` is a single thing - name to record - so a
      ;; command and a second name for that same command are not two
      ;; mechanisms: both are a name filed against a record.
      ;;
      ;; That is also why there is no `defalias` step here. GNU Emacs
      ;; needs none, because the obarray already holds the alias's symbol
      ;; and `M-x` asks `commandp` of it; this tree's table is keyed by
      ;; *name*, so a second name needs its own entry - and the RECORD is
      ;; shared, which is what keeps `this-command`,
      ;; `called-interactively-p` and the docstring identical through
      ;; either name.
      ;;
      ;; A nil RECORD files nothing: `defalias` of a non-command is not a
      ;; command either.
      ;;--------------------------------------------------------------
      (when record
        (*command-table* (cons (cons name record) (*command-table*))))
      record)

    (define (command-record-of thing)
      ;; The command record whose API is THING, or #f: how a key bound
      ;; to a `define-command' procedure is dispatched like one bound to a
      ;; record. GNU Emacs keeps `commandp' the same question - "is this
      ;; a command?" - and the answer here is "is there a table entry
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
           ;; the second half of `defalias`: the *name*, filed against
           ;; the target's own record. A target that is not a command
           ;; files nothing and the alias is not a command either.
           (%file-command-name! (symbol->string 'alias)
                                (command-record-of alias))))))

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
