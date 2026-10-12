(define-library (schemacs editor undo)
  ;; This library mirrors GNU Emacs's `undo.c': recording a buffer's edits
  ;; so that they can be undone. It is the *recording* half and only that -
  ;; `record_insert`, `record_delete`, `record_point`, `record_first_change`,
  ;; `undo-boundary`, and the undo list they push onto. The procedure that
  ;; *applies* the entries, `primitive-undo`, is `simple.el`'s
  ;; (`simple.el:3650') and stays in `simple.scm`, which is where Emacs has
  ;; it - `undo.c` records and Lisp applies, and the two files are apart in
  ;; Emacs too.
  ;;
  ;; **It sits *below* `insdel.scm`**, which is the point of it having its
  ;; own library: `record_insert` and `record_delete` are what `insdel.c`
  ;; calls as it writes, and with this library below it `insdel.scm` calls
  ;; them directly - the three `*record-*-function*` seams the engine used
  ;; to install are gone. Everything the recorders read is here or below:
  ;; the undo list is a `<buffer>` field, `buffer-pt`/`buffer-modified-p`
  ;; are the buffer's, and the file's modification time arrives through
  ;; `*buffer-visited-file-modtime-function*`, which `buffer.scm` declares
  ;; and `fileio.scm` installs.
  ;;
  ;; The two command parameters - `point_before_last_command_or_undo` and
  ;; `buffer_before_last_command_or_undo` - are `keyboard.c`'s, but they
  ;; are *read* by `record_point` here and *set* by the command loop, so
  ;; they are declared here and `keyboard.scm` imports them.
  ;;
  ;; Entries are Emacs's exactly: `(BEG . END)` an insertion, `(TEXT . POS)`
  ;; a deletion, `(t . TIME)` the mark of the last save, `<integer>` a
  ;; previous point, `()` a change-group boundary. `record_marker_adjustments`
  ;; (`undo.c:126'), `undo_inhibit_record_point` and `record_property_change`
  ;; are not carried.

  (import
    (scheme base)
    (only (schemacs editor buffer)
          text-editor-undo-list set!text-editor-undo-list
          buffer-pt buffer-modified-p current-buffer
          *buffer-visited-file-modtime-function*))

  (export
   record-insert  record-delete  record-first-change
   text-editor-undo-list  set!text-editor-undo-list
   text-editor-undo-boundary!
   text-editor-undo-disable!  text-editor-undo-enable!
   text-editor-undo-recording?
   *undo-limit*
   undo-insertion-entry?  undo-deletion-entry?  undo-modified-entry?
   *point-before-last-command-or-undo*  *buffer-before-last-command-or-undo*)

  (begin
    ;;----------------------------------------------------------------
    ;; Undo
    ;;
    ;; The buffer's undo list is GNU Emacs's `buffer-undo-list': a list
    ;; of the edits that can be undone, NEWEST ENTRY FIRST. The entry
    ;; formats are Emacs's exactly, and the mnemonic is the reverse of
    ;; the obvious one:
    ;;
    ;;   (BEG . END)   text was INSERTED, and now occupies the
    ;;                 characters BEG up to END. Undoing deletes it.
    ;;
    ;;   (TEXT . POS)  TEXT was DELETED from the buffer. `(abs POS)` is
    ;;                 the position to reinsert it at; POS is positive
    ;;                 when point was at the beginning of the deleted
    ;;                 text, negative when it was at the end, which is
    ;;                 what tells undo where to leave point.
    ;;
    ;;   <integer>     a previous value of point. Undoing moves point
    ;;                 there. (Not recorded yet: this buffer has no
    ;;                 markers, and the sign of a deletion's POS
    ;;                 already puts point where it belongs.)
    ;;
    ;;   ()            a boundary (Emacs's `nil'). The entries between
    ;;                 two boundaries are a "change group", which is
    ;;                 what one undo command undoes.
    ;;
    ;; There is no separate redo list. Undoing is itself an edit: it
    ;; runs the ordinary insert and delete primitives, which push the
    ;; inverse entries onto the front of this same list, and those ARE
    ;; the redo records. mg's `undo.c' does the same thing, and says so
    ;; in its comment: "Only when we undo a deletion, the insertion
    ;; will be recorded just as if it was typed on the keyboard.
    ;; Resulting in the inverse operation being saved in the list."
    ;;
    ;; **What this library does NOT have is `primitive-undo'** - the
    ;; procedure that applies these entries, walking the list and running
    ;; the inverse of each one. That is `simple.el`'s (`simple.el:3650'),
    ;; in the same file as the `undo' command itself, and it is there:
    ;; `undo.c` records the entries and Lisp applies them. It was here,
    ;; which put a `simple.el` function in the engine and gave it a buffer
    ;; argument Emacs's does not have.
    ;;
    ;; Entries are recorded by the two recorders below, and only by
    ;; them - `record-insert` and `record-delete`, which are undo.c's
    ;; `record_insert` and `record_delete`. The paragraph that used to
    ;; stand here described the private writers that re-inserted text
    ;; when a line break was put in or taken out, and how they counted
    ;; characters without recording: those writers, the line editor and
    ;; the character count all went with the `buffer-text` conversion,
    ;; and a line break is now a character like any other.
    ;;------------------------------------------------------------------

    (define *undo-limit*
      ;; A simplified stand-in for Emacs's `undo-limit': the greatest
      ;; number of entries kept in an undo list. When it is exceeded,
      ;; whole oldest change groups are discarded, never part of a
      ;; group. Emacs's real policy is three-tiered (soft, strong and
      ;; outer limits, measured in bytes) and is not implemented.
      ;;--------------------------------------------------------------
      (make-parameter 5000))

    (define (text-editor-undo-recording? ed)
      ;; Whether edits to ED are being recorded for undo. Emacs calls
      ;; this state `buffer-undo-list' being other than `t'.
      ;;--------------------------------------------------------------
      (list? (text-editor-undo-list ed)))

    (define (text-editor-undo-disable! ed)
      ;; Stop recording undo information for ED (Emacs's
      ;; `buffer-disable-undo', which sets `buffer-undo-list' to `t').
      ;; The list is dropped: there is nothing left to undo.
      ;;--------------------------------------------------------------
      (set!text-editor-undo-list ed #f))

    (define (text-editor-undo-enable! ed)
      ;; Start recording undo information for ED again, discarding any
      ;; undo information already recorded (Emacs's
      ;; `buffer-enable-undo', which sets `buffer-undo-list' to `nil').
      ;;--------------------------------------------------------------
      (set!text-editor-undo-list ed '()))

    (define (text-editor-undo-boundary! ed)
      ;; Place a boundary in ED's undo list (Emacs's `undo-boundary').
      ;; The undo command stops at a boundary, so the entries between
      ;; two boundaries are undone together. A boundary is never
      ;; recorded twice in a row, and never at the very front of an
      ;; empty list, the way mg's `undo_add_boundary' refuses to.
      ;;--------------------------------------------------------------
      (let ((list (text-editor-undo-list ed)))
        (when (and (list? list)
                   (pair? list)
                   (not (null? (car list))))
          (set!text-editor-undo-list ed (cons '() list))))
      ;; the C's last two lines of `Fundo_boundary` (`undo.c:278'):
      ;; "point_before_last_command_or_undo = PT; ..." - a boundary is
      ;; one of the two moments that define "before the command"
      (*point-before-last-command-or-undo* (buffer-pt ed))
      (*buffer-before-last-command-or-undo* ed))

    (define (undo-modified-entry? entry)
      ;; Whether ENTRY is the mark of where the buffer was last in sync
      ;; with its file - GNU Emacs's `(t . TIME-FLAG)'.
      ;;--------------------------------------------------------------
      (and (pair? entry) (eq? (car entry) 't)))

    (define *point-before-last-command-or-undo* (make-parameter #f))
    (define *buffer-before-last-command-or-undo* (make-parameter #f))
    ;; ^ GNU Emacs's `point_before_last_command_or_undo' and
    ;; `buffer_before_last_command_or_undo` (`keyboard.c:232-233',
    ;; declared in `keyboard.h`). The command loop sets both before it
    ;; runs a command, and `undo-boundary` sets them when it places one;
    ;; `record_point` below reads them to put point *back* where it was
    ;; before the command began.
    ;;
    ;; They are plain C globals. They are *parameters* here because a
    ;; library's imported bindings are immutable, so `keyboard.scm`
    ;; cannot `set!` one - and because a parameter is this tree's
    ;; ordinary spelling for state another library maintains, as
    ;; `*last-command*' and `*this-command*' are. Neither is ever
    ;; dynamically bound, only set.
    ;;
    ;; They are `keyboard.c`'s, and they are defined here because undo.c
    ;; is what reads them and this library holds undo.c until `undo.scm`
    ;; exists.

    (define (record-first-change)
      ;; GNU Emacs's `record_first_change` (`undo.c:132`): the entry that
      ;; says where the file was last saved, pushed the first time the
      ;; buffer is changed since then. Undoing back past it is what makes
      ;; the buffer unmodified again.
      ;;
      ;; **What it records is the visited file's modification time**, and
      ;; that is the whole point of the entry: undoing back to this mark
      ;; makes the buffer unmodified again only while the file still holds
      ;; the time it held when the mark was made. Emacs asks the *base*
      ;; buffer, an indirect buffer having no file of its own; there are
      ;; no indirect buffers here.
      ;;
      ;; **It must run while the counter still says unmodified**, which is
      ;; why the C tests `MODIFF <= SAVE_MODIFF` rather than
      ;; `buffer-modified-p` - the two agree here, but the C's test is the
      ;; one that stays true when they do not. Getting the order wrong lost
      ;; seven engine tests when the modification counter landed.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (when (not (buffer-modified-p buffer))
          (%undo-record!
           buffer (cons 't ((*buffer-visited-file-modtime-function*) buffer))))))

    (define (%record-point beg)
      ;; GNU Emacs's `record_point` (`undo.c:50`): the first-change mark,
      ;; and then Emacs's way of putting point back - an *integer* entry
      ;; recording where point was when the command began. It is
      ;; `record_insert` and `record_delete` that call it, which is why it
      ;; is here and not in `prepare_to_modify_buffer` where the C's other
      ;; before-the-change work lives.
      ;;
      ;; The deactivate-mark flag used to be set at the end of this
      ;; function. It is not undo.c's and it is not this function's - it
      ;; is `prepare_to_modify_buffer_1`'s last line, and `insdel.scm`
      ;; sets it there now.
      ;;
      ;; **The second half is Emacs's way of putting point back**, and
      ;; it is not obvious: an *integer* entry recording where point was
      ;; when the command began. `primitive-undo`'s integer case is
      ;; `(goto-char next)`, and because this entry sits *below* the
      ;; change's own, it is applied after it - so undoing a kill leaves
      ;; point where the command started, whatever the deletion's own
      ;; sign did to it.
      ;;
      ;; Emacs says so at the very place this matters, in `kill-line`
      ;; (`simple.el:6800`): "It is better to move point to the other end
      ;; of the kill before killing ... The choice has no effect on undo
      ;; now that undo records the value of point from before the command
      ;; was run." Our `kill-line` moves point too, as Emacs's does; this
      ;; entry is what makes that harmless, and without it an undo of a
      ;; kill left point one character further along.
      ;;
      ;; The three conditions are the C's, including the odd-looking
      ;; order: `at_boundary` is tested *before* `record_first_change`
      ;; pushes its own entry, which the C's comment says it depends on.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (list (text-editor-undo-list buffer))
             (at-boundary (or (not (pair? list)) (null? (car list)))))
        (record-first-change)
        (when (and at-boundary
                   (*point-before-last-command-or-undo*)
                   (not (= (*point-before-last-command-or-undo*) beg))
                   (eq? (*buffer-before-last-command-or-undo*) buffer))
          (%undo-record! buffer (*point-before-last-command-or-undo*)))))

    (define (record-insert beg length)
      ;; GNU Emacs's `record_insert` (`undo.c:86`): "Record an insertion
      ;; that just happened or is about to happen." It is the first thing
      ;; `insert_1_both` does after preparing the change, and it runs
      ;; *before* the modification counter rises.
      ;;
      ;; **The second argument is a LENGTH**, which is the C's own name
      ;; for it and is what every caller has - `insert_from_string_1`
      ;; knows how many characters it wrote, `replace_range` how many it
      ;; put in. It was called `end` here, and taken as a position, which
      ;; made the entry `(BEG . BEG)` for a caller that passed a length.
      ;; What is recorded is `(BEG . BEG+LENGTH)`: the range the
      ;; insertion occupies, which is what undoing it deletes.
      ;;--------------------------------------------------------------
      (when (text-editor-undo-recording? (current-buffer))
        (%record-point beg)
        (%undo-record-insertion! (current-buffer) beg (+ beg length))))

    (define (record-delete beg string)
      ;; GNU Emacs's `record_delete` (`undo.c:163`): "Record that a
      ;; deletion is about to take place, of the characters in STRING, at
      ;; location BEG."
      ;;
      ;; The C's sign rule is `PT == beg + SCHARS (string) ? -beg : beg`:
      ;; point at the *end* of what went is recorded as the negative of
      ;; where the text starts, and the sign is what tells undo which side
      ;; of the re-inserted text to leave point on. The caller used to
      ;; work the sign out and pass it in; it belongs here, where the C
      ;; has it.
      ;;
      ;; **Not carried**: `record_marker_adjustments`, which the C runs
      ;; between here and the push, for the markers inside the deleted
      ;; text - so undoing a deletion does not put those markers back
      ;; where they were.
      ;;--------------------------------------------------------------
      (when (text-editor-undo-recording? (current-buffer))
        (%record-point beg)
        (let ((pt (buffer-pt (current-buffer))))
          (%undo-record-deletion!
           (current-buffer) string
           (if (= pt (+ beg (string-length string))) (- beg) beg)))))

    (define (undo-insertion-entry? entry)
      ;; Whether ENTRY records an insertion, that is, whether it is a
      ;; pair of two integers - Emacs's `(BEG . END)'.
      ;;--------------------------------------------------------------
      (and (pair? entry)
           (integer? (car entry))
           (integer? (cdr entry))))

    (define (undo-deletion-entry? entry)
      ;; Whether ENTRY records a deletion, that is, whether it is a
      ;; pair of a string and an integer - Emacs's `(TEXT . POS)'.
      ;;--------------------------------------------------------------
      (and (pair? entry)
           (string? (car entry))
           (integer? (cdr entry))))

    (define (%undo-record! ed entry)
      ;; Add ENTRY to the front of ED's undo list.
      ;;--------------------------------------------------------------
      (when (text-editor-undo-recording? ed)
        (set!text-editor-undo-list ed (cons entry (text-editor-undo-list ed)))
        (%undo-truncate! ed)))

    (define (%undo-record-insertion! ed beg end)
      ;; Record that the characters BEG up to END were just inserted.
      ;; An insertion that abuts the previous one extends it rather
      ;; than adding an entry, so a run of adjacent insertions is one
      ;; entry - Emacs's `record_insert', and mg's rule that "if the
      ;; newest record is an INSERT whose end exactly abuts the new
      ;; insertion, just grow it".
      ;;--------------------------------------------------------------
      (when (and (text-editor-undo-recording? ed) (< beg end))
        (let ((list (text-editor-undo-list ed)))
          (if (and (pair? list)
                   (undo-insertion-entry? (car list))
                   (= (cdr (car list)) beg))
              (set-cdr! (car list) end)
              (set!text-editor-undo-list ed (cons (cons beg end) list))))
        (%undo-truncate! ed)))

    (define (%undo-record-deletion! ed text pos)
      ;; Record that TEXT was just deleted. POS is positive when point
      ;; was at the beginning of the deleted text and negative when it
      ;; was at the end, which is what `text-editor-undo' needs in
      ;; order to put point back where it was.
      ;;--------------------------------------------------------------
      (when (and (text-editor-undo-recording? ed)
                 (< 0 (string-length text)))
        (%undo-record! ed (cons text pos))))

    (define (%undo-truncate! ed)
      ;; Keep the undo list within `*undo-limit*' by discarding whole
      ;; oldest change groups.
      ;;--------------------------------------------------------------
      (let loop ((list (text-editor-undo-list ed)) (guard 0))
        (when (and (list? list)
                   (< (*undo-limit*) (length list))
                   ;; the guard bounds the work if dropping ever failed
                   ;; to shorten the list
                   (< guard 1000))
          (let ((kept (%undo-drop-oldest-group list)))
            (if (eq? kept list)
                ;; The list is one change group too big to keep, and a
                ;; group cannot be split. Drop it, but keep recording:
                ;; an empty list is Emacs's `nil' (nothing to undo yet),
                ;; not `t' (undo disabled).
                (set!text-editor-undo-list ed '())
                (begin
                  (set!text-editor-undo-list ed kept)
                  (loop kept (+ guard 1))))))))

    (define (%undo-drop-oldest-group list)
      ;; LIST with its oldest change group removed. The list is newest
      ;; first, so the oldest group is the run of entries after the LAST
      ;; boundary; that run, and the boundary that opens it, are what
      ;; goes. Returns LIST unchanged when it holds a single group,
      ;; which cannot be dropped without dropping everything.
      ;;--------------------------------------------------------------
      (let ((len (length list)))
        (let loop ((i 0) (node list) (last-boundary #f))
          (if (or (>= i len) (not (pair? node)))
              (if last-boundary
                  (let take ((k 0) (node list) (acc '()))
                    (if (>= k last-boundary)
                        (reverse acc)
                        (take (+ k 1) (cdr node) (cons (car node) acc))))
                  list)
              (if (null? (car node))
                  (loop (+ i 1) (cdr node) i)   ; remember this boundary
                  (loop (+ i 1) (cdr node) last-boundary))))))

    ))
