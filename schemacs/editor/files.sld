(define-library (schemacs editor files)
  ;; This library mirrors GNU Emacs's `files.el` - the file-visiting
  ;; layer: which file a buffer is visiting, how a file's line-break
  ;; convention is decoded on visit and encoded on save, whether a file
  ;; can be written, and the commands that visit and save.
  ;;
  ;; All of it is here now. The file I/O half came first, as a leaf: the
  ;; line-break protocol (Emacs's coding system, `coding.c'), the
  ;; write-protection test (`file-writable-p'), and `switch-to-buffer'.
  ;; The rest waited for `(schemacs editor minibuffer)', because every
  ;; command here prompts - `read-file-name' is what `find-file' and
  ;; `save-buffer' ask with, and the final-newline rule asks whether to add
  ;; one. `kill-buffer-command' is not really files.el's (it is the buffer
  ;; layer's), but it came here with the others because it asks too.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; Reading and writing the file itself, and the `display' that writes
    ;; the buffer back line by line. Neither is in `(scheme base)', and a
    ;; missing one reports as an unbound variable the first time a file is
    ;; visited or saved - which is how `call-with-input-file' was found.
    (scheme file)
    (only (scheme write) display)
    (only (schemacs editor engine)
          line-break-newline line-break-crlf line-break-return
          set!text-editor-buffer-name set!text-editor-file-name
          text-editor-buffer-name text-editor-char-count
          text-editor-file-name text-editor-get-char-index text-editor-get-cursor
          text-editor-insert text-editor-modified? text-editor-read-only?
          text-editor-set-cursor text-editor-set-modified!
          text-editor-set-read-only! text-editor-to-string
          text-editor-undo-disable! text-editor-undo-enable!)
    (only (schemacs editor frame)
          *current-frame* current-editor
          ncurses-frame-editor ncurses-frame-quit-cont
          set!ncurses-frame-editor
          set!ncurses-frame-message)
    ;; The commands here install their own keys, as files.el does.
    (only (schemacs editor command)
          new-command run-command)
    ;; `switch-to-buffer' is `window.el''s, and not this file's: it shows a
    ;; buffer in the selected window, which is a window operation.
    (only (schemacs editor window) switch-to-buffer)
    ;; Buffers by name, and killing one: `buffer.c'. `BUFFER-FILE-NAME' and
    ;; the buffer-local store are what `save-buffer' writes and what the
    ;; visited file's line-break convention is kept in.
    (only (schemacs editor buffer)
          *kill-buffer-query-functions*
          buffer-default-directory
          buffer-file-name
          buffer-list
          buffer-local-value
          current-buffer
          get-buffer-create
          kill-buffer
          record-buffer!
          set!buffer-default-directory
          set!buffer-file-name
          set-buffer-local-value!)
    (only (schemacs editor keymap)
          define-key
          *default-keymap*)
    ;; Every command here prompts.
    (only (schemacs editor minibuffer)
          completing-read
          file-name-history
          read-char-from-minibuffer
          read-from-minibuffer
          yes-or-no-p)
    ;; For deciding whether a file can be written, which is what makes a
    ;; visited file read-only (GNU Emacs's `file-writable-p', plus the
    ;; permission bits it also consults); and the directory reading and
    ;; name splitting `read-file-name' completes with.
    (only (guile) access? stat stat:mode W_OK logand
          closedir getcwd opendir readdir stat:type
          string-prefix? string-rindex))

  (export
   *require-final-newline*
   buffer-ends-with-newline?
   decode-dos-returns
   default-directory
   detect-line-break
   directory-entries
   directory-path?
   encode-line-breaks
   ensure-final-newline-on-save!
   ensure-final-newline-on-visit
   file-name-completion-table
   file-name-directory-part
   file-name-nondirectory-part
   file-write-protected?
   find-file
   find-file-command
   kill-buffer-command
   note-file-read-only!
   read-file-name
   save-answer-char->decision
   save-buffer
   save-buffer-command
   save-buffers-kill-terminal
   save-some-buffers
   y-or-n-p
   )

  (begin

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

    (define (buffer-file-coding-system buffer)
      ;; The line-break convention BUFFER's file was read with, so that
      ;; saving encodes the breaks back the way it found them: GNU Emacs's
      ;; `buffer-file-coding-system', the buffer-local variable its
      ;; `after-find-file' sets from what the file turned out to be.
      ;;
      ;; Emacs's value is a coding system - `utf-8-unix', `undecided-dos' -
      ;; whose eol-type is the part that matters here; there are no coding
      ;; systems yet, so what is kept is the eol-type itself, in the
      ;; engine's vocabulary (`detect-line-break' answers with one of
      ;; those). It is buffer-local, and not a slot on the frame, because
      ;; one frame shows buffers visiting files with different
      ;; conventions, and each must save in its own.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'buffer-file-coding-system
                          line-break-newline))

    (define (set!buffer-file-coding-system buffer line-break)
      ;; Record the convention BUFFER's file was read with: the
      ;; `make-local-variable' half of what Emacs's `after-find-file' does
      ;; with `buffer-file-coding-system'.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! buffer 'buffer-file-coding-system line-break))

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

    (define (file-write-protected? path)
      ;; Whether PATH cannot be written. This is GNU Emacs's `(not
      ;; (file-writable-p path))', plus its rule that a file whose
      ;; permission bits carry no write bit is read-only even for the
      ;; superuser, who is otherwise allowed to write anything.
      ;;--------------------------------------------------------------
      (or (not (access? path W_OK))
          (zero? (logand (stat:mode (stat path)) #o222))))

    (define (find-buffer-visiting path)
      ;; The buffer visiting PATH, or false: GNU Emacs's
      ;; `find-buffer-visiting'. It is `files.el''s rather than
      ;; `buffer.c''s - the answer is a buffer whose `buffer-file-name'
      ;; is this, which is a fact about visiting rather than about
      ;; buffers - so it walks the buffer list looking at each one's
      ;; file. Emacs compares truenames as well, so that a file and a
      ;; symlink to it are one buffer; nothing here makes symlinks yet.
      ;;--------------------------------------------------------------
      (let loop ((rest (buffer-list)))
        (cond ((null? rest) #f)
              ((equal? (text-editor-file-name (car rest)) path) (car rest))
              (else (loop (cdr rest))))))

    ;; The two file-visiting commands
    ;;
    ;; `find-file-command' and `save-buffer-command' are files.el's and
    ;; go to `(schemacs editor files)' with the minibuffer: they are the
    ;; only commands that prompt, and they are the only reason this
    ;; library still reaches into the file-name and final-newline code.
    ;; Everything else that used to sit under the `Commands' banner - the
    ;; editing commands, the kill ring and word motion, undo, the prefix
    ;; argument - is in `(schemacs editor simple)' now, which is GNU
    ;; Emacs's simple.el, and is imported below.
    ;;------------------------------------------------------------------

    (define find-file-command
      (new-command
       "find-file"
       (lambda ()
         (let* ((frame (*current-frame*))
                (path (read-file-name "Find file: ")))
           (guard (ex
                   (else
                    (set!ncurses-frame-message
                     frame (string-append
                            "; find-file: error loading " path))
                    #f))
             (switch-to-buffer (find-file path))
             (set!ncurses-frame-message frame "")
             (note-file-read-only! frame)
             path)))
       (lambda (path) #f)
       "Prompt for a file name and load it into the buffer."))

    (define save-buffer-command
      ;; C-x C-s. All the work is `save-buffer' - GNU Emacs's
      ;; `(interactive "p")' passes the prefix argument on to it, and
      ;; there is nothing here for that argument to change - so what is
      ;; left is the error message, which is this project's rather than
      ;; Emacs's.
      ;;--------------------------------------------------------------
      (new-command
       "save-buffer"
       (lambda ()
         (let ((frame (*current-frame*)))
           (guard (ex
                   (else
                    (set!ncurses-frame-message
                     frame (string-append
                            "; save-buffer: error writing "
                            (or (buffer-file-name (current-buffer)) "")))
                    #f))
             (save-buffer))))
       (lambda () #f)
       "Write the buffer back to its file."))

    ;;----------------------------------------------------------------
    ;; The two commands that still need the minibuffer
    ;;
    ;; `save-buffers-kill-terminal' is files.el's (it offers to save,
    ;; then asks whether to exit anyway) and `kill-buffer-command' is
    ;; the buffer layer's; both ask a question, so both wait for
    ;; `editor/minibuffer.sld'. Everything else that used to sit under
    ;; the `Windows' banner is in `(schemacs editor window)' now.
    ;;------------------------------------------------------------------

    (define save-buffers-kill-terminal
      (new-command
       "save-buffers-kill-terminal"
       ;; GNU Emacs's `save-buffers-kill-emacs': offer to save what
       ;; needs saving, then - since the user may have said no - ask
       ;; whether to go ahead and lose it. Either question abandoned
       ;; with C-g cancels the exit.
       (lambda ()
         (let ((frame (*current-frame*))
               (quit! (lambda ()
                        ((ncurses-frame-quit-cont (*current-frame*)) 'quit))))
           (case (save-some-buffers frame)
             ((clean) (quit!))
             (else
              (when (yes-or-no-p frame "Modified buffers exist; exit anyway? ")
                (quit!))))))
       (lambda () #f)
       "Quit the editor (bound to C-x C-c), offering to save first."))


    (define kill-buffer-command
      ;; GNU Emacs's `kill-buffer'. Killing a buffer that has unsaved
      ;; changes asks first: Emacs offers to kill it anyway, not to save
      ;; it (saving is offered on exit and by C-x C-s). Emacs then
      ;; switches to some other buffer; this frontend has only one, so
      ;; it falls back on an empty one, as if it had been left with
      ;; *scratch*.
      (new-command
       "kill-buffer"
       ;; GNU Emacs's `kill-buffer'. The asking is `kill-buffer-query-
       ;; functions', which is what Emacs asks with too; the rest - taking
       ;; the buffer out of the list, giving any window showing it another
       ;; buffer, and answering with its name - is `(schemacs editor
       ;; buffer)'. What used to be here was a hand-rolled version that
       ;; made a fresh buffer and forgot the one it killed.
       ;;
       ;; Emacs offers to kill a modified buffer rather than to save it;
       ;; saving is offered on exit and by C-x C-s.
       (lambda ()
         (let* ((frame (*current-frame*))
                (buffer (current-editor)))
           (let ((killed
                  (parameterize
                      ((*kill-buffer-query-functions*
                        (list (lambda ()
                                (or (not (text-editor-modified? buffer))
                                    (yes-or-no-p
                                     frame
                                     (string-append
                                      "Buffer "
                                      (text-editor-buffer-name buffer)
                                      " modified; kill anyway? ")))))))
                    (kill-buffer buffer))))
             ;; Emacs says nothing when a query function refused the kill
             ;; and "Killed buffer" when it did not; the window has already
             ;; been given another buffer by `kill-buffer' itself.
             (set!ncurses-frame-message
              frame (if killed (string-append "Killed " killed) ""))
             killed)))
       (lambda () #f)
       "Kill the current buffer (bound to C-x k), asking first if it has
 unsaved changes."))
    ;;----------------------------------------------------------------
    ;; Keymaps
    ;;
    ;; The global map is built by the libraries that define the commands, so
    ;; what is left for this file is the four bindings whose commands are
    ;; still here. `find-file-command' and `save-buffer-command' are
    ;; files.el's and go to `(schemacs editor files)' with the minibuffer
    ;; move, and these lines go with them; `kill-buffer-command' is the
    ;; buffer layer's.

    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\f))
      find-file-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\s))
      save-buffer-command)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\c))
      save-buffers-kill-terminal)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\k)
      kill-buffer-command)

    ;;----------------------------------------------------------------
    ;; The two commands that still need the minibuffer, and the last
    ;; of files.el that does
    ;;
    ;; `save-answer-char->decision' and `save-some-buffers' ask about
    ;; saving, so they are files.el's and go to
    ;; `(schemacs editor files)' with the file-visiting commands,
    ;; which are parked above. Everything else that used to sit under
    ;; the `minibuffer' and `Completion' banners is in
    ;; `(schemacs editor minibuffer)' now.
    ;;------------------------------------------------------------------

    (define (save-answer-char->decision answer)
      ;; What an answer to "Save file X? " means. The keys are GNU
      ;; Emacs's: `y' or SPC saves this buffer, `!' saves it and asks
      ;; nothing further about the buffers after it, and `n', DEL, `q'
      ;; and RET all mean "not this one". Emacs's remaining answers - `.'
      ;; (save this one and skip the rest), `C-r' and `d' (look at the
      ;; buffer and its differences from the file before deciding) - need
      ;; features this frontend does not have. C-g never arrives here: it
      ;; abandons the whole command.
      ;;--------------------------------------------------------------
      (cond
       ((not answer) 'skip)                       ; end of input
       ((or (char=? answer #\y)
            (char=? answer #\space)
            (char=? answer #\!))
        'save)
       (else 'skip)))

    (define (save-some-buffers frame)
      ;; Ask whether to save the buffer, if it needs saving, and save it
      ;; if the answer is yes. GNU Emacs's `save-some-buffers' asks this
      ;; of each modified buffer in turn; this frontend has one buffer,
      ;; so it asks once. Returns `clean' when nothing is left unsaved,
      ;; or `unsaved' when the user chose not to save it.
      ;;--------------------------------------------------------------
      (if (not (text-editor-modified? (current-editor)))
          'clean
          (let* ((ed (current-editor))
                 (file (text-editor-file-name ed))
                 (answer
                  (read-char-from-minibuffer
                   (string-append
                    ;; GNU Emacs asks about the file it would write, and
                    ;; about the buffer when it visits no file.
                    (if file
                        (string-append "Save file " file "? ")
                        (string-append
                         "Save buffer "
                         (or (text-editor-buffer-name ed) "*scratch*")
                         "? "))
                    "(y, n, !, q, or C-g) "))))
            (case (save-answer-char->decision answer)
              ((save)
               (run-command save-buffer-command)
               (if (text-editor-modified? (current-editor)) 'unsaved 'clean))
              (else 'unsaved)))))
    ;;----------------------------------------------------------------
    ;; File names
    ;;------------------------------------------------------------------

    (define (default-directory)
      ;; The directory a bare file name is relative to: GNU Emacs's
      ;; `default-directory', which is a buffer-local variable - each
      ;; buffer has its own, so two windows showing two files in two
      ;; directories prompt from the one each is in. `find-file' sets it
      ;; on the buffer it visits, as Emacs's does; a buffer that has not
      ;; been given one answers with the process's own directory.
      ;;--------------------------------------------------------------
      (or (buffer-default-directory (current-buffer))
          (string-append (getcwd) "/")))

    (define (file-name-directory-part name)
      ;; The directory part of NAME, including the final slash, or "" for
      ;; a bare name: GNU Emacs's `file-name-directory' as we need it.
      ;;--------------------------------------------------------------
      (let ((slash (string-rindex name #\/)))
        (if slash (substring name 0 (+ 1 slash)) "")))

    (define (file-name-nondirectory-part name)
      ;; The part of NAME after the last slash: GNU Emacs's
      ;; `file-name-nondirectory'.
      ;;--------------------------------------------------------------
      (let ((slash (string-rindex name #\/)))
        (if slash (substring name (+ 1 slash) (string-length name)) name)))

    (define (directory-entries dir prefix)
      ;; The names in DIR that begin with PREFIX, without the `.` and
      ;; `..` entries (which GNU Emacs hides too, unless the prefix asks
      ;; for dot files).
      ;;--------------------------------------------------------------
      (let ((port (opendir dir)))
        (if (not port)
            '()
            (let loop ((acc '()))
              (let ((entry (readdir port)))
                (cond
                 ((eof-object? entry)
                  (closedir port)
                  (reverse acc))
                 ((or (string=? entry ".") (string=? entry ".."))
                  (loop acc))
                 ((string-prefix? prefix entry) (loop (cons entry acc)))
                 (else (loop acc))))))))

    (define (directory-path? path)
      ;; Whether PATH names a directory.
      ;;--------------------------------------------------------------
      (eq? 'directory
           (with-exception-handler (lambda (e) 'none)
             (lambda () (stat:type (stat path))))))

    (define (file-name-completion-table name)
      ;; The file names NAME could complete to: GNU Emacs's
      ;; `read-file-name-internal'. Directories are offered with a
      ;; trailing slash so that completing one descends into it.
      ;;--------------------------------------------------------------
      (let* ((dir-part (file-name-directory-part name))
             (name-part (file-name-nondirectory-part name))
             (dir (if (string=? dir-part "")
                      (default-directory)
                      (if (char=? (string-ref dir-part 0) #\/)
                          dir-part
                          (string-append (default-directory) dir-part)))))
        (let loop ((entries (directory-entries dir name-part)) (acc '()))
          (if (null? entries)
              (reverse acc)
              (let ((entry (car entries)))
                (loop (cdr entries)
                      (cons (string-append
                             dir-part entry
                             (if (directory-path? (string-append dir entry)) "/" ""))
                            acc)))))))

    (define (read-file-name prompt)
      ;; Read a file name in the minibuffer, completing as TAB is typed:
      ;; GNU Emacs's `read-file-name', of which this takes the prompt
      ;; only. The prompt starts with `default-directory' already in it,
      ;; as Emacs's and mg's do, so a name is typed onto the end of it.
      ;; A name that does not exist yet is allowed, as Emacs allows it -
      ;; that is how a file is created.
      ;;--------------------------------------------------------------
      ;; `completing-read', not `read-from-minibuffer': that is the point
      ;; of this function in Emacs - it is `completing-read' with a file
      ;; name table and a file name history, and everything else about it
      ;; (what RET does, what the candidates are) is that function's.
      ;;
      ;; REQUIRE-MATCH is nil: a name that does not exist yet is allowed,
      ;; as Emacs allows it - that is how a file is created. The default
      ;; is the file the buffer already visits, so RET keeps the name it
      ;; has.
      (completing-read prompt file-name-completion-table #f #f
                       (default-directory)
                       file-name-history
                       (buffer-file-name (current-buffer))))

    ;;----------------------------------------------------------------
    ;; Final newlines
    ;;
    ;; GNU Emacs's `require-final-newline', and the rule it drives in
    ;; `basic-save-buffer-1' and `after-find-file': a buffer that does
    ;; not end in a line break is given one, on saving or on visiting,
    ;; when this says so. Emacs's own default value is nil, but
    ;; `mode-require-final-newline' is t and the file-visiting major
    ;; modes set the buffer's value from it, so what a file buffer
    ;; actually gets is t - which is why saving a file that lacked a
    ;; final line break adds one, in Emacs and here.
    ;;
    ;; t           add it when the buffer is saved
    ;; visit       add it when the file is visited
    ;; visit-save  add it at both times
    ;; any other   ask whether to add it, when saving
    ;; #f          never add one

    (define *require-final-newline*
      (make-parameter #t))

    (define (buffer-ends-with-newline? ed)
      ;; Whether the last character of the buffer is a line break. False
      ;; for an empty buffer, which Emacs treats as needing nothing.
      ;;--------------------------------------------------------------
      (let ((count (text-editor-char-count ed)))
        (and (< 0 count)
             (char=? (text-editor-get-char-index ed (- count 1)) #\newline))))

    (define (add-line-break-at-end! ed)
      ;; Append a line break to the buffer, leaving the cursor where it
      ;; was, as Emacs wraps this insertion in a `save-excursion'. The
      ;; insert is the engine's own, so the undo list and any markers
      ;; follow it, exactly as they would for a line break typed at the
      ;; end.
      ;;--------------------------------------------------------------
      (let ((at (text-editor-get-cursor ed)))
        (text-editor-set-cursor ed (text-editor-char-count ed))
        (text-editor-insert ed #\newline)
        (text-editor-set-cursor ed at)))

    (define (y-or-n-p prompt)
      ;; GNU Emacs's `y-or-n-p': a question one key answers, unlike
      ;; `yes-or-no-p', which wants the whole word. Emacs reads the key
      ;; itself; here it is read as a line whose first character is the
      ;; answer, the same deviation `read-char-from-minibuffer' has, so
      ;; "y", "yes", "n" and "no" all answer it.
      ;;--------------------------------------------------------------
      (let ((answer (read-char-from-minibuffer
                     (string-append prompt " (y or n) "))))
        (cond
         ((memv answer (list #\y #\Y #\space)) #t)
         (else #f))))

    (define (ensure-final-newline-on-save! ed)
      ;; Emacs's save-time rule: give the buffer a final line break, when
      ;; the variable says to, before it is written out. The buffer is
      ;; left holding what the file will hold, as in Emacs, which inserts
      ;; the line break into the buffer itself.
      ;;--------------------------------------------------------------
      (when (and (not (text-editor-read-only? ed))
                 (< 0 (text-editor-char-count ed))
                 (not (buffer-ends-with-newline? ed)))
        (let ((value (*require-final-newline*)))
          (when (cond
                 ((eq? value #t) #t)
                 ((eq? value 'visit-save) #t)
                 ((not value) #f)
                 (else
                  (y-or-n-p (string-append "Buffer "
                                           (or (text-editor-buffer-name ed)
                                               "*scratch*")
                                           " does not end in newline.  Add one? "))))
            (add-line-break-at-end! ed)))))

    (define (ensure-final-newline-on-visit text write-protected?)
      ;; Emacs's visit-time rule (`after-find-file'): the text being
      ;; visited, with a line break added when the variable says to add
      ;; one at visit time. A file that cannot be written is visited
      ;; read-only, and Emacs does not add anything to a read-only
      ;; buffer.
      ;;--------------------------------------------------------------
      (if (and (memq (*require-final-newline*) '(visit visit-save))
               (< 0 (string-length text))
               (not (char=? (string-ref text (- (string-length text) 1))
                            #\newline))
               (not write-protected?))
          (string-append text "\n")
          text))

    (define (note-file-read-only! frame)
      ;; Say so when the buffer just visited cannot be written, in GNU
      ;; Emacs's words. Emacs warns at visit time rather than waiting
      ;; for the first edit to be refused.
      ;;--------------------------------------------------------------
      (when (text-editor-read-only? (ncurses-frame-editor frame))
        (set!ncurses-frame-message frame "Note: file is write protected")))

    (define (find-file path)
      ;; Open a file into a text editor buffer and answer with it, the way
      ;; GNU Emacs's `find-file-noselect' visits a file: the line-break
      ;; convention is detected (CRLF, CR or LF), every carriage return is
      ;; decoded away so the buffer holds only line-feed breaks, and the
      ;; convention is recorded on the buffer - `buffer-file-coding-system'
      ;; - so saving can encode the breaks back. A file that cannot be
      ;; written is visited read-only, as Emacs does.
      ;;
      ;; The convention is the buffer's and not the caller's, which is why
      ;; nothing but the buffer comes back: Emacs's `find-file-noselect'
      ;; answers with the buffer too, and its caller has no second value to
      ;; pass on.
      ;;--------------------------------------------------------------
      (let* ((contents
              (call-with-input-file path
                (lambda (port)
                  (let loop ((acc (list)))
                    (let ((c (read-char port)))
                      (if (eof-object? c)
                          (list->string (reverse acc))
                          (loop (cons c acc))))))))
             (line-break (detect-line-break contents))
             ;; a file already visited is one buffer, not two: Emacs's
             ;; `find-file-noselect' answers with the buffer that is
             ;; visiting the file when there is one
             (visiting (find-buffer-visiting path))
             (ed (or visiting
                     ;; named after the file without its directory, as
                     ;; Emacs's `create-file-buffer' names it, and put in
                     ;; the buffer list
                     (get-buffer-create (file-name-nondirectory-part path)))))
        ;; Visiting a file leaves nothing to undo, as in GNU Emacs: what
        ;; is in the buffer is not an edit the user made. Re-enabling
        ;; undo discards what the load recorded.
        (text-editor-undo-disable! ed)
        (text-editor-insert ed (ensure-final-newline-on-visit
                                (decode-dos-returns contents)
                                (file-write-protected? path)))
        (text-editor-undo-enable! ed)
        ;; ... and what is in the buffer is what is in the file, so
        ;; there is nothing to save yet.
        (text-editor-set-modified! ed #f)
        ;; A file that cannot be written is visited read-only, so that
        ;; the edits which could not be saved are refused in the first
        ;; place rather than at the end.
        (text-editor-set-read-only! ed (file-write-protected? path))
        ;; The buffer remembers the file it came from - GNU Emacs's
        ;; `buffer-file-name' - and the name it was given when it was made
        ;; (a visiting buffer keeps the name it already had, which is what
        ;; Emacs does when it finds the file already in a buffer).
        (set!text-editor-file-name ed path)
        ;; and the convention it was read with, which is the buffer's
        ;; rather than the frame's - so that this buffer saves the way it
        ;; was loaded however many other files have been visited since
        (set!buffer-file-coding-system ed line-break)
        ;; and the directory its file is in, which its relative file names
        ;; are relative to: GNU Emacs's `default-directory', buffer-local,
        ;; which `find-file-noselect' sets to the file's directory
        (set!buffer-default-directory ed (file-name-directory-part path))
        ;; and point starts at the beginning of what was read, which is
        ;; where GNU Emacs's `find-file-noselect' puts it
        (text-editor-set-cursor ed 0 0)
        ed))

    (define (encode-line-breaks str line-break)
      ;; Encode the buffer's line-feed breaks back into the file's
      ;; line-break convention on save. A CRLF file gets its carriage
      ;; returns back; the other conventions are stored as they were read -
      ;; `decode-dos-returns' takes the carriage return out of a CR-LF pair
      ;; and leaves every other one in the buffer - so there is nothing to
      ;; put back.
      ;;--------------------------------------------------------------
      (if (not (eq? line-break line-break-crlf))
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

    (define (save-buffer)
      ;; Write the current buffer back to its file, encoding the line
      ;; breaks into the file's convention, and mark the buffer saved:
      ;; from here on there is nothing in it that the file does not have,
      ;; which is what clearing the modified flag means.
      ;;
      ;; GNU Emacs's `save-buffer', which acts on `(current-buffer)' and
      ;; takes no argument but the prefix argument that picks the backup
      ;; behaviour - there are no backup files here, so there is nothing
      ;; for that to say and nothing to pass. The file written is the
      ;; buffer's own `buffer-file-name', and the convention its own
      ;; `buffer-file-coding-system'; a buffer visiting no file asks for
      ;; one, which is what Emacs's `basic-save-buffer' does with
      ;; `(read-file-name "File to save in: ")'.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer))
            (path (or (buffer-file-name (current-buffer))
                      (let ((name (read-file-name "File to save in: ")))
                        (set!buffer-file-name (current-buffer) name)
                        name))))
        ;; Emacs settles the buffer's final line break before writing it.
        (ensure-final-newline-on-save! buffer)
        (call-with-output-file
            path
          (lambda (port)
            (display
             (encode-line-breaks
              (text-editor-to-string buffer)
              (buffer-file-coding-system buffer))
             port)))
        (text-editor-set-modified! buffer #f)
        (set!ncurses-frame-message (*current-frame*)
                                   (string-append "Wrote " path))
        path))

    ;;----------------------------------------------------------------
    ))
