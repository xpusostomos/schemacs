(define-library (schemacs minibuffer)
  ;; This library mirrors GNU Emacs's `minibuffer.el' and the part of
  ;; `minibuffer.c' behind it: reading a line in the echo area with its
  ;; history, the completion table and the commands over it, and the
  ;; yes/no readers built on top.
  ;;
  ;; GNU Emacs's minibuffer is a real buffer with its own keymap, read by a
  ;; recursive edit - the same command loop, called again. Being a buffer is
  ;; what makes it an editor: C-f, C-a, C-k, M-f, C-y and DEL all work in
  ;; the prompt with no code of their own, because they are the ordinary
  ;; commands operating on the current buffer, and the minibuffer IS the
  ;; current buffer while it is active. That is why this library needs
  ;; `(schemacs keyboard)' - for the recursive edit - and why it can
  ;; be a leaf now that the command loop is a library of its own.
  ;;
  ;; **The prompt is text in the buffer**, which is where `read_minibuf`
  ;; puts it (`minibuf.c:858`) - it carries the `field' property that
  ;; `minibuffer-prompt-end` scans for and the `minibuffer-prompt' face
  ;; that colours it, so the echo area's row is drawn from the buffer like
  ;; any other window's. A message shown while the prompt is up is an
  ;; *overlay* at the end of that buffer (`minibuffer-message`), because
  ;; the row is showing the answer being typed.
  ;;
  ;; Two definitions that sit under the Completion banner above are *not*
  ;; here, because they are files.el's and ask about saving:
  ;; `save-answer-char->decision' and `save-some-buffers'. They go to
  ;; `(schemacs files)' with the file-visiting commands, which are
  ;; still in the frontend.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
 (only (schemacs undo) text-editor-undo-disable!)
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs character) kbd)
    (scheme base)
    (scheme char)
    ;; `read-from-minibuffer' takes an optional keymap, history and default,
    ;; which is a `case-lambda'.
    (scheme case-lambda)
    (prefix (schemacs keymap) km:)
    ;; `string-prefix?' is Guile's, not R7RS's: completion is written with
    ;; it, and leaving it out reports as an unbound variable the first time
    ;; a completion is tried.
    (only (guile) string-contains)
    ;; `format' fills in a message's arguments, as GNU Emacs's
    ;; `format-message' does for `minibuffer-message'.
    (only (guile) format)
    ;; The registry and the predicate `read-variable' completes with -
    ;; `custom.scm' imports nothing that could come back here, so this is
    ;; a safe edge. Emacs needs no import: `read-variable' is
    ;; `minibuf.c'`s and reads `Vobarray' directly.
    (only (schemacs custom) custom-variable-names custom-variable-p)
    (only (schemacs command)
          current-prefix-arg define-command run-command uarg->integer
          *command-table* command-value-of command-interactive-spec
          *read-string-function* *read-number-function*
          *read-command-function* *read-minibuffer-function*
          *eval-minibuffer-function* *read-variable-function*
          *interactive-read-function-name-function*
          *interactive-read-existing-buffer-function*
          *interactive-read-buffer-function*)
    ;; `make-buffer-string` is `editfns.c:1561`'s and is
    ;; `intervals.scm`'s - it must live below `search.scm`, which
    ;; calls it and cannot import `editfns.scm` (2026-10-13).
    (only (schemacs intervals) make-buffer-string)
    
    ;; `logior' is Guile's: the bitset is three bit flags.
    (only (guile) logior)
    ;; The `*Completions*' buffer is filled with the `face' text property
    ;; and shown in a window. (`keymap' above is `(schemacs keymap)''s,
    ;; which the completion map is built with - this library's `km:' names
    ;; are the keymap library's, not this one's.)
    (only (schemacs textprop)
          get-text-property put-text-property remove-text-properties)
    (only (schemacs buffer)
          *case-fold-search*
          *current-buffer* *inhibit-read-only*
          buffer-default-directory bury-buffer current-buffer get-buffer
          get-buffer-create record-buffer!
          buffer-fill-column set!buffer-fill-column
          set!buffer-local-keymap set!buffer-default-directory
          ;; `completion-base-position' is a variable local to `*Completions*'
          buffer-local-value erase-buffer set!mode-name
          buffer-chars-modified-tick
          set-buffer-local-value! use-local-map with-current-buffer
          ;; `read-minibuffer-1` makes the minibuffer buffer current, which
          ;; is `read_minibuf`'s `Fset_buffer (minibuffer)` (`minibuf.c:794`).
          set-buffer
          ;; `read-buffer''s completion is over the buffer registry, which
          ;; is an alist of `(NAME . BUFFER)' - see `internal-complete-buffer'
          *buffer-list* buffer-name bufferp other-buffer set-point allocate-buffer buffer-beg buffer-z buffer-pt set!buffer-read-only)
    ;; `getcwd' is Guile's, for a buffer that has no `default-directory'.
    (only (guile) getcwd)
    ;; The environment `M-:' evaluates in (`%eval-expression-environment') -
    ;; the same one the back door and the init file get. `loadup' is
    ;; `loadup.el`'s file and holds what the editor is made of.
    (only (schemacs loadup) open-user-environment!)
    ;; `(scheme eval)''s `eval' is the evaluator `eval-expression' runs,
    ;; and Guile's stack is where its `*Backtrace*' frames come from.
    (scheme eval)
    (only (guile) current-module display-backtrace make-stack)
    ;; `read' is `(scheme read)''s, not `(scheme base)''s - the trap
    ;; `(scheme write)''s `display' is in, one library over.
    (only (scheme read) read)
    (only (scheme write) display write)
    (only (schemacs window)
          ;; how `switch-to-buffer` reads its buffer name - see
          ;; `read-buffer-to-switch` below
          *read-buffer-to-switch*
          delete-window get-buffer-window pop-to-buffer
          quit-window
          split-main-window-below switch-to-buffer-other-window
          window-live-p window-min-height with-selected-window
          ;; `minibuffer_unwind` puts the minibuffer window's buffer back
          ;; from `w->prev_buffers`, which `set_window_buffer` filled in.
          window-prev-buffers set-window-prev-buffers)
    ;; `line-number-at-pos' is `fns.c''s (`fns.c:6688'), re-exported by
    ;; `editfns' so that its readers here do not move: the default
    ;; `goto-line' offers is the line point is on. It is read straight
    ;; from `fns' - with the `count_lines' it counts with, which is
    ;; `xdisp.c''s and sits beside it there - because `editfns' only
    ;; re-exports the one name. The search primitives are `search.c''s,
    ;; which have their own library now (`zap-to-char' walks with them).
    (only (schemacs editfns)
          buffer-substring buffer-substring-no-properties
          char-after char-before delete-region eolp forward-line goto-char
          insert
          line-end-position
          line-number-at-pos message point point-max point-min
          save-excursion
          ;; `goto-line`'s restriction handling (`simple.el:1690`)
          save-restriction widen buffer-narrowed-p
          ;; `goto-line-relative` is `narrow-map`'s `g`
          ;; (`bindings.el:1214`).
          narrow-map
          text-editor-cursor-column text-editor-cursor-line)
    (only (schemacs fns) %count-lines)
    ;; `forward-char' is `cmds.c''s and lives in `(schemacs cmds)'.
    (only (schemacs cmds) forward-char)
    (only (schemacs search) search-backward search-forward)
    ;; `current-column' is indent.c's, which this library is the first
    ;; user of - `set-fill-column''s bare-C-u case reads it.
    ;; `line-next-start' and `window-line-rows-at' are what
    ;; `completion-fitted-height' measures the buffer's display rows
    ;; with - `window-text-pixel-size''s answer, in rows.
    (only (schemacs indentc)
          current-column current-line-display-column
          line-next-start move-to-column window-line-rows-at
          ;; the completions window's start, which the repeated-TAB
          ;; scroll reads and `scroll-to-cursor!` moves
          window-start)
    ;; `self-insert-command' is what SPC does in a file-name minibuffer
    ;; (`minibuffer-local-filename-completion-map' below), and
    ;; `with-current-buffer' and the line motion are the ordinary
    ;; commands the minibuffer's own keys fall back on.
    ;; `special-mode' is the backtrace buffer's mode - see the note on
    ;; `%eval-expression-backtrace'.
    (only (schemacs simple) special-mode special-mode-map
       self-insert-command
       ;; the two the minibuffer's arrow keys run, and the goal column
       ;; they reset - see `next-line-or-history-element`
       next-line previous-line *temporary-goal-column*
       kill-region push-mark region-active-p
       *this-command* *last-command*
       ;; the two scroll commands the repeated TAB runs, through
       ;; `with-selected-window` as Emacs runs them
       scroll-up-command scroll-down-command
       ;; `M-<down>` past the last candidate wraps to the first unless
       ;; this is nil (`next-column-completion`, simple.el:10169).
       *completion-auto-wrap*
       ;; `goto-line`'s: whether it may widen for good when the line it
       ;; is asked for is outside the visible portion (`simple.el:7691`).
       widen-automatically
       ;; the region-overlay updater's minibuffer arm asks
       ;; `minibuffer-selected-window`, which is this library's; the seam
       ;; is installed at the end of the file.
       *minibuffer-selected-window-function*)
    ;; `minibuffer-message` is an *overlay* with an `after-string`
    ;; (`minibuffer.el:836`), which is what draws it after the input
    ;; instead of over it - and the two message hooks in
    ;; `(schemacs frame)` are this library's, installed below.
    (only (schemacs buffer)
          make-overlay overlay-put delete-overlay overlays-at)
    (only (schemacs core timer) cancel-timer run-at-time)
    ;; `cursor-in-echo-area` is `dispnew.c`'s; `read-key`'s prompt puts the
    ;; cursor in the echo area, which is what `read-char-from-minibuffer`
    ;; reproduces.
    (only (schemacs dispnew) *cursor-in-echo-area*)
    ;; `minibuffer_unwind` reads the start and point `set_window_buffer`
    ;; recorded as markers.
    (only (schemacs marker) marker-position)
    (only (schemacs frame)
          *current-frame* *echo-area-buffer* *minibuffer*
          *set-message-function* *clear-message-function* *minibuf-0*
          echo-area-message-buffer
          frame-height select-window selected-window set!frame-message
          frame-minibuffer-window set-window-buffer! window-type?
          set-message! set-window-point! window-buffer window-height
          window-list window-width
          ;; the completions window's display, as
          ;; `completion--in-region-1` reads and moves it
          frame-visible-p set-window-start! window-frame window-point)
    ;; `try-completion' and `all-completions' are `minibuf.c''s and live in
    ;; `(schemacs minibuf)'; this library is `minibuffer.el' and uses
    ;; them rather than defining them.
    (only (schemacs minibuf)
          *history-add-new-input*
          *read-buffer-function*
          *read-buffer-completion-ignore-case* *completion-ignore-case*
          all-completions test-completion try-completion)
    ;; `apply-partially' is `subr.el''s, and `internal-complete-buffer-except'
    ;; is written with it, as Emacs writes it.
    (only (schemacs subr) apply-partially error-message-string)
    ;; `caddr' is `(scheme cxr)'s: a style's entry in
    ;; `completion-styles-alist' is a four-element list.
    (only (scheme cxr) caddr)

    ;; The recursive edit the minibuffer is read by: the same command loop,
    ;; called again.
    (only (schemacs keyboard)
          abort-recursive-edit exit-recursive-edit read-key-event
          recursive-edit signal-quit
          ;; `yes-or-no-p`'s pause after an answer that is neither yes
          ;; nor no is `sit-for`'s, `sleep-for` being unported.
          sit-for
          ;; `completion--in-region-1` asks whether the repeated key was
          ;; S-TAB; `this-command-keys` is how it knows.
          *this-command-keys*)
    ;; The event model, for `read-char-from-minibuffer': it asks the
    ;; key *event* what it is, `char-alt' being `lisp.h''s lowest
    ;; modifier bit - the boundary between a plain character and a
    ;; modified key - and `event-convert-list', the C's way to name one
    ;; key's event from its description.
    (only (schemacs character) char-alt event-convert-list)
    ;; `read-char-from-minibuffer' reads the one key that answers it with
    ;; the command loop's read, so a pushed-back event reaches it too;
    ;; what it draws with is the display's `render!'.
    (only (schemacs xdisp) render!
          ;; the repeated TAB's test, and the scrolling `M-<down>` gets
          ;; from the display when point leaves the window
          pos-visible-in-window-p scroll-to-cursor!)
    ;; The global map `minibuffer-local-map' is built from, and the local
    ;; map it becomes while it is read.
    (only (schemacs keymap)
          define-key *current-keymap* *default-keymap*)
    )

  (export
   *minibuffer-completion-table*
   *completion-styles*
   choose-completion
   completion--do-completion
   completion--complete-and-exit completion-complete-and-exit
   completion-list-mode-map
   display-completion-list
   completion--nth-completion
   completion-all-completions
   completion-basic-all-completions
   completion-basic-try-completion
   completion-boundaries
   completion-styles-alist
   completion-substring-all-completions
   completion-substring-try-completion
   completion-try-completion
   completing-read
   read-buffer
   read-buffer-to-switch
   confirm-nonexistent-file-or-buffer
   *confirm-nonexistent-file-or-buffer*
   internal-complete-buffer internal-complete-buffer-except
   complete-with-action completion-table-with-predicate
   minibuffer-with-setup-hook
   minibuffer--bitset
   minibuffer-complete-and-exit
   minibuffer-complete-word
   minibuffer-local-must-match-map
   *completion-auto-help*
   *completions-format*
   *completions-max-height*
   *completion-setup-hook*
   *completion-show-help*
   *completion-show-inline-help*
   *completions-header-format*
   completion-setup-function
   completions-header-string
   *minibuffer-completion-confirm*
   minibuffer-confirm-exit-commands
   *minibuffer-completing-file-name*
   *insert-default-directory*
   list-ref-or
   *minibuffer-exit-hook*
   *minibuffer-setup-hook*
   *minibuffer-message-timeout*
   *minibuffer-message-clear-timeout* *minibuffer-message-properties*
   *minibuffer--message-timer* *minibuffer--message-overlay*
   minibuffer--message-overlay-pos minibuffer--delete-message-overlay
   set-minibuffer-message clear-minibuffer-message
   completion--map-for
   completion--insert-strings
   completion--message
   completion--selected-candidate
   minibuffer-choose-completion
   minibuffer-completion-exit
   minibuffer-hide-completions
   minibuffer-local-filename-completion-map
   minibuffer-message
   minibuffer-next-completion
   minibuffer-previous-completion
   minibuffer-restore-windows
   *minibuffer-completion-predicate*
   common-prefix
   completion-candidates-message
file-name-history
   buffer-name-history
   minibuffer-default-prompt-format
   format-prompt
   read-number
read-number-history
   goto-line
   goto-line-history
   ;; `eval-expression' and its variables, from `simple.el'
   eval-expression eval-expression-print-format read--expression
   eval-expression-get-print-arguments
   read--expression-map read--expression-try-read
   ;; the minibuffer's own bindings, for a caller that must *replace*
   ;; `minibuffer-local-map` with one of its own and keep them -
   ;; `rmc.scm`'s choice map is the second such caller.
   minibuffer-local-bindings minibuffer-map-from-bindings
   debugger-quit debugger-mode-map
   *eval-expression-print-maximum-character* *eval-expression-debug-on-error*
   read-expression-history
   set-fill-column
   zap-to-char
   goto-line-read-args goto-line-relative
   make<minibuffer>
   minibuffer-complete
   minibuffer-completion-help
   minibuffer-contents minibuffer-contents-no-properties
   minibuffer-cursor-column
   minibuffer-history
   minibuffer-insert!
   minibuffer-local-completion-map
   minibuffer-local-map
   minibuffer-position
   minibuffer-prompt
   minibuffer-prompt-end
   minibuffer-prompt-string
   minibuffer-set-contents!
   minibufferp
   next-history-element
   next-line-or-history-element
   previous-history-element
   previous-line-or-history-element
   read-char-from-minibuffer
   read-from-minibuffer exit-minibuffer
   read-string
   read-command read-variable read-minibuffer eval-minibuffer
   custom-variable-history
   ;; the history record itself, for the libraries that hold their own
   ;; histories - `replace.el''s `query-replace-history' - the way
   ;; `read-number-history' would have wanted its accessors exported
   make<history> history? history-entries set!history-entries
   execute-extended-command *extended-command-history*
   yes-or-no-p yes-or-no-prompt yes-or-no-p-history
   ;; `minibuf.c`'s `Vminibuffer_selected_window`
   *minibuffer-selected-window* minibuffer-selected-window
   )

  (begin

    (define *minibuffer-selected-window* (make-parameter #f))
    ;; ^ GNU Emacs's `Vminibuffer_selected_window` (`minibuf.c`): the
    ;; window that was selected when the prompt began. `read_minibuf`
    ;; records it because the read *selects the minibuffer window*
    ;; (`minibuf.c:839`), so `(selected-window)` during a prompt is the
    ;; prompt's window and not the one being edited.

    (define (minibuffer-selected-window)
      ;; GNU Emacs's `minibuffer-selected-window`: "Return the window
      ;; selected before the minibuffer was entered. If the minibuffer is
      ;; not active, return nil." The C also tests `WINDOW_LIVE_P`; a
      ;; window here is live until it is deleted, and a deleted one is not
      ;; what a prompt would have recorded.
      ;;--------------------------------------------------------------
      (and (*minibuffer*) (*minibuffer-selected-window*)))

    ;;----------------------------------------------------------------
    ;; The minibuffer
    ;;
    ;; GNU Emacs's minibuffer is a real buffer with its own keymap, read
    ;; by a recursive edit - the same command loop, called again. Being a
    ;; buffer is what makes it an editor: C-f, C-a, C-k, M-f, C-y and DEL
    ;; all work in the prompt with no code of their own, because they are
    ;; the ordinary commands operating on the current buffer, and the
    ;; minibuffer IS the current buffer while it is active. (Emacs keeps
    ;; the selected window showing the original buffer while this is so,
    ;; which is exactly what the renderer does here.)
    ;;
    ;; The prompt is kept beside the buffer rather than in it: Emacs puts
    ;; it in the buffer as the `minibuffer-prompt' text property, and
    ;; this editor has no text properties wired to the display yet.
    ;;------------------------------------------------------------------

    (define-record-type <history>
      ;; A minibuffer history: GNU Emacs's `minibuffer-history' and
      ;; `file-name-history' are variables holding a list of previously
      ;; entered strings, so this is a mutable cell rather than a
      ;; parameter - a prompt has to be able to add to it for the next
      ;; prompt to see.
      (make<history> entries)
      history?
      (entries history-entries set!history-entries))

    (define minibuffer-history (make<history> '()))
    (define file-name-history (make<history> '()))
    (define custom-variable-history (make<history> '()))
    (define read-number-history (make<history> '()))
    ;; ^ GNU Emacs's `read-number-history' (`subr.el'), the history the
    ;; number prompts share. It is here beside `file-name-history' -
    ;; which is `files.el''s but lives here for the same reason - because
    ;; the history records are this library's, and `subr.sld' cannot
    ;; import them: minibuffer.sld already imports keyboard.sld, which
    ;; imports subr.sld, so subr -> minibuffer would be a cycle.
    (define buffer-name-history (make<history> '()))
    ;; ^ GNU Emacs's `buffer-name-history' (`minibuf.c:2515', the C's
    ;; `DEFSYM'/`Fset (..., Qnil)' pair - the same two lines that make
    ;; `minibuffer-history' on the line above, which is why they are in the
    ;; same place). It is the history `read-buffer' reads with, and so the
    ;; one `C-x b' completes its names against.
    ;;
    ;; **What is *not* a departure is how a prompt is handed one.** Emacs's
    ;; `completing-read' takes HIST as a *symbol* and looks the variable's
    ;; value up itself, so passing `buffer-name-history' there costs
    ;; nothing. This tree passes the `<history>' record. `read-buffer' was
    ;; written against the parameter this variable used to be, which put a
    ;; parameter where a record is wanted - and since a parameter is only
    ;; read when the answer is *added* to it, the failure landed at RET:
    ;; `Wrong type argument: #<<parameter> ...>' and a `C-x b' that would
    ;; not leave the minibuffer. A value crossing this seam has to be the
    ;; shape the receiving library wants, not the shape the library that
    ;; declares it happens to use.

    (define-record-type <minibuffer-type>
      (make<minibuffer>
       editor prompt keymap default history position content)
      minibuffer-type?
      (editor   minibuffer-editor   set!minibuffer-editor)
      ;; ^ The <buffer> holding what has been typed.
      (prompt   minibuffer-prompt-string set!minibuffer-prompt-string)
      (keymap   minibuffer-keymap   set!minibuffer-keymap)
      (default  minibuffer-default  set!minibuffer-default)
      (history  minibuffer-history-of set!minibuffer-history-of)
      ;; ^ Where this prompt's answers are remembered.
      (position minibuffer-position set!minibuffer-position)
      ;; ^ How far back in the history the input has been taken, 0 being
      ;; what the user typed rather than anything from the history.
      (content  minibuffer-typed-content set!minibuffer-typed-content)
      ;; ^ What the user had typed before stepping into the history, so
      ;; that stepping back out of it returns to it (Emacs's
      ;; `minibuffer-history-position' does the same job).
      )

    ;; GNU Emacs's `current-buffer' - the buffer commands act on, which
    ;; is the minibuffer's while one is active. It lives in
    ;; `(schemacs frame)' now, beside the frame state it is a fact
    ;; about, and `MINIBUFFER-EDITOR' is what the minibuffer binds to put
    ;; itself there.

    (define (minibufferp)
      ;; Whether the minibuffer is active: GNU Emacs's `minibufferp'.
      ;;--------------------------------------------------------------
      (and (*minibuffer*) #t))

    (define (minibuffer-contents . args)
      ;; What has been typed in the minibuffer: GNU Emacs's
      ;; `minibuffer-contents' (`minibuf.c:527'), whose whole body is
      ;; `make_buffer_string (prompt_end, ZV, 1)' - PROPS true, so the
      ;; text properties come with it. The optional argument is this
      ;; tree's (Emacs's takes none and works on the current buffer);
      ;; without one the active minibuffer is read.
      ;;
      ;; **It was `minibuffer-contents-no-properties' wearing this
      ;; name.** Its body was `text-editor-to-string', which passes no
      ;; PROPS, so every caller got plain text where Emacs's returns the
      ;; propertized one; that function is gone (2026-10-13) and this is
      ;; the C's line. The prompt is in neither answer here, as it is in
      ;; neither in Emacs - `prompt_end' to `ZV' is the user's input,
      ;; and this tree draws the prompt in the echo area.
      ;;--------------------------------------------------------------
      (let ((mb (if (pair? args) (car args) (*minibuffer*))))
        (if mb
            (let ((beg (%minibuffer-prompt-end mb)))
              (with-current-buffer (minibuffer-editor mb)
                (buffer-substring beg (point-max))))
            #f)))

    (define (minibuffer-contents-no-properties . args)
      ;; GNU Emacs's `minibuffer-contents-no-properties'
      ;; (`minibuf.c:537'): "Return the user input in a minibuffer as a
      ;; string, without text-properties" - the same read with PROPS
      ;; false, `make_buffer_string (prompt_end, ZV, 0)'.
      ;;
      ;; It had no counterpart here until 2026-10-13, because the one
      ;; function above was doing its job under the other name.
      ;;--------------------------------------------------------------
      (let ((mb (if (pair? args) (car args) (*minibuffer*))))
        (if mb
            (let ((beg (%minibuffer-prompt-end mb)))
              (with-current-buffer (minibuffer-editor mb)
                (buffer-substring-no-properties beg (point-max))))
            #f)))

    (define (minibuffer-set-contents! mb text)
      ;; Replace what has been typed, leaving point at the end, the way
      ;; stepping through the history does.
      ;;
      ;; GNU Emacs's shape is `goto-history-element`'s body
      ;; (`simple.el:3100'): point to the end, `delete-minibuffer-contents`
      ;; (minibuf.c - the prompt sits *beside* this buffer here rather than
      ;; in it, so the whole of it goes), then `insert`. The old body
      ;; parked point at the beginning before deleting, because the
      ;; engine's delete runs *forward* from the cursor - a wart of that
      ;; primitive, not of this function - and with `delete-region`, which
      ;; takes both ends, it is gone.
      ;;--------------------------------------------------------------
      (let ((ed (minibuffer-editor mb))
            (beg (%minibuffer-prompt-end mb)))
        (text-editor-undo-disable! ed)
        (with-current-buffer ed
          ;; from the *prompt's* end: the prompt is in the buffer now, as
          ;; it is in Emacs's, and it is not part of what is replaced
          (delete-region beg (point-max))
          (insert text))))

    (define (minibuffer-insert! text)
      ;; Add TEXT to what has been typed, for the completion commands.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (when mb
          (with-current-buffer (minibuffer-editor mb) (insert text)))))

    (define (minibuffer-prompt)
      ;; The prompt of the active minibuffer, as the echo area draws it.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (and mb (minibuffer-prompt-string mb))))

    (define (minibuffer-cursor-column)
      ;; The screen column the cursor belongs in while the minibuffer is
      ;; active: the prompt, then what has been typed up to point.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (and mb
             ;; **No prompt length added**: the prompt is in the buffer
             ;; now, so the buffer column (and the row's own scan) counts
             ;; it. It used to be `(string-length prompt) + cursor-column`,
             ;; which is the same answer only while the prompt is plain
             ;; text of one cell per character.
             (current-line-display-column
              (minibuffer-editor mb)
              (text-editor-cursor-column (minibuffer-editor mb))))))

    (define (%minibuffer-unwind mini state)
      ;; GNU Emacs's `minibuffer_unwind` (`minibuf.c:1231`): put the
      ;; minibuffer window back the way it was before the prompt took it.
      ;;
      ;; The C pops `w->prev_buffers`, which `set_window_buffer` filled
      ;; in, and restores that buffer with its start and point. **This
      ;; captures the same three things before the read instead**, because
      ;; the unwind here runs *twice*: the command loop's exit
      ;; continuation is a full continuation, so leaving the recursive
      ;; edit leaves the `dynamic-wind` and entering it again re-runs the
      ;; after thunk. Emacs's `record_unwind_protect` runs once, so its
      ;; pop is safe; a pop here puts back the buffer the first run
      ;; recorded - the dead prompt - and the row shows the prompt for
      ;; ever. Setting the same state twice is the same as setting it
      ;; once, which is what this needs to be.
      ;;
      ;; **Without this the window kept the prompt's buffer**, which is
      ;; why the echo area used to be painted by hand instead of
      ;; displayed.
      ;;--------------------------------------------------------------
      (when (and state mini (window-type? mini))
        (set-window-buffer! mini (car state))
        (set-window-start! mini (cadr state))
        (set-window-point! mini (caddr state))))

    (define (read-minibuffer-1 prompt initial keymap history default)
      ;; The body of `read-from-minibuffer'.
      ;;
      ;; INITIAL is the string to put in the minibuffer before reading -
      ;; or the pair `(STRING . POSITION)', which `read_minibuf' also
      ;; takes (minibuf.c:614). POSITION is *one-indexed* and counts from
      ;; the start of STRING, and anything one or less means its
      ;; beginning; a POSITION that is not a number means point at the
      ;; end, which is where a plain string leaves it. `completing-read'
      ;; counts the same position from zero and adds one before it gets
      ;; here (minibuffer.el:5214), because the two functions disagree.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             ;; **The selected window when the prompt began.** The read
             ;; selects the minibuffer window (`read_minibuf`,
             ;; `minibuf.c:840`), and puts this one back on the way out -
             ;; the C's `record_unwind_protect` of the selection - so a
             ;; click or a `C-x o` that left the prompt selected elsewhere
             ;; does not leave the command that asked working in a
             ;; one-row window at the bottom of the frame.
             (entry-window (selected-window))
             (ed (allocate-buffer))
             (text (if (pair? initial) (car initial) initial))
             ;; **What the minibuffer window was showing, and where**:
             ;; captured before the prompt takes the window, for
             ;; `%minibuffer-unwind`'s reason.
             (mini-state
              (let ((mini (and frame (frame-minibuffer-window frame))))
                (and mini (window-buffer mini)
                     (list (window-buffer mini)
                           (window-start mini)
                           (window-point mini)))))
             (_ (and frame (set!frame-message frame "")))
        ;; ^ GNU Emacs's `clear_message (1, 1)` (`minibuf.c:905`) at the
        ;; top of `read_minibuf`: the echo area's message goes before the
        ;; prompt takes the row. Without it a message the last command
        ;; left - the answer `map-y-or-n-p` echoes after its question -
        ;; is what the renderer shows *instead of this prompt*
        ;; (`display_echo_area` draws `echo_area_buffer[0]` when it is
        ;; non-nil, `xdisp.c:13783`), so a second question appeared only
        ;; when the next keypress's redisplay cleared it.
             ;; point, counting from zero into TEXT, or #f for its end
             (at (if (not (pair? initial))
                     #f
                     (let ((n (cdr initial)))
                       (cond ((not (integer? n)) #f)
                             ((< n 1) 1)
                             (else n))))))
        ;; Emacs disables undo in the minibuffer.
        (text-editor-undo-disable! ed)
        ;; **The prompt goes into the buffer**, which is what
        ;; `read_minibuf` does (`minibuf.c:858`):
        ;;
        ;;   Finsert (1, &minibuf_prompt);
        ;;   Fput_text_property (BEG, PT, Qfront_sticky, Qt, ...);
        ;;   Fput_text_property (BEG, PT, Qrear_nonsticky, Qt, ...);
        ;;   Fput_text_property (BEG, PT, Qfield, Qt, ...);
        ;;   ... every pair of `minibuffer-prompt-properties' ...
        ;;   minibuf_prompt_width = current_column ();
        ;;
        ;; **This was the departure the old note here named**: the prompt
        ;; was painted by the echo-area code instead, so the row the
        ;; minibuffer window drew was not the row Emacs draws. Putting it
        ;; in the buffer is what lets the window draw the whole row
        ;; through the ordinary glyph-matrix path - the prompt's face is
        ;; then the `face' text property `faces.el:2931' appends to
        ;; `minibuffer-prompt-properties', and `minibuffer-prompt-end'
        ;; finds its end by the `field' property, as `minibuf.c:521` does.
        (with-current-buffer ed
          (let ((beg (point-min)))
            (insert prompt)
            (let ((end (point-max)))
              (put-text-property beg end 'front-sticky #t ed)
              (put-text-property beg end 'rear-nonsticky #t ed)
              (put-text-property beg end 'field #t ed)
              ;; `minibuffer-prompt-properties` is `(read-only t)` in the
              ;; C (`minibuf.c:2698`) with `(face minibuffer-prompt)`
              ;; appended by `faces.el:2931`.
              (put-text-property beg end 'read-only #t ed)
              (put-text-property beg end 'face 'minibuffer-prompt ed))
            ;; ... and the initial input after it, with point where the
            ;; caller asked for - the C's `Finsert (initial)` and
            ;; `Fforward_char (pos)`, with `pos` counted from the end of
            ;; the initial text
            (when text (insert text))
            (set-point ed (if at (+ (- (point-max) (string-length text)) (- at 1))
                              (point-max)))))
        (let ((mb (make<minibuffer>
                   ed prompt (or keymap minibuffer-local-map) default
                   ;; HIST nil is the default history. HIST t is "do
                   ;; not record this answer" (`read-from-minibuffer`'s
                   ;; docstring, minibuf.c:1331): Emacs leaves the symbol
                   ;; t in `Vminibuffer_history_variable`, and
                   ;; `add-to-history`'s `(listp history)` is false for
                   ;; it, so nothing is recorded. Here it is stored as
                   ;; #t and the four readers below answer "no entries"
                   ;; for it, the same `listp` test.
                   (or history minibuffer-history)
                   0 #f)))
          ;; The minibuffer inherits the *asking* buffer's
          ;; `default-directory', as Emacs's does: a relative name typed in
          ;; the prompt is relative to the buffer that asked, not to the
          ;; minibuffer.
          ;;
          ;; It has to be copied here and not read later, because while the
          ;; prompt is being read `current-buffer' is the *minibuffer*, and
          ;; asking it then answers the process's directory instead - so
          ;; completing a file name offered the editor's own directory
          ;; rather than the one being typed about.
          (set!buffer-default-directory
           ed (or (buffer-default-directory (current-buffer)) (getcwd)))
          ;; **The minibuffer's keymap is its buffer's**, which is
          ;; where `read_minibuf' puts it: `bset_keymap (current_buffer,
          ;; map)' (`minibuf.c:906'), the buffer-local slot `use-local-map`
          ;; writes. So the map follows the *buffer* the command loop is
          ;; looking at, not this dynamic extent - which is what lets a
          ;; click into another window make that window's buffer current
          ;; and its own keymap live, while the prompt stays on screen and
          ;; on the stack. Held in `*current-keymap*` instead, the map was
          ;; pinned for the whole read and every click went on typing into
          ;; the prompt.
          ;;
          ;; **ED, and not `(current-buffer)`**: the parameterize below
          ;; has not run yet, so the current buffer here is still the
          ;; *asking* one. Emacs has the same order and gets away with it
          ;; because it made the minibuffer buffer current first
          ;; (`Fset_buffer (minibuffer)`, `minibuf.c:794`, long before
          ;; `read_minibuf` is entered).
          (set!buffer-local-keymap ed (minibuffer-keymap mb))
          ;; The current buffer is restored when the read is over, however
          ;; it was left: `read_minibuf' (minibuf.c:675) does
          ;; `record_unwind_current_buffer' for exactly this. Without it,
          ;; any `set-buffer' the prompt's own commands ran - a
          ;; `save-excursion' restoring the buffer it found current, which
          ;; while the prompt is read is the prompt's echo-area editor -
          ;; *pins* that editor in `*current-buffer*', and every command
          ;; after the prompt acts on it: write-file then saved the echo
          ;; editor's text to the file it was given.
          (parameterize ((*minibuffer* mb)
                         (*echo-area-buffer* ed)
                         ;; the window being edited, which the read is
                         ;; about to take the selection from
                         (*minibuffer-selected-window* entry-window)
                         ;; **`(*current-buffer* #f)` is the unwind, and
                         ;; the `set-buffer` inside is the value** - which
                         ;; is `read_minibuf`'s `Fset_buffer (minibuffer)`
                         ;; (`minibuf.c:794`) followed by its
                         ;; `record_unwind_current_buffer` (`:675`). The
                         ;; parameterize puts the asking buffer back when
                         ;; the read ends, however the prompt's commands -
                         ;; or a click in another window - left it.
                         (*current-buffer* #f))
            (set-buffer ed)
            ;; **The minibuffer *window* shows the prompt's buffer, and
            ;; is the selected window.** GNU Emacs's `read_minibuf` does
            ;; both, one line after the other (`minibuf.c:839`, `:840`):
            ;;
            ;;   set_window_buffer (minibuf_window, Fcurrent_buffer (), 0, 0);
            ;;   Fselect_window (minibuf_window, Qnil);
            ;;
            ;; The prompt is therefore not a state the frame knows about
            ;; but a *buffer in a window*, which is why a click on it
            ;; selects it and `C-x o` cycles out of it. **The selection
            ;; is not decoration**: with the asking window still selected
            ;; and the minibuffer buffer current, every command that reads
            ;; `(selected-window)` together with `(current-buffer)` sees
            ;; two different buffers - `<down>` in a prompt ran
            ;; `next-line`, whose `line-move-visual` took the window's
            ;; lines from the body buffer and point's offset from the
            ;; prompt, and died in `vector-ref` - and `C-x o` from the
            ;; prompt stepped *onto* the minibuffer window instead of out
            ;; of it, so leaving took two presses where Emacs takes one.
            ;; It is what `minibuffer-window-active-p` reads, too.
            (let ((mini (and frame (frame-minibuffer-window frame))))
              (when mini
                (set-window-buffer! mini ed)
                (select-window mini)))
            ;; `minibuffer-setup-hook', run where the C runs it: after
            ;; the prompt and the initial input are in place, before the
            ;; recursive edit that reads (minibuf.c:912).
            (for-each (lambda (hook) (hook)) (*minibuffer-setup-hook*))
            ;; **The selected window is put back however the read ends**,
            ;; which is `read_minibuf`'s `record_unwind_protect` of the
            ;; window selection. A `dynamic-wind` and not a statement
            ;; after the read, because a quit unwinds past everything
            ;; between: C-g must leave the body window selected too.
            (dynamic-wind
             (lambda () #t)
             (lambda ()
            (let ((result (recursive-edit frame)))
              ;; `minibuffer-exit-hook', which GNU Emacs runs on the way
              ;; out however the minibuffer was left - RET, C-g, or a
              ;; command that left of its own accord. It is what takes
              ;; the `*Completions*' window away again, and it runs
              ;; *before* a quit's thunk, so that the window is gone
              ;; even though the signal about to be raised unwinds past
              ;; everything else.
              (for-each (lambda (hook) (hook)) (*minibuffer-exit-hook*))
              (if (procedure? result)
                  ;; a quit: run the thunk, which signals, so the signal
                  ;; travels out past the minibuffer and abandons the
                  ;; command that asked (Emacs's
                  ;; `minibuffer-quit-recursive-edit')
                  (result)
                  (let* ((typed (minibuffer-contents mb))
                         ;; an empty answer takes the default, as
                         ;; `completing-read' does
                         (answer (if (and (= 0 (string-length typed)) default)
                                     default
                                     typed)))
                    (when (and (*history-add-new-input*)
                               (< 0 (string-length answer)))
                      (let ((h (minibuffer-history-of mb)))
                        ;; "If HIST is t, history is not recorded."
                        (when (history? h)
                          (set!history-entries
                           h (cons answer (history-entries h))))))
                    answer))))
             ;; the unwind: the minibuffer window goes back to the buffer
             ;; it was showing, and the window this prompt began in is the
             ;; selected one again, whatever the prompt's own commands -
             ;; or a click - did to the selection
             (lambda ()
               (%minibuffer-unwind (and frame (frame-minibuffer-window frame))
                                   mini-state)
               (when (and entry-window (window-type? entry-window))
                 (select-window entry-window))))))))

    (define read-from-minibuffer
      ;; GNU Emacs's `read-from-minibuffer'. Of its arguments this takes
      ;; PROMPT, INITIAL-INPUT, KEYMAP, HISTORY and DEFAULT; `read'
      ;; (reading the text as a Lisp object rather than as a string) and
      ;; INHERIT-INPUT-METHOD are not implemented.
      ;;--------------------------------------------------------------
      (case-lambda
       ((prompt) (read-minibuffer-1 prompt #f #f #f #f))
       ((prompt initial) (read-minibuffer-1 prompt initial #f #f #f))
       ((prompt initial keymap)
        (read-minibuffer-1 prompt initial keymap #f #f))
       ((prompt initial keymap history)
        (read-minibuffer-1 prompt initial keymap history #f))
       ((prompt initial keymap history default)
        (read-minibuffer-1 prompt initial keymap history default))))

    (define-command (exit-minibuffer)
      ;; Leave the minibuffer, accepting what has been typed: GNU Emacs's
      ;; `exit-minibuffer', which is `(throw 'exit nil)'.
      "Accept what has been typed and leave the minibuffer."
      (interactive)
      (exit-recursive-edit #f))

    (define-command (previous-history-element count)
      ;; GNU Emacs's `previous-history-element': step back N entries in
      ;; the history and put that answer in the minibuffer.
      "Step back N answers in the minibuffer history."
      (interactive "p")
      (let* ((mb (*minibuffer*))
             (h (and mb (minibuffer-history-of mb)))
             (entries (if (history? h) (history-entries h) '()))
             (position (if mb (minibuffer-position mb) 0))
             (next (min (+ position count) (length entries))))
        ;; position 0 means what the user typed rather than an entry
        (when mb
          (when (= position 0)
            (set!minibuffer-typed-content mb (minibuffer-contents mb)))
          (when (< position next)
            (set!minibuffer-position mb next)
            (minibuffer-set-contents!
             mb (list-ref entries (- next 1)))))))

    (define-command (next-history-element count)
      ;; GNU Emacs's `next-history-element': step forward N entries, and
      ;; past the most recent one back to what was typed.
      "Step forward N answers in the minibuffer history."
      (interactive "p")
      (let* ((mb (*minibuffer*))
             (h (and mb (minibuffer-history-of mb)))
             (entries (if (history? h) (history-entries h) '()))
             (position (if mb (minibuffer-position mb) 0))
             (next (max 0 (- position count))))
        (when mb
          (when (< next position)
            (set!minibuffer-position mb next)
            (minibuffer-set-contents!
             mb (if (= next 0)
                    (or (minibuffer-typed-content mb) "")
                    (list-ref entries (- next 1))))))))

    (define (%minibuffer-prompt-end mb)
      ;; `minibuffer-prompt-end` for MB, with no current buffer changed.
      ;;--------------------------------------------------------------
      (let ((ed (and mb (minibuffer-editor mb))))
        (if (not ed)
            #f
            (with-current-buffer ed
              ;; The C's walk (`minibuf.c:521`): the first position whose
              ;; `field' property is not set - the prompt is the run of
              ;; characters that carries it.
              (let loop ((p (point-min)))
                (if (and (< p (point-max)) (get-text-property p 'field ed))
                    (loop (+ p 1))
                    p))))))

    (define (minibuffer-prompt-end)
      ;; GNU Emacs's `minibuffer-prompt-end' (`minibuf.c:505'): "Return
      ;; the buffer position of the end of the minibuffer prompt. Return
      ;; (point-min) if current buffer is not a minibuffer."
      ;;
      ;; The C reads the prompt's `field' text property, which
      ;; `read_minibuf' puts there with `minibuffer-prompt-properties' -
      ;; and this tree now inserts the prompt the same way, so the walk
      ;; is the same walk. Its answer outside a minibuffer is
      ;; `(point-min)` (`:521`).
      ;;--------------------------------------------------------------
      (or (%minibuffer-prompt-end (*minibuffer*)) (point-min)))

    (define-command (next-line-or-history-element arg)
      ;; GNU Emacs's `next-line-or-history-element' (`simple.el:3136'):
      ;; move down a screen line inside the minibuffer's text, and once
      ;; point is on the last one, put the next history element in.
      ;;
      ;; `next-line-add-newlines' - "Don't add newlines if they have the
      ;; mode enabled globally" - is not carried: this tree's `next-line'
      ;; has no such option to bind.
      ;;
      ;; `(minibuffer-prompt-end)' is `(point-min)' here, so the column
      ;; the prompt ends at is column 0 and the `(1- prompt-end)' the
      ;; Elisp measures against would be position 0 - out of range.
      ;; `(max (point-min) (1- prompt-end))' is the same position the
      ;; Elisp reaches when a prompt is really in the buffer, and
      ;; position 1, column 0, when it is not.
      "Move cursor vertically down ARG lines, or to the next history element.
When point moves over the bottom line of multi-line minibuffer, puts ARGth
next element of the minibuffer history in the minibuffer."
      (interactive "^p")
      (let* ((arg (or arg 1))
             (old-point (point))
             (prompt-end (minibuffer-prompt-end))
             (old-column (if (and (eolp) (> (point) prompt-end))
                             #f
                             (if (= (line-number-at-pos) 1)
                                 (max (- (current-column)
                                         (save-excursion
                                           (goto-char (max (point-min)
                                                           (- prompt-end 1)))
                                           (current-column)))
                                      0)
                                 (current-column)))))
        (guard (err (else
                     (cond
                      ((not (string=? "End of buffer"
                                      (error-message-string err)))
                       (raise err))
                      (else
                         ;; "Restore old position since `line-move-visual'
                         ;; moves point to the end of the line when it
                         ;; fails to go to the next line."
                         (goto-char old-point)
                         (next-history-element arg)
                         ;; "Reset `temporary-goal-column' because a
                         ;; correct value is not calculated when
                         ;; `next-line' above fails by bumping against the
                         ;; bottom of the minibuffer (bug#22544)."
                         (*temporary-goal-column* 0)
                         ;; "Restore the original goal column on the last
                         ;; line of possibly multi-line input."
                         (goto-char (point-max))
                         (when old-column
                           (if (= (line-number-at-pos) 1)
                               (move-to-column
                                (+ old-column
                                   (save-excursion
                                     (goto-char (max (point-min)
                                                     (- (minibuffer-prompt-end) 1)))
                                     (current-column))))
                               (move-to-column old-column)))))))
          (next-line arg))))

    (define-command (previous-line-or-history-element arg)
      ;; GNU Emacs's `previous-line-or-history-element' (`simple.el:3179'):
      ;; the same rule upwards, and the same fall to the history.
      ;;
      ;; The Elisp's "avoid moving point to the prompt" test -
      ;; `(< (point) (minibuffer-prompt-end))' - cannot be true here for
      ;; the reason `minibuffer-prompt-end' gives above: the prompt is not
      ;; in the buffer, so its end is `(point-min)' and no point is before
      ;; it. `previous-line' signals `beginning-of-buffer' at the top of
      ;; the minibuffer's text, which is the branch below.
      "Move cursor vertically up ARG lines, or to the previous history element.
When point moves over the top line of multi-line minibuffer, puts ARGth
previous element of the minibuffer history in the minibuffer."
      (interactive "^p")
      (let* ((arg (or arg 1))
             (old-point (point))
             (prompt-end (minibuffer-prompt-end))
             (old-column (if (and (eolp) (> (point) prompt-end))
                             #f
                             (if (= (line-number-at-pos) 1)
                                 (max (- (current-column)
                                         (save-excursion
                                           (goto-char (max (point-min)
                                                           (- prompt-end 1)))
                                           (current-column)))
                                      1)
                                 (current-column)))))
        (guard (err (else
                     (cond
                      ((not (string=? "Beginning of buffer"
                                      (error-message-string err)))
                       (raise err))
                      (else
                         (goto-char old-point)
                         (previous-history-element arg)
                         (*temporary-goal-column* 0)
                         (goto-char (point-max))
                         (when old-column
                           (if (= (line-number-at-pos) 1)
                               (move-to-column
                                (+ old-column
                                   (save-excursion
                                     (goto-char (max (point-min)
                                                     (- (minibuffer-prompt-end) 1)))
                                     (current-column))))
                               (move-to-column old-column)))))))
          (previous-line arg))))

    (define (minibuffer-local-bindings)
      ;; The keys GNU Emacs's `minibuffer-local-map' carries, as (KEY .
      ;; COMMAND) pairs. One list, because two maps are built from it:
      ;; the minibuffer's own, and the expression prompt's - see the note
      ;; on `read--expression-map' for why the second cannot inherit the
      ;; first.
      ;;
      ;; `<down>` and `<up>` are `next-line-or-history-element' and
      ;; `previous-line-or-history-element' (`bindings.el:1284`, `:1288`),
      ;; not `next-line`/`previous-line`: those two are global, and on a
      ;; one-line prompt they had no history to fall back on - `<down>`
      ;; signalled `End of buffer' and, before the minibuffer window was
      ;; selected, died in `vector-ref` instead.
      ;;--------------------------------------------------------------
      (list (cons (kbd "RET") exit-minibuffer)
            (cons (kbd "C-j") exit-minibuffer)
            (cons (kbd "C-g") abort-recursive-edit)
            (cons (kbd "M-p") previous-history-element)
            (cons (kbd "M-n") next-history-element)
            (cons (kbd "<next>") next-history-element)
            (cons (kbd "<prior>") previous-history-element)
            (cons (kbd "<down>") next-line-or-history-element)
            (cons (kbd "<up>") previous-line-or-history-element)))

    (define (minibuffer-map-from-bindings name bindings)
      ;; `(make-sparse-keymap NAME)' with each `(KEY . BINDING)' of
      ;; BINDINGS defined in it. GNU Emacs has no such function - a keymap
      ;; is filled with `define-key' - and this is that in a loop, because
      ;; the minibuffer's maps are each written as a table of bindings.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap name)))
        (for-each (lambda (kv) (km:define-key map (car kv) (cdr kv))) bindings)
        map))

    (define (minibuffer-filename-completion-bindings)
      ;; `minibuffer-local-filename-completion-map''s own bindings. Named
      ;; rather than written twice, because `completion--map-for' below
      ;; needs a *fresh* map with the same bindings - it composes this map
      ;; over a different base each time, as Emacs's `make-composed-keymap'
      ;; does - and two copies of a binding table can drift apart.
      ;;--------------------------------------------------------------
      (list (cons (kbd "SPC") self-insert-command)))

    (define minibuffer-local-map
      ;; GNU Emacs's `minibuffer-local-map': the minibuffer's own bindings.
      ;; RET and C-j both leave the minibuffer, C-g abandons the command
      ;; that asked, and M-p/M-n walk the history.
      ;;
      ;; It holds *only* those. GNU Emacs's map is sparse and inherits
      ;; `global-map' because a lookup searches the local map and then the
      ;; global one, so the ordinary editing keys are found without being
      ;; copied in here - and copying them was wrong twice over: it made
      ;; the minibuffer's map a snapshot of whatever the global map held
      ;; when this library loaded, and it is what `LOOKUP-KEYMAP' in
      ;; `(schemacs keyboard)' now does per lookup instead.
      ;;--------------------------------------------------------------
      (minibuffer-map-from-bindings '*minibuffer-local-map*
                                    (minibuffer-local-bindings)))


    ;;----------------------------------------------------------------
    ;; Completion
    ;;
    ;; GNU Emacs's `try-completion' and `all-completions' over a
    ;; completion table, and the commands that use them. The table is a
    ;; procedure of one argument returning the candidates, which is one
    ;; of the forms Emacs's tables may take. Emacs lists candidates in a
    ;; *Completions* window; this editor has one window and no buffer
    ;; list yet, so they are shown in the echo area instead.
    ;;------------------------------------------------------------------

    (define *minibuffer-completion-table*
      ;; The table the minibuffer completes against: GNU Emacs's
      ;; `minibuffer-completion-table'.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (completion-candidates-message candidates)
      ;; How the candidates are shown when there is nothing to complete:
      ;; one long line in the echo area, where Emacs would open a
      ;; *Completions* window.
      ;;--------------------------------------------------------------
      (let loop ((rest candidates) (acc ""))
        (if (null? rest)
            acc
            (loop (cdr rest)
                  (string-append acc (if (string=? acc "") "" "  ") (car rest))))))

    (define-command (minibuffer-completion-help)
      ;; GNU Emacs's `minibuffer-completion-help': show what the text
      ;; could complete to. A command, because `?' is bound to it.
      ;;
      ;; The candidates go in a `*Completions*' window, which is what
      ;; Emacs does and what this used to fake with one long line in the
      ;; echo area - the comment that said "this editor has one window and
      ;; no buffer list yet" stopped being true when `display-buffer'
      ;; arrived.
      ;;
      ;; Showing the window must not take point out of the prompt, which
      ;; is why it is `completion-display-window' and not `pop-to-buffer':
      ;; the minibuffer is being read by a recursive edit, and the
      ;; completion commands act on it again as soon as this returns. The
      ;; window itself is Emacs's for the list: a *fresh* window, fitted
      ;; to the candidates (see `completion-display-window').
      ;;--------------------------------------------------------------
      "Show the possible completions of the text in the minibuffer."
      (interactive)
         (let* ((typed (or (minibuffer-contents) ""))
                (candidates (completion-all-completions
                             typed (*minibuffer-completion-table*)
                             (*minibuffer-completion-predicate*)
                             (string-length typed))))
           (cond
            ((not candidates)
             (completion--message "No match"))
            (else
             ;; The answer is a dotted list whose last cdr is the base
             ;; size, so the candidates are what is before it - and the
             ;; base size is how much of TYPED they leave out, which for a
             ;; file name is its directory. Emacs records where that puts
             ;; the completion in the minibuffer as
             ;; `completion-base-position', a variable local to the
             ;; `*Completions*' buffer, `(list (+ start base-size) end)';
             ;; the minibuffer's text starts at 0 here, the prompt being
             ;; beside it rather than in it.
             (let* ((base-size (let loop ((rest candidates))
                                 (if (pair? rest) (loop (cdr rest)) (or rest 0))))
                    (all (let loop ((rest candidates) (acc '()))
                           (if (not (pair? rest))
                               (reverse acc)
                               (loop (cdr rest) (cons (car rest) acc)))))
                    (buffer (get-buffer-create "*Completions*")))
               ;; Emptying the list is the *caller's* work, which is
               ;; GNU Emacs's `temp-buffer-window-setup` (`window.el:91')
               ;; run by this command through `with-current-buffer-window`.
               ;; `display-completion-list` only appends - it goes to
               ;; `point-max` and inserts - so without this the list before
               ;; would still stand in front of the new one. The recorded
               ;; selection goes with it: the range it names would point
               ;; into the list being thrown away.
               (clear-completions-selection!)
               (with-current-buffer buffer
                 (set!buffer-local-keymap buffer completion-list-mode-map)
                 (set!buffer-read-only buffer #f)
                 (erase-buffer))
               (let* (;; the window comes *first*, so that the fill below
                      ;; reads the window's real width (the layout's column
                      ;; count is a function of it) - Emacs displays the
                      ;; buffer and then fills it, and so does this
                      (window (completion-display-window buffer))
                      (filled (display-completion-list
                               all (substring typed base-size (string-length typed))))
                      (window2 (completion-fit-window filled)))
                 (set-buffer-local-value! filled 'completion-base-position
                                          (list base-size (string-length typed)))
                 ;; `temp-buffer-window-show` (`window.el:138`): the
                 ;; window shown becomes `minibuffer-scroll-window`, and
                 ;; its start is the beginning of the list - point in the
                 ;; buffer goes to `point-min` there too, which is the
                 ;; heading line, above the first candidate.
                 (set! minibuffer-scroll-window window2)
                 (with-current-buffer filled
                   (goto-char (point-min)))
                 ;; **The start is not written here.** `temp-buffer-window-show`
                 ;; (`window.el:138`) does `(goto-char (point-min))` in the
                 ;; buffer and then `display-buffer`; `set_window_buffer`
                 ;; gives the window that point and leaves its start to the
                 ;; redisplay. This port displays the buffer *before* filling
                 ;; it - the layout needs the window's width - so it puts the
                 ;; point back afterwards as Emacs's `goto-char` does. It used
                 ;; to call `set-window-start!` as well, which Emacs does not:
                 ;; that sets `w->force_start` (`window.c:1968`), and since
                 ;; only the *selected* window's start decision runs in this
                 ;; renderer the flag survived until the completions window's
                 ;; first `M-<down>`. The redisplay then kept the start and
                 ;; moved point into the middle of the list instead of
                 ;; scrolling to the selected candidate - measured: `M-<down>`
                 ;; landed on the help line, and the wrap never happened
                 ;; (`tools/pty-check.py`'s `completion-scroll`).
                 (set-window-point! window2 (point-min))
                 (record-buffer! filled)))))))

    (define minibuffer-scroll-window #f)
    ;; ^ GNU Emacs's `minibuffer-scroll-window` (`window.c:9274'): "Non-nil
    ;; means it is the window that C-M-v in minibuffer should scroll."
    ;; Its other reader is `completion--in-region-1`
    ;; (`minibuffer.el:1764`), which is what a repeated TAB uses, and
    ;; `temp-buffer-window-show` (`window.el:138`) sets it when the
    ;; `*Completions*` window is shown - which is
    ;; `minibuffer-completion-help` below. A plain variable and not a
    ;; parameter, per the tree's rule: Emacs `setq`s it and never
    ;; `let`-binds it.

    (define (completion--scroll-completions)
      ;; The repeated-TAB branch of GNU Emacs's `completion--in-region-1`
      ;; (`minibuffer.el:1761`): scroll the completions window one screen
      ;; down, and once the end of the list is in view go back to the
      ;; top; S-TAB is the mirror. The trailing newline the list may end
      ;; with is disregarded when asking whether the end is visible, as
      ;; the C does (bug#81630): otherwise a vertical list never counts
      ;; as fully shown.
      ;;--------------------------------------------------------------
      (let ((window minibuffer-scroll-window))
        (with-current-buffer (window-buffer window)
          (let* ((pm (point-max))
                 (pt (if (and (> pm (point-min))
                              (char=? (char-before pm) #\newline))
                         (- pm 1)
                         pm)))
            (cond
             ((equal? (*this-command-keys*) (kbd "<backtab>"))
              (if (pos-visible-in-window-p (point-min) window)
                  ;; If the beginning is in view, scroll up to the end.
                  (set-window-point! window pt)
                  ;; Else scroll down one screen.
                  (with-selected-window window (scroll-down-command #f))))
             (else
              (if (pos-visible-in-window-p pt window)
                  ;; If the end is in view, scroll up to the top.
                  (set-window-start! window (point-min))
                  ;; Else scroll down one screen.
                  (with-selected-window window (scroll-up-command #f)))))))))

    (define-command (minibuffer-complete)
      ;; GNU Emacs's `minibuffer-complete': complete as far as the text
      ;; can be, and say what the candidates are when it cannot be
      ;; completed any further.
      ;;
      ;; Emacs's is three lines that hand the work to
      ;; `completion-in-region', which is `completion--do-completion' -
      ;; and this is the same, for the same reason: every message and
      ;; every insertion comes from that one place, so the two cannot
      ;; disagree. They did: this command had a copy of the messages of
      ;; its own, and answered "Complete, but not unique" where the
      ;; shared code says "Sole completion" - so pressing TAB again on a
      ;; name that was already the only completion, which is exactly the
      ;; case `try-completion' answers `t' for, named the wrong thing.
      ;;
      ;; `completion--do-completion' takes the *text*, the table and the
      ;; predicate rather than the buffer boundaries `completion-in-region'
      ;; would give it, which is all this editor has of that function so
      ;; far - the region half of it is step G of COMPLETION-PLAN.txt.
      "Complete the text in the minibuffer as far as it can be (bound to TAB)."
      (interactive)
      (let* ((mb (*minibuffer*))
             (ed (and mb (minibuffer-editor mb)))
             (typed (or (minibuffer-contents) ""))
             (state (and ed (cons (buffer-chars-modified-tick ed)
                                  (buffer-pt ed))))
             (same? (and ed
                         (equal? state
                                 (buffer-local-value
                                  ed 'completion--attempt-state #f)))))
        ;; `completion--in-region-1` (`minibuffer.el:1749`): a completion
        ;; command that follows something else throws the recorded state
        ;; away, so the repeat is a property of the command and not of
        ;; the key - TAB after `?` completes rather than scrolls.
        (unless (eq? (*last-command*) 'completion-at-point)
          (set! minibuffer-scroll-window #f))
        (when ed
          (set-buffer-local-value! ed 'completion--attempt-state state))
        ;; "`this-command` is set to `completion-at-point`" (`:1745`), so
        ;; the next command sees the repeat.
        (*this-command* 'completion-at-point)
        (if (and same?
                 (window-live-p minibuffer-scroll-window)
                 (frame-visible-p (window-frame minibuffer-scroll-window)))
            (begin (completion--scroll-completions) #f)
            (completion--do-completion typed
                                       (*minibuffer-completion-table*)
                                       (*minibuffer-completion-predicate*)
                                       (string-length typed)
                                       #f))))

    (define (read-char-from-minibuffer prompt)
      ;; GNU Emacs's `read-char-from-minibuffer': ask a question whose
      ;; answer is a single key, and return it - `y' or `n' alone
      ;; answers, with no RET. Emacs reads the key itself (`read-key');
      ;; here the key comes from the command loop's own read, so an event
      ;; a command pushed back reaches this question too, with the prompt
      ;; drawn in the echo area.
      ;; C-g abandons the whole command, and a key the question has no
      ;; meaning for (an arrow key, a frame resize) asks it again.
      ;;
      ;; **The prompt is a *message***, which is what `read-key' makes of
      ;; it: "A non-nil PROMPT means to show it as a message"
      ;; (`simple.el`), with `cursor-in-echo-area` bound so that the
      ;; cursor goes to the echo area rather than staying in the buffer
      ;; behind it. It used to be a synthetic echo area - a fresh buffer
      ;; plus `*echo-area-prompt*` - drawn by the renderer; the echo area
      ;; is a window now and draws the frame's own echo buffer, so a
      ;; message is what puts text there.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (parameterize ((*cursor-in-echo-area* #t))
          (set!frame-message frame prompt)
          ;; `read-key` propertizes the prompt with the
          ;; `minibuffer-prompt` face; a Scheme string cannot carry
          ;; properties, so they go on the text in the buffer - which
          ;; is the echo buffer `set!frame-message` has just filled.
          (let ((echo (echo-area-message-buffer)))
            (when echo
              (with-current-buffer echo
                (put-text-property (point-min) (point-max)
                                   'face 'minibuffer-prompt echo)))
            (render! frame))
          (let loop ()
            ;; `read-key-event' answers the *key event* already: the
            ;; display's own form was normalised away at the read, so
            ;; nothing here knows which front end is running.
            (let ((key (read-key-event -1)))
              (cond
               ;; C-g abandons the whole command. A terminal sends the
               ;; byte, so the event is `(kbd "C-g")' - the same event a
               ;; window system's `g' keysym with the control modifier
               ;; becomes.
               ((eqv? key (event-convert-list '(control #\g))) (signal-quit))
               ;; a key the question names as one character answers it -
               ;; `y' and `n' and the rest. A character is an event
               ;; below every modifier bit and above the control range;
               ;; an arrow key, a frame resize and the control keys
               ;; (RET included, as it was before) ask again.
               ((and (integer? key) (< key char-alt) (>= key 32))
                (integer->char key))
               ;; an arrow key, a frame resize: asks again
               (else (loop))))))))

    (define *extended-command-history* (make<history> '()))
    ;; ^ GNU Emacs's `extended-command-history': the names `M-x' has
    ;; read, which `completing-read' offers as its history.

    (define (command-completion-table string predicate action)
      ;; The command names STRING could complete to, asked the way the
      ;; table protocol asks: ACTION #f for the completion of STRING,
      ;; `#t' for the candidates, `(boundaries . SUFFIX)' for where in
      ;; STRING the completed text begins, and `lambda' for whether
      ;; STRING is one of them. A command name is a flat name with no
      ;; directory, so the boundary always begins at zero.
      ;;--------------------------------------------------------------
      (cond
       ((and (pair? action) (eq? (car action) 'boundaries))
        (cons 'boundaries (cons 0 #f)))
       ((eq? action 'lambda)
        (and (< 0 (string-length string))
             (if predicate
                 (predicate string)
                 (and (assoc string (*command-table*)) #t))))
       (else
        (let ((names (map car (*command-table*))))
          (if (eq? action #f)
              (try-completion string names predicate)
              (all-completions string names predicate))))))

    (define-command (execute-extended-command uarg)
      ;; Run the command whose name is typed, read with completion
      ;; against the command obarray. The command runs as a key would
      ;; have run it - `C-u M-x' carries the prefix argument to it -
      ;; with the command itself as `this-command', so that a run of
      ;; kills from M-x amalgamates like a run of the keys. Emacs
      ;; signals "No match" when the name read is not a command; this
      ;; port allows the reply and reports it after.
      "Run a command by name (bound to M-x)."
      (interactive "P")
      (let* ((name (completing-read "M-x " command-completion-table
                                    #f #f #f *extended-command-history* #f))
             (entry (assoc name (*command-table*))))
        (if (not entry)
            (error "No match")
            (let ((record (cdr entry)))
              (*this-command* (command-value-of record))
              (if (command-interactive-spec record)
                  (run-command record uarg)
                  (run-command record))))))

    (define-key *default-keymap* (kbd "M-x") execute-extended-command)

    (define yes-or-no-prompt "(yes or no) ")
    (set! yes-or-no-prompt yes-or-no-prompt)
    ;; ^ GNU Emacs's `yes-or-no-prompt' (`fns.c:6881'): "String to
    ;; append when `yes-or-no-p' asks a question. For best results this
    ;; should end in a space." A plain variable, as the C's DEFVAR is.

    (define yes-or-no-p-history (make<history> '()))
    ;; ^ The history `yes-or-no-p' records its answers in - the
    ;; `yes-or-no-p-history` symbol of `fns.c:6812`, which is a history
    ;; record here because this tree's histories are records.

    (define (yes-or-no-p prompt)
      ;; GNU Emacs's `yes-or-no-p' (`fns.c:3613'): "Ask user a yes-or-no
      ;; question. Return t if answer is yes, and nil if the answer is
      ;; no." The whole word, then RET: being fussier than `y-or-n-p' is
      ;; the point - the answer to a question about losing work should
      ;; take some effort to give.
      ;;
      ;; The C's rules: the prompt gets a space appended when it does not
      ;; end in a blank, and `yes-or-no-prompt' after that
      ;; (`(yes or no) '); an answer that is neither "yes" nor "no" says
      ;; "Please answer yes or no." and asks again. Not carried:
      ;; `use-short-answers`' `y-or-n-p` arm (`y-or-n-p` is above this
      ;; library) and the dialog-box arm (`x-popup-dialog`); `ding`,
      ;; `discard-input` and `sleep-for` are unported, so the pause is
      ;; `sit-for`'s.
      ;;--------------------------------------------------------------
      (let* ((n (string-length prompt))
             (full-prompt
              (string-append
               prompt
               (if (and (< 0 n) (not (char-whitespace? (string-ref prompt (- n 1)))))
                   " "
                   "")
               yes-or-no-prompt)))
        (let loop ()
          (let ((answer (string-downcase
                         (read-from-minibuffer full-prompt #f #f
                                               yes-or-no-p-history #f))))
            (cond
             ((string=? answer "yes") #t)
             ((string=? answer "no") #f)
             (else
              (message "Please answer yes or no.")
              (sit-for 2)
              (loop)))))))

    ;;----------------------------------------------------------------
    ;; The completion styles
    ;;
    ;; GNU Emacs's `completion-styles': a *list* of ways to complete,
    ;; tried in turn, and the first one that finds anything wins. That
    ;; is what makes `basic' (prefix) and `substring' both available
    ;; without either having to know about the other.

    (define *completion-styles*
      ;; GNU Emacs's `completion-styles'. Emacs's default is
      ;; `(basic partial-completion emacs22)'; `partial-completion' is
      ;; the PCM pattern engine and `emacs22' is prefix completion on the
      ;; text before point, which for a minibuffer whose point is at the
      ;; end is what `basic' already is. The two styles this library has
      ;; are the first and the one most people reach for, so the default
      ;; is those.
      ;;--------------------------------------------------------------
      (make-parameter '(basic substring)))

    (define (completion-styles-alist)
      ;; GNU Emacs's `completion-styles-alist': each style as
      ;; `(NAME TRY-COMPLETION ALL-COMPLETIONS DESCRIPTION)'. Emacs
      ;; builds it once as a variable; it is built here each time because
      ;; the two procedures are defined below it.
      ;;--------------------------------------------------------------
      (list (list 'basic
                  completion-basic-try-completion
                  completion-basic-all-completions
                  "Completion of the prefix before point.")
            (list 'substring
                  completion-substring-try-completion
                  completion-substring-all-completions
                  "Completion of the string taken as a substring.")))

    (define (completion--some string table predicate point nth)
      ;; The `seq-some' of GNU Emacs's `completion--nth-completion': try
      ;; each style in turn and answer `(RESULT . STYLE)' for the first
      ;; that finds anything, or #f when none does.
      ;;
      ;; NTH picks which of a style's two functions to call - 1 for
      ;; `completion-try-completion', 2 for `completion-all-completions' -
      ;; which is how one list of styles serves both questions.
      ;;--------------------------------------------------------------
      (let loop ((rest (*completion-styles*)))
        (cond
         ((null? rest) #f)
         (else
          (let ((entry (assq (car rest) (completion-styles-alist))))
            (if (not entry)
                (error "Invalid completion style" (car rest))
                (let ((probe ((if (= nth 1) (cadr entry) (caddr entry))
                              string table predicate point)))
                  (if probe (cons probe (car rest)) (loop (cdr rest))))))))))

    (define (completion--nth-completion nth string table predicate point)
      ;; GNU Emacs's `completion--nth-completion': the answer from the
      ;; first style that finds anything. Emacs also lets a *table* be
      ;; quoted and unquoted around the styles and lets a style adjust
      ;; the completion metadata; neither has any meaning here yet.
      ;;--------------------------------------------------------------
      (let ((result-and-style (completion--some string table predicate point nth)))
        (and result-and-style (car result-and-style))))

    (define (completion-try-completion string table predicate point)
      ;; GNU Emacs's `completion-try-completion': what STRING can be
      ;; completed to. The answer is #f for nothing, #t for "STRING is
      ;; already the only completion", or `(NEWSTRING . NEWPOINT)' - a
      ;; *pair*, because a style may need to put point somewhere other
      ;; than the end of the new text.
      ;;--------------------------------------------------------------
      (completion--nth-completion 1 string table predicate point))

    (define (completion-all-completions string table predicate point)
      ;; GNU Emacs's `completion-all-completions': the candidates, with
      ;; the *base size* in the last cdr - the length of the text the
      ;; completion starts from, which is what tells a caller how much of
      ;; what was typed the completion replaces. `(cdr (last ANSWER))' is
      ;; how Emacs reads it back, so the answer is a dotted list.
      ;;--------------------------------------------------------------
      (completion--nth-completion 2 string table predicate point))

    (define (completion-boundaries string table predicate suffix)
      ;; GNU Emacs's `completion-boundaries': "Return the boundaries of
      ;; text on which COLLECTION will operate", as `(START . END)' -
      ;; START a position in STRING, END one in SUFFIX, the text after
      ;; point. A *function* table is asked with the action
      ;; `(boundaries . SUFFIX)' and may answer `(boundaries START . END)';
      ;; any other table, or any other answer, means the whole of both -
      ;; "for file names the result is the positions delimited by the
      ;; closest directory separators", which is `completion-file-name-table'
      ;; answering.
      ;;--------------------------------------------------------------
      (let ((boundaries (and (procedure? table)
                             (table string predicate (cons 'boundaries suffix)))))
        (let ((boundaries (and (pair? boundaries)
                               (eq? (car boundaries) 'boundaries)
                               (pair? (cdr boundaries))
                               (cdr boundaries))))
          (cons (or (and boundaries (car boundaries)) 0)
                (or (and boundaries (cdr boundaries)) (string-length suffix))))))

    (define (common-prefix strings)
      ;; The longest prefix every one of STRINGS begins with. This is not
      ;; an Emacs function: Emacs gets the same answer as a side effect of
      ;; merging the completed pattern (`completion-pcm--merge-try'), and
      ;; this is what stands in for that until the PCM engine is here.
      ;;--------------------------------------------------------------
      (let loop ((i 0))
        (if (and (< i (string-length (car strings)))
                 (let all ((rest (cdr strings)))
                   (cond
                    ((null? rest) #t)
                    ((and (< i (string-length (car rest)))
                          (char=? (string-ref (car rest) i)
                                  (string-ref (car strings) i)))
                     (all (cdr rest)))
                    (else #f))))
            (loop (+ 1 i))
            (substring (car strings) 0 i))))

    ;;----------------------------------------------------------------
    ;; The styles themselves

    (define (completion-basic-try-completion string table predicate point)
      ;; GNU Emacs's `completion-basic-try-completion': prefix completion.
      ;;
      ;; Emacs also completes the text *after* point here - the second half
      ;; of `basic', which is what makes completing "foo_bar" with point
      ;; after the underscore complete both halves. A minibuffer prompt has
      ;; point at the end and no afterpoint, so what is left is the C's
      ;; `try-completion', with point at the end of what it found.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (completion (try-completion beforepoint table predicate)))
        (if (not (string? completion))
            completion
            (cons completion (string-length completion)))))

    (define (completion-basic-all-completions string table predicate point)
      ;; GNU Emacs's `completion-basic-all-completions`: the prefix
      ;; matches, with the *base size* in the last cdr - the START of the
      ;; table's boundaries, which is how much of STRING the candidates
      ;; leave out (a file name's directory). Emacs gets the candidates
      ;; through `completion-pcm--all-completions', which for a pattern
      ;; with no wildcards is `all-completions' on the whole text.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (afterpoint (substring string point))
             (bounds (completion-boundaries beforepoint table predicate afterpoint))
             (all (all-completions beforepoint table predicate)))
        (if (null? all)
            #f
            (append all (car bounds)))))

    (define (completion-substring-candidates string pattern table predicate)
      ;; The candidates PATTERN appears in *anywhere*: what the `substring'
      ;; style means by completing. PATTERN is the part of STRING after
      ;; the table's boundary - the file name without its directory - and
      ;; the table is asked about STRING whole, as Emacs's
      ;; `completion-substring--all-completions' asks it. Emacs gets
      ;; there through its PCM pattern engine, which is a general glob
      ;; matcher shared with `partial-completion' and `flex'; the meaning
      ;; is this, and this is what it is built on when that engine arrives.
      ;;--------------------------------------------------------------
      (let loop ((rest (if (procedure? table)
                           (table string predicate #t)
                           table))
                 (acc '()))
        (cond
         ((not (pair? rest)) (reverse acc))
         (else
          (let ((candidate (if (pair? (car rest)) (car (car rest)) (car rest))))
            (cond
             ((not (string? candidate))
              (loop (cdr rest) acc))
             ((not (or (not predicate) (predicate candidate)))
              (loop (cdr rest) acc))
             ((substring? pattern candidate)
              (loop (cdr rest) (cons candidate acc)))
             (else (loop (cdr rest) acc))))))))

    (define (substring? needle haystack)
      ;; Whether NEEDLE occurs anywhere in HAYSTACK - the test the
      ;; `substring' style is named for.
      ;;--------------------------------------------------------------
      (let ((n (string-length needle))
            (h (string-length haystack)))
        (let loop ((i 0))
          (cond ((> (+ i n) h) #f)
                ((string=? needle (substring haystack i (+ i n))) #t)
                (else (loop (+ 1 i)))))))

    (define (completion-substring-all-completions string table predicate point)
      ;; GNU Emacs's `completion-substring-all-completions': the matches
      ;; of the text after the boundary, with the base size in the last
      ;; cdr as `completion-basic-all-completions' has it.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (afterpoint (substring string point))
             (bounds (completion-boundaries beforepoint table predicate afterpoint))
             (pattern (substring beforepoint (car bounds) (string-length beforepoint)))
             (all (completion-substring-candidates beforepoint pattern table predicate)))
        (if (null? all)
            #f
            (append all (car bounds)))))

    (define (completion-substring-try-completion string table predicate point)
      ;; GNU Emacs's `completion-substring-try-completion'.
      ;;
      ;; A substring match is not a *prefix* of what was typed, so the
      ;; answer is the match itself rather than a longer version of the
      ;; input: completing "oo" against `("foo")' gives "foo" and point 3,
      ;; where prefix completion would give nothing at all. Emacs merges
      ;; the pattern to get there; with several matches it answers the
      ;; longest prefix they agree on, which is what a caller does with
      ;; it anyway.
      ;;--------------------------------------------------------------
      ;;
      ;; The answer carries the text before the boundary - the directory
      ;; of a file name - in front, which is what
      ;; `completion-pcm--merge-try' does with its PREFIX.
      (let* ((beforepoint (substring string 0 point))
             (afterpoint (substring string point))
             (bounds (completion-boundaries beforepoint table predicate afterpoint))
             (prefix (substring beforepoint 0 (car bounds)))
             (pattern (substring beforepoint (car bounds) (string-length beforepoint)))
             (all (completion-substring-candidates beforepoint pattern table predicate)))
        (cond
         ((null? all) #f)
         ((and (null? (cdr all)) (string=? (car all) pattern)) #t)
         (else
          (let ((merged (string-append prefix
                                       (if (null? (cdr all))
                                           (car all)
                                           (common-prefix all)))))
            (cons merged (string-length merged)))))))
    ;;----------------------------------------------------------------
    ;; Doing a completion, and what RET does about it

    (define *minibuffer-completion-predicate*
      ;; GNU Emacs's `minibuffer-completion-predicate': the filter the
      ;; completion commands pass to the table. `completing-read' binds it
      ;; from its PREDICATE argument.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *minibuffer-completion-confirm*
      ;; GNU Emacs's `minibuffer-completion-confirm' (`minibuf.c:2630'):
      ;; "Whether to demand confirmation of completion before exiting
      ;; minibuffer.
      ;;
      ;; If nil, confirmation is not required.
      ;; If the value is `confirm', the user may exit with an input that is
      ;;  not a valid completion alternative, but Emacs asks for
      ;;  confirmation.
      ;; If the value is `confirm-after-completion', the user may exit with
      ;;  an input that is not a valid completion alternative, but Emacs
      ;;  asks for confirmation if the user submitted the input right after
      ;;  any of the completion commands listed in
      ;;  `minibuffer-confirm-exit-commands'."
      ;;
      ;; Note the shape: nil is *not* the same as any other value, and
      ;; `confirm' is not the same as `confirm-after-completion' - which
      ;; is why it was wrong as `#t'/`#f'. Emacs's `completing-read' binds
      ;; it from REQUIRE-MATCH, and `completion--complete-and-exit' reads
      ;; all four possibilities (including a predicate, which nothing here
      ;; passes yet).
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *completion-auto-help*
      ;; GNU Emacs's `completion-auto-help': whether a completion that
      ;; cannot go further shows the candidates on its own, and it is
      ;; true by default, as Emacs's is.
      ;;
      ;; Emacs's may also be the symbols `lazy', `always' and `visible',
      ;; which change *when* the list appears; only the boolean is
      ;; implemented here, so `lazy' - the second TAB rather than the
      ;; first - is not among them.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (minibuffer--bitset modified completions exact)
      ;; GNU Emacs's `minibuffer--bitset': what a completion did, as three
      ;; bits - M (the text was *modified*), C (there were completions at
      ;; all) and E (what is there now is an *exact* match).
      ;;
      ;; 001 was already an exact and unique completion
      ;; 011 was already an exact completion
      ;; 110 some completion happened, but is not exact
      ;; 111 completed to an exact completion
      ;; 000 (and 010) nothing to do
      ;;--------------------------------------------------------------
      (logior (if modified 4 0) (if completions 2 0) (if exact 1 0)))

    (define (completion--replace completion)
      ;; GNU Emacs's `completion--replace': rewrite what has been typed as
      ;; COMPLETION, with point at the end of it. Emacs replaces the text
      ;; between BEG and END, which here is the whole of what was typed.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (when mb
          (let ((ed (minibuffer-editor mb))
                (beg (%minibuffer-prompt-end mb)))
            (with-current-buffer ed
              (delete-region beg (point-max))
              (insert completion))))))

    (define (completion--do-completion string table predicate point expect-exact)
      ;; GNU Emacs's `completion--do-completion': complete STRING, put the
      ;; result in the minibuffer, and answer the bitset saying what
      ;; happened.
      ;;
      ;; The two messages it can leave are Emacs's, and they are what the
      ;; user sees when TAB does not simply fill the rest in:
      ;; "Complete, but not unique" when what is there now is a valid
      ;; completion that others also match, and the list of candidates
      ;; when it is not a valid completion at all.
      ;;
      ;; EXPECT-EXACT is Emacs's ("there is no need to tell the user when
      ;; the buffer's text is already an exact match") and is what this
      ;; command's own caller - `completion-complete-and-exit', via RET -
      ;; passes: RET is not TAB, so "Sole completion" and "Complete, but
      ;; not unique" are not news to someone who has just pressed it.
      ;;
      ;; Not ported: the `completion-cycle-threshold' cycling and the
      ;; metadata (`completion--field-metadata').
      ;;--------------------------------------------------------------
      (let ((comp (completion-try-completion string table predicate point)))
        (cond
         ((not comp)
          (completion--message "No match")
          (minibuffer--bitset #f #f #f))
         ((eq? comp #t)
          (unless expect-exact
            (completion--message "Sole completion"))
          (minibuffer--bitset #f #f #t))
         (else
          (let* ((completion (car comp))
                 ;; "completed" excludes a change of *case* alone, which
                 ;; is rewritten in the buffer but is not a completion.
                 (completed (not (string-ci=? completion string)))
                 (unchanged (string=? completion string))
                 (exact (test-completion completion table predicate)))
            (unless unchanged (completion--replace completion))
            ;; Which of the three things happened decides what is said,
            ;; and the order of the three is Emacs's - and it is the
            ;; order that matters most, because the first case covers
            ;; most TAB presses:
            ;;
            ;;   * a completion *happened*: take any stale candidates
            ;;     window away and say nothing at all. Nothing here is
            ;;     wrong - the text was completed as far as it goes.
            ;;   * nothing was completed and what is there is not a
            ;;     valid completion: show the candidates (or say so, if
            ;;     `completion-auto-help' is off).
            ;;   * nothing was completed and what is there *is* a
            ;;     valid completion: "Complete, but not unique" - the
            ;;     text will do, but it is not the only candidate.
            ;;
            ;; Saying "Complete, but not unique" in the first case
            ;; instead is what made TAB on a name that completes in full
            ;; look like a failure.
            (cond
             (completed (minibuffer-hide-completions))
             ((not exact)
              (if (*completion-auto-help*)
                  (minibuffer-completion-help)
                  (completion--message "Next char not unique")))
             (else
              ;; If the last exact completion and this one were the
              ;; same, it means we've already given a "Complete, but
              ;; not unique" message and the user's hit TAB again, so
              ;; now the candidates are shown as well - Emacs's
              ;; `(when (and (eq this-command last-command)
              ;;                 completion-auto-help) ...)', the
              ;; second TAB on a directory with nothing typed after it.
              (when (and (eq? (*this-command*) (*last-command*))
                         (*completion-auto-help*))
                (minibuffer-completion-help))
              (unless expect-exact
                (completion--message "Complete, but not unique"))))
            (minibuffer--bitset completed #t exact))))))

      ;; GNU Emacs's `minibuffer-complete-and-exit' (RET in a
      ;; `require-match' minibuffer): leave if what is typed is a valid
      ;; completion, and otherwise complete it and say why it did not.
      ;;
      ;; **The decision is Emacs 31's, across its three functions**:
      ;; `minibuffer-complete-and-exit' (`:2087'),
      ;; `completion-complete-and-exit' (`:2113') and
      ;; `completion--complete-and-exit' (`:2128'). Emacs's is not a
      ;; dispatch on the bitset of one completion; it is a chain of
      ;; conditions tried *before* anything is completed at all, and the
      ;; difference is visible in what the user gets:
      ;;
      ;;   * an *empty* answer exits at once (`(= beg end)' - "Allow user
      ;;     to specify null string"), and `read_minibuf' answers with the
      ;;     default. Ours used to show the candidates instead;
      ;;   * an answer `test-completion' accepts exits - with the case
      ;;     fixed up when completion ignores it;
      ;;   * an answer it *rejects* still exits when confirmation was
      ;;     asked for, which for `confirm-after-completion' means "unless
      ;;     the command just before this RET was TAB". Ours refused, so a
      ;;     name typed out in full and RET'd once could not create a
      ;;     buffer, and `C-x b fresh RET' answered "[No match]";
      ;;   * and only then is anything completed, and the bitset decides.
      ;;
      ;; That last rule is why `minibuffer-completion-confirm' has to hold
      ;; the SYMBOL and not a boolean, which is what this tree had: with
      ;; only `#t' there is no way to tell `confirm' from
      ;; `confirm-after-completion', and `completing-read' now binds it
      ;; from REQUIRE-MATCH with Emacs's own line.
      ;;--------------------------------------------------------------
    (define (completion--complete-and-exit string exit-function completion-function)
      ;; GNU Emacs's `completion--complete-and-exit' (`:2128'): "Exit from
      ;; `require-match' minibuffer. COMPLETION-FUNCTION is called if the
      ;; current buffer's content does not appear to be a match."
      ;;
      ;; Emacs's BEG and END address the completion *field*, which are
      ;; buffer positions there because the prompt is the minibuffer's own
      ;; text; here the field is the whole of what was typed, and they are
      ;; the empty string and the whole of it.
      ;;--------------------------------------------------------------
      (cond
       ;; Allow user to specify null string
       ((= 0 (string-length string)) (exit-function))
       ;; The CONFIRM argument is a predicate.
       ((procedure? (*minibuffer-completion-confirm*))
        (if ((*minibuffer-completion-confirm*) string)
            (exit-function)
            ;; Emacs rings the bell here first (`ding', keyboard.c's,
            ;; which is not ported - there is no bell in this tree).
            (completion--message "No match")))
       ;; See if we have a completion from the table.
       ((test-completion string (*minibuffer-completion-table*)
                         (*minibuffer-completion-predicate*))
        ;; "Fixup case of the field, if necessary."
        (when (*completion-ignore-case*)
          (let ((compl (try-completion string (*minibuffer-completion-table*)
                                       (*minibuffer-completion-predicate*))))
            (when (and (string? compl)
                       (not (string=? string compl))
                       ;; "If it weren't for this piece of paranoia, I'd
                       ;; replace the whole thing with a call to
                       ;; do-completion."
                       (= (string-length string) (string-length compl)))
              (completion--replace compl))))
        (exit-function))
       ;; The user is permitted to exit with an input that's rejected by
       ;; test-completion, after confirming her choice.
       ((memq (*minibuffer-completion-confirm*) '(confirm confirm-after-completion))
        (if (or (eq? (*last-command*) (*this-command*))
                ;; For `confirm-after-completion' we only ask for
                ;; confirmation if trying to exit immediately after typing
                ;; TAB (this catches most minibuffer typos).
                (and (eq? (*minibuffer-completion-confirm*) 'confirm-after-completion)
                     (not (memq (*last-command*) minibuffer-confirm-exit-commands))))
            (exit-function)
            ;; Emacs's `if' takes a *body* - several forms - for its else
            ;; branch, which Scheme's does not; the two go in a `begin',
            ;; and its answer (#f, Emacs's nil) is what the caller's
            ;; `cond' falls through on.
            (begin (minibuffer-message "Confirm")
                   #f)))
       (else (completion-function))))

    (define (completion-complete-and-exit string exit-function)
      ;; GNU Emacs's `completion-complete-and-exit' (`:2113'): complete
      ;; the field, and let the bitset of that completion decide. The
      ;; `condition-case'-to-1 is Emacs's, and it is not a formality - an
      ;; error out of `completion--do-completion' reads as an exact and
      ;; unique match (bit 1), so a table that raises is exited rather
      ;; than swallowed.
      ;;--------------------------------------------------------------
      (completion--complete-and-exit
       string exit-function
       (lambda ()
         (let ((bits (guard (e (else 1))
                       (completion--do-completion
                        string (*minibuffer-completion-table*)
                        (*minibuffer-completion-predicate*)
                        (string-length string)
                        #t))))
           (cond
            ((or (= bits 1) (= bits 3)) (exit-function))
            ((= bits 7)
             (if (not (*minibuffer-completion-confirm*))
                 (exit-function)
                 (begin (minibuffer-message "Confirm")
                        #f)))
            (else #f))))))

    (define-command (minibuffer-complete-and-exit no-exit)
      ;; A candidate chosen with M-<down> is taken before anything
      ;; else is tried, which is GNU Emacs's
      ;; `(when (completion--selected-candidate)
      ;;    (minibuffer-choose-completion t t))' at the head of its
      ;; `minibuffer-complete-and-exit'. NO-EXIT is its prefix argument
      ;; ("insert the selected completion, but do not leave").
      "Exit the minibuffer, if what is typed is a valid completion."
      (interactive (list (current-prefix-arg)))
      (when (completion--selected-candidate)
        (minibuffer-choose-completion #t #t))
      (unless no-exit
        (completion-complete-and-exit (or (minibuffer-contents) "")
                                      exit-minibuffer)))

    (define (completion--try-word-completion string table predicate point)
      ;; GNU Emacs's `completion--try-word-completion': complete the text
      ;; and then a space, then a hyphen - so that completing a word in a
      ;; sentence moves on to the next one. It is what SPC does in a
      ;; completing minibuffer.
      ;;--------------------------------------------------------------
      (let loop ((suffixes '(" " "-")))
        (cond
         ((null? suffixes)
          (completion-try-completion string table predicate point))
         (else
          (let ((candidate (completion-try-completion
                            (string-append string (car suffixes))
                            table predicate
                            (+ point (string-length (car suffixes))))))
            (cond
             ((and (pair? candidate) (string=? (car candidate)
                                               (string-append string (car suffixes))))
              candidate)
             (else (loop (cdr suffixes)))))))))

      ;; GNU Emacs's `minibuffer-complete-word' (SPC): complete at most a
      ;; single word.
      ;;--------------------------------------------------------------
    (define-command (minibuffer-complete-word)
      "Complete the minibuffer contents at most a single word (SPC)."
      (interactive)
      (let* ((typed (or (minibuffer-contents) ""))
             (comp (completion--try-word-completion
                    typed (*minibuffer-completion-table*)
                    (*minibuffer-completion-predicate*)
                    (string-length typed))))
        (cond
         ((and (pair? comp) (not (string=? (car comp) typed)))
          (completion--replace (car comp)))
         ((not comp)
          (completion--message "No match"))
         (else (minibuffer-completion-help)))))

    (define minibuffer-confirm-exit-commands
      ;; GNU Emacs's `minibuffer-confirm-exit-commands' (`:2075'): "List of
      ;; commands which cause an immediately following
      ;; `minibuffer-complete-and-exit' to ask for extra confirmation" -
      ;; the TABs, in other words, which is what `confirm-after-completion'
      ;; consults `last-command' for.
      ;;
      ;; Emacs lists the *symbols* `completion-at-point',
      ;; `minibuffer-complete' and `minibuffer-complete-word'. A bound
      ;; command is its procedure here, so the two that are bound are
      ;; listed as procedures - but **`completion-at-point` is listed as
      ;; the symbol**, because that is what a completing command sets
      ;; `this-command` to (`completion--in-region-1`,
      ;; `minibuffer.el:1745` - see `minibuffer-complete`), and that
      ;; symbol is therefore what `last-command` holds when the user
      ;; types RET straight after a TAB.
      ;;
      ;; Without it the `confirm-after-completion` rule could never fire
      ;; from a TAB: `(memq last-command ...)` was false for the symbol,
      ;; so RET exited and made a buffer from the typo that `[Confirm]`
      ;; exists to catch. Measured, `C-x b SWI TAB RET`: `[No match]`
      ;; from the TAB and then a buffer named SWI.
      ;;--------------------------------------------------------------
      (list 'completion-at-point minibuffer-complete minibuffer-complete-word))

    ;;----------------------------------------------------------------
    ;; Reading with completion

    (define (list-ref-or list index default)
      ;; The INDEXth of LIST, or DEFAULT when it is not there. Emacs's
      ;; optional arguments are `&optional' and a Scheme function has to
      ;; pick them out of a rest list.
      ;;--------------------------------------------------------------
      (let loop ((rest list) (n index))
        (cond ((null? rest) default)
              ((= n 0) (car rest))
              (else (loop (cdr rest) (- n 1))))))

    ;;----------------------------------------------------------------
    ;; Reading a buffer name
    ;;----------------------------------------------------------------
    ;;
    ;; `read-buffer' is `minibuf.c''s (`:1522') and so is
    ;; `internal-complete-buffer' (`:2156'); `complete-with-action'
    ;; (`minibuffer.el:232') and `completion-table-with-predicate'
    ;; (`:467') are that file's, and the strip-internal rule inside
    ;; `internal-complete-buffer' is the C's own. They live here for the
    ;; reason `completing-read' does: they read the minibuffer, and the
    ;; table has to see the buffer registry, which is above `minibuf.sld'.

    (define (%internal-buffer-name? name)
      ;; Emacs's own test for a buffer that is "internal" - the C's
      ;; `SREF (XCAR (bufs), 0) == ' '' - a name that begins with a space.
      ;; `*scratch*' is not one; `*Messages*', `*Completions*' and the
      ;; startup screen's `*Schemacs*' are.
      ;;--------------------------------------------------------------
      (and (> (string-length name) 0)
           (char=? #\space (string-ref name 0))))

    (define (complete-with-action action collection string predicate)
      ;; GNU Emacs's `complete-with-action' (`minibuffer.el:232'): "Perform
      ;; completion according to ACTION." A *function* collection is called
      ;; directly, whatever the question is; otherwise the three questions
      ;; are the three functions. ACTION is Emacs's own encoding of them -
      ;; #f, #t and `lambda' - and `metadata'/`boundaries' answer nothing,
      ;; as in Emacs (this tree's tables carry no metadata).
      ;;--------------------------------------------------------------
      (cond
       ((procedure? collection) (collection string predicate action))
       ((not action) (try-completion string collection predicate))
       ((eq? action #t) (all-completions string collection predicate))
       (else (test-completion string collection predicate))))

    (define (internal-complete-buffer string predicate action)
      ;; GNU Emacs's `internal-complete-buffer' (`minibuf.c:2156'):
      ;; "Perform completion on buffer names."
      ;;
      ;; The table is the **buffer alist** - Emacs's `Vbuffer_alist', this
      ;; tree's `*buffer-list*', which `other-buffer' and the Buffer Menu
      ;; already read as an alist of `(NAME . BUFFER)'.
      ;;
      ;; The one piece of the C that is not a dispatch is the
      ;; **strip-internal-buffers** rule, which applies only when the
      ;; *empty* string is being completed: the internal buffers at the
      ;; front are skipped, and then an internal one *after* the first
      ;; ordinary one is dropped from the rest - so the ordinary buffers
      ;; come first. When every candidate is internal they are given back
      ;; as they are, but only if they are all the buffers there are
      ;; (`list_length (res) == list_length (Vbuffer_alist)'), so a session
      ;; with nothing but internal buffers still completes.
      ;;--------------------------------------------------------------
      (cond
       ((not action)
        (try-completion string (*buffer-list*) predicate))
       ((eq? action #t)
        (let ((res (all-completions string (*buffer-list*) predicate)))
          (if (> (string-length string) 0)
              res
              (let loop ((rest res))
                (cond
                 ((null? rest)
                  (if (= (length res) (length (*buffer-list*))) res #f))
                 ((%internal-buffer-name? (car rest)) (loop (cdr rest)))
                 (else
                  (let drop ((tail (cdr rest)) (kept (list (car rest))))
                    (cond
                     ((null? tail) (reverse kept))
                     ((%internal-buffer-name? (car tail))
                      (drop (cdr tail) kept))
                     (else (drop (cdr tail) (cons (car tail) kept)))))))))))
       (else
        (test-completion string (*buffer-list*) predicate))))

    (define (completion-table-with-predicate table pred1 strict
                                             string pred2 action)
      ;; GNU Emacs's `completion-table-with-predicate' (`minibuffer.el:467'):
      ;; "Make a completion table equivalent to TABLE but filtered through
      ;; PRED1. ... If STRICT is non-nil, the predicate always applies; if
      ;; nil it only applies if it does not reduce the set of possible
      ;; completions to nothing."
      ;;
      ;; **The nil case is the one this tree needs**, and it is the two
      ;; arms of Emacs's `cond': `test-completion' ignores PRED1 outright
      ;; ("it doesn't really have to apply anyway"), and a *failed*
      ;; completion is retried with PRED2 alone. That is what lets
      ;; `read-buffer-to-switch' leave the current buffer out of the list
      ;; you are offered while still taking its name if you type it.
      ;;--------------------------------------------------------------
      (cond
       ((and (not strict) (eq? action 'lambda))
        (test-completion string table pred2))
       (else
        (or (complete-with-action
             action table string
             (if (not (and pred1 pred2))
                 (or pred1 pred2)
                 (lambda (x) (and (pred1 x) (pred2 x)))))
            (and (not strict)
                 pred1
                 (complete-with-action action table string pred2))))))

    (define (internal-complete-buffer-except . args)
      ;; GNU Emacs's `internal-complete-buffer-except'
      ;; (`minibuffer.el:4211'): "Perform completion on all buffers
      ;; excluding BUFFER. BUFFER nil or omitted means use the current
      ;; buffer."
      ;;
      ;; Emacs writes it as `apply-partially' over
      ;; `completion-table-with-predicate', fixing the table, the "not this
      ;; one" predicate and STRICT nil - so what comes back is a completion
      ;; table, called with the three arguments a table is called with.
      ;;--------------------------------------------------------------
      (let ((except (let ((buffer (if (pair? args) (car args) #f)))
                      (if (string? buffer)
                          buffer
                          (buffer-name (if buffer buffer (current-buffer)))))))
        (apply-partially completion-table-with-predicate
                         internal-complete-buffer
                         (lambda (name)
                           (not (equal? (if (pair? name) (car name) name)
                                        except)))
                         #f)))

    (define (minibuffer-with-setup-hook function thunk)
      ;; GNU Emacs's `minibuffer-with-setup-hook' (`minibuffer.el'): run
      ;; THUNK with FUNCTION added to `minibuffer-setup-hook' for the read
      ;; it makes.
      ;;
      ;; **Why a hook and not an argument.** `read-buffer' passes its own
      ;; table to `completing-read', and `read-buffer-to-switch' needs a
      ;; different one, so the only place to say so is *inside* the read:
      ;; `completing-read' binds `*minibuffer-completion-table*' before it
      ;; and `read-minibuffer-1' runs the setup hook after the prompt is in
      ;; place, so a hook that *sets* that parameter changes the table the
      ;; rest of that read completes against.
      ;;--------------------------------------------------------------
      (parameterize ((*minibuffer-setup-hook*
                      (append (*minibuffer-setup-hook*) (list function))))
        (thunk)))

    (define (%prompt-without-trailer prompt)
      ;; The C's "we must change PROMPT, editing the default value in
      ;; before the colon": drop a trailing ": " or ":" or " " from the
      ;; prompt, and let `format-prompt' put the default back the way
      ;; "Switch to buffer (default foo): " does (`minibuf.c:1557-1577').
      ;;--------------------------------------------------------------
      (let ((len (string-length prompt)))
        (cond
         ((and (>= len 2)
               (char=? #\: (string-ref prompt (- len 2)))
               (char=? #\space (string-ref prompt (- len 1))))
          (substring prompt 0 (- len 2)))
         ((and (>= len 1)
               (or (char=? #\: (string-ref prompt (- len 1)))
                   (char=? #\space (string-ref prompt (- len 1)))))
          (substring prompt 0 (- len 1)))
         (else prompt))))

    (define (read-buffer prompt . args)
      ;; GNU Emacs's `read-buffer' (`minibuf.c:1522'): "Read the name of a
      ;; buffer and return it as a string.
      ;;
      ;;     (read-buffer PROMPT &optional DEF REQUIRE-MATCH PREDICATE)
      ;;
      ;; DEF is what an empty line answers; REQUIRE-MATCH has the same
      ;; meaning as `completing-read''s; PREDICATE limits which buffers may
      ;; be offered.
      ;;
      ;; Three things of the C's, in its order: a DEF that *is a buffer* is
      ;; read as that buffer's name (which is how `switch-to-buffer' passes
      ;; `(other-buffer)' as its default); `completion-ignore-case' is bound
      ;; to `read-buffer-completion-ignore-case' for the length of the read;
      ;; and with a DEF the prompt is re-made through `format-prompt' so
      ;; that the default shows in it.
      ;;
      ;; `read-buffer-function' short-circuits all of it, as in Emacs -
      ;; called "with the arguments passed to `read-buffer'".
      ;;--------------------------------------------------------------
      (let ((def (if (pair? args) (car args) #f))
            (require-match (if (and (pair? args) (pair? (cdr args)))
                               (cadr args)
                               #f))
            (predicate (if (and (pair? args)
                                (pair? (cdr args))
                                (pair? (cddr args)))
                           (caddr args)
                           #f)))
        (if (bufferp def) (set! def (buffer-name def)))
        (parameterize ((*completion-ignore-case*
                        (*read-buffer-completion-ignore-case*)))
          (if (*read-buffer-function*)
              (let ((function (*read-buffer-function*)))
                (if predicate
                    (function prompt def require-match predicate)
                    (function prompt def require-match)))
              (let ((prompt (if def
                                (format-prompt (%prompt-without-trailer prompt)
                                               (if (pair? def) (car def) def))
                                prompt)))
                (completing-read prompt internal-complete-buffer predicate
                                 require-match #f buffer-name-history
                                 def))))))

    (define *confirm-nonexistent-file-or-buffer* (make-parameter 'after-completion))
    ;; ^ GNU Emacs's `confirm-nonexistent-file-or-buffer' (`files.el:1898'):
    ;; "Whether confirmation is requested before visiting a new file or
    ;; buffer. If nil, confirmation is not requested. If the value is
    ;; `after-completion', confirmation is requested only if the user called
    ;; `minibuffer-complete' right before `minibuffer-complete-and-exit'.
    ;; Any other non-nil value means to request confirmation."
    ;;
    ;; **A placement departure: this is `files.el`'s variable and it is in
    ;; this library.** `read-buffer-to-switch' passes it, as Emacs does, and
    ;; that function can only live here (see its note) - so the variable has
    ;; to be reachable from here, and `(schemacs files)' is above this
    ;; library. `*minor-mode-alist*' was moved for the same reason. Its
    ;; default is Emacs's `after-completion'; the tree had `#t' here with a
    ;; comment claiming "any non-nil value means ask", which is not what
    ;; Emacs's default does - with `after-completion' a name that is not
    ;; followed by TAB does not ask.

    (define (confirm-nonexistent-file-or-buffer)
      ;; GNU Emacs's `confirm-nonexistent-file-or-buffer' (`files.el:1914'):
      ;; "Whether to request confirmation before visiting a new file or
      ;; buffer" - the value to pass as `read-file-name''s or
      ;; `read-buffer''s REQUIRE-MATCH, which is why it answers the symbols
      ;; `confirm' and `confirm-after-completion' rather than `t'.
      ;;--------------------------------------------------------------
      (cond ((eq? (*confirm-nonexistent-file-or-buffer*) 'after-completion)
             'confirm-after-completion)
            ((*confirm-nonexistent-file-or-buffer*) 'confirm)
            (else #f)))

    (define (read-buffer-to-switch prompt)
      ;; GNU Emacs's `read-buffer-to-switch' (`window.el:9485'): "Read the
      ;; name of a buffer to switch to, prompting with PROMPT. Return the
      ;; name of the buffer as a string.
      ;;
      ;; This function is intended for the `switch-to-buffer' family of
      ;; commands since these need to omit the name of the current buffer
      ;; from the list of completions and default values."
      ;;
      ;; **`window.el''s` function, in this library**: `window.sld` cannot
      ;; hold it - it is built on the minibuffer - and this needs
      ;; `internal-complete-buffer-except', which is here. `window.sld`
      ;; asks for it through `*read-buffer-to-switch*`, the way a front end
      ;; installs `*frame-creation-function*`, and that library's
      ;; `switch-to-buffer` calls what it finds there. It is the wall
      ;; `goto-line' and `zap-to-char' sit behind, and the same answer.
      ;;
      ;; The table goes in through `minibuffer-with-setup-hook' rather than
      ;; as an argument because `read-buffer' passes its own table to
      ;; `completing-read' - the hook is the one place that can say
      ;; otherwise. Emacs's hook also conses the table onto
      ;; `icomplete-with-completion-tables' when icomplete is loaded; there
      ;; is no icomplete here.
      ;;
      ;; The default is `(other-buffer (current-buffer))' - what `C-x b
      ;; RET' switches to, which is Emacs's own argument.
      ;;
      ;; The last argument is `(confirm-nonexistent-file-or-buffer)' -
      ;; Emacs's own - which is why that variable and its function are in
      ;; *this* library rather than in `files.sld` where `files.el` has
      ;; them; see the note on them below.
      ;;--------------------------------------------------------------
      (minibuffer-with-setup-hook
       (lambda ()
         (*minibuffer-completion-table* (internal-complete-buffer-except)))
       (lambda ()
         (read-buffer prompt (other-buffer (current-buffer))
                      (confirm-nonexistent-file-or-buffer)))))

    ;; `window.sld`'s `switch-to-buffer` reads its buffer name through
    ;; this; see the note on `read-buffer-to-switch` above.
    (*read-buffer-to-switch* read-buffer-to-switch)

    (define (read-string prompt . args)
      ;; GNU Emacs's `read-string` (`subr.el`): "Read a string from the
      ;; minibuffer, prompting with string PROMPT." Its body is
      ;; `read-from-minibuffer` with no keymap - `minibuffer-local-map`
      ;; - and the optional INITIAL-INPUT, HISTORY and DEFAULT-VALUE
      ;; passed through. INHERIT-INPUT-METHOD is not carried: there is
      ;; no input method here.
      ;;--------------------------------------------------------------
      (let ((initial (list-ref-or args 0 #f))
            (history (list-ref-or args 1 #f))
            (default (list-ref-or args 2 #f)))
        (read-from-minibuffer prompt initial #f history default)))

    (define (completing-read prompt collection . args)
      ;; GNU Emacs's `completing-read': read a string in the minibuffer,
      ;; completing against COLLECTION.
      ;;
      ;;   (completing-read PROMPT COLLECTION &optional PREDICATE
      ;;                    REQUIRE-MATCH INITIAL-INPUT HISTORY DEF)
      ;;
      ;; REQUIRE-MATCH is the argument that changes what RET does: with it
      ;; the minibuffer will not be left holding something that is not a
      ;; valid completion, which is the whole difference between
      ;; `minibuffer-local-completion-map' and
      ;; `minibuffer-local-must-match-map'.
      ;;--------------------------------------------------------------
      (let ((predicate (list-ref-or args 0 #f))
            (require-match (list-ref-or args 1 #f))
            (initial (list-ref-or args 2 #f))
            (history (list-ref-or args 3 minibuffer-history))
            (default (list-ref-or args 4 #f)))
        ;; `(STRING . POSITION)' is the initial input with point at
        ;; POSITION in it. The position counts from *zero* here and from
        ;; one in `read-from-minibuffer', which is what the adjustment
        ;; is for (minibuffer.el:5214).
        (when (pair? initial)
          (set! initial (cons (car initial) (+ 1 (cdr initial)))))
        (parameterize ((*minibuffer-completion-table* collection)
                       (*minibuffer-completion-predicate* predicate)
                       ;; GNU Emacs's own line for this
                       ;; (`minibuffer.el:5243'): the *symbol* REQUIRE-MATCH
                       ;; named unless it is `t' - so `confirm' and
                       ;; `confirm-after-completion' arrive as themselves
                       ;; and a plain `t' arrives as nil. It was `#t' here,
                       ;; which threw away the difference that
                       ;; `completion--complete-and-exit' needs.
                       (*minibuffer-completion-confirm*
                        (if (eq? require-match #t) #f require-match)))
          (read-from-minibuffer
           prompt initial
           ;; The map to read it with. GNU Emacs layers
           ;; `minibuffer-local-filename-completion-map' over the base
           ;; map when `minibuffer-completing-file-name' is set, which
           ;; `read-file-name' does - and its one job is to take SPC
           ;; away from `minibuffer-complete-word', so that a file name
           ;; may have a space in it. A nil binding in the layered map
           ;; overrides the parent map it is composed with, which is
           ;; documented in `make-composed-keymap'.
           (completion--map-for (if require-match
                                    minibuffer-local-must-match-map
                                    minibuffer-local-completion-map))
           history default))))
	
    (define *minibuffer-completing-file-name* (make-parameter #f))
    ;; ^ GNU Emacs's `minibuffer-completing-file-name': whether the
    ;; minibuffer being read is reading a file name, which decides
    ;; whether `minibuffer-local-filename-completion-map' is layered
    ;; over the completion map. `read-file-name' binds it.

    (define *insert-default-directory* (make-parameter #t))
    ;; ^ GNU Emacs's `insert-default-directory' (minibuffer.el:3915):
    ;; "Non-nil means when reading a filename start with the default
    ;; directory in the minibuffer." `read-file-name' puts the directory
    ;; in the minibuffer when this is set, and the directory plus the
    ;; INITIAL after it when there is one - with point after the
    ;; directory, so that the name is what is typed over. Emacs's value
    ;; is t.

    (define (completion--map-for base)
      ;; BASE with `minibuffer-local-filename-completion-map' composed
      ;; over it when a file name is being read: GNU Emacs's
      ;; `(make-composed-keymap minibuffer-local-filename-completion-map
      ;; base-keymap)', which makes a map with the first's bindings and
      ;; the base as its *parent*. A parent is what lets the composed
      ;; map's binding for a key override the base's, and it is why a
      ;; fresh map is made rather than the shared one's parent set.
      ;; Emacs tests `(memq minibuffer-completing-file-name '(nil
      ;; lambda))' - a file name is being read unless the variable is
      ;; nil.
      ;;--------------------------------------------------------------
      (if (not (*minibuffer-completing-file-name*))
          base
          (let ((map (minibuffer-map-from-bindings
                      '*minibuffer-filename-completion-map*
                      (minibuffer-filename-completion-bindings))))
            (km:set-keymap-parent map base)
            map)))

    ;;----------------------------------------------------------------
    ;; The *Completions* buffer

    (define *completions-common-substring* (make-parameter ""))
    ;; ^ The COMMON-SUBSTRING the `*Completions*' buffer was last filled
    ;; with, which is what says how much of each candidate matched. GNU
    ;; Emacs keeps the same fact as the `completion-base-position' text
    ;; property on the candidates; the line's faces have to be written
    ;; again when the selection moves, and this is what they are written
    ;; from.

    (define (set-completion-line-faces! buffer start end highlight?)
      ;; Write the `face' property over one candidate line: GNU Emacs's
      ;; `completion-hilit-commonality' puts `completions-common-part'
      ;; on the part of the candidate the pattern matched and
      ;; `completions-first-difference' on the first character past it,
      ;; and the line carries the selection face as well when
      ;; HIGHLIGHT?.
      ;;
      ;; The whole line is written at once, rather than adding to
      ;; whatever is there, so that taking the selection off a line
      ;; leaves the highlighting it had rather than a line with no
      ;; faces at all.
      ;;--------------------------------------------------------------
      ;; **The buffer is read-only and the write is allowed.** The
      ;; *Completions* buffer is `special-mode''s - buffer-read-only -
      ;; and a property write barfs on it: measured, M-<down> moved
      ;; point (which needs no write) while the selection face never
      ;; landed, the command loop catching the `buffer-read-only' signal
      ;; into the echo-area message the pty dump showed beside the
      ;; prompt. Emacs writes into this buffer under
      ;; `inhibit-read-only' (`minibuffer.el:2402', the lazy insert's
      ;; own `let'), which is what binds this.
      (parameterize ((*inhibit-read-only* #t))
        (remove-text-properties start end '(face) buffer)
        (let* ((candidate (make-buffer-string buffer start end))
               (matched (min (string-length (*completions-common-substring*))
                             (string-length candidate))))
          (when highlight?
            (put-text-property start end 'face 'completions-highlight buffer))
          (when (< 0 matched)
            (put-text-property
             start (+ start matched) 'face
             (if highlight?
                 '(completions-common-part completions-highlight)
                 'completions-common-part)
             buffer))
          (when (< (+ start matched) end)
            (put-text-property
             (+ start matched) (+ 1 start matched) 'face
             (if highlight?
                 '(completions-first-difference completions-highlight)
                 'completions-first-difference)
             buffer)))))

    (define *completion-show-help*
      ;; GNU Emacs's `completion-show-help': whether the `*Completions*'
      ;; buffer carries the two lines that say how to use it.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *completions-header-format*
      ;; GNU Emacs's `completions-header-format': the heading line at the
      ;; top of the list, whose one `%s' is the number of candidates, or
      ;; #f for a list with no heading at all. Emacs puts the `shadow'
      ;; face on it.
      ;;--------------------------------------------------------------
      (make-parameter "%s possible completions:\n"))

    (define (completion-setup-function buffer)
      ;; GNU Emacs's `completion-setup-function', which writes the two
      ;; lines that say how to use the list at the top of it: the key that
      ;; takes a candidate, and the keys that move between them.
      ;;
      ;; It is on `completion-setup-hook' in Emacs, and that function is
      ;; simple.el's - but it fills the `*Completions*' buffer, and simple
      ;; is imported *by* this library, so it lives here instead. A `.el'
      ;; file needs no such care: it only has to be loaded once.
      ;;
      ;; Emacs renders the lines with `substitute-command-keys', which is
      ;; where `\[minibuffer-choose-completion]' becomes the key it is
      ;; bound to; the keys are written out here because nothing here
      ;; substitutes. `display-mouse-p' is false of a terminal, which is
      ;; why Emacs's line does not offer to click.
      ;;--------------------------------------------------------------
      (when (*completion-show-help*)
        (set-point buffer (buffer-beg buffer))
        (with-current-buffer buffer (insert "Type M-RET on a completion to select it.\n"))
        (with-current-buffer buffer (insert (string-append
                             "Type M-<down> or M-<up> to move point between "
                             "completions.\n\n")))))

    (define *completion-setup-hook*
      ;; GNU Emacs's `completion-setup-hook': run at the end of
      ;; `display-completion-list', with the completions buffer current.
      ;;--------------------------------------------------------------
      (make-parameter (list completion-setup-function)))

    (define (run-completion-setup-hook! buffer)
      (for-each (lambda (hook) (hook buffer)) (*completion-setup-hook*)))

    (define (completions-header-string count)
      ;; GNU Emacs's `completions-header-format' with its one `%s' - the
      ;; number of candidates - filled in.
      ;;
      ;; Not through `format': the format string here is Emacs's, and its
      ;; directive is `%s' where Guile's `format' spells one `~A'. Writing
      ;; the substitution out keeps the variable the same variable, which
      ;; is the point of having it - Emacs's docstring is "The format
      ;; string may include one %s".
      ;;--------------------------------------------------------------
      (let* ((format-string (*completions-header-format*))
             (text (number->string count))
             (at (string-contains format-string "%s")))
        (if (not at)
            format-string
            (string-append (substring format-string 0 at)
                           text
                           (substring format-string (+ at 2)
                                      (string-length format-string))))))

    (define (insert-completions-header! buffer count)
      ;; The heading line, `N possible completions:' in the `shadow' face:
      ;; GNU Emacs's `completions-header-format', inserted before the
      ;; candidates.
      ;;--------------------------------------------------------------
      (when (*completions-header-format*)
        ;; The property range is in *positions*, so it starts where the
        ;; text will go - `point-max' before the insert - and ends where
        ;; it went: `point-max' after it.
        (let ((start (buffer-z buffer)))
          (with-current-buffer buffer (insert (completions-header-string count)))
          (put-text-property start (buffer-z buffer)
                             'face 'shadow buffer))))

    (define (insert-completion-cell! buffer candidate)
      ;; The core of GNU Emacs's `completion--insert': put CANDIDATE at
      ;; point with the `completion--string' property that says it *is*
      ;; a candidate. (Emacs's `completion-hilit-commonality' does the
      ;; two faces to the candidate *strings*; a string here cannot
      ;; carry a property, so the faces go straight on the buffer text.)
      ;;--------------------------------------------------------------
      (let ((start (buffer-z buffer)))
        (with-current-buffer buffer (insert candidate))
        (put-text-property start (buffer-z buffer)
                           'completion--string candidate buffer)
        (set-completion-line-faces!
         buffer start (+ start (string-length candidate)) #f)))

    (define (insert-completion-separator! buffer str)
      ;; Insert the text between cells - a row break or the padding to
      ;; the next column - and take the `completion--string' property
      ;; back off it. Inserting text at the end of a propertized run
      ;; lets that run's property extend over the new text here (the
      ;; engine's `adjust-intervals-for-insertion' grows the interval
      ;; across it), and Emacs's separators carry no property: a
      ;; candidate's start is found again by "the character before has
      ;; no property", which only works while the separator between two
      ;; cells stays clean.
      ;;--------------------------------------------------------------
      (let ((start (buffer-z buffer)))
        (with-current-buffer buffer (insert str))
        (remove-text-properties start (buffer-z buffer)
                                '(completion--string) buffer)))

    (define *completions-format*
      ;; GNU Emacs's `completions-format': whether the candidates are
      ;; laid out across the window in columns or down the screen one
      ;; per line. `horizontal' is Emacs's default; `one-column' has no
      ;; arithmetic of its own, and what used to be this library's whole
      ;; layout is its `completion--insert-one-column'. Emacs's
      ;; `vertical' arrangement and the truncation of a list taller
      ;; than the window (`completions-max-height') are not implemented.
      ;;--------------------------------------------------------------
      (make-parameter 'horizontal))

    (define (completion--insert-strings buffer completions)
      ;; GNU Emacs's `completion--insert-strings': how many columns the
      ;; window can take, and the candidates arranged in them. The
      ;; arithmetic is Emacs's, kept with it:
      ;;
      ;;  * LENGTH is the widest candidate;
      ;;  * WWIDTH is the window's width less a column, or 79 when the
      ;;    window is not on the screen (Emacs's fallback);
      ;;  * COLUMNS fits as many `(+ 2 LENGTH)' columns into the width
      ;;    as it can - at least two spaces between columns - and is
      ;;    halved against the number of candidates, so that no column
      ;;    is given fewer than two of them;
      ;;  * COLWIDTH is the width each column is laid out to.
      ;;--------------------------------------------------------------
      (when (pair? completions)
        (let* ((count (length completions))
               ;; ^ Emacs's `(length strings)' is read here, *before*
               ;; LENGTH is bound below, because Scheme has one
               ;; namespace where Emacs Lisp has two: there, `length'
               ;; the function and LENGTH the variable coexist, and the
               ;; count is asked without thinking about which is which.
               (length (apply max (map string-length completions)))
               (window (get-buffer-window buffer))
               (wwidth (if window (- (window-width window) 1) 79))
               (columns (min (max 1 (quotient wwidth (+ 2 length)))
                             (max 1 (quotient count 2))))
               (colwidth (quotient wwidth columns)))
          (case (*completions-format*)
            ((one-column)
             (completion--insert-one-column buffer completions))
            ((horizontal)
             (completion--insert-horizontal buffer completions length
                                            wwidth colwidth columns))
            (else
             (error "Unknown completion format" (*completions-format*)))))))

    (define (completion--insert-horizontal buffer completions length
                                           wwidth colwidth columns)
      ;; GNU Emacs's `completion--insert-horizontal': the candidates in
      ;; rows, each in its own column, each following cell padded out to
      ;; the next `colwidth' boundary. Emacs pads with a tab carrying a
      ;; `display' property that aligns the next character to the column
      ;; on redisplay; this editor has no display properties, so the
      ;; padding is literal spaces, which is what the screen shows
      ;; either way.
      ;;
      ;; A candidate that would run past the window's width starts a new
      ;; row. The column pointer advances by one `colwidth' - Emacs's
      ;; `(* colwidth (ceiling length colwidth))' - a whole number of
      ;; column widths, which is one, a column never being narrower than
      ;; LENGTH + 2.
      ;;--------------------------------------------------------------
      (let loop ((rest completions) (column 0) (first #t) (last #f))
        (if (null? rest)
            #f
            (let ((str (car rest)))
              (if (equal? last str)
                  ;; a (consecutive) duplicate is not shown twice
                  (loop (cdr rest) column first last)
                  (begin
                    (if first
                        #t
                        (if (< wwidth (+ column (max colwidth
                                                     (string-length str))))
                            ;; no room for STR at this column: next row
                            (begin
                              (insert-completion-separator! buffer "\n")
                              (set! column 0))
                            (insert-column-padding! buffer column)))
                    (insert-completion-cell! buffer str)
                    (loop (cdr rest) (+ column colwidth) #f str)))))))

    (define (completion--insert-one-column buffer completions)
      ;; GNU Emacs's `completion--insert-one-column': the candidates
      ;; down the screen, one per line, with no newline after the last -
      ;; Emacs's `(delete-char -1)', which deletes the final one
      ;; *backward*, so the cursor steps back across it first.
      ;;--------------------------------------------------------------
      (let loop ((rest completions))
        (if (null? rest)
            (begin
              ;; The separator after the last candidate comes off, and
              ;; point steps back across it - Emacs's `(delete-char -1)'
              ;; with point at the end.
              (with-current-buffer buffer
                (delete-region (- (buffer-z buffer) 1) (buffer-z buffer))))
            (begin
              (insert-completion-cell! buffer (car rest))
              (insert-completion-separator! buffer "\n")
              (loop (cdr rest))))))

    (define (insert-column-padding! buffer column)
      ;; Pad the current line out to COLUMN with spaces, so the next
      ;; candidate starts where its column says: the `(display
      ;; (space :align-to COLUMN))' Emacs puts on the tab between
      ;; candidates, which its redisplay draws exactly as these spaces.
      ;;--------------------------------------------------------------
      (let ((at (text-editor-cursor-column buffer)))
        (when (< at column)
          (insert-completion-separator!
           buffer (make-string (- column at) #\space)))))

    (define (display-completion-list completions common-substring)
      ;; GNU Emacs's `display-completion-list': fill the `*Completions*'
      ;; buffer with COMPLETIONS and answer with it.
      ;;
      ;; The layout is Emacs's: `completion--insert-strings' works out
      ;; how many columns fit the window and `completion--insert-horizontal'
      ;; writes the candidates into them. The lines that are not
      ;; candidates - the heading and the help - are why a candidate is
      ;; marked with a property rather than being "the line point is on".
      ;;
      ;; The one deliberate departure is where the faces go: `completion-
      ;; hilit-commonality' does them to the candidate *strings* in Emacs,
      ;; and a string here cannot carry a property, so they are put on
      ;; the buffer text here instead - see `insert-completion-cell!'.
      ;;
      ;; **It appends and does not erase**, which is Emacs's contract: the
      ;; C goes to `point-max' and inserts there, and what empties the list
      ;; is the *caller* - `temp-buffer-window-setup` (`window.el:91'), run
      ;; by `minibuffer-completion-help` through `with-current-buffer-window`.
      ;; The erase used to be here, which meant this function could not be
      ;; used the way Emacs's is, to add to a list already on screen.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create "*Completions*")))
        (with-current-buffer buffer
          (goto-char (point-max))
          (*completions-common-substring* common-substring)
          (insert-completions-header! buffer (length completions))
          (completion--insert-strings buffer completions)
          ;; The help goes in at the *top*, above the heading, which is
          ;; what Emacs's `completion-setup-function' does by going to
          ;; `point-min' and inserting there - and it leaves point just
          ;; after the help, on the heading line, with the candidates
          ;; below it, so the first `M-<down>' reaches the first one.
          ;;
          ;; This insertion in the *middle* of a buffer whose text
          ;; carries properties is the one that used to come apart: see
          ;; the note on `adjust-intervals-for-insertion' in
          ;; `(schemacs intervals)'.
          (run-completion-setup-hook! buffer)
          (set!buffer-read-only buffer #t))
        buffer))

    (define *completions-max-height* (make-parameter #f))
    ;; ^ GNU Emacs's `completions-max-height': the most lines the
    ;; `*Completions*' window may have. Nil - Emacs's default - means
    ;; the window may grow to the frame.

    (define (completion-fitted-height buffer)
      ;; The height `completion-display-window' gives the `*Completions*'
      ;; window, as GNU Emacs's `fit-window-to-buffer' computes it: the
      ;; buffer's text *rows* plus its mode line, at least
      ;; `window-min-height', at most `*completions-max-height*' or -
      ;; that being nil - the frame's text area less a minimum for the
      ;; window above.
      ;;--------------------------------------------------------------
      ;; **The measure is the display's, not the line count.** Emacs
      ;; asks `window-text-pixel-size' (`window.el:10415') - how many
      ;; pixels the text will occupy *as drawn*, wrapped rows included -
      ;; and rounds to lines. This tree's `%count-lines' is the logical
      ;; line breaks, and a candidate line wider than the window wraps
      ;; into more rows than it has breaks: measured on a 60-column
      ;; window, a buffer of 3 logical lines is 5 display rows, and the
      ;; window fitted from the logical count left its last line under
      ;; the mode line - Chris's report. The walk
      ;; `window-line-rows-at' answers what the display will draw, one
      ;; line's rows at a time, which is the same question the C's
      ;; measure answers.
      ;;--------------------------------------------------------------
      (let* ((row-walk
              (let loop ((pos (buffer-beg buffer)) (rows 0))
                (if pos
                    (loop (line-next-start buffer pos)
                          (+ rows (window-line-rows-at
                                   (or (get-buffer-window buffer)
                                       (selected-window))
                                   pos)))
                    rows)))
             (needed (+ 1 row-walk))
             (max-height (or (*completions-max-height*)
                             (max 1
                                  (- (- (frame-height (*current-frame*)) 1)
                                     window-min-height)))))
        (min (max window-min-height needed) max-height)))

    (define (completion-display-window buffer)
      ;; Put the `*Completions*' buffer in a window, and answer with the
      ;; window: GNU Emacs's `minibuffer-completion-help' displays the
      ;; list with `display-buffer-at-bottom' in place of
      ;; `display-buffer-use-some-window'. Two things follow that the
      ;; plain `display-buffer' does not do:
      ;;
      ;;  * the list is shown in the bottom-most window that already
      ;;    shows it, or in a *new* window split off the frame's root -
      ;;    `split-main-window-below', Emacs's `(split-window
      ;;    (window-main-window))' - so the list is always a full-width
      ;;    window at the bottom of the frame, never an unrelated window
      ;;    taken over, and never one half of a split;
      ;;  * the window is made before the buffer is filled, so the
      ;;    layout can read the window's *width* - which is Emacs's
      ;;    order too (its `body-function' fills after the window is
      ;;    displayed). `completion-fit-window', which the caller runs
      ;;    after filling, sizes it to the list.
      ;;--------------------------------------------------------------
      (let* ((windows (window-list))
             (bottom (and (pair? windows)
                          (list-ref windows (- (length windows) 1)))))
        (if (and bottom (eq? (window-buffer bottom) buffer))
            (begin (record-buffer! buffer) bottom)
            (split-main-window-below buffer window-min-height))))

    (define (completion-fit-window buffer)
      ;; Size the `*Completions*' window to its list, and answer with it:
      ;; GNU Emacs's `completions--fit-window-to-buffer', run by the
      ;; display's `window-height' after the buffer is filled. A window
      ;; whose height already fits is kept; one that does not is replaced
      ;; by a fresh split at the fitted height - the replacement is just
      ;; this editor's way of resizing, and nothing is drawn between the
      ;; two.
      ;;--------------------------------------------------------------
      (let* ((needed (completion-fitted-height buffer))
             (window (get-buffer-window buffer)))
        (if (and window (= (window-height window) needed))
            window
            (begin
              (when (and window (< 1 (length (window-list))))
                (delete-window window))
              (split-main-window-below buffer needed)))))

    (define (choose-completion-string choice mb base-position)
      ;; GNU Emacs's `choose-completion-string' (`simple.el'): "insert the
      ;; completion choice CHOICE. BASE-POSITION says where to insert
      ;; the completion" - CHOICE replaces the minibuffer's text from
      ;; the first position to the second, and with no BASE-POSITION the
      ;; whole of it. For a file name the base is the end of the
      ;; directory, so `alpha.txt' chosen in a `/tmp/mbtest/' list gives
      ;; `/tmp/mbtest/alpha.txt'.
      ;;
      ;; Emacs then exits the minibuffer unless the choice is a directory
      ;; (its boundaries end where the text does); nothing here exits on
      ;; a choice - RET does - so that decision is not made here.
      ;;--------------------------------------------------------------
      (let* ((text (minibuffer-contents))
             (start (if (pair? base-position) (car base-position) 0))
             (end (if (and (pair? base-position) (pair? (cdr base-position)))
                      (cadr base-position)
                      (string-length text))))
        (minibuffer-set-contents!
         mb (string-append (substring text 0 (min start (string-length text)))
                           choice
                           (substring text (min end (string-length text))
                                      (string-length text))))))

      ;; GNU Emacs's `choose-completion': take the candidate on this line
      ;; and put it in the minibuffer that asked for the completion, then
      ;; take the completions window away.
      ;;
      ;; Emacs finds the candidate's text properties to know what to
      ;; insert; here the line point is on *is* the candidate, so the line
      ;; is what is read - and that is why the buffer is one per line.
      ;;--------------------------------------------------------------
    (define-command (choose-completion)
      "Select the completion on this line."
      (interactive)
      (let* ((ed (current-buffer))
             (candidate (get-text-property (buffer-pt ed)
                                           'completion--string ed))
             (mb (*minibuffer*)))
        (when (and mb (> (string-length candidate) 0))
          (choose-completion-string candidate mb
                                    (buffer-local-value ed 'completion-base-position #f))
          (quit-window))))

    (define completion-list-mode-map
      ;; GNU Emacs's `completion-list-mode-map': RET selects the
      ;; completion on the line - putting it in the minibuffer that is
      ;; still being read - and `q' takes the window away again.
      ;;
      ;; Emacs also binds `n' and `p' to the ordinary line motion, which
      ;; is not stated here because the buffer's keymap falls back to the
      ;; global one, where those already live.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*completion-list-mode-map*)))
        (define (bind! key command)
          (define-key map (kbd key) command))
        (bind! "q" quit-window)
        (bind! "C-m" choose-completion)
        (bind! "RET" choose-completion)
        map))

    ;;----------------------------------------------------------------
    ;; Messages in the echo area while the minibuffer is being read
    ;;
    ;; GNU Emacs's `minibuffer-message' (`minibuffer.el:812'), the
    ;; overlay it draws with, and the two functions `message` is routed
    ;; through while a prompt is up. The echo area is a window and its
    ;; buffer is drawn by the display layer; what is here is what a
    ;; message put there *says* and how long it stays.
    ;;
    ;; **Why an overlay.** The echo area's row is showing the prompt -
    ;; the very text the user is typing into - so a message written into
    ;; the echo buffer would hide it. `minibuffer.el` puts an
    ;; `after-string` on an empty overlay at the end of the minibuffer
    ;; instead, and the row builder draws it after the text. That is the
    ;; same mechanism Emacs uses, and this tree's renderer already draws
    ;; overlay strings.

    (define *minibuffer-message-timeout*
      ;; GNU Emacs's `minibuffer-message-timeout': how long a message
      ;; shown while the minibuffer is being read stays in the echo
      ;; area, in seconds, or #f for one that stays until the next key.
      ;; Emacs's default is two, set in `keyboard.c'.
      ;;--------------------------------------------------------------
      (make-parameter 2))

    (define *completion-show-inline-help*
      ;; GNU Emacs's `completion-show-inline-help': whether the
      ;; completion commands say what they found in the echo area.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (message-enclosed? message)
      ;; Whether MESSAGE is already written the way this function
      ;; writes one - some spaces, then `[...]' - which is the test GNU
      ;; Emacs makes with the regexp `"\\` *\\[.+\\]\\'"' before
      ;; enclosing it again.
      ;;--------------------------------------------------------------
      (let loop ((i 0))
        (cond
         ((= i (string-length message)) #f)
         ((char=? (string-ref message i) #\space) (loop (+ 1 i)))
         ((char=? (string-ref message i) #\[)
          (and (< 2 (- (string-length message) i))
               (char=? (string-ref message (- (string-length message) 1))
                       #\])))
         (else #f))))

    (define *minibuffer-message-properties* (make-parameter '()))
    ;; ^ GNU Emacs's `minibuffer-message-properties`
    ;; (`minibuffer.el:797`): "Text properties added to the text shown by
    ;; `minibuffer-message'." Nil by default.

    (define *minibuffer-message-clear-timeout* (make-parameter #f))
    ;; ^ GNU Emacs's `minibuffer-message-clear-timeout`
    ;; (`minibuffer.el:864`): how long a message routed through
    ;; `message` stays while a prompt is up. A number is a timeout; nil,
    ;; the default, leaves it until the next input event.

    (define *minibuffer--message-overlay* (make-parameter #f))
    (define *minibuffer--message-timer* (make-parameter #f))
    ;; ^ `minibuffer--message-overlay` and `minibuffer--message-timer`
    ;; (`minibuffer.el:799`, `:801`): the text on screen and the timer
    ;; that takes it down. Both are parameters because Emacs's are
    ;; ordinary variables that commands `let`-bind - `minibuffer-message`
    ;; sets them, and `clear-message-function` reads them from outside
    ;; any lexical scope.

    (define (minibuffer--message-overlay-pos)
      ;; GNU Emacs's `minibuffer--message-overlay-pos` (`minibuffer.el`):
      ;; "Return position where minibuffer message functions shall put
      ;; message overlay." The first position carrying a non-nil
      ;; `minibuffer-message` text property, or the end of the buffer.
      ;;--------------------------------------------------------------
      (let ((ed (and (*minibuffer*) (minibuffer-editor (*minibuffer*)))))
        (if (not ed)
            (point-max)
            (with-current-buffer ed
              (let loop ((p (point)))
                (cond ((= p (point-max)) p)
                      ((get-text-property p 'minibuffer-message ed) p)
                      (else (loop (+ p 1)))))))))

    (define (minibuffer--delete-message-overlay)
      ;; GNU Emacs's `minibuffer--delete-message-overlay`
      ;; (`minibuffer.el:804`): take the message overlay down and cancel
      ;; the timer that would have taken it down.
      ;;--------------------------------------------------------------
      (let ((overlay (*minibuffer--message-overlay*))
            (timer (*minibuffer--message-timer*)))
        (when overlay (delete-overlay overlay))
        (*minibuffer--message-overlay* #f)
        (when timer (cancel-timer timer))
        (*minibuffer--message-timer* #f)))

    (define (%minibuffer-message-enclose message)
      ;; The `[...]' the two message functions put round a message that
      ;; is not already written that way (`minibuffer.el:839`, `:915`):
      ;; "Enclose MESSAGE in [...] if it is not yet enclosed."
      ;;--------------------------------------------------------------
      (if (message-enclosed? message)
          message
          (string-append " [" message "]")))

    (define (%minibuffer-message-put message timeout)
      ;; The half the two functions share: put MESSAGE after the text as
      ;; an overlay's `after-string`, arm TIMEOUT if there is one, and
      ;; record both so that `minibuffer--delete-message-overlay` can
      ;; take them down.
      ;;
      ;; `priority 1100` is Emacs's (`minibuffer.el:851`): the message
      ;; must be drawn before any other overlay string at the end of the
      ;; text, or a long one could be pushed out of the window.
      ;;--------------------------------------------------------------
      (minibuffer--delete-message-overlay)
      (let ((pos (minibuffer--message-overlay-pos))
            (ed (minibuffer-editor (*minibuffer*))))
        (let ((overlay (with-current-buffer ed (make-overlay pos pos #f #t #t))))
          (with-current-buffer ed
            (overlay-put overlay 'after-string message)
            (overlay-put overlay 'priority 1100))
          (*minibuffer--message-overlay* overlay)
          ;; `(run-at-time (or minibuffer-message-timeout 1000000) nil
          ;; #'minibuffer--delete-message-overlay)` - always armed, and a
          ;; timeout of 0 fires at once. `set-minibuffer-message` arms its
          ;; own only `(when (numberp minibuffer-message-clear-timeout))`,
          ;; which is the caller's business: TIMEOUT is #f for never.
          (when (number? timeout)
            (*minibuffer--message-timer*
             (run-at-time timeout #f minibuffer--delete-message-overlay))))))

    (define (minibuffer-message text . args)
      ;; GNU Emacs's `minibuffer-message' (`minibuffer.el:812'): show
      ;; MESSAGE at the end of what has been typed, without hiding it,
      ;; and take it down again after `minibuffer-message-timeout'
      ;; seconds or at the next key, whichever comes first.
      ;;
      ;; **The argument is TEXT and not MESSAGE**, which is Emacs's name
      ;; for it: Scheme is a Lisp-1, so a parameter called MESSAGE would
      ;; hide the `message` this function *calls* in its first branch -
      ;; the C's `(apply #'message message args)` - and the string would
      ;; be applied. Same class as `newline` being spelled
      ;; `insert-newline` in `simple.scm`.
      ;;
      ;; **Called when no minibuffer is being read it is plain
      ;; `message`** - the echo area is not showing a prompt, so there is
      ;; nothing to show the text *after*. The C's whole first line:
      ;;
      ;;   (if (not (minibufferp (current-buffer) t))
      ;;       (apply #'message message args)
      ;;--------------------------------------------------------------
      (if (not (minibufferp))
          (apply message (if (pair? args) (apply format #f text args) text) '())
          ;; Elisp's `if` takes a body on the else side; Scheme's does not,
          ;; so the C's four statements are one `begin`.
          (begin
            (minibuffer--delete-message-overlay)
            ;; `(message nil)` - "Clear out any old echo-area message to
            ;; make way for our new thing" (`minibuffer.el:836`).
            (set!frame-message (*current-frame*) "")
            (let ((shown (%minibuffer-message-enclose text)))
              (when (pair? args) (set! shown (apply format #f shown args)))
              (%minibuffer-message-put
               shown
               (or (*minibuffer-message-timeout*) 1000000))))))

    (define (set-minibuffer-message frame message)
      ;; GNU Emacs's `set-minibuffer-message' (`minibuffer.el:899'): the
      ;; `set-message-function` that makes `message` work while a prompt
      ;; is up. It answers true - "the message was handled specially by
      ;; this function" - when a minibuffer window is live on FRAME's
      ;; selected frame, so the echo buffer is not touched at all.
      ;;
      ;; The docstring is Emacs's: "Temporarily display MESSAGE at the
      ;; end of the active minibuffer window." The C calls it through
      ;; `Vset_message_function` (`xdisp.c:13585`), which this tree
      ;; reaches from `set!frame-message`.
      ;;--------------------------------------------------------------
      (let ((mini (and (eq? frame (*current-frame*))
                       frame
                       (frame-minibuffer-window frame))))
        (and mini
             (window-buffer mini)
             (*minibuffer*)
             ;; "the active minibuffer" is one whose window is not
             ;; showing the empty ` *Minibuf-0*'
             (not (eq? (window-buffer mini) (*minibuf-0*)))
             (begin
               (let ((text (%minibuffer-message-enclose message)))
                 (%minibuffer-message-put
                  text (*minibuffer-message-clear-timeout*)))
               ;; "Return t telling the caller that the message was
               ;; handled specially by this function."
               #t))))

    (define (clear-minibuffer-message frame)
      ;; GNU Emacs's `clear-minibuffer-message' (`minibuffer.el:1045`):
      ;; "Clear echo-area message when the minibuffer is active." It is
      ;; `clear-message-function`, so `clear_message` reaches it
      ;; (`xdisp.c:13644`) - and this tree reaches it from
      ;; `set!frame-message` with an empty string, which is what the
      ;; command loop does at the start of every command.
      ;;--------------------------------------------------------------
      (minibuffer--delete-message-overlay)
      #f)

    ;; **`message` is routed through these while a prompt is up.**
    ;; `minibuffer.el` ends its own definition of them with
    ;;
    ;;   (setq set-message-function 'set-message-functions)
    ;;   (setq clear-message-function 'clear-minibuffer-message)
    ;;
    ;; - the first being a list of handlers, of which
    ;; `set-minibuffer-message` is the only one here. The seam in
    ;; `(schemacs frame)` hands each the frame as well, because
    ;; that is where this tree's echo area lives.
    (*set-message-function* set-minibuffer-message)
    (*clear-message-function* clear-minibuffer-message)

    (define (completion--message msg)
      ;; GNU Emacs's `completion--message': the "No match", "Sole
      ;; completion" and "Complete, but not unique" messages of the
      ;; completion commands, said only when
      ;; `completion-show-inline-help' allows it.
      ;;--------------------------------------------------------------
      (when (*completion-show-inline-help*) (minibuffer-message msg)))

    ;;----------------------------------------------------------------
    ;; The completions window, on the way out
    ;;
    ;; GNU Emacs removes the `*Completions*' window when the minibuffer
    ;; exits, whatever took it out of the minibuffer - RET, C-g, or a
    ;; command that left on its own. Two functions do it there and it
    ;; does the second one here; see `MINIBUFFER-RESTORE-WINDOWS' below
    ;; for why.

    (define (completions-window)
      ;; The window showing the `*Completions*' buffer, or #f when it
      ;; is not on the screen: the window half of GNU Emacs's
      ;; `minibuffer--completions-visible'.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer "*Completions*")))
        (and buffer (get-buffer-window buffer))))

    (define (minibuffer-hide-completions)
      ;; GNU Emacs's `minibuffer-hide-completions': get rid of an
      ;; out-of-date `*Completions*' buffer. Emacs buries the buffer in
      ;; the window; the window itself goes when the window
      ;; configuration is restored on the way out of the minibuffer,
      ;; and this project has no window configurations, so the window
      ;; is taken away here as well. Leaving it would leave the frame
      ;; split after the completion was over.
      ;;
      ;; The buffer stays alive - buried, where `C-x b' can reach it -
      ;; because that is what Emacs does with it.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer "*Completions*")))
        (when buffer
          (let ((window (get-buffer-window buffer)))
            ;; A sole window cannot be deleted, and must not be: if the
            ;; completions buffer was put in the frame's only window,
            ;; burying it is all there is to do.
            (when (and window (< 1 (length (window-list))))
              (delete-window window)))
          (bury-buffer buffer))))

    (define (minibuffer-restore-windows)
      ;; GNU Emacs's `minibuffer-restore-windows', which is on
      ;; `minibuffer-exit-hook'. In Emacs it is the *second* of two
      ;; routes: when `read-minibuffer-restore-windows' is nil the hook
      ;; removes at least the `*Completions*' window, and when it is
      ;; non-nil - the default - `read_minibuffer' instead restores the
      ;; window configuration it recorded on the way in, which removes
      ;; it just as surely. This project has no window configurations,
      ;; so it takes the first route for every exit, and that is
      ;; equivalent for the window this is about.
      ;;--------------------------------------------------------------
      (minibuffer-hide-completions))

    (define *minibuffer-setup-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `minibuffer-setup-hook' (`minibuf.c':2564): "Normal
    ;; hook to run when entering the minibuffer." `read_minibuf' runs it
    ;; after the prompt and the initial input are in place and the
    ;; minibuffer's keymap is bound, and before the recursive edit
    ;; (minibuf.c:912) - so it runs with the minibuffer current and can
    ;; still see what is in it. It is what
    ;; `minibuffer-lazy-highlight-setup' adds its hook to.

    (define *minibuffer-exit-hook* (make-parameter (list minibuffer-restore-windows)))
    ;; ^ GNU Emacs's `minibuffer-exit-hook': run when a minibuffer is
    ;; left. It is a `make-parameter' holding the list of procedures
    ;; rather than a global list, so a caller can bind it the way Emacs
    ;; lets a caller add to it.

    ;;----------------------------------------------------------------
    ;; Moving through the completions
    ;;
    ;; GNU Emacs's `minibuffer-next-completion' and its neighbours: the
    ;; cursor moves through the `*Completions*' buffer while point stays
    ;; in the minibuffer, and RET then takes the candidate it is on.
    ;; Emacs lays the candidates out in columns and walks the cells by
    ;; their text property; so does `move-completions' below, which is
    ;; Emacs's `next-column-completion' for a horizontal format.

    (define *completions-highlight-range* #f)
    ;; ^ The range of the completions buffer currently carrying the
    ;; `completions-highlight' face, or #f: what has to have the face
    ;; taken off it when the selection moves. GNU Emacs marks the
    ;; selected candidate with a `cursor-face' text property and lets
    ;; the display decide; this editor's display reads `face', so the
    ;; selection is written as a face here and the old one has to be
    ;; cleared by hand.

    (define (clear-completions-selection!)
      ;; Take the selection face off whatever had it: GNU Emacs's
      ;; `completions--clear-selection' is where point is moved off the
      ;; candidate, and this is the face that says which candidate that
      ;; was.
      ;;--------------------------------------------------------------
      (when *completions-highlight-range*
        (let* ((buffer (get-buffer "*Completions*"))
               (range *completions-highlight-range*))
          (when buffer
            ;; put the line's own highlighting back, not nothing
            (set-completion-line-faces! buffer (car range) (cdr range) #f)))
        (set! *completions-highlight-range* #f)))

    (define (show-completions-selection! buffer)
      ;; Put the selection face on the cell point is on - just that
      ;; cell, not the row, which shared its line with the cells around
      ;; it once the candidates went into columns. GNU Emacs puts a
      ;; `cursor-face' property there and lets the display decide; this
      ;; editor's display reads `face'.
      ;;--------------------------------------------------------------
      (clear-completions-selection!)
      (let* ((start (buffer-pt buffer))
             (end (completion--cell-end buffer start)))
        (when (< start end)
          (set-completion-line-faces! buffer start end #t)
          (set! *completions-highlight-range* (cons start end)))))

    (define (completion-start-at? buffer i)
      ;; Whether I is the first character of a completion cell: it
      ;; carries the `completion--string' property and the character
      ;; before it does not. Cells are what the horizontal layout put
      ;; on the row, and the spaces between them are what keeps this
      ;; test from being true inside one.
      ;;--------------------------------------------------------------
      (and (get-text-property i 'completion--string buffer)
           (or (= i 0)
               (not (get-text-property (- i 1) 'completion--string
                                       buffer)))))

    (define (completion-next-cell-start buffer from)
      ;; The first completion cell start after FROM, or #f: GNU Emacs's
      ;; `next-column-completion' founds its walk on the text property
      ;; each candidate was written with, and so does this - an index
      ;; kept where it is through the help insertion and the layout.
      ;;--------------------------------------------------------------
      (let ((last (buffer-z buffer)))
        (let loop ((i (+ from 1)))
          (cond ((>= i last) #f)
                ((completion-start-at? buffer i) i)
                (else (loop (+ i 1)))))))

    (define (first-completion-start buffer)
      ;; GNU Emacs's `first-completion` (`simple.el:10244`): "Move to the
      ;; first item in the completions buffer." The position that command
      ;; would leave point on, which is where a wrapping `M-<down>` goes.
      ;; The help and heading lines above the first candidate carry no
      ;; `completion--string`, so this is the first index that does.
      ;;--------------------------------------------------------------
      (let loop ((i (buffer-beg buffer)))
        (cond ((>= i (buffer-z buffer)) #f)
              ((completion-start-at? buffer i) i)
              (else (loop (+ i 1))))))

    (define (last-completion-start buffer)
      ;; GNU Emacs's `last-completion` (`simple.el:10260`), for the
      ;; horizontal format: the start of the last candidate in the
      ;; buffer.
      ;;--------------------------------------------------------------
      (let loop ((i (- (buffer-z buffer) 1)))
        (cond ((< i (buffer-beg buffer)) #f)
              ((completion-start-at? buffer i) i)
              (else (loop (- i 1))))))

    (define (completion-previous-cell-start buffer from)
      ;; The last completion cell start before FROM, or #f.
      ;;--------------------------------------------------------------
      (let loop ((i (- from 1)))
        (cond ((< i (buffer-beg buffer)) #f)
              ((completion-start-at? buffer i) i)
              (else (loop (- i 1))))))

    (define (completion--cell-end buffer start)
      ;; One past the last character of the cell START starts: GNU
      ;; Emacs's `completion--move-to-candidate-end', which is where a
      ;; selection face stops on its cell.
      ;;--------------------------------------------------------------
      (let ((last (buffer-z buffer))
            (value (get-text-property start 'completion--string buffer)))
        (let loop ((i (+ start 1)))
          (cond ((>= i last) i)
                ((not (equal? value (get-text-property i 'completion--string
                                                       buffer)))
                 i)
                (else (loop (+ i 1)))))))

    (define (move-completions n)
      ;; Move the `*Completions*' buffer's point N candidates, through
      ;; the cells the layout arranged them in, and mark the one that is
      ;; on. This is GNU Emacs's `next-column-completion` for a
      ;; `horizontal' format: the next cell is the next in the buffer,
      ;; which is the next column of the row and then the first of the
      ;; next.
      ;;
      ;; **The ends wrap.** `completion-auto-wrap` (`simple.el:10169')
      ;; defaults to t, and with it `next-column-completion` goes to
      ;; `first-completion` when there is no next candidate and to
      ;; `last-completion` when there is no previous one - so `M-<down>`
      ;; at the bottom comes back to the top, and the window scrolls up
      ;; to it. This port used to clamp at both ends, on the reading that
      ;; the variable was nil; it is not.
      ;;
      ;; **There is always a window to move in**: GNU Emacs's
      ;; `with-minibuffer-completions-window` (`minibuffer.el:5334`)
      ;; makes one with `minibuffer-completion-help` when none is up.
      ;;
      ;; Point starts on the heading line, above the first candidate, so
      ;; the first move finds the first cell and the moves after it walk
      ;; the cells in display order.
      ;;--------------------------------------------------------------
      (unless (completions-window)
        (minibuffer-completion-help))
      (let ((buffer (get-buffer "*Completions*")))
        (when buffer
          (let loop ((left (abs n)) (step (if (< n 0) -1 1)))
            (if (= left 0)
                #f
                (let ((next (if (< step 0)
                                (completion-previous-cell-start
                                 buffer (buffer-pt buffer))
                                (completion-next-cell-start
                                 buffer (buffer-pt buffer)))))
                  (cond
                   (next
                    (set-point buffer next)
                    (loop (- left 1) step))
                   ((*completion-auto-wrap*)
                    (let ((wrapped (if (< step 0)
                                       (last-completion-start buffer)
                                       (first-completion-start buffer))))
                      (if wrapped
                          (begin (set-point buffer wrapped)
                                 (loop (- left 1) step))
                          (loop 0 step))))
                   (else (loop 0 step))))))
          ;; the window is a view of the buffer, so its point follows
          (let ((window (completions-window)))
            (when window
              (set-window-point! window (buffer-pt buffer))
              ;; **The window follows the selection.** GNU Emacs's
              ;; `with-minibuffer-completions-window` (`minibuffer.el:5334`)
              ;; *selects* the completions window and moves point in it,
              ;; and redisplay then keeps that window's point visible -
              ;; which is why `M-<down>` scrolls once the selection
              ;; reaches the bottom. The window is not selected here, and
              ;; this display scrolls only the selected window
              ;; (`render!`'s `scroll-to-cursor!` call at `xdisp`'s
              ;; selection), so the same decision is made for this one
              ;; directly.
              (scroll-to-cursor! window)))
          (show-completions-selection! buffer))))

    (define (completion--selected-candidate)
      ;; GNU Emacs's `completion--selected-candidate': the candidate the
      ;; completions window's point is on, or #f when there is none - a
      ;; line of the heading or of the help is not one.
      ;;
      ;; Emacs reads the `completion--string' text property the candidate
      ;; was written with, and this reads the same property, which is what
      ;; `display-completion-list' puts on each candidate line.
      ;;--------------------------------------------------------------
      (let ((buffer (and (completions-window) (get-buffer "*Completions*"))))
        (and buffer
             (get-text-property (buffer-pt buffer)
                                'completion--string buffer))))

    (define (minibuffer-choose-completion . args)
      ;; GNU Emacs's `minibuffer-choose-completion': put the candidate
      ;; the completions window's point is on into the minibuffer that
      ;; is being read, without leaving it.
      ;;
      ;; The prefix argument says not to exit the minibuffer
      ;; (NO-EXIT) and not to quit the completions window (NO-QUIT);
      ;; nothing here exits the minibuffer of its own accord, so
      ;; NO-EXIT has nothing to do, and the window is left to the
      ;; minibuffer's own exit.
      ;;--------------------------------------------------------------
      (let ((candidate (completion--selected-candidate)))
        (if (not candidate)
            (error "No completion here")
            (let ((mb (*minibuffer*))
                  (buffer (get-buffer "*Completions*")))
              (when mb
                (choose-completion-string
                 candidate mb
                 (buffer-local-value buffer 'completion-base-position #f)))))))

      ;; GNU Emacs's `minibuffer-next-completion': move through the
      ;; candidates - the next cell of the layout, which for the
      ;; `horizontal' format is the next column and then the first of
      ;; the next row. Emacs also inserts the candidate here when
      ;; `minibuffer-completion-auto-choose' is set; it is nil by
      ;; default and nil here, so the move is all it does and RET is
      ;; what takes the candidate.
      ;;--------------------------------------------------------------
    (define-command (minibuffer-next-completion count)
      "Move to the next item in the completions window."
      (interactive "p")
      (move-completions count))

	
    ;; GNU Emacs's `minibuffer-previous-completion'.
    ;;--------------------------------------------------------------
    (define-command (minibuffer-previous-completion count)
      "Move to the previous item in the completions window."
      (interactive "p")
      (move-completions (- count)))

    ;; GNU Emacs's `minibuffer-completion-exit': insert the selected
    ;; completion if there is one, then leave the minibuffer. It is
    ;; what RET is bound to in a completing minibuffer, and it is why
    ;; moving through the candidates with M-<down> and then pressing
    ;; RET takes the one moved to.
    ;;--------------------------------------------------------------
    (define-command (minibuffer-completion-exit)
      "Accept what has been typed, taking the selected completion first."
      (interactive)
      (when (completion--selected-candidate)
        (minibuffer-choose-completion))
      (exit-recursive-edit #f))

    (define minibuffer-local-filename-completion-map
      ;; GNU Emacs's `minibuffer-local-filename-completion-map', which
      ;; `read-file-name' layers over `minibuffer-local-completion-map'
      ;; when `minibuffer-completing-file-name' is set. Its whole
      ;; purpose is one thing: SPC must not complete a word in a file
      ;; name, because a file name may have a space in it. Emacs writes
      ;; `"SPC" nil', which shadows the completion map's binding and
      ;; falls through to the global self-insert binding - a nil
      ;; binding in a composed keymap overriding its parent, which is
      ;; documented in `make-composed-keymap'.
      ;;
      ;; This keymap machinery's layers fall through on a nil action
      ;; rather than shadowing, so the same result is written as what
      ;; it comes to: SPC runs `self-insert-command'. That is a
      ;; departure in what the map *says* and not in what a key does,
      ;; and it is the honest way to say it while a layer cannot hold
      ;; "bound to nothing".
      ;;--------------------------------------------------------------
      (minibuffer-map-from-bindings '*minibuffer-local-filename-completion-map*
                                    (minibuffer-filename-completion-bindings)))

    (define minibuffer-local-completion-map
      ;; GNU Emacs's `minibuffer-local-completion-map', whose parent is
      ;; `minibuffer-local-map'. TAB completes, SPC completes a word, `?'
      ;; lists the candidates, and RET is `minibuffer-completion-exit' -
      ;; which takes the candidate chosen with M-<down> if there is one
      ;; and otherwise leaves the minibuffer with what is typed.
      ;;
      ;; M-<up> and M-<down> move through the candidates, and M-RET takes
      ;; the one moved to without leaving. These are Emacs's own keys for
      ;; these commands, from `minibuffer-local-completion-map' in
      ;; minibuffer.el.
      ;;
      ;; The map is defined down here, after the commands it names, for
      ;; the reason Emacs keeps its completion maps at the end of
      ;; minibuffer.el too: a keymap is built when it is defined, so every
      ;; command it binds has to exist by then.
      ;;--------------------------------------------------------------
      (let ((map (minibuffer-map-from-bindings
                  '*minibuffer-local-completion-map*
                  (list (cons (kbd "TAB") minibuffer-complete)
                        ;; `"<backtab>" #'minibuffer-complete`
                        ;; (`minibuffer.el:3432`); the repeated-TAB
                        ;; branch above uses it for the reverse scroll.
                        (cons (kbd "<backtab>") minibuffer-complete)
                        (cons (kbd "SPC") minibuffer-complete-word)
                        (cons (kbd "?") minibuffer-completion-help)
                        (cons (kbd "RET") minibuffer-completion-exit)
                        (cons (kbd "M-<up>") minibuffer-previous-completion)
                        (cons (kbd "M-<down>") minibuffer-next-completion)
                        (cons (kbd "M-RET") minibuffer-choose-completion)))))
        ;; The map it completes *from* is the parent, as Emacs's
        ;; `(set-keymap-parent map minibuffer-local-map)' has it.
        (km:set-keymap-parent map minibuffer-local-map)
        map))


    (define minibuffer-local-must-match-map
      ;; GNU Emacs's `minibuffer-local-must-match-map', whose parent is
      ;; `minibuffer-local-completion-map': RET completes and exits rather
      ;; than leaving with whatever is typed, and C-j does the same. RET
      ;; still takes a chosen candidate first, since
      ;; `minibuffer-complete-and-exit' does that itself.
      ;;--------------------------------------------------------------
      (let ((map (minibuffer-map-from-bindings
                  '*minibuffer-local-must-match-map*
                  (list (cons (kbd "RET") minibuffer-complete-and-exit)
                        (cons (kbd "C-j") minibuffer-complete-and-exit)))))
        (km:set-keymap-parent map minibuffer-local-completion-map)
        map))

    ;;----------------------------------------------------------------
    ;; Reading a number
    ;;
    ;; GNU Emacs's `read-number' is `subr.el''s, but it is here: the
    ;; reading it does is this library's, and subr.sld cannot import
    ;; this library (see `read-number-history' above).
    ;;----------------------------------------------------------------

    (define minibuffer-default-prompt-format
      ;; GNU Emacs's `minibuffer-default-prompt-format' (minibuffer.el:5485):
      ;; "Format string used to output "default" values" - the
      ;; "(default 50)" in "Number of articles (default 50): ". It is
      ;; read-number's, below, and any other prompt that names its default.
      ;;--------------------------------------------------------------
      " (default %s)")

    (define (minibuffer-default-clause default)
      ;; `minibuffer-default-prompt-format' with DEFAULT written into it:
      ;; the "(default 50)" of "Number of articles (default 50): ".
      ;;
      ;; Not through `format', for the reason `completions-header-string'
      ;; is not: the format string is Emacs's, and its directive is `%s'
      ;; where Guile's `format' spells one `~a' - it writes the `%s' out
      ;; as itself rather than filling it - so the variable would have to
      ;; be given a Guile spelling to work, and Emacs's docstring offers
      ;; `" [%s]"' as the way a user shortens it. Emacs fills the field
      ;; with whatever `format' prints, so a number comes out as digits.
      ;;--------------------------------------------------------------
      (let* ((format-string minibuffer-default-prompt-format)
             (value (if (pair? default) (car default) default))
             (text (if (string? value) value (format #f "~a" value)))
             (at (string-contains format-string "%s")))
        (if (not at)
            format-string
            (string-append (substring format-string 0 at)
                           text
                           (substring format-string (+ at 2)
                                      (string-length format-string))))))

    (define (format-prompt prompt default)
      ;; GNU Emacs's `format-prompt' (minibuffer.el:5498): "Format PROMPT
      ;; with DEFAULT according to `minibuffer-default-prompt-format'."
      ;;
      ;; Two things about the shape are Emacs's and were both missing
      ;; here. The prompt is closed with ": " whether or not it has a
      ;; default - that colon is what a prompt ends with, and leaving it
      ;; off is what left `M-%' prompting `Query replace' with the typed
      ;; text hard against it. And the default clause goes *before* that
      ;; colon, not after it: "Query replace (default a -> b): ".
      ;;
      ;; A DEFAULT that is an empty string names nothing and gets no
      ;; clause; a list names its first element; anything else names
      ;; itself.
      ;;--------------------------------------------------------------
      (let ((default (if (null? default) #f default)))
        (string-append
         prompt
         (if (and default
                  (or (not (string? default))
                      (> (string-length default) 0)))
             (minibuffer-default-clause default)
             "")
         ": ")))

    (define (read-number prompt . rest)
      ;; GNU Emacs's `read-number' (subr.el:3709): "Read from the
      ;; minibuffer and return a numeric value, prompting with PROMPT."
      ;; DEFAULT - a number, or a list of them, the first being the one
      ;; RET takes - is named in the prompt and answered when the user
      ;; types nothing; HIST is the history list, `read-number-history'
      ;; when not given. The interactive code letter "n" is what uses it.
      ;;
      ;; Not ported: the Emacs Lisp `read' of the typed string, which
      ;; parses a Lisp object and takes only what reads as a number -
      ;; `string->number' answers a number for a number's spelling and
      ;; #f otherwise, which is the same rejection for the strings a
      ;; user actually types.
      ;;
      ;; Not ported: `sit-for' after the "Please enter a number." message
      ;; (a second's pause, so the message is readable). There is no
      ;; sit-for here, and the prompt that follows the message covers the
      ;; echo area, so the message is set and the prompt goes straight
      ;; back up - what the user sees of the rejection is the prompt
      ;; again.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? rest) (car rest) #f))
             (hist (if (and (pair? rest) (pair? (cdr rest)))
                       (cadr rest)
                       read-number-history))
             (default1 (if (pair? default) (car default) default))
             ;; DEFAULT names itself in the prompt: read-number's own
             ;; string-match on "\(():[ \t]*\'" puts the format before
             ;; the final colon, or at the end of a prompt with none.
             (prompt
              (if default1
                  (let* ((with-default
                          (string-append
                           prompt
                           (minibuffer-default-clause default1)))
                         (end (string-length with-default)))
                    (let scan ((i end))
                      (cond
                       ((= i 0)
                        with-default)
                       ((char=? (string-ref with-default (- i 1)) #\space)
                        (scan (- i 1)))
                       ((char=? (string-ref with-default (- i 1)) #\:)
                        (string-append (substring with-default 0 (- i 1))
                                       (minibuffer-default-clause default1)
                                       (substring with-default
                                                  (- i 1) end)))
                       (else
                        with-default))))
                  prompt))
             ;; RET on an empty answer takes the default: the strings the
             ;; minibuffer's default is. Emacs passes every entry of a
             ;; cons DEFAULT and lets M-n cycle them; the reader here
             ;; takes one, so it takes the first.
             ;; Emacs's `(mapcar #'number-to-string (delq nil default))':
             ;; a cons DEFAULT drops its nil entries, so `(list nil N)'
             ;; offers N - `number-at-point' being nil is what puts the
             ;; current line there.
             (minibuffer-default
              (and default
                   (let scan ((rest (if (pair? default)
                                        default
                                        (list default))))
                     (cond ((null? rest) #f)
                           ((car rest) (number->string (car rest)))
                           (else (scan (cdr rest))))))))
        (let loop ()
          (let ((n (string->number
                    (read-from-minibuffer prompt #f #f hist minibuffer-default))))
            (if (number? n)
                n
                (begin
                  (set!frame-message (*current-frame*) "Please enter a number.")
                  (loop)))))))

    ;;----------------------------------------------------------------
    ;; Goto line
    ;;
    ;; GNU Emacs's `goto-line' and `goto-line-read-args' are `simple.el''s,
    ;; and they are here and not in simple.sld because they prompt:
    ;; simple.sld is *below* this library in the import graph - this
    ;; library imports simple.sld for `self-insert-command', and the
    ;; command loop imports both - so a command that reads the minibuffer
    ;; cannot live there. That is the same wall `yank-from-kill-ring'
    ;; waits behind (simple.sld says so at its `yank-pop'), and the
    ;; reason `read-number' is here too.
    ;;----------------------------------------------------------------

    (define goto-line-history (make<history> '()))
    ;; ^ GNU Emacs's `goto-line-history' (simple.el), the history the
    ;; line prompt shares, beside `read-number-history' above.

    (define (goto-line-read-args . rest)
      ;; GNU Emacs's `goto-line-read-args' (simple.el:1615): read the
      ;; arguments of `goto-line' and its relatives. A numeric prefix
      ;; argument IS the line, and nothing is read; otherwise the line
      ;; is read from the minibuffer, the number at point offered as
      ;; the default - `number-at-point' is not here, so the default
      ;; is the line point is on, which is the default Emacs offers
      ;; when there is no number under point - and the buffer read for
      ;; a cons prefix (`C-u') is not read: `goto-line''s other-buffer
      ;; switch waits for the buffer-switching its prompt needs.
      ;;--------------------------------------------------------------
      (let ((relative (if (pair? rest) (car rest) #f)))
        (if (and (current-prefix-arg)
                 (not (pair? (current-prefix-arg))))
            (let ((n (uarg->integer 1 (current-prefix-arg))))
              ;; the buffer read for a cons prefix is #f here - see the
              ;; note above - so the answer is the line and no buffer
              (list n #f))
            ;; The prompt is built with `format' and not `format-prompt',
            ;; which is what GNU Emacs does here and says why in
            ;; `read-number''s docstring: "the value of DEFAULT is always
            ;; inserted into PROMPT, so it's recommended to use `format'
            ;; instead of `format-prompt'". Naming the default here as
            ;; well names it twice. Emacs's own spec is "Goto%s line%s: ",
            ;; whose two `%s's are the narrowing note and the buffer being
            ;; switched to - this tree reads neither, so it is a literal.
            (list (read-number "Goto line: "
                               (list #f (line-number-at-pos))
                               goto-line-history)
                  #f))))

    (define-command (goto-line line buffer relative interactive)
      ;; GNU Emacs's `goto-line' (simple.el:1649): "Go to LINE, counting
      ;; from line 1 at beginning of buffer." Interactively the line is
      ;; the numeric prefix argument, or what the minibuffer read; the
      ;; mark is left where point was, unless the region is active -
      ;; Emacs's `(or (region-active-p) (push-mark))' - and point goes
      ;; to the start of that line.
      ;;
      ;; The move is Emacs's `(goto-char (point-min)) (forward-line
      ;; (1- line))' done with the engine's line-addressed cursor: line
      ;; LINE-1, column 0 - and `forward-line''s end-of-buffer case,
      ;; which stops at `point-max' when LINE is past the end, is the
      ;; cursor going to the end of the buffer instead of the start of
      ;; the last line, which is where the engine's clamp stays.
      ;;
      ;; The narrowing half is ported now that narrowing exists - the
      ;; move runs in a widened buffer and `widen-automatically` decides
      ;; whether the widening is kept - see the body. Not ported:
      ;; `selective-display', and the buffer switch the cons prefix asks
      ;; for.
      ;;--------------------------------------------------------------
      "Go to LINE, counting from line 1 at beginning of buffer."
      (interactive (append (goto-line-read-args) (list #f #t)))
      ;; Switch to the desired buffer, one way or another.
      (when interactive
        (when buffer
          (let ((window (get-buffer-window buffer)))
            (if window (select-window window)
                (switch-to-buffer-other-window buffer))))
        ;; Leave mark at previous position
        (or (region-active-p) (push-mark)))
      ;; Move to the specified line number in that buffer - the C's own
      ;; move, which this function's docstring already named:
      ;;
      ;;     (goto-char (point-min))
      ;;     (forward-line (1- line))
      ;;
      ;; **It used to be the engine's line-addressed cursor**
      ;; (`(text-editor-set-cursor ed line 0)`, an invented two-argument
      ;; form with no Emacs counterpart), plus a hand-written guard that
      ;; put point at `point-max' when the line ran off the end and a
      ;; clamp that held the line at or above 1. `forward-line` answers
      ;; both by itself: a count past the end stops at `point-max`, and a
      ;; negative one at `point-min` cannot go back past the beginning.
      ;; So the guard and the clamp both go, and what is left is exactly
      ;; what Emacs runs.
      ;;
      ;; **The restriction**, as the C's two steps: the move is made in
      ;; a *widened* buffer, and the widening is undone on the way out
      ;; unless `widen-automatically' says the caller may keep it - in
      ;; which case a position outside what was visible widens for good.
      ;;
      ;;     (let ((pos (save-restriction
      ;;                  (unless relative (widen))
      ;;                  (goto-char (point-min)) (forward-line (1- line))
      ;;                  (point))))
      ;;       (when (and (not relative) (buffer-narrowed-p)
      ;;                  widen-automatically
      ;;                  (or (> (point-min) pos) (> pos (point-max))))
      ;;         (widen))
      ;;       (goto-char pos))
      ;;--------------------------------------------------------------
      (with-current-buffer (current-buffer)
        (let ((pos (save-restriction
                     (unless relative (widen))
                     (goto-char (point-min))
                     (forward-line (- line 1))
                     (point))))
          (when (and (not relative)
                     (buffer-narrowed-p)
                     widen-automatically
                     (or (> (point-min) pos) (> pos (point-max))))
            (widen))
          (goto-char pos))))

    (define-command (goto-line-relative line buffer interactive)
      ;; GNU Emacs's `goto-line-relative' (`simple.el:1703'): "Go to LINE,
      ;; counting from line at (point-min). The line number is relative to
      ;; the accessible portion of the narrowed buffer."
      ;;
      ;; `(interactive (append (goto-line-read-args t) '(t)))' - the
      ;; reading is *relative* (so the prompt offers the line inside the
      ;; narrowing) and the appended `t` is INTERACTIVE. The move is
      ;; `goto-line`'s with RELATIVE t, which is what skips the widening.
      ;;--------------------------------------------------------------
      "Go to LINE, counting from line at (point-min).
The line number is relative to the accessible portion of the narrowed
buffer.  The arguments BUFFER and INTERACTIVE are the same as in the
function `goto-line'."
      (interactive (append (goto-line-read-args #t) (list #t)))
      (goto-line line buffer #t interactive))

    ;; The keys GNU Emacs binds it to (M-g g, and M-g M-g, which is the
    ;; same command), beside the command as the other libraries state
    ;; theirs.
    (define-key *default-keymap* (kbd "M-g g") goto-line)
    (define-key *default-keymap* (kbd "M-g M-g")
      goto-line)

    ;; `narrow-map`'s `g` (`bindings.el:1214`), flat - see the note on
    ;; `narrow-map` in `editfns.scm` - and in the map itself, which Emacs
    ;; has it in.
    (define-key *default-keymap* (kbd "C-x n g") goto-line-relative)
    (define-key narrow-map (kbd "g") goto-line-relative)

    ;;----------------------------------------------------------------
    ;; Zap to char - simple.el:6739, and here for the same reason as
    ;; `goto-line': the character it reads is a minibuffer read, and
    ;; simple.sld is below this library in the import graph.
    ;;----------------------------------------------------------------

    (define-command (zap-to-char arg char interactive)
      ;; GNU Emacs's `zap-to-char' (simple.el:6739): "Kill up to and
      ;; including ARGth occurrence of CHAR. Case is ignored if
      ;; `case-fold-search' is non-nil in the current buffer. Goes
      ;; backward if ARG is negative; error if CHAR not found." The
      ;; character is read, with `Zap to char: ' as the prompt.
      ;;
      ;; The fold rule is Emacs's own: an interactively-given
      ;; UPPER-case character searches case-sensitively whatever
      ;; `case-fold-search' says. The `translation-table-for-input'
      ;; branch of the original is not ported - there is no
      ;; input-method translation here. Not ported with it:
      ;; `zap-up-to-char', which stops before the character.
      ;;--------------------------------------------------------------
      "Kill up to and including ARGth occurrence of CHAR."
      (interactive (list (uarg->integer 1 (current-prefix-arg))
                         (read-char-from-minibuffer "Zap to char: ")
                         #t))
      (let ((fold (if (and interactive (char-upper-case? char))
                      #f
                      (*case-fold-search*))))
        (if (< arg 0)
            (kill-region (point)
                         (search-backward (string char) #f #f (- arg) fold))
            (kill-region (point)
                         (search-forward (string char) #f #f arg fold)))))

(define-command (set-fill-column arg)
      ;; GNU Emacs's `set-fill-column' (simple.el:9255): "Set
      ;; `fill-column' to specified argument. Use
      ;; \\[universal-argument] followed by a number to specify a
      ;; column. Just \\[universal-argument] as argument means to use
      ;; the current column." A bare C-u is the list `(4)' and a bare
      ;; M-- the symbol `-', so a NUMBER means C-u N; the cons is a
      ;; bare C-u; nothing typed at all asks for the number, which the
      ;; 2018 change to this command made of it - and which is why the
      ;; command is here and not in simple.sld: it prompts, and
      ;; simple.sld is below this library (the same wall `goto-line'
      ;; documents above).
      "Set `fill-column' to specified argument.
Use \\[universal-argument] followed by a number to specify a column.
Just \\[universal-argument] as argument means to use the current column."
      (interactive
       (list (or (current-prefix-arg)
                 (read-number
                  ;; Guile's `format' takes `~a', not Emacs's `%s' - a
                  ;; literal `%s' printed itself in the prompt.
                  (format #f "Change fill-column from ~a to: "
                          (buffer-fill-column (current-buffer)))
                  (current-column)))))
      (let ((n (cond
                ((pair? arg) (current-column))
                ((integer? arg) arg)
                (else #f))))
        (if (not (integer? n))
            ;; Disallow missing argument; it's probably a typo for C-x C-f.
            (error "set-fill-column requires an explicit argument")
            (let ((was (buffer-fill-column (current-buffer))))
              (set!buffer-fill-column (current-buffer) n)
              (set!frame-message
               (*current-frame*)
               (format #f "Fill column set to ~a (was ~a)" n was)))))
      #f)
    (define-key *default-keymap* (kbd "C-x f") set-fill-column)

    (define-key *default-keymap* (kbd "M-z") zap-to-char)

    ;;------------------------------------------------------------------
    ;; eval-expression - `simple.el:2140'
    ;;------------------------------------------------------------------
    ;;
    ;; **The evaluator is Scheme's, and that is the one departure.** GNU
    ;; Emacs's `eval-expression' evaluates Emacs Lisp: `(eval (let
    ;; ((lexical-binding t)) (macroexpand-all exp)) t)' (`simple.el:2172').
    ;; This editor is a Scheme program, so the expression the minibuffer
    ;; reads is a Scheme one and `(scheme eval)''s `eval' is what runs it.
    ;; Everything else is Emacs's: the `Eval: ' prompt, the result in the
    ;; echo area, `eval-expression-print-format''s octal/hex/character
    ;; suffix for an integer, and a `*Backtrace*' buffer when it raises.

    (define *eval-expression-print-maximum-character* (make-parameter 127))
    ;; ^ GNU Emacs's `eval-expression-print-maximum-character'
    ;; (`simple.el:2034'): "The largest integer that will be displayed as
    ;; a character." 127 by default.

    (define *eval-expression-debug-on-error* (make-parameter #t))
    ;; ^ `eval-expression-debug-on-error' (`simple.el:2027'): "If non-nil
    ;; set `debug-on-error' to t in `eval-expression'." On by default,
    ;; which is why an error puts up a backtrace.

    (define read-expression-history (make<history> '()))
    ;; ^ GNU Emacs's `read-expression-history' (`simple.el'), the
    ;; minibuffer history `read--expression' reads into - a
    ;; `make<history>' like `goto-line-history' beside it, because that
    ;; is what `read-from-minibuffer''s HISTORY argument is here.
    (define (%prin1-char code)
      ;; GNU Emacs's `prin1-char': CODE as the character syntax `?a' or
      ;; `?\C-a', or #f when it is not one to write that way.
      ;;
      ;; Measured on Emacs 31.1: 97 is `?a', 1 is `?\C-a', 9 is
      ;; `?\C-i' - *not* `?\TAB', so this is not
      ;; `single-key-description''s table - 27 is `?\C-[', 32 is `? '
      ;; with the space, and 127 is `?\C-?'. The letter is the control
      ;; character's caret spelling: `c + 96' for the letters, `c + 64'
      ;; for `@' and the punctuation, and `?' for DEL.
      ;;--------------------------------------------------------------
      (let ((c (integer->char code)))
        (cond
         ((and (> code 31) (< code 127)) (string #\? c))
         ((or (< code 32) (= code 127))
          (string #\? #\\ #\C #\-
                  (integer->char (cond ((and (> code 0) (<= code 26))
                                        (+ code 96))
                                       ((= code 127) 63)
                                       (else (+ code 64))))))
         (else #f))))

    (define (eval-expression-print-format value)
      ;; GNU Emacs's `eval-expression-print-format' (`simple.el:2044'):
      ;; "If VALUE is an integer, return a specially formatted string.
      ;; This string will typically look like \" (#o1, #x1, ?\\C-a)\".
      ;; If VALUE is not an integer, return nil."
      ;;
      ;; The character part is there only when the value is at most
      ;; `eval-expression-print-maximum-character' and has a character
      ;; spelling. Emacs gates it on `char-displayable-p' as well; every
      ;; code point this editor draws is displayable, so that test has
      ;; nothing to say here.
      ;;--------------------------------------------------------------
      (if (not (exact-integer? value))
          #f
          (let ((char-string
                 (and (>= value 0)
                      (<= value (*eval-expression-print-maximum-character*))
                      (%prin1-char value))))
            (if char-string
                (format #f " (#o~a, #x~a, ~a)"
                        (number->string value 8)
                        (number->string value 16)
                        char-string)
                (format #f " (#o~a, #x~a)"
                        (number->string value 8)
                        (number->string value 16))))))

    (define (%eval-expression-environment)
      ;; Where the typed expression is evaluated: **the user environment**
      ;; - `$XDG_CONFIG_HOME/imports.scm' when there is one, the whole
      ;; editor when there is not (`open-user-environment!'), which is the
      ;; same module the init file is loaded into and the back door's
      ;; session is pinned to.
      ;;
      ;; GNU Emacs evaluates a typed expression against its one obarray,
      ;; where every name in Emacs is bound. This is this tree's stand-in
      ;; for that, and it is deliberately *not* `(current-module)', which
      ;; was the first answer here: the module that is current when the
      ;; command runs is the command's *defining* library while the
      ;; command's own minibuffer prompt is being read (`eval' binds it
      ;; for the whole of the interactive spec's evaluation), so the same
      ;; expression was evaluated in a different module depending on
      ;; whether it was typed at a prompt or read by the back door - and
      ;; in a library, which has no `import' to offer.
      ;;
      ;; `(interaction-environment)' is *not* it either: under `--r7rs'
      ;; that is a minimal environment with no `+' in it at all, which is
      ;; how the first version of this answered "Unbound variable: +".
      ;;--------------------------------------------------------------
      (open-user-environment!))

    (define (eval-expression-get-print-arguments prefix-argument)
      ;; GNU Emacs's `eval-expression-get-print-arguments'
      ;; (`simple.el'): "Get arguments for commands that print an
      ;; expression result. Returns a list (INSERT-VALUE NO-TRUNCATE
      ;; CHAR-PRINT-LIMIT) based on PREFIX-ARGUMENT."
      ;;--------------------------------------------------------------
      (let ((num (uarg->integer 1 prefix-argument)))
        (list (not (memv prefix-argument (list '- #f)))
              (= num 0)
              (cond ((not (memv prefix-argument (list 0 -1 '- #f))) #f)
                    ((= num -1) 2305843009213693951)  ; most-positive-fixnum
                    (else (*eval-expression-print-maximum-character*))))))

    (define (%eval-expression-value->string value)
      (call-with-port (open-output-string)
        (lambda (port) (write value port) (get-output-string port))))

    (define (%condition-message condition)
      ;; The error's own words, for the `*Backtrace*' header. Guile's
      ;; `error-object-message' is the R7RS accessor, and for most of its
      ;; conditions it answers a *format template* - `"Unbound variable:
      ;; ~S"' - with the thing itself in `error-object-irritants'. So the
      ;; two are put back together, which is what `message' does for the
      ;; same condition when it is printed to the terminal.
      ;;
      ;; Anything that is not an error object is written out instead,
      ;; which is what a raised non-error looks like.
      ;;--------------------------------------------------------------
      (cond
       ((error-object? condition)
        (let ((template (error-object-message condition))
              (irritants (error-object-irritants condition)))
          (if (or (not (string? template))
                  (not (pair? irritants))
                  (not (string-contains template "~")))
              template
              (guard (e (#t template))
                (apply format #f
                       (%guile-format-template template)
                       irritants)))))
       (else (%eval-expression-value->string condition))))

    (define (%guile-format-template template)
      ;; Guile writes its condition messages with the *uppercase* format
      ;; directives - `~S' for `write', `~A' for `display' - and its own
      ;; `format' takes the lower-case ones. A template with any other
      ;; directive is left alone for the caller's `guard'.
      ;;--------------------------------------------------------------
      (list->string
       (let loop ((cs (string->list template)) (out '()))
         (cond
          ((null? cs) (reverse out))
          ((and (char=? (car cs) #\~) (pair? (cdr cs))
                (memv (cadr cs) '(#\S #\A)))
           (loop (cddr cs)
                 (cons (char-downcase (cadr cs)) (cons #\~ out))))
          (else (loop (cdr cs) (cons (car cs) out)))))))

    (define (%eval-expression-backtrace condition stack)
      ;; GNU Emacs's `*Backtrace*' (`debug.el:212'): the buffer is
      ;; `*Backtrace*', and `debugger--insert-header''s `error' case
      ;; (`:412') is
      ;;
      ;;     Debugger entered--Lisp error: <the error>
      ;;
      ;; followed by the frames. The frames are the *runtime's* - Emacs
      ;; asks its own backtrace machinery, and this asks Guile's
      ;; `make-stack', which is why the port is possible at all: the
      ;; debugger does not invent them.
      ;;
      ;; One word differs, and it is the departure above showing through:
      ;; Emacs says "Lisp error" because its evaluator is Lisp.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create "*Backtrace*"))
            (frames (call-with-port (open-output-string)
                      (lambda (port)
                        (if stack
                            (display-backtrace stack port)
                            (display "no stack captured\n" port))
                        (get-output-string port)))))
        (with-current-buffer buffer
          (erase-buffer)
          (insert "Debugger entered--Scheme error: ")
          (insert (%condition-message condition))
          (insert "\n")
          (insert frames)
          ;; The mode, which is what makes the buffer what it is: GNU
          ;; Emacs's `debugger-mode' (`debug.el:624') derives from
          ;; `backtrace-mode' (`backtrace.el:830') derives from
          ;; `special-mode' (`simple.el:589'), and `special-mode' is what
          ;; sets `buffer-read-only' and gives the buffer its map.
          (special-mode)
          (set!mode-name "Debugger")
          (use-local-map debugger-mode-map)
          ;; "Place point on \"stack frame 0\"" (`debug.el:372'):
          ;;
          ;;     (goto-char (point-min))
          ;;     (search-forward ":" (line-end-position) t)
          ;;     (when (and (< (point) (line-end-position))
          ;;                (= (char-after) ?\s))
          ;;       (forward-char))
          ;;
          ;; The header's line, which is what makes the buffer open showing
          ;; *why* it is there rather than its last frame - the backtrace
          ;; is longer than the window, and point left at the end of the
          ;; insertion would have shown the bottom of it.
          (goto-char (buffer-beg buffer))
          (search-forward ":" (line-end-position) #t)
          ;; `(char-after)' defaults to point in Emacs; this tree's takes
          ;; the position it is asked about, so point is passed.
          (when (and (< (point) (line-end-position))
                     (let ((c (char-after (point))))
                       (and c (char=? c #\space))))
            ;; `(forward-char)' with no argument, which is Emacs's own
            ;; call and its `(&optional N)' default of 1 - see the note
            ;; on `move_point' in `cmds.sld' for what that cost.
            (forward-char)))
        ;; `pop-to-buffer' and not `display-buffer'. Emacs shows the
        ;; debugger's buffer *and selects its window* (`debug.el:270'),
        ;; which is why a backtrace has the focus the moment it appears;
        ;; `display-buffer' shows it in some other window and leaves point
        ;; where it was, so the buffer is on screen and the keyboard is not
        ;; talking to it.
        (pop-to-buffer buffer)))

    (define (%eval-expression-run exp)
      ;; Evaluate EXP, and on an error fill and show `*Backtrace*' - GNU
      ;; Emacs's `handler-bind ((error #'eval-expression--debug))'
      ;; (`simple.el:2177'), whose default `debugger' is `debug'.
      ;;
      ;; The stack is taken *before* the unwinding, and that is the whole
      ;; trick: `with-exception-handler' calls its handler on the raising
      ;; stack, which is where `make-stack' can still see the frames, and
      ;; the continuation escapes with the condition so the header can
      ;; name it. A `guard' would have unwound first and had no frames to
      ;; show.
      ;;--------------------------------------------------------------
      (let ((stack #f)
            (failed #f))
        (let ((value (call/cc
                      (lambda (escape)
                        (with-exception-handler
                         (lambda (e)
                           (set! stack (make-stack #t))
                           (set! failed #t)
                           (escape e))
                         (lambda () (eval exp (%eval-expression-environment))))))))
          (if failed
              (begin (%eval-expression-backtrace value stack) #f)
              value))))

    (define-command (debugger-quit)
      ;; GNU Emacs's `debugger-quit' (`debug.el:773'): "Quit debugging and
      ;; return to the top level." Emacs's body is
      ;;
      ;;     (if (= (recursion-depth) 0) (quit-window) (top-level))
      ;;
      ;; and there is no recursive edit to return from here, so it is
      ;; `quit-window' - which is also what `special-mode-map''s own `q'
      ;; would do, this binding being the debugger's refinement of it.
      "Quit debugging and return to the top level."
      (interactive)
      (quit-window))

    (define debugger-mode-map
      ;; GNU Emacs's `debugger-mode-map' (`debug.el:574'). Of its keys only
      ;; `q' is carried: `c', `d', `j', `r' and `u' are the stepper's, and
      ;; there is no debugger here to step - the port fills the buffer and
      ;; hands the keyboard back.
      ;;
      ;; Its parent is `special-mode-map', as Emacs's is, so the buffer
      ;; gets `q' from here and whatever else the mode binds.
      ;;--------------------------------------------------------------
      (let ((map (minibuffer-map-from-bindings
                  '*debugger-mode-map*
                  (list (cons (kbd "q") debugger-quit)))))
        (km:set-keymap-parent map special-mode-map)
        map))

    (define-command (read--expression-try-read)
      ;; GNU Emacs's `read--expression-try-read' (`simple.el:2083'): "Try
      ;; to read an Emacs Lisp expression in the minibuffer. Exit the
      ;; minibuffer if successful, else report the error to the user and
      ;; move point to the location of the error."
      ;;
      ;; **This is why a malformed expression cannot reach the backtrace
      ;; buffer**, and it is the piece whose absence made M-: look like it
      ;; never made one: RET bound to this reads the text *while the
      ;; minibuffer is still open*, so a bad expression is reported at the
      ;; prompt and the minibuffer stays up. Without it RET exits, the
      ;; read happens afterwards, and the read error - which is not
      ;; `eval-expression''s, and so is not the debugger's either - comes
      ;; out as a bare error in the echo area.
      ;;
      ;; Not carried: moving point to the error. Emacs has the reader's
      ;; own point, because it reads in a temp buffer it can ask;
      ;; `(scheme read)' over a string port reports the position in its
      ;; message and nowhere else.
      "Try to read a Scheme expression in the minibuffer.
Exit the minibuffer if successful, else report the error to the user."
      (interactive)
      (let ((contents (minibuffer-contents)))
        (if (guard (e (#t (minibuffer-message (%condition-message e)) #f))
              (read (open-input-string contents))
              #t)
            (exit-minibuffer))))

    (define read--expression-map
      ;; GNU Emacs's `read--expression-map': the minibuffer's own map with
      ;; RET bound to `read--expression-try-read'.
      ;;
      ;; Emacs gets there with `(set-keymap-parent read--expression-map
      ;; minibuffer-local-map)'. The entries are *copied* here instead,
      ;; because this tree's lookup does not follow a keymap's parent: it
      ;; searches a map's own layers and then the next map in
      ;; `lookup-keymaps'' list, and a parent is neither - which is why
      ;; the first version of this had no M-p and answered "; undefined
      ;; key: (meta #\p)". Copying is also what the map means:
      ;; `read-from-minibuffer' *replaces* `minibuffer-local-map', so
      ;; whatever the expression prompt does not carry it loses.
      ;;--------------------------------------------------------------
      (minibuffer-map-from-bindings
       '*read--expression-map*
       (cons (cons (kbd "RET") read--expression-try-read)
             (minibuffer-local-bindings))))

    (define (read-command prompt . args)
      ;; GNU Emacs's `read-command' (`minibuf.c:1457'): "Read the name of
      ;; a command and return it as a symbol. Prompt with PROMPT. By
      ;; default, return DEFAULT-VALUE or its first element if it is a
      ;; list."
      ;;
      ;; The C is `Fcompleting_read (prompt, Vobarray, Qcommandp, Qt,
      ;; ...)' and then `Fintern'. The command obarray here is
      ;; `command-completion-table', whose entries are all commands
      ;; already - so the `commandp' predicate has nothing left to
      ;; reject.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) #f))
             (default-string (cond ((not default) #f)
                                   ((symbol? default) (symbol->string default))
                                   (else default)))
             (name (completing-read prompt command-completion-table
                                    #f #t #f #f default-string)))
        (and name (not (string=? name "")) (string->symbol name))))

    (define (read-variable prompt . args)
      ;; GNU Emacs's `read-variable' (`minibuf.c:1496'): "Read the name
      ;; of a user option and return it as a symbol."
      ;;
      ;; The C completes over `Vobarray' with `custom-variable-p' as the
      ;; predicate. **There is no obarray here**, so the collection is
      ;; `custom-variable-names` - the list `custom-declare-variable`
      ;; records as it runs - and the predicate filters it the way the C's
      ;; does.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) #f))
             (default-string (cond ((not default) #f)
                                   ((symbol? default) (symbol->string default))
                                   (else default)))
             (name (completing-read prompt custom-variable-names
                                    custom-variable-p #t #f
                                    custom-variable-history default-string)))
        (and name (not (string=? name "")) (string->symbol name))))

    (define (read-minibuffer prompt . args)
      ;; GNU Emacs's `read-minibuffer' (`simple.el`): "Return a Lisp
      ;; object read using the minibuffer, unevaluated. Prompt with
      ;; PROMPT."
      ;;
      ;; The C is `read-from-minibuffer (prompt, initial-contents,
      ;; minibuffer-local-map, t, minibuffer-history)' where the fourth
      ;; argument says "read it for me". **That READ argument is not
      ;; carried here**, so the string is read afterwards on a string
      ;; port - with Scheme's reader, which is the departure
      ;; `eval-expression' already carries.
      ;;--------------------------------------------------------------
      (let* ((text (read-from-minibuffer
                    prompt (if (pair? args) (car args) #f)
                    minibuffer-local-map #f 'minibuffer-history))
             (port (open-input-string text)))
        (let ((form (read port)))
          (unless (eof-object? (read port))
            (error "Trailing garbage following expression"))
          form)))

    (define (eval-minibuffer prompt . args)
      ;; GNU Emacs's `eval-minibuffer' (`simple.el:1999'): "Return value
      ;; of Lisp expression read using the minibuffer." The C's body is
      ;; `(eval (read--expression prompt initial-contents))', and the
      ;; environment is `eval-expression`'s - the user environment, which
      ;; is where the names a user types are bound.
      ;;--------------------------------------------------------------
      (eval (read--expression prompt) (%eval-expression-environment)))

    (define (read--expression prompt)
      ;; GNU Emacs's `read--expression' (`simple.el:2063'): "Read an Emacs
      ;; Lisp expression from the minibuffer."
      ;;
      ;; Emacs's `minibuffer-with-setup-hook' puts `emacs-lisp-mode-syntax-
      ;; table' and `elisp-completion-at-point' on the minibuffer; there is
      ;; no elisp mode here, and the expression is a Scheme one. What is
      ;; carried is the read itself: PROMPT and `read-expression-history'.
      ;; `read--expression-map', which binds RET to
      ;; `read--expression-try-read' so a bad expression is caught in the
      ;; minibuffer, is not - the tree's minibuffer map has no RET
      ;; override, so RET exits as usual and the read happens after.
      ;;--------------------------------------------------------------
      (let* ((text (read-from-minibuffer prompt #f read--expression-map
                                         read-expression-history))
             (port (open-input-string text)))
        (let ((form (read port)))
          ;; "Since `read' does not signal the "Trailing garbage following
          ;; expression" error, we check for trailing garbage ourselves."
          (let loop ()
            (let ((c (peek-char port)))
              (cond
               ((eof-object? c) form)
               ((char-whitespace? c) (read-char port) (loop))
               (else (error "Trailing garbage following expression"))))))))

    (define-command (eval-expression exp)
      "Evaluate EXP and print value in the echo area.
When called interactively, read a Scheme expression and evaluate it.

The expression is Scheme: this editor has no Lisp evaluator under it,
where GNU Emacs's `eval-expression' evaluates Emacs Lisp. Everything
else is Emacs's - the `Eval: ' prompt, the result echoed, and a
`*Backtrace*' buffer when the expression raises."
      (interactive (list (read--expression "Eval: ")))
      (let ((result (%eval-expression-run exp)))
        (when result
          (let ((suffix (eval-expression-print-format result)))
            (message "%s%s"
                     (%eval-expression-value->string result)
                     (if suffix suffix ""))))))

    ;; GNU Emacs's `(define-key global-map (kbd "M-:") 'eval-expression)'
    ;; (`simple.el:2198' region; `(where-is-internal 'eval-expression)'
    ;; answers `M-:').
    (define-key *default-keymap* (kbd "M-:") eval-expression)

    (*read-string-function* read-string)
    (*read-number-function* read-number)
    (*read-command-function* read-command)
    (*read-minibuffer-function* read-minibuffer)
    (*eval-minibuffer-function* eval-minibuffer)
    (*read-variable-function* read-variable)
    (*interactive-read-function-name-function*
     (lambda (prompt)
       ;; `a' (`callint.c:461'): "Symbol defined as a function". The C
       ;; completes over `Vobarray` with `Qfboundp`; **there is no
       ;; obarray here**, so the name is typed rather than completed, and
       ;; the predicate becomes a *resolution* - the name must exist in
       ;; the user environment and be a procedure. `symbol-function` on an
       ;; unbound name is an error in Emacs, so a guard is the right
       ;; shape, not a nil test.
       ;;
       ;; Two departures, both reachable only from an `a' spec - of which
       ;; Emacs has 5 in all of `lisp/`: no completion, and a name that
       ;; resolves to a non-procedure is an error rather than simply not
       ;; offered.
       (let* ((name (read-string prompt))
              (symbol (and name (not (string=? name ""))
                           (string->symbol name))))
         (unless symbol
           (error "No function name given"))
         (let ((value (eval symbol (%eval-expression-environment))))
           (unless (procedure? value)
             (error "%s is not a function" name))
           symbol))))
    ;; ^ The `C', `x' and `X' interactive codes' readers (`callint.c:495',
    ;; `:699', `:704'). All three are this library's, defined above, and
    ;; all three prompt - which is why they are here rather than in
    ;; `simple.scm`, where `read-minibuffer' and `eval-minibuffer` live in
    ;; Emacs.
    (*interactive-read-existing-buffer-function*
     (lambda (prompt)
       ;; `b' (`callint.c:468'): `Fcurrent_buffer ()', replaced by
       ;; `Fother_buffer' when `BASE_EQ (selected_window,
       ;; minibuf_window)' - and then `Fread_buffer (prompt, DEFAULT,
       ;; Qt, Qnil)', so MUSTMATCH is `t' and a name that is not a
       ;; buffer is refused.
       (let ((default (if (eq? (selected-window)
                               (frame-minibuffer-window (*current-frame*)))
                          (other-buffer (current-buffer))
                          (current-buffer))))
         (read-buffer prompt default #t))))
    (*interactive-read-buffer-function*
     (lambda (prompt)
       ;; `B' (`callint.c:475'): `Fread_buffer (prompt, Fother_buffer
       ;; (Fcurrent_buffer (), Qnil, Qnil), Qnil, Qnil)' - MUSTMATCH
       ;; nil, so a name that names nothing yet is accepted.
       (read-buffer prompt (other-buffer (current-buffer)) #f)))
    ;; ^ The `s'/`S'/`M' and `n'/`N' interactive codes' readers
    ;; (`callint.c:681', `:687', `:630', `:640'). `command.scm` is below
    ;; this library - everything here defines commands - so the two
    ;; arrive as seams, as `*barf-if-buffer-read-only-function*` does
    ;; from `keyboard.scm`. `read-string` is `minibuf.c`'s and
    ;; `read-number` is `subr.el`'s; both are the library's own,
    ;; defined above.

        (*minibuffer-selected-window-function* minibuffer-selected-window)
    ;; ^ `redisplay--update-region-highlight` (`simple.el:7332`) keeps a
    ;; prompt's region visible in the window the prompt was entered from:
    ;; that is `(window-minibuffer-p)` with no argument plus this
    ;; function, and `simple.scm` is below this library. Installed here,
    ;; after the definition, because a seam names a procedure and the
    ;; procedure has to exist when the form runs.

    ))
