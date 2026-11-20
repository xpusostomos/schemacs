(define-library (schemacs editor mouse)
  ;; This library mirrors GNU Emacs's `mouse.el': the commands a mouse
  ;; event runs.
  ;;
  ;; **The click and the drag are here.** Pressing `[down-mouse-1]`
  ;; selects the window the press landed in and puts point where it
  ;; landed - Emacs's own order and not a shortcut: `mouse-drag-track'
  ;; calls `mouse-set-point' in its `let*' (`mouse.el:1939', "let's jump
  ;; to the place of the event, where things are happening") *before* it
  ;; reads a single motion event. Dragging then moves the region from
  ;; there: the mark goes down with the press, each motion event moves
  ;; point to where the pointer is (Emacs's `mouse--drag-set-mark-and-
  ;; point', `mouse.el:2044'), and the release leaves the region active.
  ;; The front end delivers motion events for this - `pgtk.sld' asks for
  ;; `GDK_POINTER_MOTION_MASK' beside the button masks.
  ;;
  ;; **And dragging past the edge of the window scrolls it**, which is
  ;; what makes a selection longer than a screen possible: when a motion
  ;; event has left the window, `mouse-scroll-subr' (`mouse.el:1708')
  ;; scrolls by the rows the pointer is past the edge and repeats every
  ;; `mouse-scroll-delay' until some input arrives. That is Emacs's
  ;; function and Emacs's arithmetic; what it is built on, `vertical-motion'
  ;; (`indent.c:2207'), is in `xdisp.sld' - see the note there.
  ;;
  ;; Still not here, named so that it is not mistaken for done:
  ;;
  ;;   the click count, and so the word a double click is on and the line
  ;;   a triple click is on  - `mouse-start-end''s modes 1 and 2, which
  ;;                       need a clock to count with. Every event this
  ;;                       tree makes is a single click, so only mode 0
  ;;                       is reachable and only mode 0 is ported.
  ;;   `mouse-drag-and-drop-region', `mouse-leave-buffer-hook',
  ;;   `mouse-drag-copy-region' (nil in Emacs anyway)
  ;;   `mouse-face' highlighting
  ;;   the mode-line, scroll-bar and fringe areas - `posn-area''s other
  ;;                       answers, and the bindings in `bindings.el'
  ;;   `mouse-autoselect-window' - the hover half, a different mechanism
  ;;   `mouse-minibuffer-check''s `mouse-leave-buffer-hook' half - the
  ;;                       hook is not carried; the refusal itself is,
  ;;                       adapted to a tree with no minibuffer window
  (import
    (scheme base)
    ;; `inexact->exact` is Guile's, not `(scheme base)`'s - the echo-row
    ;; test in `mouse-minibuffer-check` needs it to compare a cell row
    ;; that arrived as an inexact number.
    (only (guile) format inexact->exact string<)
    ;; `posn-set-point' is `subr.el''s and lives here because it needs
    ;; the two below, and `(schemacs editor subr)' is beneath both of
    ;; them and cannot reach either - see the note on the posn cluster
    ;; there.
    (only (schemacs editor subr) event-start event-end posn-point posn-window
          posn-x-y
          ;; where the pointer is, which a drag that has left its window
          ;; asks for
          ;; where a release lands if the tracking loop did not eat it
          ignore)
    (only (schemacs editor frame)
          frame? frame-height frame-selected-window mouse-position
          window-type? selected-window
          select-window selected-window set-window-start! window-buffer
          window-edges window-height window-point window-type?
          ;; `mouse-minibuffer-check` asks whether a prompt is up: the
          ;; echo area is this tree's minibuffer window.
          *echo-area-buffer* minibuffer-window-active-p window-minibuffer-p
          ;; the mode-line drag and the clicks beside it (`mouse.el`'s
          ;; drag and select/delete commands)
          mouse-position-in-root-frame mouse-absolute-pixel-position
          window-frame tty-type frame-char-height frame-char-width
          frame-parameter frame-width window-live-p minibuffer-window
          *resize-mini-windows* selected-frame select-frame raise-frame
          set-mouse-position)
    (only (schemacs editor editfns) goto-char point message)
    ;; The mark a drag sets, and the region it leaves active:
    ;; `push-mark', `pop-mark', `activate-mark' and `region-active-p' are
    ;; simple.el's. `push-mark' and not `set-mark', which is Emacs's own
    ;; call in `mouse-drag-track': the mark that was there goes on the
    ;; ring rather than being lost.
    (only (schemacs editor simple)
          push-mark pop-mark set-mark deactivate-mark
          ;; `mark` is `simple.el:7062`'s, where Emacs has it, and
          ;; `mouse--drag-set-mark-and-point` calls it three times over.
          ;; **This file used to keep a second, private `(mark)`** that
          ;; answered `(text-editor-mark (current-buffer))` and never
          ;; signalled - a duplicate that could not show you it
          ;; disagreed. It is gone; the transient-mark test is Emacs's.
          mark)
    (only (schemacs editor buffer)
          buffer-auto-hscroll-mode current-buffer set!buffer-auto-hscroll-mode
          set-buffer-local-value! transient-mark-mode)
    ;; ^ `set-buffer-local-value!' is also what clears the buffer's
    ;; deferred `deactivate-mark' flag below - it is a buffer-local
    ;; *variable* (`keyboard.c:14030') and not a slot of the buffer.
    ;; a drag repaints as it moves, which is what Emacs's tracking does
    ;; with `redisplay'.
    (only (schemacs editor xdisp)
          *mode-line-format* track-mouse vertical-motion
          window-end window-start posn-at-x-y
          ;; The mode-line menus: the two hooks `mouse-menu-major-mode-map`
          ;; runs, the toggles map and its sorter, the lighter two-step
          ;; `lookup-minor-mode-from-indicator` repeats, and the run a
          ;; click's flattened string is cut into.
          *activate-menubar-hook* *menu-bar-update-hook*
          mode-line-mode-menu bindings--sort-menu-keymap
          line-column-mode-menu
          minor-mode-indicator-value minor-mode-lighter
          minor-mode-variable-true? string-property-run-at)
    ;; `mouse-position' - the pointer's own frame row, which is what
    ;; decides whether a drag has left the window - is the display's
    ;; answer, so the display is what is asked.
    (only (schemacs editor keymap)
          define-key *default-keymap* make-sparse-keymap lookup-key keymapp
          set-keymap-parent map-keymap)
    ;; a sparse keymap to hand to `set-transient-map', which is Emacs's
    ;; `(make-sparse-keymap)' in that same place
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor subr) run-hooks)
    (only (schemacs editor character)
          kbd event-modifiers event-basic-type event-convert-list)
    ;; A command that reads its own keys waits the way the command loop
    ;; does, and `read-key-event' is the read every key comes through -
    ;; the same two calls `isearch' makes. `sit-for' is that same read
    ;; with a deadline, which is how the edge-of-window scrolling knows
    ;; a drag has moved on.
    (only (schemacs editor keyboard)
          set-transient-map sit-for *key-translation-map*
          ;; `show_help_echo` (`keyboard.c`) fixes a help string through
          ;; `mouse-fixup-help-message`, which is this file's; the seam
          ;; is installed at the bottom of this file.
          *mouse-fixup-help-message-function*
          ;; the display's own event value, which is where a motion
          ;; event's *position* is - `read-key-event' answers only the key
          *last-read-event*)
    (only (schemacs editor command)
          *last-command-event* current-prefix-arg define-command
          command-record-named)
    ;; The two `mouse-1-click-*` options are defcustoms.
    (only (schemacs editor custom) define-custom)
    ;; The buffer menu: the buffers, their mode names, and the popup that
    ;; shows them (`menu.c`'s `x_popup_menu`).
    (only (schemacs editor buffer)
          buffer-file-name buffer-list buffer-modified-p buffer-name
          buffer-read-only? with-current-buffer)
    ;; `expand-file-name` is `fileio.c`'s and `fileio.scm` defines it;
    ;; `files.scm` only re-exports it. Importing it from there rather
    ;; than from `files` keeps the cycle out: `files` loads
    ;; `(schemacs map-ynp)`, which needs `*query-replace-map*` from
    ;; `replace`, which loads `isearch` -> `help-fns` -> `help`, and
    ;; `help` imports this library.
    (only (schemacs editor fileio) expand-file-name)
    (only (schemacs editor window) switch-to-buffer
          window-resize-pixelwise window-left-sibling window-right-sibling
          adjust-window-trailing-edge window-at-side-p one-window-p
          delete-window delete-other-windows)
    (only (schemacs editor xdisp) format-mode-line)
    (only (schemacs editor buffer) buffer-local-value major-mode mode-name
          current-local-map)
    (only (schemacs editor menu) x-popup-menu)
    ;; `string-match` is `search.c`'s.
    (only (schemacs editor search) string-match)
    (only (guile) sort)
    (only (schemacs editor subr) nthcdr posn-area posn-string
          *minor-mode-alist* *minor-mode-map-alist* *minor-mode-list*
          string-replace posn-object
          ;; `subr.el`'s, used by `mouse-menu-non-singleton`.
          keymap-canonicalize)
    ;; `lookup-minor-mode-from-indicator` asks whether a lighter's mode
    ;; is on, the first of the two steps the mode line takes.
    (only (schemacs editor intervals) get)
    ;; `mouse-posn-property` reads the `follow-link` and `mouse-face`
    ;; *text* properties, and `get-char-property` is the overlay-aware
    ;; reader Emacs's own uses.
    (only (schemacs editor textprop) get-char-property get-text-property)
    ;; `key-binding` is the `[follow-link]` arm of `mouse-on-link-p`.
    (only (schemacs editor keyboard) key-binding)
    ;; `mouse--last-down` keeps a time, and the one question asked of it
    ;; is how many seconds ago it was.
    (only (schemacs editor timefns) current-time float-time)
    ;; `capitalize`, for the generated minor-mode menu's title.
    (only (schemacs editor casefiddle) capitalize)
    ;; **A seam, not an import.** `popup-menu` and `menu-bar-edit-menu`
    ;; are `menu-bar.scm`'s, and `menu-bar` imports `isearch`, which
    ;; imports `help-fns`, which imports `help`, which imports this
    ;; library - so importing it here is a cycle. `menu-bar.scm`
    ;; installs both through the parameters below as it loads.
    ;; `concat` keeps the string's properties and `%substring` is Emacs's
    ;; `substring`; both are what `mouse-fixup-help-message` rewrites the
    ;; help text with.
    (only (schemacs editor fns) concat %substring))

  (export *mouse-1-click-follows-link* *mouse-1-click-in-non-selected-windows*
          mouse-event-areas-with-no-buffer-positions mouse--last-down
          mouse--down-1-maybe-follows-link mouse--click-1-maybe-follows-link
          mouse-posn-property mouse-on-link-p mouse-fixup-help-message
          posn-set-point mouse-set-point mouse-drag-region mouse-drag-track
          mouse-minibuffer-check
          mouse-set-region mouse-start-end mouse--drag-set-mark-and-point
          mouse-scroll-subr mouse-set-region-1
          *mouse-scroll-delay* *mouse-scroll-min-lines*
          *mouse-buffer-menu-mode-groups*
          mouse-buffer-menu mouse-buffer-menu-map mouse-buffer-menu-alist
          mouse-buffer-menu-split
          *mouse-buffer-menu-mode-mult* *mouse-buffer-menu-maxlen*
          mark mouse-key?
          ;; `mouse.el`'s mode-line menus. The two parameters are the
          ;; seams `menu-bar.scm` installs; the commands are what the
          ;; mode name and the lighters are bound to.
          *popup-menu-function* *menu-bar-edit-menu*
          *describe-function-function*
          mouse-menu-non-singleton mouse-menu-major-mode-map
          mouse-menu-major-mode-menu mode-line-minor-mode-menu
          mode-line-line-column-menu
          lookup-minor-mode-from-indicator minor-mode-menu-from-indicator
          mouse-minor-mode-menu
          describe-minor-mode-completion-table-for-indicator)

  (begin

    (define *mouse-buffer-menu-mode-groups*
      '(("Info\|Help\|Apropos\|Man" . "Help")
        ("\\bVM\\b\\|\\bMH\\b\\|Message\\b\\|Mail\\|Group\\|Score\\|Summary\\|Article"
         . "Mail/News")
        ("\\<C\\>" . "C")
        ("ObjC" . "C")
        ("Text" . "Text")
        ("Outline" . "Text")
        ("\\(HT\\|SG\\|X\\|XHT\\)ML" . "SGML")
        ("\\blog\\b\\|diff\\|\\bvc\\b\\|cvs\\|Git\\|Annotate" . "Version Control")
        ("Threads\\|Memory\\|Disassembly\\|Breakpoints\\|Frames\\|Locals\\|Registers\\|Inferior I/O\\|Debugger"
         . "GDB")
        ("Lisp" . "Lisp")))
    ;; ^ GNU Emacs's `mouse-buffer-menu-mode-groups` (`mouse.el:2831`):
    ;; "How to group various major modes together in
    ;; \\[mouse-buffer-menu]. Each element has the form (REGEXP .
    ;; GROUPNAME). If the major mode's name string matches REGEXP, use
    ;; GROUPNAME instead."
    ;;
    ;; `tab-line.el` binds this as the default of
    ;; `tab-line-tabs-buffer-groups`, which is why it lives here ahead of
    ;; the menu that reads it.

    ;;----------------------------------------------------------------
    ;; Where a mouse event happened
    ;;------------------------------------------------------------------

    (define (mouse-minibuffer-check event)
      ;; GNU Emacs's `mouse-minibuffer-check` (`mouse.el:768`): refuse a
      ;; mouse event that landed in a minibuffer window that is not
      ;; active, then let temporary modes - an isearch, say - turn off.
      ;;
      ;;   (let ((w (posn-window (event-start event))))
      ;;     (and (windowp w)
      ;;          (window-minibuffer-p w)
      ;;          (not (minibuffer-window-active-p w))
      ;;          (user-error "Minibuffer window is not active")))
      ;;   (run-hooks 'mouse-leave-buffer-hook)
      ;;
      ;; This is the C's test now, not a stand-in for it: the echo area is
      ;; a real minibuffer window (`frame-minibuffer-window`), so
      ;; `posn-at-x-y` names it when it is active and the frame when it is
      ;; not. **`window-minibuffer-p` and the active test are the same
      ;; question here** - the frame has exactly one minibuffer window, so
      ;; being it means being the frame's, and `minibuffer-window-active-p`
      ;; is what says whether a prompt is being read in it.
      ;;
      ;; Not carried: `mouse-leave-buffer-hook`, which no caller here
      ;; registers on.
      ;;--------------------------------------------------------------
      (let ((w (posn-window (event-start event))))
        (when (and (window-type? w)
                   (window-minibuffer-p w)
                   (not (minibuffer-window-active-p w)))
          (error "Minibuffer window is not active"))))

    (define (posn-set-point position)
      ;; GNU Emacs's `posn-set-point' (`subr.el:2013'): move point to
      ;; POSITION, selecting the corresponding window as well.
      ;;
      ;; **This is the whole of "clicking in a window activates it".**
      ;; The press carries the window it happened in and a buffer
      ;; position inside it, and the two steps below are what Emacs does
      ;; with them - `select-window', then `goto-char'.
      ;;
      ;; Which window is selected matters twice over here: `select-window'
      ;; is this tree's `select_window_1' and it makes the window's
      ;; buffer current as well (`Fselect_window''s first line,
      ;; `window.c:534'), so the *buffer* follows the click too.
      ;;--------------------------------------------------------------
      (if (frame? (posn-window position))
          ;; The press was outside every window - on the frame's own
          ;; area. GNU Emacs means the frame's selected window here,
          ;; because every part of a frame that is not a window *is* a
          ;; window in Emacs: the minibuffer is one.
          ;;
          ;; **This tree has no minibuffer window** - the echo area is a
          ;; row of the frame (`frame.scm` keeps `*echo-area-buffer*` for
          ;; it) - so a click on that row arrives here as a *frame*
          ;; position, and `select-window` cannot take a frame. Emacs
          ;; never reaches this state: `mouse-set-point` calls
          ;; `mouse-minibuffer-check` first (`mouse.el:768`, ported
          ;; below), which is where a click on the minibuffer is
          ;; answered. There is nothing to select for that area either
          ;; way - the echo area holds no buffer of its own - so the
          ;; selection is left alone.
          (let ((window (frame-selected-window (posn-window position))))
            (if (window-type? window)
                (select-window window)
                ;; Emacs's own error for a frame whose selected window is
                ;; not a window. It is what this raised before it could
                ;; tell that case from the echo area's.
                (error "Position not in text area of window")))
          (let ((window (posn-window position)))
            (unless (window-type? window)
              (error "Position not in text area of window"))
            (select-window window)))
      ;; A position that names no buffer location - a press on the mode
      ;; line - selects the window and stops there, as Emacs's does.
      (let ((point (posn-point position)))
        (when (integer? point)
          (goto-char point))))

    ;;----------------------------------------------------------------
    ;; The commands
    ;;------------------------------------------------------------------

    (define-command (mouse-set-point event promote-to-region)
      "Move point to the position clicked on with the mouse.
This should be bound to a mouse click event type.
If PROMOTE-TO-REGION is non-nil and event is a multiple-click, select
the corresponding element around point, with the resulting position of
point determined by `mouse-select-region-move-to-beginning'."
      (interactive (list (*last-command-event*) (current-prefix-arg)))
      ;; Emacs's body is
      ;;
      ;;   (and promote-to-region (> (event-click-count event) 1))
      ;;   -> the multi-click branch, else (posn-set-point (event-end event))
      ;;
      ;; **The multi-click branch is not carried**: it needs the click
      ;; count and the region, and neither is here yet. A single press
      ;; reports a click count of 1, which is the branch below.
      ;;
      ;; `mouse-minibuffer-check` first, as Emacs's first line is: it is
      ;; what refuses a click on the echo area row, which reaches here as
      ;; a frame position and would otherwise be handed to
      ;; `posn-set-point`'s `select-window`.
      ;;--------------------------------------------------------------
      (mouse-minibuffer-check event)
      (posn-set-point (event-end event)))

    (define (mouse-key? key)
      ;; Whether KEY names one of the mouse buttons this front end makes
      ;; events for. GNU Emacs's `mouse-event-p' is the same question
      ;; (`subr.el'), asked of `event-basic-type' - which strips the
      ;; button words (`down-`, `drag-`, the implicit `click`) since the
      ;; symbolic modifiers were ported, so `down-mouse-1' and
      ;; `mouse-1' really are one basic type here now.
      ;;--------------------------------------------------------------
      (and (symbol? key)
           (memq key '(mouse-1 mouse-2 mouse-3
                       down-mouse-1 down-mouse-2 down-mouse-3
                       drag-mouse-1 drag-mouse-2 drag-mouse-3))))

    ;;----------------------------------------------------------------
    ;; Following links with mouse-1 - `mouse.el:67-206'
    ;;------------------------------------------------------------------
    ;; Emacs makes a mouse-1 click on text with a non-nil `follow-link`
    ;; property behave as mouse-2 does - `occur-mode-map` and Dired's
    ;; file names are the users - by translating the mouse-1 events into
    ;; mouse-2 events in `key-translation-map`. `mouse-1-click-follows-link`
    ;; (default 450 ms, `mouse.el:67`) is the switch, and the time is
    ;; what tells a click from a press-and-hold: a long press keeps the
    ;; ordinary mouse-1 binding, which sets point.

    (define-custom *mouse-1-click-follows-link* 450
      "Non-nil means that clicking Mouse-1 on a link follows the link.

With the default setting, an ordinary Mouse-1 click on a link
performs the same action as Mouse-2 on that link, while a longer
Mouse-1 click (hold down the Mouse-1 button for more than 450
milliseconds) performs the original Mouse-1 binding (which
typically sets point where you click the mouse).

If value is an integer, the time elapsed between pressing and
releasing the mouse button determines whether to follow the link
or perform the normal Mouse-1 action (typically set point).
The absolute numeric value specifies the maximum duration of a
\"short click\" in milliseconds.  A positive value means that a
short click follows the link, and a longer click performs the
normal action.  A negative value gives the opposite behavior.

If value is `double', a double click follows the link.

Otherwise, a single Mouse-1 click unconditionally follows the link.

Note that dragging the mouse never follows the link.

This feature only works in modes that specifically identify
clickable text as links, so it may not work with some external
packages.  See `mouse-on-link-p' for details."
      :type '(choice (const :tag "Disabled" nil)
                     (const :tag "Double click" double)
                     (number :tag "Single click time limit" :value 450)
                     (other :tag "Single click" t))
      :group 'mouse)

    (define-custom *mouse-1-click-in-non-selected-windows* #t
      "If non-nil, a Mouse-1 click also follows links in non-selected windows.
If nil, a Mouse-1 click on a link in a non-selected window performs
the normal mouse-1 binding, typically selects the window and sets
point at the click position."
      :type 'boolean
      :group 'mouse)

    (define mouse-event-areas-with-no-buffer-positions
      '(mode-line header-line vertical-line
                  left-fringe right-fringe
                  left-margin right-margin
                  tab-bar menu-bar
                  tab-line))
    ;; ^ GNU Emacs's `mouse-event-areas-with-no-buffer-positions'
    ;; (`mouse.el:1787'): "Event areas not containing buffer positions."

    (define mouse--last-down #f)
    ;; ^ GNU Emacs's `mouse--last-down' (`mouse.el:149'): "Time of last
    ;; down-mouse-1 event" as `(EVENT . TIME)`. Emacs keeps a Lisp
    ;; timestamp; this keeps `float-time`'s seconds, because the one
    ;; question asked of it is how long ago the press was.

    (define (mouse--down-1-maybe-follows-link event)
      ;; GNU Emacs's `mouse--down-1-maybe-follows-link' (`mouse.el:151'):
      ;; the `[down-mouse-1]` hook that remembers the press. A
      ;; translation-map binding answers a key sequence, and this one
      ;; answers nil - it translates nothing and only records.
      ;;--------------------------------------------------------------
      (when (*mouse-1-click-follows-link*)
        (set! mouse--last-down
              (cons (if (pair? event) (car event) event)
                    (float-time (current-time)))))
      #f)

    (define (mouse--click-1-maybe-follows-link event)
      ;; GNU Emacs's `mouse--click-1-maybe-follows-link'
      ;; (`mouse.el:156'): "Turn `mouse-1' events into `mouse-2' events
      ;; if follows-link." It is bound to `[mouse-1]` and
      ;; `[double-mouse-1]` in `key-translation-map`, and answers a
      ;; one-event key sequence or nil.
      ;;
      ;; The down event compared against is built the C's way -
      ;; `(down MODIFIERS... BASETYPE)' through `event-convert-list' -
      ;; which is why the symbolic `down`/`click` modifiers had to be
      ;; ported for it. A click with no position (a key translated from
      ;; something else) is not on a link and answers nil.
      ;;--------------------------------------------------------------
      ;; The C's shape is one `and' whose first term is
      ;; `mouse--last-down`: the time is only read when there was a
      ;; press to compare it with.
      (let ((key (car-safe-of event))
            (setting (*mouse-1-click-follows-link*)))
        (and mouse--last-down
             (cond ((not setting) #f)
                   ((eq? setting 'double) (eq? key 'double-mouse-1))
                   (else
                    (and (eq? key 'mouse-1)
                         (or (not (number? setting))
                             (let ((elapsed (- (float-time (current-time))
                                               (cdr mouse--last-down)))
                                   (limit (/ (abs setting) 1000.0)))
                               ;; A negative value is the opposite rule:
                               ;; only a press *longer* than that follows.
                               (if (< setting 0)
                                   (> elapsed limit)
                                   (< elapsed limit)))))))
             (eq? (car mouse--last-down)
                  (event-convert-list
                   (append (list 'down)
                           (event-modifiers event)
                           (list (event-basic-type event)))))
             (pair? event)
             (pair? (cdr event))
             ;; **`(if action ... #f)` and not `(when action ...)`**: a
             ;; `when` whose test fails answers the *unspecified* value,
             ;; which is true in Scheme, and this function's answer is
             ;; read as "the key to translate into" - so an ordinary
             ;; mouse-1 click off a link came back as
             ;; `#<unspecified>` and the dispatcher raised "a key is a
             ;; string or a vector of events".
             (let ((action (mouse-on-link-p (event-start event))))
               (if (not action)
                   #f
                   ;; "Turn the mouse-1 into a mouse-2 to follow links,
                   ;; but only if `mouse-on-link-p' hasn't returned a
                   ;; string or vector." A string/vector ACTION names the
                   ;; event to translate into - its first element.
                   (if (or (vector? action) (string? action))
                       (vector (if (vector? action)
                                   (vector-ref action 0)
                                   (string-ref action 0)))
                       ;; "Modify the event in-place, otherwise we can get
                       ;; a prefix added again" (`mouse.el:193'): the
                       ;; answer is the whole event - `(mouse-2 POSN)` -
                       ;; so the position travels with it, and
                       ;; `last-input-event` (here `*last-read-event*`) is
                       ;; now the new event.
                       (let ((newup (if (eq? setting 'double)
                                        'double-mouse-2
                                        'mouse-2)))
                         (set-car! event newup)
                         (vector event))))))))


    (define (car-safe-of object)
      ;; GNU Emacs's `car-safe': the cons's car, or nil for anything that
      ;; is not one.
      ;;--------------------------------------------------------------
      (and (pair? object) (car object)))

    (define (mouse-start-end start end mode)
      ;; GNU Emacs's `mouse-start-end' (`mouse.el:1832'): the bounds of
      ;; the region a drag from START to END selects, widened by MODE -
      ;; 0 for a single click's drag, 1 for the word a double click is
      ;; on, 2 for its line.
      ;;
      ;; **Mode 0 only**, because a click count needs a clock and the
      ;; double-click machinery, and neither is ported: every event this
      ;; tree produces is a single click. Modes 1 and 2 would be a
      ;; `forward-word' or a `forward-line' from each end, as Emacs's
      ;; are. The ordering is Emacs's and comes first there too.
      ;;--------------------------------------------------------------
      (list (min start end) (max start end)))

    (define (mouse--drag-set-mark-and-point start click click-count)
      ;; GNU Emacs's (`mouse.el:2044'): where the mark and point go as a
      ;; drag from START to CLICK moves. Point follows the pointer and the
      ;; mark holds the other end - whichever end that is, which is what
      ;; the two `eqv?' cases are for: a drag back over its own start
      ;; should not turn the region inside out.
      ;;--------------------------------------------------------------
      (let* ((range (mouse-start-end start click click-count))
             (beg (car range))
             (end (cadr range))
             (m (mark)))
        (cond ((eqv? m beg) (goto-char end))
              ((eqv? m end) (goto-char beg))
              ((and m (< click m)) (set-mark end) (goto-char beg))
              (else (set-mark beg) (goto-char end)))))

    ;;----------------------------------------------------------------
    ;; Dragging past the edge of a window
    ;;------------------------------------------------------------------

    (define *mouse-scroll-delay* (make-parameter 0.25))
    ;; ^ GNU Emacs's `mouse-scroll-delay' (`mouse.el:1679'), "The pause
    ;; between scroll steps caused by mouse drags, in seconds. ... Setting
    ;; this to zero causes Emacs to scroll as fast as it can."

    (define *mouse-scroll-min-lines* (make-parameter 1))
    ;; ^ GNU Emacs's `mouse-scroll-min-lines' (`mouse.el:1687'): "The
    ;; minimum number of lines scrolled by dragging mouse out of window."
    ;; The pointer one row past the edge scrolls one line either way, so
    ;; this only matters when it is set higher.

    (define (mouse-scroll-subr window jump overlay start adjust)
      ;; GNU Emacs's `mouse-scroll-subr' (`mouse.el:1708'): "Scroll the
      ;; window WINDOW, JUMP lines at a time, until new input arrives. If
      ;; OVERLAY is an overlay, let it stretch from START to the far edge
      ;; of the newly visible text. ADJUST, if non-nil, is a function,
      ;; without arguments, to call after setting point. Upon exit, point
      ;; is at the far edge of the newly visible text."
      ;;
      ;; **The loop is the function.** One pass scrolls JUMP screen lines
      ;; and leaves point on the far edge of what is now visible; the
      ;; pass *repeats* while `sit-for' says the delay went by with no
      ;; input. That is the whole of "until new input arrives", and it is
      ;; why dragging the pointer out of the bottom and holding it still
      ;; keeps scrolling a step every `mouse-scroll-delay', while moving
      ;; back in or letting the button up - either of which is input - is
      ;; what stops it. A single motion event therefore scrolls one step
      ;; in a test that has already queued the next key, and the whole
      ;; buffer in a drag that is simply held out there.
      ;;
      ;; The odd-looking `(window-end window)' below is Emacs's and has to
      ;; stay: `set-window-start!' does not invalidate the recorded end,
      ;; so `window-end' still answers the *old* end until the next
      ;; redisplay - which is exactly what this wants, because the old end
      ;; is now JUMP rows above the new bottom edge, and walking JUMP - 1
      ;; rows down from it lands on the last row on the screen. (This
      ;; tree's `window-end' behaves the same way and for the same reason:
      ;; `set-window-start!' leaves `%window-end-valid?' alone.)
      ;;
      ;; NOT CARRIED: OVERLAY, which nothing here wants - the drag
      ;; highlights the region itself, and the `SECONDARY' selection
      ;; caller that would is not ported.
      ;;--------------------------------------------------------------
      (let ((jump (cond ((and (> jump 0)
                              (< jump (*mouse-scroll-min-lines*)))
                         (*mouse-scroll-min-lines*))
                        ((and (< jump 0)
                              (> jump (- (*mouse-scroll-min-lines*))))
                         (- (*mouse-scroll-min-lines*)))
                        (else jump))))
        (let ((opoint (point)))
          (let loop ()
            ;; From the window's top, so that the walk is by screen rows
            ;; and not by however far down a line point happens to be.
            (goto-char (window-start window))
            (when (not (= 0 (vertical-motion jump window)))
              (set-window-start! window (point))
              (if (>= jump 0)
                  (if (window-end window)
                      (begin
                        (goto-char (window-end window))
                        ;; window-end doesn't reflect the window's new
                        ;; start position until the next redisplay
                        (vertical-motion (- jump 1) window)
                        ;; **And then one row further, off the bottom of
                        ;; the window.** The walk above lands point on the
                        ;; window's *last* row, which the redisplay is
                        ;; happy with - the cursor is on the screen, so
                        ;; nothing moves. Leaving it one row lower is
                        ;; "the cursor has been pushed past the bottom",
                        ;; which is the one thing the redisplay's start
                        ;; decision acts on (`redisplay_window''s
                        ;; `recenter:', ported here as
                        ;; `scroll-to-cursor!'): it recentres, so the
                        ;; window moves about half its height rather than
                        ;; one line - the same thing that happens when the
                        ;; *keyboard* cursor is moved off the bottom row.
                        ;; Emacs reaches that state by a different route
                        ;; (`mouse-scroll-subr''s walk ends on the last
                        ;; row, and a GUI frame's last row is only
                        ;; partly visible, so its redisplay recentres
                        ;; too); this tree's rows are exact, so the row
                        ;; has to be stepped onto deliberately.
                        (vertical-motion 1 window))
                      (vertical-motion (- (window-height window) 2) window))
                  (goto-char (window-start window)))
              ;; Now that we have scrolled WINDOW properly, put point back
              ;; where it was for the redisplay so that we don't mess up
              ;; the selected window.
              (unless (eq? window (selected-window))
                (goto-char opoint))
              (when adjust
                (adjust))
              ;; `sit-for' answers #t when the delay went by with
              ;; nothing typed, which is what sends the loop round again -
              ;; "until new input arrives".
              (when (sit-for (*mouse-scroll-delay*) #f)
                (loop))))
          (unless (eq? window (selected-window))
            (goto-char opoint)))))

    (define (%mouse-drag-motion start-window start-point top bottom)
      ;; The body of Emacs's `[mouse-movement]' lambda (`mouse.el:1994'),
      ;; which is the command the drag's transient map binds - so this is
      ;; run by the *command loop*, once per motion event, and not from a
      ;; loop of the drag's own.
      ;;
      ;; Inside the window the drag started in - and on a character, which
      ;; is what `integer? END-POINT' asks - point follows the pointer and
      ;; the region grows to meet it. Anywhere else the drag has left the
      ;; window and the window scrolls, by the number of rows the pointer
      ;; is above the top edge or below the bottom one, so that pulling it
      ;; further out scrolls faster.
      ;;
      ;; **The second branch is not an error case.** A motion event
      ;; outside the window has no buffer position - `posn-point' answers
      ;; #f for a mode line and for the frame, and `posn-window' names
      ;; something other than the window dragged in - and Emacs reads that
      ;; as "keep scrolling", which is what makes a selection longer than
      ;; a screen possible at all.
      ;;--------------------------------------------------------------
      (let* ((ev (*last-read-event*))
             (end (and (pair? ev) (event-end ev)))
             (end-window (and end (posn-window end)))
             (end-point (and end (posn-point end))))
        (if (and (eq? end-window start-window) (integer? end-point))
            (mouse--drag-set-mark-and-point start-point end-point 0)
            ;; **The pointer's row comes from `mouse-position', not from
            ;; the event.** The event's own coordinates are relative to
            ;; whichever window the pointer was over, and are meaningless
            ;; the moment it leaves that window - which is exactly the
            ;; case this branch is for. Emacs asks its display where the
            ;; pointer is (`XQueryPointer', `gdk_window_get_device_position')
            ;; and this is that call; reading `posn-x-y' here instead is
            ;; what made a drag past the edge scroll one line at a time,
            ;; because the row it answered barely differed from the
            ;; window's bottom edge.
            (let ((mouse-row (cdr (cdr (mouse-position)))))
              (cond
               ((not (integer? mouse-row)) #f)
               ((< mouse-row top)
                (mouse-scroll-subr start-window (- mouse-row top)
                                   #f start-point #f))
               ((>= mouse-row bottom)
                (mouse-scroll-subr start-window (+ 1 (- mouse-row bottom))
                                   #f start-point #f)))))))

    (define-command (mouse-set-region click)
      "Set the region to the text dragged over, and copy to kill ring.
This should be bound to a mouse drag event."
      (interactive "e")
      ;; GNU Emacs's `mouse-set-region' (`mouse.el:1799'). **This is what
      ;; keeps the region after a drag.** The drag's transient map is
      ;; popped by the release - a command the map does not bind - and
      ;; its ON-EXIT deactivates the mark; `[drag-mouse-1]' is what then
      ;; runs, and its `push-mark'/`set-mark'/`mouse-set-region-1' put
      ;; the region back. That is why `mouse.el:3783' binds
      ;; `[drag-mouse-1]' and not `[mouse-1]'.
      ;;
      ;; NOT CARRIED, each named: `mouse-shift-adjust-point' (no
      ;; shift-adjust machinery here);
      ;; the `mouse-drag-start' terminal parameter and the click count it
      ;; is read for; `mouse-drag-copy-region' (nil in Emacs by default,
      ;; so nothing is copied); and the "(or transient-mark-mode
      ;; (window-system) (sit-for 1))" cursor bounce, which is a text
      ;; terminal's.
      ;;--------------------------------------------------------------
      ;; **`posn-window' answers the *frame* when the press was outside
      ;; every window** - `posn-at-x-y' does that deliberately, and its own
      ;; comment says so - and `select-window' on a frame is a type error:
      ;;
      ;;   Wrong type argument: #<<frame> windows: (#<<window> ...)
      ;;
      ;; That is a click in a second frame, which is the report this fixes.
      ;; The rule for what a frame position means is `posn-set-point''s,
      ;; one function up, and it is the same rule here: the frame's own
      ;; selected window. Two spellings of one rule is one too many, and
      ;; they disagreed - `posn-set-point' had it and this did not.
      (select-window
       (let ((w (posn-window (event-start click))))
         (if (window-type? w) w (frame-selected-window w))))
      (let* ((beg (posn-point (event-start click)))
             (end (if (eq? (posn-window (event-end click)) (selected-window))
                      (posn-point (event-end click))
                      ;; "If the mouse ends up in any other window or on
                      ;; the menu bar, use `window-point' of the selected
                      ;; window" (Bug#23707). Emacs's `window-point'
                      ;; defaults to the selected window; this tree's takes
                      ;; it, so it is passed.
                      (window-point (selected-window))))
             (click-count 0))
        (when (and (integer? beg) (integer? end))
          (let ((range (mouse-start-end beg end click-count)))
            (if (< end beg)
                (begin (set! end (car range)) (set! beg (cadr range)))
                (begin (set! beg (car range)) (set! end (cadr range))))))
        (when (integer? beg)
          (goto-char beg))
        (push-mark)
        (set-mark (point))
        (when (integer? end)
          (goto-char end))
        (mouse-set-region-1)))

    (define (mouse-set-region-1)
      ;; GNU Emacs's `mouse-set-region-1' (`mouse.el:1843'): "Set
      ;; transient-mark-mode for a little while" - the `(cons 'only OLD)'
      ;; value, whose `only' is what tells `deactivate-mark' to put the
      ;; old value back rather than to stay off.
      ;;--------------------------------------------------------------
      (unless (eq? (car-safe-of (transient-mark-mode)) 'only)
        (set-buffer-local-value!
         (current-buffer) 'transient-mark-mode
         (cons 'only (if (eq? (transient-mark-mode) 'lambda)
                         #f
                         (transient-mark-mode))))))

    (define (mouse-drag-track start-event)
      ;; GNU Emacs's `mouse-drag-track' (`mouse.el:1919'). Not a command
      ;; in Emacs either - `mouse-drag-region' calls it - so it is a
      ;; plain definition here too.
      ;;
      ;; **There is no read loop, and the shape is the point.** Emacs
      ;; installs a *transient keymap* (`set-transient-map',
      ;; `mouse.el:1996') binding `[mouse-movement]' to a lambda and
      ;; returns. The **command loop** reads the motion events; the map
      ;; answers for them; and the first command the map does not bind -
      ;; the button coming up, or anything else at all - pops the map and
      ;; runs the cleanup. This tree read the events itself for as long as
      ;; it had no transient keymap, and every drag fault had to be
      ;; patched in a place Emacs has no such place: a `<resize>' swallow
      ;; in the loop, an `auto-hscroll-mode' `dynamic-wind' around it.
      ;;
      ;; `#f' for PROMOTE-TO-REGION, which Emacs's call leaves out: a
      ;; `define-command' here takes the arguments its interactive
      ;; expression supplies and has no `&optional' to make one skippable,
      ;; so a programmatic call passes the same two.
      ;;
      ;; NOT CARRIED, each named where Emacs has it:
      ;; `mouse-selection-click-count' and the click count itself, which
      ;; need a clock; `echo-keystrokes' and `make-cursor-line-fully-
      ;; visible', neither of which exists here; `mouse-shift-adjust-
      ;; point'; and the `terminal-parameter' the drag's start event is
      ;; recorded in for `mouse-drag-and-drop-region'.
      ;;--------------------------------------------------------------
      ;; the C's first line, "Don't do anything for a click in an
      ;; inactive minibuffer" - which for this tree is the echo row
      (mouse-minibuffer-check start-event)
      (deactivate-mark)
      (let* ((start-posn (event-start start-event))
             (start-point (posn-point start-posn))
             ;; **A press outside every window names the frame**, which
             ;; is `posn-at-x-y`'s answer by design; `window-buffer` and
             ;; `window-height` below would then be asked of a frame -
             ;; "Wrong type argument: #<<frame> windows: ...". Emacs's
             ;; `mouse-drag-track` never meets it because its position
             ;; names a window (the minibuffer is one), so the rule for
             ;; what a frame position means is the one `posn-set-point`
             ;; states: the frame's own selected window.
             (start-window (let ((w (posn-window start-posn)))
                             (if (window-type? w)
                                 w
                                 (frame-selected-window w))))
             ;; "We've recorded what we needed from the current buffer
             ;; and window" - Emacs clears the buffer's deferred
             ;; `deactivate-mark' flag here, because this drag is about to
             ;; set its own region.
             (_ (set-buffer-local-value!
                 (window-buffer start-window) 'deactivate-mark #f))
             ;; "now let's jump to the place of the event, where things
             ;; are happening" - the call that selects the window and
             ;; moves point, and that everything below depends on.
             (_ (mouse-set-point start-event #f))
             (bounds (window-edges start-window))
             (top (list-ref bounds 1))
             ;; "Don't count the mode line": the window's last row is its
             ;; mode line, and a pointer on it is outside the text, which
             ;; is why the scrolling test below is `>= BOTTOM'. Emacs
             ;; takes the whole edge when a window has no mode line.
             (bottom (if *mode-line-format*
                         (- (list-ref bounds 3) 1)
                         (list-ref bounds 3)))
             ;; A single click, which is all this tree makes: the click
             ;; count is what a double or triple click multiplies the
             ;; region by, and counting needs a clock.
             (click-count 0)
             (auto-hscroll-saved
              (buffer-auto-hscroll-mode (window-buffer start-window)))
             ;; `track-mouse' is set for the drag and put back by the
             ;; cleanup - Emacs's `old-track-mouse'. It is *whether the
             ;; display makes an event of pointer motion at all*, so the
             ;; front end reads it; `pgtk.sld''s motion handler does.
             (old-track-mouse track-mouse)
             (cleanup (lambda ()
                        (set! track-mouse old-track-mouse)
                        (set!buffer-auto-hscroll-mode
                         (window-buffer start-window) auto-hscroll-saved))))
        ;; "Cleanup on errors" - Emacs's `condition-case'.
        (guard (ex (else (cleanup) (raise ex)))
          ;; In case the down click is in the middle of some intangible
          ;; text, use the end of that text. Below the `mouse-set-point'
          ;; above, so this is the position the drag really starts from.
          (when (< (point) start-point)
            (goto-char start-point))
          (set! start-point (point))
          ;; **Automatic hscrolling off for the duration**, and restored
          ;; by the cleanup, which is where Emacs turns it off and for the
          ;; reason its own comment gives: it "interferes with the natural
          ;; dragging behavior (point will unexpectedly be moved beneath
          ;; the pointer, making selections in auto-scrolling margins
          ;; impossible)". Emacs zeroes `scroll-margin' beside it; there
          ;; is no `scroll-margin' in this tree to zero.
          (set!buffer-auto-hscroll-mode (window-buffer start-window) #f)
          ;; The region is highlighted for the rest of this drag and no
          ;; longer than that: `(cons 'only ...)' is Emacs's own value
          ;; here, and its `deactivate-mark' half is what turns it back.
          ;;
          ;; **`setq-local`, not `setq`** - Emacs writes the *buffer's*
          ;; Transient Mark mode, and so must this: the mode a buffer sees
          ;; is its own value, so a global set here would be invisible to
          ;; `(transient-mark-mode)` and to `region-active-p`.
          (set-buffer-local-value! (current-buffer) 'transient-mark-mode
                                   (cons 'only (transient-mark-mode)))
          ;; "Activate the region, using `mouse-start-end' to determine
          ;; where to put point and mark".
          (let ((range (mouse-start-end start-point start-point click-count)))
            (push-mark (car range) #t #t)
            (goto-char (cadr range)))
          ;; **Never nil and never t**: Emacs sets this to something that
          ;; is neither, so that mouse events are not reported to have
          ;; happened on the tool bar or the tab bar - which would break a
          ;; drag that started in the window body below them
          ;; (`make_lispy_position', bug#51794). The front end's test is
          ;; the C's `!NILP (track_mouse)'.
          (set! track-mouse 'drag-tracking)
          ;; **The map that makes the loop unnecessary.** It is emptied
          ;; by `set-transient-map' when a command it does not bind runs,
          ;; and that command is normally the button coming up.
          ;;
          ;; `[switch-frame]' and `[select-window]' are bound to `ignore'
          ;; so that a *frame* event cannot end a drag - Emacs's own
          ;; lines. This tree invents no such events, and its frame
          ;; events (`<resize>' and the focus pair) do not need the
          ;; binding: they are *special events*, which
          ;; `dispatch-special-event' handles before any map is consulted
          ;; and without `pre-command-hook', exactly as Emacs's
          ;; `read_char' does (`keyboard.c:3113'). Running them as
          ;; ordinary commands is what used to end a drag on a resize.
          ;;
          ;; The movement command is a plain procedure and not a
          ;; `define-command', which is the one departure from Emacs's
          ;; `(lambda (event) (interactive "e") ...)': a lambda cannot
          ;; carry an interactive specification in this tree, and it does
          ;; not need one - the event it would be handed is where
          ;; `*last-read-event*' already is, which is how every command
          ;; here reads a mouse event's position.
          (set-transient-map
           (let ((map (km:keymap '*mouse-drag-map*)))
             (define-key map (kbd "<switch-frame>") ignore)
             (define-key map (kbd "<select-window>") ignore)
             (define-key map (kbd "<mouse-movement>")
                         (lambda ()
                           (%mouse-drag-motion start-window start-point
                                               top bottom)))
             map)
           #t
           ;; ON-EXIT: Emacs's own, minus the context-menu branch that
           ;; keeps the region when `down-mouse-3' came next - there is no
           ;; context menu here.
           (lambda ()
             (cleanup)
             (deactivate-mark)
             (pop-mark))))))

    (define-command (mouse-drag-region start-event)
      "Set the region to the text that the mouse is dragged over.
Highlight the drag area as you move the mouse.
This must be bound to a button-down mouse event.
In Transient Mark mode, the highlighting remains as long as the mark
remains active.  Otherwise, it remains until the next input event.

When the region already exists and `mouse-drag-and-drop-region'
is non-nil, this moves the entire region of text to where mouse
is dragged over to."
      (interactive "e")
      ;; Emacs's body is the drag-and-drop branch, then
      ;; `mouse-leave-buffer-hook', then `mouse-drag-track'. The hook and
      ;; the drag-and-drop branch are not carried - see the note at the
      ;; top of this library - and what is left is the call.
      ;;--------------------------------------------------------------
      (mouse-drag-track start-event))

    ;; **`mouse.el:3781'\u2013`:3783', all three of them**, and the
    ;; release's two are not decoration:
    ;;
    ;;   [down-mouse-1]  `mouse-drag-region'   the press starts the drag
    ;;   [mouse-1]       `mouse-set-point'     a release with no movement
    ;;   [drag-mouse-1]  `mouse-set-region'    a release *after* movement
    ;;
    ;; The third is what puts the region back after the drag's own
    ;; cleanup has taken it down, so without it a drag highlights the
    ;; text and then loses it the moment the button comes up.
    ;;----------------------------------------------------------------
    ;; The mouse buffer menu (`mouse.el:2848`)
    ;;----------------------------------------------------------------
    ;;
    ;; A menu of every buffer, grouped by major mode when that makes it
    ;; shorter. `tab-line.el`'s "+" button is the caller that matters
    ;; here; M-` and C-Down-mouse-1 use the same three functions.

    (define *mouse-buffer-menu-mode-mult* 4)
    ;; ^ `(defvar mouse-buffer-menu-mode-mult 4 ...)' - "Group the menu
    ;; by major mode if the sum of squares of the number of buffers in
    ;; each mode, multiplied by this, is less than the square of the
    ;; total number of buffers."

    (define *mouse-buffer-menu-maxlen* 20)
    ;; ^ `(defvar mouse-buffer-menu-maxlen 20 ...)': "Number of buffers
    ;; in each pane. If there are more than this many buffers, they are
    ;; split into panes of this size."

    (define (mouse-buffer-menu-map)
      ;; GNU Emacs's `mouse-buffer-menu-map` (`mouse.el:2862`): "Make an
      ;; alist of elements that look like (MENU-ITEM . BUFFER)."
      ;;
      ;; `(length elt1)` in the sort comparator is the C's - it counts
      ;; the mode and the name as elements too, which is why the "more
      ;; than one buffer" test below is `(> (length ...) 3)`.
      ;;--------------------------------------------------------------
      (let ((buffers (buffer-list))
            (split-by-major-mode '()))
        (for-each
         (lambda (buf)
           (with-current-buffer
               buf
             (let* ((adjusted-major-mode (major-mode))
                    (elt #f))
               (for-each
                (lambda (group)
                  (when (string-match (car group) (format-mode-line mode-name))
                    (set! adjusted-major-mode (cdr group))))
                *mouse-buffer-menu-mode-groups*)
               (set! elt (assq adjusted-major-mode split-by-major-mode))
               (unless elt
                 (set! elt (list adjusted-major-mode
                                 (if (string? adjusted-major-mode)
                                     adjusted-major-mode
                                     (format-mode-line mode-name))))
                 (set! split-by-major-mode (cons elt split-by-major-mode)))
               (unless (memq buf (cddr elt))
                 (set-cdr! (cdr elt) (cons buf (cddr elt)))))))
         buffers)
        ;; "Compute the sum of squares of sizes of the major-mode buckets."
        (let ((sum-of-squares
               (let loop ((tail split-by-major-mode) (sum 0))
                 (if (null? tail)
                     sum
                     (let ((len (length (cddr (car tail)))))
                       (loop (cdr tail) (+ sum (* len len))))))))
          (if (< (* sum-of-squares *mouse-buffer-menu-mode-mult*)
                 (* (length buffers) (length buffers)))
              ;; "Subdividing by major modes really helps, so let's do it."
              (let ((buffers-left (length buffers))
                    (subdivided-menus '()))
                ;; "Sort the list to put the most popular major modes first."
                (set! split-by-major-mode
                      (sort split-by-major-mode
                            (lambda (elt1 elt2)
                              (> (length elt1) (length elt2)))))
                (let loop ()
                  (when (and (pair? split-by-major-mode)
                             (> (length (car split-by-major-mode)) 3)
                             (> (* buffers-left 10) (length buffers)))
                    (let ((this-mode-list
                           (mouse-buffer-menu-alist
                            (cddr (car split-by-major-mode)))))
                      (when this-mode-list
                        (set! subdivided-menus
                              (cons (cons (cadr (car split-by-major-mode))
                                          this-mode-list)
                                    subdivided-menus))))
                    (set! buffers-left
                          (- buffers-left (length (car split-by-major-mode))))
                    (set! split-by-major-mode (cdr split-by-major-mode))
                    (loop)))
                ;; "If any major modes are left over, make a single
                ;; submenu for them."
                (unless (null? split-by-major-mode)
                  (let ((others-list
                         (mouse-buffer-menu-alist
                          (apply append
                                 (map cddr split-by-major-mode)))))
                    (when others-list
                      (set! subdivided-menus
                            (cons (cons "Others" others-list)
                                  subdivided-menus)))))
                (cons "Buffer Menu" (reverse subdivided-menus)))
              (cons "Buffer Menu"
                    (mouse-buffer-menu-split
                     "Select Buffer"
                     (mouse-buffer-menu-alist buffers)))))))

    (define (mouse-buffer-menu-alist buffers)
      ;; GNU Emacs's `mouse-buffer-menu-alist` (`mouse.el:2933`): the
      ;; menu's entries, name-padded, sorted by name, with the modified
      ;; and read-only flags and the file each buffer visits.
      ;;
      ;; `(format (format "%%-%ds  %%s%%s  %%s" maxlen) ...)` in the C is
      ;; the width built into the format string; here the width is a
      ;; field in Guile's own `~v'.
      ;;--------------------------------------------------------------
      (let* ((sorted (sort buffers
                           (lambda (elt1 elt2)
                             (string< (buffer-name elt1)
                                      (buffer-name elt2)))))
             (maxlen
              (let loop ((tail sorted) (maxlen 0))
                (cond ((null? tail) maxlen)
                      ((char=? (string-ref (buffer-name (car tail)) 0) #\space)
                       (loop (cdr tail) maxlen))
                      (else
                       (loop (cdr tail)
                             (max maxlen
                                  (string-length (buffer-name (car tail))))))))))
        (let loop ((tail sorted) (head '()))
          (if (null? tail)
              (reverse head)
              (let ((elt (car tail)))
                (if (char=? (string-ref (buffer-name elt) 0) #\space)
                    (loop (cdr tail) head)
                    (loop (cdr tail)
                          (cons (cons (string-append
                                               ;; "`%-Ns'" pads on the right
                                               ;; to a width taken from the
                                               ;; buffer names.
                                               (let ((name (buffer-name elt)))
                                                 (string-append
                                                  name
                                                  (make-string
                                                   (max 0 (- maxlen (string-length name)))
                                                   #\space)))
                                               "  "
                                              (if (buffer-modified-p elt) "*" " ")
                                              (with-current-buffer
                                                  elt
                                                (if (buffer-read-only?
                                                     (current-buffer))
                                                    "%" " "))
                                              (or (buffer-file-name elt)
                                                  (with-current-buffer
                                                      elt
                                                    (let ((dir (buffer-local-value
                                                                (current-buffer)
                                                                'list-buffers-directory
                                                                #f)))
                                                      (and dir
                                                           (expand-file-name dir))))
                                                  ""))
                                      elt)
                                head))))))))

    (define (mouse-buffer-menu-split title alist)
      ;; GNU Emacs's `mouse-buffer-menu-split` (`mouse.el:2973`): "If we
      ;; have lots of buffers, divide them into groups of 20 and make a
      ;; pane (or submenu) for each one."
      ;;--------------------------------------------------------------
      (if (> (length alist) (quotient (* *mouse-buffer-menu-maxlen* 3) 2))
          (let loop ((rest alist) (sublists '()) (i 1))
            (if (null? rest)
                (reverse sublists)
                (let ((next (list-tail-or rest *mouse-buffer-menu-maxlen*)))
                  (loop (if next next '())
                        (cons (cons (format #f "Buffers ~a" i)
                                    (if next
                                        (list-head rest *mouse-buffer-menu-maxlen*)
                                        rest))
                              sublists)
                        (+ i 1)))))
          (list (cons title alist))))

    (define (list-tail-or lst n)
      ;; The NTH cdr of LST, or #f when it is shorter. R7RS's
      ;; `list-tail` raises instead, which is not what the splitting walk
      ;; wants.
      ;;--------------------------------------------------------------
      (let loop ((rest lst) (n n))
        (cond ((= n 0) rest)
              ((null? rest) #f)
              (else (loop (cdr rest) (- n 1))))))

    (define (list-head lst n)
      ;; The first N elements of LST.
      ;;--------------------------------------------------------------
      (if (or (= n 0) (null? lst))
          '()
          (cons (car lst) (list-head (cdr lst) (- n 1)))))

    (define-command (mouse-buffer-menu event)
      "Pop up a menu of buffers for selection with the mouse.
This switches buffers in the window that you clicked on,
and selects that window."
      (interactive (list (*last-read-event*)))
      ;; GNU Emacs's `mouse-buffer-menu` (`mouse.el:2848`).
      ;;--------------------------------------------------------------
      (mouse-minibuffer-check event)
      (let ((buf (x-popup-menu event (mouse-buffer-menu-map)))
            (window (posn-window (event-start event))))
        (when buf
          (select-window (if (frame? window) (frame-selected-window window)
                             window))
          (switch-to-buffer buf))))

    (define (mouse-posn-property pos property)
      ;; GNU Emacs's `mouse-posn-property' (`mouse.el:1799'): "Look for a
      ;; property at click position. POS may be either a buffer position
      ;; or a click position like those returned from `event-start'."
      ;;
      ;; Emacs asks `get-char-property` of the *window*, so that
      ;; window-specific overlays count; this tree's text-property reader
      ;; takes the buffer, which is the same answer for every overlay
      ;; that is not window-scoped and there are none of those here.
      ;;--------------------------------------------------------------
      (if (pair? pos)
          (let ((w (posn-window pos))
                (pt (posn-point pos))
                (str (posn-string pos)))
            (or (and str
                     (< (cdr str) (string-length (car str)))
                     (get-text-property (cdr str) property (car str)))
                (and pt
                     (not (memq (posn-area pos)
                                mouse-event-areas-with-no-buffer-positions))
                     (get-char-property pt property
                                        (if (window-type? w)
                                            (window-buffer w)
                                            w)))))
          (get-char-property pos property)))

    (define (mouse-on-link-p pos)
      ;; GNU Emacs's `mouse-on-link-p' (`mouse.el:1829'): non-nil when
      ;; POS is on a link, and what kind.
      ;;
      ;; The `[follow-link]` key bindings Emacs also consults are looked
      ;; up without a position here - this tree's `key-binding` has no
      ;; POS argument, so the position-specific `keymap` text property is
      ;; not consulted. `follow-link` as a *text property* is, which is
      ;; what `occur-mode` and Dired set.
      ;;--------------------------------------------------------------
      (let* ((area (and (pair? pos) (posn-area pos)))
             (action
              (and (or (not (pair? pos))
                       (*mouse-1-click-in-non-selected-windows*)
                       (eq? (selected-window) (posn-window pos)))
                   (or (mouse-posn-property pos 'follow-link)
                       (and area
                            (key-binding (vector area 'follow-link) #f))
                       (key-binding (vector 'follow-link) #f)))))
        (cond
         ((eq? action 'mouse-face)
          ;; Inhibit follow-link when `mouse-1' is clicked on the tab-bar
          ;; to prevent misdirected clicks in `dired-mode' (bug#49247,
          ;; bug#81036).
          (and (not (eq? area 'tab-bar))
               (mouse-posn-property pos 'mouse-face) #t))
         ((procedure? action)
          (if (pair? pos)
              (with-current-buffer (window-buffer (posn-window pos))
                (action (posn-point pos)))
              (action pos)))
         (else action))))

    (define (mouse-fixup-help-message msg)
      ;; GNU Emacs's `mouse-fixup-help-message` (`mouse.el:1894`): "Fix
      ;; help message MSG for `mouse-1-click-follows-link'." A `help-echo`
      ;; that says "mouse-2: ..." becomes "mouse-1: ..." - or "double-"
      ;; or "Long " - when the pointer is on a link and Mouse-1 will
      ;; follow it, which is what makes a Dired name or an Occur line
      ;; describe the button that will actually work.
      ;;
      ;; The C asks `mouse-pixel-position` and feeds its pixels to
      ;; `posn-at-x-y`; this tree's `posn-at-x-y` counts *cells*, and
      ;; `mouse-position` is the query that answers those - a named
      ;; departure, and the same position either way.
      ;;--------------------------------------------------------------
      (let* ((setting (*mouse-1-click-follows-link*))
             (mp (and setting
                      (string? msg)
                      (string-match "\\`mouse-2" msg)
                      (mouse-position)))
             (pos (and mp (cdr mp)))
             (posn (and pos (pair? pos)
                        (number? (car pos)) (>= (car pos) 0)
                        (number? (cdr pos)) (>= (cdr pos) 0)
                        (posn-at-x-y (car pos) (cdr pos) (car mp))))
             (on-link? (and posn
                            (window-type? (posn-window posn))
                            (with-current-buffer
                                (window-buffer (posn-window posn))
                              (mouse-on-link-p posn)))))
        (if on-link?
            (concat (cond ((eq? setting 'double) "double-")
                          ((and (integer? setting) (< setting 0)) "Long ")
                          (else ""))
                    "mouse-1" (%substring msg 7))
            msg)))

    ;;----------------------------------------------------------------
    ;; The mode-line menus - `mouse.el:222-330'
    ;;----------------------------------------------------------------
    ;;
    ;; The mode line's mode name and minor-mode lighters carry
    ;; `mode-line-major-mode-keymap` and `mode-line-minor-mode-keymap`
    ;; (`bindings.el:571-615`), and these are the pieces they name.
    ;;
    ;; **Departure**: Emacs binds the menus as `(menu-item ... :filter
    ;; ...)` values whose filter returns a keymap, and `read_char`'s menu
    ;; prompting pops a keymap reached by a click. This tree has neither
    ;; the filter arm in a key lookup nor the menu-prompt path, so the
    ;; down-mouse bindings name two commands here that build the same
    ;; menu and pop it at the click (`mouse-menu-major-mode-menu`,
    ;; `mode-line-minor-mode-menu`). `mouse-menu-major-mode-map` and
    ;; `minor-mode-menu-from-indicator` themselves are Emacs's.

    (define *popup-menu-function* (make-parameter #f))
    ;; ^ `popup-menu` (`menu-bar.el:2690`), installed by `menu-bar.scm`.

    (define *menu-bar-edit-menu* (make-parameter #f))
    ;; ^ `menu-bar-edit-menu` (`menu-bar.el:497`), installed by the same
    ;; library - the major-mode menu's fallback when the mode has no menu
    ;; of its own.

    (define *describe-function-function* (make-parameter #f))
    ;; ^ The seam `minor-mode-menu-from-indicator`'s generated "Help for
    ;; minor mode" item reaches `describe-function` through. That
    ;; function is `help-fns.scm`'s and that library is above this one,
    ;; so it installs this parameter as it loads; without it the item is
    ;; left out of the menu.

    (define (mouse-menu-non-singleton menubar)
      ;; GNU Emacs's `mouse-menu-non-singleton` (`mouse.el:326`):
      ;; "Return menu keybar MENUBAR, or a lone submenu inside it. If
      ;; MENUBAR defines exactly one submenu, return just that submenu."
      ;;
      ;; `keymap-canonicalize` is the C's walk over the canonical form,
      ;; which is what lets `map-keymap` see a sparse map's every entry.
      ;;--------------------------------------------------------------
      (if menubar
          (let ((submap #f))
            (map-keymap
             (lambda (k v) (set! submap (if submap #t (cons k v))))
             (keymap-canonicalize menubar))
            (if (eq? submap #t)
                menubar
                (and (pair? submap)
                     (lookup-key menubar (vector (car submap))))))
          #f))

    (define (mouse-menu-major-mode-map)
      ;; GNU Emacs's `mouse-menu-major-mode-map` (`mouse.el:309`): the
      ;; menu a click on the major mode name pops up.
      ;;
      ;; A mode that puts a `[menu-bar]` submenu in its local map gets
      ;; that menu, titled "<Mode> Mode"; a mode with none gets the Edit
      ;; menu - Emacs's own fallback (`newmap = menu-bar-edit-menu`).
      ;;--------------------------------------------------------------
      (run-hooks (*activate-menubar-hook*))
      (run-hooks (*menu-bar-update-hook*))
      (let* ((ancestor
              (mouse-menu-non-singleton
               (and (current-local-map)
                    (lookup-key (current-local-map) (vector 'menu-bar)))))
             (newmap (if ancestor
                         (make-sparse-keymap
                          (string-append (format-mode-line (mode-name)) " Mode"))
                         (*menu-bar-edit-menu*))))
        (when ancestor
          (set-keymap-parent newmap ancestor))
        newmap))

    (define-command (mouse-menu-major-mode-menu event)
      "Pop up the major mode menu at EVENT.

The menu is `mouse-menu-major-mode-map`'s - Emacs reaches it through a
filtered `menu-item`; this tree pops it from a command (see the note
above the mode-line menus)."
      (interactive "@e")
      ((*popup-menu-function*) (mouse-menu-major-mode-map) event))

    (define-command (mode-line-minor-mode-menu event)
      "Pop up the menu of minor modes at EVENT.
This is `mode-line-mode-menu`, sorted by name - `bindings.el`'s
`:filter bindings--sort-menu-keymap`."
      (interactive "@e")
      ((*popup-menu-function*) (bindings--sort-menu-keymap mode-line-mode-menu)
                               event))

    (define-command (mode-line-line-column-menu event)
      "Pop up the line and column display menu at EVENT.
This is `mode-line-column-line-number-mode-map`'s menu
(`bindings.el:621-636`); Emacs binds the menu keymap directly and
pops it through `read_char`'s menu prompting, which this tree does
not have - so the press names this command, as the mode name's and
the lighters' presses do."
      (interactive "@e")
      ((*popup-menu-function*) line-column-mode-menu event))

    (define (lookup-minor-mode-from-indicator indicator . rest)
      ;; GNU Emacs's `lookup-minor-mode-from-indicator` (`help.el:1403`):
      ;; "Return a minor mode symbol from its indicator on the mode
      ;; line." A leading space is stripped from both sides of the
      ;; comparison, because a lighter starts with its own space.
      ;;
      ;; **Placement**: `help.el`'s function, but the one user is
      ;; `minor-mode-menu-from-indicator` below, and `help.el` is above
      ;; this library - `describe-minor-mode-from-indicator` imports it
      ;; from here, as `posn-set-point` is imported from here by `subr.el`'s
      ;; owner.
      ;;
      ;; The indicator is evaluated the way the mode line builds it -
      ;; `minor-mode-indicator-value` and `minor-mode-lighter`, in the
      ;; buffer of WINDOW (or the selected window) - where Emacs calls
      ;; `format-mode-line` and reads the selected window's buffer.
      ;;--------------------------------------------------------------
      (let ((window (or (and (pair? rest) (car rest)) (selected-window))))
        (let* ((buffer (window-buffer window))
               (indicator (if (and (> (string-length indicator) 0)
                                   (char=? (string-ref indicator 0) #\space))
                              (substring indicator 1)
                              indicator)))
          (let loop ((modes (*minor-mode-alist*)))
            (if (null? modes)
                #f
                (let* ((entry (car modes))
                       (minor-mode (car entry))
                       (anindicator
                        (minor-mode-lighter
                         (minor-mode-indicator-value buffer (cadr entry))))
                       (anindicator
                        (if (and (string? anindicator)
                                 (> (string-length anindicator) 0)
                                 (char=? (string-ref anindicator 0) #\space))
                            (substring anindicator 1)
                            anindicator)))
                  (if (equal? indicator anindicator)
                      minor-mode
                      (loop (cdr modes)))))))))

    (define (describe-minor-mode-completion-table-for-indicator)
      ;; GNU Emacs's `describe-minor-mode-completion-table-for-indicator`
      ;; (`help.el:1331`): "the active lighters, with the leading space
      ;; removed" - it `format-mode-line`s each `minor-mode-alist` entry,
      ;; which answers "" for a mode that is off (measured on Emacs
      ;; 31.1: with `overwrite-mode` and `auto-fill-mode` on the table is
      ;; `("Ovwrt" "Fill")`).
      ;;
      ;; **Placement**: `help.el`'s, but beside
      ;; `lookup-minor-mode-from-indicator` and the two functions the
      ;; mode line evaluates a lighter with - they are what it is made
      ;; of, and `help-fns.scm` imports it from here.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (let loop ((alist (*minor-mode-alist*)) (acc '()))
          (if (null? alist)
              (reverse acc)
              (let* ((entry (car alist))
                     (i (if (minor-mode-variable-true? buffer (car entry))
                            (minor-mode-lighter
                             (minor-mode-indicator-value buffer (cadr entry)))
                            "")))
                (loop (cdr alist)
                      (cond ((not (string? i)) acc)
                            ((= 0 (string-length i)) acc)
                            ((char=? (string-ref i 0) #\space)
                             (cons (substring i 1) acc))
                            (else (cons i acc)))))))))

    (define-command (minor-mode-menu-from-indicator indicator . rest)
      ;; GNU Emacs's `minor-mode-menu-from-indicator` (`mouse.el:222`):
      ;; "Show menu for minor mode specified by INDICATOR." A command -
      ;; M-x prompts for the indicator - and the click path passes the
      ;; clicked lighter's string, its window and its event.
      ;;
      ;; The mode-line-compact disambiguation arm is not carried - the
      ;; option is not ported, and Emacs without it behaves as this does:
      ;; the indicator must equal a whole lighter, which is the
      ;; single-lighter case. The generated menu is "Turn off" plus
      ;; "Help", the second only when a help library has installed the
      ;; seam.
      ;;--------------------------------------------------------------
      (interactive
       (list (completing-read
              "Minor mode indicator: "
              (describe-minor-mode-completion-table-for-indicator))))
      (let* ((window (and (pair? rest) (car rest)))
             (event (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (indicator (if (pair? indicator) (car indicator) indicator)))
        (when (not (string? indicator))
          (error "Wrong type argument: stringp, ~s" indicator))
        (let* ((minor-mode (if (symbol? indicator)
                               indicator
                               (lookup-minor-mode-from-indicator
                                indicator window)))
               ;; "`mm-fun` is `(or (get minor-mode :minor-mode-function)
               ;; minor-mode)`" (`mouse.el:274`): `add-minor-mode`
               ;; records a different toggle function when a mode has
               ;; one. Nothing here passes `TOGGLE-FUN`, so the property
               ;; is never set - the lookup is Emacs's shape, not a
               ;; stand-in.
               (mm-fun (and minor-mode
                            (or (get minor-mode ':minor-mode-function)
                                minor-mode)))
               (map (and minor-mode
                         (let ((cell (assq minor-mode (*minor-mode-map-alist*))))
                           ;; Elisp's `(cdr-safe ...)': a mode with no
                           ;; map is the ordinary case.
                           (and (pair? cell) (cdr cell)))))
               (menu (and map (keymapp map)
                          (lookup-key map (vector 'menu-bar)))))
          (unless minor-mode
            (error "Cannot find minor mode for `~a'" indicator))
          (when (and (not menu) mm-fun
                     ;; "`(if (fboundp mm-fun) ...)`" (`mouse.el:282`,
                     ;; bug#20201): a mode whose function no longer
                     ;; exists gets no generated menu. The command table
                     ;; is what `fboundp` is here.
                     (command-record-named (symbol->string mm-fun)))
            ;; `mouse.el:283-291`'s keymap. Emacs builds it as a *list*
            ;; keymap, `(keymap TITLE (turn-off menu-item ...) (help
            ;; menu-item ...))`; `x-popup-menu` takes a record here, so
            ;; it is made with `define-key` - back to front, because
            ;; `define-key` prepends and a menu draws the map's own
            ;; order.
            (let ((generated
                   (make-sparse-keymap
                    (format #f "~a - ~a" indicator
                            (capitalize
                             (string-replace "-" " "
                                             (symbol->string minor-mode)))))))
              (when (*describe-function-function*)
                (define-key generated (vector 'help)
                  (list 'menu-item "Help for minor mode"
                        (lambda ()
                          ((*describe-function-function*) mm-fun)))))
              (define-key generated (vector 'turn-off)
                (list 'menu-item "Turn off minor mode" mm-fun))
              (set! menu generated)))
          (if menu
              ((*popup-menu-function*) menu event)
              (message "No menu available")))))

    (define-command (mouse-minor-mode-menu event)
      "Show minor-mode menu for EVENT on minor modes area of the mode line."
      (interactive "@e")
      (let* ((posn (event-start event))
             (window (posn-window posn)))
        ;; Emacs's `posn-object` is the lighters' own string; this
        ;; tree's mode line is one flattened string, so the run carrying
        ;; the minor-mode keymap is the nearest thing.
        (minor-mode-menu-from-indicator
         (string-property-run-at posn 'local-map) window event)))

    ;;----------------------------------------------------------------
    ;; The mode line, dragged and clicked - `mouse.el:775-800', `:871-1180'
    ;;----------------------------------------------------------------
    ;;
    ;; A mode line is a handle in GNU Emacs: `[mode-line down-mouse-1]'
    ;; drags the window's bottom edge (`mouse-drag-mode-line` →
    ;; `mouse-drag-line` → `adjust-window-trailing-edge`), the click
    ;; selects the window it belongs to, mouse-2 deletes the other windows
    ;; and mouse-3 deletes that one. The bindings are `mouse.el:3818`.

    (define *mouse-leave-buffer-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `mouse-leave-buffer-hook`: "Function to be run when
    ;; the mouse leaves a buffer" - `mouse-drag-line` runs it so that
    ;; temporary modes can turn themselves off. A parameter, as every hook
    ;; here is.

    (define (mouse-position-for-drag-line tty)
      ;; GNU Emacs's `mouse-position-for-drag-line` (`mouse.el:864`):
      ;; "Return the last mouse position observed for the purposes of
      ;; `mouse-drag-line`. If TTY is non-nil, return the last attested
      ;; position of the mouse relative to the root frame. Otherwise,
      ;; return the position of the mouse relative to the selected frame,
      ;; unless the current drag operation was produced from a touch
      ;; screen event, in which event, return the position of the active
      ;; touch-screen tool relative to the same." Touch is not carried.
      ;;--------------------------------------------------------------
      (if tty
          (mouse-position-in-root-frame)
          (mouse-absolute-pixel-position)))

    (define (mouse-drag-line start-event line)
      ;; GNU Emacs's `mouse-drag-line` (`mouse.el:871`): "Drag a mode,
      ;; header, tab or vertical line with the mouse. ... LINE must be one
      ;; of the symbols `header', `mode`, `tab' or `vertical`."
      ;;
      ;; **The sampling is absolute, and that is deliberate**: the start
      ;; event's `posn-x-y` is relative to the window it names, and while
      ;; dragging the pointer crosses into other windows - the C's own
      ;; comment (`:878`) is the history of why. The motion events a
      ;; transient map answers carry no position the drag may use, so the
      ;; display is asked where the pointer is each time.
      ;;
      ;; **The drag is a transient keymap, as `mouse-drag-track`'s is**:
      ;; this returns after installing it, the command loop reads the
      ;; motion events, and the map's own cleanup runs when a key it does
      ;; not bind arrives - the button coming up.
      ;;
      ;; Not carried: `echo-keystrokes` (the echo area has no keystroke
      ;; echo here), `window-resize-pixelwise`'s cell-vs-pixel distinction
      ;; (a cell is the display's pixel here, so `charwise` always
      ;; divides by `frame-char-size` = 1 on a terminal and by the frame's
      ;; cell on Gtk), and the `scroll-bar-movement` event, which no front
      ;; end here makes yet.
      ;;--------------------------------------------------------------
      (run-hooks (*mouse-leave-buffer-hook*))
      (let* ((start (event-start start-event))
             (window (posn-window start))
             (frame (window-frame window))
             (tty (tty-type frame))
             ;; "'charwise' means to drag by character sizes on graphical
             ;; displays."
             (charwise (not (or window-resize-pixelwise tty)))
             (position-x-y (mouse-position-for-drag-line tty))
             ;; Elisp's `(car nil)'/`(cdr nil)' are nil; Scheme's are
             ;; errors. A terminal with no mouse has no position at all,
             ;; and `mouse-position-in-root-frame` answers #f there - the
             ;; press still has to install the drag, whose `move` never
             ;; runs without a motion event.
             (position (if (eq? line 'vertical)
                           (and (pair? position-x-y) (car position-x-y))
                           (and (pair? position-x-y) (cdr position-x-y))))
             (last-position position)
             (residue 0)
             (forward #t)
             (char-size 0)
             (growth 0)
             (dragged #f)
             (old-track-mouse track-mouse)
             (exitfun #f))
        (cond
         ((memq line '(header tab))
          ;; "Drag the bottom edge of the window above it."
          ;; `window-in-direction` is not carried; nothing binds these two
          ;; line types here either (Emacs 31 binds only `mode-line` and
          ;; `vertical-line` in `mouse.el`), so this is its shape.
          (set! window #f)
          (set! char-size (frame-char-height frame)))
         ((eq? line 'mode)
          ;; "LINE is a mode line or a bottom window divider. Drag the
          ;; bottom edge of its window."
          (set! char-size (frame-char-height frame)))
         ((eq? line 'vertical)
          ;; "LINE is a window divider on the right. Drag the right edge
          ;; of the window on its left."
          (let ((divider-width (frame-parameter frame 'right-divider-width)))
            (when (and (or (not (number? divider-width))
                           (= divider-width 0))
                       (eq? (frame-parameter frame 'vertical-scroll-bars) 'left))
              (set! window (window-left-sibling window))))
          (set! char-size (frame-char-width frame))))
        (let ((move
               (lambda ()
                 ;; A zero-argument procedure, because that is what the
                 ;; command loop calls a keymap's binding with here - the
                 ;; event is `*last-read-event*`, the same call
                 ;; `mouse-drag-track` makes.
                 (let ((event (*last-read-event*)))
                   (cond
                    ((not (pair? event)) #f)
                    ((eq? line 'vertical)
                     (set! position (car (mouse-position-for-drag-line tty)))
                     (set! growth (- position last-position))
                     (unless (= growth 0)
                       (when (and charwise
                                  (or (not dragged)
                                      (if forward (< growth 0) (> growth 0))))
                         (set! forward (> growth 0))
                         (set! growth
                               (if (> growth 0)
                                   (+ growth (quotient char-size 2))
                                   (- growth (quotient char-size 2)))))
                       (set! dragged #t)
                       (when charwise
                         (set! residue (remainder growth char-size))
                         (set! growth (quotient growth char-size)))
                       (unless (= growth 0)
                         (adjust-window-trailing-edge
                          window growth #t (not charwise)))
                       (set! last-position (- position residue))))
                    (else
                     (set! position (cdr (mouse-position-for-drag-line tty)))
                     (set! growth (- position last-position))
                     (unless (= growth 0)
                       (when (and charwise
                                  (or (not dragged)
                                      (if forward (< growth 0) (> growth 0))))
                         (set! forward (> growth 0))
                         (set! growth
                               (if (> growth 0)
                                   (+ growth (quotient char-size 2))
                                   (- growth (quotient char-size 2)))))
                       (set! dragged #t)
                       (when charwise
                         (set! residue (remainder growth char-size))
                         (set! growth (quotient growth char-size)))
                       (unless (= growth 0)
                         (adjust-window-trailing-edge
                          window growth #f (not charwise)))
                       (set! last-position (- position residue)))))))))
          ;; Start tracking. "The special value `dragging` signals the
          ;; display engine to freeze the mouse pointer shape for as long
          ;; as we drag" - the shape is not carried; the value is truthy,
          ;; which is what the front end reads.
          (set! track-mouse 'dragging)
          (set! exitfun
                (set-transient-map
                 (let ((map (km:keymap '*mouse-drag-line-map*)))
                   (define-key map (kbd "<switch-frame>") ignore)
                   (define-key map (kbd "<select-window>") ignore)
                   (define-key map (kbd "<scroll-bar-movement>") ignore)
                   (define-key map (kbd "<mouse-movement>") move)
                   ;; "Swallow drag-mouse-1 events to avoid selecting some
                   ;; other window."
                   (define-key map (kbd "<drag-mouse-1>")
                               (lambda () (exitfun)))
                   ;; "Some of the events will of course end up looked up
                   ;; with a mode-line, header-line or vertical-line prefix
                   ;; ..."
                   (define-key map (kbd "<mode-line>") map)
                   (define-key map (kbd "<header-line>") map)
                   (define-key map (kbd "<tab-line>") map)
                   (define-key map (kbd "<vertical-line>") map)
                   ;; "... and some maybe even with a right- or
                   ;; bottom-divider or left- or right-margin prefix ..."
                   (define-key map (kbd "<right-divider>") map)
                   (define-key map (kbd "<bottom-divider>") map)
                   (define-key map (kbd "<left-margin>") map)
                   (define-key map (kbd "<right-margin>") map)
                   map)
                 #t
                 (lambda () (set! track-mouse old-track-mouse)))))))

    (define-command (mouse-drag-mode-line start-event)
      "Change the height of a window by dragging on its mode line.
START-EVENT is the starting mouse event of the drag action.

If the drag happens in a mode line on the bottom of a frame and
that frame's `drag-with-mode-line' parameter is non-nil, drag the
frame instead."
      (interactive "e")
      (let* ((start (event-start start-event))
             (window (posn-window start))
             (frame (window-frame window)))
        ;; The `mouse-drag-mode-line-buffer` file-drag arm
        ;; (`mouse.el:1090-1106`) is not carried: there is no
        ;; drag-and-drop here.
        (cond
         ((not (window-live-p window)) #f)
         ((or (not (window-at-side-p window 'bottom))
              ;; "Allow resizing the minibuffer window if it's on the same
              ;; frame as and immediately below `window', and it's either
              ;; active or `resize-mini-windows' is nil."
              (let ((minibuffer-window (minibuffer-window frame)))
                (and (eq? (window-frame minibuffer-window) frame)
                     (or (not *resize-mini-windows*)
                         (minibuffer-window-active-p minibuffer-window)))))
          (mouse-drag-line start-event 'mode))
         ;; The `drag-with-mode-line` arm drags the frame
         ;; (`mouse-drag-frame-move`), which is not carried: there is no
         ;; frame-position or frame-resize machinery here.
         (else #f))))

    (define-command (mouse-drag-vertical-line start-event)
      "Change the width of a window by dragging on a vertical line.
START-EVENT is the starting mouse event of the drag action."
      (interactive "e")
      (mouse-drag-line start-event 'vertical))

    (define-command (mouse-select-window click)
      "Select the window clicked on; don't move point."
      (interactive "e")
      (mouse-minibuffer-check click)
      (let ((oframe (selected-frame))
            (frame (window-frame (posn-window (event-start click)))))
        (select-window (posn-window (event-start click)))
        (raise-frame frame)
        (select-frame frame)
        (or (eq? frame oframe)
            (set-mouse-position (selected-frame) (- (frame-width (selected-frame)) 1) 0))))

    (define-command (mouse-delete-window click)
      "Delete the window you click on.
Do nothing if the frame has just one window.
This command must be bound to a mouse click."
      (interactive "e")
      (unless (one-window-p #t)
        (mouse-minibuffer-check click)
        ;; "Only delete the window if the user hasn't moved point out of
        ;; the mode line before releasing the button."
        (when (and (eq? (posn-area (event-end click)) 'mode-line)
                   (eq? (posn-window (event-end click))
                        (posn-window (event-start click))))
          (delete-window (posn-window (event-start click))))))

    (define-command (mouse-delete-other-windows click)
      "Delete all windows except the one you click on."
      (interactive "e")
      (when (and (eq? (posn-area (event-end click)) 'mode-line)
                 (eq? (posn-window (event-start click))
                      (posn-window (event-end click))))
        (delete-other-windows (posn-window (event-start click)))))

    (define-key *default-keymap* (kbd "<down-mouse-1>") mouse-drag-region)
    (define-key *default-keymap* (kbd "<mouse-1>") mouse-set-point)
    (define-key *default-keymap* (kbd "<drag-mouse-1>") mouse-set-region)

    ;; `mouse.el:3818-3826': the mode line is a drag handle and the click
    ;; selects its window; the vertical line between side-by-side windows
    ;; is dragged the same way.
    (define-key *default-keymap* (kbd "<mode-line> <down-mouse-1>")
      mouse-drag-mode-line)
    (define-key *default-keymap* (kbd "<mode-line> <mouse-1>")
      mouse-select-window)
    (define-key *default-keymap* (kbd "<mode-line> <mouse-2>")
      mouse-delete-other-windows)
    (define-key *default-keymap* (kbd "<mode-line> <mouse-3>")
      mouse-delete-window)
    (define-key *default-keymap* (kbd "<vertical-line> <down-mouse-1>")
      mouse-drag-vertical-line)
    (define-key *default-keymap* (kbd "<vertical-line> <mouse-1>")
      mouse-select-window)

    ;; `mouse.el:199-206': the press is remembered, and the release is
    ;; translated into `mouse-2` when it is a click on a link. Both
    ;; bindings are procedures, which is what `key-translation-translate`
    ;; calls.
    (define-key *key-translation-map* (kbd "<down-mouse-1>")
      mouse--down-1-maybe-follows-link)
    (define-key *key-translation-map* (kbd "<double-down-mouse-1>")
      mouse--down-1-maybe-follows-link)
    (define-key *key-translation-map* (kbd "<mouse-1>")
      mouse--click-1-maybe-follows-link)
    (define-key *key-translation-map* (kbd "<double-mouse-1>")
      mouse--click-1-maybe-follows-link)

    ;; `show_help_echo` (`keyboard.c:2259`) applies
    ;; `mouse-fixup-help-message` to every help string it is about to
    ;; display. That function is this library's and `keyboard.scm` is
    ;; below it, so it arrives there through this seam.
    (*mouse-fixup-help-message-function* mouse-fixup-help-message)

    ))
