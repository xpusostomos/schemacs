(define-library (schemacs editor replace)
  ;; This library mirrors GNU Emacs's `replace.el': `query-replace'
  ;; (M-%), `query-replace-regexp', `replace-string', `replace-regexp',
  ;; and everything they are built on - `query-replace-read-args' and
  ;; the reading of FROM and TO, `perform-replace', whose loop is the
  ;; one key at a time question, `replace-search', the highlight
  ;; pair, and `query-replace-map', the keymap of answers.
  ;;
  ;; The regexp variants run on `(schemacs editor search)' - the
  ;; `string-match' layer standing in for `regex-emacs.c'.
  ;;
  ;; What is not here, and named where the C has it: the diff answer
  ;; (`d'), the multi-buffer answers (`Y'/`N' of
  ;; multi-query-replace-map), `region-noncontiguous-p' (rectangular
  ;; regions), `query-replace-skip-read-only' and the invisible and
  ;; filtered skips (no overlays, no filters here - the counts stay
  ;; zero), `recenter-top-bottom''s cycling, `scroll-other-window', the
  ;; `query-replace-show-preview' machinery (the minibuffer holds no
  ;; text properties), `read-regexp''s suggestion keys, and the `\,'
  ;; and `\#' forms that evaluate Lisp in the replacement.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor engine)
          copy-marker marker-position marker-type? set-marker!
          text-editor-char-count text-editor-get-cursor
          text-editor-undo-boundary!)
    ;; `*case-fold-search*' is the case folding `perform-replace'
    ;; parameterizes around its loop (the C's
    ;; `(let* ((case-fold-search ...)))').
    (only (schemacs editor buffer)
          *case-fold-search* buffer-modified-p current-buffer
          erase-buffer get-buffer-create transient-mark-mode
          with-current-buffer)
    (only (schemacs editor frame)
          *current-frame* frame-selected-window recenter set!frame-message
          set-message!)
    (only (schemacs editor editfns)
          barf-if-buffer-read-only bobp buffer-substring char-after
          delete-region eobp goto-char insert point point-min point-max
          save-excursion)
    ;; `transient-mark-mode' is `buffer.c''s variable here, beside
    ;; `mark-active'.
    (only (schemacs editor simple)
          deactivate-mark push-mark scroll-up-command
          scroll-down-command use-region-p word-char?)
    ;; The search primitives: the searches that find the occurrences
    ;; and the match data and `replace-match' that make the edits.
    (only (schemacs editor search)
          looking-at looking-back match-beginning match-data
          match-data--translate match-end match-string
          match-substitute-replacement re-search-backward
          re-search-forward regexp-quote replace-match save-match-data
          search-backward search-forward set-match-data string-match)
    ;; The key reads: the loop reads one key at a time, exactly the
    ;; command loop's own read, and pushes a key it does not know back
    ;; onto `*unread-command-events*'. The event's key path comes from
    ;; the generic `key-event->keymap-path' (`dispnew.sld''s, which
    ;; term and pgtk method).
    (only (schemacs editor keyboard)
          *unread-command-events* read-key-event recursive-edit
          signal-quit)
    (only (schemacs editor dispnew)
          current-display key-event->keymap-path)
    (only (schemacs editor minibuffer)
          *minibuffer-setup-hook*
          format-prompt history-entries list-ref-or make<history>
          read-from-minibuffer set!history-entries)
    ;; `history-add-new-input' is `minibuf.c''s; the two reads below turn
    ;; it off and file each answer themselves, as the C does.
    (only (schemacs editor minibuf) *history-add-new-input*)
    ;; `char-displayable-p' is `international/mule.el''s: it decides
    ;; whether the terminal can draw the separator between FROM and TO.
    (only (schemacs editor mule) char-displayable-p)
    ;; the redraw
    (only (schemacs editor xdisp) render!)
    ;; `search-upper-case' decides the search's folding, which the
    ;; `isearch-no-upper-case-p' of isearch.el reads; the highlighting is
    ;; isearch's, as it is in Emacs - `replace-highlight' makes its own
    ;; overlay and hands the other matches to the lazy highlighter.
    (only (schemacs editor isearch)
          *search-upper-case* isearch-no-upper-case-p
          *lazy-highlight-cleanup*
          isearch-lazy-highlight-update lazy-highlight-cleanup
          minibuffer-lazy-highlight-setup)
    ;; `replace-highlight''s overlay, and the `query-replace' face it
    ;; carries - `(defface query-replace '((t (:inherit isearch))))'
    ;; (replace.el:165), which is why the match point is on looks the way
    ;; an isearch match does.
    (only (schemacs editor buffer)
          current-buffer delete-overlay make-overlay move-overlay overlay-put)
    (only (schemacs editor faces) defface)
    (only (schemacs editor command)
          current-prefix-arg define-command uarg->integer)
    (only (schemacs editor keymap) define-key *default-keymap* *current-keymap*)
    (prefix (schemacs keymap) km:)
    (only (schemacs editor window) display-buffer)
    (only (schemacs editor subr) add-to-history)
    (only (guile) cadr caddr cddr cdddr cadddr cddddr format string-contains)
    )

  (export
   *case-replace*
   *query-replace-defaults*
   *query-replace-from-to-separator*
   *query-replace-history*
   *query-replace-lazy-highlight*
   *query-replace-map*
   *query-replace-read-from-default*
   *query-replace-read-from-regexp-default*
   perform-replace
   query-replace
   query-replace-descr
   query-replace-read-args
   query-replace-read-from
   query-replace-read-to
   query-replace-regexp
   replace-regexp
   replace-string
   )

  (begin

    ;;----------------------------------------------------------------
    ;; The variables
    ;;------------------------------------------------------------------

    (define *case-replace*
      ;; GNU Emacs's `case-replace' (replace.el:35): "Non-nil means
      ;; `query-replace' should preserve case in replacements."
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *query-replace-history*
      ;; GNU Emacs's `query-replace-history' (replace.el:66): the
      ;; history the FROM and TO prompts share.
      ;;--------------------------------------------------------------
      (make<history> '()))

    (define *query-replace-defaults*
      ;; GNU Emacs's `query-replace-defaults' (replace.el:71): "a list
      ;; of cons cells (FROM-STRING . TO-STRING)" - the last replacement
      ;; pair, which the FROM prompt offers as its default.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *query-replace-from-to-separator*
      ;; GNU Emacs's `query-replace-from-to-separator' (replace.el:73):
      ;; "String that separates FROM and TO in the history of replacement
      ;; pairs. When nil, the pair will not be added to the history".
      ;; Emacs draws it in the `minibuffer-prompt' face and marks it with
      ;; a `separator' text property so it can be found again; there are
      ;; no text properties on a minibuffer answer here, so it is found
      ;; as a substring (`query-replace--split-string').
      ;;--------------------------------------------------------------
      " → ")

    (define *query-replace-read-from-default*
      ;; GNU Emacs's `query-replace-read-from-default' (replace.el:221):
      ;; "Function to get default non-regexp value for
      ;; `query-replace-read-from'." Unset, as in Emacs.
      ;;--------------------------------------------------------------
      #f)

    (define *query-replace-read-from-regexp-default*
      ;; GNU Emacs's `query-replace-read-from-regexp-default'
      ;; (replace.el:224): the regexp reading's own.
      ;;--------------------------------------------------------------
      #f)

    (define *query-replace-show-replacement*
      ;; GNU Emacs's `query-replace-show-replacement' (replace.el): show
      ;; the CASED replacement in the prompt - what the match would
      ;; become - rather than the raw replacement string.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *query-replace-lazy-highlight*
      ;; GNU Emacs's `query-replace-lazy-highlight' (replace.el:153):
      ;; "Controls the lazy-highlighting during query replacements. When
      ;; non-nil, all text matching the current match that is currently
      ;; visible in the window is highlighted lazily using isearch lazy
      ;; highlighting." `replace-highlight' reads it to decide whether to
      ;; run the lazy loop, exactly as the C does.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *query-replace-highlight*
      ;; GNU Emacs's `query-replace-highlight' (replace.el:130): "Non-nil
      ;; means to highlight matches during query replacement."
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define replace-overlay (make-parameter #f))
    ;; ^ GNU Emacs's `replace-overlay' (replace.el:3031): the overlay the
    ;; match being replaced is highlighted with. It is `replace-highlight''s
    ;; own, not isearch's - the C keeps the two separate so that leaving
    ;; query-replace cannot disturb a search in progress.

    (defface 'query-replace
          '((#t :inherit isearch))
          "Face for highlighting query replacement matches.
Used in `query-replace' and `query-replace-regexp'
when `query-replace-highlight' is non-nil")

    ;;----------------------------------------------------------------
    ;; The answers: `query-replace-map'
    ;;------------------------------------------------------------------

    (define *query-replace-map*
      ;; GNU Emacs's `query-replace-map' (replace.el:2788): "Keymap of
      ;; responses to questions posed by commands like `query-replace'.
      ;; The \"bindings\" in this map are not commands; they are
      ;; answers." The keys and the answers are the C's, one exception
      ;; being DEL: this tree folds a terminal's byte 8 (C-h) and byte
      ;; 127 (DEL) into one key path, `\(ctrl #\h)', and the C binds
      ;; THOSE to different answers (`\d' skip, `\C-h' help) - the
      ;; shared path is skip's, and help is left on `?'.
      ;;--------------------------------------------------------------
      (km:keymap '*query-replace-map*))

    (define (fill-query-replace-map!)
      ;; The bindings, in the C's order.
      ;;--------------------------------------------------------------
      (define-key *query-replace-map* (list #\space) 'act)
      (define-key *query-replace-map* (list (list 'ctrl #\h)) 'skip)
      (define-key *query-replace-map* (list #\y) 'act)
      (define-key *query-replace-map* (list #\n) 'skip)
      (define-key *query-replace-map* (list #\Y) 'act)
      (define-key *query-replace-map* (list #\N) 'skip)
      (define-key *query-replace-map* (list #\e) 'edit-replacement)
      (define-key *query-replace-map* (list #\E) 'edit-replacement-exact-case)
      (define-key *query-replace-map* (list #\,) 'act-and-show)
      (define-key *query-replace-map* (list #\q) 'exit)
      (define-key *query-replace-map* (list (list 'ctrl #\m)) 'exit)
      (define-key *query-replace-map* (list #\.) 'act-and-exit)
      (define-key *query-replace-map* (list (list 'ctrl #\r)) 'edit)
      (define-key *query-replace-map* (list (list 'ctrl #\w)) 'delete-and-edit)
      (define-key *query-replace-map* (list (list 'ctrl #\l)) 'recenter)
      (define-key *query-replace-map* (list #\!) 'automatic)
      (define-key *query-replace-map* (list #\^) 'backup)
      (define-key *query-replace-map* (list #\u) 'undo)
      (define-key *query-replace-map* (list #\U) 'undo-all)
      (define-key *query-replace-map* (list #\d) 'diff)
      (define-key *query-replace-map* (list #\?) 'help)
      (define-key *query-replace-map* (list (list 'ctrl #\g)) 'quit)
      (define-key *query-replace-map* (list (list 'ctrl #\])) 'quit)
      (define-key *query-replace-map* (list (list 'ctrl #\v)) 'scroll-up)
      (define-key *query-replace-map* (list (list 'meta #\v)) 'scroll-down)
      (define-key *query-replace-map* (list (list 'ctrl #\[)) 'exit-prefix))

    (fill-query-replace-map!)

    (define query-replace-help
      ;; GNU Emacs's `query-replace-help' (replace.el:2766), verbatim.
      ;; The `\\[...]' spellings print as they stand - there is no
      ;; `substitute-command-keys' here yet.
      ;;--------------------------------------------------------------
      "Type SPC or `y' to replace one match, Delete or `n' to skip to next,
RET or `q' to exit, Period to replace one match and exit,
`,' to replace but not move point immediately,
`!' to replace all remaining matches in this buffer with no more questions,
C-r to enter recursive edit (exit-recursive-edit to get out again),
C-w to delete match and then enter recursive edit,
^ to move point back to previous match,
u to undo previous replacement,
U to undo all replacements,
e to edit the replacement string.
E to edit the replacement string with exact case.
d to display the diff buffer with all replacements.
C-l to clear the screen, redisplay, and offer same replacement again,
Y to replace all remaining matches in all remaining buffers (in
multi-buffer replacements) with no more questions,
N (in multi-buffer replacements) to skip to the next buffer without
replacing remaining matches in the current buffer.
Any other character exits the interactive replacement loop, and is then
re-executed as a normal key sequence.")

    ;;----------------------------------------------------------------
    ;; Reading the arguments
    ;;------------------------------------------------------------------

    (define (query-replace-descr string)
      ;; GNU Emacs's `query-replace-descr' (replace.el:193): the string
      ;; a prompt shows FROM or TO as, with its control characters
      ;; drawn as `^X' caret notation. The C's version adds display
      ;; text properties; the prompt is a plain string here, so the
      ;; substitution is of the characters themselves.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length string))
            (apply string-append (reverse acc))
            (let* ((c (string-ref string i))
                   (ci (char->integer c)))
              (cond
               ((< ci 32)
                (loop (+ i 1)
                      ;; the letter first: the acc is reversed at
                      ;; the end
                      (cons (make-string 1 (integer->char (+ 64 ci)))
                            (cons (make-string 1 #\^) acc))))
               ((= ci 127)
                (loop (+ i 1) (cons "^?" acc)))
               (else (loop (+ i 1) (cons (make-string 1 c) acc))))))))

    (define (query-replace-separator-string)
      ;; GNU Emacs's `query-replace-read-from' computes this in its own
      ;; `let*': `query-replace-from-to-separator' when the terminal can
      ;; draw its first non-space character, and the " -> " spelling when
      ;; it cannot - so that a terminal which has no arrow glyph gets
      ;; something it can draw.
      ;;
      ;; An all-space separator has no character to ask about; Emacs's
      ;; `(string-to-char "")' is 0, and 0 is an ASCII character and so
      ;; always displayable, which is the branch taken here.
      ;;--------------------------------------------------------------
      (let ((separator *query-replace-from-to-separator*))
        (and separator
             (let loop ((i 0))
               (cond ((>= i (string-length separator)) separator)
                     ((char=? (string-ref separator i) #\space) (loop (+ i 1)))
                     ((char-displayable-p (string-ref separator i)) separator)
                     (else " -> "))))))

    (define (query-replace-pair-string from-to separator)
      ;; One replacement pair spelled the way the FROM prompt's history
      ;; holds it: "FROM → TO", which `query-replace--split-string' reads
      ;; back into the two halves.
      ;;--------------------------------------------------------------
      (string-append (query-replace-descr (car from-to))
                     separator
                     (query-replace-descr (cdr from-to))))

    (define (query-replace--split-string string separator)
      ;; GNU Emacs's `query-replace--split-string' (replace.el:208):
      ;; "Split string STRING at a substring with property `separator'" -
      ;; the answer `(FROM . TO)' when the text holds a separator, and
      ;; STRING itself when it does not.
      ;;
      ;; Emacs finds the separator by its `separator' text property, so
      ;; that a FROM which happens to contain the same characters is not
      ;; split. There are no text properties on a minibuffer answer here,
      ;; so the *substring* is what is looked for - which differs only
      ;; for a FROM that itself contains the separator text. The
      ;; fallback spelling " -> " is not split in Emacs either, the
      ;; property not being on it, so only the separator variable's own
      ;; text is searched for.
      ;;--------------------------------------------------------------
      (if (or (not separator) (= 0 (string-length separator)))
          string
          (let ((at (string-contains string separator)))
            (if (not at)
                string
                (cons (substring string 0 at)
                      (substring string (+ at (string-length separator))
                                 (string-length string)))))))

    (define (query-replace-read-from prompt regexp-flag)
      ;; GNU Emacs's `query-replace-read-from' (replace.el:242): "Query
      ;; and return the FROM argument of a `query-replace' operation.
      ;; The return value can also be a pair (FROM . TO)".
      ;;
      ;; The history the prompt walks is not the FROM history: the last
      ;; replacement *pairs*, each spelled "FROM → TO", come first, and
      ;; the plain FROM strings after them. That is what makes M-p and
      ;; M-n step through a whole previous replacement, and it is what
      ;; the prompt's default names - "Query replace (default a → b): ".
      ;;
      ;; Not ported: the `read-regexp' the regexp case reads with, and
      ;; `query-replace-read-from-suggestions' (the region, the tag at
      ;; point, the last search string) which Emacs offers through M-n.
      ;;--------------------------------------------------------------
      (let* ((separator-string (query-replace-separator-string))
             (defaults (*query-replace-defaults*))
             (pair-entries
              (if separator-string
                  (map (lambda (from-to)
                         (query-replace-pair-string from-to separator-string))
                       defaults)
                  '()))
             ;; the history to walk: the pairs, then the plain FROMs
             (walked (make<history>
                      (append pair-entries
                              (history-entries *query-replace-history*))))
             (default (and *query-replace-read-from-default*
                           (not regexp-flag)
                           (*query-replace-read-from-default*)))
             (prompt
              (cond
               ((and *query-replace-read-from-regexp-default* regexp-flag)
                prompt)
               (default (format-prompt prompt default))
               ;; NOTE: a Scheme empty list is TRUE, which Elisp's
               ;; nil is not - the C's `(if query-replace-defaults
               ;; ...)' is `(pair? defaults)' here or the caar of the
               ;; empty list is the error, which is what the first
               ;; run of this read made of it
               ((and (pair? defaults) separator-string)
                (format-prompt prompt (car pair-entries)))
               ((pair? defaults)
                (format-prompt
                 prompt
                 (string-append (query-replace-descr (caar defaults))
                                " -> "
                                (query-replace-descr (cdar defaults)))))
               (else (format-prompt prompt #f))))
             (from
              ;; `history-add-new-input' off, as the C turns it off: the
              ;; answer is put in the history below, and a reader that
              ;; put it in as well would file it twice - and would file
              ;; it in the *walked* list, which holds the pairs.
              (parameterize ((*history-add-new-input* #f))
                (read-from-minibuffer prompt #f #f walked #f))))
        (if (and (= 0 (string-length from))
                 (pair? defaults)
                 (not default))
            (cons (caar defaults)
                  (query-replace-compile-replacement
                   (cdar defaults) regexp-flag))
            (let* ((split (query-replace--split-string from separator-string))
                   (to (if (pair? split) (cdr split) #f))
                   (from (or (and (= 0 (string-length from)) default)
                             (if (pair? split) (car split) split))))
              (set!history-entries
               *query-replace-history*
               (add-to-history (history-entries *query-replace-history*)
                               from #f #t))
              (if (not to)
                  from
                  (begin
                    (set!history-entries
                     *query-replace-history*
                     (add-to-history (history-entries *query-replace-history*)
                                     to #f #t))
                    (*query-replace-defaults*
                     (cons (cons from to) (*query-replace-defaults*)))
                    (cons from
                          (query-replace-compile-replacement to regexp-flag))))))))

    (define (query-replace-compile-replacement to regexp-flag)
      ;; GNU Emacs's `query-replace-compile-replacement' (replace.el:301):
      ;; "Maybe convert a regexp replacement TO to Lisp" - the `\,' and
      ;; `\#' forms that evaluate Lisp. Those are not wired here (the
      ;; elisp evaluator is a library of its own); an empty string
      ;; stays empty, which is what the C answers for one.
      ;;--------------------------------------------------------------
      (if (and regexp-flag
               (or (string-contains to "\\,")
                   (string-contains to "\\#")))
          (error "Invalid use of `\\,' in replacement" to)
          to))

    (define (query-replace-read-to from prompt regexp-flag)
      ;; GNU Emacs's `query-replace-read-to' (replace.el:585): "Query
      ;; and return the TO argument of a `query-replace' operation" -
      ;; the TO prompt is FROM's text with " with: " after it.
      ;;--------------------------------------------------------------
      (let ((to
             ;; the reader does not file the answer; the C's
             ;; `history-add-new-input' is off and the history is written
             ;; below, once
             (parameterize ((*history-add-new-input* #f))
               (read-from-minibuffer
                (format #f "~a ~a with: " prompt (query-replace-descr from))
                #f #f *query-replace-history* from))))
        (set!history-entries
         *query-replace-history*
         (add-to-history (history-entries *query-replace-history*) to #f #t))
        (*query-replace-defaults*
         (cons (cons from to) (*query-replace-defaults*)))
        (query-replace-compile-replacement to regexp-flag)))

    (define (query-replace-read-args prompt regexp-flag . rest)
      ;; GNU Emacs's `query-replace-read-args' (replace.el:609): read
      ;; FROM and TO, and answer `(FROM TO DELIMITED BACKWARD)' - the
      ;; prefix argument's two meanings, the C's
      ;; `(and current-prefix-arg (not (eq current-prefix-arg '-)))' and
      ;; `(eq current-prefix-arg '-)'. A bare C-u is the list `(4)', a
      ;; bare M-- the symbol `-', never a number.
      ;;
      ;; The C's two optional arguments are NOERROR, which lets a
      ;; read-only buffer through to be complained about later, and
      ;; NO-HIGHLIGHT, which turns off the lazy highlight of the FROM
      ;; read below.
      ;;--------------------------------------------------------------
      (let ((noerror (list-ref-or rest 0 #f))
            (no-highlight (list-ref-or rest 1 #f)))
      (unless noerror
        (barf-if-buffer-read-only))
      (let* ((delimited (and (current-prefix-arg)
                             (not (eq? '- (current-prefix-arg)))))
             (backward (and (current-prefix-arg)
                            (eq? '- (current-prefix-arg)))))
        (save-excursion
          ;; The FROM read is made with the buffer's matches highlighted
          ;; as the pattern is typed: GNU Emacs wraps it in
          ;; `minibuffer-with-setup-hook' with
          ;; `minibuffer-lazy-highlight-setup' (replace.el:627), whose
          ;; TRANSFORM is the FROM half of a `FROM -> TO' pair - so a
          ;; history entry picked with M-p lights the buffer up as it is
          ;; put in the minibuffer, which is the other half of what the
          ;; C does there.
          (let* ((setup (minibuffer-lazy-highlight-setup
                         (not (eq? 'no-highlight no-highlight))
                         #f
                         (lambda (string)
                           (let ((split (query-replace--split-string
                                         string
                                         (query-replace-separator-string))))
                             (if (pair? split) (car split) split)))
                         regexp-flag
                         (*case-fold-search*)))
                 (from-pair (parameterize ((*minibuffer-setup-hook*
                                            (cons setup (*minibuffer-setup-hook*))))
                              (query-replace-read-from prompt regexp-flag)))
                 (from (if (pair? from-pair) (car from-pair) from-pair))
                 (to (if (pair? from-pair)
                         (cdr from-pair)
                         (query-replace-read-to from prompt regexp-flag))))
            (list from to delimited backward))))))

    ;;----------------------------------------------------------------
    ;; The search, the highlight, the stack
    ;;------------------------------------------------------------------

    (define (replace-search search-string limit regexp-flag
                            delimited-flag case-fold backward)
      ;; GNU Emacs's `replace-search' (replace.el:2994): "Search for
      ;; the next occurrence of SEARCH-STRING to replace" - the C's is
      ;; a shell around the isearch variables' search function; ours is
      ;; the literal search or the regexp one, under
      ;; `*case-fold-search*'. DELIMITED-FLAG asks for word-bounded
      ;; matches, which Emacs spells by wrapping the pattern in `\<'
      ;; and `\>': a literal FROM gets the boundary check, a regexp
      ;; FROM the wrapping.
      ;;--------------------------------------------------------------
      (parameterize ((*case-fold-search* case-fold))
        (cond
         (regexp-flag
          (let ((pattern (if delimited-flag
                             (string-append "\\<" search-string "\\>")
                             search-string)))
            (if backward
                (re-search-backward pattern limit #t)
                (re-search-forward pattern limit #t))))
         (else
          (let loop ()
            (let* ((found (if backward
                              (search-backward search-string limit #t)
                              (search-forward search-string limit #t)))
                   (ed (current-buffer)))
              (cond
               ((not found) #f)
               (delimited-flag
                ;; the match is one only when the character either
                ;; side of it fails to be a word character - and when
                ;; the buffer's edge is there
                (let* ((beg (- found (string-length search-string)))
                       (before (and (> beg 1) (char-after (- beg 1))))
                       (after (and (< found (text-editor-char-count ed))
                                   (char-after found))))
                  (if (and before (word-char? before))
                      (and (not backward) (loop))
                      (if (and after (word-char? after))
                          (and (not backward) (loop))
                          found))))
               (else found))))))))

    (define (replace-highlight match-beg match-end search-string
                               case-fold backward)
      ;; GNU Emacs's `replace-highlight' (replace.el:3034): "Highlight the
      ;; match to be replaced" - an overlay carrying the `query-replace'
      ;; face, "higher than lazy overlays" at priority 1001, and the rest
      ;; of the matches in the window handed to the lazy highlighter so
      ;; that what is coming up can be seen. The C's other arguments -
      ;; RANGE-BEG, RANGE-END, REGEXP-FLAG, DELIMITED-FLAG - bound the
      ;; lazy search and pick the faces for regexp submatches; the window
      ;; is the bound used here, which is the same set of matches
      ;; (`lazy-highlight-buffer' is nil in this call in the C too), and
      ;; the submatch faces are not ported.
      ;;
      ;; The highlight is an overlay and not a message to the display for
      ;; the reason the whole search highlight is: an overlay's face
      ;; *merges* with the text property's, so a font-locked word inside
      ;; the match keeps its colour.
      ;;--------------------------------------------------------------
      (when (*query-replace-highlight*)
        (if (replace-overlay)
            (move-overlay (replace-overlay) match-beg match-end
                          (current-buffer))
            (let ((overlay (make-overlay match-beg match-end)))
              (replace-overlay overlay)
              (overlay-put overlay 'priority 1001)
              (overlay-put overlay 'face 'query-replace))))
      (when (*query-replace-lazy-highlight*)
        (let ((frame (*current-frame*)))
          (isearch-lazy-highlight-update (current-buffer)
                                         (frame-selected-window frame)
                                         search-string case-fold)))
      (render! (*current-frame*))
      #f)

    (define (replace-dehighlight)
      ;; GNU Emacs's `replace-dehighlight' (replace.el:3087): "Cancel
      ;; highlighting of matches being replaced" - the overlay goes, and
      ;; the lazy highlighting with it.
      ;;--------------------------------------------------------------
      (when (replace-overlay)
        (delete-overlay (replace-overlay))
        (replace-overlay #f))
      (when (*query-replace-lazy-highlight*)
        (lazy-highlight-cleanup (*lazy-highlight-cleanup*)))
      #f)

    (define (replace-match-maybe-edit newtext fixedcase literal noedit
                                      match-data backward)
      ;; GNU Emacs's `replace-match-maybe-edit' (replace.el:2936):
      ;; "Make a replacement with `replace-match', editing `\?'" - a
      ;; `\?' in the replacement asks the user for what goes there.
      ;; The C's scan is a regexp over NEWTEXT; ours is a walk keeping
      ;; the backslash doubling straight. The edit is a minibuffer
      ;; read, the C's `read-string'.
      ;;--------------------------------------------------------------
      (let* ((noedit
              (if literal
                  noedit
                  ;; the scan: `\?' asks, `\\' is a backslash, `\N'
                  ;; and `\&' pass; anything else after a backslash
                  ;; is left standing, which is what replace-match
                  ;; will read
                  (let scan ((i 0) (noedit noedit) (even? #t) (acc '()))
                    (cond
                     ((>= i (string-length newtext))
                      (list->string (reverse acc)))
                     ((char=? (string-ref newtext i) #\\)
                      (if (>= (+ i 1) (string-length newtext))
                          ;; a trailing backslash: leave it standing
                          (list->string
                           (reverse (cons #\\ acc)))
                          (let ((c (string-ref newtext (+ i 1))))
                            (cond
                             ((char=? c #\\)
                              (scan (+ i 2) noedit #t
                                    (cons #\\ (cons #\\ acc))))
                             ((and (char=? c #\?) even?)
                              ;; the `\?' asks: read what goes there,
                              ;; what has been read so far being the
                              ;; text before it
                              (let* ((before (list->string (reverse acc)))
                                     (after (substring
                                             newtext (+ i 2)
                                             (string-length newtext)))
                                     (edited
                                      (read-from-minibuffer
                                       "Edit replacement string: "
                                       before #f #f #f)))
                                ;; the answer replaces everything up
                                ;; to the `\?', the text after it
                                ;; following: the C replaces the
                                ;; `\?' match and re-scans
                                (let ((new (string-append
                                            edited
                                            after)))
                                  (scan 0 noedit #t
                                        (reverse (string->list new))))))
                             (else
                              (scan (+ i 2) noedit #f
                                    (cons (make-string 1 c) acc)))))))
                     (else (scan (+ i 1) noedit even?
                                 (cons (string-ref newtext i) acc))))))))
        (set-match-data match-data)
        (replace-match newtext fixedcase literal)
        (when backward (goto-char (match-beginning 0)))
        noedit))

    (define (replace--push-stack replaced search-str next-replace
                                 next-replacement match-again stack)
      ;; GNU Emacs's `replace--push-stack' (replace.el:3057): the
      ;; element the `^' and `u' answers walk back to: the point, what
      ;; was replaced, the match data as it stands, the strings
      ;; involved, and whether an adjacent match is possible.
      ;;--------------------------------------------------------------
      (cons
       (list (point)
             replaced
             (match-data)
             search-str
             next-replace
             next-replacement
             match-again)
       stack))

    ;;----------------------------------------------------------------
    ;; The help
    ;;------------------------------------------------------------------

    (define (show-query-replace-help frame from-string next-replacement
                                     backward delimited-flag regexp-flag)
      ;; The C's `help' answer: the help text into a `*Help*' buffer,
      ;; displayed WITHOUT selecting it - the replaced buffer stays the
      ;; current one. There is no help-mode or with-output-to-
      ;; temp-buffer here; the buffer is made, filled and shown.
      ;;--------------------------------------------------------------
      (let ((help-text
             (string-append
              "Query replacing "
              (if backward "backward " "")
              (if delimited-flag "word " "")
              (if regexp-flag "regexp " "")
              (query-replace-descr from-string) " with "
              (query-replace-descr next-replacement) ".\n\n"
              query-replace-help "\n")))
        (with-current-buffer
            (get-buffer-create "*Help*")
          (erase-buffer)
          (insert help-text))
        (display-buffer (get-buffer-create "*Help*"))
        (render! frame)))

    (define (undo-replacements def stack replaced last-was-act-and-show
                               literal regexp-flag backward noedit
                               get-real-match-data set-real-match-data!
                               set-noedit! get-replace-count
                               set-replace-count! set-next-replacement!
                               set-search-string-replaced!
                               set-next-replacement-replaced!)
      ;; The `u' and `U' responses' walk (replace.el:3476-3530): the
      ;; stack of replacement records is walked back, each REPLACED
      ;; element undone by re-applying `replace-match-maybe-edit' with
      ;; the search-string and the replacement swapped - which the C
      ;; does by looking the restored string up again (`looking-at
      ;; (regexp-quote ...)') to have the match data the undo needs.
      ;; `nocasify' is forced true the whole way (Bug#31073: undo must
      ;; preserve case). Answers the stack as it now stands; the
      ;; setters carry what the caller's locals take.
      ;;--------------------------------------------------------------
      (if (not stack)
          (begin (set-message! (*current-frame*) "Nothing to undo" 1)
                 (render! (*current-frame*))
                 stack)
          (let loop ((stack-idx 0)
                     (stack-len (length stack))
                     (stack stack)
                     (num-replacements 0)
                     (replaced replaced))
            (if (and (< stack-idx stack-len)
                     (pair? stack)
                     (or (not replaced) last-was-act-and-show))
                (let* ((elt (list-ref stack stack-idx))
                       (elt-replaced (list-ref elt 1))
                       ;; the swapped values (search-string <->
                       ;; replacement), as the C's comment says
                       (search-string
                        (list-ref elt (if elt-replaced 4 3)))
                       (last-replacement
                        (list-ref elt (if elt-replaced 3 4))))
                  (set-search-string-replaced! search-string)
                  (set-next-replacement-replaced! last-replacement)
                  (cond
                   ((and (= (+ stack-idx 1) stack-len)
                         (not elt-replaced)
                         (not last-was-act-and-show)
                         (= 0 num-replacements))
                    (set-message! (*current-frame*) "Nothing to undo" 1)
                    (render! (*current-frame*))
                    stack)
                   (elt-replaced
                    (set! stack (list-tail stack (+ stack-idx 1)))
                    (goto-char (list-ref elt 0))
                    (set-match-data (list-ref elt 2))
                    (save-excursion
                      (goto-char (match-beginning 0))
                      ;; We must quote the string (Bug#37073)
                      (looking-at (regexp-quote search-string))
                      (set-real-match-data! (match-data)))
                    (set-noedit!
                     (replace-match-maybe-edit
                      last-replacement #t literal noedit
                      (get-real-match-data) backward))
                    (set-replace-count!
                     (- (get-replace-count) 1))
                    (goto-char (match-beginning 0))
                    (looking-at (if regexp-flag
                                    last-replacement
                                    (regexp-quote last-replacement)))
                    (set-real-match-data! (match-data))
                    (when regexp-flag
                      (set-next-replacement! (list-ref elt 4)))
                    ;; Set replaced nil to keep in loop
                    (if (eq? def 'undo-all)
                        (loop 0
                              (- stack-len (+ stack-idx 1))
                              stack
                              (+ num-replacements 1)
                              #f)
                        stack))
                   (else
                    (loop (+ stack-idx 1) stack-len stack
                          num-replacements elt-replaced))))
                (begin
                  (when (and (eq? def 'undo-all) (not (= 0 num-replacements)))
                    (set-message!
                     (*current-frame*)
                     (format #f "Undid ~a replacement~a"
                             num-replacements
                             (if (= 1 num-replacements) "" "s"))
                     1)
                    (render! (*current-frame*)))
                  stack)))))

    ;;----------------------------------------------------------------
    ;; `perform-replace'
    ;;------------------------------------------------------------------

    (define (perform-replace from-string replacements
                             query-flag regexp-flag delimited-flag
                             . args)
      ;; GNU Emacs's `perform-replace' (replace.el:3141): "Subroutine
      ;; of `query-replace'.  Its complexity handles interactive
      ;; queries." REPLACEMENTS is a string; the C's cons-of-function
      ;; forms are what `\,' reads - not ported. The optional
      ;; arguments are REPEAT-COUNT, MAP, START, END and BACKWARD,
      ;; which the interactive forms pass in the C's order. Answering
      ;; nil when there were no matches, or the stack when the loop
      ;; was left early (`^' to come back to), as the C does.
      ;;--------------------------------------------------------------
      (let* ((repeat-count (if (pair? args) (car args) 1))
             (map-arg (if (and (pair? args) (pair? (cdr args))) (cadr args) #f))
             (start (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args)))
                        (caddr args) #f))
             (end (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                           (pair? (cdddr args)))
                      (cadddr args) #f))
             (backward (if (and (pair? args) (pair? (cdr args)) (pair? (cddr args))
                                (pair? (cdddr args)) (pair? (cddddr args)))
                           (list-ref args 4) #f))
             (map (or map-arg *query-replace-map*))
             (case-fold
              (if (and (*case-fold-search*) (*search-upper-case*))
                  (isearch-no-upper-case-p from-string regexp-flag)
                  (*case-fold-search*)))
             (nocasify (not (and (*case-replace*) case-fold)))
             (literal (or (not regexp-flag) (eq? regexp-flag 'literal)))
             (frame (*current-frame*)))
        (parameterize ((*case-fold-search* case-fold))
          (let* ((search-string from-string)
                 (real-match-data #f)
                 ;; the C's `((stringp replacements) (setq
                 ;; next-replacement replacements ...))': a string's
                 ;; replacement is itself
                 (next-replacement (if (string? replacements) replacements #f))
                 (noedit #f)
                 (keep-going #t)
                 (stack '())
                 (search-string-replaced #f)
                 (next-replacement-replaced #f)
                 (last-was-undo #f)
                 (last-was-act-and-show #f)
                 (update-stack #t)
                 (replace-count 0)
                 (skip-read-only-count 0)
                 (skip-filtered-count 0)
                 (skip-invisible-count 0)
                 (nonempty-match #f)
                 (multi-buffer #f)
                 (recenter-last-op #f)
                 (limit #f)
                 (match-again #t)
                 (replaced-this #f))
            ;; If region is active, in Transient Mark mode, operate on
            ;; region - the C's entry, which deactivates the mark the
            ;; region came from.
            (if backward
                (when end
                  (set! limit (copy-marker (current-buffer)
                                           (- (min start end) 1)))
                  (goto-char (max start end))
                  (deactivate-mark))
                (when start
                  (set! limit (copy-marker (current-buffer)
                                           (- (max start end) 1)))
                  (goto-char (min start end))
                  (deactivate-mark)))
            (push-mark)
            (text-editor-undo-boundary! (current-buffer))
            ;; the C's unwind-protect: the highlight is cleared however
            ;; the loop leaves - a quit included
            (dynamic-wind
             (lambda () #f)
             (lambda ()
               ;; Loop finding occurrences that perhaps should be
               ;; replaced.
               (let main-loop ()
                 (if (not (and keep-going
                               (if backward
                                   (not (or (bobp)
                                            (and limit
                                                 (<= (point)
                                                     (marker-position limit)))))
                                   (not (or (eobp)
                                            (and limit
                                                 (>= (point)
                                                     (marker-position limit))))))))
                     #f
                     ;; the next match, the C's three branches of
                     ;; `match-again'
                     (let ((m (cond
                               ;; a known match: take it, as the C's
                               ;; `(consp match-again)' branch does
                               ((pair? match-again)
                                ;; the C's `(nth 0 match-again)' and
                                ;; `(nth 1 match-again)' - the pair's
                                ;; two ends. It was `(cdr match-again)'
                                ;; here, which is the *rest of the
                                ;; list*, so point was asked to go to a
                                ;; list of markers: "Wrong type argument
                                ;; in position 1" at the second
                                ;; occurrence of a regexp replacement.
                                (goto-char
                                 (if backward
                                     (car match-again)
                                     (cadr match-again)))
                                (match-data))
                               (match-again
                                (and (replace-search
                                      search-string
                                      (and limit
                                           (+ 1 (marker-position limit)))
                                      regexp-flag delimited-flag
                                      case-fold backward)
                                     (match-data)))
                               ;; not accepting adjacent matches:
                               ;; move one char and search again,
                               ;; restoring point when the search
                               ;; fails
                               ((and (if backward
                                         (> (- (point) 1) (point-min))
                                         (< (+ (point) 1) (point-max)))
                                     (or (not limit)
                                         (if backward
                                             (> (- (point) 1)
                                                (marker-position limit))
                                             (< (+ (point) 1)
                                                (marker-position limit)))))
                                (let ((opoint (point)))
                                  (goto-char (+ opoint
                                                (if backward -1 1)))
                                  (or (and (replace-search
                                            search-string
                                            (and limit
                                                 (+ 1 (marker-position limit)))
                                            regexp-flag delimited-flag
                                            case-fold backward)
                                           (match-data))
                                      (begin (goto-char opoint) #f))))
                               (else #f))))
                       (if (not m)
                           ;; no more matches
                           (set! keep-going #f)
                           (begin
                             (set! real-match-data m)
                             ;; Record whether the match is
                             ;; nonempty, to avoid an infinite loop
                             ;; repeatedly matching the same empty
                             ;; string - and whether the next one
                             ;; can be adjacent.
                             (set! nonempty-match
                                   (not (= (match-beginning 0)
                                           (match-end 0))))
                             (set! match-again
                                   (and nonempty-match
                                        (or (not regexp-flag)
                                            (and (if backward
                                                     (looking-back
                                                      search-string)
                                                     (looking-at
                                                      search-string))
                                                 (let ((match (match-data)))
                                                   ;; the C's `/=' - is
                                                   ;; the match
                                                   ;; nonempty. Emacs's
                                                   ;; `=' compares
                                                   ;; markers by their
                                                   ;; positions; Scheme's
                                                   ;; takes numbers, so
                                                   ;; the positions are
                                                   ;; read out of them
                                                   ;; first.
                                                   (and (not (= (if (marker-type? (car match))
                                                                   (marker-position (car match))
                                                                   (car match))
                                                                (if (marker-type? (cadr match))
                                                                    (marker-position (cadr match))
                                                                    (cadr match))))
                                                        match))))))
                             (set! replaced-this #f)
                             (if (not query-flag)
                                 ;; an automatic replacement
                                 (begin
                                   (unless (or literal noedit)
                                     (replace-highlight
                                      (match-beginning 0) (match-end 0)
                                      search-string case-fold backward))
                                   (set! noedit
                                         (replace-match-maybe-edit
                                          next-replacement nocasify literal
                                          noedit real-match-data backward))
                                   (set! replace-count (+ 1 replace-count)))
                                 ;; the query itself
                                 (begin
                                   (text-editor-undo-boundary!
                                    (current-buffer))
                                   ;; Loop reading commands until
                                   ;; one of them sets done, which
                                   ;; means it has finished handling
                                   ;; this occurrence. Any command
                                   ;; that sets `done' should leave
                                   ;; behind proper match data for
                                   ;; the stack.
                                   (let response ((done #f) (replaced #f))
                                     (if done
                                         #f
                                         (begin
                                           ;; This sets match data
                                           ;; only for the next hook
                                           ;; and the highlight that
                                           ;; calls for the redraw.
                                           (set-match-data real-match-data)
                                           (replace-highlight
                                            (match-beginning 0) (match-end 0)
                                            search-string case-fold backward)
                                           (let* ((replacement-presentation
                                                   (if (*query-replace-show-replacement*)
                                                       (match-substitute-replacement
                                                        next-replacement
                                                        nocasify literal)
                                                       next-replacement))
                                                  (prompt
                                                   (format
                                                    #f
                                                    "Query replacing ~a with ~a: (help for help) "
                                                    (query-replace-descr
                                                     from-string)
                                                    (query-replace-descr
                                                     replacement-presentation))))
                                             (set!frame-message frame prompt)
                                             (render! frame)
                                             (let* ((ev (read-key-event -1))
                                                    (path (key-event->keymap-path
                                                           (current-display) ev))
                                                    (def (km:keymap-lookup
                                                          map
                                                          (km:keymap-index
                                                           path))))
                                               (cond
                                                ((eq? def 'help)
                                                 (show-query-replace-help
                                                  frame from-string
                                                  next-replacement backward
                                                  delimited-flag regexp-flag)
                                                 (response done replaced))
                                                ((eq? def 'exit)
                                                 (set! keep-going #f)
                                                 (response #t replaced))
                                                ((eq? def 'backup)
                                                 (if (pair? stack)
                                                     (let ((elt (car stack)))
                                                       (set! stack (cdr stack))
                                                       (goto-char (car elt))
                                                       (set! real-match-data
                                                             (list-ref elt 2))
                                                       (set! next-replacement
                                                             (list-ref elt 5))
                                                       (set! match-again
                                                             (list-ref elt 6))
                                                       (response done replaced))
                                                     (begin
                                                       (set-message! frame
                                                                     "No previous match"
                                                                     1)
                                                       (render! frame)
                                                       (response done replaced))))
                                                ((or (eq? def 'undo)
                                                     (eq? def 'undo-all))
                                                 (set! stack
                                                       (undo-replacements
                                                        def stack replaced
                                                        last-was-act-and-show
                                                        literal regexp-flag
                                                        backward noedit
                                                        (lambda () real-match-data)
                                                        (lambda (md)
                                                          (set! real-match-data md))
                                                        (lambda (ne)
                                                          (set! noedit ne))
                                                        ;; the C's
                                                        ;; GET-REPLACE-COUNT,
                                                        ;; which this call
                                                        ;; did not pass -
                                                        ;; five of the
                                                        ;; eight accessors
                                                        ;; were supplied
                                                        (lambda () replace-count)
                                                        (lambda (n)
                                                          (set! replace-count n))
                                                        (lambda (nr)
                                                          (set! next-replacement nr))
                                                        (lambda (v)
                                                          (set! search-string-replaced v))
                                                        (lambda (v)
                                                          (set! next-replacement-replaced v))))
                                                 (set! last-was-undo #t)
                                                 (set! last-was-act-and-show #f)
                                                 (response done replaced))
                                                ((eq? def 'act)
                                                 (or replaced
                                                     (begin
                                                       (set! noedit
                                                             (replace-match-maybe-edit
                                                              next-replacement
                                                              nocasify literal
                                                              noedit
                                                              real-match-data
                                                              backward))
                                                       (set! replace-count
                                                             (+ 1 replace-count))))
                                                 (set! update-stack
                                                       (not last-was-act-and-show))
                                                 (response #t #t))
                                                ((eq? def 'act-and-exit)
                                                 (or replaced
                                                     (begin
                                                       (set! noedit
                                                             (replace-match-maybe-edit
                                                              next-replacement
                                                              nocasify literal
                                                              noedit
                                                              real-match-data
                                                              backward))
                                                       (set! replace-count
                                                             (+ 1 replace-count))))
                                                 (set! keep-going #f)
                                                 (response #t #t))
                                                ((eq? def 'act-and-show)
                                                 (unless replaced
                                                   (set! noedit
                                                         (replace-match-maybe-edit
                                                          next-replacement
                                                          nocasify literal
                                                          noedit
                                                          real-match-data
                                                          backward))
                                                   (set! replace-count
                                                         (+ 1 replace-count))
                                                   (set! real-match-data
                                                         (match-data))
                                                   (set! replaced #t)
                                                   (set! last-was-act-and-show #t)
                                                   (set! stack
                                                         (replace--push-stack
                                                          replaced
                                                          search-string-replaced
                                                          next-replacement-replaced
                                                          next-replacement
                                                          match-again
                                                          stack)))
                                                 (response done #t))
                                                ((or (eq? def 'automatic)
                                                     (eq? def 'automatic-all))
                                                 (or replaced
                                                     (begin
                                                       (set! noedit
                                                             (replace-match-maybe-edit
                                                              next-replacement
                                                              nocasify literal
                                                              noedit
                                                              real-match-data
                                                              backward))
                                                       (set! replace-count
                                                             (+ 1 replace-count))))
                                                 (set! query-flag #f)
                                                 (response #t #t))
                                                ((eq? def 'skip)
                                                 (set! update-stack
                                                       (not last-was-act-and-show))
                                                 (response #t #f))
                                                ((eq? def 'recenter)
                                                 (recenter #f)
                                                 (set! recenter-last-op #f)
                                                 (response done replaced))
                                                ((eq? def 'scroll-up)
                                                 (scroll-up-command #f)
                                                 (set! recenter-last-op #f)
                                                 (response done replaced))
                                                ((eq? def 'scroll-down)
                                                 (scroll-down-command #f)
                                                 (set! recenter-last-op #f)
                                                 (response done replaced))
                                                ((eq? def 'edit)
                                                 ;; C-r: a recursive edit over
                                                 ;; the match
                                                 (set! real-match-data
                                                       (match-data))
                                                 (goto-char (match-beginning 0))
                                                 (save-excursion
                                                   (parameterize
                                                    ((*current-keymap* #f))
                                                    (recursive-edit frame)))
                                                 (if (and regexp-flag
                                                          nonempty-match)
                                                     (set! match-again
                                                           (and (looking-at
                                                                 search-string)
                                                                (match-data))))
                                                 (response done replaced))
                                                ((or (eq? def 'edit-replacement)
                                                     (eq? def
                                                          'edit-replacement-exact-case))
                                                 (set! next-replacement
                                                       (read-from-minibuffer
                                                        (format
                                                         #f
                                                         "Edit replacement string~a: "
                                                         (if (eq? def
                                                                  'edit-replacement-exact-case)
                                                             " (exact case)"
                                                             ""))
                                                        next-replacement
                                                        #f
                                                        *query-replace-history*
                                                        #f))
                                                 (set! noedit #f)
                                                 (if replaced
                                                     (begin
                                                       (set-match-data
                                                        real-match-data)
                                                       (set!
                                                        next-replacement-replaced
                                                        next-replacement))
                                                     (begin
                                                       (set! noedit
                                                             (replace-match-maybe-edit
                                                              next-replacement
                                                              (if (eq? def
                                                                       'edit-replacement-exact-case)
                                                                  #t
                                                                  nocasify)
                                                              literal noedit
                                                              real-match-data
                                                              backward))
                                                       (set! replaced #t)))
                                                 (response #t replaced))
                                                ((eq? def 'delete-and-edit)
                                                 (replace-match "" #t #t)
                                                 (set! real-match-data
                                                       (match-data))
                                                 (replace-dehighlight)
                                                 (save-excursion
                                                   (recursive-edit frame))
                                                 (set! replaced #t)
                                                 (response #t #t))
                                                ((eq? def 'quit)
                                                 (signal-quit))
                                                ;; the `commandp'
                                                ;; fall-through and the
                                                ;; unknown key: exit the
                                                ;; loop and give the key
                                                ;; back to the command
                                                ;; loop. Note the C's
                                                ;; comment: we do not need
                                                ;; to treat `exit-prefix'
                                                ;; specially, since we
                                                ;; reread any unrecognized
                                                ;; character.
                                                (else
                                                 (set! keep-going #f)
                                                 (*unread-command-events*
                                                  (cons ev
                                                        (*unread-command-events*)))
                                                 (response #t replaced))))))))))))
                     ;; the occurrence is handled: record the
                     ;; previous position for `^' when we move on
                     (when update-stack
                       (set! stack
                             (replace--push-stack
                              replaced-this
                              search-string-replaced
                              next-replacement-replaced
                              next-replacement
                              match-again
                              stack)))
                     (set! next-replacement-replaced #f)
                     (set! search-string-replaced #f)
                     (set! last-was-act-and-show #f)
                     (set! replaced-this #f)
                     (main-loop)))))
             (lambda ()
               (replace-dehighlight)))
            ;; the message the C's ends with
            (set!frame-message
             frame
             (format #f "Replaced ~a occurrence~a"
                     replace-count
                     (if (= 1 replace-count) "" "s")))
            (or (and keep-going stack) multi-buffer)))))


    ;;----------------------------------------------------------------
    ;; The commands
    ;;------------------------------------------------------------------

    (define-command (query-replace from-string to-string delimited start end
                                   backward)
      ;; GNU Emacs's `query-replace' (replace.el:687): "Replace some
      ;; occurrences of FROM-STRING with TO-STRING." The interactive
      ;; form's `(use-region-beginning)' / `(use-region-end)' become
      ;; `(and (use-region-p) (region-beginning))' etc.; there is no
      ;; `"r"' spec here.
      "Replace some occurrences of FROM-STRING with TO-STRING.
As each match is found, the user must type a character saying
what to do with it.  Type SPC or `y' to replace the match,
DEL or `n' to skip and go to the next match.  For more directions,
type \\[help-command] at that time."
      (interactive
       (let ((common
              (query-replace-read-args
               (string-append
                "Query replace"
                (if (current-prefix-arg)
                    (if (eq? '- (current-prefix-arg))
                        " backward" " word")
                    "")
                (if (use-region-p) " in region" ""))
               #f)))
         (list (car common) (cadr common) (caddr common)
               (and (use-region-p) (region-beginning))
               (and (use-region-p) (region-end))
               (cadddr common))))
      (perform-replace from-string to-string #t #f delimited
                       1 *query-replace-map* start end backward))

    (define-command (query-replace-regexp regexp to-string delimited
                                          start end backward)
      ;; GNU Emacs's `query-replace-regexp' (replace.el:770): the
      ;; regexp variant, which passes `regexp-flag' #t.
      "Replace some things after point matching REGEXP with TO-STRING.
As each match is found, the user must type a character saying
what to do with it.  Type SPC or `y' to replace the match,
DEL or `n' to skip and go to the next match."
      (interactive
       (let ((common
              (query-replace-read-args
               (string-append
                "Query replace regexp"
                (if (current-prefix-arg)
                    (if (eq? '- (current-prefix-arg))
                        " backward" " word")
                    "")
                (if (use-region-p) " in region" ""))
               #t)))
         (list (car common) (cadr common) (caddr common)
               (and (use-region-p) (region-beginning))
               (and (use-region-p) (region-end))
               (cadddr common))))
      (perform-replace regexp to-string #t #t delimited
                       1 *query-replace-map* start end backward))

    (define-command (replace-string from-string to-string delimited
                                    start end backward)
      ;; GNU Emacs's `replace-string' (replace.el:937): "Replace
      ;; occurrences of FROM-STRING with TO-STRING" - no questions
      ;; asked, which is `query-flag' nil. M-x only, as in Emacs.
      "Replace occurrences of FROM-STRING with TO-STRING.
Preserve case in each match.  If third arg DELIMITED is non-nil,
protect case of replaced text."
      (interactive
       (let ((common
              (query-replace-read-args
               (string-append
                "Replace"
                (if (current-prefix-arg)
                    (if (eq? '- (current-prefix-arg))
                        " backward" " word")
                    "")
                (if (use-region-p) " in region" ""))
               #f)))
         (list (car common) (cadr common) (caddr common)
               (and (use-region-p) (region-beginning))
               (and (use-region-p) (region-end))
               (cadddr common))))
      (perform-replace from-string to-string #f #f delimited
                       1 *query-replace-map* start end backward))

    (define-command (replace-regexp regexp to-string delimited
                                    start end backward)
      ;; GNU Emacs's `replace-regexp' (replace.el:1001): the automatic
      ;; regexp replacement.
      "Replace things after point matching REGEXP with TO-STRING.
This is a generic function; see `replace-regexp'."
      (interactive
       (let ((common
              (query-replace-read-args
               (string-append
                "Replace"
                (if (current-prefix-arg)
                    (if (eq? '- (current-prefix-arg))
                        " backward" " word")
                    "")
                (if (use-region-p) " in region" ""))
               #t)))
         (list (car common) (cadr common) (caddr common)
               (and (use-region-p) (region-beginning))
               (and (use-region-p) (region-end))
               (cadddr common))))
      (perform-replace regexp to-string #f #t delimited
                       1 *query-replace-map* start end backward))

    (define-key *default-keymap* (list (list 'meta #\%)) query-replace)
    (define-key *default-keymap* (list (list 'meta 'ctrl #\%))
      query-replace-regexp)

    ))
