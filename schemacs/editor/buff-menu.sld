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
    (prefix (schemacs keymap) km:)
    (only (schemacs editor command)
          define-command)
    (only (schemacs editor engine)
          text-editor-get-cursor text-editor-set-cursor text-editor-modified?
          text-editor-set-modified! text-editor-read-only?
          text-editor-point-min text-editor-point-max
          text-editor-set-read-only! text-editor-char-count
          text-editor-file-name text-editor-buffer-name text-editor-insert
          text-editor-delete-from-cursor text-editor-undo-disable!
          text-editor-undo-enable! text-editor-get-start-of-line
          text-editor-get-end-of-line)
    (only (schemacs editor frame)
          *current-frame* set!frame-message
          frame-selected-window frame-width window-buffer window-list)
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
          buffer-list buffer-live-p buffer-local-keymap buffer-local-value
          buffer-modified-p
          buffer-name bury-buffer current-buffer get-buffer-create
          kill-buffer set!buffer-local-keymap set!buffer-name
          set-buffer-local-value!
          with-current-buffer)
    ;; `quit-window' is `window.el''s and lives in `(schemacs editor
    ;; window)'; this library binds it and does not define it.
    (only (schemacs editor window)
          delete-window display-buffer get-buffer-window quit-window
          switch-to-buffer switch-to-buffer-other-window)
    ;; `Buffer-menu-execute' saves the buffers marked `s' with
    ;; `save-buffer', as Emacs's does - in the buffer, so it writes that
    ;; buffer's own file.
    (only (schemacs editor files)
          abbreviate-file-name revert-buffer save-buffer)
    ;; `g' in the Buffer List runs the GLOBAL `revert-buffer' - in
    ;; Emacs `g' is inherited from `special-mode-map' and runs the
    ;; global command, which dispatches through the buffer-local
    ;; `revert-buffer-function' to the refresh below.
    (only (schemacs editor tabulated-list)
          *tabulated-list-entries* *tabulated-list-format*
          tabulated-list-get-id tabulated-list-print)
    (only (schemacs editor xdisp) format-mode-line)
    (only (guile) string-index))

  (export
   Buffer-menu-beginning
   Buffer-menu-buffer
   Buffer-menu-bury
   Buffer-menu-delete
   Buffer-menu-execute
   Buffer-menu--set-mark!
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
   *Buffer-menu-marks*
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

    (define *Buffer-menu-marks*
      ;; The mark on each buffer, as (BUFFER . CHARACTER), or none.
      ;;
      ;; Emacs keeps the marks in the buffer's *text* - a tag character in
      ;; the first column - and reads them back out of it when it redraws.
      ;; There are no text properties here, so they are kept here instead.
      ;; It is a parameter so that a test can bind it.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (Buffer-menu--mark-of buffer)
      (let ((entry (assq buffer (*Buffer-menu-marks*))))
        (and entry (cdr entry))))

    (define (Buffer-menu--set-mark! buffer char)
      ;; Put CHAR on BUFFER's line, or take the mark off with #f.
      ;;--------------------------------------------------------------
      (*Buffer-menu-marks*
       (let loop ((rest (*Buffer-menu-marks*)))
         (cond ((null? rest) (if char (list (cons buffer char)) '()))
               ((eq? (caar rest) buffer)
                (if char
                    (cons (cons buffer char) (cdr rest))
                    (cdr rest)))
               (else (cons (car rest) (loop (cdr rest))))))))

    (define (Buffer-menu-marked-buffers)
      ;; The buffers with any mark on them: GNU Emacs's
      ;; `Buffer-menu-marked-buffers', which reads the tags back out of
      ;; the text.
      ;;--------------------------------------------------------------
      (map car (*Buffer-menu-marks*)))

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

    (define (Buffer-menu--row-for buffer old-buffer)
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
      (let ((mark (Buffer-menu--mark-of buffer)))
        (list (cond ((eq? buffer old-buffer) ".")
                    (mark (string mark))
                    (else " "))
              (if (text-editor-read-only? buffer) "%" " ")
              (cond ((eq? mark *Buffer-menu-save-char*) "S")
                    ((text-editor-modified? buffer) "*")
                    (else " "))
              (Buffer-menu--pretty-name (buffer-name buffer))
              (number->string (text-editor-char-count buffer))
              "Fundamental"
              (Buffer-menu--pretty-file-name (text-editor-file-name buffer)
                                                buffer))))

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
      (let ((old-buffer (if (pair? args) (car args) (current-buffer))))
        (let loop ((rest (buffer-list)) (entries '()))
          (cond ((null? rest) (reverse entries))
                ((Buffer-menu--listed? (car rest))
                 (loop (cdr rest)
                       (cons (cons (car rest)
                                   (Buffer-menu--row-for (car rest) old-buffer))
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
              (lambda () (list-buffers--refresh old-buffer)))
             (Buffer-menu-redraw! buffer)
             #t))
          ;; The buffer has to be writable while it is being drawn, as
          ;; Emacs's table code needs `inhibit-read-only' to write into a
          ;; read-only buffer; it is left read-only, which is what
          ;; `special-mode' - the parent of Emacs's `tabulated-list-mode' -
          ;; makes it.
          (*tabulated-list-format*
           (list (list "C" 1 #f) (list "R" 1 #f) (list "M" 1 #f)
                 (list "Buffer" (Buffer-menu-name-width (buffer-list)) #f)
                 (list "Size" *Buffer-menu-size-width* #f)
                 (list "Mode" *Buffer-menu-mode-width* #f)
                 (list "File" 0 #f)))
          (*tabulated-list-entries*
           (lambda () (list-buffers--refresh old-buffer)))
          (Buffer-menu-redraw! buffer)
          buffer)))

    (define (Buffer-menu-redraw! buffer)
      ;; Draw BUFFER's lines again, titles and rows, and leave point at the
      ;; first row: Emacs redraws through `tabulated-list-print', which is
      ;; what makes the entries again. The titles come from the format, as
      ;; they do in Emacs - `tabulated-list-print' draws them.
      ;;--------------------------------------------------------------
      (text-editor-set-read-only! buffer #f)
      (tabulated-list-print buffer)
      (text-editor-set-read-only! buffer #t)
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
        (text-editor-set-cursor ed (text-editor-point-min ed))
        ;; the newline ending the titles' line is the last character on it,
        ;; so one past it is the first character of the first buffer's line
        (text-editor-set-cursor
         ed (min (text-editor-point-max ed)
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
        (text-editor-set-cursor
         ed (min (text-editor-point-max ed)
                 (+ 1 (text-editor-get-end-of-line ed))))))

    (define-command (Buffer-menu-mark)
      ;; GNU Emacs's `Buffer-menu-mark' (m): mark the buffer on this line
      ;; to be shown, and go on to the next one.
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line for display (m)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-marker-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
    (define-command (Buffer-menu-delete count)
      ;; GNU Emacs's `Buffer-menu-delete' (d, k): mark the buffer on this
      ;; line for deletion, and go on to the next one. Nothing is killed
      ;; until `Buffer-menu-execute' (x).
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line for deletion (d)."
      (interactive "p")

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-del-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
    (define-command (Buffer-menu-unmark)
      ;; GNU Emacs's `Buffer-menu-unmark' (u): take every mark off this
      ;; line, and go on to the next one.
      ;;--------------------------------------------------------------
      
      "Remove all marks from this line (u)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer #f)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
    (define-command (Buffer-menu-save)
      ;; GNU Emacs's `Buffer-menu-save' (s): mark the buffer on this line
      ;; to be saved, and go on to the next one. (Marking it says so in
      ;; the M column; `Buffer-menu-execute' does the saving, which needs
      ;; `files.el''s `save-buffer' and the frame's file.)
      ;;--------------------------------------------------------------
      
      "Mark the buffer on this line to be saved (s)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-save-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
    (define-command (Buffer-menu-not-modified)
      ;; GNU Emacs's `Buffer-menu-not-modified' (~): say the buffer on this
      ;; line has not been changed, so that saving it is not offered.
      ;;--------------------------------------------------------------
      
      "Clear the buffer's modified flag (~)."
      (interactive)

         (let ((buffer (Buffer-menu-buffer)))
           (when buffer (text-editor-set-modified! buffer #f))
           (Buffer-menu-redraw! (current-buffer))))
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
             (text-editor-set-read-only! buffer
                                         (not (text-editor-read-only? buffer)))))
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
               (killed 0)
               (saved 0)
               (failed '()))
           (for-each
            (lambda (buffer)
              (let ((mark (Buffer-menu--mark-of buffer)))
                (cond
                 ((eq? mark *Buffer-menu-save-char*)
                  (guard (ex (else (set! failed (cons (buffer-name buffer)
                                                      failed))))
                    (with-current-buffer buffer (save-buffer))
                    (Buffer-menu--set-mark! buffer #f)
                    (set! saved (+ 1 saved))))
                 ((eq? mark *Buffer-menu-del-char*)
                  (when (and (buffer-live-p buffer)
                             (not (eq? buffer (current-buffer)))
                             (kill-buffer buffer))
                    (Buffer-menu--set-mark! buffer #f)
                    (set! killed (+ 1 killed)))))))
            (Buffer-menu-marked-buffers))
           (Buffer-menu-redraw! (current-buffer))
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
               (text-editor-set-cursor
                ed (max (text-editor-point-min ed)
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
        ;; RET is `(ctrl #\m)' and not the character `#\return': a
        ;; terminal sends the byte 13, and the key event for it is
        ;; control-M. Emacs's keymap has the same key - RET and C-m are one
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