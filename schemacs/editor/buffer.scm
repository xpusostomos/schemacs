(define-library (schemacs editor buffer)
  ;; This library mirrors GNU Emacs's `buffer.c': the *buffers* as a
  ;; collection - which ones exist, what they are called, which one is
  ;; current, making one and killing one - and the slots that belong to a
  ;; buffer without being part of its text.
  ;;
  ;; **The record is here**, and that is the one thing this library has
  ;; that it did not: `buffer.h`'s `struct buffer`, with `BUF_PT`,
  ;; `BUF_BEG`, `BUF_Z`, `BUF_MARKERS` and the rest of that header's
  ;; macros over it. It was `(schemacs editor engine)`'s, because the
  ;; engine was BELOW this library and the record is what everything
  ;; touches; the engine is built on this library now, so `buffer.c`'s own
  ;; functions work on the record rather than through a second set of
  ;; accessors. What comes back the other way arrives through the seams
  ;; beside them - see the notes on those.
  ;;
  ;; What it does not mirror, because another library already does:
  ;;
  ;;  * the text, the gap and the edits - `buffer.c`'s own text is in
  ;;    `insdel.c`, which is `(schemacs editor engine)`. A buffer here *is*
  ;;    a `<buffer>': there is no wrapper record, exactly as there is
  ;;    no second struct in Emacs. `BUFFERP' (`buffer.h:757') is `bufferp'.
  ;;  * the markers and the undo list - `marker.c' and the undo half of
  ;;    `buffer.c', also the engine's. The record holds the marker chain
  ;;    and the undo list; the operations on them are the engine's.
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
  ;;    one, so the slots live in a weak table keyed by the buffer -
  ;;    `MAKE-WEAK-KEY-HASH-TABLE' - weak because a table that held its
  ;;    keys strongly would keep every killed buffer alive
  ;;    forever. They move into the record when the local-variable
  ;;    machinery is next opened; the record itself is here now.
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
    ;; `getcwd' is what `default-directory' answers with when there is no
    ;; buffer and no frame to ask - Emacs's global value of the variable.
    ;; `sort' is what `overlays-at' orders by priority with. It is in
    ;; `(guile)' as well as `(srfi 1)', and this library already reaches
    ;; into `(guile)' for `getcwd'.
    ;; The buffer's side tables - its slots and its overlays - are held
    ;; weakly, keyed by the buffer: see the note in the header. Guile's own
    ;; weak table, a key held weakly and a value held strongly.
    (only (guile)
          caddr getcwd sort
          make-weak-key-hash-table hashq-ref hashq-set! hashq-remove!)
    (only (scheme write) display)
    ;; The buffer's text - GNU Emacs's `struct buffer_text', the `text'
    ;; field of the record below. `NEW-BUFFER-TEXT' is what
    ;; `allocate_buffer' allocates, and the other three are the `BEG' and
    ;; `Z' macros `buffer-beg' and `buffer-z' are.
    (only (schemacs editor buffer-text)
          *gap-bytes-min*
          new-buffer-text  buffer-text-base  buffer-text-z
          buffer-text-ref
          buffer-text-modiff  buffer-text-chars-modiff
          set!buffer-text-modiff  set!buffer-text-chars-modiff)
    (scheme case-lambda))
  (cond-expand
   ;; The record's pretty-printer below is Guile's.
   (guile-3
    (import (only (srfi srfi-9 gnu) set-record-type-printer!))
    )
   (else)
   )
  (export
   *buffer-list*
   *buffer-list-update-hook*
   *current-buffer*
   ;; The seams - see the notes on them below. `frame.sld' installs the
   ;; two window ones and the marker library will install the three
   ;; marker ones, each as it loads.
   *current-editor-function*
   *replace-buffer-in-windows-function*
   *build-marker-function*
   *marker-position-function*
   *set-marker-function*
   *set-marker-insertion-type-function*
   *get-text-property-function*
   *run-hooks-function*
   *make-marker-function*
   *del-range-function*
   *buffer-visited-file-modtime-function*
   ;; The buffer record - `buffer.h`'s struct, which `buffer.c` owns. Its
   ;; accessors are that header's macros: `BUF_PT`, `BUF_BEG`, `BUF_Z`,
   ;; `BUF_MARKERS`, `BVAR (b, ...)`. Everything that reads a buffer goes
   ;; through one of these, and they are exported for that reason.
   allocate-buffer  bufferp  show-text-editor
   text-editor-text  set!text-editor-text
   buffer-pt  set!buffer-pt
   %text-editor-newline-cache  set!%text-editor-newline-cache
   text-editor-text-props  set!text-editor-text-props
   text-editor-undo-list  set!text-editor-undo-list
   text-editor-save-modiff  set!text-editor-save-modiff
   %buffer-modtime  set!%buffer-modtime
   %buffer-modtime-size  set!%buffer-modtime-size
   %unknown-modtime-nsecs  %nonexistent-modtime-nsecs
   text-editor-cache-long-scans  set!text-editor-cache-long-scans
   ;; `text-editor-deactivate-mark' and its setter are gone: `deactivate-mark'
   ;; is a buffer-local *variable* (`keyboard.c:14030'), keyed by the symbol,
   ;; and read and written through `buffer-local-value' /
   ;; `set-buffer-local-value!' - see the note where the field used to be.
   %mark-marker  set!%mark-marker
   buffer-markers  set!buffer-markers
   text-editor-read-only-flag  set!text-editor-read-only-flag
   text-editor-buffer-name  set!text-editor-buffer-name
   text-editor-file-name  set!text-editor-file-name
   buffer-beg  buffer-z
   ;; `FETCH_CHAR` (`buffer.h`), which has no Lisp name - see the note
   ;; where it is defined. It came here from `engine.scm` 2026-10-13.
   fetch-char
   ;; `SET_PT` (`buffer.h:170`), the write to the point slot, clipped as
   ;; `Fgoto_char` (`editfns.c:233`) clips - see the note where it is
   ;; defined. `goto-char` is the Lisp door onto it; this is the write
   ;; below, and every caller names its buffer. It came here from
   ;; `engine.scm` 2026-10-13, where it was `text-editor-set-cursor`.
   set-point
   ;; `buffer-modified-p' and `buffer-read-only' answer with these: GNU
   ;; Emacs's `buffer-modified-tick', `buffer-modified-p' - which is the
   ;; comparison `SAVE_MODIFF < MODIFF' and not a flag - and the
   ;; `buffer-read-only' variable.
   buffer-modified-tick  buffer-chars-modified-tick
   buffer-modified-p  set-buffer-modified-p
   buffer-read-only?  set!buffer-read-only  barf-if-buffer-read-only
   validate-region
   %text-editor-incr-modiff!
   *kill-buffer-query-functions*
   *scratch-buffer-name*
   buffer-default-directory
   default-directory
   *change-major-mode-hook*
   *inhibit-read-only*
   ;; the whole list, which the redisplay asks before it takes its
   ;; no-properties shortcut
   buffer-overlays
   delete-overlay
   make-overlay
   move-overlay
   next-overlay-change
   overlay-buffer
   overlay-end
   overlay-get
   overlay-properties
   overlay-priority
   overlay-put
   overlay-start
   overlayp
   overlays-at
   overlays-in
   previous-overlay-change
   kill-all-local-variables
   major-mode
   mode-name
   set!major-mode
   set!mode-name
   buffer-file-name
   buffer-list
   buffer-list-alist
   buffer-live-p
   buffer-local-keymap
   current-local-map
   use-local-map
   buffer-local-value
   ;; `cache-long-scans' (`buffer.c:5786'), the buffer-local the
   ;; line-break cache hangs on
   cache-long-scans  set!cache-long-scans
   buffer-truncate-lines
   buffer-word-wrap
   buffer-modified-p
   erase-buffer
   *transient-mark-mode*
   buffer-cursor-in-non-selected-windows
   buffer-cursor-type
   buffer-name
   mark-active set!mark-active transient-mark-mode
   set!buffer-cursor-in-non-selected-windows
   set!buffer-cursor-type
   set!buffer-truncate-lines
   set!buffer-word-wrap
   buffer-auto-hscroll-mode
   set!buffer-auto-hscroll-mode
   buffer-overwrite-mode
   set!buffer-overwrite-mode
   buffer-fill-column
   set!buffer-fill-column
   buffer-tab-width
   set!buffer-tab-width
   buffer-hscroll-margin
   set!buffer-hscroll-margin
   buffer-hscroll-step
   set!buffer-hscroll-step
   buffer-read-only?
   bufferp
   bury-buffer
   current-buffer
   get-buffer
   *case-fold-search*
   *show-trailing-whitespace*
   find-buffer-visiting
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
   restore-buffer-modified-p
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
    (define *case-fold-search*
      ;; GNU Emacs's `case-fold-search' (buffer.c:6009): "Non-nil if
      ;; a case-insensitive search should be done." A nil value makes
      ;; every search and every case-sensitive-predicate case
      ;; sensitive; t makes them insensitive. It is buffer-local in
      ;; Emacs; the buffer-local machinery is this tree's parameters
      ;; until the value is the buffer's - which is what the other
      ;; defvars here are too.
      ;;--------------------------------------------------------------
      (make-parameter #t))
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
    (define (buffer-live-p thing)
      ;; Whether THING is a buffer that still exists: GNU Emacs's
      ;; `buffer-live-p'. A buffer is live while it is in the list.
      ;;--------------------------------------------------------------
      (and (bufferp thing)
           (let loop ((rest (*buffer-list*)))
             (cond ((null? rest) #f)
                   ((eq? (cdar rest) thing) #t)
                   (else (loop (cdr rest)))))))
    ;;----------------------------------------------------------------
    ;; The current buffer, and the two seams to the window code
    ;;------------------------------------------------------------------
    (define *current-buffer* (make-parameter #f))
    ;; ^ The buffer commands act on: GNU Emacs's `current_buffer', the C
    ;; global that `set-buffer' writes and that the *window code* writes
    ;; too. False means "no choice has been made", and `CURRENT-BUFFER'
    ;; answers the window's for it.
    ;;
    ;; **It is defined here, and it used to be defined in `frame.sld'.**
    ;; Emacs declares it in `buffer.c' and `Fselect_window' writes it -
    ;;
    ;;   Fset_buffer (w->contents);   /* `window.c:534' */
    ;;
    ;; - so both libraries have to reach it, and a Scheme import cannot be
    ;; circular. It sat with the frame state because the frame is the
    ;; lower library *today*; it is here now because this library defines
    ;; the buffer record, so the frame's window code is the one built on
    ;; it. `frame.sld' imports it and re-exports it, so every library that
    ;; asks the frame for it still finds it, and `select-window' still
    ;; writes it.
    (define *current-editor-function*
      ;; How the window's buffer is found when no choice has been made:
      ;; the half of `current_buffer' that the *window code* maintains.
      ;; `frame.sld' installs its `current-editor' here as it loads.
      ;;
      ;; A seam and not a call, for the reason above: this library cannot
      ;; import `frame.sld', which is built on it. It is the arrangement
      ;; `*read-buffer-to-switch*' (`window.sld') and
      ;; `*text-property-offset-function*' already use.
      ;;--------------------------------------------------------------
      (make-parameter (lambda () #f)))
    (define *replace-buffer-in-windows-function*
      ;; GNU Emacs's `replace_buffer_in_windows' (`window.c:3722'), which
      ;; `Fkill_buffer' calls (`buffer.c:2032') to put another buffer into
      ;; every window that was showing the one being killed. It is the
      ;; window code's function, so it arrives through this seam, which
      ;; `frame.sld' installs.
      ;;--------------------------------------------------------------
      (make-parameter (lambda (buffer) #f)))
    ;; `marker.scm`'s operations an overlay and the buffer's own mark
    ;; need. An overlay's ends are markers, so `make-overlay` has to make
    ;; them, point them, and set their insertion types; and
    ;; `allocate_buffer` makes the buffer's mark with the constructor
    ;; (`buffer.c:672`). `marker.scm` is built on *this* library - a
    ;; marker is added to a buffer's chain, and that chain is a field of
    ;; the record below - so it cannot be imported here, and these arrive
    ;; the way the two above do.
    ;;
    ;; The shapes are Emacs's own: `build-marker` takes the buffer and a
    ;; position because that is what the C passes when it has a buffer in
    ;; hand (`alloc.c:3801`), and `set-marker` takes one because its
    ;; BUFFER argument is what says which buffer a marker is being put
    ;; into (`marker.c:607`).
    (define *make-marker-function*      (make-parameter (lambda args #f)))
    (define *build-marker-function*     (make-parameter (lambda args #f)))
    (define *marker-position-function*  (make-parameter (lambda (marker) #f)))
    (define *set-marker-function*       (make-parameter (lambda args #f)))
    (define *set-marker-insertion-type-function*
      (make-parameter (lambda args #f)))
    (define *get-text-property-function*
      ;; GNU Emacs's `get-text-property', which `barf-if-buffer-read-only`
      ;; below asks about the `inhibit-read-only` property. The interval
      ;; tree's lookups are `intervals.scm`'s and that library is above
      ;; this one, so the call arrives through a seam - and a cold one:
      ;; the read-only test only reaches it when the buffer is read-only
      ;; *and* `inhibit-read-only' is nil. `textprop.scm` installs it.
      ;;--------------------------------------------------------------
      (make-parameter #f))
    (define *del-range-function*
      ;; GNU Emacs's `del_range' (`insdel.c`), which is what
      ;; `Ferase_buffer' calls to empty a buffer (`buffer.c:2472'). It is
      ;; `insdel.c`'s and insdel.c sits ABOVE this library - the whole
      ;; point of the split - so the one call this library makes back into
      ;; it arrives through a seam.
      ;;
      ;; It takes two positions, one-based, and deletes between them.
      ;;--------------------------------------------------------------
      (make-parameter (lambda (from to) #f)))
    (define *run-hooks-function*
      ;; How a hook is run from this library. `run-hooks' is `subr.el''s,
      ;; and only `kill-all-local-variables' below wants it - the one line
      ;; of this library that runs `change-major-mode-hook'.
      ;;
      ;; **Why it is a seam and not an import.** `(schemacs editor subr)'
      ;; reaches the engine the long way round - `subr.sld' imports
      ;; `fns.sld', which imports `intervals.sld', which imports the
      ;; engine - so importing `subr' here makes this library depend on
      ;; the engine, and the engine has to be built on *this* library,
      ;; because the buffer record is here. That is the cycle this seam
      ;; cuts, and it is the reason the record could not move here
      ;; before. `subr.sld' installs its `run-hooks' as it loads, which
      ;; is after this library once the record is here.
      ;;
      ;; **Transient.** Until the record does move, the engine is still
      ;; below this library, so `subr.sld' still loads *before* it and
      ;; cannot install this - `frame.sld' stands in, as it does for the
      ;; three marker seams above, and for the same reason.
      ;;--------------------------------------------------------------
      (make-parameter (lambda (hooks) #f)))
    (define *buffer-visited-file-modtime-function*
      ;; GNU Emacs's `buffer_visited_file_modtime' (`fileio.c:6157'),
      ;; which `record_first_change' (`undo.c:210') calls to write the
      ;; visited file's modification time into the `(t . TIME)' mark of
      ;; the last save.
      ;;
      ;; **Why it is a seam and not an import.** It is declared here, on
      ;; the record it reads `modtime' and `modtime_size' from, because
      ;; both libraries that need it are above this one and `fileio.scm'
      ;; cannot import the engine: fileio.c is up where files are, and
      ;; the engine is insdel.c and does not know what a file is. The
      ;; engine reads this; `fileio.scm' installs it as it loads.
      ;;
      ;; The default answers 0, "no time is known", and that is not a
      ;; placeholder: it is what `buffer_visited_file_modtime' answers
      ;; for a buffer whose `modtime' is `UNKNOWN_MODTIME_NSECS', which
      ;; is every buffer that visits no file - so a unit test that loads
      ;; the engine alone records `(t . 0)', which is Emacs's own answer
      ;; there.
      ;;--------------------------------------------------------------
      (make-parameter (lambda (buffer) 0)))
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
      (or (*current-buffer*) ((*current-editor-function*))))
    (define (set-buffer buffer)
      ;; Make BUFFER the current buffer: GNU Emacs's `set-buffer'. It does
      ;; *not* put the buffer in a window - "if you want to change which
      ;; buffer is displayed in the selected window, use
      ;; `switch-to-buffer'" - and it does not reorder the list.
      ;;
      ;; **Setting it to the buffer that is *already* current does
      ;; nothing**, which is `set_buffer_internal_1`'s first two lines
      ;; (`buffer.c:2327`):
      ;;
      ;;     if (current_buffer == b)
      ;;       return;
      ;;
      ;; That early return is load-bearing here in a way it is not in the
      ;; C, because this tree's current buffer has *two* levels and Emacs
      ;; has one: `*current-buffer*` is #f when no choice has been made
      ;; and the frame's window answers instead, and a buffer is put there
      ;; only when `set-buffer` really means to change it. Writing the
      ;; buffer that is current anyway would turn "ask the frame" into
      ;; "this buffer, pinned", and it would stay pinned for the rest of
      ;; the session - every later command acting on it while the screen
      ;; showed another, `C-x b` and `C-x o` looking like they did
      ;; nothing.
      ;;
      ;; It showed up three functions away, in `save-excursion`: the C's
      ;; `save_excursion_restore` is `Fset_buffer` and this port's is
      ;; `set-buffer`, so *any* `save-excursion` used to pin - which is
      ;; every function in `simple.el` that wraps a body in one. The C
      ;; has the same line and gets away with it because a no-op there is
      ;; a no-op; the pinning was this tree's alone.
      ;;--------------------------------------------------------------
      (define (buffer-or-name thing)
        (cond ((bufferp thing) thing)
              ((string? thing) (get-buffer thing))
              (else #f)))
      (let ((buffer (buffer-or-name buffer)))
        (unless buffer
          (error "No such buffer" buffer))
        (unless (eq? buffer (current-buffer))
          (*current-buffer* buffer))
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
    (define *show-trailing-whitespace*
      ;; GNU Emacs's `show-trailing-whitespace' (xdisp.c:38640, a
      ;; DEFVAR buffer-local): "Non-nil means highlight trailing
      ;; whitespace. The face used for trailing whitespace is
      ;; `trailing-whitespace'." The highlighting itself is the
      ;; redisplay's, which does not port yet; what is read so far is
      ;; `kill-line''s question - whether trailing whitespace counts
      ;; as visible text - which is why it exists. Nil, as the C's
      ;; default is. Buffer-local in Emacs; the buffer-local spelling
      ;; here is a parameter until the store is per-buffer.
      ;;--------------------------------------------------------------
      (make-parameter #f))
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
    (define (buffer-cursor-type buffer)
      ;; The cursor BUFFER wants: GNU Emacs's `cursor-type', which
      ;; `buffer.c' declares as a per-buffer variable (so a buffer can
      ;; turn its cursor off, or ask for a bar, without touching any
      ;; other buffer). Emacs reads it as `BVAR (buf, cursor_type)' from
      ;; `get_window_cursor_type', and the values are the ones its
      ;; docstring lists:
      ;;
      ;;   t               use the cursor specified for the frame
      ;;   nil             don't display a cursor
      ;;   box             a filled box cursor
      ;;   hollow          a hollow box cursor
      ;;   bar             a vertical bar cursor, default width
      ;;   (bar . WIDTH)   a vertical bar cursor of WIDTH
      ;;   hbar            a horizontal bar cursor, default height
      ;;   (hbar . HEIGHT) a horizontal bar cursor of HEIGHT
      ;;   anything else   a hollow box cursor
      ;;
      ;; `(schemacs editor xdisp)' is what interprets them
      ;; (`get-specified-cursor-type'), as in Emacs.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'cursor-type #t))
    (define (set!buffer-cursor-type buffer value)
      (set-buffer-local-value! buffer 'cursor-type value))
    (define (cache-long-scans . args)
      ;; GNU Emacs's `cache-long-scans' (`buffer.c:5786'): "Non-nil means
      ;; that Emacs should use caches in attempt to speedup buffer
      ;; scans." A per-buffer variable, true by default, and the switch
      ;; the line-break cache hangs on - `find_newline' consults it
      ;; before making one (`search.c:618'). It is read through the
      ;; engine, because that is where it is consulted and the engine is
      ;; below this library.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (text-editor-cache-long-scans buffer)))
    (define (set!cache-long-scans buffer value)
      ;; Emacs's `setq-local' of it; the engine's setter is the same one
      ;; the buffer's own field uses.
      ;;--------------------------------------------------------------
      (set!text-editor-cache-long-scans buffer value))
    (define (buffer-truncate-lines buffer)
      ;; Whether BUFFER's long lines are cut off at the window edge
      ;; instead of continuing onto the next screen row: GNU Emacs's
      ;; `truncate-lines', which `buffer.c' declares as a per-buffer
      ;; variable and which is nil by default - so a long line *wraps*,
      ;; and `\' is what a continued row ends with.
      ;;
      ;; The full rule is `init_iterator' (`xdisp.c'), and
      ;; `truncate-partial-width-windows' overrides it for a window that
      ;; is not the full width of the frame:
      ;;
      ;;   | Non-nil means do not display continuation lines.  Instead,
      ;;   | give each line of text just one screen line.
      ;;
      ;; A minibuffer sets it to nil, and `visual-line-mode' wants it nil
      ;; too (it sets `word-wrap' instead).
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'truncate-lines #f))
    (define (set!buffer-truncate-lines buffer value)
      (set-buffer-local-value! buffer 'truncate-lines value))
    (define (buffer-word-wrap buffer)
      ;; Whether BUFFER's continuation lines break at a space near the
      ;; window's right edge rather than at the edge itself: GNU Emacs's
      ;; `word-wrap', another of `buffer.c''s, nil by default.
      ;;
      ;;   | When word-wrapping is on, continuation lines are wrapped at
      ;;   | the space or tab character nearest to the right window edge.
      ;;   | If nil, continuation lines are wrapped at the right screen
      ;;   | edge.
      ;;
      ;; It has no effect while lines are truncated, and
      ;; `visual-line-mode' is what usually turns it on.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'word-wrap #f))
    (define (set!buffer-word-wrap buffer value)
      (set-buffer-local-value! buffer 'word-wrap value))
    (define (buffer-auto-hscroll-mode buffer)
      ;; Whether a window whose point leaves the window's horizontal view
      ;; scrolls itself just enough to bring it back: GNU Emacs's
      ;; `auto-hscroll-mode', which `xdisp.c' declares as a buffer-local
      ;; DEFVAR_LISP and which is t by default - so by default Emacs
      ;; hscrolls automatically. The value `current-line' means only the
      ;; line point is on is scrolled (`hscrolling_current_line_p'), and
      ;; that mode is not ported: `hscroll-window!' acts for the whole
      ;; window whatever the value, and only nil turns the machinery off.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'auto-hscroll-mode #t))
    (define (set!buffer-auto-hscroll-mode buffer value)
      (set-buffer-local-value! buffer 'auto-hscroll-mode value))
          (define (buffer-tab-width buffer)
      ;; How wide a tab is in columns: GNU Emacs's `tab-width', a
      ;; buffer-local DEFVAR_PER_BUFFER whose default is 8
      ;; (`buffer.c:4880'), which `indent-to' and the display both read.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'tab-width 8))
          (define (set!buffer-tab-width buffer value)
      (set-buffer-local-value! buffer 'tab-width value))
          (define (buffer-overwrite-mode buffer)
      ;; Which overwrite mode this buffer is in: GNU Emacs's
      ;; `overwrite-mode', a buffer-local DEFVAR_PER_BUFFER of `cmds.c'
      ;; whose default is nil (`buffer.c:5480' - `DEFVAR_PER_BUFFER
      ;; ("overwrite-mode", overwrite_mode, Qoverwrite_mode, ...)').
      ;;
      ;; It is nil, or one of two symbols - `overwrite-mode-textual' and
      ;; `overwrite-mode-binary' - and the value *is* the mode: there is
      ;; no separate on/off flag, which is why `overwrite-mode' being
      ;; non-nil is the same statement as "overwrite mode is on" and why
      ;; `binary-overwrite-mode' is a second command over one variable
      ;; rather than a second mode.
      ;;
      ;; `internal-self-insert' reads it on every character typed, and
      ;; the mode line reads it for the ` Ovwrt' lighter.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'overwrite-mode #f))
    (define (set!buffer-overwrite-mode buffer value)
      (set-buffer-local-value! buffer 'overwrite-mode value))
    (define (buffer-fill-column buffer)
      ;; The column `fill-paragraph' and auto fill fill to: GNU Emacs's
      ;; `fill-column', a buffer-local DEFVAR_PER_BUFFER whose default
      ;; is 70 (`buffer.c:4898').
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'fill-column 70))
    (define (set!buffer-fill-column buffer value)
      (set-buffer-local-value! buffer 'fill-column value))
    (define (buffer-hscroll-margin buffer)
      ;; How close to the window's left or right edge point may sit before
      ;; auto hscrolling starts scrolling: GNU Emacs's `hscroll-margin',
      ;; a buffer-local DEFVAR_INT of `xdisp.c' whose default is 5.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'hscroll-margin 5))
    (define (set!buffer-hscroll-margin buffer value)
      (set-buffer-local-value! buffer 'hscroll-margin value))
    (define (buffer-hscroll-step buffer)
      ;; How far auto hscrolling moves the view when it scrolls: GNU
      ;; Emacs's `hscroll-step', a buffer-local DEFVAR_* of `xdisp.c'
      ;; whose default is 0, which does not mean no scrolling - it means
      ;; put point at the window's horizontal centre
      ;; (`hscroll_window_tree', `xdisp.c:16851-16860': when the step is
      ;; neither a float nor a positive integer,
      ;; `hscroll = max (0, it.current_x - text_area_width / 2)'). An
      ;; integer N means scroll in columns, a float a fraction of the
      ;; window's width; those two are not ported, and any non-zero value
      ;; acts as 0 does here.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'hscroll-step 0))
    (define (set!buffer-hscroll-step buffer value)
      (set-buffer-local-value! buffer 'hscroll-step value))
    (define (buffer-cursor-in-non-selected-windows buffer)
      ;; What to draw in a window that is not selected, when this buffer
      ;; is in it: GNU Emacs's `cursor-in-non-selected-windows', another
      ;; of `buffer.c''s. `t' means the usual cursor type modified - a
      ;; filled box becomes hollow, a bar a narrower bar - and nil means
      ;; no cursor at all; any other value is a cursor type of its own.
      ;;--------------------------------------------------------------
      (buffer-local-value buffer 'cursor-in-non-selected-windows #t))
    (define (set!buffer-cursor-in-non-selected-windows buffer value)
      (set-buffer-local-value! buffer 'cursor-in-non-selected-windows value))
    (define (mark-active)
      ;; Whether the mark is active: GNU Emacs's `mark-active', which
      ;; `buffer.c' declares as a per-buffer variable - each buffer has
      ;; its own, so switching buffers does not carry the region with it.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'mark-active #f))
    (define (set!mark-active flag)
      (set-buffer-local-value! (current-buffer) 'mark-active (and flag #t)))
    (define (buffer-name . rest)
      ;; The name of BUFFER: GNU Emacs's `buffer-name' (buffer.c:1302):
      ;; "Return the name of BUFFER, as a string. BUFFER defaults to the
      ;; current buffer. Return nil if BUFFER has been killed."
      ;;
      ;; BUFFER is optional - the C's DEFUN is `0, 1, 0' - and `(buffer-name)'
      ;; is how the .el code this tree ports usually spells it. A required
      ;; BUFFER answered "Wrong number of arguments" instead.
      ;;
      ;; A killed buffer's name is nil, because `kill-buffer' clears it -
      ;; that is what the C answers nil *for*, and it is the test the
      ;; Dired buffer registry makes. Answering `*scratch*' for it, which
      ;; is what this did, made a killed buffer look alive and left it in
      ;; the registry for ever.
      ;;--------------------------------------------------------------
      (text-editor-buffer-name (or (and (pair? rest) (car rest))
                                   (current-buffer))))
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
      (let ((buffer (allocate-buffer)))
        (register-buffer! buffer (generate-new-buffer-name name))
        (init-buffer! buffer)
        buffer))
    (define (get-buffer-create name)
      ;; The buffer called NAME, made if there is none: GNU Emacs's
      ;; `get-buffer-create'. This is the way to reach a buffer by name -
      ;; `*Completions*', `*Messages*' - and get the same one every time.
      ;;--------------------------------------------------------------
      (or (get-buffer name)
          (let ((buffer (allocate-buffer)))
            (register-buffer! buffer name)
            (init-buffer! buffer)
            buffer)))
    (define (find-buffer-visiting filename)
      ;; The buffer whose file FILENAME is, or #f: GNU Emacs's
      ;; `find-buffer-visiting' (`buffer.c''s `Ffind_buffer_visiting'
      ;; through `get-file-buffer'), which `write-file' and
      ;; `set-visited-file-name' ask before they re-home a buffer - Emacs
      ;; warns when another buffer would be visiting the same file.
      ;;--------------------------------------------------------------
      (let scan ((buffers (buffer-list)))
        (cond ((null? buffers) #f)
              ((and (buffer-file-name (car buffers))
                    (string=? (buffer-file-name (car buffers)) filename))
               (car buffers))
              (else (scan (cdr buffers))))))
    (define (init-buffer! buffer)
      ;; Give a buffer just made the slots and flags Emacs gives a new
      ;; buffer: read-write, unmodified, with no file and an empty local
      ;; keymap. (Emacs also runs `buffer-list-update-hook' and gives the
      ;; buffer a major mode, a syntax table, buffer-local defaults and a
      ;; marker for point; those wait for the features that need them.)
      ;;--------------------------------------------------------------
      ;; Not `set-buffer-modified-p': the modified state of a buffer just
      ;; made is not set at all - `allocate_buffer' writes the counters
      ;; themselves, `BUF_MODIFF (b) = 1' and `BUF_SAVE_MODIFF (b) = 1'
      ;; (`buffer.c:630-631'), and `1 < 1' is false. `NEW-TEXT-EDITOR'
      ;; writes the same two, which is where those lines live here.
      (set!buffer-read-only buffer #f)
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
              ;; "Make this buffer not be current. Exit if it is the sole
              ;; visible buffer." - the C's
              ;;
              ;;   if (b == current_buffer)
              ;;     { tem = Fother_buffer (buffer, Qnil, Qnil);
              ;;       Fset_buffer (tem);
              ;;       if (b == current_buffer) return Qnil; }
              ;;
              ;; (buffer.c:2046-2052), and it *gives up* when there is
              ;; nothing else to show - the buffer is left alive and the
              ;; answer is nil. Without it the killed buffer stayed
              ;; current, so a *second* `C-x k' read its name - which the
              ;; kill clears, below - and `(string-append "Killed " #f)'
              ;; answered with `wrong type (expecting string) #f'. That is
              ;; why it only happened sometimes: it takes killing the
              ;; current buffer twice.
              (let ((switched
                     (if (eq? (current-buffer) buffer)
                         (begin
                           (set-buffer (other-buffer buffer))
                           (not (eq? (current-buffer) buffer)))
                         #t)))
               (if (not switched)
                   #f
                   (begin
                (*buffer-list*
                 (let loop ((rest (*buffer-list*)))
                   (cond ((null? rest) '())
                         ((eq? (cdar rest) buffer) (loop (cdr rest)))
                         (else (cons (car rest) (loop (cdr rest)))))))
                ;; A window may not be left showing a buffer that is
                ;; gone: `replace_buffer_in_windows' (`window.c:3722'),
                ;; which the C calls here for the same reason - before the
                ;; buffer leaves the list, so `other_buffer' cannot hand
                ;; the dying buffer back. It is the window code's
                ;; function, so it arrives through the seam above.
                ((*replace-buffer-in-windows-function*) buffer)
                (hashq-remove! buffer-slots-table buffer)
                ;; Emacs sets the killed buffer's `name' to nil and keeps
                ;; the old one in `last_name'. That nil *is* why
                ;; `buffer-name' answers nil for a killed buffer - the
                ;; test in `dired-buffers-for-dir' and
                ;; `dired-find-buffer-nocreate' is exactly it. The
                ;; `last-name' half is `buffer-last-name', not ported.
                (set!buffer-name buffer #f)
                (run-buffer-list-update-hook!)
                name)))))))
    ;;----------------------------------------------------------------
    ;; The slots a buffer has besides its text
    ;;
    ;; Emacs keeps `keymap', `local_var_alist' and the buffer-local
    ;; variables in the buffer struct. They are in a weak table here -
    ;; weak because a table holding its keys strongly would keep every
    ;; killed buffer alive - and the table is per buffer rather than one
    ;; slot per fact so that a buffer-local variable can be any name a
    ;; ported Elisp sets, which is what `setq-local' needs.
    ;;----------------------------------------------------------------
    ;; Overlays
    ;;
    ;; GNU Emacs's `buffer.c''s other half. An overlay is a *range of the
    ;; buffer* with properties on it, as against a text property, which is
    ;; on the characters: an overlay is an object you make, move and
    ;; delete; its two ends are markers, so it follows the text as it is
    ;; edited rather than being torn by it; and when several cover one
    ;; character the one with the highest `priority' wins.
    ;;
    ;; The C keeps them in an interval tree per buffer, for the
    ;; redisplay's sake. What is kept here is a plain list in order by
    ;; start: the lookups are over a windowful of rows rather than a whole
    ;; file, and the tree is an optimisation this tree's shape does not
    ;; need yet.
    ;;
    ;; Positions are the *engine's*, one-based - what `build-marker' takes
    ;; and what `(schemacs editor textprop)' reads. `get-char-property' is
    ;; the seam the two meet at, and says so in its own comment.
    ;;
    ;; Not ported: `before-string' and `after-string', the properties that
    ;; put text on the screen which is not in the buffer (`xdisp.c''s
    ;; `load_overlay_strings'); `evaporate'; `overlay-recenter'; the
    ;; modification hooks; and the `window' property, which limits an
    ;; overlay to one window.
    ;;------------------------------------------------------------------
    (define buffer-overlays-table (make-weak-key-hash-table))
    ;; ^ each buffer's overlays, as a list in order by start
    ;; `*inhibit-read-only*' is GNU Emacs's `inhibit-read-only'
    ;; (`buffer.c':5885), which is where Emacs defines it - but it is
    ;; *read* by `insdel.c', on every insertion and deletion, and that is
    ;; the library this one is built on. A Guile library cannot be
    ;; imported by the library it imports, so the variable is held in
    ;; `(schemacs editor engine)' and re-exported here, exactly as
    ;; `*text-property-offset-function*' is. Everything that imports it
    ;; from here still reaches it.
    ;;
    ;; "Non-nil means disregard read-only status of buffers or
    ;; characters." A global in Emacs - not buffer-local - which is what
    ;; makes `(let ((inhibit-read-only t)) ...)' the way a command writes
    ;; into a read-only buffer. It is a parameter here, as this tree keeps
    ;; the flags that Elisp let-binds, so a command writes
    ;; `(parameterize ((*inhibit-read-only* #t)) ...)'.
    (define (overlay-current-buffer)
      ;; The buffer the overlay functions act on - Emacs's
      ;; `current_buffer'. `(current-buffer)' *raises* when there is no
      ;; frame to ask, and the redisplay asks for overlays at a position
      ;; in a buffer there may be none of: a test that draws a line with
      ;; nothing current is exactly that case.
      ;;--------------------------------------------------------------
      (guard (e (#t #f)) (current-buffer)))
    (define (buffer-overlays buffer)
      ;; A buffer with no overlays has none, and *no buffer at all* has
      ;; none either - the redisplay asks this for a position in a buffer
      ;; there may not be one of, which is what a test that draws a line
      ;; with no current buffer does.
      ;;--------------------------------------------------------------
      (if buffer
          (hashq-ref buffer-overlays-table buffer '())
          '()))
    (define (set!buffer-overlays! buffer overlays)
      (hashq-set! buffer-overlays-table buffer overlays))
    (define-record-type <overlay-type>
      (make<overlay> buffer start end plist)
      overlayp
      (buffer overlay-buffer %set-overlay-buffer!)
      (start  overlay-start-marker)
      (end    overlay-end-marker)
      (plist  overlay-properties set!overlay-properties!))
    (define (%make-overlay-boundary buffer position advance)
      ;; One end of an overlay: a marker at POSITION in BUFFER whose
      ;; insertion type is ADVANCE - so that text inserted exactly at the
      ;; end is inside the overlay for a rear advance and outside it for a
      ;; front one, which is what Front-Advance and Rear-Advance mean.
      ;;
      ;; **Two calls, where GNU Emacs 31 makes one.** Its `build_overlay`
      ;; (`buffer.c:697`) puts the two flags on the overlay's interval-tree
      ;; node and does not make markers at all - the tree holds the
      ;; positions. This tree's overlays are still the older model, a pair
      ;; of markers, so the flags are the markers' insertion types and
      ;; setting them is a second call (`set-marker-insertion-type`,
      ;; `marker.c:784`). `build-marker` is part of it either way: it
      ;; takes the buffer, which `copy-marker` cannot.
      ;;--------------------------------------------------------------
      (let ((marker ((*build-marker-function*) buffer position)))
        ((*set-marker-insertion-type-function*) marker advance)
        marker))
    (define (overlay-start overlay)
      ;; GNU Emacs's `overlay-start': "Return the start position of
      ;; OVERLAY." A deleted overlay's markers point nowhere, and its
      ;; start is nil, as the C's is.
      ;;--------------------------------------------------------------
      (and (overlayp overlay)
           ((*marker-position-function*) (overlay-start-marker overlay))))
    (define (overlay-end overlay)
      ;; GNU Emacs's `overlay-end': "Return the end position of OVERLAY."
      ;;--------------------------------------------------------------
      (and (overlayp overlay)
           ((*marker-position-function*) (overlay-end-marker overlay))))
    (define (overlay-get overlay prop)
      ;; GNU Emacs's `overlay-get': "Get the property of overlay OVERLAY
      ;; with property name PROP."
      ;;--------------------------------------------------------------
      (let ((cell (assq prop (overlay-properties overlay))))
        (and cell (cdr cell))))
    (define (overlay-put overlay prop value)
      ;; GNU Emacs's `overlay-put': "Set the property of overlay OVERLAY
      ;; with property name PROP to the value VALUE. ... Return VALUE."
      ;;--------------------------------------------------------------
      (set!overlay-properties!
       overlay
       (cons (cons prop value)
             (let loop ((l (overlay-properties overlay)))
               (cond ((null? l) '())
                     ((eq? (caar l) prop) (loop (cdr l)))
                     (else (cons (car l) (loop (cdr l))))))))
      value)
    (define (overlay-priority overlay)
      ;; The C's `make_sortvec_item' (buffer.c:3304): the `priority'
      ;; property if there is one - an integer, or a cons of the
      ;; priority and a secondary one - and zero otherwise.
      ;;--------------------------------------------------------------
      (let ((p (overlay-get overlay 'priority)))
        (cond ((not p) 0)
              ((integer? p) p)
              ((pair? p) (if (integer? (car p)) (car p) 0))
              (else 0))))
    (define (add-buffer-overlay! buffer overlay)
      ;; Put OVERLAY into BUFFER's list, in order by start.
      ;;--------------------------------------------------------------
      (let loop ((l (buffer-overlays buffer)) (acc '()))
        (cond ((null? l)
               (set!buffer-overlays! buffer (reverse (cons overlay acc))))
              ((< (overlay-start overlay) (overlay-start (car l)))
               (set!buffer-overlays!
                buffer (append (reverse acc) (cons overlay l))))
              (else (loop (cdr l) (cons (car l) acc))))))
    (define (make-overlay beg end . rest)
      ;; GNU Emacs's `make-overlay' (buffer.c:3635): "Create a new overlay
      ;; with range BEG to END in BUFFER and return it. If omitted, BUFFER
      ;; defaults to the current buffer."
      ;;
      ;; "The fourth arg FRONT-ADVANCE, if non-nil, makes the marker for
      ;; the front of the overlay advance when text is inserted there
      ;; (which means the text *is not* included in the overlay). The
      ;; fifth arg REAR-ADVANCE ... (which means the text *is*
      ;; included)." Those are the markers' insertion types here, which
      ;; is what the C's interval-tree node keeps for the same purpose.
      ;;--------------------------------------------------------------
      (let* ((buffer (if (pair? rest) (or (car rest) (current-buffer))
                         (current-buffer)))
             (front-advance (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
             (rear-advance (and (pair? rest) (pair? (cdr rest))
                                (pair? (cddr rest)) (caddr rest)))
             ;; "if BEG is greater than END, swap them"
             (b (min beg end))
             (e (max beg end))
             (overlay (make<overlay> buffer
                                    (%make-overlay-boundary buffer b front-advance)
                                    (%make-overlay-boundary buffer e rear-advance)
                                    '())))
        (add-buffer-overlay! buffer overlay)
        overlay))
    (define (delete-overlay overlay)
      ;; GNU Emacs's `delete-overlay' (buffer.c:3806): "Delete the overlay
      ;; OVERLAY from its buffer." Its markers are detached, so it follows
      ;; nothing from here on and `overlay-start' answers nil.
      ;;--------------------------------------------------------------
      (let ((buffer (overlay-buffer overlay)))
        (when buffer
          (set!buffer-overlays!
           buffer
           (let loop ((l (buffer-overlays buffer)))
             (cond ((null? l) '())
                   ((eq? (car l) overlay) (cdr l))
                   (else (cons (car l) (loop (cdr l)))))))
          ((*set-marker-function*) (overlay-start-marker overlay) #f)
          ((*set-marker-function*) (overlay-end-marker overlay) #f)
          (%set-overlay-buffer! overlay #f)))
      #f)
    (define (move-overlay overlay beg end . rest)
      ;; GNU Emacs's `move-overlay': "Move OVERLAY to span the region from
      ;; BEG to END." An overlay moved to another buffer is taken out of
      ;; the one it was in and put into the other, which is what the C
      ;; does for the same reason: the two ends are markers, and a marker
      ;; belongs to one buffer.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? rest) (or (car rest) (overlay-buffer overlay))
                        (overlay-buffer overlay))))
        (unless (eq? buffer (overlay-buffer overlay))
          (delete-overlay overlay)
          (%set-overlay-buffer! overlay buffer))
        ((*set-marker-function*) (overlay-start-marker overlay) (min beg end) buffer)
        ((*set-marker-function*) (overlay-end-marker overlay) (max beg end) buffer)
        ;; the list is kept in order by start, and this may have moved it
        (when (overlay-buffer overlay)
          (let ((ovs (let loop ((l (buffer-overlays buffer)))
                       (cond ((null? l) '())
                             ((eq? (car l) overlay) (loop (cdr l)))
                             (else (cons (car l) (loop (cdr l))))))))
            (set!buffer-overlays! buffer ovs)
            (add-buffer-overlay! buffer overlay))))
      overlay)
    (define (overlays-at pos . rest)
      ;; GNU Emacs's `overlays-at' (buffer.c:3898): "Return a list of the
      ;; overlays that contain the character at POS. If SORTED is
      ;; non-nil, then sort them by decreasing priority. Zero-length
      ;; ... overlays that start and stop at POS are not included."
      ;;--------------------------------------------------------------
      (let ((found (let loop ((l (buffer-overlays (overlay-current-buffer))) (acc '()))
                     (cond ((null? l) (reverse acc))
                           ((and (<= (overlay-start (car l)) pos)
                                 (< pos (overlay-end (car l))))
                            (loop (cdr l) (cons (car l) acc)))
                           (else (loop (cdr l) acc))))))
        (if (and (pair? rest) (car rest))
            ;; "the list should be in decreasing order of priority ...
            ;; because sort_overlays sorts in the increasing order"
            (reverse (sort found (lambda (a b)
                                   (< (overlay-priority a)
                                      (overlay-priority b)))))
            found)))
    (define (overlays-in beg end)
      ;; GNU Emacs's `overlays-in' (buffer.c:3944): "Return a list of the
      ;; overlays that overlap the region BEG ... END. Overlap means that
      ;; at least one character between BEG and END is contained within
      ;; the overlay." Empty overlays at a point in the range count too.
      ;;--------------------------------------------------------------
      (let loop ((l (buffer-overlays (overlay-current-buffer))) (acc '()))
        (cond ((null? l) (reverse acc))
              ((and (< (overlay-start (car l)) end)
                    (< beg (overlay-end (car l))))
               (loop (cdr l) (cons (car l) acc)))
              (else (loop (cdr l) acc)))))
    (define (next-overlay-change pos)
      ;; GNU Emacs's `next-overlay-change' (buffer.c:3987): "Return the
      ;; next position after POS where an overlay starts or ends. If there
      ;; are no overlay boundaries from POS to (point-max), the value is
      ;; (point-max)."
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (let loop ((l (buffer-overlays buffer)) (best #f))
          (cond ((null? l)
                 (or best (buffer-z buffer)))
                (else
                 (let ((s (overlay-start (car l)))
                       (e (overlay-end (car l))))
                   (loop (cdr l)
                         (fold-best best
                                    (if (> s pos) s #f)
                                    (if (> e pos) e #f)))))))))
    (define (fold-best best . candidates)
      ;; the smallest of BEST and the CANDIDATES that are numbers, #f for
      ;; none - the "next" of `next-overlay-change'
      ;;--------------------------------------------------------------
      (let loop ((rest candidates) (best best))
        (cond ((null? rest) best)
              ((not (car rest)) (loop (cdr rest) best))
              ((or (not best) (< (car rest) best)) (loop (cdr rest) (car rest)))
              (else (loop (cdr rest) best)))))
    (define (previous-overlay-change pos)
      ;; GNU Emacs's `previous-overlay-change': "Return the previous
      ;; position before POS where an overlay starts or ends. If there are
      ;; no overlay boundaries from (point-min) to POS, the value is
      ;; (point-min)."
      ;;--------------------------------------------------------------
      (let loop ((l (buffer-overlays (overlay-current-buffer))) (best #f))
        (cond ((null? l) (or best 0))
              (else
               (let ((s (overlay-start (car l)))
                     (e (overlay-end (car l))))
                 (loop (cdr l)
                       (let ((s (if (< s pos) s #f))
                             (e (if (< e pos) e #f)))
                         (cond ((not s) (or e best))
                               ((not e) (or best s))
                               (else (max s e (or best 0)))))))))))
    (define buffer-slots-table
      ;; The table of side slots. One table rather than a slot per fact,
      ;; so that a buffer-local variable can be any name a ported Elisp
      ;; sets, which is what `setq-local' needs.
      ;;--------------------------------------------------------------
      (make-weak-key-hash-table))
    (define (buffer-local-value buffer key . args)
      ;; The buffer-local value of KEY in BUFFER, or the optional default:
      ;; GNU Emacs's `buffer-local-value', which reads a named
      ;; buffer-local variable. A key is any value, compared by identity -
      ;; a symbol for a ported Elisp variable, and this library's own
      ;; slots below are keys of its own.
      ;;--------------------------------------------------------------
      (let* ((slots (hashq-ref buffer-slots-table buffer '()))
             (entry (assq key slots)))
        (cond (entry (cdr entry))
              ((pair? args) (car args))
              (else #f))))
    (define (set-buffer-local-value! buffer key value)
      ;; Make KEY locally VALUE in BUFFER: GNU Emacs's `setq-local' and the
      ;; `make-local-variable' beneath it.
      ;;--------------------------------------------------------------
      (let ((slots (hashq-ref buffer-slots-table buffer '())))
        (hashq-set! buffer-slots-table buffer
                         (cons (cons key value)
                               (let loop ((rest slots))
                                 (cond ((null? rest) '())
                                       ((eq? (caar rest) key) (loop (cdr rest)))
                                       (else (cons (car rest)
                                                   (loop (cdr rest))))))))
        value))
    (define (use-local-map keymap)
      ;; GNU Emacs's `use-local-map' (keymap.c:1900): "Select KEYMAP as
      ;; the current local keymap. If KEYMAP is nil, that means no local
      ;; keymap."
      ;;
      ;; keymap.c's, but here: `keymap.c' cannot see a buffer in this
      ;; tree - `(schemacs editor keymap)' is imported by `frame.c', and
      ;; `buffer.c' by that - so the two functions that read and write
      ;; the buffer's own keymap slot live with the slot.
      ;;--------------------------------------------------------------
      (set!buffer-local-keymap (current-buffer) keymap))
    (define (current-local-map)
      ;; GNU Emacs's `current-local-map' (keymap.c): "Return current
      ;; buffer's local map, or nil if there is none." keymap.c's, and
      ;; here for the reason `use-local-map' is.
      ;;--------------------------------------------------------------
      (buffer-local-keymap (current-buffer)))
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
                        ((*current-editor-function*)))))
        (or (and buffer (buffer-default-directory buffer))
            (string-append (getcwd) "/"))))
    (define *change-major-mode-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `change-major-mode-hook' (`buffer.c'): "Normal hook
    ;; run before changing the major mode, when otherwise a new major
    ;; mode would be installed. ... `kill-all-local-variables' runs it."
    ;; It is what a mode puts its clean-up in.
    (define (major-mode . args)
      ;; GNU Emacs's `major-mode' (`buffer.c':5230): "Symbol for current
      ;; buffer's major mode. The default value (normally
      ;; `fundamental-mode') affects new buffers."
      ;;
      ;; A buffer-local *variable* in Emacs; a slot of the buffer here,
      ;; read through the same store `buffer-local-value' reads. The
      ;; optional argument is the buffer, and without one the current
      ;; buffer is asked - and a buffer never given one answers
      ;; `fundamental-mode', which is Emacs's default.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (buffer-local-value buffer 'major-mode 'fundamental-mode)))
    (define (set!major-mode value . args)
      ;; What `(setq major-mode MODE)' does in a buffer.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (if (pair? args) (car args) (current-buffer))
                               'major-mode value))
    (define (mode-name . args)
      ;; GNU Emacs's `mode-name' (`buffer.c':5243): "Pretty name of
      ;; current buffer's major mode. Usually a string, but can use any
      ;; of the constructs for `mode-line-format'."
      ;;
      ;; A fresh buffer answers "Fundamental", which is what Emacs shows
      ;; for one: `fundamental-mode' is the mode a buffer starts in and
      ;; this is the name it gives itself.
      ;;--------------------------------------------------------------
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        (buffer-local-value buffer 'mode-name "Fundamental")))
    (define (set!mode-name value . args)
      ;; What `(setq mode-name NAME)' does in a buffer.
      ;;--------------------------------------------------------------
      (set-buffer-local-value! (if (pair? args) (car args) (current-buffer))
                               'mode-name value))
    (define *permanent-local-variables*
      ;; The variables `kill-all-local-variables' does not reset, because
      ;; they have no default value to reset *to*: the C's
      ;; `init_buffer_once' marks them -1 in `buffer_local_flags', and
      ;; `bindings.el:1058' writes the same list down as the
      ;; `permanent-local' property.
      ;;
      ;; This tree has as slots only the ones it uses. `buffer-read-only'
      ;; is a field of the buffer here and not a slot, so it needs no
      ;; entry; `buffer-undo-list' is the engine's.
      ;;--------------------------------------------------------------
      '(default-directory buffer-file-name mark-active truncate-lines
        buffer-file-coding-system))
    (define (kill-all-local-variables . args)
      ;; GNU Emacs's `kill-all-local-variables' (`buffer.c':3019):
      ;; "Switch to Fundamental mode by killing current buffer's local
      ;; variables. Most local variable bindings are eliminated so that
      ;; the default values become effective once more. Also, ... the
      ;; local keymap is set to nil ... This function also forces
      ;; redisplay of the mode line. Every function to select a new
      ;; major mode starts by calling this function. ... The first thing
      ;; this function does is run the normal hook
      ;; `change-major-mode-hook'."
      ;;
      ;; "As a special exception, local variables whose names have a
      ;; non-nil `permanent-local' property are not eliminated by this
      ;; function." There are no properties on a variable here - a slot
      ;; is keyed by a plain value - so there is no exception to make,
      ;; and the C's KILL-PERMANENT argument has nothing to say.
      ;;--------------------------------------------------------------
      ((*run-hooks-function*) (*change-major-mode-hook*))
      (let ((buffer (if (pair? args) (car args) (current-buffer))))
        ;; "Actually eliminate all local bindings of this buffer" - except
        ;; the ones the C never had in its locals list to begin with. Those
        ;; are `init_buffer_once''s `buffer_local_flags' set to -1
        ;; (`bset_directory', `bset_filename', `bset_read_only',
        ;; `bset_mark_active', `bset_truncate_lines' and the rest), and
        ;; `bindings.el:1058' spells the same list out: "These per-buffer
        ;; variables are never reset by `kill-all-local-variables', because
        ;; they have no default value." `default-directory' is the one that
        ;; matters most - a major mode that reset it would send every bare
        ;; file name to the process's directory - and it is why
        ;; `dired-advertise', which runs from a mode, read the wrong
        ;; directory until this preserved it.
        (hashq-set!
         buffer-slots-table buffer
         (let loop ((slots (hashq-ref buffer-slots-table buffer '()))
                    (kept '()))
           (cond ((null? slots) kept)
                 ((memq (caar slots) *permanent-local-variables*)
                  (loop (cdr slots) (cons (car slots) kept)))
                 (else (loop (cdr slots) kept)))))
        (set!buffer-local-keymap buffer #f))
      ;; The C ends by asking for the mode line to be redrawn
      ;; (`bset_update_mode_line'), because every major mode command calls
      ;; this and the mode name it shows has just gone. There is nothing
      ;; to ask here: this editor redraws after every command, so the
      ;; mode line is drawn again before anything can be seen.
      #t)
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
    (define (erase-buffer)
      ;; GNU Emacs's `erase-buffer' (buffer.c:2472): "Delete the entire
      ;; contents of the current buffer. Any narrowing restriction in
      ;; effect is removed, so the buffer is truly empty after this."
      ;; The read-only check is the `*' of its interactive spec, which
      ;; `barf-if-buffer-read-only' makes - the same function
      ;; `prepare_to_modify_buffer_1` calls before any change. There is
      ;; no narrowing, so the widen is a no-op, and the `save_length' is
      ;; nothing - no auto saving machinery.
      ;;--------------------------------------------------------------
      (barf-if-buffer-read-only)
      (let ((ed (current-buffer)))
        ;; The C is three lines: `Fwiden ()', `del_range (BEG, Z)', and
        ;; the housekeeping that follows. Nothing is narrowed here, so
        ;; the widen is a no-op, and the rest is `del_range`'s.
        ((*del-range-function*) (buffer-beg ed) (buffer-z ed)))
      #f)
    (define (set-buffer-modified-p flag)
      ;; GNU Emacs's `set-buffer-modified-p' (buffer.c:1549): "Mark
      ;; current buffer as modified or unmodified according to FLAG."
      ;;
      ;; FLAG is the *only* argument - the C's DEFUN is `1, 1, 0' and it
      ;; acts on the current buffer. The C is two calls, and this is the
      ;; first of them:
      ;;
      ;;     Frestore_buffer_modified_p (flag);
      ;;     return Fforce_mode_line_update (Qnil);
      ;;
      ;; The mode line half is this tree's redisplay's business, so what
      ;; is left is `restore-buffer-modified-p'.
      ;;--------------------------------------------------------------
      (restore-buffer-modified-p flag))
    (define (restore-buffer-modified-p flag)
      ;; GNU Emacs's `restore-buffer-modified-p' (buffer.c:1576): "Like
      ;; `set-buffer-modified-p', but doesn't redisplay buffer's mode
      ;; line. A nil FLAG means to mark the buffer as unmodified."
      ;;
      ;; The arithmetic is all in terms of the two counters rather than a
      ;; flag. Marking a buffer modified *raises* `MODIFF' when
      ;; `SAVE_MODIFF' has caught up with it, so that the comparison comes
      ;; out true again - which is how "modified" is said of a buffer
      ;; whose text never changed. `modiff_incr' answers the *old* count,
      ;; so `SAVE_MODIFF' is left one below, not equal.
      ;;
      ;; The C also locks or unlocks the file the buffer visits, which
      ;; needs file locking - not ported. It returns FLAG.
      ;;
      ;; **No undo entry is recorded**, which is Emacs's behaviour and is
      ;; worth stating because it is not obvious: measured,
      ;; `(set-buffer-modified-p nil)' and `(set-buffer-modified-p t)'
      ;; both leave `buffer-undo-list' exactly as it was. The C calls
      ;; `record_first_change' from the *change* paths - `insdel.c:2090',
      ;; `textprop.c:89', `undo.c:65' - and from nothing here. The
      ;; `(t . TIME)' mark is made by `%record-point' (`record_insert`
      ;; and `record_delete` call it), before
      ;; a change to an unmodified buffer.
      ;;
      ;; **It does not touch the visited file's modtime either**, which
      ;; is the other half of the same point: `SAVE_MODIFF' is the
      ;; buffer's own record of what it last agreed with, and only
      ;; `visited-file-modtime' records what the *file* was. Saving a
      ;; buffer sets both, but through different doors - the write
      ;; updates `modtime' and this sets `SAVE_MODIFF' - and something
      ;; that marks a buffer unmodified without writing the file (a
      ;; revert, a programmatic clear) leaves `modtime' alone, as Emacs
      ;; does.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (modiff (buffer-modified-tick ed)))
        (if (not flag)
            (set!text-editor-save-modiff ed modiff)
            (when (>= (text-editor-save-modiff ed) modiff)
              (set!text-editor-save-modiff ed modiff)
              (%text-editor-incr-modiff! ed 0)))
        flag))
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
    ;;----------------------------------------------------------------
    ;; The buffer record - GNU Emacs's `struct buffer'
    ;;------------------------------------------------------------------
    ;;
    ;; **This is `buffer.h`'s struct, and it is here because it is
    ;; `buffer.c`'s.** It used to be in `(schemacs editor engine)`,
    ;; which is not a file Emacs has - and the engine is built on
    ;; this library now, not the other way round, which is what lets
    ;; `buffer.c`'s own functions work on it.
    ;;
    ;; The one thing it cannot reach is `marker.c`'s constructor:
    ;; `allocate_buffer` makes the mark with `Fmake_marker`
    ;; (`buffer.c:672`), and marker.c is built on this library for
    ;; the same reason it is built on Emacs's buffer.c - a marker is
    ;; added to a buffer's chain, and that chain is a field here. So
    ;; `*make-marker-function*` is a seam, installed by the library
    ;; that has the constructor.
    ;;--------------------------------------------------------------
    ;; GNU Emacs's two sentinel modification times (`buffer.h:314').
    ;; They are not times at all but the two answers a buffer's recorded
    ;; visited-file time can give that no `struct timespec' can hold:
    ;; "no time is known" for a buffer that visits nothing, and "the
    ;; file is not there" for one whose file has been removed.
    ;; `buffer-visited-file-modtime' (`fileio.c:6157') turns them into
    ;; the 0 and -1 the Lisp interface documents.
    ;;--------------------------------------------------------------
    (define %unknown-modtime-nsecs -2)
    (define %nonexistent-modtime-nsecs -1)

    (define-record-type <buffer>
      (make<buffer>
       text  newline-cache  point
       textprops  undo
       save-modiff  modtime  modtime-size  cache-long-scans  read-only  mark  markers
       name  file-name
       )
      bufferp
      (newline-cache %text-editor-newline-cache
                     set!%text-editor-newline-cache)
      ;; ^ GNU Emacs's `buf->newline_cache' (`buffer.h:696'), the
      ;; `region-cache' that remembers which stretches of the buffer have
      ;; been searched and found to hold no line break. False until
      ;; `find-newline' first wants it, which is when the C makes one
      ;; too (`search.c:640') - a buffer whose lines are never searched
      ;; never pays for it.
      (text       text-editor-text          set!text-editor-text)
      ;; ^ The buffer's text - a `(schemacs editor buffer-text)', which
      ;; is GNU Emacs's `struct buffer_text': the characters, the gap
      ;; and where the gap is. There is ONE of these where there used to
      ;; be four - a gap buffer of `<text-line>' records, a separate
      ;; line editor, a CDF indexing the lines, and a hand-maintained
      ;; character count. None of the four has a counterpart in Emacs;
      ;; the text is one sequence of characters there and it is one
      ;; here.
      (point      buffer-pt         set!buffer-pt)
      ;; ^ The cursor - GNU Emacs's `BUF_PT (buf)`, which is the field
      ;; `PT` on the buffer (`buffer.h:1078`). It is a `buffer-text`
      ;; *position*: one-based, the convention the class speaks, and
      ;; Emacs's own. Emacs keeps `PT' on the buffer for the same reason
      ;; it is here - it is not derivable from the gap, which can sit
      ;; anywhere - and `point' (`editfns.c') is `BUF_PT' of the current
      ;; buffer and nothing more.
      (textprops  text-editor-text-props     set!text-editor-text-props)
      ;; The root of the buffer's text-property tree. This is GNU Emacs's
      ;; `BUFFER_INTERVALS' - the root of the interval tree - which
      ;; `(schemacs editor intervals)' mirrors and this library only
      ;; holds; it is what syntax colouring and the `display' property
      ;; are kept in.
      (undo       text-editor-undo-list     set!text-editor-undo-list)
      ;; ^ The buffer's undo list, GNU Emacs's `buffer-undo-list'. A
      ;; list, newest entry first, of the edits that can be undone; or
      ;; `#t`, which is Emacs's `t', meaning that the recording of undo
      ;; information is disabled. The empty list is Emacs's `nil':
      ;; recording is enabled but there is nothing to undo.
      ;;
      ;; **The sentinel is `#t', as Emacs's is `t'.** It was `#f' until
      ;; 2026-10-14: behaviourally identical, and *inverted* in
      ;; representation, which is the dangerous kind of departure -
      ;; Emacs's `t' is true and this tree's `#f' was false, so a reader
      ;; that tested the list for truth rather than for the sentinel read
      ;; it backwards. `undo.scm`'s `text-editor-undo-recording?` is the
      ;; C's own test, `undo.c`'s `!EQ (BUF_UNDO_LIST (buf), Qt)`. See
      ;; the "Undo" section below for the entry formats.
      (save-modiff text-editor-save-modiff  set!text-editor-save-modiff)
      (modtime    %buffer-modtime         set!%buffer-modtime)
      ;; ^ GNU Emacs's `b->modtime' (`buffer.h:649'), the modification
      ;; time of the file the buffer visits, as the C's `struct
      ;; timespec' - here a pair of `(SECONDS . NANOSECONDS)'.
      ;;
      ;; **The nanoseconds carry two sentinels, as the C's do**
      ;; (`buffer.h:314'): `UNKNOWN_MODTIME_NSECS' (-2) is "no time is
      ;; known", which is what a buffer that visits nothing holds, and
      ;; `NONEXISTENT_MODTIME_NSECS' (-1) is "the file is not there".
      ;; `buffer-visited-file-modtime' (`fileio.c:6157') is what reads
      ;; them, and it is why the field is not simply a Lisp time: those
      ;; two answers have no time to be.
      ;;
      ;; It is recorded when a file is visited and again when it is
      ;; written, and what it is *for* is the `(t . TIME)' undo entry:
      ;; undoing back to the mark of the last save makes the buffer
      ;; unmodified again only while the time it recorded still matches
      ;; this one. Save in between and this changes, the entry goes
      ;; stale, and the undo does not claim the buffer matches a file it
      ;; no longer matches.
      (modtime-size %buffer-modtime-size    set!%buffer-modtime-size)
      ;; ^ GNU Emacs's `b->modtime_size' (`buffer.h:661'), the visited
      ;; file's size as of that same stat, or -1 for "not from a stat".
      ;; `verify-visited-file-modtime' compares it beside the time,
      ;; because a file can be rewritten within the resolution of the
      ;; clock and keep the same timestamp.
      (cache-long-scans text-editor-cache-long-scans
                        set!text-editor-cache-long-scans)
      ;; ^ GNU Emacs's `cache-long-scans' (`buffer.c:5786'), a
      ;; `DEFVAR_PER_BUFFER' whose default is **true**: "Non-nil means
      ;; that Emacs should use caches in attempt to speedup buffer
      ;; scans... There is no reason to set this to nil except for
      ;; debugging purposes." It is the switch both region caches hang
      ;; on - `find_newline' consults it before making one
      ;; (`search.c:618'), and `width_run_cache_on_off' checks it too.
      ;; It lives on the buffer because that is where Emacs declares
      ;; it, and `find-newline' is below the library that would
      ;; otherwise hold it.
      ;; ^ GNU Emacs's `SAVE_MODIFF' (`buffer.h'), a field of
      ;; `struct buffer': the value of the text's `modiff' when the
      ;; buffer was last in sync with its file. There is no flag
      ;; beside it - `buffer-modified-p' *is* the comparison
      ;; `SAVE_MODIFF < MODIFF', which is what `buffer-modified-p'
      ;; answers and what `set-buffer-modified-p' maintains.
      ;; It is cleared by saving and by undoing back past every change
      ;; made since the last save.
      ;; **`deactivate-mark' is NOT a field of `struct buffer' and is not a
      ;; field here either.** GNU Emacs declares it in `keyboard.c:14030'
      ;; - `DEFVAR_LISP ("deactivate-mark", Vdeactivate_mark)' followed by
      ;; `Fmake_variable_buffer_local' - so it is a *Lisp variable* that is
      ;; automatically buffer-local: a global whose value the current
      ;; buffer may shadow. It was a slot of this record until 2026-10-12,
      ;; which is the same shape read from the wrong direction: a slot
      ;; cannot be `let'-bound, cannot be `setq'-ed by ported Lisp, and
      ;; has no name for a user to set.
      ;;
      ;; It is a buffer-local *variable* now, keyed by the symbol
      ;; `deactivate-mark' in the table `buffer-local-value' and
      ;; `set-buffer-local-value!' read - the same arrangement
      ;; `transient-mark-mode', `mark-ring' and `list-buffers-directory'
      ;; already use. Nothing declares it: a key needs no definition, and
      ;; the global it falls back to is `#f', which is
      ;; `Vdeactivate_mark = Qnil'. So the reads and writes are
      ;;
      ;;     (buffer-local-value (current-buffer) 'deactivate-mark #f)
      ;;     (set-buffer-local-value! (current-buffer) 'deactivate-mark #t)
      ;;
      ;; and there are eight of them: `insdel.scm`'s
      ;; `prepare-to-modify-buffer-1` sets it ("Buffer modifications store
      ;; t in this variable"), `keyboard.scm`'s command loop clears it
      ;; before each command and applies it after, `mouse.scm` clears it
      ;; when a drag sets its own region, and `simple.scm` sets it from
      ;; the commands that change the buffer.
      ;;
      ;; The alternative - a named accessor pair declared here - was
      ;; rejected because it invents two names Emacs has not got, and
      ;; because the variable's *name* is what Lisp sets. The hazard of
      ;; it is a misspelt key, which the compiler cannot catch; the eight
      ;; sites are listed above so a sweep can find them.
      (mark       %mark-marker           set!%mark-marker)
      ;; ^ The buffer's mark, GNU Emacs's `mark': a <marker-type>, which
      ;; is what makes it survive the text around it changing. It points
      ;; nowhere until the mark is set. `TEXT-EDITOR-MARK' is the
      ;; accessor Lisp would see - the position, as Emacs's `(mark)' -
      ;; so this slot is private.
      (markers    buffer-markers    set!buffer-markers)
      ;; ^ The buffer's markers: GNU Emacs's marker chain, which the
      ;; insert and delete procedures adjust so that a marker goes on
      ;; pointing at the same character as the text around it moves.
      ;; It holds them weakly, so a marker that nothing else refers to
      ;; is collected and drops out of the chain by itself - see the
      ;; "Markers" section below for why.
      (read-only  text-editor-read-only-flag set!text-editor-read-only-flag)
      ;; ^ Whether the buffer refuses to be changed, GNU Emacs's
      ;; `buffer-read-only'. The insert and delete procedures signal an
      ;; error while it is set, so nothing can change the text by
      ;; accident - including undo, which is why the undo procedure
      ;; refuses too. It is independent of the modified flag: a buffer
      ;; can be read-only and modified at once.
      (name       text-editor-buffer-name set!text-editor-buffer-name)
      ;; ^ The buffer's name, GNU Emacs's `buffer-name': what the mode
      ;; line shows, and what distinguishes one buffer from another in
      ;; the messages that name them. A buffer visiting a file is named
      ;; after the file, without its directory (Emacs's
      ;; `create-file-buffer' uses `file-name-nondirectory'), and a
      ;; buffer with no file has a name of its own - "*scratch*",
      ;; "*Completions*". The default is Emacs's for a buffer made by
      ;; `generate-new-buffer'.
      (file-name  text-editor-file-name    set!text-editor-file-name)
      ;; ^ The file the buffer visits, GNU Emacs's `buffer-file-name',
      ;; or false when it visits none. It is the path the buffer was
      ;; read from and the one `save-buffer' writes back to - which is
      ;; why it is the buffer's and not the window's: two windows can
      ;; show the same buffer, and a window can show a buffer that
      ;; visits no file at all.
      )

    (define (allocate-buffer)
      ;; A new buffer: one `buffer-text`, no text, an empty undo list, and
      ;; the buffer-level state GNU Emacs's `struct buffer` carries -
      ;; `buffer.c`'s `make_buffer` and `Fget_buffer_create`.
      ;;
      ;; **It takes no arguments on purpose.** It used to take a
      ;; line-break protocol and a properties list, both of them the
      ;; previous author's: the protocol existed to drive a line editor
      ;; that no longer exists (the engine keeps one sequence of
      ;; characters, so a line break is a character like any other), and
      ;; the properties list was an association list of text properties
      ;; where this tree now keeps `BUFFER_INTERVALS` - the interval
      ;; tree, in `(schemacs editor intervals)`. Neither had a caller.
      ;;--------------------------------------------------------------
      (let ()
        (make<buffer>
         ;; Emacs's `BEG' is 1, and every position the class answers is in
         ;; that coordinate system. The gap is `GAP_BYTES_MIN' because
         ;; that is what a fresh buffer's is: `buffer.c:607' sets
         ;; `BUF_GAP_SIZE (b) = 20' and allocates exactly that (plus the
         ;; NUL anchor) before anything is inserted. It used to be 4096,
         ;; which was the previous author's *line* count for a store that
         ;; held lines rather than characters.
         (new-buffer-text 1 *gap-bytes-min*)
         ;; the newline cache, made on first use
         #f
         1
         #f
         ;; A newly created buffer records undo information from the
         ;; start, as in GNU Emacs.
         '()
         ;; `SAVE_MODIFF' starts at 1 and so does the text's `modiff',
         ;; which is what makes a fresh buffer unmodified: `1 < 1' is
         ;; false. Emacs sets the one to 1 at `buffer.c:631' and a fresh
         ;; buffer reports a tick of 1. Beside it a fresh buffer's
         ;; visited-file time is unknown and its size unrecorded, which
         ;; is `reset_buffer''s pair (`buffer.c:1094') exactly -
         ;; `(make_timespec (0, UNKNOWN_MODTIME_NSECS))' and -1. Long
         ;; scans are cached and the buffer is writable.
         1 (cons 0 -2) -1 #t #f
         ;; The mark, pointing nowhere until it is set, and an empty
         ;; marker chain.
         ((*make-marker-function*))
         (make-weak-key-hash-table)
         ;; Named as `generate-new-buffer' names a buffer it makes, and
         ;; visiting no file.
         "Untitled" #f
         )))

    (define show-text-editor
      ;; Write a buffer to a port the way GNU Emacs writes one, which is
      ;; `print_object`'s `PVEC_BUFFER` case (`print.c:1895`):
      ;;
      ;;     if (!BUFFER_LIVE_P (XBUFFER (obj)))
      ;;       print_c_string ("#<killed buffer>", printcharfun);
      ;;     else if (escapeflag)
      ;;       { print_c_string ("#<buffer ", ...
      ;;         print_string (BVAR (XBUFFER (obj), name), ...
      ;;     else
      ;;       print_string (BVAR (XBUFFER (obj), name), ...
      ;;
      ;; so `prin1` is `#<buffer NAME>`, `princ` is the bare name, and a
      ;; buffer that is not live is `#<killed buffer>` - and `BUFFER_LIVE_P`
      ;; is `!NILP (BVAR (b, name))` (`buffer.h:1143`), which makes
      ;; liveness the name being there, which is the nearest thing this
      ;; tree has to it. This is the `escapeflag` answer, because a Guile
      ;; record printer is handed the record and a port and nothing that
      ;; says which of the two it is - and `write`, which is what a REPL
      ;; echoes with, is `prin1`.
      ;;
      ;; **It used to write the whole buffer out**, line by line and
      ;; quoted, and that is what the first person to type
      ;; `(find-file "README.md")` at the back door saw: a screenful of
      ;; the file where the answer was one word. Emacs's `find-file`
      ;; answers the *buffer*, and a buffer prints as its name and nothing
      ;; else. It was also the expensive way round - a printed buffer
      ;; looked like a list of strings because `text-editor-line-string`
      ;; builds a fresh string for every line, so echoing a buffer
      ;; allocated one string per line of it. The storage was never a list
      ;; of strings: it is one `buffer-text`, a `u32vector` with a gap.
      ;;
      ;; **Cheap on purpose**, as well: a record printer is what runs when
      ;; Guile prints a *backtrace*, and one that walks the buffer there
      ;; has crashed before now.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (show-text-editor ed (current-output-port)))
       ((ed port)
        (let ((name (text-editor-buffer-name ed)))
          (if name
              (begin (display "#<buffer " port)
                     (display name port)
                     (display ">" port))
              (display "#<killed buffer>" port))))))


    (cond-expand
     (guile
      (set-record-type-printer! <buffer> show-text-editor)
      )
     (else)
     )



    (define *inhibit-read-only* (make-parameter #f))
    ;; ^ GNU Emacs's `inhibit-read-only' (`buffer.c':5885): "Non-nil means
    ;; disregard read-only status of buffers or characters. A non-nil
    ;; value that is a list means disregard `buffer-read-only' status, and
    ;; disregard a `read-only' text property if the property value is a
    ;; member of the list. Any other non-nil value means disregard
    ;; `buffer-read-only' and all `read-only' text properties."
    ;;
    ;; Emacs defines it in buffer.c and *reads* it from insdel.c, which is
    ;; this library - and here the read is the other way round, because
    ;; the engine cannot import the library that imports it. So it is held
    ;; here and `buffer.sld' re-exports it, the same arrangement as
    ;; `*text-property-offset-function*' below. A command writes into a
    ;; read-only buffer with
    ;; `(parameterize ((*inhibit-read-only* #t)) ...)'.
    ;;
    ;; Not ported: the *list* value's meaning for `read-only' text
    ;; properties. The engine's insert and delete do not know about text
    ;; properties at all - see `barf-if-buffer-read-only' - so any non-nil
    ;; value is the "disregard all of it" case.

    (define (buffer-beg ed)
      ;; GNU Emacs's `point-min' (`editfns.c'): "the minimum permissible
      ;; value of point in the current buffer. This is 1, unless
      ;; narrowing ... is in effect." Nothing is narrowed here, and the
      ;; buffer-text's base is that same 1.
      ;;--------------------------------------------------------------
      (buffer-text-base (text-editor-text ed)))

    (define (buffer-z ed)
      ;; GNU Emacs's `point-max' (`editfns.c'): one past the last
      ;; character of the buffer. It is the buffer-text's own `z' field,
      ;; which is Emacs's `Z'.
      ;;--------------------------------------------------------------
      (buffer-text-z (text-editor-text ed)))

    (define (fetch-char ed pos)
      ;; GNU Emacs's `FETCH_CHAR (pos)' (`buffer.h'): the character at
      ;; POS in ED, or #f when POS is outside it. It answers a
      ;; *character* and not a code point, where `buffer-text-ref' - the
      ;; store's own read - answers the integer elisp and `FETCH_CHAR'
      ;; deal in.
      ;;
      ;; **`FETCH_CHAR' is a macro over `BUF_BEG_ADDR', and this library
      ;; is that macro's home here** - it owns the record, `BEG' and `Z'
      ;; (`buffer.h:992') and the text, which is the same set of things
      ;; the macro reaches through. It has no Lisp name in Emacs, so the
      ;; tree's own spelling stands; it was `engine.scm`'s until
      ;; 2026-10-13, where it sat with the writers it has nothing to do
      ;; with.
      ;;
      ;; `char-after' (`editfns.c:1038') is the Lisp door onto this, for
      ;; the current buffer and with point as the default; this is the
      ;; read below it, and every caller of it names the buffer.
      ;;--------------------------------------------------------------
      (and (<= (buffer-beg ed) pos)
           (< pos (buffer-z ed))
           (integer->char (buffer-text-ref (text-editor-text ed) pos))))

    (define (set-point ed position)
      ;; GNU Emacs's `SET_PT' (`buffer.h:170'), as `Fgoto_char'
      ;; (`editfns.c:233') uses it: put ED's point at POSITION, clipped
      ;; into the buffer. Answers nothing.
      ;;
      ;; **`SET_PT' is a macro over the point slot, and this library is
      ;; its home here** - it owns the record and the `BEG'/'Z' the clip
      ;; runs against, the same reason `fetch-char' is above. It was
      ;; `engine.scm`'s under the invented name `text-editor-set-cursor'
      ;; until 2026-10-13, where it stood among the writers it has
      ;; nothing to do with.
      ;;
      ;; The C's `set_point' (`intervals.c:1776') does **not** clip: it
      ;; asserts the position is in range, and `Fgoto_char' is what
      ;; clips first - `SET_PT (clip_to_bounds (BEGV, XFIXNUM
      ;; (position), ZV))'. Measured on Emacs 31.1, `(goto-char 999)' on
      ;; a 7-character buffer leaves point at 7 and `(goto-char 0)' at
      ;; 1, silently. This is that clipping SET_PT, so a caller may hand
      ;; it a position it has not bounds-checked.
      ;;
      ;; `goto-char' (`editfns.scm') is the Lisp door onto this - the
      ;; current buffer, a marker or a number, answering the POSITION it
      ;; was given; this is the write below it, and every caller names
      ;; its buffer.
      ;;
      ;; The integer test is the Scheme stand-in for the C's `ptrdiff_t'
      ;; parameter, which cannot be handed anything else; a non-number is
      ;; `wrong-type-argument` in Emacs's `goto-char`.
      ;;--------------------------------------------------------------
      (if (integer? position)
          (set!buffer-pt ed
             (max (buffer-beg ed)
                  (min (buffer-z ed) position)))
          (error "text editor index must be set with an integer" position)))

    (define (buffer-modified-tick . rest)
      ;; GNU Emacs's `buffer-modified-tick' (`buffer.c:1631'): "Return
      ;; BUFFER's modification tick." It answers `MODIFF', which every
      ;; change to the text raises, so two readings that differ mean the
      ;; buffer changed in between - which is the question the line-break
      ;; cache and redisplay freshness both ask. The DEFUN is `0, 1, 0',
      ;; so BUFFER is optional.
      ;;--------------------------------------------------------------
      (buffer-text-modiff (text-editor-text (or (and (pair? rest) (car rest))
                                                (current-buffer)))))

    (define (buffer-chars-modified-tick . rest)
      ;; The same, for changes to the *characters* alone: GNU Emacs's
      ;; `buffer-chars-modified-tick' (`buffer.c:1631'). A change to a
      ;; text property raises `modiff' and not this one, so a cache of
      ;; something computed from the characters is not invalidated by a
      ;; fontification change. BUFFER is optional, as above.
      ;;--------------------------------------------------------------
      (buffer-text-chars-modiff (text-editor-text (or (and (pair? rest) (car rest))
                                                      (current-buffer)))))

    (define (buffer-modified-p . rest)
      ;; GNU Emacs's `buffer-modified-p' (buffer.c:1506): "Return non-nil
      ;; if BUFFER was modified since its file was last read or saved. No
      ;; argument or nil as argument means use current buffer as BUFFER."
      ;;
      ;; Not a flag: it is the comparison
      ;;
      ;;     BUF_SAVE_MODIFF (buf) < BUF_MODIFF (buf)
      ;;
      ;; and the DEFUN is `0, 1, 0', so BUFFER is optional.
      ;;--------------------------------------------------------------
      (let ((ed (or (and (pair? rest) (car rest)) (current-buffer))))
        (< (text-editor-save-modiff ed) (buffer-modified-tick ed))))

    (define (%text-editor-incr-modiff! ed len)
      ;; Raise the modification counter by `modiff_incr''s rule
      ;; (`lisp.h:4142'): one for a change that is not to the characters,
      ;; and `elogb (len) + 1' - the base-2 logarithm of the size, plus
      ;; one - for one that is. Raising it more for a bigger change but
      ;; only logarithmically is what stops a large edit racing the
      ;; counter away; and `chars_modiff' follows `modiff' only for a
      ;; change to the characters (`insdel.c:929').
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (set!buffer-text-modiff
         text (+ (buffer-text-modiff text)
                 (if (or (not len) (= len 0))
                     1
                     (+ 1 (let loop ((n len) (w 0))
                            (if (<= n 1) w (loop (quotient n 2) (+ w 1))))))))
        (when (and len (> len 0))
          (set!buffer-text-chars-modiff text (buffer-text-modiff text)))))

    (define (buffer-read-only? ed)
      ;; Whether ED refuses to be changed. GNU Emacs's
      ;; `buffer-read-only'.
      ;;--------------------------------------------------------------
      (text-editor-read-only-flag ed))

    (define (set!buffer-read-only ed flag)
      ;; Set whether ED refuses to be changed: the variable GNU Emacs
      ;; keeps as `buffer-read-only', and that its `read-only-mode'
      ;; toggles.
      ;;--------------------------------------------------------------
      (set!text-editor-read-only-flag ed (and flag #t)))

    (define (barf-if-buffer-read-only . rest)
      ;; GNU Emacs's `barf-if-buffer-read-only' (`buffer.c:2453'):
      ;; "Signal a `buffer-read-only' error if the current buffer is
      ;; read-only. If the text under POSITION (which defaults to point)
      ;; has the `inhibit-read-only' text property set, the error will
      ;; not be raised."
      ;;
      ;; **This is `buffer.c`'s and it is here, not in `editfns.scm`
      ;; where it used to be.** `insdel.c`'s `prepare_to_modify_buffer_1`
      ;; is its main caller and `insdel.scm` sits above this library and
      ;; below `editfns.scm`, so a copy in editfns was unreachable from
      ;; the one place that needs it most - and the two would have been
      ;; free to disagree.
      ;;
      ;; The C's test is three parts, in this order: the buffer is
      ;; read-only, `inhibit-read-only' is nil - the global a command
      ;; let-binds to write into a read-only buffer - and the *text
      ;; property* is nil where the change is. The property is read
      ;; through a seam because the interval tree's lookups are
      ;; `intervals.scm`'s and that library is above this one; the seam
      ;; is cold, since the C's `&&` asks it only when the first two
      ;; tests have already passed.
      ;;
      ;; Not ported: the `read-only` text property, which makes a piece
      ;; of an otherwise writable buffer read-only. Nothing consults it.
      ;;--------------------------------------------------------------
      (when (and (buffer-read-only? (current-buffer))
                 (not (*inhibit-read-only*))
                 (let ((lookup (*get-text-property-function*)))
                   (or (not lookup)
                       (not (lookup (if (pair? rest) (car rest)
                                        (buffer-pt (current-buffer)))
                                    'inhibit-read-only)))))
        (error "Buffer is read-only")))

    (define (validate-region b e)
      ;; GNU Emacs's `validate_region` (`buffer.c:2492`): put the two ends
      ;; of a region in order, check them against the buffer's bounds, and
      ;; answer the pair the caller should use. It is the first line of
      ;; every region-taking DEFUN - `casify_region` is one - and it
      ;; exists because the two ends arrive in whatever order the caller
      ;; had them, so each one has to be sorted before it can be used.
      ;;
      ;; **Not carried**: the C's `fix_position` coerces a marker to its
      ;; position before anything is compared, and it is `buffer.c`'s. The
      ;; callers here are the region commands, whose `region-beginning`
      ;; and `region-end` answer integers, so there is no marker to coerce
      ;; - and `marker.scm` is *above* this library, so the coercion could
      ;; not be written here anyway. It belongs with whichever caller
      ;; starts accepting an arbitrary object.
      ;;--------------------------------------------------------------
      (let* ((beg (if (< e b) e b))
             (end (if (< e b) b e))
             (ed (current-buffer)))
        (if (not (and (<= (buffer-beg ed) beg) (<= end (buffer-z ed))))
            (error "Args out of range" ed b e))
        (values beg end)))

    ))
