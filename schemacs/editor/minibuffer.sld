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
          new-command new-count-command run-command)
    (only (schemacs editor engine)
          new-text-editor text-editor-char-count text-editor-copy-string
          text-editor-cursor-column text-editor-delete-from-cursor
          text-editor-get-end-of-line text-editor-get-start-of-line
          text-editor-insert text-editor-set-cursor
          text-editor-set-read-only! text-editor-to-string
          text-editor-undo-disable!)
    ;; `logior' is Guile's: the bitset is three bit flags.
    (only (guile) logior)
    ;; The `*Completions*' buffer is filled with the `face' text property
    ;; and shown in a window. (`keymap' above is `(schemacs keymap)''s,
    ;; which the completion map is built with - this library's `km:' names
    ;; are the keymap library's, not this one's.)
    (only (schemacs editor textprop) put-text-property)
    (only (schemacs editor buffer)
          buffer-default-directory current-buffer get-buffer-create
          buffer-local-keymap set!buffer-local-keymap set!buffer-default-directory
          with-current-buffer)
    ;; `getcwd' is Guile's, for a buffer that has no `default-directory'.
    (only (guile) getcwd)
    (only (schemacs editor window) display-buffer quit-window)
    (only (schemacs editor frame)
          *current-frame* *echo-area-buffer* *echo-area-prompt* *minibuffer*
          set!ncurses-frame-message)
    ;; `try-completion' and `all-completions' are `minibuf.c''s and live in
    ;; `(schemacs editor minibuf)'; this library is `minibuffer.el' and uses
    ;; them rather than defining them.
    (only (schemacs editor minibuf)
          all-completions test-completion try-completion)
    ;; `caddr' is `(scheme cxr)'s: a style's entry in
    ;; `completion-styles-alist' is a four-element list.
    (only (scheme cxr) caddr)

    ;; The recursive edit the minibuffer is read by: the same command loop,
    ;; called again.
    (only (schemacs editor keyboard)
          abort-recursive-edit exit-recursive-edit recursive-edit)
    ;; The global map `minibuffer-local-map' is built from, and the local
    ;; map it becomes while it is read.
    (only (schemacs editor keymap)
          define-key *current-keymap* *default-keymap*)
    )

  (export
   *minibuffer-completion-table*
   *completion-styles*
   choose-completion
   completion--do-completion
   completion-list-mode-map
   display-completion-list
   completion--nth-completion
   completion-all-completions
   completion-basic-all-completions
   completion-basic-try-completion
   completion-boundaries
   completion-styles-alist
   completion-substring-all-completions
   completion-substring-try-completion
   completion-try-completion
   completing-read
   minibuffer--bitset
   minibuffer-complete-and-exit
   minibuffer-complete-word
   minibuffer-local-must-match-map
   *completion-auto-help*
   *minibuffer-completion-confirm*
   *minibuffer-completion-predicate*
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
          ;; The minibuffer inherits the *asking* buffer's
          ;; `default-directory', as Emacs's does: a relative name typed in
          ;; the prompt is relative to the buffer that asked, not to the
          ;; minibuffer.
          ;;
          ;; It has to be copied here and not read later, because while the
          ;; prompt is being read `current-buffer' is the *minibuffer*, and
          ;; asking it then answers the process's directory instead - so
          ;; completing a file name offered the editor's own directory
          ;; rather than the one being typed about.
          (set!buffer-default-directory
           ed (or (buffer-default-directory (current-buffer)) (getcwd)))
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

    (define minibuffer-completion-help
      ;; GNU Emacs's `minibuffer-completion-help': show what the text
      ;; could complete to. A command, because `?' is bound to it.
      ;;
      ;; The candidates go in a `*Completions*' window, which is what
      ;; Emacs does and what this used to fake with one long line in the
      ;; echo area - the comment that said "this editor has one window and
      ;; no buffer list yet" stopped being true when `display-buffer'
      ;; arrived.
      ;;
      ;; Showing the window must not take point out of the prompt, which
      ;; is why it is `display-buffer' and not `pop-to-buffer': the
      ;; minibuffer is being read by a recursive edit, and the completion
      ;; commands act on it again as soon as this returns.
      ;;--------------------------------------------------------------
      (new-command
       "minibuffer-completion-help"
       (lambda ()
         (let* ((typed (or (minibuffer-contents) ""))
                (candidates (completion-all-completions
                             typed (*minibuffer-completion-table*)
                             (*minibuffer-completion-predicate*)
                             (string-length typed))))
           (cond
            ((not candidates)
             (set!ncurses-frame-message (*current-frame*) "No match"))
            (else
             ;; The answer is a dotted list whose last cdr is the base
             ;; size, so the candidates are what is before it.
             (display-buffer
              (display-completion-list
               (let loop ((rest candidates) (acc '()))
                 (if (not (pair? rest))
                     (reverse acc)
                     (loop (cdr rest) (cons (car rest) acc))))
               typed))))))
       (lambda () #f)
       "Show the possible completions of the text in the minibuffer."))

    (define minibuffer-complete
      ;; GNU Emacs's `minibuffer-complete': complete as far as the text
      ;; can be, and say what the candidates are when it cannot be
      ;; completed any further.
      ;;--------------------------------------------------------------
      (new-command
       "minibuffer-complete"
       (lambda ()
         (let* ((typed (or (minibuffer-contents) ""))
                ;; `completion-try-completion' rather than
                ;; `try-completion', because a *style* decides how to
                ;; complete: the answer is #t, #f, or a pair of the new
                ;; text and where point goes in it.
                (completion (completion-try-completion
                             typed (*minibuffer-completion-table*) #f
                             (string-length typed))))
           (cond
            ((eq? completion #t)
             (set!ncurses-frame-message (*current-frame*) "Complete, but not unique"))
            ((not completion)
             (set!ncurses-frame-message (*current-frame*) "No match"))
            ((string=? (car completion) typed) (run-command minibuffer-completion-help))
            (else
             ;; What is inserted is the part of the completion that is
             ;; past what was typed - a *substring* completion can differ
             ;; from the text before the end, so the common prefix is what
             ;; stays put.
             (let ((new (car completion)))
               ;; `string-length', not `length': the common prefix is a
               ;; *string*, and `length' wants a list.
               (minibuffer-insert!
                (substring new (string-length (common-prefix (list typed new))))))))))
       (lambda () #f)
       "Complete the text in the minibuffer as far as it can be (bound to TAB)."))

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

    ;;----------------------------------------------------------------
    ;; The completion styles
    ;;
    ;; GNU Emacs's `completion-styles': a *list* of ways to complete,
    ;; tried in turn, and the first one that finds anything wins. That
    ;; is what makes `basic' (prefix) and `substring' both available
    ;; without either having to know about the other.

    (define *completion-styles*
      ;; GNU Emacs's `completion-styles'. Emacs's default is
      ;; `(basic partial-completion emacs22)'; `partial-completion' is
      ;; the PCM pattern engine and `emacs22' is prefix completion on the
      ;; text before point, which for a minibuffer whose point is at the
      ;; end is what `basic' already is. The two styles this library has
      ;; are the first and the one most people reach for, so the default
      ;; is those.
      ;;--------------------------------------------------------------
      (make-parameter '(basic substring)))

    (define (completion-styles-alist)
      ;; GNU Emacs's `completion-styles-alist': each style as
      ;; `(NAME TRY-COMPLETION ALL-COMPLETIONS DESCRIPTION)'. Emacs
      ;; builds it once as a variable; it is built here each time because
      ;; the two procedures are defined below it.
      ;;--------------------------------------------------------------
      (list (list 'basic
                  completion-basic-try-completion
                  completion-basic-all-completions
                  "Completion of the prefix before point.")
            (list 'substring
                  completion-substring-try-completion
                  completion-substring-all-completions
                  "Completion of the string taken as a substring.")))

    (define (completion--some string table predicate point nth)
      ;; The `seq-some' of GNU Emacs's `completion--nth-completion': try
      ;; each style in turn and answer `(RESULT . STYLE)' for the first
      ;; that finds anything, or #f when none does.
      ;;
      ;; NTH picks which of a style's two functions to call - 1 for
      ;; `completion-try-completion', 2 for `completion-all-completions' -
      ;; which is how one list of styles serves both questions.
      ;;--------------------------------------------------------------
      (let loop ((rest (*completion-styles*)))
        (cond
         ((null? rest) #f)
         (else
          (let ((entry (assq (car rest) (completion-styles-alist))))
            (if (not entry)
                (error "Invalid completion style" (car rest))
                (let ((probe ((if (= nth 1) (cadr entry) (caddr entry))
                              string table predicate point)))
                  (if probe (cons probe (car rest)) (loop (cdr rest))))))))))

    (define (completion--nth-completion nth string table predicate point)
      ;; GNU Emacs's `completion--nth-completion': the answer from the
      ;; first style that finds anything. Emacs also lets a *table* be
      ;; quoted and unquoted around the styles and lets a style adjust
      ;; the completion metadata; neither has any meaning here yet.
      ;;--------------------------------------------------------------
      (let ((result-and-style (completion--some string table predicate point nth)))
        (and result-and-style (car result-and-style))))

    (define (completion-try-completion string table predicate point)
      ;; GNU Emacs's `completion-try-completion': what STRING can be
      ;; completed to. The answer is #f for nothing, #t for "STRING is
      ;; already the only completion", or `(NEWSTRING . NEWPOINT)' - a
      ;; *pair*, because a style may need to put point somewhere other
      ;; than the end of the new text.
      ;;--------------------------------------------------------------
      (completion--nth-completion 1 string table predicate point))

    (define (completion-all-completions string table predicate point)
      ;; GNU Emacs's `completion-all-completions': the candidates, with
      ;; the *base size* in the last cdr - the length of the text the
      ;; completion starts from, which is what tells a caller how much of
      ;; what was typed the completion replaces. `(cdr (last ANSWER))' is
      ;; how Emacs reads it back, so the answer is a dotted list.
      ;;--------------------------------------------------------------
      (completion--nth-completion 2 string table predicate point))

    (define (completion-boundaries string table predicate afterpoint)
      ;; GNU Emacs's `completion-boundaries', which asks a table where the
      ;; text it is completing *begins and ends* - the answer is
      ;; `(START . END)' within the string. A plain list of candidates has
      ;; no opinion, so the default is the whole string; Emacs has the same
      ;; default for a table with no metadata, and the file-name table is
      ;; the one that answers otherwise.
      ;;--------------------------------------------------------------
      (cons 0 0))

    (define (common-prefix strings)
      ;; The longest prefix every one of STRINGS begins with. This is not
      ;; an Emacs function: Emacs gets the same answer as a side effect of
      ;; merging the completed pattern (`completion-pcm--merge-try'), and
      ;; this is what stands in for that until the PCM engine is here.
      ;;--------------------------------------------------------------
      (let loop ((i 0))
        (if (and (< i (string-length (car strings)))
                 (let all ((rest (cdr strings)))
                   (cond
                    ((null? rest) #t)
                    ((and (< i (string-length (car rest)))
                          (char=? (string-ref (car rest) i)
                                  (string-ref (car strings) i)))
                     (all (cdr rest)))
                    (else #f))))
            (loop (+ 1 i))
            (substring (car strings) 0 i))))

    ;;----------------------------------------------------------------
    ;; The styles themselves

    (define (completion-basic-try-completion string table predicate point)
      ;; GNU Emacs's `completion-basic-try-completion': prefix completion.
      ;;
      ;; Emacs also completes the text *after* point here - the second half
      ;; of `basic', which is what makes completing "foo_bar" with point
      ;; after the underscore complete both halves. A minibuffer prompt has
      ;; point at the end and no afterpoint, so what is left is the C's
      ;; `try-completion', with point at the end of what it found.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (completion (try-completion beforepoint table predicate)))
        (if (not (string? completion))
            completion
            (cons completion (string-length completion)))))

    (define (completion-basic-all-completions string table predicate point)
      ;; GNU Emacs's `completion-basic-all-completions`: the prefix
      ;; matches, with the base size in the last cdr.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (all (all-completions beforepoint table predicate)))
        (if (null? all)
            #f
            (append all 0))))

    (define (completion-substring-candidates string table predicate)
      ;; The candidates STRING appears in *anywhere*: what the `substring'
      ;; style means by completing. Emacs gets there through its PCM
      ;; pattern engine, which is a general glob matcher shared with
      ;; `partial-completion' and `flex'; the meaning is this, and this is
      ;; what it is built on when that engine arrives.
      ;;--------------------------------------------------------------
      (let loop ((rest (if (procedure? table)
                           (table string predicate #t)
                           table))
                 (acc '()))
        (cond
         ((not (pair? rest)) (reverse acc))
         (else
          (let ((candidate (if (pair? (car rest)) (car (car rest)) (car rest))))
            (cond
             ((not (string? candidate))
              (loop (cdr rest) acc))
             ((not (or (not predicate) (predicate candidate)))
              (loop (cdr rest) acc))
             ((substring? string candidate)
              (loop (cdr rest) (cons candidate acc)))
             (else (loop (cdr rest) acc))))))))

    (define (substring? needle haystack)
      ;; Whether NEEDLE occurs anywhere in HAYSTACK - the test the
      ;; `substring' style is named for.
      ;;--------------------------------------------------------------
      (let ((n (string-length needle))
            (h (string-length haystack)))
        (let loop ((i 0))
          (cond ((> (+ i n) h) #f)
                ((string=? needle (substring haystack i (+ i n))) #t)
                (else (loop (+ 1 i)))))))

    (define (completion-substring-all-completions string table predicate point)
      ;; GNU Emacs's `completion-substring-all-completions'.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (all (completion-substring-candidates beforepoint table predicate)))
        (if (null? all)
            #f
            (append all 0))))

    (define (completion-substring-try-completion string table predicate point)
      ;; GNU Emacs's `completion-substring-try-completion'.
      ;;
      ;; A substring match is not a *prefix* of what was typed, so the
      ;; answer is the match itself rather than a longer version of the
      ;; input: completing "oo" against `("foo")' gives "foo" and point 3,
      ;; where prefix completion would give nothing at all. Emacs merges
      ;; the pattern to get there; with several matches it answers the
      ;; longest prefix they agree on, which is what a caller does with
      ;; it anyway.
      ;;--------------------------------------------------------------
      (let* ((beforepoint (substring string 0 point))
             (all (completion-substring-candidates beforepoint table predicate)))
        (cond
         ((null? all) #f)
         ((and (null? (cdr all)) (string=? (car all) beforepoint)) #t)
         ((null? (cdr all)) (cons (car all) (string-length (car all))))
         (else (cons (common-prefix all) (string-length (common-prefix all)))))))
    ;;----------------------------------------------------------------
    ;; Doing a completion, and what RET does about it

    (define *minibuffer-completion-predicate*
      ;; GNU Emacs's `minibuffer-completion-predicate': the filter the
      ;; completion commands pass to the table. `completing-read' binds it
      ;; from its PREDICATE argument.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *minibuffer-completion-confirm*
      ;; GNU Emacs's `minibuffer-completion-confirm': whether RET may
      ;; leave the minibuffer holding something that is *not* a valid
      ;; completion. #f means it may not, `confirm' means it asks first,
      ;; and anything else means it may.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *completion-auto-help*
      ;; GNU Emacs's `completion-auto-help': whether a completion that
      ;; cannot go further shows the candidates on its own.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (minibuffer--bitset modified completions exact)
      ;; GNU Emacs's `minibuffer--bitset': what a completion did, as three
      ;; bits - M (the text was *modified*), C (there were completions at
      ;; all) and E (what is there now is an *exact* match).
      ;;
      ;; 001 was already an exact and unique completion
      ;; 011 was already an exact completion
      ;; 110 some completion happened, but is not exact
      ;; 111 completed to an exact completion
      ;; 000 (and 010) nothing to do
      ;;--------------------------------------------------------------
      (logior (if modified 4 0) (if completions 2 0) (if exact 1 0)))

    (define (completion--replace completion)
      ;; GNU Emacs's `completion--replace': rewrite what has been typed as
      ;; COMPLETION, with point at the end of it. Emacs replaces the text
      ;; between BEG and END, which here is the whole of what was typed.
      ;;--------------------------------------------------------------
      (let ((mb (*minibuffer*)))
        (when mb
          (let ((ed (minibuffer-editor mb)))
            (text-editor-set-cursor ed 0)
            (text-editor-delete-from-cursor ed (text-editor-char-count ed))
            (text-editor-insert ed completion)))))

    (define (completion--do-completion string table predicate point)
      ;; GNU Emacs's `completion--do-completion': complete STRING, put the
      ;; result in the minibuffer, and answer the bitset saying what
      ;; happened.
      ;;
      ;; The two messages it can leave are Emacs's, and they are what the
      ;; user sees when TAB does not simply fill the rest in:
      ;; "Complete, but not unique" when what is there now is a valid
      ;; completion that others also match, and the list of candidates
      ;; when it is not a valid completion at all.
      ;;
      ;; Not ported: the `completion-cycle-threshold' cycling, the
      ;; metadata (`completion--field-metadata'), and
      ;; `completion-auto-help''s `lazy' mode.
      ;;--------------------------------------------------------------
      (let ((comp (completion-try-completion string table predicate point)))
        (cond
         ((not comp)
          (set!ncurses-frame-message (*current-frame*) "No match")
          (minibuffer--bitset #f #f #f))
         ((eq? comp #t)
          (set!ncurses-frame-message (*current-frame*) "Sole completion")
          (minibuffer--bitset #f #f #t))
         (else
          (let* ((completion (car comp))
                 ;; "completed" excludes a change of *case* alone, which
                 ;; is rewritten in the buffer but is not a completion.
                 (completed (not (string-ci=? completion string)))
                 (unchanged (string=? completion string))
                 (exact (test-completion completion table predicate)))
            (unless unchanged (completion--replace completion))
            (cond
             ((not exact)
              (if (*completion-auto-help*)
                  (run-command minibuffer-completion-help)
                  (set!ncurses-frame-message (*current-frame*)
                                             "Next char not unique")))
             (else
              (set!ncurses-frame-message (*current-frame*)
                                         "Complete, but not unique")))
            (minibuffer--bitset completed #t exact))))))

    (define minibuffer-complete-and-exit
      ;; GNU Emacs's `minibuffer-complete-and-exit' (RET in a
      ;; `require-match' minibuffer): leave if what is typed is a valid
      ;; completion, and otherwise complete it and say why it did not.
      ;;
      ;; The bitset is what decides, and the cases are Emacs's: an exact
      ;; (and unique) completion leaves; a completion that reached an
      ;; exact match leaves unless `minibuffer-completion-confirm' says to
      ;; ask first; and anything else stays put.
      ;;--------------------------------------------------------------
      (new-command
       "minibuffer-complete-and-exit"
       (lambda ()
         (let* ((typed (or (minibuffer-contents) ""))
                (bits (completion--do-completion
                       typed (*minibuffer-completion-table*)
                       (*minibuffer-completion-predicate*)
                       (string-length typed))))
           (cond
            ((or (= bits 1) (= bits 3)) (run-command exit-minibuffer))
            ((= bits 7)
             (if (*minibuffer-completion-confirm*)
                 (set!ncurses-frame-message (*current-frame*) "Confirm")
                 (run-command exit-minibuffer)))
            (else #f))))
       (lambda () #f)
       "Exit the minibuffer, if what is typed is a valid completion."))

    (define (completion--try-word-completion string table predicate point)
      ;; GNU Emacs's `completion--try-word-completion': complete the text
      ;; and then a space, then a hyphen - so that completing a word in a
      ;; sentence moves on to the next one. It is what SPC does in a
      ;; completing minibuffer.
      ;;--------------------------------------------------------------
      (let loop ((suffixes '(" " "-")))
        (cond
         ((null? suffixes)
          (completion-try-completion string table predicate point))
         (else
          (let ((candidate (completion-try-completion
                            (string-append string (car suffixes))
                            table predicate
                            (+ point (string-length (car suffixes))))))
            (cond
             ((and (pair? candidate) (string=? (car candidate)
                                               (string-append string (car suffixes))))
              candidate)
             (else (loop (cdr suffixes)))))))))

    (define minibuffer-complete-word
      ;; GNU Emacs's `minibuffer-complete-word' (SPC): complete at most a
      ;; single word.
      ;;--------------------------------------------------------------
      (new-command
       "minibuffer-complete-word"
       (lambda ()
         (let* ((typed (or (minibuffer-contents) ""))
                (comp (completion--try-word-completion
                       typed (*minibuffer-completion-table*)
                       (*minibuffer-completion-predicate*)
                       (string-length typed))))
           (cond
            ((and (pair? comp) (not (string=? (car comp) typed)))
             (completion--replace (car comp)))
            ((not comp)
             (set!ncurses-frame-message (*current-frame*) "No match"))
            (else (run-command minibuffer-completion-help)))))
       (lambda () #f)
       "Complete the minibuffer contents at most a single word (SPC)."))

    ;;----------------------------------------------------------------
    ;; Reading with completion

    (define (list-ref-or list index default)
      ;; The INDEXth of LIST, or DEFAULT when it is not there. Emacs's
      ;; optional arguments are `&optional' and a Scheme function has to
      ;; pick them out of a rest list.
      ;;--------------------------------------------------------------
      (let loop ((rest list) (n index))
        (cond ((null? rest) default)
              ((= n 0) (car rest))
              (else (loop (cdr rest) (- n 1))))))

    (define (completing-read prompt collection . args)
      ;; GNU Emacs's `completing-read': read a string in the minibuffer,
      ;; completing against COLLECTION.
      ;;
      ;;   (completing-read PROMPT COLLECTION &optional PREDICATE
      ;;                    REQUIRE-MATCH INITIAL-INPUT HISTORY DEF)
      ;;
      ;; REQUIRE-MATCH is the argument that changes what RET does: with it
      ;; the minibuffer will not be left holding something that is not a
      ;; valid completion, which is the whole difference between
      ;; `minibuffer-local-completion-map' and
      ;; `minibuffer-local-must-match-map'.
      ;;--------------------------------------------------------------
      (let ((predicate (list-ref-or args 0 #f))
            (require-match (list-ref-or args 1 #f))
            (initial (list-ref-or args 2 #f))
            (history (list-ref-or args 3 minibuffer-history))
            (default (list-ref-or args 4 #f)))
        (parameterize ((*minibuffer-completion-table* collection)
                       (*minibuffer-completion-predicate* predicate)
                       (*minibuffer-completion-confirm*
                        (if (or (eq? require-match 'confirm)
                                (eq? require-match 'confirm-after-completion))
                            #t
                            #f)))
          (read-from-minibuffer
           prompt initial
           (if require-match
               minibuffer-local-must-match-map
               minibuffer-local-completion-map)
           history default))))
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
                       ((#\space) . ,minibuffer-complete-word)
                       ((#\?) . ,minibuffer-completion-help))))
              (km:keymap->layers-list minibuffer-local-map))))


    (define minibuffer-local-must-match-map
      ;; GNU Emacs's `minibuffer-local-must-match-map', whose parent is
      ;; `minibuffer-local-completion-map': RET completes and exits rather
      ;; than leaving with whatever is typed, and C-j does the same.
      ;;--------------------------------------------------------------
      (apply km:keymap
             '*minibuffer-local-must-match-map*
             (append
              (list (km:alist->keymap-layer
                     `(((ctrl #\m) . ,minibuffer-complete-and-exit)
                       ((ctrl #\j) . ,minibuffer-complete-and-exit))))
              (km:keymap->layers-list minibuffer-local-completion-map))))

    ;;----------------------------------------------------------------
    ;; The *Completions* buffer

    (define (display-completion-list completions common-substring)
      ;; GNU Emacs's `display-completion-list': fill the `*Completions*'
      ;; buffer with COMPLETIONS, one per line, and answer with it.
      ;;
      ;; Two departures from Emacs, both because of what this project has:
      ;;
      ;;  * **One candidate per line.** Emacs lays them out in columns to
      ;;    fit the window (`completions-format' is `horizontal'), which
      ;;    is a display concern wanting the window's width; this is
      ;;    Emacs's `one-column' format.
      ;;  * **The faces go on here**, not in `completion-hilit-commonality'
      ;;    as in Emacs - because Emacs highlights the candidate
      ;;    *strings*, and a string here cannot carry a property. A face
      ;;    lives on buffer text, which is also where the renderer reads
      ;;    it, so this is where it has to be put.
      ;;--------------------------------------------------------------
      (let ((buffer (get-buffer-create "*Completions*")))
        (with-current-buffer buffer
          (set!buffer-local-keymap buffer completion-list-mode-map)
          (text-editor-set-read-only! buffer #f)
          (text-editor-set-cursor buffer 0)
          (text-editor-delete-from-cursor buffer (text-editor-char-count buffer))
          (for-each
           (lambda (candidate)
             (let ((start (text-editor-char-count buffer))
                   (matched (min (string-length common-substring)
                                 (string-length candidate))))
               (text-editor-insert buffer candidate)
               ;; `completions-common-part' on the part the pattern
               ;; matched, and `completions-first-difference' on the
               ;; first character past it - Emacs's
               ;; `completion-hilit-commonality', applied to the line
               ;; rather than to the string.
               (put-text-property start (+ start matched)
                                  'face 'completions-common-part buffer)
               (when (< (+ start matched) (+ start (string-length candidate)))
                 (put-text-property (+ start matched) (+ 1 start matched)
                                    'face 'completions-first-difference buffer))
               (text-editor-insert buffer "\n")))
           completions)
          (text-editor-set-read-only! buffer #t)
          (text-editor-set-cursor buffer 0))
        buffer))

    (define choose-completion
      ;; GNU Emacs's `choose-completion': take the candidate on this line
      ;; and put it in the minibuffer that asked for the completion, then
      ;; take the completions window away.
      ;;
      ;; Emacs finds the candidate's text properties to know what to
      ;; insert; here the line point is on *is* the candidate, so the line
      ;; is what is read - and that is why the buffer is one per line.
      ;;--------------------------------------------------------------
      (new-command
       "choose-completion"
       (lambda ()
         (let* ((ed (current-buffer))
                (start (text-editor-get-start-of-line ed))
                (end (text-editor-get-end-of-line ed))
                (candidate (text-editor-copy-string ed start end))
                (mb (*minibuffer*)))
           (when (and mb (> (string-length candidate) 0))
             ;; put it in the prompt, replacing what was typed
             (let ((mb-ed (minibuffer-editor mb)))
               (text-editor-set-cursor mb-ed 0)
               (text-editor-delete-from-cursor mb-ed
                                               (text-editor-char-count mb-ed))
               (text-editor-insert mb-ed candidate))
             (quit-window))))
       (lambda () #f)
       "Select the completion on this line."))

    (define completion-list-mode-map
      ;; GNU Emacs's `completion-list-mode-map': RET selects the
      ;; completion on the line - putting it in the minibuffer that is
      ;; still being read - and `q' takes the window away again.
      ;;
      ;; Emacs also binds `n' and `p' to the ordinary line motion, which
      ;; is not stated here because the buffer's keymap falls back to the
      ;; global one, where those already live.
      ;;--------------------------------------------------------------
      (let ((map (km:keymap '*completion-list-mode-map*)))
        (define (bind! key command)
          (define-key map (if (list? key) key (list key)) command))
        (bind! #\q quit-window)
        (bind! (list 'ctrl #\m) choose-completion)
        (bind! #\return choose-completion)
        map))

    ))
