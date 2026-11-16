(define-library (schemacs editor keyboard)
  ;; This library mirrors GNU Emacs's `keyboard.c': the command loop and
  ;; the reading of keys. It reads a key event, turns it into a key
  ;; sequence, looks that up in the keymap, runs the command it finds, and
  ;; reports what went wrong in the echo area - then does it again.
  ;;
  ;; The command loop can be *re-entered* rather than copied, which is what
  ;; makes a minibuffer possible: a minibuffer is this same loop called
  ;; again with a different keymap and a different current buffer, which is
  ;; GNU Emacs's `recursive-edit'. Everything the loop does for a command -
  ;; the undo boundary before it, the kill flag rotation, error reporting,
  ;; `last-command' - a prompt gets for free.
  ;;
  ;; Leaving a recursive edit is a `throw' in Emacs: `exit-minibuffer' does
  ;; `(throw \'exit nil)' (minibuffer.el:3048), and a *quit* is
  ;; `(throw \'exit <a function>)' (minibuffer.el:3060) - the function is
  ;; run when the recursive edit has been left, so the quit is raised in
  ;; the CALLER's context and travels out past the minibuffer to the command
  ;; loop, abandoning the command that asked the question. Continuations do
  ;; the same job here, and a quit is that same trick: the loop returns a
  ;; thunk, and the caller runs it.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
 (only (schemacs editor undo) *point-before-last-command-or-undo* *buffer-before-last-command-or-undo*)
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    ;; `delay' and `force` are the modal lookup state's: a step hands its
    ;; callbacks a *promise* of the key sequence rather than the sequence,
    ;; because only one of the three outcomes uses it.
    (only (scheme lazy) delay force)
    ;; `eval' is `menu_item_eval_property`'s - the dynamic parts of a
    ;; menu item (`:visible`, `:enable`, `:filter`) are forms.
    (scheme eval)
    ;; `let/ec' is the early `return' `parse_menu_item` is written with.
    (only (ice-9 control) let/ec)
    ;; The error the loop reports is formatted from the format string its
    ;; arguments arrive apart in.
    ;; `format' and `string-index' are Guile's and not R7RS's, and both are
    ;; on the error path: `report-command-error!' asks whether the message
    ;; has a `~' in it and fills it in if it has. Neither was imported, so
    ;; reporting an error failed - and only a test that makes a command
    ;; signal one could see it, because the error path is not otherwise
    ;; reached.
    (only (guile) format inexact->exact logior logand string-index
          current-module filter caddr
          ;; `init_signals`: C-g and C-\ arrive as signals, because
          ;; `init_sys_modes` made them the terminal's interrupt and quit
          ;; characters.
          sigaction SIGINT SIGQUIT)
    (prefix (schemacs editor keymap) km:)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs editor intervals) make-buffer-string get)

    ;; `xsignal3 (Qscan_error, ...)' - the condition `scan-lists' and the
    ;; motions signal, which the reporter below names rather than
    ;; printing "error".
    (only (schemacs editor syntax) scan-error? scan-error-string)
    
    (only (schemacs editor command)
          ;; The quit condition and its flag, which `keyboard-quit`
          ;; (`simple.scm`) has to reach and this library is above it.
          quit-char *quit-flag* *inhibit-quit* quit-condition?
          signal-quit maybe-quit rarely-quit
          *last-command-event*
          command-interactive-spec command-name command-record-of
          command-type? define-command
          run-command)
    ;; Reading a key, and asking the display what it means, is the
    ;; display's job - `getch', its timeout and the terminal's own key
    ;; table all belong to the driver, and this loop calls through the
    ;; interface.
    (only (schemacs editor dispnew)
          *mouse-event-keys* current-display key-event->key
          read-input-event)
    (only (schemacs editor frame)
          *current-frame* *pre-command-hook* blink-cursor-check
          display-selections-p frame-keymap-state
          frame-quit-cont run-pre-command-hook!
          set!frame-keymap-state set!frame-message
          set!frame-quit-cont
          *echo-area-buffer*)
    ;; The global map the lookup falls back on, and the local map a
    ;; minibuffer or a mode binds to have its own keys.
    (only (schemacs editor keymap)
          *current-keymap*
          *default-keymap*
          *special-event-map* define-key keymap-parent keymap-type?
          keymap-lookup
          ;; Emacs's `key-description', which the undefined-key message is
          ;; built out of (`subr.el:1297') - and `single-key-description',
          ;; which the prefix-argument echo uses.
          key-description)
    ;; The keys the current buffer has of its own - what gives a buffer
    ;; like `*Completions*' its own bindings - and which buffer is current.
    (only (schemacs editor buffer)
          buffer-local-keymap buffer-overwrite-mode
          current-buffer mark-active transient-mark-mode
          ;; `deactivate-mark' is a buffer-local *variable*
          ;; (`keyboard.c:14030'), not a slot of the buffer record: the
          ;; command loop clears it before every command and applies it
          ;; after, reading and writing it by name.
          buffer-local-value set-buffer-local-value! allocate-buffer buffer-pt
          ;; `get-text-property` is `textprop.c`'s, and `textprop.scm` is
          ;; *above* this library (`buffer.scm` imports this one), so the
          ;; read arrives through the seam `buffer.scm` holds for it -
          ;; the same one `barf-if-buffer-read-only` asks through.
          *get-text-property-function*)
    (only (schemacs editor simple)
          *last-change-was-undo* *last-command* *this-command*
          *select-active-regions*
          deactivate-mark clear-prefix! delete-char pending-uarg
          place-undo-boundary!
          undo undo-redo update-prefix!)
    ;; `message` is the C's `message3`, which logs before it displays:
    ;; `report-command-error!` below says an error the way Emacs does,
    ;; and in Emacs that leaves the line in `*Messages*` too.
    (only (schemacs editor editfns) insert message)
    ;; `barf-if-buffer-read-only' is `buffer.c`'s (`:2453'), and it lives
    ;; in `buffer.scm' now - `insdel.c`'s `prepare_to_modify_buffer_1' is
    ;; its main caller and `insdel.scm' is below `editfns.scm'.
    (only (schemacs editor buffer) barf-if-buffer-read-only)
    ;; `uarg->integer' is `callint.c''s, in the command library the
    ;; commands' interactive specs come from.
    (only (schemacs editor command) uarg->integer current-prefix-arg
          *pending-coding-system* command-record-named command-value-of)
    ;; The two variables C-x RET c names for the next command. They are
    ;; `coding.c`'s, and they are bound here because the command loop is
    ;; what has the extent Emacs binds them for.
    (only (schemacs editor coding)
          *coding-system-for-read* *coding-system-for-write*)
    ;; The primary selection the command loop keeps updated while the
    ;; region stays active - the call `keyboard.c:1639' makes.
    (only (schemacs editor select) gui-set-selection
          *saved-region-selection*)
    ;; The region's text, which the update is of.
    (only (schemacs editor editfns) region-beginning region-end)
    ;; `render!' after every key: the loop is what drives the display.
    ;; `*menu-bar-items-function*` is the seam the redisplay builds a
    ;; terminal's menu bar through - see the note on it in `xdisp.scm`.
    (only (schemacs editor xdisp)
          render! redisplay-frames! *menu-bar-items-function*
          *tab-bar-items-function* *tab-bar-keymap-function*)
    ;; The development back door, which the command loop gives its turn
    ;; between keys. A no-op unless `SCHEMACS_REPL' opened it.
    (only (scheme-utils repl server) poll-repl! repl-running? repl-wake)
    ;; The clock. The read's timeout is shortened to the next timer
    ;; (`read-timeout-or'), and the timers are run when it expires - which
    ;; is how a cursor blink happens while the editor sits still.
    (only (schemacs editor timer)
          *timer-idle-list* *timer-list* cancel-timer current-idle-time
          set!timer-due-at timer-args timer-due-at
          timer-function timer-idle? timer-idle-start! timer-idle-stop!
          timer-mark-run! timer-repeat timer-ripe?
          ;; The delay to the next timer and the front end's wake are the
          ;; timer module's: "when is the next timer due" is a fact about
          ;; the timer lists. This library keeps only the loop that acts
          ;; on them. See `timer.sld'.
          timer-next-delay timer-reschedule!)
    ;; `ceiling' and `inexact->exact' are Guile's; the delay is a
    ;; fractional number of seconds and the read wants whole milliseconds.
    (only (guile) ceiling delq inexact->exact)
    ;; the clock the next timer's delay is measured against
    ;; the millisecond clock a timed read's deadline is measured against -
    ;; the same two calls the front ends' own `now-ms' are made of
    (only (guile) get-internal-real-time internal-time-units-per-second)
    ;; `ignore' is what the special-event-map binds a key that the loop
    ;; must receive but not act on to - the frame's resize.
    (only (schemacs editor subr)
          kbd ignore *minor-mode-map-alist* keymap-canonicalize
          ;; A click's position list: its area and, when it landed on a
          ;; *string* - a tab, a mode line - the string and offset, which
          ;; is where a `keymap` text property is found. `keyboard.c`'s
          ;; `POSN_POSN`/`POSN_STRING`, used below.
          posn-area posn-string event-start)
    (only (schemacs editor character)
          char-meta char-alt char-super char-hyper char-shift char-ctl
          parse-modifiers-uncached event-convert-list)
    )

  (export
   ;; `*current-keymap*' and `*special-event-map*' are not re-exported:
   ;; they are `(schemacs editor keymap)''s, and a library that both
   ;; imports and exports a name gives its importers two of it.
   *recursive-edit-exit*
   *unread-command-events*
   abort-recursive-edit
   command-loop
   dispatch-key
   dispatch-key-event
   dispatch-input-event *last-read-event*
   ;; GNU Emacs's `command-remapping' - what a `[remap COMMAND]' binding
   ;; in the active maps answers, applied by the loop before a command
   ;; runs (`keyboard.c').
   command-remapping
   function-key-translate
   event-loop
   ;; The outermost loop for a front end that owns its own: no loop at
   ;; all, just these three - the hook an event is pushed into, and the
   ;; two halves of what the loop does around one.
   event-loop-on
   *dispatch-event*
   command-loop-key!
   command-loop-idle!
   command-loop-ready?
   exit-recursive-edit
   quoted-insert
   read-quoted-char
   *overriding-terminal-local-map*
   *this-command-keys*
   ;; `keyboard.c`'s menu-bar half. `menu_bar_items` and `parse_menu_item`
   ;; are C-internal in Emacs (the front end calls them); here the front
   ;; end is Scheme and must import them, so the property slots are
   ;; exported with them.
   *menu-bar-final-items* *overriding-local-map-menu-flag*
   menu-bar-items parse-menu-item menu-separator-name?
   tab-bar-items lookup-keymaps
   ;; `keymap.c`'s, in this library for the reason its header gives:
   ;; its default argument is `current-active-maps`, which is this
   ;; file's `lookup-keymaps`.
   where-is-internal
   *enable-disabled-menus-and-buttons*
   *item-properties*
   item-property-item item-property-name item-property-def
   item-property-map item-property-type item-property-keyeq
   item-property-selected item-property-help item-property-enable
   ;; The modal lookup state - `read_key_sequence''s one-event-at-a-time
   ;; walk. It was `(schemacs keymap)''s and is `keyboard.c''s; the
   ;; accessors are published because the tests drive the walk by hand.
   new-modal-lookup-state modal-lookup-state-type?
   modal-lookup-state-step! modal-lookup-state-key-index
   modal-lookup-state-keymaps
   internal-pop-keymap
   internal-push-keymap
   read-key-event
   read-menu-command
   key-binding
   read-wait-ms
   recursive-edit
   set-transient-map
   sit-for
   report-command-error!
   ;; `signal-quit`, `quit-char`, `*quit-flag*` and `*inhibit-quit*` are
   ;; `(schemacs editor command)`'s and re-exported here, so that every
   ;; importer of this library is unchanged.
   signal-quit quit-char *quit-flag* *inhibit-quit*
   ;; The SIGINT handler and `maybe_quit` - `keyboard.c`'s and `eval.c`'s.
   handle-interrupt init-signals maybe-quit
   ;; `timer_check' and the read's deadline are the command loop's, so
   ;; they are published the way the rest of the loop is.
   timer-check!
   timer-next-delay
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Key events

    ;; `*esc-pending*' is keyboard.c's own state (its meta-prefix
    ;; resolution), which is why it lives here and not on the frame.
    (define *esc-pending* (make-parameter #f))

    (define *this-command-keys* (make-parameter #()))
    ;; ^ GNU Emacs's `this-command-keys' - "the key sequence that invoked
    ;; this command" - which `keyboard.c' keeps for the command being run
    ;; and `read_key_sequence' fills in as the chord is entered. It is a
    ;; **vector of events**, which is exactly Emacs's
    ;; `this-command-keys-vector', and what `keymap-lookup' takes. Its
    ;; one reader for now is `set-transient-map''s keep test, which is
    ;; exactly Emacs's `(lookup-key map (this-command-keys-vector))'.

    (define *overriding-terminal-local-map* #f)
    ;; ^ GNU Emacs's `overriding-terminal-local-map' (`keyboard.c',
    ;; `Voverriding_terminal_local_map'), which `keyboard.c:8704' puts
    ;; **first** of all the maps a key is looked up in - ahead of the
    ;; buffer's own map, the mode maps and `global-map'. It is what
    ;; `set-transient-map' installs into, and the only thing that does.
    ;;
    ;; **A plain variable, not a parameter**, because Emacs's is a
    ;; kboard slot with no dynamic binding of its own: the transient map
    ;; is pushed and popped by name, and the pop happens from
    ;; `pre-command-hook', long after any `parameterize' that installed
    ;; it would have unwound.
    ;;
    ;; **A list of keymaps, most recently pushed first, where Emacs's is
    ;; one composed keymap.** A keymap here is a record, and
    ;; `make-composed-keymap' - the list `(keymap add-keymap-witness MAP
    ;; ...)' - would be a second representation of the same idea; the
    ;; order is what matters to the lookup, so the list carries the order
    ;; and `lookup-keymaps' splices it in. `add-keymap-witness' exists in
    ;; Emacs to tell a bare keymap from a composed one in this same
    ;; variable, and nothing here sets it to a bare keymap.

    (define (internal-push-keymap keymap)
      ;; GNU Emacs's `internal-push-keymap' (`subr.el:6976'), which takes
      ;; the variable as its second argument because Lisp can `set' a
      ;; symbol and Scheme cannot; there is one such variable here.
      ;;
      ;; "Add KEYMAP to the front of the list, unless it is already
      ;; there" - which is Emacs's `(unless (memq keymap map) ...)', and
      ;; it is what makes pushing the same map twice a no-op rather than
      ;; a duplicate that has to be popped twice.
      ;;--------------------------------------------------------------
      ;;
      ;; Emacs's `(memq keymap map)' reads nil as the empty list; here the
      ;; variable's empty value is #f (Emacs's nil, spelled the way this
      ;; tree spells nil where a list is expected), and `memq' on #f would
      ;; be a type error rather than an empty answer.
      ;;--------------------------------------------------------------
      (when (not (memq keymap (or *overriding-terminal-local-map* '())))
        (set! *overriding-terminal-local-map*
              (cons keymap (or *overriding-terminal-local-map* '())))))

    (define (internal-pop-keymap keymap)
      ;; GNU Emacs's `internal-pop-keymap' (`subr.el:6985'): take KEYMAP
      ;; back off. Emacs also collapses the composed keymap back to the
      ;; bare map it started as when the last transient map goes; here
      ;; the empty list *is* the bare state, so dropping the map is the
      ;; whole of it.
      ;;--------------------------------------------------------------
      (when (memq keymap (or *overriding-terminal-local-map* '()))
        (set! *overriding-terminal-local-map*
              (delq keymap (or *overriding-terminal-local-map* '()))))
      (when (null? *overriding-terminal-local-map*)
        (set! *overriding-terminal-local-map* #f)))

    (define *function-key-map*
      ;; GNU Emacs's `function-key-map' (`keyboard.c':14209', filled by
      ;; `bindings.el':1554' and `lisp/term/common-win.el'). It "decodes
      ;; input escape sequences": a key that is not a character, but that
      ;; has a character people expect it to mean, is translated into
      ;; that character before anything looks the key up. `read_key_sequence'
      ;; is where Emacs consults it; here it is `function-key-translate',
      ;; called from `dispatch-key'.
      ;;
      ;; The entries are the ones a plain (unmodified) key has, read off
      ;; a real Emacs (`emacs -Q --batch'): the erase key is DEL 127,
      ;; Return is 13, TAB is 9, Escape is 27 - which is what makes a
      ;; window system's Return the same key a terminal's byte 13 is -
      ;; and the keypad is spelled into the key beside it, `kp-enter' to
      ;; 13 and `kp-0' to `0'. A key with no entry (`up', `f1', `menu')
      ;; passes through unchanged and is looked up as itself.
      ;;
      ;; The modifier combinations `function-key-map' also carries
      ;; (`C-kp-1' and the rest, `bindings.el':1541') and the M- ones in
      ;; `x-alternatives-map' are not here yet.
      ;;--------------------------------------------------------------
      (list (cons 'backspace 127) (cons 'delete 127) (cons 'kp-delete 127)
            (cons 'tab 9) (cons 'kp-tab 9) (cons 'linefeed 10)
            (cons 'clear 12)
            (cons 'return 13) (cons 'kp-enter 13)
            (cons 'escape 27)
            (cons 'kp-space 32)
            (cons 'kp-multiply 42) (cons 'kp-add 43) (cons 'kp-separator 44)
            (cons 'kp-subtract 45) (cons 'kp-decimal 46) (cons 'kp-divide 47)
            (cons 'kp-0 48) (cons 'kp-1 49) (cons 'kp-2 50) (cons 'kp-3 51)
            (cons 'kp-4 52) (cons 'kp-5 53) (cons 'kp-6 54) (cons 'kp-7 55)
            (cons 'kp-8 56) (cons 'kp-9 57) (cons 'kp-equal 61)
            (cons 'kp-home 'home) (cons 'kp-left 'left) (cons 'kp-up 'up)
            (cons 'kp-right 'right) (cons 'kp-down 'down)
            (cons 'kp-prior 'prior) (cons 'kp-next 'next) (cons 'kp-end 'end)
            (cons 'kp-begin 'begin) (cons 'kp-insert 'insert)))

    (define (function-key-translate key)
      ;; KEY as `function-key-map' means it, or KEY itself when it has no
      ;; entry there. `read_key_sequence''s translation step, over one
      ;; key rather than a sequence - every read here answers one.
      ;;--------------------------------------------------------------
      (if (symbol? key)
          (let ((found (assq key *function-key-map*)))
            (if found (cdr found) key))
          key))

    (define *selection-inhibit-update-commands*
      ;; GNU Emacs's `selection-inhibit-update-commands' (keyboard.c:14371):
      ;; "List of commands which should not update the selection.
      ;; Normally, if `select-active-regions' is non-nil and the mark
      ;; remains active after a command (i.e. the mark was not
      ;; deactivated), the Emacs command loop sets the selection to the
      ;; text in the region.  However, if the command is in this list,
      ;; the selection is not updated." The two are `handle-switch-frame'
      ;; and `handle-select-window', window-switching commands of which
      ;; there are none here yet - `memq' on them is harmless.
      ;;--------------------------------------------------------------
      (make-parameter '(handle-switch-frame handle-select-window)))

    (define *unread-command-events* (make-parameter '()))
    ;; ^ GNU Emacs's `unread-command-events': events put back on the
    ;; input, which the next read answers before it asks the display.
    ;; isearch pushes the key that ended a search onto it so the command
    ;; loop runs that key, which is what `isearch-other-control-char'
    ;; does in `isearch.el'. It is keyboard.c's variable - the read's
    ;; first step is `read_char''s - which is why it is here and not on
    ;; the display.

    (define (this-command-name)
      ;; The command's name, as `Vthis_command' is in the C: the symbol
      ;; `define-command' bound the procedure with. A command may have
      ;; renamed itself while it ran - `kill-region' to itself,
      ;; `yank-pop' to `yank' - so the question is asked of
      ;; `*this-command*' after the command, not of the key's action.
      ;;--------------------------------------------------------------
      (let ((cmd (*this-command*)))
        (if (symbol? cmd)
            cmd
            (let ((record (command-record-of cmd)))
              (and record (command-name record))))))

    (define (dispatch-action frame action)
      ;; Run an action reached by a key lookup. The pending prefix
      ;; argument is consumed here, not when the key event arrives, so
      ;; that it survives the intermediate keys of a chord. mg's
      ;; per-command flag rotation happens here too, which is what
      ;; breaks a run of consecutive kills at any command that is not
      ;; itself a kill.
      ;;
      ;; This is also the command loop's undo work: a boundary goes into
      ;; the buffer's undo list before the command runs, so that the
      ;; command's edits form one change group and one undo undoes one
      ;; command. The undo commands themselves are the exception to
      ;; `last-change-was-undo', which is how a redo knows there is
      ;; something to redo.
      ;;--------------------------------------------------------------
      (let* ((action (remapped-command action))
             (uarg (pending-uarg))
             ;; C-x RET c leaves a coding system for *this* command, the
             ;; way C-u leaves a prefix argument - read here so that
             ;; `clear-prefix!' below is what consumes both.
             (coding (*pending-coding-system*))
             (buffer (current-buffer)))
        ;; Emacs clears its buffer-local deferred flag before every command;
        ;; edits and region commands may set it again while they run.
        (set-buffer-local-value! buffer 'deactivate-mark #f)
        ;; `this_command' is what is running - and a command may *change*
        ;; it (`kill-region' renames itself to itself, `yank-pop' says
        ;; `yank'), which is why the promotion to `last-command' reads it
        ;; again after the command rather than using ACTION.
        (*this-command* action)
        (place-undo-boundary! action)
        (unless (or (eq? action undo) (eq? action undo-redo))
          (*last-change-was-undo* #f))
        (clear-prefix!)
        (*pending-coding-system* #f)
        (set!frame-message frame "")
        ;; `pre-command-hook', run here because Emacs runs it here: after
        ;; `this-command' is set and before the command itself
        ;; (`keyboard.c': "Vthis_command = cmd; ... safe_run_hooks
        ;; (Qpre_command_hook)"). The blinking cursor is its one user -
        ;; the first key you press after a pause is what stops the blink
        ;; and gives you a solid cursor to type at.
        (run-pre-command-hook!)
        ;; A command that cannot do what it was asked - editing a
        ;; read-only buffer, say - signals an error, and the command
        ;; loop reports it in the echo area and carries on, as GNU Emacs
        ;; does. Letting it out would take the editor down with it.
        ;; Bound around the command, as Emacs's rewritten `this-command'
        ;; binds them: the extent has to cover the command's own
        ;; minibuffer read, which is where a coding system is usually
        ;; *named* - a `let' would leave the prompt outside it.
        (parameterize ((*coding-system-for-read* coding)
                       (*coding-system-for-write* coding))
        ;; "Record point and buffer, so we can put point into the undo
        ;; information if necessary" - `keyboard.c:1534`, which the
        ;; command loop does before running the command. `record_point`
        ;; (`undo.c:50`) reads them to push the integer entry that puts
        ;; point back where the command began; without it, undoing a
        ;; `kill-line` - which moves point to the far end of what it
        ;; kills, as Emacs's own does - left point one character along.
        (*point-before-last-command-or-undo* (buffer-pt (current-buffer)))
        (*buffer-before-last-command-or-undo* (current-buffer))
        (guard (ex (else (report-command-error! frame ex)))
          (cond
           ((command-type? action)
            ;; A command declares with its interactive spec whether it
            ;; takes the universal argument; the default (#f) takes none.
            (if (command-interactive-spec action)
                (run-command action uarg)
                (run-command action)))
           ((symbol? action)
            ;; **A command *name*.** GNU Emacs's `command-execute` is
            ;; handed a symbol and finds its function in the obarray
            ;; (`keyboard.c:1428`); a menu item is usually written that
            ;; way - `(menu-item "Save" save-buffer)` - while this
            ;; tree's keymaps usually hold the procedure itself. Both
            ;; have to run, and an item holding the symbol that did not
            ;; is `not a command`.
            (let ((record (command-record-named action)))
              (if record
                  (if (command-interactive-spec record)
                      (run-command record uarg)
                      (run-command record))
                  (error "not a command" action))))
           ((procedure? action)
            ;; A procedure the keymap holds. It may be a
            ;; `define-command' - a bare procedure whose command record sits
            ;; in the obarray - in which case it is run like the record
            ;; it belongs to, so the interactive specification is
            ;; honoured; otherwise it is a plain procedure to call.
            (let ((record (command-record-of action)))
              (if record
                  (if (command-interactive-spec record)
                      (run-command record uarg)
                      (run-command record))
                  (action))))
           (else (error "not a command" action)))))
        ;; Commands such as `kill-ring-save' set the buffer's deferred
        ;; `deactivate-mark' flag. Apply it after the command, as Emacs does,
        ;; so later motion does not extend the copied region. Not
        ;; deactivating - the mark still active - is keyboard.c:1615's
        ;; else-branch: with `select-active-regions' on, PRIMARY is set to
        ;; the region after every command, which is how a selection stays
        ;; current for other programs while the region is being adjusted.
        ;; The conditions are the C's: `window-system', or the tty's
        ;; `tty-select-active-regions' with `xterm--set-selection' - both
        ;; `display-selections-p' - with the mark really set
        ;; (Bug#7044's check; the mark is the buffer's own here), Transient
        ;; Mark mode on, and the command not on the inhibit list. The
        ;; region text is what `region-extract-function''s default makes,
        ;; which `deactivate-mark' makes too, and an empty selection is
        ;; not set. `post-select-region-hook' is not run - no user of it.
        (when (mark-active)
          (if (buffer-local-value buffer 'deactivate-mark #f)
              (begin
                (set-buffer-local-value! buffer 'deactivate-mark #f)
                (deactivate-mark))
              (when (and (display-selections-p)
                         (*select-active-regions*)
                         (transient-mark-mode)
                         (not (memq (this-command-name)
                                    (*selection-inhibit-update-commands*))))
                ;; `buffer' and not `(current-buffer)' or
                ;; `(current-editor)': this command loop bound it once at
                ;; the top, which is the C's `current_buffer' for the
                ;; whole command (keyboard.c:1615-1647), and
                ;; `region-beginning'/`region-end' answer against the
                ;; same buffer. Re-reading it here asks a *different*
                ;; question - a command may have moved the current
                ;; buffer, and the answer at this point is not
                ;; necessarily the one the positions were computed in.
                (let ((txt (make-buffer-string
                            buffer
                            (region-beginning)
                            (region-end))))
                  (unless (= 0 (string-length txt))
                    ;; Don't set empty selections.
                    (gui-set-selection 'PRIMARY txt)))))
          ;; `Vsaved_region_selection = Qnil' (keyboard.c:1647) - spent
          ;; after every command the mark was active through.
          (*saved-region-selection* #f))
        (*last-command* (*this-command*))))

    (define (report-command-error! frame ex)
      ;; ... including a quit, which Emacs's command loop reports as
      ;; "Quit" rather than as an error.
      ;;--------------------------------------------------------------
      ;; Show in the echo area what went wrong, the way GNU Emacs's
      ;; command loop does with the errors its commands signal. Many
      ;; errors arrive as a format string with its arguments kept apart
      ;; ("Wrong type argument in position ~A: ~S"), so the text is put
      ;; together here; Emacs shows the formatted message too.
      ;;--------------------------------------------------------------
      ;; **`message', not `set!frame-message'**, because Emacs's error
      ;; path logs: `print_error_message` (`print.c:1098') prints with
      ;; `Fprinc (errmsg, Qt)`, and `Qt' as a print function is the echo
      ;; area *through* `message_dolog` (`print.c:410') - which is why
      ;; `C-f` at the end of a buffer leaves "End of buffer" in
      ;; `*Messages*` (measured, Emacs 31.1).
      ;;
      ;; The C also prefixes the line with the function the error was
      ;; signalled in - `print_error_message`'s CALLER, from
      ;; `Vsignaling_function` - so Emacs's line reads
      ;; "funcall-interactively: End of buffer". This tree's command loop
      ;; does not carry that variable, so the text is logged without the
      ;; prefix: a named departure, not a guess at the name.
      ;; **`cmd_error` clears the quit state** (`keyboard.c:1014`):
      ;; "Vquit_flag = Qnil; Vinhibit_quit = Qnil;". Without it the flag
      ;; the SIGINT handler set would still be there when the next read
      ;; began, and the editor would quit again and again.
      (when (quit-condition? ex)
        (*quit-flag* #f)
        (*inhibit-quit* #f))
      (message
       "%s"
       (cond
        ((quit-condition? ex) "Quit")
        ((scan-error? ex) (scan-error-string ex))
        ((error-object? ex)
         (let ((message (error-object-message ex))
               (irritants (error-object-irritants ex)))
           (if (and (list? irritants)
                    (string-index message #\~))
               (apply format #f message irritants)
               message)))
        (else "error"))))

    ;; `special-event-map' is in `(schemacs editor keymap)', beside
    ;; `*default-keymap*' - which Emacs also creates in `keymap.c', and
    ;; which this tree put in the leaf for the same reason: the libraries
    ;; that own the commands bind into it, and they cannot import this
    ;; library.

    ;; The frame's resize: Emacs has no resize key - a frame resize is
    ;; handled by redisplay re-framing (`window-size-change-functions'),
    ;; and the event only has to be dispatched for this loop to redraw,
    ;; which is what `render!' does by re-tiling. Emacs binds keys that
    ;; must be received but not acted on to `ignore' (`bindings.el:1757',
    ;; `[sigusr1]' in `special-event-map'), which is what this is.
    (define-key *special-event-map* (kbd "<resize>") ignore)

    ;; `*default-keymap*' - which Emacs also creates in `keymap.c', and
    ;; which this tree put in the leaf for the same reason: the libraries
    ;; that own the commands bind into it, and they cannot import this
    ;; library.

    (define (minor-mode-keymaps)
      ;; The keymaps of the minor modes that are on *in this buffer*, in
      ;; `*minor-mode-map-alist*' order - the order an alist is walked in,
      ;; and the order `current_active_maps' (`keymap.c') walks it, so an
      ;; entry added later shadows one added earlier.
      ;;
      ;; A mode's variable is buffer-local here (`define-minor-mode'
      ;; writes it with `set-buffer-local-value!'), so "is the mode on" is
      ;; the same question and the same answer as Emacs's.
      ;;--------------------------------------------------------------
      (let loop ((rest (*minor-mode-map-alist*)) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((buffer-local-value (current-buffer) (caar rest) #f)
               (loop (cdr rest) (cons (cdar rest) acc)))
              (else (loop (cdr rest) acc)))))

    (define (command-remapping command)
      ;; GNU Emacs's `command-remapping' (`keymap.c:1216'): "Return the
      ;; remapping for command COMMAND. Returns nil if COMMAND is not
      ;; remapped (or not a symbol)."
      ;;
      ;; The C makes the vector `[remap COMMAND]' and asks `key-binding'
      ;; for it in the active maps. A key here is already an event or a
      ;; vector, so that binding is an ordinary one and this is the same
      ;; lookup the command loop makes.
      ;; "if (!SYMBOLP (command)) return Qnil" - the C's first line. A
      ;; command name here is a string, so the test is the guard that keeps
      ;; a string from being taken for a key event.
      ;;--------------------------------------------------------------
      (and (symbol? command)
           (let loop ((maps (lookup-keymaps)))
             (and (pair? maps)
                  (or (km:keymap-lookup (car maps) (vector 'remap command))
                      (loop (cdr maps)))))))

    (define (remapped-command action)
      ;; ACTION, or the command a keymap remaps it to. Emacs applies this
      ;; at the top of `command_loop_1' - `cmd = Fcommand_remapping (cmd,
      ;; Qnil, Qnil)' - before `this-command' is set, so the remapped
      ;; command is the one that runs and the one recorded.
      ;;
      ;; COMMAND is a symbol in Emacs. A command here is a procedure whose
      ;; record carries the symbol it was defined under, and the symbol is
      ;; what a `[remap ...]' binding names.
      ;;--------------------------------------------------------------
      (let* ((record (if (command-type? action) action (command-record-of action)))
             (name (and record (command-name record)))
             (mapped (and name (command-remapping name))))
        (or mapped action)))

    (define (lookup-keymaps . args)
      ;; What a key sequence is looked up in, in precedence order. GNU
      ;; Emacs's `read_key_sequence' searches, in order: the current
      ;; buffer's own map (`current-local-map', the keymap a buffer has of
      ;; its own) and then `global-map'. `NEW-MODAL-LOOKUP-STATE' takes the
      ;; list.
      ;;
      ;; The buffer's map comes first, which is what gives a `*Buffer
      ;; List*' or a `*Completions*' buffer its own keys - the reason the
      ;; buffer has a keymap slot at all. `*CURRENT-KEYMAP*' is the map a
      ;; *mode* binds around the buffer it is reading: the minibuffer binds
      ;; its own there while it reads, which in Emacs is the same thing as
      ;; the minibuffer's buffer having a local map, since the minibuffer
      ;; is the current buffer while it is read.
      ;;
      ;; The keymaps are *shared* with the list, so a binding made after
      ;; this is built is still found; what is fixed is the list itself.
      ;; That is why a buffer's map needs no copy of the global one - the
      ;; precedence is settled per lookup rather than once at load.
      ;;--------------------------------------------------------------
      ;; **A click adds the map its position carries**, which is GNU
      ;; Emacs's `current_active_maps (Qt, position)` (`keymap.c:1649`):
      ;; for a cons POSITION it takes the `local-map` and `keymap` *text
      ;; properties* of the string the click landed on - a tab, a mode
      ;; line, an overlay string - and conses the `keymap` one in front of
      ;; the buffer's and the minor modes'. That, and only that, is what
      ;; makes a tab a button: the string `tab-line-format` builds
      ;; carries `keymap tab-line-tab-map`, and the command lives there.
      (let* ((position (and (pair? args) (car args)))
             (string (and position (posn-string position)))
             (position-map
              (and string
                   (let ((s (car string)) (pos (cdr string)))
                     (and (integer? pos)
                          (>= pos 0)
                          (< pos (string-length s))
                          (let ((lookup (*get-text-property-function*)))
                            (and lookup (lookup pos 'keymap s))))))))
        (let ((buffer-keys (buffer-local-keymap (current-buffer)))
              (mode-keys (*current-keymap*)))
        ;; **`overriding-terminal-local-map' first**, which is where
        ;; `keyboard.c:8704' puts it: ahead of the buffer's own map, the
        ;; mode maps and `global-map'. That is the whole of what makes a
        ;; `set-transient-map' transient map take precedence.
        ;;
        ;; `special-event-map' used to be listed first here - "the window
        ;; system's events are looked up in it before the ordinary maps".
        ;; It is not a map of this list at all any more:
        ;; `dispatch-special-event' looks an event up in it before this
        ;; lookup is reached, which is where Emacs does it (`read_char',
        ;; `keyboard.c:3113') and is what keeps a frame event out of the
        ;; command loop's head.
        (append
         (or *overriding-terminal-local-map* '())
         (if position-map (list position-map) '())
         ;; **The enabled minor modes' maps come before the buffer's own**,
         ;; where `current_active_maps' (`keymap.c') puts them: a minor
         ;; mode's key shadows the buffer's, and the buffer's shadows
         ;; `global-map'.
         (minor-mode-keymaps)
         (if buffer-keys (%keymap-and-parents buffer-keys) '())
         (if mode-keys (%keymap-and-parents mode-keys) '())
         (%keymap-and-parents *default-keymap*)))))

    ;;----------------------------------------------------------------
    ;; The modal lookup state - `read_key_sequence''s feel for a chord
    ;;------------------------------------------------------------------
    ;;
    ;; In Emacs, key lookup is modal: `read_key_sequence' (`keyboard.c')
    ;; reads ONE event at a time, and each step looks that event up in the
    ;; keymap the last step reached. A *keymap* answer means the sequence
    ;; so far is a prefix and the next event is looked up in it; anything
    ;; else is the command and the chord ends there; nothing at all ends
    ;; it as an undefined key. `lookup-keymaps' above is the list of maps
    ;; the FIRST event is looked up in - `read_key_sequence' searches the
    ;; buffer's own map and then `global-map' - and this state is what
    ;; carries that from one event to the next.
    ;;
    ;; **This was `(schemacs editor keymap)''s, and it is `keyboard.c''s.** That
    ;; library kept a keymap as a list of "layers" and this state folded
    ;; the map *list* into it; the layers are gone, so the state holds the
    ;; maps it was given and tries them in order - which is the same
    ;; search, without a representation invented for it.
    ;;------------------------------------------------------------------

    (define-record-type <modal-lookup-state-type>
      (make<modal-lookup-state-type> keymaps stack)
      modal-lookup-state-type?
      (keymaps modal-lookup-state-keymaps set!modal-lookup-state-keymaps)
      (stack   modal-lookup-state-index-stack set!modal-lookup-state-index-stack))

    (define (new-modal-lookup-state km)
      ;; A new state over one keymap, or over a *list* of them.
      ;;
      ;; A list is a precedence order: the first keymap that binds the key
      ;; wins, and one that does not falls through to the next. It is what
      ;; `lookup-keymaps' builds, and what GNU Emacs's `read_key_sequence'
      ;; does with the buffer's local map and then `global-map'.
      ;;--------------------------------------------------------------
      (cond
       ((km:keymap-type? km)
        (make<modal-lookup-state-type> (list km) '()))
       ((and (list? km) (pair? km) (km:keymap-type? (car km)))
        (make<modal-lookup-state-type> km '()))
       ((null? km)
        (error "no keymap to look a key sequence up in"))
       (else
        (error "argument must be a <keymap-type> or a list of them" km))))

    (define (modal-lookup-state-key-index state)
      ;; The key sequence read so far - a *list of events*, which is what
      ;; GNU Emacs's `this-command-keys' answers with (a vector, there;
      ;; the same events).
      ;;--------------------------------------------------------------
      (reverse (modal-lookup-state-index-stack state)))

    (define (modal-lookup-state-lookup state event)
      ;; Look ONE event up in the state's keymaps, in precedence order.
      ;;--------------------------------------------------------------
      (let loop ((maps (modal-lookup-state-keymaps state)))
        (cond
         ((null? maps) #f)
         (else
          (let ((got (km:keymap-lookup (car maps) (list event))))
            (or got (loop (cdr maps))))))))

    (define (key-binding key)
      ;; GNU Emacs's `key-binding' (`keymap.c`): "Return the binding for
      ;; command KEY in the current keymaps. KEY is a string or vector,
      ;; that gives the key sequence."
      ;;
      ;; **The lookup's answer is coerced, as `access_keymap` coerces
      ;; it.** A menu-bar item is bound as `(STRING . DEFN)` and an
      ;; extended one as `(menu-item NAME DEFN ...)`; both are *menu
      ;; spellings* of the binding, and a caller that is not the menu
      ;; builder - `popup-menu` looking up `[menu-bar file]` - wants the
      ;; DEFN. `get_keyelt` (`keymap.c:678`) is that step, and
      ;; `get_keyelt`'s note in `(schemacs editor menu)` says what
      ;; happens without it: the clicked item's sequence stops at the
      ;; first symbol.
      ;;--------------------------------------------------------------
      (define (coerce def)
        (cond
         ((and (pair? def) (string? (car def))) (cdr def))
         ((and (pair? def) (eq? (car def) 'menu-item))
          (and (>= (length def) 3) (list-ref def 2)))
         (else def)))
      (let loop ((maps (lookup-keymaps)))
        (if (null? maps)
            #f
            (let ((def (coerce (km:keymap-lookup (car maps) key))))
              (if def def (loop (cdr maps)))))))

    (define (modal-lookup-state-step! state event do-action do-wait-next do-fail-lookup)
      ;; One event of `read_key_sequence''s walk.
      ;;
      ;; DO-ACTION is called with a promise of the key sequence and the
      ;; action found - the chord is over. DO-WAIT-NEXT is called with the
      ;; same promise and the keymap the sequence has become a prefix of -
      ;; more events are wanted. DO-FAIL-LOOKUP is called with the key
      ;; sequence itself when the event named nothing at all. The answer
      ;; is #t while more events are wanted and #f when the chord ended.
      ;;--------------------------------------------------------------
      (let* ((stack (cons event (modal-lookup-state-index-stack state)))
             (full-key (delay (reverse stack)))
             (action-or-map (modal-lookup-state-lookup state event)))
        (set!modal-lookup-state-index-stack state stack)
        (cond
         ((and action-or-map (not (km:keymap-type? action-or-map)))
          (set!modal-lookup-state-keymaps state '())
          (do-action full-key action-or-map)
          #f)
         ((km:keymap-type? action-or-map)
          (set!modal-lookup-state-keymaps state (list action-or-map))
          (do-wait-next full-key action-or-map) #t)
         (else
          (set!modal-lookup-state-keymaps state '())
          (do-fail-lookup (force full-key)) #f))))

    (define (%keymap-and-parents keymap)
      ;; KEYMAP and its parents, nearest first.
      ;;
      ;; **This is what makes `set-keymap-parent' mean anything**, and
      ;; without it the tree had a map-inheritance mechanism that did
      ;; nothing. GNU Emacs searches a keymap and then its parent - a
      ;; child's binding shadows the parent's, which is the whole point of
      ;; `define-derived-mode''s `(set-keymap-parent CHILD-map
      ;; (current-local-map))' and of dired's `(set-keymap-parent map
      ;; special-mode-map)'.
      ;;
      ;; What the lookup did instead was walk a map's own *layers* and stop
      ;; (`keymap-lookup-binding-key' in `(schemacs editor keymap)'), and no map
      ;; in this tree has one of its parents among its layers. So every
      ;; parent was decorative: a mode that inherited a key did not have
      ;; it, and the only reason nothing showed is that the modes which
      ;; need a key tend to bind it themselves rather than inherit it.
      ;; The Buffer Menu's note about `g' being "inherited from
      ;; `special-mode-map'' was true of Emacs and not of here.
      ;;--------------------------------------------------------------
      (let loop ((map keymap) (out '()))
        (if (not map)
            (reverse out)
            (loop (keymap-parent map) (cons map out)))))

    (define (dispatch-special-event frame key)
      ;; Whether KEY is a *special event* and has been handled as one -
      ;; GNU Emacs's `read_char' (`keyboard.c:3113'), which looks the
      ;; event up in `special-event-map' by itself and, when it hits,
      ;; runs the handler with `command-execute' and goes back to
      ;; reading. These are the window system's events: a frame's focus,
      ;; its deletion, its resize.
      ;;
      ;; **The handler runs with the command loop's duties left undone**,
      ;; which is what `command-execute' from `read_char' means: no undo
      ;; boundary is placed, the handler does not become `this-command',
      ;; and `pre-command-hook' does not run. That last is the one that
      ;; matters to `set-transient-map' - its clearfun lives on that hook
      ;; - and it is why this is here rather than in `lookup-keymaps',
      ;; where the map used to sit first of all the maps: a frame event
      ;; that ran through `dispatch-action' popped any transient map, and
      ;; a window is resized the moment a drag's pointer leaves it.
      ;;--------------------------------------------------------------
      (let ((handler (km:keymap-lookup *special-event-map* key)))
        (and handler
             (begin
               (*last-read-event* (list key (list frame)))
               (let ((record (if (command-type? handler)
                                 handler
                                 (command-record-of handler))))
                 (if record
                     (parameterize ((*last-command-event* (list key (list frame))))
                       (if (command-interactive-spec record)
                           (run-command record #f)
                           (run-command record)))
                     (handler)))
               #t))))

    (define (dispatch-key-event frame key)
      ;; Dispatch one key *event* - and, for a click in a named area,
      ;; the two events Emacs makes of it.
      ;;
      ;; **GNU Emacs's fake prefix** (`keyboard.c:11947`): "Clicks in
      ;; non-text areas get prefixed by the symbol in their CHAR-ADDRESS
      ;; field. For example, a click on the mode line is prefixed by the
      ;; symbol `mode-line'." `read_key_sequence` turns one event into
      ;; two - `keybuf[t] = posn; keybuf[t+1] = key` - and looks the pair
      ;; up, which is how `[tab-line down-mouse-1]` is a key at all.
      ;;
      ;; The prefix is a *lookup* prefix, not a command: the sequence only
      ;; continues if the area symbol opened a keymap. When it did not -
      ;; every area but a tab's, today - the pair is not a key, and Emacs's
      ;; "last event alone" rule runs the click by itself, which is what
      ;; `dispatch-key-1`'s fail arm does. `silent?` is what tells the
      ;; area symbol's own step not to report it undefined: an unbound
      ;; area is the *ordinary* case.
      ;;--------------------------------------------------------------
      (let* ((mouse-posn (and (symbol? key)
                              (memq key *mouse-event-keys*)
                              (let ((raw (*last-read-event*)))
                                (and (pair? raw) (event-start raw)))))
             (area (and mouse-posn (posn-area mouse-posn))))
        (if (and area (not (frame-keymap-state frame)))
            (begin
              (dispatch-key-1 frame area mouse-posn #t)
              ;; The click itself, whether the area was a prefix or not.
              (dispatch-key-1 frame key mouse-posn #f))
            (dispatch-key-1 frame key mouse-posn #f))))

    (define (dispatch-key-1 frame key position silent?)
      ;; Dispatch one key *event* through the modal keymap lookup. The
      ;; modal lookup state persists across events while a chord
      ;; (such as C-x C-c) is being entered. C-u and digits are
      ;; consumed as prefix arguments before the keymap lookup; the
      ;; pending prefix is left alone for the rest of the chord and is
      ;; consumed by `dispatch-action' when a command finally runs.
      ;;
      ;; KEY is an event, which is what every read answers with and what
      ;; the keymap is keyed by - one event per step of the walk, as
      ;; `read_key_sequence' reads one key at a time.
      ;;--------------------------------------------------------------
      ;; **`last-command-event', set where the C sets it.** GNU Emacs sets
      ;; it in the command loop, once per command, to the last event of the
      ;; sequence it just read (`keyboard.c:1449': `last_command_event =
      ;; keybuf[i - 1]'), so it is the key you finished typing with: in
      ;; `C-x C-f' the `f', and in `C-u 3 a' the `a'. Setting it as each
      ;; event is dispatched lands on the same value, and doing it here
      ;; covers the events a prefix swallows as well.
      ;;
      ;; A *mouse* key keeps its own value - the one with the window and
      ;; the position in it - because that is the event Emacs's
      ;; `last-command-event' holds for a click; a frame event's value is
      ;; the frame, `(focus-in (FRAME))' as Emacs builds it.
      ;;
      ;; It is bound here and not in `dispatch-key' so that a caller
      ;; holding a decoded key and no display event gets it too - the
      ;; harness drives named keys with a direct call, `(dispatch-key-event
      ;; frame #\z)', and the ESC-prefixed keys of `dispatch-key' come
      ;; straight here as well.
      (parameterize ((*last-command-event*
                      (if (symbol? key)
                          (let ((raw (*last-read-event*)))
                            (if (and (pair? raw) (memq (car raw) *mouse-keys*))
                                raw
                                (list key (list frame))))
                          key)))
      (if (dispatch-special-event frame key)
          #t
          (if (update-prefix! key)
          ;; C-u or a prefix digit was consumed. It is a command in
          ;; its own right, so like any other command it breaks a run
          ;; of consecutive kills - by *being* the last command, which
          ;; is what `kill-region' asks about.
          (begin
            (*last-command* 'kill-region)
            (set!frame-keymap-state frame #f))
          ;; any other key: continue (or start) the keymap lookup
          (begin
            (let* ((continuing? (and (frame-keymap-state frame) #t))
                   (state
                    (or (frame-keymap-state frame)
                        (new-modal-lookup-state (lookup-keymaps position)))))
              ;; NOTE: the state is stored on the frame BEFORE the lookup
              ;; step, because the step's callbacks read it - `do-action'
              ;; reads the completed chord off it for `*this-command-keys*'
              ;; and the undefined-key message.
              (set!frame-keymap-state frame state)
              (let* ((run
                      (lambda (st action)
                        ;; **The chord that ran the command**, which
                        ;; `set-transient-map`'s keep test reads - GNU
                        ;; Emacs's `this-command-keys'. It has to be
                        ;; bound around `dispatch-action` and not merely
                        ;; set, because it must cover `pre-command-hook`
                        ;; as well as the command itself.
                        (parameterize
                            ((*this-command-keys*
                              (list->vector
                               (modal-lookup-state-key-index st))))
                          (dispatch-action frame action))
                        #f))
                     (report-undefined
                      (lambda (full-path)
                        ;; An undefined key ends the chord: the pending
                        ;; prefix is discarded with it, the way GNU Emacs
                        ;; drops a prefix argument when the key sequence it
                        ;; precedes is not a command.
                        ;;
                        ;; **The message is Emacs's `undefined' command's**
                        ;; (`subr.el:1297'):
                        ;;
                        ;;   (message "%s is undefined"
                        ;;            (key-description (this-single-command-keys)))
                        ;;
                        ;; so it reads `C-c C-z is undefined' and not this
                        ;; tree's old `; undefined key: ...', which printed
                        ;; the keymap's *private* spelling at the user.
                        ;; `key-description` is Emacs's, over the events the
                        ;; chord actually was. The `ding` that command does
                        ;; first is not ported - there is no bell here (the
                        ;; same gap `minibuffer.sld` notes for the
                        ;; completion messages).
                        (clear-prefix!)
                        (set!frame-message
                         frame
                         (string-append
                          (key-description
                           (list->vector
                            (km:keymap-index->events full-path)))
                          " is undefined"))))
                     (fail
                      (lambda (full-path)
                        ;; **Emacs's "last event alone" rule.** When a
                        ;; sequence that began with a prefix has no
                        ;; binding, `read_key_sequence` throws the prefix
                        ;; away and looks the event just read up by
                        ;; itself - which is what makes `C-x C-g` *quit*
                        ;; rather than being an undefined `C-x C-g`. This
                        ;; tree only reported it undefined, and that was
                        ;; not merely cosmetic: C-g arrives as SIGINT, its
                        ;; `quit-flag` is cleared by `keyboard-quit`, and
                        ;; `keyboard-quit` never ran - so the flag stayed
                        ;; set, the next read raised `quit`, and the
                        ;; terminal editor exited. Measured at a pty:
                        ;; `C-x C-g` printed a backtrace and killed the
                        ;; editor.
                        (let* ((alone (new-modal-lookup-state
                                       (lookup-keymaps position)))
                               ;; **A step answers #f both for "the chord
                               ;; ended with a command" and for "nothing
                               ;; was bound"**, so the answer cannot say
                               ;; whether the retry succeeded: the command
                               ;; running is what does.
                               (found? #f)
                               (retried
                                (modal-lookup-state-step!
                                 alone key
                                 (lambda (fp action)
                                   (set! found? #t)
                                   (run alone action))
                                 (lambda (fp action)
                                   (set! found? #t)
                                   #t)
                                 (lambda (fp) #f))))
                          ;; Emacs's rule is "if the last event alone has
                          ;; a binding, use it"; a last event that is a
                          ;; prefix map by itself is not used, which is
                          ;; the one corner this does not take.
                          (unless (or found? silent?)
                            (report-undefined full-path)))))
                     (result
                      (modal-lookup-state-step!
                       state key
                       (lambda (full-path action) (run state action))
                       (lambda (full-path action) #t)
                       fail)))
                (set!frame-keymap-state frame (and result state)))))))))

    (define (dispatch-key frame key)
      ;; Dispatch one *key event* - the integer or symbol `read-key-event'
      ;; answers with - applying the Emacs ASCII protocol where ESC
      ;; prefixes the next key with the meta modifier.
      ;;
      ;; Nothing here knows which front end is running: the display's own
      ;; form was normalised away by `read-key-event' - or by
      ;; `dispatch-input-event', for a caller holding one - into the very
      ;; event GNU Emacs's `read_char' would have answered with.
      ;;--------------------------------------------------------------
      ;; `function-key-map' first, as `read_key_sequence' does: the
      ;; erase key, Return, TAB and Escape are translated into the
      ;; characters they mean before anything looks them up.
      (set! key (function-key-translate key))
      (cond
       ;; ESC prefixes the next key with the meta modifier. Its event is
       ;; 27, `(kbd "ESC")', and it is the same event from either display:
       ;; a terminal sends byte 27, and Gtk sends the keysym 0xff1b, which
       ;; `character-path' folds to control-[ and so to the same event
       ;; - "the two displays must name it the same way or a keymap
       ;; binding one misses the other". A test against the *character*
       ;; was a terminal-shaped one, and on Gtk a lone ESC came out an
       ;; unhandled event instead of prefixing the next key.
       ((eqv? key (event-convert-list '(control #\[)))
        (*esc-pending* #t))
       ;; and the next key takes the meta modifier, which is how a
       ;; terminal's `ESC x' becomes `M-x'. A *character* event takes
       ;; the C's `CHAR_META' bit - `(logior key char-meta)' is
       ;; `make_lispy_event''s own arithmetic - and a named key becomes
       ;; the symbol with `M-' on it, which is `M-up', exactly as
       ;; `(kbd "M-<up>")' spells it. `event-convert-list' is the C's
       ;; way from a description to an event and is what both do.
       ((and (*esc-pending*) key)
        (*esc-pending* #f)
        (dispatch-key-event
         frame (if (integer? key)
                   (logior key char-meta)
                   (event-convert-list (list 'meta key)))))
       (else
        (*esc-pending* #f)
        (dispatch-key-event frame key))))

    (define (dispatch-input-event frame ev)
      ;; Dispatch one event *as a display answered it*: normalise it into
      ;; the key event and dispatch that. The command loop does not come
      ;; through here - it reads through `read-key-event', which has
      ;; already normalised - but a caller that holds a display's own
      ;; event wants exactly that, and the harness that drives a front end
      ;; by hand is such a caller: `AGENTS.md`'s
      ;; `(dispatch-input-event f (+ #x20 (* 4 (expt 2 32))))` names the
      ;; integer a Gtk key arrives as. The display's decode is called in
      ;; these two places and nowhere else.
      ;;--------------------------------------------------------------
      (let ((key (key-event->key (current-display) ev)))
        (if key
            (begin
              ;; **The event's own value goes with the key.** A mouse
              ;; click's value is where it happened, and `dispatch-key-
              ;; event' hands it to the command as `(interactive "e")'
              ;; does; a key has no value of its own and is dispatched
              ;; from the key alone. Emacs carries the same thing in
              ;; `last-input-event'.
              (*last-read-event* ev)
              (dispatch-key frame key))
            (begin
              (*esc-pending* #f)
              (set!frame-message
               frame
               (string-append "; unhandled event: "
                              (cond ((integer? ev) (number->string ev))
                                    ((char? ev) (string ev))
                                    (else "#f"))))))))

    ;;----------------------------------------------------------------
    ;; The command loop, and recursive edits
    ;;
    ;; GNU Emacs's command loop: read a key, run the command it names,
    ;; redraw, and repeat. The important thing is that it can be
    ;; *re-entered* rather than copied: a minibuffer is this same loop
    ;; called again with a different keymap and a different current
    ;; buffer, which is Emacs's `recursive-edit'. Everything the loop
    ;; does for a command - the undo boundary before it, the kill flag
    ;; rotation, error reporting, `last-command' - a prompt gets for
    ;; free, instead of each hand-rolled reader re-implementing RET, C-g
    ;; and end of input for itself.
    ;;
    ;; Leaving a recursive edit is a `throw' in Emacs: `exit-minibuffer'
    ;; does `(throw 'exit nil)' (minibuffer.el:3048), and a *quit* is
    ;; `(throw 'exit <a function>)' (minibuffer.el:3060) - the function
    ;; is run when the recursive edit has been left, so the quit signal
    ;; is raised in the CALLER's context and travels out past the
    ;; minibuffer to the command loop, abandoning the command that asked
    ;; the question. Continuations do the same job here, and a quit is
    ;; that same trick: the loop returns a thunk, and the caller runs it.
    ;;------------------------------------------------------------------

    ;;----------------------------------------------------------------
    ;; Quitting: `quit-flag`, `inhibit-quit`, and C-g as a *signal*
    ;;
    ;; GNU Emacs's `keyboard.c` and `eval.c`. The terminal's `VINTR` is
    ;; `quit-char` (`init_sys_modes`, `sysdep.c:1163`), so a C-g does not
    ;; arrive as a byte at all: the kernel turns it into SIGINT, and
    ;; `handle_interrupt` records that the user asked to quit. Two things
    ;; read that record - `maybe-quit` in a loop, and the read itself,
    ;; which answers `quit-char` as an event so that the keymaps see the
    ;; C-g they are bound for.
    ;;
    ;; **Why a signal rather than a key.** It is the only way C-g can
    ;; interrupt a *blocked* wait: the byte would sit in the input queue
    ;; until the read that is already waiting returned. It is also what
    ;; makes `C-q C-g` possible - `read_char` answers `quit_char` for a
    ;; pending flag (`keyboard.c:2806`), so the quoted-insert reads a C-g
    ;; even though the kernel consumed the byte.
    ;;------------------------------------------------------------------

    ;; `quit-char`, `*quit-flag*`, `*inhibit-quit*`, the `<quit-condition>`
    ;; record and `signal-quit` are `(schemacs editor command)`'s - see the
    ;; note there. They are re-exported below, so every importer of this
    ;; library is unchanged.

    (define force-quit-count 0)
    ;; ^ `force_quit_count`: the third C-g in a row quits even inside
    ;; `inhibit-quit`, which is how a user escapes a loop that meant to be
    ;; uninterruptible.

    (define (handle-interrupt sig)
      ;; GNU Emacs's `handle_interrupt` (`keyboard.c`): "Request quit when
      ;; it's safe."
      ;;
      ;; **The emergency-escape branch is not carried.** The C's first
      ;; branch is for `quit-flag' holding `kill-emacs' - it drops to a
      ;; shell and offers to auto-save and dump core - and nothing here
      ;; sets that value.
      ;;--------------------------------------------------------------
      (let ((count (if (*quit-flag*) (+ force-quit-count 1) 1)))
        (set! force-quit-count count)
        (when (= count 3)
          (*inhibit-quit* #f))
        (*quit-flag* #t)))

    (define (init-signals)
      ;; GNU Emacs's `init_signals` (`keyboard.c`), the two that matter for
      ;; a terminal: `init_sys_modes` made C-g the interrupt character and
      ;; C-\ the quit character, so both arrive here and neither reaches
      ;; the byte reader.
      ;;--------------------------------------------------------------
      (sigaction SIGINT handle-interrupt)
      (sigaction SIGQUIT handle-interrupt))

    ;; `maybe-quit` and `rarely-quit` are `(schemacs editor command)`'s -
    ;; see the note there. They sat here until 2026-11-15, and the scans
    ;; in `syntax.scm` that need them could not reach them.

    (define *recursive-edit-exit* (make-parameter #f))

    (define (key-event? ev)
      ;; Whether a read produced a key: a key *event*, and not the `#f' a
      ;; read that produced nothing answers with. The driver's
      ;; `read-input-event' answers `#f' for a timed-out read, a
      ;; non-blocking read with no input, and the end of input alike, and
      ;; `read-key-event' turns everything that is not `#f' into an
      ;; event.
      ;;
      ;; The distinction this loses is end of input against a timeout.
      ;; It is recovered by the caller from the *timeout*: a blocking
      ;; read only comes back with nothing at the end of input, so the
      ;; editor is left then and not otherwise.
      ;;--------------------------------------------------------------
      (not (eq? ev #f)))

    (define (%now-ms)
      ;; Milliseconds since some fixed point, for a read's deadline.
      ;;--------------------------------------------------------------
      (quotient (* 1000 (get-internal-real-time))
                internal-time-units-per-second))

    (define (read-key-event timeout)
      ;; Read one key for the command loop, TIMEOUT milliseconds allowed -
      ;; a negative TIMEOUT blocks. The answer is the *key event* GNU
      ;; Emacs's `read_char' would answer with - the integer 19 for
      ;; `C-s', the symbol `up' for an arrow - or `#f' for a read that
      ;; produced nothing. A key put back on `*unread-command-events*' is
      ;; answered first, which is how the loop runs a key a command gave
      ;; back to it; otherwise the display is asked for one. GNU Emacs's
      ;; `read_char' takes the same first step.
      ;;
      ;; This is the read every key comes through, whatever asked for it:
      ;; the command loop, isearch's own reading, and the minibuffer's
      ;; y-or-n question all call it - so this is where the two displays'
      ;; forms of a key are made *one*, and it is the only place that has
      ;; to know them.
      ;;
      ;; They do not agree. A terminal folds the modifiers into the byte
      ;; and `read-input-event' answers a character or a keypad code; Gtk
      ;; answers every key as the integer `(modifiers . keysym)'. GNU
      ;; Emacs has no such difference to bridge, because the reader
      ;; normalises: `read_char' hands back one event whatever the input
      ;; source produced, and every command above it compares events and
      ;; modifiers without asking where they came from. Everything above
      ;; this line needs the same freedom - and it already speaks the
      ;; *event*, which is what a key is looked up by:
      ;; `dispatch-key-event', `y-or-n-p', `perform-replace' and
      ;; `read-quoted-char' all take one. `key-event->key' is the
      ;; display's own decode into it, and this is the one call.
      ;;
      ;; `isearch' read the display's event itself and compared it to
      ;; characters - a terminal-shaped test - so on Gtk every key it read
      ;; was a number that matched nothing, and no key did anything,
      ;; `C-g' included.
      ;;--------------------------------------------------------------
      ;;
      ;; **A special event is handled here and the read goes on**, which
      ;; is the other half of `read_char''s own arrangement
      ;; (`keyboard.c:3108'): "Process special events within read_char and
      ;; loop around to read another event", then `goto retry'. The
      ;; handler runs, and the event is *not* returned to whoever asked -
      ;; so a read keeps waiting through a frame resize or a focus change
      ;; instead of being ended by one. That is what makes a drag that has
      ;; left the window keep scrolling: `mouse-scroll-subr''s loop ends
      ;; on any input at all, and a window resize is not input. Returning
      ;; it here is what made the drag scroll one step per resize event.
      ;;
      ;; The deadline is *absolute* across those retries, as the C's is:
      ;; `read_filtered_event' computes the end time once and hands
      ;; `read_char' the same one every time round, so a special event
      ;; does not extend the wait.
      ;;
      ;; The redisplay is here for the same reason the event exists at
      ;; all: Emacs re-frames a resized window from its own redisplay, and
      ;; this tree's `render!' is what re-tiles from the display's size.
      ;; Emacs has no such event - a GUI frame resize is not input there -
      ;; so there is nothing of its own for this line to copy; what it
      ;; copies is that the *next* redisplay is what acts on the resize.
      ;;--------------------------------------------------------------
      (let ((deadline (and (>= timeout 0) (+ (%now-ms) timeout))))
        (let loop ()
          ;; **`read_key_sequence` opens with `maybe_quit ()`**
          ;; (`keyboard.c:11917`): a quit recorded since the last read is
          ;; signalled now, which is what makes a C-g that arrived while a
          ;; command was running take effect at the next read. A C-g that
          ;; arrives *during* the read below is the other half - the read
          ;; answers `quit_char` for it, as `read_char` does.
          (maybe-quit)
          (let* ((unread (*unread-command-events*))
                   (ev (if (null? unread)
                           (let ((raw (read-input-event
                                       (current-display)
                                       (if deadline
                                           (max 0 (- deadline (%now-ms)))
                                           timeout))))
                             (*last-read-event* raw)
                             (and raw (key-event->key (current-display) raw)))
                           (begin
                             (*unread-command-events* (cdr unread))
                             (car unread)))))
              ;; **`read_key_sequence` clears `Vquit_flag` after every key
              ;; it reads** (`keyboard.c:11892`). The flag is what the
              ;; terminal's read turned into `quit_char` above
              ;; (`keyboard.c:2806`); leaving it set is what made a C-g
              ;; that aborted isearch fire again at the *next*
              ;; `maybe-quit` - as a quit condition raised out of the
              ;; command loop's read, which nothing caught, so the editor
              ;; exited. A real C-g key (a Gtk frame's) leaves the flag
              ;; #f and this is a no-op.
              (when (and (eqv? ev quit-char) (*quit-flag*))
                (*quit-flag* #f))
              (if (and ev (dispatch-special-event (*current-frame*) ev))
                  (begin
                    (redisplay-frames!)
                    (loop))
                  ev)))))

    (define (read-menu-command)
      ;; GNU Emacs's `read_menu_command' (`keyboard.c:1691'): read one key
      ;; sequence *for a tty menu*, and answer the command it names
      ;; without running it.
      ;;
      ;; **The command is not executed**, which is the whole difference
      ;; from the command loop: `tty_menu_activate` looks at which of the
      ;; `tty-menu-*` symbols it got and acts on it itself
      ;; (`term.c:3630'). A key the navigation map does not bind falls
      ;; through to the global map - `overriding-terminal-local-map` is
      ;; searched first, not instead - and the menu ignores whatever
      ;; command that is.
      ;;
      ;; The C binds `echo-keystrokes` to zero around the read so that
      ;; typing a chord is not echoed while a menu is up. Nothing here
      ;; echoes a partial chord: the prefix description is a timer armed
      ;; by `simple.sld`'s `request-prefix-echo!`, which only the command
      ;; loop's dispatch calls.
      ;;
      ;; Answers `#t` when the sequence named nothing - the C's `i == 0 ||
      ;; i == -1` - which is what makes an unbound *prefix* pop the menu
      ;; down.
      ;;--------------------------------------------------------------
      (let loop ((state (new-modal-lookup-state (lookup-keymaps))))
        ;; **A pending quit is the quit *key*, as `read_char` makes it**
        ;; (`keyboard.c:2806`): "if quit is requested, return the quit
        ;; character". Emacs's `read_menu_command` then looks that key up
        ;; in the navigation map, where C-g is bound to `tty-menu-exit`.
        ;; Raising the quit here instead would make C-g a stack unwind
        ;; rather than a menu command, and `tty_menu_activate` could not
        ;; decide what a cancelled menu means - which for a menu-bar
        ;; position is "pop down and say nothing" (`MENU_FOR_CLICK`).
        ;;
        ;; `*inhibit-quit*` is what keeps `read-key-event`'s own
        ;; `maybe-quit` from raising it first; the flag is cleared here,
        ;; by hand, exactly as `read_char` clears it.
        (let ((event (if (*quit-flag*)
                         (begin (*quit-flag* #f) quit-char)
                         (parameterize ((*inhibit-quit* #t))
                           (read-key-event 100)))))
          ;; **`read_char` clears `Vquit_flag` when it answers the quit
          ;; character** (`keyboard.c:2806`), and this is that half: the
          ;; flag is what the terminal's read left set, and a menu that
          ;; consumes the C-g as `tty-menu-exit` must not leave it to
          ;; fire at the next command as a quit nobody asked for.
          (when (and (*quit-flag*) (eqv? event quit-char))
            (*quit-flag* #f))
          (if (not event)
              ;; A read that produced nothing: the deadline, which exists
              ;; here because a *quit* arrives as a signal and this
              ;; terminal's `select` is restarted across it. GNU Emacs's
              ;; `pselect` returns EINTR and `read_key_sequence` quits;
              ;; the flag is looked at by `maybe-quit` at the top of the
              ;; next read, and a real end of input spins here with the
              ;; command loop's own behaviour.
              (loop state)
              (let ((answer 'more))
                (modal-lookup-state-step!
                 state event
                 (lambda (full-path action) (set! answer action))
                 (lambda (full-path map) (set! answer 'more))
                 (lambda (full-path) (set! answer #t)))
                (if (eq? answer 'more)
                    (loop state)
                    answer))))))

    (define (sit-for seconds nodisp)
      ;; GNU Emacs's `sit-for' (`subr.el:3836'): "Redisplay, then wait
      ;; for SECONDS seconds; stop when input is available. ... Value is
      ;; t if waited the full time with no input arriving, and nil
      ;; otherwise."
      ;;
      ;; **Here and not in `subr.sld', where Emacs's is.** Waiting for
      ;; input is `read-key-event' and redisplaying is
      ;; `redisplay-frames!', and both of those are this library's;
      ;; `subr.sld' is a leaf beneath them and can reach neither.
      ;;
      ;; A key that arrives inside the wait is put back on
      ;; `*unread-command-events*', which is Emacs's own move - it does
      ;; `(push (cons t read) unread-command-events)' so that the key is
      ;; both not lost and not recorded in the *current* command's
      ;; `this-command-keys'. There is no `this-command-keys' recording
      ;; here for the cons to be about, so the key goes back as itself,
      ;; which is the shape every other push-back in this tree has.
      ;;
      ;; Not carried: `input-pending-p' (`keyboard.c'), so a key that is
      ;; already waiting is *read* rather than tested for. The answer is
      ;; the same and the read returns at once; what differs is that the
      ;; redisplay happens, where Emacs skips it in that case. Also not
      ;; carried: `sleep-for', which is what Emacs's version uses on a
      ;; noninteractive frame - there is no `noninteractive' here, and
      ;; this editor always has a display to wait on.
      ;;--------------------------------------------------------------
      (when (not nodisp)
        (redisplay-frames!))
      (if (<= seconds 0)
          #t
          (let ((key (read-key-event
                      (inexact->exact (round (* seconds 1000))))))
            (if key
                (begin
                  (*unread-command-events*
                   (cons key (*unread-command-events*)))
                  #f)
                #t))))

    (define (set-transient-map map keep-pred on-exit)
      ;; GNU Emacs's `set-transient-map' (`subr.el:7006'): "Set MAP as a
      ;; temporary keymap taking precedence over other keymaps.
      ;; Normally, MAP is used only once, to look up the very next key.
      ;; However, if the optional argument KEEP-PRED is t, MAP stays
      ;; active if a key from MAP is used. ... Optional arg ON-EXIT, if
      ;; non-nil, specifies a function that is called, with no arguments,
      ;; after MAP is deactivated."
      ;;
      ;; Three parts, and they are Emacs's:
      ;;
      ;;   * the map goes on **`overriding-terminal-local-map'**, where
      ;;     the key lookup finds it before every other map;
      ;;   * a *clearfun* goes on **`pre-command-hook'**, which runs
      ;;     before every command and asks whether the map should survive
      ;;     the command about to run;
      ;;   * and what it asks is whether "the command about to run is the
      ;;     one this map binds at the key that selected it" - Emacs's
      ;;
      ;;         (let ((mc (lookup-key map (this-command-keys-vector))))
      ;;           (and mc (eq this-command mc)))
      ;;
      ;; **That is the whole of "a transient map is used until a command
      ;; that is not its own runs"**, and it is why a caller like
      ;; `mouse-drag-track' needs no read loop of its own: the command
      ;; loop reads every key as it always does, the map answers for the
      ;; ones it binds, and the first command it does not bind - the
      ;; button coming up, a self-insert, anything - pops it and runs
      ;; ON-EXIT. Emacs chases the binding through
      ;; `command-remapping' as well; nothing here remaps commands.
      ;;
      ;; Emacs also removes the clearfun with `remove-hook' and installs
      ;; it with `add-hook'; the hook here is a parameter holding a list
      ;; of procedures, which is this tree's shape for a hook, and the
      ;; two lines below are what `add-hook' would do to it.
      ;;
      ;; NOT CARRIED: MESSAGE and TIMEOUT. A prompt for a transient map
      ;; and an idle-timeout that deactivates one are both more
      ;; machinery than anything here asks for - the drag passes neither -
      ;; and the timeout needs a timer per map.
      ;;--------------------------------------------------------------
      (internal-push-keymap map)
      (let ((exitfun #f))
        (let ((clearfun
               (lambda ()
                 ;; **`cond' true means KEEP, and `exitfun' is what
                 ;; happens when it is false** - Emacs's
                 ;; `(if (cond ...) t (funcall exitfun))', whose `t' is
                 ;; the whole of "and do nothing".
                 (if (cond
                      ((not keep-pred)
                         ;; a one-shot map: the next command ends it
                         #f)
                      ((and (not (eq? map
                                      (car (or *overriding-terminal-local-map*
                                               '()))))
                            (memq map (or *overriding-terminal-local-map*
                                          '())))
                       ;; some *other* transient map is on top of this
                       ;; one, so wait for that one to finish first -
                       ;; Emacs's own nesting rule: the lifetime of the
                       ;; outer map is not ended by a command of the
                       ;; inner one
                       #t)
                      ((eq? keep-pred #t)
                       ;; "the command about to run is the one this map
                       ;; binds at the key that selected it"
                       (let ((mc (km:keymap-lookup
                                  map (*this-command-keys*))))
                         (and mc (eq? (*this-command*) mc))))
                      (else (keep-pred)))
                     #t
                     (exitfun)))))
          (set! exitfun
                (lambda ()
                  (internal-pop-keymap map)
                  (*pre-command-hook*
                   (delq clearfun (*pre-command-hook*)))
                  (when on-exit
                    (on-exit))))
          (*pre-command-hook* (cons clearfun (*pre-command-hook*)))
          exitfun)))

    ;;----------------------------------------------------------------
    ;; Timers
    ;;
    ;; `timer_check', which is GNU Emacs's `keyboard.c''s and not
    ;; `timer.el''s: the list of timers is `timer.el''s, but *running* the
    ;; ripe ones and putting the repeating ones back is the command
    ;; loop's, and it runs from `read_char''s wait - here from this loop,
    ;; which is what waits in this editor.
    ;;------------------------------------------------------------------

    (define (timer-check!)
      ;; GNU Emacs's `timer_check': run every timer that is ripe. It
      ;; answers whether any ran rather than, as the C does, the time of
      ;; the next one - because this editor's redisplay is the command
      ;; loop's, so the caller has to be told to draw again when a timer
      ;; changed what should be on the screen. That is what makes a cursor
      ;; blink visible without a keypress.
      ;;
      ;; The lists are walked as *copies*, as Emacs copies them too, so
      ;; that a timer which adds another one (or itself) cannot make this
      ;; loop run for ever on a timer that is ripe the moment it is added.
      ;;--------------------------------------------------------------
      (let ((idle (current-idle-time))
            (ran? #f))
        (let loop ((timers (append (reverse (*timer-list*))
                                   (if idle
                                       (reverse (*timer-idle-list*))
                                       '()))))
          (when (pair? timers)
            (let ((timer (car timers)))
              (if (timer-ripe? timer idle)
                  (begin
                    (set! ran? #t)
                    (cond
                     ;; An idle timer stays on its list but is marked as
                     ;; having run, so it does not run again until the
                     ;; editor has been idle afresh; a one-shot one goes.
                     ((timer-idle? timer)
                      (if (timer-repeat timer)
                          (timer-mark-run! timer)
                          (cancel-timer timer)))
                     (else
                      ;; A repeating timer is taken off and put back at
                      ;; its new time; a one-shot one is simply gone.
                      ;; Either way it is cancelled first, so that a timer
                      ;; whose function cancels it does not end up on the
                      ;; list twice. The next time is measured from when
                      ;; it *should* have run, not from now, which is
                      ;; Emacs's `timer-inc-time' - so a repeating timer
                      ;; does not drift later and later.
                      (cancel-timer timer)
                      (when (timer-repeat timer)
                        (set!timer-due-at
                         timer (+ (timer-due-at timer) (timer-repeat timer)))
                        (*timer-list*
                         (append (*timer-list*) (list timer))))))
                    (apply (timer-function timer) (timer-args timer))))
              (loop (cdr timers)))))
        ;; A repeating timer has been put back at its new time, and a
        ;; one-shot one has gone: either way the front end has to be told
        ;; when to come back.
        (when ran? (timer-reschedule!))
        ran?))

    (define (read-timeout-or message-timeout timer-delay cap)
      ;; The timeout the command loop's read should be given: the one it
      ;; would have had, shortened to the next timer when one is due
      ;; sooner. A negative timeout blocks, so it is "no timeout at all"
      ;; rather than a number to compare.
      ;;
      ;; This is the whole reason a timer can fire at all: a read that
      ;; blocks for ever cannot be woken by a clock, so the loop has to
      ;; ask how long it may sleep. Emacs's `read_char' computes its wait
      ;; from `timer_check' the same way.
      ;;--------------------------------------------------------------
      (let ((timer-ms (and timer-delay
                           (inexact->exact
                            (max 0 (ceiling (* 1000 timer-delay)))))))
        (let ((want (cond ((not timer-ms) message-timeout)
                          ((< message-timeout 0) timer-ms)
                          (else (min message-timeout timer-ms)))))
          ;; a cap applies to a negative (blocking) timeout too: that is
          ;; the case it exists for
          (cond ((not cap) want)
                ((< want 0) cap)
                (else (min want cap))))))

    (define (read-wait-ms)
      ;; How long an interactive read may block for, in milliseconds, or a
      ;; negative number for "until an event arrives".
      ;;
      ;; It is the command loop's own computation, published because a
      ;; command that reads its *own* keys has to wait the same way and
      ;; must not drift from it. `isearch' is that command.
      ;;
      ;; The cap is for a front end that cannot be *woken*: a read that
      ;; blocks for ever gives nothing else in the process a turn, and on
      ;; a terminal the read blocks in `getch' with nothing to poll, so
      ;; the development REPL would never answer between keys. A front
      ;; end that can be woken - Gtk, through `REPL-WAKE' - sets that
      ;; parameter and gets no cap at all, so its read blocks properly.
      ;;--------------------------------------------------------------
      (read-timeout-or -1 #f (and (repl-running?) (not (repl-wake)) 100)))

    (define *mouse-keys*
      ;; The mouse events this front end makes - what `dispatch-key' asks
      ;; before handing an event to a command. An event not in it is
      ;; replaced by `(KEY (FRAME))', which is the shape a *frame* event
      ;; has, and a mouse event whose value has been thrown away like that
      ;; reaches `mouse-set-region' as nothing to drag over.
      ;;
      ;; **The list itself is `dispnew.sld''s**, because the display needs
      ;; it too - to tell an event it made from a key it must decode - and
      ;; the two copies did not stay equal: `drag-mouse-1' was in this one
      ;; and not in that one, so the release decoded to nothing at all.
      ;; The name is kept here, where every reader already knows it.
      ;;--------------------------------------------------------------
      *mouse-event-keys*)

    (define *last-read-event*
      ;; The display's *own* event value for the last key read, or #f.
      ;;
      ;; **A key path element cannot carry a position.** A mouse event in
      ;; GNU Emacs is a list - `(down-mouse-1 (WINDOW POS (X . Y)
      ;; TIMESTAMP))' - and the command bound to it receives the whole
      ;; thing through `(interactive "e")'. This tree's reader answers the
      ;; *key* (`key-event->key'), which is what a keymap is looked up
      ;; by, so the value it came from is kept here and `dispatch-key-
      ;; event' hands it on when the key is a mouse key. Without it a
      ;; click would reach the command as `(down-mouse-1 (FRAME))' - the
      ;; shape Emacs uses for a *frame* event, which is right for
      ;; `focus-in' and wrong for a click - and `posn-set-point' would
      ;; refuse it with "Position not in text area of window".
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *dispatch-event* (make-parameter #f))
    ;; ^ How a front end that owns its own loop hands an event to the
    ;; command loop, or #f when it has no loop of its own and the loop
    ;; waits in a read instead.
    ;;
    ;; **This is what makes the loop the front end's.** A terminal cannot
    ;; set it: ncurses has no callback, its keys can only be got by a
    ;; blocking `getch', and so its loop must wait in the read. Gtk can:
    ;; its signal handlers call this, so the loop *absorbing input* is
    ;; `gtk_main` itself - which is the whole point, because a widget
    ;; added to a frame (a menu, a popup, a drag) only receives its
    ;; events if the loop dispatching them is the one Gtk expects.
    ;;
    ;; It is set for the **outermost** loop only. A nested one - the
    ;; minibuffer's, an isearch's - is entered from inside a command and
    ;; has to wait for a key of its own, so it reads, and reads nest
    ;; inside Gtk's loop. That is the reentrancy Chris described: "run a
    ;; reentrant gtk loop so you're still waiting in a gtk loop, just not
    ;; the main loop".
    ;;
    ;; A parameter is safe here in a way `REPL-WAKE' was not: this is
    ;; read and written on the one thread - Gtk's callbacks are the main
    ;; thread - and the `parameterize' that sets it encloses the loop
    ;; that runs the callbacks. See `(scheme-utils repl server)` on what
    ;; happens when that is not true.

    (define (command-loop-idle! frame)
      ;; The housekeeping that belongs to the moment the editor settles
      ;; down to wait for input: give the development REPL its turn, arm
      ;; the cursor blink, and mark the editor idle so that an idle timer
      ;; counts from here.
      ;;
      ;; It is its own function because the two shapes of the loop need
      ;; it at *different points*. A loop that waits itself calls it just
      ;; before its read; a front end that owns the loop calls it after
      ;; it has finished with a key and is handing control back. See
      ;; `COMMAND-LOOP-KEY!` for the other half.
      ;;--------------------------------------------------------------
      (poll-repl!)
      ;; Arm the mode that blinks the cursor, if the frame can and it is
      ;; not armed already. Emacs does this from its focus-change hook;
      ;; there is no such hook here, and this loop is the thing that
      ;; always runs.
      (blink-cursor-check)
      ;; The editor is about to wait, which is what "idle" means.
      (timer-idle-start!))

    (define (command-loop-timers!)
      ;; A timer that was due has now run. Redraw when one did, which is
      ;; what makes a cursor blink visible without a keypress: Emacs's
      ;; `internal-show-cursor' asks for a redisplay and this is where
      ;; that lands here.
      ;;--------------------------------------------------------------
      (when (timer-check!) (redisplay-frames!)))

    (define %dispatching #f)
    ;; ^ Whether a command is running right now, so that a front end can
    ;; tell "hand this event over" from "a command is already running, put
    ;; it on the queue". A plain variable rather than a parameter for the
    ;; reason the shared module's wake is: it is read from a callback, and
    ;; a fluid's value is captured per thread when the thread is made.

    (define (command-loop-ready?)
      ;; Whether the command loop can take an event right now.
      ;;--------------------------------------------------------------
      (not %dispatching))

    (define (command-loop-key! frame ev)
      ;; Everything the command loop does with one event *except* read
      ;; it: stop the idle clock, run any timer that came due, dispatch
      ;; the event, and redraw.
      ;;
      ;; A front end that owns its loop calls this straight from its own
      ;; signal handler, through `*DISPATCH-EVENT*`. Everything the key
      ;; needs is here or on the frame - `dispatch-key` keeps the chord
      ;; state in `frame-keymap-state` and `dispatch-action` does
      ;; `this-command`, the undo boundary, `pre-command-hook`,
      ;; `last-command` and the region bookkeeping - so nothing is lost
      ;; by the loop not being on the stack.
      ;;--------------------------------------------------------------
      (timer-idle-stop!)
      (command-loop-timers!)
      (set! %dispatching #t)
      ;; `dynamic-wind`, because a quit or an error escaping from the
      ;; command must not leave the editor believing a command is still
      ;; running - it would then never accept another key.
      (dynamic-wind
       (lambda () #t)
       (lambda () (dispatch-key frame ev))
       (lambda () (set! %dispatching #f)))
      (redisplay-frames!))

    (define (command-loop frame . args)
      ;; Read key events and dispatch them, until something leaves this
      ;; level with `exit-recursive-edit' - or, at the outermost level,
      ;; until the editor is quit.
      ;;
      ;; The read is given a timeout while a message that times out is
      ;; on the screen, and none otherwise. That is this editor's stand
      ;; in for the timer GNU Emacs arms in `minibuffer-message': with
      ;; no timeout the read would block in `getch' and the message
      ;; would stay up until the user typed, which is how "No match"
      ;; used to sit in the echo area for as long as you looked at it.
      ;; The timeout costs nothing while nothing is pending, which is
      ;; why it is armed and disarmed rather than always on - and it is
      ;; why end of input is still noticed at once.
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (exit)
         (parameterize ((*recursive-edit-exit* exit))
           ;; draw before the first key is read: a prompt that appears only
           ;; after a key is typed looks like nothing happened
           (redisplay-frames!)
           (let loop ()
             ;; **Re-read the selected frame each time round, if this is
             ;; the outermost loop.** Selecting another frame - `C-x 5 o',
             ;; or a click in another window once there is one - has to
             ;; take effect on the *next* command, and Emacs's loop reads
             ;; `selected_frame' every iteration the same way. The frame
             ;; this loop was *called* with is what a nested loop keeps:
             ;; `recursive-edit' passes no flag, so a prompt stays on the
             ;; frame it was asked from. That pinning is a deliberate
             ;; departure - Emacs gives every frame its own minibuffer, and
             ;; this tree has a single `*minibuffer*' parameter
             ;; (`frame.sld'), so following focus mid-prompt would move the
             ;; prompt's state to another frame.
             (when (and (pair? args) (car args))
               (set! frame (or (*current-frame*) frame)))
             ;; The half of the loop that belongs to *waiting*: give the
             ;; development REPL a turn, arm the cursor blink, and mark
             ;; the editor idle. A front end that owns its loop calls the
             ;; same function after it has finished with a key, which is
             ;; why it is a function - see `command-loop-idle!`.
             (command-loop-idle! frame)
             ;; **The read is inside the error guard too, as it is in
             ;; Emacs.** `command_loop_1`'s `condition-case` wraps the
             ;; whole iteration, `read_key_sequence` included; this loop
             ;; guarded only the command, so a quit raised by the read's
             ;; own `maybe-quit` - a C-g that arrived between one command
             ;; and the next read - escaped and exited the editor
             ;; (measured: SIGINT, then the process gone with a
             ;; `%quit-condition' throw). The handler reports it and the
             ;; loop goes on reading, which is what `cmd_error` does.
             (guard (ex (else (report-command-error! frame ex)))
             (let ((want (read-timeout-or
                          ;; **Nothing to wait for but a key.** The
                          ;; echo area's two clock-driven habits - a
                          ;; message that times out, and the prefix
                          ;; description owed once `echo-keystrokes' has
                          ;; passed - used to be a timeout on this read,
                          ;; which is what made an idle editor wake up
                          ;; ten times a second. Each is a timer now
                          ;; and `timer-next-delay' already shortens the
                          ;; read to the next one, so this read blocks
                          ;; until a key arrives.
                          -1
                          (timer-next-delay)
                          ;; **A wait is shortened for the development
                          ;; REPL only when this front end cannot be
                          ;; woken by it.** A front end that can sets
                          ;; `REPL-WAKE' and needs no cap at all; one
                          ;; that cannot - a terminal, whose read blocks
                          ;; in `getch' with nothing to hang a poll on -
                          ;; keeps the cap. See `REPL-WAKE'.
                          (and (repl-running?) (not (repl-wake)) 100))))
             (let ((ev (read-key-event want)))
               (cond
                ((key-event? ev)
                 ;; The half of the loop that belongs to *a key arriving*:
                 ;; stop the idle clock, run any timer that came due,
                 ;; dispatch, and redraw. The same function a front end
                 ;; that owns its loop calls from its own signal handler.
                 (command-loop-key! frame ev))
                ;; Nothing to read on a *blocking* read is the end of
                ;; input - the read answers #f for that too - so leave
                ;; the editor. "Blocking" is the test, and it has to be
                ;; the test rather than "no message is pending": a read
                ;; is also armed when a *timer* is due, and a timer that
                ;; is due must not read as the end of the input.
                ((< want 0)
                 (let ((quit (frame-quit-cont frame)))
                   (when quit (quit 'eof))))
                ;; A timed-out read: a timer was due, which is the only
                ;; reason this read was armed at all. Run it and redraw.
                (else (command-loop-timers!))))))
             (loop))))))

    (define (recursive-edit frame)
      ;; Enter a nested command loop and return what leaving it produced:
      ;; either the value `exit-recursive-edit' was given, or a thunk
      ;; that signals quit (which the caller runs, so that the signal is
      ;; raised outside this edit - see the note above). The caller is
      ;; expected to have bound `*current-keymap*' and `*minibuffer*'.
      ;;
      ;; A key chord cannot be half-entered when a recursive edit begins
      ;; (the command's own key finished the chord), but the pending
      ;; lookup state is saved and restored all the same, so that a
      ;; nested loop cannot inherit or clobber the outer one's.
      ;;--------------------------------------------------------------
      (let ((outer-state (frame-keymap-state frame)))
        (set!frame-keymap-state frame #f)
        (let ((result (command-loop frame)))
          (set!frame-keymap-state frame outer-state)
          result)))

    (define exit-recursive-edit
      ;; Leave the innermost recursive edit with a value. GNU Emacs's
      ;; `exit-recursive-edit'.
      ;;--------------------------------------------------------------
      (case-lambda
       (() (exit-recursive-edit #f))
       ((value)
        (let ((exit (*recursive-edit-exit*)))
          (if exit
              (exit value)
              (error "Not in a recursive edit"))))))

    ;;----------------------------------------------------------------
    ;; Quoted insertion
    ;;
    ;; GNU Emacs's `quoted-insert' (C-q) and the `read-quoted-char' it
    ;; reads with are simple.el's, but they are here and not there for
    ;; the import graph's sake: they read a KEY, and reading a key is
    ;; `read-key-event''s, which simple.sld cannot import - this
    ;; library imports simple, not the other way around. It is the
    ;; same wall `abort-recursive-edit' is the other side of.
    ;;------------------------------------------------------------------

    (define *read-quoted-char-radix*
      ;; GNU Emacs's `read-quoted-char-radix' (simple.el): "Radix for
      ;; `quoted-insert' and other uses of `read-quoted-char'.
      ;; Supported radix values are 8, 10 and 16."
      ;;--------------------------------------------------------------
      (make-parameter 8))

    (define (read-quoted-char . args)
      ;; GNU Emacs's `read-quoted-char' (simple.el:986): "Like
      ;; `read-char', but do not allow quitting. Also, if the first
      ;; character read is an octal digit, we read any number of octal
      ;; digits and return the specified character code. Any nondigit
      ;; terminates the sequence. If the terminator is RET, it is
      ;; discarded; any other terminator is used itself as input."
      ;; The optional PROMPT is what the echo area shows with a `-'
      ;; after it. Quitting is inhibited for the FIRST character only -
      ;; which is why C-q C-g inserts a ^G - and a C-g later in the
      ;; digits quits, as the C's `inhibit-quit' binding says.
      ;;--------------------------------------------------------------
      (let* ((prompt (if (pair? args) (car args) #f))
             (frame (*current-frame*))
             (radix (*read-quoted-char-radix*))
             (done #f)
             (first #t)
             (code 0))
        ;; **The prompt is a *message*, which is what Emacs's
        ;; `(read-event (and prompt (format "%s-" prompt)))` makes of it**
        ;; - `read_char` echoes a read's prompt into the echo area - and
        ;; so is the running record of the digits typed, `(setq prompt
        ;; (message "%s %c" prompt translated))`. It used to be a
        ;; synthetic echo area (`*echo-area-buffer*` and
        ;; `*echo-area-prompt*`) painted by the renderer; the echo area
        ;; is a window drawing the frame's own echo buffer now, so both
        ;; are messages.
        ;;
        ;; `message-log-max` is bound to nil in the C's `let`, so these
        ;; are `set!frame-message` (display only) and not `message`.
        (set!frame-message frame (if prompt (string-append prompt "-") ""))
        (render! frame)
        (let loop ()
            (if done
                code
                ;; The key is the *event*, and the C is a character
                ;; reader: `read-char' answers the character the event
                ;; is, which for every key this asks about - a digit, a
                ;; `C-g', RET - is the event itself. `event-convert-list'
                ;; names the event of a description and is the C's own, so
                ;; the tests below spell the keys the way Emacs's
                ;; `(eq char ?\C-g)' does.
                (let* ((key (read-key-event -1))
                       (code-read (and (integer? key) key)))
                  (cond
                   ;; a C-g after the first character quits, as the
                   ;; C's quitting is enabled once `first' is past
                   ((and (not first)
                         (eqv? key (event-convert-list '(control #\g))))
                    (signal-quit))
                   ;; a digit of the radix: accumulate, and echo the
                   ;; digit after the prompt
                   ((and code-read
                         (or (char-numeric? (integer->char code-read))
                             (and (= 16 radix)
                                  (char<=? #\a (integer->char code-read) #\f))
                             (and (<= 10 radix)
                                  (char<=? #\a (integer->char code-read)
                                           (integer->char (+ 87 (- radix 10)))))))
                    ;; ^ Elisp's second branch is the letters a-F up
                    ;; to the radix, for 16: `(and (<= ?a (downcase
                    ;; translated)) (< (downcase translated) (+ ?a
                    ;; -10 (min 36 read-quoted-char-radix))))'
                    (set! code (+ (* code radix)
                                  (- code-read (char->integer #\0))))
                    (set! first #f)
                    ;; `(and prompt (setq prompt (message "%s %c" prompt
                    ;; translated)))` - the digits typed so far.
                    (when prompt
                      (set! prompt
                            (format #f "~a ~a" prompt
                                    (integer->char code-read)))
                      (set!frame-message frame prompt))
                    (loop))
                   ;; RET after the first digit terminates and is
                   ;; discarded; before that it is the character
                   ((and (not first)
                         (eqv? key (event-convert-list '(control #\m))))
                    (set! done #t)
                    (loop))
                   ;; any other terminator after the first digit is
                   ;; used itself as input: pushed back for the
                   ;; caller, and its code read
                   ((not first)
                    (*unread-command-events*
                     (cons key (*unread-command-events*)))
                    (set! done #t)
                    (loop))
                   ;; the first character, not a digit: it is the
                   ;; answer - quitting inhibited, so a C-g is code 7
                   ((and code-read)
                    (set! code code-read)
                    (set! done #t)
                    (loop))
                   (else
                    ;; a key that is not a character at all (an
                    ;; arrow, a frame resize): ask again, as the C's
                    ;; `(cond ((null translated)))' does
                    (loop))))))))

    (define-command (abort-recursive-edit)
      ;; Leave the innermost recursive edit and signal quit, so the
      ;; command that asked the question is abandoned: GNU Emacs's
      ;; `abort-recursive-edit', which is keyboard.c's own - a function
      ;; any Lisp can call, and a command at the same time, which is
      ;; why the minibuffer map can bind it directly. It is
      ;; `exit-recursive-edit' with a thunk whose call signals, exactly
      ;; as Emacs's `minibuffer-quit-recursive-edit' does.
      "Quit the innermost recursive edit and the command that asked the question."
      (interactive)
      (exit-recursive-edit signal-quit))

    (define-command (quoted-insert arg)
      ;; GNU Emacs's `quoted-insert' (simple.el:1047): "Read next input
      ;; character and insert it. This is useful for inserting control
      ;; characters. With argument, insert ARG copies of the
      ;; character." The `*' of its interactive spec is the read-only
      ;; check, and it is made first.
      ;;
      ;; "In overwrite mode, this function inserts the character anyway,
      ;; and does not handle octal (or decimal or hex) digits specially.
      ;; This means that if you use overwrite mode as your normal editing
      ;; mode, you can use this function to insert characters when
      ;; necessary" (`simple.el:1068') - so in *textual* overwrite mode
      ;; the character is read plainly rather than through
      ;; `read-quoted-char'; binary mode keeps the octal reader, its own
      ;; docstring calling that "useful for editing binary files".
      ;;
      ;; Not ported: the `user-error' for a non-character event, which
      ;; needs `key-description' and a message, neither of which this
      ;; library has.
      "Read next input character and insert it.
This is useful for inserting control characters.
With argument, insert ARG copies of the character."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (barf-if-buffer-read-only)
      (let* ((mode (buffer-overwrite-mode (current-buffer)))
             (code (if (eq? mode 'overwrite-mode-textual)
                       ;; "a character reader": `read-char' answers the
                       ;; character the event is, and for every key this
                       ;; asks about the event *is* the code
                       (let ((key (read-key-event -1)))
                         (and (integer? key) key))
                       (read-quoted-char)))
             (char (and code (integer->char code))))
        (when char
          ;; "In binary overwrite mode, this function does overwrite"
          ;; (`simple.el:1097'): the characters being replaced are
          ;; deleted first, and the insert below is an ordinary one -
          ;; so `C-q' replaces ARG characters in binary overwrite mode
          ;; where in textual mode it goes through
          ;; `internal-self-insert' per character instead.
          (when (and (> arg 0) (eq? mode 'overwrite-mode-binary))
            (delete-char arg))
          (let loop ((left arg))
            (when (> left 0)
              (insert char)
              (loop (- left 1)))))
        #f))

    (define (event-loop frame)
      ;; The outermost command loop, as a *loop*: it runs until the editor
      ;; is quit.
      ;;
      ;; This is the terminal's, and it is the terminal's because ncurses
      ;; has no callback: there is nothing to push an event into, its keys
      ;; can only be got by a blocking `getch', and so the loop has to
      ;; wait in the read. A front end that *does* own an event loop uses
      ;; `EVENT-LOOP-ON` instead, where there is no loop at all and Gtk's
      ;; own loop is the one absorbing input.
      ;;--------------------------------------------------------------
      (parameterize ((*current-frame* frame)
                     ;; **`#f`, not the global map.** The parameter's
                     ;; false value already means "no mode map, use
                     ;; `global-map'", and naming it explicitly listed
                     ;; the map a second time - which `lookup-keymaps`
                     ;; dutifully returned twice, harmless for a key
                     ;; lookup and visible in the menu bar, where each
                     ;; item was contributed twice.
                     (*current-keymap* #f))
        (redisplay-frames!)
        (call/cc
         (lambda (k)
           (set!frame-quit-cont frame k)
           ;; #t: the outermost loop follows the selected frame, which is
           ;; what makes `C-x 5 o' take effect (`recursive-edit' does not).
           (command-loop frame #t)))))

    (define (event-loop-on frame run-loop quit-loop)
      ;; The outermost command loop for a front end that owns its own
      ;; loop: set up, hand control to RUN-LOOP, and let QUIT-LOOP leave
      ;; it.
      ;;
      ;; **There is no loop here, and that is the point.** The editor's
      ;; outermost level holds no state of its own - the chord is
      ;; `frame-keymap-state` on the frame, the prefix argument and
      ;; `this-command` are globals, idleness is the timer module's - so
      ;; it does not need to be a loop at all; it needs to be something
      ;; an event can be pushed into, which is `command-loop-key!`. That
      ;; is what makes the loop absorbing input the *front end's* own:
      ;; `gtk_main` calls the handler, the handler runs one command and
      ;; returns, and control goes back to `gtk_main` - which is what a
      ;; widget added to a frame (a menu, a popup, a drag) needs, since
      ;; it is `gtk_main` that then gets its events.
      ;;
      ;; RUN-LOOP does not return until the editor is quit, and QUIT-LOOP
      ;; is what `frame-quit-cont` calls. Both are the front end's, so
      ;; that this library never names a display - the same arrangement
      ;; that keeps `dispnew.sld` free of both.
      ;;
      ;; A *nested* loop - a prompt, an isearch - is still
      ;; `COMMAND-LOOP`'s, and still blocks: it is entered from inside a
      ;; command and has to wait for a key of its own. See
      ;; `*DISPATCH-EVENT*`.
      ;;--------------------------------------------------------------
      (parameterize ((*current-frame* frame)
                     (*current-keymap* #f)
                     (*dispatch-event*
                      (lambda (ev)
                        ;; The selected frame is read each time, as
                        ;; `command_loop_1' reads `selected_frame' every
                        ;; iteration: `C-x 5 o' has to take effect on the
                        ;; next command.
                        (command-loop-key! (or (*current-frame*) frame) ev)
                        ;; Control is about to go back to the front end's
                        ;; loop, which is what "waiting for input" now
                        ;; means.
                        (command-loop-idle! (or (*current-frame*) frame)))))
        (set!frame-quit-cont frame (lambda (value) (quit-loop)))
        ;; draw before the first event: a file's text, or a prompt, that
        ;; appeared only after a key was typed looks like nothing happened
        (redisplay-frames!)
        ;; The editor starts out waiting for input.
        (command-loop-idle! frame)
        (run-loop)))

    ;;--------------------------------------------------------------
    ;; The menu bar - `keyboard.c`'s `menu_bar_items', its parser and the
    ;; `menu-item' properties it fills in.
    ;;
    ;; The bar is not a table anywhere: it is the `[menu-bar]' binding of
    ;; every ACTIVE keymap, walked in precedence order and parsed into
    ;; `(KEY NAME DEFS UNUSED)' quads - the C's four-slot entries. What
    ;; is not here yet is the widget side and `parse_menu_item`'s
    ;; key-equivalent computation (see its note).
    ;;--------------------------------------------------------------

    (define *enable-disabled-menus-and-buttons* #f)
    ;; ^ `(defvar enable-disabled-menus-and-buttons nil)'
    ;; (`keyboard.c:14342'): "If non-nil, then the menus and buttons of
    ;; type `:enable' are enabled even when their :enable is nil." A
    ;; plain variable, being `setq'ed.
    ;;
    ;; **The self-assignment is not a typo.** Guile's compiler treats a
    ;; top-level definition that the module never assigns as a
    ;; *constant* and folds the reads, so a `module-set!` from outside -
    ;; a user's `setq`, or a test - is invisible: measured, a compiled
    ;; `keyboard.scm` answered #f here after `module-set!` had set it to
    ;; #t, and the menu tests failed only when the cache held a compiled
    ;; copy. Assigning it in the file marks it mutable.
    (set! *enable-disabled-menus-and-buttons* *enable-disabled-menus-and-buttons*)

    (define *menu-bar-final-items* '())
    ;; the same self-assignment, for the same reason
    (set! *menu-bar-final-items* *menu-bar-final-items*)
    ;; ^ `(defvar menu-bar-final-items nil)' (`keyboard.c:14110'): "List
    ;; of menu bar items to move to the end of the menu bar." `menu-bar.el'
    ;; sets it to `(help-menu)'. A plain variable.

    (define *overriding-local-map-menu-flag* #f)
    ;; ^ `(defvar overriding-local-map-menu-flag nil)'
    ;; (`keyboard.c:14147'): "Non-nil means `overriding-local-map'
    ;; applies to the menu bar. Otherwise, the menu bar continues to
    ;; reflect the buffer's local map and the minor mode maps regardless
    ;; of `overriding-local-map'." **Nil is the C's default**, so an
    ;; overriding map puts no items in the bar unless it is set.
    ;;
    ;; The self-assignment is `*enable-disabled-menus-and-buttons*`'s
    ;; reason: without it Guile folds the reads to the constant, and a
    ;; `setq` from another module is invisible in a compiled build.
    (set! *overriding-local-map-menu-flag* *overriding-local-map-menu-flag*)

    ;; `item_properties''s slots - the C's `enum item_property_idx'.
    (define item-property-item 0)
    (define item-property-name 1)
    (define item-property-def 2)
    (define item-property-map 3)
    (define item-property-type 4)
    (define item-property-keyeq 5)
    (define item-property-selected 6)
    (define item-property-help 7)
    (define item-property-enable 8)
    (define *item-properties* (make-vector 9 #f))

    (define (menu-item-eval-property sexpr)
      ;; GNU Emacs's `menu_item_eval_property' (`keyboard.c:8843'):
      ;; "Evaluate an expression and return the result (or nil if
      ;; something went wrong). Used to evaluate dynamic parts of menu
      ;; items."
      ;;
      ;; Emacs binds `inhibit-redisplay' around it and catches `quit'
      ;; specially; there is no redisplay to inhibit here and no quit
      ;; signal, so this is the `condition-case' half only. The form is
      ;; evaluated in the CURRENT MODULE - the environment the caller's
      ;; own code lives in; Emacs evaluates in the global environment.
      ;;--------------------------------------------------------------
      (guard (e (else #f))
        (eval sexpr (current-module))))

    ;;----------------------------------------------------------------
    ;; `where-is-internal' - `keymap.c:2496' (`where_is_internal'), its
    ;; walker (`:2787'), and the DEFUN (`:2588')
    ;;----------------------------------------------------------------
    ;;
    ;; `parse_menu_item`'s last step asks `(where-is-internal DEF nil t
    ;; nil nil)` for the key sequence that runs DEF, and renders it into
    ;; ITEM_PROPERTY_KEYEQ - which is the "C-x C-s" a menu shows to the
    ;; right of "Save". Without it a menu is a list of names with no keys
    ;; at all.
    ;;
    ;; **All of it is `keymap.c`'s, and it lives here.** The DEFUN's
    ;; default for its KEYMAP argument is `current-active-maps`, which is
    ;; `keyboard.c`'s; in this tree that is `lookup-keymaps` below, and
    ;; `keymap.sld` sits under this library. Emacs reaches both across
    ;; the same boundary through its one obarray.
    ;;
    ;; Not carried, each named where it would go: command remapping
    ;; (`Fcommand_remapping`, `[remap ...]` - so `remapped` is always
    ;; false and that arm never runs), `:advertised-binding`, and
    ;; `where_is_cache` (it exists for the menu bar's many calls per
    ;; redisplay; this tree rebuilds a menu only when its `menu_items`
    ;; change).
    ;;--------------------------------------------------------------

    (define *where-is-preferred-modifier* #f)
    ;; ^ `where_is_preferred_modifier` (`keymap.c:2364`), the parsed
    ;; `where-is-preferred-modifier` variable: a `firstonly` answer
    ;; prefers a sequence whose only modifier is this one. nil is Emacs's
    ;; default and means 0, the C's "no modifier at all".

    (define (preferred-sequence-p sequence)
      ;; `preferred_sequence_p` (`keymap.c:2371`): "Return 0 if SEQ uses
      ;; non-preferred modifiers or non-char events. Else, return 2 if SEQ
      ;; uses the where_is_preferred_modifier, and 1 otherwise."
      ;;
      ;; The mask excludes META, so `M-x` counts as unmodified here - the
      ;; meta bit is part of the character rather than a modifier state
      ;; as far as this test is concerned.
      ;;--------------------------------------------------------------
      (let ((mask (logior char-alt char-super char-hyper char-shift char-ctl))
            (preferred (or *where-is-preferred-modifier* 0))
            (events (cond ((vector? sequence) (vector->list sequence))
                          ((pair? sequence) sequence)
                          (else '()))))
        (let loop ((rest events) (result 1))
          (cond
           ((null? rest) result)
           ((not (integer? (car rest))) 0)
           (else
            (let ((modifiers (logand (car rest) mask)))
              (cond ((= modifiers preferred) (loop (cdr rest) 2))
                    ((not (= modifiers 0)) 0)
                    (else (loop (cdr rest) result)))))))))

    (define %mouse-events
      ;; `Vmouse_events` (`keymap.c:3421`): the event types whose keymaps
      ;; a `firstonly` search will not look inside - "If no menu entries
      ;; should be returned, skip over the keymaps bound to `menu-bar'
      ;; and `tool-bar' and other non-ascii prefixes like
      ;; `C-down-mouse-2'."
      ;;--------------------------------------------------------------
      '(menu-bar tab-bar tool-bar tab-line header-line mode-line
                 mouse-1 mouse-2 mouse-3 mouse-4 mouse-5))

    (define (where-is-internal-1 definition key binding this last last-is-meta
                                 noindirect)
      ;; GNU Emacs's `where_is_internal_1` (`keymap.c:2787`): the sequence
      ;; that reaches BINDING through THIS with KEY on the end, or #f when
      ;; BINDING is not DEFINITION. The C pushes onto a list; this
      ;; answers, and the caller conses.
      ;;--------------------------------------------------------------
      (let ((binding (if noindirect binding (km:get-keyelt binding #f))))
        ;; `and`, not `when`: a `when` whose test fails answers the
        ;; unspecified value, which is *true* in Scheme - and the caller
        ;; reads the answer as "found". It was cosmetic here for one
        ;; round because `(when sequence ...)' swallows it, but the value
        ;; ends up in the sequence list the moment it is not.
        (and (or (eq? binding definition)
                 (and (pair? definition) (equal? binding definition)))
             (if (and (integer? key) last-is-meta)
                 (let ((sequence (vector-copy this)))
                   (vector-set! sequence last (logior key char-meta))
                   sequence)
                 (km:append-key this key)))))

    (define (where-is-internal-walk definition keymaps noindirect nomenus)
      ;; GNU Emacs's static `where_is_internal` (`keymap.c:2496`): every
      ;; sequence that reaches DEFINITION, in `accessible-keymaps`' order.
      ;;--------------------------------------------------------------
      (let ((sequences '()))
        (for-each
         (lambda (map)
           (for-each
            (lambda (entry)
              (let* ((this (car entry))
                     (thismap (cdr entry))
                     (events (vector->list this))
                     (last (- (length events) 1))
                     (last-is-meta (and (>= last 0)
                                        (eqv? (list-ref events last) 27))))
                (unless (and nomenus
                             (>= last 0)
                             (symbol? (list-ref events 0))
                             ;; **`parse_modifiers`' answer has a
                             ;; different shape here.** The C's is
                             ;; `(BASE-EVENT . MODIFIER-BITS)`, which is
                             ;; what `XCAR (parse_modifiers (tem))` reads;
                             ;; this tree's `parse-modifiers-uncached`
                             ;; answers `(MODIFIER-BITS . NAME-STRING)`,
                             ;; so the base event is the name it gives.
                             (memq (string->symbol
                                    (cdr (parse-modifiers-uncached
                                          (list-ref events 0))))
                                   %mouse-events))
                  (km:map-keymap
                   (lambda (key binding)
                     (let ((sequence (where-is-internal-1
                                      definition key binding this last
                                      last-is-meta noindirect)))
                       (when sequence
                         (set! sequences (cons sequence sequences))))
                     #f)
                   thismap))))
            (km:accessible-keymaps map #f)))
         keymaps)
        (reverse sequences)))

    (define (%shadow-lookup keymaps key)
      ;; `shadow_lookup` (`keymap.c:2464`) with `accept_default` nil and
      ;; `remap` false: the first keymap of KEYMAPS that binds KEY.
      ;;
      ;; The C's `FIXNATP (value)` guard - "`key' is too long!" - has no
      ;; counterpart here: `keymap-lookup` answers the command it found or
      ;; nil, never a count of what it consumed.
      ;;--------------------------------------------------------------
      (let loop ((rest keymaps))
        (and (pair? rest)
             (or (keymap-lookup (car rest) key) (loop (cdr rest))))))

    (define (where-is-internal definition keymap firstonly noindirect no-remap)
      ;; GNU Emacs's `where-is-internal` (`keymap.c:2588`): "Return list
      ;; of keys that invoke DEFINITION. ... If optional 3rd arg
      ;; FIRSTONLY is non-nil, return the first key sequence found."
      ;;--------------------------------------------------------------
      ;; **A symbol on one side, a value on the other.** Elisp's keymaps
      ;; hold the command *symbol*, so the C's `EQ (binding, definition)`
      ;; compares like with like. This tree's keymaps hold the value
      ;; `define-command` made, while a menu item may still name its
      ;; command as the symbol the C would - `(menu-item "Save"
      ;; save-buffer)` - which is what `dispatch-action` exists for.
      ;; `command-value-of` is that same value, so the search is made for
      ;; it. Without this no menu item that names a symbol ever finds its
      ;; key, which is what the first run of this did.
      (let* ((definition (if (symbol? definition)
                             (let ((record (command-record-named definition)))
                               (if record
                                   (command-value-of record)
                                   definition))
                             definition))
             (nomenus (and firstonly (not (eq? firstonly 'non-ascii))))
             (keymaps (cond ((and (pair? keymap) (keymap-type? (car keymap)))
                             keymap)
                            (keymap (list keymap *default-keymap*))
                            (else (lookup-keymaps))))
             (sequences (where-is-internal-walk definition keymaps
                                                (not (not noindirect)) nomenus)))
        (let loop ((rest sequences) (found '()))
          (cond
           ((null? rest)
            ;; "firstonly may have been t, but we may have gone all the
            ;; way through the keymaps without finding an all-ASCII key
            ;; sequence. So just return the best we could find."
            ;; `Fcar` of nil is nil in the C, so an empty answer stays
            ;; #f rather than raising here.
            (let ((found (reverse found))
                  (best (lambda (l) (and (pair? l) (car l)))))
              (cond ((not firstonly) found)
                    ((or (not *where-is-preferred-modifier*)
                         (= *where-is-preferred-modifier* 0))
                     (best found))
                    (else
                     (let scan ((b found))
                       (cond ((null? b) (best found))
                             ((preferred-sequence-p (car b)) (car b))
                             (else (scan (cdr b)))))))))
           (else
            (let ((sequence (car rest)))
              (cond
               ;; "Verify that this key binding is not shadowed by another
               ;; binding for the same key, before we say it exists."
               ((not (equal? (%shadow-lookup keymaps sequence) definition))
                (loop (cdr rest) found))
               (else
                ;; "Don't annoy user with strings from a menu such as the
                ;; entries from the `Edit => Paste from Kill Menu'."
                (let ((n (vector-length sequence)))
                  (when (and (> n 0) (string? (vector-ref sequence (- n 1))))
                    (vector-set! sequence (- n 1) "(any string)")))
                ;; "It is a true unshadowed match. Record it, unless it's
                ;; already been seen (as could happen when inheriting
                ;; keymaps)."
                (when (and (not (member sequence found))
                           (not (and (= (vector-length sequence) 1)
                                     (symbol? (vector-ref sequence 0))
                                     (get (vector-ref sequence 0)
                                          'non-key-event))))
                  (set! found (cons sequence found)))
                (cond
                 ((eq? firstonly 'non-ascii) sequence)
                 ((and firstonly (= 2 (preferred-sequence-p sequence)))
                  sequence)
                 (else (loop (cdr rest) found)))))))))))

    (define (help-echo-substitute-command-keys string)
      ;; `help_echo_substitute_command_keys' (`keyboard.c'): Emacs runs
      ;; `substitute-command-keys' over a menu item's help string. That
      ;; function is not ported - it needs `documentation' and the
      ;; keymap-description machinery - so the string is carried through
      ;; unchanged. Named departure: a `:help' containing `\[command]'
      ;; shows the escape.
      ;;--------------------------------------------------------------
      string)

    (define (parse-menu-item item inmenubar)
      ;; GNU Emacs's `parse_menu_item' (`keyboard.c:8899'): "This
      ;; function parses a menu item and leaves the result in the vector
      ;; `item_properties'. ... INMENUBAR is > 0 when this is considered
      ;; for an entry in a menu bar top level. INMENUBAR is < 0 when this
      ;; is considered for an entry in a keyboard menu."
      ;;
      ;; **The key-equivalent computation is not carried.** After the
      ;; menu-bar arm the C asks `where-is-internal', `key-binding' and
      ;; `substitute-command-keys' to fill ITEM_PROPERTY_KEYEQ; the
      ;; first exists here only in the reduced
      ;; `keymap-lookup-binding-key' form, and the other two not at all.
      ;; It is reached only when INMENUBAR <= 0, so the menu bar itself
      ;; is unaffected; ITEM_PROPERTY_KEYEQ stays nil.
      ;;--------------------------------------------------------------
      (and
       (pair? item)
       (let/ec return
         (let ((item-string (car item))
               (filter #f)
               (keyhint #f)
               (start item))
           ;; Initialize the optional entries; ENABLE starts true.
           (let loop ((i item-property-def))
             (when (<= i item-property-enable)
               (vector-set! *item-properties* i #f)
               (loop (+ i 1))))
           (vector-set! *item-properties* item-property-enable #t)
           (vector-set! *item-properties* item-property-item item)
           (set! item (cdr item))
           (cond
            ((string? item-string)
             ;; Old format: `(STRING [HELP] [KEY-CACHE] . DEF)'.
             (vector-set! *item-properties* item-property-name item-string)
             (when (and (pair? item) (string? (car item)))
               (vector-set! *item-properties* item-property-help
                            (help-echo-substitute-command-keys (car item)))
               (set! start item)
               (set! item (cdr item)))
             ;; Maybe an obsolete key binding cache.
             (when (and (pair? item) (pair? (car item))
                        (or (not (car (car item)))
                            (vector? (car (car item)))))
               (set! item (cdr item)))
             (vector-set! *item-properties* item-property-def item)
             (when (symbol? item)
               (let ((tem (get item 'menu-enable)))
                 (if *enable-disabled-menus-and-buttons*
                     (vector-set! *item-properties* item-property-enable #t)
                     (when tem
                       (vector-set! *item-properties* item-property-enable
                                    tem))))))
            ((and (eq? item-string 'menu-item) (pair? item))
             ;; New format: `(menu-item NAME [DEF . PROPS])'.
             (vector-set! *item-properties* item-property-name (car item))
             (set! start (cdr item))
             (cond
              ((pair? start)
               (vector-set! *item-properties* item-property-def (car start))
               (set! item (cdr start))
               ;; Maybe an obsolete cache list with key equivalences.
               (when (and (pair? item) (pair? (car item)))
                 (set! item (cdr item)))
               ;; The properties, two at a time.
               (let loop ((rest item))
                 (when (pair? rest)
                   (cond
                    ((not (pair? (cdr rest))) #f)
                    (else
                     (let ((prop (car rest))
                           (value (cadr rest)))
                       (cond
                        ((eq? prop ':enable)
                         (if *enable-disabled-menus-and-buttons*
                             (vector-set! *item-properties*
                                          item-property-enable #t)
                             (vector-set! *item-properties*
                                          item-property-enable value)))
                        ((eq? prop ':visible)
                         ;; A :visible form that evaluates to nil
                         ;; makes this item vanish.
                         (unless (menu-item-eval-property value)
                           (return #f)))
                        ((eq? prop ':help)
                         (vector-set! *item-properties* item-property-help
                                      (if (string? value)
                                          (help-echo-substitute-command-keys
                                           value)
                                          value)))
                        ((eq? prop ':filter)
                         ;; The C keeps the TAIL whose car is the
                         ;; filter; the definition is passed through
                         ;; it below.
                         (set! filter (cdr rest)))
                        ((eq? prop ':key-sequence)
                         (when (or (symbol? value) (string? value)
                                   (vector? value))
                           ;; "Be GC protected. Set keyhint to item
                           ;; instead of tem." The C keeps the *list*
                           ;; whose car is the value, so that
                           ;; `XCAR (keyhint)' is the value however the
                           ;; rest of the property list is built.
                           (set! keyhint (cdr rest))))
                        ((eq? prop ':keys)
                         (vector-set! *item-properties* item-property-keyeq
                                      (cond ((procedure? value) (value))
                                            ((or (pair? value) (string? value))
                                             value)
                                            (else #f))))
                        ((and (eq? prop ':button) (pair? value))
                         (let ((type (car value)))
                           (when (or (eq? type ':toggle) (eq? type ':radio))
                             (vector-set! *item-properties*
                                          item-property-selected (cdr value))
                             (vector-set! *item-properties*
                                          item-property-type type))))
                        (else #f))
                       (loop (cddr rest))))))))
              ((or (not (= inmenubar 0)) (not (null? start)))
               (return #f))
              (else #f)))
            (else
             (return #f)))                 ; not a menu item

           ;; If the item string is not a string, evaluate it to get
           ;; one; if that is not a string either, skip the item.
           (let ((name (vector-ref *item-properties* item-property-name)))
             (unless (string? name)
               (set! name (menu-item-eval-property name))
               (unless (string? name) (return #f))
               (vector-set! *item-properties* item-property-name name)))

           ;; A filter applies to the definition.
           (when filter
             (let ((def (vector-ref *item-properties* item-property-def)))
               (set! def (menu-item-eval-property
                          (list (car filter) (list 'quote def))))
               (vector-set! *item-properties* item-property-def def)))

           ;; Enable or disable selection.
           (let ((tem (vector-ref *item-properties* item-property-enable)))
             (unless (eq? tem #t)
               (set! tem (menu-item-eval-property tem))
               ;; Disabled items are ignored in the menu bar.
               (when (and (not (= inmenubar 0)) (not tem)) (return #f))
               (vector-set! *item-properties* item-property-enable tem)))

           ;; No definition: unselectable text, which is OK in a submenu
           ;; but not in the menu bar.
           (when (not (vector-ref *item-properties* item-property-def))
             (return (= inmenubar 0)))

           ;; A subkeymap is a submenu.
           (let ((def (vector-ref *item-properties* item-property-def)))
             (when (km:keymap-type? def)
               (vector-set! *item-properties* item-property-map def)
               (vector-set! *item-properties* item-property-def def)
               (return #t)))

           ;; The menu bar does not display key equivalents.
           (when (> inmenubar 0) (return #t))

           ;; "This is a command. See if there is an equivalent key
           ;; binding." - `keyboard.c:9095`. The answer is the
           ;; ITEM_PROPERTY_KEYEQ a menu draws to the right of the item's
           ;; name: `tty_menu_show` right-aligns it, and the toolkit menus
           ;; do the same.
           (let* ((keyeq (vector-ref *item-properties* item-property-keyeq))
                  (def (vector-ref *item-properties* item-property-def)))
             (if (and (string? keyeq) (not (pair? keyhint)))
                 ;; `substitute-command-keys` is not ported (see
                 ;; `help-echo-substitute-command-keys`), so a `:keys`
                 ;; that is a string is used as it stands.
                 (vector-set! *item-properties* item-property-keyeq
                              (string-append "  " keyeq))
                 (let ((prefix keyeq)
                       (keys #f))
                   (when (pair? prefix)
                     (set! def (car prefix))
                     (set! prefix (cdr prefix)))
                   ;; "We have a suggested key. Is it bound to the
                   ;; command?" The C also accepts an alias of DEF; this
                   ;; tree has no command aliases, so the test is `eq?'.
                   (when (and (pair? keyhint) (car keyhint))
                     (set! keys (car keyhint))
                     (let ((tem (key-binding keys)))
                       (unless (and tem (eq? tem def))
                         (set! keys #f))))
                   (unless keys
                     (set! keys (where-is-internal def #f #t #f #f)))
                   (if keys
                       (let ((tem (key-description keys)))
                         (when (pair? prefix)
                           (if (string? (car prefix))
                               (set! tem (string-append (car prefix) tem)))
                           (if (string? (cdr prefix))
                               (set! tem (string-append tem (cdr prefix)))))
                         (vector-set! *item-properties* item-property-keyeq
                                      (string-append "  " tem)))
                       (vector-set! *item-properties* item-property-keyeq
                                    #f)))))

           ;; Radio buttons and toggle boxes.
           (let ((tem (vector-ref *item-properties* item-property-selected)))
             (when tem
               (vector-set! *item-properties* item-property-selected
                            (menu-item-eval-property tem))))
           #t))))

    (define %separator-names
      ;; The C's `separator_names` table (`keyboard.c:8579').
      '("space" "no-line" "single-line" "double-line"
        "single-dashed-line" "double-dashed-line"
        "shadow-etched-in" "shadow-etched-out"
        "shadow-etched-in-dash" "shadow-etched-out-dash"
        "shadow-double-etched-in" "shadow-double-etched-out"
        "shadow-double-etched-in-dash" "shadow-double-etched-out-dash"))

    (define (menu-separator-name? label)
      ;; GNU Emacs's `menu_separator_name_p' (`keyboard.c:8608'):
      ;; whether LABEL names a separator line rather than an item.
      ;;
      ;; Two spellings: a name containing only dashes, and the
      ;; toolkit's own `--NAMES` list - `--space`, `--double-line` and
      ;; the shadowed etchings. The C tests `strnlen (label, 4) == 4`
      ;; first, so `--` itself falls to the all-dashes branch, and a
      ;; label shorter than two characters cannot match either.
      ;;--------------------------------------------------------------
      (cond
       ((not (string? label)) #f)
       ((and (>= (string-length label) 4)
             (string=? (substring label 0 2) "--")
             (not (char=? (string-ref label 2) #\-)))
        (if (member (substring label 2 (string-length label)) %separator-names)
            #t
            #f))
       (else
        (let loop ((i 0))
          (cond ((>= i (string-length label)) #t)
                ((char=? (string-ref label i) #\-) (loop (+ i 1)))
                (else #f))))))

    (define (menu-bar-items)
      ;; GNU Emacs's `menu_bar_items' (`keyboard.c:8641'): the
      ;; `[menu-bar]' bindings of every active keymap, in precedence
      ;; order, as `(KEY NAME DEFS UNUSED)' quads.
      ;;
      ;; Emacs builds an array least-specific-first and walks it
      ;; BACKWARDS, so the global map contributes first and a more
      ;; specific map's entry is later merged over it. `lookup-keymaps'
      ;; is most-specific-first, so it is walked in reverse here. The
      ;; C's `menu_bar_one_keymap_changed_items' is the per-map
      ;; `changed' list: a key one map has already contributed is not
      ;; contributed again, even when the parse then rejects it.
      ;;
      ;; The 4th slot is the C's unused `0', kept so a front-end port
      ;; reads the same quad layout (`(key string maps unused)' - see
      ;; `set_frame_menubar`'s `AREF (items, 4 * i)').
      ;;--------------------------------------------------------------
      (let ((items '()))
        (define (find-item key)
          (let loop ((rest items))
            (cond ((null? rest) #f)
                  ((eq? (car (car rest)) key) (car rest))
                  (else (loop (cdr rest))))))
        (define (remove-item! key)
          (set! items
                (filter (lambda (quad) (not (eq? (car quad) key))) items)))
        (define (append-item! quad)
          (set! items (append items (list quad))))
        (for-each
         (lambda (map)
           (let ((def (km:keymap-lookup map 'menu-bar)))
             (when (km:keymap-type? def)
               (let ((changed '()))
                 (km:map-keymap
                  (lambda (key item)
                    (cond
                     ;; An explicit `undefined' removes an item another
                     ;; map put there.
                     ((eq? item 'undefined) (remove-item! key))
                     ((or (memq key changed) (not item)) #f)
                     (else
                      (set! changed (cons key changed))
                      (when (parse-menu-item item 1)
                        (let ((def (vector-ref *item-properties*
                                               item-property-def))
                              (name (vector-ref *item-properties*
                                                item-property-name))
                              (old (find-item key)))
                          (if (not old)
                              (append-item! (list key name (list def) 0))
                              ;; Both keymaps: keep both, the new first.
                              ;; Otherwise the lookup only finds the
                              ;; new one.
                              (let ((defs (caddr old)))
                                (set-car! (cddr old)
                                          (if (and (km:keymap-type? def)
                                                   (km:keymap-type? (car defs)))
                                              (cons def defs)
                                              (list def))))))))))
                  (keymap-canonicalize def))))))
         ;; `overriding-local-map-menu-flag` is nil by default, and the C
         ;; then specbinds both overriding maps to nil
         ;; (`keyboard.c:8677') - the bar keeps reflecting the buffer's
         ;; maps. This tree has the terminal one only, so it is that
         ;; entry that is dropped.
         (reverse (if *overriding-local-map-menu-flag*
                      (lookup-keymaps)
                      (filter (lambda (map)
                                (not (memq map
                                           (or *overriding-terminal-local-map*
                                               '()))))
                              (lookup-keymaps)))))
        ;; Move the named items to the end, in the order listed.
        (for-each
         (lambda (key)
           (let ((old (find-item key)))
             (when old
               (remove-item! key)
               (append-item! old))))
         *menu-bar-final-items*)
        items))

    (define (parse-tab-bar-item key item)
      ;; GNU Emacs's `parse_tab_bar_item` (`keyboard.c:9876`): one tab
      ;; bar item's six slots, or #f when the binding is not one.
      ;;
      ;; **It is NOT `parse_menu_item`**, and the difference matters: a
      ;; tab's item carries a nil *binding* - the click finds its tab by
      ;; the item's KEY - and `parse_menu_item` refuses a nil definition
      ;; in a menu bar ("If we got no definition, this item is just
      ;; unselectable text which is OK in a submenu but not in the
      ;; menubar", `keyboard.c:9612`). Reusing it here dropped every tab
      ;; but the current one.
      ;;
      ;; The C's slots, in order: KEY, ENABLED, SELECTED, CAPTION,
      ;; BINDING, HELP (`dispextern.h:3408`).
      ;;--------------------------------------------------------------
      (define (walk-props rest enabled selected help filter)
        ;; "Process the rest of the properties." **WALK-PROPS and not
        ;; PROPS**: a parameter named `props` hides the procedure that
        ;; recurses, and the call applies the list.
        (cond
         ((and (pair? rest) (pair? (cdr rest)))
          (let ((k (car rest)) (v (cadr rest)))
            (cond ((eq? k ':enable)
                   (walk-props (cddr rest) v selected help filter))
                  ((eq? k ':help)
                   (walk-props (cddr rest) enabled selected v filter))
                  ((eq? k ':filter)
                   (walk-props (cddr rest) enabled selected help v))
                  ((eq? k ':button)
                   (walk-props (cddr rest) enabled
                               (if (and (pair? v) (memq (car v) '(toggle radio)))
                                   (cdr v)
                                   selected)
                               help filter))
                  (else
                   (walk-props (cddr rest) enabled selected help filter)))))
         (else (list enabled selected help filter))))
      (cond
       ((not (pair? item)) #f)
       ;; "As an exception, allow old-style menu separators."
       ((string? (car item)) (list key #t #f (car item) #f #f))
       ((not (eq? (car item) 'menu-item)) #f)
       ((not (pair? (cdr item))) #f)
       (else
        (let* ((caption (cadr item))
               (rest (cddr item)))
          (cond
           ((not (string? caption)) #f)
           ;; "If the rest following the caption is not a list, the menu
           ;; item is either a separator, or invalid."
           ((not (pair? rest))
            (if (menu-separator-name? caption)
                (list key #f #f #f #f #f)
                #f))
           (else
            (let* ((binding (car rest))
                   (tail (cdr rest))
                   ;; "Ignore cached key binding, if any."
                   (tail (if (and (pair? tail) (pair? (car tail)))
                             (cdr tail)
                             tail))
                   (pb (walk-props tail #t #f #f #f))
                   (enabled (list-ref pb 0))
                   (selected (list-ref pb 1))
                   (help (list-ref pb 2))
                   (filter (list-ref pb 3))
                   (binding (if filter
                                (menu-item-eval-property
                                 (list filter (list 'quote binding)))
                                binding)))
              ;; "See if the binding is a keymap. Give up if it is."
              (cond
               ((km:keymap-type? binding) #f)
               (else
                (list key
                      (if (eq? enabled #t) #t
                          (menu-item-eval-property enabled))
                      (if selected (menu-item-eval-property selected) #f)
                      caption binding help))))))))))

    (define (tab-bar-collect-items keymap items)
      ;; One map's `[tab-bar]' submap walked into ITEMS - the C's
      ;; `process_tab_bar_item` with `map_keymap` over it. A key appears
      ;; once per map, so an item replaces any earlier one of the same
      ;; key rather than joining it (a tab is identified by its key).
      ;;--------------------------------------------------------------
      (km:map-keymap
       (lambda (key item)
         (cond ((eq? item 'undefined)
                (set! items
                      (filter (lambda (quad) (not (eq? (car quad) key))) items)))
               (else
                (let ((parsed (parse-tab-bar-item key item)))
                  (when parsed
                    (set! items
                          (append (filter (lambda (quad)
                                            (not (eq? (car quad) key)))
                                          items)
                                  (list parsed))))))))
       keymap)
      items)

    (define (tab-bar-items)
      ;; GNU Emacs's `tab_bar_items` (`keyboard.c:9751`): the
      ;; `[tab-bar]' bindings of every active keymap, in precedence
      ;; order, as six-slot items - `(KEY ENABLED SELECTED CAPTION
      ;; BINDING HELP)`, the C's `TAB_BAR_ITEM_*` enum.
      ;;
      ;; **This is `menu-bar-items' with one key changed**, which is what
      ;; the C's is: the same reverse walk over the active maps and the
      ;; same `map-keymap' over each map's `[tab-bar]' submap. The C's
      ;; differences are that the prefix key is `Qtab_bar' rather than
      ;; `Qmenu_bar', that there is no `tab-bar-final-items' pass, and
      ;; that the parser is `parse-tab-bar-item` above.
      ;;--------------------------------------------------------------
      ;; **The keymap is rebuilt first.** The C reaches it through
      ;; `[tab-bar]`'s `:filter` (`get_keyelt`'s `menu_item_eval_property`
      ;; arm), and this tree's keymap lookup does not apply filters - the
      ;; evaluating function is this library's and `keymap.scm` is below
      ;; it. The filter's work is done here instead, so every reader of
      ;; the items sees the current tabs, not the ones of the last
      ;; redisplay.
      (when (*tab-bar-keymap-function*)
        ((*tab-bar-keymap-function*)))
      (let ((maps (reverse
                   (if *overriding-local-map-menu-flag*
                       (lookup-keymaps)
                       (filter (lambda (map)
                                 (not (memq map
                                            (or *overriding-terminal-local-map*
                                                '()))))
                               (lookup-keymaps))))))
        (let loop ((rest maps) (items '()))
          (cond ((null? rest) items)
                (else
                 (let ((def (km:keymap-lookup (car rest) 'tab-bar)))
                   (loop (cdr rest)
                         (if (km:keymap-type? def)
                             (tab-bar-collect-items
                              (keymap-canonicalize def) items)
                             items))))))))

    (define-key *default-keymap* (kbd "C-q") quoted-insert)

    ;; The redisplay's seam: `menu_bar_items` is this library's
    ;; (`keyboard.c:8641`) and `update_menu_bar` is `xdisp.c`'s, which is
    ;; *below* here - so the redisplay asks for the items through this.
    (*menu-bar-items-function* menu-bar-items)
    (*tab-bar-items-function* tab-bar-items)

    ))
