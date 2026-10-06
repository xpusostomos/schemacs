(define-library (schemacs editor minibuffer)
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
  ;; `(schemacs editor keyboard)' - for the recursive edit - and why it can
  ;; be a leaf now that the command loop is a library of its own.
  ;;
  ;; The prompt is kept beside the buffer rather than in it: Emacs puts it
  ;; in the buffer as the `minibuffer-prompt' text property, and this editor
  ;; has no text properties wired to the display yet. What the display reads
  ;; is the frame's echo area (`*echo-area-buffer*', `*echo-area-prompt*'),
  ;; which is where Emacs keeps the same two facts.
  ;;
  ;; Two definitions that sit under the Completion banner above are *not*
  ;; here, because they are files.el's and ask about saving:
  ;; `save-answer-char->decision' and `save-some-buffers'. They go to
  ;; `(schemacs editor files)' with the file-visiting commands, which are
  ;; still in the frontend.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    (scheme char)
    ;; `read-from-minibuffer' takes an optional keymap, history and default,
    ;; which is a `case-lambda'.
    (scheme case-lambda)
    (prefix (schemacs keymap) km:)
    ;; `string-prefix?' is Guile's, not R7RS's: completion is written with
    ;; it, and leaving it out reports as an unbound variable the first time
    ;; a completion is tried.
    (only (guile) string-contains string-prefix?)
    ;; `format' fills in a message's arguments, as GNU Emacs's
    ;; `format-message' does for `minibuffer-message'.
    (only (guile) format)
    (only (schemacs editor command)
          current-prefix-arg define-command run-command uarg->integer
          *command-table* command-value-of command-interactive-spec)
    (only (schemacs editor engine)
          new-text-editor text-editor-char-count text-editor-point-min text-editor-copy-string
          text-editor-point-min text-editor-point-max
          text-editor-cursor-column text-editor-cursor-line
          text-editor-delete-from-cursor text-editor-get-cursor
          text-editor-insert text-editor-line-count text-editor-set-cursor
          text-editor-set-read-only! text-editor-to-string
          text-editor-undo-disable!)
    ;; `logior' is Guile's: the bitset is three bit flags.
    (only (guile) logior)
    ;; The `*Completions*' buffer is filled with the `face' text property
    ;; and shown in a window. (`keymap' above is `(schemacs keymap)''s,
    ;; which the completion map is built with - this library's `km:' names
    ;; are the keymap library's, not this one's.)
    (only (schemacs editor textprop)
          get-text-property put-text-property remove-text-properties)
    (only (schemacs editor buffer)
          *case-fold-search*
          *current-buffer*
          buffer-default-directory bury-buffer current-buffer get-buffer
          get-buffer-create record-buffer!
          buffer-fill-column set!buffer-fill-column
          buffer-local-keymap set!buffer-local-keymap set!buffer-default-directory
          ;; `completion-base-position' is a variable local to `*Completions*'
          buffer-local-value erase-buffer set!mode-name
          set-buffer-local-value! use-local-map with-current-buffer)
    ;; `getcwd' is Guile's, for a buffer that has no `default-directory'.
    (only (guile) getcwd)
    ;; `(scheme eval)''s `eval' is the evaluator `eval-expression' runs,
    ;; and Guile's stack is where its `*Backtrace*' frames come from.
    (scheme eval)
    (only (guile) current-module display-backtrace make-stack)
    ;; `read' is `(scheme read)''s, not `(scheme base)''s - the trap
    ;; `(scheme write)''s `display' is in, one library over.
    (only (scheme read) read)
    (only (scheme write) display write)
    (only (schemacs editor keymap) set-keymap-parent)
    (only (schemacs editor window)
          delete-window display-buffer get-buffer-window pop-to-buffer
          quit-window
          split-main-window-below switch-to-buffer-other-window
          window-min-height)
    ;; `line-number-at-pos' is `editfns.c''s: the default `goto-line'
    ;; offers is the line point is on. The search primitives are
    ;; `search.c''s, which have their own library now (`zap-to-char'
    ;; walks with them).
    (only (schemacs editor editfns)
          char-after goto-char insert line-end-position
          line-number-at-pos message point)
    ;; `forward-char' is `cmds.c''s and lives in `(schemacs editor cmds)'.
    (only (schemacs editor cmds) forward-char)
    (only (schemacs editor search) search-backward search-forward)
    ;; `current-column' is indent.c's, which this library is the first
    ;; user of - `set-fill-column''s bare-C-u case reads it.
    (only (schemacs editor indentc) current-column)
    ;; `self-insert-command' is what SPC does in a file-name minibuffer
    ;; (`minibuffer-local-filename-completion-map' below), and
    ;; `with-current-buffer' and the line motion are the ordinary
    ;; commands the minibuffer's own keys fall back on.
    ;; `special-mode' is the backtrace buffer's mode - see the note on
    ;; `%eval-expression-backtrace'.
    (only (schemacs editor simple) special-mode special-mode-map
       self-insert-command
       kill-region push-mark region-active-p
       *this-command* *last-command*)
    (only (schemacs editor frame)
          *current-frame* *echo-area-buffer* *echo-area-prompt* *minibuffer*
          frame-height select-window set!frame-message
          set-message! set-window-point! window-buffer window-height
          window-list window-width)
    ;; `try-completion' and `all-completions' are `minibuf.c''s and live in
    ;; `(schemacs editor minibuf)'; this library is `minibuffer.el' and uses
    ;; them rather than defining them.
    (only (schemacs editor minibuf)
          *history-add-new-input*
          all-completions test-completion try-completion)
    ;; `caddr' is `(scheme cxr)'s: a style's entry in
    ;; `completion-styles-alist' is a four-element list.
    (only (scheme cxr) caddr)

    ;; The recursive edit the minibuffer is read by: the same command loop,
    ;; called again.
    (only (schemacs editor keyboard)
          abort-recursive-edit exit-recursive-edit read-key-event
          recursive-edit signal-quit)
    ;; The event model, for `read-char-from-minibuffer': it asks the
    ;; key *event* what it is, `char-alt' being `lisp.h''s lowest
    ;; modifier bit - the boundary between a plain character and a
    ;; modified key - and `event-convert-list', the C's way to name one
    ;; key's event from its description.
    (only (schemacs editor character) char-alt event-convert-list)
    ;; `read-char-from-minibuffer' reads the one key that answers it with
    ;; the command loop's read, so a pushed-back event reaches it too;
    ;; what it draws with is the display's `render!'.
    (only (schemacs editor xdisp) render!)
    ;; The global map `minibuffer-local-map' is built from, and the local
    ;; map it becomes while it is read.
    (only (schemacs editor keymap)
          define-key *current-keymap* *default-keymap*)
    )

  (export
   *minibuffer-completion-table*
   *completion-styles*
   choose-completion
   completion--do-completion
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
   *minibuffer-completing-file-name*
   *insert-default-directory*
   list-ref-or
   *minibuffer-exit-hook*
   *minibuffer-setup-hook*
   *minibuffer-message-timeout*
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
   minibuffer-default-prompt-format
   format-prompt
   read-number
read-number-history
   goto-line
   goto-line-history
   ;; `eval-expression' and its variables, from `simple.el'
   eval-expression eval-expression-print-format read--expression
   read--expression-map read--expression-try-read
   debugger-quit debugger-mode-map
   *eval-expression-print-maximum-character* *eval-expression-debug-on-error*
   read-expression-history
   set-fill-column
   zap-to-char
   goto-line-read-args
   make<minibuffer>
   minibuffer-complete
   minibuffer-completion-help
   minibuffer-contents
   minibuffer-cursor-column
   minibuffer-history
   minibuffer-insert!
   minibuffer-local-completion-map
   minibuffer-local-map
   minibuffer-position
   minibuffer-prompt
   minibuffer-prompt-string
   minibuffer-set-contents!
   minibufferp
   next-history-element
   previous-history-element
   read-char-from-minibuffer
   read-from-minibuffer
   ;; the history record itself, for the libraries that hold their own
   ;; histories - `replace.el''s `query-replace-history' - the way
   ;; `read-number-history' would have wanted its accessors exported
   make<history> history-entries set!history-entries
   execute-extended-command *extended-command-history*
   yes-or-no-p
   )

  (begin

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
    (define read-number-history (make<history> '()))
    ;; ^ GNU Emacs's `read-number-history' (`subr.el'), the history the
    ;; number prompts share. It is here beside `file-name-history' -
    ;; which is `files.el''s but lives here for the same reason - because
    ;; the history records are this library's, and `subr.sld' cannot
    ;; import them: minibuffer.sld already imports keyboard.sld, which
    ;; imports subr.sld, so subr -> minibuffer would be a cycle.

    (define-record-type <minibuffer-type>
      (make<minibuffer>
       editor prompt keymap default history position content)
      minibuffer-type?
      (editor   minibuffer-editor   set!minibuffer-editor)
      ;; ^ The <text-editor-type> holding what has been typed.
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
    ;; `(schemacs editor frame)' now, beside the frame state it is a fact
    ;; about, and `MINIBUFFER-EDITOR' is what the minibuffer binds to put
    ;; itself there.

    (define (minibufferp)
      ;; Whether the minibuffer is active: GNU Emacs's `minibufferp'.
      ;;--------------------------------------------------------------
      (and (*minibuffer*) #t))

    (define (minibuffer-contents . args)
      ;; What has been typed in the minibuffer: GNU Emacs's
      ;; `minibuffer-contents'. The optional argument is a minibuffer;
      ;; without one the active minibuffer is read.
      ;;--------------------------------------------------------------
      (let ((mb (if (pair? args) (car args) (*minibuffer*))))
        (if mb
            (text-editor-to-string (minibuffer-editor mb))
            #f)))

    (define (minibuffer-set-contents! mb text)
      ;; Replace what has been typed, leaving point at the end, the way
      ;; stepping through the history does.
      ;;--------------------------------------------------------------
      (let ((ed (minibuffer-editor mb)))
        (text-editor-undo-disable! ed)
        ;; the cursor goes to the beginning *before* the deletion: the
        ;; engine deletes forward from the cursor, so deleting first, at
        ;; the end where the cursor is, deletes nothing - and the text
        ;; that was there stayed in front of the new text. Stepping
        ;; through the history, and choosing a completion, both put the
        ;; answer one keystroke in front of the previous one.
        (text-editor-set-cursor ed (text-editor-point-min ed))
        (text-editor-delete-from-cursor ed (text-editor-char-count ed))
        (text-editor-insert ed text)))

    (define (minibuffer-insert! text)
      ;; Add TEXT to what has been typed, for the completion commands.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (when mb
          (text-editor-insert (minibuffer-editor mb) text))))

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
             (+ (string-length (minibuffer-prompt-string mb))
                (text-editor-cursor-column (minibuffer-editor mb))))))

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
             (ed (new-text-editor))
             (text (if (pair? initial) (car initial) initial))
             ;; point, counting from zero into TEXT, or #f for its end
             (at (if (not (pair? initial))
                     #f
                     (let ((n (cdr initial)))
                       (cond ((not (integer? n)) #f)
                             ((< n 1) 1)
                             (else n))))))
        ;; Emacs disables undo in the minibuffer.
        (text-editor-undo-disable! ed)
        (when text (text-editor-insert ed text))
        (text-editor-set-cursor ed
                                (if at
                                    (min at (text-editor-point-max ed))
                                    (text-editor-point-max ed)))
        (let ((mb (make<minibuffer>
                   ed prompt (or keymap minibuffer-local-map) default
                   (or history minibuffer-history) 0 #f)))
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
                         (*echo-area-prompt* prompt)
                         (*current-keymap* (minibuffer-keymap mb))
                         (*current-buffer* #f))
            ;; `minibuffer-setup-hook', run where the C runs it: after
            ;; the prompt and the initial input are in place, before the
            ;; recursive edit that reads (minibuf.c:912).
            (for-each (lambda (hook) (hook)) (*minibuffer-setup-hook*))
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
                        (set!history-entries
                         h (cons answer (history-entries h)))))
                    answer)))))))

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
             (entries (if h (history-entries h) '()))
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
             (entries (if h (history-entries h) '()))
             (position (if mb (minibuffer-position mb) 0))
             (next (max 0 (- position count))))
        (when mb
          (when (< next position)
            (set!minibuffer-position mb next)
            (minibuffer-set-contents!
             mb (if (= next 0)
                    (or (minibuffer-typed-content mb) "")
                    (list-ref entries (- next 1))))))))

    (define (minibuffer-local-bindings)
      ;; The keys GNU Emacs's `minibuffer-local-map' carries, as (KEY .
      ;; COMMAND) pairs. One list, because two maps are built from it:
      ;; the minibuffer's own, and the expression prompt's - see the note
      ;; on `read--expression-map' for why the second cannot inherit the
      ;; first.
      ;;--------------------------------------------------------------
      (list (cons (kbd "RET") exit-minibuffer)
            (cons (kbd "C-j") exit-minibuffer)
            (cons (kbd "C-g") abort-recursive-edit)
            (cons (kbd "M-p") previous-history-element)
            (cons (kbd "M-n") next-history-element)))

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
      ;; `(schemacs editor keyboard)' now does per lookup instead.
      ;;--------------------------------------------------------------
      (km:keymap
       '*minibuffer-local-map*
       (km:alist->keymap-layer (minibuffer-local-bindings))))


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
                    ;; the window comes *first*, so that the fill below
                    ;; reads the window's real width (the layout's column
                    ;; count is a function of it) - Emacs displays the
                    ;; buffer and then fills it, and so does this
                    (window (completion-display-window
                             (get-buffer-create "*Completions*")))
                    (buffer (display-completion-list
                             all (substring typed base-size (string-length typed))))
                    (window2 (completion-fit-window buffer)))
               (set-buffer-local-value! buffer 'completion-base-position
                                        (list base-size (string-length typed)))
               (record-buffer! buffer))))))

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
      (let ((typed (or (minibuffer-contents) "")))
        (completion--do-completion typed (*minibuffer-completion-table*)
                                   (*minibuffer-completion-predicate*)
                                   (string-length typed))))

    (define (read-char-from-minibuffer prompt)
      ;; GNU Emacs's `read-char-from-minibuffer': ask a question whose
      ;; answer is a single key, and return it - `y' or `n' alone
      ;; answers, with no RET. Emacs reads the key itself (`read-key');
      ;; here the key comes from the command loop's own read, so an event
      ;; a command pushed back reaches this question too, with the prompt
      ;; drawn in the echo area.
      ;; C-g abandons the whole command, and a key the question has no
      ;; meaning for (an arrow key, a frame resize) asks it again.
      ;;--------------------------------------------------------------
      (let ((frame (*current-frame*)))
        (parameterize ((*echo-area-buffer* (new-text-editor))
                       (*echo-area-prompt* prompt))
          (render! frame)
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

    (define (yes-or-no-p frame prompt)
      ;; GNU Emacs's `yes-or-no-p': the whole word, then RET. Being
      ;; fussier than `y-or-n-p' is the point - the answer to a question
      ;; about losing work should take some effort to give. C-g abandons
      ;; the command that asked.
      ;;--------------------------------------------------------------
      (let loop ()
        (let ((answer (read-from-minibuffer (string-append prompt "(yes or no) "))))
          (cond
           ((string-ci=? answer "yes") #t)
           ((string-ci=? answer "no") #f)
           (else (set!frame-message frame "Please answer yes or no.")
                 (loop))))))

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
      ;; GNU Emacs's `minibuffer-completion-confirm': whether RET may
      ;; leave the minibuffer holding something that is *not* a valid
      ;; completion. #f means it may not, `confirm' means it asks first,
      ;; and anything else means it may.
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
          (let ((ed (minibuffer-editor mb)))
            (text-editor-set-cursor ed (text-editor-point-min ed))
            (text-editor-delete-from-cursor ed (text-editor-char-count ed))
            (text-editor-insert ed completion)))))

    (define (completion--do-completion string table predicate point)
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
      ;; Not ported: the `completion-cycle-threshold' cycling and the
      ;; metadata (`completion--field-metadata').
      ;;--------------------------------------------------------------
      (let ((comp (completion-try-completion string table predicate point)))
        (cond
         ((not comp)
          (completion--message "No match")
          (minibuffer--bitset #f #f #f))
         ((eq? comp #t)
          (completion--message "Sole completion")
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
              (completion--message "Complete, but not unique")))
            (minibuffer--bitset completed #t exact))))))

      ;; GNU Emacs's `minibuffer-complete-and-exit' (RET in a
      ;; `require-match' minibuffer): leave if what is typed is a valid
      ;; completion, and otherwise complete it and say why it did not.
      ;;
      ;; The bitset is what decides, and the cases are Emacs's: an exact
      ;; (and unique) completion leaves; a completion that reached an
      ;; exact match leaves unless `minibuffer-completion-confirm' says to
      ;; ask first; and anything else stays put.
      ;;--------------------------------------------------------------
    (define-command (minibuffer-complete-and-exit)
      ;; A candidate chosen with M-<down> is taken before anything
      ;; else is tried, which is GNU Emacs's
      ;; `(when (completion--selected-candidate)
      ;;    (minibuffer-choose-completion t t))' at the head of its
      ;; `minibuffer-complete-and-exit'.
      "Exit the minibuffer, if what is typed is a valid completion."
      (interactive)
      (when (completion--selected-candidate)
        (minibuffer-choose-completion))
      (let* ((typed (or (minibuffer-contents) ""))
             (bits (completion--do-completion
                    typed (*minibuffer-completion-table*)
                    (*minibuffer-completion-predicate*)
                    (string-length typed))))
        (cond
         ;; `exit-minibuffer' is called, not run: `run-command' takes a
         ;; command *record* and this is the command's own procedure.
         ;; Nothing reached this until `read-file-name' began passing
         ;; `confirm-nonexistent-file-or-buffer' as its REQUIRE-MATCH -
         ;; M-x reads with REQUIRE-MATCH nil, so its RET is the plain
         ;; `exit-minibuffer' binding and never comes here.
         ((or (= bits 1) (= bits 3)) (exit-minibuffer))
         ((= bits 7)
          (if (*minibuffer-completion-confirm*)
              (minibuffer-message "Confirm")
              (exit-minibuffer)))
         (else #f))))

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
                       (*minibuffer-completion-confirm*
                        (if (or (eq? require-match 'confirm)
                                (eq? require-match 'confirm-after-completion))
                            #t
                            #f)))
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
      ;; BASE with `minibuffer-local-filename-completion-map' layered
      ;; over it when a file name is being read: GNU Emacs's
      ;; `(make-composed-keymap minibuffer-local-filename-completion-map
      ;; base-keymap)' with the base as the parent, which is what lets
      ;; the layered map's binding for a key override the base's.
      ;; Emacs tests `(memq minibuffer-completing-file-name '(nil
      ;; lambda))' - a file name is being read unless the variable is
      ;; nil.
      ;;--------------------------------------------------------------
      (if (not (*minibuffer-completing-file-name*))
          base
          (apply km:keymap
                 '*minibuffer-filename-completion-map*
                 (append
                  (km:keymap->layers-list minibuffer-local-filename-completion-map)
                  (km:keymap->layers-list base)))))

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
      (remove-text-properties start end '(face) buffer)
      (let* ((candidate (text-editor-copy-string buffer start end))
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
           buffer))))

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
        (text-editor-set-cursor buffer (text-editor-point-min buffer))
        (text-editor-insert buffer "Type M-RET on a completion to select it.\n")
        (text-editor-insert buffer
                            (string-append
                             "Type M-<down> or M-<up> to move point between "
                             "completions.\n\n"))))

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
        (let ((start (text-editor-point-max buffer)))
          (text-editor-insert buffer (completions-header-string count))
          (put-text-property start (text-editor-point-max buffer)
                             'face 'shadow buffer))))

    (define (insert-completion-cell! buffer candidate)
      ;; The core of GNU Emacs's `completion--insert': put CANDIDATE at
      ;; point with the `completion--string' property that says it *is*
      ;; a candidate. (Emacs's `completion-hilit-commonality' does the
      ;; two faces to the candidate *strings*; a string here cannot
      ;; carry a property, so the faces go straight on the buffer text.)
      ;;--------------------------------------------------------------
      (let ((start (text-editor-point-max buffer)))
        (text-editor-insert buffer candidate)
        (put-text-property start (text-editor-point-max buffer)
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
      (let ((start (text-editor-point-max buffer)))
        (text-editor-insert buffer str)
        (remove-text-properties start (text-editor-point-max buffer)
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
              (text-editor-set-cursor
               buffer (- (text-editor-point-max buffer) 1))
              (text-editor-delete-from-cursor buffer 1))
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
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create "*Completions*")))
        ;; the list is about to be thrown away, so the selection in it
        ;; is too: the recorded range would point into the new list.
        (clear-completions-selection!)
        (with-current-buffer buffer
          (set!buffer-local-keymap buffer completion-list-mode-map)
          (text-editor-set-read-only! buffer #f)
          (text-editor-set-cursor buffer (text-editor-point-min buffer))
          (text-editor-delete-from-cursor buffer (text-editor-char-count buffer))
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
          ;; `(schemacs editor intervals)'.
          (run-completion-setup-hook! buffer)
          (text-editor-set-read-only! buffer #t))
        buffer))

    (define *completions-max-height* (make-parameter #f))
    ;; ^ GNU Emacs's `completions-max-height': the most lines the
    ;; `*Completions*' window may have. Nil - Emacs's default - means
    ;; the window may grow to the frame.

    (define (completion-fitted-height buffer)
      ;; The height `completion-display-window' gives the `*Completions*'
      ;; window, as GNU Emacs's `fit-window-to-buffer' computes it: the
      ;; buffer's text lines plus its mode line, at least
      ;; `window-min-height', at most `*completions-max-height*' or -
      ;; that being nil - the frame's text area less a minimum for the
      ;; window above.
      ;;--------------------------------------------------------------
      (let* ((needed (+ 1 (text-editor-line-count buffer)))
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
             (candidate (get-text-property (text-editor-get-cursor ed)
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
    ;; GNU Emacs's `minibuffer-message' (minibuffer.el:813) and the
    ;; timer it arms. The echo area itself is drawn by the display
    ;; layer; what is here is what a message put there *says* and how
    ;; long it stays.

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

    (define (minibuffer-message message . args)
      ;; GNU Emacs's `minibuffer-message': show MESSAGE at the end of
      ;; what has been typed, without hiding it, and take it down again
      ;; after `minibuffer-message-timeout' seconds or at the next key,
      ;; whichever comes first. It is enclosed in `[...]' with a space
      ;; in front, which is Emacs's mark that this is something the
      ;; editor is saying and not part of the answer - so "No match"
      ;; reads " [No match]" after the prompt.
      ;;
      ;; Called when no minibuffer is being read, it is `message' and
      ;; the echo area is drawn as usual; the timeout is the same,
      ;; since the command loop takes messages down between commands
      ;; either way.
      ;;--------------------------------------------------------------
      (let ((text (if (and (not (pair? args)) (message-enclosed? message))
                      message
                      (string-append " [" message "]"))))
        (set-message! (*current-frame*)
                      (if (pair? args) (apply format #f text args) text)
                      (and (*minibuffer-message-timeout*)
                           (*minibuffer-message-timeout*)))))

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
      (let* ((start (text-editor-get-cursor buffer))
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
      (let ((last (text-editor-point-max buffer)))
        (let loop ((i (+ from 1)))
          (cond ((>= i last) #f)
                ((completion-start-at? buffer i) i)
                (else (loop (+ i 1)))))))

    (define (completion-previous-cell-start buffer from)
      ;; The last completion cell start before FROM, or #f.
      ;;--------------------------------------------------------------
      (let loop ((i (- from 1)))
        (cond ((< i (text-editor-point-min buffer)) #f)
              ((completion-start-at? buffer i) i)
              (else (loop (- i 1))))))

    (define (completion--cell-end buffer start)
      ;; One past the last character of the cell START starts: GNU
      ;; Emacs's `completion--move-to-candidate-end', which is where a
      ;; selection face stops on its cell.
      ;;--------------------------------------------------------------
      (let ((last (text-editor-point-max buffer))
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
      ;; on. This is GNU Emacs's `next-column-completion' for a
      ;; `horizontal' format: the next cell is the next in the buffer,
      ;; which is the next column of the row and then the first of the
      ;; next. The ends are clamped rather than wrapped, which is
      ;; `completion-auto-wrap' being nil - this editor's one-column
      ;; navigation always worked that way.
      ;;
      ;; Point starts on the heading line, above the first candidate, so
      ;; the first move finds the first cell and the moves after it walk
      ;; the cells in display order.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer "*Completions*")))
        (when buffer
          (let loop ((left (abs n)) (step (if (< n 0) -1 1)))
            (if (= left 0)
                #f
                (let ((next (if (< step 0)
                                (completion-previous-cell-start
                                 buffer (text-editor-get-cursor buffer))
                                (completion-next-cell-start
                                 buffer (text-editor-get-cursor buffer)))))
                  (if next
                      (begin (text-editor-set-cursor buffer next)
                             (loop (- left 1) step))
                      (loop 0 step))))
          ;; the window is a view of the buffer, so its point follows
          (let ((window (completions-window)))
            (when window
              (set-window-point! window (text-editor-get-cursor buffer))))
          (show-completions-selection! buffer)))))

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
             (get-text-property (text-editor-get-cursor buffer)
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
      (km:keymap
       '*minibuffer-local-filename-completion-map*
       (km:alist->keymap-layer
        (list (cons (kbd "SPC") self-insert-command)))))

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
      (apply km:keymap
             '*minibuffer-local-completion-map*
             (append
              (list (km:alist->keymap-layer
                     (list (cons (kbd "TAB") minibuffer-complete)
                           (cons (kbd "SPC") minibuffer-complete-word)
                           (cons (kbd "?") minibuffer-completion-help)
                           (cons (kbd "RET") minibuffer-completion-exit)
                           (cons (kbd "M-<up>") minibuffer-previous-completion)
                           (cons (kbd "M-<down>") minibuffer-next-completion)
                           (cons (kbd "M-RET") minibuffer-choose-completion))))
              (km:keymap->layers-list minibuffer-local-map))))


    (define minibuffer-local-must-match-map
      ;; GNU Emacs's `minibuffer-local-must-match-map', whose parent is
      ;; `minibuffer-local-completion-map': RET completes and exits rather
      ;; than leaving with whatever is typed, and C-j does the same. RET
      ;; still takes a chosen candidate first, since
      ;; `minibuffer-complete-and-exit' does that itself.
      ;;--------------------------------------------------------------
      (apply km:keymap
             '*minibuffer-local-must-match-map*
             (append
              (list (km:alist->keymap-layer
                     (list (cons (kbd "RET") minibuffer-complete-and-exit)
                           (cons (kbd "C-j") minibuffer-complete-and-exit))))
              (km:keymap->layers-list minibuffer-local-completion-map))))

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
      ;; Not ported: `selective-display' and the narrowing -
      ;; `re-search-forward' and `save-restriction' have nothing to act
      ;; on here - `widen-automatically', and the buffer switch the
      ;; cons prefix asks for.
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
      ;; Move to the specified line number in that buffer.
      ;; `let*', not `let': TARGET's initializer reads ED, and Elisp's
      ;; `let' binds its names one at a time the way `let*' does. Under
      ;; `let' ED is unbound there and the command dies with "Unbound
      ;; variable: ed" in the echo area - which is what `M-g g' did.
      (let* ((ed (current-buffer))
             (target (max (text-editor-point-min ed) line)))
        (text-editor-set-cursor ed target 0)
        (when (< (text-editor-cursor-line ed) target)
          (text-editor-set-cursor ed (text-editor-point-max ed)))))

    ;; The keys GNU Emacs binds it to (M-g g, and M-g M-g, which is the
    ;; same command), beside the command as the other libraries state
    ;; theirs.
    (define-key *default-keymap* (kbd "M-g g") goto-line)
    (define-key *default-keymap* (kbd "M-g M-g")
      goto-line)

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
                  (format #f "Change fill-column from %s to: "
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
      ;; Where the typed expression is evaluated.
      ;;
      ;; GNU Emacs evaluates in the current buffer's own context. The
      ;; nearest thing here is the module that is current when the command
      ;; runs, which is where the editor's own bindings live - so
      ;; `(+ 40 2)' finds `+' and a name the editor defines finds that
      ;; too. `(interaction-environment)' is *not* it: under `--r7rs' that
      ;; is a minimal environment with no `+' in it at all, which is how
      ;; the first version of this answered "Unbound variable: +".
      ;;--------------------------------------------------------------
      (current-module))

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
          (goto-char (text-editor-point-min buffer))
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
      (let ((map (km:keymap
                  '*debugger-mode-map*
                  (km:alist->keymap-layer
                   (list (cons (kbd "q") debugger-quit))))))
        (set-keymap-parent map special-mode-map)
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
      (km:keymap
       '*read--expression-map*
       (km:alist->keymap-layer
        (cons (cons (kbd "RET") read--expression-try-read)
              (minibuffer-local-bindings)))))

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

    ))
