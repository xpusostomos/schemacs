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
  ;; (`view-mode'), `Buffer-menu-1-window' and `-2-window' (arranging the
  ;; frame's windows for a set of marked buffers), the isearch and
  ;; multi-occur commands over marked buffers, `Buffer-menu-filter-*'
  ;; (regexps over the list), and the `-other-window' variants (they need
  ;; `switch-to-buffer-other-window', which is `window.el''s and not here
  ;; yet).
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor command)
          new-command new-count-command uarg->integer)
    (only (schemacs editor engine)
          text-editor-get-cursor text-editor-set-cursor text-editor-modified?
          text-editor-set-modified! text-editor-read-only?
          text-editor-set-read-only! text-editor-char-count
          text-editor-file-name text-editor-buffer-name text-editor-insert
          text-editor-delete-from-cursor text-editor-undo-disable!
          text-editor-undo-enable! text-editor-get-start-of-line
          text-editor-get-end-of-line)
    (only (schemacs editor frame)
          *current-frame* set!ncurses-frame-message
          ncurses-frame-selected-window frame-width window-buffer window-list)
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
          buffer-list buffer-live-p buffer-local-keymap buffer-modified-p
          buffer-name bury-buffer current-buffer get-buffer-create
          kill-buffer set!buffer-local-keymap set!buffer-name
          with-current-buffer)
    (only (schemacs editor window)
          delete-window display-buffer get-buffer-window)
    ;; `Buffer-menu-execute' saves the buffers marked `s' with
    ;; `save-buffer', as Emacs's does - in the buffer, so it writes that
    ;; buffer's own file.
    (only (schemacs editor files) save-buffer switch-to-buffer!)
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
   Buffer-menu-save
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
   quit-window
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

    (define (Buffer-menu--pretty-file-name file)
      ;; GNU Emacs's `Buffer-menu--pretty-file-name': the file without its
      ;; directory, or the empty string for a buffer visiting no file.
      ;; (`abbreviate-file-name' is not here; Emacs shortens a long
      ;; directory to `~' and elides what is in the middle.)
      ;;--------------------------------------------------------------
      (or file ""))

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
              (Buffer-menu--pretty-file-name (text-editor-file-name buffer)))))

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

    (define list-buffers
      ;; GNU Emacs's `list-buffers' (C-x C-b): show the list in another
      ;; window, leaving the selected window and point alone. Emacs
      ;; displays it without selecting it - use `C-x o' to get there, or
      ;; the `BUFFER-MENU' command, which selects it.
      ;;--------------------------------------------------------------
      (new-command
       "list-buffers"
       (lambda () (display-buffer (list-buffers-noselect)))
       (lambda () #f)
       "Display a list of existing buffers (bound to C-x C-b)."))

    (define buffer-menu
      ;; GNU Emacs's `buffer-menu', which shows the list *and* selects it,
      ;; so that its commands act on it with no `C-x o' first.
      ;;--------------------------------------------------------------
      (new-command
       "buffer-menu"
       (lambda ()
         (switch-to-buffer! (*current-frame*) (list-buffers-noselect)))
       (lambda () #f)
       "Switch to the Buffer Menu."))

    (define (Buffer-menu-beginning)
      ;; Put point at the first buffer's line, past the titles: GNU Emacs's
      ;; `Buffer-menu-beginning', which goes to the beginning of the buffer
      ;; and then one line forward - the titles being a line of the text
      ;; when `Buffer-menu-use-header-line' is nil, which is the layout
      ;; this project has.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer)))
        (text-editor-set-cursor ed 0)
        ;; the newline ending the titles' line is the last character on it,
        ;; so one past it is the first character of the first buffer's line
        (text-editor-set-cursor
         ed (min (text-editor-char-count ed)
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
         ed (min (text-editor-char-count ed)
                 (+ 1 (text-editor-get-end-of-line ed))))))

    (define Buffer-menu-mark
      ;; GNU Emacs's `Buffer-menu-mark' (m): mark the buffer on this line
      ;; to be shown, and go on to the next one.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-mark"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-marker-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
       (lambda () #f)
       "Mark the buffer on this line for display (m)."))

    (define Buffer-menu-delete
      ;; GNU Emacs's `Buffer-menu-delete' (d, k): mark the buffer on this
      ;; line for deletion, and go on to the next one. Nothing is killed
      ;; until `Buffer-menu-execute' (x).
      ;;--------------------------------------------------------------
      (new-count-command
       "Buffer-menu-delete"
       (lambda (count)
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-del-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
       "Mark the buffer on this line for deletion (d)."))

    (define Buffer-menu-unmark
      ;; GNU Emacs's `Buffer-menu-unmark' (u): take every mark off this
      ;; line, and go on to the next one.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-unmark"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer #f)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
       (lambda () #f)
       "Remove all marks from this line (u)."))

    (define Buffer-menu-save
      ;; GNU Emacs's `Buffer-menu-save' (s): mark the buffer on this line
      ;; to be saved, and go on to the next one. (Marking it says so in
      ;; the M column; `Buffer-menu-execute' does the saving, which needs
      ;; `files.el''s `save-buffer' and the frame's file.)
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-save"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (Buffer-menu--set-mark! buffer *Buffer-menu-save-char*)
             (Buffer-menu-redraw! (current-buffer)))
           (Buffer-menu--move-down!)))
       (lambda () #f)
       "Mark the buffer on this line to be saved (s)."))

    (define Buffer-menu-not-modified
      ;; GNU Emacs's `Buffer-menu-not-modified' (~): say the buffer on this
      ;; line has not been changed, so that saving it is not offered.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-not-modified"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer (text-editor-set-modified! buffer #f))
           (Buffer-menu-redraw! (current-buffer))))
       (lambda () #f)
       "Clear the buffer's modified flag (~)."))

    (define Buffer-menu-bury
      ;; GNU Emacs's `Buffer-menu-bury' (b): move the buffer on this line
      ;; to the end of the buffer list, so that `other-buffer' does not
      ;; choose it.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-bury"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer (bury-buffer buffer)))
         (Buffer-menu-redraw! (current-buffer)))
       (lambda () #f)
       "Bury the buffer on this line (b)."))

    (define Buffer-menu-toggle-read-only
      ;; GNU Emacs's `Buffer-menu-toggle-read-only': do in the buffer on
      ;; this line what `read-only-mode' does.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-toggle-read-only"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (text-editor-set-read-only! buffer
                                         (not (text-editor-read-only? buffer)))))
         (Buffer-menu-redraw! (current-buffer)))
       (lambda () #f)
       "Toggle whether the buffer on this line can be changed."))

    (define Buffer-menu-this-window
      ;; GNU Emacs's `Buffer-menu-this-window' (RET, f): show the buffer on
      ;; this line in the selected window, replacing the list.
      ;;--------------------------------------------------------------
      (new-command
       "Buffer-menu-this-window"
       (lambda ()
         (let ((buffer (Buffer-menu-buffer)))
           (when buffer
             (switch-to-buffer! (*current-frame*) buffer))))
       (lambda () #f)
       "Select the buffer on this line (RET)."))

    (define Buffer-menu-execute
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
      (new-command
       "Buffer-menu-execute"
       (lambda ()
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
           (set!ncurses-frame-message
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
       (lambda () #f)
       "Save and kill the buffers marked in the Buffer Menu (x)."))

    (define (quit-window)
      ;; GNU Emacs's `quit-window' (q in the Buffer Menu), which is
      ;; `window.el''s: take this window off the frame and bury the buffer
      ;; it was showing. A frame's only window cannot be removed, and then
      ;; the buffer is just buried.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (window (ncurses-frame-selected-window frame))
             (buffer (window-buffer window)))
        (bury-buffer buffer)
        (if (> (length (window-list)) 1)
            (delete-window window)
            #f)))

    (define Buffer-menu-quit
      (new-command
       "quit-window"
       (lambda () (quit-window))
       (lambda () #f)
       "Remove the Buffer Menu from the display (q)."))

    (define Buffer-menu-revert
      (new-command
       "revert-buffer"
       (lambda () (Buffer-menu-redraw! (current-buffer)))
       (lambda () #f)
       "Update the list of buffers (g)."))

    (define Buffer-menu-next-line
      ;; GNU Emacs's list binds `n' and SPC to `next-line'.
      ;;--------------------------------------------------------------
      (new-count-command
       "next-line"
       (lambda (count)
         (let loop ((n count))
           (when (> n 0) (Buffer-menu--move-down!) (loop (- n 1)))))
       "Move to the next line (n)."))

    (define Buffer-menu-previous-line
      (new-count-command
       "previous-line"
       (lambda (count)
         (let loop ((n count))
           (when (> n 0)
             (let ((ed (current-buffer)))
               (text-editor-set-cursor
                ed (max 0 (- (text-editor-get-start-of-line ed) 2))))
             (loop (- n 1)))))
       "Move to the previous line (p)."))

    (define buffer-menu-mode-map
      ;; GNU Emacs's `Buffer-menu-mode-map', with the keys read from a
      ;; terminal Emacs: q, d, k, C-k, x, u, m, s, b, ~, %, g, RET, f, e,
      ;; n, SPC and p. The ones Emacs binds that are not here are the ones
      ;; whose commands are not ported - `t' (`Buffer-menu-visit-tags-table'),
      ;; the other-window and view commands, `1' and `2' and `v' (they
      ;; arrange the frame's windows, and `2' and `v' need
      ;; `switch-to-buffer-other-window', which `window.el' does not have
      ;; here yet), the unmark-all and mark-backwards commands, the
      ;; files-only and show-internal toggles, and the isearch and
      ;; multi-occur commands over marked buffers.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*buffer-menu-mode-map*)))
        (define (bind! key command)
          ;; a key is a path, as `define-key' takes it: one key, which may
          ;; be a character or a modifier and a character
          (define-key map (if (list? key) key (list key)) command))
        (bind! #\q Buffer-menu-quit)
        (bind! #\d Buffer-menu-delete)
        (bind! #\k Buffer-menu-delete)
        (bind! (list 'ctrl #\k) Buffer-menu-delete)
        (bind! #\x Buffer-menu-execute)
        (bind! #\u Buffer-menu-unmark)
        (bind! #\m Buffer-menu-mark)
        (bind! #\s Buffer-menu-save)
        (bind! #\b Buffer-menu-bury)
        (bind! #\~ Buffer-menu-not-modified)
        (bind! #\% Buffer-menu-toggle-read-only)
        (bind! #\g Buffer-menu-revert)
        ;; RET is `(ctrl #\m)' and not the character `#\return': a
        ;; terminal sends the byte 13, and the keymap path for it is
        ;; control-M. Emacs's keymap has the same key - RET and C-m are one
        ;; key there too - which is why `(key-binding "\r")' finds it.
        (bind! (list 'ctrl #\m) Buffer-menu-this-window)
        (bind! #\f Buffer-menu-this-window)
        (bind! #\e Buffer-menu-this-window)
        (bind! #\n Buffer-menu-next-line)
        (bind! #\space Buffer-menu-next-line)
        (bind! #\p Buffer-menu-previous-line)
        map))

    ;;----------------------------------------------------------------
    ;; The keys

    (define-key *default-keymap* (list (list 'ctrl #\x) (list 'ctrl #\b))
      list-buffers)

    ))