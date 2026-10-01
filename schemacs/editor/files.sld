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
          frame-editor frame-quit-cont
          set!frame-editor
          set!frame-message)
    ;; The commands here install their own keys, as files.el does.
    (only (schemacs editor command)
          current-prefix-arg define-command run-command)
    ;; `switch-to-buffer' is `window.el''s, and not this file's: it shows a
    ;; buffer in the selected window, which is a window operation.
    (only (schemacs editor window) switch-to-buffer)
    ;; The file-name table is a *function* table, so it answers
    ;; `try-completion' and `all-completions' itself - `minibuf.c''s.
    (only (schemacs editor minibuf) all-completions try-completion)
    ;; Buffers by name, and killing one: `buffer.c'. `BUFFER-FILE-NAME' and
    ;; the buffer-local store are what `save-buffer' writes and what the
    ;; visited file's line-break convention is kept in.
    ;; `buffer.c''s `kill-buffer' is imported apart, because the command
    ;; below keeps Emacs's name `kill-buffer' for the interactive entry,
    ;; and the mechanism runs as `%kill-buffer'. (In Emacs the two are
    ;; one function; here the mechanism - which asks
    ;; `kill-buffer-query-functions' and leaves the buffer list - is in
    ;; `(schemacs editor buffer)', and the command, which needs the
    ;; minibuffer's question, is here.)
    (rename (only (schemacs editor buffer)
                  *current-buffer*
                  *kill-buffer-query-functions*
                  buffer-default-directory
                  buffer-file-name
                  buffer-list
                  buffer-name
                  rename-buffer
                  find-buffer-visiting
                  set-buffer-modified-p
                  buffer-local-value
                  current-buffer
                  get-buffer-create
                  kill-buffer
                  record-buffer!
                  set!buffer-default-directory
                  set!buffer-file-name
                  set-buffer-local-value!
                  with-current-buffer)
            (kill-buffer %kill-buffer))
    (only (schemacs editor keymap)
          define-key
          *default-keymap*
          *special-event-map*)
    ;; Every command here prompts.
    (only (schemacs editor minibuffer)
          *minibuffer-completing-file-name*
          completing-read
          file-name-history
          read-char-from-minibuffer
          read-from-minibuffer
          yes-or-no-p)
    ;; For deciding whether a file can be written, which is what makes a
    ;; visited file read-only (GNU Emacs's `file-writable-p', plus the
    ;; permission bits it also consults); and the directory reading and
    ;; name splitting `read-file-name' completes with.
    (only (guile) access? stat stat:mode W_OK X_OK logand logior
          closedir getcwd opendir readdir stat:type
          string-index string-prefix? string-rindex))

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
   expand-file-name
directory-name-p
   file-exists-p
   file-writable-p
   file-name-completion-table
   file-name-directory-part
   file-name-nondirectory-part
   file-write-protected?
   files--buffers-needing-to-be-saved
   find-file
   find-file-noselect
   kill-buffer
   note-file-read-only!
   read-file-name
   save-answer-char->decision
save-buffer
   set-visited-file-name
   write-file
   save-buffers-kill-terminal
   handle-delete-frame
   frames-except
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
      ;;
      ;; A file that is not there yet is writable when its *directory*
      ;; is: `file-writable-p''s docstring is "can be written or
      ;; created", and its C asks the directory when the file itself
      ;; answers ENOENT. Without that the file that `C-x C-f' had just
      ;; been asked to create was visited read-only - the exact opposite
      ;; of what a file being created is for.
      ;;--------------------------------------------------------------
      (cond
       ((not (file-exists-p path))
        (let ((dir (file-name-directory-part path)))
          (not (access? (if (string=? dir "") (default-directory) dir)
                        (logior W_OK X_OK)))))
       (else
        (or (not (access? path W_OK))
            (zero? (logand (stat:mode (stat path)) #o222))))))

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

    (define-command (find-file path)
      ;; GNU Emacs's `find-file' (files.el), the command C-x C-f runs:
      ;; prompt for a file name and visit it, switching to the buffer,
      ;; exactly as Emacs's `(switch-to-buffer (find-file-noselect
      ;; filename))' is. That is why the visitor below is
      ;; `find-file-noselect' and this command `find-file' - the one is
      ;; a plain function, the other a command, as in Emacs.
      "Prompt for a file name and load it into the buffer."
      (interactive (list (read-file-name "Find file: ")))
      (let ((frame (*current-frame*)))
        (guard (ex
                (else
                 (set!frame-message
                  frame (string-append
                         "; find-file: error loading " path))
                 #f))
          ;; the message is cleared *before* the file is visited, so
          ;; that what `find-file' says about it - "(New file)", or
          ;; the read-only note - is what stays in the echo area
          (set!frame-message frame "")
          (switch-to-buffer (find-file-noselect path))
          (note-file-read-only! frame)
          path)))

    ;;----------------------------------------------------------------
    ;; The two commands that still need the minibuffer
    ;;
    ;; `save-buffers-kill-terminal' is files.el's (it offers to save,
    ;; then asks whether to exit anyway) and `kill-buffer-command' is
    ;; the buffer layer's; both ask a question, so both wait for
    ;; `editor/minibuffer.sld'. Everything else that used to sit under
    ;; the `Windows' banner is in `(schemacs editor window)' now.
    ;;------------------------------------------------------------------

    (define (frames-except frame)
      ;; The frames other than FRAME. This editor has one frame
      ;; (`*current-frame*'), so the scan Emacs's `handle-delete-frame'
      ;; does before it decides the frame being closed is the last is a
      ;; scan over that one frame - and it is the scan, not a hardcoded
      ;; "this is the last frame", that a multi-frame editor extends.
      ;;--------------------------------------------------------------
      (let ((current (*current-frame*)))
        (if (and current (not (eq? current frame))) (list current) '())))

    (define-command (handle-delete-frame event)
      ;; GNU Emacs's `handle-delete-frame' (`frame.el:265'): the window
      ;; manager has asked to close FRAME. "If there is another visible
      ;; frame, delete this one; otherwise `save-buffers-kill-emacs'" -
      ;; the second of those being the logic Chris presumed, and it is
      ;; `save-buffers-kill-emacs' rather than a bare exit, which is why
      ;; Emacs asks about unsaved buffers before it goes. It is in this
      ;; library rather than `frame.sld' because the command it hands off
      ;; to is `save-buffers-kill-terminal', which is here.
      ;;
      ;; Emacs's takes the EVENT as its argument - `(interactive "e")' -
      ;; and reads the frame from it: `(nth 1 event)' is the frame list
      ;; `keyboard.c:6238' built, whose car is the frame. This tree's
      ;; event is the same shape, so the frame is read from it too - and
      ;; `frames-except' is given *that* frame, which is the one being
      ;; closed and need not be the selected one if there were several.
      ;;--------------------------------------------------------------
      "Handle the window manager's request to close the frame."
      (interactive "e")
      (let ((others (frames-except (car (list-ref event 1)))))
        (if (pair? others)
            others
            (save-buffers-kill-terminal))))

    (define-command (save-buffers-kill-terminal)
      ;; GNU Emacs's `save-buffers-kill-emacs': offer to save what
      ;; needs saving, then - since the user may have said no - ask
      ;; whether to go ahead and lose it. Either question abandoned
      ;; with C-g cancels the exit.
      "Quit the editor (bound to C-x C-c), offering to save first."
      (interactive)
      (let ((frame (*current-frame*))
            (quit! (lambda ()
                     ((frame-quit-cont (*current-frame*)) 'quit))))
        ;; The asking happens only when there is something worth
        ;; asking about - `files--buffers-needing-to-be-saved', with
        ;; Emacs's predicate `t'. The minibuffer and `*Completions*'
        ;; are modified a good deal of the time and visit no file, so
        ;; a `C-x C-c' asked right after `C-x C-f' does not offer to
        ;; save the help buffer: there is nothing on the list.
        (when (files--buffers-needing-to-be-saved #t)
          (save-some-buffers frame #t))
        ;; Then Emacs's `and' legs: without a modified file-visiting
        ;; buffer there is nothing more to ask and it kills; with
        ;; one, it asks whether to go ahead, and kills on "yes".
        ;; C-g in the question abandons the whole command, and
        ;; nothing is killed.
        (if (let scan ((buffers (buffer-list)))
              (and (pair? buffers)
                   (let ((buffer (car buffers)))
                     (or (and (buffer-file-name buffer)
                              (text-editor-modified? buffer))
                         (scan (cdr buffers))))))
            (when (yes-or-no-p frame
                               "Modified buffers exist; exit anyway? ")
              (quit!))
            (quit!))))


    (define-command (kill-buffer)
      ;; C-x k runs this. GNU Emacs's `kill-buffer'. Killing a buffer
      ;; that has unsaved changes asks first: Emacs offers to kill it
      ;; anyway, not to save it (saving is offered on exit and by C-x
      ;; C-s). Emacs then switches to some other buffer; this frontend
      ;; has only one, so it falls back on an empty one, as if it had
      ;; been left with *scratch*.
      ;;
      ;; GNU Emacs's `kill-buffer'. The asking is `kill-buffer-query-
      ;; functions', which is what Emacs asks with too; the rest - taking
      ;; the buffer out of the list, giving any window showing it another
      ;; buffer, and answering with its name - is `(schemacs editor
      ;; buffer)'. What used to be here was a hand-rolled version that
      ;; made a fresh buffer and forgot the one it killed.
      ;;
      ;; Emacs offers to kill a modified buffer rather than to save it;
      ;; saving is offered on exit and by C-x C-s.
      "Kill the current buffer (bound to C-x k), asking first if it has
 unsaved changes."
      (interactive)
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
                 (%kill-buffer buffer))))
          ;; Emacs says nothing when a query function refused the kill
          ;; and "Killed buffer" when it did not; the window has already
          ;; been given another buffer by `%kill-buffer' itself.
          (set!frame-message
           frame (if killed (string-append "Killed " killed) ""))
          killed)))
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
      ;; What an answer to "Save file X? " means, in the terms the
      ;; asking loop acts on. The keys are GNU Emacs's, from
      ;; `map-y-or-n-p`, which `save-some-buffers` asks through: `y' or
      ;; SPC saves this buffer and goes on to the next, `n', DEL or any
      ;; other key leaves it and goes on, `!' saves it and saves the rest
      ;; without asking, `q', RET or ESC stops asking here, and `.'
      ;; saves this one and then stops (Emacs: "ESC or q to exit").
      ;; Emacs's remaining answers - `C-r' and `d' (look at the buffer
      ;; and its differences from the file before deciding) - need
      ;; features this frontend does not have. C-g never arrives here:
      ;; it abandons the whole command.
      ;;--------------------------------------------------------------
      (cond
       ((not answer) 'skip)                       ; end of input
       ((or (char=? answer #\y) (char=? answer #\space)) 'save)
       ((char=? answer #\!) 'save-all)
       ((char=? answer #\.) 'save-then-quit)
       ((or (char=? answer #\q) (char=? answer #\return)
            (char=? answer #\esc)) 'quit)
       (else 'skip)))

    (define (files--buffers-needing-to-be-saved pred)
      ;; GNU Emacs's `files--buffers-needing-to-be-saved': the modified
      ;; buffers worth asking about, in `buffer-list' order. What "worth"
      ;; means is the point of the function: a buffer counts only when it
      ;; is modified AND either visits a file or has said in advance that
      ;; it wants to be offered (`buffer-offer-save', which the mail and
      ;; log buffers set in Emacs). The minibuffer's own buffer and
      ;; `*Completions*' are modified a good deal of the time and visit
      ;; nothing, so they are never on the list - which is why a `C-x C-f'
      ;; that never reached a file does not make `C-x C-c' ask about them.
      ;;
      ;; PRED is Emacs's: `t' - what both callers here pass - gives the
      ;; whole list, and a procedure would keep only the buffers for
      ;; which it returns true.
      ;;
      ;; Not ported: `buffer-base-buffer' (there are no indirect buffers)
      ;; and `buffer-save-without-query' (no library here saves buffers
      ;; on its own before asking about them).
      ;;--------------------------------------------------------------
      (let loop ((buffers (buffer-list)) (kept '()))
        (if (null? buffers)
            (reverse kept)
            (let ((buffer (car buffers)))
              (loop (cdr buffers)
                    (if (and (text-editor-modified? buffer)
                             (or (buffer-file-name buffer)
                                 (let ((offer (buffer-local-value
                                               buffer 'buffer-offer-save #f)))
                                   (or (eq? offer 'always)
                                       (and pred offer
                                            (< 0 (text-editor-char-count
                                                  buffer))))))
                             (or (not (procedure? pred))
                                 (with-current-buffer buffer (pred))))
                        (cons buffer kept)
                        kept))))))

    (define (save-some-buffers frame pred)
      ;; Ask whether to save each buffer that needs saving, and save it
      ;; if the answer is yes: GNU Emacs's `save-some-buffers', whose
      ;; candidates are `files--buffers-needing-to-be-saved' and whose
      ;; questions go through `map-y-or-n-p` - the answers are the ones
      ;; `save-answer-char->decision' spells out. Emacs also saves, up
      ;; front and without asking, any buffer that has
      ;; `buffer-save-without-query' set; nothing in this frontend sets
      ;; it.
      ;;
      ;; Each saved buffer is saved in its own right, made current for
      ;; the save as Emacs's action is `(with-current-buffer buffer
      ;; (save-buffer))': saving one buffer must not touch another.
      ;;--------------------------------------------------------------
      (let ask ((buffers (files--buffers-needing-to-be-saved pred)))
        (if (null? buffers)
            #f
            (let* ((ed (car buffers))
                   (rest (cdr buffers))
                   (file (text-editor-file-name ed))
                   (answer
                    (read-char-from-minibuffer
                     (string-append
                      ;; GNU Emacs asks about the file it would write,
                      ;; and about the buffer when it visits no file but
                      ;; offered to be asked.
                      (if file
                          (string-append "Save file " file "? ")
                          (string-append
                           "Save buffer "
                           (or (text-editor-buffer-name ed) "*scratch*")
                           "? "))
                      "(y, n, !, ., q, or C-g) "))))
              (case (save-answer-char->decision answer)
                ((save)
                 (with-current-buffer ed (save-buffer))
                 (ask rest))
                ((save-all)
                 (for-each (lambda (buffer)
                             (with-current-buffer buffer (save-buffer)))
                           (cons ed (reverse rest))))
                ((save-then-quit)
                 (with-current-buffer ed (save-buffer)))
                ((quit) #f)
                (else (ask rest)))))))
    ;;----------------------------------------------------------------
    ;; File names
    ;;------------------------------------------------------------------

    (define (default-directory)
      ;; The directory a bare file name is relative to: GNU Emacs's
      ;; `default-directory', which is a buffer-local variable - each
      ;; buffer has its own, so two windows showing two files in two
      ;; directories prompt from the one each is in. `find-file' sets it
      ;; on the buffer it visits, as Emacs's does.
      ;;
      ;; Its *default* - what it answers with when the buffer has not
      ;; been given one, and when there is no current buffer at all - is
      ;; the process's own directory, which is Emacs's global value of
      ;; the variable. The no-buffer case matters: `find-file' expands
      ;; the name it is given against this, so a `find-file' called with
      ;; nothing current - from a script, or a test - failed on the way
      ;; to reading the file at all.
      ;;--------------------------------------------------------------
      ;;
      ;; `(current-buffer)' with one guard: it falls back to the frame's
      ;; selected window, and with no frame there - which is what a
      ;; `find-file' called from a script or a test has - there is
      ;; nothing to ask, so the answer is the process's directory rather
      ;; than an error on the way to reading the file.
      ;;--------------------------------------------------------------
      (let ((buffer (or (*current-buffer*)
                        (and (*current-frame*) (current-editor)))))
        (or (and buffer (buffer-default-directory buffer))
            (string-append (getcwd) "/"))))

    (define (path-segments path)
      ;; PATH's segments, with the empty ones - from a leading or a
      ;; repeated slash - dropped.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (start 0) (acc '()))
        (cond
         ((= i (string-length path))
          (reverse (if (< start i) (cons (substring path start i) acc) acc)))
         ((char=? (string-ref path i) #\/)
          (loop (+ 1 i) (+ 1 i)
                (if (< start i) (cons (substring path start i) acc) acc)))
         (else (loop (+ 1 i) start acc)))))

    (define (join-path-segments segments)
      ;; SEGMENTS joined with a slash between them: the tail of
      ;; `expand-file-name' that puts a resolved path back together.
      ;;--------------------------------------------------------------
      (if (null? segments)
          ""
          (let loop ((rest (cdr segments)) (acc (car segments)))
            (if (null? rest)
                acc
                (loop (cdr rest) (string-append acc "/" (car rest)))))))

    (define (expand-file-name name . args)
      ;; GNU Emacs's `expand-file-name': NAME as an absolute file name.
      ;; A NAME with no directory of its own - one not starting with a
      ;; slash - is relative to DEFAULT-DIRECTORY, which is the asking
      ;; buffer's own when no other is given; either way the `.` and `..`
      ;; segments are resolved and repeated slashes collapsed.
      ;;
      ;; This is what `read-file-name' answers with, which is why a bare
      ;; name can be typed at the prompt at all: Emacs puts the directory
      ;; *in* the minibuffer, so its answer is absolute already, while
      ;; this editor keeps the prompt beside the buffer rather than in it
      ;; - so what is typed has to be joined to the directory here. A
      ;; name typed in a buffer visiting a file is relative to that
      ;; file's directory, which is what `default-directory' says.
      ;;
      ;; Not implemented: `~' expansion, and the environment-variable,
      ;; wildcard and remote-file syntaxes. Nothing here has a home
      ;; directory to expand against yet.
      ;;--------------------------------------------------------------
      (let* ((default (if (pair? args) (car args) (default-directory)))
             (full (cond
                    ((= 0 (string-length name)) default)
                    ((char=? (string-ref name 0) #\/) name)
                    (else (string-append default name))))
             ;; A trailing slash names a directory and has to survive
             ;; the rebuilding below, which would otherwise drop it.
             ;; An *empty* NAME is the exception, and Emacs's: it expands
             ;; to the directory itself with no trailing slash.
             (directory? (and (< 0 (string-length name))
                              (< 1 (string-length full))
                              (char=? (string-ref full
                                                  (- (string-length full) 1))
                                      #\/))))
        (let resolve ((rest (path-segments full)) (acc '()))
          (cond
           ((null? rest)
            (let ((path (string-append "/" (join-path-segments
                                            (reverse acc)))))
              (cond ((string=? path "/") path)
                    (directory? (string-append path "/"))
                    (else path))))
           ((string=? (car rest) ".") (resolve (cdr rest) acc))
           ;; a `..' takes back the segment before it, and does nothing
           ;; at the root, which is what Emacs does with one
           ((string=? (car rest) "..")
            (resolve (cdr rest) (if (null? acc) acc (cdr acc))))
           (else (resolve (cdr rest) (cons (car rest) acc)))))))

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

    (define (directory-name-p name)
      ;; GNU Emacs's `directory-name-p' (fileio.c:703): whether NAME
      ;; ends with a directory separator - "for example `usr/' and
      ;; `usr' are both directories, but only `usr/' is a directory
      ;; name". It is what `write-file' asks of the name the user gave,
      ;; since a name that ends in a slash names a directory and the
      ;; file gets the buffer's own base name in it.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length name))
           (char=? (string-ref name (- (string-length name) 1)) #\/)))

    (define (file-writable-p path)
      ;; GNU Emacs's `file-writable-p' (fileio.c): "t if you can write
      ;; to file or directory PATH". A file that does not exist is
      ;; writable when its directory is, which is Emacs's rule and the
      ;; one `write-file' works from - a buffer made writable by the
      ;; file it now visits.
      ;;--------------------------------------------------------------
      (if (file-exists-p path)
          (access? path W_OK)
          (let ((dir (file-name-directory-part path)))
            (access? (if (string=? dir "") "." dir) W_OK))))

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

    (define (file-exists-p path)
      ;; GNU Emacs's `file-exists-p': whether PATH names something that
      ;; exists. Emacs's is true of a directory as well as of a file, and
      ;; so is this.
      ;;
      ;; `guard', not `with-exception-handler': the exception `stat'
      ;; raises is *non-continuable*, and a handler that returns from one
      ;; of those re-raises it - so the `with-exception-handler' spelling
      ;; this started as answered nothing at all and let the error out.
      ;;--------------------------------------------------------------
      (guard (e (else #f))
        (stat path)
        #t))

    (define (directory-path? path)
      ;; Whether PATH names a directory. `guard' for the same reason
      ;; `file-exists-p' uses it: a non-continuable exception cannot be
      ;; caught by a handler that returns.
      ;;--------------------------------------------------------------
      (guard (e (else #f))
        (eq? 'directory (stat:type (stat path)))))

    (define (file-name-completion-table string predicate action)
      ;; The file names STRING could complete to: GNU Emacs's
      ;; `read-file-name-internal'.
      ;;
      ;; It is a *function* table - called with `(STRING PREDICATE
      ;; ACTION)' - because which names are candidates depends on STRING,
      ;; and the caller says which of the three questions it is asking:
      ;; ACTION is #f for what STRING can be completed to, `#t' for the
      ;; candidates themselves, and anything else - Emacs sends the symbol
      ;; `lambda' - for whether STRING is *already* one of them. That is
      ;; Emacs's signature, and a table that took only STRING would be the
      ;; old one-argument form this project used before
      ;; `(schemacs editor minibuf)' existed.
      ;;
      ;; The third question is the one this table used to get wrong, and
      ;; the wrong answer read as a completion that had gone as far as it
      ;; could: `all-completions' answered it with a *list* of names, which
      ;; is true whatever the name was, so `completion--do-completion'
      ;; thought every name typed was a valid completion and TAB on an
      ;; ambiguous one said "Complete, but not unique" instead of showing
      ;; the candidates. GNU Emacs's `completion-file-name-table' answers
      ;; it with `file-exists-p'.
      ;;
      ;; The fourth question is `(boundaries . SUFFIX)': where in STRING
      ;; the text being completed *begins*, which for a file name is
      ;; after the last slash - the directory part is not completed, the
      ;; name after it is. That is what makes the candidates come back
      ;; as names without their directory (`file-name-all-completions
      ;; name realdir'), and the `*Completions*' buffer show `alpha.txt'
      ;; where the minibuffer holds `/tmp/mbtest/alpha.txt': the styles
      ;; hand the boundary on as the *base size*, and `choose-completion'
      ;; replaces only what is after it.
      ;;
      ;; Directories are offered with a trailing slash so that completing
      ;; one descends into it.
      ;;--------------------------------------------------------------
      (cond
       ((and (pair? action) (eq? (car action) 'boundaries))
        ;; `(boundaries START . END)': START is the length of the
        ;; directory part - "clipping it back" to STRING's length is
        ;; Emacs's guard for the w32 "C:" case - and END is where the next
        ;; slash is in SUFFIX, or #f for its end.
        (let ((start (string-length (file-name-directory-part string)))
              (suffix (cdr action)))
          (cons 'boundaries
                (cons (min start (string-length string))
                      (string-index suffix #\/)))))

       ((eq? action 'lambda)
        ;; is STRING itself a file? The empty string is not, whatever
        ;; `file-exists-p' would say about it - Emacs's comment on that
        ;; is "Not sure why it's here, but it probably doesn't harm".
        (and (< 0 (string-length string))
             (if predicate (predicate string) (file-exists-p string))))

       (else
        (let* ((name (file-name-nondirectory-part string))
               (specdir (file-name-directory-part string))
               (realdir (cond ((string=? specdir "") (default-directory))
                              ((char=? (string-ref specdir 0) #\/) specdir)
                              (else (string-append (default-directory) specdir))))
               ;; `file-name-all-completions name realdir': the entries
               ;; NAME is a prefix of, as names, a slash on the directories
               (names (let loop ((entries (directory-entries realdir name)) (acc '()))
                        (if (null? entries)
                            (reverse acc)
                            (let ((entry (car entries)))
                              (loop (cdr entries)
                                    (cons (string-append
                                           entry
                                           (if (directory-path? (string-append realdir entry))
                                               "/" ""))
                                          acc)))))))
          (cond
           ((eq? action #f)
            ;; `file-name-completion name realdir pred', and the directory
            ;; put back in front of what it found
            (let ((comp (try-completion name names predicate)))
              (if (string? comp)
                  (string-append specdir comp)
                  comp)))
           (else
            ;; ACTION is #t for the list, or a function for the
            ;; candidates PREDICATE accepts - and `all-completions'
            ;; answers both, with the names as Emacs answers them.
            (all-completions name names predicate)))))))

    (define (read-file-name . args)
      ;; Read a file name in the minibuffer, completing as TAB is typed:
      ;; GNU Emacs's `read-file-name', of which this takes the prompt and
      ;; - as `write-file' needs - an optional DEFAULT, Emacs's fourth
      ;; argument: what RET answers when the user types nothing. The
      ;; prompt starts with `default-directory' already in it, as Emacs's
      ;; and mg's do, so a name is typed onto the end of it. A name that
      ;; does not exist yet is allowed, as Emacs allows it - that is how
      ;; a file is created.
      ;;--------------------------------------------------------------
      ;; `completing-read', not `read-from-minibuffer': that is the point
      ;; of this function in Emacs - it is `completing-read' with a file
      ;; name table and a file name history, and everything else about it
      ;; (what RET does, what the candidates are) is that function's.
      ;;
      ;; REQUIRE-MATCH is nil: a name that does not exist yet is allowed,
      ;; as Emacs allows it - that is how a file is created. The default
      ;; is the file the buffer already visits, so RET keeps the name it
      ;; has - unless the caller named one, which `write-file' does for a
      ;; buffer that visits nothing.
      ;;
      ;; `minibuffer-completing-file-name' is what tells
      ;; `completing-read' to layer the file-name keymap over the
      ;; completion map, and that map's whole job is to take SPC away
      ;; from `minibuffer-complete-word' - a file name may have a space
      ;; in it, and a space must insert one.
      ;;
      ;; The answer is put through `expand-file-name', as Emacs's
      ;; `read-file-name-default' does with the name it read - the
      ;; reader types a name relative to the directory in the prompt, and
      ;; a bare name means nothing to anything that opens the file.
      ;;--------------------------------------------------------------
      (let* ((prompt (car args))
             (directory (default-directory))
             (default (if (pair? (cdr args)) (cadr args) #f)))
        (expand-file-name
         (parameterize ((*minibuffer-completing-file-name* #t))
           (completing-read prompt file-name-completion-table #f #f
                            directory
                            file-name-history
                            (or default
                                (buffer-file-name (current-buffer)))))
         directory)))

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
      (when (text-editor-read-only? (frame-editor frame))
        (set!frame-message frame "Note: file is write protected")))

    (define (find-file-noselect path)
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
      ;;
      ;; A name that is not there yet is *not* an error: it is how a file
      ;; is created. Emacs visits an empty buffer for it, calls it
      ;; `buffer-file-name' so that saving writes it there, and says
      ;; "(New file)" - and this used to fail with an error reading a file
      ;; that was not there, so `C-x C-f newfile.txt' could not make one.
      ;;--------------------------------------------------------------
      ;; The name is made absolute first, which is the first thing Emacs's
      ;; `find-file-noselect' does - `(setq filename (abbreviate-file-name
      ;; (expand-file-name filename)))'. A name that arrives from
      ;; `read-file-name' is absolute already, but one that does not - a
      ;; file named on the command line, which startup.el visits by name -
      ;; is not, and everything below reads its *directory*: the buffer's
      ;; `default-directory' is set from it, so `C-x C-f' in a buffer
      ;; visiting `foo' prompted with nothing at all, the directory part
      ;; of a bare name being the empty string. Emacs's
      ;; `abbreviate-file-name' - which shortens a name under the home
      ;; directory - is not implemented; there is no home directory here
      ;; to shorten against.
      (let ((path (expand-file-name path)))
      (or
       ;; a file already visited is one buffer, not two - and it is
       ;; returned as it stands: Emacs's `find-file-noselect' does not
       ;; read the file again either, and reading it into the buffer it
       ;; is already in would *append* a second copy to it.
       (find-buffer-visiting path)
       (let* ((new? (not (file-exists-p path)))
              (contents
               (if new?
                   ""
                   (call-with-input-file path
                     (lambda (port)
                       (let loop ((acc (list)))
                         (let ((c (read-char port)))
                           (if (eof-object? c)
                               (list->string (reverse acc))
                               (loop (cons c acc)))))))))
             (line-break (detect-line-break contents))
             ;; named after the file without its directory, as Emacs's
             ;; `create-file-buffer' names it, and put in the buffer list
             (ed (get-buffer-create (file-name-nondirectory-part path))))
        ;; Visiting a file leaves nothing to undo, as in GNU Emacs: what
        ;; is in the buffer is not an edit the user made. Re-enabling
        ;; undo discards what the load recorded.
        (text-editor-undo-disable! ed)
        (unless new?
          (text-editor-insert ed (ensure-final-newline-on-visit
                                  (decode-dos-returns contents)
                                  (file-write-protected? path))))
        (text-editor-undo-enable! ed)
        ;; The echo area says what Emacs's `after-find-file' says about a
        ;; file that was not there.
        (when new? (set!frame-message (*current-frame*) "(New file)"))
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
        ed))))

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

    (define-command (save-buffer)
      ;; C-x C-s runs this. GNU Emacs's `save-buffer', which acts on
      ;; `(current-buffer)' and takes no argument but the prefix
      ;; argument that picks the backup behaviour - there are no backup
      ;; files here, so there is nothing for that to say and nothing to
      ;; pass. The file written is the buffer's own
      ;; `buffer-file-name', and the convention its own
      ;; `buffer-file-coding-system'; a buffer visiting no file asks
      ;; for one, which is what Emacs's `basic-save-buffer' does with
      ;; `(read-file-name "File to save in: ")'.
      ;;
      ;; Write the current buffer back to its file, encoding the line
      ;; breaks into the file's convention, and mark the buffer saved:
      ;; from here on there is nothing in it that the file does not
      ;; have, which is what clearing the modified flag means. The
      ;; error message around it is this project's rather than Emacs's:
      ;; Emacs signals, and the command loop reports.
      "Write the buffer back to its file."
      (interactive)
      (let ((frame (*current-frame*)))
        (guard (ex
                (else
                 (set!frame-message
                  frame (string-append
                         "; save-buffer: error writing "
                         (or (buffer-file-name (current-buffer)) "")))
                 #f))
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
            (set!frame-message (*current-frame*)
                                       (string-append "Wrote " path))
            path))))

    (define (set-visited-file-name filename . args)
      ;; GNU Emacs's `set-visited-file-name' (files.el:5146): "Change
      ;; name of file visited in current buffer to FILENAME. This also
      ;; renames the buffer to correspond to the new file. The next
      ;; time the buffer is saved it will go in the newly specified
      ;; file." FILENAME nil or the empty string marks the buffer as
      ;; visiting nothing. NO-QUERY - `write-file''s way of passing
      ;; `(not CONFIRM)' - leaves out the warning when another buffer
      ;; already visits the file. ALONG-WITH-FILE is Emacs's third
      ;; argument, for a file that has been renamed under the buffer;
      ;; nothing here tracks a file's modtime, so there is nothing for
      ;; it to keep in step with.
      ;;
      ;; Not ported: the file's truename and `buffer-file-number', the
      ;; visit-modtime bookkeeping, `buffer-backed-up' (there are no
      ;; backups yet), and the flushing of `write-file-functions' -
      ;; there are no hooks here either. `find-file-visit-truename' is
      ;; not a variable here.
      ;;--------------------------------------------------------------
      (let ((no-query (if (pair? args) (car args) #f)))
        (let ((filename (and filename
                             (not (string=? filename ""))
                             (expand-file-name filename))))
          (when filename
            (unless (< 0 (string-length (file-name-nondirectory-part filename)))
              (error "Empty file name")))
          ;; A buffer already visiting the file is asked about, as
          ;; Emacs's `find-buffer-visiting' branch is.
          (let ((buffer (and filename (find-buffer-visiting filename))))
            (when (and buffer (not (eq? buffer (current-buffer))) (not no-query))
              (or (y-or-n-p
                   (string-append "A buffer is visiting " filename "; proceed? "))
                  (error "Aborted"))))
          (set!buffer-file-name (current-buffer) filename)
          ;; the buffer's name reflects the file's, as Emacs's does,
          ;; and so does its default directory
          (when filename
            (let ((new-name (file-name-nondirectory-part filename)))
              (set!buffer-default-directory
               (current-buffer) (file-name-directory-part filename))
              ;; If new-name == old-name, renaming would add a spurious
              ;; <2> and it's considered as a feature in rename-buffer.
              (unless (string=? new-name (buffer-name (current-buffer)))
                (rename-buffer (current-buffer) new-name #t))))
          filename)))

    (define-command (write-file filename confirm)
      ;; GNU Emacs's `write-file' (files.el:5267): "Write current buffer
      ;; into file FILENAME. This makes the buffer visit that file, and
      ;; marks it as not modified." `save-buffer' can only write the
      ;; file a buffer already visits, so this is how a buffer gets a
      ;; new name to live in.
      ;;
      ;; Interactively the name is read, and - unless a prefix argument
      ;; was given - overwriting an existing file is confirmed with
      ;; `y-or-n-p'.
      ;;
      ;; Not ported: the executable bit Emacs copies from the file the
      ;; buffer visited before (`file-modes' / `set-file-modes' are not
      ;; here).
      ;;--------------------------------------------------------------
      "Write current buffer into file FILENAME."
      (interactive
       (list (if (buffer-file-name (current-buffer))
                 (read-file-name "Write file: ")
                 (read-file-name
                  "Write file: "
                  (expand-file-name
                   (file-name-nondirectory-part (buffer-name (current-buffer)))
                   (default-directory))))
             (not (current-prefix-arg))))
      (unless (or (not filename) (string=? filename ""))
        ;; If arg is a directory name, use the default file name, but
        ;; in that directory.
        (let ((filename
               (if (directory-name-p filename)
                   (string-append
                    filename
                    (file-name-nondirectory-part
                     (or (buffer-file-name (current-buffer))
                         (buffer-name (current-buffer)))))
                   filename)))
          (when (and confirm (file-exists-p filename))
            (or (y-or-n-p (string-append "File `" filename "' exists; overwrite? "))
                (error "Canceled")))
          (set-visited-file-name filename (not confirm)))
        (set-buffer-modified-p (current-buffer) #t)
        ;; Make buffer writable if file is writable: a buffer that
        ;; could not write its old file was visited read-only, and the
        ;; new one is not to be.
        (when (and (buffer-file-name (current-buffer))
                   (file-writable-p (buffer-file-name (current-buffer))))
          (text-editor-set-read-only! (current-buffer) #f))
        (save-buffer)))

    ;;----------------------------------------------------------------
    ;; Keymaps
    ;;
    ;; The global map is built by the libraries that define the commands,
    ;; so a library binds the keys of the commands it defines. These are
    ;; the last things in the file, because the bindings hold the
    ;; commands' values, and Guile resolves a binding when the form is
    ;; evaluated - a `define-key' before its command's `define-command' would
    ;; find the name unbound.
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\f))
      find-file)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\s))
      save-buffer)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\w))
      write-file)
    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\c))
      save-buffers-kill-terminal)
    ;; The window manager's request to close the frame arrives as the key
    ;; event `(delete-frame (FRAME))', which `keyboard.c:6238' makes and
    ;; `keyboard.c:14550' binds to `handle-delete-frame' in
    ;; `special-event-map'. Here the binding is made where the command is,
    ;; as every binding in this tree is.
    (define-key *special-event-map* (list "delete-frame")
      handle-delete-frame)
    (define-key *default-keymap* (list (list 'ctrl #\x) #\k)
      kill-buffer)

    ;;----------------------------------------------------------------
    ))
