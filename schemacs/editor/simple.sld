(define-library (schemacs editor simple)
  ;; This library mirrors GNU Emacs's `simple.el' - the basic editing
  ;; commands and the machinery they need: point motion, insertion and
  ;; deletion, the kill ring and word motion, undo, and the prefix
  ;; argument. In Emacs they are one file, and they call each other
  ;; (`kill-line' into the kill ring, `kill-region' into `kill-new'), so
  ;; they are one library here too.
  ;;
  ;; What is *not* here yet, though it is simple.el's: the region
  ;; commands, `mark-whole-buffer', the quit signal that `keyboard-quit'
  ;; raises - which belongs to the command loop's error reporting - and
  ;; the two file-visiting commands, which are files.el's in the end.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor engine)
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
         *current-frame* current-editor ncurses-frame-keymap-state 
         selected-window set!ncurses-frame-keymap-state 
         set!ncurses-frame-message set!window-top-line window-body-height 
         window-buffer window-top-line)
    (only (schemacs editor command)
         new-command new-count-command uarg->integer)
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
   *kill-buffer* *last-change-was-undo* *last-command* *last-command-kill*
   *pending-undo-list* *prefix-cu* *prefix-digits* *this-command-kill*
   amalgamating-command? backward-char backward-delete-char
   backward-kill-word backward-word backward-word-position
   beginning-of-buffer beginning-of-line clear-prefix! delete-char
   end-of-buffer end-of-line exchange-point-and-mark forward-char
   forward-word forward-word-position keyboard-quit kill-line kill-line-chunk
   kill-line-command kill-range kill-word next-line pending-uarg
   ;; `newline' clashes with `(scheme base)'s output procedure, so it
   ;; is exported by rename; see the definition below.
   (rename (newline-command newline))
   place-undo-boundary! previous-line read-only-mode rotate-kill-flag!
   scroll-down-command scroll-up-command self-insert-command
   self-insert-layer self-insert-tab
   digit-argument negative-argument
   strip-undo-boundaries undo-command undo-redo-command update-prefix!
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

    (define self-insert-command
      ;; The character is not an argument the dispatcher can supply: it
      ;; is re-derived from the frame's keymap lookup state, which holds
      ;; the key index of the chord that reached this command. The
      ;; prefix argument is supplied normally, as the repeat count.
      (new-command
       "self-insert-command"
       (lambda (uarg)
         (let ((state (ncurses-frame-keymap-state (*current-frame*))))
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

    (define self-insert-tab
      (new-count-command
       "self-insert-tab"
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-insert (current-editor) #\tab)
             (loop (+ 1 i)))))
       "Insert N tab characters at point."))

    (define forward-char
      (new-count-command
       "forward-char"
       (lambda (count) (text-editor-move-cursor (current-editor) count))
       "Move point N characters forward."))

    (define backward-char
      (new-count-command
       "backward-char"
       (lambda (count) (text-editor-move-cursor (current-editor) (- count)))
       "Move point N characters backward."))

    (define next-line
      (new-count-command
       "next-line"
       (lambda (count)
         (let ((ed (current-editor)))
           (let loop ((i 0))
             (when (< i count)
               (let ((line (text-editor-cursor-line ed)))
                 (text-editor-set-cursor
                  ed (+ 1 line) (text-editor-cursor-column ed))
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
       "Move point down N lines, keeping the column."))

    (define previous-line
      (new-count-command
       "previous-line"
       (lambda (count)
         (let ((ed (current-editor)))
           (let loop ((i 0))
             (when (< i count)
               (let ((line (text-editor-cursor-line ed)))
                 (text-editor-set-cursor
                  ed (- line 1) (text-editor-cursor-column ed))
                 (cond
                  ((= line (text-editor-cursor-line ed))
                   (text-editor-set-cursor
                    ed (text-editor-get-start-of-line ed))
                   (error "Beginning of buffer"))
                  (else (loop (+ 1 i)))))))))
       "Move point up N lines, keeping the column."))

    (define beginning-of-line
      (new-command
       "beginning-of-line"
       (lambda () (text-editor-set-cursor (current-editor)
                                          (text-editor-get-start-of-line
                                           (current-editor))))
       (lambda () (text-editor-set-cursor (current-editor)
                                          (text-editor-get-start-of-line
                                           (current-editor))))
       "Move point to the beginning of the current line."))

    (define end-of-line
      (new-command
       "end-of-line"
       (lambda () (text-editor-set-cursor (current-editor)
                                          (text-editor-get-end-of-line
                                           (current-editor))))
       (lambda () (text-editor-set-cursor (current-editor)
                                          (text-editor-get-end-of-line
                                           (current-editor))))
       "Move point to the end of the current line."))

    (define delete-char
      (new-count-command
       "delete-char"
       (lambda (count)
         (text-editor-delete-from-cursor (current-editor) count))
       "Delete N characters after point."))

    (define backward-delete-char
      (new-count-command
       "backward-delete-char"
       (lambda (count)
         (text-editor-delete-from-cursor (current-editor) (- count)))
       "Delete N characters before point."))

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
          (set!ncurses-frame-message (*current-frame*) "; End of buffer")
          #f)
         ((cdr chunk+dir) (kill-range ed start (+ start chunk) #t))
         (else (kill-range ed (- start chunk) start #f)))))

    (define kill-line
      ;; mg's `killline'. Unlike the other count-taking commands this one
      ;; needs the raw prefix argument, because killing no lines and
      ;; killing one line are different operations.
      (new-command
       "kill-line"
       (lambda (uarg) (kill-line-command uarg))
       kill-line-command
       "Kill N lines at point. With no argument, kill to the end of the
 line, taking the line break when only blanks remain before it."
       'uarg))

    ;; The command GNU Emacs calls `newline'. It is defined under the
    ;; name `NEWLINE-COMMAND' and exported as `newline', because `newline'
    ;; is one of the names `(scheme base)' exports (it is R7RS's output
    ;; procedure): defining it here would be a redefinition of an
    ;; imported binding, which R7RS forbids, and Guile resolves it by
    ;; keeping the imported one - so the definition would be silently
    ;; lost and the keymap would end up bound to Scheme's `newline'
    ;; instead of the command. `(rename ...)' in an export is the
    ;; standard way to export a name that clashes with an import, and it
    ;; is what the other commands of this shape already spell with a
    ;; `-command' suffix. See LAYOUT-PLAN.txt.
    (define newline-command
      (new-count-command
       "newline"
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-insert (current-editor) #\newline)
             (loop (+ 1 i)))))
       "Insert N line breaks at point."))

    ;; `keyboard-quit', `read-only-mode' and
    ;; `exchange-point-and-mark' are simple.el's; they were
    ;; misfiled under the Windows and isearch banners.
    (define keyboard-quit
      (new-command
       "keyboard-quit"
       (lambda ()
         (set!ncurses-frame-message (*current-frame*) "")
         (set!ncurses-frame-keymap-state (*current-frame*) #f))
       (lambda () #f)
       "Cancel the current action and clear the echo area."))

    (define read-only-mode
      ;; GNU Emacs's `read-only-mode', bound to C-x C-q (it used to be
      ;; called `toggle-read-only'). With no argument it toggles; with
      ;; one it turns read-only on for a positive count and off
      ;; otherwise, which is the convention Emacs's minor modes follow.
      ;; The buffer's text cannot be changed while it is on, and undo
      ;; will not touch it either.
      (new-command
       "read-only-mode"
       (lambda (uarg)
         (let* ((frame (*current-frame*))
                (ed (current-editor))
                (on? (if uarg
                         (< 0 (uarg->integer 1 uarg))
                         (not (text-editor-read-only? ed)))))
           (text-editor-set-read-only! ed on?)
           (set!ncurses-frame-message
            frame
            (if on?
                "Read-Only mode enabled in current buffer"
                "Read-Only mode disabled in current buffer"))))
       (lambda (flag) (text-editor-set-read-only! (current-editor) flag))
       "Toggle whether the buffer can be changed (bound to C-x C-q)."
       'uarg))

    (define exchange-point-and-mark
      ;; GNU Emacs's `exchange-point-and-mark' (C-x C-x): go back to
      ;; where the mark is, leaving the mark where point was. It is how
      ;; you return to where a search started.
      (new-command
       "exchange-point-and-mark"
       (lambda ()
         (let* ((ed (current-editor))
                (mark (text-editor-mark ed))
                (point (text-editor-get-cursor ed)))
           (when mark
             (text-editor-set-cursor ed mark)
             (set!text-editor-mark ed point))))
       (lambda () #f)
       "Go to the mark, leaving the mark where point was (bound to C-x C-x)."))

    (define scroll-up-command
      ;; Scroll the view COUNT screenfuls down (toward the end of the
      ;; buffer), with a two-line overlap, like mg's `forwpage`. If
      ;; the point falls outside the new window it moves to the top
      ;; of the window, column zero. Reports "End of buffer" when the
      ;; view cannot scroll further.
      (new-count-command
       "scroll-up-command"
       (lambda (count)
         (let* ((frame (*current-frame*))
                (window (selected-window))
                (ed (window-buffer window))
                (vheight (window-body-height window))
                (n (* count (max 1 (- vheight 2))))
                (last-line (max 0 (- (text-editor-line-count ed) 1)))
                (new-top
                 (min (+ (window-top-line window) n) last-line)))
           (if (<= new-top (window-top-line window))
               (set!ncurses-frame-message frame "; End of buffer")
               (begin
                 (set!window-top-line window new-top)
                 (let ((line (text-editor-cursor-line ed)))
                   (when (or (< line new-top)
                             (>= line (+ new-top vheight)))
                     (text-editor-set-cursor ed new-top 0)))))))
       "Scroll the view down N screenfuls."))

    (define scroll-down-command
      ;; Scroll the view COUNT screenfuls up (toward the beginning of
      ;; the buffer), the mirror of `scroll-up-command`.
      (new-count-command
       "scroll-down-command"
       (lambda (count)
         (let* ((frame (*current-frame*))
                (window (selected-window))
                (ed (window-buffer window))
                (vheight (window-body-height window))
                (n (* count (max 1 (- vheight 2))))
                (new-top (max 0 (- (window-top-line window) n))))
           (if (= new-top (window-top-line window))
               (set!ncurses-frame-message frame "; Beginning of buffer")
               (begin
                 (set!window-top-line window new-top)
                 (let ((line (text-editor-cursor-line ed)))
                   (when (or (< line new-top)
                             (>= line (+ new-top vheight)))
                     (text-editor-set-cursor
                      ed (+ new-top (- vheight 1)) 0)))))))
       "Scroll the view up N screenfuls."))

    (define beginning-of-buffer
      (new-command
       "beginning-of-buffer"
       (lambda ()
         (let ((window (selected-window)))
           (set!window-top-line window 0)
           (text-editor-set-cursor (window-buffer window) 0 0)))
       (lambda () #f)
       "Move point to the beginning of the buffer."))

    (define end-of-buffer
      (new-command
       "end-of-buffer"
       (lambda ()
         (let ((ed (current-editor)))
           (text-editor-set-cursor
            ed (text-editor-char-count ed))))
       (lambda () #f)
       "Move point to the end of the buffer."))

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

    (define *kill-buffer* (make-parameter ""))
    (define *this-command-kill* (make-parameter #f))
    (define *last-command-kill* (make-parameter #f))

    (define (rotate-kill-flag!)
      ;; mg's per-command flag rotation: the flags set by the command
      ;; that just ran become the flags the next command reads, so a
      ;; kill command can tell whether it continues a run of kills.
      ;;--------------------------------------------------------------
      (*last-command-kill* (*this-command-kill*))
      (*this-command-kill* #f))

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
      ;; Kill (cut) the text between the character indices START and
      ;; END into the kill buffer, following mg's CFKILL protocol:
      ;; consecutive kills accumulate, forward kills append at the
      ;; end of the kill buffer, backward kills prepend at the front.
      ;; Returns the killed text.
      ;;--------------------------------------------------------------
      (let* ((text (text-editor-copy-string ed start end)))
        (cond
         ((not (*last-command-kill*))
          (*kill-buffer* text))
         ((< start end)  ;; forward kill: append at the end
          (*kill-buffer* (string-append (*kill-buffer*) text)))
         (else           ;; backward kill: prepend at the front
          (*kill-buffer* (string-append text (*kill-buffer*)))))
        (*this-command-kill* #t)
        (text-editor-set-cursor ed (min start end))
        (text-editor-delete-from-cursor ed (abs (- end start)))
        text))

    (define forward-word
      ;; mg's `forwword` (word.c:51) with its numeric-argument loop: move
      ;; N words forward, stopping at the end of the buffer.
      (new-count-command
       "forward-word"
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-set-cursor
              (current-editor) (forward-word-position (current-editor)))
             (loop (+ 1 i)))))
       "Move point N words forward, to the end of each word."))

    (define backward-word
      ;; mg's `backword` (word.c:27) with its numeric-argument loop.
      (new-count-command
       "backward-word"
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-set-cursor
              (current-editor) (backward-word-position (current-editor)))
             (loop (+ 1 i)))))
       "Move point N words backward, to the start of each word."))

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

    (define kill-word
      ;; Like mg's `delfword` (word.c:397): kill from point to the end
      ;; of the next word. The N words are one kill, so they accumulate
      ;; into the kill buffer as a single entry.
      (new-count-command
       "kill-word"
       (lambda (count)
         (let* ((ed (current-editor))
                (start (text-editor-get-cursor ed))
                (end (word-run-end ed count)))
           (when (< start end)
             (kill-range ed start end #t))))
       "Kill N words forward from point."))

    (define backward-kill-word
      ;; Like mg's `delbword` (word.c:453): kill from the start of the
      ;; previous word to point.
      (new-count-command
       "backward-kill-word"
       (lambda (count)
         (let* ((ed (current-editor))
                (end (text-editor-get-cursor ed))
                (start (word-run-start ed count)))
           (when (< start end)
             (kill-range ed start end #f))))
       "Kill N words backward from point."))

    (define yank
      ;; mg's `yank` (yank.c:224) inserts the kill buffer N times.
      (new-count-command
       "yank"
       (lambda (count)
         (let ((text (*kill-buffer*)))
           (when (> (string-length text) 0)
             (let loop ((i 0))
               (when (< i count)
                 (text-editor-insert (current-editor) text)
                 (loop (+ 1 i)))))))
       "Insert the kill buffer at point, N times."))

    ;;----------------------------------------------------------------
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

    (define undo-command
      ;; GNU Emacs's `undo'. Repeating it undoes further back, and when
      ;; it reaches the end of the undo list the next one reports that
      ;; there is nothing left.
      (new-count-command
       "undo"
       (lambda (count)
         (let* ((frame (*current-frame*))
                (ed (current-editor))
                (pending
                 (if (eq? (*last-command*) undo-command)
                     ;; continue the run
                     (*pending-undo-list*)
                     ;; start a new run, from the front of the list
                     (strip-undo-boundaries (text-editor-undo-list ed)))))
           (if (not (list? pending))
               (set!ncurses-frame-message frame "No further undo information")
               (let ((rest (text-editor-undo ed pending count)))
                 ;; Emacs sets `pending-undo-list' to t once the run has
                 ;; reached the end; false is that state here, and it is
                 ;; what makes the next undo report that it is finished.
                 (*pending-undo-list* (if (null? rest) #f rest))
                 (*last-change-was-undo* #t)
                 (set!ncurses-frame-message frame "Undo")))))
       "Undo some previous changes."))

    (define undo-redo-command
      ;; GNU Emacs's `undo-redo': undo the undos. The records an undo
      ;; created are ordinary undo entries sitting at the front of the
      ;; list, so redoing one is undoing it - that is the whole of the
      ;; redo mechanism, and why there is no redo list.
      (new-count-command
       "undo-redo"
       (lambda (count)
         (let ((frame (*current-frame*)))
           (if (not (*last-change-was-undo*))
               (set!ncurses-frame-message frame "No undone changes to redo")
               (let* ((ed (current-editor))
                      (list (strip-undo-boundaries
                             (text-editor-undo-list ed))))
                 (if (not (pair? list))
                     (set!ncurses-frame-message
                      frame "No undone changes to redo")
                     (begin
                       (text-editor-undo ed list count)
                       (*last-change-was-undo* #t)
                       (set!ncurses-frame-message frame "Redo")))))))
       "Redo the last undone change, or the last COUNT undone changes."))

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
      (*prefix-negative* #f))

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
       ((not (*prefix-digits*))
        (* (if (*prefix-negative*) -1 1) (expt 4 (*prefix-cu*))))
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
        (prefix-keys-message)
        #t)
       ((and (*prefix-cu*)
             ;; Only while the prefix itself is being read. GNU Emacs
             ;; reads its digits through `universal-argument-map', which
             ;; is a transient keymap: a key that starts a chord - the
             ;; C of C-x - leaves it, and the keys of the chord are the
             ;; chord's, digits included. Without this the 2 of
             ;; `C-u 8 C-x 2' was taken as another digit of the prefix,
             ;; so the chord never completed and the argument became 82.
             (not (ncurses-frame-keymap-state (*current-frame*)))
             (= (length path) 1)
             (char? (car path))
             (char-numeric? (car path)))
        (*prefix-digits*
         (string-append (or (*prefix-digits*) "") (string (car path))))
        (prefix-keys-message)
        #t)
       (else #f)))

    (define (prefix-keys-message)
      ;; What the echo area shows while an argument is being typed: the
      ;; keys of it and a trailing dash, e.g. `C-u 8-'. GNU Emacs shows
      ;; exactly this, from its command loop rather than from any one
      ;; command, and it is why a half-typed argument is visible at all.
      ;;--------------------------------------------------------------
      (set!ncurses-frame-message
       (*current-frame*)
       (string-append
        (cond ((*prefix-cu*) (string-append "C-u "
                                            (or (*prefix-digits*) "")
                                            (if (*prefix-negative*) "-" "")))
              ((*prefix-digits*) (string-append (if (*prefix-negative*) "-" "")
                                                (*prefix-digits*)))
              (else "M--"))
        "-")))

    (define (last-command-event-digit)
      ;; The digit the key that reached this command spelled, or #f.
      ;; GNU Emacs's `digit-argument' reads it from
      ;; `last-command-event', masking the modifier bits off with
      ;; `(logand char ?\177)'. The key is re-derived here from the
      ;; frame's keymap lookup state, the way `self-insert-command'
      ;; re-derives its character - and the modifier bits are the
      ;; other elements of the chord, so nothing has to be masked.
      ;;--------------------------------------------------------------
      (let* ((state (ncurses-frame-keymap-state (*current-frame*)))
             (ix (and state (km:modal-lookup-state-key-index state)))
             (path (and ix (km:keymap-index->list ix)))
             (last (and (pair? path) (car (reverse path)))))
        (and (char? last)
             (char-numeric? last)
             (- (char->integer last) (char->integer #\0)))))

    (define digit-argument
      ;; GNU Emacs's `digit-argument': a digit typed with Meta adds
      ;; itself to the numeric argument for the next command.
      ;; `M-3 M-5 C-n' moves down thirty-five lines.
      ;;
      ;; It is a command and not part of `UPDATE-PREFIX!', because in
      ;; Emacs it is one: `esc-map' binds M-0 to M-9 to it, which is why
      ;; M-6 is not an undefined key there. What it receives is the raw
      ;; prefix argument, since `M-3 M-5' has to build on `M-3' rather
      ;; than start again.
      ;;--------------------------------------------------------------
      (new-command
       "digit-argument"
       (lambda (uarg)
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
             (unless (zerop digit)
               (*prefix-digits* (number->string digit))))
            (else
             (*prefix-negative* #f)
             (*prefix-digits* (number->string digit))))
           (prefix-keys-message)))
       (lambda (uarg) uarg)
       "Add the digit of this key to the numeric argument for the next command."
       'uarg))

    (define negative-argument
      ;; GNU Emacs's `negative-argument': M-- begins a negative numeric
      ;; argument, and a second M-- cancels it.
      ;;--------------------------------------------------------------
      (new-command
       "negative-argument"
       (lambda (uarg)
         (cond ((integer? uarg) (*prefix-negative* (not (< uarg 0))))
               ((eq? '- uarg) (*prefix-negative* #f))
               (else (*prefix-negative* #t)))
         (prefix-keys-message))
       (lambda (uarg) uarg)
       "Begin a negative numeric argument for the next command."
       'uarg))

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
    (define-key *default-keymap* (list (list 'ctrl #\m)) newline-command)
    (define-key *default-keymap* (list (list 'ctrl #\j)) newline-command)
    (define-key *default-keymap* (list (list 'ctrl #\g)) keyboard-quit)
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
      (list (list 'ctrl (integer->char 31))) undo-command)
    (define-key *default-keymap*
      (list (list 'meta 'ctrl (integer->char 31))) undo-redo-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\u) undo-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\q) read-only-mode)
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
