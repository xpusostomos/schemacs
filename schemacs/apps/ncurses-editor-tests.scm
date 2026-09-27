(import
 (scheme base)
 (scheme char)
 (scheme file)
 (only (guile) chmod mkdir sort)
 (only (ice-9 exceptions) exception-message)
 (prefix (schemacs keymap) km:)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor engine)
       new-text-editor set!text-editor-buffer-name set!text-editor-mark
       text-editor-char-count text-editor-get-cursor text-editor-insert
       text-editor-mark text-editor-move-cursor text-editor-set-cursor
       text-editor-set-modified! text-editor-set-read-only!
       text-editor-to-string text-editor-undo-list)
 (only (schemacs editor frame)
       *current-frame* *echo-area-buffer* *echo-area-prompt* *minibuffer*
       frame-height ncurses-frame-editor ncurses-frame-message
       ncurses-frame-selected-window new-frame set!window-buffer
       window-internal?
       window-list
       set!window-height set!window-width
       set-window-point! window-body-width window-buffer window-edges
       window-height window-point window-right-border? window-top
       window-width)
 (only (schemacs editor keyboard)
       dispatch-key-event dispatch-ncurses-event ncurses-key->keymap-path)
 (only (schemacs editor keymap) *current-keymap* *default-keymap*)
 (only (schemacs editor buff-menu)
       *Buffer-menu-del-char* *Buffer-menu-marks* Buffer-menu-buffer
       Buffer-menu-execute Buffer-menu--set-mark! Buffer-menu-redraw!
       list-buffers-noselect)
 (only (guile) string-split)
 (only (schemacs editor command) run-command)
 (only (schemacs editor buffer)
       *buffer-list* *current-buffer* *kill-buffer-query-functions*
       buffer-list buffer-name get-buffer get-buffer-create
       buffer-local-keymap set!buffer-local-keymap)
 (only (schemacs editor engine) text-editor-insert text-editor-read-only?)
 (only (schemacs editor files)
       *require-final-newline* ensure-final-newline-on-visit
       file-name-completion-table file-name-directory-part
       file-name-nondirectory-part find-file note-file-read-only!
       save-answer-char->decision)
 ;; `try-completion' and `all-completions' are `minibuf.c''s.
 (only (schemacs editor minibuf) all-completions try-completion)
 (only (schemacs editor minibuffer)
       make<minibuffer> minibuffer-contents
       minibuffer-cursor-column minibuffer-history
       minibuffer-local-completion-map minibuffer-local-map minibufferp)
 (only (schemacs editor simple)
       *kill-buffer* *last-change-was-undo* *last-command* read-only-mode
       *last-command-kill* *pending-undo-list* *this-command-kill*
       pending-uarg)
 (only (schemacs editor isearch)
       *search-case-fold?* *search-pattern* isearch-find isearch-message)
 (only (schemacs editor window)
       delete-window delete-other-windows get-buffer-window
       other-window-command split-window-below split-window-right
       switch-to-buffer)
 (only (schemacs editor xdisp)
       *mode-line-format* cursor-screen-position format-mode-line
       mode-line-string status-string)
 (only (schemacs editor command)
       command-name command-type?)
 )

;; Regression tests for the ncurses frontend's key dispatch: the
;; universal argument (C-u) and the kill ring.
;;
;; The tests drive the frontend the way the event loop does - as a
;; stream of ncurses key events through `ncurses-key->keymap-path' -
;; rather than as keymap paths, because the translation from a
;; keystroke to a path is itself part of what can break (TAB arrives as
;; `#\tab' but is bound as C-i, and the arrow keys arrive as integers).
;; Only `dispatch-key-event' is called, so no terminal is opened and the
;; whole file runs headless.

;;--------------------------------------------------------------------
;; Harness

(define (test-frame ed)
  ;; A frame over a 24x80 screen with one window filling it, showing ED,
  ;; which is what `(new-frame ed)' makes when a terminal is open. These
  ;; tests open none, so the size is given rather than asked for.
  ;;--------------------------------------------------------------
  (new-frame ed 24 80))

(define (run-keys* text evs)
  ;; Load TEXT into a fresh buffer, run EVS over it, and return
  ;; (buffer-contents cursor-index kill-buffer echo-message). The kill
  ;; ring, the flags it works with and the undo state are module state,
  ;; so bind them fresh for every run: otherwise one test's kills leak
  ;; into the next.
  ;;--------------------------------------------------------------
  (let* ((ed (new-text-editor))
         (frame (test-frame ed)))
    (parameterize ((*current-frame* frame)
                   (*search-pattern* #f)
                   (*search-case-fold?* #t)
                   (*kill-buffer* "")
                   (*this-command-kill* #f)
                   (*last-command-kill* #f)
                   (*last-command* #f)
                   (*pending-undo-list* #f)
                   (*last-change-was-undo* #f)
                   (*buffer-list* '())
                   (*current-buffer* #f)
                   (*kill-buffer-query-functions* '()))
      (text-editor-insert ed text)
      (text-editor-set-cursor ed 0 0)
      (for-each (lambda (ev) (dispatch-ncurses-event frame ev)) evs)
      (list (text-editor-to-string ed)
            (text-editor-get-cursor ed)
            (*kill-buffer*)
            (ncurses-frame-message frame)))))

(define (run-keys text evs)
  ;; The buffer contents and cursor of RUN-KEYS*, which is what most
  ;; tests are about.
  ;;--------------------------------------------------------------
  (let ((result (run-keys* text evs)))
    (cons (car result) (cadr result))))

(define (letters n)
  ;; N lowercase letters, for exercising runs of self-inserting
  ;; characters.
  ;;--------------------------------------------------------------
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (integer->char (+ 97 (modulo i 26))) acc)))))

;; The key events used below.
(define C-u (integer->char 21))
(define C-k (integer->char 11))
(define C-y (integer->char 25))
(define C-d (integer->char 4))
(define C-n (integer->char 14))
(define C-p (integer->char 16))
(define C-f (integer->char 6))
(define C-a (integer->char 1))
(define C-b (integer->char 2))
(define C-e (integer->char 5))
(define C-g (integer->char 7))
(define C-underscore (integer->char 31))   ; C-_ and C-/ are the same byte
(define C-x (integer->char 24))
(define ESC #\esc)

;;--------------------------------------------------------------------
;; The universal argument

(test-begin "schemacs_ncurses_editor_prefix_argument")

;; A bare C-u is 4, C-u C-u is 16, and digits typed after C-u replace
;; the count.
(test-equal '("aaaaX" . 4) (run-keys "X" (list C-u #\a)))
(test-equal '("aaaX" . 3) (run-keys "X" (list C-u #\3 #\a)))
(test-equal (cons (string-append (make-string 16 #\a) "X") 16)
  (run-keys "X" (list C-u C-u #\a)))

;; The prefix reaches every count-taking command, not just self-insert.
(test-equal '("\t\t\t\tX" . 4) (run-keys "X" (list C-u #\tab)))
(test-equal '("\n\n\n\nX" . 4) (run-keys "X" (list C-u #\return)))
(test-equal '("o" . 0) (run-keys "hello" (list C-u C-d)))
(test-equal '("a\nb\nc\nd\ne" . 8) (run-keys "a\nb\nc\nd\ne" (list C-u C-n)))
(test-equal '("one two three four" . 18)
  (run-keys "one two three four" (list C-u ESC #\f)))

;; The prefix is pending state: it survives the keys of a chord and is
;; consumed when a command finally runs.
(test-equal 4
  (let* ((ed (new-text-editor))
        (frame (test-frame ed)))
    (parameterize ((*current-frame* frame))
      (dispatch-key-event frame (ncurses-key->keymap-path C-u))
      (dispatch-key-event frame (ncurses-key->keymap-path (integer->char 24)))
      (pending-uarg))))

(test-equal #f
  (let* ((ed (new-text-editor))
        (frame (test-frame ed)))
    (parameterize ((*current-frame* frame))
      (dispatch-key-event frame (ncurses-key->keymap-path C-u))
      (dispatch-key-event frame (ncurses-key->keymap-path #\a))
      (pending-uarg))))

;; An undefined key ends the chord and discards the prefix with it.
(test-equal #f
  (let* ((ed (new-text-editor))
        (frame (test-frame ed)))
    (parameterize ((*current-frame* frame))
      (dispatch-key-event frame (ncurses-key->keymap-path C-u))
      (dispatch-key-event frame (ncurses-key->keymap-path (integer->char 24)))
      (dispatch-key-event frame (ncurses-key->keymap-path #\a))
      (pending-uarg))))

(test-end "schemacs_ncurses_editor_prefix_argument")

;;--------------------------------------------------------------------
;; The kill ring

(test-begin "schemacs_ncurses_editor_kill_ring")

;; C-k kills into the kill buffer, so C-y brings the text back. This
;; covers single-line buffers too, whose first character used to be
;; dropped by `text-editor-copy-string'.
(test-equal '("hello\nworld" . 5) (run-keys "hello\nworld" (list C-k C-y)))
(test-equal '("one two" . 7) (run-keys "one two" (list C-k C-y)))
(test-equal '("X" . 1) (run-keys "X" (list C-k C-y)))

;; Consecutive kills accumulate into one kill-buffer entry (the CFKILL
;; protocol), and any command that is not a kill starts a new entry.
(test-equal "hello\n" (caddr (run-keys* "hello\nworld" (list C-k C-k))))
(test-equal "one two" (caddr (run-keys* "one two three" (list ESC #\d ESC #\d))))
(test-equal "two" (caddr (run-keys* "one two three" (list ESC #\d C-f ESC #\d))))

;; ... and the accumulated entry is what C-y brings back.
(test-equal '("hello\nworld" . 6) (run-keys "hello\nworld" (list C-k C-k C-y)))

;; A prefix argument repeats the yank.
(test-equal '("XXXXX" . 5) (run-keys "X" (list C-k C-y C-u C-y)))

;; Kill-line follows mg's `killline': no argument kills to the end of
;; the line, taking the line break when only blanks remain before it.
(test-equal '("foobar" . 3) (run-keys "foo   \nbar" (list C-f C-f C-f C-k)))
(test-equal '("foo\nbaz" . 3) (run-keys "foo bar\nbaz" (list C-f C-f C-f C-k)))

;; ... with a numeric argument it kills that many lines, the last one's
;; break included, and with an argument of 0 it kills backward to the
;; start of the line.
(test-equal '("c\nd" . 0) (run-keys "a\nb\nc\nd" (list C-u #\2 C-k)))
(test-equal '("b" . 0) (run-keys "a\nb" (list C-u #\1 C-k)))
(test-equal '("c" . 0) (run-keys "abc" (list C-f C-f C-u #\0 C-k)))

;; Killing words with a prefix argument kills them as a single entry.
(test-equal "one two three" (caddr (run-keys* "one two three" (list C-u ESC #\d))))
(test-equal '("one two three" . 13)
  (run-keys "one two three" (list C-u ESC #\d C-y)))

(test-end "schemacs_ncurses_editor_kill_ring")

;;--------------------------------------------------------------------
;; Undo

(test-begin "schemacs_ncurses_editor_undo")

;; Typing is amalgamated: a run of self-inserting characters is one undo
;; step, so undoing after typing a word removes the whole word. Point
;; ends where the undone text began, as in GNU Emacs.
(test-equal '("X" . 0) (run-keys "X" (list #\a #\b #\c C-underscore)))

;; A command that edits the buffer is a step of its own.
(test-equal '("abc" . 0) (run-keys "abc" (list #\K C-underscore)))

;; Repeating the undo walks further back: the first restores what the
;; kill removed (leaving point where the killed text began), the second
;; takes back the typing before it.
(test-equal '("abK" . 2)
  (run-keys "K" (list #\a #\b C-k C-underscore)))
(test-equal '("K" . 0)
  (run-keys "K" (list #\a #\b C-k C-underscore C-underscore)))

;; A command that changes nothing is not a step of its own; undo goes to
;; the last thing that actually changed. C-d here deleted the third
;; character, and undo puts it back with point at its beginning.
(test-equal '("abc" . 2)
  (run-keys "abc" (list C-f C-f C-d C-underscore)))

;; C-x u is the same command as C-_ (both are bound to `undo').
(test-equal '("X" . 0) (run-keys "X" (list #\a C-x #\u)))

;; A prefix argument undoes that many change groups. The C-k in the
;; middle kills nothing (point is at the end of the buffer, which has no
;; line break to take), so it contributes no group and the three groups
;; undone are the two inserts and the kill between them.
(test-equal '("K" . 0)
  (run-keys "K" (list #\a C-k #\b C-k C-u #\3 C-underscore)))

;; When the undo list is exhausted there is nothing further to undo.
(test-equal "No further undo information"
  (cadddr (run-keys* "abc" (list C-underscore C-underscore))))

;; Redo re-applies what was undone: the records an undo creates are
;; ordinary undo entries, so redoing one is undoing it.
(test-equal '("abX" . 0) (run-keys "X" (list #\a #\b C-underscore ESC C-underscore)))
(test-equal "Redo"
  (cadddr (run-keys* "X" (list #\a C-underscore ESC C-underscore))))

;; ... and redo without a preceding undo is refused.
(test-equal "No undone changes to redo"
  (cadddr (run-keys* "X" (list ESC C-underscore))))

;; Undoing a kill does not disturb the kill ring: the killed text is
;; still there to be yanked again (Emacs's undo deletes without touching
;; the kill ring).
(test-equal '("XX" . 1)
  (run-keys "X" (list C-k C-underscore C-y)))

;; Visiting a file leaves nothing to undo: the buffer's contents are not
;; an edit the user made.
(test-equal '(() "loaded\ntext\n")
  (begin
    (call-with-output-file "/tmp/schemacs-fe-undo.txt"
      (lambda (port) (display "loaded\ntext\n" port)))
    (let ((ed (find-file "/tmp/schemacs-fe-undo.txt")))
      (list (text-editor-undo-list ed) (text-editor-to-string ed)))))

;; Amalgamation is bounded: a boundary goes in every
;; `amalgamating-undo-limit' (20) commands, so a run of 21 self-inserts
;; undoes as the last character, then as the twenty before it.
(test-equal '("abcdefghijklmnopqrst" . 20)
  (run-keys "" (append (letters 21) (list C-underscore))))
(test-equal '("" . 0)
  (run-keys "" (append (letters 21) (list C-underscore C-underscore))))
(test-equal '("" . 0)
  (run-keys "" (append (letters 20) (list C-underscore))))

(test-end "schemacs_ncurses_editor_undo")

;;--------------------------------------------------------------------
;; The modified flag and the status line

(test-begin "schemacs_ncurses_editor_modified")

(define (with-file-buffer path contents thunk . opts)
  ;; Visit CONTENTS in a buffer whose file is PATH, run THUNK on the
  ;; frame, and return (status-line . file-contents-now). When OPTS
  ;; holds the symbol `read-only', the file is made unwritable first,
  ;; the way visiting someone else's file goes.
  ;;--------------------------------------------------------------
  ;; in case an earlier test left the file here read-only
  (when (file-exists? path) (chmod path #o644))
  (call-with-output-file path (lambda (port) (display contents port)))
  (when (memq 'read-only opts) (chmod path #o444))
  ;; the buffer list is bound fresh for every test: `find-file' answers
  ;; with the buffer already visiting the file when there is one, so a
  ;; buffer left over from an earlier test would be the one this test got
  (parameterize ((*buffer-list* '())
                 (*current-buffer* #f)
                 (*kill-buffer-query-functions* '()))
   (let ((ed (find-file path)))
    (let ((frame (test-frame ed)))
      (parameterize ((*current-frame* frame)
                     (*search-pattern* #f)
                     (*search-case-fold?* #t)
                     (*kill-buffer* "")
                     (*this-command-kill* #f)
                     (*last-command-kill* #f)
                     (*last-command* #f)
                     (*pending-undo-list* #f)
                     (*last-change-was-undo* #f))
        ;; as `find-file-command' does: the file's buffer is shown in the
        ;; selected window - inside the frame binding, because
        ;; `switch-to-buffer' acts on the selected window, as in Emacs. The
        ;; line-break convention is the buffer's own - `find-file' recorded
        ;; it there - so there is nothing to adopt.
        (switch-to-buffer ed)
        ;; what `find-file-command' does after installing the new buffer
        (note-file-read-only! frame)
        (thunk frame)
        (cons (status-string frame)
              (call-with-input-file path
                (lambda (port)
                  (let loop ((acc '()))
                    (let ((c (read-char port)))
                      (if (eof-object? c)
                          (list->string (reverse acc))
                          (loop (cons c acc)))))))))))))

(define (type frame . evs)
  (for-each (lambda (ev) (dispatch-ncurses-event frame ev)) evs))

(define save-key (integer->char 19))   ; C-x C-s

;; A buffer just visited is unmodified: the status line starts with the
;; two cells GNU Emacs's mode line uses for that, `--'.
(test-equal "--"
  (substring (car (with-file-buffer "/tmp/fe-mod.txt" "orig\n"
                    (lambda (frame) #f)))
             0 2))

;; Typing marks it modified (`**'), and saving marks it unmodified again
;; while actually writing the file.
(test-equal '("**" "orig\n" "--" "Xorig\n")
  (append
   (let ((result (with-file-buffer "/tmp/fe-mod.txt" "orig\n"
                   (lambda (frame) (type frame #\X)))))
     (list (substring (car result) 0 2) (cdr result)))
   (let ((result (with-file-buffer "/tmp/fe-mod.txt" "orig\n"
                   (lambda (frame)
                     (type frame #\X)
                     (type frame (integer->char 24) save-key)))))
     (list (substring (car result) 0 2) (cdr result)))))

;; Undoing back to the saved state makes the buffer unmodified again,
;; and redoing makes it modified again - the status line follows.
(test-equal '("**" "--" "**")
  (let ((states '()))
    (with-file-buffer "/tmp/fe-mod.txt" "orig\n"
      (lambda (frame)
        (type frame #\X (integer->char 24) save-key)   ; save "Xorig"
        (type frame #\Y)                               ; "YXorig"
        (set! states (cons (substring (status-string frame) 0 2) states))
        (type frame C-underscore)                      ; undo the Y
        (set! states (cons (substring (status-string frame) 0 2) states))
        (type frame ESC C-underscore)                  ; redo it
        (set! states (cons (substring (status-string frame) 0 2) states))))
    (reverse states)))

;; The line-break convention is the buffer's own, not the frame's: the
;; buffer visiting the CRLF file saves it with CRLF however many other
;; files have been visited in between. It used to be a slot on the frame,
;; so visiting an LF file after a CRLF one rewrote the CRLF file with LF -
;; and visiting a CRLF file after an LF one the other way round. It is
;; `buffer-file-coding-system' on the buffer now, as in Emacs.
(test-equal "Xa\r\nb\r\n"
  (cdr (with-file-buffer "/tmp/fe-crlf.txt" "a\r\nb\r\n"
         (lambda (frame)
           ;; visit an LF file - this is what used to overwrite the
           ;; frame's idea of the convention
           (call-with-output-file "/tmp/fe-lf.txt"
             (lambda (port) (display "c\nd\n" port)))
           (find-file "/tmp/fe-lf.txt")
           ;; back to the CRLF buffer, change it, and save it
           (switch-to-buffer (get-buffer "fe-crlf.txt"))
           (type frame #\X)
           (type frame (integer->char 24) save-key)))))

;; The answer to "Save file X? " decides what happens: y, SPC and ! save
;; the buffer, and n, DEL, q, RET (and end of input) leave it alone.
;; C-g is not among these: it leaves the minibuffer and signals quit, so
;; the whole command is abandoned rather than the answer being read.
(test-equal '(save save save skip skip skip skip skip skip)
  (map save-answer-char->decision
       (list #\y #\space #\! #\n (integer->char 127) #\q #\return #\z
             #f)))

(test-end "schemacs_ncurses_editor_modified")

;;--------------------------------------------------------------------
;; Read-only buffers

(test-begin "schemacs_ncurses_editor_read_only")

(define (visit* path contents keys . opts)
  ;; Visit CONTENTS at PATH, run KEYS, and return (status-indicator
  ;; echo-message file-contents buffer-contents). The buffer and the
  ;; file are both reported because the interesting cases are the ones
  ;; where they differ - an edit that was refused, or one that was made
  ;; but not saved.
  ;;--------------------------------------------------------------
  (let ((message #f)
        (buffer #f))
    (let ((result (apply with-file-buffer path contents
                         (lambda (frame)
                           (for-each (lambda (ev) (dispatch-ncurses-event frame ev))
                                     keys)
                           (set! message (ncurses-frame-message frame))
                           (set! buffer (text-editor-to-string
                                         (ncurses-frame-editor frame))))
                         opts)))
      (list (substring (car result) 0 2) message (cdr result) buffer))))

;; Visiting a file that cannot be written makes the buffer read-only,
;; and the status line says so with GNU Emacs's `%%' - along with the
;; warning Emacs gives at that point rather than at the first refused
;; edit.
(test-equal '("%%" "Note: file is write protected" "content\n" "content\n")
  (visit* "/tmp/fe-ro.txt" "content\n" '() 'read-only))

;; A writable file is neither.
(test-equal '("--" "" "content\n" "content\n")
  (visit* "/tmp/fe-rw.txt" "content\n" '()))

;; Editing a read-only buffer changes nothing, and reports the error in
;; the echo area instead of bringing the editor down.
(test-equal '("%%" "Buffer is read-only" "content\n" "content\n")
  (visit* "/tmp/fe-ro.txt" "content\n" (list #\X) 'read-only))

;; C-x C-q toggles it, and says which way, in GNU Emacs's words.
(test-equal '("%%" "Read-Only mode enabled in current buffer" "content\n" "content\n")
  (visit* "/tmp/fe-rw.txt" "content\n" (list C-x #\q)))
(test-equal '("--" "Read-Only mode disabled in current buffer" "content\n" "content\n")
  (visit* "/tmp/fe-rw.txt" "content\n" (list C-x #\q C-x #\q)))

;; ... so after toggling it back the buffer can be edited again (the
;; file is untouched until it is saved).
(test-equal '("**" "" "content\n" "Xcontent\n")
  (visit* "/tmp/fe-rw.txt" "content\n" (list C-x #\q C-x #\q #\X)))

;; A buffer that is both modified and read-only shows `%*', not `%%'.
;; The indicator is two constructs, `mode-line-modified' being
;; `("%1*" "%1+")' - `%*' gives `%' for a read-only buffer whatever its
;; modification state, and `%+' gives `*' for a modified one, so the pair
;; is `%*'. Measured from a terminal Emacs for the three states:
;; read-only and modified `%*', read-only and clean `%%', modified alone
;; `**'. The hand-rolled indicator this replaced got the first of those
;; wrong.
(test-equal '("%*" "Xcontent\n")
  (let ((result (visit* "/tmp/fe-rw.txt" "content\n" (list #\X C-x #\q))))
    (list (car result) (cadddr result))))

;; Undo refuses a read-only buffer too, as GNU Emacs's `undo' does, and
;; leaves the buffer alone.
(test-equal '("%*" "Buffer is read-only" "content\n" "Xcontent\n")
  (visit* "/tmp/fe-rw.txt" "content\n" (list #\X C-x #\q C-underscore)))

;; The visit-time warning is a rule of its own: it appears when the
;; buffer is read-only and stays quiet when it is not.
(define (message-after-note read-only?)
  (let* ((ed (new-text-editor))
         (frame (test-frame ed)))
    (parameterize ((*current-frame* frame))
      (text-editor-set-read-only! ed read-only?)
      (note-file-read-only! frame)
      (ncurses-frame-message frame))))

(test-equal '("Note: file is write protected" "")
  (list (message-after-note #t) (message-after-note #f)))

(test-end "schemacs_ncurses_editor_read_only")

;;--------------------------------------------------------------------
;; Incremental search
;;
;; The search loop itself reads the terminal, so it is exercised end to
;; end in a pty; what is tested here is the two pieces with all the logic
;; in them: the message Emacs shows while searching, and the search step
;; that decides where point goes.

(test-begin "schemacs_ncurses_editor_isearch")

;; The prompt, in GNU Emacs's words and its order: the status words, then
;; "I-search" (or "I-search backward"), then the search string. Emacs
;; builds it in lower case and capitalises the first letter.
(test-equal "I-search: "
  (isearch-message "" 'forward #t #f #t 0 0))
(test-equal "I-search: beta"
  (isearch-message "beta" 'forward #t #f #t 10 0))
(test-equal "Failing I-search: zzz"
  (isearch-message "zzz" 'forward #f #f #t 0 0))
(test-equal "Failing case-sensitive I-search: Zzz"
  (isearch-message "Zzz" 'forward #f #f #f 0 0))
(test-equal "I-search backward: beta"
  (isearch-message "beta" 'backward #t #f #t 6 16))
(test-equal "Failing I-search backward: zzz"
  (isearch-message "zzz" 'backward #f #f #t 0 0))

;; Wrapping is reported, and is "overwrapped" once point has passed where
;; the search began (Emacs's rule).
(test-equal '("Wrapped I-search: a" "Overwrapped I-search: a")
  (list (isearch-message "a" 'forward #t #t #t 2 5)
        (isearch-message "a" 'forward #t #t #t 5 0)))

;; The search step, against "alpha beta gamma\nbeta delta\n" (the two
;; "beta"s are at 6..10 and 17..21).
(define (isearch-buffer)
  (let ((ed (new-text-editor)))
    (text-editor-insert ed "alpha beta gamma\nbeta delta\n")
    ed))

;; Forward searches leave point past the match; backward ones leave it at
;; the match's start.
(test-equal '(10 21 6)
  (let ((ed (isearch-buffer)))
    (text-editor-set-cursor ed 0)
    (let ((first (isearch-find ed "beta" 'forward #f #f)))
      (text-editor-set-cursor ed first)
      (let ((second (isearch-find ed "beta" 'forward #f #t)))
        (text-editor-set-cursor ed 16)
        (list first second (isearch-find ed "beta" 'backward #f #f))))))

;; A failing search reports nothing and leaves the caller's point alone.
(test-equal #f (isearch-find (isearch-buffer) "zzz" 'forward #f #f))

;; An empty search string searches for nothing at all.
(test-equal #f (isearch-find (isearch-buffer) "" 'forward #f #f))

;; Whether the search folds case is the caller's to decide - the
;; argument is Emacs's `case-fold-search', the right way round - and the
;; incremental search turns it off when an upper-case letter is typed in.
(test-equal '(10 #f)
  (let ((ed (isearch-buffer)))
    (text-editor-set-cursor ed 0)
    (list (isearch-find ed "BETA" 'forward #t #f)
          (isearch-find ed "BETA" 'forward #f #f))))

(test-end "schemacs_ncurses_editor_isearch")

;;--------------------------------------------------------------------
;; The minibuffer

(test-begin "schemacs_ncurses_editor_minibuffer")

;; `try-completion' is GNU Emacs's: the candidates the text matches, the
;; longest prefix they share, #t when the text is already a candidate, and
;; #f when nothing matches.
;; A completion table is a *list* of candidates in the simplest form
;; Emacs allows, and that is what `file-name-completion-table' answers too.
;; (The function form takes three arguments, `(STRING PREDICATE ACTION)',
;; not one - see `(schemacs editor minibuf)'.)
(define (table-of names) names)
(define fruit (table-of '("apple" "apricot" "banana")))

(test-equal '(("apple" "apricot") ())
  (list (all-completions "ap" fruit) (all-completions "zz" fruit)))
(test-equal "ap" (try-completion "ap" fruit))
(test-equal "apple" (try-completion "app" fruit))
(test-equal #t (try-completion "apple" fruit))
(test-equal #f (try-completion "banana split" fruit))
(test-equal "banana" (try-completion "ban" fruit))

;; A single candidate completes all the way to it.
(test-equal "banana" (try-completion "ban" (table-of '("banana"))))

;; File names split the way Emacs's `file-name-directory' and
;; `file-name-nondirectory' do.
(test-equal '("" "foo.txt" "./" "foo.txt" "/tmp/x/" "y")
  (list (file-name-directory-part "foo.txt")
        (file-name-nondirectory-part "foo.txt")
        (file-name-directory-part "./foo.txt")
        (file-name-nondirectory-part "./foo.txt")
        (file-name-directory-part "/tmp/x/y")
        (file-name-nondirectory-part "/tmp/x/y")))

;; Completing a file name offers the entries of the directory, with a
;; slash on the ones that are directories (so completing one descends
;; into it), and only the ones the typed text is a prefix of.
(test-equal '("/tmp/mbtest/alpha.txt" "/tmp/mbtest/another/")
  (begin
    (if (not (file-exists? "/tmp/mbtest")) (mkdir "/tmp/mbtest"))
    (if (not (file-exists? "/tmp/mbtest/another")) (mkdir "/tmp/mbtest/another"))
    (call-with-output-file "/tmp/mbtest/alpha.txt" (lambda (p) (display "a" p)))
    (call-with-output-file "/tmp/mbtest/beta.txt" (lambda (p) (display "b" p)))
    (sort (file-name-completion-table "/tmp/mbtest/a")
          (lambda (a b) (string<? a b)))))

;; With no minibuffer active there are no contents, and `minibufferp' is
;; false - so the renderer draws the echo area as usual.
(test-equal '(#f #f)
  (parameterize ((*minibuffer* #f))
    (list (minibufferp) (minibuffer-contents))))

;; The minibuffer keymaps are sparse maps that inherit the global one, so
;; RET leaves the minibuffer, C-g abandons the command that asked, M-p and
;; M-n walk the history, and the ordinary editing keys still apply.
(define (bound-in keymap path)
  (km:keymap-lookup keymap (km:keymap-index path)))
(define (command-named? action name)
  (and (command-type? action) (string=? (command-name action) name)))

(test-equal '(#t #t #t #t #t)
  (list (command-named? (bound-in minibuffer-local-map (list 'ctrl #\m))
                        "exit-minibuffer")
        (command-named? (bound-in minibuffer-local-map (list 'ctrl #\g))
                        "abort-recursive-edit")
        (command-named? (bound-in minibuffer-local-map (list 'meta #\p))
                        "previous-history-element")
        (command-named? (bound-in minibuffer-local-map (list 'meta #\n))
                        "next-history-element")
        (command-named? (bound-in minibuffer-local-completion-map
                                  (list 'ctrl #\i))
                        "minibuffer-complete")))

;; ... and the global bindings are *not* copied into it. The map holds
;; only the minibuffer's own keys, and an ordinary editing key is found
;; because the lookup searches the local map and then the global one, as
;; GNU Emacs's `read_key_sequence' does. So C-f is not bound in the map
;; itself, and dispatching it while the minibuffer is being read still
;; moves point forward - in the *minibuffer's* buffer, because that is the
;; current buffer while it is read.
(test-equal '(#f 1 0)
  (let* ((ed (new-text-editor))
         (frame (test-frame ed))
         (mb-ed (new-text-editor))
         (mb (make<minibuffer> mb-ed "" minibuffer-local-map
                              #f minibuffer-history 0 #f)))
    (text-editor-insert mb-ed "abc")
    (text-editor-set-cursor mb-ed 0 0)
    (parameterize ((*current-frame* frame)
                   (*minibuffer* mb)
                   (*echo-area-buffer* mb-ed)
                   (*current-keymap* minibuffer-local-map))
      (dispatch-key-event frame (list (list 'ctrl #\f)))
      (list (bound-in minibuffer-local-map (list (list 'ctrl #\f)))
            (text-editor-get-cursor mb-ed)
            (text-editor-get-cursor ed)))))

(test-end "schemacs_ncurses_editor_minibuffer")

;;--------------------------------------------------------------------
;; Where point is drawn
;;
;; Both of these were the engine reporting the end of a buffer whose
;; last line has no trailing line break as an empty line past it, and
;; the frontend compensating for it: `cursor-screen-position' could not
;; find that line to draw point on and left the cursor unpainted (so it
;; appeared stuck at the beginning), and `minibuffer-cursor-column' had
;; a correction of its own. With the engine fixed, both are plain.

(test-begin "schemacs_ncurses_editor_cursor_position")

(define (window-of frame) (ncurses-frame-selected-window frame))

;; The frame's one window fills the frame's text area: the rows above
;; the echo area, all of the columns.
(test-equal '(23 80)
  (let* ((frame (test-frame (new-text-editor)))
         (window (window-of frame)))
    (list (window-height window) (window-width window))))

;; Point at the end of a buffer with no trailing line break is drawn
;; after the last character of the line, on the line's own row.
(test-equal '(0 . 3)
  (let* ((frame (test-frame (new-text-editor)))
         (ed (ncurses-frame-editor frame)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 0 0)
    (text-editor-move-cursor ed 100)
    (cursor-screen-position (window-of frame))))

;; ... and it is a column on the last line, so moving point backward and
;; forward again returns to it.
(test-equal '((0 . 3) (0 . 2) (0 . 3))
  (let* ((frame (test-frame (new-text-editor)))
         (ed (ncurses-frame-editor frame))
         (window (window-of frame)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 0 0)
    (text-editor-move-cursor ed 100)
    (let ((at-end (cursor-screen-position window)))
      (text-editor-move-cursor ed -1)
      (let ((back (cursor-screen-position window)))
        (text-editor-move-cursor ed 1)
        (list at-end back (cursor-screen-position window))))))

;; A line break at the end of the buffer does start a line, and point at
;; the very end is drawn on that empty line, one row down.
(test-equal '(1 . 0)
  (let* ((frame (test-frame (new-text-editor)))
         (ed (ncurses-frame-editor frame)))
    (text-editor-insert ed "abc\n")
    (text-editor-set-cursor ed 0 0)
    (text-editor-move-cursor ed 100)
    (cursor-screen-position (window-of frame))))

;; The minibuffer draws the cursor at the prompt, then what has been
;; typed up to point - and at the end of it, after the last character.
(test-equal '(11 14 13 11)
  (let* ((ed (new-text-editor))
         (mb (make<minibuffer> ed "Find file: " minibuffer-local-map
                              #f minibuffer-history 0 #f)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 0 0)
    (parameterize ((*minibuffer* mb))
      (let ((at-start (minibuffer-cursor-column)))
        (text-editor-move-cursor ed 100)
        (let ((at-end (minibuffer-cursor-column)))
          (text-editor-move-cursor ed -1)
          (let ((back (minibuffer-cursor-column)))
            (text-editor-move-cursor ed -100)
            (list at-start at-end back (minibuffer-cursor-column))))))))

(test-end "schemacs_ncurses_editor_cursor_position")

;;--------------------------------------------------------------------
;; Windows: C-x 2, C-x o, C-x 0, C-x 1
;;
;; GNU Emacs's windows are views of buffers on a rectangle of the
;; screen. A frame's windows tile its text area exactly - between them
;; they cover every row and no row twice - and each has its own point
;; and its own mode line. These tests drive the keys and check the
;; geometry and the points, which is the part that a screenful of
;; scrambled rows would hide.

(test-begin "schemacs_ncurses_editor_windows")

(define (selected-window-of frame)
  (ncurses-frame-selected-window frame))

(define (frame-rows frame)
  ;; The rows of the frame's text area: all of them but the echo area's.
  (- (frame-height frame) 1))

(define (window-rects frame)
  ;; Each window as (TOP HEIGHT), top to bottom.
  (map (lambda (w) (list (window-top w) (window-height w)))
       (window-list frame)))

(define (tiles? frame)
  ;; Whether the windows tile the frame's text area: starting at row 0,
  ;; each window begins where the one before it ended, and the last ends
  ;; at the last row of the text area.
  (let loop ((rest (window-list frame)) (row 0))
    (cond
     ((null? rest) (= row (frame-rows frame)))
     ((not (= (window-top (car rest)) row)) #f)
     (else (loop (cdr rest) (+ row (window-height (car rest))))))))

(define (frame-with text)
  (let* ((ed (new-text-editor))
         (frame (test-frame ed)))
    (text-editor-insert ed text)
    (text-editor-set-cursor ed 0 0)
    frame))

(define (run-window-keys frame . evs)
  (parameterize ((*current-frame* frame)
                 (*search-pattern* #f)
                 (*search-case-fold?* #t)
                 (*kill-buffer* "")
                 (*this-command-kill* #f)
                 (*last-command-kill* #f)
                 (*last-command* #f)
                 (*pending-undo-list* #f)
                 (*last-change-was-undo* #f))
    (for-each (lambda (ev) (dispatch-ncurses-event frame ev)) evs)
    frame))

(define (points frame)
  ;; Each window's point, and the buffer's own.
  (append (map window-point (window-list frame))
          (list (text-editor-get-cursor (ncurses-frame-editor frame)))))

;; A frame starts with exactly one window, filling the text area, and it
;; is the selected one.
(test-equal '(#t 1 (0 23))
  (let* ((frame (frame-with "alpha\nbeta\n"))
         (windows (window-list frame)))
    (list (eq? (car windows) (selected-window-of frame))
          (length windows)
          (list (window-top (car windows)) (window-height (car windows))))))

;; C-x 2 splits it into two, one above the other, sharing the rows as
;; evenly as they divide - and both showing the same buffer at the same
;; point, because `split-window-keep-point' is t in GNU Emacs.
(test-equal '(#t 2 ((0 12) (12 11)) #t (0 0 0))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2)))
    (let ((windows (window-list frame)))
      (list (tiles? frame)
            (length windows)
            (window-rects frame)
            (eq? (window-buffer (car windows))
                 (window-buffer (cadr windows)))
            (points frame)))))

;; The upper (selected) window is still the selected one: a split does
;; not move the selection.
(test-equal #t
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2)))
    (eq? (car (window-list frame))
         (selected-window-of frame))))

;; A second C-x 2 splits the selected window again, and the three still
;; tile the frame.
(test-equal '(#t 3 ((0 6) (6 6) (12 11)))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2 C-x #\2)))
    (list (tiles? frame)
          (length (window-list frame))
          (window-rects frame))))

;; A prefix argument is the SIZE, as it is in GNU Emacs: `C-u 8 C-x 2'
;; gives the upper window eight rows.
(test-equal '((0 8) (8 15))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-u #\8 C-x #\2)))
    (window-rects frame)))

;; A negative size gives the new window -SIZE rows.
(test-equal '((0 17) (17 6))
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame))
      (split-window-below (selected-window-of frame) -6))
    (window-rects frame)))

;; Splitting a window with no room for two signals GNU Emacs's error
;; rather than making a window nothing can be read in.
(test-equal "Size of new window too small"
  (let* ((frame (frame-with "alpha\nbeta\n"))
         (window (selected-window-of frame)))
    (set!window-height window 6)
    (parameterize ((*current-frame* frame))
      (guard (ex (else (exception-message ex)))
        (split-window-below window #f)
        #f))))

;; C-x o selects the next window, and each window keeps its own point:
;; the buffer's point is the selected window's, and the window left
;; behind holds the point it had.
(test-equal '(#t 0 0 3)
  (let* ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2))
         (ed (ncurses-frame-editor frame)))
    ;; move point forward in the upper window, then change windows: the
    ;; upper keeps the point it had, the lower gets it as its own
    (text-editor-move-cursor ed 3)
    (run-window-keys frame C-x #\o)
    (let* ((windows (window-list frame))
           (selected (selected-window-of frame))
           (lower (cadr windows)))
      (list (eq? selected lower)
            (text-editor-get-cursor ed)
            (window-point lower)
            (window-point (car windows))))))

;; C-x o cycles back round to the first window, and takes the point that
;; window was holding.
(test-equal '(#t 3)
  (let* ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2))
         (ed (ncurses-frame-editor frame)))
    (text-editor-move-cursor ed 3)
    (run-window-keys frame C-x #\o C-x #\o)
    (list (eq? (car (window-list frame)) (selected-window-of frame))
          (text-editor-get-cursor ed))))

;; C-x 1 makes the selected window the only one, filling the frame.
(test-equal '(#t 1 0 23)
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\2 C-x #\1)))
    (let ((window (selected-window-of frame)))
      (list (tiles? frame) (length (window-list frame))
            (window-top window) (window-height window)))))

;; C-x 0 removes the selected window; the window above it grows into the
;; rows, so the windows still tile the frame. The selected window was the
;; lower one, so the upper window becomes selected.
(test-equal '(#t 1 ((0 23)) #t)
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\2 C-x #\o C-x #\0)))
    (list (tiles? frame)
          (length (window-list frame))
          (window-rects frame)
          (eq? (car (window-list frame)) (selected-window-of frame)))))

;; Removing the first of two windows gives its rows to the one below,
;; which moves up to meet the top of the frame.
(test-equal '(#t ((0 23)))
  (let* ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\2))
         (windows (window-list frame)))
    (parameterize ((*current-frame* frame))
      (delete-window (car windows)))
    (list (tiles? frame) (window-rects frame))))

;; The last window cannot be removed: GNU Emacs signals an error rather
;; than leave a frame with no window.
(test-equal "Attempt to delete minibuffer or sole ordinary window"
  (let ((frame (frame-with "alpha\nbeta\n")))
    (parameterize ((*current-frame* frame))
      (guard (ex (else (exception-message ex)))
        (delete-window (selected-window-of frame))
        #f))))

;; Each window has its own mode line, and each says where its own point
;; is: the same buffer in two windows is at two places in it. Point has
;; been moved to index 3 in the buffer, which is the selected window's
;; point and so shows as column 3 - `%c' counts from zero, as GNU Emacs's
;; does - while the window the split made still holds the point it was
;; made with, column 0. Both windows said `C1' before this: the split
;; window and the new one were reading the same point, which is the bug
;; the two different numbers are here to catch.
(test-equal '("** alpha.txt    -- L1 C3" "** alpha.txt    -- L1 C0")
  (let* ((frame (frame-with "alpha\nbeta\n"))
         (ed (ncurses-frame-editor frame)))
    (set!text-editor-buffer-name ed "alpha.txt")
    (run-window-keys frame C-x #\2)
    (text-editor-move-cursor ed 3)
    ;; read inside the frame's context: `window-point' asks which window is
    ;; selected, and that is a fact about the current frame - outside it
    ;; every window answers with its own marker, which is where this test
    ;; was quietly reading both of them
    (parameterize ((*current-frame* frame))
      (map (lambda (w) (mode-line-string w)) (window-list frame)))))

;; C-x 3 splits the selected window into two side by side, the new one
;; to the right, sharing the width. An even width divides evenly; an odd
;; one gives the extra column to the left window, as GNU Emacs does (81
;; columns divide 41 and 40 there).
(test-equal '(((0 0 40 23) (40 0 80 23)) ((0 0 41 23) (41 0 81 23)))
  (list (let ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\3)))
          (map window-edges (window-list frame)))
        (let* ((frame (new-frame (new-text-editor) 24 81)))
          (run-window-keys frame C-x #\3)
          (map window-edges (window-list frame)))))

;; The two are separated by the frame's vertical border, one column wide,
;; which belongs to the window on its left: so the left window is 40
;; columns of which the last is the border, and shows text 39 wide,
;; while the right window's 40 are all text. This is what a text terminal
;; Emacs reports for the same split: `L=(0 1 40 23) LB=(0 1 39 22)
;; R=(40 1 80 23) RB=(40 1 80 22) TW=40 BW=39'.
(test-equal '(#t 39 40 #f)
  (let ((frame (frame-with "alpha\nbeta\n")))
    (run-window-keys frame C-x #\3)
    (parameterize ((*current-frame* frame))
      (let* ((windows (window-list frame))
             (left (car windows)) (right (cadr windows)))
        (list (window-right-border? left)
              (window-body-width left)
              (window-body-width right)
              (window-right-border? right))))))

;; A prefix argument is the SIZE, as it is in GNU Emacs: `C-u 30 C-x 3'
;; gives the left window thirty columns, and a negative size gives the
;; new window -SIZE.
(test-equal '(((0 0 30 23) (30 0 80 23)) ((0 0 50 23) (50 0 80 23)))
  (list (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                      C-u #\3 #\0 C-x #\3)))
          (map window-edges (window-list frame)))
        (let ((frame (frame-with "alpha\nbeta\n")))
          (parameterize ((*current-frame* frame))
            (split-window-right (selected-window-of frame) -30))
          (map window-edges (window-list frame)))))

;; With no size asked for, both windows have to be wide enough to read:
;; GNU Emacs's `window-min-width' is 10.
(test-equal "Size of new window too small"
  (let* ((frame (frame-with "alpha\nbeta\n"))
         (window (selected-window-of frame)))
    (set!window-width window 18)
    (parameterize ((*current-frame* frame))
      (guard (ex (else (exception-message ex)))
        (split-window-right window #f)
        #f))))

;; Splitting right and below at once: the left window keeps the whole
;; height, and each is joined by the vertical border where they meet.
(test-equal '(((0 0 40 23) (40 0 80 12) (40 12 80 23)) (#t #f #f))
  (let ((frame (frame-with "alpha\nbeta\n")))
    (run-window-keys frame C-x #\3 C-x #\o C-x #\2)
    (parameterize ((*current-frame* frame))
      (list (map window-edges (window-list frame))
            (map window-right-border? (window-list frame))))))

;; Removing a window gives what it occupied to the windows it was
;; combined with. These are the shapes GNU Emacs produces for the same
;; sequences, read from a text terminal Emacs with `window-edges' (its
;; rows are one more than ours, its frames having a menu bar).

;; A window and its right-hand neighbour: either one left gives the
;; other the whole frame.
(test-equal '(((0 0 80 23)) ((0 0 80 23)))
  (list (let* ((frame (run-window-keys (frame-with "alpha\nbeta\n") C-x #\3))
               (left (car (window-list frame))))
          (parameterize ((*current-frame* frame)) (delete-window left))
          (map window-edges (window-list frame)))
        (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                      C-x #\3 C-x #\o C-x #\0)))
          (map window-edges (window-list frame)))))

;; Deleting the lower right of three: the window above it - the one it
;; was split from - grows back to the full height, and the left window is
;; untouched.
(test-equal '((0 0 40 23) (40 0 80 23))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\3 C-x #\o C-x #\2 C-x #\0)))
    (map window-edges (window-list frame))))

;; Deleting a window that is a whole column of the frame - the left-hand
;; window split in two, with the right-hand window beside them - gives
;; the columns to both of the windows beside it, so they both grow to the
;; full width.
(test-equal '((0 0 80 12) (0 12 80 23))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\3 C-x #\2 C-x #\o C-x #\o C-x #\0)))
    (map window-edges (window-list frame))))

;; Deleting the lower of a stack gives its rows to the window above it,
;; and deleting the upper gives them to the one below, which moves up.
;; The windows are compared as a set: which of them comes first in
;; `window-list' is GNU Emacs's window tree's business, and this frontend
;; keeps its windows in the order they were made.
(define (sorted-edges frame)
  (sort (map window-edges (window-list frame))
        (lambda (a b) (< (car a) (car b)))))

(test-equal '(((0 0 40 23) (40 0 80 23)) ((0 0 40 23) (40 0 80 23)))
  (list (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                      C-x #\3 C-x #\o C-x #\2 C-x #\0)))
          (sorted-edges frame))
        (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                      C-x #\3 C-x #\o C-x #\2
                                      C-x #\o C-x #\0)))
          (sorted-edges frame))))

;; A window's point is a MARKER, so it survives the text moving under
;; it while the window is not selected. Split, put the lower window's
;; point on the fifth character, edit above it in the upper window, and
;; come back: the point is on the same character still, which is what a
;; real Emacs reports for the same sequence (point 5 becomes 7 when two
;; characters are inserted in front of it).
(test-equal '(5 0 7 7)
  (let* ((frame (frame-with "one two three"))
         (ed (ncurses-frame-editor frame)))
    (parameterize ((*current-frame* frame))
      ;; upper window: point at the start; lower window: point on "t" of "two"
      (run-window-keys frame C-x #\2 C-x #\o)
      (text-editor-set-cursor ed 5)
      (set-window-point! (selected-window-of frame) 5)
      (let ((lower-point-before (window-point (selected-window-of frame))))
        (run-window-keys frame C-x #\o)        ; back to the upper window
        (let ((upper-point (text-editor-get-cursor ed)))
          (run-window-keys frame C-a #\X #\Y)  ; edit above the other window's point
          (run-window-keys frame C-x #\o)       ; and back down to it
          (list lower-point-before upper-point
                (text-editor-get-cursor ed)
                (window-point (selected-window-of frame))))))))

;; The same for the mark: Emacs moves a mark with the text too, so a
;; search that leaves the mark behind can still be returned to after the
;; buffer has been edited in front of it.
(test-equal '(5 7)
  (let* ((frame (frame-with "one two three"))
         (ed (ncurses-frame-editor frame)))
    (set!text-editor-mark ed 5)
    (let ((mark-before (text-editor-mark ed)))
      (run-window-keys frame C-a #\X #\Y)     ; edit in front of the mark
      (list mark-before (text-editor-mark ed)))))

;; Deleting the *middle* of three windows gives its rows to the one it
;; was split from - its sibling in the tree - and nothing else moves.
;; This is the case the window tree exists for: the old code inferred the
;; takers by comparing row and column bands, found both the window above
;; and the one below adjacent to the middle one, and grew both, which
;; overlapped them. Read from GNU Emacs for the same sequence: its
;; `(window-edges)' for these leaves are (0 1 80 13) and (0 13 80 24),
;; ours being one row less at the top.
(test-equal '((0 12) (12 11))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\2 C-x #\2 C-x #\o C-x #\0)))
    (window-rects frame)))

;; ... and the windows that are left are still in their screen order, so
;; C-x o walks from the top one to the bottom one and round again, which
;; is what `other-window' does in GNU Emacs after the same deletion.
(test-equal '((12 11) (0 12) (12 11))
  (let ((frame (run-window-keys (frame-with "alpha\nbeta\n")
                                C-x #\2 C-x #\2 C-x #\o C-x #\0)))
    (let loop ((i 0) (seen '()))
      (if (= i 3)
          (reverse seen)
          (begin
            (run-window-keys frame C-x #\o)
            (loop (+ 1 i)
                  (cons (let ((w (selected-window-of frame)))
                          (list (window-top w) (window-height w)))
                        seen)))))))

;;--------------------------------------------------------------------
;; The mode line's format
;;
;; GNU Emacs's `mode-line-format' is a template that `format-mode-line'
;; evaluates; there is no hand-rolled string. Every value below was read
;; from a terminal Emacs running the same construct - `emacs -Q -nw', with
;; the answer written out from `(format-mode-line ...)' rather than
;; guessed, because `format-mode-line' returns "" in a batch Emacs and the
;; padding rules are not documented anywhere.

(test-begin "schemacs_ncurses_editor_mode_line_format")

(define (format-in frame f)
  (parameterize ((*current-frame* frame))
    (format-mode-line f (ncurses-frame-selected-window frame))))

;; The constructs: the buffer name, the position, the modification state.
;; `%c' counts from zero - the leftmost column is displayed as 0, which is
;; Emacs's rule and not the engine's, whose columns start at one.
(test-equal '("probe" "1" "0" "1" "12" "%")
  (let ((frame (frame-with "hello\nworld\n")))
    (let ((ed (ncurses-frame-editor frame)))
      (set!text-editor-buffer-name ed "probe")
      (text-editor-set-read-only! ed #t)
      (list (format-in frame "%b")
            (format-in frame "%l")
            (format-in frame "%c")
            (format-in frame "%C")
            (format-in frame "%i")
            (format-in frame "%%")))))

;; The three states of the modification indicator, which is two constructs
;; rather than one: `mode-line-modified' is `("%1*" "%1+")' in Emacs, and
;; a buffer that is both modified and read-only shows `%*' - `%*' gives
;; `%' for a read-only buffer, `%+' gives `*' for a modified one.
(test-equal '("--" "**" "%*" "%%")
  (let* ((frame (frame-with "hello\n"))
         (ed (ncurses-frame-editor frame))
         (indicator (lambda () (format-in frame (list "%1*" "%1+")))))
    ;; visiting the text left the buffer modified, so it is cleared first
    ;; to get the third state - what an untouched buffer shows
    (text-editor-set-modified! ed #f)
    (let ((clean (indicator)))
      (text-editor-insert ed "X")
      (let ((modified (indicator)))
        (text-editor-set-read-only! ed #t)
        (let ((both (indicator)))
          (text-editor-set-modified! ed #f)
          (list clean modified both (indicator)))))))

;; A field pads a number on the left and anything else on the right, so
;; that digits line up as point moves; the `(N ...)' element form is a
;; different mechanism and pads on the right whatever it holds.
(test-equal '("     1" "  1" "probe       " "1     ")
  (let ((frame (frame-with "hello\n")))
    (set!text-editor-buffer-name (ncurses-frame-editor frame) "probe")
    (list (format-in frame "%6l") (format-in frame "%3l")
          (format-in frame "%12b") (format-in frame (list 6 "%l")))))

;; A format is a list of constructs, nested as deeply as it likes, and a
;; construct that is a procedure is called for its value: Emacs's `:eval'
;; holds a form because Emacs has an evaluator, and this holds the
;; procedure, which is the same thing without one.
(test-equal '("Untitled|1" "hello" "" "%y")
  (let ((frame (frame-with "hello\n")))
    (list (format-in frame (list "%b" "|" (list "%l")))
          ;; `:eval' is a keyword in Emacs Lisp and self-evaluating; in
          ;; Scheme it is a symbol and has to be quoted
          (format-in frame (list ':eval (lambda () "hello")))
          ;; a symbol is a variable to evaluate, and there is no variable
          ;; registry yet, so it is unbound and yields nothing - which is
          ;; what an unbound variable yields in Emacs too
          (format-in frame 'mode-line-mule-info)
          ;; a construct that is not implemented is printed as it stands
          (format-in frame "%y"))))

;; The default format is the editor's mode line, and it says the buffer,
;; its own window's position and its modification state.
(test-equal #t
  (let* ((frame (frame-with "hello\nworld\n"))
         (ed (ncurses-frame-editor frame)))
    (set!text-editor-buffer-name ed "probe.txt")
    (text-editor-insert ed "X")
    ;; point is where the insert left it, one character in, and `%c'
    ;; counts from zero - so C1, not C0
    (string=? "** probe.txt    -- L1 C1"
              (format-in frame (*mode-line-format*)))))

(test-end "schemacs_ncurses_editor_mode_line_format")

(test-end "schemacs_ncurses_editor_windows")

;;--------------------------------------------------------------------
;; The final line break
;;
;; GNU Emacs's `require-final-newline': a buffer that does not end in a
;; line break is given one when it is saved, which is what a file buffer
;; gets by default (`mode-require-final-newline' is t and the file modes
;; set the buffer's value from it). The variable's other values add it
;; when the file is visited instead, at both times, or never.

(test-begin "schemacs_ncurses_editor_final_newline")

;; Saving adds the missing line break, to the buffer as well as the file,
;; and leaves the buffer unmodified - Emacs inserts it into the buffer.
(test-equal '("--" "ab\n" "ab\n")
  (let ((result (visit* "/tmp/fe-nl.txt" "ab" (list C-x save-key))))
    (list (car result) (cadddr result) (caddr result))))

;; A file that already ends in one is left alone.
(test-equal '("ab\n" "ab\n")
  (let ((result (visit* "/tmp/fe-nl2.txt" "ab\n" (list C-x save-key))))
    (list (cadddr result) (caddr result))))

;; An empty buffer is left alone: Emacs asks for a non-empty buffer
;; before adding anything.
(test-equal '("" "")
  (let ((result (visit* "/tmp/fe-nl3.txt" "" (list C-x save-key))))
    (list (cadddr result) (caddr result))))

;; A read-only buffer is left alone, and saving it writes what it holds:
;; Emacs does not add a line break to a read-only buffer.
(test-equal '("ab" "ab")
  (let ((result (visit* "/tmp/fe-nl4.txt" "ab" (list C-x #\q C-x save-key))))
    (list (cadddr result) (caddr result))))

;; The variable's other values, as Emacs defines them.
(test-equal '("ab" "ab")
  (parameterize ((*require-final-newline* #f))
    (let ((result (visit* "/tmp/fe-nl5.txt" "ab" (list C-x save-key))))
      (list (cadddr result) (caddr result)))))

(test-equal '("ab\n" "ab")
  (parameterize ((*require-final-newline* 'visit))
    (let ((result (visit* "/tmp/fe-nl6.txt" "ab" (list))))
      (list (cadddr result) (caddr result)))))

(test-equal '("ab\n" "ab\n")
  (parameterize ((*require-final-newline* 'visit-save))
    (let ((result (visit* "/tmp/fe-nl7.txt" "ab" (list C-x save-key))))
      (list (cadddr result) (caddr result)))))

;; A file whose line breaks are CRLF keeps them: the buffer holds the
;; line break as a newline and saving writes it back in the file's own
;; convention, so the newly added one is a CRLF too.
(test-equal '("ab\ncd\n" "ab\r\ncd\r\n")
  (let ((result (visit* "/tmp/fe-nl8.txt" "ab\r\ncd" (list C-x save-key))))
    (list (cadddr result) (caddr result))))

;; The visit-time rule is a function of the text and whether the file can
;; be written, which is how Emacs's `after-find-file' asks it.
(test-equal '("ab\n" "ab\n" "ab")
  (parameterize ((*require-final-newline* 'visit))
    (list (ensure-final-newline-on-visit "ab" #f)
          (ensure-final-newline-on-visit "ab\n" #f)
          (ensure-final-newline-on-visit "ab" #t))))

;; ... and with the default, which adds at saving rather than visiting,
;; it leaves the text alone.
(test-equal '("ab" "ab\n")
  (list (ensure-final-newline-on-visit "ab" #f)
        (ensure-final-newline-on-visit "ab\n" #f)))


;;--------------------------------------------------------------------
;; Buffers by name: `(schemacs editor buffer)', which the file commands
;; now go through

(test-begin "schemacs_ncurses_editor_buffers")

;; Visiting a file that is already visited uses the buffer that is already
;; showing it, rather than making a second one: GNU Emacs's
;; `find-file-noselect' answers with the buffer visiting the file, which
;; is what makes two visits one buffer and not two.
(test-equal '(#t 1)
  (parameterize ((*buffer-list* '()))
    (call-with-output-file "/tmp/fe-revisit.txt"
      (lambda (port) (display "once\n" port)))
    (let ((first (find-file "/tmp/fe-revisit.txt")))
      (let ((second (find-file "/tmp/fe-revisit.txt")))
        (list (eq? first second) (length (buffer-list)))))))

;; ... and the buffer keeps the name it was given when it was made, which
;; is the file without its directory.
(test-equal "fe-revisit.txt"
  (parameterize ((*buffer-list* '()))
    (let ((ed (find-file "/tmp/fe-revisit.txt")))
      (buffer-name ed))))

;; C-x k kills the buffer, and the window is given another one rather than
;; left showing a buffer that is gone. The replacement is `other-buffer',
;; which makes `*scratch*' when there is nothing else to show.
;;
;; `with-file-buffer' answers with the status line and the file's contents,
;; not with the frame - it runs its thunk on the frame - so what the test
;; wants afterwards is captured inside the thunk.
(test-equal '("*scratch*" ("*scratch*") "Killed fe-kill.txt")
  (let ((shown #f) (names #f) (message #f))
    (with-file-buffer "/tmp/fe-kill.txt" "text\n"
      (lambda (frame)
        (type frame C-x #\k)
        (set! shown (buffer-name (ncurses-frame-editor frame)))
        (set! names (map buffer-name (buffer-list)))
        (set! message (ncurses-frame-message frame))))
    (list shown names message)))

;; A modified buffer is asked about first, and `n' leaves it alone: the
;; window still shows it and it is still in the list.
(test-equal '("fe-kill2.txt" #t)
  (let ((shown #f) (still #f))
    (with-file-buffer "/tmp/fe-kill2.txt" "text\n"
      (lambda (frame)
        (text-editor-insert (ncurses-frame-editor frame) "edited")
        (type frame C-x #\k #\n #\return)
        (set! shown (buffer-name (ncurses-frame-editor frame)))
        (set! still (and (get-buffer "fe-kill2.txt") #t))))
    (list shown still)))


;;--------------------------------------------------------------------
;; A buffer's own keymap
;;
;; The lookup searches the current buffer's keymap before the global one,
;; which is what GNU Emacs's `read_key_sequence' does with
;; `current-local-map'. It is what gives a buffer like `*Completions*' or
;; a buffer list its own keys, and until it was wired the keymap slot was
;; stored and never consulted.

(test-begin "schemacs_ncurses_editor_buffer_keymap")

;; `M-z` is bound in no map here, so what happens to it says which keymaps
;; the lookup searched: bound in the buffer's own map, the command runs;
;; with no buffer map, the key is undefined and the echo area says so.
;;
;; It is `M-z` rather than something easier to type because the key has to
;; be one *neither* editor wants: C-z belongs to job control - GNU Emacs
;; binds it to `suspend-frame', which raises SIGTSTP itself - and C-c is
;; the mode-map prefix. `M-z` is `zap-to-char` in Emacs and nothing here,
;; and this test is about this editor's lookup, not about Emacs's map.
(define (press-m-z local?)
  ;; Every step is inside the `parameterize', the buffer included: a
  ;; `get-buffer-create' in the `let*' above it would run with the real
  ;; buffer list, find the buffer the previous call made, and inherit the
  ;; keymap it left on it.
  (let ((ed (new-text-editor)))
    (parameterize ((*current-frame* (test-frame ed))
                   (*echo-area-buffer* #f)
                   (*buffer-list* '())
                   ;; #f: the buffer is made below, and the frame's
                   ;; notion is the window's buffer, which the
                   ;; `set!window-buffer' below sets to it
                   (*current-buffer* #f)
                   (*current-keymap* #f)
                   (*search-pattern* #f)
                   (*search-case-fold?* #t)
                   (*kill-buffer* "")
                   (*this-command-kill* #f)
                   (*last-command-kill* #f)
                   (*last-command* #f)
                   (*pending-undo-list* #f)
                   (*last-change-was-undo* #f))
     (let ((frame (*current-frame*))
           (buffer (get-buffer-create "*own-keys*")))
      (set!window-buffer (ncurses-frame-selected-window frame) buffer)
      (when local?
        (set!buffer-local-keymap
         buffer
         (km:keymap '*own-keys*
                    (km:alist->keymap-layer
                     `(((meta #\z) . ,read-only-mode))))))
      (dispatch-key-event frame (list (list 'meta #\z)))
      (list (text-editor-read-only? buffer)
            (ncurses-frame-message frame))))))

(test-equal '(#t "Read-Only mode enabled in current buffer")
  (press-m-z #t))

(test-equal '(#f "; undefined key: (meta #\\z)")
  (press-m-z #f))

(test-end "schemacs_ncurses_editor_buffer_keymap")


;;--------------------------------------------------------------------
;; The Buffer Menu: `(schemacs editor buffer-menu)', which is buff-menu.el

(test-begin "schemacs_ncurses_editor_buffer_menu")

(define (with-buffer-menu extra thunk)
  ;; A frame showing "shown.txt", with the buffers in EXTRA made - each
  ;; (NAME READ-ONLY MODIFIED) - and the buffer list made from that
  ;; frame. THUNK is given the list buffer's text.
  ;;--------------------------------------------------------------
  (parameterize ((*buffer-list* '())
                 (*current-buffer* #f)
                 (*Buffer-menu-marks* '())
                 (*kill-buffer-query-functions* '()))
    (let* ((ed (get-buffer-create "shown.txt"))
           (frame (test-frame ed)))
      (parameterize ((*current-frame* frame) (*echo-area-buffer* #f))
        (set!window-buffer (ncurses-frame-selected-window frame) ed)
        (for-each (lambda (spec)
                    (let ((buffer (get-buffer-create (car spec))))
                      (when (cadr spec) (text-editor-set-read-only! buffer #t))
                      (when (caddr spec) (text-editor-insert buffer "x"))))
                  extra)
        (thunk (text-editor-to-string (list-buffers-noselect)))))))

(define (mentions? text what)
  (and (string-contains text what) #t))

;; The list has the column titles and a row for each buffer, and the C
;; column marks the buffer the list was made from with `.` - what GNU
;; Emacs's `list-buffers--refresh' does with its `old-buffer' argument.
(test-equal '(#t #t #t)
  (with-buffer-menu '()
    (lambda (text)
      (list (mentions? text "C R M Buffer")
            (mentions? text "shown.txt")
            (mentions? text ".  shown.txt")))))

;; A buffer whose name starts with a space is not listed - those are the
;; internal ones - and neither is the list buffer itself.
(test-equal '(#f #f)
  (with-buffer-menu (list (list " *internal*" #f #f))
    (lambda (text)
      (list (mentions? text "internal")
            (mentions? text "Buffer List")))))

;; The R and M columns: `%' for a buffer that is read-only and `*' for one
;; that has been changed.
(test-equal '(#t #t)
  (with-buffer-menu (list (list "ro.txt" #t #f) (list "mod.txt" #f #t))
    (lambda (text)
      ;; the three columns are one character each, so the R column is a
      ;; single space after the C column and the name follows the M column
      ;; directly
      (list (mentions? text "% ro.txt")
            (mentions? text "*mod.txt")))))

;; Marking a buffer for deletion and then executing the marks kills it,
;; and the row shows the `D' mark while it is marked.
(test-equal '(#t #f)
  (with-buffer-menu (list (list "doomed.txt" #f #f))
    (lambda (text)
      ;; the commands act on the current buffer, which is the list while
      ;; the user is in it - the same buffer point is in
      (*current-buffer* (get-buffer "*Buffer List*"))
      (Buffer-menu--set-mark! (get-buffer "doomed.txt") *Buffer-menu-del-char*)
      (Buffer-menu-redraw! (get-buffer "*Buffer List*"))
      (let ((marked (text-editor-to-string (get-buffer "*Buffer List*"))))
        (run-command Buffer-menu-execute)
        (list (mentions? marked "D  doomed.txt")
              (get-buffer "doomed.txt"))))))

;; The keys of the list, sent the way a terminal sends them. Every test
;; above reaches the commands directly or through their marks, so none of
;; them ever asked which buffer a line is - and `Buffer-menu-buffer', the
;; one function that answers that, called a helper that had gone missing.
;; A key pressed in the list is what reaches it.
(define (with-buffer-menu-keys extra thunk)
  ;; A frame showing the buffer list, with the list buffer current so
  ;; that its own keymap is the one keys are looked up in. THUNK is given
  ;; the list buffer - named for the menu it is - and a procedure that
  ;; sends one key event.
  ;;
  ;; The buffers in EXTRA are made in order, and a buffer goes to the
  ;; front of the buffer list when it is made, so the list shows them in
  ;; the reverse of that order: after "shown.txt", the last of EXTRA is
  ;; the first line.
  ;;--------------------------------------------------------------
  (parameterize ((*buffer-list* '())
                 (*current-buffer* #f)
                 (*Buffer-menu-marks* '())
                 (*kill-buffer-query-functions* '()))
    (let* ((ed (get-buffer-create "shown.txt"))
           (frame (test-frame ed)))
      (parameterize ((*current-frame* frame) (*echo-area-buffer* #f))
        (set!window-buffer (ncurses-frame-selected-window frame) ed)
        (for-each (lambda (spec)
                    (let ((buffer (get-buffer-create (car spec))))
                      (when (cadr spec) (text-editor-set-read-only! buffer #t))
                      (when (caddr spec) (text-editor-insert buffer "x"))))
                  extra)
        (let ((list (list-buffers-noselect)))
          (set!window-buffer (ncurses-frame-selected-window frame) list)
          (*current-buffer* list)
          (thunk list (lambda (ev) (dispatch-ncurses-event frame ev))))))))

;; Point starts on the first buffer's line, not on the titles' - which is
;; what `Buffer-menu-beginning' is for - and `n' walks down a line at a
;; time. With two buffers made after "shown.txt", the list is b.txt,
;; a.txt, shown.txt.
(test-equal '("b.txt" "a.txt" "shown.txt")
  (with-buffer-menu-keys (list (list "a.txt" #f #f) (list "b.txt" #f #f))
    (lambda (menu-buffer press!)
      (list (buffer-name (Buffer-menu-buffer))
            (begin (press! #\n) (buffer-name (Buffer-menu-buffer)))
            (begin (press! #\n) (buffer-name (Buffer-menu-buffer)))))))

;; Off the entries - on the titles' line - there is no buffer, as in
;; Emacs, where the line has no `tabulated-list-id'.
(test-equal #f
  (with-buffer-menu-keys '()
    (lambda (menu-buffer press!)
      (press! #\p)
      (Buffer-menu-buffer))))

;; `m' marks the buffer on the line and steps down, so pressing it twice
;; marks the first two lines.
(test-equal
  (string-append
   "C R M Buffer             Size   Mode            File\n"
   ">  b.txt              0      Fundamental     \n"
   ">  a.txt              0      Fundamental     \n"
   ".  shown.txt          0      Fundamental     \n")
  (with-buffer-menu-keys (list (list "a.txt" #f #f) (list "b.txt" #f #f))
    (lambda (menu-buffer press!)
      (press! #\m)
      (press! #\m)
      (text-editor-to-string menu-buffer))))

;; `%' toggles the read-only flag of the buffer on the line, and the R
;; column says which way it went.
(test-equal '(#t #t)
  (with-buffer-menu-keys (list (list "a.txt" #f #f) (list "b.txt" #f #f))
    (lambda (menu-buffer press!)
      (press! #\%)
      (list (text-editor-read-only? (get-buffer "b.txt"))
            (mentions? (text-editor-to-string menu-buffer) "% b.txt")))))

;; `s' marks a buffer for saving and `x' saves it, which is what GNU
;; Emacs's `Buffer-menu-execute' does with `(with-current-buffer buffer
;; (save-buffer))'. Saving writes *that buffer's* file - not the file of
;; whatever buffer happens to be current - which is the thing a frame
;; argument got wrong: the frame is whichever window the user is in, and
;; the buffer to save is the one the line names.
(test-equal
  (list "saved\noriginal\n"
        (string-append
         "C R M Buffer             Size   Mode            File\n"
         ".  bm-save.txt        15     Fundamental     /tmp/bm-save.txt\n"))
  (parameterize ((*buffer-list* '())
                 (*current-buffer* #f)
                 (*Buffer-menu-marks* '())
                 (*kill-buffer-query-functions* '()))
    (call-with-output-file "/tmp/bm-save.txt"
      (lambda (port) (display "original\n" port)))
    (let* ((ed (find-file "/tmp/bm-save.txt"))
           ;; the list is made from this buffer, so its line is marked `.`
           (frame (test-frame ed)))
      (parameterize ((*current-frame* frame) (*echo-area-buffer* #f))
        (set!window-buffer (ncurses-frame-selected-window frame) ed)
        (*current-buffer* ed)
        (text-editor-insert ed "saved\n")
        ;; now into the list, which becomes the current buffer - so if
        ;; `x' saved "the current buffer" it would save the list
        (set!window-buffer (ncurses-frame-selected-window frame)
                           (list-buffers-noselect))
        (*current-buffer* (get-buffer "*Buffer List*"))
        ;; `s' marks the buffer on this line for saving, `x' does it
        (dispatch-ncurses-event frame #\s)
        (dispatch-ncurses-event frame #\x)
        (list (call-with-input-file "/tmp/bm-save.txt"
                (lambda (port)
                  (let loop ((acc '()))
                    (let ((c (read-char port)))
                      (if (eof-object? c)
                          (list->string (reverse acc))
                          (loop (cons c acc)))))))
              (text-editor-to-string (get-buffer "*Buffer List*")))))))

;; RET shows the buffer on the line in the selected window, replacing the
;; list. The key arrives as the byte 13 a terminal sends, which is why it
;; is bound as C-m.
(test-equal '("a.txt" #f)
  (with-buffer-menu-keys (list (list "a.txt" #f #f) (list "b.txt" #f #f))
    (lambda (menu-buffer press!)
      (press! #\n)
      (press! #\return)
      (list (buffer-name (window-buffer (ncurses-frame-selected-window
                                         (*current-frame*))))
            ;; the list is off the frame's window, so nothing shows it
            (get-buffer-window (get-buffer "*Buffer List*"))))))

(test-end "schemacs_ncurses_editor_buffer_menu")


(test-end "schemacs_ncurses_editor_buffers")

(test-end "schemacs_ncurses_editor_final_newline")

;;--------------------------------------------------------------------
;; Commands run inside the minibuffer
;;
;; The minibuffer *is* the current buffer while it is being read, so the
;; ordinary editing commands act on it with no code of their own - and
;; nothing else in this file checks that, because they all reach the
;; minibuffer's API directly rather than through the command dispatcher.
;;
;; That gap hid a real bug: `current-editor' was moved to another library
;; while it still referenced a minibuffer accessor, so every command
;; errored *while the minibuffer was active* - and the command loop
;; swallows such an error into the echo area, where the prompt is drawn
;; over it. The symptom was typed text landing in the buffer behind the
;; prompt. Asserting the echo message is empty is what makes it visible.

(test-begin "schemacs_ncurses_editor_minibuffer_dispatch")

(define (with-minibuffer prompt initial evs)
  ;; Run EVS with a minibuffer active over a buffer holding "abc", and
  ;; return (minibuffer-contents buffer-contents echo-message).
  ;;--------------------------------------------------------------
  (let* ((ed (new-text-editor))
         (frame (test-frame ed))
         (mb-ed (new-text-editor))
         (mb (make<minibuffer> mb-ed prompt minibuffer-local-map
                              #f minibuffer-history 0 #f)))
    (text-editor-insert ed "abc")
    (text-editor-set-cursor ed 0 0)
    (when initial (text-editor-insert mb-ed initial))
    (text-editor-set-cursor mb-ed (text-editor-char-count mb-ed))
    (parameterize ((*current-frame* frame)
                   (*minibuffer* mb)
                   (*echo-area-buffer* mb-ed)
                   ;; the prompt too: the renderer draws it from
                   ;; the frame, and a command that runs with the
                   ;; minibuffer active must not see a stale one
                   (*echo-area-prompt* prompt)
                   (*search-pattern* #f)
                   (*search-case-fold?* #t)
                   (*kill-buffer* "")
                   (*this-command-kill* #f)
                   (*last-command-kill* #f)
                   (*last-command* #f)
                   (*pending-undo-list* #f)
                   (*last-change-was-undo* #f))
      (for-each (lambda (ev) (dispatch-ncurses-event frame ev)) evs)
      (list (text-editor-to-string mb-ed)
            (text-editor-to-string ed)
            (ncurses-frame-message frame)))))

;; Typing goes into the prompt, the buffer behind it is untouched, and
;; nothing errored.
(test-equal '("xyz" "abc" "")
  (with-minibuffer "Find file: " #f (list #\x #\y #\z)))

;; The line commands act on the prompt: C-a, type, C-e, C-b, C-d.
(test-equal '("bax" "abc" "")
  (with-minibuffer "" "axc" (list C-a #\b C-e C-b C-d)))

;; C-k kills to the end of the prompt's line, not the buffer's: with
;; point after the first character of "axc", "a" is what is left.
(test-equal '("a" "abc" "")
  (with-minibuffer "" "axc" (list C-a C-f C-k)))

;; The buffer's own contents survive a whole session in the prompt.
(test-equal "abc"
  (let ((result (with-minibuffer "> " #f (list #\a C-e C-a (integer->char 11)))))
    (list-ref result 1)))

(test-end "schemacs_ncurses_editor_minibuffer_dispatch")
