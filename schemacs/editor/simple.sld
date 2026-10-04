(define-library (schemacs editor simple)
  ;; This library mirrors GNU Emacs's `simple.el' - the basic editing
  ;; commands and the machinery they need: point motion, insertion and
  ;; deletion, the kill ring and word motion, undo, and the prefix
  ;; argument. In Emacs they are one file, and they call each other
  ;; (`kill-line' into the kill ring, `kill-region' into `kill-new'), so
  ;; they are one library here too.
  ;;
  ;; What is *not* here yet, though it is simple.el's: the kill ring's
  ;; commands (`kill-region', M-w, M-y) and the rest of the region
  ;; commands, the quit signal that `keyboard-quit' raises - which belongs
  ;; to the command loop's error reporting - and the two file-visiting
  ;; commands, which are files.el's in the end.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    ;; `format' fills in `what-cursor-position''s message - Guile's,
    ;; which `(scheme base)' does not have.
    (only (guile) format)
    ;; `caddr' is `(scheme cxr)'s, and `push-mark' takes Emacs's three
    ;; optional arguments.
    (only (scheme cxr) caddr)
    ;; The prefix echo is a time.
    (only (scheme time) current-second)
    (prefix (schemacs keymap) km:)
    ;; `define-derived-mode' is `derived.el''s, and `special-mode' below
    ;; is defined with it.
    (only (schemacs editor derived) define-derived-mode)
    (only (schemacs editor engine)
         copy-marker marker-position set-marker!
         set!text-editor-deactivate-mark! text-editor-deactivate-mark
         set!text-editor-mark text-editor-char-count text-editor-copy-string 
         text-editor-cursor-column text-editor-cursor-line 
         text-editor-delete-from-cursor text-editor-get-char-index 
         text-editor-get-cursor text-editor-get-end-of-line 
         text-editor-get-start-of-line text-editor-insert 
         text-editor-line-count text-editor-mark text-editor-move-cursor 
         text-editor-read-only? text-editor-set-cursor 
         text-editor-set-read-only! text-editor-undo 
         text-editor-undo-boundary! text-editor-undo-list)
    (only (schemacs editor frame)
         *current-frame* *echo-area-buffer* display-selections-p
         set-message!
         frame-keymap-state
         selected-window set!frame-keymap-state
         set!frame-message set!window-top-line window-body-height
         window-buffer window-list window-top-line
         %window-hscroll)
    ;; The kill ring's window-system half: the cut and paste functions
    ;; are simple.el's `interprogram-*-function' variables' defaults,
    ;; and `deactivate-mark' sets PRIMARY through the low-level
    ;; `gui-set-selection' and asks the ownership questions.
    (only (schemacs editor select)
         gui-select-text gui-selection-value gui-set-selection
         gui-backend-selection-owner-p gui-backend-selection-exists-p
         *saved-region-selection*)
    ;; `toggle-truncate-lines' resets the `hscroll' of every window
    ;; showing the buffer, which is `set-window-hscroll''s
    (only (schemacs editor window) set-window-hscroll!)
    (only (schemacs editor command)
         current-prefix-arg new-command uarg->integer define-command)
    ;; The buffer-local store, for `mark-ring' - which is the buffer's
    ;; own - and the variables that come from the libraries Emacs
    ;; declares them in: `mark-active' and `transient-mark-mode' are
    ;; `buffer.c''s, `mark-even-if-inactive' is `callint.c''s,
    ;; `region-beginning' and `region-end' are `editfns.c''s, and
    ;; `add-to-history' is `subr.el''s.
    (only (schemacs editor buffer)
          *show-trailing-whitespace*
          buffer-local-value buffer-truncate-lines current-buffer mark-active
          set!buffer-truncate-lines set!mark-active
          set-buffer-local-value! transient-mark-mode)
    (only (schemacs editor command) *mark-even-if-inactive*)
    (only (schemacs editor editfns)
          bolp buffer-size delete-and-extract-region delete-region eobp
          eolp following-char forward-line insert line-beginning-position
          line-end-position goto-char point point-max preceding-char
          region-beginning region-end save-excursion)
    (only (schemacs editor syntax) skip-chars-forward skip-chars-backward)
    ;; `kbd' is how the bindings below name their keys, as
    ;; `(define-key global-map (kbd "C-/") ...)' would in Emacs.
    (only (schemacs editor subr) add-to-history kbd nthcdr)
    ;; `define-key' and the global map, which this library fills with the
    ;; bindings for the commands it defines - as simple.el does with
    ;; `(define-key global-map ...)'.
    (only (schemacs editor keymap)
         add-keymap-layer!
         define-key
         single-key-description
         *default-keymap*)
    )

  (export
   special-mode special-mode-hook special-mode-map
   %blank-line? %char-at %inword-at *amalgamating-count% *amalgamating-undo-limit*
   *last-change-was-undo* *last-command* *this-command* *temporary-goal-column*
   *kill-do-not-save-duplicates* *kill-read-only-ok*
   *kill-ring* *kill-ring-max* *kill-ring-yank-pointer*
   *interprogram-cut-function* *interprogram-paste-function*
   *select-active-regions* *yank-pop-change-selection*
   *pending-undo-list* *prefix-cu* *prefix-digits* *prefix-negative*
   amalgamating-command? backward-char backward-delete-char
   backward-kill-word backward-word backward-word-position
   beginning-of-buffer beginning-of-line clear-prefix! delete-char
   end-of-buffer end-of-line exchange-point-and-mark forward-char
   forward-word forward-word-position keyboard-quit kill-line
   copy-region-as-kill current-kill kill-append
   kill-new kill-range kill-region kill-ring-save kill-word next-line
   pending-uarg yank-pop
   ;; Emacs's `newline' clashes with `(scheme base)'s output procedure,
   ;; so the command is named `insert-newline' here; see below.
   insert-newline
   place-undo-boundary! previous-line read-only-mode
   scroll-down-command scroll-up-command self-insert-command
   self-insert-layer self-insert-tab
   *activate-mark-hook* *deactivate-mark-hook*
   *exchange-point-and-mark-highlight-region*
   *mark-ring-max* *use-empty-active-region*
   activate-mark deactivate-mark digit-argument
   mark mark-ring mark-whole-buffer negative-argument
   pop-mark pop-to-mark-command push-mark push-mark-command
   region-active-p set-mark set-mark-command
   set!mark-ring use-region-p
prefix-argument-description
   what-cursor-position
   open-line open-line-command delete-indentation-command
just-one-space delete-horizontal-space delete-blank-lines
   *kill-whole-line*
   delete-all-space delete-leading-space delete-trailing-space
   transpose-chars transpose-words fixup-whitespace
   prefix-echo-pending? request-prefix-echo! show-prefix-echo!
   strip-undo-boundaries undo undo-redo update-prefix!
   word-char? word-run-end word-run-start yank
   )

  (begin

    ;;----------------------------------------------------------------
    ;; `special-mode'
    ;;------------------------------------------------------------------

    (define special-mode-map
      ;; GNU Emacs's `special-mode-map', which `define-derived-mode'
      ;; makes for the mode below: the keys every special mode shares.
      ;; It has no keys of its own here yet - Emacs's carries the
      ;; `special-mode' bindings - so it is an empty map for the modes
      ;; that derive from this one to layer over.
      ;;--------------------------------------------------------------
      (km:keymap '*special-mode-map*))

    (define special-mode-hook '())
    ;; ^ GNU Emacs's `special-mode-hook', made by `define-derived-mode'.
    ;; Emacs's macro invents both names from the mode's; this one is
    ;; handed them, for the reason `(schemacs editor derived)' gives.

    (define-derived-mode (special-mode #f "Special" special-mode-map
                                       special-mode-hook)
      "Parent major mode from which special major modes should inherit.

A special major mode is intended to view specially formatted data
rather than files.  These modes usually use read-only buffers."
      (text-editor-set-read-only! (current-buffer) #t))

    ;;----------------------------------------------------------------
    ;; Commands
    ;;
    ;; Commands are named after their Emacs equivalents, so the
    ;; command layer remains Elisp-compatible. The API procedure (the
    ;; second lambda) takes real arguments and can be applied from
    ;; Elisp later, in the same way GNU Emacs distinguishes interactive
    ;; from programmatic calls.
    ;;
    ;; A command that works with a count declares the `uarg' interactive
    ;; spec, which is how it tells the dispatcher to hand it the prefix
    ;; argument; `NEW-COUNT-COMMAND' builds both lambdas for that case.
    ;; It and `NEW-COMMAND' are the command substrate, so they live in
    ;; `(schemacs editor command)' - GNU Emacs's `interactive' forms are
    ;; the interpreter's business (callint.c), not any one .el file's,
    ;; and the minibuffer needs it too.

    ;; `self-insert-command' is the one command left on `new-command':
    ;; the character it inserts is re-derived from the keymap lookup
    ;; state at *interactive* time, which `(interactive ...)' cannot say
    ;; yet - so it stays on the record form until it can.
    (define self-insert-command
      ;; The character is not an argument the dispatcher can supply: it
      ;; is re-derived from the frame's keymap lookup state, which holds
      ;; the key index of the chord that reached this command. The
      ;; prefix argument is supplied normally, as the repeat count.
      (new-command
       "self-insert-command"
       (lambda (uarg)
         (let ((state (frame-keymap-state (*current-frame*))))
           (when state
             (km:keymap-index-to-char
              (km:modal-lookup-state-key-index state) #f
              (lambda (c)
                (let loop ((i (uarg->integer 1 uarg)))
                  (when (> i 0)
                    (text-editor-insert (current-buffer) c)
                    (loop (- i 1)))))
              (lambda () #f))
              )))
       (lambda (c) (text-editor-insert (current-buffer) c))
       "Insert the typed character at point."
       'uarg))

    (define-command (self-insert-tab count)
      "Insert N tab characters at point."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-insert (current-buffer) #\tab)
          (loop (+ 1 i)))))

    (define-command (forward-char count)
      "Move point N characters forward."
      (interactive "p")
      (text-editor-move-cursor (current-buffer) count))

    (define-command (backward-char count)
      "Move point N characters backward."
      (interactive "p")
      (text-editor-move-cursor (current-buffer) (- count)))

    (define *temporary-goal-column* (make-parameter 0))

    (define-command (next-line count)
      "Move point down N lines, keeping the column."
      (interactive "p")
      (let* ((ed (current-buffer))
             (goal (if (memq (*last-command*) (list next-line previous-line))
                       (*temporary-goal-column*)
                       (text-editor-cursor-column ed))))
        (*temporary-goal-column* goal)
        (let loop ((i 0))
          (when (< i count)
            (let ((line (text-editor-cursor-line ed)))
              (text-editor-set-cursor ed (+ 1 line) goal)
              (cond
               ;; There was no line to move to: point is on the last
               ;; line, and the engine will not leave it. Emacs moves
               ;; point to the end of the buffer there - which is the
               ;; end of this line, there being no line break after it
               ;; - and reports `end-of-buffer'.
               ((= line (text-editor-cursor-line ed))
                (text-editor-set-cursor
                 ed (text-editor-get-end-of-line ed))
                (error "End of buffer"))
               (else (loop (+ 1 i)))))))))

    (define-command (previous-line count)
      "Move point up N lines, keeping the column."
      (interactive "p")
      (let* ((ed (current-buffer))
             (goal (if (memq (*last-command*) (list next-line previous-line))
                       (*temporary-goal-column*)
                       (text-editor-cursor-column ed))))
        (*temporary-goal-column* goal)
        (let loop ((i 0))
          (when (< i count)
            (let ((line (text-editor-cursor-line ed)))
              (text-editor-set-cursor ed (- line 1) goal)
              (cond
               ((= line (text-editor-cursor-line ed))
                (text-editor-set-cursor
                 ed (text-editor-get-start-of-line ed))
                (error "Beginning of buffer"))
               (else (loop (+ 1 i)))))))))

    (define-command (beginning-of-line)
      "Move point to the beginning of the current line."
      (interactive)
      (text-editor-set-cursor (current-buffer)
                              (text-editor-get-start-of-line
                               (current-buffer))))

    (define-command (end-of-line)
      "Move point to the end of the current line."
      (interactive)
      (text-editor-set-cursor (current-buffer)
                              (text-editor-get-end-of-line
                               (current-buffer))))

    (define-command (delete-char count)
      "Delete N characters after point."
      (interactive "p")
      (text-editor-delete-from-cursor (current-buffer) count))

    (define-command (backward-delete-char count)
      "Delete N characters before point."
      (interactive "p")
      (text-editor-delete-from-cursor (current-buffer) (- count)))

    (define-command (kill-line uarg)
      "Kill N lines at point. With no argument, kill to the end of the
 line, taking the line break when only blanks remain before it."
      (interactive "P")
      (kill-region (point)
                   (begin
                     (if uarg
                         (let ((fail (forward-line (uarg->integer 1 uarg))))
                           ;; `forward-visible-line 0' is
                           ;; `beginning-of-line', which `forward-line 0'
                           ;; is too - the engine's zero stays where it
                           ;; is, so it is done here
                           (when (= 0 (uarg->integer 1 uarg))
                             (beginning-of-line))
                           (unless (= 0 fail)
                             (error "End of buffer")))
                         (begin
                           (when (eobp)
                             (error "End of buffer"))
                           (let ((end (line-end-position)))
                             (if (or (save-excursion
                                       (unless (*show-trailing-whitespace*)
                                         (skip-chars-forward " \t" end))
                                       (eolp))
                                     (and (*kill-whole-line*) (bolp)))
                                 (let ((fail (forward-line 1)))
                                   (unless (= 0 fail)
                                     (error "End of buffer")))
                                 (goto-char end)))))
                     (point))))

    (define-command (insert-newline count)
      "Insert N line breaks at point."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-insert (current-buffer) #\newline)
          (loop (+ 1 i)))))

    ;; `keyboard-quit', `read-only-mode' and
    ;; `exchange-point-and-mark' are simple.el's; they were
    ;; misfiled under the Windows and isearch banners.
    (define-command (keyboard-quit)
      "Cancel the current action and clear the echo area."
      (interactive)
      (set!frame-message (*current-frame*) "")
      (set!frame-keymap-state (*current-frame*) #f))

    (define-command (read-only-mode uarg)
      ;; GNU Emacs's `read-only-mode' (it used to be called
      ;; `toggle-read-only'). With no argument it toggles; with one it
      ;; turns read-only on for a positive count and off otherwise,
      ;; which is the convention Emacs's minor modes follow. The
      ;; buffer's text cannot be changed while it is on, and undo will
      ;; not touch it either.
      "Toggle whether the buffer can be changed (bound to C-x C-q)."
      (interactive "P")
      (let* ((frame (*current-frame*))
             (ed (current-buffer))
             (on? (if uarg
                      (< 0 (uarg->integer 1 uarg))
                      (not (text-editor-read-only? ed)))))
        (text-editor-set-read-only! ed on?)
        (set!frame-message
         frame
         (if on?
             "Read-Only mode enabled in current buffer"
             "Read-Only mode disabled in current buffer"))))

    (define *exchange-point-and-mark-highlight-region*
      ;; GNU Emacs's `exchange-point-and-mark-highlight-region':
      ;; whether exchanging the point and the mark also activates the
      ;; region. Setting it to #f swaps the meanings of C-x C-x with and
      ;; without a prefix argument.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define-command (exchange-point-and-mark arg)
      ;; GNU Emacs's `exchange-point-and-mark' (C-x C-x): put the mark
      ;; where point is now, and point where the mark was - which is how
      ;; you return to where a search started. It works even when the
      ;; mark is not active, and it *reactivates* it, so that the region
      ;; it just went back to is the one you see.
      ;;
      ;; A prefix argument does the opposite: it leaves the mark
      ;; inactive. Unless `exchange-point-and-mark-highlight-region' is
      ;; off, in which case a prefix argument is what activates it -
      ;; Emacs's `(xor arg ...)' below, which is the whole of that
      ;; variable's meaning.
      "Put the mark where point is now, and point where the mark is now."
      (interactive "P")
      (let ((omark (mark #t))
            (region-was-active (region-active-p)))
        (if (not omark)
            (error "No mark set in this buffer")
            (begin
              (set-mark (text-editor-get-cursor (current-buffer)))
              (text-editor-set-cursor (current-buffer) omark)
              (if (eq? (and arg #t)
                       (not (if (*exchange-point-and-mark-highlight-region*)
                                (region-active-p)
                                region-was-active)))
                  (deactivate-mark)
                  (activate-mark))))))

        (define *next-screen-context-lines* (make-parameter 2))
    ;; ^ GNU Emacs's `next-screen-context-lines', which `window.c:9300'
    ;; declares as a DEFVAR_INT defaulting to 2: "Number of lines of
    ;; continuity when scrolling by screenfuls". It is what a
    ;; near-full-screen scroll leaves visible at the far edge.

    ;; The two are named as GNU Emacs's `window.el:10953' and `:11007' name
    ;; them: `scroll-up-command' "Scroll text of selected window upward" -
    ;; the text moves up, which is toward the *end* of the buffer - and
    ;; `scroll-down-command' scrolls downward, toward the beginning. Emacs
    ;; binds C-v to the first and M-v to the second
    ;; (`bindings.el:1404-1405' binds `[prior]' and `[next]' to the same
    ;; two), and this tree's names were the other way round: the command
    ;; bound to C-v was named `scroll-down-command', so M-x showed the
    ;; name Emacs gives the *other* key.
    ;;
    ;; The *number of lines* is `scroll_command''s (`window.c:6975'), and
    ;; it is not the same for the two ways the command is called:
    ;;
    ;;   * with no prefix, the near-full-screen amount - and
    ;;     `window_scroll_line_based' multiplies it out from the window's
    ;;     height: "If scrolling screen-fulls, compute the number of lines
    ;;     to scroll from the window's height" - `n *= max (1, ht -
    ;;     nscls)', where `ht' is the window's internal height (its height
    ;;     less the mode line, which is `window-body-height' here) and
    ;;     `nscls' is `next-screen-context-lines', 2 by default
    ;;     (`window.c:9302'). So the amount *is* the window's height less
    ;;     two, and grows with the window.
    ;;   * with a *numeric* prefix, `whole' is false and the
    ;;     multiplication is not done: the command scrolls exactly that
    ;;     many lines (`window.c:7002-7005' - "NILP (n)" gives the whole
    ;;     screen, anything else passes `n * direction' straight through).
    ;;
    ;; This tree multiplied in both cases, so `C-u 3 M-v' scrolled three
    ;; screenfuls where Emacs scrolls three *lines*.

    (define (scroll-amount uarg window)
      ;; The number of lines to scroll: the near-full-screen amount when
      ;; no prefix was typed, its negative for the atom `-', and exactly
      ;; the prefix's numeric value otherwise - `scroll_command''s three
      ;; cases (`window.c:7002-7005'), in its order.
      ;;--------------------------------------------------------------
      (let* ((vheight (window-body-height window))
             (full (max 1 (- vheight (*next-screen-context-lines*)))))
        (cond ((not uarg) full)
              ((eq? uarg '-) (- full))
              (else (uarg->integer 1 uarg)))))

    (define-command (scroll-up-command uarg)
      ;; Scroll the view toward the end of the buffer, with a two-line
      ;; overlap, like mg's `forwpage`. If the point falls outside the new
      ;; window it moves to the top of the window, column zero. Reports
      ;; "End of buffer" when the view cannot scroll further.
      "Scroll text of selected window upward."
      (interactive "P")
      (let* ((frame (*current-frame*))
             (window (selected-window))
             (ed (window-buffer window))
             (vheight (window-body-height window))
             (n (scroll-amount uarg window))
             (last-line (max 0 (- (text-editor-line-count ed) 1)))
             (new-top (min (+ (window-top-line window) n) last-line)))
        (if (<= new-top (window-top-line window))
            (set!frame-message frame "; End of buffer")
            (begin
              (set!window-top-line window new-top)
              (let ((line (text-editor-cursor-line ed)))
                (when (or (< line new-top)
                          (>= line (+ new-top vheight)))
                  (text-editor-set-cursor ed new-top 0)))))))

    (define-command (scroll-down-command uarg)
      ;; Scroll the view toward the beginning of the buffer, the mirror
      ;; of `scroll-up-command'.
      "Scroll text of selected window downward."
      (interactive "P")
      (let* ((frame (*current-frame*))
             (window (selected-window))
             (ed (window-buffer window))
             (vheight (window-body-height window))
             (n (scroll-amount uarg window))
             (new-top (max 0 (- (window-top-line window) n))))
        (if (= new-top (window-top-line window))
            (set!frame-message frame "; Beginning of buffer")
            (begin
              (set!window-top-line window new-top)
              (let ((line (text-editor-cursor-line ed)))
                (when (or (< line new-top)
                          (>= line (+ new-top vheight)))
                  (text-editor-set-cursor
                   ed (+ new-top (- vheight 1)) 0)))))))
	
	(define-command (toggle-truncate-lines arg)
      "Toggle truncating of long lines for the current buffer.
When truncating is off, long lines are folded.
With prefix argument ARG, truncate long lines if ARG is positive,
otherwise fold them.  Note that in side-by-side windows, this
command has no effect if `truncate-partial-width-windows' is
non-nil."
      ;; `simple.el:9341'. It is an M-x command there, bound to nothing -
      ;; so it is here, where the buffer's `truncate-lines' lives. The
      ;; `visual-line-mode' half of its message has no counterpart: that
      ;; minor mode is not ported.
      (interactive (list (current-prefix-arg)))
      (let ((truncate
             (if (not arg)
                 (not (buffer-truncate-lines (current-buffer)))
                 (> (uarg->integer 1 arg) 0))))
        (set!buffer-truncate-lines (current-buffer) truncate)
        (unless truncate
          ;; turning folding back on clears the `hscroll' of every window
          ;; showing the buffer, as `walk-windows' does (`simple.el:9359')
          (let ((buffer (current-buffer)))
            (for-each
             (lambda (window)
               (when (eq? buffer (window-buffer window))
                 (set-window-hscroll! window 0)))
             (window-list (*current-frame*)))))
        (set!frame-message
         (*current-frame*)
         (string-append "Truncate long lines "
                        (if truncate "enabled" "disabled")))))

    (define-command (beginning-of-buffer)
      "Move point to the beginning of the buffer."
      (interactive)
      (let ((window (selected-window)))
        (set!window-top-line window 0)
        (text-editor-set-cursor (window-buffer window) 0 0)))

    (define-command (end-of-buffer)
      "Move point to the end of the buffer."
      (interactive)
      (let ((ed (current-buffer)))
        (text-editor-set-cursor
         ed (text-editor-char-count ed))))

    ;;----------------------------------------------------------------
    ;; Kill ring and word motion
    ;;
    ;; The kill ring follows mg's `yank.c` model: a single kill buffer
    ;; where consecutive kills accumulate (the CFKILL protocol from
    ;; mg's yank.c: the kill buffer is cleared only when the previous
    ;; command was not a kill), forward kills append at the end and
    ;; backward kills prepend at the front. A multi-entry ring with
    ;; M-y cycling can be added later.
    ;;
    ;; The CFKILL protocol needs two flags, not one, because a kill has
    ;; to be able to ask about the command *before* it: mg's command
    ;; loop keeps `thisflag' (set by the command that just ran) and
    ;; `lastflag' (what the running command sees) and rotates them at
    ;; the top of every command (mg's main.c:328, "lastflag = thisflag;
    ;; thisflag = 0"). The frontend rotates them in `dispatch-action',
    ;; which is the one place a command is invoked from the keyboard.
    ;;------------------------------------------------------------------

    (define *this-command*
      ;; The command being run: GNU Emacs's `this-command', which the
      ;; command loop sets before a command and - this is the part that
      ;; matters - *the command itself may set again*, and which the loop
      ;; then makes `last-command'.
      ;;
      ;; That is how a kill run is joined: `kill-region' sets it to
      ;; itself, so a command that kills is seen as `kill-region' by the
      ;; next one whatever key ran it. It is also how `yank-pop' can be
      ;; repeated - it sets it to `yank', so the next M-y still looks like
      ;; one - and why the ring may be gone round and round.
      ;;
      ;; It replaces mg's `*this-command-kill*'/`*last-command-kill*'
      ;; pair, which was the same idea for the one thing mg needed it
      ;; for.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (word-char? c)
      ;; The word-constituent predicate, like mg's `inword`/ISWORD:
      ;; alphanumeric characters (plus the underscore).
      ;;--------------------------------------------------------------
      (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

    (define (%char-at ed index)
      (text-editor-get-char-index ed index))

    (define (%inword-at ed index)
      ;; like mg's `inword`, over absolute character indices
      (let ((c (%char-at ed index)))
        (and c (word-char? c))))

    (define (forward-word-position ed)
      ;; Like mg's `forwword` (word.c:51): skip over non-word
      ;; characters, then over word characters. Returns the absolute
      ;; character index of the end of the next word.
      ;;--------------------------------------------------------------
      (let ((count (text-editor-char-count ed)))
        (let loop ((i (text-editor-get-cursor ed)) (phase 'skip))
          (cond
           ((>= i count) count)
           ((eq? phase 'skip)
            (if (%inword-at ed i) (loop i 'word) (loop (+ i 1) 'skip)))
           (else
            (if (%inword-at ed i) (loop (+ i 1) 'word) i))))))

    (define (backward-word-position ed)
      ;; Like mg's `backword` (word.c:27): step back one character,
      ;; skip back over non-word characters, then back over word
      ;; characters, and step forward once, landing on the first
      ;; character of the word.
      ;;--------------------------------------------------------------
      (let ((i0 (text-editor-get-cursor ed)))
        (if (<= i0 0) 0
            (let loop ((i (- i0 1)) (phase 'skip))
              (cond
               ((< i 0) 0)
               ((eq? phase 'skip)
                (if (%inword-at ed i) (loop i 'word) (loop (- i 1) 'skip)))
               (else
                (if (%inword-at ed i) (loop (- i 1) 'word) (+ i 1))))))))

    (define (kill-range ed start end forward?)
      ;; Kill (cut) the text between the character indices START and END
      ;; and return it. This is the shared middle of the commands that
      ;; kill: the word kills, and `kill-line'.
      ;;
      ;; It was mg's, over a single kill *buffer*, and is now a thin layer
      ;; over Emacs's kill *ring* - `kill-append' on a run of kills and
      ;; `kill-new' to start one. The callers did not change.
      ;;
      ;; Emacs's rule is `(kill-append string (< end beg))' with BEG the
      ;; mark and END point, so BEFORE-P is true when the text being
      ;; killed lies *before* what was killed last - a backward kill.
      ;; FORWARD? says the same thing here, the other way up.
      ;;--------------------------------------------------------------
      (let* ((text (text-editor-copy-string ed start end)))
        (if (eq? (*last-command*) kill-region)
            (kill-append text (not forward?))
            (kill-new text))
        ;; "Any command that calls this function is a kill command": it
        ;; says so by becoming `kill-region' for the next one.
        (*this-command* kill-region)
        (text-editor-set-cursor ed (min start end))
        (text-editor-delete-from-cursor ed (abs (- end start)))
        text))

    (define-command (forward-word count)
      ;; mg's `forwword` (word.c:51) with its numeric-argument loop: move
      ;; N words forward, stopping at the end of the buffer.
      "Move point N words forward, to the end of each word."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-set-cursor
           (current-buffer) (forward-word-position (current-buffer)))
          (loop (+ 1 i)))))

    (define-command (backward-word count)
      ;; mg's `backword` (word.c:27) with its numeric-argument loop.
      "Move point N words backward, to the start of each word."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-set-cursor
           (current-buffer) (backward-word-position (current-buffer)))
          (loop (+ 1 i)))))

    (define (word-run-end ed count)
      ;; The character index COUNT words forward of point, found the way
      ;; mg's `delfword' (word.c:397) counts its `size' before deleting:
      ;; walk the word motion, stopping when it stops advancing (the end
      ;; of the buffer).
      ;;--------------------------------------------------------------
      (let loop ((i 0) (pos (text-editor-get-cursor ed)))
        (if (>= i count)
            pos
            (begin
              (text-editor-set-cursor ed pos)
              (let ((next (forward-word-position ed)))
                (if (= next pos) pos (loop (+ 1 i) next)))))))

    (define (word-run-start ed count)
      ;; The character index COUNT words back from point, the mirror of
      ;; `word-run-end' and the way mg's `delbword' (word.c:453) counts.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (pos (text-editor-get-cursor ed)))
        (if (>= i count)
            pos
            (begin
              (text-editor-set-cursor ed pos)
              (let ((prev (backward-word-position ed)))
                (if (= prev pos) prev (loop (+ 1 i) prev)))))))

    (define-command (kill-word count)
      ;; Like mg's `delfword` (word.c:397): kill from point to the end
      ;; of the next word. The N words are one kill, so they accumulate
      ;; into the kill buffer as a single entry.
      "Kill N words forward from point."
      (interactive "p")
      (let* ((ed (current-buffer))
             (start (text-editor-get-cursor ed))
             (end (word-run-end ed count)))
        (when (< start end)
          (kill-range ed start end #t))))

    (define-command (backward-kill-word count)
      ;; Like mg's `delbword` (word.c:453): kill from the start of the
      ;; previous word to point.
      "Kill N words backward from point."
      (interactive "p")
      (let* ((ed (current-buffer))
             (end (text-editor-get-cursor ed))
             (start (word-run-start ed count)))
        (when (< start end)
          (kill-range ed start end #f))))

    ;;----------------------------------------------------------------
    ;; The kill ring
    ;;
    ;; GNU Emacs's `simple.el', the same banner: `kill-ring' is a *list*
    ;; of the last `kill-ring-max' kills, most recent first, with
    ;; `kill-ring-yank-pointer' pointing into it at the entry the next
    ;; `yank' would use. It replaces mg's single `*kill-buffer*', whose
    ;; CFKILL accumulation was the same idea with nowhere to rotate to -
    ;; so there was no M-y.
    ;;
    ;; The rule that makes consecutive kills join is worth stating,
    ;; because it is not where it looks. `kill-region' tests
    ;; `(eq last-command 'kill-region)' and then **sets `this-command' to
    ;; `kill-region'** - so a command that kills *renames itself*, and the
    ;; next command sees a kill as the last one whatever key ran it. That
    ;; is what `*last-command-kill*' is here: mg's flag, rotated by the
    ;; command loop, set by everything that kills.
    ;;--------------------------------------------------------------

    (define *kill-ring*
      ;; GNU Emacs's `kill-ring': the killed texts, most recent first.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *kill-ring-yank-pointer*
      ;; GNU Emacs's `kill-ring-yank-pointer`: a *tail* of `kill-ring',
      ;; the entry the next `yank' takes and the place `yank-pop'
      ;; rotates from. A tail rather than an index, as in Emacs, because
      ;; that is what `kill-new' can set in one move.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *kill-ring-max*
      ;; GNU Emacs's `kill-ring-max': how many kills are kept. 120 on
      ;; Emacs 31, which is where this number comes from.
      ;;--------------------------------------------------------------
      (make-parameter 120))

    (define *kill-do-not-save-duplicates*
      ;; GNU Emacs's `kill-do-not-save-duplicates', off by default: when
      ;; it is on, killing text that is already the front of the ring
      ;; does not add it again.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *kill-whole-line*
      ;; GNU Emacs's `kill-whole-line' (simple.el:6762, a defcustom):
      ;; "If non-nil, `kill-line' with no arg at start of line kills
      ;; the whole line. This variable also affects `kill-visual-line'
      ;; in the same way as it does `kill-line'." Off, as Emacs's
      ;; default is; `defcustom' is spelled a parameter here, the
      ;; customize machinery behind it not being ported.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *kill-read-only-ok*
      ;; GNU Emacs's `kill-read-only-ok', off by default: when it is on,
      ;; a kill from a read-only buffer puts the text in the ring and
      ;; says so instead of signalling.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    ;; The window-system cut and paste hooks, simple.el:5666 and :5677 -
    ;; "Function to call to make a killed region available to other
    ;; programs" and its paste-side counterpart, which answers "text
    ;; cut from other programs" or nil when none has been provided.
    ;; Their defaults are `select.el''s `gui-select-text' and
    ;; `gui-selection-value', which this library imports; a text
    ;; terminal's backend answers #f under them, so they are no-ops
    ;; there, which is what `emacs -nw' does.
    (define *interprogram-cut-function* (make-parameter gui-select-text))
    (define *interprogram-paste-function* (make-parameter gui-selection-value))

    (define *select-active-regions*
      ;; GNU Emacs's `select-active-regions', on by default: whether an
      ;; active region is put in the window system's PRIMARY selection -
      ;; on deactivation (`deactivate-mark') and, on the C side, after
      ;; each command. keyboard.c declares it (a DEFVAR_LISP defaulting
      ;; to t, `keyboard.c:14361'), and the command-loop half that reads
      ;; it after every command is not ported; `deactivate-mark' below
      ;; is the only reader here.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *yank-pop-change-selection*
      ;; GNU Emacs's `yank-pop-change-selection', off by default:
      ;; whether rotating the kill ring - usually with `yank-pop' - also
      ;; copies the new kill to the window system selection.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (kill-new string . args)
      ;; GNU Emacs's `kill-new': make STRING the latest kill, and point
      ;; the yank pointer at it. REPLACE - false unless passed - replaces
      ;; the front of the ring rather than adding a new entry, which is
      ;; how a run of kills becomes one entry.
      ;;
      ;; Emacs also offers the string to the window system here
      ;; (`interprogram-cut-function'), which is what makes M-w visible
      ;; to other programs: its default, `gui-select-text', puts the
      ;; text on the clipboard.
      ;;
      ;; Not ported: `kill-transform-function' (its default is to pass
      ;; the string through) and `menu-bar-update-yank-menu' (there is
      ;; no menu bar), and `save-interprogram-paste-before-kill', off by
      ;; default - the block that saves what other programs have on the
      ;; clipboard before a kill replaces the ring.
      ;;--------------------------------------------------------------
      (let ((replace (if (pair? args) (car args) #f)))
        ;; `equal-including-properties''s empty-ring case: in Elisp
        ;; `(car nil)' is nil, and nil is not equal to STRING, so an
        ;; empty ring always takes the new entry.
        (unless (and (*kill-do-not-save-duplicates*)
                     (pair? (*kill-ring*))
                     (equal? string (car (*kill-ring*))))
          (if (and replace (pair? (*kill-ring*)))
              (set-car! (*kill-ring*) string)
              (*kill-ring* (add-to-history (*kill-ring*) string
                                           (*kill-ring-max*) #t))))
        (*kill-ring-yank-pointer* (*kill-ring*))
        (if (*interprogram-cut-function*)
            ((*interprogram-cut-function*) string))
        string))

    (define (kill-append string before-p)
      ;; GNU Emacs's `kill-append': add STRING to the latest kill, or -
      ;; BEFORE-P - in front of it. This is the consecutive-kill case, and
      ;; the reason two C-k's paste as two lines rather than one.
      ;;
      ;; Emacs decides whether to replace the front of the ring by whether
      ;; the text being appended to came from a `yank-handler'; there is
      ;; no `yank-handler' here, so it always replaces, which is what its
      ;; expression comes to without one.
      ;;
      ;; An empty ring: Elisp's `cur' is nil then, and `(concat nil s)'
      ;; is s - so the first kill-append onto an empty ring appends
      ;; nothing.
      ;;--------------------------------------------------------------
      (let ((cur (if (pair? (*kill-ring*)) (car (*kill-ring*)) "")))
        (kill-new (if before-p
                      (string-append string cur)
                      (string-append cur string))
                  #t)))

    (define (current-kill n . args)
      ;; GNU Emacs's `current-kill': the Nth kill counting back from the
      ;; yank pointer, which is moved to it unless DO-NOT-MOVE says not
      ;; to. `(current-kill 0)' is "the latest kill".
      ;;
      ;; The ring maths is Emacs's: the pointer is a tail, and
      ;; `(mod (- n (length pointer)) (length ring))' turns "N back from
      ;; the pointer" into a distance from the front of the list. The
      ;; arithmetic wraps, which is what makes M-y keep going round.
      ;;
      ;; A kill with N zero asks the window system first: if another
      ;; program has provided text since Emacs last looked
      ;; (`interprogram-paste-function'), that text becomes the latest
      ;; kill and is what is yanked.
      ;;--------------------------------------------------------------
      (let ((do-not-move (if (pair? args) (car args) #f)))
        (let ((interprogram-paste (and (= n 0)
                                       (*interprogram-paste-function*)
                                       ((*interprogram-paste-function*)))))
          (if interprogram-paste
              (begin
                ;; Disable the interprogram cut function when we add the
                ;; new text to the kill ring, so Emacs doesn't try to own
                ;; the selection, with identical text. Also disable the
                ;; interprogram paste function, so that `kill-new'
                ;; doesn't call it repeatedly.
                (parameterize ((*interprogram-cut-function* #f)
                               (*interprogram-paste-function* #f))
                  ;; Emacs's `(listp interprogram-paste)': the function
                  ;; may answer a list of strings, the first of which is
                  ;; the paste and the rest of which join the ring.
                  (if (pair? interprogram-paste)
                      ;; Use `reverse' to avoid modifying external data.
                      (for-each kill-new (reverse interprogram-paste))
                      (kill-new interprogram-paste)))
                (car (*kill-ring*)))
              (begin
                ;; Emacs's `(or kill-ring (error ...))': `'()' is true in Scheme, so
                ;; the test has to be `pair?' - the empty ring signals
                ;; "Kill ring is empty" and nothing else reaches the
                ;; `modulo' below.
                (or (pair? (*kill-ring*)) (error "Kill ring is empty"))
                (let ((element
                       (nthcdr (modulo (- n (length (*kill-ring-yank-pointer*)))
                                       (length (*kill-ring*)))
                               (*kill-ring*))))
                  (unless do-not-move
                    (*kill-ring-yank-pointer* element)
                    (when (and (*yank-pop-change-selection*)
                               (> n 0)
                               (*interprogram-cut-function*))
                      ((*interprogram-cut-function*) (car element))))
                  (car element)))))))

    (define (kill-region-arguments)
      ;; The BEG and END the region commands work on, in Emacs's order:
      ;; the mark first, then point - "Pass mark first, then point,
      ;; because the order matters when calling `kill-append'". It is
      ;; Emacs's interactive form, which asks for the region and answers
      ;; #f when there is no mark to make one from.
      ;;
      ;; An *empty* region is not a mistake: GNU Emacs's `C-w' with point
      ;; on the mark puts the empty string in the kill ring and does
      ;; nothing else, which is worth knowing before "why did my kill ring
      ;; stop pasting?".
      ;;--------------------------------------------------------------
      (let ((mark (mark #f)))   ; signals when the mark is not active
        (and mark
             (list mark (text-editor-get-cursor (current-buffer))))))

    (define-command (kill-region beg end)
      ;; GNU Emacs's `kill-region' (simple.el:5999): "Kill the text
      ;; between BEG and END and put it in the kill ring" - which is
      ;; Emacs's own signature, `(defun kill-region (beg end &optional
      ;; region) ...)' with the interactive spec `(r)'; the earlier
      ;; zero-argument port read the region itself. A kill that runs
      ;; into a read-only buffer does not lose the text: Emacs copies
      ;; it to the ring and then signals, so that the killing commands
      ;; can be used to *copy* out of a read-only buffer - and
      ;; `kill-read-only-ok' turns the signal into a message.
      "Kill (cut) the text between point and mark."
      (interactive (list (region-beginning) (region-end)))
           (let* ((beg (- beg 1))
                  (end (- end 1))
                      (string (text-editor-copy-string (current-buffer) beg end))
                      (read-only? (text-editor-read-only? (current-buffer))))
                 ;; The ring takes the text first, as in Emacs, so that a
                 ;; read-only buffer still gives up its text.
                 (if (and (not read-only?)
                          (eq? (*last-command*) kill-region))
                     (kill-append string (< end beg))
                     (kill-new string))
                 (*this-command* kill-region)
                 (set!text-editor-deactivate-mark! (current-buffer) #t)
                (if read-only?
                    (unless (*kill-read-only-ok*)
                      (error "Buffer is read-only"))
                    (delete-region beg end))))

    (define (copy-region-as-kill beg end)
      ;; GNU Emacs's `copy-region-as-kill': put the text in the kill ring
      ;; without deleting it. The appending rule is the kill one, so M-w
      ;; after a kill extends that kill rather than starting a new entry.
      ;;--------------------------------------------------------------
      (let ((string (text-editor-copy-string (current-buffer) beg end)))
        (if (eq? (*last-command*) kill-region)
            (kill-append string (< end beg))
            (kill-new string))
        ;; M-w does *not* rename itself: Emacs's `copy-region-as-kill' has
        ;; no `(setq this-command ...)', so copying twice makes two
        ;; entries where killing twice makes one.
        (set!text-editor-deactivate-mark! (current-buffer) #t)))

    (define-command (kill-ring-save)
      ;; GNU Emacs's `kill-ring-save' (M-w), which is `copy-region-as-kill'
      ;; with a moment of visual feedback - Emacs's
      ;; `indicate-copied-region', which blinks the other end of the
      ;; region. There is no blink here, so it is the copy alone.
      "Save the region as if killed, but don't kill it."
      (interactive)
      (let ((args (kill-region-arguments)))
        (if (not args)
            (error "The mark is not set now, so there is no region")
            (copy-region-as-kill (car args) (cadr args)))))

    (define-command (yank arg)
      ;; GNU Emacs's `yank' (C-y): insert the most recent kill at point,
      ;; put point after it, and set the mark at the beginning of it
      ;; **without activating it** - which is what `yank-pop' then uses to
      ;; find the text it is to replace.
      ;;
      ;; With no argument it is `(current-kill 0)'; with a prefix argument
      ;; it is the Nth kill back, and with `C-u' - the raw argument that
      ;; is not an integer - it is also 0, but point and mark end up the
      ;; *other* way round, so that the command repeated with C-u walks
      ;; back through the ring.
      ;;
      ;; Emacs inserts through `insert-for-yank', which honours the
      ;; `yank-handler' text property and `yank-excluded-properties';
      ;; there are no text properties on a yank here yet.
      "Reinsert (paste) the last stretch of killed text."
      (interactive "P")
      ;; `(cond ((listp arg) 0) ((eq arg '-) -2) (t (1- arg)))' in
      ;; Emacs: a bare `C-u' is the latest kill, `M-- C-y' is the one
      ;; *before* the latest - which is -2 because `current-kill'
      ;; counts back from the yank pointer, and the pointer has already
      ;; moved to the latest - and a number is that many kills back.
      (let ((n (cond ((not arg) 0)
                     ((pair? arg) 0)
                     ((eq? '- arg) -2)
                     (else (- arg 1))))
            (ed (current-buffer)))
        (push-mark)
        (text-editor-insert ed (current-kill n))
        ;; `C-u C-y' leaves point *before* what it inserted and the
        ;; mark after it, which is like `exchange-point-and-mark' but
        ;; does not activate the mark. Emacs asks `(consp arg)' - a
        ;; bare `C-u' - and that is what the list is for.
        (when (pair? arg)
          (let ((was (mark #t)))
            (set!text-editor-mark ed (text-editor-get-cursor ed))
            (text-editor-set-cursor ed was))))
      ;; "If we do get all the way thru, make this-command indicate
      ;; that" - which is what `yank-pop' asks about, and what makes a
      ;; run of M-y possible.
      (*this-command* yank))

    (define-command (yank-pop count)
      ;; GNU Emacs's `yank-pop' (M-y): replace what the last yank inserted
      ;; with an older kill. It deletes the text between point and the
      ;; mark - which `yank' left at the beginning of what it inserted -
      ;; and inserts the next kill back in the ring.
      ;;
      ;; Emacs 31's `yank-pop' does something else when the command before
      ;; it was not a yank: it reads a kill out of the ring in the
      ;; minibuffer (`yank-from-kill-ring'). That needs the minibuffer,
      ;; which imports *this* library, so it is not here - and the older
      ;; Emacs behaviour is, which is to say so.
      "Replace the just-yanked text with an older kill."
      (interactive "p")
      (if (not (eq? (*last-command*) yank))
          (error "Previous command was not a yank")
          (let* ((ed (current-buffer))
                 (before (< (text-editor-get-cursor ed) (mark #t)))
                 (beg (if before (text-editor-get-cursor ed) (mark #t)))
                 (end (if before (mark #t) (text-editor-get-cursor ed))))
            (delete-region beg end)
            (set!text-editor-mark ed (text-editor-get-cursor ed))
            (text-editor-insert ed (current-kill count))
            ;; ... and it says `yank' as well, so the *next* M-y still
            ;; looks like one and the ring may be gone round and round.
            (*this-command* yank))))

    ;; Undo
    ;;
    ;; The undo list itself is a property of the buffer and lives in the
    ;; engine, which is where GNU Emacs keeps `buffer-undo-list' and
    ;; where the insert and delete primitives record into it. What the
    ;; command loop owes it is the grouping: a boundary in the list
    ;; before each command, so that one undo undoes one command.
    ;;
    ;; The other half is `pending-undo-list', which Emacs keeps as a
    ;; buffer-local variable but maintains from the command loop: it is
    ;; the tail of the undo list that a run of undo commands is walking,
    ;; saved so that the records the undo itself creates (which go to
    ;; the front of the undo list, and are the redo records) do not
    ;; interfere with continuing the run.
    ;;------------------------------------------------------------------

    (define *last-command* (make-parameter #f))
    (define *amalgamating-count* (make-parameter 0))
    (define *pending-undo-list* (make-parameter #f))
    (define *last-change-was-undo* (make-parameter #f))

    (define *amalgamating-undo-limit* (make-parameter 20))

    (define (amalgamating-command? action)
      ;; Commands whose runs are amalgamated into a single undo step, so
      ;; that undoing after typing a word removes the whole word rather
      ;; than its last character. These are the commands that call GNU
      ;; Emacs's `undo-auto-amalgamate'.
      ;;--------------------------------------------------------------
      (or (eq? action self-insert-command)
          (eq? action delete-char)))

    (define (place-undo-boundary! action)
      ;; Emacs's command loop calls `undo-boundary' before each key
      ;; sequence, so that each command is one undo step. A command that
      ;; amalgamates keeps adding to the current step instead, until
      ;; `amalgamating-undo-limit' of them have run in a row (Emacs
      ;; removes the previous boundary rather than never placing one;
      ;; the effect is the same).
      ;;--------------------------------------------------------------
      (if (and (amalgamating-command? action)
               (eq? action (*last-command*))
               (< (*amalgamating-count*) (*amalgamating-undo-limit*)))
          (*amalgamating-count* (+ 1 (*amalgamating-count*)))
          (begin
            (text-editor-undo-boundary! (current-buffer))
            (*amalgamating-count* (if (amalgamating-command? action) 1 0)))))

    (define (strip-undo-boundaries list)
      ;; LIST without its leading boundaries. Emacs strips these before
      ;; walking a run of undos, since the command loop's boundary for
      ;; the undo command itself sits at the front and the first thing
      ;; an undo does is step over it ("get rid of initial undo
      ;; boundary").
      ;;--------------------------------------------------------------
      (let loop ((list list))
        (if (and (pair? list) (null? (car list))) (loop (cdr list)) list)))

    (define-command (undo count)
      ;; GNU Emacs's `undo'. Repeating it undoes further back, and when
      ;; it reaches the end of the undo list the next one reports that
      ;; there is nothing left.
      "Undo some previous changes."
      (interactive "p")
      (let* ((frame (*current-frame*))
             (ed (current-buffer))
             (pending
              (if (eq? (*last-command*) undo)
                  ;; continue the run
                  (*pending-undo-list*)
                  ;; start a new run, from the front of the list
                  (strip-undo-boundaries (text-editor-undo-list ed)))))
        (if (not (list? pending))
            (set!frame-message frame "No further undo information")
            (let ((rest (text-editor-undo ed pending count)))
              ;; Emacs sets `pending-undo-list' to t once the run has
              ;; reached the end; false is that state here, and it is
              ;; what makes the next undo report that it is finished.
              (*pending-undo-list* (if (null? rest) #f rest))
              (*last-change-was-undo* #t)
              (set!frame-message frame "Undo")))))

    (define-command (undo-redo count)
      ;; GNU Emacs's `undo-redo': undo the undos. The records an undo
      ;; created are ordinary undo entries sitting at the front of the
      ;; list, so redoing one is undoing it - that is the whole of the
      ;; redo mechanism, and why there is no redo list.
      "Redo the last undone change, or the last COUNT undone changes."
      (interactive "p")
      (let ((frame (*current-frame*)))
        (if (not (*last-change-was-undo*))
            (set!frame-message frame "No undone changes to redo")
            (let* ((ed (current-buffer))
                   (list (strip-undo-boundaries
                          (text-editor-undo-list ed))))
              (if (not (pair? list))
                  (set!frame-message
                   frame "No undone changes to redo")
                  (begin
                    (text-editor-undo ed list count)
                    (*last-change-was-undo* #t)
                    (set!frame-message frame "Redo")))))))

    ;;----------------------------------------------------------------
    ;; Prefix arguments
    ;;
    ;; The raw argument conventions of GNU Emacs and mg: C-u pressed
    ;; N times means the count 4^N (C-u = 4, C-u C-u = 16); digits
    ;; typed after C-u build a number which replaces the C-u count
    ;; (C-u 7 = 7, C-u 7 2 = 72). A command without digits after C-u
    ;; receives 4^N.
    ;;
    ;; The prefix is *pending* state, not a value captured per key
    ;; event: it survives the intermediate keys of a key chord, so that
    ;; C-u C-x C-s hands the argument to whichever command the chord
    ;; finally names, and it is consumed only when a command actually
    ;; runs (`dispatch-action'). This is what GNU Emacs's command loop
    ;; does, where `prefix-arg' is bound before the whole key sequence
    ;; for the command is read.
    ;;------------------------------------------------------------------

    (define *prefix-cu* (make-parameter #f))
    (define *prefix-digits* (make-parameter #f))
    ;; Whether the argument is negative. GNU Emacs carries this in the
    ;; *value* - `prefix-arg' may be the symbol `-' - which a string of
    ;; digits cannot spell, so it is a field of its own here. `M--' with
    ;; nothing after it leaves `pending-uarg' answering `-', the symbol
    ;; Emacs answers, and `M-- 5' answers -5.
    (define *prefix-negative* (make-parameter #f))

    (define (clear-prefix!)
      (*prefix-cu* #f)
      (*prefix-digits* #f)
      (*prefix-negative* #f)
      ;; ... and the description is not owed any more: the argument it
      ;; described has been used or thrown away.
      (*prefix-echo-due* #f))

    (define (pending-uarg)
      ;; The universal argument the next command will receive: #f when
      ;; no prefix was typed, the symbol `-' for a bare `M--', 4^N after
      ;; N presses of C-u, or the number typed after C-u. Commands that
      ;; declare the `uarg' interactive spec receive this raw value and
      ;; convert it with `uarg->integer', the way GNU Emacs's
      ;; `(interactive "p")' does.
      ;;--------------------------------------------------------------
      (cond
       ((and (not (*prefix-cu*)) (not (*prefix-digits*)))
        (and (*prefix-negative*) '-))
       ;; A bare `C-u' - one with no digits after it - is a *list* of one
       ;; number, which is GNU Emacs's raw value for it: `universal-argument'
       ;; sets `prefix-arg' to `(list 4)'. That is not a detail: it is how a
       ;; command tells `C-u' from `C-u 4', and commands do ask - `yank' takes
       ;; the latest kill for the list and the Nth for the number, and
       ;; `set-mark-command' only pops the mark ring for `C-u C-u', which is
       ;; the list `(16)'. `uarg->integer' reads the number out of it, so
       ;; everything that only wants a count is unaffected.
       ((not (*prefix-digits*))
        (list (* (if (*prefix-negative*) -1 1) (expt 4 (*prefix-cu*)))))
       (else
        (* (if (*prefix-negative*) -1 1)
           (string->number (*prefix-digits*))))))

    (define (update-prefix! path)
      ;; Handle C-u and digit key events while a prefix is pending.
      ;; Returns #t when the event was consumed as part of the prefix.
      ;;--------------------------------------------------------------
      (cond
       ((and (= (length path) 2)
             (eq? (car path) 'ctrl)
             (char=? (cadr path) #\u))
        (*prefix-cu* (+ 1 (or (*prefix-cu*) 0)))
        (request-prefix-echo!)
        #t)
       ((and (*prefix-cu*)
             ;; Only while the prefix itself is being read. GNU Emacs
             ;; reads its digits through `universal-argument-map', which
             ;; is a transient keymap: a key that starts a chord - the
             ;; C of C-x - leaves it, and the keys of the chord are the
             ;; chord's, digits included. Without this the 2 of
             ;; `C-u 8 C-x 2' was taken as another digit of the prefix,
             ;; so the chord never completed and the argument became 82.
             (not (frame-keymap-state (*current-frame*)))
             (= (length path) 1)
             (char? (car path))
             (char-numeric? (car path)))
        (*prefix-digits*
         (string-append (or (*prefix-digits*) "") (string (car path))))
        (request-prefix-echo!)
        #t)
       (else #f)))

    (define *echo-keystrokes*
      ;; GNU Emacs's `echo-keystrokes': how long the keyboard must be
      ;; idle, in the middle of a command, before what has been typed so
      ;; far is echoed - the prefix argument with it.
      ;;
      ;; Emacs's default is one second, and the waiting is `read_char''s
      ;; `sit_for': type on and nothing is echoed at all. That is why
      ;; `M-6' shows nothing in Emacs: the digit argument *is* echoed,
      ;; but only to someone who stops typing after it.
      ;;--------------------------------------------------------------
      (make-parameter 1))

    (define *prefix-echo-due* (make-parameter #f))
    ;; ^ When the prefix argument should be described in the echo area,
    ;; or #f when there is nothing to describe or it has been described.
    ;; The command loop watches this the same way it watches a message
    ;; that times out.

    (define (request-prefix-echo!)
      ;; The prefix was just changed, so its description is owed to the
      ;; echo area once the keyboard has been idle for `echo-keystrokes'.
      ;;--------------------------------------------------------------
      (*prefix-echo-due*
       (and (*echo-keystrokes*) (+ (current-second) (*echo-keystrokes*)))))

    (define (prefix-echo-pending?)
      ;; Whether a prefix description is waiting for the keyboard to go
      ;; quiet.
      ;;--------------------------------------------------------------
      (*prefix-echo-due*))

    (define (prefix-argument-description)
      ;; GNU Emacs's `universal-argument--description': what the echo
      ;; area says about the argument being typed, or #f when there is
      ;; none. It always begins `C-u', whatever key began the argument -
      ;; `M-6' included, which is why an argument typed with a digit is
      ;; echoed as `C-u 6'.
      ;;--------------------------------------------------------------
      (let ((uarg (pending-uarg)))
        (cond
         ((not uarg) #f)
         ((eq? '- uarg) "C-u -")
         ;; Emacs's `pcase' has a clause for the *list* - `(4)' for `C-u',
         ;; `(16)' for `C-u C-u' - and it describes it as the number it
         ;; holds describes itself.
         ((pair? uarg) (prefix-argument-description-of (car uarg)))
         ((integer? uarg) (prefix-argument-description-of uarg))
         (else (string-append "C-u " (number->string uarg))))))

    (define (prefix-argument-description-of n)
      ;; What an argument of N is described as: `C-u' repeated as many
      ;; times as N divides by 4, and N itself when it does not divide
      ;; cleanly. Emacs writes this loop twice, once for the number and
      ;; once inside its list clause; here it is one procedure.
      ;;--------------------------------------------------------------
      (let loop ((n n) (str ""))
        (cond
         ((and (> n 4) (= 0 (modulo n 4)))
          (loop (quotient n 4) (string-append str " C-u")))
         ((= n 4) (string-append "C-u" str))
         (else (string-append "C-u " (number->string n))))))

    (define (show-prefix-echo!)
      ;; Describe the prefix argument, if its time has come: the echo
      ;; area's half of `prefix-command-echo-keystrokes-functions', which
      ;; GNU Emacs's `read_char' calls once `sit_for' has waited out
      ;; `echo-keystrokes'.
      ;;
      ;; Only in the ordinary way of things, though: Emacs's `read_char'
      ;; starts that echo "if in middle of key sequence and minibuffer
      ;; not active" - `minibuf_level == 0' in the C - and the prefix
      ;; description is part of the same echo. So nothing at all is said
      ;; about the argument while a minibuffer is being read, which is
      ;; what makes `M-6' silent at a `C-x C-f' prompt and is the reason
      ;; it is silent there: the echo area *is* the minibuffer, and what
      ;; it is showing is the answer being typed.
      ;;--------------------------------------------------------------
      (let ((due (*prefix-echo-due*)))
        (when (and due (<= due (current-second)))
          (*prefix-echo-due* #f)
          (when (not (*echo-area-buffer*))
            (let ((description (prefix-argument-description)))
              (when description
                (set!frame-message (*current-frame*) description)))))))

    (define (last-command-event-digit)
      ;; The digit the key that reached this command spelled, or #f.
      ;; GNU Emacs's `digit-argument' reads it from
      ;; `last-command-event', masking the modifier bits off with
      ;; `(logand char ?\177)'. The key is re-derived here from the
      ;; frame's keymap lookup state, the way `self-insert-command'
      ;; re-derives its character - and the modifier bits are the
      ;; other elements of the chord, so nothing has to be masked.
      ;;--------------------------------------------------------------
      (let* ((state (frame-keymap-state (*current-frame*)))
             (ix (and state (km:modal-lookup-state-key-index state)))
             (path (and ix (km:keymap-index->list ix)))
             (last (and (pair? path) (car (reverse path)))))
        (and (char? last)
             (char-numeric? last)
             (- (char->integer last) (char->integer #\0)))))

    (define-command (digit-argument uarg)
      ;; GNU Emacs's `digit-argument': a digit typed with Meta adds
      ;; itself to the numeric argument for the next command.
      ;; `M-3 M-5 C-n' moves down thirty-five lines.
      ;;
      ;; It is a command and not part of `UPDATE-PREFIX!', because in
      ;; Emacs it is one: `esc-map' binds M-0 to M-9 to it, which is why
      ;; M-6 is not an undefined key there. What it receives is the raw
      ;; prefix argument, since `M-3 M-5' has to build on `M-3' rather
      ;; than start again.
      "Add the digit of this key to the numeric argument for the next command."
      (interactive "P")
         (let ((digit (or (last-command-event-digit) 0)))
           ;; digits replace a C-u count rather than multiplying it, as
           ;; Emacs's `universal-argument' does with `M-6' after `C-u'
           (*prefix-cu* #f)
           (cond
            ((integer? uarg)
             (let ((value (+ (* uarg 10)
                             (if (< uarg 0) (- digit) digit))))
               (*prefix-negative* (< value 0))
               (*prefix-digits* (number->string (abs value)))))
            ((eq? '- uarg)
             ;; Treat -0 as just -, so that -01 will work.
             (*prefix-negative* #t)
             (unless (zero? digit)
               (*prefix-digits* (number->string digit))))
            (else
             (*prefix-negative* #f)
             (*prefix-digits* (number->string digit))))
          (request-prefix-echo!)))

    (define-command (negative-argument uarg)
      ;; GNU Emacs's `negative-argument': M-- begins a negative numeric
      ;; argument, and a second M-- cancels it.
      "Begin a negative numeric argument for the next command."
      (interactive "P")
      (cond ((integer? uarg) (*prefix-negative* (not (< uarg 0))))
            ((eq? '- uarg) (*prefix-negative* #f))
            (else (*prefix-negative* #t)))
      (request-prefix-echo!))

    ;;----------------------------------------------------------------
    ;; The mark and the region
    ;;
    ;; GNU Emacs's banner of the same name in simple.el. The mark is a
    ;; *marker* the engine keeps on the buffer (buffer.c's `BVAR (b,
    ;; mark)'), and the region is what it makes with point - "the closest
    ;; equivalent in Emacs to what some editors call the selection".
    ;;
    ;; What is *not* here is the state these work on, because Emacs
    ;; declares it elsewhere and so does this: `transient-mark-mode' and
    ;; `mark-active' are `buffer.c''s variables and live in
    ;; `(schemacs editor buffer)', `mark-even-if-inactive' is
    ;; `callint.c''s and lives in `(schemacs editor command)',
    ;; `region-beginning' and `region-end' are `editfns.c''s and live in
    ;; `(schemacs editor editfns)', and `add-to-history' is `subr.el''s
    ;; and lives in `(schemacs editor subr)'.

    (define *use-empty-active-region*
      ;; GNU Emacs's `use-empty-active-region': whether an *empty*
      ;; active region is worth acting on. Off, as in Emacs, so a
      ;; command that would act on the region does not when point and
      ;; mark are in the same place.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (mark . args)
      ;; GNU Emacs's `(mark)': where this buffer's mark is, or #f when it
      ;; has never been set. In Transient Mark mode it *signals* when the
      ;; mark is not active, unless `mark-even-if-inactive' says
      ;; otherwise or FORCE is passed - which is why `(mark t)' is the
      ;; spelling most callers use.
      ;;--------------------------------------------------------------
      (let ((force (if (pair? args) (car args) #f)))
        (if (or force (not (transient-mark-mode))
                (mark-active) (*mark-even-if-inactive*))
            (text-editor-mark (current-buffer))
            (error "The mark is not active now"))))

    (define (set-mark position)
      ;; GNU Emacs's `set-mark': put the mark at POSITION and activate
      ;; it, or - given #f - clear it and deactivate. Emacs's docstring
      ;; warns callers off it: "Normally, when a new mark is set, the old
      ;; one should go on the stack. This is why most applications should
      ;; use `push-mark', not `set-mark'."
      ;;--------------------------------------------------------------
      (if position
          (begin
            (set!text-editor-mark (current-buffer) position)
            (activate-mark 'no-tmm))
          (begin
            ;; "Normally we never clear mark-active except in Transient
            ;; Mark mode. But when we actually clear out the mark value
            ;; too, we must clear mark-active in any mode."
            (deactivate-mark #t)
            (set!mark-active #f)
            (set!text-editor-mark (current-buffer) #f))))

    (define (region-active-p)
      ;; GNU Emacs's `region-active-p': Transient Mark mode is on and the
      ;; mark is active. Emacs asserts that the mark is set as well -
      ;; "somehow we sometimes end up with mark-active non-nil but
      ;; without the mark being set (bug#17324)" - and so does this.
      ;;--------------------------------------------------------------
      (and (transient-mark-mode) (mark-active) (mark #t) #t))

    (define (use-region-p)
      ;; GNU Emacs's `use-region-p': the region is active *and* worth
      ;; acting on, which is what the commands that act on it ask. An
      ;; empty region is not, unless `use-empty-active-region' says so.
      ;; (Emacs's mouse-1 caveat is about a mouse there is not one of.)
      ;;--------------------------------------------------------------
      (and (region-active-p)
           (or (< (region-beginning) (region-end))
               (*use-empty-active-region*))))

    (define *activate-mark-hook* (make-parameter '()))
    (define *deactivate-mark-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `activate-mark-hook' and `deactivate-mark-hook'.

    (define (activate-mark . args)
      ;; GNU Emacs's `activate-mark': set `mark-active', and - unless the
      ;; caller says not to touch it - turn Transient Mark mode on for
      ;; this one command if it is off.
      ;;
      ;; "No-TMM" is Emacs's name for the second argument; here it is the
      ;; first, since the only caller that passes it is `set-mark'.
      ;;--------------------------------------------------------------
      (let ((no-tmm (if (pair? args) (car args) #f)))
        (when (mark #t)
          (unless (region-active-p)
            (set!mark-active #t)
            (unless (or (transient-mark-mode) no-tmm)
              (set-buffer-local-value! (current-buffer)
                                       'transient-mark-mode 'lambda))
            (for-each (lambda (hook) (hook)) (*activate-mark-hook*))))))

    (define (deactivate-mark . args)
      ;; GNU Emacs's `deactivate-mark': make the mark inactive and run
      ;; the hook. FORCE does it even when the region was not active,
      ;; which is what `set-mark' with no position needs.
      ;;
      ;; Deactivation also updates the primary selection according to
      ;; `select-active-regions' - `simple.el:7084'. The var
      ;; `saved-region-selection', if non-nil, is the text in the region
      ;; prior to the last command modifying the buffer (`gui-select-text'
      ;; saves it, as insdel.c does before a modification): set the
      ;; selection to that, or to the current region. If another program
      ;; has acquired the selection, region deactivation should not
      ;; clobber it (Bug#11772), which is what the ownership questions in
      ;; the second branch ask.
      ;;
      ;; Not ported: the check of the `deactivate-mark' *variable*'s
      ;; `dont-save' value - the variable is the C command loop's flag,
      ;; which this tree's loop applies itself - and
      ;; `redisplay--update-region-highlight', the redraw being the
      ;; command loop's here. `select-active-regions''s obsolete `only'
      ;; value is not ported either; the temporary Transient Mark mode
      ;; this tree knows is `lambda'.
      ;;--------------------------------------------------------------
      (let ((force (if (pair? args) (car args) #f)))
        (when (or (region-active-p) force)
          (when (and (*select-active-regions*)
                     (region-active-p)
                     (display-selections-p))
            (cond ((*saved-region-selection*)
                   (if (gui-backend-selection-owner-p 'PRIMARY)
                       (gui-set-selection 'PRIMARY (*saved-region-selection*)))
                   (*saved-region-selection* #f))
                  ((and (not (= (region-beginning) (region-end)))
                        (or (gui-backend-selection-owner-p 'PRIMARY)
                            (not (gui-backend-selection-exists-p 'PRIMARY))))
                   ;; `region-extract-function''s default for a nil
                   ;; METHOD is the region's text (`simple.el:1452');
                   ;; there is no `filter-buffer-substring' here. The
                   ;; region answers are one-based, the engine's copy
                   ;; zero-based - the conversion at the edge.
                   (gui-set-selection 'PRIMARY
                                      (text-editor-copy-string
                                       (current-buffer)
                                       (- (region-beginning) 1)
                                       (- (region-end) 1))))))
          ;; a temporarily-enabled Transient Mark mode goes back to what
          ;; it was
          (when (eq? (buffer-local-value (current-buffer)
                                         'transient-mark-mode #f)
                     'lambda)
            (set-buffer-local-value! (current-buffer) 'transient-mark-mode #f))
          (set!mark-active #f)
          (for-each (lambda (hook) (hook)) (*deactivate-mark-hook*)))))

    (define *mark-ring-max* (make-parameter 16))
    ;; ^ GNU Emacs's `mark-ring-max': "Maximum size of mark ring."

    (define (mark-ring)
      ;; The buffer's own mark ring, most recent first: GNU Emacs's
      ;; `mark-ring', which is buffer-local.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'mark-ring '()))

    (define (set!mark-ring entries)
      (set-buffer-local-value! (current-buffer) 'mark-ring entries))

    (define (push-mark . args)
      ;; GNU Emacs's `push-mark': put the mark where LOCATION says (point
      ;; by default), pushing the old mark onto the buffer's mark ring,
      ;; and say "Mark set" unless NOMSG.
      ;;
      ;; The third argument ACTIVATE is Emacs's: the mark is activated
      ;; when it is passed, and - when Transient Mark mode is *off* -
      ;; always, since with no transient mark there is nothing for
      ;; activation to do but the region is still worth having.
      ;;--------------------------------------------------------------
      (let ((location (if (pair? args) (car args) #f))
            (nomsg (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
            (activate (if (and (pair? args) (pair? (cdr args))
                               (pair? (cddr args)))
                          (caddr args)
                          #f)))
        (when (mark #t)
          (set!mark-ring
           (add-to-history (mark-ring)
                           (copy-marker (current-buffer)
                                        (text-editor-mark (current-buffer)))
                           (*mark-ring-max*) #t)))
        (set!text-editor-mark (current-buffer)
                              (or location (text-editor-get-cursor
                                            (current-buffer))))
        (unless (or nomsg (*echo-area-buffer*))
          (set!frame-message (*current-frame*) "Mark set"))
        (when (or activate (not (transient-mark-mode)))
          (set-mark (mark #t)))
        #f))

    (define (pop-mark)
      ;; GNU Emacs's `pop-mark': take the last mark off the ring and make
      ;; it the mark, "does not set point", and deactivate.
      ;;--------------------------------------------------------------
      (let ((ring (mark-ring)))
        (when (pair? ring)
          (set!mark-ring
           (append (cdr ring)
                   (list (copy-marker (current-buffer)
                                      (text-editor-mark (current-buffer))))))
          (set!text-editor-mark (current-buffer)
                                (marker-position (car ring)))
          (set-marker! (car ring) #f (current-buffer))))
      (deactivate-mark))

    (define (push-mark-command arg nomsg)
      ;; GNU Emacs's `push-mark-command': set the mark at point, or - if
      ;; it is already there and no prefix argument was given - just
      ;; activate it.
      ;;--------------------------------------------------------------
      (let ((here (mark #t))
            (point (text-editor-get-cursor (current-buffer))))
        (if (or arg (not here) (not (= here point)))
            (push-mark #f nomsg #t)
            (begin
              (activate-mark 'no-tmm)
              (unless nomsg
                (set!frame-message (*current-frame*)
                                           "Mark activated"))))))

    (define (pop-to-mark-command)
      ;; GNU Emacs's `pop-to-mark-command': jump to the mark, and put a
      ;; new one - off the ring - where it was.
      ;;--------------------------------------------------------------
      (if (not (mark #t))
          (error "No mark set in this buffer")
          (begin
            (when (= (text-editor-get-cursor (current-buffer)) (mark #t))
              (set!frame-message (*current-frame*) "Mark popped"))
            (text-editor-set-cursor (current-buffer) (mark #t))
            (pop-mark))))

    (define-command (set-mark-command arg)
      ;; GNU Emacs's `set-mark-command' (C-SPC, and C-@, which is the
      ;; same key): set the mark where point is and activate it, or - with
      ;; a prefix argument - jump to the mark and pop a new one off the
      ;; ring.
      ;;
      ;; The rest of Emacs's version is about `set-mark-command-repeat-pop'
      ;; and the global mark ring, neither of which is here yet; what is
      ;; here is the part C-SPC needs. Repeating C-SPC on an active region
      ;; deactivates it, which is how the same key turns the region off.
      "Set the mark where point is, and activate it; or jump to the mark."
      (interactive "P")
         ;; Emacs's `cond', clause for clause, less the two that are
         ;; about `set-mark-command-repeat-pop' and the global mark ring.
         ;; (`C-u C-u' is the raw argument 16 here rather than a cons,
         ;; because a repeated C-u counts up instead of making one.)
         (cond
          ;; `(and (consp arg) (> (prefix-numeric-value arg) 4))' in
          ;; Emacs: only `C-u C-u' sets the mark here unconditionally.
          ((and (pair? arg) (> (car arg) 4)) (push-mark-command #f #f))
          ((not (eq? (*last-command*) set-mark-command))
           (if arg (pop-to-mark-command) (push-mark-command #t #f)))
          (arg (pop-to-mark-command))
          ((region-active-p)
           (deactivate-mark)
           (set!frame-message (*current-frame*) "Mark deactivated"))
          (else
           (activate-mark)
           (set!frame-message (*current-frame*) "Mark activated"))))

    (define-command (mark-whole-buffer)
      ;; GNU Emacs's `mark-whole-buffer' (C-x h): point at the beginning
      ;; and the mark at the end, with the old mark pushed first.
      ;;
      ;; Emacs goes to `minibuffer-prompt-end' rather than to the start of
      ;; the buffer; the prompt is not in the buffer here, so the two are
      ;; the same.
      "Put point at beginning and mark at end of buffer."
      (interactive)
      (push-mark)
      (push-mark (text-editor-char-count (current-buffer)) #f #t)
      (text-editor-set-cursor (current-buffer) 0))

    ;;----------------------------------------------------------------
    ;; The keys GNU Emacs binds these commands to
    ;;
    ;; simple.el states them beside the commands, with
    ;; `(define-key global-map ...)', and this is the same: the binding for
    ;; `forward-char' is written where `forward-char' is defined rather than
    ;; in one list of every binding in the editor. It is a load-time side
    ;; effect, which is what makes it right - the binding exists once the
    ;; command does, and a library is loaded once however many times it is
    ;; imported.
    ;;------------------------------------------------------------------

    (define-key *default-keymap* (list (list 'ctrl #\f)) forward-char)
    (define-key *default-keymap* (list (list 'ctrl #\b)) backward-char)
    (define-key *default-keymap* (list (list 'ctrl #\n)) next-line)
    (define-key *default-keymap* (list (list 'ctrl #\p)) previous-line)
    (define-key *default-keymap* (list (list 'ctrl #\a)) beginning-of-line)
    (define-key *default-keymap* (list (list 'ctrl #\e)) end-of-line)
    (define-key *default-keymap* (list (list 'ctrl #\d)) delete-char)
    (define-key *default-keymap* (list (list 'ctrl #\h)) backward-delete-char)
    (define-key *default-keymap* (list (list 'ctrl #\k)) kill-line)
    (define-key *default-keymap* (list (list 'ctrl #\m)) insert-newline)
    (define-key *default-keymap* (list (list 'ctrl #\j)) insert-newline)
    (define-key *default-keymap* (list (list 'ctrl #\g)) keyboard-quit)
    ;; The mark. GNU Emacs binds this to TWO keys, and outside a terminal
    ;; they are not the same key at all - `bindings.el' has both lines:
    ;;
    ;;     (define-key global-map "\C-@" 'set-mark-command)
    ;;     (define-key global-map [?\C- ] 'set-mark-command)
    ;;
    ;; The first is the NUL byte. A terminal sends NUL for either key, so
    ;; there one binding serves; a *window system* sends a `space' keysym
    ;; with the control modifier for C-SPC and a `at' keysym for C-@, so
    ;; on GTK they are two separate events - and an editor with only the
    ;; first has a `set-mark-command' that silently does nothing when
    ;; C-SPC is pressed. That is what the GTK backend showed: the region
    ;; tests passed because they were driven with C-@.
    ;;
    ;; The event translation folds NUL to `C-@' (`term.sld'), which is
    ;; Emacs's own `(define-key function-key-map [?\C-@] [?\C-\s])' the
    ;; other way round - Emacs folds the terminal's byte *to* the window
    ;; system's spelling, and calls C-SPC the advertised binding.
    (define-key *default-keymap* (list (list 'ctrl #\@)) set-mark-command)
    (define-key *default-keymap* (list (list 'ctrl #\space)) set-mark-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\h) mark-whole-buffer)
    ;; The named keys a terminal sends for its arrow, home and end keys:
    ;; GNU Emacs binds these in `global-map' too, and to the same
    ;; commands as the control keys beside them. Keeping them separate
    ;; from those control keys is what leaves `M-<up>' free to be
    ;; `minibuffer-previous-completion' in a minibuffer.
    (define-key *default-keymap* (list (list "up")) previous-line)
    (define-key *default-keymap* (list (list "down")) next-line)
    (define-key *default-keymap* (list (list "left")) backward-char)
    (define-key *default-keymap* (list (list "right")) forward-char)
    (define-key *default-keymap* (list (list "home")) beginning-of-line)
    (define-key *default-keymap* (list (list "end")) end-of-line)
    (define-key *default-keymap* (list (list "delete")) delete-char)
    ;; PgUp and PgDn: `bindings.el:1418-1419' binds `[prior]' to
    ;; `scroll-down-command' and `[next]' to `scroll-up-command' - the
    ;; same two commands C-v and M-v run. Without them the keys were
    ;; unbound, and an unbound key was taken for a self-inserting
    ;; character, so in a read-only Dired buffer PgDn said only "Buffer is
    ;; read-only" and otherwise did nothing.
    (define-key *default-keymap* (list (list "prior")) scroll-down-command)
    (define-key *default-keymap* (list (list "next")) scroll-up-command)
    ;; Undo, on the keys GNU Emacs binds it to - and there are *four* of
    ;; them, not one, because the two front ends do not spell them alike.
    ;; `bindings.el:1237-1238' has
    ;;
    ;;     (define-key global-map [?\C-/] 'undo)
    ;;     (define-key global-map "\C-_" 'undo)
    ;;
    ;; - a *keysym* vector for C-/ and a *byte* string for C-_. In a
    ;; terminal they are the same byte (31) and one binding serves both;
    ;; in a window system they are two different events, so a binding
    ;; written as the byte leaves C-/ and C-_ dead. The undo-redo keys
    ;; are the same thing, `bindings.el:1247-1248': `[(control ??)]' is
    ;; C-? and `[?\C-\M-_]' is C-M-_.
    ;;
    ;; On a terminal C-? *is* DEL, which arrives as backspace, so it
    ;; cannot be bound there - the comment above this in the byte spelling
    ;; was a terminal's answer, not a general one.
    (define-key *default-keymap* (kbd "C-x u") undo)
    (define-key *default-keymap* (kbd "C-/") undo)
    (define-key *default-keymap* (kbd "C-_") undo)
    (define-key *default-keymap* (kbd "C-?") undo-redo)
    (define-key *default-keymap* (kbd "C-M-_") undo-redo)
    ;; and the byte spelling is what a terminal delivers for *both* C-/
    ;; and C-_, where a window system sends two different keysyms - which
    ;; is why Emacs's `bindings.el' has `\C-_' (the byte) as well as
    ;; `[?\C-/]' (the keysym), and why they are two bindings here and
    ;; not one: `kbd "C-_"' names the keysym, and the terminal's byte 31
    ;; is a different key that only the byte spelling reaches.
    (define-key *default-keymap*
      (list (list 'ctrl (integer->char 31))) undo)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 31))) undo-redo)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\u) undo)
    ;; `read-only-mode' is C-x C-q, which is where files.el:9330 binds
    ;; it; `C-x q' is kbd-macro-query's key in Emacs, which is not
    ;; ported.
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\q))
      read-only-mode)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\x))
      exchange-point-and-mark)
    (define-key *default-keymap* (list (list 'ctrl #\i)) self-insert-tab)
    (define-key *default-keymap* (list (list 'ctrl #\v)) scroll-up-command)
    (define-key *default-keymap* (list (list 'meta #\v)) scroll-down-command)
    (define-key *default-keymap* (list (list 'meta #\<)) beginning-of-buffer)
    (define-key *default-keymap* (list (list 'meta #\>)) end-of-buffer)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 28))) beginning-of-buffer)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 30))) end-of-buffer)
    ;; The numeric argument, on every key GNU Emacs binds it to:
    ;; `bindings.el' puts `digit-argument' on M-0 to M-9, on C-0 to C-9
    ;; and on C-M-0 to C-M-9, and `negative-argument' on M--, C-- and
    ;; C-M--. C-u is not bound because it never reaches the keymap -
    ;; `UPDATE-PREFIX!' consumes it first, as Emacs's
    ;; `universal-argument-map' does.
    (let loop ((i 0))
      (when (<= i 9)
        (let ((digit (integer->char (+ (char->integer #\0) i))))
          (define-key *default-keymap* (list (list 'meta digit)) digit-argument)
          (define-key *default-keymap*
            (list (list 'ctrl digit)) digit-argument)
          (define-key *default-keymap*
            (list (list 'meta 'ctrl digit)) digit-argument))
        (loop (+ 1 i))))
    (define-key *default-keymap* (list (list 'meta #\-)) negative-argument)
    (define-key *default-keymap* (list (list 'ctrl #\-)) negative-argument)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl #\-)) negative-argument)
    (define-key *default-keymap* (list (list 'meta #\f)) forward-word)
    (define-key *default-keymap* (list (list 'meta #\b)) backward-word)
    (define-key *default-keymap* (list (list 'meta #\d)) kill-word)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl #\h)) backward-kill-word)
        (define-key *default-keymap* (list (list 'ctrl #\y)) yank)
    (define-key *default-keymap* (list (list 'meta #\y)) yank-pop)
    (define-key *default-keymap* (list (list 'ctrl #\w)) kill-region)
    (define-key *default-keymap* (list (list 'meta #\w)) kill-ring-save)

    ;;----------------------------------------------------------------
    ;; Line surgery and whitespace - simple.el
    ;;
    ;; `open-line' (C-o), `delete-indentation'/`join-line' (M-^),
    ;; `fixup-whitespace' (which `delete-indentation' uses),
    ;; `delete-blank-lines' (C-x C-o), `delete-horizontal-space' (M-\),
    ;; `just-one-space' (M-SPC), and the two directions mg's
    ;; `delleadwhite' and `deltrailwhite' do - which this tree spells
    ;; `delete-leading-space' and `delete-trailing-space', there being
    ;; no Emacs command of either name: both are
    ;; `delete-space--internal' with its one knob turned.
    ;;
    ;; Not ported of `open-line': the fill prefix and `left-margin'
    ;; insertion, there being no fill prefix or margin here.
    ;; Not ported of `fixup-whitespace': the `\s)' and `\s(' clauses -
    ;; the close- and open-parenthesis *syntax classes*, which need a
    ;; syntax table, so a space is left between words and none only at
    ;; the line's ends.
    ;;----------------------------------------------------------------

    (define (%blank-line? ed)
      ;; Whether the line point is on is blank: nothing on it but
      ;; spaces and tabs. `looking-at "[ \t]*$"' from the line's
      ;; beginning, which is how `delete-blank-lines' asks.
      ;;--------------------------------------------------------------
      (let ((start (text-editor-get-start-of-line ed))
            (end (text-editor-get-end-of-line ed)))
        (if (= start end)
            #t
            (let loop ((i start))
              (cond ((= i end) #t)
                    ((memv (%char-at ed i) '(#\space #\tab))
                     (loop (+ i 1)))
                    (else #f))))))

    (define (open-line n)
      ;; GNU Emacs's `open-line' (simple.el:700): "Insert a newline and
      ;; leave point before it. With arg N, insert N newlines." The
      ;; body is `(newline n)' then `(goto-char loc)' - the newlines go
      ;; in at point and point goes back in front of them. What is kept
      ;; of the rest is the `(end-of-line)' - a no-op with no fill
      ;; prefix or margin to have been inserted, which is why the
      ;; whole loop drops out.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (loc (text-editor-get-cursor ed)))
        (text-editor-undo-boundary! ed)
        (let loop ((i 0))
          (when (< i n)
            (text-editor-insert ed #\newline)
            (loop (+ i 1))))
        (text-editor-set-cursor ed loc)))

    (define-command (open-line-command n)
      ;; `open-line' as a command - the name keeps `open-line''s, the
      ;; way `kill-line' and `kill-line-command' split.
      "Insert a newline and leave point before it."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (open-line n))

    (define-command (delete-indentation-command arg beg end)
      ;; GNU Emacs's `delete-indentation' (simple.el:778): "Join this
      ;; line to previous and fix up whitespace at join." With a prefix
      ;; ARG, join the current line to the following line. When BEG and
      ;; END are non-nil, join all lines in the region they define -
      ;; going to END first, but only if the region spans multiple
      ;; lines. The region is ignored when a prefix arg is given.
      ;; `join-line' is the alias Emacs defines of this; there is no
      ;; aliasing here, so the binding below is on this name.
      ;; What is not ported is the fill prefix deletion, there being no
      ;; fill prefix - and `barf-if-buffer-read-only' in the
      ;; interactive form, the deletion's own read-only error taking
      ;; its place.
      "Join this line to previous and fix up whitespace at join."
      (interactive
       (list (current-prefix-arg)
             (and (use-region-p) (region-beginning))
             (and (use-region-p) (region-end))))
      ;; Consistently deactivate mark even when no text is changed.
      (set!text-editor-deactivate-mark! (current-buffer) #t)
      (if (and beg (not arg))
          ;; Region is active. Go to END, but only if region spans
          ;; multiple lines.
          (and (goto-char beg)
               (> end (line-end-position))
               (goto-char end))
          ;; Region is inactive. Set a loop sentinel (subtracting 1 in
          ;; order to compare less than BOB).
          (begin
            (set! beg (- (line-beginning-position (and arg 2)) 1))
            (when arg (forward-line))))
      (let ((prefix (and #f "")))   ; no fill prefix
        ;; Elisp's `(while (and (> (line-beginning-position) beg)
        ;; (forward-line 0) (= (preceding-char) ?\n)) ...)': the
        ;; `forward-line 0' has two roles - it moves point to the
        ;; beginning of the line and its answer is always true (0 is
        ;; true in Elisp, false here) - so here the move is
        ;; `beginning-of-line' and the condition goes on.
        (let loop ()
          (when (and (> (line-beginning-position) beg)
                     ;; Elisp's `(forward-line 0)' answers 0, which is
                     ;; true there; `beginning-of-line' here answers
                     ;; nothing, so the condition supplies the value
                     (begin (beginning-of-line) #t)
                     ;; Elisp's `(preceding-char)' answers 0 at BOB, so
                     ;; `(= 0 ?\n)' is false there; this one answers #f,
                     ;; which is the same false answer
                     (and (preceding-char)
                          (char=? (preceding-char) #\newline)))
            (delete-char -1)
            (fixup-whitespace)
            (loop)))))

(define (fixup-whitespace)
      ;; GNU Emacs's `fixup-whitespace' (simple.el:1123): "Fixup white
      ;; space between objects around point. Leave one space or none,
      ;; according to the context." Point is kept where it was, which
      ;; is the C's `save-excursion' around the whole body. The context
      ;; without the parenthesis *syntax classes* (`\s)' and `\s(',
      ;; which need a syntax table) is a line's ends: no space at
      ;; either, one space otherwise - and the `looking-at' question at
      ;; the point deletion left is bolp/eolp here.
      ;;--------------------------------------------------------------
      (save-excursion
        (delete-horizontal-space #f)
        (if (or (bolp) (eolp))
            #f
            (insert " "))))

    (define-command (delete-horizontal-space backward-only)
      ;; GNU Emacs's `delete-horizontal-space' (simple.el:1135): "Delete
      ;; all spaces and tabs around point." BACKWARD-ONLY is the prefix
      ;; argument, which Emacs passes to `delete-space--internal' the
      ;; same way.
      "Delete all spaces and tabs around point."
      (interactive (list (current-prefix-arg)))
      (delete-space--internal " \t" backward-only))

    (define-command (delete-all-space backward-only)
      ;; GNU Emacs's `delete-all-space' (simple.el:1140): "Delete all
      ;; spaces, tabs, and newlines around point."
      "Delete all spaces, tabs, and newlines around point."
      (interactive (list (current-prefix-arg)))
      (delete-space--internal " \t\r\n" backward-only))

    (define (delete-space--internal chars backward-only)
      ;; GNU Emacs's `delete-space--internal' (simple.el:1147): "Delete
      ;; CHARS around point" - the skips move point the way the
      ;; original's do, and the deletion runs between where they leave
      ;; it. What is not ported is the `constrain-to-field' pair,
      ;; there being no fields.
      ;;--------------------------------------------------------------
      (if backward-only
          (delete-region (text-editor-get-cursor (current-buffer))
                         (begin
                           (skip-chars-backward chars)
                           (text-editor-get-cursor (current-buffer))))
          (begin
            (skip-chars-forward chars)
            (delete-region (text-editor-get-cursor (current-buffer))
                           (begin
                             (skip-chars-backward chars)
                             (text-editor-get-cursor (current-buffer)))))))

    (define-command (delete-leading-space)
      ;; mg's `delleadwhite' - the whitespace *before* point - which is
      ;; `delete-space--internal' with its one knob turned; there is no
      ;; Emacs command of this name.
      "Delete all spaces and tabs before point."
      (interactive)
      (delete-space--internal " \t" #t))

    (define-command (delete-trailing-space)
      ;; mg's `deltrailwhite' - the whitespace *after* point - the other
      ;; turn of `delete-space--internal''s knob.
      "Delete all spaces and tabs after point."
      (interactive)
      (delete-space--internal " \t" #f))

    (define-command (just-one-space n)
      ;; GNU Emacs's `just-one-space' (simple.el:1162): "Delete all
      ;; spaces and tabs around point, leaving one space (or N
      ;; spaces)." A negative N deletes newlines as well and leaves
      ;; -N spaces. The subtlety of the original: the spaces a
      ;; bounded skip forward consumes come OFF N - which is why the
      ;; spaces that stay are the ones the skip stepped over, and a
      ;; point already inside a run leaves exactly one.
      "Delete all spaces and tabs around point, leaving one space (or N spaces)."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let* ((ed (current-buffer))
             (skip-characters (if (and n (< n 0)) " \t\n\r" " \t"))
             (num (abs (or n 1))))
        ;; the skips move point the way the original's do
        (skip-chars-backward skip-characters)
        ;; the bounded skip: spaces only, at most NUM of them, and
        ;; what it skipped comes off NUM - the spaces it stepped over
        ;; are the ones that stay
        (let* ((num (- num (skip-chars-forward " " (+ num (point)))))
               (mid (text-editor-get-cursor ed))
               (end (begin
                      (skip-chars-forward skip-characters)
                      (text-editor-get-cursor ed))))
          (delete-region mid end)
          (text-editor-insert ed (make-string num #\space)))))

    (define (%blank-line-up ed pos)
      ;; The position `re-search-backward "[^ \t\n]"' and `(forward-
      ;; line 1)' find walking up from POS: the start of the line after
      ;; the first non-blank one. #f - which the caller reads as
      ;; `point-min' - when nothing but blanks is before POS.
      ;;--------------------------------------------------------------
      (save-excursion
        (let walk ((p pos))
          (if (<= p 0)
              #f
              (begin
                ;; the newline that ends the line above POS, which is
                ;; where the previous line starts
                (text-editor-set-cursor ed (- p 1))
                (let ((start (text-editor-get-start-of-line ed)))
                  (text-editor-set-cursor ed start)
                  (if (%blank-line? ed)
                      (walk start)
                      ;; the first non-blank line: past it, which is
                      ;; `(forward-line 1)'
                      (let ((eol (text-editor-get-end-of-line ed)))
                        (if (< eol (text-editor-char-count ed))
                            (+ eol 1)
                            eol)))))))))

    (define (%blank-line-down ed pos)
      ;; The start of the first non-blank line at or after POS, walking
      ;; down: what `re-search-forward "[^ \t\n]"' finds, and the
      ;; `(beginning-of-line)' after it. #f - which the caller reads as
      ;; `point-max' - when only blanks follow.
      ;;--------------------------------------------------------------
      (save-excursion
        (let walk ((p pos))
          (if (>= p (text-editor-char-count ed))
              #f
              (begin
                (text-editor-set-cursor ed p)
                (text-editor-set-cursor ed (text-editor-get-start-of-line ed))
                (if (%blank-line? ed)
                    (let ((eol (text-editor-get-end-of-line ed)))
                      (if (< eol (text-editor-char-count ed))
                          (walk (+ eol 1))
                          #f))
                    (text-editor-get-cursor ed)))))))

    (define-command (delete-blank-lines)
      ;; GNU Emacs's `delete-blank-lines' (simple.el:818): "On blank
      ;; line, delete all surrounding blank lines, leaving just one. On
      ;; isolated blank line, delete that one. On nonblank line, delete
      ;; any immediately following blank lines."
      "On blank line, delete all surrounding blank lines, leaving just one."
      (interactive)
      (let* ((ed (current-buffer))
             (here (text-editor-get-cursor ed))
             (thisblank
              (save-excursion
                (beginning-of-line)
                (%blank-line? ed)))
             ;; Set singleblank if there is just one blank line here.
             (singleblank
              (save-excursion
                (and thisblank
                     ;; there is no second blank line after this one -
                     ;; the not of `looking-at "[ \t]*\n[ \t]*$"'
                     (let ((eol (text-editor-get-end-of-line ed)))
                       (or (>= eol (text-editor-char-count ed))
                           (begin
                             (text-editor-set-cursor ed (+ eol 1))
                             (not (%blank-line? ed)))))
                     ;; and the line before it is not blank - or there
                     ;; is none
                     (or (<= (text-editor-get-start-of-line ed) 0)
                         (begin
                           (text-editor-set-cursor
                            ed (- (text-editor-get-start-of-line ed) 1))
                           (text-editor-set-cursor
                            ed (text-editor-get-start-of-line ed))
                           (not (%blank-line? ed))))))))
        ;; Delete preceding blank lines, and this one too if it's the
        ;; only one: from past the first non-blank line above, to
        ;; here - or past this line's newline when it is the only one.
        (when thisblank
          (beginning-of-line)
          (delete-region
           (or (%blank-line-up ed (text-editor-get-cursor ed)) 0)
           (if singleblank
               (let ((eol (text-editor-get-end-of-line ed)))
                 (if (< eol (text-editor-char-count ed))
                     (+ eol 1)
                     eol))
               (text-editor-get-cursor ed))))
        ;; Delete following blank lines, unless the current line is
        ;; blank and there are no following blank lines.
        (if (not (and thisblank singleblank))
            (let ((eol (text-editor-get-end-of-line ed)))
              (when (< eol (text-editor-char-count ed))
                ;; forward-line 1, then the walk down
                (delete-region
                 (+ eol 1)
                 (or (%blank-line-down ed (+ eol 1))
                     (text-editor-char-count ed))))))
        ;; Handle the special case where point is followed by newline
        ;; and eob. Delete the line, leaving point at eob - Emacs's
        ;; `(looking-at "^[ \t]*\n\\'")'.
        (when (and thisblank
                   (= (text-editor-get-cursor ed)
                      (text-editor-get-start-of-line ed))
                   (= (text-editor-get-end-of-line ed)
                      (- (text-editor-char-count ed) 1)))
          (delete-region (text-editor-get-cursor ed)
                         (text-editor-char-count ed)))))
    ;; Transposition - simple.el
    ;;
    ;; `transpose-chars' (C-t) and `transpose-words' (M-t) over
    ;; `transpose-subr', the subroutine both of them and the other
    ;; transposes share. `transpose-subr-1' is its, and does the buffer
    ;; edit: the two objects swap by the three edits the C's
    ;; `atomic-change-group' makes one change of.
    ;;----------------------------------------------------------------

    (define (%transpose-subr-1 pos1 pos2)
      ;; GNU Emacs's `transpose-subr-1' (simple.el:8921): normalize the
      ;; two position pairs, order them, and swap what they hold with
      ;; the three edits that keep the markers between them.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (when (> (car pos1) (cdr pos1))
          (set! pos1 (cons (cdr pos1) (car pos1))))
        (when (> (car pos2) (cdr pos2))
          (set! pos2 (cons (cdr pos2) (car pos2))))
        (when (> (car pos1) (car pos2))
          (let ((swap pos1)) (set! pos1 pos2) (set! pos2 swap)))
        (if (> (cdr pos1) (car pos2))
            (error "Don't have two things to transpose")
            (let* ((word (text-editor-copy-string ed (car pos2) (cdr pos2)))
                   (len1 (- (cdr pos1) (car pos1)))
                   (len2 (string-length word)))
              (text-editor-undo-boundary! ed)
              ;; Emacs's sequence (`transpose-subr-1', the C's
              ;; `atomic-change-group' body): the second object's text
              ;; goes in at the END of the first (`insert-before-
              ;; markers', which pushes the boundary marker along);
              ;; the first object is extracted and deleted; it goes
              ;; in where the boundary now is; and the second
              ;; object's original copy is deleted from after it.
              ;; Without a marker the boundary is tracked by where
              ;; the edits move it: +LEN2 for the first insert
              ;; (BEG2 is at or after it), -LEN1 for the delete.
              (text-editor-set-cursor ed (cdr pos1))
              (text-editor-insert ed word)
              (text-editor-set-cursor ed (car pos1))
              (let ((first (delete-and-extract-region
                            (+ 1 (car pos1))
                            (+ 1 (car pos1) len1))))
                (text-editor-set-cursor
                 ed (+ (car pos2) (- len2 len1)))
                (insert first)
                (text-editor-set-cursor
                 ed (+ (car pos2) (- len2 len1) len1))
                (delete-region
                 (+ (car pos2) (- len2 len1) len1)
                 (+ (car pos2) (- len2 len1) len1 len2)))))))

    (define (%transpose-subr mover arg)
      ;; GNU Emacs's `transpose-subr' (simple.el:8885): "Subroutine to
      ;; do the work of transposing objects." MOVER moves by one unit,
      ;; and its positions are the cons the ordinary (non-special)
      ;; callers make of going over and coming back. The ARG zero case
      ;; exchanges with the mark's object, and what it is not ported
      ;; for - `(or (mark) (error ...))' - is the same error.
      ;;--------------------------------------------------------------
      (let ((aux
             (lambda (x)
               ;; Emacs's: `(cons (begin (funcall mover x) (point))
               ;; (begin (funcall mover (- x)) (point)))' - the second
               ;; mover runs from where the first left point, and the
               ;; two together net point back to where it was.
               (let ((ed (current-buffer)))
                 (mover x)
                 (let ((here (text-editor-get-cursor ed)))
                   (mover (- x))
                   (cons here (text-editor-get-cursor ed)))))))
        (cond
         ((= arg 0)
          ;; Emacs's arg-zero case (simple.el:8897): the transposition
          ;; inside `save-excursion' - point back where it started when
          ;; it is done - and then `exchange-point-and-mark', which puts
          ;; point where the mark was.
          (save-excursion
            (let ((pos1 (aux 1)))
              (if (not (mark #t))
                  (error "No mark set in this buffer")
                  (begin
                    (text-editor-set-cursor (current-buffer) (mark #t))
                    (let ((pos2 (aux 1)))
                      (%transpose-subr-1 pos1 pos2))))))
          (exchange-point-and-mark #f))
         ((> arg 0)
          (let* ((pos1 (aux -1))
                 (pos2 (aux arg)))
            (%transpose-subr-1 pos1 pos2)
            (text-editor-set-cursor (current-buffer) (car pos2))))
         (else
          (let* ((pos1 (aux -1))
                 (ed (current-buffer)))
            (text-editor-set-cursor ed (car pos1))
            (let ((pos2 (aux arg)))
              (%transpose-subr-1 pos1 pos2)
              (text-editor-set-cursor
               ed (+ (car pos2) (- (cdr pos1) (car pos1))))))))))

    (define-command (transpose-chars arg)
      ;; GNU Emacs's `transpose-chars' (simple.el:8787): "Interchange
      ;; characters around point, moving forward one character." At end
      ;; of line the previous two characters are exchanged, which is
      ;; the backward step the eolp case makes first.
      "Interchange characters around point, moving forward one character."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let ((ed (current-buffer)))
        (when (and (= (text-editor-get-cursor ed)
                      (text-editor-get-end-of-line ed))
                   (> (text-editor-get-cursor ed) 0))
          (text-editor-move-cursor ed -1)))
      (%transpose-subr
       (lambda (x)
         (text-editor-move-cursor (current-buffer) x))
       arg))

    (define-command (transpose-words arg)
      ;; GNU Emacs's `transpose-words' (simple.el:8798), over
      ;; `transpose-subr' with `forward-word' as its mover - which this
      ;; tree's `forward-word' cannot do backward, so a negative count
      ;; moves by `backward-word'.
      "Interchange words around point, leaving point at end of them."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (%transpose-subr
       (lambda (x)
         (if (> x 0)
             (forward-word x)
             (backward-word (- x))))
       arg))

    (define-key *default-keymap* (list (list 'ctrl #\o)) open-line-command)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 30))) delete-indentation-command)
    (define-key *default-keymap*
      (list (list 'meta (integer->char 30))) delete-indentation-command)
    (define-key *default-keymap* (list (list 'meta #\space)) just-one-space)
    (define-key *default-keymap*
      (list (list 'ctrl #\x) (list 'ctrl #\o)) delete-blank-lines)
    (define-key *default-keymap* (list (list 'meta #\\)) delete-horizontal-space)
    (define-key *default-keymap* (list (list 'ctrl #\t)) transpose-chars)
    (define-key *default-keymap* (list (list 'meta #\t)) transpose-words)

    ;;----------------------------------------------------------------
    ;; `what-cursor-position' - simple.el:1856, C-x =
    ;;----------------------------------------------------------------

    (define-command (what-cursor-position detail)
      ;; GNU Emacs's `what-cursor-position' (simple.el:1856): "Print
      ;; info on cursor position (on screen and within buffer). Also
      ;; describe the character after point, and give its character
      ;; code in octal, decimal and hex." With a prefix argument it
      ;; would go on to `describe-char' in a `*Help*' buffer - which is
      ;; not here, so the argument is taken and does nothing.
      ;;
      ;; Not ported: `what-cursor-show-names' (the character's name),
      ;; the bidi fixers for embedding-starting characters (there is no
      ;; bidi here, and the fixer Emacs's condition answers for every
      ;; other character is the empty string anyway), the `display'
      ;; text-property and coding-system branches of the encoding
      ;; message - every character here is what the buffer holds - and
      ;; the `<BEG-END>' narrowed part of the message, nothing being
      ;; narrowed. The bidi fixer being the empty string is why it
      ;; drops out of the format below.
      ;;--------------------------------------------------------------
      "Print info on cursor position (on screen and within buffer)."
      (interactive (list (current-prefix-arg)))
      (let* ((frame (*current-frame*))
             ;; Emacs's own let*: the one-based point, the buffer's
             ;; size, and the percent of the characters BEFORE point
             (pos (point))
             (total (buffer-size))
             (percent (round (/ (* 100 (- pos 1)) (max 1 total))))
             (hscroll (if (= (%window-hscroll (selected-window)) 0)
                          ""
                          (format #f " Hscroll=~a"
                                  (%window-hscroll (selected-window)))))
             (col (text-editor-cursor-column (current-buffer)))
             (char (following-char))
             (shown (and char
                         (if (< (char->integer char) 128)
                             (single-key-description char)
                             (string char))))
             (code (and char (char->integer char))))
        (if (= pos (point-max))
            ;; Emacs's `(= pos end)' - the end being `point-max'
            (set-message! frame
                          (format #f "point=~a of ~a (EOB) column=~a~a"
                                  pos total col hscroll))
            (set-message! frame
                          (format #f
                                  "Char: ~a (~a, #o~o, #x~x) point=~a of ~a (~a%) column=~a~a"
                                  shown code code code
                                  pos total percent col hscroll)))))

    (define-key *default-keymap* (list (list 'ctrl #\x) #\=)
      what-cursor-position)

    (define self-insert-layer
      ;; Catch all printable characters and bind them to
      ;; `self-insert-command`: the global map's fallback layer, reached
      ;; when no layer above it matched. It is here because the command it
      ;; names is here - which is the reason the bindings live with their
      ;; commands at all.
      ;;--------------------------------------------------------------
      (km:new-self-insert-keymap-layer
       #f
       (lambda (c) self-insert-command)
       (lambda () #f)))

    (add-keymap-layer! *default-keymap* self-insert-layer)
    ))
