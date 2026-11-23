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
    (only (guile) format inexact->exact logior logand lognot string-index
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
          ;; a click's window - `current_active_maps` switches to the
          ;; buffer of the window clicked on before it reads anything
          window-type? window-buffer
          set!frame-keymap-state set!frame-message
          set!frame-quit-cont
          *echo-area-buffer*)
    ;; The global map the lookup falls back on, and the local map a
    ;; minibuffer or a mode binds to have its own keys.
    (only (schemacs editor keymap)
          *current-keymap*
          *default-keymap*
          *special-event-map* define-key keymap-parent keymap-type?
          keymap-lookup lookup-key
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
          *get-text-property-function*
          ;; `current_active_maps`' buffer-position half: the `local-map`/
          ;; `keymap` text properties at a click, through `get_local_map`
          ;; (`editfns.scm`, above this library) - installed there.
          *get-local-map-function*
          ;; `current_active_maps` switches to the clicked window's buffer
          ;; for the lookup; the parameter is this tree's current buffer.
          *current-buffer*
          buffer-beg buffer-z)
    ;; `parse-tool-bar-item` builds a default label with `upcase-initials`
    ;; (`casefiddle.c:418`); `casefiddle.scm` is below this library.
    (only (schemacs editor casefiddle) upcase-initials)
    (only (schemacs editor simple)
          *last-command* *this-command*
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
          *pending-coding-system* command-record-named command-value-of
          *barf-if-buffer-read-only-function* *read-char-event-function*
          *read-key-sequence-function* *read-key-sequence-vector-function*)
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
          *tab-bar-items-function* *tab-bar-keymap-function*
          *tool-bar-items-function* *tool-bar-keymap-function*
          ;; The redisplay hands it the help-echo it found under the
          ;; pointer; `show-help-echo` is this library's (`keyboard.c`),
          ;; and the redisplay is below, so it is the one installed the
          ;; other way round from the rest: see the tail of this file.
          *show-help-echo-function*)
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
          posn-area posn-window posn-point posn-string event-start)
    (only (schemacs editor character)
          char-meta char-alt char-super char-hyper char-shift char-ctl
          parse-modifiers-uncached event-convert-list
          ;; The C's mouse-event fallback reads an event's modifiers and
          ;; its base type (`keyboard.c:12115`).
          event-modifiers event-basic-type)
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
   ;; `last-nonmenu-event', and the recording `read_key_sequence' does:
   ;; both front ends hand keys to the command loop by more than one
   ;; path, and every path has to say what kind of event it was.
   *last-nonmenu-event* record-nonmenu-event!
   ;; "How many pixels the mouse can move between press and release and
   ;; still be treated as a click" - read by the Gtk front end's button
   ;; release (`keyboard.c:6668-6682').
   double-click-fuzz
   ;; GNU Emacs's `command-remapping' - what a `[remap COMMAND]' binding
   ;; in the active maps answers, applied by the loop before a command
   ;; runs (`keyboard.c').
   command-remapping
   function-key-translate *key-translation-map* key-translation-translate
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
   *overriding-terminal-local-map* *overriding-local-map*
   *this-command-keys* help-char help-event-list
   ;; `keyboard.c`'s menu-bar half. `menu_bar_items` and `parse_menu_item`
   ;; are C-internal in Emacs (the front end calls them); here the front
   ;; end is Scheme and must import them, so the property slots are
   ;; exported with them.
   *menu-bar-final-items* *overriding-local-map-menu-flag*
   menu-bar-items parse-menu-item menu-separator-name?
   tab-bar-items lookup-keymaps
   ;; `keyboard.c`'s help echo: the display function the tooltip library
   ;; installs, and the two seams upper libraries fill in.
   *show-help-function* *help-echo-substitute-function*
   *mouse-fixup-help-message-function*
   show-help-echo help-echo-substitute-command-keys
   ;; `keyboard.c`'s tool-bar half, the same way: `tool_bar_items` and
   ;; `parse_tool_bar_item` are C-internal in Emacs, and the front end
   ;; here is Scheme. The slot indices are the C's `TOOL_BAR_ITEM_*`
   ;; enum (`dispextern.h:3453`), exported for the widget builder.
   tool-bar-items parse-tool-bar-item tool-bar-max-label-size
   tool-bar-item-key tool-bar-item-enabled-p tool-bar-item-selected-p
   tool-bar-item-caption tool-bar-item-images tool-bar-item-binding
   tool-bar-item-type tool-bar-item-help tool-bar-item-rtl-image
   tool-bar-item-label tool-bar-item-vert-only tool-bar-item-wrap
   tool-bar-item-nslots
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
   undefined
   read-key-event read-char-event read-key-sequence read-key-sequence-vector
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
   handle-interrupt init-signals maybe-quit *signal-wake-function*
   ;; `timer_check' and the read's deadline are the command loop's, so
   ;; they are published the way the rest of the loop is.
   timer-check!
   timer-next-delay
   )

  (begin

    ;; **The `*' interactive code's check** - `callint.c`'s
    ;; `barf_if_buffer_read_only` (`:370`). `interactive-proc` is
    ;; `callint.c`'s and lives in `(schemacs editor command)`, which is a
    ;; leaf below this library; `barf-if-buffer-read-only` is
    ;; `buffer.c`'s and lives below it too, in
    ;; `(schemacs editor buffer)`. So the two meet here, where the
    ;; command loop is, through the seam `command.scm` declares - the
    ;; same shape `*record-window-buffer-function*` and
    ;; `*frame-creation-function*` take. Without this line a command
    ;; whose specification begins with `*' (`comment-indent' is one)
    ;; reads its arguments and runs without the check.
    (*barf-if-buffer-read-only-function* barf-if-buffer-read-only)

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

    (define *overriding-local-map* (make-parameter #f))
    ;; ^ GNU Emacs's `overriding-local-map' (`keyboard.c',
    ;; `Voverriding_local_map'): a keymap packages `let`-bind to make it
    ;; the only map consulted besides `global-map' for the extent of the
    ;; binding. `current_active_maps` (`keymap.c:1694`) is where the rule
    ;; lives, and `lookup-keymaps` below is this tree's copy of it.
    ;;
    ;; **A parameter**, because Emacs binds it dynamically - that is its
    ;; whole contract - and `describe-buffer-bindings` reads it, which is
    ;; why it exists here now.

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

    (define *key-translation-map*
      ;; GNU Emacs's `key-translation-map` (`keyboard.c:14773`: "Keymap
      ;; for translating one key sequence into another while reading
      ;; input." The C applies it after `function-key-map', and a binding
      ;; may be a *function*: `read_key_sequence` calls it - with no
      ;; arguments here, where the C's translators take an optional echo
      ;; prompt - and its answer, a key sequence or nil, is what the key
      ;; means. `mouse--click-1-maybe-follows-link` (mouse.el:156) is the
      ;; one user, and it turns a mouse-1 that follows a link into a
      ;; mouse-2.
      ;;--------------------------------------------------------------
      (km:keymap '*key-translation-map*))

    (define (key-translation-translate key)
      ;; KEY as `key-translation-map' means it, or KEY itself when it has
      ;; no entry there. A procedure entry is called; its answer's first
      ;; event replaces KEY, and a nil answer - the mouse translator
      ;; saying "not a link" - leaves KEY alone.
      ;;
      ;; The event passed to the translator is `*last-read-event*` when
      ;; that is the event KEY came from, which is where a mouse click's
      ;; *position* is; a key pushed back onto `*unread-command-events*`
      ;; has no position, so the translator sees `(KEY)` - Emacs's
      ;; `last-input-event` holds the whole `(mouse-1 POSN)` event.
      ;;--------------------------------------------------------------
      (let ((binding (km:keymap-lookup *key-translation-map* key)))
        (cond
         ((not binding) key)
         ((procedure? binding)
          (let* ((raw (*last-read-event*))
                 (event (if (and (pair? raw) (eq? (car raw) key))
                            raw
                            (list key)))
                 (answer (binding event)))
            (cond
             ((not answer) key)
             ((and (vector? answer) (> (vector-length answer) 0))
              (let ((translated (vector-ref answer 0)))
                ;; A translator may answer a whole *event* - the
                ;; mouse-1-to-mouse-2 translation answers
                ;; `(mouse-2 POSITION)` - and the position is the whole
                ;; point of it: `event-start` of the translated event has
                ;; to still name the place that was clicked. Emacs mutates
                ;; `last-input-event` in place (`mouse.el:193`); here the
                ;; translated event becomes `*last-read-event*` and its
                ;; `car` is the key the lookup uses.
                (if (pair? translated)
                    (begin
                      (*last-read-event* translated)
                      (car translated))
                    translated)))
             ((pair? answer) (car answer))
             (else answer))))
         (else binding))))

    (define (function-key-translate key)
      ;; KEY as `function-key-map' then `key-translation-map' mean it, or
      ;; KEY itself when neither has an entry. `read_key_sequence''s
      ;; translation steps, over one key rather than a sequence - every
      ;; read here answers one.
      ;;--------------------------------------------------------------
      (let ((key (if (symbol? key)
                     (let ((found (assq key *function-key-map*)))
                       (if found (cdr found) key))
                     key)))
        (key-translation-translate key)))

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

    (define help-char 8)
    ;; ^ GNU Emacs's `help-char` (`keyboard.c:14491`): "Character to
    ;; recognize as meaning Help." The C sets `Ctl ('H')`, which is 8. A
    ;; plain variable - a DEFVAR that nothing `let`-binds - and the
    ;; self-assignment marks it mutable against the compiler's constant
    ;; folding, because an init file may `set!` it.
    (set! help-char help-char)

    (define help-event-list '())
    ;; ^ GNU Emacs's `help-event-list` (`keyboard.c:14497`): "List of
    ;; input events to recognize as meaning Help. These work just like
    ;; the value of `help-char`." Nil in a plain Emacs.
    (set! help-event-list help-event-list)

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
      ;; command. Whether there is something to redo is *derived* from
      ;; that list, not flagged: `undo--last-change-was-undo-p' asks the
      ;; table `undo' fills (`simple.scm`), as Emacs's does.
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
      ;; "if (!SYMBOLP (command)) return Qnil" - the C's first line.
      ;;
      ;; **A command name HERE is a string**, because `new-command` takes
      ;; it from `symbol->string`, and a `[remap ...]` binding is keyed by
      ;; the *symbol*. So a string is interned first: without that, the
      ;; guard rejected every name this tree has and **every `[remap ...]`
      ;; binding in the tree was dead** - `remapped-command` always passed
      ;; a string. Found while porting `suppress-keymap`, which is
      ;; Emacs's one essential use of `remap`.
      ;;--------------------------------------------------------------
      (let ((command (if (string? command) (string->symbol command) command)))
        (and (symbol? command)
             (let loop ((maps (lookup-keymaps)))
               (and (pair? maps)
                    (or (km:keymap-lookup (car maps) (vector 'remap command))
                        (loop (cdr maps))))))))

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
             (click-window (and position (posn-window position)))
             (click-buffer (and (window-type? click-window)
                                (window-buffer click-window)))
             (string (and position (posn-string position)))
             ;; The string's own `keymap` and `local-map` properties - a
             ;; tab's map, a mode line item's - read through the seam
             ;; `textprop.scm` installs.
             (string-props
              (and string
                   (let ((s (car string)) (pos (cdr string)))
                     (and (integer? pos)
                          (>= pos 0)
                          (< pos (string-length s))
                          (let ((lookup (*get-text-property-function*)))
                            (and lookup
                                 (cons (lookup pos 'keymap s)
                                       (lookup pos 'local-map s))))))))
             ;; `click_position' (`keymap.c:1640'): a position that names
             ;; no buffer location - a mode line, a tab - asks about PT;
             ;; and one outside the clicked buffer's accessible range is
             ;; ignored, which is the C's `BEG <= pos && pos <= Z` test.
             (buffer-pos
              (and click-buffer
                   (let ((posn (and position (posn-point position))))
                     (if (and (integer? posn)
                              (>= posn (buffer-beg click-buffer))
                              (<= posn (buffer-z click-buffer)))
                         posn
                         (buffer-pt click-buffer))))))
        ;; "If a mouse click position is given, our variables are based on
        ;; the buffer clicked on, not the current buffer" - the C's
        ;; `set_buffer_internal`, which is restored when it is done.
        (parameterize ((*current-buffer* (or click-buffer (*current-buffer*))))
        (let ((buffer-keys (buffer-local-keymap (current-buffer)))
              (mode-keys (*current-keymap*))
              ;; "first consider the `local-map' and `keymap' properties of
              ;; that string"; otherwise the clicked buffer position's,
              ;; where `get_local_map`'s `local-map` arm falls back on the
              ;; buffer's own map, exactly as the C's does.
              (position-map
               (or (and string-props (car string-props))
                   (and click-buffer
                        ((*get-local-map-function*)
                         buffer-pos click-buffer 'keymap))))
              (local-map
               (or (and string-props (cdr string-props))
                   (and click-buffer
                        ((*get-local-map-function*)
                         buffer-pos click-buffer 'local-map)))))
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
        ;; **`overriding-local-map` suppresses everything else**, which
        ;; is `current_active_maps`'s rule (`keymap.c:1694`): "The doc
        ;; said that overriding-terminal-local-map should override
        ;; overriding-local-map.  The code used them both, but it seems
        ;; clearer to use just one.  rms, jan 2005." So when it is set -
        ;; and the terminal one is not - the lookup is that map and
        ;; `global-map` alone.
        (if (and (not *overriding-terminal-local-map*)
                 (*overriding-local-map*))
            (append (if (list? (*overriding-local-map*))
                        (*overriding-local-map*)
                        (list (*overriding-local-map*)))
                    (%keymap-and-parents *default-keymap*))
        (append
         (or *overriding-terminal-local-map* '())
         ;; "Then, if the click was in the buffer, get the local
         ;; text-property keymap of the place clicked on" - and the
         ;; `keymap` property goes in front of everything but the
         ;; overriding map.
         (if position-map (list position-map) '())
         ;; **The enabled minor modes' maps come before the buffer's own**,
         ;; where `current_active_maps' (`keymap.c') puts them: a minor
         ;; mode's key shadows the buffer's, and the buffer's shadows
         ;; `global-map'. The position's `local-map` property sits between
         ;; them and the buffer's own map, which is the C's cons order.
         (minor-mode-keymaps)
         ;; "Finally, fall back on the buffer's local map": the string's
         ;; `local-map` overrides it when it has one.
         (if (or local-map buffer-keys)
             (%keymap-and-parents (or local-map buffer-keys))
             '())
         (if mode-keys (%keymap-and-parents mode-keys) '())
         (%keymap-and-parents *default-keymap*)))))))

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
       ;; A keymap *list* `(keymap MAP ...)` - what `access-keymap`
       ;; answers when a key is a prefix in two maps - is one keymap.
       ((km:keymapp km)
        (make<modal-lookup-state-type> (list km) '()))
       ((and (list? km) (pair? km) (km:keymapp (car km)))
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
      ;;
      ;; **The whole list goes to ONE lookup**, as the C hands its
      ;; `current_binding` - a keymap *list* - to `follow_key`
      ;; (`keyboard.c:12062`). `access-keymap` searches the list for the
      ;; event and, when several maps bind it as a *prefix*, answers a
      ;; keymap list `(keymap M1 M2 ...)`; the next event is looked up in
      ;; that whole list, which is how a prefix in one map that does not
      ;; bind the next event falls through to another map's prefix.
      ;;
      ;; **Walking the maps one at a time loses exactly that**, and the
      ;; symptom was a mode-line drag that never ended: the drag's
      ;; transient map binds `[mode-line]` to itself but not
      ;; `[mode-line mouse-1]`; the global map has the `[mode-line
      ;; mouse-1]` prefix. Map by map, the transient map's prefix won and
      ;; the release was unbound - Emacs's `set-transient-map` doc says
      ;; what should happen instead: "if no match for a key is found in
      ;; MAP, the normal key lookup sequence then continues."
      ;;--------------------------------------------------------------
      (km:keymap-lookup (modal-lookup-state-keymaps state) (list event)))

    (define (key-binding key . rest)
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
      ;; KEY may be looked up with ACCEPT-DEFAULT - Emacs's
      ;; `(key-binding KEY ACCEPT-DEFAULT)` - which is the third argument
      ;; of `lookup-key`'s DEFUN, applied to the whole list of active
      ;; maps. `lookup-key` reads a *list* of keymaps with that rule
      ;; already, so the walk is one call - and its "too long" answer
      ;; (a number) passes through, as `help--binding-undefined-p`
      ;; expects.
      (let ((def (lookup-key (lookup-keymaps) key
                             (and (pair? rest) (car rest)))))
        def))

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
         ((and action-or-map (not (km:keymapp action-or-map)))
          (set!modal-lookup-state-keymaps state '())
          (do-action full-key action-or-map)
          #f)
         ((km:keymapp action-or-map)
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

    (define (%unbound-mouse-reduction event)
      ;; One step of GNU Emacs's reduction of an unbound mouse event
      ;; (`keyboard.c:12100-12210`): "Attempt to reduce an unbound mouse
      ;; event to a simpler event that is bound: Drags reduce to clicks.
      ;; Double-clicks reduce to clicks. ... Up/Down-clicks are
      ;; eliminated."
      ;;
      ;; Answers the event to try next in the *same* map, the symbol
      ;; `drop` for an up or down click - which the C disposes of by
      ;; reading another event, running nothing and reporting nothing -
      ;; or #f for anything that is not a mouse click, which keeps the
      ;; "last event alone" rule for keyboard prefixes.
      ;;
      ;; **Why this matters**: a mode-line item's map binds
      ;; `[mode-line mouse-1]` and nothing else. A press on it
      ;; (`down-mouse-1`) is therefore unbound in that map, and without
      ;; this rule the dispatcher retried it alone and found the *text*
      ;; binding `mouse-drag-region`, which cannot act on a mode-line
      ;; position - "Wrong type argument in position 2: #f" from
      ;; `mouse-drag-track`. Emacs drops the press instead.
      ;;--------------------------------------------------------------
      (let ((modifiers (and (symbol? event) (event-modifiers event))))
        (cond
         ((not modifiers) #f)
         ;; `triple-mouse-1` is tried first as a double, as the C's
         ;; `modifiers ^= (double | triple)` does.
         ((memq 'triple modifiers)
          (event-convert-list (list 'double (event-basic-type event))))
         ((or (memq 'double modifiers) (memq 'drag modifiers))
          (event-basic-type event))
         ((or (memq 'down modifiers) (memq 'click modifiers))
          'drop)
         (else #f))))

    (define (%run-reduced-click prefix-maps event run)
      ;; The rest of the C's loop: a reduced click is looked up in the
      ;; *same* keymap the failed event was in, and what is still unbound
      ;; keeps reducing until it is bound or is an up/down click.
      ;; Answers like a chord: #t when the reduced event is itself a
      ;; prefix keymap, #f when it ran a command or nothing was found.
      ;;--------------------------------------------------------------
      (let loop ((ev event))
        (let* ((sub (new-modal-lookup-state prefix-maps))
               (found? #f)
               (result
                (modal-lookup-state-step!
                 sub ev
                 (lambda (fp action)
                   (set! found? #t)
                   (run sub action))
                 (lambda (fp action)
                   (set! found? #t)
                   #t)
                 (lambda (fp) #f))))
          (cond
           (found? (and result #t))
           (else
            (let ((next (%unbound-mouse-reduction ev)))
              (cond ((eq? next 'drop) #f)
                    (next (loop next))
                    (else #f))))))))

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
              ;; `letrec*` and not `let*`: the `fail` closure calls
              ;; `fail-alone` and reads `prefix-maps`, which are bound
              ;; after it in this list - a `let*` would leave both
              ;; unbound inside the closure (the compiler says so, and
              ;; the mouse fallback then dies on the one path it exists
              ;; for).
              (letrec* ((run
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
                        ;; **The C's mouse-event fallback comes first**:
                        ;; an unbound mouse click is reduced or dropped,
                        ;; never retried alone (`%unbound-mouse-reduction`).
                        (let ((reduced (%unbound-mouse-reduction key)))
                          (cond
                           ((eq? reduced 'drop) #f)
                           (reduced (%run-reduced-click prefix-maps reduced run))
                           (else (fail-alone full-path))))))
                     (fail-alone
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
                     ;; The map the failed event was looked up in - the
                     ;; prefix's map for the second event of a chord.
                     ;; `modal-lookup-state-step!` empties it as it
                     ;; fails, so it is taken before the step.
                     (prefix-maps (modal-lookup-state-keymaps state))
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
              ;; The same record the read makes: this is the other path
              ;; an event reaches the command loop by, and
              ;; `last-nonmenu-event' has to know a click from a key
              ;; whichever one delivered it.
              (record-nonmenu-event! ev key)
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

    (define *signal-wake-function*
      (make-parameter #f))
    ;; ^ How a front end is told that a signal has set `*quit-flag*`, or
    ;; #f when it needs no telling.
    ;;
    ;; **Emacs's handler longjmps out of `pselect`** (`quit_throw_to_
    ;; read_char`), and that is what ends the wait; a Scheme `sigaction`
    ;; handler is a *deferred* procedure, run at the VM's next safe
    ;; point, so it cannot. Measured on this Guile: a SIGINT during a
    ;; blocking `select` makes `select` return an empty ready set with
    ;; the handler *not yet run*, and the wait then re-blocks with the
    ;; flag set and nothing to see it - `C-g` was occasionally lost until
    ;; the next key. A front end whose wait is a `select` gives this
    ;; parameter a thunk that writes one byte to a pipe it selects on;
    ;; the handler runs at the loop's next safe point, writes, and the
    ;; wait returns and reads the flag. The terminal installs it beside
    ;; its back-door wake; the Gtk loop is already woken by its own
    ;; sources, so it needs nothing.

    (define (handle-interrupt sig)
      ;; GNU Emacs's `handle_interrupt` (`keyboard.c`): "Request quit when
      ;; it's safe."
      ;;
      ;; **The emergency-escape branch is not carried.** The C's first
      ;; branch is for `quit-flag' holding `kill-emacs` - it drops to a
      ;; shell and offers to auto-save and dump core - and nothing here
      ;; sets that value.
      ;;
      ;; The wake is *after* the flag: a wait that returns for the byte
      ;; must find the quit recorded. See `*signal-wake-function*`.
      ;;--------------------------------------------------------------
      (let ((count (if (*quit-flag*) (+ force-quit-count 1) 1)))
        (set! force-quit-count count)
        (when (= count 3)
          (*inhibit-quit* #f))
        (*quit-flag* #t)
        (when (*signal-wake-function*)
          ((*signal-wake-function*)))))

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

    (define-command (undefined)
      ;; GNU Emacs's `undefined` (`subr.el:1297`): "Beep once and tell
      ;; user that nothing is bound to this key sequence."
      ;;
      ;; **It is `subr.el`'s in Emacs and lives here**, because its
      ;; message is built from `this-single-command-keys` - this
      ;; library's `*this-command-keys*`, bound around `dispatch-action`
      ;; and above every library that could otherwise define it.
      ;;
      ;; It exists because **`suppress-keymap` binds `[remap
      ;; self-insert-command]` to it** (`subr.el:1320`): a special-mode
      ;; buffer's printing characters do not fall through to
      ;; self-insert, they arrive here and say "x is undefined". That is
      ;; why the `*Backtrace*` pty check expects "undefined" rather than
      ;; the read-only error - a letter never reaches the buffer.
      ;;
      ;; Not carried: the `ding` (no bell here) and the `prefix-arg`
      ;; reset for a non-mouse event.
      "Beep once and tell user that nothing is bound to this key sequence."
      (interactive)
      (message "%s is undefined"
               (km:key-description (*this-command-keys*))))

    (define (%read-key-sequence-answer events vector?)
      ;; GNU Emacs's `Fread_key_sequence` -> `read-key-sequence`: "Return
      ;; the sequence as a string if all events are characters, else a
      ;; vector" - and `Fread_key_sequence_vector` always a vector. The
      ;; test is `make_event_array` (`alloc.c:3691`): an event fits a
      ;; string when, "after discarding the meta bit and all the bits
      ;; above it", it is below 0200.
      ;;
      ;; **The meta bit is the one part that cannot be carried.** Emacs
      ;; moves it into the string byte's high bit there (`SSET ...
      ;; | 0x80`), so `M-:' becomes the unibyte string byte 0xBA; a
      ;; Guile string is Unicode, and that byte would read back as `º'.
      ;; So a modified event answers a vector here, and every consumer
      ;; takes either form through `keymap-index`.
      ;;
      ;; The "all integers" test this replaced was also a *crash*:
      ;; `C-h k M-:' raised "Value out of range -1 to <1114111>:
      ;; 134217786" from `integer->char` - the read had answered the
      ;; meta event and this asked Guile to make a character of it.
      ;;--------------------------------------------------------------
      (if (or vector?
              (not (let loop ((rest events))
                     (or (null? rest)
                         (and (integer? (car rest))
                              (<= 0 (car rest) 127)
                              (loop (cdr rest)))))))
          (list->vector events)
          (list->string (map integer->char events))))

    (define (%read-key-sequence prompt vector?)
      ;; The shared body of `read-key-sequence` and
      ;; `read-key-sequence-vector`.
      ;;
      ;; GNU Emacs's `read_key_sequence` (`keyboard.c:11441') is a
      ;; thousand lines because it *is* the whole input pipeline:
      ;; translation maps, the echo of the partial sequence, mouse
      ;; prefixes, discarded input. This tree's pipeline is
      ;; `read-key-event` (which normalises the two displays' events and
      ;; applies `input-decode-map`) plus the modal lookup the command
      ;; loop already runs - so what is left is the assembly: read an
      ;; event, step the lookup, and go round again while what it found
      ;; is a prefix keymap.
      ;;
      ;; **Not carried, each because nothing here makes the event**: the
      ;; down-event/up-event *discard* (Emacs reads and throws away the
      ;; `mouse-1` that follows a `down-mouse-1`, so a `k` prompt on a
      ;; click cannot leave the release queued), which also means
      ;; `callint.c`'s `U` code has no up-event to answer; and the echo
      ;; of the partial sequence as it is typed.
      ;;--------------------------------------------------------------
      (when prompt (message "%s" prompt))
      ;; **`read_key_sequence_vs` opens with `maybe_quit ()`**
      ;; (`keyboard.c:12457`), and this is the Lisp-facing
      ;; `read-key-sequence` it wraps. The quit is *not* raised by
      ;; `read-key-event` - that is `read_char`, which answers a pending
      ;; C-g as `quit_char` - so a reader assembling a sequence starts
      ;; with the same check the command loop does.
      (maybe-quit)
      (let ((state (new-modal-lookup-state (lookup-keymaps)))
            (events '())
            ;; The step's own answer is "was the chord finished?" - a
            ;; boolean - so the sequence the callbacks build goes in a
            ;; variable. **Without it this function answered #f for
            ;; every call**, which made `C-h k` describe "#f".
            (answer #f))
        (let loop ((meta-prefix #f))
          (let* ((raw (function-key-translate (read-key-event -1)))
                 ;; `read_key_sequence` clears `Vquit_flag` after every
                 ;; key it reads (`keyboard.c:11892`).
                 (_ (*quit-flag* #f))
                 (event (cond ((not raw) raw)
                              ((not meta-prefix) raw)
                              ((integer? raw) (logior raw char-meta))
                              (else (event-convert-list (list 'meta raw))))))
            (cond
             ;; **ESC prefixes the next key with the meta modifier** -
             ;; `read_key_sequence`'s `meta_prefix_char` step
             ;; (`keyboard.c:11829`), and the state the command loop
             ;; already keeps in `*esc-pending*` (`dispatch-key-event`).
             ;; Without it `C-h k` read a lone ESC on a terminal and
             ;; answered "ESC is undefined" where Emacs describes `M-:'.
             ;; Like the command loop, the fold is unconditional: a
             ;; two-event `ESC KEY` binding is not a spelling this tree
             ;; uses - meta is one event here, as it is in Emacs.
             ((and (not meta-prefix)
                   (eqv? raw (event-convert-list '(control #\[))))
              (loop #t))
             (else
              (set! events (append events (list event)))
              (modal-lookup-state-step!
               state event
               ;; a binding that is not a prefix: the sequence is complete
               (lambda (full-path action)
                 (set! answer (%read-key-sequence-answer events vector?)))
               ;; a prefix keymap: keep reading
               (lambda (full-path action) (loop #f))
               ;; nothing bound: Emacs still answers the sequence it read,
               ;; and the *caller* reports it - `k`'s command does
               (lambda (full-path)
                 (set! answer (%read-key-sequence-answer events vector?))))))))
        answer))

    (define (read-key-sequence prompt)
      ;; GNU Emacs's `read-key-sequence` (`keyboard.c:12501`): "Read a
      ;; sequence of keystrokes, ignoring clicks and other discarded
      ;; input. Return the sequence as a string if all events are
      ;; characters, else a vector."
      ;;--------------------------------------------------------------
      (%read-key-sequence prompt #f))

    (define (read-key-sequence-vector prompt)
      ;; GNU Emacs's `read-key-sequence-vector` (`keyboard.c:12562`):
      ;; the same, always a vector.
      ;;--------------------------------------------------------------
      (%read-key-sequence prompt #t))

    (define (read-char-event . args)
      ;; GNU Emacs's `read-char' (`keyboard.c:11240'): "Read a character
      ;; event from the command input (keyboard or macro). Return the
      ;; character as a number. ... If the user generates an event which
      ;; is not a character ... `read-char' signals an error" - which the
      ;; *caller* does: the C returns nil and `callint.c:490' raises
      ;; "Non-character input-event".
      ;;
      ;; **Named `read-char-event` and not `read-char`**, which is the
      ;; Emacs name, because `read-char` is Guile's: it reads a
      ;; character from a *port*, and `coding.scm`, `theme.scm` and the
      ;; test files all use it that way. Defining Emacs's here would
      ;; shadow that binding inside this library and, worse, export it
      ;; over the core one for anything importing this library - the
      ;; compiler says so: "non-idempotent binding for `read-char` ...
      ;; any module reload would capture module-local binding rather
      ;; than import". The same collision took `insert-newline`'s name
      ;; from Emacs's `newline`.
      ;;
      ;; The C is
      ;;
      ;;   read_filtered_event (1, 1, 1, INHERIT_INPUT_METHOD, SECONDS)
      ;;   ... !FIXNUMP (val) ? Qnil : char_resolve_modifier_mask (...)
      ;;
      ;; **`char_resolve_modifier_mask` is not carried, because this
      ;; tree's events never hold a modifier mask.** `read-key-event`
      ;; folds them - `C-s` arrives as 19, not as `s` with a control bit
      ;; - which its own docstring calls the one thing a reader must do
      ;; so that nothing above it asks where a key came from. So what is
      ;; left of the C is the type test.
      ;;
      ;; INHERIT-INPUT-METHOD and SECONDS are not taken: there is no
      ;; input method here, and a caller that wants a deadline wants
      ;; `read-key-event` itself.
      ;;--------------------------------------------------------------
      (let ((prompt (if (pair? args) (car args) #f)))
        (when prompt (message "%s" prompt))
        (let ((event (read-key-event -1)))
          (if (integer? event) event #f))))

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
          ;; **This is `read_char`, and `read_char` does not signal a
          ;; quit.** A pending C-g is *answered* - `quit_char`, from
          ;; `read_char`'s interrupted branch (`keyboard.c:2817`) or from
          ;; `kbd_buffer_get_event` before it blocks (`:4117`) - so that
          ;; a reader which asked for a key (a `read-char`, and
          ;; `read-quoted-char` above all) gets the character the user
          ;; pressed. The raise lives one level up, in
          ;; `read_key_sequence_vs`'s `maybe_quit ()`
          ;; (`keyboard.c:12457`), and that is the command loop's and
          ;; `read-key-sequence`'s read - both call `maybe-quit` before
          ;; they read for exactly this reason. Putting it here as well
          ;; made a C-g that arrived between the command loop reading
          ;; C-q and `read-quoted-char` reading its character *raise*
          ;; instead of being the quoted character: `C-q C-g` was "Quit"
          ;; about a third of the time, measured at a pty.
          (let* ((unread (*unread-command-events*))
                   (ev (if (null? unread)
                           (begin
                             ;; **`read_char` redisplays before it
                             ;; waits** (`keyboard.c:2718-2723`: "Redisplay
                             ;; if no pending input", inside the loop that
                             ;; retries when input preempts the draw).
                             ;; That is what lets a command that is
                             ;; *waiting* for a key show what it changed:
                             ;; `help--help-screen` switches to *Metahelp*
                             ;; and then reads options, and without this
                             ;; the switch was the editor's state and never
                             ;; reached the terminal (measured - the
                             ;; window and buffer were right and the screen
                             ;; still showed the file).
                             (redisplay-frames!)
                             (let* ((raw (read-input-event
                                          (current-display)
                                          (if deadline
                                              (max 0 (- deadline (%now-ms)))
                                              timeout)))
                                    (key (and raw (key-event->key
                                                   (current-display) raw))))
                               (*last-read-event* raw)
                               ;; "Normally, last_nonmenu_event gets the
                               ;; previous key we read" - `read_key_
                               ;; sequence`'s line for every key it hands
                               ;; back (`keyboard.c:12216').
                               (record-nonmenu-event! raw key)
                               key))
                           (begin
                             (*unread-command-events* (cdr unread))
                             (let ((key (car unread)))
                               ;; A key put back on `unread-command-
                               ;; events' is still a key `read_key_
                               ;; sequence' returns, so it is recorded
                               ;; too - Emacs's loop does the same for
                               ;; an event it re-reads.
                               (record-nonmenu-event! #f key)
                               key)))))
              ;; **The flag is cleared here only when quitting was
              ;; inhibited** - `read_char`'s own rule (`keyboard.c:2824`:
              ;; "If we report the quit char as an event, don't do so
              ;; more than once", `if (!NILP (Vinhibit_quit))
              ;; Vquit_flag = Qnil;`). With quitting enabled the flag
              ;; stays set on purpose: the C-g is answered once to the
              ;; reader that asked (so `read-quoted-char` can finish a
              ;; digit sequence with it), and the *next* command-loop
              ;; read raises it as the quit it is - which is what makes
              ;; Emacs insert the code read so far and then say
              ;; "Quit". The command loop clears the flag itself after
              ;; every key it reads, as `read_key_sequence` does
              ;; (`keyboard.c:11892`). A real C-g key (a Gtk frame's)
              ;; leaves the flag #f and this is a no-op.
              (when (and (eqv? ev quit-char) (*quit-flag*)
                         (*inhibit-quit*))
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

    (define (sit-for seconds . rest)
      ;; GNU Emacs's `sit-for' (`subr.el:3836'): "Redisplay, then wait
      ;; for SECONDS seconds; stop when input is available. ... Value is
      ;; t if waited the full time with no input arriving, and nil
      ;; otherwise." NODISP is `&optional` in Emacs - `(sit-for 2)` is
      ;; the ordinary call - so it is a rest parameter here; a required
      ;; one made the answer loop's pause an arity error.
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
      (let ((nodisp (if (pair? rest) (car rest) #f)))
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
                  #t)))))

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

    (define *last-nonmenu-event* (make-parameter #f))
    ;; ^ GNU Emacs's `last-nonmenu-event' (`keyboard.c:14307'): "Last
    ;; input event in a command, except for mouse menu events. Mouse
    ;; menus give back keys that don't look like mouse events; this
    ;; variable holds the actual mouse event that led to the menu, so
    ;; that you can determine whether the command was run by mouse or
    ;; not."
    ;;
    ;; **`read_key_sequence` sets it to every key it reads**
    ;; (`keyboard.c:12216': "last_nonmenu_event gets the previous key we
    ;; read. But when a mouse popup menu is being used, we don't update
    ;; last_nonmenu_event; it continues to hold the mouse event that
    ;; preceded the first level of menu"), and a menu's own key events
    ;; are *conses* rather than plain keys (`keyboard.c:10673' turns
    ;; each unread menu key into `(KEY . disabled)'). That is what
    ;; `next-read-file-uses-dialog-p' and `use-dialog-box-p' test:
    ;; `CONSP' means the command came from a mouse or a menu, a plain
    ;; key means it came from the keyboard.
    ;;
    ;; This tree's front ends tag a menu's keys `(menu-bar-event . KEY)'
    ;; and `(tool-bar-event . KEY)', and a mouse event's display value
    ;; is already the list `subr.scm''s `posn-' accessors walk - so the
    ;; *raw* event is what answers "was this from the mouse", and the
    ;; key is only what a keymap was looked up by.
    (define (record-nonmenu-event! raw key)
      ;; The `last_nonmenu_event = key' of `read_key_sequence'
      ;; (`keyboard.c:12216'), called by every path that hands a key to
      ;; the command loop: the read below, `dispatch-input-event', and
      ;; the Gtk front end's queue drain - which is that front end's
      ;; stand-in for a read, so it must record the same fact.
      ;;
      ;; RAW is the display's own event and KEY what it decodes to (see
      ;; `*last-read-event*' above for why the two exist).
      ;;--------------------------------------------------------------
      (when key
        (*last-nonmenu-event*
         (if (pair? raw) raw key))))

    (define double-click-fuzz 3)
    ;; ^ GNU Emacs's `double-click-fuzz' (`keyboard.c:14449', a
    ;; DEFVAR_INT, default 3): "How many pixels the mouse can move between
    ;; press and release and still be treated as a click rather than a
    ;; drag. Zero means a click must be perfectly still." It is a plain
    ;; variable, not a parameter, because nothing `let`-binds it in
    ;; Emacs - it is read where the button release is made
    ;; (`keyboard.c:6668-6682'), which is the front end's job and is why
    ;; `pgtk.scm` imports it.
    ;;
    ;; The sibling this tree does not need yet is `double-click-time`:
    ;; double- and triple-click events are not made by either front end
    ;; (there is no click clock), so nothing here reads a click count.

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
             ;; guarded only the command, so a quit raised by the read -
             ;; `maybe-quit` below, for a C-g that arrived between one
             ;; command and the next read - escaped and exited the editor
             ;; (measured: SIGINT, then the process gone with a
             ;; `%quit-condition' throw). The handler reports it and the
             ;; loop goes on reading, which is what `cmd_error` does.
             ;; **The redisplay after an error is the loop's, as it is
             ;; Emacs's**: `cmd_error` reports and returns to
             ;; `command_loop_1`, which redisplays before it reads again.
             ;; Without it a command that raised part-way - a C-g over
             ;; the *Completions* window is the one measured - left the
             ;; screen showing what the aborted command had drawn, and
             ;; the window it had made stayed there until the next key.
             (guard (ex (else (report-command-error! frame ex)
                              (redisplay-frames!)))
             ;; **`read_key_sequence_vs` opens with `maybe_quit ()`**
             ;; (`keyboard.c:12457`): "a quit recorded since the last
             ;; read is signalled now", which is what makes a C-g that
             ;; arrived while a command was running take effect at the
             ;; next read. It is here and not in `read-key-event'
             ;; because `read-key-event' is `read_char', and
             ;; `read_char` *answers* a pending C-g as `quit_char`
             ;; instead (`keyboard.c:2817`) - a reader such as
             ;; `read-quoted-char` needs the character, not a quit.
             ;; **The guard wraps it too**, as Emacs's `command_loop_1`
             ;; condition-case wraps `read_key_sequence`.
             (maybe-quit)
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
               ;; **`read_key_sequence` clears `Vquit_flag` after every
               ;; key it reads** (`keyboard.c:11892`). The C-g above may
               ;; have arrived as a `quit_char` during the wait; the key
               ;; itself still goes through the keymaps (which is how a
               ;; menu consumes it as `tty-menu-exit`), and the flag
               ;; must not fire a second time at the *next* read - that
               ;; double quit is what used to exit the editor.
               (*quit-flag* #f)
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
                ;; **`(let ((inhibit-quit first)) ... (if inhibit-quit
                ;; (setq quit-flag nil)))`** (`simple.el:1002`,
                ;; `:1013`). The read is a `read-char`'s: a C-g that
                ;; arrives now is *answered* as `quit_char' by
                ;; `read-key-event' (`read_char`'s own rule) and is the
                ;; character C-q quotes. Inhibiting quitting for the
                ;; first read is what keeps `maybe_quit`-style code from
                ;; turning it into a quit on the way through, and the
                ;; clear afterwards is the C's, for the case where the
                ;; flag was already set when the read began. With
                ;; `first' past, a C-g is an ordinary terminator here -
                ;; it is pushed back and the code read so far is
                ;; returned; the *next* command-loop read raises the
                ;; flag as the quit it is, which is Emacs's "finish the
                ;; character, then quit".
                (let* ((inhibit-quit first)
                       (key (parameterize ((*inhibit-quit* inhibit-quit))
                              (read-key-event -1))))
                  (when inhibit-quit
                    (*quit-flag* #f))
                  ;; Emacs's `(lookup-key local-function-key-map (vector
                  ;; char))': RET is 13 and TAB 9 whichever display sent
                  ;; them, and `function-key-translate' is this tree's
                  ;; step for that (and for the events a Gtk frame names
                  ;; by symbol).
                  (let* ((translated (and key (function-key-translate key)))
                         (code-read (and (integer? translated) translated)))
                    (cond
                     ;; `((null translated))': nothing that is a
                     ;; character - ask again.
                     ((not translated) #f)
                     ;; `((not (integerp translated)) (setq
                     ;; unread-command-events (list char) done t)':
                     ;; a function key is used itself as input.
                     ((not code-read)
                      (*unread-command-events*
                       (cons key (*unread-command-events*)))
                      (set! done #t))
                     ;; "Turn a meta-character into a character with
                     ;; the 0200 bit set."
                     ((not (= 0 (logand code-read char-meta)))
                      (set! code (logior (logand code-read (lognot char-meta))
                                         128))
                      (set! done #t))
                     ;; "if the first character read is an octal
                     ;; digit, we read any number of octal digits" -
                     ;; and decimal and hex, by `read-quoted-char-radix'.
                     ((and (<= (char->integer #\0) code-read)
                           (< code-read (+ (char->integer #\0)
                                           (min 10 radix))))
                      (set! code (+ (* code radix)
                                    (- code-read (char->integer #\0))))
                      (when prompt
                        (set! prompt
                              (format #f "~a ~a" prompt
                                      (integer->char code-read)))
                        (set!frame-message frame prompt)))
                     ((and (<= (char->integer #\a)
                               (char->integer
                                (char-downcase (integer->char code-read))))
                           (< (char->integer
                               (char-downcase (integer->char code-read)))
                              (+ (char->integer #\a) -10 (min 36 radix))))
                      (set! code (+ (* code radix)
                                    (+ 10 (- (char->integer
                                              (char-downcase
                                               (integer->char code-read)))
                                             (char->integer #\a)))))
                      (when prompt
                        (set! prompt
                              (format #f "~a ~a" prompt
                                      (integer->char code-read)))
                        (set!frame-message frame prompt)))
                     ;; RET after the first digit terminates and is
                     ;; discarded; before that it is the character.
                     ((and (not first)
                           (eqv? translated
                                 (event-convert-list '(control #\m))))
                      (set! done #t))
                     ;; any other terminator after the first digit is
                     ;; used itself as input: pushed back for the
                     ;; caller, and its code read
                     ((not first)
                      (*unread-command-events*
                       (cons key (*unread-command-events*)))
                      (set! done #t))
                     ;; the first character, not a digit: it is the
                     ;; answer
                     (else
                      (set! code code-read)
                      (set! done #t)))
                    ;; `(setq first nil)' at the end of every
                    ;; iteration, as the C has it.
                    (set! first #f)
                    (loop)))))))

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

    (define (%where-is-value x)
      ;; **A symbol on one side, a value on the other.** Elisp's keymaps
      ;; hold the command *symbol*, so the C's `EQ (binding, definition)'
      ;; compares like with like. This tree's keymaps hold the value
      ;; `define-command` made, while a menu item may still name its
      ;; command as the symbol the C would - `(menu-item "Save"
      ;; save-buffer)'. Resolving the symbol through the command table
      ;; makes both sides values; anything that names no command is left
      ;; as it is, so two identical symbols still compare equal.
      ;;--------------------------------------------------------------
      (if (symbol? x)
          (let ((record (command-record-named x)))
            (if record (command-value-of record) x))
          x))

    (define (where-is-internal-1 definition key binding this last last-is-meta
                                 noindirect)
      ;; GNU Emacs's `where_is_internal_1` (`keymap.c:2787`): the sequence
      ;; that reaches BINDING through THIS with KEY on the end, or #f when
      ;; BINDING is not DEFINITION. The C pushes onto a list; this
      ;; answers, and the caller conses.
      ;;--------------------------------------------------------------
      (let ((binding (%where-is-value
                      (if noindirect binding (km:get-keyelt binding #f)))))
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
               ((not (equal? (%where-is-value
                              (%shadow-lookup keymaps sequence))
                             definition))
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

    ;;----------------------------------------------------------------
    ;; The help echo - `show_help_echo` (`keyboard.c:2259`)
    ;;----------------------------------------------------------------

    (define *show-help-function* (make-parameter #f))
    ;; ^ GNU Emacs's `show-help-function` (`keyboard.c:14824`): "Function
    ;; to call to display help for menu or tool bar item, if mouse is
    ;; over it. It is called with the help string as argument. If nil,
    ;; the echo area is used."
    ;;
    ;; **A parameter, not a plain variable.** Emacs `defvar`s it and only
    ;; `setq`s it (tooltip.el, tty-tip.el, pc-win.el); here it is written
    ;; by `tooltip.scm`, which imports this library, and the tree's
    ;; cross-library spelling for a variable another library assigns is a
    ;; parameter - the seam convention. Read as `(*show-help-function*)`.

    (define *help-echo-substitute-function* (make-parameter (lambda (help) help)))
    ;; ^ The seam `help-echo-substitute-command-keys` substitutes
    ;; through. `substitute-command-keys` is `help.scm`'s, which imports
    ;; this library, so it arrives from above as a parameter that library
    ;; installs at load - the `*barf-if-buffer-read-only-function*` shape.
    ;; The default carries the string through unchanged, which is what a
    ;; session with no help library gets.

    (define *mouse-fixup-help-message-function* (make-parameter (lambda (msg) msg)))
    ;; ^ `mouse-fixup-help-message` (`mouse.el:1894`) is `mouse.scm`'s,
    ;; and `mouse.scm` imports this library - so `show-help-echo` reaches
    ;; it through this parameter, which that library installs at load.

    (define (help-echo-substitute-command-keys help)
      ;; GNU Emacs's `help_echo_substitute_command_keys`
      ;; (`keyboard.c:2219`): "Substitute key descriptions and quotes in
      ;; HELP, unless its first character has a non-nil
      ;; `help-echo-inhibit-substitution' property."
      ;;
      ;; The inhibit test needs `get-text-property` on a string, which is
      ;; `textprop.scm`'s and above this library, so it is applied by the
      ;; seam's installer (`help.scm`) and not here. The answer is used
      ;; both by `show_help_echo` below and by menu item parsing
      ;; (`parse_menu_item`'s `:help`).
      ;;--------------------------------------------------------------
      (if (string? help)
          ((*help-echo-substitute-function*) help)
          help))

    (define (%show-help help)
      ;; The half of `show_help_echo` that runs once HELP is known to be a
      ;; string or nil. `mouse-fixup-help-message` is applied to a string
      ;; only - "The `mouse-fixup-help-message' Lisp function can call
      ;; `mouse_position_hook', which resets the `mouse_moved' flags" -
      ;; and the display function is called with the substituted text.
      ;;--------------------------------------------------------------
      (when (string? help)
        (set! help ((*mouse-fixup-help-message-function*) help)))
      (let ((function (*show-help-function*)))
        (when function
          (function (help-echo-substitute-command-keys help)))))

    (define (show-help-echo help window object pos)
      ;; GNU Emacs's `show_help_echo` (`keyboard.c:2259`): "Display the
      ;; help-echo property of the character after the mouse pointer.
      ;; Either show it in the echo area, or call `show-help-function' to
      ;; display it by other means (maybe in a tooltip)."
      ;;
      ;; HELP may be a string, a function, or a form:
      ;;
      ;;   "If HELP is nil, that means clear the previous help echo.
      ;;    If HELP is a string, display that string. If HELP is a
      ;;    function, call it with OBJECT and POS as arguments; the
      ;;    function should return a help string or nil for none. For all
      ;;    other types of HELP, evaluate it to obtain a string."
      ;;
      ;; WINDOW, OBJECT and POS are the C's: the window the help was
      ;; generated in, the object it was found in (a buffer, an overlay,
      ;; a display string, or nil), and the position within it. The
      ;; errors a bad function or form raises are swallowed, as the C's
      ;; `safe_calln`/`safe_eval` swallow them - this runs from a Gtk
      ;; signal handler, where a raise is fatal.
      ;;--------------------------------------------------------------
      (cond
       ((or (not help) (string? help)) (%show-help help))
       (else
        (let ((value (guard (ex (#t #f))
                       (if (procedure? help)
                           (help window object pos)
                           (eval help (current-module))))))
          ;; "If HELP is not a string, return without doing anything" -
          ;; the C's early return, which is *not* a clear: a function
          ;; that answers nil for this position leaves whatever was
          ;; showing in place.
          (when (string? value)
            (%show-help value))))))

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

    ;;----------------------------------------------------------------
    ;; The tool bar - keyboard.c's `tool_bar_items` and its parser
    ;;----------------------------------------------------------------
    ;;
    ;; GNU Emacs's `tool_bar_items` (`keyboard.c:10135`) is a sibling of
    ;; `menu_bar_items` above: the `[tool-bar]` bindings of the active
    ;; maps, parsed into items - but at twelve slots per item
    ;; (`dispextern.h:3453`'s `enum tool_bar_item_idx`) rather than the
    ;; menu bar's four, and with a parser of its own because a tool bar
    ;; item carries an *image*, a label and a `:vert-only` flag that a
    ;; menu item has no notion of. The widget half is the Gtk front
    ;; end's (`pgtk.scm`, after `gtkutil.c`'s `update_frame_tool_bar`);
    ;; only a toolkit-less build draws a text bar, and a Gtk build has
    ;; no tool bar on a terminal at all (`display_tool_bar` is compiled
    ;; out under `HAVE_EXT_TOOL_BAR`).

    (define tool-bar-item-key 0)
    (define tool-bar-item-enabled-p 1)
    (define tool-bar-item-selected-p 2)
    (define tool-bar-item-caption 3)
    (define tool-bar-item-images 4)
    (define tool-bar-item-binding 5)
    (define tool-bar-item-type 6)
    (define tool-bar-item-help 7)
    (define tool-bar-item-rtl-image 8)
    (define tool-bar-item-label 9)
    (define tool-bar-item-vert-only 10)
    (define tool-bar-item-wrap 11)
    (define tool-bar-item-nslots 12)
    ;; ^ The C's `TOOL_BAR_ITEM_*` enum and `TOOL_BAR_ITEM_NSLOTS`
    ;; (`dispextern.h:3453-3495`).

    (define tool-bar-max-label-size 14)
    ;; ^ `tool_bar_max_label_size` (a DEFVAR_INT in `xdisp.c:39016`, whose
    ;; initializer is `DEFAULT_TOOL_BAR_LABEL_SIZE`, `dispextern.h:3510`):
    ;; "Maximum number of characters a label can have to be shown." A
    ;; plain variable - nothing `let`-binds it - carrying the
    ;; self-assignment the compiler needs so a user's `set!` is not
    ;; folded away (the `*enable-disabled-menus-and-buttons*` rule).
    ;;
    ;; **It was 10, and that is why the isearch tool bar showed no
    ;; labels at all.** `parse_tool_bar_item` makes a label out of the
    ;; item's caption and sets it to the empty string when it is longer
    ;; than this (`keyboard.c:10555`); "Repeat Forward" is exactly 14
    ;; characters, so with 10 every isearch item's label was discarded
    ;; while real Emacs showed "Repeat Forward" (and not "Repeat
    ;; Backward", which is 15). Measured: `(prin1
    ;; tool-bar-max-label-size)` in `emacs -Q --batch` answers 14.
    (set! tool-bar-max-label-size tool-bar-max-label-size)

    (define *tool-bar-item-properties* (make-vector tool-bar-item-nslots #f))

    (define (%tool-bar-default-label caption key)
      ;; The C's "Try to make one from caption and key"
      ;; (`keyboard.c:10480`): a label no wider than
      ;; `tool-bar-max-label-size`, built from the caption when that is
      ;; short enough and from the key's name otherwise, with `-` read
      ;; as a space and each word's initial upcased.
      ;;
      ;; MAX-LBL-SIZE is the C's `2 * max (0, min
      ;; (tool_bar_max_label_size, STRING_BYTES_BOUND / 2)) + 1`: a
      ;; caption at least that long leaves the key's name as the base.
      ;;--------------------------------------------------------------
      (let* ((capt (if (string? caption) caption ""))
             (max-size (+ 1 (* 2 (max 0 tool-bar-max-label-size))))
             (base
              (if (and (> (string-length capt) 0)
                       (< (string-length capt) max-size))
                  ;; Strip the trailing dots: "Save...".
                  (let loop ((s capt))
                    (if (and (> (string-length s) 0)
                             (char=?
                              (string-ref s (- (string-length s) 1)) #\.))
                        (loop (substring s 0 (- (string-length s) 1)))
                        s))
                  (if (symbol? key) (symbol->string key) "")))
             (base
              (if (and (> (string-length base) 0)
                       (< (string-length base) max-size))
                  (list->string
                   (map (lambda (c) (if (char=? c #\-) #\space c))
                        (string->list base)))
                  ""))
             (up (upcase-initials base)))
        (if (<= (string-length up) tool-bar-max-label-size) up "")))

    (define (parse-tool-bar-item key item)
      ;; GNU Emacs's `parse_tool_bar_item` (`keyboard.c:10312`): "Parse
      ;; a tool bar item specification ITEM for key KEY and return the
      ;; result in tool_bar_item_properties."
      ;;
      ;; **`HAVE_EXT_TOOL_BAR` is this build.** The Gtk front end has a
      ;; toolkit widget, so the toolkit-less branches are not carried:
      ;; a separator carries no image expression (the widget is a
      ;; `GtkSeparatorToolItem`), and `:wrap` answers false - the C's
      ;; own `return false` under that flag, "Line wrapping isn't
      ;; supported on builds utilizing external tool bars".
      ;;--------------------------------------------------------------
      (and
       (pair? item)
       (let/ec return
         (let ((props *tool-bar-item-properties*))
           ;; "As an exception, allow old-style menu separators." The
           ;; C's two branches: a string is made a one-element list and
           ;; carries on; anything else must be a `menu-item` and is
           ;; advanced past that symbol.
           (cond ((string? (car item)) (set! item (list (car item))))
                 ((not (eq? (car item) 'menu-item)) (return #f))
                 (else
                  (set! item (cdr item))
                  (unless (pair? item) (return #f))))
           ;; Reset to defaults.
           (let loop ((i 0))
             (when (< i tool-bar-item-nslots)
               (vector-set! props i #f)
               (loop (+ i 1))))
           (vector-set! props tool-bar-item-key key)
           (vector-set! props tool-bar-item-enabled-p #t)
           ;; The caption is what is first, for a menu item and a
           ;; normalized separator alike - the C's `caption = XCAR
           ;; (item)` after its two branches.
           (let ((caption (car item)))
             (unless (string? caption)
               (set! caption (menu-item-eval-property caption)))
             (unless (string? caption) (return #f))
             (vector-set! props tool-bar-item-caption caption)
             (set! item (cdr item))
             (if (not (pair? item))
                 ;; "If the rest following the caption is not a list,
                 ;; the menu item is either a separator, or invalid."
                 (if (menu-separator-name? caption)
                     (begin (vector-set! props tool-bar-item-type #t) #t)
                     #f)
                 (begin
                   (vector-set! props tool-bar-item-binding (car item))
                   (set! item (cdr item))
                   ;; "Ignore cached key binding, if any."
                   (when (and (pair? item) (pair? (car item)))
                     (set! item (cdr item)))
                   (let ((filter #f) (have-label #f))
                     (let loop ((rest item))
                       (when (pair? rest)
                         (let ((ikey (car rest)))
                           (set! rest (cdr rest))
                           (when (pair? rest)
                             (let ((value (car rest)))
                               (cond
                                ((eq? ikey ':enable)
                                 ;; "`--enable-disabled-menus-and-buttons'
                                 ;; overrides the :enable property."
                                 (vector-set!
                                  props tool-bar-item-enabled-p
                                  (if *enable-disabled-menus-and-buttons*
                                      #t value)))
                                ((eq? ikey ':visible)
                                 ;; "If got a visible property and that
                                 ;; evaluates to nil then ignore this item."
                                 (unless (menu-item-eval-property value)
                                   (return #f)))
                                ((eq? ikey ':help)
                                 (vector-set! props tool-bar-item-help value))
                                ((eq? ikey ':vert-only)
                                 (vector-set! props tool-bar-item-vert-only value))
                                ((eq? ikey ':label)
                                 (vector-set!
                                  props tool-bar-item-label
                                  (if (string? value)
                                      value
                                      "!!?GARBLED ITEM?!!"))
                                 (set! have-label #t))
                                ((eq? ikey ':filter) (set! filter value))
                                ((and (eq? ikey ':button) (pair? value))
                                 (let ((type (car value))
                                       (selected (cdr value)))
                                   (when (memq type '(:toggle :radio))
                                     (vector-set! props
                                                  tool-bar-item-selected-p
                                                  selected)
                                     (vector-set! props tool-bar-item-type
                                                  type))))
                                ((and (eq? ikey ':image)
                                      (or (pair? value)
                                          (and (vector? value)
                                               (= (vector-length value) 4))))
                                 (vector-set! props tool-bar-item-images value))
                                ((eq? ikey ':rtl)
                                 (vector-set! props tool-bar-item-rtl-image
                                              value))
                                ((eq? ikey ':wrap)
                                 ;; `HAVE_EXT_TOOL_BAR`.
                                 (return #f)))
                               (loop (cdr rest)))))))
                     (unless have-label
                       (vector-set!
                        props tool-bar-item-label
                        (%tool-bar-default-label
                         (vector-ref props tool-bar-item-caption)
                         (vector-ref props tool-bar-item-key))))
                     ;; "If got a filter apply it on binding."
                     (when filter
                       (vector-set!
                        props tool-bar-item-binding
                        (menu-item-eval-property
                         (list filter
                               (list 'quote
                                     (vector-ref props
                                                 tool-bar-item-binding))))))
                     ;; "See if the binding is a keymap. Give up if it is."
                     (when (km:keymapp (vector-ref props tool-bar-item-binding))
                       (return #f))
                     ;; "If there is a key binding, add it to the help,
                     ;; which will be displayed as a tooltip for this
                     ;; entry."
                     (let* ((binding (vector-ref props tool-bar-item-binding))
                            (keys (where-is-internal binding #f #t #f #f)))
                       (when keys
                         (let ((orig (vector-ref props tool-bar-item-help)))
                           (unless orig
                             (set! orig (vector-ref props
                                                    tool-bar-item-caption)))
                           (vector-set!
                            props tool-bar-item-help
                            (string-append orig "  ("
                                           (key-description keys) ")")))))
                     ;; "Enable or disable selection of item."
                     (let ((enabled (vector-ref props tool-bar-item-enabled-p)))
                       (unless (eq? enabled #t)
                         (vector-set!
                          props tool-bar-item-enabled-p
                          (menu-item-eval-property enabled))))
                     ;; "Handle radio buttons or toggle boxes."
                     (let ((selected (vector-ref props
                                                 tool-bar-item-selected-p)))
                       (when selected
                         (vector-set!
                          props tool-bar-item-selected-p
                          (menu-item-eval-property selected))))
                     #t))))))))

    (define (tool-bar-collect-items keymap items)
      ;; One map's `[tool-bar]' submap walked into ITEMS - the C's
      ;; `process_tool_bar_item` with `map_keymap` over it.
      ;;
      ;; **Unlike a tab or a menu bar entry, a tool bar item is
      ;; *appended*, not replaced**: "Accept more than one definition
      ;; for the same key" (`keyboard.c:10245`) - the local map's item
      ;; and the global map's both show, the specific one first. An
      ;; explicit `undefined` removes the earlier item.
      ;;--------------------------------------------------------------
      (km:map-keymap
       (lambda (key item)
         (cond ((eq? item 'undefined)
                (set! items
                      (filter (lambda (quad) (not (eq? (car quad) key))) items)))
               (else
                (when (parse-tool-bar-item key item)
                  (set! items
                        (append items
                                (list (vector->list
                                       *tool-bar-item-properties*))))))))
       keymap)
      items)

    (define (tool-bar-items)
      ;; GNU Emacs's `tool_bar_items` (`keyboard.c:10135`): "Return a
      ;; vector of tool bar items for keymaps currently in effect."
      ;; The answer is the list of twelve-element items; the redisplay
      ;; flattens it into the frame's vector, as it does the tab bar's.
      ;;
      ;; **The keymap is rebuilt first**, for the reason `tab-bar-items`
      ;; gives: the C reaches it through `[tool-bar]`'s `:filter`
      ;; (`get_keyelt`'s `menu_item_eval_property` arm) and this tree's
      ;; keymap lookup does not apply filters - `tool-bar-make-keymap`
      ;; is `tool-bar.el`'s and arrives through the seam.
      ;;--------------------------------------------------------------
      (when (*tool-bar-keymap-function*)
        ((*tool-bar-keymap-function*)))
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
                 (let ((def (km:keymap-lookup (car rest) 'tool-bar)))
                   (loop (cdr rest)
                         (if (km:keymap-type? def)
                             (tool-bar-collect-items
                              (keymap-canonicalize def) items)
                             items))))))))

    (define-key *default-keymap* (kbd "C-q") quoted-insert)

    ;; The redisplay's seam: `menu_bar_items` is this library's
    ;; (`keyboard.c:8641`) and `update_menu_bar` is `xdisp.c`'s, which is
    ;; *below* here - so the redisplay asks for the items through this.
    (*menu-bar-items-function* menu-bar-items)
    (*tab-bar-items-function* tab-bar-items)
    (*tool-bar-items-function* tool-bar-items)

    
    (*read-char-event-function* read-char-event)
    (*read-key-sequence-function* read-key-sequence)
    (*read-key-sequence-vector-function* read-key-sequence-vector)
    ;; ^ The `k' and `K' interactive codes' readers. Beside
    ;; `read-char-event` above, for the same reason: this library defines
    ;; them, so the install has to come after the definitions.
    ;; ^ The `c' interactive code's reader (`keyboard.c`'s `read-char`,
    ;; spelled `read-char-event` here). **It is installed at the end of
    ;; the file, not beside `*barf-if-buffer-read-only-function*` above**,
    ;; because `read-char-event` is *this library's* and a `define` at
    ;; the top of the file has not run when a form above it is
    ;; evaluated - measured, the install raised "Unbound variable:
    ;; read-char-event" and thirty suites died at load. The same rule as
    ;; `define-key` after the command it binds: a binding resolves when
    ;; the form runs.

    ;; The redisplay's help-echo seam: `note_mouse_highlight` is
    ;; `xdisp.c`'s and `show_help_echo` is this library's, which imports
    ;; it - so the redisplay calls back up through this parameter, as it
    ;; does for the menu bar's items.
    (*show-help-echo-function* show-help-echo)

    ))