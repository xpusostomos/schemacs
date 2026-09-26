(define-library (schemacs apps ncurses-editor)
  ;; This library defines a minimal text editor frontend for the
  ;; `(schemacs editor engine)` library, rendered with the guile-ncurses
  ;; bindings. The editor engine is the single source of truth: the
  ;; terminal view never owns text, it only projects the engine's lines
  ;; onto the character grid, and routes key events back into editor
  ;; commands.
  ;;
  ;; This frontend deliberately bypasses the `(schemacs ui)` "div"
  ;; framework: a single-window editor does not need the div tree, and
  ;; hand-computed character-cell positions are the practical pattern
  ;; for a curses frontend (the same discipline the GTK debugui uses).
  ;;
  ;; Commands are named after their Emacs counterparts so the command
  ;; layer remains Elisp-compatible as the project matures.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    (scheme file)
    (scheme cxr)
    (only (scheme write) display write)
    (scheme char)
    (only (schemacs editor engine)
          new-text-editor text-load-port text-dump-port
          text-editor-char-count
          text-editor-insert text-editor-delete-from-cursor
          text-editor-move-cursor text-editor-set-cursor
          text-editor-get-cursor text-editor-cursor-line
          text-editor-cursor-column text-editor-get-start-of-line
          text-editor-get-end-of-line text-editor-line-count
          text-editor-copy-string
          text-editor-line-editor-ref
          text-editor-get-char-index
          text-editor-text-line-ref
          text-line->string text-line-inner->string
          line-break-newline line-break-crlf line-break-return
          text-editor-to-string)
    (only (schemacs editor command)
          new-command command-type? run-command)
    (prefix (schemacs keymap) km:)
    (ncurses curses)
    )

  (export
   main-ncurses
   *default-keymap*
   dispatch-key-event
   *current-frame*
   ncurses-frame-type?
   make<ncurses-frame>
   ncurses-frame-editor
   ncurses-frame-file-path
   ncurses-frame-top-row
   ncurses-frame-message
   prefix-arg-value
   render!
   with-terminal
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Editor state

    (define-record-type <ncurses-frame>
      (make<ncurses-frame>
       editor file-path top-row message keymap-state quit-cont esc-pending
       crlf?)
      ncurses-frame-type?
      (editor     ncurses-frame-editor     set!ncurses-frame-editor)
      ;; ^ The <text-editor-type> holding the buffer being edited.
      (file-path  ncurses-frame-file-path  set!ncurses-frame-file-path)
      ;; ^ The path the buffer was loaded from, or false for an
      ;; unnamed buffer.
      (top-row    ncurses-frame-top-row    set!ncurses-frame-top-row)
      ;; ^ The zero-based index of the engine line drawn at screen row
      ;; zero (the scroll offset).
      (message    ncurses-frame-message    set!ncurses-frame-message)
      ;; ^ A message string drawn in the echo area, or false.
      (keymap-state ncurses-frame-keymap-state set!ncurses-frame-keymap-state)
      ;; ^ A pending modal keymap lookup state, or false. It persists
      ;; between key events when a key chord (such as C-x C-s) is
      ;; partially entered.
      (quit-cont  ncurses-frame-quit-cont  set!ncurses-frame-quit-cont)
      ;; ^ An escape continuation captured by the event loop, invoked
      ;; by `save-buffers-kill-terminal` to exit the editor.
      (esc-pending ncurses-frame-esc-pending set!ncurses-frame-esc-pending)
      ;; ^ Whether an ESC key was just seen: the next key event is
      ;; dispatched with the `meta` modifier (the Emacs ASCII
      ;; protocol, where ESC prefixes meta keys).
      (crlf? ncurses-frame-crlf? set!ncurses-frame-crlf?)
      ;; ^ Whether the file's line-break convention is CRLF: carriage
      ;; returns are decoded away on load and encoded back on save.
      )

    ;; The frame currently dispatching a key event. Commands read the
    ;; frame through this parameter.
    (define *current-frame* (make-parameter #f))

    (define (current-editor)
      (ncurses-frame-editor (*current-frame*)))

    ;;----------------------------------------------------------------
    ;; Terminal setup

    (define (with-terminal thunk)
      ;; Run THUNK with the terminal in curses mode, restoring the
      ;; terminal even if THUNK raises an error.
      ;;--------------------------------------------------------------
      (dynamic-wind
        (lambda ()
          (initscr)
          (noecho!)
          ;; `raw!` (not `cbreak!`) so that C-c and C-z reach the
          ;; editor's keymap instead of raising signals.
          (raw!)
          (nonl!)
          (keypad! (stdscr) #t)
          (scrollok! (stdscr) #f)
          ;; disable the insert/delete-character optimizations: they
          ;; corrupt the display when lines merge (ncurses tracks a
          ;; virtual screen the terminal no longer matches)
          (idcok! (stdscr) #f)
          (idlok! (stdscr) #f)
          (curs-set 1)
          )
        thunk
        (lambda () (endwin))
        ))

    ;;----------------------------------------------------------------
    ;; Display expansion
    ;;
    ;; GNU Emacs renders a control character in the buffer as its
    ;; caret notation: the carriage return (a single character) is
    ;; drawn as the two-cell glyph ^M, and point takes one keystroke
    ;; to cross it. Tabs are drawn as whitespace up to the next tab
    ;; stop. This layer converts buffer characters to screen glyphs
    ;; and maps buffer columns to screen columns.
    ;;------------------------------------------------------------------

    (define *tab-width* (make-parameter 8))

    (define (char-display-glyph c col)
      ;; The display string for the buffer character C drawn at screen
      ;; column COL, and its width in screen cells is the string
      ;; length.
      ;;--------------------------------------------------------------
      (cond
       ((char=? c #\tab)
        (make-string
         (- (*tab-width*) (modulo col (*tab-width*)))
         #\space))
       ((and (char<? c #\space))
        (string #\^ (integer->char (+ 64 (char->integer c)))))
       ((= (char->integer c) 127)
        "^?")
       (else (string c))))

    (define (expand-line-display str width)
      ;; Expand a whole line string into its display form (caret
      ;; notation for control characters, tabs to tab stops), up to
      ;; WIDTH screen cells.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (let loop ((i 0) (col 0))
            (when (and (< i (string-length str)) (< col width))
              (let ((glyph (char-display-glyph (string-ref str i) col)))
                (display glyph port)
                (loop (+ i 1) (+ col (string-length glyph))))))
          (get-output-string port))))

    (define (current-line-display-column ed buffer-col)
      ;; The screen column at which buffer column BUFFER-COL of the
      ;; current line is drawn.
      ;;--------------------------------------------------------------
      (let loop ((j 0) (col 0))
        (if (>= j buffer-col)
            col
            (let ((ch (text-editor-line-editor-ref ed j)))
              (loop (+ 1 j)
                    (+ col (string-length
                            (char-display-glyph ch col))))))))

    ;;----------------------------------------------------------------
    ;; Rendering

    (define (ncurses-line-string frame i)
      ;; Get the displayable contents of line I (not including its
      ;; line break) as a string, or #f when I is past the end of the
      ;; buffer. The current line is read from the line editor, which
      ;; holds the live copy of the line under the cursor; every other
      ;; line is read from the lines gap-buffer.
      ;;--------------------------------------------------------------
      (let ((ed (ncurses-frame-editor frame)))
        (cond
         ((= i (text-editor-cursor-line ed))
          ;; The live current line: the line editor's characters, from
          ;; the start of the line to the end of the line.
          (call-with-port (open-output-string)
            (lambda (port)
              (let* ((start (text-editor-get-start-of-line ed))
                     (end   (text-editor-get-end-of-line ed))
                     (len   (- end start)))
                (let loop ((j 0))
                  (when (< j len)
                    (let ((ch (text-editor-line-editor-ref ed j)))
                      (when ch (write-char ch port)))
                    (loop (+ 1 j)))))
              (get-output-string port))))
         ((< i (text-editor-line-count ed))
          ;; the display form of the line: its contents WITHOUT the
          ;; terminating line break
          (text-line-inner->string (text-editor-text-line-ref ed i)))
         (else #f))))

    (define (view-height)
      ;; The number of screen rows available to the text view: the
      ;; terminal height minus the status line and the echo/minibuffer
      ;; line.
      (max 1 (- (lines) 2)))

    (define (truncate-line str width)
      (let ((len (string-length str)))
        (cond
         ((<= len width) str)
         ((<= width 0) "")
         (else (substring str 0 width)))))

    (define (pad-line str width)
      (let ((len (string-length str)))
        (cond
         ((< width len) (truncate-line str width))
         (else (string-append str (make-string (- width len) #\space))))))

    (define (scroll-to-cursor! frame)
      ;; Adjust the scroll offset so the cursor line is visible.
      ;;--------------------------------------------------------------
      (let* ((ed (ncurses-frame-editor frame))
             (cursor-line (text-editor-cursor-line ed))
             (vheight (view-height)))
        (cond
         ((< cursor-line (ncurses-frame-top-row frame))
          (set!ncurses-frame-top-row frame cursor-line))
         ((>= cursor-line (+ (ncurses-frame-top-row frame) vheight))
          (set!ncurses-frame-top-row
           frame (+ 1 (- cursor-line vheight)))
           ))))

    (define (status-string frame)
      (let* ((ed (ncurses-frame-editor frame))
             (file (or (ncurses-frame-file-path frame) "*scratch*")))
        (string-append
         "-- " file " -- L"
         (number->string (+ 1 (text-editor-cursor-line ed)))
         " C"
         (number->string (+ 1 (text-editor-cursor-column ed)))
         )))

    (define (render! frame)
      ;; Draw the text view, the status line, and the echo area, then
      ;; place the terminal cursor at the editor's cursor position.
      ;;--------------------------------------------------------------
      (scroll-to-cursor! frame)
      (let ((width (cols))
            (height (lines))
            (vheight (view-height))
            (ed (ncurses-frame-editor frame)))
        (erase (stdscr))
        ;; text view rows
        (let loop ((row 0))
          (when (< row vheight)
            (let* ((line-index (+ (ncurses-frame-top-row frame) row))
                   (line-string (ncurses-line-string frame line-index)))
              (when line-string
                (addstr (stdscr)
                        (expand-line-display line-string width)
                        #:y row #:x 0))
              (loop (+ 1 row))
              )))
        ;; status line
        (let ((status (status-string frame)))
          (attr-on! (stdscr) A_REVERSE)
          (addstr (stdscr) (pad-line status width) #:y (- height 2) #:x 0)
          (attr-off! (stdscr) A_REVERSE))
        ;; echo area
        (addstr (stdscr)
                (truncate-line (ncurses-frame-message frame) width)
                #:y (- height 1) #:x 0)
        ;; force a full repaint: partial-update optimizations (scroll
        ;; regions, insert/delete character) desync the physical
        ;; terminal when lines merge
        (clearok! (stdscr) #t)
        ;; place the terminal cursor at the editor cursor
        (let ((screen-row (- (text-editor-cursor-line ed)
                             (ncurses-frame-top-row frame))))
          (when (and (>= screen-row 0) (< screen-row vheight))
            (move (stdscr)
                  screen-row
                  (min (current-line-display-column
                        ed (text-editor-cursor-column ed))
                       (- width 1)))))
        (refresh (stdscr))
        ))


    ;;----------------------------------------------------------------
    ;; Commands
    ;;
    ;; Commands are named after their Emacs equivalents, so the
    ;; command layer remains Elisp-compatible. Each command takes no
    ;; arguments when dispatched; the API procedure (the second
    ;; lambda) takes real arguments and can be applied from Elisp
    ;; later, in the same way GNU Emacs distinguishes interactive
    ;; from programmatic calls.

    (define self-insert-command
      (new-command
       "self-insert-command"
       (lambda ()
         (let ((state (ncurses-frame-keymap-state (*current-frame*))))
           (when state
             (km:keymap-index-to-char
              (km:modal-lookup-state-key-index state) #f
              (lambda (c)
                (let loop ((i (prefix-arg-value)))
                  (when (> i 0)
                    (text-editor-insert (current-editor) c)
                    (loop (- i 1)))))
              (lambda () #f))
              )))
       (lambda (c) (text-editor-insert (current-editor) c))
       "Insert the typed character at point."))

    (define self-insert-tab
      (new-command
       "self-insert-tab"
       (lambda () (text-editor-insert (current-editor) #\tab))
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-insert (current-editor) #\tab)
             (loop (+ 1 i)))))
       "Insert a tab character at point."))

    (define forward-char
      (new-command
       "forward-char"
       (lambda () (text-editor-move-cursor (current-editor) (prefix-arg-value)))
       (lambda (count) (text-editor-move-cursor (current-editor) count))
       "Move point N characters forward."))

    (define backward-char
      (new-command
       "backward-char"
       (lambda () (text-editor-move-cursor (current-editor) (- (prefix-arg-value))))
       (lambda (count) (text-editor-move-cursor (current-editor) (- count)))
       "Move point N characters backward."))

    (define next-line
      (new-command
       "next-line"
       (lambda ()
         (text-editor-set-cursor
          (current-editor)
          (+ 1 (text-editor-cursor-line (current-editor)))
          (text-editor-cursor-column (current-editor))))
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-set-cursor
              (current-editor)
              (+ 1 (text-editor-cursor-line (current-editor)))
              (text-editor-cursor-column (current-editor)))
             (loop (+ 1 i)))))
       "Move point down N lines, keeping the column."))

    (define previous-line
      (new-command
       "previous-line"
       (lambda ()
         (text-editor-set-cursor
          (current-editor)
          (+ -1 (text-editor-cursor-line (current-editor)))
          (text-editor-cursor-column (current-editor))))
       (lambda (count)
         (let loop ((i 0))
           (when (< i count)
             (text-editor-set-cursor
              (current-editor)
              (+ -1 (text-editor-cursor-line (current-editor)))
              (text-editor-cursor-column (current-editor)))
             (loop (+ 1 i)))))
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
      (new-command
       "delete-char"
       (lambda () (text-editor-delete-from-cursor (current-editor) (prefix-arg-value)))
       (lambda (count)
         (text-editor-delete-from-cursor (current-editor) count))
       "Delete N characters after point."))

    (define backward-delete-char
      (new-command
       "backward-delete-char"
       (lambda () (text-editor-delete-from-cursor (current-editor) (- (prefix-arg-value))))
       (lambda (count)
         (text-editor-delete-from-cursor (current-editor) (- count)))
       "Delete N characters before point."))

    (define kill-line
      ;; Kill from point to the end of the line. At the end of the
      ;; line, kill the line break itself, joining the next line onto
      ;; this one (the same behavior as mg's `killline` and GNU Emacs
      ;; `kill-line`).
      (new-command
       "kill-line"
       (lambda ()
         (let* ((ed (current-editor))
                (cur (text-editor-get-cursor ed))
                (end (text-editor-get-end-of-line ed)))
           (if (= end cur)
               ;; at end of line: the line break is what gets killed
               (text-editor-delete-from-cursor ed 1)
               (text-editor-delete-from-cursor ed (- end cur)))))
       (lambda (count)
         (let* ((ed (current-editor))
                (cur (text-editor-get-cursor ed))
                (end (text-editor-get-end-of-line ed)))
           (text-editor-delete-from-cursor ed (- end cur))))
       "Delete text from point to the end of the current line."))

    (define newline
      (new-command
       "newline"
       (lambda () (text-editor-insert (current-editor) #\newline))
       (lambda () (text-editor-insert (current-editor) #\newline))
       "Insert a line break at point."))

    (define find-file-command
      (new-command
       "find-file"
       (lambda ()
         (let* ((frame (*current-frame*))
                (path (read-minibuffer frame "Find file: ")))
           (when path
             (guard (ex
                     (else
                      (set!ncurses-frame-message
                       frame (string-append
                              "; find-file: error loading " path))
                      #f))
               (let-values (((new-ed crlf?) (find-file path)))
                 (set!ncurses-frame-editor frame new-ed)
                 (set!ncurses-frame-crlf? frame crlf?))
               (set!ncurses-frame-file-path frame path)
               ;; a newly opened buffer starts at the beginning
               (text-editor-set-cursor
                (ncurses-frame-editor frame) 0 0)
               (set!ncurses-frame-top-row frame 0)
               (set!ncurses-frame-message frame "")
               path))))
       (lambda (path) #f)
       "Prompt for a file name and load it into the buffer."))

    (define save-buffer-command
      (new-command
       "save-buffer"
       (lambda ()
         (let* ((frame (*current-frame*))
                (path
                 (or (ncurses-frame-file-path frame)
                     ;; an unnamed buffer (the scratch buffer): prompt
                     ;; for the file name and remember it
                     (let ((name (read-minibuffer frame "File to save in: ")))
                       (when name
                         (set!ncurses-frame-file-path frame name))
                       name))))
           (when path
             (guard (ex
                     (else
                      (set!ncurses-frame-message
                       frame (string-append
                              "; save-buffer: error writing " path))
                      #f))
               (save-buffer frame)
               (set!ncurses-frame-message
                frame (string-append "Wrote " path))
               path))))
       (lambda () #f)
       "Write the buffer back to its file."))

    (define scroll-up-command
      ;; Scroll the view one screenful down (toward the end of the
      ;; buffer), with a two-line overlap, like mg's `forwpage`. If
      ;; the point falls outside the new window it moves to the top
      ;; of the window, column zero. Reports "End of buffer" when the
      ;; view cannot scroll further.
      (new-command
       "scroll-up-command"
       (lambda ()
         (let* ((frame (*current-frame*))
                (ed (current-editor))
                (n (max 1 (- (view-height) 2)))
                (count (text-editor-line-count ed))
                (new-top
                 (min (+ (ncurses-frame-top-row frame) n)
                      (max 0 (- count 1)))))
           (if (<= new-top (ncurses-frame-top-row frame))
               (set!ncurses-frame-message frame "; End of buffer")
               (begin
                 (set!ncurses-frame-top-row frame new-top)
                 (let ((line (text-editor-cursor-line ed)))
                   (when (or (< line new-top)
                             (>= line (+ new-top (view-height))))
                     (text-editor-set-cursor ed new-top 0)))))))
       (lambda (count) #f)
       "Scroll the view down one screenful."))

    (define scroll-down-command
      ;; Scroll the view one screenful up (toward the beginning of
      ;; the buffer), the mirror of `scroll-up-command`.
      (new-command
       "scroll-down-command"
       (lambda ()
         (let* ((frame (*current-frame*))
                (ed (current-editor))
                (n (max 1 (- (view-height) 2)))
                (new-top (max 0 (- (ncurses-frame-top-row frame) n))))
           (if (= new-top (ncurses-frame-top-row frame))
               (set!ncurses-frame-message frame "; Beginning of buffer")
               (begin
                 (set!ncurses-frame-top-row frame new-top)
                 (let ((line (text-editor-cursor-line ed)))
                   (when (or (< line new-top)
                             (>= line (+ new-top (view-height))))
                     (text-editor-set-cursor
                      ed (+ new-top (- (view-height) 1)) 0)))))))
       (lambda (count) #f)
       "Scroll the view up one screenful."))

    (define beginning-of-buffer
      (new-command
       "beginning-of-buffer"
       (lambda ()
         (let ((frame (*current-frame*)))
           (set!ncurses-frame-top-row frame 0)
           (text-editor-set-cursor (current-editor) 0 0)))
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

    (define keyboard-quit
      (new-command
       "keyboard-quit"
       (lambda ()
         (set!ncurses-frame-message (*current-frame*) "")
         (set!ncurses-frame-keymap-state (*current-frame*) #f))
       (lambda () #f)
       "Cancel the current action and clear the echo area."))

    (define save-buffers-kill-terminal
      (new-command
       "save-buffers-kill-terminal"
       (lambda ()
         ((ncurses-frame-quit-cont (*current-frame*)) 'quit))
       (lambda () #f)
       "Quit the editor (bound to C-x C-c)."))

    ;;----------------------------------------------------------------
    ;; Kill ring and word motion
    ;;
    ;; The kill ring follows mg's `yank.c` model: a single kill buffer
    ;; where consecutive kills accumulate (the CFKILL protocol from
    ;; mg's yank.c: the kill buffer is cleared only when the previous
    ;; command was not a kill), forward kills append at the end and
    ;; backward kills prepend at the front. A multi-entry ring with
    ;; M-y cycling can be added later.
    ;;------------------------------------------------------------------

    (define *kill-buffer* (make-parameter ""))
    (define *last-command-kill* (make-parameter #f))

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
        (*last-command-kill* #t)
        (text-editor-set-cursor ed (min start end))
        (text-editor-delete-from-cursor ed (abs (- end start)))
        text))

    (define forward-word
      (new-command
       "forward-word"
       (lambda ()
         (text-editor-set-cursor
          (current-editor) (forward-word-position (current-editor))))
       (lambda (count) #f)
       "Move point forward to the end of the next word."))

    (define backward-word
      (new-command
       "backward-word"
       (lambda ()
         (text-editor-set-cursor
          (current-editor) (backward-word-position (current-editor))))
       (lambda (count) #f)
       "Move point backward to the start of the previous word."))

    (define kill-word
      ;; Like mg's `delfword` (word.c:397): kill from point to the end
      ;; of the next word.
      (new-command
       "kill-word"
       (lambda ()
         (let* ((ed (current-editor))
                (start (text-editor-get-cursor ed))
                (end (forward-word-position ed)))
           (kill-range ed start end #t)))
       (lambda (count) #f)
       "Kill to the end of the next word."))

    (define backward-kill-word
      ;; Like mg's `delbword` (word.c:453): kill from the start of the
      ;; previous word to point.
      (new-command
       "backward-kill-word"
       (lambda ()
         (let* ((ed (current-editor))
                (start (backward-word-position ed))
                (end (text-editor-get-cursor ed)))
           (kill-range ed start end #f)))
       (lambda (count) #f)
       "Kill back to the start of the previous word."))

    (define yank
      (new-command
       "yank"
       (lambda ()
         (let ((text (*kill-buffer*)))
           (when (> (string-length text) 0)
             (text-editor-insert (current-editor) text)
             (*last-command-kill* #f))))
       (lambda () #f)
       "Insert the kill buffer at point."))

    ;;----------------------------------------------------------------
    ;; Prefix arguments
    ;;
    ;; The raw argument conventions of GNU Emacs and mg: C-u pressed
    ;; N times means the count 4^N (C-u = 4, C-u C-u = 16); digits
    ;; typed after C-u build a number which replaces the C-u count
    ;; (C-u 7 = 7, C-u 7 2 = 72). A command without digits after C-u
    ;; receives 4^N; commands read the value with `prefix-arg-value`
    ;; (or 1 when no prefix was typed). Any other command clears the
    ;; pending prefix.
    ;;------------------------------------------------------------------

    (define *prefix-cu* (make-parameter #f))
    (define *prefix-digits* (make-parameter #f))
    (define *prefix-arg* (make-parameter #f))

    (define (clear-prefix!)
      (*prefix-cu* #f)
      (*prefix-digits* #f))

    (define (prefix-arg-value)
      ;; The numeric prefix argument for the current command, or 1
      ;; when no prefix was typed.
      ;;--------------------------------------------------------------
      (or (*prefix-arg*) 1))

    (define (update-prefix! path)
      ;; Handle C-u and digit key events while a prefix is pending.
      ;; Returns #t when the event was consumed as part of the prefix.
      ;;--------------------------------------------------------------
      (cond
       ((and (= (length path) 2)
             (eq? (car path) 'ctrl)
             (char=? (cadr path) #\u))
        (*prefix-cu* (+ 1 (or (*prefix-cu*) 0)))
        (set!ncurses-frame-message
         (*current-frame*)
         (string-append
          "C-u"
          (or (and (*prefix-digits*)
                   (string-append " " (*prefix-digits*)))
              "")
          "-"))
        #t)
       ((and (*prefix-cu*)
             (= (length path) 1)
             (char? (car path))
             (char-numeric? (car path)))
        (*prefix-digits*
         (string-append (or (*prefix-digits*) "") (string (car path))))
        (set!ncurses-frame-message
         (*current-frame*)
         (string-append
          "C-u " (*prefix-digits*) "-"))
        #t)
       (else #f)))

    ;;----------------------------------------------------------------
    ;; Keymaps

    (define self-insert-layer
      ;; Catch all printable characters and bind them to
      ;; `self-insert-command`.
      (km:new-self-insert-keymap-layer
       #f
       (lambda (c) self-insert-command)
       (lambda () #f)))

    (define *default-keymap*
      (km:keymap
       '*default-keymap*
       (km:alist->keymap-layer
        `(((ctrl #\f) . ,forward-char)
          ((ctrl #\b) . ,backward-char)
          ((ctrl #\n) . ,next-line)
          ((ctrl #\p) . ,previous-line)
          ((ctrl #\a) . ,beginning-of-line)
          ((ctrl #\e) . ,end-of-line)
          ((ctrl #\d) . ,delete-char)
          ((ctrl #\h) . ,backward-delete-char)
          ((ctrl #\k) . ,kill-line)
          ((ctrl #\m) . ,newline)
          ((ctrl #\j) . ,newline)
          ((ctrl #\g) . ,keyboard-quit)
          ((ctrl #\i) . ,self-insert-tab)
          ((ctrl #\v) . ,scroll-up-command)
          ((meta #\v) . ,scroll-down-command)
          ((meta #\<) . ,beginning-of-buffer)
          ((meta #\>) . ,end-of-buffer)
          ((meta ctrl ,(integer->char 28)) . ,beginning-of-buffer)
          ((meta ctrl ,(integer->char 30)) . ,end-of-buffer)
          ((meta #\f) . ,forward-word)
          ((meta #\b) . ,backward-word)
          ((meta #\d) . ,kill-word)
          ((meta ctrl #\h) . ,backward-kill-word)
          ((ctrl #\y) . ,yank)
          (((ctrl #\x) (ctrl #\f)) . ,find-file-command)
          (((ctrl #\x) (ctrl #\s)) . ,save-buffer-command)
          (((ctrl #\x) (ctrl #\c)) . ,save-buffers-kill-terminal)
          ))
       self-insert-layer
       ))

    ;;----------------------------------------------------------------
    ;; Key events

    (define (ncurses-key->keymap-path ev)
      ;; Convert an ncurses key event to a keymap path: a list of
      ;; modifier symbols and characters (or #f when the event cannot
      ;; be converted). Keypad keys (arrow keys etc.) are mapped to
      ;; their Emacs control-key equivalents.
      ;;--------------------------------------------------------------
      (cond
       ((char? ev)
        (let ((ci (char->integer ev)))
          (cond
           ((char=? ev #\return) (list 'ctrl #\m))
           ((char=? ev #\newline) (list 'ctrl #\j))
           ((char=? ev #\esc) (list 'ctrl #\[))
           ((or (= ci 127) (char=? ev #\backspace))
            (list 'ctrl #\h))
           ((and (< 0 ci) (< ci 27))
            (list 'ctrl (integer->char (+ 96 ci))))
           ((and (>= ci 28) (< ci 32))
            (list 'ctrl (integer->char ci)))
           ((and (>= ci 32) (not (= ci 127)))
            (list ev))
           (else #f))))
       ((integer? ev)
        (cond
         ((= ev KEY_LEFT)  (list 'ctrl #\b))
         ((= ev KEY_RIGHT) (list 'ctrl #\f))
         ((= ev KEY_UP)    (list 'ctrl #\p))
         ((= ev KEY_DOWN)  (list 'ctrl #\n))
         ((= ev KEY_HOME)  (list 'ctrl #\a))
         ((= ev KEY_END)   (list 'ctrl #\e))
         ((= ev KEY_DC)    (list 'ctrl #\d))
         ((= ev KEY_BACKSPACE) (list 'ctrl #\h))
         ((= ev KEY_RESIZE) (list 'resize))
         (else #f)))
       (else #f)))

    (define (dispatch-action frame action)
      ;; Any non-kill command breaks a sequence of consecutive kills
      ;; (the CFKILL flag protocol); the kill commands set the flag
      ;; themselves. Any command consumes a pending prefix argument.
      (*last-command-kill* #f)
      (clear-prefix!)
      (set!ncurses-frame-message (*current-frame*) "")
      (cond
       ((command-type? action) (run-command action))
       ((procedure? action) (action))
       (else (error "not a command" action))))

    (define (dispatch-key-event frame path)
      ;; Dispatch one key event through the modal keymap lookup. The
      ;; modal lookup state persists across events while a chord
      ;; (such as C-x C-c) is being entered. C-u and digits are
      ;; consumed as prefix arguments before the keymap lookup. When
      ;; a command key arrives, the pending prefix is captured into
      ;; *prefix-arg* and the command is dispatched normally.
      ;;--------------------------------------------------------------
      (if (update-prefix! path)
          ;; C-u or a prefix digit was consumed
          (begin
            (set!ncurses-frame-keymap-state frame #f)
            (*last-command-kill* #f))
          ;; a command key: capture the pending prefix, if any
          (begin
            (*prefix-arg*
             (cond
              ((not (*prefix-cu*)) #f)
              ((not (*prefix-digits*)) (expt 4 (*prefix-cu*)))
              (else (string->number (*prefix-digits*)))))
            (*prefix-cu* #f)
            (*prefix-digits* #f)
            (let ((state
                   (or (ncurses-frame-keymap-state frame)
                       (km:new-modal-lookup-state *default-keymap*))))
              ;; NOTE: the state must be stored on the frame BEFORE the
              ;; lookup step, because commands dispatched by the step
              ;; (such as `self-insert-command`) read the key index of
              ;; the chord from the frame's state.
              (set!ncurses-frame-keymap-state frame state)
              (let ((result
                     (km:modal-lookup-state-step!
                      state (km:keymap-index path)
                      (lambda (full-path action)
                        (dispatch-action frame action) #f)
                      (lambda (full-path action) #t)
                      (lambda (full-path)
                        (set!ncurses-frame-message
                         frame
                         (string-append
                          "; undefined key: "
                          (call-with-port (open-output-string)
                            (lambda (port)
                              (write (km:keymap-index->list full-path) port)
                              (get-output-string port)))))))))
                (set!ncurses-frame-keymap-state
                 frame (and result state)))))))

    (define (read-minibuffer frame prompt)
      ;; A synchronous modal prompt in the echo area: reads characters
      ;; until RET (returns the entered string) or C-g (returns #f).
      ;; Keypad keys are mapped to their control-key equivalents, so
      ;; the arrow keys are ignored and Backspace deletes. End of
      ;; input cancels.
      ;;--------------------------------------------------------------
      (let loop ((buf (list)))
        (set!ncurses-frame-message
         frame (string-append prompt (list->string (reverse buf))))
        (render! frame)
        (let ((ev (getch (stdscr))))
          (cond
           ((and (integer? ev) (= ev ERR)) #f)
           ((and (char? ev)
                 (or (char=? ev #\backspace) (= (char->integer ev) 127)))
            (loop (if (null? buf) buf (cdr buf))))
           ((and (integer? ev) (= ev KEY_BACKSPACE))
            (loop (if (null? buf) buf (cdr buf))))
           ((and (char? ev)
                 (or (char=? ev #\return) (char=? ev #\newline)))
            (list->string (reverse buf)))
           ((and (char? ev)
                 (or (= (char->integer ev) 7)   ;C-g
                     (= (char->integer ev) 27))) ;ESC
            #f)
           ((char? ev) (loop (cons ev buf)))
           (else (loop buf))))))

    ;;----------------------------------------------------------------
    ;; Event loop

    (define (event-loop frame)
      ;; Read key events from the terminal and dispatch them until
      ;; `save-buffers-kill-terminal` escapes through the frame's quit
      ;; continuation.
      ;;--------------------------------------------------------------
      (parameterize ((*current-frame* frame))
        (render! frame)
        (call/cc
         (lambda (k)
           (set!ncurses-frame-quit-cont frame k)
           (let loop ()
             (let ((ev (getch (stdscr))))

               ;; ERR (-1) means end of input: leave the event loop.
               (when (and (integer? ev) (= ev ERR))
                 (let ((k (ncurses-frame-quit-cont frame)))
                   (when k (k 'eof))))
               (let ((path (ncurses-key->keymap-path ev)))
                 (cond
                  ;; ESC prefixes the next key with the meta modifier
                  ((and (char? ev) (char=? ev #\esc))
                   (set!ncurses-frame-esc-pending frame #t))
                  ((and path (ncurses-frame-esc-pending frame))
                   (set!ncurses-frame-esc-pending frame #f)
                   (dispatch-key-event frame (cons 'meta path))
                   )
                  ((and path (eq? 'resize (car path)))
                   (set!ncurses-frame-message frame "")
                   (set!ncurses-frame-esc-pending frame #f))
                  (path
                   (set!ncurses-frame-esc-pending frame #f)
                   (dispatch-key-event frame path))
                  (else
                   (set!ncurses-frame-esc-pending frame #f)
                   (set!ncurses-frame-message
                    frame
                    (string-append
                     "; unhandled event: "
                     (if (integer? ev)
                         (number->string ev)
                         (string ev)))))))
               (render! frame))
             (loop)
             )))))

    ;;----------------------------------------------------------------
    ;; File I/O

    (define (detect-line-break contents)
      ;; Detect the line-break protocol from the first line break in
      ;; the file contents, the way mg does on file load: CRLF, CR or
      ;; LF, defaulting to LF. Files with mixed line breaks get the
      ;; protocol of their first break.
      ;;--------------------------------------------------------------
      (let scan ((i 0) (n (string-length contents)))
        (cond
         ((>= i n) line-break-newline)
         ((char=? (string-ref contents i) #\newline)
          line-break-newline)
         ((char=? (string-ref contents i) #\return)
          (if (and (< (+ i 1) n)
                   (char=? (string-ref contents (+ i 1)) #\newline))
              line-break-crlf
              line-break-return))
         (else (scan (+ i 1) n)))))

    (define (string-has-crlf? str)
      ;; Whether the string's first line break is a CRLF pair (the
      ;; file's line-break convention, the way mg and GNU Emacs
      ;; detect it on file visit).
      ;;--------------------------------------------------------------
      (let scan ((i 0) (n (string-length str)))
        (cond
         ((>= i n) #f)
         ((char=? (string-ref str i) #\newline) #f)
         ((char=? (string-ref str i) #\return) #t)
         (else (scan (+ i 1) n)))))

    (define (decode-dos-returns str)
      ;; Decode the file's CRLF pairs into line feeds: the carriage
      ;; return of every CR-LF pair is removed, the way GNU Emacs's
      ;; coding system decodes a DOS file on visit. A stray carriage
      ;; return NOT followed by a line feed stays in the buffer, where
      ;; the display layer draws it as the two-cell glyph ^M (one
      ;; character to cross).
      ;;--------------------------------------------------------------
      (let* ((n (string-length str)))
        (let loop ((i 0) (acc (list)))
          (if (>= i n)
              (list->string (reverse acc))
              (let ((c (string-ref str i)))
                (if (and (char=? c #\return)
                         (< (+ i 1) n)
                         (char=? (string-ref str (+ i 1)) #\newline))
                    (loop (+ i 1) acc)
                    (loop (+ i 1) (cons c acc))))))))

    (define (find-file path)
      ;; Open a file into a new text editor buffer, the way GNU Emacs
      ;; visits a file: the line-break convention is detected (CRLF
      ;; or LF), every carriage return is decoded away so the buffer
      ;; holds only line-feed breaks, and the convention is recorded
      ;; so saving can encode the breaks back.
      ;;--------------------------------------------------------------
      (let* ((contents
              (call-with-input-file path
                (lambda (port)
                  (let loop ((acc (list)))
                    (let ((c (read-char port)))
                      (if (eof-object? c)
                          (list->string (reverse acc))
                          (loop (cons c acc))))))))
             (crlf? (string-has-crlf? contents))
             (ed (new-text-editor)))
        (text-editor-insert ed (decode-dos-returns contents))
        (values ed crlf?)))

    (define (encode-line-breaks str crlf?)
      ;; Encode the buffer's line-feed breaks back into the file's
      ;; line-break convention on save.
      ;;--------------------------------------------------------------
      (if (not crlf?)
          str
          (call-with-port (open-output-string)
            (lambda (port)
              (string-for-each
               (lambda (c)
                 (if (char=? c #\newline)
                     (begin (write-char #\return port)
                            (write-char #\newline port))
                     (write-char c port)))
               str)
              (get-output-string port)))))

    (define (save-buffer frame)
      ;; Write the editor buffer back to its file, encoding the line
      ;; breaks into the file's convention.
      ;;--------------------------------------------------------------
      (call-with-output-file
          (ncurses-frame-file-path frame)
        (lambda (port)
          (display
           (encode-line-breaks
            (text-editor-to-string (ncurses-frame-editor frame))
            (ncurses-frame-crlf? frame))
           port))
        ))

    ;;----------------------------------------------------------------
    ;; Main entry

    (define (main-ncurses . args)
      ;; With a file argument, load the file; with no arguments, start
      ;; with an empty unnamed buffer (the scratch buffer).
      ;;------------------------------------------------------------------
      (let ((frame
             (if (pair? args)
                 (let-values (((ed crlf?) (find-file (car args))))
                   (text-editor-set-cursor ed 0 0)
                   (make<ncurses-frame>
                    ed (car args) 0 "" #f #f #f crlf?))
                 (make<ncurses-frame>
                  (new-text-editor) #f 0 "" #f #f #f #f))))
        (with-terminal
         (lambda ()
           (event-loop frame)
           ))))
	)
  )
  
