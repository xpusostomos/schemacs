(define-library (schemacs editor engine)
  ;; This library mirrors GNU Emacs's `buffer.c' + `insdel.c' +
  ;; `marker.c' + `search.c': the buffer and its text (a gap buffer of
  ;; lines), inserting into it and deleting from it, the markers that
  ;; follow edits, and searching over it.
  ;;
  ;; It is four Emacs files in one library, which the rule in
  ;; LAYOUT-PLAN.txt does not ask for - the rule is one library per
  ;; mirrored file. It is that way because it was written before the rule
  ;; and split later: a marker subsystem gets its own `marker.sld' when
  ;; markers are next worked on, and the same for overlays and regexp
  ;; search. Until then this header says which four files it stands for.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library predates.
  ;;------------------------------------------------------------------
  (import
    (scheme base)
    (scheme case-lambda)
    (only (scheme char) char-downcase)  ; for case-folding searches
    (only (scheme write) display write) ;;DEBUG
    (scheme case-lambda)
    (only (schemacs vector)
          u32vector?  make-u32vector  u32vector-ref  u32vector-set!
          u64vector?  make-u64vector
          )
    (only (schemacs vbal)
          vbal-type?  vbal->alist  alist->vbal
          )
    ;;(only (schemacs lexer) make<source-file-location>)
    ;; The marker chain is held weakly - see the note above
    ;; `MAKE<MARKER>'. There is no Emacs name for the mechanism and no
    ;; wrapper for it any more: this is Guile's own weak table, a key
    ;; held weakly with a constant for its value, which `(schemacs
    ;; weak)' used to spell `new-weak-set'.
    (only (guile)
          make-weak-key-hash-table  hashq-set!  hashq-remove!  hash-for-each)
    ;; The buffer's text. Emacs's `struct buffer_text' as an object -
    ;; the characters, the gap and where the gap is - so the four
    ;; structures this file used to keep (a gap buffer of `<text-line>'
    ;; records, a separate line editor, a CDF indexing the lines, and a
    ;; hand-maintained character count) are one sequence of characters,
    ;; as they are in Emacs.
    (only (schemacs editor buffer-text)
          new-buffer-text  buffer-text-type?
          buffer-text-base  buffer-text-z  buffer-text-length
          buffer-text-gap-size  buffer-text-allocation
          buffer-text-ref  buffer-text-set!
          buffer-text-insert!  buffer-text-delete!
          buffer-text-substring  buffer-text-for-each
          buffer-text-clear!
          buffer-text-beg-unchanged  set!buffer-text-beg-unchanged
          buffer-text-modiff  buffer-text-chars-modiff
          set!buffer-text-modiff  set!buffer-text-chars-modiff
          )
    ;; The line-break cache `find-newline' keeps - GNU Emacs's
    ;; `region-cache.c', which is `buf->newline_cache' there. It is what
    ;; makes searching a buffer with very long lines affordable: a
    ;; stretch already searched and found free of line breaks is skipped
    ;; whole rather than scanned again.
    (only (schemacs editor region-cache)
          new-region-cache  know-region-cache  invalidate-region-cache
          region-cache-forward  region-cache-backward)
    )
  (cond-expand
   ;; To define pretty-printers for Guile
   (guile-3
    (import (only (srfi srfi-9 gnu) set-record-type-printer!))
    )
   (else)
   )
  (export
   ;; The text editor data type
   new-text-editor  text-editor-type?
   *init-text-editor-line-count*
   text-editor-char-count
   text-load-port  text-dump-port  text-editor-to-string
   text-editor-insert
   text-editor-delete-from-cursor
   text-editor-copy-string
   *after-change-functions*
   signal-after-change

   ;; Undo
   text-editor-undo-list  set!text-editor-undo-list
   text-editor-undo  text-editor-undo-boundary!
   text-editor-undo-disable!  text-editor-undo-enable!
   text-editor-undo-recording?
   *undo-limit*
   undo-insertion-entry?  undo-deletion-entry?  undo-modified-entry?

   ;; The root of the buffer's text-property interval tree, and the
   ;; procedure that shifts it on an edit. GNU Emacs keeps the root on the
   ;; buffer too (`BVAR (buf, intervals)') and shifts it from `insdel.c';
   ;; the tree and the operations on it are `(schemacs editor intervals)',
   ;; which mirrors `intervals.c'.
   text-editor-text-props  set!text-editor-text-props
   text-editor-deactivate-mark  set!text-editor-deactivate-mark!
   *inhibit-read-only*
   *text-property-offset-function*

   ;; Whether the buffer has changed since it was last saved
   text-editor-modified?  text-editor-set-modified!
   text-editor-save-token

   ;; Whether the buffer refuses to be changed
   text-editor-read-only?  text-editor-set-read-only!

   ;; Searching, and the mark
   text-editor-search-forward  text-editor-search-backward
   string-search-forward
   text-editor-mark  set!text-editor-mark

   ;; The buffer's identity: its name and the file it visits
   text-editor-buffer-name  set!text-editor-buffer-name
   text-editor-file-name    set!text-editor-file-name

   ;; Markers: positions that follow the text
   new-marker  copy-marker  marker-type?
   marker-position  marker-buffer  marker-insertion-type
   set-marker!  set-marker-insertion-type!
   mark-marker
   text-editor-markers

   ;; Changing the line-break protocol for the editor
   text-editor-set-line-break!
   line-break-newline  line-break-return
   line-break-null  line-break-crlf  line-break-lfcr
   line-break-bytevector  line-break-write-to-port
   line-break-size   *default-line-break*
   line-break  show-line-break

   ;; Getting and setting the cursor index. Every *position* the engine
   ;; answers is one-based, as Emacs's are: `point-min' is 1 and
   ;; `point-max' is one past the last character. Line numbers count
   ;; from 1 (`line-number-at-pos'); columns from 0 (`current-column').
   text-editor-char-count
   text-editor-point-min
   text-editor-point-max
   text-editor-ref
   text-editor-cursor-line
   text-editor-cursor-column
   text-editor-line-count
   text-editor-line-string
   text-editor-get-start-of-line
   text-editor-get-end-of-line
   text-editor-set-cursor
   text-editor-move-cursor
   text-editor-get-cursor
   text-editor-get-char-index
   text-editor-line-ref
   text-editor-line-outer-size
   ;; The scans the line arithmetic is built on - GNU Emacs's
   ;; `find_newline' (`search.c:675'), `scan_newline_from_point'
   ;; (:986), `bol' (`editfns.c:665'), `eol' (:723),
   ;; `find_before_next_newline' (`search.c':997) and `count_lines'
   ;; (`xdisp.c:29892').
   find-newline  scan-newline-from-point
   bol  eol  find-before-next-newline  count-lines
   text-editor  show-text-editor
   ;; `invalidate_buffer_caches' (`insdel.c:2206'). The three writers in
   ;; this file call it themselves; it is exported because anything that
   ;; changes the text by another route has to, and the C's `erase-buffer'
   ;; is the example - `(invalidate_buffer_caches (current_buffer, BEGV,
   ;; ZV))' (buffer.c:2773). `erase-buffer' here goes through
   ;; `text-editor-delete-from-cursor', so it is already covered.
   text-editor-invalidate-caches!
   ;; `BEG_UNCHANGED' (`buffer.h:156') and the caches' own "everything is
   ;; current as of now".
   text-editor-beg-unchanged  text-editor-note-unchanged!
   ;; `buffer-modified-tick' and `buffer-chars-modified-tick' (buffer.c)
   text-editor-modiff  text-editor-chars-modiff
   ;; `modify_text_properties' raises `MODIFF' without touching
   ;; `CHARS_MODIFF' (textprop.c:90); this is that raise
   text-editor-note-property-change!
   )

  (begin

    ;; Cumulative Distribution Function (CDF): since most text editors
    ;; require moving the cursor to a precise index, as though the
    ;; text buffer were an array of characters, and since this editor
    ;; engine buffers variable-length lines and not characters, we
    ;; provide a way to efficiently map arbitrary character indicies
    ;; to line indicies. This is accomplished with a CDF which
    ;; precisely describes how characters are distributed throughout
    ;; the text buffer, that way character lookup by index can be
    ;; performed with a simple binary search in O(log n) time. The CDF
    ;; implementation defined here provides APIs for changing the
    ;; characters and lazily re-computing the distribution whenever
    ;; characters are inserted or removed from somewhere in the middle
    ;; of the text buffer.

    ;;----------------------------------------------------------------
    ;; Line breaking state machine (not to be confused with a
    ;; break-dancing robot).

    (define-record-type <line-break-type>
      ;; This record type keeps a set of procedures and data related
      ;; to how certain line-break protocols are used. If the line
      ;; break scheme requires two characters, such as
      ;; line-feed->carriage-return (LFCR) or
      ;; carriage-return->line-feed (CRLF), The
      ;; `LINE-BREAK-SETUP-EDITOR!` acts as a state transition procedure
      ;; which waits for a second character to be inserted and then
      ;; decides what to do after. To use the procedure stored to
      ;; `LINE-BREAK-SETUP-EDITOR!` apply a text editor to it, the text
      ;; editor will be updated to have it's
      ;; `text-editor-insert-char` procedure set to the initial
      ;; state of the state machine.
      (make<line-break> bv str to-port ins-char)
      line-break-type?
      (bv        line-break-bytevector)
      (str       line-break-string)
      (to-port   line-break-write-to-port)
      (ins-char  line-break-setup-editor!)
      )

    (define (line-break-size lbrk)
      (bytevector-length (line-break-bytevector lbrk))
      )

    (define (%line-break-plain-insert ed)
      ;; **The line-break state machine is gone.** With one store a line
      ;; break is a character like any other, and there is nothing left
      ;; for a machine to watch for.
      ;;
      ;; It existed to notice the second character of a two-character
      ;; break (CRLF, LFCR) so the editor could freeze the line editor
      ;; and push the line into the buffer, recording the break on the
      ;; line rather than as text. There is no line editor and no
      ;; freeze: the characters simply go in, and the break is in the
      ;; text like everything else.
      ;;
      ;; The break is still a *value* the editor carries - it is what
      ;; `text-dump-port' writes for a buffer that has no breaks of its
      ;; own yet, and what the line scans look for.
      ;;--------------------------------------------------------------
      (set!text-editor-insert-char
       ed (lambda (input-ch) (text-editor-force-insert-char ed input-ch)))
      )

    (define (line-break-2-state break-ch0 break-ch1)
      ;; NOTE: `<line-break-type>` fields are in the order (bv str
      ;; to-port ins-char), so the bytevector comes first.
      (make<line-break>
       (let ((bv (make-bytevector 2)))
         (bytevector-u8-set! bv 0 (char->integer break-ch0))
         (bytevector-u8-set! bv 1 (char->integer break-ch1))
         bv
         )
       (let ((str (make-string 2)))
         (string-set! str 0 break-ch0)
         (string-set! str 1 break-ch1)
         str
         )
       (lambda (port)
         (write-char break-ch0 port)
         (write-char break-ch1 port)
         )
       %line-break-plain-insert))

    (define (line-break-1-state break-ch)
      (make<line-break>
       (make-bytevector 1 (char->integer break-ch))
       (make-string 1 break-ch)
       (lambda (port) (write-char break-ch port))
       %line-break-plain-insert))

    (define line-break-crlf    (line-break-2-state #\return #\newline))
    (define line-break-lfcr    (line-break-2-state #\newline #\return))
    (define line-break-newline (line-break-1-state #\newline))
    (define line-break-return  (line-break-1-state #\return))
    (define line-break-null    (line-break-1-state #\null))

    (define (line-break str)
      (cond
       ((not str) #f)
       ((line-break-type? str) str)
       ((char? str)
        (cond
         ((char=? str #\newline) line-break-newline)
         ((char=? str #\return)  line-break-return)
         ((char=? str #\null)    line-break-null)
         (else (error "invalid line break" str))
         ))
       ((string? str)
        (cond
         ((string=? str "\n")   line-break-newline)
         ((string=? str "\r")   line-break-return)
         ((string=? str "\n\r") line-break-crlf)
         ((string=? str "\r\n") line-break-lfcr)
         ((string=? str "\0")   line-break-null)
         (else (error "invalid line break" str))
         ))
       ((symbol? str)
        (cond
         ((eq? str 'crlf)    line-break-crlf)
         ((eq? str 'lfcr)    line-break-lfcr)
         ((eq? str 'newline) line-break-newline)
         ((eq? str 'return)  line-break-return)
         ((eq? str 'null)    line-break-null)
         (else (error "unknown line break type" str))
         ))
       (else (error "not a string or char" str))
       ))

    (define (line-break->string lbrk)
      (cond
       ((not lbrk) #f)
       ((line-break-type? lbrk) (line-break-string lbrk))
       ((string? lbrk) lbrk)
       ((char? lbrk) lbrk)
       (else (error "not a line break type" lbrk))
       ))

    (define show-line-break
      (case-lambda
       ((lbrk) (show-line-break lbrk (current-output-port)))
       ((lbrk port)
        (display "(line-break " port)
        (write (line-break->string lbrk) port)
        (display ")" port)
        )))

    (cond-expand
     (guile
      (set-record-type-printer! <line-break-type> show-line-break)
      )
     (else)
     )

    (define (text-editor-set-line-break! ed lbrk)
      ;; Change the line breaking character used by the editor. By
      ;; default it is set to `line-break-newline`, which is the
      ;; `#\newline` character.
      ;;--------------------------------------------------------------
      (cond
       ((line-break-type? lbrk) ((line-break-setup-editor! lbrk) ed))
       (else (error "not a line-breaker configuration" lbrk))
       ))

    ;;----------------------------------------------------------------

    (define-record-type <text-editor-type>
      (make<text-editor>
       text  newline-cache  point
       ins-char  lbrk  textprops  undo
       save-modiff  save-token  read-only  mark  markers
       deactivate-mark
       name  file-name
       )
      text-editor-type?
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
      (point      text-editor-point         set!text-editor-point)
      ;; ^ The cursor, as a `buffer-text' *position* - one-based, the
      ;; convention the class speaks, and Emacs's own. Emacs keeps `PT'
      ;; on the buffer for the same reason: it is not derivable from the
      ;; gap, which can sit anywhere. `TEXT-EDITOR-GET-CURSOR' answers
      ;; this position as it stands, so `point' is that value and
      ;; nothing has to convert between two conventions.
      (ins-char   %text-editor-insert-char   set!text-editor-insert-char)
      ;; ^ A function which inserts characters into the editor.
      (lbrk       text-editor-line-break     set!text-editor-line-break)
      ;; ^ The current line-breaking protocol.
      (textprops  text-editor-text-props     set!text-editor-text-props)
      ;; A VBAL of the buffer's text properties. This is GNU Emacs's
      ;; `BUFFER_INTERVALS' - the root of the interval tree - which
      ;; `(schemacs editor intervals)' mirrors and this library only
      ;; holds; it is what syntax colouring and the `display' property
      ;; are kept in.
      (undo       text-editor-undo-list     set!text-editor-undo-list)
      ;; ^ The buffer's undo list, GNU Emacs's `buffer-undo-list'. A
      ;; list, newest entry first, of the edits that can be undone; or
      ;; false, which is Emacs's `t', meaning that the recording of
      ;; undo information is disabled. The empty list is Emacs's `nil':
      ;; recording is enabled but there is nothing to undo. See the
      ;; "Undo" section below for the entry formats.
      (save-modiff text-editor-save-modiff  set!text-editor-save-modiff)
      ;; ^ GNU Emacs's `SAVE_MODIFF' (`buffer.h'), a field of
      ;; `struct buffer': the value of the text's `modiff' when the
      ;; buffer was last in sync with its file. There is no flag
      ;; beside it - `buffer-modified-p' *is* the comparison
      ;; `SAVE_MODIFF < MODIFF', which is what `text-editor-modified?'
      ;; answers and what `text-editor-set-modified!' maintains.
      ;; It is cleared by saving and by undoing back past every change
      ;; made since the last save.
      (save-token text-editor-save-token    set!text-editor-save-token)
      ;; ^ Identifies the state the buffer was last in sync with its
      ;; file. It is an integer that counts up every time the buffer is
      ;; marked unmodified, and it is what the `(t . TOKEN)' undo entry
      ;; records: undoing back to that entry makes the buffer
      ;; unmodified again, but only while the token still matches,
      ;; which is false once the buffer has been saved in the meantime.
      ;; Emacs records the visited file's modification time there
      ;; instead and compares it with `visited-file-modtime'; the
      ;; engine has no file or clock, so it numbers its saves.
      (deactivate-mark text-editor-deactivate-mark
                       set!text-editor-deactivate-mark!)
      ;; ^ Whether the mark should be deactivated once this command is
      ;; over: GNU Emacs's `deactivate-mark' variable, which the command
      ;; loop sets to nil before each command and tests when the command
      ;; returns. **Any buffer modification stores t in it**
      ;; (`insdel.c''s `prepare_to_modify_buffer'), which is what makes
      ;; the region go away when you type or yank.
      (mark       %mark-marker           set!%mark-marker)
      ;; ^ The buffer's mark, GNU Emacs's `mark': a <marker-type>, which
      ;; is what makes it survive the text around it changing. It points
      ;; nowhere until the mark is set. `TEXT-EDITOR-MARK' is the
      ;; accessor Lisp would see - the position, as Emacs's `(mark)' -
      ;; so this slot is private.
      (markers    text-editor-markers    set!text-editor-markers)
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

    (define *init-text-editor-line-count* (make-parameter 4096))

    (define *default-line-break* (make-parameter line-break-newline))

    (define new-text-editor
      (case-lambda
        (() (new-text-editor #f #f))
        ((lbrk)
         (cond
          ((line-break-type? lbrk) (new-text-editor lbrk #f))
          ((or (vbal-type? lbrk) (list? lbrk)) (new-text-editor #f lbrk))
          (else (error "expecting properties list, or `line-break-type?`" lbrk))
          ))
        ((lbrk props)
         (cond
          ((and lbrk (not (line-break-type? lbrk)))
           (error "first argument not a line-break-type" lbrk)
           )
          ((and props (not (or (vbal-type? props) (list? props))))
           (error "second argument not a properties list" props)
           )
          (else
           (let*((size (*init-text-editor-line-count*))
                 (lbrk (or lbrk (*default-line-break*)))
                 (ed (let ()
                       (make<text-editor>
                        ;; Emacs's `BEG' is 1, and every position the
                        ;; class answers is in that coordinate system.
                        (new-buffer-text 1 size)
                        ;; the newline cache, made on first use
                        #f
                        1
                        #f lbrk props
                        ;; A newly created buffer records undo
                        ;; information from the start, as in GNU Emacs.
                        '()
                        ;; `SAVE_MODIFF' starts at 1 and so does the
                        ;; text's `modiff', which is what makes a fresh
                        ;; buffer unmodified: `1 < 1' is false. Emacs
                        ;; sets the one to 1 at `buffer.c:631' and a
                        ;; fresh buffer reports a tick of 1.
                        ;; `SAVE_MODIFF' is 1, the `save-token' 0, and
                        ;; the buffer writable.
                        1 0 #f
                        ;; The mark, pointing nowhere until it is set,
                        ;; and an empty marker chain.
                        (make<marker> #f 0 #f)
                        (make-weak-key-hash-table)
                        ;; Nothing is waiting to deactivate the mark.
                        #f
                        ;; Named as `generate-new-buffer' names a
                        ;; buffer it makes, and visiting no file.
                        "Untitled" #f
                        ))))
             ((line-break-setup-editor! lbrk) ed)
             ed
             ))))))

    (define (text-editor location lbrk . lines)
      ;; Construct a text editor from a list of text lines.
      ;;--------------------------------------------------------------
      (let ((ed (new-text-editor lbrk)))
        (let loop ((lines lines))
          (cond
           ((null? lines)
            (when location (text-editor-set-cursor ed location))
            ed)
           (else
            (text-editor-insert ed (car lines))
            (loop (cdr lines))
            )))))

    (define (text-editor-char-count ed)
      ;; The number of characters in the buffer - Emacs's `buffer-size'
      ;; (`editfns.c:855'), which is also `(- (point-max) 1)'.
      ;;
      ;; This used to be a slot the engine maintained by hand, and it is
      ;; not any more: the class owns the length, so it cannot drift
      ;; from the text. AGENTS.md records what that drift cost - it
      ;; manifested three screens from its cause.
      ;;--------------------------------------------------------------
      (buffer-text-length (text-editor-text ed))
      )

    (define show-text-editor
      ;; Write the whole content of a text editor to a port: where point
      ;; is, then the buffer's lines, one per line, each indented two
      ;; spaces - the shape this printer has had since it printed a gap
      ;; buffer of lines, kept so that a printed buffer reads the same as
      ;; it always did.
      ;;
      ;; Point is printed as a character position with the line it is on
      ;; and its column beside it, which is the pair `line-number-at-pos'
      ;; and `current-column' answer. It used to be a `<text-location>'
      ;; record - a `(line . column)' pair counting columns from 1, which
      ;; is a type GNU Emacs does not have - and the engine no longer
      ;; knows that type exists.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (show-text-editor ed (current-output-port)))
       ((ed port)
        (display "(text-editor (point " port)
        (write (text-editor-point ed) port)
        (display " line " port)
        (write (text-editor-cursor-line ed) port)
        (display " column " port)
        (write (text-editor-cursor-column ed) port)
        (display ")" port)
        (newline port)
        (let ((last (text-editor-line-count ed)))
          (let loop ((line 1))
            (when (<= line last)
              (display "  " port)
              (write (text-editor-line-string ed line) port)
              (newline port)
              (loop (+ line 1)))))
        (display "  )\n" port)
        )))

    (cond-expand
     (guile
      (set-record-type-printer! <text-editor-type> show-text-editor)
      )
     (else)
     )


    ;;----------------------------------------------------------------
    ;; Inserting text


    (define (text-editor-copy-string ed start end)
      ;; The buffer's text between the positions START and END, as a
      ;; string - GNU Emacs's `buffer-substring' over the whole buffer,
      ;; and the same half-open range (START in, END out). Arguments may
      ;; be given in either order; the empty range returns "".
      ;;--------------------------------------------------------------
      (let ((start (min start end))
            (end (max start end)))
        (buffer-text-substring (text-editor-text ed) start end)))

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
    ;; Entries are recorded by the two public mutators below, and only
    ;; by them. The internal procedures that shuffle lines when a line
    ;; break is inserted or deleted (the merge helpers, `write-back',
    ;; `load-current-line') re-insert text through
    ;; `text-editor-force-insert-char' or `%text-editor-move-char', not
    ;; through the public API, so they record nothing - which is what we
    ;; want, since they change how the buffer is stored rather than what
    ;; it contains. Those two differ in the `char-count' field and
    ;; nothing else: `text-editor-force-insert-char' counts what it puts
    ;; in, because a character typed really is a new character, and
    ;; `%text-editor-move-char' does not, because a character moved from
    ;; the next line into the line editor is already counted.
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
          (set!text-editor-undo-list ed (cons '() list)))))

    (define (undo-modified-entry? entry)
      ;; Whether ENTRY is the mark of where the buffer was last in sync
      ;; with its file - GNU Emacs's `(t . TIME-FLAG)'.
      ;;--------------------------------------------------------------
      (and (pair? entry) (eq? (car entry) 't)))

    ;;----------------------------------------------------------------
    ;; Markers
    ;;
    ;; A marker is a position in a buffer that follows the text: insert
    ;; or delete anywhere and the marker goes on pointing at the same
    ;; character, because its index is adjusted by the change. It is
    ;; GNU Emacs's marker (marker.c), and it is what a position that
    ;; must not go stale has to be - the mark, a window's point, and
    ;; (later) the bounds of an overlay.
    ;;
    ;; Positions that must NOT move are plain integers, and that is not
    ;; an accident: Emacs's `region-beginning' returns an integer, so
    ;; code that binds it gets a fixed anchor, while the mark and
    ;; window points are markers and do follow the text. The engine
    ;; supplies both kinds; a buffer's own cursor is the integer kind,
    ;; because it is the current position and the insert and delete
    ;; procedures move it themselves.
    ;;
    ;; Each buffer holds its markers in a chain (`text-editor-markers')
    ;; that the insert and delete procedures walk. GNU Emacs's chain
    ;; does not keep its markers alive - its collector prunes the chain
    ;; while sweeping, so an unreachable marker is collected and its
    ;; place in the chain goes with it. A Scheme implementation cannot
    ;; hook its collector's sweep, so the chain holds its markers
    ;; weakly instead - `MAKE-WEAK-KEY-HASH-TABLE', whose key is held
    ;; weakly and whose value is the constant `#t' - which comes to the
    ;; same thing: a marker that nothing else refers to is collected,
    ;; and it stops being adjusted.

    (define-record-type <marker-type>
      (make<marker> buffer index insertion-type)
      marker-type?
      (buffer     marker-buffer           set!marker-buffer)
      ;; ^ The <text-editor-type> this marker points into, or false
      ;; when it points nowhere - GNU Emacs's "marker points nowhere",
      ;; which is what a marker made by `MAKE-MARKER' is, and what one
      ;; is left as when its buffer is killed or its position is set to
      ;; false.
      (index      %marker-index           set!%marker-index)
      ;; ^ The character index within that buffer. Only meaningful
      ;; while the marker has one.
      (insertion-type marker-insertion-type set!marker-insertion-type)
      ;; ^ GNU Emacs's marker insertion type: whether the marker
      ;; advances past text inserted exactly at it. False - the default,
      ;; and what Emacs gives a marker made by `MAKE-MARKER' - leaves
      ;; the marker where it is and lets the inserted text follow it;
      ;; true moves the marker past the insertion. Text inserted on
      ;; either side of the marker moves it whichever way the text went,
      ;; whatever the type.
      )

    (define (marker-position marker)
      ;; Where MARKER points, as a character index, or false when it
      ;; points nowhere. GNU Emacs's `marker-position'.
      ;;--------------------------------------------------------------
      (and (marker-buffer marker) (%marker-index marker)))

    (define (new-marker)
      ;; A marker that points nowhere, GNU Emacs's `make-marker'.
      ;;--------------------------------------------------------------
      (make<marker> #f 0 #f))

    (define (copy-marker ed index . insertion-type)
      ;; A new marker at character index INDEX of ED, GNU Emacs's
      ;; `copy-marker'. It is added to ED's chain, so it follows the
      ;; text from here on.
      ;;--------------------------------------------------------------
      (let ((marker (make<marker> ed index
                                (and (pair? insertion-type) (car insertion-type)))))
        (hashq-set! (text-editor-markers ed) marker #t)
        marker))

    (define (set-marker! marker position . buffer)
      ;; Point MARKER at POSITION, or nowhere when POSITION is false:
      ;; GNU Emacs's `set-marker'. A marker that points nowhere is in no
      ;; buffer's chain and follows nothing, and one that is set
      ;; nowhere loses its buffer; a marker being given a position it
      ;; has no buffer for needs one, as in Emacs.
      ;;--------------------------------------------------------------
      (let ((ed (cond ((pair? buffer) (car buffer))
                      (else (marker-buffer marker)))))
        (cond
         (position
          (unless ed
            (error "set-marker! needs a buffer for a marker that points nowhere"))
          (set!marker-buffer marker ed)
          (set!%marker-index marker position)
          (hashq-set! (text-editor-markers ed) marker #t))
         (else
          (when ed
            (hashq-remove! (text-editor-markers ed) marker))
          (set!marker-buffer marker #f)
          (set!%marker-index marker 0)))
        marker))

    (define (set-marker-insertion-type! marker type)
      (set!marker-insertion-type marker (and type #t))
      type)

    (define (for-each-marker ed proc)
      ;; Apply PROC to every marker in ED's chain. A marker that has
      ;; been collected is simply no longer in it.
      ;;--------------------------------------------------------------
      (hash-for-each (lambda (marker _) (proc marker))
                     (text-editor-markers ed)))

    (define (adjust-markers-for-insertion! ed position delta)
      ;; Move the markers of ED for DELTA characters inserted at
      ;; POSITION: GNU Emacs's `adjust_markers_for_insert'. A marker
      ;; after the insertion moves with the text that follows it; one
      ;; exactly at POSITION moves only if its insertion type says so
      ;; (see the type's note above).
      ;;--------------------------------------------------------------
      (for-each-marker
       ed
       (lambda (marker)
         (let ((index (%marker-index marker)))
           (when (or (> index position)
                     (and (= index position) (marker-insertion-type marker)))
             (set!%marker-index marker (+ index delta)))))))

    (define (adjust-markers-for-deletion! ed start end)
      ;; Move the markers of ED for the characters in [START, END)
      ;; having been deleted: GNU Emacs's `adjust_markers_for_delete'.
      ;; Markers after the deleted text move back by its length; the
      ;; ones inside it - whose character is gone - are left at its
      ;; start, which is where Emacs leaves them.
      ;;--------------------------------------------------------------
      (for-each-marker
       ed
       (lambda (marker)
         (let ((index (%marker-index marker)))
           (cond
            ((>= index end) (set!%marker-index marker (- index (- end start))))
            ((> index start) (set!%marker-index marker start)))))))

    (define (mark-marker ed)
      ;; The buffer's mark as the marker it is, GNU Emacs's
      ;; `mark-marker': the same marker object every time, so that
      ;; setting the mark moves it rather than replacing it.
      ;;--------------------------------------------------------------
      (%mark-marker ed))

    (define (text-editor-mark ed)
      ;; Where the buffer's mark is, as a character index, or false when
      ;; it has not been set: GNU Emacs's `(mark)'. The mark is a marker
      ;; (see `MARK-MARKER'), so it follows the text: set it, edit
      ;; before it, and it is still on the character it was put on.
      ;;--------------------------------------------------------------
      (marker-position (%mark-marker ed)))

    (define (set!text-editor-mark ed position)
      ;; Put the buffer's mark at POSITION, or leave it unset when
      ;; POSITION is false.
      ;;--------------------------------------------------------------
      (set-marker! (%mark-marker ed) (and position position) ed))

    (define (text-editor-modiff ed)
      ;; The buffer's modification tick: GNU Emacs's `buffer-modified-tick'
      ;; (`buffer.c:1631'), which answers `MODIFF'. Every change to the
      ;; text raises it, so two readings that differ mean the buffer
      ;; changed in between - which is the question the line-break cache
      ;; and redisplay freshness both ask.
      ;;--------------------------------------------------------------
      (buffer-text-modiff (text-editor-text ed)))

    (define (text-editor-chars-modiff ed)
      ;; The same, for changes to the *characters* alone: GNU Emacs's
      ;; `buffer-chars-modified-tick'. A change to a text property raises
      ;; `modiff' and not this one, so a cache of something computed from
      ;; the characters is not invalidated by a fontification change.
      ;;--------------------------------------------------------------
      (buffer-text-chars-modiff (text-editor-text ed)))

    (define (text-editor-modified? ed)
      ;; Whether the buffer has been changed since it was last saved or
      ;; visited: GNU Emacs's `buffer-modified-p' (`buffer.c'), which is
      ;; not a flag but the comparison
      ;;
      ;;     BUF_SAVE_MODIFF (buf) < BUF_MODIFF (buf)
      ;;--------------------------------------------------------------
      (< (text-editor-save-modiff ed) (text-editor-modiff ed)))

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

    (define (text-editor-note-property-change! ed start end)
      ;; A change to the buffer's *text properties* rather than to its
      ;; characters - GNU Emacs's `modify_text_properties'
      ;; (`textprop.c:80'), which wraps every property write. It raises
      ;; `modiff' by one and does **not** touch `chars_modiff', which is
      ;; the whole reason the two counters exist apart: a cache of
      ;; something computed from the characters need not be thrown away
      ;; because a face changed.
      ;;--------------------------------------------------------------
      (text-editor-invalidate-caches! ed start end)
      (%text-editor-incr-modiff! ed 0))

    (define (text-editor-set-modified! ed flag)
      ;; Set whether ED is modified - GNU Emacs's
      ;; `set-buffer-modified-p' (`buffer.c:1573'), whose arithmetic is
      ;; all in terms of the two counters rather than a flag.
      ;;
      ;; Marking it modified *raises MODIFF* when `SAVE_MODIFF' has
      ;; caught up with it, so that the comparison comes out true again:
      ;; that is how "modified" is said of a buffer whose text never
      ;; changed. Note that `modiff_incr' answers the *old* count, so
      ;; `SAVE_MODIFF' is set to the value `MODIFF' had before the
      ;; raise, and the two end up one apart.
      ;;
      ;; Marking it unmodified records where it was last in sync with its
      ;; file, so undoing back past every change made since then can mark
      ;; it unmodified again; the `(t . TOKEN)' undo entry is that mark,
      ;; and an older one no longer counts - the buffer saved in the
      ;; meantime is not the buffer that mark describes.
      ;;--------------------------------------------------------------
      (cond
       (flag
        (unless (text-editor-modified? ed)
          (%undo-record! ed (cons 't (text-editor-save-token ed)))
          (when (>= (text-editor-save-modiff ed) (text-editor-modiff ed))
            (set!text-editor-save-modiff ed (text-editor-modiff ed))
            (%text-editor-incr-modiff! ed 0))))
       (else
        (when (text-editor-modified? ed)
          (set!text-editor-save-modiff ed (text-editor-modiff ed))
          (set!text-editor-save-token ed (+ 1 (text-editor-save-token ed)))))))

    (define (%text-editor-note-change! ed)
      ;; Note that ED is about to be changed. This goes BEFORE the
      ;; change is recorded, so that the mark of the last save sits
      ;; below the change's own entry in the list and is reached after
      ;; the change has been undone.
      ;;
      ;; A modification also asks for the mark to be deactivated, which
      ;; is what GNU Emacs's `prepare_to_modify_buffer' does with
      ;; `(setq deactivate-mark t)' - `insdel.c''s, where this is.
      ;;--------------------------------------------------------------
      ;;
      ;; The mark is recorded here because this is the C's
      ;; `record_first_change' (`undo.c:210'), which `record_insert' calls
      ;; before the modification counter rises - so the test "have we
      ;; changed since the save?" is still answered by the *old* counter.
      ;; It is not a call to `set-buffer-modified-p': with the counter
      ;; moved, `text-editor-modified?' is true on its own.
      (when (not (text-editor-modified? ed))
        (%undo-record! ed (cons 't (text-editor-save-token ed))))
      (set!text-editor-deactivate-mark! ed #t))

    (define *after-change-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-functions' (`buffer.c'): "List of
    ;; functions to call after a change in the buffer.  Each function
    ;; is called with three arguments: the beginning and end of the text
    ;; that was changed, and the length of the old text." The positions
    ;; are one-based, as every position of the Emacs-named layer is.
    ;; `minibuffer-lazy-highlight-setup' hangs its highlighting on this.

    (define (signal-after-change beg end old-length)
      ;; GNU Emacs's `signal_after_change' (`insdel.c':2381): run
      ;; `after-change-functions' over a change that has just been made.
      ;; The C's `(charpos, lendel, lenins)' are BEG, END and
      ;; OLD-LENGTH here: `(charpos + lenins)' is where the changed text
      ;; now ends, and LENDEL is what was there before it - zero for an
      ;; insertion, which is what makes a hook able to tell an insertion
      ;; from a deletion.
      ;;--------------------------------------------------------------
      (for-each (lambda (f) (f beg end old-length))
                (*after-change-functions*)))

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

    (define (text-editor-undo ed list arg)
      ;; Undo ARG change groups from the front of LIST, applying the
      ;; inverse of each entry, and return what remains of LIST. This
      ;; is GNU Emacs's `primitive-undo', and it returns what Emacs's
      ;; does, so that the caller can keep the returned tail as
      ;; `pending-undo-list' and thereby walk further and further back
      ;; over a run of undo commands.
      ;;
      ;; A group ends at a boundary, which is consumed but does not
      ;; itself undo anything - so a list whose front is a boundary
      ;; gives back the same list with that boundary removed, which is
      ;; what Emacs means by "get rid of initial undo boundary".
      ;;
      ;; Because the inverse operations run the ordinary insert and
      ;; delete primitives, they record their own inverses on the front
      ;; of ED's undo list, and that is how redo works.
      ;;
      ;; A read-only buffer cannot be undone: undoing is an edit like
      ;; any other, and GNU Emacs's `undo' has the `*' in its
      ;; interactive spec that refuses before it does anything. Refusing
      ;; here rather than part way through matters, since a half-undone
      ;; change would be worse than none.
      ;;--------------------------------------------------------------
      (when (text-editor-read-only? ed)
        (error "Buffer is read-only"))
      (let loop ((list list) (arg arg) (opening? #t))
        (if (or (<= arg 0) (not (pair? list)))
            list
            (let ((entry (car list))
                  (rest (cdr list)))
              (cond
               ;; a boundary ends the group
               ((null? entry) (loop rest (- arg 1) #t))
               ;; Undoing back past the mark of the last save makes the
               ;; buffer unmodified again, which is what tells the user
               ;; there is nothing left to save. The mark only counts
               ;; while it still describes the current save: a buffer
               ;; saved since then is not the buffer this mark was made
               ;; for. It does not end the group (GNU Emacs).
               ((undo-modified-entry? entry)
                (when (= (cdr entry) (text-editor-save-token ed))
                  (text-editor-set-modified! ed #f))
                (loop rest arg #f))
               (else
                ;; The entries the undo is about to create, by running
                ;; the ordinary insert and delete primitives, must form
                ;; a change group of their own - otherwise undoing them
                ;; again would swallow the very entries being undone
                ;; here. One boundary before the group's first entry
                ;; separates them from everything older, and the
                ;; boundary below already separates them from the
                ;; group being undone. mg's undo brackets its inverse
                ;; operations the same way.
                (when opening? (text-editor-undo-boundary! ed))
                (cond
                 ((undo-insertion-entry? entry)
                  (let ((beg (car entry))
                        (end (cdr entry)))
                    ;; Move point first, so that undoing this undo does
                    ;; not send point back to where it is now (Emacs's
                    ;; comment in `primitive-undo').
                    (text-editor-set-cursor ed beg)
                    (text-editor-delete-from-cursor ed (- end beg))))
                 ((undo-deletion-entry? entry)
                  (let* ((text (car entry))
                         (pos (cdr entry))
                         (at (abs pos)))
                    (text-editor-set-cursor ed at)
                    (text-editor-insert ed text)
                    ;; POS was positive when point was at the beginning
                    ;; of the deleted text and negative when it was at
                    ;; the end; undo puts point back on the side it was
                    ;; on (Emacs's rule for the sign of POS).
                    (text-editor-set-cursor
                     ed (if (< pos 0) (+ at (string-length text)) at)))))
                (loop rest arg #f)))))))

    (define (text-editor-read-only? ed)
      ;; Whether ED refuses to be changed. GNU Emacs's
      ;; `buffer-read-only'.
      ;;--------------------------------------------------------------
      (text-editor-read-only-flag ed))

    (define (text-editor-set-read-only! ed flag)
      ;; Set whether ED refuses to be changed: the variable GNU Emacs
      ;; keeps as `buffer-read-only', and that its `read-only-mode'
      ;; toggles.
      ;;--------------------------------------------------------------
      (set!text-editor-read-only-flag ed (and flag #t)))

    ;;----------------------------------------------------------------
    ;; Searching
    ;;
    ;; GNU Emacs's `search-forward' and `search-backward' (mg's
    ;; forwsrch/backsrch): a literal search over the buffer's
    ;; characters, in which a line break counts as a single #\newline,
    ;; whichever line-break protocol the buffer uses. Both references
    ;; leave point at the far end of the match - past it when searching
    ;; forward, at its start when searching backward - and these
    ;; procedures return that position, so a caller can put its cursor
    ;; where Emacs would have left point.
    ;;
    ;; Case folding is the caller's decision, passed in: in Emacs the
    ;; rule that an upper-case letter in the search string turns folding
    ;; off (`search-upper-case') belongs to isearch, not to
    ;; `search-forward', which only obeys `case-fold-search'.
    ;;------------------------------------------------------------------

    (define (string-search-forward haystack needle from case-fold?)
      ;; The index of the first occurrence of NEEDLE in the string
      ;; HAYSTACK at or after FROM, or #f. With CASE-FOLD? the comparison
      ;; ignores case, the way mg's `eq' macro does with its `xcase'
      ;; argument. This is the rule the buffer searches below use, and it
      ;; is exported so that a caller which already holds the text - the
      ;; renderer drawing search matches, say - can apply the same rule
      ;; without asking the buffer for it again.
      ;; The index of the first occurrence of NEEDLE in HAYSTACK at or
      ;; after FROM, or #f. With CASE-FOLD? the comparison ignores case,
      ;; the way mg's `eq' macro does with its `xcase' argument.
      ;;--------------------------------------------------------------
      (let ((n (string-length haystack))
            (m (string-length needle)))
        (let loop ((i from))
          (cond
           ((> (+ i m) n) #f)
           ((%string-match-at? haystack needle i case-fold?)
            i)
           (else (loop (+ 1 i)))))))

    (define (%string-search-backward haystack needle from case-fold?)
      ;; The index of the last occurrence of NEEDLE in HAYSTACK that
      ;; begins at or before FROM, or #f.
      ;;--------------------------------------------------------------
      (let ((m (string-length needle)))
        (let loop ((i (min from (- (string-length haystack) m))))
          (cond
           ((< i 0) #f)
           ((%string-match-at? haystack needle i case-fold?) i)
           (else (loop (- i 1)))))))

    (define (%string-match-at? haystack needle at case-fold?)
      ;; Whether NEEDLE occurs in HAYSTACK at index AT.
      ;;--------------------------------------------------------------
      (let ((m (string-length needle)))
        (let loop ((j 0))
          (cond
           ((>= j m) #t)
           ((char=? (%fold (string-ref haystack (+ at j)) case-fold?)
                    (%fold (string-ref needle j) case-fold?))
            (loop (+ 1 j)))
           (else #f)))))

    (define (%fold c case-fold?)
      (if case-fold? (char-downcase c) c))

    (define (text-editor-search-forward ed string start case-fold?)
      ;; Search forward from the position START for STRING. Returns the
      ;; position just past the match, which is where GNU Emacs's
      ;; `search-forward' leaves point, or #f when STRING does not
      ;; occur there. An empty STRING finds nothing, as it does for
      ;; mg's `is_find', rather than matching everywhere as Emacs's
      ;; `search-forward' does - an empty search string means "no search
      ;; yet" to the incremental search that wants this.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let ((found (string-search-forward
                         (text-editor-copy-string
                          ed start (text-editor-point-max ed))
                         string 0 case-fold?)))
             (and found (+ start found (string-length string))))))

    (define (text-editor-search-backward ed string start case-fold?)
      ;; Search backward from the position START for STRING. Returns the
      ;; position of the start of the match, which is where GNU Emacs's
      ;; `search-backward' leaves point, or #f when STRING does not
      ;; occur before START. An empty STRING finds nothing.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let* ((text (text-editor-copy-string ed (text-editor-point-min ed)
                                                    start))
                  (found (%string-search-backward
                          text string (- (string-length text)
                                         (string-length string))
                          case-fold?)))
             ;; FOUND is an offset into TEXT, whose first character is
             ;; at `point-min'
             (and found (+ found (text-editor-point-min ed))))))

    (define *text-property-offset-function*
      ;; The procedure that shifts a buffer's text-property intervals when
      ;; text is inserted or deleted at a position - GNU Emacs's
      ;; `offset_intervals', which lives in `intervals.c' and is called
      ;; from `insdel.c' on every edit.
      ;;
      ;; It is a parameter because of how the halves are split *here*.
      ;; The engine is `buffer.c' + `insdel.c' + `marker.c' + `search.c'
      ;; and holds the tree's root; the tree and its operations are
      ;; `(schemacs editor intervals)', which reaches that root through
      ;; this engine's accessors - so this engine cannot import it, and
      ;; the call has to come in sideways. In C there is no such problem
      ;; and this seam is what stands in for the direct call. It is #f
      ;; until that library is loaded, which is why the callers check.
      ;;--------------------------------------------------------------
      (make-parameter #f))

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

    (define (text-editor-insert ed thing)
      ;; Insert THING at the cursor. The insertion is recorded in the
      ;; buffer's undo list as the range of characters it now occupies,
      ;; and marks the buffer modified. Nothing is inserted into a
      ;; read-only buffer; that is an error, as it is in GNU Emacs -
      ;; unless `inhibit-read-only' says otherwise, which is the same
      ;; test the C's `prepare_to_modify_buffer_1' makes.
      ;;--------------------------------------------------------------
      (when (and (text-editor-read-only? ed)
                 (not (*inhibit-read-only*)))
        (error "Buffer is read-only"))
      (let ((beg (text-editor-get-cursor ed)))
        (%text-editor-insert ed thing)
        (let ((end (text-editor-get-cursor ed)))
          ;; Inserting nothing is not a change, so it marks the buffer
          ;; modified only if the cursor actually moved. The mark of the
          ;; last save is recorded first, so that it lies under the
          ;; insertion's own entry.
          (when (< beg end)
            ;; The text is in, so the markers after it move with it.
            ;; Doing it here - once for the whole insertion, from where
            ;; the cursor ended up - covers every way text gets in:
            ;; characters, strings, a whole file, and an insertion
            ;; replayed by undo, which comes back through here.
            (adjust-markers-for-insertion! ed beg (- end beg))
            ;; The intervals move with the text for the same reason the
            ;; markers do, and from the same place: once for the whole
            ;; insertion, so that every way text gets in is covered.
            (let ((offset (*text-property-offset-function*)))
              (when offset (offset ed beg (- end beg))))
            (%text-editor-note-change! ed)
            ;; The modification counter rises once for the whole
            ;; insertion, sized by how much went in - the C's
            ;; `insert_from_string_1' does one
            ;; `modiff_incr (&MODIFF, nchars)' for a string, however many
            ;; characters that is (`insdel.c:1069'), where counting each
            ;; character separately would race the counter away on a
            ;; large insertion. It is here rather than beside the
            ;; character writer because `force-insert-char' is called
            ;; once per character, and the operation is what the C
            ;; counts.
            ;;
            ;; It comes *after* `note-change!', which is where the C
            ;; puts it too: `record_insert' runs before `modiff_incr'
            ;; (`insdel.c:926-928'), and `record_insert' is what asks
            ;; "is this the first change since the save?".
            (%text-editor-incr-modiff! ed (- end beg))
            (%undo-record-insertion! ed beg end)
            ;; and the after-change hooks, once the text is really in.
            ;; BEG and END are positions, one-based like Emacs's, so
            ;; they are what `signal_after_change' is given as they
            ;; stand.
            (signal-after-change beg end 0)))))

    (define (%text-editor-insert ed thing)
      (cond
       ((string? thing)
        ;; NOTE: the insert-char procedure must be re-read for every
        ;; character, because `text-editor-insert-char' is a slot a
        ;; caller can replace (the line-break protocols install their
        ;; own) and re-reading is what sees the current one.
        ;;--------------------------------------------------------------
        (string-for-each
         (lambda (c) ((%text-editor-insert-char ed) c))
         thing
         ))
       ((char? thing)
        ((%text-editor-insert-char ed) thing)
        )
       ((and (input-port? thing) (input-port-open? thing))
        (text-editor-insert-from-port ed thing)
        )
       (else (error "editor cannot insert text from" thing))
       ))

    (define (text-editor-force-insert-char ed ch)
      ;; **The one place a character enters the text.** Everything else
      ;; arrives here: typing, a string, a whole file, a line break, and
      ;; an insertion replayed by undo. There used to be two more
      ;; writers - `%text-editor-move-char' and `load-current-line' -
      ;; and they existed only because the text had two levels, a line
      ;; editor over a buffer of lines. It has one level now, so the
      ;; writers are one, and this is it.
      ;;
      ;; A line break is no longer special: it is a character like any
      ;; other, and it goes in the same way. The freeze-and-write-back
      ;; dance it used to trigger went with the line editor.
      ;;--------------------------------------------------------------
      (let ((text  (text-editor-text ed))
            (point (text-editor-point ed))
            )
        (text-editor-invalidate-caches! ed point point)
        (buffer-text-insert! text point (string ch))
        (set!text-editor-point ed (+ 1 point))
        ch
        ))

    ;; Deleting text
    ;;
    ;; GNU Emacs's `del_range' (`insdel.c'): take the characters of a
    ;; range out of the buffer. With one store and no line objects there
    ;; is nothing else to it - a line break is a character like any
    ;; other, so joining two lines is deleting the break between them.
    ;; The merge helpers this section used to carry, which walked a line
    ;; editor, a gap buffer of `<text-line>' records and a CDF, have no
    ;; counterpart in Emacs and are gone with those three structures.

    (define (text-editor-invalidate-caches! ed start end)
      ;; Tell the buffer's caches that the region START to END is about to
      ;; change - GNU Emacs's `invalidate_buffer_caches' (`insdel.c:2206'),
      ;; which `prepare_to_modify_buffer' calls before every modification.
      ;; The line-break cache is the only one this tree keeps; the C's
      ;; `bidi_paragraph_cache' and `width_run_cache' cache things - bidi
      ;; paragraph starts, and the display widths of a stretch of text -
      ;; that nothing here asks for.
      ;;
      ;; The cache is told in the HEAD/TAIL form - "this many characters
      ;; unchanged at the beginning of the buffer, this many at the end" -
      ;; rather than with positions, because an insertion or a deletion
      ;; moves everything after it and that form reads the same before and
      ;; after the change. For an insertion at POINT the tail is
      ;; `Z - POINT`, which is the same count either side of it.
      ;;--------------------------------------------------------------
      (let ((beg (text-editor-point-min ed))
            (text (text-editor-text ed)))
        ;; Nothing before the change is known to be unchanged any more -
        ;; the C's `if (GPT - BEG < BEG_UNCHANGED) BEG_UNCHANGED =
        ;; GPT - BEG' (`insdel.c:1608'). The `%l' cache reads this to
        ;; decide whether the line number it remembers is still true.
        (let ((prefix (- start beg)))
          (when (< prefix (buffer-text-beg-unchanged text))
            (set!buffer-text-beg-unchanged text prefix)))
        (let ((cache (%text-editor-newline-cache ed)))
          (when cache
            (invalidate-region-cache cache beg (text-editor-point-max ed)
                                     (- start beg)
                                     (- (text-editor-point-max ed) end))))))

    (define (text-editor-beg-unchanged ed)
      ;; GNU Emacs's `BEG_UNCHANGED' (`buffer.h:156'): how many characters
      ;; at the beginning of the buffer are known not to have changed
      ;; since `text-editor-note-unchanged!' was last called. The `%l'
      ;; cache is only good while this still reaches past the line it
      ;; remembers - `BASE_LINE_NUMBER_VALID_P' (`xdisp.c:19393').
      ;;--------------------------------------------------------------
      (buffer-text-beg-unchanged (text-editor-text ed)))

    (define (text-editor-note-unchanged! ed)
      ;; Say that everything the buffer holds is current as of now, so
      ;; that `text-editor-beg-unchanged' counts from here. The C does
      ;; this from `mark_window_display_accurate_1', once per redisplay
      ;; (`xdisp.c:22732'); here the only reader is the `%l' cache, so it
      ;; is done when that cache is written - the same statement, made at
      ;; the one moment it is needed.
      ;;--------------------------------------------------------------
      (set!buffer-text-beg-unchanged
       (text-editor-text ed)
       (- (text-editor-point-max ed) (text-editor-point-min ed))))

    (define (%text-editor-delete-forward ed n)
      ;; Delete up to N characters after point, clamped at `point-max'.
      ;; GNU Emacs's `Fdelete_char' (`cmds.c:221') with a positive N
      ;; deletes the range `(PT, PT + n)'; where the C signals
      ;; `end-of-buffer' this engine's public delete clamps instead,
      ;; which is its documented behaviour.
      ;;--------------------------------------------------------------
      (let* ((point (text-editor-point ed))
             (avail (- (text-editor-point-max ed) point))
             (n     (min n avail))
             )
        (text-editor-invalidate-caches! ed point (+ point n))
        (buffer-text-delete! (text-editor-text ed) point (+ point n))
        n))

    (define (%text-editor-delete-backward ed n)
      ;; Delete up to N characters before point, clamped at `point-min',
      ;; and leave point at the start of what went.
      ;;--------------------------------------------------------------
      (let* ((point (text-editor-point ed))
             (avail (- point (text-editor-point-min ed)))
             (n     (min n avail))
             )
        (text-editor-invalidate-caches! ed (- point n) point)
        (buffer-text-delete! (text-editor-text ed) (- point n) point)
        (set!text-editor-point ed (- point n))
        n))

    (define (text-editor-delete-from-cursor ed n)
      ;; Delete N characters at the text editor cursor. Positive N
      ;; deletes characters after the cursor (forward), negative N
      ;; deletes characters before the cursor. Deletion is clamped to
      ;; the bounds of the buffer. Returns the number of characters
      ;; deleted.
      ;;
      ;; This is GNU Emacs's `delete-char' (`cmds.c:221') over
      ;; `del_range', with its two endpoint errors (`end-of-buffer',
      ;; `beginning-of-buffer') replaced by that clamp.
      ;;
      ;; The deleted text is captured first and recorded in the
      ;; buffer's undo list as `record_delete' (`undo.c:163') records
      ;; it: the text, and the position it went back to - POSITIVE when
      ;; point was at the beginning of it, NEGATIVE when point was at
      ;; the end.
      ;;
      ;; Nothing is deleted from a read-only buffer; that is an error,
      ;; as it is in GNU Emacs - and as with insertion, not when
      ;; `inhibit-read-only' says otherwise.
      ;;--------------------------------------------------------------
      (when (and (not (= n 0))
                 (text-editor-read-only? ed)
                 (not (*inhibit-read-only*)))
        (error "Buffer is read-only"))
      (cond
       ((= n 0) 0)
       (else
        (let* ((cursor (text-editor-point ed))
               (target (max (text-editor-point-min ed)
                            (min (text-editor-point-max ed) (+ cursor n))))
               (text   (text-editor-copy-string ed cursor target))
               (deleted (cond
                         ((< n 0) (%text-editor-delete-backward ed (- n)))
                         (else (%text-editor-delete-forward ed n)))))
          (when (< 0 deleted)
            ;; The markers in what was deleted are left at its start,
            ;; and the ones after it move back. A backward delete took
            ;; the text before the cursor, so the deleted range began
            ;; DELETED characters before it; a forward delete took the
            ;; text after it, so the range began at it.
            (let ((beg (if (< n 0) (- cursor deleted) cursor)))
              (adjust-markers-for-deletion! ed beg (+ beg deleted))
              (let ((offset (*text-property-offset-function*)))
                (when offset (offset ed beg (- deleted))))
              ;; and the after-change hooks, while BEG is in hand: a
              ;; deletion inserts nothing, so the changed range is empty
              ;; and OLD-LENGTH is what went
              (signal-after-change beg beg deleted))
            (%text-editor-note-change! ed)
            ;; One rise for the whole deletion, sized by how much went,
            ;; and again *after* the first-change mark - the C's
            ;; `record_delete' then `modiff_incr (&MODIFF, nchars_del)'
            ;; (`insdel.c:2030', `:2036').
            (%text-editor-incr-modiff! ed deleted)
            ;; The sign of the recorded position is Emacs's rule in
            ;; `record_delete': `-beg' when point was at the end of the
            ;; deleted text (a backward delete leaves it there), `beg'
            ;; when it was at the beginning (a forward delete). In both
            ;; cases `(abs POS)' is where the text has to go back, and
            ;; the sign is what tells the undo which side of it to leave
            ;; point on.
            (%undo-record-deletion! ed text (if (< n 0) (- deleted cursor) cursor)))
          deleted))))

    (define (text-editor-insert-from-port ed port)
      ;; Insert everything the port has left, at the cursor. This is
      ;; GNU Emacs's `insert-file-contents' (`fileio.c'): the text is
      ;; read first and inserted in one go, which is the C's shape - it
      ;; reads the file into a buffer and inserts the whole of it.
      ;;
      ;; The old engine read one *line* at a time, because a line was
      ;; the unit it stored and a line break was a record's field rather
      ;; than a character. There are no lines to read one at a time now,
      ;; so `text-editor-insert-line-from-port', which stopped at the
      ;; first frozen line, is gone with them.
      ;;--------------------------------------------------------------
      (let loop ((acc '()))
        (let ((next (read-char port)))
          (cond
           ((eof-object? next) (text-editor-insert ed (list->string (reverse acc))))
           (else (loop (cons next acc)))
           ))))

    ;; Writing the buffer out
    ;;
    ;; The engine keeps one sequence of characters, so writing it out is
    ;; one `write-string' of the whole text with the buffer's line-break
    ;; convention applied - the shape `text-editor-dump-before' and
    ;; `text-editor-dump-after' had to fake, because the live copy of the
    ;; current line sat in the line editor rather than in the buffer.

    (define (text-editor-dump ed port)
      ;; Write the buffer's characters to PORT, with a `\n' written as
      ;; the buffer's own line break.
      ;;--------------------------------------------------------------
      (let ((lbrk (text-editor-line-break ed)))
        (buffer-text-for-each
         (text-editor-text ed)
         (lambda (_pos cp)
           (if (= cp #x0a)
               ((line-break-write-to-port lbrk) port)
               (write-char (integer->char cp) port))
           ))))


    (define text-load-port
      (case-lambda
       ((ed port) (text-load-port ed port #f))
       ((ed port _flags) (text-editor-insert-from-port ed port))
       ))

    (define text-dump-port
      (case-lambda
       ((ed port) (text-dump-port ed port #f))
       ((ed port _flags) (text-editor-dump ed port))
       ))

    (define (text-editor-to-string ed)
      ;; The buffer's characters as a string - GNU Emacs's
      ;; `buffer-string' (`editfns.c'): "Return the contents of the
      ;; current buffer as a string."
      ;;
      ;; It is the *raw* text, with `\n' for every line break and no
      ;; coding-system translation, because that is what a buffer holds
      ;; in Emacs. The buffer's line-break convention is applied once,
      ;; by whoever writes the buffer out - `(schemacs editor files)'s
      ;; `encode-line-breaks', which mirrors `coding.c' - and not here:
      ;; this used to route through `text-dump-port', which applies the
      ;; line break, and `save-buffer' then applied it a second time, so
      ;; a CRLF file was written as `\r\r\n'.
      ;;--------------------------------------------------------------
      (text-editor-copy-string ed
                               (text-editor-point-min ed)
                               (text-editor-point-max ed)))

    ;;----------------------------------------------------------------
    ;; The cursor, lines and columns
    ;;
    ;; GNU Emacs stores no line index. It *scans*: `find_newline'
    ;; (`search.c:675') walks the buffer counting newlines, and
    ;; everything that wants a line or a column is built on it - `bol'
    ;; and `eol' (`editfns.c:665', :723), `line-beginning-position',
    ;; `line-end-position', `line-number-at-pos' (`fns.c:6688').
    ;;
    ;; The engine used to keep an index instead: a CDF over a gap buffer
    ;; of lines, so a character index could be turned into a line with a
    ;; binary search. That was a departure, and an expensive one - the
    ;; index had to be invalidated on every edit, and where it went stale
    ;; showed up three screens from where it mattered. There is one
    ;; sequence of characters now and no index; the scans below are
    ;; Emacs's, ported over `buffer-text'.
    ;;
    ;; Positions are one-based, as Emacs's are: `point-min' is 1 and
    ;; `point-max' is one past the last character. Line numbers count
    ;; from 1; columns count from 0.
    ;;
    ;; A knowing deviation: `find_newline' in the C exists largely to
    ;; cope with a byte store that a gap splits in two, and it keeps a
    ;; `region_cache' of where newlines are known to be, so that
    ;; repeated scans do not walk the whole buffer. `buffer-text-ref'
    ;; already copes with the gap, so the gap half of the C is gone;
    ;; the *cache* half is not ported, so a scan here really is O(n).
    ;; That is what the renderer pays for a line it reads by scanning to
    ;; it, and the cache is the Emacs answer when that stops being good
    ;; enough.

    ;;----------------------------------------------------------------
    ;; Positions

    (define (text-editor-point-min ed)
      ;; GNU Emacs's `point-min' (`editfns.c'): "the minimum permissible
      ;; value of point in the current buffer. This is 1, unless
      ;; narrowing ... is in effect." Nothing is narrowed here, and the
      ;; buffer-text's base is that same 1.
      ;;--------------------------------------------------------------
      (buffer-text-base (text-editor-text ed)))

    (define (text-editor-point-max ed)
      ;; GNU Emacs's `point-max' (`editfns.c'): one past the last
      ;; character of the buffer. It is the buffer-text's own `z' field,
      ;; which is Emacs's `Z'.
      ;;--------------------------------------------------------------
      (buffer-text-z (text-editor-text ed)))

    (define (text-editor-ref ed pos)
      ;; The character at position POS, or false when there is none
      ;; there - GNU Emacs's `char-after' (`editfns.c'), which answers
      ;; nil at or past the end of the buffer.
      ;;--------------------------------------------------------------
      (and (<= (text-editor-point-min ed) pos)
           (< pos (text-editor-point-max ed))
           (integer->char (buffer-text-ref (text-editor-text ed) pos))
           ))

    ;;----------------------------------------------------------------
    ;; Newlines

    (define (find-newline ed start count end)
      ;; GNU Emacs's `find_newline' (`search.c:675'): scan COUNT line
      ;; boundaries from START, forward for a positive COUNT and
      ;; backward for a negative one, and stop at END if COUNT of them
      ;; are not there.
      ;;
      ;; Two values come back: where the scan stopped, and how many
      ;; boundaries it found, counted the way COUNT is - positive going
      ;; forward, negative going backward. Where it found them all, the
      ;; position is just past the COUNTth one; where it ran out of
      ;; text, it is END. Both conventions are the C's, whose caller
      ;; reads the pair out of `*counted' and `*bytepos'.
      ;;
      ;; Scanning backward looks at the character *before* the position
      ;; it is at, so a COUNT of -1 from the middle of a line lands on
      ;; the line's first character when there is a newline just behind
      ;; it - which is what `bol' is.
      ;;
      ;; END false means what the C's zero means: "the end of the buffer
      ;; in the direction of travel" - `ZV' going forward, `BEGV' going
      ;; backward (`search.c:681').
      ;;
      ;; The line-break cache (`buf->newline_cache', which is
      ;; `(schemacs editor region-cache)') is consulted on the way, as
      ;; the C consults it: a stretch already searched and found to hold
      ;; no line break is skipped whole, and a stretch this scan crosses
      ;; without finding one is recorded as known. That is what makes a
      ;; buffer with very long lines affordable - see `region-cache.sld'
      ;; for why the C has it at all.
      ;;--------------------------------------------------------------
      (let* ((end  (or end (if (< 0 count)
                               (text-editor-point-max ed)
                               (text-editor-point-min ed))))
             ;; The cache is made here on first use, as the C makes it
             ;; (`if (!cache_buffer->newline_cache) cache_buffer->
             ;; newline_cache = new_region_cache ()', `search.c:640') - a
             ;; buffer whose lines are never searched never pays for one.
             (cache (or (%text-editor-newline-cache ed)
                        (let ((c (new-region-cache (text-editor-point-min ed))))
                          (set!%text-editor-newline-cache ed c)
                          c))))
        (if (< 0 count)
            (find-newline-forward ed start count end cache)
            (find-newline-backward ed start count end cache))))

    (define (%newline-in ed pos lim)
      ;; The first line break in [POS, LIM), or false when there is none -
      ;; the C's "dumb loop", the innermost scan that knows nothing about
      ;; the cache or the buffer's ends. It carries one variable, because
      ;; it runs once per character.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((>= p lim) #f)
                ((= (buffer-text-ref text p) #x0a) p)
                (else (loop (+ p 1)))))))

    (define (%newline-before ed pos lim)
      ;; The first line break strictly before POS and at or after LIM,
      ;; answering the position just *after* it, or false when there is
      ;; none. Scanning backward looks at the character before the
      ;; position it is at, which is why the answer is a position past the
      ;; break rather than on it.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((p pos))
          (cond ((<= p lim) #f)
                ((= (buffer-text-ref text (- p 1)) #x0a) p)
                (else (loop (- p 1)))))))

    (define (find-newline-forward ed start count end cache)
      ;; The forward half of `find-newline'. Each round asks the cache
      ;; where the knowledge runs out, scans that far for a line break,
      ;; and records what it crossed - which is the C's structure: consult,
      ;; dumb-loop, `know_region_cache', repeat.
      ;;
      ;; A stretch the cache calls known holds no line break, so it is
      ;; stepped over rather than looked at. That is the whole saving.
      ;;--------------------------------------------------------------
      (let ((beg (text-editor-point-min ed))
            (z (text-editor-point-max ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (>= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-forward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    ;; known: no break in here at all - step over it
                    (let ((skip (min next-change end)))
                      (if (<= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    ;; unknown as far as NEXT-CHANGE, or as far as the
                    ;; caller asked
                    (let ((lim (min (if (> next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-in ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (> lim pos))
                            (know-region-cache cache beg z pos lim))
                          (outer lim left found))
                         (else
                          (when (and cache (> nl pos))
                            (know-region-cache cache beg z pos nl))
                          (if (= left 1)
                              (values (+ nl 1) (+ found 1))
                              (outer (+ nl 1) (- left 1) (+ found 1)))))))))))))))

    (define (find-newline-backward ed start count end cache)
      ;; The backward half of `find-newline', the mirror of the forward
      ;; one: consult, scan down to where the knowledge runs out, record
      ;; what was crossed, repeat.
      ;;--------------------------------------------------------------
      (let ((beg (text-editor-point-min ed))
            (z (text-editor-point-max ed)))
        (let outer ((pos start) (left count) (found 0))
          (if (<= pos end)
              (values end found)
              (call-with-values
                  (lambda ()
                    (if cache
                        (region-cache-backward cache beg z pos)
                        (values 0 pos)))
                (lambda (known next-change)
                  (cond
                   ((= known 1)
                    (let ((skip (max next-change end)))
                      (if (>= skip pos)
                          (values end found)
                          (outer skip left found))))
                   (else
                    (let ((lim (max (if (< next-change pos) next-change end)
                                    end)))
                      (let ((nl (%newline-before ed pos lim)))
                        (cond
                         ((not nl)
                          (when (and cache (< lim pos))
                            (know-region-cache cache beg z lim pos))
                          (outer lim left found))
                         (else
                          (when (and cache (< nl pos))
                            (know-region-cache cache beg z nl pos))
                          (if (= left -1)
                              (values nl -1)
                              (outer (- nl 1) (+ left 1) (- found 1)))))))))))))))

    (define (scan-newline-from-point ed count)
      ;; GNU Emacs's `scan_newline_from_point' (`search.c':986'): scan
      ;; COUNT line boundaries from point. It does not move point.
      ;;
      ;; Two values come back - where the scan stopped, and how many
      ;; boundaries it found - which is the C's two out-parameters
      ;; (`*charpos' and the returned `counted'). A COUNT at or below
      ;; zero scans backward, one boundary further back than COUNT asks
      ;; for; that difference is what makes `bol' land on the *start* of
      ;; a line where `forward-line' would land on the one before it.
      ;;--------------------------------------------------------------
      (if (<= count 0)
          (find-newline ed (text-editor-point ed) (- count 1)
                        (text-editor-point-min ed))
          (find-newline ed (text-editor-point ed) count
                        (text-editor-point-max ed))))

    (define (bol ed n)
      ;; The position of the first character of the line N - 1 lines
      ;; forward - the internal `bol' (`editfns.c:665') that
      ;; `line-beginning-position', `beginning-of-line' and
      ;; `forward-line' are all built on. N false means the current
      ;; line. It does not move point.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (scan-newline-from-point ed (if n (- n 1) 0)))
        (lambda (pos _found) pos)))

    (define (eol ed n)
      ;; The position of the last character of the line N - 1 lines
      ;; forward - the internal `eol' (`editfns.c:723') that
      ;; `line-end-position', `end-of-line' and `forward-line' are built
      ;; on. N false means the current line. It does not move point.
      ;;--------------------------------------------------------------
      (let ((count (if n n 1)))
        (find-before-next-newline ed (text-editor-point ed)
                                  (- count (if (<= count 0) 1 0)))))

    (define (find-before-next-newline ed from cnt)
      ;; GNU Emacs's `find_before_next_newline' (`search.c':997'): where
      ;; the line boundary CNT boundaries away from FROM begins. With a
      ;; positive CNT the scan lands just *after* the newline, so it
      ;; steps back one, to the newline's own position - which is what
      ;; an end-of-line wants.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda () (find-newline ed from cnt #f))
        (lambda (pos found)
          (if (= found cnt) (- pos 1) pos))))

    (define (count-lines ed from to)
      ;; The number of line boundaries between the positions FROM and TO
      ;; - GNU Emacs's `count_lines' (`xdisp.c:29892'), which is
      ;; `display_count_lines (FROM, TO, ZV)'. The C's display version
      ;; also honours `selective-display'; that is not ported.
      ;;
      ;; NOTE: `count_lines' is `xdisp.c''s in Emacs and this is the
      ;; engine, but `line-number-at-pos' - which is what wants it - is
      ;; `fns.c''s and reads the buffer through exactly this scan.
      ;; `(schemacs editor xdisp)' imports the engine, so the name lives
      ;; here and can be re-exported there.
      ;;--------------------------------------------------------------
      (let ((text (text-editor-text ed)))
        (let loop ((pos from) (n 0))
          (cond
           ((>= pos to) n)
           ((= (buffer-text-ref text pos) #x0a) (loop (+ pos 1) (+ n 1)))
           (else (loop (+ pos 1) n))))))

    ;;----------------------------------------------------------------
    ;; Lines, by scanning

    (define (%line-start ed line)
      ;; The position of the first character of line LINE, counting from
      ;; 1; false when the buffer has no such line. This is the `bol'
      ;; scan started from the buffer's beginning rather than from
      ;; point: `find_newline' from `point-min' for LINE - 1 boundaries.
      ;;--------------------------------------------------------------
      (and (integer? line)
           (<= (text-editor-point-min ed) line)
           (call-with-values
               (lambda ()
                 (find-newline ed (text-editor-point-min ed) (- line 1) #f))
             (lambda (pos found) (and (= found (- line 1)) pos)))))

    (define (%bol-at ed pos)
      ;; The position of the first character of the line POSITION is on.
      ;; Emacs reaches this with `save-excursion' around
      ;; `line-beginning-position'; here the scan simply starts where it
      ;; is told to.
      ;;--------------------------------------------------------------
      (call-with-values
          (lambda ()
            (find-newline ed pos -1 (text-editor-point-min ed)))
        (lambda (found-pos _found) found-pos)))

    (define (%line-end ed from)
      ;; The position of the newline that ends the line containing FROM, or
      ;; `point-max' when there is none. It is the forward half of `eol'
      ;; with the scan started where it is told to rather than at point.
      ;;
      ;; It goes through `find-before-next-newline', and so through
      ;; `find-newline' and the line-break cache, as the C's does. It used
      ;; to be a private character-at-a-time loop, which not only
      ;; duplicated a scan Emacs already has but missed the cache
      ;; entirely - a long line was re-walked by every caller, which is
      ;; what `region-cache.c' exists to prevent.
      ;;--------------------------------------------------------------
      (find-before-next-newline ed from 1))

    (define (%text-editor-position ed line col)
      ;; The position of column COL - counting from 0 - on line LINE -
      ;; counting from 1 - clamped to the line. False when the buffer
      ;; has no such line. This is what `goto-line' and `move-to-column'
      ;; between them do, `line-beginning-position' then an offset.
      ;;--------------------------------------------------------------
      (let ((start (%line-start ed line)))
        (and start
             (min (%line-end ed start) (+ start (max 0 col))))))

    (define (text-editor-line-string ed line)
      ;; The contents of LINE - a line *number*, counting from 1 - as a
      ;; string, without the line break that ends it. False when the
      ;; buffer has no such line.
      ;;
      ;; There is no Emacs function that materialises a line as a
      ;; string: `xdisp.c' walks the buffer with the display iterator
      ;; and never builds one. This is the engine's own, the shortcut
      ;; the renderer reads its lines through, and both ends of the line
      ;; come from the same scans everything else uses.
      ;;--------------------------------------------------------------
      (let ((start (%line-start ed line)))
        (and start
             (buffer-text-substring (text-editor-text ed)
                                    start (%line-end ed start)))))

    (define (text-editor-line-outer-size ed line)
      ;; How many characters line LINE advances the buffer by: its
      ;; contents plus the line break that ends it. Zero for a line the
      ;; buffer does not hold.
      ;;--------------------------------------------------------------
      (let ((start (%line-start ed line)))
        (if (not start)
            0
            (let ((end (%line-end ed start)))
              (+ (- end start)
                 (if (< end (text-editor-point-max ed)) 1 0))))))

    (define text-editor-get-start-of-line
      ;; The position of the first character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-beginning-position' (`editfns.c:700'), which is
      ;; `(bol nil)'; with a POSITION the C reaches the same place with
      ;; `save-excursion' around `goto-char', the scan here simply starts
      ;; where it is told to. It does not move point.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (bol ed #f))
       ((ed pos) (%bol-at ed pos))))

    (define text-editor-get-end-of-line
      ;; The position of the last character of the line point is on - or,
      ;; with POS, of the line POS is on. GNU Emacs's
      ;; `line-end-position' (`editfns.c:736'), which is `(eol nil)'; the
      ;; POSITION form is the same scan started where it is told to
      ;; rather than at point. At the end of the buffer it is `point-max',
      ;; as the C's is. It does not move point.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (eol ed #f))
       ((ed pos) (%line-end ed pos))))

    (define (text-editor-line-count ed)
      ;; How many lines the buffer has - which is the line number of
      ;; `point-max', since every line boundary in front of it starts
      ;; another line. An empty buffer has one line, as Emacs's does.
      ;;--------------------------------------------------------------
      (+ 1 (count-lines ed (text-editor-point-min ed)
                           (text-editor-point-max ed))))

    (define (text-editor-cursor-line ed)
      ;; The line number point is on, counting from 1 - GNU Emacs's
      ;; `line-number-at-pos' (`fns.c:6688'), which is
      ;; `(count_lines BEGV PT) + 1'.
      ;;--------------------------------------------------------------
      (+ 1 (count-lines ed (text-editor-point-min ed) (text-editor-point ed))))

    (define (text-editor-cursor-column ed)
      ;; How many characters point is from the start of its line,
      ;; counting from 0 - what the C's `current-column' (`indent.c:298')
      ;; answers for a line with no tab and no multi-column character in
      ;; it. The *display* column, which is what `current-column' really
      ;; answers, is `(schemacs editor indentc)''s
      ;; `current-line-display-column', and every caller that wants one
      ;; goes through it.
      ;;--------------------------------------------------------------
      (- (text-editor-point ed) (text-editor-get-start-of-line ed)))

    (define (text-editor-line-ref ed offset)
      ;; The character at column OFFSET - counting from 0 - of the
      ;; current line, or false when OFFSET is past the end of the line.
      ;; The display-width walk and the renderer read a line's
      ;; characters through this.
      ;;--------------------------------------------------------------
      (let ((pos (+ (text-editor-get-start-of-line ed) offset)))
        (and (< pos (text-editor-get-end-of-line ed))
             (integer->char (buffer-text-ref (text-editor-text ed) pos)))))

    (define (text-editor-get-char-index ed ch-index)
      ;; The character at position CH-INDEX, or false when there is none
      ;; there - GNU Emacs's `char-after' (`editfns.c'), which answers
      ;; nil at or past the end of the buffer.
      ;;--------------------------------------------------------------
      (text-editor-ref ed ch-index))

    ;;----------------------------------------------------------------
    ;; Moving the cursor

    (define (text-editor-get-cursor ed)
      ;; The position of the cursor, one-based as every position of this
      ;; engine is - GNU Emacs's `point' (`editfns.c'). Emacs keeps `PT'
      ;; on the buffer and so does this: the position *is* the cursor.
      ;;--------------------------------------------------------------
      (text-editor-point ed))

    (define (text-editor-move-cursor ed move-by)
      ;; Move the cursor MOVE-BY characters, clamped to the buffer -
      ;; GNU Emacs's `forward-char' (`cmds.c') with its two endpoint
      ;; errors replaced by that clamp. Answers the new position.
      ;;--------------------------------------------------------------
      (text-editor-set-cursor
       ed (max (text-editor-point-min ed)
               (min (text-editor-point-max ed)
                    (+ (text-editor-point ed) move-by)))))

    (define text-editor-set-cursor
      (case-lambda
       ((ed index)
        (if (integer? index)
            ;; A position, one-based as every position here is.
            (set!text-editor-point ed
               (max (text-editor-point-min ed)
                    (min (text-editor-point-max ed) index)))
            (error "text editor index must be set with an integer" index)))
       ((ed line-num column-num)
        ;; Move the cursor to the given line - counting from 1, as
        ;; `line-number-at-pos' does - and column, counting from 0 as
        ;; `current-column' does, clamped to the line. This is
        ;; `goto-line' followed by `move-to-column', both built on the
        ;; scans.
        ;;
        ;; The new empty line past the end of the buffer is only
        ;; addressable when the buffer's last line ends in a line break
        ;; - that break is what starts it. Without one, the last line
        ;; the buffer holds is the last line there is, and the end of
        ;; the buffer is the end of that line, which is where GNU Emacs
        ;; puts `point-max'.
        (set!text-editor-point
         ed (max (text-editor-point-min ed)
                 (min (text-editor-point-max ed)
                      (or (%text-editor-position
                           ed (max 1 line-num) (max 0 column-num))
                          (text-editor-point-max ed)))))))
      )

    )
  )
