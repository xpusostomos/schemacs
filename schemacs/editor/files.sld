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
    ;;
    ;; `delete-file' is EXCEPTED: `(scheme file)' exports a one-argument
    ;; one, Emacs's `delete-file' (defined below, files.el's) takes the
    ;; TRASH argument as well, and an imported binding of the same name
    ;; wins over the definition - so the two-argument call came apart
    ;; with "Wrong number of arguments to #<procedure delete-file (_)>"
    ;; the first time Dired deleted anything.
    (except (scheme file) delete-file)
    (only (scheme write) display)
    (only (rnrs io ports) get-bytevector-all put-bytevector)
    ;; The coding system layer, which is where reading and writing
    ;; a file stopped going through the default port encoding.
    (only (schemacs editor coding)
          coding-setup-port! coding-read-char coding-write-char
          coding-system-p coding-system-name coding-system-eol-type
          coding-system-change-eol-conversion
          detect-eol bytes-have-null? adjust-coding-eol-type
          detect-coding-bytes find-operation-coding-system
          coding-system-bom
          decode-eol encode-eol *last-coding-system-used*
          *coding-system-for-read* *coding-system-for-write*)
    (only (schemacs editor mule) set-auto-coding)
    (only (schemacs editor engine)
          set!text-editor-buffer-name set!text-editor-file-name
          text-editor-buffer-name text-editor-char-count
          text-editor-file-name text-editor-get-char-index text-editor-get-cursor
          text-editor-point-min text-editor-point-max
          text-editor-insert text-editor-to-code-points
          text-editor-modified? text-editor-read-only?
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
    ;; `find-file-other-window' shows one in the OTHER window.
    (only (schemacs editor window) pop-to-buffer-same-window
          switch-to-buffer switch-to-buffer-other-window)
    ;; The file-name table is a *function* table, so it answers
    ;; `try-completion' and `all-completions' itself - `minibuf.c''s.
    (only (schemacs editor minibuf) all-completions try-completion)
    ;; `insert-file', `revert-buffer' and the rest edit the buffer:
    ;; the position primitives and the read-only check are editfns.c's.
    (only (schemacs editor editfns)
          barf-if-buffer-read-only goto-char insert message point point-max)
    (only (schemacs editor simple) push-mark)
    ;; `string-prefix-p' is `subr.el''s and now lives in
    ;; `(schemacs editor subr)', which is below this library.
    (only (schemacs editor subr) kbd run-hook-with-args-until-success
          string-prefix-p)
    (only (schemacs editor buffer)
          *case-fold-search*
          current-buffer default-directory erase-buffer)
    ;; The file primitives that were here and have moved to the library
    ;; that mirrors the C file they are really from, `fileio.c':
    ;; `expand-file-name' with the two name helpers and its path
    ;; segments, the two predicates, and `directory-name-p'. This
    ;; library is `files.el' and is built *on* them.
    (only (schemacs editor fileio)
          delete-directory-internal delete-file-internal
          directory-file-name directory-name-p expand-file-name
          file-directory-p file-exists-p file-name-absolute-p
          file-name-as-directory
          file-name-case-insensitive-p
          file-name-directory-part file-name-nondirectory-part
          file-symlink-p file-system-info file-writable-p
          find-file-name-handler
          ;; `read-file-name' runs the typed name through it before
          ;; expanding - see the note there.
          substitute-in-file-name
          ;; `cd' resolves its argument through this
          locate-file-internal)
    ;; `parse-colon-path' runs the whole search path through it before
    ;; splitting it - `files.el:946'
    (only (schemacs editor env) substitute-env-vars)
    ;; `directory-files' and `file-attributes' are `dired.c''s, and
    ;; `delete-directory''s recursive half reads both.
    (only (schemacs editor diredc) directory-files file-attributes)
    ;; the truename walk, the home directory, and the last-dot search
    ;; `file-name-sans-extension' does
    (only (guile) canonicalize-path getenv string-rindex)
    ;; `file-name-sans-versions' matches a regexp, as the C's does
    ;; `regexp-quote' and the match-data accessors are what
    ;; `abbreviate-file-name`'s regexp and its `match-beginning 1' need.
    (only (schemacs editor search)
          match-beginning match-end match-string regexp-quote string-match)
    ;; `get' and `put' are `fns.c`'s - symbol properties, which is where
    ;; `abbreviate-file-name`'s cache records the home directory it was
    ;; built for. They live in `intervals.sld` for now (see the note
    ;; there); the property is on the *symbol*, which is what Emacs's
    ;; `(put 'abbreviated-home-dir 'home ...)' is too.
    (only (schemacs editor intervals) get put)
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
                  buffer-modified-p
                  buffer-name
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
                  generate-new-buffer
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
          *insert-default-directory*
          *minibuffer-completing-file-name*
          completing-read
          *confirm-nonexistent-file-or-buffer*
          confirm-nonexistent-file-or-buffer
          file-name-history
          list-ref-or
          read-char-from-minibuffer
          read-from-minibuffer
          yes-or-no-p)
    ;; For deciding whether a file can be written, which is what makes a
    ;; visited file read-only (GNU Emacs's `file-writable-p', plus the
    ;; permission bits it also consults); and the directory reading and
    ;; name splitting `read-file-name' completes with.
    (only (guile) access? format stat stat:mode W_OK X_OK logand logior
          closedir getcwd opendir readdir stat:type
          string-index string-prefix? string-rindex)
    ;; `file-size-human-readable''s arithmetic
    (only (guile) caddr exact->inexact floor quotient remainder)
    ;; `format' here is Guile's (destination first); the C's `format' is
    ;; editfns.c's, so it is imported under a prefix of its own.
    (prefix (only (schemacs editor editfns) format) ef:)
    ;; The two files.el functions `ls-lisp' needs, handed over below.
    (only (schemacs editor ls-lisp)
          install-ls-lisp-files! ls-lisp--insert-directory))

  (export
   *byte-count-to-string-function*
   file-size-human-readable
   file-size-human-readable-iec
   get-free-disk-space
   *delete-by-moving-to-trash*
   *directory-files-no-dot-files-regexp*
   delete-directory
   delete-file
   *require-final-newline*
   buffer-ends-with-newline?
   default-directory
   default-buffer-file-coding-system
   buffer-file-coding-system
   set!buffer-file-coding-system
   coding-system-for-file
   decode-file-bytes
   write-file-code-points
   files--message
   find-alternate-file
   find-file-other-window
   find-file-read-only
   insert-file
   ;; `fileio.c''s primitive that `insert-file' and `revert-buffer' rest
   ;; on, and what the startup screen reads its text with - a file that is
   ;; *not* visited, so the buffer's file name stays nil.
   insert-file-contents
   not-modified
   pwd
   *save-silently*
   revert-buffer
   revert-buffer--default
   abbreviate-file-name
   *directory-abbrev-alist*
   *abbreviated-home-dir*
   directory-abbrev-apply directory-abbrev-make-regexp
   directory-listing-before-filename-regexp
   directory-entries
   file-name-base
   file-name-sans-extension
   file-name-sans-versions
   file-size-human-readable
   insert-directory
   files--use-insert-directory-program-p
   *insert-directory-program*
   *ls-lisp-use-insert-directory-program*
   wildcard-to-regexp
   file-name-version-regexp
   file-relative-name
   file-truename
   directory-path?
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
   create-file-buffer
   *find-directory-functions*
   *find-file-run-dired*
   files--name-absolute-system-p
   find-file-noselect
   kill-buffer
   note-file-read-only!
   read-directory-name
   read-file-name
   ;; `cd' (files.el:920), with `cd-absolute', `cd-path', the
   ;; `parse-colon-path' that fills it, and the `locate-file' the
   ;; command resolves through
   cd  cd-absolute  cd-path  set!cd-path  parse-colon-path  locate-file
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

    (define default-buffer-file-coding-system 'utf-8-unix)
    ;; ^ GNU Emacs's `buffer-file-coding-system' in a buffer that visits no
    ;; file, measured on Emacs 31.1 rather than assumed: `(default-value
    ;; 'buffer-file-coding-system)' answers `utf-8-unix'. Emacs used to
    ;; answer `undecided' here and chooses UTF-8 outright now, and the
    ;; behaviour is the same either way for us - there is no statistical
    ;; detector, so `undecided' could only resolve to `utf-8'.

    (define (buffer-file-coding-system buffer)
      ;; The coding system BUFFER's file was read with, so that saving
      ;; writes the bytes back the way it found them: GNU Emacs's
      ;; `buffer-file-coding-system', the buffer-local variable its
      ;; `after-find-file' sets from what the file turned out to be.
      ;;
      ;; **It is a coding system, not a line-break convention.** Emacs's
      ;; value is `utf-8-unix' or `iso-latin-1-dos' - the *charset* and
      ;; the *end of line* in one name - and the eol half is only half of
      ;; it. This used to hold the eol-type alone (in the engine's
      ;; `line-break-*' vocabulary), which is why every file was read as
      ;; UTF-8 whatever it was.
      ;;
      ;; It is buffer-local, and not a slot on the frame, because one
      ;; frame shows buffers visiting files with different conventions and
      ;; each must save in its own.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'buffer-file-coding-system
                          default-buffer-file-coding-system))

    (define (set!buffer-file-coding-system buffer coding)
      ;; Record the coding system BUFFER's file was read with: the
      ;; `make-local-variable' half of what Emacs's `after-find-file' does
      ;; with `buffer-file-coding-system'.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! buffer 'buffer-file-coding-system coding))

    (define (coding-system-for-file path bytes)
      ;; The coding system to read PATH's BYTES with: what they declare
      ;; (`set-auto-coding'), or the default - with the end of line
      ;; settled from the bytes themselves when the name does not settle
      ;; it.
      ;;
      ;; **The eol half is the piece that is easy to leave out.** Emacs
      ;; detects the convention only when the coding system has not named
      ;; one (the C's `(VECTORP (eol_type))' test, `coding.c:8933'), so a
      ;; file saying `-*- coding: utf-8 -*-' on a CRLF file is `utf-8-dos'
      ;; while the same file saying `utf-8-unix' keeps UNIX. Measured on
      ;; Emacs 31.1, both.
      ;;--------------------------------------------------------------
      (let* ((base (or (*coding-system-for-read*)
                       ;; `coding-system-for-read' is the outermost word
                       ;; on the subject - `insert-file-contents' checks it
                       ;; before the tag and before detection
                       ;; (`fileio.c:4317') - and it is what C-x RET c and
                       ;; C-x RET r set.
                       (set-auto-coding path bytes)
                       ;; Nothing declared, so the *statistical* detector
                       ;; is asked - GNU Emacs's `detect-coding-region',
                       ;; which `find-operation-coding-system' falls back
                       ;; to for a file. It answers #f for the C's
                       ;; `undecided', which is a file that is all 7-bit
                       ;; text and declares nothing: the default, as it
                       ;; was before there was a detector at all.
                       ;; **The by-name step comes next**, and it is
                       ;; Emacs's: `find-operation-coding-system' matches
                       ;; the file name against `file-coding-system-alist',
                       ;; whose catch-all entry is `("" undecided)'. That
                       ;; entry matches every name, which is what makes it
                       ;; mean "decide by detection" rather than "no
                       ;; coding system" - so an `undecided' answer falls
                       ;; through to the statistics below, exactly as it
                       ;; does in Emacs.
                       (let ((by-name (find-operation-coding-system
                                       'insert-file-contents path)))
                         (and by-name (car by-name)
                              (not (eq? (car by-name) 'undecided))
                              (car by-name)))
                       ;; and finally the statistics. Nothing declared and
                       ;; nothing detected means the file is all 7-bit
                       ;; text, whose answer is `undecided' - what Emacs
                       ;; answers for such a file and what its mode line
                       ;; shows as `-'.
                       (let ((detected (detect-coding-bytes bytes #t)))
                         (or (and detected (car detected)) 'undecided))))
             ;; The eol is detected only when the name has not settled it
             ;; (`adjust-coding-eol-type'), so a coding system the
             ;; *detector* chose arrives here already carrying one.
             (eol (if (bytes-have-null? bytes)
                      ;; "if the text contains NUL, it is binary" -
                      ;; `coding.c:8930' - so the line ends are not
                      ;; converted whatever they look like.
                      'unix
                      (detect-eol bytes))))
        (or (adjust-coding-eol-type base eol)
            base)))

    (define (decode-file-bytes bytes coding)
      ;; BYTES through CODING: the code points out, with the coding
      ;; system's end-of-line conversion applied - GNU Emacs's
      ;; `decode_coding', which `after-insert-file-set-coding' runs over
      ;; what `insert-file-contents' put in the buffer.
      ;;
      ;; The answer is a *list of code points* rather than a string, and
      ;; it has to be: a byte the coding system cannot decode becomes a
      ;; byte character, and `#x3FFFE9' is above Guile's `#x10FFFF', so
      ;; there is no string that holds it.
      ;;
      ;; **The byte order mark is consumed here**, as the C's
      ;; `decode_coding' consumes it for a `-with-signature' coding system:
      ;; it is a signature on the byte stream and not text, so it is not in
      ;; the buffer and cannot come back out of it. Guile's ports do this
      ;; themselves for UTF-8, but *not* for the explicit-endian codecs -
      ;; measured, `"UTF-16LE"' on `FF FE 41 00' answers `(65279 65)'
      ;; where `"UTF-16"' answers `(65)' - so it is done at the byte level
      ;; here for every coding system that carries one.
      ;;--------------------------------------------------------------
      (let* ((mark (coding-system-bom coding))
             (n (if mark (bytevector-length mark) 0))
             (bytes (if (and mark
                             (>= (bytevector-length bytes) n)
                             (equal? (bytevector-copy bytes 0 n) mark))
                        ;; `mark' is the signature the coding system declares,
                        ;; so a match *is* the mark - no search, and no
                        ;; stripping of a U+FEFF that is really text.
                        (bytevector-copy bytes n (bytevector-length bytes))
                        bytes)))
        (call-with-port (open-input-bytevector bytes)
            (lambda (port)
              (coding-setup-port! port coding)
              (let loop ((acc '()))
                (let ((c (coding-read-char port coding)))
                  (if (eof-object? c)
                      (decode-eol (reverse acc) coding)
                      (loop (cons c acc)))))))))

    (define (write-file-code-points path points coding)
      ;; The encode half: the line ends first, then the codec, then the
      ;; bytes to the file. The mirror of `read-file-code-points'.
      ;;
      ;; **The byte order mark is written here, once, at the front**, and
      ;; its bytes come from the coding system - Emacs's `:bom', applied by
      ;; `encode_coding'. The mark is not in the buffer (the read consumed
      ;; it), so without this a file that arrived with one left without it,
      ;; and a file that arrived little-endian left big-endian - the two
      ;; data losses `tools/coding-diff.py' found on its first run, its
      ;; `utf8-bom' case being 9 bytes in and 6 out.
      ;;
      ;; `put-bytevector' writes the mark *raw* into a port whose encoding
      ;; is already set, while the `write-char's after it are encoded -
      ;; the same mixing `coding-write-char' relies on for its byte
      ;; characters, in a run rather than one byte at a time.
      ;;--------------------------------------------------------------
      (let ((bytes
             (call-with-port (open-output-bytevector)
               (lambda (port)
                 (coding-setup-port! port coding)
                 (let ((mark (coding-system-bom coding)))
                   (when mark (put-bytevector port mark)))
                 (for-each (lambda (c) (coding-write-char port c coding))
                           (encode-eol points coding))
                 (get-output-bytevector port)))))
        (call-with-port (open-output-file path #:encoding #f)
          (lambda (port) (put-bytevector port bytes)))))

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
      ;; The C is
      ;;
      ;;   (let ((value (find-file-noselect filename nil nil wildcards)))
      ;;     (if (listp value)
      ;;         (mapcar #'pop-to-buffer-same-window (nreverse value))
      ;;       (pop-to-buffer-same-window value)))
      ;;
      ;; so the answer is what `pop-to-buffer-same-window' answers, which
      ;; is the *buffer* - and it is `pop-to-buffer-same-window', not
      ;; `switch-to-buffer'. Wildcards are not ported, so the `listp' arm
      ;; cannot arise.
      ;;
      ;; There is no error guard, and the C's `find-file' has none: a name
      ;; that cannot be visited signals, and the command loop puts the
      ;; error in the echo area. The guard this used to have turned every
      ;; such failure into `"; find-file: error loading <name>"' - which
      ;; said nothing about the cause. A directory was being read as a file
      ;; underneath it and the message hid exactly the thing worth seeing;
      ;; the directory branch in `find-file-noselect' is what fixed that.
      ;;
      ;; The read-only note is not here either: the C says it from
      ;; `after-find-file', which is `find-file-noselect''s, and it is
      ;; there now.
      (pop-to-buffer-same-window (find-file-noselect path)))

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
             (buffer (current-buffer)))
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

















    ;;----------------------------------------------------------------
    ;; Abbreviating a name, and the truename
    ;;------------------------------------------------------------------

    (define *directory-abbrev-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `directory-abbrev-alist' (files.el:43): "Alist of
    ;; abbreviations for file directories.
    ;;
    ;; A list of elements of the form (FROM . TO), each meaning to replace
    ;; a match for FROM with TO when a directory name matches FROM.  This
    ;; replacement is done when setting up the default directory of a
    ;; newly visited file buffer.
    ;;
    ;; FROM is a regexp that is matched against directory names anchored at
    ;; the first character, so it should start with a \"\\\\\\=`\", or, if
    ;; directory names cannot have embedded newlines, with a \"^\"."
    ;;
    ;; Nil by default, as in Emacs - the variable exists so a user can map
    ;; a symlinked path onto the name they normally use.

    (define *abbreviated-home-dir* (make-parameter #f))
    ;; ^ GNU Emacs's `abbreviated-home-dir' (files.el:2294): the home
    ;; directory as a regexp, cached by `abbreviate-file-name' so it is
    ;; not rebuilt on every call. It is set to `#f' to have it
    ;; recalculated, which is what Emacs's docstring tells a user who has
    ;; changed their home directory to do.
    ;;
    ;; **The other half of the cache is a symbol property**, and that is
    ;; Emacs's arrangement rather than a Scheme one: `(put
    ;; 'abbreviated-home-dir 'home ...)' records *which* home the regexp
    ;; was built for, so that a home directory that has changed since is
    ;; ignored rather than believed (a temporary change of HOME is the
    ;; case that cares). `get'/`put' are `fns.c''s and live in
    ;; `intervals.sld' here, which is where the text-property layer put
    ;; them; the property is on the *symbol*, exactly as in Emacs, so the
    ;; variable above and the property are two places as Emacs has two.

    (define (directory-abbrev-make-regexp directory)
      ;; GNU Emacs's `directory-abbrev-make-regexp' (files.el:71):
      ;; "Create a regexp to match DIRECTORY for `directory-abbrev-alist'."
      ;;
      ;; The group is the point of it: the regexp matches the whole
      ;; directory *and* the slash after it (or the end of the name), so
      ;; that `/usr/foobar' is not taken for the home directory `/usr/foo'
      ;; - the comment in the C's original. `match-beginning 1' is then
      ;; where the slash is, which is what `abbreviate-file-name' keeps.
      ;;--------------------------------------------------------------
      (string-append "\\`" (regexp-quote directory) "\\(/\\|\\'\\)"))

    (define (directory-abbrev-apply filename)
      ;; GNU Emacs's `directory-abbrev-apply' (files.el:87): "Apply the
      ;; abbreviations in `directory-abbrev-alist' to FILENAME. Note that
      ;; when calling this, you should set `case-fold-search' as
      ;; appropriate for the filesystem used for FILENAME."
      ;;
      ;; **Every matching element applies, in order**, and each replaces
      ;; from the end of what it matched - `(match-end 0)', not the length
      ;; of FROM - which is why FROM being a regexp and not a prefix
      ;; matters. This was a literal-prefix `string-prefix?' walk that
      ;; stopped at the first match, which is a different function: it
      ;; could not take a regexp at all, and Emacs's docstring says FROM
      ;; is one and should be anchored.
      ;;--------------------------------------------------------------
      (let loop ((rest (*directory-abbrev-alist*)) (name filename))
        (cond ((null? rest) name)
              ((not (and (pair? (car rest))
                         (string? (caar rest))
                         (string? (cdar rest))))
               (loop (cdr rest) name))
              ((string-match (caar rest) name)
               (loop (cdr rest)
                     (string-append (cdar rest)
                                    (substring name (match-end 0)
                                               (string-length name)))))
              (else (loop (cdr rest) name)))))

    (define (abbreviate-file-name filename)
      ;; GNU Emacs's `abbreviate-file-name' (files.el:2298): "Return a
      ;; version of FILENAME shortened using `directory-abbrev-alist'.
      ;; This also substitutes \"~\" for the user's home directory (unless
      ;; the home directory is a root directory)."
      ;;
      ;; The order is the C's and each step matters:
      ;;
      ;;   1. a file name handler, if one claims the name;
      ;;   2. the `directory-abbrev-alist' pass, which may rewrite the
      ;;      name before the home directory is looked for;
      ;;   3. the `~' substitution, against the *cached* regexp - built by
      ;;      abbreviating `(expand-file-name "~")' through this same
      ;;      function (with `*abbreviated-home-dir*' bound to an
      ;;      impossible regexp, so the recursion does not try to
      ;;      substitute `~' into the home directory itself), which is how
      ;;      an abbreviation covering the home directory is respected;
      ;;   4. and the guard that the home directory has not changed since
      ;;      that cache was made.
      ;;
      ;; `case-fold-search' is bound from
      ;; `file-name-case-insensitive-p' for the length of it: `string-match'
      ;; reads that variable, as the C's does, so on a filesystem that
      ;; does not distinguish case - `/HOME/chris' for `/home/chris' -
      ;; the substitution happens case-insensitively. On this platform
      ;; that function answers `#f' (`fileio.sld' says why), which is
      ;; Emacs's own answer for the same filesystem.
      ;;
      ;; `(aref filename 0)' is `(string-ref filename 0)' here, and the
      ;; MS-DOS drive-letter guard is not carried: `system-type' is not a
      ;; thing this tree has, and the branch it guards is about `C:/'.
      ;;--------------------------------------------------------------
      (let ((handler (find-file-name-handler filename 'abbreviate-file-name)))
        (if handler
            (handler 'abbreviate-file-name filename)
            (parameterize ((*case-fold-search*
                            (file-name-case-insensitive-p filename)))
              (let* ((name (directory-abbrev-apply filename))
                     (home (expand-file-name "~")))
                (unless (*abbreviated-home-dir*)
                  (put 'abbreviated-home-dir 'home home)
                  (*abbreviated-home-dir*
                   (directory-abbrev-make-regexp
                    (parameterize ((*abbreviated-home-dir* "\\`\\'."))
                      (abbreviate-file-name home)))))
                ;; **`mb1` is saved, as the C saves it.** Emacs's
                ;; `(setq mb1 (match-beginning 1))' is inside the `and'
                ;; and the body uses the *variable* - so a condition
                ;; further along that runs a search of its own (the
                ;; `expand-file-name "~"' below asks the filesystem, but
                ;; a port of this that asked something that searched
                ;; would) cannot move the answer out from under the
                ;; `substring'.
                (let ((mb1 #f))
                  (if (and (string-match (*abbreviated-home-dir*) name)
                           (set! mb1 (match-beginning 1))
                           ;; "If the homedir is just /, don't change it."
                           (not (and (= (match-end 0) 1)
                                     (char=? #\/ (string-ref name 0))))
                           (equal? (get 'abbreviated-home-dir 'home)
                                   (expand-file-name "~")))
                      (string-append "~" (substring name mb1
                                                    (string-length name)))
                      name)))))))

    (define (file-truename filename . rest)
      ;; GNU Emacs's `file-truename' (files.el): "Return the truename of
      ;; FILENAME. If FILENAME is not absolute, first expands it against
      ;; `default-directory'. The truename of a file name is found by
      ;; chasing symbolic links both at the level of the file and at the
      ;; level of the directories containing it, until no links are left
      ;; at any level."
      ;;
      ;; Guile's `canonicalize-path' is that walk - the C's `Ffile_truename'
      ;; is a `realpath' with the parts Emacs needs around it - and the
      ;; C's COUNTER and PREV-DIRS are for its own recursion, which
      ;; `realpath' does internally.
      ;;--------------------------------------------------------------
      (canonicalize-path (expand-file-name filename)))

    (define (match-at-end regexp string)
      ;; The start of the leftmost match of REGEXP in STRING that *ends*
      ;; at the end of STRING - which is what Emacs means by writing
      ;; REGEXP with `\\'' after it. This tree's regexp engine has no
      ;; end-of-string anchor, so the anchor is applied here instead.
      ;;--------------------------------------------------------------
      (let loop ((start 0))
        (if (> start (string-length string))
            #f
            (let ((at (guard (e (#t #f)) (string-match regexp string start))))
              (cond ((not at) #f)
                    ((= (+ at (string-length (match-string 0 string)))
                        (string-length string))
                     at)
                    (else (loop (+ at 1))))))))

    (define file-name-version-regexp
      ;; GNU Emacs's `file-name-version-regexp' (files.el:5507): "Regular
      ;; expression matching the backup/version part of a file name."
      ;; Emacs spells its groups shy (`\\(?:'); those have no ERE
      ;; spelling, and a plain group means the same thing here.
      ;;--------------------------------------------------------------
      "\\(~\\|\\.~[-[:alnum:]:#@^._]+\\(~[[:digit:]]+\\)?~\\)")

    (define (file-name-sans-versions name . rest)
      ;; GNU Emacs's `file-name-sans-versions' (files.el:5514): "Return
      ;; file NAME sans backup versions or strings. ... If the optional
      ;; argument KEEP-BACKUP-VERSION is non-nil, we do not remove backup
      ;; version numbers, only true file version numbers."
      ;;--------------------------------------------------------------
      (let ((keep (and (pair? rest) (car rest))))
        (if keep
            name
            (let ((at (match-at-end file-name-version-regexp name)))
              (if at (substring name 0 at) name)))))

    (define (file-name-sans-extension filename)
      ;; GNU Emacs's `file-name-sans-extension' (files.el:5572): "Return
      ;; FILENAME sans final \"extension\" and any backup version strings.
      ;; The extension ... is the part that begins with the last `.',
      ;; except that a leading `.' of the file name, if there is one,
      ;; doesn't count."
      ;;--------------------------------------------------------------
      (let* ((file (file-name-sans-versions
                    (file-name-nondirectory-part filename)))
             (dot (string-rindex file #\.)))
        (if (and dot (> dot 0))
            (string-append (file-name-directory-part filename)
                           (substring file 0 dot))
            filename)))

    (define (file-name-base . rest)
      ;; GNU Emacs's `file-name-base': "Return the base name of the
      ;; FILENAME: no directory, no extension."
      ;;
      ;; The C defaults FILENAME to the buffer's own file - the
      ;; DEPRECATED advertised-calling-convention Emacs keeps.
      ;;--------------------------------------------------------------
      (let ((filename (if (pair? rest)
                          (car rest)
                          (buffer-file-name (current-buffer)))))
        (file-name-sans-extension
         (file-name-nondirectory-part (or filename "")))))

(define (wildcard-to-regexp wildcard)
      ;; GNU Emacs's `wildcard-to-regexp' (files.el): "Given a shell file
      ;; name pattern WILDCARD, return an equivalent regexp. The
      ;; generated regexp will match a file name only if the file name
      ;; matches that wildcard according to shell rules. Only wildcards
      ;; known by `sh' are supported."
      ;;
      ;; The C's walk, kept in its shape: the leading run of non-special
      ;; characters is copied whole, then each special character is
      ;; translated - `*' to `[^\000]*', `?' to `[^\000]', a `[...]'
      ;; class to a regexp class with `!' spelled as `^' - and the
      ;; result is anchored at both ends.
      ;;
      ;; `\000' cannot occur in a file name, so `[^\000]' is "any
      ;; character". It is left spelled with the NUL in it, as the C
      ;; writes it, so that the text says what Emacs's says.
      ;;--------------------------------------------------------------
      (let* ((i (string-match "[[.*+\\^$?]" wildcard))
             (result (substring wildcard 0 (if i i (string-length wildcard))))
             (len (string-length wildcard)))
        (if (not i)
            (string-append "\\`" result "\\'")
            (begin
              ;; the C's `(while (< i len) ...)'
              (let loop ()
                (when (< i len)
                  (let ((ch (string-ref wildcard i)))
                    (set! result
                          (string-append
                           result
                           (cond
                            ((and (char=? ch #\[)
                                  (< (+ i 1) len)
                                  (char=? #\] (string-ref wildcard (+ i 1))))
                             "\\[")
                            ((char=? ch #\[)   ; [...] maps to a regexp class
                             (set! i (+ i 1))
                             (let* ((opener
                                     (cond
                                      ((char=? (string-ref wildcard i) #\!)
                                       ;; [!...] -> [^...]
                                       (set! i (+ i 1))
                                       (if (and (< i len)
                                                (char=? #\] (string-ref wildcard i)))
                                           (begin (set! i (+ i 1)) "[^]")
                                           "[^"))
                                      ((char=? (string-ref wildcard i) #\^)
                                       ;; "Found `[^'. Insert a `\0'
                                       ;; character (which cannot happen
                                       ;; in a filename) into the
                                       ;; character class, so that `^' is
                                       ;; not the first character after
                                       ;; `[', and thus non-special in a
                                       ;; regexp."
                                       (set! i (+ i 1))
                                       (string-append "[" (string #\nul) "^"))
                                      ((char=? (string-ref wildcard i) #\])
                                       ;; "I don't think `]' can appear
                                       ;; in a character class in a
                                       ;; wildcard, but let's be general
                                       ;; here."
                                       (set! i (+ i 1))
                                       "[]")
                                      (else "[")))
                                    ;; "copy everything up to next `]'"
                                    (j (let search ((k i))
                                         (cond ((>= k len) #f)
                                               ((char=? #\] (string-ref wildcard k)) k)
                                               (else (search (+ k 1))))))
                                    (body (substring wildcard i (if j j len))))
                               (set! i (if j (- j 1) (- len 1)))
                               (string-append opener body)))
                            ((char=? ch #\.) "\\.")
                            ((char=? ch #\*) (string-append "[^" (string #\nul) "]*"))
                            ((char=? ch #\+) "\\+")
                            ((char=? ch #\^) "\\^")
                            ((char=? ch #\$) "\\$")
                            ((char=? ch #\\) "\\\\")  ; probably cannot happen...
                            ((char=? ch #\?) (string-append "[^" (string #\nul) "]"))
                            (else (string ch))))))
                  (set! i (+ i 1))
                  (loop)))
              (string-append "\\`" result "\\'")))))

    ;; `file-size-human-readable' is defined once, further down this file
    ;; beside `file-size-human-readable-iec' and
    ;; `byte-count-to-string-function' - which is where its two callers
    ;; are. There was a second copy here, and it was *this* one that the
    ;; later definition shadowed: two definitions of one files.el
    ;; function is a departure the compiler catches as "shadows previous
    ;; definition", and only the live one was ever exercised.

    (define (file-relative-name filename . rest)
      ;; GNU Emacs's `file-relative-name' (files.el): "Convert FILENAME to
      ;; be relative to DIRECTORY (default: `default-directory'). ...
      ;; This function returns a relative file name that is equivalent to
      ;; FILENAME when used with that default directory as the default."
      ;;
      ;; The walk is the C's: climb out of DIRECTORY one component at a
      ;; time with `..' until what is left of it is a prefix of
      ;; FILENAME, then add the rest of FILENAME on.
      ;;--------------------------------------------------------------
      (let* ((directory (file-name-as-directory
                         (expand-file-name (if (pair? rest)
                                               (car rest)
                                               (default-directory)))))
             (filename (expand-file-name filename)))
        (let loop ((directory directory) (ancestor "."))
          (cond
           ((or (string-prefix? directory filename)
                (string-prefix? (directory-file-name directory) filename))
            (if (string-prefix? directory filename)
                (let ((rest (substring filename (string-length directory))))
                  (if (and (string=? ancestor ".") (not (string=? rest "")))
                      rest
                      (string-append (file-name-as-directory ancestor) rest)))
                ancestor))
           (else
            (loop (file-name-directory-part
                   (substring directory 0 (- (string-length directory) 1)))
                  ;; the C: `(if (equal ancestor ".") ".." ...)' - from
                  ;; the first step the ancestor is `..', and each step
                  ;; after adds a level on
                  (if (string=? ancestor ".") ".." (string-append "../" ancestor))))))))

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

    (define (read-file-name prompt . rest)
      ;; Read a file name in the minibuffer, completing as TAB is typed:
      ;; GNU Emacs's `read-file-name' (minibuffer.el:4001), with the
      ;; arguments its `read-file-name-default' (minibuffer.el:4071)
      ;; takes:
      ;;
      ;;   (read-file-name PROMPT &optional DIR DEFAULT-FILENAME
      ;;                   MUSTMATCH INITIAL PREDICATE)
      ;;
      ;; DIR is the directory relative names complete in, nil meaning
      ;; `default-directory'. DEFAULT-FILENAME is what RET answers when
      ;; the minibuffer is left holding exactly what was inserted; when
      ;; none is given it is the buffer's own file, or - when INITIAL is
      ;; given, which is the case that needs it - DIR with INITIAL after
      ;; it.
      ;;
      ;; INITIAL is what is put in the minibuffer after the directory,
      ;; and where point goes is the point of it: the directory is
      ;; inserted, INITIAL after it, and point is left at the length of
      ;; the directory. So `C-x C-v' fills in the file being visited and
      ;; puts point at the start of its *name*, which is Emacs's
      ;; behaviour and the whole reason INITIAL exists here.
      ;;
      ;; PREDICATE is not taken - the completion table here has the one
      ;; predicate, `file-name-completion-table'.
      ;;--------------------------------------------------------------
      ;; `completing-read', not `read-from-minibuffer': that is the point
      ;; of this function in Emacs - it is `completing-read' with a file
      ;; name table and a file name history, and everything else about it
      ;; (what RET does, what the candidates are) is that function's.
      ;;
      ;; MUSTMATCH is passed through to `completing-read' as Emacs passes
      ;; it. A name that does not exist is allowed when it is nil, which
      ;; is how a file is created; `confirm', which is what
      ;; `confirm-nonexistent-file-or-buffer' answers, asks first.
      ;;
      ;; `minibuffer-completing-file-name' is what tells
      ;; `completing-read' to layer the file-name keymap over the
      ;; completion map, and that map's whole job is to take SPC away
      ;; from `minibuffer-complete-word' - a file name may have a space
      ;; in it, and a space must insert one.
      ;;
      ;; The answer is put through `expand-file-name' against DIR. Emacs
      ;; says of its own return that "the return value is not
      ;; expanded---you must call `expand-file-name' yourself", and every
      ;; caller here wants the expanded name, so it is done here; with
      ;; `insert-default-directory' the minibuffer holds an absolute name
      ;; already and this changes nothing.
      ;;--------------------------------------------------------------
      (let* ((dir (let ((d (or (list-ref-or rest 0 #f) (default-directory))))
                    ;; Emacs's own two lines here: `(unless dir (setq dir (or
                    ;; default-directory "~/")))' - which the `or' above is -
                    ;; and `(unless (file-name-absolute-p dir) (setq dir
                    ;; (expand-file-name dir)))', which this is.
                    (if (file-name-absolute-p d) d (expand-file-name d))))
             (named-default (list-ref-or rest 1 #f))
             (mustmatch (list-ref-or rest 2 #f))
             (initial (list-ref-or rest 3 #f))
             (default-filename
              (or named-default
                  (cond ((not initial) (buffer-file-name (current-buffer)))
                        ((string=? "" initial) dir)
                        (else (expand-file-name initial dir)))))
             ;; **"If dir starts with user's homedir, change that to ~"**
             ;; (minibuffer.el:4085), and the same for the default. This is
             ;; where the `C-x C-f' prompt gets its `~': the directory is
             ;; put *in* the minibuffer here, so abbreviating it is what
             ;; the user sees, and `expand-file-name' below turns it back
             ;; into a path (it expands a leading `~').
             (dir (abbreviate-file-name dir))
             (default-filename (and default-filename
                                    (abbreviate-file-name default-filename)))
             ;; What is inserted, and where point is left in it: the
             ;; directory, then INITIAL, with point at the directory's
             ;; own length - Emacs's `insdef', whose cdr is that length
             ;; (minibuffer.el:4096).
             (insdef
              (cond ((and (*insert-default-directory*) (string? dir))
                     (if initial
                         (cons (string-append dir initial) (string-length dir))
                         dir))
                    (initial (cons initial 0))
                    (else #f))))
        (expand-file-name
         ;; The answer goes through `substitute-in-file-name' *before* it
         ;; is expanded, which is what `read-file-name-default' does at
         ;; its exit (minibuffer.el:4192). That call is where a typed name
         ;; is re-rooted: `substitute-in-file-name' discards everything up
         ;; to a `//' (or a `/~', or a `$VAR' that expands to an absolute
         ;; name), so `C-x C-f /tmp//x' visits `/x' - and `/tmp//x' is
         ;; `/tmp/x' only to `expand-file-name', which is what this used
         ;; to give it to. Emacs runs the two in this order for the whole
         ;; file-name-reading path; leaving the first out made every
         ;; `//' in a typed name mean "a doubled separator" instead of
         ;; "the root".
         (substitute-in-file-name
          (parameterize ((*minibuffer-completing-file-name* #t))
            (completing-read prompt file-name-completion-table #f mustmatch
                             insdef
                             file-name-history
                             default-filename)))
         dir)))

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

    (define directory-listing-before-filename-regexp
      ;; GNU Emacs's `directory-listing-before-filename-regexp'
      ;; (files.el:8250): "Regular expression to match up to the file name
      ;; in a directory listing. The default value is designed to
      ;; recognize dates and times regardless of the language."
      ;;
      ;; The C builds it out of named pieces in one `let*', and the names
      ;; are kept. `HH:MM' is a legal Scheme identifier, `:' being a
      ;; special initial, so it stays as Emacs spells it.
      ;;
      ;; The `\0' and `\177' of `[^\0-\177]' are NUL and DEL written in
      ;; Guile's `\x..;' spelling. That range cannot survive this tree's
      ;; regexp translation, and what that costs is measured in
      ;; `(schemacs editor search)'s `%without-nul' - nothing, on the line
      ;; shapes a listing has.
      ;;--------------------------------------------------------------
      (let* ((l "\\([A-Za-z]\\|[^\x0;-\x7f;]\\)")
             (l-or-quote "\\([A-Za-z']\\|[^\x0;-\x7f;]\\)")
             (month (string-append l-or-quote l-or-quote "+\\.?"))
             (s " ")
             (yyyy "[0-9][0-9][0-9][0-9]")
             (dd "[ 0-3][0-9]")
             (HH:MM "[ 0-2][0-9][:.][0-5][0-9]")
             (seconds "[0-6][0-9]\\([.,][0-9]+\\)?")
             (zone "[-+][0-2][0-9][0-5][0-9]")
             (iso-mm-dd "[01][0-9]-[0-3][0-9]")
             (iso-time (string-append HH:MM "\\(:" seconds
                                      "\\( ?" zone "\\)?\\)?"))
             (iso (string-append "\\(\\(" yyyy "-\\)?" iso-mm-dd "[ T]" iso-time
                                 "\\|" yyyy "-" iso-mm-dd "\\)"))
             (western (string-append "\\(" month s "+" dd "\\|" dd "\\.?"
                                     s month "\\)"
                                     s "+"
                                     "\\(" HH:MM "\\|" yyyy "\\)"))
             (western-comma (string-append month s "+" dd "," s "+" yyyy))
             (DD-MMM-YYYY (string-append dd "-" month "-" yyyy s HH:MM))
             ;; "Japanese MS-Windows ls-lisp has one-digit months, and
             ;; omits the Kanji characters after month and day-of-month.
             ;; On Mac OS X 10.3, the date format in East Asian locales is
             ;; day-of-month digits followed by month digits."
             (mm "[ 0-1]?[0-9]")
             (east-asian
              (string-append "\\(" mm l "?" s dd l "?" s "+"
                             "\\|" dd s mm s "+" "\\)"
                             "\\(" HH:MM "\\|" yyyy l "?" "\\)")))
        (string-append "\\([0-9][BkKMGTPEZYRQ]? " iso
                       "\\|.*[0-9][BkKMGTPEZYRQ]? "
                       "\\(" western "\\|" western-comma
                       "\\|" DD-MMM-YYYY "\\|" east-asian "\\)"
                       "\\) +")))

    (define (read-directory-name prompt . rest)
      ;; GNU Emacs's `read-directory-name' (files.el:884): "Read directory
      ;; name, prompting with PROMPT and completing in directory DIR. The
      ;; return value is not expanded - you must call `expand-file-name'
      ;; yourself."
      ;;
      ;; "It is `read-file-name' with `file-directory-p' as the completion
      ;; predicate and with DIR as the default"; PREDICATE, the sixth
      ;; argument, is not taken here for the reason `read-file-name' above
      ;; gives - the completion table carries the one predicate.
      ;;--------------------------------------------------------------
      (let* ((dir (or (list-ref-or rest 0 #f) (default-directory)))
             (default-dirname (list-ref-or rest 1 #f))
             (mustmatch (list-ref-or rest 2 #f))
             (initial (list-ref-or rest 3 #f)))
        (read-file-name prompt dir
                        (or default-dirname
                            (if initial
                                (expand-file-name initial dir)
                                dir))
                        mustmatch initial)))

    (define *require-final-newline*
      (make-parameter #t))

    (define (buffer-ends-with-newline? ed)
      ;; Whether the last character of the buffer is a line break. False
      ;; for an empty buffer, which Emacs treats as needing nothing.
      ;;--------------------------------------------------------------
      (let ((max (text-editor-point-max ed)))
        (and (< (text-editor-point-min ed) max)
             (char=? (text-editor-get-char-index ed (- max 1)) #\newline))))

    (define (add-line-break-at-end! ed)
      ;; Append a line break to the buffer, leaving the cursor where it
      ;; was, as Emacs wraps this insertion in a `save-excursion'. The
      ;; insert is the engine's own, so the undo list and any markers
      ;; follow it, exactly as they would for a line break typed at the
      ;; end.
      ;;--------------------------------------------------------------
      (let ((at (text-editor-get-cursor ed)))
        ;; `point-max', not the character count: positions are one-based
        ;; and `point-max' is one past the last character, which is where
        ;; a break appended to the buffer goes. The count is one short of
        ;; it, which put the break before the last character.
        (text-editor-set-cursor ed (text-editor-point-max ed))
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

    (define (ensure-final-newline-on-visit points write-protected?)
      ;; Emacs's visit-time rule (`after-find-file'): the text being
      ;; visited, with a line break added when the variable says to add
      ;; one at visit time. A file that cannot be written is visited
      ;; read-only, and Emacs does not add anything to a read-only
      ;; buffer.
      ;;
      ;; POINTS is a list of code points and not a string, because what
      ;; is being visited may contain a byte character, which a string
      ;; cannot hold. Emacs's own version works on the buffer - it is
      ;; `(goto-char (point-max)) (insert "\n")' after the file is in -
      ;; and answers a list for the same reason: the text has to exist
      ;; somewhere before it is inserted here, and a list is the only
      ;; place it can be.
      ;;--------------------------------------------------------------
      (if (and (memq (*require-final-newline*) '(visit visit-save))
               (pair? points)
               (not (= 10 (car (reverse points))))
               (not write-protected?))
          (append points (list 10))
          points))

    (define (note-file-read-only! frame)
      ;; Say so when the buffer's *file* cannot be written, in GNU Emacs's
      ;; words: `after-find-file''s "Note: file is write protected"
      ;; (`files.el:2940'), which Emacs says of a file that is not
      ;; writable - the buffer's read-only flag is a *consequence* of that
      ;; in Emacs (`:2920'), never the test.
      ;;
      ;; **The test here was the flag**, and it showed the moment a
      ;; read-only buffer that visits nothing was current: the startup
      ;; screen is read-only and fileless, and the front end's call to
      ;; this said "file is write protected" about it. `file-write-
      ;; protected?' is Emacs's own test - and the one `find-file-noselect'
      ;; already used to set the flag in the first place.
      ;;--------------------------------------------------------------
      (let ((file (buffer-file-name (frame-editor frame))))
        (when (and file (file-write-protected? file))
          (set!frame-message frame "Note: file is write protected"))))

    (define *find-file-run-dired* (make-parameter #t))
    ;; ^ GNU Emacs's `find-file-run-dired' (files.el:579): "Non-nil means
    ;; allow `find-file' to visit directories. To visit the directory,
    ;; `find-file' runs `find-directory-functions'." T, as in Emacs.

    (define *find-directory-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `find-directory-functions' (files.el:585): "List of
    ;; functions to try in sequence to visit a directory. Each function is
    ;; called with the directory name as the sole argument and should
    ;; return either a buffer or nil."
    ;;
    ;; The C's value is `(cvs-dired-noselect dired-noselect)' - the two
    ;; functions *named*, because an Elisp hook is a list of symbols. A
    ;; hook here is a list of procedures, so it cannot name a function in
    ;; a library that is built on this one: the list starts empty and
    ;; `dired.sld' adds `dired-noselect' to it at load. `cvs-dired-noselect'
    ;; is CVS's, which is not ported.

    (define (files--name-absolute-system-p file)
      ;; GNU Emacs's `files--name-absolute-system-p' (files.el:1522):
      ;; "Return non-nil if FILE is an absolute name to the operating
      ;; system. This is like `file-name-absolute-p', except that it
      ;; returns nil for names beginning with `~'."
      ;;--------------------------------------------------------------
      (and (file-name-absolute-p file)
           (not (char=? (string-ref file 0) #\~))))

    (define (create-file-buffer filename)
      ;; GNU Emacs's `create-file-buffer' (files.el:2266): "Create a
      ;; suitably named buffer for visiting FILENAME, and return it.
      ;; FILENAME (sans directory) is used unchanged if that name is free;
      ;; otherwise the buffer is renamed according to
      ;; `uniquify-buffer-name-style' to get an unused name.
      ;;
      ;; Emacs treats buffers whose names begin with a space as internal
      ;; buffers. To avoid confusion when visiting a file whose name
      ;; begins with a space, this function prepends a \"|\" to the final
      ;; result if necessary."
      ;;
      ;; The renaming is the *uniquify* advice, and uniquify is not
      ;; ported: `uniquify-trailing-separator-flag' is nil by default
      ;; (uniquify.el:194) so its first branch is the one taken in any
      ;; case, and `uniquify-buffer-name-style' - which only the *advice*
      ;; reads - then has nothing to do. `generate-new-buffer' is what
      ;; makes the name unique, and it is already Emacs's.
      ;;--------------------------------------------------------------
      (let* ((lastname (file-name-nondirectory-part
                        (directory-file-name filename)))
             ;; "FILENAME is a root directory"
             (lastname (if (string=? lastname "") filename lastname))
             (basename (if (string-prefix-p " " lastname)
                           (string-append "|" lastname)
                           lastname)))
        (generate-new-buffer basename)))

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
      (if (file-directory-p path)
          ;; "To visit the directory, `find-file' runs
          ;; `find-directory-functions'." The C passes the truename when
          ;; `find-file-visit-truename' - nil by default, and truenames
          ;; are not ported - and otherwise the name itself.
          ;;
          ;; Without this a directory was read as a file: the editor said
          ;; `find-file: error loading <dir>', and there was no way to
          ;; reach Dired by visiting a directory at all.
          (or (and (*find-file-run-dired*)
                   (run-hook-with-args-until-success
                    (*find-directory-functions*)
                    path))
              (error "%s is a directory" path))
      (or
       ;; a file already visited is one buffer, not two - and it is
       ;; returned as it stands: Emacs's `find-file-noselect' does not
       ;; read the file again either, and reading it into the buffer it
       ;; is already in would *append* a second copy to it.
       (find-buffer-visiting path)
       (let* ((new? (not (file-exists-p path)))
              ;; The file's *bytes*, read before anything is decoded: what
              ;; coding system to use is a question about them, and the
              ;; answer cannot come from text that has already been read
              ;; as something.
              (bytes (if new?
                         #vu8()
                         (call-with-port (open-input-file path #:encoding #f)
                           get-bytevector-all)))
              (coding (coding-system-for-file path bytes))
              ;; named after the file without its directory, as Emacs's
              ;; `create-file-buffer' names it, and put in the buffer list
              (ed (get-buffer-create (file-name-nondirectory-part path))))
        ;; Visiting a file leaves nothing to undo, as in GNU Emacs: what
        ;; is in the buffer is not an edit the user made. Re-enabling
        ;; undo discards what the load recorded.
        (text-editor-undo-disable! ed)
        (unless new?
          (text-editor-insert ed (ensure-final-newline-on-visit
                                  (decode-file-bytes bytes coding)
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
        ;; and the echo area says so, which the C does from
        ;; `after-find-file' - in `find-file-noselect', not in the command.
        ;; A frame is needed to say it in, and a script has none.
        (when (*current-frame*) (note-file-read-only! (*current-frame*)))
        ;; The buffer remembers the file it came from - GNU Emacs's
        ;; `buffer-file-name' - and the name it was given when it was made
        ;; (a visiting buffer keeps the name it already had, which is what
        ;; Emacs does when it finds the file already in a buffer).
        (set!text-editor-file-name ed path)
        ;; and the coding system it was read with, which is the buffer's
        ;; rather than the frame's - so that this buffer saves the way it
        ;; was loaded however many other files have been visited since
        (set!buffer-file-coding-system ed coding)
        ;; and it is the coding system that was *used*, which Emacs
        ;; records separately because reading a file can resolve an
        ;; undecided one into a real choice that the buffer's variable was
        ;; never told about - GNU Emacs's `last-coding-system-used'.
        (unless new? (*last-coding-system-used* coding))
        ;; and the directory its file is in, which its relative file names
        ;; are relative to: GNU Emacs's `default-directory', buffer-local,
        ;; which `find-file-noselect' sets to the file's directory
        (set!buffer-default-directory ed (file-name-directory-part path))
        ;; and point starts at the beginning of what was read, which is
        ;; where GNU Emacs's `find-file-noselect' puts it - `point-min'
        (text-editor-set-cursor ed 1 0)
        ed)))))

    (define *save-silently* (make-parameter #f))
    ;; ^ GNU Emacs's `save-silently' (files.el:830), nil by default: "If
    ;; non-nil, messages are suppressed when saving a file." It is read
    ;; by `files--message' below and by `basic-save-buffer'.

    (define (files--message format-string . args)
      ;; GNU Emacs's `files--message' (files.el:2538): "Like `message',
      ;; except sometimes don't show the message text. If the variable
      ;; `save-silently' is non-nil, the message will not be visible in
      ;; the echo area." The C is two statements - `(apply #'message
      ;; FORMAT ARGS)' and `(when save-silently (message nil))' - and
      ;; this is those two.
      ;;
      ;; FORMAT-STRING is `message''s, so it is an *Emacs* format
      ;; string: this used to hand the text to Guile's `format' instead,
      ;; which reads `~a' and prints a `%s' as itself - a departure that
      ;; made every `files--message' call site speak Guile rather than
      ;; Emacs. `pwd' below is the message that showed it.
      ;;--------------------------------------------------------------
      (apply message format-string args)
      (when (*save-silently*) (message #f)))

    ;;----------------------------------------------------------------
    ;; Reading a file into the buffer: `insert-file-contents'
    ;;------------------------------------------------------------------

    (define (insert-file-contents filename . args)
      ;; GNU Emacs's `insert-file-contents' (fileio.c:4057), the
      ;; primitive `insert-file' and `revert-buffer' rest on: "Insert
      ;; contents of file FILENAME after point." The optional VISIT
      ;; marks the buffer as visiting the file - and unmodified, which
      ;; is what a visit means - and REPLACE, when true, replaces the
      ;; buffer's whole contents instead of adding to them - the C's
      ;; replace-the-accessible-portion, which keeps markers either
      ;; side of what it changes. What is inserted is the file's text
      ;; decoded by the coding system the file declares, as
      ;; `find-file-noselect''s reading is; the buffer's
      ;; `buffer-file-coding-system' is not touched - the C sets it
      ;; through `after-insert-file-set-coding', which the visit-time
      ;; callers do. The answer is `(FILENAME SIZE)' - the C's, which
      ;; `insert-file-1' takes the second of.
      ;;--------------------------------------------------------------
      (let* ((visit (and (pair? args) (car args)))
             (replace (and (pair? args) (pair? (cdr args)) (cadr args)))
             (bytes (call-with-port (open-input-file filename #:encoding #f)
                      get-bytevector-all))
             (coding (coding-system-for-file filename bytes))
             (decoded (decode-file-bytes bytes coding))
             (ed (current-buffer)))
        (when replace
          (erase-buffer)
          ;; the whole buffer is the file's: the coding system is the
          ;; file's again, as `revert-buffer-insert-file-contents'
          ;; makes of it
          (set!buffer-file-coding-system ed coding))
        (text-editor-insert ed decoded)
        ;; the visit: the buffer is what the file is now, so there is
        ;; nothing in it the file does not have
        (when visit (text-editor-set-modified! ed #f))
        (list filename (length decoded))))

    (define (insert-file-1 filename insert-func)
      ;; GNU Emacs's `insert-file-1' (files.el:2836): the common shape
      ;; of `insert-file' and `insert-file-literally' - "a directory is
      ;; not a file to open" - and the note about a file already
      ;; visited and modified elsewhere.
      ;;--------------------------------------------------------------
      (when (directory-path? filename)
        (error "Opening input file: Is a directory" filename))
      (let* ((result (insert-func filename))
             (size (cadr result)))
        ;; Emacs's insert-file-1: `(push-mark (+ (point) (car (cdr tem))))'
        ;; - one argument, which leaves "Mark set" to show.
        (push-mark (+ (point) size))
        (let ((buffer
               (find-buffer-visiting
                (expand-file-name filename))))
          (when (and buffer (buffer-modified-p buffer))
            ;; the C's `(message "File %s already visited and modified in
            ;; buffer %s" ...)' - `message', not `files--message'
            (message
             "File %s already visited and modified in buffer %s"
             filename (buffer-name buffer))))))

    (define-command (insert-file filename)
      ;; GNU Emacs's `insert-file' (files.el:6627): "Insert contents of
      ;; file FILENAME into buffer after point. Set mark after the
      ;; inserted text." The `*' of the interactive spec is the
      ;; read-only check, made first.
      "Insert contents of file FILENAME into buffer after point.
Set mark after the inserted text."
      (interactive (list (read-file-name "Insert file: ")))
      (barf-if-buffer-read-only)
      (insert-file-1 filename
                     (lambda (name) (insert-file-contents name))))

    ;; `*confirm-nonexistent-file-or-buffer*' and
    ;; `confirm-nonexistent-file-or-buffer' are `files.el`'s (`:1898' and
    ;; `:1914') and live in `(schemacs editor minibuffer)' here, because
    ;; `read-buffer-to-switch' passes them and that function can only be
    ;; there; they are imported above, as `completing-read' is.

    ;;----------------------------------------------------------------
    ;; The other ways to visit a file
    ;;------------------------------------------------------------------

    (define (find-file--read-only mode filename wildcards)
      ;; GNU Emacs's `find-file--read-only' (files.el:2084): the shape
      ;; `find-file-read-only' and its window variants share - visit,
      ;; then turn read-only on. WILDCARDS are not ported; the buffer
      ;; is visited by the MODE given.
      ;;--------------------------------------------------------------
      (unless (file-exists-p filename)
        (error "~a does not exist" filename))
      (mode filename)
      (with-current-buffer (current-buffer)
        (text-editor-set-read-only! (current-buffer) #t)))

    (define-command (find-file-read-only filename)
      ;; GNU Emacs's `find-file-read-only' (files.el:2095): "Edit file
      ;; FILENAME but don't allow changes. Like `find-file', but marks
      ;; buffer as read-only. Use `read-only-mode' to permit editing."
      "Edit file FILENAME but don't allow changes.
Like \\[find-file], but marks buffer as read-only.
Use \\[read-only-mode] to permit editing."
      (interactive (list (read-file-name "Find file read-only: ")))
      (find-file--read-only
       (lambda (name)
         (find-file name)
         (text-editor-set-read-only! (current-buffer) #t))
       filename #f))

    (define-command (find-file-other-window filename)
      ;; GNU Emacs's `find-file-other-window' (files.el:2003): "Edit
      ;; file FILENAME, in another window" - the same prompt, the
      ;; visit, and the buffer shown in the other window, which is
      ;; `switch-to-buffer-other-window''s work.
      "Edit file FILENAME, in another window."
      (interactive (list (read-file-name "Find file in other window: ")))
      (switch-to-buffer-other-window (find-file-noselect filename))
      (note-file-read-only! (*current-frame*))
      filename)

    (define-command (find-alternate-file filename)
      ;; GNU Emacs's `find-alternate-file' (files.el:2171): "Find file
      ;; FILENAME, select its buffer, kill previous buffer." The C's
      ;; way survives a failed visit: the old buffer is renamed `**lose**'
      ;; first, its file variables cleared, the new one visited, and on
      ;; failure the names are put back - an unwind-protect, which is
      ;; the dynamic-wind here. No indirect buffers, no wildcards, no
      ;; dired-directory (none of that is ported).
      "Find file FILENAME, select its buffer, kill previous buffer.
If the current buffer now contains an empty file that you just visited
\(presumably by mistake), use this command to visit the file you really want."
      ;; The C's interactive: the visited file's directory, its own name
      ;; as the read's INITIAL, and `confirm-nonexistent-file-or-buffer'
      ;; as the read's MUSTMATCH. The directory and the name are put in
      ;; the minibuffer with point at the start of the name, so the
      ;; command offers the file being visited for editing rather than
      ;; making the whole name be typed again. The C's `t' beside the
      ;; name is WILDCARDS, which this tree does not port.
      (interactive
       (let* ((file (buffer-file-name (current-buffer)))
              (name (and file (file-name-nondirectory-part file)))
              (dir (and file (file-name-directory-part file))))
         (list (read-file-name "Find alternate file: " dir #f
                               (confirm-nonexistent-file-or-buffer) name))))
      (unless (let loop ((rest (*kill-buffer-query-functions*)))
                (or (null? rest)
                    (and ((car rest)) (loop (cdr rest)))))
        (error "Aborted"))
      (when (and (buffer-modified-p (current-buffer))
                 (buffer-file-name (current-buffer))
                 (not (yes-or-no-p
                       (*current-frame*)
                       (format #f "Kill and replace buffer `~a' without saving it? "
                               (buffer-name (current-buffer))))))
        (error "Aborted"))
      (let* ((obuf (current-buffer))
             (ofile (buffer-file-name obuf))
             (oname (buffer-name obuf)))
        ;; the kill-buffer hook the C runs here - the query functions
        ;; have been asked already; the buffer-local hook value is not
        ;; ported (no hooks yet)
        (when (get-buffer-create " **lose**")
          (%kill-buffer " **lose**"))
        (rename-buffer obuf " **lose**")
        (set!buffer-file-name obuf #f)
        (let ((newbuf
               (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (let ((newbuf (find-file-noselect filename)))
                     (switch-to-buffer newbuf)
                     newbuf))
                 (lambda ()
                   ;; on failure the old buffer is put back, as the
                   ;; C's unwind-protect does
                   (unless (eq? (current-buffer) obuf)
                     #f)))))
          (unless (eq? (current-buffer) obuf)
            (let ((*kill-buffer-query-functions* '()))
              (%kill-buffer obuf)))
          newbuf)))

    ;;----------------------------------------------------------------
    ;; `revert-buffer'
    ;;------------------------------------------------------------------

    (define (revert-buffer--default ignore-auto noconfirm)
      ;; GNU Emacs's `revert-buffer--default' (files.el:7199): "Default
      ;; function for `revert-buffer'. The function returns non-nil if
      ;; it reverts the buffer, and signals an error if the buffer is
      ;; not associated with a file." The auto-save questions are not
      ;; ported (no auto-saving here); the confirmations are the C's
      ;; exact ones - a buffer that was edited is asked about, and so
      ;; is one that was not (`revert-without-query' is nil by
      ;; default, so the catch branch reduces to the question).
      ;;--------------------------------------------------------------
      (let ((file-name (buffer-file-name (current-buffer))))
        (cond
         ((not file-name)
          (error "Buffer does not seem to be associated with any file"))
         ((not (file-exists-p file-name))
          (error "Cannot revert nonexistent file ~a" file-name))
         ((not (file-writable-p file-name))
          ;; the C's test is `file-readable-p'; a file that cannot be
          ;; read cannot be reverted either, and the message is the
          ;; unreadable one
          (error "File ~a no longer readable!" file-name))
         ((or noconfirm
              (yes-or-no-p
               (*current-frame*)
               ;; Emacs's `(if (buffer-modified-p) (format "Discard ...")
               ;; (format "Revert ..."))' - the two `format' calls are
               ;; separate there and separate here, which is also what
               ;; lets the compiler check both format strings.
               (if (buffer-modified-p (current-buffer))
                   (format #f "Discard edits and reread from ~a? " file-name)
                   (format #f "Revert buffer from file ~a? " file-name))))
          ;; the re-read: the buffer's text becomes the file's, its
          ;; name and the variables it visits with standing
          (let* ((ed (current-buffer))
                 (old-point (point)))
            (with-current-buffer ed
              (text-editor-set-read-only! ed #f)
              (insert-file-contents file-name #t #t)
              (goto-char (min old-point (point-max)))
              ;; the visit-time messages and the read-only note, as
              ;; `after-find-file' does
              (text-editor-set-read-only! ed (file-write-protected? file-name))
              (note-file-read-only! (*current-frame*)))
            #t)
          #t))))

    (define-command (revert-buffer . args)
      ;; GNU Emacs's `revert-buffer' (files.el:7189): "Replace current
      ;; buffer text with the text of the visited file on disk. This
      ;; undoes all changes since the file was visited or saved." Its
      ;; parameters are Elisp's `&optional' three - IGNORE-AUTO,
      ;; NOCONFIRM, PRESERVE-MODES - which this tree's fixed-parameter
      ;; pattern cannot spell for a command Lisp calls with any number
      ;; of them, so the rest-list stands for it: the interactive
      ;; prefix argument's sense is reversed ("I admit it's odd"),
      ;; which the interactive form's doing. The buffer-local
      ;; `revert-buffer-function' runs instead when there is one - the
      ;; Buffer List's own refresh is that.
      "Replace current buffer text with the text of the visited file on disk.
This undoes all changes since the file was visited or saved.
With a prefix argument, offer to revert from latest auto-save file, if
that is more recent than the visited file."
      (interactive (list (not current-prefix-arg)))
      ;; the optional NOCONFIRM and PRESERVE-MODES are the Lisp call's;
      ;; interactively neither is given
      (let ((ignore-auto (if (pair? args) (car args) #f))
            (noconfirm (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f)))
        (let ((fn (buffer-local-value (current-buffer) 'revert-buffer-function)))
          (if fn
              (fn ignore-auto noconfirm)
              (revert-buffer--default ignore-auto noconfirm)))))

    ;;----------------------------------------------------------------
    ;; `not-modified'
    ;;------------------------------------------------------------------

    (define-command (not-modified arg)
      ;; GNU Emacs's `not-modified' (files.el:6591): "Mark current
      ;; buffer as unmodified, not needing to be saved. With prefix
      ;; ARG, mark buffer as modified, so `save-buffer' will save."
      "Mark current buffer as unmodified, not needing to be saved.
With prefix ARG, mark buffer as modified, so \\[save-buffer] will save."
      (interactive "P")
      (files--message
       (if arg "Modification-flag set" "Modification-flag cleared"))
      (set-buffer-modified-p (and arg #t))
      #f)

    (define-command (pwd insert?)
      ;; GNU Emacs's `pwd' (files.el:924): "Show the current default
      ;; directory. With prefix argument INSERT, insert the current
      ;; default directory at point instead."
      ;;
      ;; `(interactive "P")' is the raw prefix, so *any* prefix inserts -
      ;; `C-u M-x pwd' and `M-1 M-x pwd' both do, which is what testing
      ;; the argument for truth means in Elisp and what
      ;; `(current-prefix-arg)' answers here, a bare `C-u' being the list
      ;; `(4)'.
      ;;
      ;; The C's parameter is named INSERT, and it cannot be here: the
      ;; body calls editfns.c's `insert', and a parameter of that name
      ;; shadows the procedure - so `(insert (default-directory))' tried
      ;; to *apply* the prefix, "(4)", as a function. The `?' is the
      ;; tree's mark for a name the host language took, as
      ;; `font-lock--add-text-property''s `append?' is.
      "Show the current default directory.
With prefix argument INSERT, insert the current default directory
at point instead."
      (interactive (list (current-prefix-arg)))
      ;; `default-directory' is a *variable* in Emacs and a zero-argument
      ;; procedure here - it is buffer-local and answers from the buffer -
      ;; so the C's `default-directory' is `(default-directory)'. Without
      ;; the call the message reads "Directory #<procedure
      ;; default-directory ()>", which is how this was found.
      (if insert?
          (insert (default-directory))
          (message "Directory %s" (default-directory))))

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
            ;; The buffer's own coding system, which is the character set
            ;; *and* the end of line - and the code points go out rather
            ;; than a string, because a buffer holding a byte character
            ;; has no string form.
            ;; `coding-system-for-write' first, as `write-region' does:
            ;; it is what C-x RET c sets for the following command.
            (let ((coding (or (*coding-system-for-write*)
                              (buffer-file-coding-system buffer))))
              (write-file-code-points path (text-editor-to-code-points buffer)
                                      coding)
              (*last-coding-system-used* coding))
            (text-editor-set-modified! buffer #f)
            (set!frame-message (*current-frame*)
                                       (string-append "Wrote " path))
            ;; the C's `(when save-silently (message nil))', which
            ;; `basic-save-buffer' runs after the write: with the
            ;; variable set there is nothing in the echo area to say
            (when (*save-silently*) (message #f))
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
       ;; The C's two reads, in the C's argument positions: DIR,
       ;; DEFAULT-FILENAME, MUSTMATCH, INITIAL. A buffer that visits
       ;; nothing is offered its own name in `default-directory'.
       (list (if (buffer-file-name (current-buffer))
                 (read-file-name "Write file: " #f #f #f #f)
                 (read-file-name
                  "Write file: " (default-directory)
                  (expand-file-name
                   (file-name-nondirectory-part (buffer-name (current-buffer)))
                   (default-directory))
                  #f #f))
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
        (set-buffer-modified-p #t)
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
    (define-key *default-keymap* (kbd "C-x C-f")
      find-file)
    (define-key *default-keymap* (kbd "C-x C-s")
      save-buffer)
    (define-key *default-keymap* (kbd "C-x C-w")
      write-file)
    (define-key *default-keymap* (kbd "C-x C-c")
      save-buffers-kill-terminal)
    ;; The window manager's request to close the frame arrives as the key
    ;; event `(delete-frame (FRAME))', which `keyboard.c:6238' makes and
    ;; `keyboard.c:14550' binds to `handle-delete-frame' in
    ;; `special-event-map'. Here the binding is made where the command is,
    ;; as every binding in this tree is.
    (define-key *special-event-map* (kbd "<delete-frame>")
      handle-delete-frame)
    (define-key *default-keymap* (kbd "C-x k")
      kill-buffer)
    ;; The rest of files.el's C-x map and M-~.
    (define-key *default-keymap* (kbd "C-x i")
      insert-file)
    (define-key *default-keymap* (kbd "C-x C-r")
      find-file-read-only)
    (define-key *default-keymap*
      (kbd "C-x 4 f")
      find-file-other-window)
    (define-key *default-keymap* (kbd "C-x C-v")
      find-alternate-file)
    (define-key *default-keymap* (kbd "M-~") not-modified)

    ;;----------------------------------------------------------------
    ;; insert-directory

    (define *insert-directory-program* (make-parameter "ls"))
    ;; ^ GNU Emacs's `insert-directory-program' (files.el): "The program
    ;; to use to list a directory."

    (define *ls-lisp-use-insert-directory-program* (make-parameter #f))
    ;; ^ GNU Emacs's `ls-lisp-use-insert-directory-program', whose own
    ;; default is `(not (memq system-type '(ms-dos windows-nt android)))'
    ;; - true on GNU/Linux, where Emacs runs `ls'. It is false here, and
    ;; that is the decision `ls-lisp.sld''s header records rather than an
    ;; accident: this editor lists directories with `ls-lisp' everywhere,
    ;; so that a listing needs no subprocess, no `--dired' parsing and no
    ;; coding-system round trip.

    (define (files--use-insert-directory-program-p)
      ;; GNU Emacs's `files--use-insert-directory-program-p' (files.el):
      ;; "Return non-nil if we should use `insert-directory-program'.
      ;; Return nil if we should prefer `ls-lisp' instead."
      ;;--------------------------------------------------------------
      (and (*ls-lisp-use-insert-directory-program*)
           (*insert-directory-program*)))

    (define *directory-files-no-dot-files-regexp* "[^.]\\|\\.\\.\\.")
    ;; ^ GNU Emacs's `directory-files-no-dot-files-regexp' (files.el:6768),
    ;; a `defconst': "Regexp matching any file name except \".\" and
    ;; \"..\". More precisely, it matches parts of any nonempty string
    ;; except those two."

    (define *delete-by-moving-to-trash* (make-parameter #f))
    ;; ^ GNU Emacs's `delete-by-moving-to-trash' (files.el), false by
    ;; default: "Non-nil means `delete-file' and `delete-directory'
    ;; move to the system trash instead of deleting."

    (define (delete-file filename . rest)
      ;; GNU Emacs's `delete-file' (files.el): "Delete file named
      ;; FILENAME. If it is a symlink, remove the symlink. ... TRASH
      ;; non-nil means to trash the file instead of deleting, provided
      ;; `delete-by-moving-to-trash' is non-nil."
      ;;
      ;; `move-file-to-trash' is not ported, and the arm that calls it
      ;; cannot be reached while `delete-by-moving-to-trash' is false,
      ;; which is its default.
      ;;--------------------------------------------------------------
      (let ((trash (if (pair? rest) (car rest) #f)))
        (if (and (file-directory-p filename) (not (file-symlink-p filename)))
            (error "Removing old name: is a directory")
            (let ((filename (expand-file-name filename)))
              (cond ((and (*delete-by-moving-to-trash*) trash)
                     (error "move-file-to-trash is not ported"))
                    (else (delete-file-internal filename)))))))

    (define (delete-directory directory . rest)
      ;; GNU Emacs's `delete-directory' (files.el): "Delete the directory
      ;; named DIRECTORY. Does not follow symlinks. If RECURSIVE is
      ;; non-nil, delete files in DIRECTORY as well, with no error if
      ;; something else is simultaneously deleting them."
      ;;
      ;; The C's `(files--force t #'directory-files ...)' is an
      ;; autoload-forcing call, which has no equivalent here, and its
      ;; `(files--force t #'delete-file file)' likewise; the calls are
      ;; made directly. `move-file-to-trash' is not ported, as in
      ;; `delete-file' above.
      ;;--------------------------------------------------------------
      (let* ((recursive (if (pair? rest) (car rest) #f))
             (trash (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
             (directory (directory-file-name (expand-file-name directory))))
        (cond
         ((and (*delete-by-moving-to-trash*) trash)
          (if (not (or recursive
                       (null? (directory-files directory #t
                                               *directory-files-no-dot-files-regexp*))))
              (error "Directory is not empty, not moving to trash")
              (error "move-file-to-trash is not ported")))
         (else
          ;; "Otherwise, call ourselves recursively if needed."
          (when (or (not recursive)
                    (file-symlink-p directory)
                    (let ((files (directory-files
                                  directory #t
                                  *directory-files-no-dot-files-regexp*)))
                      (for-each
                       (lambda (file)
                         ;; "This test is equivalent to but more efficient
                         ;; than (and (file-directory-p fn) (not
                         ;; (file-symlink-p fn)))."
                         (if (eq? #t (car (file-attributes file)))
                             (delete-directory file recursive)
                             (delete-file file)))
                       files)
                      #t))
            (delete-directory-internal directory))))))

    (define *byte-count-to-string-function* (make-parameter #f))
    ;; ^ GNU Emacs's `byte-count-to-string-function' (files.el:1740), a
    ;; `defcustom': "Function that turns a number of bytes into a
    ;; human-readable string. It is for use when displaying file sizes and
    ;; disk space where other constraints do not force a specific format."
    ;; Its default is `file-size-human-readable-iec', filled in below
    ;; because that function is defined after it.

    (define (file-size-human-readable file-size . rest)
      ;; GNU Emacs's `file-size-human-readable' (files.el:1689): "Produce
      ;; a string showing FILE-SIZE in human-readable form." FLAVOR is
      ;; nil, `si' or `iec'; SPACE goes between the number and the unit;
      ;; UNIT is the unit symbol.
      ;;--------------------------------------------------------------
      (let* ((flavor (if (pair? rest) (car rest) #f))
             (space (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
             (unit (if (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest)))
                       (caddr rest)
                       #f))
             (power (if (or (not flavor) (eq? flavor 'iec)) 1024.0 1000.0))
             (prefixes '("" "k" "M" "G" "T" "P" "E" "Z" "Y" "R" "Q")))
        (let loop ((size (exact->inexact file-size)) (prefixes prefixes))
          ;; "while (and (>= file-size power) (cdr prefixes))"
          (if (and (>= size power) (pair? (cdr prefixes)))
              (loop (/ size power) (cdr prefixes))
              (let* ((prefix (car prefixes))
                     (prefixed-unit
                      (if (eq? flavor 'iec)
                          (string-append
                           (if (string=? prefix "k") "K" prefix)
                           (if (string=? prefix "") "" "i")
                           (or unit "B"))
                          (string-append prefix (or unit "")))))
                ;; "Mimic what GNU \"ls -lh\" does: If the formatted size
                ;; will have just one digit before the decimal ... and its
                ;; fractional part is not too small ... then emit one digit
                ;; after the decimal."
                ;; The C's own `(format "%.1f%s%s" ...)': `format' is
                ;; Guile's in this library, so editfns.c's is imported
                ;; under `ef:' for this - Guile's `~,0f' writes "0." where
                ;; C's `%.0f' writes "0", and ours writes C's.
                ;;
                ;; `(mod size 1.0)' is the fractional part; Guile's
                ;; `modulo' takes integers only.
                (ef:format (if (and (< size 10)
                                    (>= (- size (floor size)) 0.05)
                                    (< (- size (floor size)) 0.95))
                               "%.1f%s%s"
                               "%.0f%s%s")
                        size
                        (if (string=? prefixed-unit "") "" (or space ""))
                        prefixed-unit))))))

    (define (file-size-human-readable-iec size)
      ;; GNU Emacs's `file-size-human-readable-iec': "Human-readable
      ;; string for SIZE bytes, using IEC prefixes."
      ;;--------------------------------------------------------------
      (file-size-human-readable size 'iec " "))

    (*byte-count-to-string-function* file-size-human-readable-iec)

    (define (get-free-disk-space dir)
      ;; GNU Emacs's `get-free-disk-space' (files.el:8242): "String
      ;; describing the amount of free space on DIR's file system. If
      ;; DIR's free space cannot be obtained, this function returns nil."
      ;;
      ;; It reads element 2 of `file-system-info' - the *available*
      ;; space - and passes it through `byte-count-to-string-function'.
      ;; `file-system-info' is fileio.c's and is NOT ported: Guile has no
      ;; `statvfs' at all (checked: neither `(guile)' nor any `ice-9'
      ;; module), so porting it means reaching `statvfs(3)' through FFI
      ;; and reading a `struct statvfs' by offset, which the GTK binding
      ;; in `pgtk.sld' shows how to do but which nothing here has done
      ;; yet. Until it is, this answers nil, which is the C's own answer
      ;; when the free space cannot be obtained.
      ;;--------------------------------------------------------------
      (let ((info (file-system-info dir)))
        (if (not info)
            #f
            (let ((avail (let loop ((rest info) (n 2))
                           (cond ((not (pair? rest)) #f)
                                 ((= n 0) (car rest))
                                 (else (loop (cdr rest) (- n 1)))))))
              (and avail ((*byte-count-to-string-function*) avail))))))

    (define (insert-directory file switches . rest)
      ;; GNU Emacs's `insert-directory' (files.el): "Insert directory
      ;; listing for FILE, formatted according to SWITCHES. Leaves point
      ;; after the inserted text. SWITCHES may be a string of options, or
      ;; a list of strings representing individual options. Optional
      ;; third arg WILDCARD means treat FILE as shell wildcard. Optional
      ;; fourth arg FULL-DIRECTORY-P means file is a directory and
      ;; switches do not contain `d', so that a full listing is expected.
      ;;
      ;; Depending on the value of `ls-lisp-use-insert-directory-program'
      ;; this works either using a Lisp emulation of the "ls" program or
      ;; by running a directory listing program whose name is in the
      ;; variable `insert-directory-program'."
      ;;
      ;; Only the first arm is ported: `insert-directory-program', the
      ;; shell and the `--dired' parsing are the machinery this tree does
      ;; not have, and `files--use-insert-directory-program-p' is false
      ;; here, so that arm is the one a listing would not have taken.
      ;; Its place is kept rather than dropped, so that the day a
      ;; subprocess exists the shape is already Emacs's.
      ;;--------------------------------------------------------------
      (let ((wildcard (and (pair? rest) (car rest)))
            (full-directory-p (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        ;; "We need the directory in order to find the right handler."
        (let ((handler (find-file-name-handler (expand-file-name file)
                                               'insert-directory)))
          (cond
           (handler
            (handler 'insert-directory file switches wildcard full-directory-p))
           ((not (files--use-insert-directory-program-p))
            (ls-lisp--insert-directory file switches wildcard full-directory-p))
           (else
            (error "No `insert-directory-program' here: %s"
                   (*insert-directory-program*)))))))


    ;;----------------------------------------------------------------
    ;; The seam to `ls-lisp.sld'

    ;; `ls-lisp.sld' cannot import this library - this library is *its*
    ;; importer, and a Scheme library import cannot be circular, where
    ;; Emacs gets away with the same cycle because files.el only
    ;; `(require 'ls-lisp)' from inside a function body. So the two
    ;; files.el functions `ls-lisp' calls are handed to it here, once,
    ;; at the end of this library's load. A listing that somehow ran
    ;; before this line would say those functions were missing rather

    ;; than quietly draw something else.
    (install-ls-lisp-files! wildcard-to-regexp file-size-human-readable)

    ;;----------------------------------------------------------------
    ;; `cd' - the buffer's default directory
    ;;------------------------------------------------------------------

    (define *cd-path*
      ;; GNU Emacs's `cd-path' (`files.el:933'): "Value of the CDPATH
      ;; environment variable, as a list. Not actually set up until the
      ;; first time you use it." A parameter here for the same reason the
      ;; other defvars are - so a test can bind it.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (cd-path . args)
      ;; The value of the variable, which `cd' fills in on first use.
      ;; GNU Emacs's `cd-path' is a `defvar', so this is its reading face
      ;; and `set!cd-path' its writing one - the same pair the other
      ;; defvars here have.
      ;;--------------------------------------------------------------
      (*cd-path*))

    (define (set!cd-path value)
      (*cd-path* value))

    (define (parse-colon-path search-path)
      ;; GNU Emacs's `parse-colon-path' (`files.el:937'): "Explode a
      ;; search path into a list of directory names... For an empty path
      ;; element (i.e., a leading or trailing separator, or two adjacent
      ;; separators), return nil (meaning `default-directory') as the
      ;; associated list element."
      ;;
      ;; The names are runs of non-separator characters, each turned
      ;; into directory syntax, and each an environment-substituted
      ;; string first - which is `substitute-env-vars', called on the
      ;; whole path before it is split (`:946'). The C's
      ;; `double-slash-special-p' case is for Windows and Cygwin; the
      ;; leading-slash collapse here is the `1' branch.
      ;;--------------------------------------------------------------
      (if (not (string? search-path))
          #f
          (let ((spath (substitute-env-vars search-path)))
            (let loop ((i 0) (start 0) (acc '()))
              (cond
               ((= i (string-length spath))
                (reverse (let ((piece (substring spath start i)))
                           (cons (if (equal? "" piece)
                                     #f
                                     (let* ((dir (file-name-as-directory piece))
                                            ;; the whole run of leading
                                            ;; slashes collapses to one -
                                            ;; `(substring dir (1- (match-end 0)))'
                                            ;; for a run of `//+' on a
                                            ;; system where a double slash is
                                            ;; not special
                                            (run (let loop ((i 0))
                                                   (if (and (< i (string-length dir))
                                                            (char=? #\/ (string-ref dir i)))
                                                       (loop (+ i 1))
                                                       i))))
                                       (if (> run 1) (substring dir (- run 1)) dir)))
                                 acc))))
               ((char=? #\: (string-ref spath i))
                (loop (+ i 1) (+ i 1)
                      (cons (if (= start i)
                                #f
                                (file-name-as-directory (substring spath start i)))
                            acc)))
               (else (loop (+ i 1) start acc)))))))

    (define (locate-file filename path . rest)
      ;; GNU Emacs's `locate-file' (`files.el:1113'): "Search for
      ;; FILENAME through PATH. If found, return the absolute file name
      ;; of FILENAME; otherwise return nil."
      ;;
      ;; The C wrapper's symbol forms of PREDICATE - `executable',
      ;; `readable', `writable', `exists' - are the `access' bits, which
      ;; is what `(lread.c:1582') spells with a logior. They are not
      ;; carried: the one caller here passes a procedure.
      ;;--------------------------------------------------------------
      (let ((suffixes (if (pair? rest) (car rest) '()))
            (predicate (if (and (pair? rest) (pair? (cdr rest)))
                           (cadr rest)
                           #f)))
        (locate-file-internal filename path suffixes predicate)))

    (define (cd-absolute dir)
      ;; GNU Emacs's `cd-absolute' (`files.el:962'): "Change current
      ;; directory to given absolute file name DIR."
      ;;
      ;; "Put the name into directory syntax now, because otherwise
      ;; expand-file-name may give some bad results" - the C's own
      ;; comment, and the reason for the order of the first two lines.
      ;; `abbreviate-file-name' is deliberately not called; the C's note
      ;; says why: most buffers never go through here, so abbreviating
      ;; only some of them makes the directory look different for no
      ;; reason.
      ;;--------------------------------------------------------------
      (let* ((dir (file-name-as-directory dir))
             (dir (expand-file-name dir)))
        (if (not (file-directory-p dir))
            ;; the C's two messages (`files.el:973-976'), each built as
            ;; one string - `(error "a" dir)' would put DIR in the
            ;; irritants and print a message without it
            (error (if (file-exists-p dir)
                       (format #f "~a is not a directory" dir)
                       (format #f "~a: no such directory" dir)))
            ;; `(setq default-directory dir)' and `(setq
            ;; list-buffers-directory dir)' are the C's last two lines
            ;; (`files.el:980-981'), and they are Emacs's else *body* -
            ;; which is two forms, so it is a `begin' here. The second is
            ;; what `C-x C-b' shows in the File column for a buffer that
            ;; visits no file, which is why `cd' in `*scratch*' is visible
            ;; there at all. The variable is `menu-bar.el''s and needs no
            ;; definition: this tree's buffer-local variables are a
            ;; per-buffer table keyed by a symbol.
            (begin
              (set!buffer-default-directory (current-buffer) dir)
              (set-buffer-local-value! (current-buffer)
                                       'list-buffers-directory dir)))))

    (define-command (cd dir)
      "Make DIR become the current buffer's default directory.
If your environment includes a `CDPATH' variable, try each one of
that list of directories (separated by occurrences of
`path-separator') when resolving a relative directory name.
The path separator is colon in GNU and GNU-like systems."
      (interactive (list (read-directory-name "Change default directory: "
                                              (default-directory)
                                              (default-directory))))
      ;; The CDPATH list is filled in on first use, as `cd-path' says it
      ;; is, and both the interactive spec and the body need it - so it
      ;; is done here rather than twice.
      (unless (*cd-path*)
        (*cd-path* (or (parse-colon-path (getenv "CDPATH")) (list "./"))))
      (cd-absolute
       (or (locate-file dir (*cd-path*) '()
                        (lambda (f)
                          (and (file-directory-p f) 'dir-ok)))
           (if (getenv "CDPATH")
               (error (format #f
                              "No such directory found via CDPATH environment variable: ~a"
                              dir))
               (error (format #f "No such directory: ~a" dir))))))

    ))
