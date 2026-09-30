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
    ;; `caddr' is `(scheme cxr)'s, and `push-mark' takes Emacs's three
    ;; optional arguments.
    (only (scheme cxr) caddr)
    ;; The prefix echo is a time.
    (only (scheme time) current-second)
    (prefix (schemacs keymap) km:)
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
         *current-frame* *echo-area-buffer* current-editor frame-keymap-state 
         selected-window set!frame-keymap-state 
         set!frame-message set!window-top-line window-body-height 
         window-buffer window-top-line)
    (only (schemacs editor command)
         new-command uarg->integer defcommand)
    ;; The buffer-local store, for `mark-ring' - which is the buffer's
    ;; own - and the variables that come from the libraries Emacs
    ;; declares them in: `mark-active' and `transient-mark-mode' are
    ;; `buffer.c''s, `mark-even-if-inactive' is `callint.c''s,
    ;; `region-beginning' and `region-end' are `editfns.c''s, and
    ;; `add-to-history' is `subr.el''s.
    (only (schemacs editor buffer)
          buffer-local-value current-buffer mark-active set!mark-active
          set-buffer-local-value! transient-mark-mode)
    (only (schemacs editor command) *mark-even-if-inactive*)
    (only (schemacs editor editfns)
          delete-region region-beginning region-end)
    (only (schemacs editor subr) add-to-history nthcdr)
    ;; `define-key' and the global map, which this library fills with the
    ;; bindings for the commands it defines - as simple.el does with
    ;; `(define-key global-map ...)'.
    (only (schemacs editor keymap)
         add-keymap-layer!
         define-key
         *default-keymap*)
    )

  (export
   %char-at %inword-at *amalgamating-count* *amalgamating-undo-limit*
   *last-change-was-undo* *last-command* *this-command* *temporary-goal-column*
   *kill-do-not-save-duplicates* *kill-read-only-ok*
   *kill-ring* *kill-ring-max* *kill-ring-yank-pointer*
   *pending-undo-list* *prefix-cu* *prefix-digits* *prefix-negative*
   amalgamating-command? backward-char backward-delete-char
   backward-kill-word backward-word backward-word-position
   beginning-of-buffer beginning-of-line clear-prefix! delete-char
   end-of-buffer end-of-line exchange-point-and-mark forward-char
   forward-word forward-word-position keyboard-quit kill-line kill-line-chunk
   copy-region-as-kill current-kill kill-append kill-line-command
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
   prefix-echo-pending? request-prefix-echo! show-prefix-echo!
   strip-undo-boundaries undo undo-redo update-prefix!
   word-char? word-run-end word-run-start yank
   )

  (begin
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
                    (text-editor-insert (current-editor) c)
                    (loop (- i 1)))))
              (lambda () #f))
              )))
       (lambda (c) (text-editor-insert (current-editor) c))
       "Insert the typed character at point."
       'uarg))

    (defcommand (self-insert-tab count)
      "Insert N tab characters at point."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-insert (current-editor) #\tab)
          (loop (+ 1 i)))))

    (defcommand (forward-char count)
      "Move point N characters forward."
      (interactive "p")
      (text-editor-move-cursor (current-editor) count))

    (defcommand (backward-char count)
      "Move point N characters backward."
      (interactive "p")
      (text-editor-move-cursor (current-editor) (- count)))

    (define *temporary-goal-column* (make-parameter 0))

    (defcommand (next-line count)
      "Move point down N lines, keeping the column."
      (interactive "p")
      (let* ((ed (current-editor))
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

    (defcommand (previous-line count)
      "Move point up N lines, keeping the column."
      (interactive "p")
      (let* ((ed (current-editor))
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

    (defcommand (beginning-of-line)
      "Move point to the beginning of the current line."
      (interactive)
      (text-editor-set-cursor (current-editor)
                              (text-editor-get-start-of-line
                               (current-editor))))

    (defcommand (end-of-line)
      "Move point to the end of the current line."
      (interactive)
      (text-editor-set-cursor (current-editor)
                              (text-editor-get-end-of-line
                               (current-editor))))

    (defcommand (delete-char count)
      "Delete N characters after point."
      (interactive "p")
      (text-editor-delete-from-cursor (current-editor) count))

    (defcommand (backward-delete-char count)
      "Delete N characters before point."
      (interactive "p")
      (text-editor-delete-from-cursor (current-editor) (- count)))

    (define (kill-line-chunk ed uarg)
      ;; How many characters `kill-line' removes from point, and in
      ;; which direction, following mg's `killline' (yank.c:151), whose
      ;; rule set GNU Emacs's `kill-line' shares:
      ;;
      ;;   no argument  from point to the end of the line; when nothing
      ;;                but blanks is left before the end of the line,
      ;;                the line break goes too, joining the next line on
      ;;   N > 0        N lines forward, including the break that ends
      ;;                the Nth one, stopping at the end of the buffer
      ;;   N = 0        backward from point to the start of the line
      ;;   N < 0        backward to the start of the line, then |N|
      ;;                more lines back
      ;;
      ;; Returns a pair: the character count, and #t when the kill runs
      ;; forward from point or #f when it runs backward. UARG is the raw
      ;; universal argument, so that "no prefix" is distinguishable from
      ;; a prefix of 1 (mg's FFARG flag; the two cases differ).
      ;;--------------------------------------------------------------
      (let* ((start (text-editor-get-cursor ed))
             (bol (text-editor-get-start-of-line ed))
             (eol (text-editor-get-end-of-line ed))
             (len (text-editor-char-count ed))
             (blank-at? (lambda (i)
                          (let ((c (text-editor-get-char-index ed i)))
                            (and c (or (char=? c #\space) (char=? c #\tab))))))
             (break-at? (lambda (i)
                          (let ((c (text-editor-get-char-index ed i)))
                            (and c (char=? c #\newline))))))
        (cond
         ((not uarg)
          (let loop ((i start))
            (cond
             ((>= i eol)
              ;; only blanks (or nothing at all) before the end of the
              ;; line: the break is part of the kill
              (cons (- (min len (+ eol 1)) start) #t))
             ((blank-at? i) (loop (+ i 1)))
             (else (cons (- eol start) #t)))))
         ((> uarg 0)
          ;; walk forward over UARG line breaks; the break that ends the
          ;; UARGth line is included, the way mg counts `chunk'
          (cons (- (let loop ((i start) (lines 1))
                     (cond
                      ((>= i len) len)
                      ((break-at? i)
                       (if (>= lines uarg) (+ i 1) (loop (+ i 1) (+ lines 1))))
                      (else (loop (+ i 1) lines))))
                   start)
                #t))
         ((= uarg 0) (cons (- start bol) #f))
         (else
          ;; backward: to the start of this line, then |N| more lines
          (cons (- start
                   (let loop ((i bol) (lines 0))
                     (if (or (>= lines (- uarg)) (<= i 0))
                         i
                         ;; step over the break that ends the previous
                         ;; line, then back over the whole of that line
                         (let scan ((k (- i 1)))
                           (if (and (> k 0) (not (break-at? (- k 1))))
                               (scan (- k 1))
                               (loop k (+ lines 1)))))))
                #f)))))

    (define (kill-line-command uarg)
      ;; Kill at point, into the kill buffer. UARG is the raw universal
      ;; argument: #f when no prefix was typed, otherwise a number.
      ;;--------------------------------------------------------------
      (let* ((ed (current-editor))
             (start (text-editor-get-cursor ed))
             (chunk+dir (kill-line-chunk ed uarg))
             (chunk (car chunk+dir)))
        (cond
         ((= chunk 0)
          (set!frame-message (*current-frame*) "; End of buffer")
          #f)
         ((cdr chunk+dir) (kill-range ed start (+ start chunk) #t))
         (else (kill-range ed (- start chunk) start #f)))))

    (defcommand (kill-line uarg)
      ;; mg's `killline'. Unlike the other count-taking commands this one
      ;; needs the raw prefix argument, because killing no lines and
      ;; killing one line are different operations.
      "Kill N lines at point. With no argument, kill to the end of the
 line, taking the line break when only blanks remain before it."
      (interactive "P")
      (kill-line-command uarg))

    ;; The command GNU Emacs calls `newline' - `simple.el' defines it
    ;; under that name and it is what RET and C-j are bound to. The name
    ;; is taken here, though: `newline' is one of the names `(scheme
    ;; base)' exports (it is R7RS's output procedure), and defining it
    ;; again would be a redefinition of an imported binding, which R7RS
    ;; forbids - Guile would keep the imported one and the keymap would
    ;; end up bound to Scheme's `newline' instead of the command. A
    ;; clash with the host language is a real collision, so the command
    ;; is named `INSERT-NEWLINE' instead.
    (defcommand (insert-newline count)
      "Insert N line breaks at point."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-insert (current-editor) #\newline)
          (loop (+ 1 i)))))

    ;; `keyboard-quit', `read-only-mode' and
    ;; `exchange-point-and-mark' are simple.el's; they were
    ;; misfiled under the Windows and isearch banners.
    (defcommand (keyboard-quit)
      "Cancel the current action and clear the echo area."
      (interactive)
      (set!frame-message (*current-frame*) "")
      (set!frame-keymap-state (*current-frame*) #f))

    (defcommand (read-only-mode uarg)
      ;; GNU Emacs's `read-only-mode' (it used to be called
      ;; `toggle-read-only'). With no argument it toggles; with one it
      ;; turns read-only on for a positive count and off otherwise,
      ;; which is the convention Emacs's minor modes follow. The
      ;; buffer's text cannot be changed while it is on, and undo will
      ;; not touch it either.
      "Toggle whether the buffer can be changed (bound to C-x C-q)."
      (interactive "P")
      (let* ((frame (*current-frame*))
             (ed (current-editor))
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

    (defcommand (exchange-point-and-mark arg)
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
              (set-mark (text-editor-get-cursor (current-editor)))
              (text-editor-set-cursor (current-editor) omark)
              (if (eq? (and arg #t)
                       (not (if (*exchange-point-and-mark-highlight-region*)
                                (region-active-p)
                                region-was-active)))
                  (deactivate-mark)
                  (activate-mark))))))

    (defcommand (scroll-down-command count)
      ;; Scroll the view COUNT screenfuls down (toward the end of the
      ;; buffer), with a two-line overlap, like mg's `forwpage`. If
      ;; the point falls outside the new window it moves to the top
      ;; of the window, column zero. Reports "End of buffer" when the
      ;; view cannot scroll further.
      "Scroll the view down N screenfuls."
      (interactive "p")
      (let* ((frame (*current-frame*))
             (window (selected-window))
             (ed (window-buffer window))
             (vheight (window-body-height window))
             (n (* count (max 1 (- vheight 2))))
             (last-line (max 0 (- (text-editor-line-count ed) 1)))
             (new-top
              (min (+ (window-top-line window) n) last-line)))
        (if (<= new-top (window-top-line window))
            (set!frame-message frame "; End of buffer")
            (begin
              (set!window-top-line window new-top)
              (let ((line (text-editor-cursor-line ed)))
                (when (or (< line new-top)
                          (>= line (+ new-top vheight)))
                  (text-editor-set-cursor ed new-top 0)))))))

    (defcommand (scroll-up-command count)
      ;; Scroll the view COUNT screenfuls up (toward the beginning of
      ;; the buffer), the mirror of `scroll-up-command'.
      "Scroll the view up N screenfuls."
      (interactive "p")
      (let* ((frame (*current-frame*))
             (window (selected-window))
             (ed (window-buffer window))
             (vheight (window-body-height window))
             (n (* count (max 1 (- vheight 2))))
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

    (defcommand (beginning-of-buffer)
      "Move point to the beginning of the buffer."
      (interactive)
      (let ((window (selected-window)))
        (set!window-top-line window 0)
        (text-editor-set-cursor (window-buffer window) 0 0)))

    (defcommand (end-of-buffer)
      "Move point to the end of the buffer."
      (interactive)
      (let ((ed (current-editor)))
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

    (defcommand (forward-word count)
      ;; mg's `forwword` (word.c:51) with its numeric-argument loop: move
      ;; N words forward, stopping at the end of the buffer.
      "Move point N words forward, to the end of each word."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-set-cursor
           (current-editor) (forward-word-position (current-editor)))
          (loop (+ 1 i)))))

    (defcommand (backward-word count)
      ;; mg's `backword` (word.c:27) with its numeric-argument loop.
      "Move point N words backward, to the start of each word."
      (interactive "p")
      (let loop ((i 0))
        (when (< i count)
          (text-editor-set-cursor
           (current-editor) (backward-word-position (current-editor)))
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

    (defcommand (kill-word count)
      ;; Like mg's `delfword` (word.c:397): kill from point to the end
      ;; of the next word. The N words are one kill, so they accumulate
      ;; into the kill buffer as a single entry.
      "Kill N words forward from point."
      (interactive "p")
      (let* ((ed (current-editor))
             (start (text-editor-get-cursor ed))
             (end (word-run-end ed count)))
        (when (< start end)
          (kill-range ed start end #t))))

    (defcommand (backward-kill-word count)
      ;; Like mg's `delbword` (word.c:453): kill from the start of the
      ;; previous word to point.
      "Kill N words backward from point."
      (interactive "p")
      (let* ((ed (current-editor))
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

    (define *kill-read-only-ok*
      ;; GNU Emacs's `kill-read-only-ok', off by default: when it is on,
      ;; a kill from a read-only buffer puts the text in the ring and
      ;; says so instead of signalling.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (kill-new string . args)
      ;; GNU Emacs's `kill-new': make STRING the latest kill, and point
      ;; the yank pointer at it. REPLACE - false unless passed - replaces
      ;; the front of the ring rather than adding a new entry, which is
      ;; how a run of kills becomes one entry.
      ;;
      ;; Emacs also offers the string to the window system here
      ;; (`interprogram-cut-function') and can pull in what another
      ;; program has on the clipboard first; there is no window system
      ;; yet. See REGION-PLAN.txt.
      ;;--------------------------------------------------------------
      (let ((replace (if (pair? args) (car args) #f)))
        (unless (and (*kill-do-not-save-duplicates*)
                     (equal? string (car (*kill-ring*))))
          (if (and replace (pair? (*kill-ring*)))
              (set-car! (*kill-ring*) string)
              (*kill-ring* (add-to-history (*kill-ring*) string
                                           (*kill-ring-max*) #t))))
        (*kill-ring-yank-pointer* (*kill-ring*))
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
      ;;--------------------------------------------------------------
      (let ((cur (car (*kill-ring*))))
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
      ;;--------------------------------------------------------------
      (let ((do-not-move (if (pair? args) (car args) #f)))
        (or (*kill-ring*) (error "Kill ring is empty"))
        (let ((element (nthcdr (modulo (- n (length (*kill-ring-yank-pointer*)))
                                       (length (*kill-ring*)))
                               (*kill-ring*))))
          (unless do-not-move
            (*kill-ring-yank-pointer* element))
          (car element))))

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
             (list mark (text-editor-get-cursor (current-editor))))))

    (defcommand (kill-region)
      ;; GNU Emacs's `kill-region' (C-w): delete the region and put it in
      ;; the kill ring.
      ;;
      ;; A kill that runs into a read-only buffer does not lose the text:
      ;; Emacs copies it to the ring and then signals, so that the killing
      ;; commands can be used to *copy* out of a read-only buffer - and
      ;; `kill-read-only-ok' turns the signal into a message.
      "Kill (cut) the text between point and mark."
      (interactive)
         (let ((args (kill-region-arguments)))
           (if (not args)
               (error "The mark is not set now, so there is no region")
               (let* ((beg (car args))
                      (end (cadr args))
                      (string (text-editor-copy-string (current-editor) beg end))
                      (read-only? (text-editor-read-only? (current-editor))))
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
                    (delete-region beg end))))))

    (define (copy-region-as-kill beg end)
      ;; GNU Emacs's `copy-region-as-kill': put the text in the kill ring
      ;; without deleting it. The appending rule is the kill one, so M-w
      ;; after a kill extends that kill rather than starting a new entry.
      ;;--------------------------------------------------------------
      (let ((string (text-editor-copy-string (current-editor) beg end)))
        (if (eq? (*last-command*) kill-region)
            (kill-append string (< end beg))
            (kill-new string))
        ;; M-w does *not* rename itself: Emacs's `copy-region-as-kill' has
        ;; no `(setq this-command ...)', so copying twice makes two
        ;; entries where killing twice makes one.
        (set!text-editor-deactivate-mark! (current-buffer) #t)))

    (defcommand (kill-ring-save)
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

    (defcommand (yank arg)
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
            (ed (current-editor)))
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

    (defcommand (yank-pop count)
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
          (let* ((ed (current-editor))
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
            (text-editor-undo-boundary! (current-editor))
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

    (defcommand (undo count)
      ;; GNU Emacs's `undo'. Repeating it undoes further back, and when
      ;; it reaches the end of the undo list the next one reports that
      ;; there is nothing left.
      "Undo some previous changes."
      (interactive "p")
      (let* ((frame (*current-frame*))
             (ed (current-editor))
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

    (defcommand (undo-redo count)
      ;; GNU Emacs's `undo-redo': undo the undos. The records an undo
      ;; created are ordinary undo entries sitting at the front of the
      ;; list, so redoing one is undoing it - that is the whole of the
      ;; redo mechanism, and why there is no redo list.
      "Redo the last undone change, or the last COUNT undone changes."
      (interactive "p")
      (let ((frame (*current-frame*)))
        (if (not (*last-change-was-undo*))
            (set!frame-message frame "No undone changes to redo")
            (let* ((ed (current-editor))
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

    (defcommand (digit-argument uarg)
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

    (defcommand (negative-argument uarg)
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
      ;; Emacs also sets the PRIMARY selection here when
      ;; `select-active-regions' says to; there is no selection to set.
      ;;--------------------------------------------------------------
      (let ((force (if (pair? args) (car args) #f)))
        (when (or (region-active-p) force)
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
                                            (current-editor))))
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
            (point (text-editor-get-cursor (current-editor))))
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
            (when (= (text-editor-get-cursor (current-editor)) (mark #t))
              (set!frame-message (*current-frame*) "Mark popped"))
            (text-editor-set-cursor (current-editor) (mark #t))
            (pop-mark))))

    (defcommand (set-mark-command arg)
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

    (defcommand (mark-whole-buffer)
      ;; GNU Emacs's `mark-whole-buffer' (C-x h): point at the beginning
      ;; and the mark at the end, with the old mark pushed first.
      ;;
      ;; Emacs goes to `minibuffer-prompt-end' rather than to the start of
      ;; the buffer; the prompt is not in the buffer here, so the two are
      ;; the same.
      "Put point at beginning and mark at end of buffer."
      (interactive)
      (push-mark)
      (push-mark (text-editor-char-count (current-editor)) #f #t)
      (text-editor-set-cursor (current-editor) 0))

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
    ;; Undo, on the keys GNU Emacs binds it to. C-/ and C-_ are the same
    ;; byte (31) in a terminal, so one binding serves both. Emacs's other
    ;; redo key, C-?, cannot be bound: it is DEL, which arrives here as
    ;; backspace.
    (define-key *default-keymap*
      (list (list 'ctrl (integer->char 31))) undo)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 31))) undo-redo)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\u) undo)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\q) read-only-mode)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\x))
      exchange-point-and-mark)
    (define-key *default-keymap* (list (list 'ctrl #\i)) self-insert-tab)
    (define-key *default-keymap* (list (list 'ctrl #\v)) scroll-down-command)
    (define-key *default-keymap* (list (list 'meta #\v)) scroll-up-command)
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
