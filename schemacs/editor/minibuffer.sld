(define-library (schemacs editor minibuffer)
  ;; This library mirrors GNU Emacs's `minibuffer.el' and the part of
  ;; `minibuffer.c' behind it: reading a line in the echo area with its
  ;; history, the completion table and the commands over it, and the
  ;; yes/no readers built on top.
  ;;
  ;; GNU Emacs's minibuffer is a real buffer with its own keymap, read by a
  ;; recursive edit - the same command loop, called again. Being a buffer is
  ;; what makes it an editor: C-f, C-a, C-k, M-f, C-y and DEL all work in
  ;; the prompt with no code of their own, because they are the ordinary
  ;; commands operating on the current buffer, and the minibuffer IS the
  ;; current buffer while it is active. That is why this library needs
  ;; `(schemacs editor keyboard)' - for the recursive edit - and why it can
  ;; be a leaf now that the command loop is a library of its own.
  ;;
  ;; The prompt is kept beside the buffer rather than in it: Emacs puts it
  ;; in the buffer as the `minibuffer-prompt' text property, and this editor
  ;; has no text properties wired to the display yet. What the display reads
  ;; is the frame's echo area (`*echo-area-buffer*', `*echo-area-prompt*'),
  ;; which is where Emacs keeps the same two facts.
  ;;
  ;; Two definitions that sit under the Completion banner above are *not*
  ;; here, because they are files.el's and ask about saving:
  ;; `save-answer-char->decision' and `save-some-buffers'. They go to
  ;; `(schemacs editor files)' with the file-visiting commands, which are
  ;; still in the frontend.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    ;; `read-from-minibuffer' takes an optional keymap, history and default,
    ;; which is a `case-lambda'.
    (scheme case-lambda)
    (prefix (schemacs keymap) km:)
    ;; `string-prefix?' is Guile's, not R7RS's: completion is written with
    ;; it, and leaving it out reports as an unbound variable the first time
    ;; a completion is tried.
    (only (guile) string-prefix?)
    (only (schemacs editor command)
          new-command new-count-command)
    (only (schemacs editor engine)
          new-text-editor text-editor-char-count text-editor-cursor-column
          text-editor-delete-from-cursor text-editor-insert
          text-editor-set-cursor text-editor-to-string
          text-editor-undo-disable!)
    (only (schemacs editor frame)
          *current-frame* *echo-area-buffer* *echo-area-prompt* *minibuffer*
          set!ncurses-frame-message)
    ;; `try-completion' and `all-completions' are `minibuf.c''s and live in
    ;; `(schemacs editor minibuf)'; this library is `minibuffer.el' and uses
    ;; them rather than defining them.
    (only (schemacs editor minibuf) all-completions try-completion)
    ;; The recursive edit the minibuffer is read by: the same command loop,
    ;; called again.
    (only (schemacs editor keyboard)
          abort-recursive-edit exit-recursive-edit recursive-edit)
    ;; The global map `minibuffer-local-map' is built from, and the local
    ;; map it becomes while it is read.
    (only (schemacs editor keymap)
          *current-keymap* *default-keymap*)
    )

  (export
   *minibuffer-completion-table*
   common-prefix
   completion-candidates-message
   file-name-history
   make<minibuffer>
   minibuffer-complete
   minibuffer-completion-help
   minibuffer-contents
   minibuffer-cursor-column
   minibuffer-history
   minibuffer-insert!
   minibuffer-local-completion-map
   minibuffer-local-map
   minibuffer-position
   minibuffer-prompt
   minibuffer-prompt-string
   minibuffer-set-contents!
   minibufferp
   next-history-element
   previous-history-element
   read-char-from-minibuffer
   read-from-minibuffer
   yes-or-no-p
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The minibuffer
    ;;
    ;; GNU Emacs's minibuffer is a real buffer with its own keymap, read
    ;; by a recursive edit - the same command loop, called again. Being a
    ;; buffer is what makes it an editor: C-f, C-a, C-k, M-f, C-y and DEL
    ;; all work in the prompt with no code of their own, because they are
    ;; the ordinary commands operating on the current buffer, and the
    ;; minibuffer IS the current buffer while it is active. (Emacs keeps
    ;; the selected window showing the original buffer while this is so,
    ;; which is exactly what the renderer does here.)
    ;;
    ;; The prompt is kept beside the buffer rather than in it: Emacs puts
    ;; it in the buffer as the `minibuffer-prompt' text property, and
    ;; this editor has no text properties wired to the display yet.
    ;;------------------------------------------------------------------

    (define-record-type <history>
      ;; A minibuffer history: GNU Emacs's `minibuffer-history' and
      ;; `file-name-history' are variables holding a list of previously
      ;; entered strings, so this is a mutable cell rather than a
      ;; parameter - a prompt has to be able to add to it for the next
      ;; prompt to see.
      (make<history> entries)
      history?
      (entries history-entries set!history-entries))

    (define minibuffer-history (make<history> '()))
    (define file-name-history (make<history> '()))

    (define-record-type <minibuffer-type>
      (make<minibuffer>
       editor prompt keymap default history position content)
      minibuffer-type?
      (editor   minibuffer-editor   set!minibuffer-editor)
      ;; ^ The <text-editor-type> holding what has been typed.
      (prompt   minibuffer-prompt-string set!minibuffer-prompt-string)
      (keymap   minibuffer-keymap   set!minibuffer-keymap)
      (default  minibuffer-default  set!minibuffer-default)
      (history  minibuffer-history-of set!minibuffer-history-of)
      ;; ^ Where this prompt's answers are remembered.
      (position minibuffer-position set!minibuffer-position)
      ;; ^ How far back in the history the input has been taken, 0 being
      ;; what the user typed rather than anything from the history.
      (content  minibuffer-typed-content set!minibuffer-typed-content)
      ;; ^ What the user had typed before stepping into the history, so
      ;; that stepping back out of it returns to it (Emacs's
      ;; `minibuffer-history-position' does the same job).
      )

    ;; GNU Emacs's `current-buffer' - the buffer commands act on, which
    ;; is the minibuffer's while one is active. It lives in
    ;; `(schemacs editor frame)' now, beside the frame state it is a fact
    ;; about, and `MINIBUFFER-EDITOR' is what the minibuffer binds to put
    ;; itself there.

    (define (minibufferp)
      ;; Whether the minibuffer is active: GNU Emacs's `minibufferp'.
      ;;--------------------------------------------------------------
      (and (*minibuffer*) #t))

    (define (minibuffer-contents . args)
      ;; What has been typed in the minibuffer: GNU Emacs's
      ;; `minibuffer-contents'. The optional argument is a minibuffer;
      ;; without one the active minibuffer is read.
      ;;--------------------------------------------------------------
      (let ((mb (if (pair? args) (car args) (*minibuffer*))))
        (if mb
            (text-editor-to-string (minibuffer-editor mb))
            #f)))

    (define (minibuffer-set-contents! mb text)
      ;; Replace what has been typed, leaving point at the end, the way
      ;; stepping through the history does.
      ;;--------------------------------------------------------------
      (let ((ed (minibuffer-editor mb)))
        (text-editor-undo-disable! ed)
        (text-editor-delete-from-cursor ed (text-editor-char-count ed))
        (text-editor-set-cursor ed 0)
        (text-editor-insert ed text)))

    (define (minibuffer-insert! text)
      ;; Add TEXT to what has been typed, for the completion commands.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (when mb
          (text-editor-insert (minibuffer-editor mb) text))))

    (define (minibuffer-prompt)
      ;; The prompt of the active minibuffer, as the echo area draws it.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (and mb (minibuffer-prompt-string mb))))

    (define (minibuffer-cursor-column)
      ;; The screen column the cursor belongs in while the minibuffer is
      ;; active: the prompt, then what has been typed up to point.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (and mb
             (+ (string-length (minibuffer-prompt-string mb))
                (text-editor-cursor-column (minibuffer-editor mb))))))

    (define (read-minibuffer-1 prompt initial keymap history default)
      ;; The body of `read-from-minibuffer'.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (ed (new-text-editor)))
        ;; Emacs disables undo in the minibuffer.
        (text-editor-undo-disable! ed)
        (when initial (text-editor-insert ed initial))
        (text-editor-set-cursor ed (text-editor-char-count ed))
        (let ((mb (make<minibuffer>
                   ed prompt (or keymap minibuffer-local-map) default
                   (or history minibuffer-history) 0 #f)))
          (parameterize ((*minibuffer* mb)
                         (*echo-area-buffer* ed)
                         (*echo-area-prompt* prompt)
                         (*current-keymap* (minibuffer-keymap mb)))
            (let ((result (recursive-edit frame)))
              (if (procedure? result)
                  ;; a quit: run the thunk, which signals, so the signal
                  ;; travels out past the minibuffer and abandons the
                  ;; command that asked (Emacs's
                  ;; `minibuffer-quit-recursive-edit')
                  (result)
                  (let* ((typed (minibuffer-contents mb))
                         ;; an empty answer takes the default, as
                         ;; `completing-read' does
                         (answer (if (and (= 0 (string-length typed)) default)
                                     default
                                     typed)))
                    (when (< 0 (string-length answer))
                      (let ((h (minibuffer-history-of mb)))
                        (set!history-entries
                         h (cons answer (history-entries h)))))
                    answer)))))))

    (define read-from-minibuffer
      ;; GNU Emacs's `read-from-minibuffer'. Of its arguments this takes
      ;; PROMPT, INITIAL-INPUT, KEYMAP, HISTORY and DEFAULT; `read'
      ;; (reading the text as a Lisp object rather than as a string) and
      ;; INHERIT-INPUT-METHOD are not implemented.
      ;;--------------------------------------------------------------
      (case-lambda
       ((prompt) (read-minibuffer-1 prompt #f #f #f #f))
       ((prompt initial) (read-minibuffer-1 prompt initial #f #f #f))
       ((prompt initial keymap)
        (read-minibuffer-1 prompt initial keymap #f #f))
       ((prompt initial keymap history)
        (read-minibuffer-1 prompt initial keymap history #f))
       ((prompt initial keymap history default)
        (read-minibuffer-1 prompt initial keymap history default))))

    (define exit-minibuffer
      ;; Leave the minibuffer, accepting what has been typed: GNU Emacs's
      ;; `exit-minibuffer', which is `(throw 'exit nil)'.
      ;;--------------------------------------------------------------
      (new-command
       "exit-minibuffer"
       (lambda () (exit-recursive-edit #f))
       (lambda () (exit-recursive-edit #f))
       "Accept what has been typed and leave the minibuffer."))

    (define abort-minibuffer
      ;; Leave the minibuffer and abandon the command that asked the
      ;; question: what C-g does in a minibuffer.
      ;;--------------------------------------------------------------
      (new-command
       "abort-recursive-edit"
       (lambda () (abort-recursive-edit))
       (lambda () (abort-recursive-edit))
       "Quit the minibuffer and the command that asked for it."))

    (define previous-history-element
      ;; GNU Emacs's `previous-history-element': step back N entries in
      ;; the history and put that answer in the minibuffer.
      ;;--------------------------------------------------------------
      (new-count-command
       "previous-history-element"
       (lambda (count)
         (let* ((mb (*minibuffer*))
                (h (and mb (minibuffer-history-of mb)))
                (entries (if h (history-entries h) '()))
                (position (if mb (minibuffer-position mb) 0))
                (next (min (+ position count) (length entries))))
           ;; position 0 means what the user typed rather than an entry
           (when mb
             (when (= position 0)
               (set!minibuffer-typed-content mb (minibuffer-contents mb)))
             (when (< position next)
               (set!minibuffer-position mb next)
               (minibuffer-set-contents!
                mb (list-ref entries (- next 1)))))))
       "Step back N answers in the minibuffer history."))

    (define next-history-element
      ;; GNU Emacs's `next-history-element': step forward N entries, and
      ;; past the most recent one back to what was typed.
      ;;--------------------------------------------------------------
      (new-count-command
       "next-history-element"
       (lambda (count)
         (let* ((mb (*minibuffer*))
                (h (and mb (minibuffer-history-of mb)))
                (entries (if h (history-entries h) '()))
                (position (if mb (minibuffer-position mb) 0))
                (next (max 0 (- position count))))
           (when mb
             (when (< next position)
               (set!minibuffer-position mb next)
               (minibuffer-set-contents!
                mb (if (= next 0)
                       (or (minibuffer-typed-content mb) "")
                       (list-ref entries (- next 1))))))))
       "Step forward N answers in the minibuffer history."))

    (define minibuffer-local-map
      ;; GNU Emacs's `minibuffer-local-map': the minibuffer's own bindings.
      ;; RET and C-j both leave the minibuffer, C-g abandons the command
      ;; that asked, and M-p/M-n walk the history.
      ;;
      ;; It holds *only* those. GNU Emacs's map is sparse and inherits
      ;; `global-map' because a lookup searches the local map and then the
      ;; global one, so the ordinary editing keys are found without being
      ;; copied in here - and copying them was wrong twice over: it made
      ;; the minibuffer's map a snapshot of whatever the global map held
      ;; when this library loaded, and it is what `LOOKUP-KEYMAP' in
      ;; `(schemacs editor keyboard)' now does per lookup instead.
      ;;--------------------------------------------------------------
      (km:keymap
       '*minibuffer-local-map*
       (km:alist->keymap-layer
        `(((ctrl #\m) . ,exit-minibuffer)
          ((ctrl #\j) . ,exit-minibuffer)
          ((ctrl #\g) . ,abort-minibuffer)
          ((meta #\p) . ,previous-history-element)
          ((meta #\n) . ,next-history-element)))))


    ;;----------------------------------------------------------------
    ;; Completion
    ;;
    ;; GNU Emacs's `try-completion' and `all-completions' over a
    ;; completion table, and the commands that use them. The table is a
    ;; procedure of one argument returning the candidates, which is one
    ;; of the forms Emacs's tables may take. Emacs lists candidates in a
    ;; *Completions* window; this editor has one window and no buffer
    ;; list yet, so they are shown in the echo area instead.
    ;;------------------------------------------------------------------

    (define *minibuffer-completion-table*
      ;; The table the minibuffer completes against: GNU Emacs's
      ;; `minibuffer-completion-table'.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (completion-candidates-message candidates)
      ;; How the candidates are shown when there is nothing to complete:
      ;; one long line in the echo area, where Emacs would open a
      ;; *Completions* window.
      ;;--------------------------------------------------------------
      (let loop ((rest candidates) (acc ""))
        (if (null? rest)
            acc
            (loop (cdr rest)
                  (string-append acc (if (string=? acc "") "" "  ") (car rest))))))

    (define (minibuffer-completion-help)
      ;; GNU Emacs's `minibuffer-completion-help': show what the text
      ;; could complete to.
      ;;--------------------------------------------------------------
      (let ((candidates (all-completions (or (minibuffer-contents) "")
                                         (*minibuffer-completion-table*))))
        (set!ncurses-frame-message
         (*current-frame*)
         (if (null? candidates)
             "No match"
             (completion-candidates-message candidates)))))

    (define minibuffer-complete
      ;; GNU Emacs's `minibuffer-complete': complete as far as the text
      ;; can be, and say what the candidates are when it cannot be
      ;; completed any further.
      ;;--------------------------------------------------------------
      (new-command
       "minibuffer-complete"
       (lambda ()
         (let* ((typed (or (minibuffer-contents) ""))
                (completion (try-completion typed (*minibuffer-completion-table*))))
           (cond
            ((eq? completion #t)
             (set!ncurses-frame-message (*current-frame*) "Complete, but not unique"))
            ((not completion)
             (set!ncurses-frame-message (*current-frame*) "No match"))
            ((string=? completion typed) (minibuffer-completion-help))
            (else
             (minibuffer-insert! (substring completion (string-length typed)))))))
       (lambda () #f)
       "Complete the text in the minibuffer as far as it can be (bound to TAB)."))

    (define minibuffer-local-completion-map
      ;; GNU Emacs's `minibuffer-local-completion-map', whose parent is
      ;; `minibuffer-local-map'. TAB completes; RET leaves the minibuffer
      ;; as it does there rather than running Emacs's
      ;; `minibuffer-completion-exit', because nothing here selects a
      ;; completion to put in the text first.
      ;;--------------------------------------------------------------
      (apply km:keymap
             '*minibuffer-local-completion-map*
             (append
              (list (km:alist->keymap-layer
                     `(((ctrl #\i) . ,minibuffer-complete)
                       ((#\?) . ,minibuffer-completion-help))))
              (km:keymap->layers-list minibuffer-local-map))))

    (define (read-char-from-minibuffer prompt)
      ;; GNU Emacs's `read-char-from-minibuffer': ask a question whose
      ;; answer is a single key, and return that key. Emacs reads the key
      ;; on its own, without RET, through a special keymap; here the key
      ;; is typed and then RET, and its first character is the answer.
      ;; (Answering on the keystroke itself needs a keymap whose
      ;; self-inserting layer reports the character it matched, which
      ;; this editor's keymap machinery cannot yet do.)
      ;;--------------------------------------------------------------
      (let ((answer (read-from-minibuffer prompt)))
        (and (< 0 (string-length answer))
             (string-ref answer 0))))

    (define (yes-or-no-p frame prompt)
      ;; GNU Emacs's `yes-or-no-p': the whole word, then RET. Being
      ;; fussier than `y-or-n-p' is the point - the answer to a question
      ;; about losing work should take some effort to give. C-g abandons
      ;; the command that asked.
      ;;--------------------------------------------------------------
      (let loop ()
        (let ((answer (read-from-minibuffer (string-append prompt "(yes or no) "))))
          (cond
           ((string-ci=? answer "yes") #t)
           ((string-ci=? answer "no") #f)
           (else (set!ncurses-frame-message frame "Please answer yes or no.")
                 (loop))))))

    ))
