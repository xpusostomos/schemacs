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
    (only (schemacs weak)
          new-weak-set  weak-set-add!  weak-set-delete!  weak-set-for-each)
    (only (schemacs editor cdf)
          new-cdf  cdf-cursor  cdf-maximum  cdf-ref
          cdf-fill  cdf-invalidate!  cdf-push  cdf-find
          )
    (prefix (schemacs ui text-buffer-impl) impl/)
    (only (schemacs ui text-buffer-impl)
          make<text-location>  text-location-type?
          text-location-line   text-location-column
          text-location  show-text-location
          )
    (only (schemacs sequence)
          *sequence-allocate-function*
          sequence-resize
          vector-sequence-iface
          u16vector-sequence-iface
          u32vector-sequence-iface
          u64vector-sequence-iface
          bytevector-sequence-iface
          get-sequence-iface
          iface-make-sequence
          iface-sequence-length
          iface-sequence-ref
          iface-sequence-set!
          iface-sequence-copy!
          iface-sequence-for-each
          seq-step-forward/index
          typeof-vector?
          )
    (only (schemacs gap-buffer)
          new-gap-buffer              gap-buffer-allocate
          gap-buffer-end-of-line?     gap-buffer-start-of-line?
          gap-buffer-for-each         gap-buffer-for-each/index
          gap-buffer-for-each-after   gap-buffer-for-each-after/index
          gap-buffer-for-each-before  gap-buffer-for-each-before/index
          gap-buffer-update-min-max   gap-buffer-insert-min-max
          gap-buffer-set-cursor       gap-buffer-ref
          gap-buffer-ref-before       gap-buffer-ref-after
          gap-buffer-cursor-to-start  gap-buffer-cursor-to-end
          gap-buffer-insert-before    gap-buffer-insert-after
          gap-buffer-delete
          gap-buffer-minimum          set!gap-buffer-minimum
          gap-buffer-maximum          set!gap-buffer-maximum
          gap-buffer-cursor           gap-buffer-weight
          gap-buffer-clear-before     gap-buffer-clear
          )
    )
  (cond-expand
   ;; To define pretty-printers for Guile
   (guile-3
    (import (only (srfi srfi-9 gnu) set-record-type-printer!))
    )
   (else)
   )
  (export
   ;; Text lines, these are contain individual lines of text possibly
   ;; terminated with some line breaking character sequence.
   text-line-type?  new-text-line  text-line
   text-line-inner-size  text-line-outer-size
   write-text-line  text-line-for-each
   text-line-ref    text-line-code-ref
   text-line->string  text-line-inner->string  show-text-line

   ;; The text editor data type
   new-text-editor  text-editor-type?
   *init-text-editor-line-count*
   text-editor-char-count
   text-load-port  text-dump-port  text-editor-to-string
   text-editor-insert
   text-editor-delete-from-cursor
   text-editor-copy-string

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

   ;; Getting and setting the cursor index
   text-editor-char-count
   text-editor-cursor-line
   text-editor-cursor-column
   text-editor-cursor-location
   text-editor-line-count
   text-editor-get-start-of-line
   text-editor-get-end-of-line
   text-editor-get-line-column
   text-editor-set-cursor
   text-editor-move-cursor
   text-editor-get-cursor
   text-editor-get-char-index
   text-editor-line-editor-ref
   text-editor-text-line-ref
   text-editor-line-outer-size
   text-editor  show-text-editor

   run-editor-engine
   ;; ^ This procedure is called in the same way as the Scheme
   ;; `apply` procedure, except that it parameterizes all of the
   ;; relevant parameter variables in the
   ;; `(schemacs ui text-buffer-impl)` library.
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

    (define cdf-sequence-iface u64vector-sequence-iface)

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

    (define (line-break-2-state break-ch0 break-ch1)
      ;; To understand this procedure, consider the case where we are
      ;; constructing a state machine to handle CR-LF line breaks.
      (define (make-state-machine ed)
        (define (state-1 input-ch)
          ;; This is the procedure for the state that the text editor is
          ;; in ordinarily, having not yet received a CR character since
          ;; the last line break event.
          (cond
           ((char=? input-ch break-ch0)
            ;; On receiving the CR character we set the text editor to
            ;; the next state in the state machine, which awaits an LF
            ;; character.
            (set!text-editor-insert-char ed state-2)
            )
           (else
            ;; If we do not receive the CR character, trigger the
            ;; `ON-NON-BREAK` character event, which would insert the
            ;; character into the buffer as usual.
            (text-editor-force-insert-char ed input-ch)
            )))
        (define (state-2 input-ch)
          ;; This is the procedure for the state the the text editor is
          ;; in after having received the CR character. In this second
          ;; state, regardless of what character we receive, the text
          ;; editor always returns back to being in the first state.
          (set!text-editor-insert-char ed state-1)
          (cond
           ((char=? input-ch break-ch1)
            ;; If we receive the LF character, trigger the `ON-BREAK`
            ;; event, which will freeze the line editor and push the
            ;; line into the buffer, then reset the line editor.
            (text-editor-add-char-count ed 2)
            (text-editor-force-line-break ed)
            )
           (else
            ;; If we are in the state of having received a CR but then
            ;; we do not receive an LF, insert the CR as any ordinary
            ;; character.
            (text-editor-force-insert-char ed break-ch0)
            (text-editor-force-insert-char ed input-ch)
            )))
        state-1
        )
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
       (lambda (ed)
         (set!text-editor-insert-char ed (make-state-machine ed))
         )))

    (define (line-break-1-state break-ch)
      (make<line-break>
       (make-bytevector 1 (char->integer break-ch))
       (make-string 1 break-ch)
       (lambda (port) (write-char break-ch port))
       (lambda (ed)
         (set!text-editor-insert-char
          ed (lambda (input-ch)
               (cond
                ((char=? input-ch break-ch)
                 (text-editor-add-char-count ed 1)
                 (text-editor-force-line-break ed)
                 )
                (else
                 (text-editor-force-insert-char ed input-ch)
                 )))))))

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
    ;; "immutable" text lines

    (define-record-type <text-line-type>
      ;; This is the type for lines of text in the buffer. Once a line
      ;; it is done being editied, it is "frozen" to this type and
      ;; placed somewhere into the buffer where the line cursor is.
      ;;--------------------------------------------------------------
      (make<text-line> string props parser offset maxval lbrk iface)
      text-line-type?
      (string   text-line-string   set!text-line-string)
      ;; ^ This defines the actual string content.
      (props    text-line-props    set!text-line-props)
      ;; ^ This stores aribtrary information about the text properties
      ;; of the string. It should be a Vector-Backed Association list
      ;; (VBAL) type.
      (parser   text-line-parser  set!text-line-parser)
      ;; ^ When parsing a large files it is sometimes faster to keep a
      ;; continuation with the current parser state that was captured
      ;; when the end of the input lines was reached by the parser.
      ;; This allows the continuation to resume from this text line
      ;; when a change is made to lines coming after it.
      (offset   text-line-char-offset  set!text-line-char-offset)
      ;; ^ A simple way to compress data using an unboxed vector is to
      ;; keep track of the lowest and highest value in the sequence and
      ;; offset them so they fit into a fewer number of bits.
      (maxval   text-line-char-max     set!text-line-char-max)
      (lbrk     text-line-break        set!text-line-break)
      ;; ^ The line breaking symbol (or char or string) used to
      ;; delimit this line from the next in a sequence of lines. This
      ;; is usually the procedure `line-break-crlf`,
      ;; `line-break-lfcr`, `line-break-null`, `line-break-newline`,
      ;; or `line-break-return`.
      (iface    text-line-sequence-iface)
      ;; ^ a reference to the vector interface for the
      ;; `text-line-string` field of this value.
      )

    (define new-text-line
      (case-lambda
       ((string) (new-text-line (get-sequence-iface string) string))
       ((iface string)
        (make<text-line> string #f #f #f #f #f iface)
        )))

    (define (text-line-inner-size line)
      ;; Return the number of characters in the text line
      ;; *NOT_INCLUDING* the line break.
      ;;--------------------------------------------------------------
      (let ((iface (text-line-sequence-iface line)))
        ;; If `iface` is `#f` this is an indication that the line is empty
        (cond
         (iface ((iface-sequence-length iface) (text-line-string line)))
         (else 0)
         )))

    (define (text-line-outer-size line)
      ;; Return the number of characters in the text line including
      ;; the line break.
      ;;--------------------------------------------------------------
      (let ((lbrk (text-line-break line)))
        (+ (text-line-inner-size line)
           (if lbrk (line-break-size lbrk) 0)
           )))

    (define (text-line-ref line i)
      ;; Lookup a character in the `LINE` at the given index `I`.
      ;;--------------------------------------------------------------
      (let ((c (text-line-code-ref line i)))
        (and c (integer->char c))
        ))

    (define (text-line-code-ref line i)
      ;; Like `text-line-ref` but returns the UTF code point, rather
      ;; than a `char?` value.
      ;;--------------------------------------------------------------
      (let*((iface (text-line-sequence-iface line))
            (str (text-line-string line))
            (len (if iface ((iface-sequence-length iface) str) 0))
            )
        (cond
         ((< i 0) #f)
         ((< i len)
          (+ (text-line-char-offset line)
             ((iface-sequence-ref (text-line-sequence-iface line))
              (text-line-string line) i
              )))
         (else
          (let*((lbrk (text-line-break line))
                (lbrk-str (and lbrk (line-break-bytevector lbrk)))
                (lbrk-len (and lbrk-str (bytevector-length lbrk-str)))
                (i (and lbrk-len (- i len)))
                )
            (cond
             ((and i (< i lbrk-len)) (bytevector-u8-ref lbrk-str i))
             (else #f)
             ))))))

    (define (text-line-for-each proc line)
      (let ((str (text-line-string line)))
        (cond
         ((string? str) (string-for-each proc str))
         ((not     str) (values))
         (else
          (let*((iface   (text-line-sequence-iface line))
                (foreach (iface-sequence-for-each iface))
                (offset  (text-line-char-offset line))
                )
            (cond
             ((and offset (= offset 0))
              (foreach (lambda (i) (proc (integer->char i))) str)
              )
             (else
              (foreach
               (lambda (i) (proc (integer->char (+ i offset))))
               str
               ))))))))

    (define write-text-line
      ;; Write the content of a `text-line-type?` to a port. If the
      ;; text line applied is the only argument, and no port is
      ;; applied as an argument, then the port returned by
      ;; `current-output-port` is used.
      ;;--------------------------------------------------------------
      (case-lambda
        ((line) (write-text-line line (current-output-port)))
        ((line port)
         (let ((lbrk (text-line-break line)))
           (text-line-for-each (lambda (c) (write-char c port)) line)
           (when lbrk ((line-break-write-to-port lbrk) port))
           ))))

    (define (text-line->string line)
      ;; The "file form" of a line: the line contents INCLUDING its
      ;; terminating line break, exactly as `write-text-line` writes
      ;; it to a file.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (write-text-line line port)
          (get-output-string port)
          )))

    (define (text-line-inner->string line)
      ;; The "display form" of a line: the line contents WITHOUT its
      ;; terminating line break. This is what a display layer should
      ;; draw; the line break is part of the file, not part of the
      ;; line's visible contents.
      ;;--------------------------------------------------------------
      (call-with-port (open-output-string)
        (lambda (port)
          (text-line-for-each (lambda (c) (write-char c port)) line)
          (get-output-string port)
          )))

    (define (text-line str)
      ;; Construct a text line from a string `STR`. The given `STR` is
      ;; copied into a new character vector up to but not including
      ;; any line breaking character (if any). All characters after a
      ;; line breaking character are ignored. Line breaking characters
      ;; include `#\newline`, `#\return`, and `#\null`.
      ;;--------------------------------------------------------------
      (cond
       ((string? str)
        (let ((len (string-length str)))
          (let loop ((lo #x10FFFF) (hi 0) (count 0))
            (let ((ch (and (< count len) (string-ref str count))))
              (cond
               ((or (not ch) 
                    (char=? ch #\newline)
                    (char=? ch #\return)
                    (char=? ch #\null)
                    )
                (let*((iface (%line-editor-pre-freeze lo hi))
                      (set-char! (iface-sequence-set! iface))
                      (vec ((iface-make-sequence iface) count))
                      )
                  (let loop ((i 0))
                    (cond
                     ((< i count)
                      (set-char! vec (- (char->integer (string-ref str i)) lo))
                      (loop (+ 1 i))
                      )
                     (else (make<text-line> vec #f #f lo hi #f iface))
                     ))))
               (else
                (let ((pt (char->integer ch)))
                  (loop (min lo pt) (max hi pt) (+ 1 count))
                  )))))))
       (else (error "not a string" str))
       ))

    (define show-text-line
      (case-lambda
       ((line) (show-text-line line (current-output-port)))
       ((line port)
        (display "(text-line " port)
        (write (text-line->string line) port)
          ;; ^ TODO: this need to output characters WITHOUT allocating
          ;; a string copy of the line first
        (display ")" port)
        )))

    (cond-expand
     (guile
      (set-record-type-printer! <text-line-type> show-text-line)
      )
     (else)
     )

    ;;----------------------------------------------------------------

    (define-record-type <text-editor-type>
      (make<text-editor>
       lines  count  line-ed  line-ch  moved  column
       cdf  ins-char  lbrk  textprops  undo
       modified  save-token  read-only  mark  markers
       deactivate-mark
       name  file-name
       )
      text-editor-type?
      (lines      text-editor-lines         set!text-editor-lines)
      ;; ^ A <gap-buffer-type> which buffers <text-line-type> values.
      (count      text-editor-char-count    set!text-editor-char-count)
      ;; ^ Counting the number of characters.
      (line-ed    text-editor-line-editor   set!text-editor-line-editor)
      ;; ^ A <gap-buffer-type> which buffers characters, edits the
      ;; current line under the cursor.
      (line-ch    text-editor-line-changed  set!text-editor-line-changed)
      ;; ^ A boolean value indicating that the current line being edited
      ;; by the `text-editor-line-editor` has actually changed. This
      ;; allows the editor to decide whether the current line editor
      ;; needs to be frozen and written-back to the line buffer. If
      ;; there have been no edits when the cursor is moved, the freeze
      ;; and write-back step can be skipped.
      (moved      text-editor-line-moved    set!text-editor-line-moved)
      ;; ^ A boolean value indicating that the cursor of the
      ;; `text-editor-lines` gap buffer has moved and the line editor
      ;; need to be reset with the content of the current line.
      (column     text-editor-column        set!text-editor-column)
      ;; ^ When the selected line changes, the column number of the cursor
      ;; may be lost. This field keeps a record of the column number.
      (cdf        text-editor-cdf           set!text-editor-cdf)
      ;; ^ The "Cumulative Distribution Function" is a gap buffer that
      ;; keeps a running total number of characters for each line in
      ;; the `text-editor-lines` gap buffer. Any change to the
      ;; `text-editor-lines` buffer erases everything after the cursor
      ;; in the CDF so that they can be re-computed.
      (ins-char   %text-editor-insert-char   set!text-editor-insert-char)
      ;; ^ A function which inserts characters into the editor.
      (lbrk       text-editor-line-break     set!text-editor-line-break)
      ;; ^ The current line-breaking protocol.
      (textprops  text-editor-text-props     set!text-editor-text-props)
      ;; A VBAL that contains text properties for ranges of text that
      ;; span multiple <text-line-type> values. This is useful for
      ;; syntax coloring as you can declare all characters between any
      ;; two (line,colunm) coordinates to have a particular tag.
      (undo       text-editor-undo-list     set!text-editor-undo-list)
      ;; ^ The buffer's undo list, GNU Emacs's `buffer-undo-list'. A
      ;; list, newest entry first, of the edits that can be undone; or
      ;; false, which is Emacs's `t', meaning that the recording of
      ;; undo information is disabled. The empty list is Emacs's `nil':
      ;; recording is enabled but there is nothing to undo. See the
      ;; "Undo" section below for the entry formats.
      (modified   text-editor-modified-flag set!text-editor-modified-flag)
      ;; ^ Whether the buffer has been changed since it was last saved
      ;; or visited, GNU Emacs's `buffer-modified-p'. It is cleared by
      ;; saving and by undoing back past every change made since the
      ;; last save.
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
                 (line (new-gap-buffer u32vector-sequence-iface size))
                 (lbrk (or lbrk (*default-line-break*)))
                 (ed (let ()
                       (set!gap-buffer-minimum line #xFFFFFFFF)
                       (set!gap-buffer-maximum line 0)
                       (make<text-editor>
                        (new-gap-buffer vector-sequence-iface size)
                        0 line #f #f 0
                        (new-cdf u64vector-sequence-iface size)
                        #f lbrk props
                        ;; A newly created buffer records undo
                        ;; information from the start, as in GNU Emacs,
                        ;; is unmodified (there is no file it could
                        ;; differ from), writable, and has no mark set.
                        '() #f 0 #f
                        ;; The mark, pointing nowhere until it is set,
                        ;; and an empty marker chain.
                        (make<marker> #f 0 #f)
                        (new-weak-set)
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

    (define (text-editor-add-char-count ed count)
      (set!text-editor-char-count ed (+ count (text-editor-char-count ed)))
      )

    (define (show-text-editor-single-line port)
      (lambda (line)
        (display "  " port)
        (write (text-line->string line) port)
        (newline port)
        ))

    (define show-text-editor
      ;; Write the whole content of a text editor to a port.
      ;;--------------------------------------------------------------
      (case-lambda
       ((ed) (show-text-editor ed (current-output-port)))
       ((ed port)
        (let*((lines (text-editor-lines ed))
              (weight (gap-buffer-weight lines))
              (location (text-editor-cursor-location ed))
              )
          (display "(text-editor " port)
          (show-text-location location port)
          (cond
           ((= weight 0) (display ")" port))
           (else
            (newline port)
            (gap-buffer-for-each-before (show-text-editor-single-line port) lines)
            ;; TODO: output current gap buffer, if necessary.
            (gap-buffer-for-each-after (show-text-editor-single-line port) lines)
            (display "  )\n" port)
            ))))))

    (cond-expand
     (guile
      (set-record-type-printer! <text-editor-type> show-text-editor)
      )
     (else)
     )

    ;;----------------------------------------------------------------
    ;; Line editor procedures

    (define (line-editor-cursor-to-end! line-ed)
      (gap-buffer-cursor-to-end line-ed)
      )

    (define (line-editor-cursor-to-start! line-ed)
      (gap-buffer-cursor-to-start line-ed)
      )

    (define (%line-editor-pre-freeze lo hi)
      (or
       (and lo hi
        (let*((range (abs (- hi lo))))
          (cond
           ((<= range #xFF) bytevector-sequence-iface)
           ((<= range #xFFFF) u16vector-sequence-iface)
           (else #f)
           )))
       u32vector-sequence-iface
       ))

    (define (line-editor-freeze line-ed lbrk)
      ;; Freeze all characters in the line buffer into a new
      ;; `<text-line-type>` object that contains the exact right size
      ;; to hold all of the characters.
      ;;--------------------------------------------------------------
      (gap-buffer-update-min-max line-ed)
      (let*((weight   (gap-buffer-weight  line-ed))
            (cursor   (gap-buffer-cursor  line-ed))
            (lo       (gap-buffer-minimum line-ed))
            (hi       (gap-buffer-maximum line-ed))
            (iface    (%line-editor-pre-freeze lo hi))
            (vec      ((iface-make-sequence iface) weight))
            (seq-set! (iface-sequence-set! iface))
            )
        (gap-buffer-for-each/index
         (lambda (i n) (seq-set! vec i (- n lo)))
         line-ed
         )
        (make<text-line> vec #f #f lo hi lbrk iface)
        ))

    ;;----------------------------------------------------------------
    ;; Current-line checkout / write-back
    ;;
    ;; The canonical data model: the lines gap-buffer contains one
    ;; element for EVERY line of the buffer, so
    ;; `(GAP-BUFFER-REF LINES I)` is always line `I`. The line
    ;; currently under the cursor (whose index is the gap-buffer
    ;; cursor) is "checked out" into the line editor, which holds the
    ;; live copy of that line, while the gap-buffer element at the
    ;; cursor index holds a possibly-stale copy of the same line. The
    ;; gap-buffer cursor may also point one past the last element, in
    ;; which case the current line is a new, empty line (like the line
    ;; that follows the final newline of a file).
    ;;
    ;; `TEXT-EDITOR-LOAD-CURRENT-LINE` copies the line at the cursor
    ;; into the line editor. `TEXT-EDITOR-WRITE-BACK` freezes the line
    ;; editor into a <text-line-type> and stores it back into the gap
    ;; buffer when the line editor has been modified. Navigation
    ;; procedures write back before moving the gap-buffer cursor, so
    ;; the stale copy is refreshed whenever the cursor leaves a
    ;; modified line.
    ;;----------------------------------------------------------------

    (define (text-editor-load-current-line ed)
      ;; Load the line at the lines gap-buffer cursor into the line
      ;; editor, placing the line editor cursor at the column stored
      ;; in the `text-editor-column` field (clamped to the line). If
      ;; the gap-buffer cursor is at or past the end of the lines
      ;; gap-buffer, the current line is a new empty line and the line
      ;; editor is simply cleared. The stale copy in the gap buffer is
      ;; left in place; it is identical to the loaded content.
      ;;--------------------------------------------------------------
      (let*((line-ed   (text-editor-line-editor ed))
            (lines     (text-editor-lines ed))
            (line-num  (gap-buffer-cursor lines))
            (line
             (if (< line-num (gap-buffer-weight lines))
                 (gap-buffer-ref lines line-num)
                 #f))
            (size      (or (and line (text-line-inner-size line)) 0))
            (col-num   (max 0 (min (text-editor-column ed) size)))
            )
        ;; NOTE: the `text-editor-column` field is an input here and
        ;; is deliberately not written back: the clamped column must
        ;; not clobber the field during transient states (such as
        ;; freezing the line editor while the lines gap-buffer is
        ;; momentarily empty).
        ;; Clear the current line editor, and size it to fit the line.
        (gap-buffer-clear line-ed)
        (gap-buffer-allocate line-ed size)
        ;; First loop, fill the line editor before-region with the
        ;; characters before the cursor column.
        (let loop ((i 0))
          (cond
           ((< i col-num)
            (gap-buffer-insert-before line-ed (text-line-code-ref line i))
            (loop (+ 1 i))
            )
           (else (values))
           ))
        ;; Second loop, fill the line editor after-region from the end
        ;; of the line backwards. Each `GAP-BUFFER-INSERT-AFTER` lands
        ;; at the line editor cursor, so iterating backwards leaves
        ;; the characters in their original order after the cursor.
        (let loop ((i size))
          (cond
           ((< col-num i)
            (gap-buffer-insert-after
             line-ed (text-line-code-ref line (- i 1))
             )
            (loop (- i 1))
            )
           (else (values))
           ))
        (set!text-editor-line-changed ed #f)
        (set!text-editor-line-moved ed #f)
        ))

    (define (text-editor-write-back ed)
      ;; If the line editor has been modified since the current line
      ;; was loaded (`text-editor-line-changed`), freeze the entire
      ;; contents of the line editor into a <text-line-type> and store
      ;; it into the lines gap-buffer at the gap-buffer cursor,
      ;; replacing the stale copy of the current line. If the current
      ;; line is a new line past the end of the gap-buffer, the frozen
      ;; line is appended, and the cursor stays on it - the appended
      ;; line carries no line break, so no line follows it, and the end
      ;; of the buffer is the end of that line. The cursor is left at
      ;; the column the line was being edited at, which preserves its
      ;; absolute position.
      ;;--------------------------------------------------------------
      (when (text-editor-line-changed ed)
        (let*((lines     (text-editor-lines ed))
              (line-ed   (text-editor-line-editor ed))
              (cdf       (text-editor-cdf ed))
              (line-num  (gap-buffer-cursor lines))
              (weight    (gap-buffer-weight lines))
              (col-num   (gap-buffer-cursor line-ed))
              ;; The frozen line keeps the line-break protocol of the
              ;; line it replaces, so that editing a CRLF file, for
              ;; example, does not silently rewrite line breaks. A new
              ;; line past the end of the gap-buffer carries no line
              ;; break: it is only given one if a line break is typed
              ;; on it, which `TEXT-EDITOR-FORCE-LINE-BREAK` handles.
              (lbrk
               (if (< line-num weight)
                   (text-line-break (gap-buffer-ref lines line-num))
                   #f))
              )
          ;; Capture the whole line: move the line editor cursor to
          ;; the end of the line editor, then freeze everything before
          ;; it.
          (gap-buffer-cursor-to-end line-ed)
          (let ((line (line-editor-freeze-line-before line-ed lbrk)))
            (cdf-invalidate! cdf line-num)
            (cond
             ((< line-num weight)
              ;; Replace the stale copy of the current line.
              (gap-buffer-delete lines 1)
              (gap-buffer-insert-after lines line)
              (gap-buffer-set-cursor lines line-num)
              )
             (else
              ;; The current line is a new line past the end of the
              ;; lines gap-buffer: append it as a committed line and
              ;; stay on it.
              ;;
              ;; It carries no line break - a break typed on such a
              ;; line is dealt with by `TEXT-EDITOR-FORCE-LINE-BREAK',
              ;; which commits both halves - so no line follows it: the
              ;; buffer's last line is the last line it has, and the end
              ;; of the buffer is the end of that line, which is where
              ;; GNU Emacs puts `point-max'. Advancing to an empty line
              ;; after it would be advancing onto a line the buffer does
              ;; not have, and the engine would then answer two ways
              ;; about where the cursor is: `TEXT-EDITOR-INDEX-LINE-OFFSET'
              ;; reports such a position as the end of the last line,
              ;; while the line editor would be holding an empty line.
              ;; The delete procedures read the line editor, which is
              ;; how a backwards deletion at the end of a buffer came to
              ;; delete one character fewer than it reported.
              ;;
              ;; Staying on the line also preserves the cursor exactly:
              ;; `TEXT-EDITOR-LOAD-CURRENT-LINE' below reloads this line
              ;; with the line editor cursor at the column it was being
              ;; edited at, whereas the empty line after it would put
              ;; the cursor at the end of the buffer whatever column it
              ;; had been at.
              (gap-buffer-insert-after lines line)
              (gap-buffer-set-cursor lines line-num)
              ))
            (gap-buffer-clear line-ed)
            (set!text-editor-column ed col-num)
            (text-editor-load-current-line ed)
            ))))

    (define (line-editor-char-range ref foreach line-ed)
      (let*((lo (ref line-ed #f))
            (hi lo)
            )
        (foreach
         (lambda (n)
           (cond
            ((< n lo) (set! lo n))
            ((< hi n) (set! hi n))
            (else (values))
            ))
         line-ed
         )
        (values lo hi)
        ))

    (define (line-editor-freeze-part calc-frozen-size ref foreach foreach/index index-base)
      ;; Creates a procedure which freezes part of a line editor gap
      ;; buffer into a <text-line-type>. `CALC-FROZEN-SIZE` computes
      ;; the number of characters to freeze from the gap-buffer weight
      ;; and cursor; `REF`, `FOREACH` and `FOREACH/INDEX` read the
      ;; part of the line editor to freeze (before or after the
      ;; cursor); `INDEX-BASE` gives the logical index at which the
      ;; frozen part starts (0 for the before-cursor part, the cursor
      ;; for the after-cursor part), so that the frozen sequence is
      ;; indexed from zero.
      (lambda (line-ed lbrk)
        (let*((weight (gap-buffer-weight line-ed))
              (cursor (gap-buffer-cursor line-ed))
              (frozen-size (calc-frozen-size weight cursor))
              )
          (cond
           ((< 0 weight)
            (let-values (((lo hi) (line-editor-char-range ref foreach line-ed)))
              (let*((iface    (%line-editor-pre-freeze lo hi))
                    (vec      ((iface-make-sequence iface) frozen-size))
                    (seq-set! (iface-sequence-set! iface))
                    (base     (index-base cursor))
                    )
                (foreach/index
                 (lambda (i n) (seq-set! vec (- i base) (- n lo)))
                 line-ed
                 )
                (make<text-line> vec #f #f lo hi lbrk iface)
                )))
           (else (make<text-line> #f #f #f #f #f lbrk #f))
           ))))

    (define line-editor-freeze-line-before
      (line-editor-freeze-part
       (lambda (_weight cursor) cursor)
       gap-buffer-ref-before
       gap-buffer-for-each-before
       gap-buffer-for-each-before/index
       (lambda (_cursor) 0)
       ))

    (define (line-editor-freeze-line-after line-ed lbrk)
      (cond
       ((gap-buffer-end-of-line? line-ed)
        (make<text-line> #f #f #f #f #f lbrk #f)
        )
      (else
       (let ((freeze
              (line-editor-freeze-part
               (lambda (weight cursor) (- weight cursor))
               gap-buffer-ref-after
               gap-buffer-for-each-after
               gap-buffer-for-each-after/index
               (lambda (cursor) cursor)
               )))
       (freeze line-ed lbrk)
       ))))

    ;;----------------------------------------------------------------
    ;; Inserting text

    (define (text-editor-force-line-break ed)
      ;; Forces a line break regardless of whether an actual line
      ;; breaking character has been inserted. The characters in the
      ;; line editor before the cursor are frozen into a
      ;; <text-line-type> which replaces the stale copy of the current
      ;; line in the lines gap-buffer, and the characters after the
      ;; cursor remain in the line editor as the new current line (the
      ;; line after the break), with the line editor cursor at column
      ;; zero. A snapshot of the characters after the cursor is stored
      ;; in the gap-buffer as the (identical) copy of the new current
      ;; line, so that the invariant "the gap-buffer contains one
      ;; element for every line of the buffer" is preserved, and the
      ;; gap-buffer cursor is advanced to point at the new current
      ;; line.
      ;;--------------------------------------------------------------
      (let*((line-ed (text-editor-line-editor ed))
            (lines   (text-editor-lines ed))
            (cdf     (text-editor-cdf ed))
            (cur     (gap-buffer-cursor lines))
            (weight  (gap-buffer-weight lines))
            (lbrk    (text-editor-line-break ed))
            ;; The line after the break inherits the line-break
            ;; protocol of the line it was split from; but if the
            ;; after-break part is empty and no lines follow the
            ;; current line (the cursor is at the end of the lines
            ;; gap-buffer), the new line has no line break at all.
            (after-lbrk
             (if (< cur weight)
                 (text-line-break (gap-buffer-ref lines cur))
                 #f))
            ;; snapshot of the line after the break, before clearing
            (after
             (line-editor-freeze-line-after line-ed after-lbrk))
            ;; the line before the break, terminated by the line
            ;; break that was just typed
            (line
             (line-editor-freeze-line-before line-ed lbrk))
            (sum (cdf-invalidate! cdf cur))
            )
        ;; Replace the stale copy of the current line with the
        ;; before-break part. If the current line is a new line past
        ;; the end of the gap-buffer there is no stale copy to remove.
        (when (< cur (gap-buffer-weight lines))
          (gap-buffer-delete lines 1)
          )
        ;; Insert the after-break snapshot first, then the
        ;; before-break line: each `GAP-BUFFER-INSERT-AFTER` lands at
        ;; the gap-buffer cursor, so this order leaves the snapshot at
        ;; the cursor position (+ 1 cur).
        (gap-buffer-insert-after lines after)
        (gap-buffer-insert-after lines line)
        ;; advance the cursor to the new current line (the
        ;; after-break part), and record the new committed line's
        ;; running total in the CDF, if the CDF is up-to-date.
        (gap-buffer-set-cursor lines (+ 1 cur))
        (when sum (cdf-push cdf (text-line-outer-size line)))
        ;; The line editor keeps only the characters after the break,
        ;; with the cursor at column zero.
        (gap-buffer-clear-before line-ed)
        (set!text-editor-line-changed ed #f)
        after
        ))

    (define (text-editor-copy-string ed start end)
      ;; Copy the buffer contents between the character indices START
      ;; (inclusive) and END (exclusive) into a string. Arguments may
      ;; be given in either order; the empty range returns "".
      ;;--------------------------------------------------------------
      (let ((start (min start end))
            (end (max start end)))
        (call-with-port (open-output-string)
          (lambda (port)
            (let loop ((i start))
              (when (< i end)
                (let ((c (text-editor-get-char-index ed i)))
                  (when c (write-char c port)))
                (loop (+ 1 i))))
            (get-output-string port)))))

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
    ;; weakly instead (`(schemacs weak)'), which comes to the same
    ;; thing: a marker that nothing else refers to is collected, and it
    ;; stops being adjusted.

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
        (weak-set-add! (text-editor-markers ed) marker)
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
          (weak-set-add! (text-editor-markers ed) marker))
         (else
          (when ed
            (weak-set-delete! (text-editor-markers ed) marker))
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
      (weak-set-for-each proc (text-editor-markers ed)))

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

    (define (text-editor-modified? ed)
      ;; Whether the buffer has been changed since it was last saved or
      ;; visited. GNU Emacs's `buffer-modified-p'.
      ;;--------------------------------------------------------------
      (text-editor-modified-flag ed))

    (define (text-editor-set-modified! ed flag)
      ;; Set whether ED is modified, GNU Emacs's
      ;; `set-buffer-modified-p'. Marking a buffer modified records
      ;; where it was last in sync with its file, so that undoing back
      ;; past every change made since then can mark it unmodified
      ;; again; marking it unmodified (saving it) starts a new such
      ;; point, which is why an older mark no longer counts - the
      ;; buffer saved in the meantime is not the buffer that mark
      ;; describes.
      ;;--------------------------------------------------------------
      (cond
       (flag
        (unless (text-editor-modified? ed)
          (%undo-record! ed (cons 't (text-editor-save-token ed)))
          (set!text-editor-modified-flag ed #t)))
       (else
        (when (text-editor-modified? ed)
          (set!text-editor-modified-flag ed #f)
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
      (text-editor-set-modified! ed #t)
      (set!text-editor-deactivate-mark! ed #t))

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
      ;; Search forward from the character index START for STRING.
      ;; Returns the index just past the match, which is where GNU
      ;; Emacs's `search-forward' leaves point, or #f when STRING does
      ;; not occur there. An empty STRING finds nothing, as it does for
      ;; mg's `is_find', rather than matching everywhere as Emacs's
      ;; `search-forward' does - an empty search string means "no search
      ;; yet" to the incremental search that wants this.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let ((found (string-search-forward
                         (text-editor-copy-string
                          ed start (text-editor-char-count ed))
                         string 0 case-fold?)))
             (and found (+ start found (string-length string))))))

    (define (text-editor-search-backward ed string start case-fold?)
      ;; Search backward from the character index START for STRING.
      ;; Returns the index of the start of the match, which is where GNU
      ;; Emacs's `search-backward' leaves point, or #f when STRING does
      ;; not occur before START. An empty STRING finds nothing.
      ;;--------------------------------------------------------------
      (and (< 0 (string-length string))
           (let* ((text (text-editor-copy-string ed 0 start))
                  (found (%string-search-backward
                          text string (- (string-length text)
                                         (string-length string))
                          case-fold?)))
             found)))

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

    (define (text-editor-insert ed thing)
      ;; Insert THING at the cursor. The insertion is recorded in the
      ;; buffer's undo list as the range of characters it now occupies,
      ;; and marks the buffer modified. Nothing is inserted into a
      ;; read-only buffer; that is an error, as it is in GNU Emacs.
      ;;--------------------------------------------------------------
      (when (text-editor-read-only? ed)
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
            ;; characters, strings, whole lines, a line break typed or
            ;; forced by the line-break state machine, and an insertion
            ;; replayed by undo, which comes back through here.
            (adjust-markers-for-insertion! ed beg (- end beg))
            ;; The intervals move with the text for the same reason the
            ;; markers do, and from the same place: once for the whole
            ;; insertion, so that every way text gets in is covered.
            (let ((offset (*text-property-offset-function*)))
              (when offset (offset ed beg (- end beg))))
            (%text-editor-note-change! ed)
            (%undo-record-insertion! ed beg end)))))

    (define (%text-editor-insert ed thing)
      (cond
       ((text-line-type? thing)
        (text-line-for-each
         (lambda (c) ((%text-editor-insert-char ed) c))
         thing
         ))
       ((string? thing)
        ;; NOTE: the insert-char procedure must be re-read for every
        ;; character, because the line-break state machine sets
        ;; `text-editor-insert-char` when it transitions states.
        ;;--------------------------------------------------------------
        (string-for-each
         (lambda (c) ((%text-editor-insert-char ed) c))
         thing
         ))
       ((char? thing)
        ((%text-editor-insert-char ed) thing)
        )
       ((and (input-port? thing) (input-port-open? thing))
        (text-editor-insert-line-from-port ed thing)
        )
       (else (error "editor cannot insert text from" thing))
       ))

    (define (text-editor-force-insert-char ed ch)
      (let ((line-ed (text-editor-line-editor ed))
            (chi (char->integer ch))
            )
        (gap-buffer-insert-before line-ed chi)
        (gap-buffer-insert-min-max line-ed chi)
        (text-editor-add-char-count ed 1)
        (set!text-editor-line-changed ed #t)
        ch
        ))

    (define (%text-editor-move-char ed ch)
      ;; Put CH in the line editor *without* counting it: the
      ;; counterpart of `text-editor-force-insert-char' for the
      ;; procedures that rearrange how the buffer is stored rather than
      ;; change what it contains. The merge helpers below move a line's
      ;; characters from one line structure into another, and those
      ;; characters are already in the char count; counting them again
      ;; inflates it by the length of every merged line.
      ;;--------------------------------------------------------------
      (let ((line-ed (text-editor-line-editor ed))
            (chi (char->integer ch))
            )
        (gap-buffer-insert-before line-ed chi)
        (gap-buffer-insert-min-max line-ed chi)
        (set!text-editor-line-changed ed #t)
        ch
        ))

    ;; Deleting text

    (define (%text-editor-line-inner-size ed line-num)
      ;; The number of characters in the line at line index LINE-NUM,
      ;; not counting its line break. Returns false when LINE-NUM is
      ;; past the end of the lines gap-buffer.
      (let ((lines (text-editor-lines ed)))
        (if (< line-num (gap-buffer-weight lines))
            (or (text-line-inner-size (gap-buffer-ref lines line-num)) 0)
            #f)))

    (define (%text-editor-freeze-editor-with ed lbrk)
      ;; Freeze the whole line editor into a <text-line-type> carrying
      ;; the line break LBRK, then restore the line editor contents
      ;; and cursor position. The frozen line is returned but not
      ;; stored anywhere.
      ;;--------------------------------------------------------------
      (let* ((lines   (text-editor-lines ed))
             (line-ed (text-editor-line-editor ed))
             (col-num (gap-buffer-cursor line-ed)))
        (gap-buffer-cursor-to-end line-ed)
        (let ((line (line-editor-freeze-line-before line-ed lbrk)))
          (gap-buffer-clear line-ed)
          (set!text-editor-column ed col-num)
          (text-editor-load-current-line ed)
          line
          )))

    (define (%text-editor-merge-next-line! ed)
      ;; Merge the line after the current line into the current line,
      ;; deleting the line break between them - one character on a `\n'
      ;; buffer and two on a CR-LF one. The merged line inherits the
      ;; line break of the (former) next line. The line editor keeps the
      ;; merged line contents with the cursor at the former end of the
      ;; current line. Returns the size of the line break that was
      ;; deleted, in characters.
      ;;--------------------------------------------------------------
      (let* ((lines (text-editor-lines ed))
             (line-ed (text-editor-line-editor ed))
             (cdf (text-editor-cdf ed))
             (k (gap-buffer-cursor lines))
             (col-num (gap-buffer-cursor line-ed))
             (next (gap-buffer-ref lines (+ 1 k)))
             (next-lbrk (text-line-break next))
             ;; the line break that goes away is the *current* line's -
             ;; the merged line keeps NEXT's. The characters copied out
             ;; of the next line are a rearrangement of what is already
             ;; in the buffer and are not counted; this break is the
             ;; only thing that has really gone.
             (gone-lbrk (text-line-break (gap-buffer-ref lines k))))
        ;; append the next line's characters to the line editor
        (gap-buffer-cursor-to-end line-ed)
        (text-line-for-each
         (lambda (ch) (%text-editor-move-char ed ch))
         next
         )
        ;; restore the line editor cursor to the former end of the
        ;; current line (where the deleted line break was)
        (gap-buffer-set-cursor line-ed col-num)
        ;; delete the stale copies of both lines and store the merged
        ;; contents as the new stale copy of the merged line
        (gap-buffer-delete lines 2)
        (let ((merged (%text-editor-freeze-editor-with ed next-lbrk)))
          (gap-buffer-insert-after lines merged)
          (gap-buffer-set-cursor lines k)
          (cdf-invalidate! cdf k)
          )
        (text-editor-add-char-count
         ed (- (if gone-lbrk (line-break-size gone-lbrk) 0)))
        (text-editor-load-current-line ed)
        (if gone-lbrk (line-break-size gone-lbrk) 0)))

    (define (%text-editor-merge-previous-line! ed)
      ;; Merge the current line into the line before it, deleting the
      ;; line break between them (one character). The merged line
      ;; keeps the current line's line-break protocol (the break that
      ;; terminated the merged-away tail line), and the cursor ends up
      ;; at the former end of the previous line (where the break was).
      ;;--------------------------------------------------------------
      (let* ((lines (text-editor-lines ed))
             (line-ed (text-editor-line-editor ed))
             (cdf (text-editor-cdf ed))
             (k (gap-buffer-cursor lines))
             (weight (gap-buffer-weight lines))
             (prev-size (%text-editor-line-inner-size ed (- k 1)))
             ;; the merged line's line-break protocol is the tail
             ;; line's line break; at the end of the buffer the
             ;; current line is a new line with no line break and no
             ;; stale copy, so the merged line ends up with none
             (tail-lbrk
              (if (< k weight)
                  (text-line-break (gap-buffer-ref lines k))
                  #f))
             ;; the number of stale copies to delete: two (the
             ;; previous line's and the current line's) except at the
             ;; end of the buffer, where only the previous line's
             ;; stale copy exists
             (stale-count (if (< k weight) 2 1))
             ;; the line break that goes away is the *previous* line's.
             ;; The current line's characters are moved into the line
             ;; editor rather than inserted, so they are not counted;
             ;; this break is the only thing that has really gone.
             (gone-lbrk (and (< 0 k)
                             (text-line-break (gap-buffer-ref lines (- k 1))))))
        ;; capture the current line's characters, move the gap-buffer
        ;; cursor to the previous line, and load it into the line
        ;; editor with the cursor at its end.
        (let ((current-string
               (call-with-port (open-output-string)
                 (lambda (port)
                   (gap-buffer-for-each
                    (lambda (n) (write-char (integer->char n) port))
                    line-ed)
                   (get-output-string port)))))
          (text-editor-set-cursor ed (- k 1) prev-size)
          (string-for-each
           (lambda (c) (%text-editor-move-char ed c))
           current-string
           )
          ;; delete the stale copies and store the merged contents as
          ;; the new stale copy of the merged line
          (gap-buffer-delete lines stale-count)
          (let ((merged (%text-editor-freeze-editor-with ed tail-lbrk)))
            (gap-buffer-insert-after lines merged)
            (gap-buffer-set-cursor lines (- k 1))
            (cdf-invalidate! cdf (- k 1))
            )
          (text-editor-add-char-count
           ed (- (if gone-lbrk (line-break-size gone-lbrk) 0)))
          (text-editor-load-current-line ed)
          (if gone-lbrk (line-break-size gone-lbrk) 0))))

    (define (text-editor-delete-from-cursor ed n)
      ;; Delete N characters at the text editor cursor. Positive N
      ;; deletes characters after the cursor (forward), negative N
      ;; deletes characters before the cursor. Deletion is clamped to
      ;; the bounds of the buffer. Deleting across a line boundary
      ;; merges the two lines. Returns the number of characters
      ;; deleted.
      ;;
      ;; The deleted text is captured first, and recorded in the
      ;; buffer's undo list. The deletion is clamped, so what is
      ;; recorded is whatever was really there to delete: a request to
      ;; delete 100 characters at the end of a 3-character buffer
      ;; records 3, and reinserts 3.
      ;;
      ;; Nothing is deleted from a read-only buffer; that is an error,
      ;; as it is in GNU Emacs.
      ;;--------------------------------------------------------------
      (when (and (not (= n 0)) (text-editor-read-only? ed))
        (error "Buffer is read-only"))
      (cond
       ((= n 0) 0)
       (else
        (let* ((cursor (text-editor-get-cursor ed))
               (text (text-editor-copy-string ed cursor (+ cursor n)))
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
                (when offset (offset ed beg (- deleted)))))
            (%text-editor-note-change! ed)
            ;; A forward delete removes the text after point, so point
            ;; was at its beginning and POS is positive; a backward
            ;; delete removes the text before point, so point was at its
            ;; end and POS is negative. In both cases `(abs POS)` is
            ;; where the text has to go back, and the sign is what tells
            ;; the undo which side of it to leave point on.
            (%undo-record-deletion!
             ed
             (if (< deleted (string-length text))
                 (if (< n 0)
                     (substring text (- (string-length text) deleted)
                                (string-length text))
                     (substring text 0 deleted))
                 text)
             (if (< n 0) (- deleted cursor) cursor)))
          deleted))))

    (define (%text-editor-delete-forward ed n)
      (let* ((lines (text-editor-lines ed))
             (line-ed (text-editor-line-editor ed))
             (col (gap-buffer-cursor line-ed))
             (avail (- (gap-buffer-weight line-ed) col))
             )
        (cond
         ((<= n avail)
          ;; delete within the current line
          (gap-buffer-delete line-ed n)
          (text-editor-add-char-count ed (- n))
          (set!text-editor-line-changed ed #t)
          n)
         ((< 0 avail)
          ;; delete to the end of the current line, then continue
          (gap-buffer-delete line-ed avail)
          (text-editor-add-char-count ed (- avail))
          (set!text-editor-line-changed ed #t)
          (+ avail (%text-editor-delete-forward ed (- n avail))))
         ((< (+ 1 (gap-buffer-cursor lines)) (gap-buffer-weight lines))
          ;; the cursor is at the end of the line: delete the line
          ;; break by merging with the next line, then continue. The
          ;; break is one character on a `\n' buffer and two on a
          ;; CR-LF one, so how much of N is left is what the merge
          ;; says it took, not a fixed one.
          (let ((gone (%text-editor-merge-next-line! ed)))
            (+ gone (%text-editor-delete-forward ed (- n gone)))))
         ;; the cursor is at the end of the last line: delete the
         ;; current line's own terminating line break, if it has one
         ;; (as GNU Emacs does)
         (else
          (let* ((stale
                  (and (< (gap-buffer-cursor lines)
                          (gap-buffer-weight lines))
                       (gap-buffer-ref lines (gap-buffer-cursor lines))))
                 (lbrk (and stale (text-line-break stale))))
            (if lbrk
                (let ((size (line-break-size lbrk)))
                  (set!text-line-break stale #f)
                  (text-editor-add-char-count ed (- size))
                  (set!text-editor-line-changed ed #t)
                  size)
                0))
          ))))

    (define (%text-editor-delete-backward ed n)
      (let* ((lines (text-editor-lines ed))
             (line-ed (text-editor-line-editor ed))
             (col (gap-buffer-cursor line-ed))
             )
        (cond
         ((<= n col)
          (gap-buffer-delete line-ed (- n))
          (text-editor-add-char-count ed (- n))
          (set!text-editor-column ed (- col n))
          (set!text-editor-line-changed ed #t)
          n)
         ((< 0 (gap-buffer-cursor lines))
          ;; at the start of a line which has a line before it: the
          ;; deleted character is the line break; merge the lines. The
          ;; break is one character on a `\n' buffer and two on a
          ;; CR-LF one, so how much of N is left is what the merge
          ;; says it took, not a fixed one.
          (let ((gone (%text-editor-merge-previous-line! ed)))
            (+ gone (%text-editor-delete-backward ed (- n gone)))))
         (else 0)
         )))

    (define (text-editor-insert-from-port-until until ed port)
      (let loop ((next (read-char port)))
        (cond
         ((eof-object? next) next)
         (else
          (let ((result ((%text-editor-insert-char ed) next)))
            (if (until result) result (loop (read-char port)))
            )))))

    (define (text-editor-insert-from-port ed port)
      (text-editor-insert-from-port-until (lambda _ #f) ed port)
      )

    (define (text-editor-insert-line-from-port ed port)
      (text-editor-insert-from-port-until text-line-type? ed port)
      )

    (define (text-editor-dump-before ed port)
      (let*((line-gb (text-editor-lines ed))
            (line (gap-buffer-cursor line-gb))
            (changed (text-editor-line-changed ed))
            )
        (cond
         (changed
          ;; The line editor holds the live contents of the current
          ;; line, whose stale copy sits at the gap-buffer cursor. All
          ;; committed lines before the cursor are written, then the
          ;; line editor's characters before its cursor; the
          ;; `text-editor-dump-after` companion writes the rest.
          (let ((end line))
            (gap-buffer-for-each-before/index
             (lambda (i text-line)
               (when (< i end) (write-text-line text-line port))
               )
             line-gb
             )
            (gap-buffer-for-each-before
             (lambda (ch) (write-char (integer->char ch) port))
             (text-editor-line-editor ed)
             )))
         (else
          (gap-buffer-for-each-before
           (lambda (text-line)
             (write-text-line text-line port)
             )
           line-gb
           )))))

    (define (text-editor-dump-after ed port)
      (let*((line-gb (text-editor-lines ed))
            (line    (gap-buffer-cursor line-gb))
            (changed (text-editor-line-changed ed))
            )
        (when changed
          (gap-buffer-for-each-after
           (lambda (ch) (write-char (integer->char ch) port))
           (text-editor-line-editor ed)
           )
          ;; The current line's terminating line break is stored in
          ;; its stale copy in the gap-buffer (the line editor holds
          ;; only the line contents, not its break), so it must be
          ;; written here explicitly.
          (when (< line (gap-buffer-weight line-gb))
            (let ((lbrk (text-line-break (gap-buffer-ref line-gb line))))
              (when lbrk ((line-break-write-to-port lbrk) port))
              )))
        ;; Write the committed lines after the gap-buffer cursor. When
        ;; the line editor has been modified, the gap-buffer element
        ;; at the cursor holds the stale copy of the current line,
        ;; which the line editor contents replace, so it is skipped.
        (gap-buffer-for-each-after/index
         (lambda (i text-line)
           (unless (and changed (= i line))
             (write-text-line text-line port)
             ))
         line-gb
         )))

    (define (text-editor-dump ed port)
      (text-editor-dump-before ed port)
      (text-editor-dump-after ed port)
      )

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
      ;; Dump the text editor buffer into a string.
      (call-with-port (open-output-string)
        (lambda (port)
          (text-dump-port ed port)
          (get-output-string port)
          )))

    (define (text-editor-cursor-line ed)
      (let ((lines (text-editor-lines ed)))
        (or (and lines (gap-buffer-cursor lines)) 0)
        ))

    (define (text-editor-cursor-column ed)
      (let ((line-ed (text-editor-line-editor ed)))
        (or (and line-ed (gap-buffer-cursor line-ed)) 0)
        ))

    (define (text-editor-cursor-line-number ed)
      (gap-buffer-cursor (text-editor-lines ed))
      )

    (define (text-editor-cursor-column-number ed)
      (gap-buffer-cursor (text-editor-line-editor ed))
      )

    (define (text-editor-cursor-location ed)
      (make<text-location>
       (text-editor-cursor-line-number ed)
       (text-editor-cursor-column-number ed)
       ))

    (define (text-editor-make-cdf-fill-range lines to)
      ;; Creates a closure that acts as a generator of lines in the
      ;; `LINES` gap buffer between the indices of the current cursor
      ;; position of the CDF up until the index given by the argument
      ;; `TO` (not including `TO`) using `gap-buffer-ref`, and
      ;; `text-line-size` to produce the output values.
      ;;--------------------------------------------------------------
      (lambda (cursor accum)
        (cond
         ((< cursor to)
          (text-line-outer-size (gap-buffer-ref lines cursor))
          )
         (else #f)
         )))

    (define (text-editor-make-cdf-fill-until lines accum-max-value)
      ;; Creates a closure that acts as a generator of lines in the
      ;; `LINES` gap buffer and continues until the end of the buffer
      ;; is reached or until the accumulator exceeds `ACCUM-MAX-VALUE`.
      ;;
      ;; The accumulator is the CDF value of the line *before* the one
      ;; being generated, so generation must continue while it is less
      ;; than or EQUAL to the target: the line whose bucket starts at
      ;; the accumulator is the line the target index falls on. Testing
      ;; `<` instead left that line's bucket unfilled, so `CDF-FIND`
      ;; saw the target as out of bounds and every character index that
      ;; begins a line - index 0 above all - was unresolvable.
      ;;--------------------------------------------------------------
      (let ((weight (gap-buffer-weight lines)))
        (lambda (cursor accum)
          (cond
           ((and (<= accum accum-max-value) (< cursor weight))
            (text-line-outer-size (gap-buffer-ref lines cursor))
            )
           (else #f)
           ))))

    (define (text-editor-text-line-ref ed offset)
      ;; Get a whole line of text given the line number.
      ;;--------------------------------------------------------------
      (gap-buffer-ref (text-editor-lines ed) offset)
      )

    (define (text-editor-line-outer-size ed line-index)
      ;; How many characters line LINE-INDEX advances the buffer's
      ;; character index by: its contents plus its line break, which is
      ;; the unit the CDF counts lines in. Zero for a line the buffer
      ;; does not hold - the empty line past the end of the buffer, which
      ;; is the only line a brand new buffer has.
      ;;
      ;; This exists because `TEXT-EDITOR-LINE-COUNT' counts that last
      ;; empty line, while the lines gap-buffer does not hold it yet, so
      ;; `TEXT-EDITOR-TEXT-LINE-REF' cannot be asked for it.
      ;;--------------------------------------------------------------
      (let ((lines (text-editor-lines ed)))
        (if (< line-index (gap-buffer-weight lines))
            (text-line-outer-size (gap-buffer-ref lines line-index))
            0)))

    (define (text-editor-line-editor-ref ed offset)
      ;; Used to get the character on the current line. The line
      ;; editor always holds the contents of the current line, so the
      ;; character is read directly from the line editor. Returns
      ;; false when the offset is past the end of the line.
      ;;--------------------------------------------------------------
      (let ((line-ed (text-editor-line-editor ed)))
        (and (< offset (gap-buffer-weight line-ed))
             (integer->char (gap-buffer-ref line-ed offset))
             )))

    (define (text-editor-get-cursor ed)
      ;; Check if the CDF needs updating, and if so, recompute all
      ;; elements up to the current cursor position. Returns the
      ;; character position of the text editor's cursor when complete.
      ;;--------------------------------------------------------------
      (let*((lines    (text-editor-lines ed))
            (line-num (gap-buffer-cursor lines))
            (line-ed  (text-editor-line-editor ed))
            (cdf      (text-editor-cdf ed))
            (cdf-cur  (cdf-cursor cdf))
            (offset
             (cond
              ((< cdf-cur line-num)
               (cdf-fill
                cdf (text-editor-make-cdf-fill-range lines line-num)
                ))
              ((< 0 line-num)
               (cdf-ref cdf (- line-num 1))
               )
              (else 0)
              )))
        (+ offset (or (and line-ed (gap-buffer-cursor line-ed)) 0))
        ))

    (define (text-editor-move-cursor ed move-by)
      ;; Move the text editor cursor to the position
      ;; `(+ (TEXT-EDITOR-GET-CURSOR ED) MOVE-BY)`, clamped to the
      ;; bounds of the buffer. When the target position is on a
      ;; different line than the current cursor position, the current
      ;; line is written back into the lines gap-buffer, the
      ;; gap-buffer cursor is moved to the target line, and the
      ;; target line is loaded into the line editor. The remembered
      ;; column (`text-editor-column`) is updated to the target
      ;; column.
      ;;--------------------------------------------------------------
      (let*((ch-index0 (text-editor-get-cursor ed))
            (count (text-editor-char-count ed))
            (target (max 0 (min count (+ ch-index0 move-by))))
            (delta (- target ch-index0))
            )
        (cond
         ((= 0 delta) (values))
         (else
          (text-editor-write-back ed)
          (let*-values
              (((t-line t-col) (text-editor-index-line-offset ed target))
               ((lines) (text-editor-lines ed))
               ((line-ed) (text-editor-line-editor ed))
               ((line-num) (gap-buffer-cursor lines)))
            (cond
             ;; Same line: the line editor is already loaded, just
             ;; move its cursor to the target column.
             ((= t-line line-num)
              (gap-buffer-set-cursor line-ed t-col)
              (set!text-editor-column ed t-col)
              )
             (else
              (gap-buffer-set-cursor lines t-line)
              (set!text-editor-column ed t-col)
              (text-editor-load-current-line ed)
              )))))))

    (define text-editor-set-cursor
      (case-lambda
       ((ed index)
        (cond
         ((text-location-type? index)
          (text-editor-set-cursor
           ed (text-location-line index)
                 (text-location-column index)
              ))
         ((integer? index)
          (let ((cursor (text-editor-get-cursor ed)))
            (text-editor-move-cursor ed (- index cursor))
            ))
         (else
          (error
           "text editor index must be set with integer or text-location-type"
           index
           ))))
       ((ed line-num column-num)
        ;; Move the cursor to the given zero-based line index and
        ;; column. Writing back any modified line first preserves the
        ;; buffer contents; the target line is then loaded into the
        ;; line editor with the cursor at the given column (clamped
        ;; to the line by `TEXT-EDITOR-LOAD-CURRENT-LINE').
        ;;
        ;; The new empty line past the end of the buffer is only
        ;; addressable when the buffer's last line ends in a line
        ;; break - that break is what starts it. Without one the last
        ;; line the buffer holds is the last line there is, and the
        ;; end of the buffer is the end of that line, which is where
        ;; GNU Emacs puts `point-max': moving past it, as `next-line'
        ;; does at the last line, stays on the last line rather than
        ;; onto a line that does not exist.
        (let* ((lines (text-editor-lines ed)))
          (text-editor-write-back ed)
          (let* ((weight (gap-buffer-weight lines))
                 (last (if (and (< 0 weight)
                                (text-line-break (gap-buffer-ref lines (- weight 1))))
                           weight
                           (- weight 1))))
            (gap-buffer-set-cursor lines (max 0 (min line-num last))))
          (set!text-editor-column ed column-num)
          (text-editor-load-current-line ed)
          ))))

    (define (text-editor-index-line-offset ed ch-index)
      ;; This function is used to update the CDF and to return the
      ;; line number, and the character offset (column) of the
      ;; character index `CH-INDEX` within its line. Returns two
      ;; values: (1) the zero-based line index to which the
      ;; `CH-INDEX` is pointing, and (2) the zero-based column of the
      ;; character within that line.
      ;;
      ;; First, write back any modified line editor contents, so the
      ;; gap-buffer and CDF reflect the true buffer contents, then
      ;; fill the CDF until it covers `CH-INDEX`, and binary-search it
      ;; with `CDF-FIND`, which returns the line index and the start
      ;; offset of that line. `CDF-FIND` returns false values when
      ;; `CH-INDEX` is at or past the end of the last committed line,
      ;; which is one of two positions:
      ;;
      ;;  - the current line, when it is a new, empty line past every
      ;;    committed one (the lines gap-buffer cursor is at its
      ;;    weight). That is a line of its own - the empty line a
      ;;    brand new buffer has, and the one a line break at the end
      ;;    of the buffer starts - so the index is on it, at the
      ;;    column the CDF does not reach;
      ;;
      ;;  - the end of the last committed line, when that line has no
      ;;    line break after it. That is NOT a line of its own: the
      ;;    buffer's line count has no such line, and GNU Emacs puts
      ;;    `point-max' at the end of the last line here. Reporting a
      ;;    phantom line instead is what left point at the end of a
      ;;    buffer that does not end in a newline on an empty line
      ;;    past it, so that `C-e' then `C-a' could not reach the
      ;;    beginning of the line at all (`beginning-of-line' moved
      ;;    point to the start of the empty line - the same place),
      ;;    and the mode line read `L2 C1' for a file of one line.
      ;;--------------------------------------------------------------
      (let*((lines (text-editor-lines ed))
            (cdf (text-editor-cdf ed))
            (_write-back (text-editor-write-back ed))
            (_fill (cdf-fill cdf (text-editor-make-cdf-fill-until lines ch-index)))
            )
        (call-with-values
            (lambda () (cdf-find cdf ch-index))
          (lambda (i lo)
            (cond
             (i (values i (- ch-index lo)))
             (else
              (let ((weight (gap-buffer-weight lines))
                    (line-num (gap-buffer-cursor lines)))
                (if (= line-num weight)
                    (values weight
                            (max 0 (- ch-index (cdf-maximum cdf))))
                    (let ((outer (text-line-outer-size
                                  (gap-buffer-ref lines (- weight 1)))))
                      (values (- weight 1)
                              (max 0 (- ch-index
                                        (- (cdf-maximum cdf) outer))))))
                )))))))

    (define (text-editor-get-char-index ed ch-index)
      ;; Get the character at the given index `CH-INDEX`. This
      ;; recomputes part of the CDF for the editor buffer.
      ;;--------------------------------------------------------------
      (let*-values
          (((cdf-cur offset) (text-editor-index-line-offset ed ch-index))
           ((lines) (text-editor-lines ed))
           )
        (cond
         ((< cdf-cur (gap-buffer-weight lines))
          (text-line-ref (gap-buffer-ref lines cdf-cur) offset)
          )
         (else #f)
         )))

    (define (%text-editor-get-line-column ed ch-index)
      (cond
       ;; If `index` is not `#f` compute the line and column number of
       ;; that character index.
       (ch-index
        (let*-values
            (((line-index offset)
              (text-editor-index-line-offset ed ch-index)
              ))
          (make<text-location> (+ 1 line-index) (+ 1 offset))
          ))
       ;; Otherwise get the current cursor position.
       (else
        (make<text-location>
         (+ 1 (text-editor-cursor-line ed))
         (+ 1 (text-editor-cursor-column ed))
         ))))

    (define text-editor-get-line-column
      (case-lambda
       ((ed) (%text-editor-get-line-column ed #f))
       ((ed ch-index) (%text-editor-get-line-column ed ch-index))
       ))

    (define (text-editor-get-end-of-line ed)
      ;; Get the character index of the end of the current line. The
      ;; line editor always holds the current line's contents, so this
      ;; is the start of the current line plus the number of
      ;; characters in the line editor.
      ;;--------------------------------------------------------------
      (text-editor-get-cursor ed)
      (let*((lines (text-editor-lines ed))
            (line-num (gap-buffer-cursor lines))
            (cdf (text-editor-cdf ed))
            )
        (+ (cond
            ((< 0 line-num) (cdf-ref cdf (- line-num 1)))
            (else 0)
            )
           (gap-buffer-weight (text-editor-line-editor ed))
           )))

    (define (text-editor-line-count ed)
      ;; The total number of lines in the buffer. The lines gap-buffer
      ;; contains one element for every line of the buffer, except
      ;; that when the gap-buffer cursor points past the last
      ;; committed line, the current line is a new empty line which is
      ;; not yet buffered, so one more line is counted. That is a line
      ;; the buffer really has, because it is a line break at the end of
      ;; the buffer that starts it: a last line with no break after it
      ;; is the last line there is (see `TEXT-EDITOR-WRITE-BACK').
      ;;--------------------------------------------------------------
      (let* ((lines (text-editor-lines ed))
             (line-num (gap-buffer-cursor lines))
             (weight (gap-buffer-weight lines)))
        (if (= line-num weight) (+ 1 weight) weight)))

    (define (text-editor-get-start-of-line ed)
      ;; Get the character index of the start of the current line:
      ;; the running total of the CDF for the line before the current
      ;; line, which `TEXT-EDITOR-GET-CURSOR` has ensured is filled.
      ;;--------------------------------------------------------------
      (text-editor-get-cursor ed)
      (let*((lines (text-editor-lines ed))
            (line-num (gap-buffer-cursor lines))
            (cdf (text-editor-cdf ed))
            )
        (cond
         ((< 0 line-num) (cdf-ref cdf (- line-num 1)))
         ;; If the cursor is at the beginning of the buffer, the
         ;; start-of-line is always zero.
         (else 0)
         )))

    ;;----------------------------------------------------------------

    (define (run-editor-engine proc . args)
      (parameterize
          ((impl/new-buffer*           new-text-editor)
           (impl/buffer-type?*         text-editor-type?)
           (impl/buffer-length*        text-editor-char-count)
           (impl/text-load-port*       text-load-port)
           (impl/text-dump-port*       text-dump-port)
           (impl/style-type?*          vbal-type?)
           (impl/new-style*            alist->vbal)
           (impl/get-cursor-index*     text-editor-get-cursor)
           (impl/move-cursor-index*    text-editor-move-cursor)
           (impl/set-cursor-position*  text-editor-set-cursor)
           (impl/index->line-column*   text-editor-get-line-column)
           (impl/get-end-of-line*      text-editor-get-end-of-line)
           (impl/get-start-of-line*    text-editor-get-start-of-line)
           (impl/insert*               text-editor-insert)
           (impl/copy-string*          '*TODO*)
           (impl/get-char*             '*TODO*)
           (impl/delete-range*         '*TODO*)
           (impl/delete-from-cursor*   '*TODO*)
           (impl/get-default-style*    '*TODO*)
           (impl/set-default-style*    '*TODO*)
           (impl/get-text-style*       '*TODO*)
           (impl/set-text-style*       '*TODO*)
           (impl/get-selection*        '*TODO*)
           (impl/set-selection*        '*TODO*)
           (impl/scan-for-char*        '*TODO*)
           (impl/scan-for-string*      '*TODO*)
           )
        (apply proc args)
        ))

    )
  )
