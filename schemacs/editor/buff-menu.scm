(define-library (schemacs editor buff-menu)
  ;; This library mirrors GNU Emacs's `buff-menu.el`: the buffer menu -
  ;; `list-buffers' (C-x C-b), the `*Buffer List*' it makes, and the
  ;; commands that act on the buffers it lists.
  ;;
  ;; In Emacs this file is a thin layer over `tabulated-list-mode' (its
  ;; parent mode, in `tabulated-list.el'), which does the laying out; that
  ;; mode is `(schemacs editor tabulated-list)' here, and it is a subset.
  ;; What `buff-menu.el' contributes, and what is ported below, is the
  ;; seven columns and what goes in them, the filtering of which buffers
  ;; are listed, the mode and its keymap, and the commands.
  ;;
  ;; Three substitutions, each because the thing Emacs uses is not here:
  ;;
  ;;  * **Marks are a table, not text properties.** Emacs puts a tag
  ;;    character in the buffer's text (`tabulated-list-put-tag') and
  ;;    reads the marks back out of the text when it redraws
  ;;    (`Buffer-menu-marked-buffers'). There are no text properties here,
  ;;    so the marks are a table keyed by buffer, and the redraw reads
  ;;    that - the same information with the same effect.
  ;;  * **The column titles are the first line of the text**, not a header
  ;;    line. Emacs puts them in `header-line-format' by default
  ;;    (`Buffer-menu-use-header-line'), and this project has no header
  ;;    line yet; putting them in the text is what Emacs does when that
  ;;    variable is nil, so the layout is Emacs's with that set.
  ;;  * **There are no faces**, so `Buffer-menu--pretty-name' is the name
  ;;    itself; it exists in Emacs only to put a face and a mouse face on
  ;;    it.
  ;;
  ;; Not ported, with what each would need: `Buffer-menu-visit-tags-table'
  ;; (a tags table), `Buffer-menu-view' and `-view-other-window'
  ;; (`view-mode'), `Buffer-menu-1-window' and `-2-window' and
  ;; `Buffer-menu-select' (arranging the frame's windows for a set of
  ;; marked buffers), the unmark-all and mark-backwards commands, the
  ;; files-only and show-internal toggles, the isearch and multi-occur
  ;; commands over marked buffers, and `Buffer-menu-filter-*' (regexps over
  ;; the list).
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    (scheme char)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor command)
          current-prefix-arg define-command)
    
    ;; The line arithmetic is `editfns.c`'s and lives there now.
    (only (schemacs editor editfns)
          char-after eobp forward-line line-beginning-position
          line-end-position point
          text-editor-get-start-of-line
          text-editor-get-end-of-line)
    ;; The list's rows are `tabulated-list.el`'s now, and with them the
    ;; two functions that *edit* a row - which is what a mark is.
    (only (schemacs editor tabulated-list)
          tabulated-list-delete-entry tabulated-list-get-entry
          tabulated-list-set-col)
    (only (schemacs editor frame)
          *current-frame* set!frame-message
          frame-width)
    (only (schemacs editor keymap) define-key *default-keymap*)
    ;; The list's own keys are the buffer's, which is what the lookup
    ;; searches first. `CURRENT-BUFFER' is what the commands act on, and
    ;; it is `(current-buffer)' and not the frame's `current-editor'
    ;; because `list-buffers-noselect' draws the list inside a
    ;; `with-current-buffer', where the window still shows the buffer the
    ;; list was made from - `set-buffer' is what makes the list the
    ;; current buffer there, and `Buffer-menu-beginning' has to put
    ;; *its* point on the first line.
    (only (schemacs editor buffer)
          buffer-list buffer-live-p buffer-local-value
          buffer-name bury-buffer current-buffer get-buffer-create
          set!buffer-local-keymap
          set-buffer-local-value!
          with-current-buffer set-point buffer-modified-p set-buffer-modified-p buffer-read-only? buffer-beg buffer-z set!buffer-read-only text-editor-file-name)
    ;; `quit-window' is `window.el''s and lives in `(schemacs editor
    ;; window)'; this library binds it and does not define it.
    (only (schemacs editor window)
          display-buffer quit-window
          switch-to-buffer switch-to-buffer-other-window)
    ;; `Buffer-menu-execute' saves the buffers marked `s' with
    ;; `save-buffer', as Emacs's does - in the buffer, so it writes that
    ;; buffer's own file.
    ;; `kill-buffer' is `files.scm`'s - **the command**, not the
    ;; mechanism: GNU Emacs's `Buffer-menu-execute` calls `kill-buffer`
    ;; (`buff-menu.el:619`), which is `Fkill_buffer` and asks
    ;; `kill-buffer--possibly-save` when the buffer is modified. This
    ;; imported `buffer`'s half of the tree's split until 2026-10-14, so
    ;; `x` on a modified buffer killed it without asking.
    (only (schemacs editor files)
          abbreviate-file-name kill-buffer revert-buffer save-buffer)
    ;; `g' in the Buffer List runs the GLOBAL `revert-buffer' - in
    ;; Emacs `g' is inherited from `special-mode-map' and runs the
    ;; global command, which dispatches through the buffer-local
    ;; `revert-buffer-function' to the refresh below.
    (only (schemacs editor tabulated-list)
          *tabulated-list-entries* *tabulated-list-format*
          tabulated-list-get-id tabulated-list-print)
    )

  (export
   Buffer-menu-beginning
   Buffer-menu-buffer
   Buffer-menu-bury
   Buffer-menu-delete
   Buffer-menu-execute
   Buffer-menu-redraw!
   Buffer-menu-mark
   Buffer-menu-not-modified
   Buffer-menu-other-window
   Buffer-menu-save
   Buffer-menu-switch-other-window
   Buffer-menu-this-window
   Buffer-menu-toggle-read-only
   Buffer-menu-unmark
   *Buffer-menu-del-char*
   *Buffer-menu-marker-char*
   *Buffer-menu-mode-width*
   *Buffer-menu-name-width*
   *Buffer-menu-size-width*
   buffer-menu
   buffer-menu-mode-map
   list-buffers
   list-buffers--refresh
   list-buffers-noselect
   )

  (begin

    ;;----------------------------------------------------------------
    ;; What the menu is made of

    (define *Buffer-menu-marker-char* #\>)
    (define *Buffer-menu-del-char* #\D)
    (define *Buffer-menu-save-char* #\S)
    ;; ^ GNU Emacs's `Buffer-menu-marker-char' (the `m' mark: show this
    ;; buffer), `Buffer-menu-del-char' (the `d' mark: kill it) and the `S'
    ;; that `Buffer-menu-save' puts in the M column.

    (define (Buffer-menu-marked-buffers ed)
      ;; GNU Emacs's `Buffer-menu-marked-buffers' (`buff-menu.el:645'):
      ;; the buffers whose line carries a `>' tag.
      ;;
      ;; **The tags are read back out of the text**, line by line, because
      ;; that is where they live - there is no table of marks. This is what
      ;; makes `>' survive a redraw and the `d' and `s' tags not:
      ;; `list-buffers--refresh' rebuilds the C column from this list and
      ;; from nothing else, so a redraw restores `>' and loses the rest.
      ;; That is Emacs's own behaviour, measured - `d` then `g` leaves the
      ;; line blank - and it was **not** this tree's until 2026-10-14,
      ;; because the marks were kept in an alist that nothing ever
      ;; cleared.
      ;;
      ;; The C searches with `(re-search-forward "^>" nil t)'; the tag is
      ;; the line's first character, so the walk tests the character.
      ;;--------------------------------------------------------------
      (with-current-buffer ed
        (Buffer-menu-beginning)
        (let loop ((buffers '()))
          (cond
           ((eobp) (reverse buffers))
           (else
            (let ((buffer (tabulated-list-get-id ed))
                  (c (char-after (line-beginning-position))))
              (forward-line 1)
              (loop (if (and buffer c (char=? c *Buffer-menu-marker-char*))
                        (cons buffer buffers)
                        buffers))))))))

    (define (Buffer-menu--unmark ed mark)
      ;; GNU Emacs's `Buffer-menu--unmark' (`buff-menu.el:509'): "Remove
      ;; MARK in current entry. If MARK is RET remove all marks." A mark
      ;; can be in column 0 (the C tag) or column 2 (the M tag), so both
      ;; are cleared - and the `*' of a modified buffer is put back in
      ;; column 2, which is the C's "Reset modified mark".
      ;;--------------------------------------------------------------
      (let ((entry (tabulated-list-get-entry ed)))
        (when entry
          (for-each
           (lambda (col)
             (when (or (char=? mark #\return)
                       (char=? mark (string-ref (list-ref entry col) 0)))
               (tabulated-list-set-col ed col " " #t)))
           (list 0 2))
          (let ((buffer (Buffer-menu-buffer)))
            (when (and buffer (buffer-modified-p buffer)
                       (string=? (list-ref entry 2) " "))
              (tabulated-list-set-col ed 2 "*" #t))))))

    (define *Buffer-menu-size-width* 7)
    (define *Buffer-menu-mode-width* 16)
    (define *Buffer-menu-name-width*
      ;; GNU Emacs's `Buffer-menu-name-width', whose default is
      ;; `Buffer-menu--dynamic-name-width': the window's width divided by
      ;; 4.2, but never narrower than 19 characters and never wider than
      ;; the longest name.
      ;;--------------------------------------------------------------
      #f)

    (define (Buffer-menu--dynamic-name-width buffers)
      ;; The width of the name column for these buffers: GNU Emacs's
      ;; `Buffer-menu--dynamic-name-width'.
      ;;--------------------------------------------------------------
      (max 19
           (min (exact (truncate (/ (frame-width (*current-frame*)) 4.2)))
                (let loop ((rest buffers) (widest 0))
                  (if (null? rest)
                      widest
                      (loop (cdr rest)
                            (max widest
                                 (string-length (buffer-name (car rest))))))))))

    (define (Buffer-menu-name-width buffers)
      (if *Buffer-menu-name-width*
          *Buffer-menu-name-width*
          (Buffer-menu--dynamic-name-width buffers)))

    (define (Buffer-menu--pretty-name name)
      ;; GNU Emacs's `Buffer-menu--pretty-name', which puts a face and a
      ;; mouse face on the name. There are no faces here, so it answers
      ;; with the name.
      ;;--------------------------------------------------------------
      name)

    (define (Buffer-menu--pretty-file-name file buffer)
      ;; GNU Emacs's `Buffer-menu--pretty-file-name' (`buff-menu.el:890'):
      ;; the file the buffer visits, shortened - "~" for the home
      ;; directory - or the directory a dired buffer is showing, or
      ;; nothing at all.
      ;;
      ;; **`(bound-and-true-p list-buffers-directory)' is a buffer-local
      ;; read here**, and the BUFFER is passed for it: Emacs's row runs
      ;; inside a `with-current-buffer', and this tree's row takes its
      ;; buffer explicitly. `list-buffers-directory' is `menu-bar.el''s
      ;; (`:2404') and is set by dired (`dired.el:2913', to the directory
      ;; it lists) and by `cd' (`files.el:981') - a buffer that visits no
      ;; file can still have something to show in this column. It is not
      ;; *defined* anywhere here, because this tree's buffer-local
      ;; variables are a per-buffer table keyed by a symbol: reading one
      ;; that was never set answers the default, as Emacs's unbound-but-
      ;; nil variable does.
      ;;--------------------------------------------------------------
      (cond (file (abbreviate-file-name file))
            ((buffer-local-value buffer 'list-buffers-directory #f)
             => abbreviate-file-name)
            (else "")))

    (define (Buffer-menu--row-for buffer old-buffer marked)
      ;; One row of the list: the seven fields of GNU Emacs's
      ;; `list-buffers--refresh', as strings.
      ;;
      ;;   C  `.` for the buffer the list was made from, `>` for one marked
      ;;      to be shown, `D' for one marked for deletion, else a space
      ;;   R  `%' when the buffer is read-only
      ;;   M  `*' when it is modified, `S' when it is marked for saving
      ;;      then the name, the size in characters, the major mode, and
      ;;      the file it visits
      ;;
      ;; The mode column says `Fundamental' for every buffer, because this
      ;; editor has no major modes yet: Emacs asks the buffer for its
      ;; `mode-name'. It is a row of its own here so that when modes exist
      ;; this is the one place that changes.
      ;;--------------------------------------------------------------
      (list (cond ((eq? buffer old-buffer) ".")
                  ((memq buffer marked) ">")
                  (else " "))
            (if (buffer-read-only? buffer) "%" " ")
            ;; **`S' is not among these**, and its absence is the point:
            ;; Emacs's `list-buffers--refresh' builds the M column from
            ;; `(buffer-modified-p)' alone, so the `s' tag is *lost* by a
            ;; redraw. Measured, and copied.
            (if (buffer-modified-p buffer) "*" " ")
            (Buffer-menu--pretty-name (buffer-name buffer))
            (number->string (- (buffer-z buffer) (buffer-beg buffer)))
            "Fundamental"
            (Buffer-menu--pretty-file-name (text-editor-file-name buffer)
                                           buffer)))

    (define (Buffer-menu--listed? buffer)
      ;; Whether the list shows this buffer: GNU Emacs's filter, which is
      ;; "not a buffer whose name starts with a space" - those are its
      ;; internal buffers - and never the list buffer itself.
      ;;--------------------------------------------------------------
      (let ((name (buffer-name buffer)))
        (and (> (string-length name) 0)
             (not (char=? (string-ref name 0) #\space))
             (not (string=? name "*Buffer List*")))))

    (define (list-buffers--refresh . args)
      ;; The rows of the buffer list, which is what the mode calls for its
      ;; entries: GNU Emacs's `list-buffers--refresh'. The optional
      ;; argument is the buffer the list was made from, which its line
      ;; marks with `.` - Emacs passes `(current-buffer)' from
      ;; `list-buffers-noselect'.
      ;;--------------------------------------------------------------
      (let* ((old-buffer (if (pair? args) (car args) (current-buffer)))
             (menu (if (and (pair? args) (pair? (cdr args)))
                       (cadr args)
                       (current-buffer)))
             ;; **The `>' tags are read out of the text *before* the rows
             ;; are made**: the redraw that follows rewrites every line, and
             ;; the tags are only in the text - GNU Emacs's
             ;; `(marked-buffers (Buffer-menu-marked-buffers))', the first
             ;; binding of its `list-buffers--refresh'.
             (marked (Buffer-menu-marked-buffers menu)))
        (let loop ((rest (buffer-list)) (entries '()))
          (cond ((null? rest) (reverse entries))
                ((Buffer-menu--listed? (car rest))
                 (loop (cdr rest)
                       (cons (cons (car rest)
                                   (Buffer-menu--row-for (car rest) old-buffer
                                                         marked))
                             entries)))
                (else (loop (cdr rest) entries))))))

    (define (list-buffers-noselect)
      ;; The `*Buffer List*' buffer, filled in and set up: GNU Emacs's
      ;; `list-buffers-noselect'. The buffer is made once and redrawn
      ;; afterwards, so that a window already showing it goes on showing
      ;; it.
      ;;--------------------------------------------------------------
      (let ((old-buffer (current-buffer))
            (buffer (get-buffer-create "*Buffer List*")))
        (with-current-buffer buffer
          (set!buffer-local-keymap buffer buffer-menu-mode-map)
          ;; `tabulated-list-mode' sets `revert-buffer-function' to
          ;; `tabulated-list-revert' (tabulated-list.el:872), which
          ;; runs the `tabulated-list-revert-hook' and prints again -
          ;; and buff-menu.el puts `list-buffers--refresh' on that
          ;; hook. The same dispatch is one closure here: the entries
          ;; thunk is a parameter whose value was set in THIS call, so
          ;; the closure carries the asking buffer with it rather than
          ;; re-reading the parameter stale.
          (set-buffer-local-value!
           buffer 'revert-buffer-function
           (lambda (ignore-auto noconfirm)
             (*tabulated-list-entries*
              (lambda () (list-buffers--refresh old-buffer buffer)))
             (Buffer-menu-redraw! buffer)
             #t))
          ;; The buffer has to be writable while it is being drawn, as
          ;; Emacs's table code needs `inhibit-read-only' to write into a
          ;; read-only buffer; it is left read-only, which is what
          ;; `special-mode' - the parent of Emacs's `tabulated-list-mode' -
          ;; makes it.
          (*tabulated-list-format*
           ;; **GNU Emacs's own format** (`buff-menu.el:860'), its
           ;; `:pad-right' and `:right-align' included: the C and R columns
           ;; are packed hard against each other so the header reads
           ;; "CRM", the M column keeps its space (which is the gap before
           ;; the name), the size is right-aligned in its column so the
           ;; digits line up, and the File column is last so it is never
           ;; padded or truncated.
           (list (list "C" 1 #f ':pad-right 0)
                 (list "R" 1 #f ':pad-right 0)
                 (list "M" 1 #f)
                 (list "Buffer" (Buffer-menu-name-width (buffer-list)) #f)
                 (list "Size" *Buffer-menu-size-width* #f ':right-align #t)
                 (list "Mode" *Buffer-menu-mode-width* #f)
                 (list "File" 1 #f)))
          (*tabulated-list-entries*
           (lambda () (list-buffers--refresh old-buffer buffer)))
          (Buffer-menu-redraw! buffer)
          buffer)))

    (define (Buffer-menu-redraw! buffer)
      ;; Draw BUFFER's lines again, titles and rows, and leave point at the
      ;; first row: Emacs redraws through `tabulated-list-print', which is
      ;; what makes the entries again. The titles come from the format, as
      ;; they do in Emacs - `tabulated-list-print' draws them.
      ;;--------------------------------------------------------------
      (set!buffer-read-only buffer #f)
      (tabulated-list-print buffer)
      (set!buffer-read-only buffer #t)
      (Buffer-menu-beginning))

    (define-command (list-buffers)
      ;; GNU Emacs's `list-buffers' (C-x C-b): show the list in another
      ;; window, leaving the selected window and point alone. Emacs
      ;; displays it without selecting it - use `C-x o' to get there, or
      ;; the `BUFFER-MENU' command, which selects it.
      ;;--------------------------------------------------------------
      
      "Display a list of existing buffers (bound to C-x C-b)."
      (interactive)
 (display-buffer (list-buffers-noselect)))
    (define-command (buffer-menu)
      ;; GNU Emacs's `buffer-menu', which shows the list *and* selects it,
      ;; so that its commands act on it with no `C-x o' first.
      ;;--------------------------------------------------------------
      
      "Switch to the Buffer Menu."
      (interactive)

         (switch-to-buffer (list-buffers-noselect)))
    (define (Buffer-menu-beginning)
      ;; Put point at the first buffer's line, past the titles: GNU Emacs's
      ;; `Buffer-menu-beginning', which goes to the beginning of the buffer
      ;; and then one line forward - the titles being a line of the text
      ;; when `Buffer-menu-use-header-line' is nil, which is the layout
      ;; this project has.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (set-point ed (buffer-beg ed))
        ;; the newline ending the titles' line is the last character on it,
        ;; so one past it is the first character of the first buffer's line
        (set-point
         ed (min (buffer-z ed)
                 (+ 1 (text-editor-get-end-of-line ed))))))

    (define (Buffer-menu-buffer)
      ;; The buffer on the line point is on, or #f when the line is not a
      ;; buffer's: GNU Emacs's `Buffer-menu-buffer', which asks
      ;; `tabulated-list-get-id' for the line's entry. What the entries
      ;; carry in their ID slot is the buffer itself
      ;; (`list-buffers--refresh'), so it is the answer.
      ;;--------------------------------------------------------------
      (tabulated-list-get-id (current-buffer)))

    (define (Buffer-menu--move-down!)
      (let ((ed (current-buffer)))
        (set-point
         ed (min (buffer-z ed)
                 (+ 1 (text-editor-get-end-of-line ed))))))

    (define-command (Buffer-menu-mark)
      ;; GNU Emacs's `Buffer-menu-mark' (m): mark the buffer on this line
      ;; to be shown, and go on to the next one.
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line for display (m)."
      (interactive)

         (when (Buffer-menu-buffer)
           (tabulated-list-set-col (current-buffer) 0
                                   (string *Buffer-menu-marker-char*) #t))
         (Buffer-menu--move-down!))
    (define-command (Buffer-menu-delete count)
      ;; GNU Emacs's `Buffer-menu-delete' (d, k): mark the buffer on this
      ;; line for deletion, and go on to the next one. Nothing is killed
      ;; until `Buffer-menu-execute' (x).
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line for deletion (d)."
      (interactive "p")

         (when (Buffer-menu-buffer)
           (tabulated-list-set-col (current-buffer) 0
                                   (string *Buffer-menu-del-char*) #t))
         (Buffer-menu--move-down!))
    (define-command (Buffer-menu-unmark)
      ;; GNU Emacs's `Buffer-menu-unmark' (u): take every mark off this
      ;; line, and go on to the next one.
      ;;--------------------------------------------------------------
      
      "Remove all marks from this line (u)."
      (interactive)

         (when (Buffer-menu-buffer)
           (Buffer-menu--unmark (current-buffer) #\return))
         (Buffer-menu--move-down!))
    (define-command (Buffer-menu-save)
      ;; GNU Emacs's `Buffer-menu-save' (s): mark the buffer on this line
      ;; to be saved, and go on to the next one. (Marking it says so in
      ;; the M column; `Buffer-menu-execute' does the saving, which needs
      ;; `files.el''s `save-buffer' and the frame's file.)
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line to be saved (s)."
      (interactive)

         (when (Buffer-menu-buffer)
           (tabulated-list-set-col (current-buffer) 2 "S" #t))
         (Buffer-menu--move-down!))
    (define-command (Buffer-menu-not-modified arg)
      ;; GNU Emacs's `Buffer-menu-not-modified' (`buff-menu.el:585'):
      ;;
      ;;     (interactive "P" Buffer-menu-mode)
      ;;     (with-current-buffer (Buffer-menu-buffer t)
      ;;       (set-buffer-modified-p arg))
      ;;
      ;; ARG is the raw prefix, and a non-nil one marks the buffer
      ;; *modified* rather than unmodified - `set-buffer-modified-p'
      ;; treats any non-nil as "modified". Emacs then updates column 2
      ;; with `tabulated-list-set-col'; this redraws the list.
      ;;--------------------------------------------------------------
      "Mark the buffer on this line as unmodified (no changes to save).
If ARG is non-nil (interactively, with a prefix argument), mark
it as modified."
      (interactive (list (current-prefix-arg)))
      (let ((buffer (Buffer-menu-buffer)))
        (when buffer
          (with-current-buffer buffer
            (set-buffer-modified-p arg))))
      (Buffer-menu-redraw! (current-buffer)))
    (define-command (Buffer-menu-bury)
      ;; GNU Emacs's `Buffer-menu-bury' (b): move the buffer on this line
      ;; to the end of the buffer list, so that `other-buffer' does not
      ;; choose it.
      ;;--------------------------------------------------------------
      
      "Bury the buffer on this line (b)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer (bury-buffer buffer)))
         (Buffer-menu-redraw! (current-buffer)))
    (define-command (Buffer-menu-toggle-read-only)
      ;; GNU Emacs's `Buffer-menu-toggle-read-only': do in the buffer on
      ;; this line what `read-only-mode' does.
      ;;--------------------------------------------------------------
      
      "Toggle whether the buffer on this line can be changed."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (set!buffer-read-only buffer
                                         (not (buffer-read-only? buffer)))))
         (Buffer-menu-redraw! (current-buffer)))
    (define-command (Buffer-menu-this-window)
      ;; GNU Emacs's `Buffer-menu-this-window' (RET, f): show the buffer on
      ;; this line in the selected window, replacing the list.
      ;;--------------------------------------------------------------
      
      "Select the buffer on this line (RET)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (switch-to-buffer buffer))))
    (define-command (Buffer-menu-other-window)
      ;; GNU Emacs's `Buffer-menu-other-window' (o): show the buffer on
      ;; this line in the *other* window and select that window, so that
      ;; the Buffer Menu is left where it is - which is the point of the
      ;; command, and what makes it different from RET.
      ;;
      ;; Emacs binds `display-buffer-overriding-action' to an action that
      ;; refuses the selected window for the call; this library states the
      ;; same thing by passing the action to `display-buffer' directly,
      ;; there being no such variable here.
      ;;--------------------------------------------------------------
      
      "Select the buffer on this line in the other window (o)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (switch-to-buffer-other-window buffer))))
    (define-command (Buffer-menu-switch-other-window)
      ;; GNU Emacs's `Buffer-menu-switch-other-window' (C-o): make the
      ;; other window show the buffer on this line, but leave point in the
      ;; Buffer Menu - so the menu stays selected and more lines can be
      ;; looked at without coming back.
      ;;--------------------------------------------------------------
      
      "Show the buffer on this line in the other window (C-o)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (display-buffer buffer '(nil (inhibit-same-window . #t))))))
    (define-command (Buffer-menu-execute)
      ;; GNU Emacs's `Buffer-menu-execute' (x): do what the marks say -
      ;; save the buffers marked with `s', kill the ones marked with `d'
      ;; - and redraw the list.
      ;;
      ;; A `>' mark means "show this buffer" and is not acted on here, so
      ;; it is left on the line, as Emacs leaves it. A mark is taken off
      ;; as it is acted on, and a buffer whose saving or killing did not
      ;; happen keeps its mark.
      ;;
      ;; Emacs walks the list a line at a time; the marks are a table
      ;; here and not text, so what it walks is the marks. The same marks
      ;; and the same work either way.
      ;;
      ;; The killing asks the buffer's own question, which is
      ;; `kill-buffer-query-functions': a refusal leaves the buffer alone
      ;; - and Emacs will not kill the buffer the list is being used from
      ;; either, which is `(not (eq buffer (current-buffer)))' there.
      ;; Saving is `save-buffer' in the buffer, as Emacs's
      ;; `(with-current-buffer buffer (save-buffer))' is: it writes the
      ;; buffer's own file, not the frame's.
      ;;--------------------------------------------------------------
      
      "Save and kill the buffers marked in the Buffer Menu (x)."
      (interactive)

         (let ((frame (*current-frame*))
               (ed (current-buffer))
               (killed 0)
               (saved 0)
               (failed '()))
           ;; **The list is walked a line at a time**, which is how Emacs's
           ;; `Buffer-menu-execute' walks it: the marks are characters in
           ;; the text, so the text is what says what to do. The character
           ;; at point is the C column - the tag - and column 2 of the
           ;; line's entry is the M column.
           ;;
           ;; (Emacs wraps the walk in `save-excursion'; here the walk ends
           ;; with a redraw, which puts point back at the first line
           ;; itself.)
           (with-current-buffer ed
             (Buffer-menu-beginning)
             (let loop ()
               (unless (eobp)
                 (let ((buffer (tabulated-list-get-id ed))
                       (entry (tabulated-list-get-entry ed)))
                   (cond
                    ((not entry) (forward-line 1))
                    ((not (buffer-live-p buffer))
                     ;; the buffer is gone: its line goes with it
                     (tabulated-list-delete-entry ed))
                    (else
                     (let ((delete? (char=? (char-after (point))
                                            *Buffer-menu-del-char*)))
                       (when (string=? (list-ref entry 2) "S")
                         (guard (ex (else (set! failed
                                                (cons (buffer-name buffer)
                                                      failed))))
                           (with-current-buffer buffer (save-buffer))
                           (tabulated-list-set-col ed 2 " " #t)
                           (set! saved (+ 1 saved))))
                       (if (and delete?
                                (not (eq? buffer ed))
                                (kill-buffer buffer))
                           (tabulated-list-delete-entry ed)
                           (forward-line 1))))))
                 (loop))))
           (Buffer-menu-redraw! ed)
           (set!frame-message
            frame
            (cond ((pair? failed)
                   (string-append "Error saving: "
                                  (apply string-append
                                         (map (lambda (name)
                                                (string-append name " "))
                                              failed))))
                  ((> saved 0)
                   (string-append (number->string saved) " buffer(s) saved"))
                  ((> killed 0)
                   (string-append (number->string killed)
                                  " buffer(s) killed"))
                  (else "No buffers marked for deletion or saving")))))
    (define-command (Buffer-menu-next-line count)
      ;; GNU Emacs's list binds `n' and SPC to `next-line'.
      ;;--------------------------------------------------------------
      
      "Move to the next line (n)."
      (interactive "p")

         (let loop ((n count))
           (when (> n 0) (Buffer-menu--move-down!) (loop (- n 1)))))
    (define-command (Buffer-menu-previous-line count)
      
      "Move to the previous line (p)."
      (interactive "p")

         (let loop ((n count))
           (when (> n 0)
             (let ((ed (current-buffer)))
               (set-point
                ed (max (buffer-beg ed)
                        (- (text-editor-get-start-of-line ed) 2))))
             (loop (- n 1)))))
    (define buffer-menu-mode-map
      ;; GNU Emacs's `Buffer-menu-mode-map', with the keys read from a
      ;; terminal Emacs: q, d, k, C-k, x, u, m, s, b, ~, %, g, RET, f, e,
      ;; o, C-o, n, SPC and p. The ones Emacs binds that are not here are
      ;; the ones whose commands are not ported - `t'
      ;; (`Buffer-menu-visit-tags-table'), the view commands, `1' and `2'
      ;; and `v' (they arrange the frame's windows), the unmark-all and
      ;; mark-backwards commands, the files-only and show-internal
      ;; toggles, and the isearch and multi-occur commands over marked
      ;; buffers.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*buffer-menu-mode-map*)))
        (define (bind! key command)
          ;; a key is written the way Emacs writes it, as `kbd' reads it:
          ;; `"q"', `"C-k"', `"M-x"', `"<up>"'
          (define-key map (kbd key) command))
        (bind! "q" quit-window)
        (bind! "d" Buffer-menu-delete)
        (bind! "k" Buffer-menu-delete)
        (bind! "C-k" Buffer-menu-delete)
        (bind! "x" Buffer-menu-execute)
        (bind! "u" Buffer-menu-unmark)
        (bind! "m" Buffer-menu-mark)
        (bind! "s" Buffer-menu-save)
        (bind! "b" Buffer-menu-bury)
        (bind! "~" Buffer-menu-not-modified)
        (bind! "%" Buffer-menu-toggle-read-only)
        (bind! "g" revert-buffer)
        ;; RET is the event `control-M' (13) and not the character
        ;; `#\return': a terminal sends the byte 13, and the key event
        ;; for it is control-M. Emacs's keymap has the same key - RET and C-m are one
        ;; key there too - which is why `(key-binding "\r")' finds it.
        (bind! "C-m" Buffer-menu-this-window)
        (bind! "f" Buffer-menu-this-window)
        (bind! "e" Buffer-menu-this-window)
        (bind! "o" Buffer-menu-other-window)
        (bind! "C-o" Buffer-menu-switch-other-window)
        (bind! "n" Buffer-menu-next-line)
        (bind! "SPC" Buffer-menu-next-line)
        (bind! "p" Buffer-menu-previous-line)
        map))

    ;;----------------------------------------------------------------
    ;; The keys

    (define-key *default-keymap* (kbd "C-x C-b")
      list-buffers)

    ))