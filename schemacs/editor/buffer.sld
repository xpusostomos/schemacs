(define-library (schemacs editor buffer)
  ;; This library mirrors GNU Emacs's `buffer.c': the *buffers* as a
  ;; collection - which ones exist, what they are called, which one is
  ;; current, making one and killing one - and the slots that belong to a
  ;; buffer without being part of its text.
  ;;
  ;; What it does not mirror, because another library already does:
  ;;
  ;;  * the text, the gap and the edits - `buffer.c`'s own text is in
  ;;    `insdel.c`, which is `(schemacs editor engine)'. A buffer here *is*
  ;;    a `<text-editor>': there is no wrapper record, exactly as there is
  ;;    no second struct in Emacs. `BUFFERP' is `TEXT-EDITOR-TYPE?'.
  ;;  * the markers and the undo list - `marker.c' and the undo half of
  ;;    `buffer.c', also the engine's.
  ;;  * `current-buffer' *maintained* by the window code: in Emacs it is
  ;;    `window.c''s `set_buffer_internal' that sets `current_buffer' when
  ;;    a window is selected or a buffer displayed. Ours is
  ;;    `(schemacs editor frame)''s `CURRENT-EDITOR', which asks the echo
  ;;    area and then the selected window, and this library only adds the
  ;;    dynamic override that `SET-BUFFER' needs on top of it.
  ;;
  ;; Two decisions worth stating, because Emacs decides them differently:
  ;;
  ;;  * **The buffer-local slots are a table beside the buffer, not fields
  ;;    of it.** Emacs keeps `keymap' and `local_var_alist' inside the
  ;;    buffer struct, so that the collector can see them and so that
  ;;    reaching them is a field read. The engine is a large and tested
  ;;    library, and a keymap is a management concern rather than a text
  ;;    one, so the slots live in a weak table keyed by the buffer
  ;;    (`WEAK-TABLE', from `(schemacs weak)') - weak because a table that
  ;;    held its keys strongly would keep every killed buffer alive
  ;;    forever. They move into the record when the engine is next opened.
  ;;  * **Names.** Where Emacs has a *function*, this library uses its
  ;;    name - `GET-BUFFER', `KILL-BUFFER', `SET-BUFFER', `OTHER-BUFFER'
  ;;    and the rest - so that Elisp reads the same here. Where Emacs has
  ;;    only a *variable* (`buffer-read-only', `default-directory',
  ;;    `buffer-local-keymap' has no function either) the accessor is
  ;;    named after the variable with this tree's `?' and `SET!' spelling,
  ;;    and the docstring says which variable it is.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs weak)
          new-weak-table
          weak-table-ref
          weak-table-set!
          weak-table-delete!
          weak-table-keys)
    (only (schemacs editor engine)
          new-text-editor
          text-editor-type?
          text-editor-buffer-name set!text-editor-buffer-name
          text-editor-file-name set!text-editor-file-name
          text-editor-modified? text-editor-set-modified!
          text-editor-read-only? text-editor-set-read-only!
          text-editor-get-cursor)
    (only (schemacs editor frame)
          *current-frame*
          current-editor
          selected-window
          set!window-buffer
          set!window-top-line
          window-buffer))

  (export
   *buffer-list*
   *buffer-list-update-hook*
   *current-buffer*
   *kill-buffer-query-functions*
   *scratch-buffer-name*
   buffer-default-directory
   buffer-file-name
   buffer-list
   buffer-list-alist
   buffer-live-p
   buffer-local-keymap
   buffer-local-value
   buffer-modified-p
   *transient-mark-mode*
   buffer-name
   mark-active set!mark-active transient-mark-mode
   buffer-read-only?
   bufferp
   bury-buffer
   current-buffer
   get-buffer
   get-buffer-create
   generate-new-buffer
   generate-new-buffer-name
   kill-buffer
   other-buffer
   record-buffer!
   rename-buffer
   run-buffer-list-update-hook!
   save-current-buffer
   set-buffer
   set-buffer-local-value!
   set-buffer-modified-p
   set!buffer-default-directory
   set!buffer-file-name
   set!buffer-local-keymap
   set!buffer-name
   set!buffer-read-only
   with-current-buffer
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The buffers that exist, and the one that is current

    (define *buffer-list*
      ;; GNU Emacs's `Vbuffer-alist': the live buffers, as an association
      ;; list of (NAME . BUFFER) ordered most-recently-used first.
      ;;
      ;; One structure serves three purposes in Emacs and here: it is what
      ;; `GET-BUFFER' searches by name, what `BUFFER-LIST' returns, and
      ;; what the order of `OTHER-BUFFER' and `BURY-BUFFER' means. A hash
      ;; table keyed by name would find a buffer faster and lose the order,
      ;; which is why Emacs does not use one.
      ;;
      ;; It is a parameter rather than a module-level variable so that a
      ;; test can bind it, which is this project's convention for state
      ;; that a test would otherwise leak into the next one.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *buffer-list-update-hook*
      ;; GNU Emacs's `buffer-list-update-hook': thunks run whenever the
      ;; list changes - a buffer made, killed, or moved in the order.
      ;; Emacs runs it from `Fset_buffer_list'; so does this.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *current-buffer*
      ;; The dynamically current buffer, or false when the choice belongs
      ;; to the frame: `SET-BUFFER' sets it, `SAVE-CURRENT-BUFFER' and
      ;; `WITH-CURRENT-BUFFER' restore it. Emacs has no such variable - its
      ;; `current_buffer' is the C global that both `set-buffer' and the
      ;; window code write - so this is that global, with false meaning
      ;; "whatever the frame says" rather than "no buffer".
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *kill-buffer-query-functions*
      ;; GNU Emacs's `kill-buffer-query-functions': procedures of no
      ;; arguments asked before a buffer is killed, in order. A false
      ;; answer from any of them cancels the kill. This is where "Buffer
      ;; modified; kill anyway?" belongs.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *scratch-buffer-name* "*scratch*")
    ;; ^ The name of the buffer Emacs makes when there would otherwise be
    ;; no buffer at all, and the name it starts with.

    (define (run-buffer-list-update-hook!)
      ;; Tell whoever is listening that the list of buffers changed.
      ;;--------------------------------------------------------------
      (for-each (lambda (thunk) (thunk)) (*buffer-list-update-hook*)))

    (define (buffer-list-alist)
      ;; The list itself, names and buffers: GNU Emacs's `Vbuffer-alist'
      ;; as a value. `BUFFER-LIST' is the same list without the names.
      ;;--------------------------------------------------------------
      (*buffer-list*))

    (define (buffer-list)
      ;; Every live buffer, most-recently-used first: GNU Emacs's
      ;; `(buffer-list)'. What "most recently used" means to Emacs is the
      ;; order of the list itself, which the functions below maintain: a
      ;; new buffer goes to the front, `BURY-BUFFER' sends one to the end,
      ;; and the display code promotes a buffer to the front when it shows
      ;; it (that last one is not wired here yet - see `RECORD-BUFFER!'
      ;; below).
      ;;--------------------------------------------------------------
      (map cdr (*buffer-list*)))

    (define (bufferp thing)
      ;; Whether THING is a buffer: GNU Emacs's `bufferp'. A buffer here
      ;; is the engine's text editor, so this is its type predicate.
      ;;--------------------------------------------------------------
      (text-editor-type? thing))

    (define (buffer-live-p thing)
      ;; Whether THING is a buffer that still exists: GNU Emacs's
      ;; `buffer-live-p'. A buffer is live while it is in the list.
      ;;--------------------------------------------------------------
      (and (bufferp thing)
           (let loop ((rest (*buffer-list*)))
             (cond ((null? rest) #f)
                   ((eq? (cdar rest) thing) #t)
                   (else (loop (cdr rest)))))))

    (define (current-buffer)
      ;; The buffer a command acts on: GNU Emacs's `(current-buffer)'.
      ;;
      ;; The answer is the dynamically current buffer when `SET-BUFFER'
      ;; has set one, and otherwise whatever the frame makes current -
      ;; the echo area's buffer while a minibuffer is read, else the
      ;; selected window's. Emacs has the same order with the parts in
      ;; different places: `current_buffer' is written by `set-buffer' and
      ;; by the window code.
      ;;--------------------------------------------------------------
      (or (*current-buffer*) (current-editor)))

    (define (set-buffer buffer)
      ;; Make BUFFER the current buffer: GNU Emacs's `set-buffer'. It does
      ;; *not* put the buffer in a window - "if you want to change which
      ;; buffer is displayed in the selected window, use
      ;; `switch-to-buffer'" - and it does not reorder the list.
      ;;--------------------------------------------------------------
      (define (buffer-or-name thing)
        (cond ((bufferp thing) thing)
              ((string? thing) (get-buffer thing))
              (else #f)))
      (let ((buffer (buffer-or-name buffer)))
        (unless buffer
          (error "No such buffer" buffer))
        (*current-buffer* buffer)
        buffer))

    (define (save-current-buffer thunk)
      ;; Call THUNK with the current buffer as it is, and put the current
      ;; buffer back afterwards whatever THUNK does: GNU Emacs's
      ;; `save-current-buffer'. Emacs's is a macro, and re-entrant the same
      ;; way - the restore is a `dynamic-wind' here and an unwind form
      ;; there.
      ;;--------------------------------------------------------------
      (let ((saved (*current-buffer*)))
        (dynamic-wind
          (lambda () #f)
          thunk
          (lambda () (*current-buffer* saved)))))

    (define-syntax with-current-buffer
      ;; Run the body with BUFFER current, and restore the current buffer
      ;; afterwards: GNU Emacs's `with-current-buffer', which is
      ;; `save-current-buffer' with a `set-buffer' inside.
      ;;
      ;; It is a macro here as it is in Emacs - not a procedure taking a
      ;; thunk - because the body is several forms and the point of it is
      ;; that they read as if the buffer were simply current:
      ;;
      ;;     (with-current-buffer "*Completions*"
      ;;       (erase-buffer)
      ;;       (insert "hello"))
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((with-current-buffer buffer body ...)
         (save-current-buffer
          (lambda ()
            (set-buffer buffer)
            body ...)))))

    (define (record-buffer! buffer)
      ;; Move BUFFER to the front of the list, it having just been shown or
      ;; selected: GNU Emacs's `record_buffer' in `window.c'.
      ;;
      ;; This is not called by anything yet. Emacs calls it from the
      ;; display code, which this project's renderer does not know about
      ;; yet, so the order is only what making, killing and burying make
      ;; it. It is here because it is the other half of the order, and
      ;; because `OTHER-BUFFER' is defined in terms of it.
      ;;--------------------------------------------------------------
      (let ((name (buffer-name buffer)))
        (*buffer-list*
         (cons (cons name buffer)
               (let loop ((rest (*buffer-list*)))
                 (cond ((null? rest) '())
                       ((eq? (cdar rest) buffer) (loop (cdr rest)))
                       (else (cons (car rest) (loop (cdr rest))))))))
        (run-buffer-list-update-hook!)
        buffer))

    ;;----------------------------------------------------------------
    ;; Names

    (define *transient-mark-mode*
      ;; GNU Emacs's `transient-mark-mode', which is `buffer.c''s: whether
      ;; the mark is *transient* - active until a command that is not a
      ;; motion or a mark command runs - and whether the region is drawn
      ;; while it is.
      ;;
      ;; It is on, as it is in an interactive Emacs, and that default is
      ;; worth writing down because it is hidden: the C's value is nil and
      ;; nothing in Lisp turns it on either. What does is `cus-start.el':
      ;;
      ;;   (transient-mark-mode editing-basics boolean nil
      ;;                        :standard (not noninteractive))
      ;;
      ;; so it is on in a session and off under `--batch' - which is why
      ;; `emacs --batch -Q' answers nil. There is no batch here to differ
      ;; from, so it is on.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (transient-mark-mode)
      ;; The mode as the *buffer* sees it: its own value if it has one,
      ;; else the global one. GNU Emacs turns the mode on for a single
      ;; command by setting the buffer-local value to the symbol `lambda'
      ;; (and `deactivate-mark' resets it), which is the one case where
      ;; the two differ.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'transient-mark-mode
                          (*transient-mark-mode*)))

    (define (mark-active)
      ;; Whether the mark is active: GNU Emacs's `mark-active', which
      ;; `buffer.c' declares as a per-buffer variable - each buffer has
      ;; its own, so switching buffers does not carry the region with it.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'mark-active #f))

    (define (set!mark-active flag)
      (set-buffer-local-value! (current-buffer) 'mark-active (and flag #t)))

    (define (buffer-name buffer)
      ;; The name of BUFFER: GNU Emacs's `buffer-name'. Emacs gives every
      ;; buffer a name, and a buffer with no name of its own would be one
      ;; the engine has not been told about, so it is named `*scratch*'
      ;; here the way an unnamed buffer is by Emacs's startup.
      ;;--------------------------------------------------------------
      (or (text-editor-buffer-name buffer) *scratch-buffer-name*))

    (define (set!buffer-name buffer name)
      ;; Name BUFFER: what Emacs's `rename-buffer' ends with. Use
      ;; `RENAME-BUFFER' to keep the list consistent, which is why that is
      ;; the function Emacs has and this one is its last step.
      ;;--------------------------------------------------------------
      (set!text-editor-buffer-name buffer name))

    (define (get-buffer name)
      ;; The buffer called NAME, or false: GNU Emacs's `get-buffer'.
      ;;--------------------------------------------------------------
      (let ((entry (assoc name (*buffer-list*))))
        (and entry (cdr entry))))

    (define (generate-new-buffer-name name . args)
      ;; A name no buffer has, based on NAME: GNU Emacs's
      ;; `generate-new-buffer-name'. If NAME is free it is returned;
      ;; otherwise `<N>' is appended with N counting from 2 until one is.
      ;; Emacs's optional second argument is a name it is all right to
      ;; return even though a buffer has it.
      ;;--------------------------------------------------------------
      (let ((ignore (if (pair? args) (car args) #f)))
        (cond
         ((and ignore (string=? name ignore)) name)
         ((not (get-buffer name)) name)
         (else
          (let loop ((n 2))
            (let ((candidate (string-append name
                                            "<"
                                            (number->string n)
                                            ">")))
              (if (get-buffer candidate)
                  (loop (+ 1 n))
                  candidate)))))))

    (define (rename-buffer buffer newname . args)
      ;; Give BUFFER the name NEWNAME: GNU Emacs's `rename-buffer'. With a
      ;; second argument the name is made unique rather than raising an
      ;; error when it is taken - Emacs's UNIQUE.
      ;;--------------------------------------------------------------
      (let* ((unique (if (pair? args) (car args) #f))
             (name (if unique
                       (generate-new-buffer-name newname (buffer-name buffer))
                       newname)))
        (when (and (not unique) (get-buffer name))
          (error "Buffer name already in use" name))
        (let ((old (buffer-name buffer)))
          (set!buffer-name buffer name)
          (*buffer-list*
           (map (lambda (entry)
                  (if (string=? (car entry) old)
                      (cons name (cdr entry))
                      entry))
                (*buffer-list*)))
          (run-buffer-list-update-hook!)
          name)))

    ;;----------------------------------------------------------------
    ;; Making a buffer

    (define (register-buffer! buffer name)
      ;; Put a new buffer at the front of the list: what Emacs's
      ;; `Fget_buffer_create' does with `Vbuffer_alist', and why a buffer
      ;; just made is the most recently used one.
      ;;--------------------------------------------------------------
      (set!buffer-name buffer name)
      (*buffer-list* (cons (cons name buffer) (*buffer-list*)))
      (run-buffer-list-update-hook!)
      buffer)

    (define (generate-new-buffer name)
      ;; A new buffer with a name based on NAME but unique: GNU Emacs's
      ;; `generate-new-buffer'. Emacs's optional second argument is about
      ;; *hooks* rather than the name - "inhibit-buffer-hooks" - and there
      ;; are no buffer hooks here yet, so this takes the name alone.
      ;;--------------------------------------------------------------
      (let ((buffer (new-text-editor)))
        (register-buffer! buffer (generate-new-buffer-name name))
        (init-buffer! buffer)
        buffer))

    (define (get-buffer-create name)
      ;; The buffer called NAME, made if there is none: GNU Emacs's
      ;; `get-buffer-create'. This is the way to reach a buffer by name -
      ;; `*Completions*', `*Messages*' - and get the same one every time.
      ;;--------------------------------------------------------------
      (or (get-buffer name)
          (let ((buffer (new-text-editor)))
            (register-buffer! buffer name)
            (init-buffer! buffer)
            buffer)))

    (define (init-buffer! buffer)
      ;; Give a buffer just made the slots and flags Emacs gives a new
      ;; buffer: read-write, unmodified, with no file and an empty local
      ;; keymap. (Emacs also runs `buffer-list-update-hook' and gives the
      ;; buffer a major mode, a syntax table, buffer-local defaults and a
      ;; marker for point; those wait for the features that need them.)
      ;;--------------------------------------------------------------
      (text-editor-set-modified! buffer #f)
      (text-editor-set-read-only! buffer #f)
      (set!text-editor-file-name buffer #f)
      (set!buffer-local-keymap buffer #f)
      buffer)

    (define (other-buffer . args)
      ;; A buffer other than the one named: GNU Emacs's `other-buffer',
      ;; which returns the most recently used buffer that is not the
      ;; current one - what a command wants when it has to have *some*
      ;; buffer and does not care which.
      ;;
      ;; The optional argument is the buffer to avoid, and #f means the
      ;; current one. When there is no other buffer Emacs makes
      ;; `*scratch*' rather than answer with nothing, so that a window is
      ;; never left showing a buffer that does not exist.
      ;;--------------------------------------------------------------
      (let* ((avoid (if (pair? args) (car args) #f))
             (avoid (if avoid
                        (if (bufferp avoid) avoid (get-buffer avoid))
                        (current-buffer))))
        (let loop ((rest (*buffer-list*)))
          (cond
           ((null? rest)
            ;; Emacs's `Fother_buffer' creates a buffer rather than fail
            (get-buffer-create *scratch-buffer-name*))
           ((eq? (cdar rest) avoid) (loop (cdr rest)))
           (else (cdar rest))))))

    (define (bury-buffer . args)
      ;; Move a buffer to the end of the list, so that `OTHER-BUFFER' will
      ;; not choose it until there is nothing else: GNU Emacs's
      ;; `bury-buffer', whose argument defaults to the current buffer.
      ;;--------------------------------------------------------------
      (let* ((thing (if (pair? args) (car args) #f))
             (buffer (cond ((not thing) (current-buffer))
                           ((bufferp thing) thing)
                           (else (get-buffer thing)))))
        (when buffer
          (let ((name (buffer-name buffer)))
            (*buffer-list*
             (let loop ((rest (*buffer-list*)) (moved '()))
               (cond ((null? rest) (reverse moved))
                     ((string=? (caar rest) name) (loop (cdr rest) moved))
                     (else (loop (cdr rest) (cons (car rest) moved))))))
            (*buffer-list*
             (append (*buffer-list*)
                     (list (cons name buffer))))
            (run-buffer-list-update-hook!)))
        buffer))

    (define (kill-buffer . args)
      ;; Kill a buffer: GNU Emacs's `kill-buffer'. The optional argument
      ;; is the buffer, or its name; with none, the current buffer.
      ;;
      ;; Emacs asks `kill-buffer-query-functions' first and kills nothing
      ;; if one of them says no, which is where the "Buffer modified; kill
      ;; anyway?" question belongs. The buffer then leaves the list, leaves
      ;; every window that was showing it (given another buffer), and
      ;; returns its name - or false when the question was answered no.
      ;;
      ;; What is *not* here, with what Emacs does about it: running
      ;; `kill-buffer-hook' (a buffer-local variable, and buffer-local
      ;; variables are only the slot mechanism so far), killing the
      ;; buffer's process and its overlays (neither exists here), and
      ;; `kill-buffer-query-functions'' `buffer-offer-save' branch (the
      ;; saving question is `files.el''s, which asks it its own way).
      ;;--------------------------------------------------------------
      (let* ((thing (if (pair? args) (car args) #f))
             (buffer (cond ((not thing) (current-buffer))
                           ((bufferp thing) thing)
                           (else (get-buffer thing)))))
        (unless (bufferp buffer)
          (error "No such buffer" thing))
        (let ((name (buffer-name buffer))
              (refused (let loop ((rest (*kill-buffer-query-functions*)))
                         (cond ((null? rest) #f)
                               ((not ((car rest))) #t)
                               (else (loop (cdr rest)))))))
          (if refused
              #f
              (begin
                (*buffer-list*
                 (let loop ((rest (*buffer-list*)))
                   (cond ((null? rest) '())
                         ((eq? (cdar rest) buffer) (loop (cdr rest)))
                         (else (cons (car rest) (loop (cdr rest)))))))
                ;; a window may not be left showing a buffer that is gone
                (let ((replacement #f))
                  (let loop ((windows (frame-windows-with buffer)))
                    (unless (null? windows)
                      ;; avoid the buffer being killed: while it is
                      ;; still in the list, `other-buffer' could hand it
                      ;; back, and a window would be left showing a buffer
                      ;; that is gone
                      (unless replacement
                        (set! replacement (other-buffer buffer)))
                      (let ((window (car windows)))
                        (set!window-buffer window replacement)
                        (set!window-top-line window 0))
                      (loop (cdr windows)))))
                (weak-table-delete! buffer-slots-table buffer)
                (run-buffer-list-update-hook!)
                name)))))

    (define (frame-windows-with buffer)
      ;; The current frame's windows showing BUFFER: `window.c''s
      ;; `replace-buffer-in-windows' walks the same thing. This project has
      ;; one window per frame for now, so it is a list of none or one.
      ;;--------------------------------------------------------------
      (let ((window (and (*current-frame*)
                         (selected-window))))
        (if (and window (eq? (window-buffer window) buffer))
            (list window)
            '())))

    ;;----------------------------------------------------------------
    ;; The slots a buffer has besides its text
    ;;
    ;; Emacs keeps `keymap', `local_var_alist' and the buffer-local
    ;; variables in the buffer struct. They are in a weak table here -
    ;; weak because a table holding its keys strongly would keep every
    ;; killed buffer alive - and the table is per buffer rather than one
    ;; slot per fact so that a buffer-local variable can be any name a
    ;; ported Elisp sets, which is what `setq-local' needs.

    (define buffer-slots-table
      ;; The table of side slots. One table rather than a slot per fact,
      ;; so that a buffer-local variable can be any name a ported Elisp
      ;; sets, which is what `setq-local' needs.
      ;;--------------------------------------------------------------
      (new-weak-table))

    (define (buffer-local-value buffer key . args)
      ;; The buffer-local value of KEY in BUFFER, or the optional default:
      ;; GNU Emacs's `buffer-local-value', which reads a named
      ;; buffer-local variable. A key is any value, compared by identity -
      ;; a symbol for a ported Elisp variable, and this library's own
      ;; slots below are keys of its own.
      ;;--------------------------------------------------------------
      (let* ((slots (weak-table-ref buffer-slots-table buffer '()))
             (entry (assq key slots)))
        (cond (entry (cdr entry))
              ((pair? args) (car args))
              (else #f))))

    (define (set-buffer-local-value! buffer key value)
      ;; Make KEY locally VALUE in BUFFER: GNU Emacs's `setq-local' and the
      ;; `make-local-variable' beneath it.
      ;;--------------------------------------------------------------
      (let ((slots (weak-table-ref buffer-slots-table buffer '())))
        (weak-table-set! buffer-slots-table buffer
                         (cons (cons key value)
                               (let loop ((rest slots))
                                 (cond ((null? rest) '())
                                       ((eq? (caar rest) key) (loop (cdr rest)))
                                       (else (cons (car rest)
                                                   (loop (cdr rest))))))))
        value))

    (define (buffer-local-keymap buffer)
      ;; The buffer's own keymap, or false: GNU Emacs's `current-local-map'
      ;; for a buffer that is not current, and its `BVAR (buf, keymap)'
      ;; underneath. `(schemacs editor keyboard)' looks a key sequence up
      ;; in this map first and the global map after it.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'buffer-local-keymap #f))

    (define (set!buffer-local-keymap buffer keymap)
      ;; Give BUFFER its own keymap: GNU Emacs's `use-local-map'.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! buffer 'buffer-local-keymap keymap))

    (define (buffer-default-directory buffer . args)
      ;; The directory BUFFER's relative file names are relative to: GNU
      ;; Emacs's `default-directory', which is a buffer-local variable, so
      ;; it is a slot here. The optional argument is the buffer, and
      ;; without one the current buffer is asked.
      ;;
      ;; `(schemacs editor files)''s `DEFAULT-DIRECTORY' still answers from
      ;; the *frame*'s file path rather than from the buffer, which is a
      ;; deviation: two windows showing two files have one answer between
      ;; them. It moves here when the file commands are next worked on.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (buffer-local-value buffer 'default-directory #f)))

    (define (set!buffer-default-directory buffer directory)
      ;; What `(setq default-directory DIRECTORY)' does in a buffer.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! buffer 'default-directory directory))

    ;;----------------------------------------------------------------
    ;; The flags and the file name, which are the engine's
    ;;
    ;; Emacs has these as `buffer.c' primitives over fields of the struct;
    ;; the fields are the engine's here, so these are the names Emacs's
    ;; Elisp calls - `buffer-modified-p' - over the engine's accessors,
    ;; which are spelled the way the rest of this tree spells them.

    (define (buffer-modified-p buffer)
      ;; Whether the buffer has been changed since it was saved: GNU Emacs's
      ;; `buffer-modified-p'.
      ;;--------------------------------------------------------------
      (text-editor-modified? buffer))

    (define (set-buffer-modified-p buffer flag)
      ;; Set that flag: GNU Emacs's `set-buffer-modified-p'. Emacs takes
      ;; the buffer first and the flag second, and so does this.
      ;;--------------------------------------------------------------
      (text-editor-set-modified! buffer flag))

    (define (buffer-read-only? buffer)
      ;; Whether the buffer refuses changes: GNU Emacs's `buffer-read-only'
      ;; *variable*, which is a field rather than a function there; the `?'
      ;; is this tree's spelling for a predicate.
      ;;--------------------------------------------------------------
      (text-editor-read-only? buffer))

    (define (set!buffer-read-only buffer flag)
      ;; What `(setq buffer-read-only FLAG)' does in a buffer. Emacs's
      ;; `read-only-mode' is the command over it, and turns the flag on and
      ;; off; this is the flag itself.
      ;;--------------------------------------------------------------
      (text-editor-set-read-only! buffer flag))

    (define (buffer-file-name buffer)
      ;; The file BUFFER visits, or false: GNU Emacs's `buffer-file-name'.
      ;;--------------------------------------------------------------
      (text-editor-file-name buffer))

    (define (set!buffer-file-name buffer path)
      ;; Make BUFFER visit PATH: GNU Emacs's `set-visited-file-name' ends
      ;; here. Emacs also renames the buffer after the file and marks it
      ;; unmodified when the name is set from a file; that is
      ;; `set-visited-file-name''s job, above this.
      ;;--------------------------------------------------------------
      (set!text-editor-file-name buffer path))

    ))